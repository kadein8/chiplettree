`timescale 1ns/1ps

`include "config/prediction_params.vh"
`include "config/interface_params.vh"
`include "config/memory_params.vh"
`include "config/model_params.vh"

/*
 * 文件作用：
 * 1. 这是 strict tree-mask 论文主链里的正式 `PE arrays` 容器。
 * 2. 它位于：
 *      StrictTreeMaskPaperIssueScheduler / compute descriptor
 *          -> PaperPeArrays16x128Mesh
 *          -> request_controller(issue)
 *          -> sram_subsystem
 *          -> request_controller(resp regroup)
 *          -> multicast_network
 *          -> readout / comparator
 *    这一段论文后端边界上。
 * 3. 当前实现严格按用户刚刚裁定的“方案2”推进：
 *    - 固定采用 `4x4` 的 2D wavefront mesh；
 *    - 不再使用“一个 slot 固定绑一整行 PE，整行同步广播”的方案1语义；
 *    - 改为 mesh phase 驱动的波前推进，slot payload 在列推进过程中跨行流动。
 * 4. 当前阶段仍然先把 ownership、握手和 mesh 时序边界收紧：
 *    - compute descriptor -> vec_req
 *    - vec_req -> request_controller -> sram_subsystem
 *    - sram_subsystem -> request_controller(resp regroup) -> multicast -> mc_resp
 *    - mc_resp -> readout/comparator result
 *    真正 128-MAC 的精细数值核以后继续收进这个容器内部。
 * 5. 后续就算继续替换数值 datapath，也不能把 strict 主链回退成旧 batch shortcut。
 */
module PaperPeArrays16x128Mesh #(
    parameter integer PRIVATE_DEPTH_W =
        (((`MAX_VERIFY_NODES_PER_BRANCH + 1) <= 2) ? 1 :
         $clog2(`MAX_VERIFY_NODES_PER_BRANCH + 1)),
    parameter integer DEPTH_PACK_W = (`BRANCH_NUM * PRIVATE_DEPTH_W),
    parameter integer PE_ROWS = 4,
    parameter integer PE_COLS = 4,
    parameter integer MACS_PER_PE = 128
) (
    input                             clk,
    input                             rst_n,

    /*
     * formal compute descriptor 输入边界。
     * 这一套 bundle 由 StrictTreeMaskPaperIssueScheduler 冻结并组装完成，
     * 当前模块只能消费它，不能回头去碰旧的 batch flatten 逻辑。
     */
    input                             issue_bundle_valid,
    output                            issue_bundle_ready,
    input      [`REQ_ID_W-1:0]        issue_bundle_req_id,
    input      [`TREE_FRONTIER_SLOTS-1:0] issue_bundle_slot_valid,
    input      [`TREE_FRONTIER_SLOTS-1:0] issue_bundle_slot_lookup_hit,
    input      [`TREE_FRONTIER_SLOTS*`TOKEN_ID_W-1:0]
               issue_bundle_token_id,
    input      [`TREE_FRONTIER_SLOTS*`POSITION_ID_W-1:0]
               issue_bundle_position_id,
    input      [`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0]
               issue_bundle_node_id,
    input      [`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0]
               issue_bundle_parent_node_id,
    input      [`TREE_FRONTIER_SLOTS*`BRANCH_ID_W-1:0]
               issue_bundle_branch_id,
    input      [`TREE_LEVEL_ID_W-1:0]  issue_bundle_level_id,
    input      [4:0]                  issue_bundle_slot_count,
    input      [15:0]                 issue_bundle_prefix_len,
    input      [`TREE_FRONTIER_SLOTS-1:0] issue_bundle_slot_tree_mask_en,
    input      [`TREE_FRONTIER_SLOTS*`MODEL_MAX_POS_EMB-1:0]
               issue_bundle_slot_visible_mask,
    input      [`TREE_FRONTIER_SLOTS*PRIVATE_DEPTH_W-1:0]
               issue_bundle_private_depth,
    input      [`TREE_FRONTIER_SLOTS*`SRAM_ID_W-1:0]
               issue_bundle_sram_id,
    input      [`TREE_FRONTIER_SLOTS*`BANK_ID_W-1:0]
               issue_bundle_bank_id,
    input      [`TREE_FRONTIER_SLOTS*`SUBBANK_ID_W-1:0]
               issue_bundle_subbank_start,
    input      [`TREE_FRONTIER_SLOTS*`KV_GROUP_LEN_W-1:0]
               issue_bundle_group_len,
    input      [`TREE_FRONTIER_SLOTS*`BRANCH_MASK_W-1:0]
               issue_bundle_branch_mask,
    input      [`TREE_FRONTIER_SLOTS-1:0] issue_bundle_is_shared,
    input      [`TREE_FRONTIER_SLOTS*`TOKEN_STATE_W-1:0]
               issue_bundle_entry_state,
    input      [`TREE_FRONTIER_SLOTS*`TOKEN_ENTRY_TYPE_W-1:0]
               issue_bundle_entry_type,
    input      [`SRAM_ADDR_W-1:0]      issue_bundle_embedding_base_addr,
    input      [`SRAM_ADDR_W-1:0]      issue_bundle_hidden0_base_addr,
    input      [`SRAM_ADDR_W-1:0]      issue_bundle_hidden1_base_addr,
    input      [`SRAM_ADDR_W-1:0]      issue_bundle_final_base_addr,
    input      [`SRAM_ADDR_W-1:0]      issue_bundle_weight_sram_base_addr,
    input      [`SRAM_ADDR_W-1:0]      issue_bundle_kv_cache_base_addr,
    input      [`SRAM_ADDR_W-1:0]      issue_bundle_draft_kv_base_addr,
    input      [`HBM_ADDR_W-1:0]       issue_bundle_hbm_weight_base_addr,
    input      [`SRAM_ADDR_W-1:0]      issue_bundle_final_norm_gamma_addr,
    input      [`SRAM_ADDR_W-1:0]      issue_bundle_lm_head_weight_base_addr,

    /*
     * 对 request_controller 的正式 vector 请求边界。
     * 方案2里每个 vec lane 现在代表一个 mesh cell，而不是一个 slot 或一整行 slot。
     */
    output     [`MEM_REQ_LANES-1:0]   vec_req_valid,
    input      [`MEM_REQ_LANES-1:0]   vec_req_ready,
    output     [`MEM_REQ_LANES-1:0]   vec_req_write,
    output     [`MEM_REQ_LANES*`SRAM_ADDR_W-1:0] vec_req_addr,
    output     [`MEM_REQ_LANES*`SRAM_WDATA_W-1:0] vec_req_wdata,
    output     [`MEM_REQ_LANES*`REQ_ID_W-1:0] vec_req_req_id,
    output     [`MEM_REQ_LANES*`PE_MASK_W-1:0] vec_req_pe_mask,
    output     [`MEM_REQ_LANES*`REQ_PRIORITY_W-1:0] vec_req_priority,
    output     [`MEM_REQ_LANES*`BANK_ID_W-1:0] vec_req_bank_id,
    output     [`MEM_REQ_LANES*`SUBBANK_ID_W-1:0] vec_req_subbank_id,

    /*
     * multicast_network 返回的 per-PE 响应。
     * 当前 phase 只对正在飞的 mesh cell 拉 ready，避免旧响应穿越到错误 phase。
     */
    input      [`PE_MASK_W-1:0]       mc_resp_valid,
    output     [`PE_MASK_W-1:0]       mc_resp_ready,
    input      [`PE_MASK_W*`SRAM_RDATA_W-1:0] mc_resp_rdata,
    input      [`PE_MASK_W*`REQ_ID_W-1:0] mc_resp_req_id,
    input      [`PE_MASK_W*`PE_MASK_W-1:0] mc_resp_pe_mask,
    input      [`PE_MASK_W-1:0]       mc_resp_last,

    /*
     * 方案2冻结后的正式结果边界：
     * PE arrays 只允许输出 hidden/logits tile，
     * token readout / comparator 必须放到更外层。
     */
    output                            tile_result_valid,
    output     [`REQ_ID_W-1:0]        tile_result_req_id,
    output     [`BRANCH_NUM-1:0]      tile_result_slot_valid,
    output     [`BRANCH_NUM*`BRANCH_ID_W-1:0] tile_result_branch_id,
    output     [DEPTH_PACK_W-1:0]     tile_result_private_depth,
    output     [`BRANCH_NUM*`NODE_ID_W-1:0] tile_result_node_id,
    output     [`BRANCH_NUM*`NODE_ID_W-1:0] tile_result_parent_node_id,
    output     [1:0]                  tile_result_kind,
    output     [15:0]                 tile_result_tile_index,
    output     [`BRANCH_NUM-1:0]      tile_result_last,
    output     [`BRANCH_NUM*`SRAM_RDATA_W-1:0] tile_result_data,

    output                            busy
);

localparam integer PE_TOTAL = (PE_ROWS * PE_COLS);
localparam integer SLOT_IDX_W =
    ((`TREE_FRONTIER_SLOTS <= 2) ? 1 : $clog2(`TREE_FRONTIER_SLOTS));
localparam integer PE_COL_W =
    ((PE_COLS <= 2) ? 1 : $clog2(PE_COLS));
localparam integer FP16_ELEMS_PER_BEAT = (`SRAM_RDATA_W / `FP16_TILE_DATA_W);
localparam integer MODEL_VECTOR_BEATS =
    ((`MODEL_DMODEL + FP16_ELEMS_PER_BEAT - 1) / FP16_ELEMS_PER_BEAT);
localparam integer MODEL_MAC_TILE_BEATS =
    ((MACS_PER_PE + FP16_ELEMS_PER_BEAT - 1) / FP16_ELEMS_PER_BEAT);
localparam integer MODEL_MAC_TILE_BEAT_W =
    ((MODEL_MAC_TILE_BEATS <= 2) ? 1 : $clog2(MODEL_MAC_TILE_BEATS));
localparam integer MODEL_K_TILE_COUNT =
    ((`MODEL_DMODEL + MACS_PER_PE - 1) / MACS_PER_PE);
localparam integer MESH_K_ITER_COUNT =
    ((MODEL_K_TILE_COUNT + PE_COLS - 1) / PE_COLS);
localparam integer MESH_K_ITER_W =
    ((MESH_K_ITER_COUNT <= 2) ? 1 : $clog2(MESH_K_ITER_COUNT));
localparam [`SRAM_ADDR_W-1:0] MODEL_VECTOR_BEATS_ADDR =
    `SRAM_ADDR_W'(MODEL_VECTOR_BEATS);
localparam [`SRAM_ADDR_W-1:0] MODEL_MAC_TILE_BEATS_ADDR =
    `SRAM_ADDR_W'(MODEL_MAC_TILE_BEATS);
localparam integer ROW_LSB = `OFFSET_W;
localparam integer SUBBANK_LSB = (ROW_LSB + `ROW_ADDR_W);
localparam integer BANK_LSB = (SUBBANK_LSB + `SUBBANK_ID_W);
localparam [2:0] LAST_PHASE = 3'(PE_COLS - 1);
localparam [MESH_K_ITER_W-1:0] LAST_MESH_K_ITER =
    MESH_K_ITER_W'(MESH_K_ITER_COUNT - 1);
localparam [MODEL_MAC_TILE_BEAT_W-1:0] LAST_MODEL_MAC_TILE_BEAT =
    MODEL_MAC_TILE_BEAT_W'(MODEL_MAC_TILE_BEATS - 1);
localparam [`REQ_PRIORITY_W-1:0] PAPER_REQ_PRIORITY = {`REQ_PRIORITY_W{1'b0}};
localparam [1:0] TILE_KIND_HIDDEN = 2'd0;
localparam [1:0] TILE_KIND_LOGITS = 2'd1;

/*
 * 当前 phase 下 mesh 上哪些 cell 需要发请求。
 * 方案2的关键点就在这三个组合量：
 * 1. `phase_cell_valid_c`：这一拍有哪些 PE cell 被当前 wavefront 占用；
 * 2. `phase_slot_idx_flat_c`：每个 cell 当前承载的是哪个 slot 的 payload；
 * 3. `phase_local_col_flat_c`：这个 payload 当前处于 mesh 的第几列，也就是第几个列内切片阶段。
 */
reg [`PE_MASK_W-1:0] phase_cell_valid_c;
reg [(`PE_MASK_W*SLOT_IDX_W)-1:0] phase_slot_idx_flat_c;
reg [(`PE_MASK_W*PE_COL_W)-1:0] phase_local_col_flat_c;

/*
 * `mesh_phase_r` / `mesh_k_tile_r`：
 * - `mesh_phase_r` 表示当前 wavefront 已推进到第几个列阶段；
 * - `mesh_k_tile_r` 表示当前 bundle 正在进行第几轮 K 维 tile sweep；
 * - phase 0 只点亮第 0 列；
 * - phase 1 点亮第 0/1 列；
 * - phase 3 时 4 列全部点亮，此时整个 4x4 mesh 全忙；
 * - 若模型维度大于单轮 `PE_COLS * MACS_PER_PE`，则 phase 0..3 会重复多轮。
 */
reg [2:0] mesh_phase_r;
reg [MESH_K_ITER_W-1:0] mesh_k_tile_r;
reg [MODEL_MAC_TILE_BEAT_W-1:0] mesh_tile_beat_r;
reg phase_inflight_r;
reg [`PE_MASK_W-1:0] phase_resp_mask_r;
reg [`PE_MASK_W-1:0] next_phase_resp_mask_c;
reg phase_output_pending_r;
reg [PE_COL_W-1:0] phase_output_col_cursor_r;
reg [PE_COLS-1:0] phase_output_col_valid_r;

reg bundle_pending_r;
reg tile_result_valid_r;

/*
 * 下面这批 pending_* 是当前 strict bundle 在 mesh 内飞行期间锁住的论文元数据。
 * 任何 phase 都只能消费这些锁存值，不能回读上游的新 bundle。
 */
reg [`REQ_ID_W-1:0] pending_req_id_r;
reg [`TREE_FRONTIER_SLOTS-1:0] pending_slot_valid_r;
reg [`TREE_FRONTIER_SLOTS*`TOKEN_ID_W-1:0] pending_token_id_r;
reg [`TREE_FRONTIER_SLOTS*`POSITION_ID_W-1:0] pending_position_id_r;
reg [`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0] pending_node_id_r;
reg [`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0] pending_parent_node_id_r;
reg [`TREE_FRONTIER_SLOTS*`BRANCH_ID_W-1:0] pending_branch_id_r;
reg [`TREE_FRONTIER_SLOTS*PRIVATE_DEPTH_W-1:0] pending_private_depth_r;
reg [`TREE_FRONTIER_SLOTS*`SRAM_ID_W-1:0] pending_sram_id_r;
reg [`TREE_FRONTIER_SLOTS*`BANK_ID_W-1:0] pending_bank_id_r;
reg [`TREE_FRONTIER_SLOTS*`SUBBANK_ID_W-1:0] pending_subbank_start_r;
reg [`TREE_FRONTIER_SLOTS*`KV_GROUP_LEN_W-1:0] pending_group_len_r;
reg [`TREE_FRONTIER_SLOTS*`BRANCH_MASK_W-1:0] pending_branch_mask_r;
reg [`TREE_FRONTIER_SLOTS-1:0] pending_is_shared_r;
reg [`TREE_FRONTIER_SLOTS*`TOKEN_STATE_W-1:0] pending_entry_state_r;
reg [`TREE_FRONTIER_SLOTS*`TOKEN_ENTRY_TYPE_W-1:0] pending_entry_type_r;
reg [`TREE_LEVEL_ID_W-1:0] pending_level_id_r;
reg [15:0] pending_prefix_len_r;
reg [`TREE_FRONTIER_SLOTS-1:0] pending_slot_tree_mask_en_r;
reg [`TREE_FRONTIER_SLOTS*`MODEL_MAX_POS_EMB-1:0] pending_slot_visible_mask_r;
reg [`SRAM_ADDR_W-1:0] pending_embedding_base_addr_r;
reg [`SRAM_ADDR_W-1:0] pending_hidden0_base_addr_r;
reg [`SRAM_ADDR_W-1:0] pending_hidden1_base_addr_r;
reg [`SRAM_ADDR_W-1:0] pending_final_base_addr_r;
reg [`SRAM_ADDR_W-1:0] pending_weight_sram_base_addr_r;
reg [`SRAM_ADDR_W-1:0] pending_kv_cache_base_addr_r;
reg [`SRAM_ADDR_W-1:0] pending_draft_kv_base_addr_r;
reg [`HBM_ADDR_W-1:0] pending_hbm_weight_base_addr_r;
reg [`SRAM_ADDR_W-1:0] pending_final_norm_gamma_addr_r;
reg [`SRAM_ADDR_W-1:0] pending_lm_head_weight_base_addr_r;

reg [`REQ_ID_W-1:0] tile_result_req_id_r;
reg [`BRANCH_NUM-1:0] tile_result_slot_valid_r;
reg [`BRANCH_NUM*`BRANCH_ID_W-1:0] tile_result_branch_id_r;
reg [DEPTH_PACK_W-1:0] tile_result_private_depth_r;
reg [`BRANCH_NUM*`NODE_ID_W-1:0] tile_result_node_id_r;
reg [`BRANCH_NUM*`NODE_ID_W-1:0] tile_result_parent_node_id_r;
reg [1:0] tile_result_kind_r;
reg [15:0] tile_result_tile_index_r;
reg [`BRANCH_NUM-1:0] tile_result_last_r;
reg [`BRANCH_NUM*`SRAM_RDATA_W-1:0] tile_result_data_r;
reg [(PE_COLS*`BRANCH_NUM)-1:0] phase_output_slot_valid_by_col_r;
reg [(PE_COLS*`BRANCH_NUM*`BRANCH_ID_W)-1:0] phase_output_branch_id_by_col_r;
reg [(PE_COLS*DEPTH_PACK_W)-1:0] phase_output_private_depth_by_col_r;
reg [(PE_COLS*`BRANCH_NUM*`NODE_ID_W)-1:0] phase_output_node_id_by_col_r;
reg [(PE_COLS*`BRANCH_NUM*`NODE_ID_W)-1:0]
    phase_output_parent_node_id_by_col_r;
reg [(PE_COLS*16)-1:0] phase_output_tile_index_by_col_r;
reg [(PE_COLS*`BRANCH_NUM)-1:0] phase_output_last_by_col_r;
reg [(PE_COLS*`BRANCH_NUM*`SRAM_RDATA_W)-1:0] phase_output_data_by_col_r;

reg [`MEM_REQ_LANES-1:0] vec_req_valid_r;
reg [`MEM_REQ_LANES-1:0] vec_req_write_r;
reg [`MEM_REQ_LANES*`SRAM_ADDR_W-1:0] vec_req_addr_r;
reg [`MEM_REQ_LANES*`SRAM_WDATA_W-1:0] vec_req_wdata_r;
reg [`MEM_REQ_LANES*`REQ_ID_W-1:0] vec_req_req_id_r;
reg [`MEM_REQ_LANES*`PE_MASK_W-1:0] vec_req_pe_mask_r;
reg [`MEM_REQ_LANES*`REQ_PRIORITY_W-1:0] vec_req_priority_r;
reg [`MEM_REQ_LANES*`BANK_ID_W-1:0] vec_req_bank_id_r;
reg [`MEM_REQ_LANES*`SUBBANK_ID_W-1:0] vec_req_subbank_id_r;

reg [`SRAM_ADDR_W-1:0] phase_compute_base_addr_c;
reg [`SRAM_ADDR_W-1:0] embedding_token_offset_comb;
reg [`SRAM_ADDR_W-1:0] slot_workspace_offset_comb;
reg [`SRAM_ADDR_W-1:0] phase_tile_offset_comb;
reg [`SRAM_ADDR_W-1:0] embedding_token_base_addr_comb;
reg [`SRAM_ADDR_W-1:0] slot_workspace_base_addr_comb;
reg [`SRAM_ADDR_W-1:0] phase_tile_base_addr_comb;
wire issue_bundle_accept_w;
wire phase_launch_fire_w;
wire [`TREE_FRONTIER_SLOTS-1:0] accepted_slot_mask_w;

integer slot_i;
integer col_i;
integer lane_i;
integer slot_wave_row;
integer slot_idx_i;
integer local_col_i;
integer resp_i;
integer global_k_tile_i;
reg [`SRAM_ADDR_W-1:0] cell_addr_comb;

assign accepted_slot_mask_w =
    issue_bundle_slot_valid & issue_bundle_slot_lookup_hit;

/*
 * 方案2下，上游 ready 只取决于当前 mesh 是否空闲。
 * 一旦 bundle 被接住，后续 phase 推进完全在 mesh 内部完成。
 */
assign issue_bundle_ready = !bundle_pending_r && !phase_inflight_r;
assign issue_bundle_accept_w = issue_bundle_valid && issue_bundle_ready;

assign tile_result_valid = tile_result_valid_r;
assign tile_result_req_id = tile_result_req_id_r;
assign tile_result_slot_valid = tile_result_slot_valid_r;
assign tile_result_branch_id = tile_result_branch_id_r;
assign tile_result_private_depth = tile_result_private_depth_r;
assign tile_result_node_id = tile_result_node_id_r;
assign tile_result_parent_node_id = tile_result_parent_node_id_r;
assign tile_result_kind = tile_result_kind_r;
assign tile_result_tile_index = tile_result_tile_index_r;
assign tile_result_last = tile_result_last_r;
assign tile_result_data = tile_result_data_r;
assign mc_resp_ready = phase_resp_mask_r;
assign busy = bundle_pending_r || phase_inflight_r;

assign vec_req_valid = vec_req_valid_r;
assign vec_req_write = vec_req_write_r;
assign vec_req_addr = vec_req_addr_r;
assign vec_req_wdata = vec_req_wdata_r;
assign vec_req_req_id = vec_req_req_id_r;
assign vec_req_pe_mask = vec_req_pe_mask_r;
assign vec_req_priority = vec_req_priority_r;
assign vec_req_bank_id = vec_req_bank_id_r;
assign vec_req_subbank_id = vec_req_subbank_id_r;

/*
 * `phase_compute_base_addr_c`：
 * - 用 formal compute descriptor 里的 base addr 给 mesh phase 定义正式的阶段语义；
 * - phase0 视为 embedding/read stage；
 * - phase1/2 视为 hidden tile stage；
 * - phase3 视为 final reduce/readout stage；
 * - 它只描述“当前 phase 访问哪一类向量区”，具体 tile 偏移在 vec_req 公式里单独计算。
 */
always @* begin
    case (mesh_phase_r)
        3'd0: phase_compute_base_addr_c = pending_embedding_base_addr_r;
        3'd1: phase_compute_base_addr_c = pending_hidden0_base_addr_r;
        3'd2: phase_compute_base_addr_c = pending_hidden1_base_addr_r;
        default: phase_compute_base_addr_c = pending_final_base_addr_r;
    endcase
end

/*
 * 这个组合块是方案2的核心：
 * - 对每个 active slot；
 * - 对当前 phase 已经打开的每一列；
 * - 计算它在 mesh 上落在哪一行。
 *
 * 关键公式：
 *     slot_wave_row = (slot_i + mesh_phase_r - col_i)
 *
 * 这意味着同一个 slot 在列推进过程中会跨行流动，而不是永久绑在某一行上。
 * 当 phase 递增时，mesh 上会形成真正的 grow-to-full 4x4 wavefront。
 */
always @* begin
    phase_cell_valid_c = {`PE_MASK_W{1'b0}};
    phase_slot_idx_flat_c = {(`PE_MASK_W*SLOT_IDX_W){1'b0}};
    phase_local_col_flat_c = {(`PE_MASK_W*PE_COL_W){1'b0}};

    for (slot_i = 0; slot_i < `TREE_FRONTIER_SLOTS; slot_i = slot_i + 1) begin
        if (pending_slot_valid_r[slot_i] && (slot_i < PE_ROWS)) begin
            for (col_i = 0; col_i < PE_COLS; col_i = col_i + 1) begin
                global_k_tile_i = (mesh_k_tile_r * PE_COLS) + col_i;
                if ((mesh_phase_r >= col_i[2:0]) &&
                    (global_k_tile_i < MODEL_K_TILE_COUNT)) begin
                    slot_wave_row = slot_i + {{29{1'b0}}, mesh_phase_r};
                    slot_wave_row = slot_wave_row - col_i;
                    while (slot_wave_row >= PE_ROWS) begin
                        slot_wave_row = slot_wave_row - PE_ROWS;
                    end
                    lane_i = (slot_wave_row * PE_COLS) + col_i;
                    if (lane_i < `PE_MASK_W) begin
                        phase_cell_valid_c[lane_i] = 1'b1;
                        phase_slot_idx_flat_c[
                            (lane_i*SLOT_IDX_W) +: SLOT_IDX_W] =
                            slot_i[SLOT_IDX_W-1:0];
                        phase_local_col_flat_c[
                            (lane_i*PE_COL_W) +: PE_COL_W] =
                            col_i[PE_COL_W-1:0];
                    end
                end
            end
        end
    end
end

/*
 * vec_req 生成：
 * - 每个 mesh cell 对应一个 vec lane；
 * - 当前 phase 只有 active cell 才发请求；
 * - pe_mask 变成“单个 PE cell”的 one-hot，而不是方案1里的整行广播。
 */
always @* begin
    vec_req_valid_r = {`MEM_REQ_LANES{1'b0}};
    vec_req_write_r = {`MEM_REQ_LANES{1'b0}};
    vec_req_addr_r = {(`MEM_REQ_LANES*`SRAM_ADDR_W){1'b0}};
    vec_req_wdata_r = {(`MEM_REQ_LANES*`SRAM_WDATA_W){1'b0}};
    vec_req_req_id_r = {(`MEM_REQ_LANES*`REQ_ID_W){1'b0}};
    vec_req_pe_mask_r = {(`MEM_REQ_LANES*`PE_MASK_W){1'b0}};
    vec_req_priority_r = {(`MEM_REQ_LANES*`REQ_PRIORITY_W){1'b0}};
    vec_req_bank_id_r = {(`MEM_REQ_LANES*`BANK_ID_W){1'b0}};
    vec_req_subbank_id_r = {(`MEM_REQ_LANES*`SUBBANK_ID_W){1'b0}};

    if (bundle_pending_r && !phase_inflight_r) begin
        for (lane_i = 0; lane_i < `MEM_REQ_LANES; lane_i = lane_i + 1) begin
            if (phase_cell_valid_c[lane_i]) begin
                slot_idx_i = {{(32-SLOT_IDX_W){1'b0}},
                    phase_slot_idx_flat_c[
                        (lane_i*SLOT_IDX_W) +: SLOT_IDX_W]};
                local_col_i = {{(32-PE_COL_W){1'b0}},
                    phase_local_col_flat_c[
                        (lane_i*PE_COL_W) +: PE_COL_W]};
                global_k_tile_i = (mesh_k_tile_r * PE_COLS) + local_col_i;

                /*
                 * 正式 tile-aware 地址公式：
                 * 1. embedding phase：`token_id -> embedding vector`；
                 * 2. hidden/final phase：`slot_id -> workspace vector`；
                 * 3. 所有 phase 统一再叠加 K 维 tile 列偏移。
                 *
                 * 这里故意不再把 visible/state/shared 等 metadata 混入地址，
                 * 这些字段只保留给后续数值核与比较/生命周期语义使用。
                 */
                embedding_token_offset_comb =
                    `SRAM_ADDR_W'(
                        {{(`SRAM_ADDR_W-`TOKEN_ID_W){1'b0}},
                         pending_token_id_r[
                             (slot_idx_i*`TOKEN_ID_W) +: `TOKEN_ID_W]} *
                        MODEL_VECTOR_BEATS_ADDR);
                embedding_token_base_addr_comb =
                    pending_embedding_base_addr_r +
                    embedding_token_offset_comb;

                slot_workspace_offset_comb =
                    `SRAM_ADDR_W'(slot_idx_i * MODEL_VECTOR_BEATS_ADDR);
                slot_workspace_base_addr_comb =
                    phase_compute_base_addr_c +
                    slot_workspace_offset_comb;

                phase_tile_offset_comb =
                    `SRAM_ADDR_W'(
                        global_k_tile_i * MODEL_MAC_TILE_BEATS_ADDR);
                phase_tile_base_addr_comb =
                    ((mesh_phase_r == 3'd0) ?
                        embedding_token_base_addr_comb :
                        slot_workspace_base_addr_comb) +
                    phase_tile_offset_comb;

                cell_addr_comb = phase_tile_base_addr_comb +
                    `SRAM_ADDR_W'(mesh_tile_beat_r);

                vec_req_valid_r[lane_i] = 1'b1;
                vec_req_addr_r[
                    (lane_i*`SRAM_ADDR_W) +: `SRAM_ADDR_W] = cell_addr_comb;
                vec_req_req_id_r[
                    (lane_i*`REQ_ID_W) +: `REQ_ID_W] =
                    pending_req_id_r +
                    lane_i[`REQ_ID_W-1:0] +
                    {{(`REQ_ID_W-1){1'b0}}, 1'b1};
                vec_req_pe_mask_r[
                    (lane_i*`PE_MASK_W) +: `PE_MASK_W] =
                    ({{(`PE_MASK_W-1){1'b0}}, 1'b1} << lane_i);
                vec_req_priority_r[
                    (lane_i*`REQ_PRIORITY_W) +: `REQ_PRIORITY_W] =
                    PAPER_REQ_PRIORITY;
                vec_req_bank_id_r[
                    (lane_i*`BANK_ID_W) +: `BANK_ID_W] =
                    cell_addr_comb[
                        BANK_LSB +: `BANK_ID_W];
                vec_req_subbank_id_r[
                    (lane_i*`SUBBANK_ID_W) +: `SUBBANK_ID_W] =
                    cell_addr_comb[
                        SUBBANK_LSB +: `SUBBANK_ID_W];
            end
        end
    end
end

/*
 * 当前 phase 能否 launch：
 * - 只有 mesh 里还没有在飞响应；
 * - 并且这一 phase 需要的所有 active vec lane 都 ready；
 * - 才允许把波前推进到下一个 in-flight 阶段；
 * - phase 之间的推进粒度仍然是“整批 active cells 同发同收”，不破坏论文的并行拍语义。
 */
assign phase_launch_fire_w =
    bundle_pending_r &&
    !phase_inflight_r &&
    !phase_output_pending_r &&
    ((phase_cell_valid_c & (~vec_req_ready)) == {`MEM_REQ_LANES{1'b0}});

/*
 * 当前 phase 的响应 drain 掩码。
 * 哪个 PE cell 的响应回来了，就把对应 bit 清掉；
 * 只有整个当前 phase 全部 drain 完，wavefront 才能继续向下一 phase 推。
 */
always @* begin
    next_phase_resp_mask_c = phase_resp_mask_r;
    for (resp_i = 0; resp_i < `PE_MASK_W; resp_i = resp_i + 1) begin
        if (mc_resp_valid[resp_i] && phase_resp_mask_r[resp_i]) begin
            next_phase_resp_mask_c[resp_i] = 1'b0;
        end
    end
end

/*
 * 主时序块：
 * 1. 接住新 bundle，锁存 formal descriptor；
 * 2. 按 phase 0 -> 1 -> 2 -> 3 推进 wavefront；
 * 3. 若单轮列数不够覆盖全部 K 维 tile，则继续推进下一轮 `mesh_k_tile_r`；
 * 4. 每个 phase 等待自己那一批 mesh cell 的响应全部退休；
 * 5. 只有最后一轮 K sweep 的最后一列 phase，才把 comparator 需要的结构结果收出来。
 */
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        mesh_phase_r <= 3'd0;
        mesh_k_tile_r <= {MESH_K_ITER_W{1'b0}};
        mesh_tile_beat_r <= {MODEL_MAC_TILE_BEAT_W{1'b0}};
        phase_inflight_r <= 1'b0;
        phase_resp_mask_r <= {`PE_MASK_W{1'b0}};
        phase_output_pending_r <= 1'b0;
        phase_output_col_cursor_r <= {PE_COL_W{1'b0}};
        phase_output_col_valid_r <= {PE_COLS{1'b0}};
        bundle_pending_r <= 1'b0;
        tile_result_valid_r <= 1'b0;
        pending_req_id_r <= {`REQ_ID_W{1'b0}};
        pending_slot_valid_r <= {`TREE_FRONTIER_SLOTS{1'b0}};
        pending_token_id_r <= {(`TREE_FRONTIER_SLOTS*`TOKEN_ID_W){1'b0}};
        pending_position_id_r <=
            {(`TREE_FRONTIER_SLOTS*`POSITION_ID_W){1'b0}};
        pending_node_id_r <= {(`TREE_FRONTIER_SLOTS*`NODE_ID_W){1'b0}};
        pending_parent_node_id_r <=
            {(`TREE_FRONTIER_SLOTS*`NODE_ID_W){1'b0}};
        pending_branch_id_r <= {(`TREE_FRONTIER_SLOTS*`BRANCH_ID_W){1'b0}};
        pending_private_depth_r <=
            {(`TREE_FRONTIER_SLOTS*PRIVATE_DEPTH_W){1'b0}};
        pending_sram_id_r <= {(`TREE_FRONTIER_SLOTS*`SRAM_ID_W){1'b0}};
        pending_bank_id_r <= {(`TREE_FRONTIER_SLOTS*`BANK_ID_W){1'b0}};
        pending_subbank_start_r <=
            {(`TREE_FRONTIER_SLOTS*`SUBBANK_ID_W){1'b0}};
        pending_group_len_r <=
            {(`TREE_FRONTIER_SLOTS*`KV_GROUP_LEN_W){1'b0}};
        pending_branch_mask_r <=
            {(`TREE_FRONTIER_SLOTS*`BRANCH_MASK_W){1'b0}};
        pending_is_shared_r <= {`TREE_FRONTIER_SLOTS{1'b0}};
        pending_entry_state_r <=
            {(`TREE_FRONTIER_SLOTS*`TOKEN_STATE_W){1'b0}};
        pending_entry_type_r <=
            {(`TREE_FRONTIER_SLOTS*`TOKEN_ENTRY_TYPE_W){1'b0}};
        pending_level_id_r <= {`TREE_LEVEL_ID_W{1'b0}};
        pending_prefix_len_r <= 16'd0;
        pending_slot_tree_mask_en_r <= {`TREE_FRONTIER_SLOTS{1'b0}};
        pending_slot_visible_mask_r <=
            {(`TREE_FRONTIER_SLOTS*`MODEL_MAX_POS_EMB){1'b0}};
        pending_embedding_base_addr_r <= {`SRAM_ADDR_W{1'b0}};
        pending_hidden0_base_addr_r <= {`SRAM_ADDR_W{1'b0}};
        pending_hidden1_base_addr_r <= {`SRAM_ADDR_W{1'b0}};
        pending_final_base_addr_r <= {`SRAM_ADDR_W{1'b0}};
        pending_weight_sram_base_addr_r <= {`SRAM_ADDR_W{1'b0}};
        pending_kv_cache_base_addr_r <= {`SRAM_ADDR_W{1'b0}};
        pending_draft_kv_base_addr_r <= {`SRAM_ADDR_W{1'b0}};
        pending_hbm_weight_base_addr_r <= {`HBM_ADDR_W{1'b0}};
        pending_final_norm_gamma_addr_r <= {`SRAM_ADDR_W{1'b0}};
        pending_lm_head_weight_base_addr_r <= {`SRAM_ADDR_W{1'b0}};
        tile_result_req_id_r <= {`REQ_ID_W{1'b0}};
        tile_result_slot_valid_r <= {`BRANCH_NUM{1'b0}};
        tile_result_branch_id_r <= {(`BRANCH_NUM*`BRANCH_ID_W){1'b0}};
        tile_result_private_depth_r <= {DEPTH_PACK_W{1'b0}};
        tile_result_node_id_r <= {(`BRANCH_NUM*`NODE_ID_W){1'b0}};
        tile_result_parent_node_id_r <= {(`BRANCH_NUM*`NODE_ID_W){1'b0}};
        tile_result_kind_r <= 2'd0;
        tile_result_tile_index_r <= 16'd0;
        tile_result_last_r <= {`BRANCH_NUM{1'b0}};
        tile_result_data_r <= {(`BRANCH_NUM*`SRAM_RDATA_W){1'b0}};
        phase_output_slot_valid_by_col_r <= {(PE_COLS*`BRANCH_NUM){1'b0}};
        phase_output_branch_id_by_col_r <=
            {(PE_COLS*`BRANCH_NUM*`BRANCH_ID_W){1'b0}};
        phase_output_private_depth_by_col_r <= {(PE_COLS*DEPTH_PACK_W){1'b0}};
        phase_output_node_id_by_col_r <=
            {(PE_COLS*`BRANCH_NUM*`NODE_ID_W){1'b0}};
        phase_output_parent_node_id_by_col_r <=
            {(PE_COLS*`BRANCH_NUM*`NODE_ID_W){1'b0}};
        phase_output_tile_index_by_col_r <= {(PE_COLS*16){1'b0}};
        phase_output_last_by_col_r <= {(PE_COLS*`BRANCH_NUM){1'b0}};
        phase_output_data_by_col_r <=
            {(PE_COLS*`BRANCH_NUM*`SRAM_RDATA_W){1'b0}};
    end else begin
        tile_result_valid_r <= 1'b0;

        if (phase_output_pending_r) begin
            tile_result_slot_valid_r <=
                phase_output_slot_valid_by_col_r[
                    (phase_output_col_cursor_r*`BRANCH_NUM) +:
                    `BRANCH_NUM];
            tile_result_branch_id_r <=
                phase_output_branch_id_by_col_r[
                    (phase_output_col_cursor_r*(`BRANCH_NUM*`BRANCH_ID_W)) +:
                    (`BRANCH_NUM*`BRANCH_ID_W)];
            tile_result_private_depth_r <=
                phase_output_private_depth_by_col_r[
                    (phase_output_col_cursor_r*DEPTH_PACK_W) +:
                    DEPTH_PACK_W];
            tile_result_node_id_r <=
                phase_output_node_id_by_col_r[
                    (phase_output_col_cursor_r*(`BRANCH_NUM*`NODE_ID_W)) +:
                    (`BRANCH_NUM*`NODE_ID_W)];
            tile_result_parent_node_id_r <=
                phase_output_parent_node_id_by_col_r[
                    (phase_output_col_cursor_r*(`BRANCH_NUM*`NODE_ID_W)) +:
                    (`BRANCH_NUM*`NODE_ID_W)];
            /*
             * 这里输出的是论文 PE arrays 直出的 raw hidden tile，而不是最终 logits。
             * 原因：
             * 1. 方案2已经冻结了 “mesh/backend 只吐 hidden/logits tile，token compare 外移”；
             * 2. 其中 hidden -> logits 的正式数值后处理 ownership 必须收敛到 postprocess；
             * 3. 因此 mesh 这一层在任何情况下都不能再把自己声明成 formal logits 边界。
             */
            tile_result_kind_r <= TILE_KIND_HIDDEN;
            tile_result_tile_index_r <=
                phase_output_tile_index_by_col_r[
                    (phase_output_col_cursor_r*16) +: 16];
            tile_result_last_r <=
                phase_output_last_by_col_r[
                    (phase_output_col_cursor_r*`BRANCH_NUM) +:
                    `BRANCH_NUM];
            tile_result_data_r <=
                phase_output_data_by_col_r[
                    (phase_output_col_cursor_r*(`BRANCH_NUM*`SRAM_RDATA_W)) +:
                    (`BRANCH_NUM*`SRAM_RDATA_W)];
            tile_result_valid_r <=
                phase_output_col_valid_r[phase_output_col_cursor_r];

            if (phase_output_col_cursor_r == PE_COL_W'(PE_COLS-1)) begin
                phase_output_pending_r <= 1'b0;
                phase_output_col_cursor_r <= {PE_COL_W{1'b0}};
                phase_output_col_valid_r <= {PE_COLS{1'b0}};
                phase_output_slot_valid_by_col_r <=
                    {(PE_COLS*`BRANCH_NUM){1'b0}};
                phase_output_branch_id_by_col_r <=
                    {(PE_COLS*`BRANCH_NUM*`BRANCH_ID_W){1'b0}};
                phase_output_private_depth_by_col_r <=
                    {(PE_COLS*DEPTH_PACK_W){1'b0}};
                phase_output_node_id_by_col_r <=
                    {(PE_COLS*`BRANCH_NUM*`NODE_ID_W){1'b0}};
                phase_output_parent_node_id_by_col_r <=
                    {(PE_COLS*`BRANCH_NUM*`NODE_ID_W){1'b0}};
                phase_output_tile_index_by_col_r <= {(PE_COLS*16){1'b0}};
                phase_output_last_by_col_r <= {(PE_COLS*`BRANCH_NUM){1'b0}};
                phase_output_data_by_col_r <=
                    {(PE_COLS*`BRANCH_NUM*`SRAM_RDATA_W){1'b0}};

                if (mesh_tile_beat_r == LAST_MODEL_MAC_TILE_BEAT) begin
                    mesh_tile_beat_r <= {MODEL_MAC_TILE_BEAT_W{1'b0}};
                    if (mesh_k_tile_r == LAST_MESH_K_ITER) begin
                        bundle_pending_r <= 1'b0;
                    end else begin
                        mesh_phase_r <= 3'd0;
                        mesh_k_tile_r <= mesh_k_tile_r + 1'b1;
                    end
                end else begin
                    mesh_phase_r <= 3'd0;
                    mesh_tile_beat_r <= mesh_tile_beat_r + 1'b1;
                end
            end else begin
                phase_output_col_cursor_r <= phase_output_col_cursor_r + 1'b1;
            end
        end else if (issue_bundle_accept_w) begin
            pending_req_id_r <= issue_bundle_req_id;
            pending_slot_valid_r <= accepted_slot_mask_w;
            pending_token_id_r <= issue_bundle_token_id;
            pending_position_id_r <= issue_bundle_position_id;
            pending_node_id_r <= issue_bundle_node_id;
            pending_parent_node_id_r <= issue_bundle_parent_node_id;
            pending_branch_id_r <= issue_bundle_branch_id;
            pending_private_depth_r <= issue_bundle_private_depth;
            pending_sram_id_r <= issue_bundle_sram_id;
            pending_bank_id_r <= issue_bundle_bank_id;
            pending_subbank_start_r <= issue_bundle_subbank_start;
            pending_group_len_r <= issue_bundle_group_len;
            pending_branch_mask_r <= issue_bundle_branch_mask;
            pending_is_shared_r <= issue_bundle_is_shared;
            pending_entry_state_r <= issue_bundle_entry_state;
            pending_entry_type_r <= issue_bundle_entry_type;
            pending_level_id_r <= issue_bundle_level_id;
            pending_prefix_len_r <= issue_bundle_prefix_len;
            pending_slot_tree_mask_en_r <= issue_bundle_slot_tree_mask_en;
            pending_slot_visible_mask_r <= issue_bundle_slot_visible_mask;
            pending_embedding_base_addr_r <= issue_bundle_embedding_base_addr;
            pending_hidden0_base_addr_r <= issue_bundle_hidden0_base_addr;
            pending_hidden1_base_addr_r <= issue_bundle_hidden1_base_addr;
            pending_final_base_addr_r <= issue_bundle_final_base_addr;
            pending_weight_sram_base_addr_r <=
                issue_bundle_weight_sram_base_addr;
            pending_kv_cache_base_addr_r <= issue_bundle_kv_cache_base_addr;
            pending_draft_kv_base_addr_r <= issue_bundle_draft_kv_base_addr;
            pending_hbm_weight_base_addr_r <=
                issue_bundle_hbm_weight_base_addr;
            pending_final_norm_gamma_addr_r <=
                issue_bundle_final_norm_gamma_addr;
            pending_lm_head_weight_base_addr_r <=
                issue_bundle_lm_head_weight_base_addr;

            mesh_phase_r <= 3'd0;
            mesh_k_tile_r <= {MESH_K_ITER_W{1'b0}};
            mesh_tile_beat_r <= {MODEL_MAC_TILE_BEAT_W{1'b0}};
            phase_inflight_r <= 1'b0;
            phase_resp_mask_r <= {`PE_MASK_W{1'b0}};
            phase_output_pending_r <= 1'b0;
            phase_output_col_cursor_r <= {PE_COL_W{1'b0}};
            phase_output_col_valid_r <= {PE_COLS{1'b0}};
            tile_result_req_id_r <= issue_bundle_req_id;
            tile_result_slot_valid_r <= {`BRANCH_NUM{1'b0}};
            tile_result_branch_id_r <= {(`BRANCH_NUM*`BRANCH_ID_W){1'b0}};
            tile_result_private_depth_r <= {DEPTH_PACK_W{1'b0}};
            tile_result_node_id_r <= {(`BRANCH_NUM*`NODE_ID_W){1'b0}};
            tile_result_parent_node_id_r <= {(`BRANCH_NUM*`NODE_ID_W){1'b0}};
            /*
             * bundle 起始时也要把默认 kind 锁成 hidden，避免零 slot/空拍路径
             * 仍残留旧的 “mesh 直接输出 logits” 语义。
             */
            tile_result_kind_r <= TILE_KIND_HIDDEN;
            tile_result_tile_index_r <= 16'd0;
            tile_result_last_r <= {`BRANCH_NUM{1'b0}};
            tile_result_data_r <= {(`BRANCH_NUM*`SRAM_RDATA_W){1'b0}};
            phase_output_slot_valid_by_col_r <= {(PE_COLS*`BRANCH_NUM){1'b0}};
            phase_output_branch_id_by_col_r <=
                {(PE_COLS*`BRANCH_NUM*`BRANCH_ID_W){1'b0}};
            phase_output_private_depth_by_col_r <= {(PE_COLS*DEPTH_PACK_W){1'b0}};
            phase_output_node_id_by_col_r <=
                {(PE_COLS*`BRANCH_NUM*`NODE_ID_W){1'b0}};
            phase_output_parent_node_id_by_col_r <=
                {(PE_COLS*`BRANCH_NUM*`NODE_ID_W){1'b0}};
            phase_output_tile_index_by_col_r <= {(PE_COLS*16){1'b0}};
            phase_output_last_by_col_r <= {(PE_COLS*`BRANCH_NUM){1'b0}};
            phase_output_data_by_col_r <=
                {(PE_COLS*`BRANCH_NUM*`SRAM_RDATA_W){1'b0}};

            if (accepted_slot_mask_w == {`TREE_FRONTIER_SLOTS{1'b0}}) begin
                bundle_pending_r <= 1'b0;
                tile_result_valid_r <= 1'b1;
            end else begin
                bundle_pending_r <= 1'b1;
            end
        end else if (bundle_pending_r) begin
            if (!phase_inflight_r) begin
                if (phase_launch_fire_w) begin
                    phase_inflight_r <= 1'b1;
                    phase_resp_mask_r <= phase_cell_valid_c;
                end
            end else begin
                phase_resp_mask_r <= next_phase_resp_mask_c;

                for (resp_i = 0; resp_i < `PE_MASK_W; resp_i = resp_i + 1) begin
                    if (mc_resp_valid[resp_i] && phase_resp_mask_r[resp_i]) begin
                        /*
                         * phase3 是 strict paper mesh 的 readout stage：
                         * - 这里不能再偷懒只拿最后一列；
                         * - 必须按当前 cell 对应的真实 slot 映射收集每一列响应；
                         * - 然后再串成一拍一列的 tile_result 流送给外层 readout。
                         */
                        if ((mesh_phase_r == LAST_PHASE) &&
                            ({{(32-SLOT_IDX_W){1'b0}},
                              phase_slot_idx_flat_c[
                                (resp_i*SLOT_IDX_W) +:
                                SLOT_IDX_W]} < `TREE_FRONTIER_SLOTS) &&
                            pending_slot_valid_r[
                                phase_slot_idx_flat_c[
                                    (resp_i*SLOT_IDX_W) +:
                                    SLOT_IDX_W]]) begin
                            phase_output_col_valid_r[(resp_i % PE_COLS)] <= 1'b1;
                            phase_output_slot_valid_by_col_r[
                                ((resp_i % PE_COLS)*`BRANCH_NUM) +
                                {{(32-`BRANCH_ID_W){1'b0}},
                                 pending_branch_id_r[
                                    (phase_slot_idx_flat_c[
                                        (resp_i*SLOT_IDX_W) +:
                                        SLOT_IDX_W]*`BRANCH_ID_W) +:
                                    `BRANCH_ID_W]}] <=
                                pending_slot_valid_r[
                                    phase_slot_idx_flat_c[
                                        (resp_i*SLOT_IDX_W) +:
                                        SLOT_IDX_W]];
                            phase_output_branch_id_by_col_r[
                                (((resp_i % PE_COLS)*(`BRANCH_NUM*`BRANCH_ID_W)) +
                                 ({{(32-`BRANCH_ID_W){1'b0}},
                                   pending_branch_id_r[
                                      (phase_slot_idx_flat_c[
                                          (resp_i*SLOT_IDX_W) +:
                                          SLOT_IDX_W]*`BRANCH_ID_W) +:
                                      `BRANCH_ID_W]}*`BRANCH_ID_W)) +:
                                `BRANCH_ID_W] <=
                                pending_branch_id_r[
                                    (phase_slot_idx_flat_c[
                                        (resp_i*SLOT_IDX_W) +:
                                        SLOT_IDX_W]*`BRANCH_ID_W) +:
                                    `BRANCH_ID_W];
                            phase_output_private_depth_by_col_r[
                                (((resp_i % PE_COLS)*DEPTH_PACK_W) +
                                 ({{(32-`BRANCH_ID_W){1'b0}},
                                   pending_branch_id_r[
                                      (phase_slot_idx_flat_c[
                                          (resp_i*SLOT_IDX_W) +:
                                          SLOT_IDX_W]*`BRANCH_ID_W) +:
                                      `BRANCH_ID_W]}*PRIVATE_DEPTH_W)) +:
                                PRIVATE_DEPTH_W] <=
                                pending_private_depth_r[
                                    (phase_slot_idx_flat_c[
                                        (resp_i*SLOT_IDX_W) +:
                                        SLOT_IDX_W]*PRIVATE_DEPTH_W) +:
                                    PRIVATE_DEPTH_W];
                            phase_output_node_id_by_col_r[
                                (((resp_i % PE_COLS)*(`BRANCH_NUM*`NODE_ID_W)) +
                                 ({{(32-`BRANCH_ID_W){1'b0}},
                                   pending_branch_id_r[
                                      (phase_slot_idx_flat_c[
                                          (resp_i*SLOT_IDX_W) +:
                                          SLOT_IDX_W]*`BRANCH_ID_W) +:
                                      `BRANCH_ID_W]}*`NODE_ID_W)) +:
                                `NODE_ID_W] <=
                                pending_node_id_r[
                                    (phase_slot_idx_flat_c[
                                        (resp_i*SLOT_IDX_W) +:
                                        SLOT_IDX_W]*`NODE_ID_W) +:
                                    `NODE_ID_W];
                            phase_output_parent_node_id_by_col_r[
                                (((resp_i % PE_COLS)*(`BRANCH_NUM*`NODE_ID_W)) +
                                 ({{(32-`BRANCH_ID_W){1'b0}},
                                   pending_branch_id_r[
                                      (phase_slot_idx_flat_c[
                                          (resp_i*SLOT_IDX_W) +:
                                          SLOT_IDX_W]*`BRANCH_ID_W) +:
                                      `BRANCH_ID_W]}*`NODE_ID_W)) +:
                                `NODE_ID_W] <=
                                pending_parent_node_id_r[
                                    (phase_slot_idx_flat_c[
                                        (resp_i*SLOT_IDX_W) +:
                                        SLOT_IDX_W]*`NODE_ID_W) +:
                                    `NODE_ID_W];
                            phase_output_tile_index_by_col_r[
                                ((resp_i % PE_COLS)*16) +: 16] <=
                                16'((((mesh_k_tile_r * PE_COLS) +
                                      (resp_i % PE_COLS)) *
                                     MODEL_MAC_TILE_BEATS) +
                                    {{(32-MODEL_MAC_TILE_BEAT_W){1'b0}},
                                     mesh_tile_beat_r});
                            phase_output_last_by_col_r[
                                ((resp_i % PE_COLS)*`BRANCH_NUM) +
                                {{(32-`BRANCH_ID_W){1'b0}},
                                 pending_branch_id_r[
                                    (phase_slot_idx_flat_c[
                                        (resp_i*SLOT_IDX_W) +:
                                        SLOT_IDX_W]*`BRANCH_ID_W) +:
                                    `BRANCH_ID_W]}] <=
                                ((((mesh_k_tile_r * PE_COLS) +
                                   (resp_i % PE_COLS)) ==
                                  (MODEL_K_TILE_COUNT - 1)) &&
                                 (mesh_tile_beat_r ==
                                  LAST_MODEL_MAC_TILE_BEAT));
                            phase_output_data_by_col_r[
                                (((resp_i % PE_COLS)*(`BRANCH_NUM*`SRAM_RDATA_W)) +
                                 ({{(32-`BRANCH_ID_W){1'b0}},
                                   pending_branch_id_r[
                                      (phase_slot_idx_flat_c[
                                          (resp_i*SLOT_IDX_W) +:
                                          SLOT_IDX_W]*`BRANCH_ID_W) +:
                                      `BRANCH_ID_W]}*`SRAM_RDATA_W)) +:
                                `SRAM_RDATA_W] <=
                                mc_resp_rdata[
                                    (resp_i*`SRAM_RDATA_W) +: `SRAM_RDATA_W];
                        end
                    end
                end

                if (next_phase_resp_mask_c == {`PE_MASK_W{1'b0}}) begin
                    phase_inflight_r <= 1'b0;
                    if (mesh_phase_r == LAST_PHASE) begin
                        phase_output_pending_r <= 1'b1;
                        phase_output_col_cursor_r <= {PE_COL_W{1'b0}};
                    end else begin
                        mesh_phase_r <= mesh_phase_r + 1'b1;
                    end
                end
            end
        end
    end
end

endmodule
