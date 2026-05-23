`timescale 1ns/1ps

`include "config/prediction_params.vh"
`include "config/interface_params.vh"
`include "config/memory_params.vh"

/*
 * 文件作用：
 * 1. 本文件实现论文 TreeControl 路径里的 AGU（Address Generation Unit）。
 * 2. 它的核心职责不是做数值计算，而是把树前端拆出来的 prefix/frontier 节点
 *    规范化成后续资源管理可消费的工作项，并为 token_register / prefetch_queue /
 *    free_list 提供统一的地址分配入口。
 * 3. 在论文完整主路径里，它位于：
 *    native_tree_req
 *      -> tree_analyze / NativeTreeMainFrontend
 *      -> AGU
 *      -> prefetch_queue / free_list / token_register
 * 4. 这个模块同时承担三件事：
 *    - 把 prefix/frontier 统一压成内部 work queue；
 *    - 按分支存活信息过滤已经被 prune 的节点；
 *    - 接住 free_list 返回的 candidate 位置后，向 token_register 发 token->KV 位置映射。
 * 5. 当前 frozen strict tree-mask shortcut 主路径会绕过这条论文式 AGU 主链；
 *    因此这里描述的是“论文完整 TreeControl 前置资源管理语义”。
 */
module agu (
    // 时钟与复位。
    input                        clk,
    input                        rst_n,

    // tree_in_*：
    // 代表来自 tree control 主入口的标量树节点请求。
    input                        tree_in_valid,
    output                       tree_in_ready,
    input  [`REQ_ID_W-1:0]       tree_in_req_id,
    input  [`BRANCH_ID_W-1:0]    tree_in_branch_id,
    input  [`NODE_ID_W-1:0]      tree_in_node_id,

    // prefix_*：
    // tree_analyze/NativeTreeMainFrontend 拆出来的共享前缀流。
    input                        prefix_valid,
    output                       prefix_ready,
    input  [`REQ_ID_W-1:0]       prefix_req_id,
    input                        prefix_node_valid,
    input  [`NODE_ID_W-1:0]      prefix_node_id,
    input  [`NODE_ID_W-1:0]      prefix_parent_node_id,
    input  [`TOKEN_ID_W-1:0]     prefix_token_id,
    input  [`POSITION_ID_W-1:0]  prefix_position_id,
    input  [`LAYER_ID_W-1:0]     prefix_layer_id,
    input                        prefix_is_last,

    // frontier_*：
    // tree_analyze 按 level 输出的 frontier，每拍可能携带多个 slot。
    input                        frontier_valid,
    output                       frontier_ready,
    input  [`REQ_ID_W-1:0]       frontier_req_id,
    input  [`TREE_LEVEL_ID_W-1:0] frontier_level_id,
    input  [`TREE_FRONTIER_SLOTS-1:0] frontier_slot_valid,
    input  [`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0] frontier_node_id,
    input  [`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0] frontier_parent_node_id,
    input  [`TREE_FRONTIER_SLOTS*`TOKEN_ID_W-1:0] frontier_token_id,
    input  [`TREE_FRONTIER_SLOTS*`POSITION_ID_W-1:0] frontier_position_id,

    // prefetch queue 是否还能接收新的工作项。
    input                        prefetch_enq_ready,

    // free_list 候选位置返回。
    input                        cand_resp_valid,
    input                        cand_resp_grant,
    input  [`REQ_ID_W-1:0]       cand_resp_req_id,
    input  [`SRAM_ID_W-1:0]      cand_resp_sram_id,
    input  [`BANK_ID_W-1:0]      cand_resp_bank_id,
    input  [`SUBBANK_ID_W-1:0]   cand_resp_subbank_start,
    input  [`KV_GROUP_LEN_W-1:0] cand_resp_group_len,

    // alloc_resp_* 是旧接口遗留输入，当前实现里实际上不再驱动 AGU 主状态流。
    input                        alloc_resp_valid,
    input                        alloc_resp_grant,
    input  [`REQ_ID_W-1:0]       alloc_resp_req_id,
    input  [`SRAM_ID_W-1:0]      alloc_resp_sram_id,
    input  [`BANK_ID_W-1:0]      alloc_resp_bank_id,
    input  [`SUBBANK_ID_W-1:0]   alloc_resp_subbank_start,
    input  [`KV_GROUP_LEN_W-1:0] alloc_resp_group_len,

    // flush / liveness 控制：
    // flush_freeze 表示 flush 正在冻结前端，
    // flush_drain_busy 表示 free_list 还在回收旧节点，
    // branch_liveness_* 表示哪些分支仍然存活。
    input                        flush_freeze,
    input                        flush_drain_busy,
    input                        flush_ctrl_valid,
    input  [`REQ_ID_W-1:0]       flush_ctrl_req_id,
    input  [`BRANCH_MASK_W-1:0]  flush_ctrl_branch_mask,
    input  [`NODE_MASK_W-1:0]    flush_ctrl_node_mask,
    input                        branch_liveness_valid,
    input  [`REQ_ID_W-1:0]       branch_liveness_req_id,
    input  [`BRANCH_MASK_W-1:0]  branch_liveness_live_mask,
    input  [`BRANCH_MASK_W-1:0]  branch_liveness_prune_mask,

    // prefix/frontier 的规范化输出：
    // 这些信号主要给调试或后续观察点使用，反映 AGU 接收到的“论文语义节点流”。
    output                       prefix_norm_valid,
    output [`REQ_ID_W-1:0]       prefix_norm_req_id,
    output                       prefix_norm_node_valid,
    output [`NODE_ID_W-1:0]      prefix_norm_node_id,
    output [`NODE_ID_W-1:0]      prefix_norm_parent_node_id,
    output [`TOKEN_ID_W-1:0]     prefix_norm_token_id,
    output [`POSITION_ID_W-1:0]  prefix_norm_position_id,
    output [`LAYER_ID_W-1:0]     prefix_norm_layer_id,
    output                       prefix_norm_is_last,
    output                       prefix_norm_is_shared,
    output                       frontier_norm_valid,
    output [`REQ_ID_W-1:0]       frontier_norm_req_id,
    output [`TREE_LEVEL_ID_W-1:0] frontier_norm_level_id,
    output [`TREE_FRONTIER_SLOTS-1:0] frontier_norm_slot_valid,
    output [`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0] frontier_norm_node_id,
    output [`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0] frontier_norm_parent_node_id,
    output [`TREE_FRONTIER_SLOTS*`TOKEN_ID_W-1:0] frontier_norm_token_id,
    output [`TREE_FRONTIER_SLOTS*`POSITION_ID_W-1:0] frontier_norm_position_id,
    output [`TREE_FRONTIER_SLOTS*`KV_GROUP_LEN_W-1:0] frontier_norm_size_subbank,
    output [`TREE_FRONTIER_SLOTS-1:0] frontier_norm_slot_shared,

    // alloc_cand_*：
    // 旧版 Stage B/Stage C 候选交接接口，当前实现保留端口但不再有效驱动。
    output                       alloc_cand_valid,
    output [`REQ_ID_W-1:0]       alloc_cand_req_id,
    output [`BRANCH_ID_W-1:0]    alloc_cand_branch_id,
    output [`NODE_ID_W-1:0]      alloc_cand_node_id,
    output [`KV_GROUP_LEN_W-1:0] alloc_cand_size_subbank,
    output                       alloc_cand_shared,
    output [`SRAM_ID_W-1:0]      alloc_cand_sram_id,
    output [`BANK_ID_W-1:0]      alloc_cand_bank_id,
    output [`SUBBANK_ID_W-1:0]   alloc_cand_subbank_start,
    output [`KV_GROUP_LEN_W-1:0] alloc_cand_group_len,

    // token_wr_*：
    // 当 free_list 给出 candidate 后，把该节点的 token/position -> SRAM 位置映射写入
    // token_register / 后续位置表。
    output                       token_wr_valid,
    output [`REQ_ID_W-1:0]       token_wr_req_id,
    output [`TOKEN_ID_W-1:0]     token_wr_token_id,
    output [`POSITION_ID_W-1:0]  token_wr_position_id,
    output [`NODE_ID_W-1:0]      token_wr_node_id,
    output [`BRANCH_ID_W-1:0]    token_wr_branch_id,
    output [`BRANCH_MASK_W-1:0]  token_wr_branch_mask,
    output                       token_wr_is_shared,
    output [`SRAM_ID_W-1:0]      token_wr_sram_id,
    output [`BANK_ID_W-1:0]      token_wr_bank_id,
    output [`SUBBANK_ID_W-1:0]   token_wr_subbank_start,
    output [`KV_GROUP_LEN_W-1:0] token_wr_group_len,

    // prefetch_queue 入队与 flush 扇出。
    output                       prefetch_enq_valid,
    output [`REQ_ID_W-1:0]       prefetch_enq_req_id,
    output [`BRANCH_ID_W-1:0]    prefetch_enq_branch_id,
    output [`NODE_ID_W-1:0]      prefetch_enq_node_id,
    output [`LAYER_ID_W-1:0]     prefetch_enq_layer_id,
    output [`KV_GROUP_LEN_W-1:0] prefetch_enq_size_subbank,
    output                       prefetch_enq_shared,
    output                       prefetch_flush_valid,
    output [`REQ_ID_W-1:0]       prefetch_flush_req_id,
    output [`BRANCH_MASK_W-1:0]  prefetch_flush_branch_mask,
    output [`NODE_MASK_W-1:0]    prefetch_flush_node_mask,
    output                       free_list_flush_valid,
    output [`REQ_ID_W-1:0]       free_list_flush_req_id,
    output [`BRANCH_MASK_W-1:0]  free_list_flush_branch_mask,
    output [`NODE_MASK_W-1:0]    free_list_flush_node_mask,
    output                       token_flush_valid,
    output [`REQ_ID_W-1:0]       token_flush_req_id,
    output [`BRANCH_MASK_W-1:0]  token_flush_branch_mask,
    output [`NODE_MASK_W-1:0]    token_flush_node_mask
);

// AGU 三态状态机：
// IDLE       : 等待从 tree_in 或内部 work queue 取出一个待处理节点。
// WAIT_CAND  : 已经把节点送去申请 candidate，等待 free_list 返回候选位置。
// WAIT_ALLOC : candidate 已拿到，并已经发出 token_wr_valid，等待这一拍排空后回到 IDLE。
localparam [1:0] AGU_STATE_IDLE       = 2'd0;
localparam [1:0] AGU_STATE_WAIT_CAND  = 2'd1;
localparam [1:0] AGU_STATE_WAIT_ALLOC = 2'd2;

localparam integer TREE_WORK_QUEUE_DEPTH =
    `TREE_MAX_PREFIX_NODES + (`TREE_MAX_FRONTIER_LEVELS * `TREE_FRONTIER_SLOTS);
localparam integer TREE_WORK_COUNT_W =
    ((TREE_WORK_QUEUE_DEPTH <= 1) ? 1 : $clog2(TREE_WORK_QUEUE_DEPTH + 1));

// 当前 AGU 状态。
reg [1:0] agu_state_r;

// 当前正在等待 candidate 的节点上下文。
reg [`REQ_ID_W-1:0] pending_req_id_r;
reg [`BRANCH_ID_W-1:0] pending_branch_id_r;
reg [`NODE_ID_W-1:0] pending_node_id_r;
reg pending_shared_r;
reg [`TOKEN_ID_W-1:0] pending_token_id_r;
reg [`POSITION_ID_W-1:0] pending_position_id_r;
reg [`LAYER_ID_W-1:0] pending_layer_id_r;

// free_list 返回的 candidate 物理位置。
reg [`SRAM_ID_W-1:0] cand_sram_id_r;
reg [`BANK_ID_W-1:0] cand_bank_id_r;
reg [`SUBBANK_ID_W-1:0] cand_subbank_start_r;
reg [`KV_GROUP_LEN_W-1:0] cand_group_len_r;

// token_wr_valid_r 只打一拍，通知后续位置表“当前 pending 节点已成功拿到物理位置”。
reg token_wr_valid_r;

// prefix/frontier 规范化观测寄存器。
reg prefix_norm_valid_r;
reg [`REQ_ID_W-1:0] prefix_norm_req_id_r;
reg prefix_norm_node_valid_r;
reg [`NODE_ID_W-1:0] prefix_norm_node_id_r;
reg [`NODE_ID_W-1:0] prefix_norm_parent_node_id_r;
reg [`TOKEN_ID_W-1:0] prefix_norm_token_id_r;
reg [`POSITION_ID_W-1:0] prefix_norm_position_id_r;
reg [`LAYER_ID_W-1:0] prefix_norm_layer_id_r;
reg prefix_norm_is_last_r;
reg prefix_norm_is_shared_r;

reg frontier_norm_valid_r;
reg [`REQ_ID_W-1:0] frontier_norm_req_id_r;
reg [`TREE_LEVEL_ID_W-1:0] frontier_norm_level_id_r;
reg [`TREE_FRONTIER_SLOTS-1:0] frontier_norm_slot_valid_r;
reg [`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0] frontier_norm_node_id_r;
reg [`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0] frontier_norm_parent_node_id_r;
reg [`TREE_FRONTIER_SLOTS*`TOKEN_ID_W-1:0] frontier_norm_token_id_r;
reg [`TREE_FRONTIER_SLOTS*`POSITION_ID_W-1:0] frontier_norm_position_id_r;
reg [`TREE_FRONTIER_SLOTS*`KV_GROUP_LEN_W-1:0] frontier_norm_size_subbank_r;
reg [`TREE_FRONTIER_SLOTS-1:0] frontier_norm_slot_shared_r;

// 内部树工作队列：
// prefix 节点与 frontier slot 都会先压进这里，随后由 AGU 一个个派发给 free_list。
reg treeq_valid_r [0:TREE_WORK_QUEUE_DEPTH-1];
reg [`REQ_ID_W-1:0] treeq_req_id_r [0:TREE_WORK_QUEUE_DEPTH-1];
reg [`BRANCH_ID_W-1:0] treeq_branch_id_r [0:TREE_WORK_QUEUE_DEPTH-1];
reg [`NODE_ID_W-1:0] treeq_node_id_r [0:TREE_WORK_QUEUE_DEPTH-1];
reg treeq_shared_r [0:TREE_WORK_QUEUE_DEPTH-1];
reg [`TOKEN_ID_W-1:0] treeq_token_id_r [0:TREE_WORK_QUEUE_DEPTH-1];
reg [`POSITION_ID_W-1:0] treeq_position_id_r [0:TREE_WORK_QUEUE_DEPTH-1];
reg [`LAYER_ID_W-1:0] treeq_layer_id_r [0:TREE_WORK_QUEUE_DEPTH-1];
reg [TREE_WORK_COUNT_W-1:0] treeq_count_r;

reg treeq_valid_n [0:TREE_WORK_QUEUE_DEPTH-1];
reg [`REQ_ID_W-1:0] treeq_req_id_n [0:TREE_WORK_QUEUE_DEPTH-1];
reg [`BRANCH_ID_W-1:0] treeq_branch_id_n [0:TREE_WORK_QUEUE_DEPTH-1];
reg [`NODE_ID_W-1:0] treeq_node_id_n [0:TREE_WORK_QUEUE_DEPTH-1];
reg treeq_shared_n [0:TREE_WORK_QUEUE_DEPTH-1];
reg [`TOKEN_ID_W-1:0] treeq_token_id_n [0:TREE_WORK_QUEUE_DEPTH-1];
reg [`POSITION_ID_W-1:0] treeq_position_id_n [0:TREE_WORK_QUEUE_DEPTH-1];
reg [`LAYER_ID_W-1:0] treeq_layer_id_n [0:TREE_WORK_QUEUE_DEPTH-1];
reg [TREE_WORK_COUNT_W-1:0] treeq_count_n;

// 当前队首条目，以及与 branch liveness 相关的组合辅助量。
reg treeq_head_valid_comb;
reg [`REQ_ID_W-1:0] treeq_head_req_id_comb;
reg [`BRANCH_ID_W-1:0] treeq_head_branch_id_comb;
reg [`NODE_ID_W-1:0] treeq_head_node_id_comb;
reg treeq_head_shared_comb;
reg [`TOKEN_ID_W-1:0] treeq_head_token_id_comb;
reg [`POSITION_ID_W-1:0] treeq_head_position_id_comb;
reg [`LAYER_ID_W-1:0] treeq_head_layer_id_comb;

reg [`BRANCH_MASK_W-1:0] pending_branch_mask_comb;
reg [`TOKEN_ID_W-1:0] scalar_token_id_placeholder_comb;
reg [`POSITION_ID_W-1:0] scalar_position_id_placeholder_comb;
reg branch_liveness_valid_r;
reg [`REQ_ID_W-1:0] branch_liveness_req_id_r;
reg [`BRANCH_MASK_W-1:0] branch_liveness_live_mask_r;
reg branch_liveness_state_valid_comb;
reg [`REQ_ID_W-1:0] branch_liveness_state_req_id_comb;
reg [`BRANCH_MASK_W-1:0] branch_liveness_state_live_mask_comb;
reg pending_live_comb;
reg tree_in_live_comb;
reg treeq_head_live_comb;
reg queue_entry_live_comb;
reg frontier_slot_live_comb;

reg scalar_dispatch_fire_comb;
reg treeq_dispatch_fire_comb;
reg pending_flush_hit_comb;
integer pending_flush_node_bit_i;

// 循环变量和临时拼接变量。
integer slot_i;
integer queue_i;
integer pack_idx_i;
integer frontier_slot_i;
reg [`LAYER_ID_W-1:0] frontier_layer_id_comb;

// branch_live_for_req：
// 判断一个节点在当前 req_id 的 liveness 视角下是否仍然有效。
// 共享节点不受单分支 prune 影响；私有节点若所在 branch 已被 prune，则返回 0。
function branch_live_for_req;
    input is_shared_in;
    input [`REQ_ID_W-1:0] req_id_in;
    input [`BRANCH_ID_W-1:0] branch_id_in;
    input liveness_valid_in;
    input [`REQ_ID_W-1:0] liveness_req_id_in;
    input [`BRANCH_MASK_W-1:0] liveness_mask_in;
    begin
        branch_live_for_req = 1'b1;
        if (!is_shared_in &&
            liveness_valid_in &&
            (req_id_in == liveness_req_id_in) &&
            (branch_id_in < `BRANCH_NUM) &&
            !liveness_mask_in[branch_id_in]) begin
            branch_live_for_req = 1'b0;
        end
    end
endfunction

// tree_in_ready：
// 只有 AGU 空闲、没有 flush 冻结/排空、prefetch_queue 能接收，并且当前树节点所属
// branch 仍存活时，才允许上游再推一个 tree_in 节点。
assign tree_in_ready =
    (agu_state_r == AGU_STATE_IDLE) &&
    !flush_freeze &&
    !flush_drain_busy &&
    prefetch_enq_ready &&
    (!tree_in_valid || tree_in_live_comb);

// prefix/frontier 的 ready 取决于：
// 1. flush 没冻结前端；
// 2. free_list 没在排空旧回收；
// 3. 内部工作队列有空间。
assign prefix_ready =
    !flush_freeze &&
    !flush_drain_busy &&
    (treeq_count_r < TREE_WORK_QUEUE_DEPTH);

assign frontier_ready =
    !flush_freeze &&
    !flush_drain_busy &&
    (treeq_count_r <= (TREE_WORK_QUEUE_DEPTH - `TREE_FRONTIER_SLOTS));

// 规范化输出直接由寄存器导出。
assign prefix_norm_valid = prefix_norm_valid_r;
assign prefix_norm_req_id = prefix_norm_req_id_r;
assign prefix_norm_node_valid = prefix_norm_node_valid_r;
assign prefix_norm_node_id = prefix_norm_node_id_r;
assign prefix_norm_parent_node_id = prefix_norm_parent_node_id_r;
assign prefix_norm_token_id = prefix_norm_token_id_r;
assign prefix_norm_position_id = prefix_norm_position_id_r;
assign prefix_norm_layer_id = prefix_norm_layer_id_r;
assign prefix_norm_is_last = prefix_norm_is_last_r;
assign prefix_norm_is_shared = prefix_norm_is_shared_r;

assign frontier_norm_valid = frontier_norm_valid_r;
assign frontier_norm_req_id = frontier_norm_req_id_r;
assign frontier_norm_level_id = frontier_norm_level_id_r;
assign frontier_norm_slot_valid = frontier_norm_slot_valid_r;
assign frontier_norm_node_id = frontier_norm_node_id_r;
assign frontier_norm_parent_node_id = frontier_norm_parent_node_id_r;
assign frontier_norm_token_id = frontier_norm_token_id_r;
assign frontier_norm_position_id = frontier_norm_position_id_r;
assign frontier_norm_size_subbank = frontier_norm_size_subbank_r;
assign frontier_norm_slot_shared = frontier_norm_slot_shared_r;

// Legacy compatibility only. The effective Stage B candidate handoff is now
// driven directly from free_list into bank_state_table in the same timing step
// that free_list returns the selected candidate back to AGU.
// 当前这些信号保留为 0，只是为了兼容旧版接口，不再参与真实资源交接。
assign alloc_cand_valid = 1'b0;
assign alloc_cand_req_id = {`REQ_ID_W{1'b0}};
assign alloc_cand_branch_id = {`BRANCH_ID_W{1'b0}};
assign alloc_cand_node_id = {`NODE_ID_W{1'b0}};
assign alloc_cand_size_subbank = {`KV_GROUP_LEN_W{1'b0}};
assign alloc_cand_shared = 1'b0;
assign alloc_cand_sram_id = {`SRAM_ID_W{1'b0}};
assign alloc_cand_bank_id = {`BANK_ID_W{1'b0}};
assign alloc_cand_subbank_start = {`SUBBANK_ID_W{1'b0}};
assign alloc_cand_group_len = {`KV_GROUP_LEN_W{1'b0}};

// token_wr_* 直接描述“当前 pending 节点被分配到的最终物理位置”。
assign token_wr_valid = token_wr_valid_r;
assign token_wr_req_id = pending_req_id_r;
assign token_wr_token_id = pending_token_id_r;
assign token_wr_position_id = pending_position_id_r;
assign token_wr_node_id = pending_node_id_r;
assign token_wr_branch_id = pending_branch_id_r;
assign token_wr_branch_mask = pending_branch_mask_comb;
assign token_wr_is_shared = pending_shared_r;
assign token_wr_sram_id = cand_sram_id_r;
assign token_wr_bank_id = cand_bank_id_r;
assign token_wr_subbank_start = cand_subbank_start_r;
assign token_wr_group_len = cand_group_len_r;

// prefetch_enq_*：
// AGU 空闲时优先直接消费 tree_in 标量节点；如果没有 tree_in，再消费内部队列队首。
assign prefetch_enq_valid =
    (agu_state_r == AGU_STATE_IDLE) &&
    !flush_freeze &&
    !flush_drain_busy &&
    ((tree_in_valid && tree_in_live_comb) ||
     (!tree_in_valid && treeq_head_valid_comb && treeq_head_live_comb));
assign prefetch_enq_req_id =
    (tree_in_valid && tree_in_live_comb) ? tree_in_req_id : treeq_head_req_id_comb;
assign prefetch_enq_branch_id =
    (tree_in_valid && tree_in_live_comb) ? tree_in_branch_id : treeq_head_branch_id_comb;
assign prefetch_enq_node_id =
    (tree_in_valid && tree_in_live_comb) ? tree_in_node_id : treeq_head_node_id_comb;
assign prefetch_enq_layer_id =
    (tree_in_valid && tree_in_live_comb) ? {`LAYER_ID_W{1'b0}} : treeq_head_layer_id_comb;
assign prefetch_enq_size_subbank = `KV_GROUP_SIZE_SUBBANK;
assign prefetch_enq_shared =
    (tree_in_valid && tree_in_live_comb) ? 1'b0 : treeq_head_shared_comb;
assign prefetch_flush_valid = flush_ctrl_valid;
assign prefetch_flush_req_id = flush_ctrl_req_id;
assign prefetch_flush_branch_mask = flush_ctrl_branch_mask;
assign prefetch_flush_node_mask = flush_ctrl_node_mask;
assign free_list_flush_valid = flush_ctrl_valid;
assign free_list_flush_req_id = flush_ctrl_req_id;
assign free_list_flush_branch_mask = flush_ctrl_branch_mask;
assign free_list_flush_node_mask = flush_ctrl_node_mask;
assign token_flush_valid = flush_ctrl_valid;
assign token_flush_req_id = flush_ctrl_req_id;
assign token_flush_branch_mask = flush_ctrl_branch_mask;
assign token_flush_node_mask = flush_ctrl_node_mask;

// 组合辅助逻辑：
// 1. 生成 pending token 的 branch mask；
// 2. 生成 tree_in 的占位 token/position；
// 3. 汇总 branch liveness 当前状态；
// 4. 决定 tree_in / treeq_head / pending 是否仍然活着；
// 5. 判定当前 pending 节点是否正好被 flush 命中。
always @* begin
    // pending_branch_mask_comb：
    // 共享节点映射到“所有 branch 都可见”，私有节点只点亮自己的 branch。
    pending_branch_mask_comb = {`BRANCH_MASK_W{1'b0}};
    if (pending_shared_r) begin
        pending_branch_mask_comb = {`BRANCH_MASK_W{1'b1}};
    end else if (pending_branch_id_r < `BRANCH_NUM) begin
        pending_branch_mask_comb[pending_branch_id_r] = 1'b1;
    end

    // tree_in 标量路径当前没有完整 token/position 描述，
    // 这里先用 node_id 低位做占位，后续若论文实现继续完善可替换成真实映射。
    scalar_token_id_placeholder_comb = {`TOKEN_ID_W{1'b0}};
    scalar_token_id_placeholder_comb[`NODE_ID_W-1:0] = tree_in_node_id;

    scalar_position_id_placeholder_comb = {`POSITION_ID_W{1'b0}};
    scalar_position_id_placeholder_comb[`NODE_ID_W-1:0] = tree_in_node_id;

    // branch_liveness_state_*：
    // 组合态优先采用本拍新收到的 liveness，若本拍没有更新，则沿用寄存器中的旧值。
    branch_liveness_state_valid_comb = branch_liveness_valid_r;
    branch_liveness_state_req_id_comb = branch_liveness_req_id_r;
    branch_liveness_state_live_mask_comb = branch_liveness_live_mask_r;
    if (branch_liveness_valid) begin
        branch_liveness_state_valid_comb = 1'b1;
        branch_liveness_state_req_id_comb = branch_liveness_req_id;
        branch_liveness_state_live_mask_comb = branch_liveness_live_mask;
    end

    // 判断当前 tree_in 节点是否还属于活分支。
    tree_in_live_comb = branch_live_for_req(
        1'b0,
        tree_in_req_id,
        tree_in_branch_id,
        branch_liveness_state_valid_comb,
        branch_liveness_state_req_id_comb,
        branch_liveness_state_live_mask_comb
    );

    // 取内部工作队列队首，并把默认值补成 0，避免空队列时出现 X。
    treeq_head_valid_comb = (treeq_count_r != {TREE_WORK_COUNT_W{1'b0}});
    treeq_head_req_id_comb = {`REQ_ID_W{1'b0}};
    treeq_head_branch_id_comb = {`BRANCH_ID_W{1'b0}};
    treeq_head_node_id_comb = {`NODE_ID_W{1'b0}};
    treeq_head_shared_comb = 1'b0;
    treeq_head_token_id_comb = {`TOKEN_ID_W{1'b0}};
    treeq_head_position_id_comb = {`POSITION_ID_W{1'b0}};
    treeq_head_layer_id_comb = {`LAYER_ID_W{1'b0}};
    if (treeq_head_valid_comb) begin
        treeq_head_req_id_comb = treeq_req_id_r[0];
        treeq_head_branch_id_comb = treeq_branch_id_r[0];
        treeq_head_node_id_comb = treeq_node_id_r[0];
        treeq_head_shared_comb = treeq_shared_r[0];
        treeq_head_token_id_comb = treeq_token_id_r[0];
        treeq_head_position_id_comb = treeq_position_id_r[0];
        treeq_head_layer_id_comb = treeq_layer_id_r[0];
    end

    // 分别判断队首节点和当前 pending 节点是否仍活着。
    treeq_head_live_comb = branch_live_for_req(
        treeq_head_shared_comb,
        treeq_head_req_id_comb,
        treeq_head_branch_id_comb,
        branch_liveness_state_valid_comb,
        branch_liveness_state_req_id_comb,
        branch_liveness_state_live_mask_comb
    );
    pending_live_comb = branch_live_for_req(
        pending_shared_r,
        pending_req_id_r,
        pending_branch_id_r,
        branch_liveness_state_valid_comb,
        branch_liveness_state_req_id_comb,
        branch_liveness_state_live_mask_comb
    );

    // scalar_dispatch_fire_comb：
    // AGU 空闲时，tree_in 标量路径是否能立刻直通到 prefetch_queue/free_list。
    scalar_dispatch_fire_comb =
        (agu_state_r == AGU_STATE_IDLE) &&
        !flush_freeze &&
        !flush_drain_busy &&
        prefetch_enq_ready &&
        tree_in_valid &&
        tree_in_live_comb;

    // treeq_dispatch_fire_comb：
    // 当没有 tree_in 抢占时，是否可以发送内部 work queue 的队首条目。
    treeq_dispatch_fire_comb =
        (agu_state_r == AGU_STATE_IDLE) &&
        !flush_freeze &&
        !flush_drain_busy &&
        prefetch_enq_ready &&
        !tree_in_valid &&
        treeq_head_valid_comb &&
        treeq_head_live_comb;

    // 如果当前 pending 的私有节点刚好被 flush 掉，需要把这次等待中的分配流程直接中止。
    pending_flush_hit_comb = 1'b0;
    pending_flush_node_bit_i = 0;
    if (flush_ctrl_valid &&
        !pending_shared_r &&
        (agu_state_r != AGU_STATE_IDLE) &&
        (pending_req_id_r == flush_ctrl_req_id) &&
        (pending_branch_id_r < `BRANCH_NUM)) begin
        pending_flush_node_bit_i =
            (pending_branch_id_r * `MAX_VERIFY_NODES_PER_BRANCH) +
            pending_node_id_r;

        if ((pending_flush_node_bit_i < `NODE_MASK_W) &&
            flush_ctrl_branch_mask[pending_branch_id_r] &&
            flush_ctrl_node_mask[pending_flush_node_bit_i]) begin
            pending_flush_hit_comb = 1'b1;
        end
    end
end

// 内部工作队列 next-state 计算：
// 1. 先清空 next-state；
// 2. 保留仍有效、未被本拍派发掉的旧条目；
// 3. 追加本拍新来的 prefix 节点；
// 4. 再把 frontier level 中所有有效 slot 展开为独立条目。
always @* begin
    for (queue_i = 0; queue_i < TREE_WORK_QUEUE_DEPTH; queue_i = queue_i + 1) begin
        treeq_valid_n[queue_i] = 1'b0;
        treeq_req_id_n[queue_i] = {`REQ_ID_W{1'b0}};
        treeq_branch_id_n[queue_i] = {`BRANCH_ID_W{1'b0}};
        treeq_node_id_n[queue_i] = {`NODE_ID_W{1'b0}};
        treeq_shared_n[queue_i] = 1'b0;
        treeq_token_id_n[queue_i] = {`TOKEN_ID_W{1'b0}};
        treeq_position_id_n[queue_i] = {`POSITION_ID_W{1'b0}};
        treeq_layer_id_n[queue_i] = {`LAYER_ID_W{1'b0}};
    end

    pack_idx_i = 0;
    for (queue_i = 0; queue_i < TREE_WORK_QUEUE_DEPTH; queue_i = queue_i + 1) begin
        // queue_entry_live_comb 用于丢弃那些已经被 prune 的旧工作项。
        queue_entry_live_comb = branch_live_for_req(
            treeq_shared_r[queue_i],
            treeq_req_id_r[queue_i],
            treeq_branch_id_r[queue_i],
            branch_liveness_state_valid_comb,
            branch_liveness_state_req_id_comb,
            branch_liveness_state_live_mask_comb
        );
        if (treeq_valid_r[queue_i] &&
            !(treeq_dispatch_fire_comb && (queue_i == 0)) &&
            queue_entry_live_comb) begin
            // 保留旧条目，同时通过 pack_idx_i 做紧凑重排。
            treeq_valid_n[pack_idx_i] = 1'b1;
            treeq_req_id_n[pack_idx_i] = treeq_req_id_r[queue_i];
            treeq_branch_id_n[pack_idx_i] = treeq_branch_id_r[queue_i];
            treeq_node_id_n[pack_idx_i] = treeq_node_id_r[queue_i];
            treeq_shared_n[pack_idx_i] = treeq_shared_r[queue_i];
            treeq_token_id_n[pack_idx_i] = treeq_token_id_r[queue_i];
            treeq_position_id_n[pack_idx_i] = treeq_position_id_r[queue_i];
            treeq_layer_id_n[pack_idx_i] = treeq_layer_id_r[queue_i];
            pack_idx_i = pack_idx_i + 1;
        end
    end

    // prefix 节点总是视为 shared，并以 branch_id=0 的形式进入内部工作队列。
    if (prefix_valid && prefix_ready && prefix_node_valid) begin
        treeq_valid_n[pack_idx_i] = 1'b1;
        treeq_req_id_n[pack_idx_i] = prefix_req_id;
        treeq_branch_id_n[pack_idx_i] = {`BRANCH_ID_W{1'b0}};
        treeq_node_id_n[pack_idx_i] = prefix_node_id;
        treeq_shared_n[pack_idx_i] = 1'b1;
        treeq_token_id_n[pack_idx_i] = prefix_token_id;
        treeq_position_id_n[pack_idx_i] = prefix_position_id;
        treeq_layer_id_n[pack_idx_i] = prefix_layer_id;
        pack_idx_i = pack_idx_i + 1;
    end

    // frontier 的 layer_id 由 level_id 零扩展得到，随后把每个有效 slot 单独入队。
    frontier_layer_id_comb = {`LAYER_ID_W{1'b0}};
    frontier_layer_id_comb[`TREE_LEVEL_ID_W-1:0] = frontier_level_id;
    if (frontier_valid && frontier_ready) begin
        for (frontier_slot_i = 0;
             frontier_slot_i < `TREE_FRONTIER_SLOTS;
             frontier_slot_i = frontier_slot_i + 1) begin
            frontier_slot_live_comb = branch_live_for_req(
                1'b0,
                frontier_req_id,
                frontier_slot_i[`BRANCH_ID_W-1:0],
                branch_liveness_state_valid_comb,
                branch_liveness_state_req_id_comb,
                branch_liveness_state_live_mask_comb
            );
            if (frontier_slot_valid[frontier_slot_i] &&
                frontier_slot_live_comb) begin
                // 每个有效 frontier slot 独立变成一个私有 work item。
                treeq_valid_n[pack_idx_i] = 1'b1;
                treeq_req_id_n[pack_idx_i] = frontier_req_id;
                treeq_branch_id_n[pack_idx_i] =
                    frontier_slot_i[`BRANCH_ID_W-1:0];
                treeq_node_id_n[pack_idx_i] =
                    frontier_node_id[(frontier_slot_i*`NODE_ID_W) +: `NODE_ID_W];
                treeq_shared_n[pack_idx_i] = 1'b0;
                treeq_token_id_n[pack_idx_i] =
                    frontier_token_id[(frontier_slot_i*`TOKEN_ID_W) +: `TOKEN_ID_W];
                treeq_position_id_n[pack_idx_i] =
                    frontier_position_id[(frontier_slot_i*`POSITION_ID_W) +: `POSITION_ID_W];
                treeq_layer_id_n[pack_idx_i] = frontier_layer_id_comb;
                pack_idx_i = pack_idx_i + 1;
            end
        end
    end

    // 队列长度就是重排后的最终条目数。
    treeq_count_n = pack_idx_i[TREE_WORK_COUNT_W-1:0];
end

// AGU 主时序块：
// 1. 维护规范化输出寄存器；
// 2. 更新 branch liveness 快照；
// 3. 维护内部 work queue；
// 4. 驱动 AGU 状态机和 pending candidate 流程。
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        // 复位时清空状态、工作队列和所有一拍脉冲型输出。
        agu_state_r <= AGU_STATE_IDLE;
        pending_req_id_r <= {`REQ_ID_W{1'b0}};
        pending_branch_id_r <= {`BRANCH_ID_W{1'b0}};
        pending_node_id_r <= {`NODE_ID_W{1'b0}};
        pending_shared_r <= 1'b0;
        pending_token_id_r <= {`TOKEN_ID_W{1'b0}};
        pending_position_id_r <= {`POSITION_ID_W{1'b0}};
        pending_layer_id_r <= {`LAYER_ID_W{1'b0}};
        cand_sram_id_r <= {`SRAM_ID_W{1'b0}};
        cand_bank_id_r <= {`BANK_ID_W{1'b0}};
        cand_subbank_start_r <= {`SUBBANK_ID_W{1'b0}};
        cand_group_len_r <= {`KV_GROUP_LEN_W{1'b0}};
        token_wr_valid_r <= 1'b0;
        prefix_norm_valid_r <= 1'b0;
        prefix_norm_req_id_r <= {`REQ_ID_W{1'b0}};
        prefix_norm_node_valid_r <= 1'b0;
        prefix_norm_node_id_r <= {`NODE_ID_W{1'b0}};
        prefix_norm_parent_node_id_r <= {`NODE_ID_W{1'b0}};
        prefix_norm_token_id_r <= {`TOKEN_ID_W{1'b0}};
        prefix_norm_position_id_r <= {`POSITION_ID_W{1'b0}};
        prefix_norm_layer_id_r <= {`LAYER_ID_W{1'b0}};
        prefix_norm_is_last_r <= 1'b0;
        prefix_norm_is_shared_r <= 1'b0;
        frontier_norm_valid_r <= 1'b0;
        frontier_norm_req_id_r <= {`REQ_ID_W{1'b0}};
        frontier_norm_level_id_r <= {`TREE_LEVEL_ID_W{1'b0}};
        frontier_norm_slot_valid_r <= {`TREE_FRONTIER_SLOTS{1'b0}};
        frontier_norm_node_id_r <= {(`TREE_FRONTIER_SLOTS*`NODE_ID_W){1'b0}};
        frontier_norm_parent_node_id_r <= {(`TREE_FRONTIER_SLOTS*`NODE_ID_W){1'b0}};
        frontier_norm_token_id_r <= {(`TREE_FRONTIER_SLOTS*`TOKEN_ID_W){1'b0}};
        frontier_norm_position_id_r <= {(`TREE_FRONTIER_SLOTS*`POSITION_ID_W){1'b0}};
        frontier_norm_size_subbank_r <= {(`TREE_FRONTIER_SLOTS*`KV_GROUP_LEN_W){1'b0}};
        frontier_norm_slot_shared_r <= {`TREE_FRONTIER_SLOTS{1'b0}};
        branch_liveness_valid_r <= 1'b0;
        branch_liveness_req_id_r <= {`REQ_ID_W{1'b0}};
        branch_liveness_live_mask_r <= {`BRANCH_MASK_W{1'b1}};
        treeq_count_r <= {TREE_WORK_COUNT_W{1'b0}};
        for (queue_i = 0; queue_i < TREE_WORK_QUEUE_DEPTH; queue_i = queue_i + 1) begin
            treeq_valid_r[queue_i] <= 1'b0;
            treeq_req_id_r[queue_i] <= {`REQ_ID_W{1'b0}};
            treeq_branch_id_r[queue_i] <= {`BRANCH_ID_W{1'b0}};
            treeq_node_id_r[queue_i] <= {`NODE_ID_W{1'b0}};
            treeq_shared_r[queue_i] <= 1'b0;
            treeq_token_id_r[queue_i] <= {`TOKEN_ID_W{1'b0}};
            treeq_position_id_r[queue_i] <= {`POSITION_ID_W{1'b0}};
            treeq_layer_id_r[queue_i] <= {`LAYER_ID_W{1'b0}};
        end
    end else begin
        // 这些都是单拍脉冲，默认每拍先清零。
        token_wr_valid_r <= 1'b0;
        prefix_norm_valid_r <= 1'b0;
        frontier_norm_valid_r <= 1'b0;

        // 若本拍收到新的 branch liveness，则覆盖缓存。
        if (branch_liveness_valid) begin
            branch_liveness_valid_r <= 1'b1;
            branch_liveness_req_id_r <= branch_liveness_req_id;
            branch_liveness_live_mask_r <= branch_liveness_live_mask;
        end

        // 把组合算出的内部工作队列 next-state 写回。
        treeq_count_r <= treeq_count_n;
        for (queue_i = 0; queue_i < TREE_WORK_QUEUE_DEPTH; queue_i = queue_i + 1) begin
            treeq_valid_r[queue_i] <= treeq_valid_n[queue_i];
            treeq_req_id_r[queue_i] <= treeq_req_id_n[queue_i];
            treeq_branch_id_r[queue_i] <= treeq_branch_id_n[queue_i];
            treeq_node_id_r[queue_i] <= treeq_node_id_n[queue_i];
            treeq_shared_r[queue_i] <= treeq_shared_n[queue_i];
            treeq_token_id_r[queue_i] <= treeq_token_id_n[queue_i];
            treeq_position_id_r[queue_i] <= treeq_position_id_n[queue_i];
            treeq_layer_id_r[queue_i] <= treeq_layer_id_n[queue_i];
        end

        // prefix/frontier 规范化旁路输出：
        // 便于观察 AGU 当前真正接收到的“论文语义节点”。
        if (!flush_freeze && prefix_valid && prefix_ready) begin
            prefix_norm_valid_r <= 1'b1;
            prefix_norm_req_id_r <= prefix_req_id;
            prefix_norm_node_valid_r <= prefix_node_valid;
            prefix_norm_node_id_r <= prefix_node_id;
            prefix_norm_parent_node_id_r <= prefix_parent_node_id;
            prefix_norm_token_id_r <= prefix_token_id;
            prefix_norm_position_id_r <= prefix_position_id;
            prefix_norm_layer_id_r <= prefix_layer_id;
            prefix_norm_is_last_r <= prefix_is_last;
            prefix_norm_is_shared_r <= 1'b1;
        end else if (!flush_freeze && frontier_valid && frontier_ready) begin
            frontier_norm_valid_r <= 1'b1;
            frontier_norm_req_id_r <= frontier_req_id;
            frontier_norm_level_id_r <= frontier_level_id;
            frontier_norm_slot_valid_r <= frontier_slot_valid;
            frontier_norm_node_id_r <= frontier_node_id;
            frontier_norm_parent_node_id_r <= frontier_parent_node_id;
            frontier_norm_token_id_r <= frontier_token_id;
            frontier_norm_position_id_r <= frontier_position_id;
            frontier_norm_slot_shared_r <= {`TREE_FRONTIER_SLOTS{1'b0}};
            for (slot_i = 0; slot_i < `TREE_FRONTIER_SLOTS; slot_i = slot_i + 1) begin
                // 每个有效 frontier slot 固定申请一个 KV_GROUP_SIZE_SUBBANK 的空间。
                if (frontier_slot_valid[slot_i]) begin
                    frontier_norm_size_subbank_r[(slot_i*`KV_GROUP_LEN_W) +: `KV_GROUP_LEN_W] <=
                        `KV_GROUP_SIZE_SUBBANK;
                end else begin
                    frontier_norm_size_subbank_r[(slot_i*`KV_GROUP_LEN_W) +: `KV_GROUP_LEN_W] <=
                        {`KV_GROUP_LEN_W{1'b0}};
                end
            end
        end

        // 如果等待中的 pending 节点所属分支已经被 prune，则立即丢弃这次分配。
        if (!pending_live_comb && (agu_state_r != AGU_STATE_IDLE)) begin
            agu_state_r <= AGU_STATE_IDLE;
            pending_req_id_r <= {`REQ_ID_W{1'b0}};
            pending_branch_id_r <= {`BRANCH_ID_W{1'b0}};
            pending_node_id_r <= {`NODE_ID_W{1'b0}};
            pending_shared_r <= 1'b0;
            pending_token_id_r <= {`TOKEN_ID_W{1'b0}};
            pending_position_id_r <= {`POSITION_ID_W{1'b0}};
            pending_layer_id_r <= {`LAYER_ID_W{1'b0}};
            cand_sram_id_r <= {`SRAM_ID_W{1'b0}};
            cand_bank_id_r <= {`BANK_ID_W{1'b0}};
            cand_subbank_start_r <= {`SUBBANK_ID_W{1'b0}};
            cand_group_len_r <= {`KV_GROUP_LEN_W{1'b0}};
        end else if (pending_flush_hit_comb) begin
            // 如果 pending 节点被显式 flush 命中，也做同样的清空回退。
            agu_state_r <= AGU_STATE_IDLE;
            pending_req_id_r <= {`REQ_ID_W{1'b0}};
            pending_branch_id_r <= {`BRANCH_ID_W{1'b0}};
            pending_node_id_r <= {`NODE_ID_W{1'b0}};
            pending_shared_r <= 1'b0;
            pending_token_id_r <= {`TOKEN_ID_W{1'b0}};
            pending_position_id_r <= {`POSITION_ID_W{1'b0}};
            pending_layer_id_r <= {`LAYER_ID_W{1'b0}};
            cand_sram_id_r <= {`SRAM_ID_W{1'b0}};
            cand_bank_id_r <= {`BANK_ID_W{1'b0}};
            cand_subbank_start_r <= {`SUBBANK_ID_W{1'b0}};
            cand_group_len_r <= {`KV_GROUP_LEN_W{1'b0}};
        end else begin
            case (agu_state_r)
                AGU_STATE_IDLE: begin
                    if (scalar_dispatch_fire_comb) begin
                        // 优先消费 tree_in 标量节点，并锁存成 pending 上下文。
                        pending_req_id_r <= tree_in_req_id;
                        pending_branch_id_r <= tree_in_branch_id;
                        pending_node_id_r <= tree_in_node_id;
                        pending_shared_r <= 1'b0;
                        pending_token_id_r <= scalar_token_id_placeholder_comb;
                        pending_position_id_r <= scalar_position_id_placeholder_comb;
                        pending_layer_id_r <= {`LAYER_ID_W{1'b0}};
                        agu_state_r <= AGU_STATE_WAIT_CAND;
                    end else if (treeq_dispatch_fire_comb) begin
                        // 没有 tree_in 时，再消费内部队列队首。
                        pending_req_id_r <= treeq_head_req_id_comb;
                        pending_branch_id_r <= treeq_head_branch_id_comb;
                        pending_node_id_r <= treeq_head_node_id_comb;
                        pending_shared_r <= treeq_head_shared_comb;
                        pending_token_id_r <= treeq_head_token_id_comb;
                        pending_position_id_r <= treeq_head_position_id_comb;
                        pending_layer_id_r <= treeq_head_layer_id_comb;
                        agu_state_r <= AGU_STATE_WAIT_CAND;
                    end
                end

                AGU_STATE_WAIT_CAND: begin
                    // 等 free_list 返回与 pending_req_id 对应的 candidate。
                    if (cand_resp_valid && (cand_resp_req_id == pending_req_id_r)) begin
                        if (cand_resp_grant) begin
                            // grant 成功：锁存 candidate，并打一拍 token_wr_valid。
                            cand_sram_id_r <= cand_resp_sram_id;
                            cand_bank_id_r <= cand_resp_bank_id;
                            cand_subbank_start_r <= cand_resp_subbank_start;
                            cand_group_len_r <= cand_resp_group_len;
                            token_wr_valid_r <= 1'b1;
                            agu_state_r <= AGU_STATE_WAIT_ALLOC;
                        end else begin
                            // grant 失败：本次节点无法分配位置，直接丢弃 pending。
                            agu_state_r <= AGU_STATE_IDLE;
                            pending_req_id_r <= {`REQ_ID_W{1'b0}};
                            pending_branch_id_r <= {`BRANCH_ID_W{1'b0}};
                            pending_node_id_r <= {`NODE_ID_W{1'b0}};
                            pending_shared_r <= 1'b0;
                            pending_token_id_r <= {`TOKEN_ID_W{1'b0}};
                            pending_position_id_r <= {`POSITION_ID_W{1'b0}};
                            pending_layer_id_r <= {`LAYER_ID_W{1'b0}};
                            cand_sram_id_r <= {`SRAM_ID_W{1'b0}};
                            cand_bank_id_r <= {`BANK_ID_W{1'b0}};
                            cand_subbank_start_r <= {`SUBBANK_ID_W{1'b0}};
                            cand_group_len_r <= {`KV_GROUP_LEN_W{1'b0}};
                        end
                    end
                end

                AGU_STATE_WAIT_ALLOC: begin
                    // free_list has already reserved the candidate location and
                    // token_wr_valid is driven from the latched pending payload in
                    // this one-cycle drain state. Do not stall tree progress on a
                    // later bank_state_table bookkeeping pulse.
                    // 这里仅作为一拍排空态，让 token_wr_valid 顺利被下游观察后回到空闲。
                    agu_state_r <= AGU_STATE_IDLE;
                    pending_req_id_r <= {`REQ_ID_W{1'b0}};
                    pending_branch_id_r <= {`BRANCH_ID_W{1'b0}};
                    pending_node_id_r <= {`NODE_ID_W{1'b0}};
                    pending_shared_r <= 1'b0;
                    pending_token_id_r <= {`TOKEN_ID_W{1'b0}};
                    pending_position_id_r <= {`POSITION_ID_W{1'b0}};
                    pending_layer_id_r <= {`LAYER_ID_W{1'b0}};
                end

                default: begin
                    // 防御式回到空闲态。
                    agu_state_r <= AGU_STATE_IDLE;
                end
            endcase
        end

        // flush 冻结期间若 AGU 已空闲，显式把 pending_shared 归零，避免残留语义。
        if (flush_freeze && (agu_state_r == AGU_STATE_IDLE)) begin
            pending_shared_r <= 1'b0;
        end
    end
end

endmodule
