`timescale 1ns/1ps

`include "config/prediction_params.vh"
`include "config/interface_params.vh"
`include "config/memory_params.vh"

module PredictionWindowOwnershipClosureSidecar #(
    parameter integer SOURCE_ID_W = 3,
    parameter integer CONF_W = 8,
    parameter integer WINDOW_BRANCH_SLOTS = `TREE_FRONTIER_SLOTS,
    parameter [`REQ_ID_W-1:0] SIDECAR_REQ_ID = 4'he,
    parameter [`NODE_ID_W-1:0] BRIDGE_SYNTH_NODE_BASE =
        {{(`NODE_ID_W-4){1'b0}}, 4'h8}
) (
    input                             clk,
    input                             rst_n,
    input                             enable,
    input                             main_path_quiet,

    input                             src_tree_window_valid,
    output                            src_tree_window_ready,
    input      [`NODE_ID_W-1:0]       src_tree_window_parent_node_id,
    input      [WINDOW_BRANCH_SLOTS-1:0] src_tree_window_slot_valid,
    input      [WINDOW_BRANCH_SLOTS*SOURCE_ID_W-1:0] src_tree_window_source_id,
    input      [WINDOW_BRANCH_SLOTS*`TOKEN_ID_W-1:0] src_tree_window_token_id,
    input      [WINDOW_BRANCH_SLOTS*`TOKEN_ID_W-1:0]
               src_tree_window_referenced_token_id,
    input      [WINDOW_BRANCH_SLOTS*`POSITION_ID_W-1:0]
               src_tree_window_referenced_position,
    input      [WINDOW_BRANCH_SLOTS*CONF_W-1:0] src_tree_window_confidence,

    output                            pe_req_valid,
    input                             pe_req_ready,
    output                            pe_req_write,
    output     [`SRAM_ADDR_W-1:0]     pe_req_addr,
    output     [`SRAM_WDATA_W-1:0]    pe_req_wdata,
    output     [`REQ_ID_W-1:0]        pe_req_req_id,
    output     [`PE_MASK_W-1:0]       pe_req_pe_mask,
    output     [`REQ_PRIORITY_W-1:0]  pe_req_priority,
    output     [`BANK_ID_W-1:0]       pe_req_bank_id,
    output     [`SUBBANK_ID_W-1:0]    pe_req_subbank_id,

    input                             pe_resp_valid,
    output                            pe_resp_ready,
    input      [`SRAM_RDATA_W-1:0]    pe_resp_rdata,
    input      [`REQ_ID_W-1:0]        pe_resp_req_id,
    input      [`PE_MASK_W-1:0]       pe_resp_pe_mask,
    input                             pe_resp_last,

    output                            busy,
    output                            debug_window_fire,
    output                            debug_token_wr_fire,
    output                            debug_lookup_hit,
    output                            debug_pe_req_fire,
    output                            debug_pe_resp_fire
);

wire bridge_src_tree_window_valid_w;
wire bridge_src_tree_window_ready_w;
wire frontier_valid_w;
wire frontier_ready_w;
wire [`REQ_ID_W-1:0] frontier_req_id_w;
wire [`TREE_LEVEL_ID_W-1:0] frontier_level_id_w;
wire [WINDOW_BRANCH_SLOTS-1:0] frontier_slot_valid_w;
wire [WINDOW_BRANCH_SLOTS*`NODE_ID_W-1:0] frontier_node_id_w;
wire [WINDOW_BRANCH_SLOTS*`NODE_ID_W-1:0] frontier_parent_node_id_w;
wire [WINDOW_BRANCH_SLOTS*`TOKEN_ID_W-1:0] frontier_token_id_w;
wire [WINDOW_BRANCH_SLOTS*`POSITION_ID_W-1:0] frontier_position_id_w;

wire prefetch_enq_ready_w;
wire prefetch_enq_valid_w;
wire [`REQ_ID_W-1:0] prefetch_enq_req_id_w;
wire [`BRANCH_ID_W-1:0] prefetch_enq_branch_id_w;
wire [`NODE_ID_W-1:0] prefetch_enq_node_id_w;
wire [`LAYER_ID_W-1:0] prefetch_enq_layer_id_w;
wire [`KV_GROUP_LEN_W-1:0] prefetch_enq_size_subbank_w;
wire prefetch_enq_shared_w;

wire prefetch_deq_valid_w;
wire prefetch_deq_ready_w;
wire [`REQ_ID_W-1:0] prefetch_deq_req_id_w;
wire [`BRANCH_ID_W-1:0] prefetch_deq_branch_id_w;
wire [`NODE_ID_W-1:0] prefetch_deq_node_id_w;
wire [`LAYER_ID_W-1:0] prefetch_deq_layer_id_w;
wire [`KV_GROUP_LEN_W-1:0] prefetch_deq_size_subbank_w;
wire prefetch_deq_shared_w;

wire cand_resp_valid_w;
wire cand_resp_grant_w;
wire [`REQ_ID_W-1:0] cand_resp_req_id_w;
wire [`SRAM_ID_W-1:0] cand_resp_sram_id_w;
wire [`BANK_ID_W-1:0] cand_resp_bank_id_w;
wire [`SUBBANK_ID_W-1:0] cand_resp_subbank_start_w;
wire [`KV_GROUP_LEN_W-1:0] cand_resp_group_len_w;

wire alloc_cand_valid_w;
wire [`REQ_ID_W-1:0] alloc_cand_req_id_w;
wire [`BRANCH_ID_W-1:0] alloc_cand_branch_id_w;
wire [`NODE_ID_W-1:0] alloc_cand_node_id_w;
wire [`KV_GROUP_LEN_W-1:0] alloc_cand_size_subbank_w;
wire alloc_cand_shared_w;
wire [`SRAM_ID_W-1:0] alloc_cand_sram_id_w;
wire [`BANK_ID_W-1:0] alloc_cand_bank_id_w;
wire [`SUBBANK_ID_W-1:0] alloc_cand_subbank_start_w;
wire [`KV_GROUP_LEN_W-1:0] alloc_cand_group_len_w;

wire alloc_resp_valid_w;
wire alloc_resp_grant_w;
wire [`REQ_ID_W-1:0] alloc_resp_req_id_w;
wire [`SRAM_ID_W-1:0] alloc_resp_sram_id_w;
wire [`BANK_ID_W-1:0] alloc_resp_bank_id_w;
wire [`SUBBANK_ID_W-1:0] alloc_resp_subbank_start_w;
wire [`KV_GROUP_LEN_W-1:0] alloc_resp_group_len_w;

wire token_wr_valid_w;
wire [`REQ_ID_W-1:0] token_wr_req_id_w;
wire [`TOKEN_ID_W-1:0] token_wr_token_id_w;
wire [`POSITION_ID_W-1:0] token_wr_position_id_w;
wire [`NODE_ID_W-1:0] token_wr_node_id_w;
wire [`BRANCH_ID_W-1:0] token_wr_branch_id_w;
wire [`BRANCH_MASK_W-1:0] token_wr_branch_mask_w;
wire token_wr_is_shared_w;
wire [`SRAM_ID_W-1:0] token_wr_sram_id_w;
wire [`BANK_ID_W-1:0] token_wr_bank_id_w;
wire [`SUBBANK_ID_W-1:0] token_wr_subbank_start_w;
wire [`KV_GROUP_LEN_W-1:0] token_wr_group_len_w;

wire lookup_ready_w;
wire lookup_resp_valid_w;
wire lookup_resp_hit_w;
wire [`REQ_ID_W-1:0] lookup_resp_req_id_w;
wire [`SRAM_ID_W-1:0] lookup_resp_sram_id_w;
wire [`BANK_ID_W-1:0] lookup_resp_bank_id_w;
wire [`SUBBANK_ID_W-1:0] lookup_resp_subbank_start_w;
wire [`KV_GROUP_LEN_W-1:0] lookup_resp_group_len_w;

reg [`TOKEN_REG_INDEX_W-1:0] token_wr_index_r;
reg captured_token_valid_r;
reg [`TOKEN_ID_W-1:0] captured_token_id_r;
reg [`POSITION_ID_W-1:0] captured_position_id_r;
reg lookup_sent_r;
reg lookup_hit_seen_r;
reg pe_req_sent_r;
reg pe_resp_seen_r;
reg [`SRAM_ID_W-1:0] lookup_sram_id_r;
reg [`BANK_ID_W-1:0] lookup_bank_id_r;
reg [`SUBBANK_ID_W-1:0] lookup_subbank_start_r;

wire window_fire_w;
wire lookup_hit_fire_w;
wire pe_req_fire_w;
wire pe_resp_fire_w;

assign bridge_src_tree_window_valid_w = enable && src_tree_window_valid;
assign src_tree_window_ready = enable ? bridge_src_tree_window_ready_w : 1'b1;
assign window_fire_w = bridge_src_tree_window_valid_w &&
                       bridge_src_tree_window_ready_w;

assign lookup_hit_fire_w = lookup_resp_valid_w && lookup_resp_hit_w &&
                           (lookup_resp_req_id_w == SIDECAR_REQ_ID);

assign pe_req_valid = enable && lookup_hit_seen_r && !pe_req_sent_r &&
                      main_path_quiet;
assign pe_req_write = 1'b0;
assign pe_req_addr = {
    lookup_sram_id_r,
    lookup_bank_id_r,
    lookup_subbank_start_r,
    {`ROW_ADDR_W{1'b0}},
    {`OFFSET_W{1'b0}}
};
assign pe_req_wdata = {`SRAM_WDATA_W{1'b0}};
assign pe_req_req_id = SIDECAR_REQ_ID;
assign pe_req_pe_mask = {{(`PE_MASK_W-1){1'b0}}, 1'b1};
assign pe_req_priority = {`REQ_PRIORITY_W{1'b0}};
assign pe_req_bank_id = lookup_bank_id_r;
assign pe_req_subbank_id = lookup_subbank_start_r;
assign pe_req_fire_w = pe_req_valid && pe_req_ready;

assign pe_resp_ready = enable && pe_req_sent_r && !pe_resp_seen_r;
assign pe_resp_fire_w = pe_resp_valid && pe_resp_ready &&
                        (pe_resp_req_id == SIDECAR_REQ_ID) &&
                        pe_resp_last;

assign busy = enable && captured_token_valid_r && !pe_resp_seen_r;

assign debug_window_fire = window_fire_w;
assign debug_token_wr_fire = token_wr_valid_w;
assign debug_lookup_hit = lookup_hit_fire_w;
assign debug_pe_req_fire = pe_req_fire_w;
assign debug_pe_resp_fire = pe_resp_fire_w;

PredictionWindowAguBridge #(
    .SOURCE_ID_W(SOURCE_ID_W),
    .CONF_W(CONF_W),
    .WINDOW_BRANCH_SLOTS(WINDOW_BRANCH_SLOTS),
    .BRIDGE_SYNTH_NODE_BASE(BRIDGE_SYNTH_NODE_BASE)
) u_bridge (
    .clk(clk),
    .rst_n(rst_n),
    .src_tree_window_valid(bridge_src_tree_window_valid_w),
    .src_tree_window_ready(bridge_src_tree_window_ready_w),
    .src_tree_window_req_id(SIDECAR_REQ_ID),
    .src_tree_window_parent_node_id(src_tree_window_parent_node_id),
    .src_tree_window_slot_valid(src_tree_window_slot_valid),
    .src_tree_window_source_id(src_tree_window_source_id),
    .src_tree_window_token_id(src_tree_window_token_id),
    .src_tree_window_referenced_token_id(
        src_tree_window_referenced_token_id),
    .src_tree_window_referenced_position(
        src_tree_window_referenced_position),
    .src_tree_window_confidence(src_tree_window_confidence),
    .frontier_valid(frontier_valid_w),
    .frontier_ready(frontier_ready_w),
    .frontier_req_id(frontier_req_id_w),
    .frontier_level_id(frontier_level_id_w),
    .frontier_slot_valid(frontier_slot_valid_w),
    .frontier_node_id(frontier_node_id_w),
    .frontier_parent_node_id(frontier_parent_node_id_w),
    .frontier_token_id(frontier_token_id_w),
    .frontier_position_id(frontier_position_id_w)
);

agu u_agu (
    .clk(clk),
    .rst_n(rst_n),
    .tree_in_valid(1'b0),
    .tree_in_ready(),
    .tree_in_req_id({`REQ_ID_W{1'b0}}),
    .tree_in_branch_id({`BRANCH_ID_W{1'b0}}),
    .tree_in_node_id({`NODE_ID_W{1'b0}}),
    // 该 sidecar 仍走旧 frontier 入口，新的 bundle 并行接口先显式拉低，
    // 保证接口升级期间结构一致、综合无悬空端口。
    .bundle_in_valid(1'b0),
    .bundle_in_ready(),
    .bundle_in_req_id({`REQ_ID_W{1'b0}}),
    .bundle_in_level_id({`TREE_LEVEL_ID_W{1'b0}}),
    .bundle_in_slot_valid({`TREE_FRONTIER_SLOTS{1'b0}}),
    .bundle_in_node_id({(`TREE_FRONTIER_SLOTS*`NODE_ID_W){1'b0}}),
    .bundle_in_parent_node_id({(`TREE_FRONTIER_SLOTS*`NODE_ID_W){1'b0}}),
    .bundle_in_token_id({(`TREE_FRONTIER_SLOTS*`TOKEN_ID_W){1'b0}}),
    .bundle_in_position_id({(`TREE_FRONTIER_SLOTS*`POSITION_ID_W){1'b0}}),
    .bundle_in_branch_id({(`TREE_FRONTIER_SLOTS*`BRANCH_ID_W){1'b0}}),
    .bundle_in_slot_shared({`TREE_FRONTIER_SLOTS{1'b0}}),
    .prefix_valid(1'b0),
    .prefix_ready(),
    .prefix_req_id({`REQ_ID_W{1'b0}}),
    .prefix_node_valid(1'b0),
    .prefix_node_id({`NODE_ID_W{1'b0}}),
    .prefix_parent_node_id({`NODE_ID_W{1'b0}}),
    .prefix_token_id({`TOKEN_ID_W{1'b0}}),
    .prefix_position_id({`POSITION_ID_W{1'b0}}),
    .prefix_layer_id({`LAYER_ID_W{1'b0}}),
    .prefix_is_last(1'b0),
    .frontier_valid(frontier_valid_w),
    .frontier_ready(frontier_ready_w),
    .frontier_req_id(frontier_req_id_w),
    .frontier_level_id(frontier_level_id_w),
    .frontier_slot_valid(frontier_slot_valid_w),
    .frontier_node_id(frontier_node_id_w),
    .frontier_parent_node_id(frontier_parent_node_id_w),
    .frontier_token_id(frontier_token_id_w),
    .frontier_position_id(frontier_position_id_w),
    .prefetch_enq_ready(prefetch_enq_ready_w),
    .prefetch_bundle_ready(1'b0),
    .cand_resp_valid(cand_resp_valid_w),
    .cand_resp_grant(cand_resp_grant_w),
    .cand_resp_req_id(cand_resp_req_id_w),
    .cand_resp_sram_id(cand_resp_sram_id_w),
    .cand_resp_bank_id(cand_resp_bank_id_w),
    .cand_resp_subbank_start(cand_resp_subbank_start_w),
    .cand_resp_group_len(cand_resp_group_len_w),
    .cand_resp_bundle_valid(1'b0),
    .cand_resp_bundle_req_id({`REQ_ID_W{1'b0}}),
    .cand_resp_bundle_slot_valid({`TREE_FRONTIER_SLOTS{1'b0}}),
    .cand_resp_bundle_grant({`TREE_FRONTIER_SLOTS{1'b0}}),
    .cand_resp_bundle_sram_id({(`TREE_FRONTIER_SLOTS*`SRAM_ID_W){1'b0}}),
    .cand_resp_bundle_bank_id({(`TREE_FRONTIER_SLOTS*`BANK_ID_W){1'b0}}),
    .cand_resp_bundle_subbank_start({(`TREE_FRONTIER_SLOTS*`SUBBANK_ID_W){1'b0}}),
    .cand_resp_bundle_group_len({(`TREE_FRONTIER_SLOTS*`KV_GROUP_LEN_W){1'b0}}),
    .alloc_resp_valid(alloc_resp_valid_w),
    .alloc_resp_grant(alloc_resp_grant_w),
    .alloc_resp_req_id(alloc_resp_req_id_w),
    .alloc_resp_sram_id(alloc_resp_sram_id_w),
    .alloc_resp_bank_id(alloc_resp_bank_id_w),
    .alloc_resp_subbank_start(alloc_resp_subbank_start_w),
    .alloc_resp_group_len(alloc_resp_group_len_w),
    .flush_freeze(1'b0),
    .flush_drain_busy(1'b0),
    .flush_ctrl_valid(1'b0),
    .flush_ctrl_req_id({`REQ_ID_W{1'b0}}),
    .flush_ctrl_branch_mask({`BRANCH_MASK_W{1'b0}}),
    .flush_ctrl_node_mask({`NODE_MASK_W{1'b0}}),
    .branch_liveness_valid(1'b0),
    .branch_liveness_req_id({`REQ_ID_W{1'b0}}),
    .branch_liveness_live_mask({`BRANCH_MASK_W{1'b1}}),
    .branch_liveness_prune_mask({`BRANCH_MASK_W{1'b0}}),
    .prefix_norm_valid(),
    .prefix_norm_req_id(),
    .prefix_norm_node_valid(),
    .prefix_norm_node_id(),
    .prefix_norm_parent_node_id(),
    .prefix_norm_token_id(),
    .prefix_norm_position_id(),
    .prefix_norm_layer_id(),
    .prefix_norm_is_last(),
    .prefix_norm_is_shared(),
    .frontier_norm_valid(),
    .frontier_norm_req_id(),
    .frontier_norm_level_id(),
    .frontier_norm_slot_valid(),
    .frontier_norm_node_id(),
    .frontier_norm_parent_node_id(),
    .frontier_norm_token_id(),
    .frontier_norm_position_id(),
    .frontier_norm_size_subbank(),
    .frontier_norm_slot_shared(),
    .alloc_cand_valid(alloc_cand_valid_w),
    .alloc_cand_req_id(alloc_cand_req_id_w),
    .alloc_cand_branch_id(alloc_cand_branch_id_w),
    .alloc_cand_node_id(alloc_cand_node_id_w),
    .alloc_cand_size_subbank(alloc_cand_size_subbank_w),
    .alloc_cand_shared(alloc_cand_shared_w),
    .alloc_cand_sram_id(alloc_cand_sram_id_w),
    .alloc_cand_bank_id(alloc_cand_bank_id_w),
    .alloc_cand_subbank_start(alloc_cand_subbank_start_w),
    .alloc_cand_group_len(alloc_cand_group_len_w),
    .token_wr_valid(token_wr_valid_w),
    .token_wr_req_id(token_wr_req_id_w),
    .token_wr_token_id(token_wr_token_id_w),
    .token_wr_position_id(token_wr_position_id_w),
    .token_wr_node_id(token_wr_node_id_w),
    .token_wr_branch_id(token_wr_branch_id_w),
    .token_wr_branch_mask(token_wr_branch_mask_w),
    .token_wr_is_shared(token_wr_is_shared_w),
    .token_wr_sram_id(token_wr_sram_id_w),
    .token_wr_bank_id(token_wr_bank_id_w),
    .token_wr_subbank_start(token_wr_subbank_start_w),
    .token_wr_group_len(token_wr_group_len_w),
    .token_wr_bundle_valid(),
    .token_wr_bundle_req_id(),
    .token_wr_bundle_slot_valid(),
    .token_wr_bundle_token_id(),
    .token_wr_bundle_position_id(),
    .token_wr_bundle_node_id(),
    .token_wr_bundle_branch_id(),
    .token_wr_bundle_sram_id(),
    .token_wr_bundle_bank_id(),
    .token_wr_bundle_subbank_start(),
    .token_wr_bundle_group_len(),
    .token_wr_bundle_branch_mask(),
    .token_wr_bundle_is_shared(),
    .prefetch_enq_valid(prefetch_enq_valid_w),
    .prefetch_enq_req_id(prefetch_enq_req_id_w),
    .prefetch_enq_branch_id(prefetch_enq_branch_id_w),
    .prefetch_enq_node_id(prefetch_enq_node_id_w),
    .prefetch_enq_layer_id(prefetch_enq_layer_id_w),
    .prefetch_enq_size_subbank(prefetch_enq_size_subbank_w),
    .prefetch_enq_shared(prefetch_enq_shared_w),
    .prefetch_bundle_valid(),
    .prefetch_bundle_req_id(),
    .prefetch_bundle_layer_id(),
    .prefetch_bundle_slot_valid(),
    .prefetch_bundle_branch_id(),
    .prefetch_bundle_node_id(),
    .prefetch_bundle_size_subbank(),
    .prefetch_bundle_shared(),
    .prefetch_flush_valid(),
    .prefetch_flush_req_id(),
    .prefetch_flush_branch_mask(),
    .prefetch_flush_node_mask(),
    .free_list_flush_valid(),
    .free_list_flush_req_id(),
    .free_list_flush_branch_mask(),
    .free_list_flush_node_mask(),
    .token_flush_valid(),
    .token_flush_req_id(),
    .token_flush_branch_mask(),
    .token_flush_node_mask()
);

prefetch_queue u_prefetch_queue (
    .clk(clk),
    .rst_n(rst_n),
    .enq_valid(prefetch_enq_valid_w),
    .enq_ready(prefetch_enq_ready_w),
    .enq_req_id(prefetch_enq_req_id_w),
    .enq_branch_id(prefetch_enq_branch_id_w),
    .enq_node_id(prefetch_enq_node_id_w),
    .enq_layer_id(prefetch_enq_layer_id_w),
    .enq_size_subbank(prefetch_enq_size_subbank_w),
    .enq_shared(prefetch_enq_shared_w),
    .bundle_enq_valid(1'b0),
    .bundle_enq_ready(),
    .bundle_enq_req_id({`REQ_ID_W{1'b0}}),
    .bundle_enq_layer_id({`LAYER_ID_W{1'b0}}),
    .bundle_enq_slot_valid({`TREE_FRONTIER_SLOTS{1'b0}}),
    .bundle_enq_branch_id({(`TREE_FRONTIER_SLOTS*`BRANCH_ID_W){1'b0}}),
    .bundle_enq_node_id({(`TREE_FRONTIER_SLOTS*`NODE_ID_W){1'b0}}),
    .bundle_enq_size_subbank({(`TREE_FRONTIER_SLOTS*`KV_GROUP_LEN_W){1'b0}}),
    .bundle_enq_shared({`TREE_FRONTIER_SLOTS{1'b0}}),
    .flush_valid(1'b0),
    .flush_req_id({`REQ_ID_W{1'b0}}),
    .flush_branch_mask({`BRANCH_MASK_W{1'b0}}),
    .flush_node_mask({`NODE_MASK_W{1'b0}}),
    .bundle_deq_valid(),
    .bundle_deq_ready(1'b0),
    .bundle_deq_req_id(),
    .bundle_deq_layer_id(),
    .bundle_deq_slot_valid(),
    .bundle_deq_branch_id(),
    .bundle_deq_node_id(),
    .bundle_deq_size_subbank(),
    .bundle_deq_shared(),
    .deq_valid(prefetch_deq_valid_w),
    .deq_ready(prefetch_deq_ready_w),
    .deq_req_id(prefetch_deq_req_id_w),
    .deq_branch_id(prefetch_deq_branch_id_w),
    .deq_node_id(prefetch_deq_node_id_w),
    .deq_layer_id(prefetch_deq_layer_id_w),
    .deq_size_subbank(prefetch_deq_size_subbank_w),
    .deq_shared(prefetch_deq_shared_w)
);

free_list #(
    .ENABLE_TOPOLOGY_AWARE_MAPPING(1),
    .ENABLE_SHARED_PREFIX_FREEZE(1),
    .ENABLE_BRANCH_ISOLATION(1)
) u_free_list (
    .clk(clk),
    .rst_n(rst_n),
    .cand_req_valid(prefetch_deq_valid_w),
    .cand_req_ready(prefetch_deq_ready_w),
    .cand_req_req_id(prefetch_deq_req_id_w),
    .cand_req_branch_id(prefetch_deq_branch_id_w),
    .cand_req_node_id(prefetch_deq_node_id_w),
    .cand_req_size_subbank(prefetch_deq_size_subbank_w),
    .cand_req_shared(prefetch_deq_shared_w),
    .cand_resp_valid(cand_resp_valid_w),
    .cand_resp_grant(cand_resp_grant_w),
    .cand_resp_req_id(cand_resp_req_id_w),
    .cand_resp_sram_id(cand_resp_sram_id_w),
    .cand_resp_bank_id(cand_resp_bank_id_w),
    .cand_resp_subbank_start(cand_resp_subbank_start_w),
    .cand_resp_group_len(cand_resp_group_len_w),
    .cand_resp_bundle_valid(),
    .cand_resp_bundle_req_id(),
    .cand_resp_bundle_slot_valid(),
    .cand_resp_bundle_grant(),
    .cand_resp_bundle_sram_id(),
    .cand_resp_bundle_bank_id(),
    .cand_resp_bundle_subbank_start(),
    .cand_resp_bundle_group_len(),
    .alloc_cand_valid(alloc_cand_valid_w),
    .alloc_cand_req_id(alloc_cand_req_id_w),
    .alloc_cand_branch_id(alloc_cand_branch_id_w),
    .alloc_cand_node_id(alloc_cand_node_id_w),
    .alloc_cand_size_subbank(alloc_cand_size_subbank_w),
    .alloc_cand_shared(alloc_cand_shared_w),
    .alloc_cand_sram_id(alloc_cand_sram_id_w),
    .alloc_cand_bank_id(alloc_cand_bank_id_w),
    .alloc_cand_subbank_start(alloc_cand_subbank_start_w),
    .alloc_cand_group_len(alloc_cand_group_len_w),
    .alloc_cand_bundle_valid(),
    .alloc_cand_bundle_req_id(),
    .alloc_cand_bundle_slot_valid(),
    .alloc_cand_bundle_branch_id(),
    .alloc_cand_bundle_node_id(),
    .alloc_cand_bundle_size_subbank(),
    .alloc_cand_bundle_shared(),
    .alloc_cand_bundle_sram_id(),
    .alloc_cand_bundle_bank_id(),
    .alloc_cand_bundle_subbank_start(),
    .alloc_cand_bundle_group_len(),
    .flush_valid(1'b0),
    .flush_req_id({`REQ_ID_W{1'b0}}),
    .flush_branch_mask({`BRANCH_MASK_W{1'b0}}),
    .flush_node_mask({`NODE_MASK_W{1'b0}}),
    .flush_drain_busy(),
    .flush_reclaim_valid(),
    .flush_reclaim_sram_id(),
    .flush_reclaim_bank_id(),
    .flush_reclaim_subbank_start(),
    .flush_reclaim_group_len(),
    .release_valid(1'b0),
    .release_sram_id({`SRAM_ID_W{1'b0}}),
    .release_bank_id({`BANK_ID_W{1'b0}}),
    .release_subbank_start({`SUBBANK_ID_W{1'b0}}),
    .release_group_len({`KV_GROUP_LEN_W{1'b0}})
);

bank_state_table #(
    .ENABLE_SHARED_PREFIX_FREEZE(1),
    .ENABLE_PREFIX_PROMOTION(1),
    .ENABLE_BRANCH_ISOLATION(1)
) u_bank_state_table (
    .clk(clk),
    .rst_n(rst_n),
    .cand_valid(alloc_cand_valid_w),
    .cand_ready(),
    .cand_req_id(alloc_cand_req_id_w),
    .cand_branch_id(alloc_cand_branch_id_w),
    .cand_node_id(alloc_cand_node_id_w),
    .cand_size_subbank(alloc_cand_size_subbank_w),
    .cand_shared(alloc_cand_shared_w),
    .cand_sram_id(alloc_cand_sram_id_w),
    .cand_bank_id(alloc_cand_bank_id_w),
    .cand_subbank_start(alloc_cand_subbank_start_w),
    .cand_group_len(alloc_cand_group_len_w),
    .alloc_resp_valid(alloc_resp_valid_w),
    .alloc_resp_grant(alloc_resp_grant_w),
    .alloc_resp_req_id(alloc_resp_req_id_w),
    .alloc_resp_sram_id(alloc_resp_sram_id_w),
    .alloc_resp_bank_id(alloc_resp_bank_id_w),
    .alloc_resp_subbank_start(alloc_resp_subbank_start_w),
    .alloc_resp_group_len(alloc_resp_group_len_w),
    .alloc_resp_occ_bitmap(),
    .commit_valid(1'b0),
    .commit_req_id({`REQ_ID_W{1'b0}}),
    .commit_sram_id({`SRAM_ID_W{1'b0}}),
    .commit_bank_id({`BANK_ID_W{1'b0}}),
    .commit_subbank_start({`SUBBANK_ID_W{1'b0}}),
    .commit_group_len({`KV_GROUP_LEN_W{1'b0}}),
    .commit_branch_mask({`BRANCH_MASK_W{1'b0}}),
    .commit_node_mask({`NODE_MASK_W{1'b0}}),
    .flush_valid(1'b0),
    .flush_req_id({`REQ_ID_W{1'b0}}),
    .flush_branch_mask({`BRANCH_MASK_W{1'b0}}),
    .flush_node_mask({`NODE_MASK_W{1'b0}}),
    .reclaim_valid(1'b0),
    .reclaim_sram_id({`SRAM_ID_W{1'b0}}),
    .reclaim_bank_id({`BANK_ID_W{1'b0}}),
    .reclaim_subbank_start({`SUBBANK_ID_W{1'b0}}),
    .reclaim_group_len({`KV_GROUP_LEN_W{1'b0}}),
    .query_valid(1'b0),
    .query_sram_id({`SRAM_ID_W{1'b0}}),
    .query_bank_id({`BANK_ID_W{1'b0}}),
    .query_resp_valid(),
    .query_resp_occ_bitmap(),
    .query_resp_state(),
    .query_resp_branch_mask(),
    .query_resp_refcnt()
);

token_register u_token_register (
    .clk(clk),
    .rst_n(rst_n),
    .wr_valid(token_wr_valid_w),
    .wr_ready(),
    .wr_index(token_wr_index_r),
    .wr_req_id(token_wr_req_id_w),
    .wr_token_id(token_wr_token_id_w),
    .wr_position_id(token_wr_position_id_w),
    .wr_node_id(token_wr_node_id_w),
    .wr_branch_id(token_wr_branch_id_w),
    .wr_sram_id(token_wr_sram_id_w),
    .wr_bank_id(token_wr_bank_id_w),
    .wr_subbank_start(token_wr_subbank_start_w),
    .wr_group_len(token_wr_group_len_w),
    .wr_branch_mask(token_wr_branch_mask_w),
    .wr_is_shared(token_wr_is_shared_w),
    .wr_bundle_valid(1'b0),
    .wr_bundle_ready(),
    .wr_bundle_slot_valid({`TREE_FRONTIER_SLOTS{1'b0}}),
    .wr_bundle_index({(`TREE_FRONTIER_SLOTS*`TOKEN_REG_INDEX_W){1'b0}}),
    .wr_bundle_req_id({`REQ_ID_W{1'b0}}),
    .wr_bundle_token_id({(`TREE_FRONTIER_SLOTS*`TOKEN_ID_W){1'b0}}),
    .wr_bundle_position_id({(`TREE_FRONTIER_SLOTS*`POSITION_ID_W){1'b0}}),
    .wr_bundle_node_id({(`TREE_FRONTIER_SLOTS*`NODE_ID_W){1'b0}}),
    .wr_bundle_branch_id({(`TREE_FRONTIER_SLOTS*`BRANCH_ID_W){1'b0}}),
    .wr_bundle_sram_id({(`TREE_FRONTIER_SLOTS*`SRAM_ID_W){1'b0}}),
    .wr_bundle_bank_id({(`TREE_FRONTIER_SLOTS*`BANK_ID_W){1'b0}}),
    .wr_bundle_subbank_start({(`TREE_FRONTIER_SLOTS*`SUBBANK_ID_W){1'b0}}),
    .wr_bundle_group_len({(`TREE_FRONTIER_SLOTS*`KV_GROUP_LEN_W){1'b0}}),
    .wr_bundle_branch_mask({(`TREE_FRONTIER_SLOTS*`BRANCH_MASK_W){1'b0}}),
    .wr_bundle_is_shared({`TREE_FRONTIER_SLOTS{1'b0}}),
    .lookup_valid(enable && captured_token_valid_r && !lookup_sent_r),
    .lookup_ready(lookup_ready_w),
    .lookup_req_id(SIDECAR_REQ_ID),
    .lookup_token_id(captured_token_id_r),
    .lookup_position_id(captured_position_id_r),
    .lookup_resp_valid(lookup_resp_valid_w),
    .lookup_resp_hit(lookup_resp_hit_w),
    .lookup_resp_req_id(lookup_resp_req_id_w),
    .lookup_resp_sram_id(lookup_resp_sram_id_w),
    .lookup_resp_bank_id(lookup_resp_bank_id_w),
    .lookup_resp_subbank_start(lookup_resp_subbank_start_w),
    .lookup_resp_group_len(lookup_resp_group_len_w),
    .lookup_resp_branch_mask(),
    .lookup_resp_is_shared(),
    .lookup_resp_entry_type(),
    .lookup_resp_state(),
    .lookup_bundle_valid(1'b0),
    .lookup_bundle_ready(),
    .lookup_bundle_req_id({`REQ_ID_W{1'b0}}),
    .lookup_bundle_slot_valid({`TREE_FRONTIER_SLOTS{1'b0}}),
    .lookup_bundle_token_id({(`TREE_FRONTIER_SLOTS*`TOKEN_ID_W){1'b0}}),
    .lookup_bundle_position_id({(`TREE_FRONTIER_SLOTS*`POSITION_ID_W){1'b0}}),
    .lookup_bundle_resp_valid(),
    .lookup_bundle_resp_req_id(),
    .lookup_bundle_resp_hit(),
    .lookup_bundle_resp_sram_id(),
    .lookup_bundle_resp_bank_id(),
    .lookup_bundle_resp_subbank_start(),
    .lookup_bundle_resp_group_len(),
    .lookup_bundle_resp_branch_mask(),
    .lookup_bundle_resp_is_shared(),
    .lookup_bundle_resp_state(),
    .lookup_bundle_resp_entry_type(),
    .commit_valid(1'b0),
    .commit_index({`TOKEN_REG_INDEX_W{1'b0}}),
    .commit_req_id({`REQ_ID_W{1'b0}}),
    .commit_branch_mask({`BRANCH_MASK_W{1'b0}}),
    .commit_node_mask({`NODE_MASK_W{1'b0}}),
    .flush_valid(1'b0),
    .flush_req_id({`REQ_ID_W{1'b0}}),
    .flush_branch_mask({`BRANCH_MASK_W{1'b0}}),
    .flush_node_mask({`NODE_MASK_W{1'b0}}),
    .entry_count(),
    .error_flag()
);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        token_wr_index_r <= {`TOKEN_REG_INDEX_W{1'b0}};
        captured_token_valid_r <= 1'b0;
        captured_token_id_r <= {`TOKEN_ID_W{1'b0}};
        captured_position_id_r <= {`POSITION_ID_W{1'b0}};
        lookup_sent_r <= 1'b0;
        lookup_hit_seen_r <= 1'b0;
        pe_req_sent_r <= 1'b0;
        pe_resp_seen_r <= 1'b0;
        lookup_sram_id_r <= {`SRAM_ID_W{1'b0}};
        lookup_bank_id_r <= {`BANK_ID_W{1'b0}};
        lookup_subbank_start_r <= {`SUBBANK_ID_W{1'b0}};
    end else if (!enable) begin
        token_wr_index_r <= {`TOKEN_REG_INDEX_W{1'b0}};
        captured_token_valid_r <= 1'b0;
        captured_token_id_r <= {`TOKEN_ID_W{1'b0}};
        captured_position_id_r <= {`POSITION_ID_W{1'b0}};
        lookup_sent_r <= 1'b0;
        lookup_hit_seen_r <= 1'b0;
        pe_req_sent_r <= 1'b0;
        pe_resp_seen_r <= 1'b0;
        lookup_sram_id_r <= {`SRAM_ID_W{1'b0}};
        lookup_bank_id_r <= {`BANK_ID_W{1'b0}};
        lookup_subbank_start_r <= {`SUBBANK_ID_W{1'b0}};
    end else begin
        if (token_wr_valid_w) begin
            token_wr_index_r <= token_wr_index_r + 1'b1;
            if (!captured_token_valid_r) begin
                captured_token_valid_r <= 1'b1;
                captured_token_id_r <= token_wr_token_id_w;
                captured_position_id_r <= token_wr_position_id_w;
            end
        end

        if (captured_token_valid_r && !lookup_sent_r && lookup_ready_w) begin
            lookup_sent_r <= 1'b1;
        end

        if (lookup_hit_fire_w) begin
            lookup_hit_seen_r <= 1'b1;
            lookup_sram_id_r <= lookup_resp_sram_id_w;
            lookup_bank_id_r <= lookup_resp_bank_id_w;
            lookup_subbank_start_r <= lookup_resp_subbank_start_w;
        end

        if (pe_req_fire_w) begin
            pe_req_sent_r <= 1'b1;
        end

        if (pe_resp_fire_w) begin
            pe_resp_seen_r <= 1'b1;
        end
    end
end

endmodule
