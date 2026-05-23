`timescale 1ns/1ps

`include "config/prediction_params.vh"
`include "config/interface_params.vh"
`include "config/memory_params.vh"

/*
 * 文件作用：
 * 1. 本文件实现论文 TreeControl 资源管理路径里的 free_list。
 * 2. 它负责在 SRAM bank/subbank 空间里为每个待验证节点挑选可用 KV 存储位置，
 *    同时支持 flush 后的回收与 release 后的释放。
 * 3. 在论文完整主路径里，它位于：
 *    AGU / prefetch_queue
 *      -> free_list
 *      -> bank_state_table / token_register
 * 4. 这不是“简单空闲队列”，而是带有：
 *    - shared prefix 复用
 *    - topology-aware bank 轮转
 *    - per-branch 私有 bank 隔离
 *    - flush reclaim 排空
 *    的位置分配器。
 * 5. 当前 frozen strict tree-mask shortcut 主路径会绕过这条论文式资源分配主链；
 *    本文件对应的是论文完整实现中的动态 KV 位置管理部分。
 */
module free_list #(
    parameter integer ENABLE_TOPOLOGY_AWARE_MAPPING = 0,
    parameter integer ENABLE_SHARED_PREFIX_FREEZE = 0,
    parameter integer ENABLE_BRANCH_ISOLATION = 0
) (
    // 时钟与复位。
    input                        clk,
    input                        rst_n,

    // cand_req_*：
    // 来自 AGU 的“请为这个节点找一段连续 subbank 空间”的申请。
    input                        cand_req_valid,
    output                       cand_req_ready,
    input  [`REQ_ID_W-1:0]       cand_req_req_id,
    input  [`BRANCH_ID_W-1:0]    cand_req_branch_id,
    input  [`NODE_ID_W-1:0]      cand_req_node_id,
    input  [`KV_GROUP_LEN_W-1:0] cand_req_size_subbank,
    input                        cand_req_shared,

    // cand_resp_*：
    // 返回本拍是否找到位置，以及位置在哪里。
    output                       cand_resp_valid,
    output                       cand_resp_grant,
    output [`REQ_ID_W-1:0]       cand_resp_req_id,
    output [`SRAM_ID_W-1:0]      cand_resp_sram_id,
    output [`BANK_ID_W-1:0]      cand_resp_bank_id,
    output [`SUBBANK_ID_W-1:0]   cand_resp_subbank_start,
    output [`KV_GROUP_LEN_W-1:0] cand_resp_group_len,

    // alloc_cand_*：
    // 对 bank_state_table 的并行通知，表明“哪一个节点占用了哪一段物理位置”。
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

    // flush_*：
    // 比较器决定丢弃某些 branch/node 后，free_list 需要回收其占用空间。
    input                        flush_valid,
    input  [`REQ_ID_W-1:0]       flush_req_id,
    input  [`BRANCH_MASK_W-1:0]  flush_branch_mask,
    input  [`NODE_MASK_W-1:0]    flush_node_mask,
    output                       flush_drain_busy,
    output                       flush_reclaim_valid,
    output [`SRAM_ID_W-1:0]      flush_reclaim_sram_id,
    output [`BANK_ID_W-1:0]      flush_reclaim_bank_id,
    output [`SUBBANK_ID_W-1:0]   flush_reclaim_subbank_start,
    output [`KV_GROUP_LEN_W-1:0] flush_reclaim_group_len,

    // release_*：
    // 某些位置在后续阶段被显式释放时，从这里返还到空闲池。
    input                        release_valid,
    input  [`SRAM_ID_W-1:0]      release_sram_id,
    input  [`BANK_ID_W-1:0]      release_bank_id,
    input  [`SUBBANK_ID_W-1:0]   release_subbank_start,
    input  [`KV_GROUP_LEN_W-1:0] release_group_len
);

// 一些派生常量：
// TOTAL_BANKS                       : 整个 SRAM 体系总 bank 数。
// SHARED_BANKS_PER_SRAM             : 共享前缀倾向使用的 bank 数。
// PRIVATE_BANKS_PER_BRANCH          : 每个分支可用的私有 bank 数。
// TOTAL_SHARED_BANKS / TOTAL_PRIVATE_BANKS_PER_BRANCH :
//     用于 shared/private 轮转搜索的逻辑 bank 空间大小。
localparam integer TOTAL_BANKS = `SRAM_NUM * `SRAM_BANK_NUM;
localparam integer SHARED_BANKS_PER_SRAM =
    (`SRAM_BANK_NUM >= 4) ? (`SRAM_BANK_NUM / 4) : 1;
localparam integer PRIVATE_BANKS_PER_SRAM =
    (`SRAM_BANK_NUM > SHARED_BANKS_PER_SRAM) ?
        (`SRAM_BANK_NUM - SHARED_BANKS_PER_SRAM) : 1;
localparam integer PRIVATE_BANKS_PER_BRANCH =
    (PRIVATE_BANKS_PER_SRAM >= `BRANCH_NUM) ?
        (PRIVATE_BANKS_PER_SRAM / `BRANCH_NUM) : 1;
localparam integer TOTAL_SHARED_BANKS = `SRAM_NUM * SHARED_BANKS_PER_SRAM;
localparam integer TOTAL_PRIVATE_BANKS_PER_BRANCH =
    `SRAM_NUM * PRIVATE_BANKS_PER_BRANCH;

// free_bitmap：
// 1 表示该 subbank 空闲，0 表示已占用。
// 维度是 [flat_bank][subbank_idx]。
reg [`SUBBANK_NUM_PER_BANK-1:0] free_bitmap [0:TOTAL_BANKS-1];

// 通用轮转游标。
reg [`SRAM_ID_W-1:0] cursor_sram;
reg [`BANK_ID_W-1:0] cursor_bank;
reg [`SUBBANK_ID_W-1:0] cursor_subbank;

// shared/private 路径各自的轮转游标。
reg [`SRAM_ID_W-1:0] shared_cursor_sram;
reg [`BANK_ID_W-1:0] shared_cursor_bank;
reg [`SUBBANK_ID_W-1:0] shared_cursor_subbank;
reg [`SRAM_ID_W-1:0] private_cursor_sram [0:`BRANCH_NUM-1];
reg [`BANK_ID_W-1:0] private_cursor_bank [0:`BRANCH_NUM-1];
reg [`SUBBANK_ID_W-1:0] private_cursor_subbank [0:`BRANCH_NUM-1];

// 候选响应与占用通知寄存器。
reg cand_resp_valid_r;
reg cand_resp_grant_r;
reg [`REQ_ID_W-1:0] cand_resp_req_id_r;
reg [`SRAM_ID_W-1:0] cand_resp_sram_id_r;
reg [`BANK_ID_W-1:0] cand_resp_bank_id_r;
reg [`SUBBANK_ID_W-1:0] cand_resp_subbank_start_r;
reg [`KV_GROUP_LEN_W-1:0] cand_resp_group_len_r;
reg alloc_cand_valid_r;
reg [`REQ_ID_W-1:0] alloc_cand_req_id_r;
reg [`BRANCH_ID_W-1:0] alloc_cand_branch_id_r;
reg [`NODE_ID_W-1:0] alloc_cand_node_id_r;
reg [`KV_GROUP_LEN_W-1:0] alloc_cand_size_subbank_r;
reg alloc_cand_shared_r;
reg [`SRAM_ID_W-1:0] alloc_cand_sram_id_r;
reg [`BANK_ID_W-1:0] alloc_cand_bank_id_r;
reg [`SUBBANK_ID_W-1:0] alloc_cand_subbank_start_r;
reg [`KV_GROUP_LEN_W-1:0] alloc_cand_group_len_r;
reg flush_reclaim_valid_r;
reg [`SRAM_ID_W-1:0] flush_reclaim_sram_id_r;
reg [`BANK_ID_W-1:0] flush_reclaim_bank_id_r;
reg [`SUBBANK_ID_W-1:0] flush_reclaim_subbank_start_r;
reg [`KV_GROUP_LEN_W-1:0] flush_reclaim_group_len_r;

// entry_*：
// 对每个已占用 subbank 记录是谁占的、属于哪个 branch/node、是否 shared。
reg [`REQ_ID_W-1:0] entry_req_id [0:TOTAL_BANKS-1][0:`SUBBANK_NUM_PER_BANK-1];
reg [`BRANCH_ID_W-1:0] entry_branch_id [0:TOTAL_BANKS-1][0:`SUBBANK_NUM_PER_BANK-1];
reg [`BRANCH_MASK_W-1:0] entry_branch_mask [0:TOTAL_BANKS-1][0:`SUBBANK_NUM_PER_BANK-1];
reg [`NODE_ID_W-1:0] entry_node_id [0:TOTAL_BANKS-1][0:`SUBBANK_NUM_PER_BANK-1];
reg entry_shared [0:TOTAL_BANKS-1][0:`SUBBANK_NUM_PER_BANK-1];

// pending_reclaim_*：
// flush 可能一拍命中多个可回收连续区，但接口一次只能吐一个 reclaim。
// 其余待发 reclaim 暂存在这里，后续逐拍排出。
reg pending_reclaim_valid [0:TOTAL_BANKS-1][0:`SUBBANK_NUM_PER_BANK-1];
reg [`KV_GROUP_LEN_W-1:0] pending_reclaim_group_len [0:TOTAL_BANKS-1][0:`SUBBANK_NUM_PER_BANK-1];

reg search_found;
reg search_reuse;
reg [`SRAM_ID_W-1:0] search_sram_id;
reg [`BANK_ID_W-1:0] search_bank_id;
reg [`SUBBANK_ID_W-1:0] search_subbank_start;
reg [`KV_GROUP_LEN_W-1:0] search_group_len;

integer req_size_i;
integer cursor_flat_i;
integer bank_offset_i;
integer bank_idx_i;
integer branch_idx_i;
integer branch_base_bank_i;
integer start_base_i;
integer start_pos_i;
integer bit_idx_i;
integer search_flat_i;
integer release_flat_i;
reg range_free;
integer init_i;
integer init_branch_i;
integer clear_i;
integer release_i;
integer next_flat_i;
integer next_pos_i;
integer next_logical_i;
integer init_subbank_i;
integer flush_flat_i;
integer flush_idx_i;
integer flush_node_bit_i;
reg flush_hit;
reg flush_prev_contiguous_hit;
reg flush_head_hit;
integer flush_range_len_i;
integer flush_len_scan_i;
integer shared_cursor_logical_i;
integer private_cursor_logical_i;
integer logical_bank_idx_i;
reg flush_emit_claimed;
reg pending_reclaim_found_comb;
reg [`SRAM_ID_W-1:0] pending_reclaim_sram_id_comb;
reg [`BANK_ID_W-1:0] pending_reclaim_bank_id_comb;
reg [`SUBBANK_ID_W-1:0] pending_reclaim_subbank_start_comb;
reg [`KV_GROUP_LEN_W-1:0] pending_reclaim_group_len_comb;
integer pending_reclaim_flat_idx_comb;
integer pending_scan_flat_i;
integer pending_scan_idx_i;

// 把 branch_id 转成 one-hot branch mask。
function [`BRANCH_MASK_W-1:0] branch_onehot;
    input [`BRANCH_ID_W-1:0] branch_id_in;
    begin
        branch_onehot = {`BRANCH_MASK_W{1'b0}};
        if (branch_id_in < `BRANCH_NUM) begin
            branch_onehot[branch_id_in] = 1'b1;
        end
    end
endfunction

// 计算某个分支的私有 bank 起始偏移。
function integer private_base_bank;
    input integer branch_id_in;
    begin
        if (PRIVATE_BANKS_PER_SRAM > 0) begin
            private_base_bank =
                SHARED_BANKS_PER_SRAM +
                ((branch_id_in * PRIVATE_BANKS_PER_BRANCH) %
                 PRIVATE_BANKS_PER_SRAM);
        end else begin
            private_base_bank = SHARED_BANKS_PER_SRAM;
        end
    end
endfunction

// 共享路径的“逻辑 bank 编号 -> 扁平 flat bank 编号”。
function integer shared_logical_to_flat;
    input integer logical_idx_in;
    begin
        shared_logical_to_flat =
            ((logical_idx_in / SHARED_BANKS_PER_SRAM) * `SRAM_BANK_NUM) +
            (logical_idx_in % SHARED_BANKS_PER_SRAM);
    end
endfunction

// 私有路径的“逻辑 bank 编号 -> 扁平 flat bank 编号”。
function integer private_logical_to_flat;
    input integer branch_id_in;
    input integer logical_idx_in;
    begin
        private_logical_to_flat =
            ((logical_idx_in / PRIVATE_BANKS_PER_BRANCH) * `SRAM_BANK_NUM) +
            private_base_bank(branch_id_in) +
            (logical_idx_in % PRIVATE_BANKS_PER_BRANCH);
    end
endfunction

// 输入输出连线：
// cand_req_ready 固定为 1，表示 free_list 本身不做上游反压，
// 真正找不到位置时通过 cand_resp_grant=0 表示失败。
assign cand_req_ready = 1'b1;
assign cand_resp_valid = cand_resp_valid_r;
assign cand_resp_grant = cand_resp_grant_r;
assign cand_resp_req_id = cand_resp_req_id_r;
assign cand_resp_sram_id = cand_resp_sram_id_r;
assign cand_resp_bank_id = cand_resp_bank_id_r;
assign cand_resp_subbank_start = cand_resp_subbank_start_r;
assign cand_resp_group_len = cand_resp_group_len_r;
assign alloc_cand_valid = alloc_cand_valid_r;
assign alloc_cand_req_id = alloc_cand_req_id_r;
assign alloc_cand_branch_id = alloc_cand_branch_id_r;
assign alloc_cand_node_id = alloc_cand_node_id_r;
assign alloc_cand_size_subbank = alloc_cand_size_subbank_r;
assign alloc_cand_shared = alloc_cand_shared_r;
assign alloc_cand_sram_id = alloc_cand_sram_id_r;
assign alloc_cand_bank_id = alloc_cand_bank_id_r;
assign alloc_cand_subbank_start = alloc_cand_subbank_start_r;
assign alloc_cand_group_len = alloc_cand_group_len_r;
assign flush_drain_busy = pending_reclaim_found_comb;
assign flush_reclaim_valid = flush_reclaim_valid_r;
assign flush_reclaim_sram_id = flush_reclaim_sram_id_r;
assign flush_reclaim_bank_id = flush_reclaim_bank_id_r;
assign flush_reclaim_subbank_start = flush_reclaim_subbank_start_r;
assign flush_reclaim_group_len = flush_reclaim_group_len_r;

// 候选搜索组合逻辑：
// 1. 若启用 shared-prefix-freeze，先尝试复用同一 req/node 的 shared 旧区域。
// 2. 否则根据 shared/private/普通模式选择不同 bank 搜索域。
// 3. 要求找到一段长度为 cand_req_size_subbank 的连续空闲 subbank。
always @* begin
    search_found = 1'b0;
    search_reuse = 1'b0;
    search_sram_id = {`SRAM_ID_W{1'b0}};
    search_bank_id = {`BANK_ID_W{1'b0}};
    search_subbank_start = {`SUBBANK_ID_W{1'b0}};
    search_group_len = cand_req_size_subbank;

    req_size_i = cand_req_size_subbank;
    cursor_flat_i = (cursor_sram * `SRAM_BANK_NUM) + cursor_bank;
    branch_idx_i = 0;
    if (cand_req_branch_id < `BRANCH_NUM) begin
        branch_idx_i = cand_req_branch_id;
    end

    if ((req_size_i > 0) && (req_size_i <= `SUBBANK_NUM_PER_BANK)) begin
        // 第一优先级：shared 前缀复用。
        // 若同一个 req/node 的 shared 区域已经分配过，就直接重用，避免重复占位。
        if (ENABLE_SHARED_PREFIX_FREEZE && cand_req_shared) begin
            for (bank_idx_i = 0; bank_idx_i < TOTAL_BANKS; bank_idx_i = bank_idx_i + 1) begin
                for (start_pos_i = 0;
                     start_pos_i <= (`SUBBANK_NUM_PER_BANK - req_size_i);
                     start_pos_i = start_pos_i + 1) begin
                    if (!search_found &&
                        !free_bitmap[bank_idx_i][start_pos_i] &&
                        entry_shared[bank_idx_i][start_pos_i] &&
                        (entry_req_id[bank_idx_i][start_pos_i] == cand_req_req_id) &&
                        (entry_node_id[bank_idx_i][start_pos_i] == cand_req_node_id) &&
                        ((start_pos_i == 0) ||
                         free_bitmap[bank_idx_i][start_pos_i - 1] ||
                         !entry_shared[bank_idx_i][start_pos_i - 1] ||
                         (entry_req_id[bank_idx_i][start_pos_i - 1] != cand_req_req_id) ||
                         (entry_node_id[bank_idx_i][start_pos_i - 1] != cand_req_node_id))) begin
                        range_free = 1'b1;
                        for (bit_idx_i = 0; bit_idx_i < req_size_i; bit_idx_i = bit_idx_i + 1) begin
                            // “复用”要求整段都属于同一个 shared 节点，不能只是空闲。
                            if (free_bitmap[bank_idx_i][start_pos_i + bit_idx_i] ||
                                !entry_shared[bank_idx_i][start_pos_i + bit_idx_i] ||
                                (entry_req_id[bank_idx_i][start_pos_i + bit_idx_i] !=
                                 cand_req_req_id) ||
                                (entry_node_id[bank_idx_i][start_pos_i + bit_idx_i] !=
                                 cand_req_node_id)) begin
                                range_free = 1'b0;
                            end
                        end

                        if (range_free) begin
                            search_found = 1'b1;
                            search_reuse = 1'b1;
                            search_sram_id = bank_idx_i / `SRAM_BANK_NUM;
                            search_bank_id = bank_idx_i % `SRAM_BANK_NUM;
                            search_subbank_start = start_pos_i[`SUBBANK_ID_W-1:0];
                            search_group_len = cand_req_size_subbank;
                        end
                    end
                end
            end
        end

        if (!search_found) begin
            if ((ENABLE_TOPOLOGY_AWARE_MAPPING || ENABLE_SHARED_PREFIX_FREEZE) &&
                cand_req_shared) begin
                // shared 节点：优先在 shared bank 域内轮转搜索。
                shared_cursor_logical_i =
                    (shared_cursor_sram * SHARED_BANKS_PER_SRAM) +
                    shared_cursor_bank;
                for (bank_offset_i = 0;
                     bank_offset_i < TOTAL_SHARED_BANKS;
                     bank_offset_i = bank_offset_i + 1) begin
                    logical_bank_idx_i =
                        (shared_cursor_logical_i + bank_offset_i) %
                        TOTAL_SHARED_BANKS;
                    bank_idx_i = shared_logical_to_flat(logical_bank_idx_i);
                    if (bank_offset_i == 0) begin
                        start_base_i = shared_cursor_subbank;
                    end else begin
                        start_base_i = 0;
                    end

                    for (start_pos_i = start_base_i;
                         start_pos_i <= (`SUBBANK_NUM_PER_BANK - req_size_i);
                         start_pos_i = start_pos_i + 1) begin
                        range_free = 1'b1;
                        for (bit_idx_i = 0; bit_idx_i < req_size_i; bit_idx_i = bit_idx_i + 1) begin
                            // 普通分配要求整段都空闲。
                            if (!free_bitmap[bank_idx_i][start_pos_i + bit_idx_i]) begin
                                range_free = 1'b0;
                            end
                        end

                        if (!search_found && range_free) begin
                            search_found = 1'b1;
                            search_sram_id = bank_idx_i / `SRAM_BANK_NUM;
                            search_bank_id = bank_idx_i % `SRAM_BANK_NUM;
                            search_subbank_start = start_pos_i[`SUBBANK_ID_W-1:0];
                            search_group_len = cand_req_size_subbank;
                        end
                    end
                end
            end else if ((ENABLE_TOPOLOGY_AWARE_MAPPING || ENABLE_BRANCH_ISOLATION) &&
                         !cand_req_shared) begin
                // 私有节点：若启用 topology-aware / branch-isolation，则只在本分支私有 bank 域搜索。
                branch_base_bank_i = private_base_bank(branch_idx_i);
                private_cursor_logical_i =
                    (private_cursor_sram[branch_idx_i] * PRIVATE_BANKS_PER_BRANCH) +
                    (private_cursor_bank[branch_idx_i] - branch_base_bank_i);
                for (bank_offset_i = 0;
                     bank_offset_i < TOTAL_PRIVATE_BANKS_PER_BRANCH;
                     bank_offset_i = bank_offset_i + 1) begin
                    logical_bank_idx_i =
                        (private_cursor_logical_i + bank_offset_i) %
                        TOTAL_PRIVATE_BANKS_PER_BRANCH;
                    bank_idx_i =
                        private_logical_to_flat(branch_idx_i, logical_bank_idx_i);
                    if (bank_offset_i == 0) begin
                        start_base_i = private_cursor_subbank[branch_idx_i];
                    end else begin
                        start_base_i = 0;
                    end

                    for (start_pos_i = start_base_i;
                         start_pos_i <= (`SUBBANK_NUM_PER_BANK - req_size_i);
                         start_pos_i = start_pos_i + 1) begin
                        range_free = 1'b1;
                        for (bit_idx_i = 0; bit_idx_i < req_size_i; bit_idx_i = bit_idx_i + 1) begin
                            if (!free_bitmap[bank_idx_i][start_pos_i + bit_idx_i]) begin
                                range_free = 1'b0;
                            end
                        end

                        if (!search_found && range_free) begin
                            search_found = 1'b1;
                            search_sram_id = bank_idx_i / `SRAM_BANK_NUM;
                            search_bank_id = bank_idx_i % `SRAM_BANK_NUM;
                            search_subbank_start = start_pos_i[`SUBBANK_ID_W-1:0];
                            search_group_len = cand_req_size_subbank;
                        end
                    end
                end
            end else begin
                // 默认模式：在全局 bank 空间做轮转搜索。
                for (bank_offset_i = 0; bank_offset_i < TOTAL_BANKS; bank_offset_i = bank_offset_i + 1) begin
                    bank_idx_i = (cursor_flat_i + bank_offset_i) % TOTAL_BANKS;
                    if (bank_offset_i == 0) begin
                        start_base_i = cursor_subbank;
                    end else begin
                        start_base_i = 0;
                    end

                    for (start_pos_i = start_base_i;
                         start_pos_i <= (`SUBBANK_NUM_PER_BANK - req_size_i);
                         start_pos_i = start_pos_i + 1) begin
                        range_free = 1'b1;
                        for (bit_idx_i = 0; bit_idx_i < req_size_i; bit_idx_i = bit_idx_i + 1) begin
                            if (!free_bitmap[bank_idx_i][start_pos_i + bit_idx_i]) begin
                                range_free = 1'b0;
                            end
                        end

                        if (!search_found && range_free) begin
                            search_found = 1'b1;
                            search_sram_id = bank_idx_i / `SRAM_BANK_NUM;
                            search_bank_id = bank_idx_i % `SRAM_BANK_NUM;
                            search_subbank_start = start_pos_i[`SUBBANK_ID_W-1:0];
                            search_group_len = cand_req_size_subbank;
                        end
                    end
                end
            end
        end
    end
end

// pending reclaim 扫描：
// flush 时可能有多个连续区被标记为待回收，这里取出第一个待发送 reclaim 事件。
always @* begin
    pending_reclaim_found_comb = 1'b0;
    pending_reclaim_sram_id_comb = {`SRAM_ID_W{1'b0}};
    pending_reclaim_bank_id_comb = {`BANK_ID_W{1'b0}};
    pending_reclaim_subbank_start_comb = {`SUBBANK_ID_W{1'b0}};
    pending_reclaim_group_len_comb = {`KV_GROUP_LEN_W{1'b0}};
    pending_reclaim_flat_idx_comb = 0;

    for (pending_scan_flat_i = 0;
         pending_scan_flat_i < TOTAL_BANKS;
         pending_scan_flat_i = pending_scan_flat_i + 1) begin
        for (pending_scan_idx_i = 0;
             pending_scan_idx_i < `SUBBANK_NUM_PER_BANK;
             pending_scan_idx_i = pending_scan_idx_i + 1) begin
            if (!pending_reclaim_found_comb &&
                pending_reclaim_valid[pending_scan_flat_i][pending_scan_idx_i]) begin
                // 一旦找到第一个待回收条目，就把它转成 flush_reclaim_* 输出。
                pending_reclaim_found_comb = 1'b1;
                pending_reclaim_sram_id_comb = pending_scan_flat_i / `SRAM_BANK_NUM;
                pending_reclaim_bank_id_comb = pending_scan_flat_i % `SRAM_BANK_NUM;
                pending_reclaim_subbank_start_comb =
                    pending_scan_idx_i[`SUBBANK_ID_W-1:0];
                pending_reclaim_group_len_comb =
                    pending_reclaim_group_len[pending_scan_flat_i][pending_scan_idx_i];
                pending_reclaim_flat_idx_comb = pending_scan_flat_i;
            end
        end
    end
end

// 主时序块：
// 1. 维护 free_bitmap 与 entry 元数据；
// 2. 处理 release；
// 3. 处理 flush 与 reclaim 排空；
// 4. 响应新的 cand_req 并更新轮转游标。
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        // 复位时：所有 subbank 空闲，元数据清零，轮转游标回到起始位置。
        for (init_i = 0; init_i < TOTAL_BANKS; init_i = init_i + 1) begin
            free_bitmap[init_i] <= {`SUBBANK_NUM_PER_BANK{1'b1}};
            for (init_subbank_i = 0; init_subbank_i < `SUBBANK_NUM_PER_BANK; init_subbank_i = init_subbank_i + 1) begin
                entry_req_id[init_i][init_subbank_i] <= {`REQ_ID_W{1'b0}};
                entry_branch_id[init_i][init_subbank_i] <= {`BRANCH_ID_W{1'b0}};
                entry_branch_mask[init_i][init_subbank_i] <=
                    {`BRANCH_MASK_W{1'b0}};
                entry_node_id[init_i][init_subbank_i] <= {`NODE_ID_W{1'b0}};
                entry_shared[init_i][init_subbank_i] <= 1'b0;
                pending_reclaim_valid[init_i][init_subbank_i] <= 1'b0;
                pending_reclaim_group_len[init_i][init_subbank_i] <= {`KV_GROUP_LEN_W{1'b0}};
            end
        end
        cursor_sram <= {`SRAM_ID_W{1'b0}};
        cursor_bank <= {`BANK_ID_W{1'b0}};
        cursor_subbank <= {`SUBBANK_ID_W{1'b0}};
        shared_cursor_sram <= {`SRAM_ID_W{1'b0}};
        shared_cursor_bank <= {`BANK_ID_W{1'b0}};
        shared_cursor_subbank <= {`SUBBANK_ID_W{1'b0}};
        for (init_branch_i = 0;
             init_branch_i < `BRANCH_NUM;
             init_branch_i = init_branch_i + 1) begin
            private_cursor_sram[init_branch_i] <= {`SRAM_ID_W{1'b0}};
            private_cursor_bank[init_branch_i] <=
                private_base_bank(init_branch_i);
            private_cursor_subbank[init_branch_i] <= {`SUBBANK_ID_W{1'b0}};
        end
        cand_resp_valid_r <= 1'b0;
        cand_resp_grant_r <= 1'b0;
        cand_resp_req_id_r <= {`REQ_ID_W{1'b0}};
        cand_resp_sram_id_r <= {`SRAM_ID_W{1'b0}};
        cand_resp_bank_id_r <= {`BANK_ID_W{1'b0}};
        cand_resp_subbank_start_r <= {`SUBBANK_ID_W{1'b0}};
        cand_resp_group_len_r <= {`KV_GROUP_LEN_W{1'b0}};
        alloc_cand_valid_r <= 1'b0;
        alloc_cand_req_id_r <= {`REQ_ID_W{1'b0}};
        alloc_cand_branch_id_r <= {`BRANCH_ID_W{1'b0}};
        alloc_cand_node_id_r <= {`NODE_ID_W{1'b0}};
        alloc_cand_size_subbank_r <= {`KV_GROUP_LEN_W{1'b0}};
        alloc_cand_shared_r <= 1'b0;
        alloc_cand_sram_id_r <= {`SRAM_ID_W{1'b0}};
        alloc_cand_bank_id_r <= {`BANK_ID_W{1'b0}};
        alloc_cand_subbank_start_r <= {`SUBBANK_ID_W{1'b0}};
        alloc_cand_group_len_r <= {`KV_GROUP_LEN_W{1'b0}};
        flush_reclaim_valid_r <= 1'b0;
        flush_reclaim_sram_id_r <= {`SRAM_ID_W{1'b0}};
        flush_reclaim_bank_id_r <= {`BANK_ID_W{1'b0}};
        flush_reclaim_subbank_start_r <= {`SUBBANK_ID_W{1'b0}};
        flush_reclaim_group_len_r <= {`KV_GROUP_LEN_W{1'b0}};
    end else begin
        // 单拍响应默认清零。
        cand_resp_valid_r <= 1'b0;
        alloc_cand_valid_r <= 1'b0;
        flush_reclaim_valid_r <= 1'b0;
        flush_reclaim_sram_id_r <= {`SRAM_ID_W{1'b0}};
        flush_reclaim_bank_id_r <= {`BANK_ID_W{1'b0}};
        flush_reclaim_subbank_start_r <= {`SUBBANK_ID_W{1'b0}};
        flush_reclaim_group_len_r <= {`KV_GROUP_LEN_W{1'b0}};

        if (release_valid) begin
            // 显式 release：把给定连续区间直接标回空闲。
            release_flat_i = (release_sram_id * `SRAM_BANK_NUM) + release_bank_id;
            for (release_i = 0; release_i < release_group_len; release_i = release_i + 1) begin
                if ((release_subbank_start + release_i) < `SUBBANK_NUM_PER_BANK) begin
                    free_bitmap[release_flat_i][release_subbank_start + release_i] <= 1'b1;
                    entry_req_id[release_flat_i][release_subbank_start + release_i] <= {`REQ_ID_W{1'b0}};
                    entry_branch_id[release_flat_i][release_subbank_start + release_i] <= {`BRANCH_ID_W{1'b0}};
                    entry_branch_mask[release_flat_i]
                                     [release_subbank_start + release_i] <=
                        {`BRANCH_MASK_W{1'b0}};
                    entry_node_id[release_flat_i][release_subbank_start + release_i] <= {`NODE_ID_W{1'b0}};
                    entry_shared[release_flat_i][release_subbank_start + release_i] <= 1'b0;
                end
            end
        end

        if (flush_valid) begin
            // flush 期间，需要扫描所有已占用私有节点，把命中的连续区间回收出来。
            flush_emit_claimed = 1'b0;

            for (flush_flat_i = 0; flush_flat_i < TOTAL_BANKS; flush_flat_i = flush_flat_i + 1) begin
                for (flush_idx_i = 0; flush_idx_i < `SUBBANK_NUM_PER_BANK; flush_idx_i = flush_idx_i + 1) begin
                    flush_hit = 1'b0;
                    flush_node_bit_i = 0;
                    flush_prev_contiguous_hit = 1'b0;
                    flush_head_hit = 1'b0;
                    flush_range_len_i = 0;

                    // flush_hit：
                    // 当前 subbank 是否属于这次 req_id/branch/node 命中的被剪枝节点。
                    if (!free_bitmap[flush_flat_i][flush_idx_i] &&
                        !entry_shared[flush_flat_i][flush_idx_i] &&
                        (entry_req_id[flush_flat_i][flush_idx_i] == flush_req_id) &&
                        (entry_branch_id[flush_flat_i][flush_idx_i] < `BRANCH_NUM)) begin
                        flush_node_bit_i =
                            (entry_branch_id[flush_flat_i][flush_idx_i] *
                             `MAX_VERIFY_NODES_PER_BRANCH) +
                            entry_node_id[flush_flat_i][flush_idx_i];

                        if ((flush_node_bit_i < `NODE_MASK_W) &&
                            flush_branch_mask[entry_branch_id[flush_flat_i][flush_idx_i]] &&
                            flush_node_mask[flush_node_bit_i]) begin
                            flush_hit = 1'b1;
                        end
                    end

                    // flush_prev_contiguous_hit：
                    // 用来判断当前命中 subbank 是否是同一连续区间的中间部分。
                    if (flush_hit && (flush_idx_i > 0) &&
                        !free_bitmap[flush_flat_i][flush_idx_i - 1] &&
                        !entry_shared[flush_flat_i][flush_idx_i - 1] &&
                        (entry_req_id[flush_flat_i][flush_idx_i - 1] ==
                         entry_req_id[flush_flat_i][flush_idx_i]) &&
                        (entry_branch_id[flush_flat_i][flush_idx_i - 1] ==
                         entry_branch_id[flush_flat_i][flush_idx_i]) &&
                        (entry_node_id[flush_flat_i][flush_idx_i - 1] ==
                         entry_node_id[flush_flat_i][flush_idx_i])) begin
                        flush_prev_contiguous_hit = 1'b1;
                    end

                    // 只有连续区间的头部才负责发 reclaim 事件。
                    flush_head_hit = flush_hit && !flush_prev_contiguous_hit;

                    if (flush_head_hit) begin
                        // 从头部开始向后扫描，统计这段连续区间长度。
                        for (flush_len_scan_i = flush_idx_i;
                             flush_len_scan_i < `SUBBANK_NUM_PER_BANK;
                             flush_len_scan_i = flush_len_scan_i + 1) begin
                            if (!free_bitmap[flush_flat_i][flush_len_scan_i] &&
                                !entry_shared[flush_flat_i][flush_len_scan_i] &&
                                (entry_req_id[flush_flat_i][flush_len_scan_i] ==
                                 entry_req_id[flush_flat_i][flush_idx_i]) &&
                                (entry_branch_id[flush_flat_i][flush_len_scan_i] ==
                                 entry_branch_id[flush_flat_i][flush_idx_i]) &&
                                (entry_node_id[flush_flat_i][flush_len_scan_i] ==
                                 entry_node_id[flush_flat_i][flush_idx_i])) begin
                                flush_range_len_i = flush_range_len_i + 1;
                            end else begin
                                flush_len_scan_i = `SUBBANK_NUM_PER_BANK;
                            end
                        end

                        if (!flush_emit_claimed) begin
                            // 本拍第一个命中的连续区，直接走输出口。
                            flush_reclaim_valid_r <= 1'b1;
                            flush_reclaim_sram_id_r <= flush_flat_i / `SRAM_BANK_NUM;
                            flush_reclaim_bank_id_r <= flush_flat_i % `SRAM_BANK_NUM;
                            flush_reclaim_subbank_start_r <=
                                flush_idx_i[`SUBBANK_ID_W-1:0];
                            flush_reclaim_group_len_r <=
                                flush_range_len_i[`KV_GROUP_LEN_W-1:0];
                            flush_emit_claimed = 1'b1;
                        end else begin
                            // 同拍后续命中的 reclaim 先缓存起来，留待后续几拍排出。
                            pending_reclaim_valid[flush_flat_i][flush_idx_i] <= 1'b1;
                            pending_reclaim_group_len[flush_flat_i][flush_idx_i] <=
                                flush_range_len_i[`KV_GROUP_LEN_W-1:0];
                        end
                    end

                    // 只要 flush_hit，当前 subbank 就立刻归还为空闲。
                    if (flush_hit) begin
                        free_bitmap[flush_flat_i][flush_idx_i] <= 1'b1;
                        entry_req_id[flush_flat_i][flush_idx_i] <= {`REQ_ID_W{1'b0}};
                        entry_branch_id[flush_flat_i][flush_idx_i] <= {`BRANCH_ID_W{1'b0}};
                        entry_branch_mask[flush_flat_i][flush_idx_i] <=
                            {`BRANCH_MASK_W{1'b0}};
                        entry_node_id[flush_flat_i][flush_idx_i] <= {`NODE_ID_W{1'b0}};
                        entry_shared[flush_flat_i][flush_idx_i] <= 1'b0;
                    end
                end
            end
        end else if (pending_reclaim_found_comb) begin
            // 没有新的 flush 时，继续把之前挂起的 reclaim 逐拍吐出去。
            flush_reclaim_valid_r <= 1'b1;
            flush_reclaim_sram_id_r <= pending_reclaim_sram_id_comb;
            flush_reclaim_bank_id_r <= pending_reclaim_bank_id_comb;
            flush_reclaim_subbank_start_r <= pending_reclaim_subbank_start_comb;
            flush_reclaim_group_len_r <= pending_reclaim_group_len_comb;
            pending_reclaim_valid[pending_reclaim_flat_idx_comb]
                                 [pending_reclaim_subbank_start_comb] <= 1'b0;
            pending_reclaim_group_len[pending_reclaim_flat_idx_comb]
                                     [pending_reclaim_subbank_start_comb] <=
                {`KV_GROUP_LEN_W{1'b0}};
        end

        if (cand_req_valid && cand_req_ready) begin
            // 对当前 cand_req 返回搜索结果，并同步产生 alloc_cand_* 通知。
            cand_resp_valid_r <= 1'b1;
            cand_resp_grant_r <= search_found;
            cand_resp_req_id_r <= cand_req_req_id;
            cand_resp_sram_id_r <= search_sram_id;
            cand_resp_bank_id_r <= search_bank_id;
            cand_resp_subbank_start_r <= search_subbank_start;
            cand_resp_group_len_r <= cand_req_size_subbank;
            alloc_cand_valid_r <= search_found;
            alloc_cand_req_id_r <= cand_req_req_id;
            alloc_cand_branch_id_r <= cand_req_branch_id;
            alloc_cand_node_id_r <= cand_req_node_id;
            alloc_cand_size_subbank_r <= cand_req_size_subbank;
            alloc_cand_shared_r <= cand_req_shared;
            alloc_cand_sram_id_r <= search_sram_id;
            alloc_cand_bank_id_r <= search_bank_id;
            alloc_cand_subbank_start_r <= search_subbank_start;
            alloc_cand_group_len_r <= cand_req_size_subbank;

            if (search_found) begin
                // 真正命中时，把连续区间标成占用，并写入 entry 元数据。
                search_flat_i = (search_sram_id * `SRAM_BANK_NUM) + search_bank_id;
                for (clear_i = 0; clear_i < cand_req_size_subbank; clear_i = clear_i + 1) begin
                    free_bitmap[search_flat_i][search_subbank_start + clear_i] <= 1'b0;
                    entry_req_id[search_flat_i][search_subbank_start + clear_i] <= cand_req_req_id;
                    entry_branch_id[search_flat_i][search_subbank_start + clear_i] <= cand_req_branch_id;
                    entry_branch_mask[search_flat_i]
                                     [search_subbank_start + clear_i] <=
                        ((cand_req_shared && ENABLE_SHARED_PREFIX_FREEZE) ?
                            (search_reuse ?
                                (entry_branch_mask[search_flat_i]
                                                  [search_subbank_start + clear_i] |
                                 branch_onehot(cand_req_branch_id)) :
                                branch_onehot(cand_req_branch_id)) :
                            branch_onehot(cand_req_branch_id));
                    entry_node_id[search_flat_i][search_subbank_start + clear_i] <= cand_req_node_id;
                    entry_shared[search_flat_i][search_subbank_start + clear_i] <= cand_req_shared;
                end

                if (!search_reuse) begin
                    // 只有新分配而非复用时，才推进轮转游标。
                    next_flat_i = search_flat_i;
                    next_pos_i = search_subbank_start + cand_req_size_subbank;
                    if (next_pos_i >= `SUBBANK_NUM_PER_BANK) begin
                        // 当前 bank 放不下更多连续空间时，游标跳到下一个逻辑 bank。
                        next_pos_i = 0;
                        if ((ENABLE_TOPOLOGY_AWARE_MAPPING || ENABLE_SHARED_PREFIX_FREEZE) &&
                            cand_req_shared) begin
                            next_logical_i =
                                ((search_sram_id * SHARED_BANKS_PER_SRAM) +
                                 search_bank_id + 1) %
                                TOTAL_SHARED_BANKS;
                            next_flat_i = shared_logical_to_flat(next_logical_i);
                        end else if ((ENABLE_TOPOLOGY_AWARE_MAPPING ||
                                      ENABLE_BRANCH_ISOLATION) &&
                                     !cand_req_shared) begin
                            next_logical_i =
                                ((search_sram_id * PRIVATE_BANKS_PER_BRANCH) +
                                 (search_bank_id - private_base_bank(branch_idx_i)) +
                                 1) %
                                TOTAL_PRIVATE_BANKS_PER_BRANCH;
                            next_flat_i =
                                private_logical_to_flat(branch_idx_i, next_logical_i);
                        end else begin
                            next_flat_i = (search_flat_i + 1) % TOTAL_BANKS;
                        end
                    end

                    if ((ENABLE_TOPOLOGY_AWARE_MAPPING || ENABLE_SHARED_PREFIX_FREEZE) &&
                        cand_req_shared) begin
                        // 更新 shared 域游标。
                        shared_cursor_sram <= next_flat_i / `SRAM_BANK_NUM;
                        shared_cursor_bank <= next_flat_i % `SRAM_BANK_NUM;
                        shared_cursor_subbank <= next_pos_i[`SUBBANK_ID_W-1:0];
                    end else if ((ENABLE_TOPOLOGY_AWARE_MAPPING ||
                                  ENABLE_BRANCH_ISOLATION) &&
                                 !cand_req_shared) begin
                        // 更新当前 branch 的私有域游标。
                        private_cursor_sram[branch_idx_i] <=
                            next_flat_i / `SRAM_BANK_NUM;
                        private_cursor_bank[branch_idx_i] <=
                            next_flat_i % `SRAM_BANK_NUM;
                        private_cursor_subbank[branch_idx_i] <=
                            next_pos_i[`SUBBANK_ID_W-1:0];
                    end else begin
                        // 更新全局通用游标。
                        cursor_sram <= next_flat_i / `SRAM_BANK_NUM;
                        cursor_bank <= next_flat_i % `SRAM_BANK_NUM;
                        cursor_subbank <= next_pos_i[`SUBBANK_ID_W-1:0];
                    end
                end
            end
        end
    end
end

endmodule
