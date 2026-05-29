`timescale 1ns/1ps

`include "config/prediction_params.vh"
`include "config/interface_params.vh"
`include "config/memory_params.vh"
`include "config/model_params.vh"
`include "tree_control/PaperPeArrays16x128Mesh.v"
`include "tree_control/StrictTreeMaskPaperLogitsPostprocess.v"

/*
 * 文件作用：
 * 1. 这是 strict tree-mask 论文主链后端里的正式 transformer 算子链容器。
 * 2. 它把后端正式层次固定成：
 *      compute descriptor
 *          -> embedding / decoder-layer stack / final-norm+lm-head
 *          -> hidden/logits tile
 *    这条 strict paper path。
 * 3. 当前这一轮先把“算子链容器边界”搭起来，不把旧
 *    `fp16_inference_top` 整体搬回 strict 主链。
 * 4. 现阶段的具体落地方式是：
 *    - `PaperPeArrays16x128Mesh` 负责 embedding + layer stack 对应的
 *      原始 hidden tile 产生；
 *    - `StrictTreeMaskPaperLogitsPostprocess` 负责 final norm / lm head
 *      对应的后处理边界与 formal logits tile 输出；
 *    - 更细的叶子算子数值核后续继续只往这个容器内部收敛。
 * 5. 这条容器的外部共享基础设施边界保持论文 ownership 不变：
 *    - issue 侧：`PE/Compute -> request_controller -> sram_subsystem`
 *    - return 侧：`sram_subsystem -> request_controller(resp regroup)
 *      -> multicast_network -> PE arrays`
 */
module StrictTreeMaskPaperTransformerOperatorChain #(
    parameter integer PRIVATE_DEPTH_W =
        (((`MAX_VERIFY_NODES_PER_BRANCH + 1) <= 2) ? 1 :
         $clog2(`MAX_VERIFY_NODES_PER_BRANCH + 1)),
    parameter integer DEPTH_PACK_W = (`BRANCH_NUM * PRIVATE_DEPTH_W)
) (
    input                             clk,
    input                             rst_n,

    /*
     * strict paper path 发出的正式 compute descriptor。
     * 这套 bundle 是整个 transformer 算子链唯一认可的 issue 入口。
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
     * 对共享基础设施的外部接口保持不变：
     * - request_controller 继续看到 vec_req；
     * - multicast_network 继续返回 mc_resp；
     * - 外层 readout 继续消费 formal tile result。
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

    input      [`PE_MASK_W-1:0]       mc_resp_valid,
    output     [`PE_MASK_W-1:0]       mc_resp_ready,
    input      [`PE_MASK_W*`SRAM_RDATA_W-1:0] mc_resp_rdata,
    input      [`PE_MASK_W*`REQ_ID_W-1:0] mc_resp_req_id,
    input      [`PE_MASK_W*`PE_MASK_W-1:0] mc_resp_pe_mask,
    input      [`PE_MASK_W-1:0]       mc_resp_last,

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

/*
 * backend 内部两层 split：
 * 1. `raw_mesh_tile_result_*` 是 layer stack / PE arrays 直接吐出的 raw hidden tile；
 * 2. 对外 `tile_result_*` 是 postprocess 收口后的 formal logits tile；
 * 3. 这样 embedding / layer stack / final norm+lm head 的正式层次已经在结构上固定。
 */
wire paper_mesh_busy_w;
wire raw_mesh_tile_result_valid_w;
wire [`REQ_ID_W-1:0] raw_mesh_tile_result_req_id_w;
wire [`BRANCH_NUM-1:0] raw_mesh_tile_result_slot_valid_w;
wire [`BRANCH_NUM*`BRANCH_ID_W-1:0] raw_mesh_tile_result_branch_id_w;
wire [DEPTH_PACK_W-1:0] raw_mesh_tile_result_private_depth_w;
wire [`BRANCH_NUM*`NODE_ID_W-1:0] raw_mesh_tile_result_node_id_w;
wire [`BRANCH_NUM*`NODE_ID_W-1:0] raw_mesh_tile_result_parent_node_id_w;
wire [1:0] raw_mesh_tile_result_kind_w;
wire [15:0] raw_mesh_tile_result_tile_index_w;
wire [`BRANCH_NUM-1:0] raw_mesh_tile_result_last_w;
wire [`BRANCH_NUM*`SRAM_RDATA_W-1:0] raw_mesh_tile_result_data_w;
wire [`MEM_REQ_LANES-1:0] paper_mesh_vec_req_valid_w;
wire [`MEM_REQ_LANES-1:0] paper_mesh_vec_req_write_w;
wire [`MEM_REQ_LANES*`SRAM_ADDR_W-1:0] paper_mesh_vec_req_addr_w;
wire [`MEM_REQ_LANES*`SRAM_WDATA_W-1:0] paper_mesh_vec_req_wdata_w;
wire [`MEM_REQ_LANES*`REQ_ID_W-1:0] paper_mesh_vec_req_req_id_w;
wire [`MEM_REQ_LANES*`PE_MASK_W-1:0] paper_mesh_vec_req_pe_mask_w;
wire [`MEM_REQ_LANES*`REQ_PRIORITY_W-1:0] paper_mesh_vec_req_priority_w;
wire [`MEM_REQ_LANES*`BANK_ID_W-1:0] paper_mesh_vec_req_bank_id_w;
wire [`MEM_REQ_LANES*`SUBBANK_ID_W-1:0] paper_mesh_vec_req_subbank_id_w;
wire [`PE_MASK_W-1:0] paper_mesh_mc_resp_ready_w;

wire paper_postprocess_mem_active_w;
wire [`MEM_REQ_LANES-1:0] paper_postprocess_vec_req_valid_w;
wire [`MEM_REQ_LANES-1:0] paper_postprocess_vec_req_write_w;
wire [`MEM_REQ_LANES*`SRAM_ADDR_W-1:0] paper_postprocess_vec_req_addr_w;
wire [`MEM_REQ_LANES*`SRAM_WDATA_W-1:0] paper_postprocess_vec_req_wdata_w;
wire [`MEM_REQ_LANES*`REQ_ID_W-1:0] paper_postprocess_vec_req_req_id_w;
wire [`MEM_REQ_LANES*`PE_MASK_W-1:0] paper_postprocess_vec_req_pe_mask_w;
wire [`MEM_REQ_LANES*`REQ_PRIORITY_W-1:0] paper_postprocess_vec_req_priority_w;
wire [`MEM_REQ_LANES*`BANK_ID_W-1:0] paper_postprocess_vec_req_bank_id_w;
wire [`MEM_REQ_LANES*`SUBBANK_ID_W-1:0] paper_postprocess_vec_req_subbank_id_w;
wire [`PE_MASK_W-1:0] paper_postprocess_mc_resp_ready_w;
wire paper_postprocess_busy_w;

assign busy = paper_mesh_busy_w || paper_postprocess_busy_w;
assign vec_req_valid =
    paper_postprocess_mem_active_w ?
        paper_postprocess_vec_req_valid_w :
        paper_mesh_vec_req_valid_w;
assign vec_req_write =
    paper_postprocess_mem_active_w ?
        paper_postprocess_vec_req_write_w :
        paper_mesh_vec_req_write_w;
assign vec_req_addr =
    paper_postprocess_mem_active_w ?
        paper_postprocess_vec_req_addr_w :
        paper_mesh_vec_req_addr_w;
assign vec_req_wdata =
    paper_postprocess_mem_active_w ?
        paper_postprocess_vec_req_wdata_w :
        paper_mesh_vec_req_wdata_w;
assign vec_req_req_id =
    paper_postprocess_mem_active_w ?
        paper_postprocess_vec_req_req_id_w :
        paper_mesh_vec_req_req_id_w;
assign vec_req_pe_mask =
    paper_postprocess_mem_active_w ?
        paper_postprocess_vec_req_pe_mask_w :
        paper_mesh_vec_req_pe_mask_w;
assign vec_req_priority =
    paper_postprocess_mem_active_w ?
        paper_postprocess_vec_req_priority_w :
        paper_mesh_vec_req_priority_w;
assign vec_req_bank_id =
    paper_postprocess_mem_active_w ?
        paper_postprocess_vec_req_bank_id_w :
        paper_mesh_vec_req_bank_id_w;
assign vec_req_subbank_id =
    paper_postprocess_mem_active_w ?
        paper_postprocess_vec_req_subbank_id_w :
        paper_mesh_vec_req_subbank_id_w;
assign mc_resp_ready =
    paper_postprocess_mem_active_w ?
        paper_postprocess_mc_resp_ready_w :
        paper_mesh_mc_resp_ready_w;

/*
 * Stage 1:
 * embedding + decoder-layer stack 的正式承接容器。
 * 当前先继续由 `PaperPeArrays16x128Mesh` 统一承接，
 * 后续更细的 layer scheduler / per-layer operator chain 只允许往它内部收敛。
 */
PaperPeArrays16x128Mesh #(
    .PRIVATE_DEPTH_W(PRIVATE_DEPTH_W),
    .DEPTH_PACK_W(DEPTH_PACK_W),
    .PE_ROWS(`STRICT_PAPER_PE_ROWS),
    .PE_COLS(`STRICT_PAPER_PE_COLS),
    .MACS_PER_PE(`MAC_NUM_PER_PE)
) u_paper_pe_arrays_16x128_mesh (
    .clk(clk),
    .rst_n(rst_n),
    .issue_bundle_valid(issue_bundle_valid),
    .issue_bundle_ready(issue_bundle_ready),
    .issue_bundle_req_id(issue_bundle_req_id),
    .issue_bundle_slot_valid(issue_bundle_slot_valid),
    .issue_bundle_slot_lookup_hit(issue_bundle_slot_lookup_hit),
    .issue_bundle_token_id(issue_bundle_token_id),
    .issue_bundle_position_id(issue_bundle_position_id),
    .issue_bundle_node_id(issue_bundle_node_id),
    .issue_bundle_parent_node_id(issue_bundle_parent_node_id),
    .issue_bundle_branch_id(issue_bundle_branch_id),
    .issue_bundle_level_id(issue_bundle_level_id),
    .issue_bundle_slot_count(issue_bundle_slot_count),
    .issue_bundle_prefix_len(issue_bundle_prefix_len),
    .issue_bundle_slot_tree_mask_en(issue_bundle_slot_tree_mask_en),
    .issue_bundle_slot_visible_mask(issue_bundle_slot_visible_mask),
    .issue_bundle_private_depth(issue_bundle_private_depth),
    .issue_bundle_sram_id(issue_bundle_sram_id),
    .issue_bundle_bank_id(issue_bundle_bank_id),
    .issue_bundle_subbank_start(issue_bundle_subbank_start),
    .issue_bundle_group_len(issue_bundle_group_len),
    .issue_bundle_branch_mask(issue_bundle_branch_mask),
    .issue_bundle_is_shared(issue_bundle_is_shared),
    .issue_bundle_entry_state(issue_bundle_entry_state),
    .issue_bundle_entry_type(issue_bundle_entry_type),
    .issue_bundle_embedding_base_addr(issue_bundle_embedding_base_addr),
    .issue_bundle_hidden0_base_addr(issue_bundle_hidden0_base_addr),
    .issue_bundle_hidden1_base_addr(issue_bundle_hidden1_base_addr),
    .issue_bundle_final_base_addr(issue_bundle_final_base_addr),
    .issue_bundle_weight_sram_base_addr(issue_bundle_weight_sram_base_addr),
    .issue_bundle_kv_cache_base_addr(issue_bundle_kv_cache_base_addr),
    .issue_bundle_draft_kv_base_addr(issue_bundle_draft_kv_base_addr),
    .issue_bundle_hbm_weight_base_addr(issue_bundle_hbm_weight_base_addr),
    .issue_bundle_final_norm_gamma_addr(issue_bundle_final_norm_gamma_addr),
    .issue_bundle_lm_head_weight_base_addr(issue_bundle_lm_head_weight_base_addr),
    .vec_req_valid(paper_mesh_vec_req_valid_w),
    .vec_req_ready(vec_req_ready),
    .vec_req_write(paper_mesh_vec_req_write_w),
    .vec_req_addr(paper_mesh_vec_req_addr_w),
    .vec_req_wdata(paper_mesh_vec_req_wdata_w),
    .vec_req_req_id(paper_mesh_vec_req_req_id_w),
    .vec_req_pe_mask(paper_mesh_vec_req_pe_mask_w),
    .vec_req_priority(paper_mesh_vec_req_priority_w),
    .vec_req_bank_id(paper_mesh_vec_req_bank_id_w),
    .vec_req_subbank_id(paper_mesh_vec_req_subbank_id_w),
    .mc_resp_valid(mc_resp_valid),
    .mc_resp_ready(paper_mesh_mc_resp_ready_w),
    .mc_resp_rdata(mc_resp_rdata),
    .mc_resp_req_id(mc_resp_req_id),
    .mc_resp_pe_mask(mc_resp_pe_mask),
    .mc_resp_last(mc_resp_last),
    .tile_result_valid(raw_mesh_tile_result_valid_w),
    .tile_result_req_id(raw_mesh_tile_result_req_id_w),
    .tile_result_slot_valid(raw_mesh_tile_result_slot_valid_w),
    .tile_result_branch_id(raw_mesh_tile_result_branch_id_w),
    .tile_result_private_depth(raw_mesh_tile_result_private_depth_w),
    .tile_result_node_id(raw_mesh_tile_result_node_id_w),
    .tile_result_parent_node_id(raw_mesh_tile_result_parent_node_id_w),
    .tile_result_kind(raw_mesh_tile_result_kind_w),
    .tile_result_tile_index(raw_mesh_tile_result_tile_index_w),
    .tile_result_last(raw_mesh_tile_result_last_w),
    .tile_result_data(raw_mesh_tile_result_data_w),
    .busy(paper_mesh_busy_w)
);

/*
 * Stage 2:
 * final norm + lm head 的正式后处理边界。
 * 当前保持 formal tile ownership，不再让 mesh 直接越级输出 token。
 */
StrictTreeMaskPaperLogitsPostprocess #(
    .PRIVATE_DEPTH_W(PRIVATE_DEPTH_W),
    .DEPTH_PACK_W(DEPTH_PACK_W)
) u_strict_tree_mask_paper_logits_postprocess (
    .clk(clk),
    .rst_n(rst_n),
    .mesh_tile_valid(raw_mesh_tile_result_valid_w),
    .mesh_tile_req_id(raw_mesh_tile_result_req_id_w),
    .mesh_tile_slot_valid(raw_mesh_tile_result_slot_valid_w),
    .mesh_tile_branch_id(raw_mesh_tile_result_branch_id_w),
    .mesh_tile_private_depth(raw_mesh_tile_result_private_depth_w),
    .mesh_tile_node_id(raw_mesh_tile_result_node_id_w),
    .mesh_tile_parent_node_id(raw_mesh_tile_result_parent_node_id_w),
    .mesh_tile_kind(raw_mesh_tile_result_kind_w),
    .mesh_tile_tile_index(raw_mesh_tile_result_tile_index_w),
    .mesh_tile_last(raw_mesh_tile_result_last_w),
    .mesh_tile_data(raw_mesh_tile_result_data_w),
    .final_norm_gamma_addr(issue_bundle_final_norm_gamma_addr),
    .lm_head_weight_base_addr(issue_bundle_lm_head_weight_base_addr),
    .mem_active(paper_postprocess_mem_active_w),
    .vec_req_valid(paper_postprocess_vec_req_valid_w),
    .vec_req_ready(vec_req_ready),
    .vec_req_write(paper_postprocess_vec_req_write_w),
    .vec_req_addr(paper_postprocess_vec_req_addr_w),
    .vec_req_wdata(paper_postprocess_vec_req_wdata_w),
    .vec_req_req_id(paper_postprocess_vec_req_req_id_w),
    .vec_req_pe_mask(paper_postprocess_vec_req_pe_mask_w),
    .vec_req_priority(paper_postprocess_vec_req_priority_w),
    .vec_req_bank_id(paper_postprocess_vec_req_bank_id_w),
    .vec_req_subbank_id(paper_postprocess_vec_req_subbank_id_w),
    .mc_resp_valid(mc_resp_valid),
    .mc_resp_ready(paper_postprocess_mc_resp_ready_w),
    .mc_resp_rdata(mc_resp_rdata),
    .mc_resp_req_id(mc_resp_req_id),
    .mc_resp_pe_mask(mc_resp_pe_mask),
    .mc_resp_last(mc_resp_last),
    .tile_result_valid(tile_result_valid),
    .tile_result_req_id(tile_result_req_id),
    .tile_result_slot_valid(tile_result_slot_valid),
    .tile_result_branch_id(tile_result_branch_id),
    .tile_result_private_depth(tile_result_private_depth),
    .tile_result_node_id(tile_result_node_id),
    .tile_result_parent_node_id(tile_result_parent_node_id),
    .tile_result_kind(tile_result_kind),
    .tile_result_tile_index(tile_result_tile_index),
    .tile_result_last(tile_result_last),
    .tile_result_data(tile_result_data),
    .busy(paper_postprocess_busy_w)
);

endmodule
