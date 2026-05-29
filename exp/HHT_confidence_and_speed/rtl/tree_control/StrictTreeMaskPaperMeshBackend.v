`timescale 1ns/1ps

`include "config/prediction_params.vh"
`include "config/interface_params.vh"
`include "config/memory_params.vh"
`include "config/model_params.vh"
`include "tree_control/StrictTreeMaskPaperTransformerOperatorChain.v"

/*
 * 文件作用：
 * 1. 这是 strict tree-mask 论文主链后端的正式包装层。
 * 2. 它的职责不是再自己实现一套旧的 batch 骨架，而是把：
 *      compute descriptor
 *          -> formal transformer operator chain
 *          -> request_controller(issue)
 *          -> sram_subsystem
 *          -> request_controller(resp regroup)
 *          -> multicast_network
 *          -> readout / comparator
 *    这一段 ownership 固定下来。
 * 3. 从这一步开始，strict 主链唯一认可的计算后端就是 `PaperPeArrays16x128Mesh`。
 *    如果后续继续细化 16 PE × 128 MAC 的数值阵列，应当只在该容器内部替换，
 *    不能把 ownership 再退回到旧的 `tree_verify_dispatcher -> batch fp16 inference`。
 */
module StrictTreeMaskPaperMeshBackend #(
    parameter integer PRIVATE_DEPTH_W =
        (((`MAX_VERIFY_NODES_PER_BRANCH + 1) <= 2) ? 1 :
         $clog2(`MAX_VERIFY_NODES_PER_BRANCH + 1)),
    parameter integer DEPTH_PACK_W = (`BRANCH_NUM * PRIVATE_DEPTH_W)
) (
    input                             clk,
    input                             rst_n,

    /*
     * strict paper path 发出的正式 compute descriptor。
     * 这一套输入字段必须保持稳定，作为论文后端唯一 issue 边界。
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
     * - request_controller 仍然看到 vec_req；
     * - multicast_network 仍然返回 mc_resp；
     * - lifecycle/comparator 仍然消费 result。
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
 * 当前包装层只保留 strict 后端对外名字和 top-level ownership；
 * 真正的 transformer 算子链层次已经下沉到
 * `StrictTreeMaskPaperTransformerOperatorChain` 内部。
 */
StrictTreeMaskPaperTransformerOperatorChain #(
    .PRIVATE_DEPTH_W(PRIVATE_DEPTH_W),
    .DEPTH_PACK_W(DEPTH_PACK_W)
) u_strict_tree_mask_paper_transformer_operator_chain (
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
    .vec_req_valid(vec_req_valid),
    .vec_req_ready(vec_req_ready),
    .vec_req_write(vec_req_write),
    .vec_req_addr(vec_req_addr),
    .vec_req_wdata(vec_req_wdata),
    .vec_req_req_id(vec_req_req_id),
    .vec_req_pe_mask(vec_req_pe_mask),
    .vec_req_priority(vec_req_priority),
    .vec_req_bank_id(vec_req_bank_id),
    .vec_req_subbank_id(vec_req_subbank_id),
    .mc_resp_valid(mc_resp_valid),
    .mc_resp_ready(mc_resp_ready),
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
    .busy(busy)
);

endmodule
