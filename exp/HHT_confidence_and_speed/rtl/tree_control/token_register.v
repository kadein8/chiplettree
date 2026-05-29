`timescale 1ns/1ps

`include "config/prediction_params.vh"
`include "config/interface_params.vh"
`include "config/memory_params.vh"

/*
 * 文件作用：
 * 1. 本文件实现论文 TreeControl 资源管理链里的 token_register。
 * 2. 它维护“逻辑 token / position / req_id”到“物理 KV 位置”的映射表，是
 *    TreeControl 在运行期查询 token 位置的核心索引之一。
 * 3. 在论文完整主路径里，它位于：
 *    AGU / free_list
 *      -> token_register
 *      -> comparator / 后续控制逻辑查表
 * 4. free_list 只负责分到哪块 SRAM 空间；token_register 负责把“是谁占了这块空间”
 *    记下来，方便后续按 token_id + position_id 反查。
 * 5. 当前 frozen strict tree-mask shortcut 主路径会绕过这套串行动态管理，
 *    但论文完整设计里，这个模块属于 TreeControl 基础台账。
 */
module token_register (
    // 时钟与复位。
    input                        clk,
    input                        rst_n,

    // 写入端：
    // AGU / free_list 确认好物理位置后，把一个 token 条目写进表里。
    input                        wr_valid,
    output                       wr_ready,
    input  [`TOKEN_REG_INDEX_W-1:0] wr_index,
    input  [`REQ_ID_W-1:0]       wr_req_id,
    input  [`TOKEN_ID_W-1:0]     wr_token_id,
    input  [`POSITION_ID_W-1:0]  wr_position_id,
    input  [`NODE_ID_W-1:0]      wr_node_id,
    input  [`BRANCH_ID_W-1:0]    wr_branch_id,
    input  [`SRAM_ID_W-1:0]      wr_sram_id,
    input  [`BANK_ID_W-1:0]      wr_bank_id,
    input  [`SUBBANK_ID_W-1:0]   wr_subbank_start,
    input  [`KV_GROUP_LEN_W-1:0] wr_group_len,
    input  [`BRANCH_MASK_W-1:0]  wr_branch_mask,
    input                        wr_is_shared,
    // wr_bundle_*：
    // 1. 这是论文路径里 AGU/free_list -> token_register 的并行写表边界；
    // 2. bundle 入口优先于旧标量 wr_*，用于整层/多 branch 同拍写入 token->KV 映射；
    // 3. 每个有效 slot 都在本拍独立写入自己的表项，不再因为多 slot 同拍而整拍停住。
    input                        wr_bundle_valid,
    output                       wr_bundle_ready,
    input  [`TREE_FRONTIER_SLOTS-1:0] wr_bundle_slot_valid,
    input  [`TREE_FRONTIER_SLOTS*`TOKEN_REG_INDEX_W-1:0] wr_bundle_index,
    input  [`REQ_ID_W-1:0]       wr_bundle_req_id,
    input  [`TREE_FRONTIER_SLOTS*`TOKEN_ID_W-1:0] wr_bundle_token_id,
    input  [`TREE_FRONTIER_SLOTS*`POSITION_ID_W-1:0] wr_bundle_position_id,
    input  [`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0] wr_bundle_node_id,
    input  [`TREE_FRONTIER_SLOTS*`BRANCH_ID_W-1:0] wr_bundle_branch_id,
    input  [`TREE_FRONTIER_SLOTS*`SRAM_ID_W-1:0] wr_bundle_sram_id,
    input  [`TREE_FRONTIER_SLOTS*`BANK_ID_W-1:0] wr_bundle_bank_id,
    input  [`TREE_FRONTIER_SLOTS*`SUBBANK_ID_W-1:0] wr_bundle_subbank_start,
    input  [`TREE_FRONTIER_SLOTS*`KV_GROUP_LEN_W-1:0] wr_bundle_group_len,
    input  [`TREE_FRONTIER_SLOTS*`BRANCH_MASK_W-1:0] wr_bundle_branch_mask,
    input  [`TREE_FRONTIER_SLOTS-1:0] wr_bundle_is_shared,

    // 查找端：
    // 按 req_id + token_id + position_id 查回对应的物理 KV 位置与条目状态。
    input                        lookup_valid,
    output                       lookup_ready,
    input  [`REQ_ID_W-1:0]       lookup_req_id,
    input  [`TOKEN_ID_W-1:0]     lookup_token_id,
    input  [`POSITION_ID_W-1:0]  lookup_position_id,
    output                       lookup_resp_valid,
    output                       lookup_resp_hit,
    output [`REQ_ID_W-1:0]       lookup_resp_req_id,
    output [`SRAM_ID_W-1:0]      lookup_resp_sram_id,
    output [`BANK_ID_W-1:0]      lookup_resp_bank_id,
    output [`SUBBANK_ID_W-1:0]   lookup_resp_subbank_start,
    output [`KV_GROUP_LEN_W-1:0] lookup_resp_group_len,
    output [`BRANCH_MASK_W-1:0]  lookup_resp_branch_mask,
    output                       lookup_resp_is_shared,
    output [`TOKEN_STATE_W-1:0]  lookup_resp_state,
    output [`TOKEN_ENTRY_TYPE_W-1:0] lookup_resp_entry_type,
    // lookup_bundle_*：
    // 1. 这是论文 strict 主路径里 token_register -> compute issue 的并行查表边界；
    // 2. 上游一次提交一个 level/bundle，请求同拍查回多个 branch/slot 的物理 KV 位置；
    // 3. 与单 lookup 一样，响应在下一拍寄存输出，便于后级统一按 ready/valid 接收。
    input                        lookup_bundle_valid,
    output                       lookup_bundle_ready,
    input  [`REQ_ID_W-1:0]       lookup_bundle_req_id,
    input  [`TREE_FRONTIER_SLOTS-1:0] lookup_bundle_slot_valid,
    input  [`TREE_FRONTIER_SLOTS*`TOKEN_ID_W-1:0] lookup_bundle_token_id,
    input  [`TREE_FRONTIER_SLOTS*`POSITION_ID_W-1:0] lookup_bundle_position_id,
    output                       lookup_bundle_resp_valid,
    output [`REQ_ID_W-1:0]       lookup_bundle_resp_req_id,
    output [`TREE_FRONTIER_SLOTS-1:0] lookup_bundle_resp_hit,
    output [`TREE_FRONTIER_SLOTS*`SRAM_ID_W-1:0] lookup_bundle_resp_sram_id,
    output [`TREE_FRONTIER_SLOTS*`BANK_ID_W-1:0] lookup_bundle_resp_bank_id,
    output [`TREE_FRONTIER_SLOTS*`SUBBANK_ID_W-1:0] lookup_bundle_resp_subbank_start,
    output [`TREE_FRONTIER_SLOTS*`KV_GROUP_LEN_W-1:0] lookup_bundle_resp_group_len,
    output [`TREE_FRONTIER_SLOTS*`BRANCH_MASK_W-1:0] lookup_bundle_resp_branch_mask,
    output [`TREE_FRONTIER_SLOTS-1:0] lookup_bundle_resp_is_shared,
    output [`TREE_FRONTIER_SLOTS*`TOKEN_STATE_W-1:0] lookup_bundle_resp_state,
    output [`TREE_FRONTIER_SLOTS*`TOKEN_ENTRY_TYPE_W-1:0] lookup_bundle_resp_entry_type,

    // commit / flush：
    // commit 把某条树条目标为 committed/stream；
    // flush 删除被剪枝节点所属的树条目。
    input                        commit_valid,
    input  [`TOKEN_REG_INDEX_W-1:0] commit_index,
    input  [`REQ_ID_W-1:0]       commit_req_id,
    input  [`BRANCH_MASK_W-1:0]  commit_branch_mask,
    input  [`NODE_MASK_W-1:0]    commit_node_mask,
    input                        flush_valid,
    input  [`REQ_ID_W-1:0]       flush_req_id,
    input  [`BRANCH_MASK_W-1:0]  flush_branch_mask,
    input  [`NODE_MASK_W-1:0]    flush_node_mask,
    output [`TOKEN_REG_INDEX_W:0] entry_count,
    output                       error_flag
);

// 条目状态枚举：
// INVALID   : 槽位无效。
// SPEC      : 该 token 还是 speculative tree 条目。
// COMMITTED : 该 token 已完成 commit。
localparam [`TOKEN_STATE_W-1:0] TOKEN_STATE_INVALID   = {`TOKEN_STATE_W{1'b0}};
localparam [`TOKEN_STATE_W-1:0] TOKEN_STATE_SPEC      = {{(`TOKEN_STATE_W-1){1'b0}}, 1'b1};
localparam [`TOKEN_STATE_W-1:0] TOKEN_STATE_COMMITTED = {{(`TOKEN_STATE_W-2){1'b0}}, 2'b10};

// 条目主存储阵列。
reg valid_entry [0:`TOKEN_REG_DEPTH-1];
reg [`REQ_ID_W-1:0] entry_req_id [0:`TOKEN_REG_DEPTH-1];
reg [`TOKEN_ID_W-1:0] entry_token_id [0:`TOKEN_REG_DEPTH-1];
reg [`POSITION_ID_W-1:0] entry_position_id [0:`TOKEN_REG_DEPTH-1];
reg [`NODE_ID_W-1:0] entry_node_id [0:`TOKEN_REG_DEPTH-1];
reg [`BRANCH_ID_W-1:0] entry_branch_id [0:`TOKEN_REG_DEPTH-1];
reg [`SRAM_ID_W-1:0] entry_sram_id [0:`TOKEN_REG_DEPTH-1];
reg [`BANK_ID_W-1:0] entry_bank_id [0:`TOKEN_REG_DEPTH-1];
reg [`SUBBANK_ID_W-1:0] entry_subbank_start [0:`TOKEN_REG_DEPTH-1];
reg [`KV_GROUP_LEN_W-1:0] entry_group_len [0:`TOKEN_REG_DEPTH-1];
reg [`BRANCH_MASK_W-1:0] entry_branch_mask [0:`TOKEN_REG_DEPTH-1];
reg entry_is_shared [0:`TOKEN_REG_DEPTH-1];
reg [`TOKEN_STATE_W-1:0] entry_state [0:`TOKEN_REG_DEPTH-1];
reg [`TOKEN_ENTRY_TYPE_W-1:0] entry_type [0:`TOKEN_REG_DEPTH-1];

// lookup 组合搜索结果。
reg lookup_hit_comb;
reg [`REQ_ID_W-1:0] lookup_req_id_comb;
reg [`SRAM_ID_W-1:0] lookup_sram_id_comb;
reg [`BANK_ID_W-1:0] lookup_bank_id_comb;
reg [`SUBBANK_ID_W-1:0] lookup_subbank_start_comb;
reg [`KV_GROUP_LEN_W-1:0] lookup_group_len_comb;
reg [`BRANCH_MASK_W-1:0] lookup_branch_mask_comb;
reg lookup_is_shared_comb;
reg [`TOKEN_STATE_W-1:0] lookup_state_comb;
reg [`TOKEN_ENTRY_TYPE_W-1:0] lookup_entry_type_comb;
reg [`TREE_FRONTIER_SLOTS-1:0] lookup_bundle_hit_comb;
reg [`TREE_FRONTIER_SLOTS*`SRAM_ID_W-1:0] lookup_bundle_sram_id_comb;
reg [`TREE_FRONTIER_SLOTS*`BANK_ID_W-1:0] lookup_bundle_bank_id_comb;
reg [`TREE_FRONTIER_SLOTS*`SUBBANK_ID_W-1:0]
    lookup_bundle_subbank_start_comb;
reg [`TREE_FRONTIER_SLOTS*`KV_GROUP_LEN_W-1:0]
    lookup_bundle_group_len_comb;
reg [`TREE_FRONTIER_SLOTS*`BRANCH_MASK_W-1:0]
    lookup_bundle_branch_mask_comb;
reg [`TREE_FRONTIER_SLOTS-1:0] lookup_bundle_is_shared_comb;
reg [`TREE_FRONTIER_SLOTS*`TOKEN_STATE_W-1:0]
    lookup_bundle_state_comb;
reg [`TREE_FRONTIER_SLOTS*`TOKEN_ENTRY_TYPE_W-1:0]
    lookup_bundle_entry_type_comb;

// lookup 响应寄存器：
// 采用一拍寄存方式，保证查找接口是同步返回。
reg lookup_resp_valid_r;
reg lookup_resp_hit_r;
reg [`REQ_ID_W-1:0] lookup_resp_req_id_r;
reg [`SRAM_ID_W-1:0] lookup_resp_sram_id_r;
reg [`BANK_ID_W-1:0] lookup_resp_bank_id_r;
reg [`SUBBANK_ID_W-1:0] lookup_resp_subbank_start_r;
reg [`KV_GROUP_LEN_W-1:0] lookup_resp_group_len_r;
reg [`BRANCH_MASK_W-1:0] lookup_resp_branch_mask_r;
reg lookup_resp_is_shared_r;
reg [`TOKEN_STATE_W-1:0] lookup_resp_state_r;
reg [`TOKEN_ENTRY_TYPE_W-1:0] lookup_resp_entry_type_r;
reg lookup_bundle_resp_valid_r;
reg [`REQ_ID_W-1:0] lookup_bundle_resp_req_id_r;
reg [`TREE_FRONTIER_SLOTS-1:0] lookup_bundle_resp_hit_r;
reg [`TREE_FRONTIER_SLOTS*`SRAM_ID_W-1:0] lookup_bundle_resp_sram_id_r;
reg [`TREE_FRONTIER_SLOTS*`BANK_ID_W-1:0] lookup_bundle_resp_bank_id_r;
reg [`TREE_FRONTIER_SLOTS*`SUBBANK_ID_W-1:0]
    lookup_bundle_resp_subbank_start_r;
reg [`TREE_FRONTIER_SLOTS*`KV_GROUP_LEN_W-1:0]
    lookup_bundle_resp_group_len_r;
reg [`TREE_FRONTIER_SLOTS*`BRANCH_MASK_W-1:0]
    lookup_bundle_resp_branch_mask_r;
reg [`TREE_FRONTIER_SLOTS-1:0] lookup_bundle_resp_is_shared_r;
reg [`TREE_FRONTIER_SLOTS*`TOKEN_STATE_W-1:0] lookup_bundle_resp_state_r;
reg [`TREE_FRONTIER_SLOTS*`TOKEN_ENTRY_TYPE_W-1:0]
    lookup_bundle_resp_entry_type_r;

// 当前有效条目个数，作为调试/容量观测输出。
reg [`TOKEN_REG_INDEX_W:0] entry_count_r;

// 循环变量与 flush/commit 辅助变量。
integer idx_i;
integer count_i;
integer init_i;
integer wr_bundle_slot_i;
integer lookup_bundle_slot_i;
integer lookup_bundle_entry_i;
reg [`BRANCH_MASK_W-1:0] next_branch_mask;
// is_node_selected：
// 给定 branch_id / node_id，去 node_mask 里取这个“branch 上该 node”的选择位。
function is_node_selected;
    input [`BRANCH_ID_W-1:0] branch_id_in;
    input [`NODE_ID_W-1:0] node_id_in;
    input [`NODE_MASK_W-1:0] node_mask_in;
    integer bit_index_i;
    begin
        bit_index_i = (branch_id_in * `MAX_VERIFY_NODES_PER_BRANCH) + node_id_in;
        if ((node_id_in < `MAX_VERIFY_NODES_PER_BRANCH) && (bit_index_i < `NODE_MASK_W)) begin
            is_node_selected = node_mask_in[bit_index_i];
        end else begin
            is_node_selected = 1'b0;
        end
    end
endfunction

// wr_ready / wr_bundle_ready：
// 1. 没有 bundle 时，旧标量 wr_* 仍然始终 ready；
// 2. 有 bundle 时，旧标量 wr_ready 拉低，强制上游只走 bundle 边界；
// 3. wr_bundle_ready 固定允许整包进入，由本模块在时序块里并行处理所有有效 slot。
assign wr_ready = !wr_bundle_valid;
assign wr_bundle_ready = 1'b1;
assign lookup_ready = 1'b1;
assign lookup_bundle_ready = 1'b1;
assign lookup_resp_valid = lookup_resp_valid_r;
assign lookup_resp_hit = lookup_resp_hit_r;
assign lookup_resp_req_id = lookup_resp_req_id_r;
assign lookup_resp_sram_id = lookup_resp_sram_id_r;
assign lookup_resp_bank_id = lookup_resp_bank_id_r;
assign lookup_resp_subbank_start = lookup_resp_subbank_start_r;
assign lookup_resp_group_len = lookup_resp_group_len_r;
assign lookup_resp_branch_mask = lookup_resp_branch_mask_r;
assign lookup_resp_is_shared = lookup_resp_is_shared_r;
assign lookup_resp_state = lookup_resp_state_r;
assign lookup_resp_entry_type = lookup_resp_entry_type_r;
assign lookup_bundle_resp_valid = lookup_bundle_resp_valid_r;
assign lookup_bundle_resp_req_id = lookup_bundle_resp_req_id_r;
assign lookup_bundle_resp_hit = lookup_bundle_resp_hit_r;
assign lookup_bundle_resp_sram_id = lookup_bundle_resp_sram_id_r;
assign lookup_bundle_resp_bank_id = lookup_bundle_resp_bank_id_r;
assign lookup_bundle_resp_subbank_start = lookup_bundle_resp_subbank_start_r;
assign lookup_bundle_resp_group_len = lookup_bundle_resp_group_len_r;
assign lookup_bundle_resp_branch_mask = lookup_bundle_resp_branch_mask_r;
assign lookup_bundle_resp_is_shared = lookup_bundle_resp_is_shared_r;
assign lookup_bundle_resp_state = lookup_bundle_resp_state_r;
assign lookup_bundle_resp_entry_type = lookup_bundle_resp_entry_type_r;
assign entry_count = entry_count_r;
assign error_flag = 1'b0;

// 组合查找逻辑：
// 1. 默认返回 miss。
// 2. 遍历整个表，找到第一个满足 req/token/position 全匹配且状态有效的条目。
// 3. 同时统计当前有效条目数量。
always @* begin
    lookup_hit_comb = 1'b0;
    lookup_req_id_comb = lookup_req_id;
    lookup_sram_id_comb = {`SRAM_ID_W{1'b0}};
    lookup_bank_id_comb = {`BANK_ID_W{1'b0}};
    lookup_subbank_start_comb = {`SUBBANK_ID_W{1'b0}};
    lookup_group_len_comb = {`KV_GROUP_LEN_W{1'b0}};
    lookup_branch_mask_comb = {`BRANCH_MASK_W{1'b0}};
    lookup_is_shared_comb = 1'b0;
    lookup_state_comb = TOKEN_STATE_INVALID;
    lookup_entry_type_comb = `TOKEN_ENTRY_TREE;
    entry_count_r = {(`TOKEN_REG_INDEX_W+1){1'b0}};

    for (count_i = 0; count_i < `TOKEN_REG_DEPTH; count_i = count_i + 1) begin
        // entry_count_r 统计当前有效槽位数。
        if (valid_entry[count_i]) begin
            entry_count_r = entry_count_r + 1'b1;
        end

        // 只取第一个命中项，后续命中不再覆盖。
        if (!lookup_hit_comb &&
            valid_entry[count_i] &&
            (entry_req_id[count_i] == lookup_req_id) &&
            (entry_token_id[count_i] == lookup_token_id) &&
            (entry_position_id[count_i] == lookup_position_id) &&
            (entry_state[count_i] != TOKEN_STATE_INVALID)) begin
            lookup_hit_comb = 1'b1;
            lookup_sram_id_comb = entry_sram_id[count_i];
            lookup_bank_id_comb = entry_bank_id[count_i];
            lookup_subbank_start_comb = entry_subbank_start[count_i];
            lookup_group_len_comb = entry_group_len[count_i];
            lookup_branch_mask_comb = entry_branch_mask[count_i];
            lookup_is_shared_comb = entry_is_shared[count_i];
            lookup_state_comb = entry_state[count_i];
            lookup_entry_type_comb = entry_type[count_i];
        end
    end
end

// 并行 bundle lookup 组合搜索逻辑：
// 1. 每个 slot 独立按 req/token/position 搜索；
// 2. 命中后返回对应 SRAM 位置、branch mask、条目状态；
// 3. 不命中的 slot 保持 miss/全零，等待后级按论文语义处理。
always @* begin
    lookup_bundle_hit_comb = {`TREE_FRONTIER_SLOTS{1'b0}};
    lookup_bundle_sram_id_comb =
        {(`TREE_FRONTIER_SLOTS*`SRAM_ID_W){1'b0}};
    lookup_bundle_bank_id_comb =
        {(`TREE_FRONTIER_SLOTS*`BANK_ID_W){1'b0}};
    lookup_bundle_subbank_start_comb =
        {(`TREE_FRONTIER_SLOTS*`SUBBANK_ID_W){1'b0}};
    lookup_bundle_group_len_comb =
        {(`TREE_FRONTIER_SLOTS*`KV_GROUP_LEN_W){1'b0}};
    lookup_bundle_branch_mask_comb =
        {(`TREE_FRONTIER_SLOTS*`BRANCH_MASK_W){1'b0}};
    lookup_bundle_is_shared_comb = {`TREE_FRONTIER_SLOTS{1'b0}};
    lookup_bundle_state_comb =
        {(`TREE_FRONTIER_SLOTS*`TOKEN_STATE_W){1'b0}};
    lookup_bundle_entry_type_comb =
        {(`TREE_FRONTIER_SLOTS*`TOKEN_ENTRY_TYPE_W){1'b0}};

    for (lookup_bundle_slot_i = 0;
         lookup_bundle_slot_i < `TREE_FRONTIER_SLOTS;
         lookup_bundle_slot_i = lookup_bundle_slot_i + 1) begin
        lookup_bundle_state_comb[
            (lookup_bundle_slot_i*`TOKEN_STATE_W) +: `TOKEN_STATE_W] =
            TOKEN_STATE_INVALID;
        lookup_bundle_entry_type_comb[
            (lookup_bundle_slot_i*`TOKEN_ENTRY_TYPE_W) +:
            `TOKEN_ENTRY_TYPE_W] = `TOKEN_ENTRY_TREE;

        if (lookup_bundle_slot_valid[lookup_bundle_slot_i]) begin
            for (lookup_bundle_entry_i = 0;
                 lookup_bundle_entry_i < `TOKEN_REG_DEPTH;
                 lookup_bundle_entry_i = lookup_bundle_entry_i + 1) begin
                if (!lookup_bundle_hit_comb[lookup_bundle_slot_i] &&
                    valid_entry[lookup_bundle_entry_i] &&
                    (entry_req_id[lookup_bundle_entry_i] == lookup_bundle_req_id) &&
                    (entry_token_id[lookup_bundle_entry_i] ==
                        lookup_bundle_token_id[
                            (lookup_bundle_slot_i*`TOKEN_ID_W) +: `TOKEN_ID_W]) &&
                    (entry_position_id[lookup_bundle_entry_i] ==
                        lookup_bundle_position_id[
                            (lookup_bundle_slot_i*`POSITION_ID_W) +:
                            `POSITION_ID_W]) &&
                    (entry_state[lookup_bundle_entry_i] != TOKEN_STATE_INVALID)) begin
                    lookup_bundle_hit_comb[lookup_bundle_slot_i] = 1'b1;
                    lookup_bundle_sram_id_comb[
                        (lookup_bundle_slot_i*`SRAM_ID_W) +: `SRAM_ID_W] =
                        entry_sram_id[lookup_bundle_entry_i];
                    lookup_bundle_bank_id_comb[
                        (lookup_bundle_slot_i*`BANK_ID_W) +: `BANK_ID_W] =
                        entry_bank_id[lookup_bundle_entry_i];
                    lookup_bundle_subbank_start_comb[
                        (lookup_bundle_slot_i*`SUBBANK_ID_W) +:
                        `SUBBANK_ID_W] =
                        entry_subbank_start[lookup_bundle_entry_i];
                    lookup_bundle_group_len_comb[
                        (lookup_bundle_slot_i*`KV_GROUP_LEN_W) +:
                        `KV_GROUP_LEN_W] =
                        entry_group_len[lookup_bundle_entry_i];
                    lookup_bundle_branch_mask_comb[
                        (lookup_bundle_slot_i*`BRANCH_MASK_W) +:
                        `BRANCH_MASK_W] =
                        entry_branch_mask[lookup_bundle_entry_i];
                    lookup_bundle_is_shared_comb[lookup_bundle_slot_i] =
                        entry_is_shared[lookup_bundle_entry_i];
                    lookup_bundle_state_comb[
                        (lookup_bundle_slot_i*`TOKEN_STATE_W) +:
                        `TOKEN_STATE_W] =
                        entry_state[lookup_bundle_entry_i];
                    lookup_bundle_entry_type_comb[
                        (lookup_bundle_slot_i*`TOKEN_ENTRY_TYPE_W) +:
                        `TOKEN_ENTRY_TYPE_W] =
                        entry_type[lookup_bundle_entry_i];
                end
            end
        end
    end
end

// 主时序块：
// 1. 复位时清空整张表；
// 2. 每拍锁存 lookup 响应；
// 3. 处理写入、commit、flush。
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        // 全表清空到 INVALID。
        for (init_i = 0; init_i < `TOKEN_REG_DEPTH; init_i = init_i + 1) begin
            valid_entry[init_i] <= 1'b0;
            entry_req_id[init_i] <= {`REQ_ID_W{1'b0}};
            entry_token_id[init_i] <= {`TOKEN_ID_W{1'b0}};
            entry_position_id[init_i] <= {`POSITION_ID_W{1'b0}};
            entry_node_id[init_i] <= {`NODE_ID_W{1'b0}};
            entry_branch_id[init_i] <= {`BRANCH_ID_W{1'b0}};
            entry_sram_id[init_i] <= {`SRAM_ID_W{1'b0}};
            entry_bank_id[init_i] <= {`BANK_ID_W{1'b0}};
            entry_subbank_start[init_i] <= {`SUBBANK_ID_W{1'b0}};
            entry_group_len[init_i] <= {`KV_GROUP_LEN_W{1'b0}};
            entry_branch_mask[init_i] <= {`BRANCH_MASK_W{1'b0}};
            entry_is_shared[init_i] <= 1'b0;
            entry_state[init_i] <= TOKEN_STATE_INVALID;
            entry_type[init_i] <= `TOKEN_ENTRY_TREE;
        end
        lookup_resp_valid_r <= 1'b0;
        lookup_resp_hit_r <= 1'b0;
        lookup_resp_req_id_r <= {`REQ_ID_W{1'b0}};
        lookup_resp_sram_id_r <= {`SRAM_ID_W{1'b0}};
        lookup_resp_bank_id_r <= {`BANK_ID_W{1'b0}};
        lookup_resp_subbank_start_r <= {`SUBBANK_ID_W{1'b0}};
        lookup_resp_group_len_r <= {`KV_GROUP_LEN_W{1'b0}};
        lookup_resp_branch_mask_r <= {`BRANCH_MASK_W{1'b0}};
        lookup_resp_is_shared_r <= 1'b0;
        lookup_resp_state_r <= TOKEN_STATE_INVALID;
        lookup_resp_entry_type_r <= `TOKEN_ENTRY_TREE;
        lookup_bundle_resp_valid_r <= 1'b0;
        lookup_bundle_resp_req_id_r <= {`REQ_ID_W{1'b0}};
        lookup_bundle_resp_hit_r <= {`TREE_FRONTIER_SLOTS{1'b0}};
        lookup_bundle_resp_sram_id_r <=
            {(`TREE_FRONTIER_SLOTS*`SRAM_ID_W){1'b0}};
        lookup_bundle_resp_bank_id_r <=
            {(`TREE_FRONTIER_SLOTS*`BANK_ID_W){1'b0}};
        lookup_bundle_resp_subbank_start_r <=
            {(`TREE_FRONTIER_SLOTS*`SUBBANK_ID_W){1'b0}};
        lookup_bundle_resp_group_len_r <=
            {(`TREE_FRONTIER_SLOTS*`KV_GROUP_LEN_W){1'b0}};
        lookup_bundle_resp_branch_mask_r <=
            {(`TREE_FRONTIER_SLOTS*`BRANCH_MASK_W){1'b0}};
        lookup_bundle_resp_is_shared_r <= {`TREE_FRONTIER_SLOTS{1'b0}};
        lookup_bundle_resp_state_r <=
            {(`TREE_FRONTIER_SLOTS*`TOKEN_STATE_W){1'b0}};
        lookup_bundle_resp_entry_type_r <=
            {(`TREE_FRONTIER_SLOTS*`TOKEN_ENTRY_TYPE_W){1'b0}};
    end else begin
        // lookup 响应总是在当前拍把组合搜索结果锁存下来。
        lookup_resp_valid_r <= lookup_valid;
        lookup_resp_hit_r <= lookup_hit_comb;
        lookup_resp_req_id_r <= lookup_req_id_comb;
        lookup_resp_sram_id_r <= lookup_sram_id_comb;
        lookup_resp_bank_id_r <= lookup_bank_id_comb;
        lookup_resp_subbank_start_r <= lookup_subbank_start_comb;
        lookup_resp_group_len_r <= lookup_group_len_comb;
        lookup_resp_branch_mask_r <= lookup_branch_mask_comb;
        lookup_resp_is_shared_r <= lookup_is_shared_comb;
        lookup_resp_state_r <= lookup_state_comb;
        lookup_resp_entry_type_r <= lookup_entry_type_comb;
        lookup_bundle_resp_valid_r <= lookup_bundle_valid;
        lookup_bundle_resp_req_id_r <= lookup_bundle_req_id;
        lookup_bundle_resp_hit_r <= lookup_bundle_hit_comb;
        lookup_bundle_resp_sram_id_r <= lookup_bundle_sram_id_comb;
        lookup_bundle_resp_bank_id_r <= lookup_bundle_bank_id_comb;
        lookup_bundle_resp_subbank_start_r <=
            lookup_bundle_subbank_start_comb;
        lookup_bundle_resp_group_len_r <= lookup_bundle_group_len_comb;
        lookup_bundle_resp_branch_mask_r <= lookup_bundle_branch_mask_comb;
        lookup_bundle_resp_is_shared_r <= lookup_bundle_is_shared_comb;
        lookup_bundle_resp_state_r <= lookup_bundle_state_comb;
        lookup_bundle_resp_entry_type_r <= lookup_bundle_entry_type_comb;

        if (wr_bundle_valid) begin
            // bundle 写表：
            // 1. 每个有效 slot 都带着自己独立的 index / token / position / 物理位置；
            // 2. 本模块在同一拍里逐 slot 展开写入，形成论文要求的整层并行元数据落表；
            // 3. 若上游错误地给出重复 index，则后出现的 slot 会覆盖前者，因此 index 唯一性
            //    仍然由 AGU/free_list 负责保证。
            for (wr_bundle_slot_i = 0;
                 wr_bundle_slot_i < `TREE_FRONTIER_SLOTS;
                 wr_bundle_slot_i = wr_bundle_slot_i + 1) begin
                if (wr_bundle_slot_valid[wr_bundle_slot_i]) begin
                    valid_entry[
                        wr_bundle_index[
                            (wr_bundle_slot_i*`TOKEN_REG_INDEX_W) +:
                            `TOKEN_REG_INDEX_W]] <= 1'b1;
                    entry_req_id[
                        wr_bundle_index[
                            (wr_bundle_slot_i*`TOKEN_REG_INDEX_W) +:
                            `TOKEN_REG_INDEX_W]] <= wr_bundle_req_id;
                    entry_token_id[
                        wr_bundle_index[
                            (wr_bundle_slot_i*`TOKEN_REG_INDEX_W) +:
                            `TOKEN_REG_INDEX_W]] <=
                        wr_bundle_token_id[
                            (wr_bundle_slot_i*`TOKEN_ID_W) +: `TOKEN_ID_W];
                    entry_position_id[
                        wr_bundle_index[
                            (wr_bundle_slot_i*`TOKEN_REG_INDEX_W) +:
                            `TOKEN_REG_INDEX_W]] <=
                        wr_bundle_position_id[
                            (wr_bundle_slot_i*`POSITION_ID_W) +:
                            `POSITION_ID_W];
                    entry_node_id[
                        wr_bundle_index[
                            (wr_bundle_slot_i*`TOKEN_REG_INDEX_W) +:
                            `TOKEN_REG_INDEX_W]] <=
                        wr_bundle_node_id[
                            (wr_bundle_slot_i*`NODE_ID_W) +: `NODE_ID_W];
                    entry_branch_id[
                        wr_bundle_index[
                            (wr_bundle_slot_i*`TOKEN_REG_INDEX_W) +:
                            `TOKEN_REG_INDEX_W]] <=
                        wr_bundle_branch_id[
                            (wr_bundle_slot_i*`BRANCH_ID_W) +:
                            `BRANCH_ID_W];
                    entry_sram_id[
                        wr_bundle_index[
                            (wr_bundle_slot_i*`TOKEN_REG_INDEX_W) +:
                            `TOKEN_REG_INDEX_W]] <=
                        wr_bundle_sram_id[
                            (wr_bundle_slot_i*`SRAM_ID_W) +: `SRAM_ID_W];
                    entry_bank_id[
                        wr_bundle_index[
                            (wr_bundle_slot_i*`TOKEN_REG_INDEX_W) +:
                            `TOKEN_REG_INDEX_W]] <=
                        wr_bundle_bank_id[
                            (wr_bundle_slot_i*`BANK_ID_W) +: `BANK_ID_W];
                    entry_subbank_start[
                        wr_bundle_index[
                            (wr_bundle_slot_i*`TOKEN_REG_INDEX_W) +:
                            `TOKEN_REG_INDEX_W]] <=
                        wr_bundle_subbank_start[
                            (wr_bundle_slot_i*`SUBBANK_ID_W) +:
                            `SUBBANK_ID_W];
                    entry_group_len[
                        wr_bundle_index[
                            (wr_bundle_slot_i*`TOKEN_REG_INDEX_W) +:
                            `TOKEN_REG_INDEX_W]] <=
                        wr_bundle_group_len[
                            (wr_bundle_slot_i*`KV_GROUP_LEN_W) +:
                            `KV_GROUP_LEN_W];
                    entry_branch_mask[
                        wr_bundle_index[
                            (wr_bundle_slot_i*`TOKEN_REG_INDEX_W) +:
                            `TOKEN_REG_INDEX_W]] <=
                        wr_bundle_branch_mask[
                            (wr_bundle_slot_i*`BRANCH_MASK_W) +:
                            `BRANCH_MASK_W];
                    entry_is_shared[
                        wr_bundle_index[
                            (wr_bundle_slot_i*`TOKEN_REG_INDEX_W) +:
                            `TOKEN_REG_INDEX_W]] <=
                        wr_bundle_is_shared[wr_bundle_slot_i];
                    entry_state[
                        wr_bundle_index[
                            (wr_bundle_slot_i*`TOKEN_REG_INDEX_W) +:
                            `TOKEN_REG_INDEX_W]] <= TOKEN_STATE_SPEC;
                    entry_type[
                        wr_bundle_index[
                            (wr_bundle_slot_i*`TOKEN_REG_INDEX_W) +:
                            `TOKEN_REG_INDEX_W]] <= `TOKEN_ENTRY_TREE;
                end
            end
        end else if (wr_valid) begin
            // 旧标量写口保留给非 strict-paper 的遗留路径。
            valid_entry[wr_index] <= 1'b1;
            entry_req_id[wr_index] <= wr_req_id;
            entry_token_id[wr_index] <= wr_token_id;
            entry_position_id[wr_index] <= wr_position_id;
            entry_node_id[wr_index] <= wr_node_id;
            entry_branch_id[wr_index] <= wr_branch_id;
            entry_sram_id[wr_index] <= wr_sram_id;
            entry_bank_id[wr_index] <= wr_bank_id;
            entry_subbank_start[wr_index] <= wr_subbank_start;
            entry_group_len[wr_index] <= wr_group_len;
            entry_branch_mask[wr_index] <= wr_branch_mask;
            entry_is_shared[wr_index] <= wr_is_shared;
            entry_state[wr_index] <= TOKEN_STATE_SPEC;
            entry_type[wr_index] <= `TOKEN_ENTRY_TREE;
        end

        if (commit_valid) begin
            // commit 只作用于：
            // 1. 槽位有效；
            // 2. req_id 匹配；
            // 3. branch/node 被 commit mask 选中。
            if (valid_entry[commit_index] &&
                (entry_req_id[commit_index] == commit_req_id) &&
                is_node_selected(entry_branch_id[commit_index], entry_node_id[commit_index], commit_node_mask)) begin
                // commit 后扩展 branch_mask，并把条目升级为 COMMITTED/STREAM。
                entry_branch_mask[commit_index] <= entry_branch_mask[commit_index] | commit_branch_mask;
                entry_state[commit_index] <= TOKEN_STATE_COMMITTED;
                entry_type[commit_index] <= `TOKEN_ENTRY_STREAM;
            end
        end

        if (flush_valid) begin
            // flush 只清理 TREE 条目，不动已经升级为 STREAM 的 committed 条目。
            for (idx_i = 0; idx_i < `TOKEN_REG_DEPTH; idx_i = idx_i + 1) begin
                if (valid_entry[idx_i] &&
                    (entry_req_id[idx_i] == flush_req_id) &&
                    (entry_type[idx_i] == `TOKEN_ENTRY_TREE) &&
                    is_node_selected(entry_branch_id[idx_i], entry_node_id[idx_i], flush_node_mask) &&
                    ((entry_branch_mask[idx_i] & flush_branch_mask) != {`BRANCH_MASK_W{1'b0}})) begin
                    // 从当前 branch_mask 中减掉被 flush 的分支。
                    next_branch_mask = entry_branch_mask[idx_i] & ~flush_branch_mask;
                    if (next_branch_mask == {`BRANCH_MASK_W{1'b0}}) begin
                        // 若没有任何分支还引用这个条目，则整个槽位失效。
                        valid_entry[idx_i] <= 1'b0;
                        entry_branch_mask[idx_i] <= {`BRANCH_MASK_W{1'b0}};
                        entry_state[idx_i] <= TOKEN_STATE_INVALID;
                        entry_type[idx_i] <= `TOKEN_ENTRY_TREE;
                    end else begin
                        // 否则只收缩 branch_mask，保留条目本体。
                        entry_branch_mask[idx_i] <= next_branch_mask;
                    end
                end
            end
        end
    end
end

endmodule
