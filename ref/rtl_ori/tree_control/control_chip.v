`include "config/prediction_params.vh"
`timescale 1ns/1ps

`include "config/interface_params.vh"
`include "config/memory_params.vh"

module control_chip #(
    parameter CFG_W = 32
) (
    input                    clk,
    input                    rst_n,
    input                    cfg_valid,
    input  [CFG_W-1:0]       cfg_data,
    input                    start,
    input                    hbm_resp_valid,
    input  [`HBM_DATA_W-1:0] hbm_resp_rdata,
    input  [`REQ_ID_W-1:0]   hbm_resp_id,
    output                   busy,
    output                   error_flag,
    output                   hbm_req_valid,
    output                   hbm_req_write,
    output [`HBM_ADDR_W-1:0] hbm_req_addr,
    output [`HBM_DATA_W-1:0] hbm_req_wdata,
    output [`REQ_ID_W-1:0]   hbm_req_id
);

localparam integer PRIVATE_DEPTH_W =
    (((`MAX_VERIFY_NODES_PER_BRANCH + 1) <= 2) ? 1 :
     $clog2(`MAX_VERIFY_NODES_PER_BRANCH + 1));
localparam integer BRANCH_EPOCH_W = 2;
localparam integer PATH_PACK_W =
    (`BRANCH_NUM * `MAX_VERIFY_NODES_PER_BRANCH * `NODE_ID_W);
localparam integer DEPTH_PACK_W =
    (`BRANCH_NUM * PRIVATE_DEPTH_W);
localparam integer EPOCH_PACK_W =
    (`BRANCH_NUM * BRANCH_EPOCH_W);
localparam integer SRAM_LANE = 0;

localparam [`REQ_ID_W-1:0] FLUSH_REQ_ID = 4'ha;
localparam [`BRANCH_ID_W-1:0] VICTIM_BRANCH_ID = 2'd1;
localparam [`NODE_ID_W-1:0] VICTIM_NODE_ID = 4'd2;

reg scenario_busy_r;
reg victim_seen_r;
reg [`TOKEN_REG_INDEX_W-1:0] token_wr_index_r;
reg seen_first_scenario_r;
reg scenario_reentry_mode_r;
reg scenario_second_flush_mode_r;
reg scenario_second_flush_writeback_mode_r;
reg scenario_post_reentry_flush_writeback_mode_r;
reg scenario_third_flush_mode_r;
reg scenario_third_flush_writeback_mode_r;
reg scenario_second_post_reentry_flush_writeback_mode_r;
reg scenario_variable_len_token_writeback_mode_r;
reg scenario_dual_tree_near_steady_state_mode_r;
reg scenario_tree_driven_strict_serial_mode_r;
reg scenario_tree_driven_serial_long_span_mode_r;
reg scenario_tree_driven_reusable_idle_final_mode_r;
reg [1:0] scenario_variable_len_token_count_sel_r;
reg [1:0] scenario_dual_tree_flush_target_r;
reg [7:0] scenario_tree_descriptor_id_r;

wire scenario_start;
wire scenario_done;
wire scenario_wave3_flush_mode_w;
wire scenario_wave3_post_reentry_flush_writeback_mode_w;
wire scenario_wave2_post_reentry_flush_writeback_mode_w;
wire scenario_tree_driven_any_mode_w;

wire pred_tree_req_valid;
wire pred_tree_req_ready;
wire [`REQ_ID_W-1:0] pred_tree_req_id;
wire [`TREE_MAX_PREFIX_NODES-1:0] pred_src_prefix_slot_valid;
wire [`TREE_MAX_PREFIX_NODES*`NODE_ID_W-1:0] pred_src_prefix_node_id;
wire [`TREE_MAX_FRONTIER_LEVELS-1:0] pred_src_frontier_level_valid;
wire [`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS-1:0]
    pred_src_frontier_slot_valid;
wire [`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0]
    pred_src_frontier_node_id;
wire [`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0]
    pred_src_frontier_parent_node_id;
wire pred_tree_in_valid;
wire pred_tree_in_ready;
wire [`REQ_ID_W-1:0] pred_tree_in_req_id;
wire [`BRANCH_ID_W-1:0] pred_tree_in_branch_id;
wire [`NODE_ID_W-1:0] pred_tree_in_node_id;
wire [`REQ_ID_W-1:0] pred_cmp_req_id;
wire [`BRANCH_NUM-1:0] pred_cmp_slot_valid;
wire [`BRANCH_NUM*`TOKEN_ID_W-1:0] pred_cmp_slot_real_token_id;
wire [`BRANCH_NUM*`TOKEN_ID_W-1:0] pred_cmp_slot_candidate_token_id;
wire [`BRANCH_NUM*`NODE_ID_W-1:0] pred_cmp_slot_node_id;
wire [`BRANCH_NUM*`NODE_ID_W-1:0] pred_cmp_slot_parent_node_id;
wire [`BRANCH_NUM*`BRANCH_ID_W-1:0] pred_cmp_slot_branch_id;
wire flush_done;
wire tree_verify_done;
wire [2:0] effective_flush_count;
wire stale_event_drop_seen;

wire prep_done;
wire lookup_valid;
wire lookup_ready;
wire [`REQ_ID_W-1:0] lookup_req_id;
wire [`TOKEN_ID_W-1:0] lookup_token_id;
wire [`POSITION_ID_W-1:0] lookup_position_id;
wire lookup_resp_valid;
wire lookup_resp_hit;
wire [`REQ_ID_W-1:0] lookup_resp_req_id;
wire [`SRAM_ID_W-1:0] lookup_resp_sram_id;
wire [`BANK_ID_W-1:0] lookup_resp_bank_id;
wire [`SUBBANK_ID_W-1:0] lookup_resp_subbank_start;
wire [`KV_GROUP_LEN_W-1:0] lookup_resp_group_len;
wire [`BRANCH_MASK_W-1:0] lookup_resp_branch_mask;
wire lookup_resp_is_shared;
wire [`TOKEN_STATE_W-1:0] lookup_resp_state;

wire prep_req_valid;
wire prep_req_write;
wire [`SRAM_ADDR_W-1:0] prep_req_addr;
wire [`SRAM_WDATA_W-1:0] prep_req_wdata;
wire [`REQ_ID_W-1:0] prep_req_id;

wire pe_req_valid;
wire pe_req_ready;
wire pe_req_write;
wire [`SRAM_ADDR_W-1:0] pe_req_addr;
wire [`SRAM_WDATA_W-1:0] pe_req_wdata;
wire [`REQ_ID_W-1:0] pe_req_req_id;
wire [`PE_MASK_W-1:0] pe_req_pe_mask;
wire [`REQ_PRIORITY_W-1:0] pe_req_priority;
wire [`BANK_ID_W-1:0] pe_req_bank_id;
wire [`SUBBANK_ID_W-1:0] pe_req_subbank_id;
wire pe_resp_ready_lane0;

wire survivor_meta_valid;
wire [`TOKEN_REG_INDEX_W-1:0] survivor_commit_index;
wire [`REQ_ID_W-1:0] survivor_commit_req_id;
wire [`BRANCH_MASK_W-1:0] survivor_commit_branch_mask;
wire [`NODE_MASK_W-1:0] survivor_commit_node_mask;
wire [`SRAM_ID_W-1:0] survivor_commit_sram_id;
wire [`BANK_ID_W-1:0] survivor_commit_bank_id;
wire [`SUBBANK_ID_W-1:0] survivor_commit_subbank_start;
wire [`KV_GROUP_LEN_W-1:0] survivor_commit_group_len;
wire survivor_read_done;
wire [`SRAM_RDATA_W-1:0] survivor_read_data;
wire [`TOKEN_ID_W-1:0] survivor_new_token_len;
wire [`TOKEN_ID_W-1:0] survivor_new_token0;
wire [`TOKEN_ID_W-1:0] survivor_new_token1;
wire [`TOKEN_ID_W-1:0] survivor_new_token2;

wire token_commit_valid;
wire [`TOKEN_REG_INDEX_W-1:0] token_commit_index;
wire [`REQ_ID_W-1:0] token_commit_req_id;
wire [`BRANCH_MASK_W-1:0] token_commit_branch_mask;
wire [`NODE_MASK_W-1:0] token_commit_node_mask;
wire bank_commit_valid;
wire [`REQ_ID_W-1:0] bank_commit_req_id;
wire [`SRAM_ID_W-1:0] bank_commit_sram_id;
wire [`BANK_ID_W-1:0] bank_commit_bank_id;
wire [`SUBBANK_ID_W-1:0] bank_commit_subbank_start;
wire [`KV_GROUP_LEN_W-1:0] bank_commit_group_len;
wire [`BRANCH_MASK_W-1:0] bank_commit_branch_mask;
wire [`NODE_MASK_W-1:0] bank_commit_node_mask;
wire shim_hbm_req_valid;
wire shim_hbm_req_write;
wire [`HBM_ADDR_W-1:0] shim_hbm_req_addr;
wire [`HBM_DATA_W-1:0] shim_hbm_req_wdata;
wire [`REQ_ID_W-1:0] shim_hbm_req_id;

wire commit_valid;
wire [`BRANCH_MASK_W-1:0] commit_branch_mask;
wire [`NODE_MASK_W-1:0] commit_node_mask;
wire flush_valid;
wire [`BRANCH_MASK_W-1:0] flush_branch_mask;
wire [`NODE_MASK_W-1:0] flush_node_mask;
wire accepted_prefix_valid;
wire [`REQ_ID_W-1:0] accepted_prefix_req_id;
wire [PRIVATE_DEPTH_W-1:0] accepted_prefix_depth;
wire [(`MAX_VERIFY_NODES_PER_BRANCH*`NODE_ID_W)-1:0] accepted_prefix_node_id;
wire [`BRANCH_NUM-1:0] live_branch_mask;
wire [`BRANCH_NUM-1:0] prune_branch_mask;

wire prefix_valid;
wire prefix_ready;
wire [`REQ_ID_W-1:0] prefix_req_id;
wire prefix_node_valid;
wire [`NODE_ID_W-1:0] prefix_node_id;
wire [`NODE_ID_W-1:0] prefix_parent_node_id;
wire [`TOKEN_ID_W-1:0] prefix_token_id;
wire [`POSITION_ID_W-1:0] prefix_position_id;
wire [`LAYER_ID_W-1:0] prefix_layer_id;
wire prefix_is_last;
wire frontier_valid;
wire frontier_ready;
wire [`REQ_ID_W-1:0] frontier_req_id;
wire [`TREE_LEVEL_ID_W-1:0] frontier_level_id;
wire [`TREE_FRONTIER_SLOTS-1:0] frontier_slot_valid;
wire [`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0] frontier_node_id;
wire [`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0] frontier_parent_node_id;
wire [`TREE_FRONTIER_SLOTS*`TOKEN_ID_W-1:0] frontier_token_id;
wire [`TREE_FRONTIER_SLOTS*`POSITION_ID_W-1:0] frontier_position_id;

wire prefetch_enq_ready;
wire prefetch_enq_valid;
wire [`REQ_ID_W-1:0] prefetch_enq_req_id;
wire [`BRANCH_ID_W-1:0] prefetch_enq_branch_id;
wire [`NODE_ID_W-1:0] prefetch_enq_node_id;
wire [`LAYER_ID_W-1:0] prefetch_enq_layer_id;
wire [`KV_GROUP_LEN_W-1:0] prefetch_enq_size_subbank;
wire prefetch_enq_shared;
wire prefetch_flush_valid;
wire [`REQ_ID_W-1:0] prefetch_flush_req_id;
wire [`BRANCH_MASK_W-1:0] prefetch_flush_branch_mask;
wire [`NODE_MASK_W-1:0] prefetch_flush_node_mask;
wire queue_deq_valid;
wire queue_deq_ready;
wire [`REQ_ID_W-1:0] queue_deq_req_id;
wire [`BRANCH_ID_W-1:0] queue_deq_branch_id;
wire [`NODE_ID_W-1:0] queue_deq_node_id;
wire [`LAYER_ID_W-1:0] queue_deq_layer_id;
wire [`KV_GROUP_LEN_W-1:0] queue_deq_size_subbank;
wire queue_deq_shared;

wire cand_resp_valid;
wire cand_resp_grant;
wire [`REQ_ID_W-1:0] cand_resp_req_id;
wire [`SRAM_ID_W-1:0] cand_resp_sram_id;
wire [`BANK_ID_W-1:0] cand_resp_bank_id;
wire [`SUBBANK_ID_W-1:0] cand_resp_subbank_start;
wire [`KV_GROUP_LEN_W-1:0] cand_resp_group_len;
wire alloc_cand_valid;
wire [`REQ_ID_W-1:0] alloc_cand_req_id;
wire [`BRANCH_ID_W-1:0] alloc_cand_branch_id;
wire [`NODE_ID_W-1:0] alloc_cand_node_id;
wire [`KV_GROUP_LEN_W-1:0] alloc_cand_size_subbank;
wire alloc_cand_shared;
wire [`SRAM_ID_W-1:0] alloc_cand_sram_id;
wire [`BANK_ID_W-1:0] alloc_cand_bank_id;
wire [`SUBBANK_ID_W-1:0] alloc_cand_subbank_start;
wire [`KV_GROUP_LEN_W-1:0] alloc_cand_group_len;
wire free_list_flush_valid;
wire [`REQ_ID_W-1:0] free_list_flush_req_id;
wire [`BRANCH_MASK_W-1:0] free_list_flush_branch_mask;
wire [`NODE_MASK_W-1:0] free_list_flush_node_mask;
wire free_list_flush_drain_busy;
wire flush_reclaim_valid;
wire [`SRAM_ID_W-1:0] flush_reclaim_sram_id;
wire [`BANK_ID_W-1:0] flush_reclaim_bank_id;
wire [`SUBBANK_ID_W-1:0] flush_reclaim_subbank_start;
wire [`KV_GROUP_LEN_W-1:0] flush_reclaim_group_len;

wire alloc_resp_valid;
wire alloc_resp_grant;
wire [`REQ_ID_W-1:0] alloc_resp_req_id;
wire [`SRAM_ID_W-1:0] alloc_resp_sram_id;
wire [`BANK_ID_W-1:0] alloc_resp_bank_id;
wire [`SUBBANK_ID_W-1:0] alloc_resp_subbank_start;
wire [`KV_GROUP_LEN_W-1:0] alloc_resp_group_len;
wire [`BANK_OCC_BITMAP_W-1:0] alloc_resp_occ_bitmap;

wire token_wr_valid;
wire [`REQ_ID_W-1:0] token_wr_req_id;
wire [`TOKEN_ID_W-1:0] token_wr_token_id;
wire [`POSITION_ID_W-1:0] token_wr_position_id;
wire [`NODE_ID_W-1:0] token_wr_node_id;
wire [`BRANCH_ID_W-1:0] token_wr_branch_id;
wire [`BRANCH_MASK_W-1:0] token_wr_branch_mask;
wire token_wr_is_shared;
wire [`SRAM_ID_W-1:0] token_wr_sram_id;
wire [`BANK_ID_W-1:0] token_wr_bank_id;
wire [`SUBBANK_ID_W-1:0] token_wr_subbank_start;
wire [`KV_GROUP_LEN_W-1:0] token_wr_group_len;
wire token_flush_valid;
wire [`REQ_ID_W-1:0] token_flush_req_id;
wire [`BRANCH_MASK_W-1:0] token_flush_branch_mask;
wire [`NODE_MASK_W-1:0] token_flush_node_mask;
wire [`TOKEN_REG_INDEX_W:0] token_entry_count;
wire token_error_flag;

wire [`MEM_REQ_LANES-1:0] rc_mem_req_valid;
wire [`MEM_REQ_LANES-1:0] rc_mem_req_ready;
wire [`MEM_REQ_LANES-1:0] rc_mem_req_write;
wire [`MEM_REQ_LANES*`SRAM_ADDR_W-1:0] rc_mem_req_addr;
wire [`MEM_REQ_LANES*`SRAM_WDATA_W-1:0] rc_mem_req_wdata;
wire [`MEM_REQ_LANES*`REQ_ID_W-1:0] rc_mem_req_id;
wire [`MEM_REQ_LANES-1:0] sram_mem_req_valid;
wire [`MEM_REQ_LANES-1:0] sram_mem_req_ready;
wire [`MEM_REQ_LANES-1:0] sram_mem_req_write;
wire [`MEM_REQ_LANES*`SRAM_ADDR_W-1:0] sram_mem_req_addr;
wire [`MEM_REQ_LANES*`SRAM_WDATA_W-1:0] sram_mem_req_wdata;
wire [`MEM_REQ_LANES*`REQ_ID_W-1:0] sram_mem_req_id;
wire [`MEM_REQ_LANES-1:0] sram_mem_resp_valid;
wire [`MEM_REQ_LANES*`SRAM_RDATA_W-1:0] sram_mem_resp_rdata;
wire [`MEM_REQ_LANES*`REQ_ID_W-1:0] sram_mem_resp_id;
wire [`MEM_REQ_LANES-1:0] sram_mem_resp_last;
wire [`MEM_REQ_LANES-1:0] pe_resp_valid;
wire [`MEM_REQ_LANES*`SRAM_RDATA_W-1:0] pe_resp_rdata;
wire [`MEM_REQ_LANES*`REQ_ID_W-1:0] pe_resp_req_id;
wire [`MEM_REQ_LANES*`PE_MASK_W-1:0] pe_resp_pe_mask;
wire [`MEM_REQ_LANES-1:0] pe_resp_last;
wire [`MEM_REQ_LANES-1:0] pe_resp_ready_bus;

assign scenario_start = cfg_valid && start && !scenario_busy_r;
assign scenario_tree_driven_any_mode_w =
    scenario_tree_driven_strict_serial_mode_r ||
    scenario_tree_driven_serial_long_span_mode_r ||
    scenario_tree_driven_reusable_idle_final_mode_r;
assign pe_resp_ready_bus =
    (scenario_dual_tree_near_steady_state_mode_r ||
     scenario_tree_driven_any_mode_w) ?
        {{(`MEM_REQ_LANES-1){1'b1}}, pe_resp_ready_lane0} :
        {{(`MEM_REQ_LANES-1){1'b0}}, pe_resp_ready_lane0};

assign sram_mem_req_valid =
    prep_req_valid ? {{(`MEM_REQ_LANES-1){1'b0}}, 1'b1} : rc_mem_req_valid;
assign sram_mem_req_write =
    prep_req_valid ? {{(`MEM_REQ_LANES-1){1'b0}}, prep_req_write} :
                     rc_mem_req_write;
assign sram_mem_req_addr =
    prep_req_valid ?
        {{((`MEM_REQ_LANES-1)*`SRAM_ADDR_W){1'b0}}, prep_req_addr} :
        rc_mem_req_addr;
assign sram_mem_req_wdata =
    prep_req_valid ?
        {{((`MEM_REQ_LANES-1)*`SRAM_WDATA_W){1'b0}}, prep_req_wdata} :
        rc_mem_req_wdata;
assign sram_mem_req_id =
    prep_req_valid ?
        {{((`MEM_REQ_LANES-1)*`REQ_ID_W){1'b0}}, prep_req_id} :
        rc_mem_req_id;
assign rc_mem_req_ready =
    prep_req_valid ? {`MEM_REQ_LANES{1'b0}} : sram_mem_req_ready;

assign busy = scenario_busy_r;
assign error_flag = token_error_flag;
assign hbm_req_valid = shim_hbm_req_valid;
assign hbm_req_write = shim_hbm_req_write;
assign hbm_req_addr = shim_hbm_req_addr;
assign hbm_req_wdata = shim_hbm_req_wdata;
assign hbm_req_id = shim_hbm_req_id;
assign scenario_wave3_post_reentry_flush_writeback_mode_w =
    scenario_third_flush_writeback_mode_r ||
    scenario_second_post_reentry_flush_writeback_mode_r;
assign scenario_wave3_flush_mode_w =
    scenario_third_flush_mode_r ||
    scenario_wave3_post_reentry_flush_writeback_mode_w;
assign scenario_wave2_post_reentry_flush_writeback_mode_w =
    scenario_second_flush_writeback_mode_r ||
    scenario_post_reentry_flush_writeback_mode_r;

prediction_unit_bounded_stub #(
    .CFG_W(CFG_W)
) u_prediction_unit_bounded_stub (
    .clk(clk),
    .rst_n(rst_n),
    .scenario_start(scenario_start),
    .scenario_reentry_mode(scenario_reentry_mode_r),
    .scenario_second_flush_mode(scenario_second_flush_mode_r),
    .scenario_second_flush_writeback_mode(
        scenario_wave2_post_reentry_flush_writeback_mode_w),
    .scenario_third_flush_mode(scenario_wave3_flush_mode_w),
    .scenario_variable_len_token_writeback_mode(
        scenario_variable_len_token_writeback_mode_r),
    .scenario_dual_tree_near_steady_state_mode(
        scenario_dual_tree_near_steady_state_mode_r),
    .scenario_dual_tree_flush_target(
        scenario_dual_tree_flush_target_r),
    .scenario_tree_driven_strict_serial_mode(
        scenario_tree_driven_any_mode_w),
    .scenario_tree_descriptor_id(
        scenario_tree_descriptor_id_r),
    .tree_req_ready(pred_tree_req_ready),
    .tree_in_ready(pred_tree_in_ready),
    .prep_done(prep_done),
    .victim_seen(victim_seen_r),
    .survivor_read_done(survivor_read_done),
    .tree_req_valid(pred_tree_req_valid),
    .tree_req_id(pred_tree_req_id),
    .src_prefix_slot_valid(pred_src_prefix_slot_valid),
    .src_prefix_node_id(pred_src_prefix_node_id),
    .src_frontier_level_valid(pred_src_frontier_level_valid),
    .src_frontier_slot_valid(pred_src_frontier_slot_valid),
    .src_frontier_node_id(pred_src_frontier_node_id),
    .src_frontier_parent_node_id(pred_src_frontier_parent_node_id),
    .tree_in_valid(pred_tree_in_valid),
    .tree_in_req_id(pred_tree_in_req_id),
    .tree_in_branch_id(pred_tree_in_branch_id),
    .tree_in_node_id(pred_tree_in_node_id),
    .cmp_req_id(pred_cmp_req_id),
    .cmp_slot_valid(pred_cmp_slot_valid),
    .cmp_slot_real_token_id(pred_cmp_slot_real_token_id),
    .cmp_slot_candidate_token_id(pred_cmp_slot_candidate_token_id),
    .cmp_slot_node_id(pred_cmp_slot_node_id),
    .cmp_slot_parent_node_id(pred_cmp_slot_parent_node_id),
    .cmp_slot_branch_id(pred_cmp_slot_branch_id),
    .flush_done(flush_done),
    .tree_verify_done(tree_verify_done),
    .effective_flush_count(effective_flush_count),
    .stale_event_drop_seen(stale_event_drop_seen)
);

compute_module_bounded_stub u_compute_module_bounded_stub (
    .clk(clk),
    .rst_n(rst_n),
    .scenario_start(scenario_start),
    .scenario_reentry_mode(scenario_reentry_mode_r),
    .scenario_second_flush_mode(scenario_second_flush_mode_r),
    .scenario_second_flush_writeback_mode(
        scenario_wave2_post_reentry_flush_writeback_mode_w),
    .scenario_third_flush_mode(scenario_wave3_flush_mode_w),
    .scenario_variable_len_token_writeback_mode(
        scenario_variable_len_token_writeback_mode_r),
    .scenario_variable_len_token_count_sel(
        scenario_variable_len_token_count_sel_r),
    .scenario_dual_tree_near_steady_state_mode(
        scenario_dual_tree_near_steady_state_mode_r),
    .scenario_dual_tree_flush_target(
        scenario_dual_tree_flush_target_r),
    .scenario_tree_driven_strict_serial_mode(
        scenario_tree_driven_any_mode_w),
    .tree_verify_done(tree_verify_done),
    .effective_flush_count(effective_flush_count),
    .flush_done(flush_done),
    .token_wr_valid(token_wr_valid),
    .token_wr_index(token_wr_index_r),
    .token_wr_req_id(token_wr_req_id),
    .token_wr_token_id(token_wr_token_id),
    .token_wr_position_id(token_wr_position_id),
    .token_wr_node_id(token_wr_node_id),
    .token_wr_branch_id(token_wr_branch_id),
    .token_wr_branch_mask(token_wr_branch_mask),
    .token_wr_is_shared(token_wr_is_shared),
    .lookup_ready(lookup_ready),
    .lookup_valid(lookup_valid),
    .lookup_req_id(lookup_req_id),
    .lookup_token_id(lookup_token_id),
    .lookup_position_id(lookup_position_id),
    .lookup_resp_valid(lookup_resp_valid),
    .lookup_resp_hit(lookup_resp_hit),
    .lookup_resp_req_id(lookup_resp_req_id),
    .lookup_resp_sram_id(lookup_resp_sram_id),
    .lookup_resp_bank_id(lookup_resp_bank_id),
    .lookup_resp_subbank_start(lookup_resp_subbank_start),
    .lookup_resp_group_len(lookup_resp_group_len),
    .prep_ready(sram_mem_req_ready[SRAM_LANE]),
    .prep_valid(prep_req_valid),
    .prep_write(prep_req_write),
    .prep_addr(prep_req_addr),
    .prep_wdata(prep_req_wdata),
    .prep_req_id(prep_req_id),
    .pe_req_ready(pe_req_ready),
    .pe_req_valid(pe_req_valid),
    .pe_req_write(pe_req_write),
    .pe_req_addr(pe_req_addr),
    .pe_req_wdata(pe_req_wdata),
    .pe_req_req_id(pe_req_req_id),
    .pe_req_pe_mask(pe_req_pe_mask),
    .pe_req_priority(pe_req_priority),
    .pe_req_bank_id(pe_req_bank_id),
    .pe_req_subbank_id(pe_req_subbank_id),
    .pe_resp_valid(pe_resp_valid[SRAM_LANE]),
    .pe_resp_rdata(pe_resp_rdata[(SRAM_LANE*`SRAM_RDATA_W) +:
                                 `SRAM_RDATA_W]),
    .pe_resp_req_id(pe_resp_req_id[(SRAM_LANE*`REQ_ID_W) +: `REQ_ID_W]),
    .pe_resp_last(pe_resp_last[SRAM_LANE]),
    .pe_resp_ready(pe_resp_ready_lane0),
    .prep_done(prep_done),
    .survivor_meta_valid(survivor_meta_valid),
    .survivor_commit_index(survivor_commit_index),
    .survivor_commit_req_id(survivor_commit_req_id),
    .survivor_commit_branch_mask(survivor_commit_branch_mask),
    .survivor_commit_node_mask(survivor_commit_node_mask),
    .survivor_commit_sram_id(survivor_commit_sram_id),
    .survivor_commit_bank_id(survivor_commit_bank_id),
    .survivor_commit_subbank_start(survivor_commit_subbank_start),
    .survivor_commit_group_len(survivor_commit_group_len),
    .survivor_read_done(survivor_read_done),
    .survivor_read_data(survivor_read_data),
    .survivor_new_token_len(survivor_new_token_len),
    .survivor_new_token0(survivor_new_token0),
    .survivor_new_token1(survivor_new_token1),
    .survivor_new_token2(survivor_new_token2)
);

commit_writeback_bounded_shim u_commit_writeback_bounded_shim (
    .clk(clk),
    .rst_n(rst_n),
    .scenario_start(scenario_start),
    .scenario_reentry_mode(scenario_reentry_mode_r),
    .scenario_second_flush_mode(scenario_second_flush_mode_r),
    .scenario_second_flush_writeback_mode(
        scenario_wave2_post_reentry_flush_writeback_mode_w),
    .scenario_third_flush_mode(scenario_wave3_flush_mode_w),
    .scenario_third_flush_writeback_mode(
        scenario_wave3_post_reentry_flush_writeback_mode_w),
    .scenario_dual_tree_near_steady_state_mode(
        scenario_dual_tree_near_steady_state_mode_r),
    .scenario_dual_tree_flush_target(
        scenario_dual_tree_flush_target_r),
    .scenario_tree_driven_strict_serial_mode(
        scenario_tree_driven_any_mode_w),
    .scenario_variable_len_token_count_sel(
        scenario_variable_len_token_count_sel_r),
    .tree_verify_done(tree_verify_done),
    .effective_flush_count(effective_flush_count),
    .survivor_meta_valid(survivor_meta_valid),
    .survivor_commit_index(survivor_commit_index),
    .survivor_commit_req_id(survivor_commit_req_id),
    .survivor_commit_branch_mask(survivor_commit_branch_mask),
    .survivor_commit_node_mask(survivor_commit_node_mask),
    .survivor_commit_sram_id(survivor_commit_sram_id),
    .survivor_commit_bank_id(survivor_commit_bank_id),
    .survivor_commit_subbank_start(survivor_commit_subbank_start),
    .survivor_commit_group_len(survivor_commit_group_len),
    .flush_done(flush_done),
    .survivor_read_done(survivor_read_done),
    .survivor_read_data(survivor_read_data),
    .survivor_new_token_len(survivor_new_token_len),
    .survivor_new_token0(survivor_new_token0),
    .survivor_new_token1(survivor_new_token1),
    .survivor_new_token2(survivor_new_token2),
    .token_commit_valid(token_commit_valid),
    .token_commit_index(token_commit_index),
    .token_commit_req_id(token_commit_req_id),
    .token_commit_branch_mask(token_commit_branch_mask),
    .token_commit_node_mask(token_commit_node_mask),
    .bank_commit_valid(bank_commit_valid),
    .bank_commit_req_id(bank_commit_req_id),
    .bank_commit_sram_id(bank_commit_sram_id),
    .bank_commit_bank_id(bank_commit_bank_id),
    .bank_commit_subbank_start(bank_commit_subbank_start),
    .bank_commit_group_len(bank_commit_group_len),
    .bank_commit_branch_mask(bank_commit_branch_mask),
    .bank_commit_node_mask(bank_commit_node_mask),
    .hbm_req_valid(shim_hbm_req_valid),
    .hbm_req_write(shim_hbm_req_write),
    .hbm_req_addr(shim_hbm_req_addr),
    .hbm_req_wdata(shim_hbm_req_wdata),
    .hbm_req_id(shim_hbm_req_id),
    .scenario_done(scenario_done)
);

comparator u_comparator (
    .clk(clk),
    .rst_n(rst_n),
    .cmp_req_id(pred_cmp_req_id),
    .cmp_slot_valid(pred_cmp_slot_valid),
    .cmp_slot_real_token_id(pred_cmp_slot_real_token_id),
    .cmp_slot_candidate_token_id(pred_cmp_slot_candidate_token_id),
    .cmp_slot_node_id(pred_cmp_slot_node_id),
    .cmp_slot_parent_node_id(pred_cmp_slot_parent_node_id),
    .cmp_slot_branch_id(pred_cmp_slot_branch_id),
    .reduce_start_valid(1'b0),
    .reduce_req_id({`REQ_ID_W{1'b0}}),
    .active_branch_valid({`BRANCH_NUM{1'b0}}),
    .active_branch_epoch({EPOCH_PACK_W{1'b0}}),
    .active_branch_depth({DEPTH_PACK_W{1'b0}}),
    .active_branch_node_id({PATH_PACK_W{1'b0}}),
    .active_branch_parent_node_id({PATH_PACK_W{1'b0}}),
    .result_slot_valid({`BRANCH_NUM{1'b0}}),
    .result_req_id({`REQ_ID_W{1'b0}}),
    .result_branch_id({(`BRANCH_NUM*`BRANCH_ID_W){1'b0}}),
    .result_branch_epoch({EPOCH_PACK_W{1'b0}}),
    .result_private_depth({DEPTH_PACK_W{1'b0}}),
    .result_node_id({(`BRANCH_NUM*`NODE_ID_W){1'b0}}),
    .result_parent_node_id({(`BRANCH_NUM*`NODE_ID_W){1'b0}}),
    .result_accept({`BRANCH_NUM{1'b0}}),
    .commit_valid(commit_valid),
    .commit_branch_mask(commit_branch_mask),
    .commit_node_mask(commit_node_mask),
    .flush_valid(flush_valid),
    .flush_branch_mask(flush_branch_mask),
    .flush_node_mask(flush_node_mask),
    .accepted_prefix_valid(accepted_prefix_valid),
    .accepted_prefix_req_id(accepted_prefix_req_id),
    .accepted_prefix_depth(accepted_prefix_depth),
    .accepted_prefix_node_id(accepted_prefix_node_id),
    .live_branch_mask(live_branch_mask),
    .prune_branch_mask(prune_branch_mask)
);

tree_analyze u_tree_analyze (
    .clk(clk),
    .rst_n(rst_n),
    .req_valid(pred_tree_req_valid),
    .req_ready(pred_tree_req_ready),
    .req_id(pred_tree_req_id),
    .src_prefix_slot_valid(pred_src_prefix_slot_valid),
    .src_prefix_node_id(pred_src_prefix_node_id),
    .src_frontier_level_valid(pred_src_frontier_level_valid),
    .src_frontier_slot_valid(pred_src_frontier_slot_valid),
    .src_frontier_node_id(pred_src_frontier_node_id),
    .src_frontier_parent_node_id(pred_src_frontier_parent_node_id),
    .prefix_valid(prefix_valid),
    .prefix_ready(prefix_ready),
    .prefix_req_id(prefix_req_id),
    .prefix_node_valid(prefix_node_valid),
    .prefix_node_id(prefix_node_id),
    .prefix_parent_node_id(prefix_parent_node_id),
    .prefix_token_id(prefix_token_id),
    .prefix_position_id(prefix_position_id),
    .prefix_layer_id(prefix_layer_id),
    .prefix_is_last(prefix_is_last),
    .frontier_valid(frontier_valid),
    .frontier_ready(frontier_ready),
    .frontier_req_id(frontier_req_id),
    .frontier_level_id(frontier_level_id),
    .frontier_slot_valid(frontier_slot_valid),
    .frontier_node_id(frontier_node_id),
    .frontier_parent_node_id(frontier_parent_node_id),
    .frontier_token_id(frontier_token_id),
    .frontier_position_id(frontier_position_id)
);

agu u_agu (
    .clk(clk),
    .rst_n(rst_n),
    .tree_in_valid(pred_tree_in_valid),
    .tree_in_ready(pred_tree_in_ready),
    .tree_in_req_id(pred_tree_in_req_id),
    .tree_in_branch_id(pred_tree_in_branch_id),
    .tree_in_node_id(pred_tree_in_node_id),
    .prefix_valid(prefix_valid),
    .prefix_ready(prefix_ready),
    .prefix_req_id(prefix_req_id),
    .prefix_node_valid(prefix_node_valid),
    .prefix_node_id(prefix_node_id),
    .prefix_parent_node_id(prefix_parent_node_id),
    .prefix_token_id(prefix_token_id),
    .prefix_position_id(prefix_position_id),
    .prefix_layer_id(prefix_layer_id),
    .prefix_is_last(prefix_is_last),
    .frontier_valid(frontier_valid),
    .frontier_ready(frontier_ready),
    .frontier_req_id(frontier_req_id),
    .frontier_level_id(frontier_level_id),
    .frontier_slot_valid(frontier_slot_valid),
    .frontier_node_id(frontier_node_id),
    .frontier_parent_node_id(frontier_parent_node_id),
    .frontier_token_id(frontier_token_id),
    .frontier_position_id(frontier_position_id),
    .prefetch_enq_ready(prefetch_enq_ready),
    .cand_resp_valid(cand_resp_valid),
    .cand_resp_grant(cand_resp_grant),
    .cand_resp_req_id(cand_resp_req_id),
    .cand_resp_sram_id(cand_resp_sram_id),
    .cand_resp_bank_id(cand_resp_bank_id),
    .cand_resp_subbank_start(cand_resp_subbank_start),
    .cand_resp_group_len(cand_resp_group_len),
    .alloc_resp_valid(alloc_resp_valid),
    .alloc_resp_grant(alloc_resp_grant),
    .alloc_resp_req_id(alloc_resp_req_id),
    .alloc_resp_sram_id(alloc_resp_sram_id),
    .alloc_resp_bank_id(alloc_resp_bank_id),
    .alloc_resp_subbank_start(alloc_resp_subbank_start),
    .alloc_resp_group_len(alloc_resp_group_len),
    .flush_freeze(flush_valid),
    .flush_drain_busy(free_list_flush_drain_busy),
    .flush_ctrl_valid(flush_valid),
    .flush_ctrl_req_id(pred_cmp_req_id),
    .flush_ctrl_branch_mask(flush_branch_mask),
    .flush_ctrl_node_mask(flush_node_mask),
    .branch_liveness_valid(accepted_prefix_valid),
    .branch_liveness_req_id(accepted_prefix_req_id),
    .branch_liveness_live_mask(live_branch_mask),
    .branch_liveness_prune_mask(prune_branch_mask),
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
    .alloc_cand_valid(),
    .alloc_cand_req_id(),
    .alloc_cand_branch_id(),
    .alloc_cand_node_id(),
    .alloc_cand_size_subbank(),
    .alloc_cand_shared(),
    .alloc_cand_sram_id(),
    .alloc_cand_bank_id(),
    .alloc_cand_subbank_start(),
    .alloc_cand_group_len(),
    .token_wr_valid(token_wr_valid),
    .token_wr_req_id(token_wr_req_id),
    .token_wr_token_id(token_wr_token_id),
    .token_wr_position_id(token_wr_position_id),
    .token_wr_node_id(token_wr_node_id),
    .token_wr_branch_id(token_wr_branch_id),
    .token_wr_branch_mask(token_wr_branch_mask),
    .token_wr_is_shared(token_wr_is_shared),
    .token_wr_sram_id(token_wr_sram_id),
    .token_wr_bank_id(token_wr_bank_id),
    .token_wr_subbank_start(token_wr_subbank_start),
    .token_wr_group_len(token_wr_group_len),
    .prefetch_enq_valid(prefetch_enq_valid),
    .prefetch_enq_req_id(prefetch_enq_req_id),
    .prefetch_enq_branch_id(prefetch_enq_branch_id),
    .prefetch_enq_node_id(prefetch_enq_node_id),
    .prefetch_enq_layer_id(prefetch_enq_layer_id),
    .prefetch_enq_size_subbank(prefetch_enq_size_subbank),
    .prefetch_enq_shared(prefetch_enq_shared),
    .prefetch_flush_valid(prefetch_flush_valid),
    .prefetch_flush_req_id(prefetch_flush_req_id),
    .prefetch_flush_branch_mask(prefetch_flush_branch_mask),
    .prefetch_flush_node_mask(prefetch_flush_node_mask),
    .free_list_flush_valid(free_list_flush_valid),
    .free_list_flush_req_id(free_list_flush_req_id),
    .free_list_flush_branch_mask(free_list_flush_branch_mask),
    .free_list_flush_node_mask(free_list_flush_node_mask),
    .token_flush_valid(token_flush_valid),
    .token_flush_req_id(token_flush_req_id),
    .token_flush_branch_mask(token_flush_branch_mask),
    .token_flush_node_mask(token_flush_node_mask)
);

prefetch_queue u_prefetch_queue (
    .clk(clk),
    .rst_n(rst_n),
    .enq_valid(prefetch_enq_valid),
    .enq_ready(prefetch_enq_ready),
    .enq_req_id(prefetch_enq_req_id),
    .enq_branch_id(prefetch_enq_branch_id),
    .enq_node_id(prefetch_enq_node_id),
    .enq_layer_id(prefetch_enq_layer_id),
    .enq_size_subbank(prefetch_enq_size_subbank),
    .enq_shared(prefetch_enq_shared),
    .flush_valid(prefetch_flush_valid),
    .flush_req_id(prefetch_flush_req_id),
    .flush_branch_mask(prefetch_flush_branch_mask),
    .flush_node_mask(prefetch_flush_node_mask),
    .deq_valid(queue_deq_valid),
    .deq_ready(queue_deq_ready),
    .deq_req_id(queue_deq_req_id),
    .deq_branch_id(queue_deq_branch_id),
    .deq_node_id(queue_deq_node_id),
    .deq_layer_id(queue_deq_layer_id),
    .deq_size_subbank(queue_deq_size_subbank),
    .deq_shared(queue_deq_shared)
);

free_list u_free_list (
    .clk(clk),
    .rst_n(rst_n),
    .cand_req_valid(queue_deq_valid),
    .cand_req_ready(queue_deq_ready),
    .cand_req_req_id(queue_deq_req_id),
    .cand_req_branch_id(queue_deq_branch_id),
    .cand_req_node_id(queue_deq_node_id),
    .cand_req_size_subbank(queue_deq_size_subbank),
    .cand_req_shared(queue_deq_shared),
    .cand_resp_valid(cand_resp_valid),
    .cand_resp_grant(cand_resp_grant),
    .cand_resp_req_id(cand_resp_req_id),
    .cand_resp_sram_id(cand_resp_sram_id),
    .cand_resp_bank_id(cand_resp_bank_id),
    .cand_resp_subbank_start(cand_resp_subbank_start),
    .cand_resp_group_len(cand_resp_group_len),
    .alloc_cand_valid(alloc_cand_valid),
    .alloc_cand_req_id(alloc_cand_req_id),
    .alloc_cand_branch_id(alloc_cand_branch_id),
    .alloc_cand_node_id(alloc_cand_node_id),
    .alloc_cand_size_subbank(alloc_cand_size_subbank),
    .alloc_cand_shared(alloc_cand_shared),
    .alloc_cand_sram_id(alloc_cand_sram_id),
    .alloc_cand_bank_id(alloc_cand_bank_id),
    .alloc_cand_subbank_start(alloc_cand_subbank_start),
    .alloc_cand_group_len(alloc_cand_group_len),
    .flush_valid(free_list_flush_valid),
    .flush_req_id(free_list_flush_req_id),
    .flush_branch_mask(free_list_flush_branch_mask),
    .flush_node_mask(free_list_flush_node_mask),
    .flush_drain_busy(free_list_flush_drain_busy),
    .flush_reclaim_valid(flush_reclaim_valid),
    .flush_reclaim_sram_id(flush_reclaim_sram_id),
    .flush_reclaim_bank_id(flush_reclaim_bank_id),
    .flush_reclaim_subbank_start(flush_reclaim_subbank_start),
    .flush_reclaim_group_len(flush_reclaim_group_len),
    .release_valid(1'b0),
    .release_sram_id({`SRAM_ID_W{1'b0}}),
    .release_bank_id({`BANK_ID_W{1'b0}}),
    .release_subbank_start({`SUBBANK_ID_W{1'b0}}),
    .release_group_len({`KV_GROUP_LEN_W{1'b0}})
);

bank_state_table u_bank_state_table (
    .clk(clk),
    .rst_n(rst_n),
    .cand_valid(alloc_cand_valid),
    .cand_ready(),
    .cand_req_id(alloc_cand_req_id),
    .cand_branch_id(alloc_cand_branch_id),
    .cand_node_id(alloc_cand_node_id),
    .cand_size_subbank(alloc_cand_size_subbank),
    .cand_shared(alloc_cand_shared),
    .cand_sram_id(alloc_cand_sram_id),
    .cand_bank_id(alloc_cand_bank_id),
    .cand_subbank_start(alloc_cand_subbank_start),
    .cand_group_len(alloc_cand_group_len),
    .alloc_resp_valid(alloc_resp_valid),
    .alloc_resp_grant(alloc_resp_grant),
    .alloc_resp_req_id(alloc_resp_req_id),
    .alloc_resp_sram_id(alloc_resp_sram_id),
    .alloc_resp_bank_id(alloc_resp_bank_id),
    .alloc_resp_subbank_start(alloc_resp_subbank_start),
    .alloc_resp_group_len(alloc_resp_group_len),
    .alloc_resp_occ_bitmap(alloc_resp_occ_bitmap),
    .commit_valid(bank_commit_valid),
    .commit_req_id(bank_commit_req_id),
    .commit_sram_id(bank_commit_sram_id),
    .commit_bank_id(bank_commit_bank_id),
    .commit_subbank_start(bank_commit_subbank_start),
    .commit_group_len(bank_commit_group_len),
    .commit_branch_mask(bank_commit_branch_mask),
    .commit_node_mask(bank_commit_node_mask),
    .flush_valid(1'b0),
    .flush_req_id({`REQ_ID_W{1'b0}}),
    .flush_branch_mask({`BRANCH_MASK_W{1'b0}}),
    .flush_node_mask({`NODE_MASK_W{1'b0}}),
    .reclaim_valid(flush_reclaim_valid),
    .reclaim_sram_id(flush_reclaim_sram_id),
    .reclaim_bank_id(flush_reclaim_bank_id),
    .reclaim_subbank_start(flush_reclaim_subbank_start),
    .reclaim_group_len(flush_reclaim_group_len),
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
    .wr_valid(token_wr_valid),
    .wr_ready(),
    .wr_index(token_wr_index_r),
    .wr_req_id(token_wr_req_id),
    .wr_token_id(token_wr_token_id),
    .wr_position_id(token_wr_position_id),
    .wr_node_id(token_wr_node_id),
    .wr_branch_id(token_wr_branch_id),
    .wr_sram_id(token_wr_sram_id),
    .wr_bank_id(token_wr_bank_id),
    .wr_subbank_start(token_wr_subbank_start),
    .wr_group_len(token_wr_group_len),
    .wr_branch_mask(token_wr_branch_mask),
    .wr_is_shared(token_wr_is_shared),
    .lookup_valid(lookup_valid),
    .lookup_ready(lookup_ready),
    .lookup_req_id(lookup_req_id),
    .lookup_token_id(lookup_token_id),
    .lookup_position_id(lookup_position_id),
    .lookup_resp_valid(lookup_resp_valid),
    .lookup_resp_hit(lookup_resp_hit),
    .lookup_resp_req_id(lookup_resp_req_id),
    .lookup_resp_sram_id(lookup_resp_sram_id),
    .lookup_resp_bank_id(lookup_resp_bank_id),
    .lookup_resp_subbank_start(lookup_resp_subbank_start),
    .lookup_resp_group_len(lookup_resp_group_len),
    .lookup_resp_branch_mask(lookup_resp_branch_mask),
    .lookup_resp_is_shared(lookup_resp_is_shared),
    .lookup_resp_state(lookup_resp_state),
    .commit_valid(token_commit_valid),
    .commit_index(token_commit_index),
    .commit_req_id(token_commit_req_id),
    .commit_branch_mask(token_commit_branch_mask),
    .commit_node_mask(token_commit_node_mask),
    .flush_valid(token_flush_valid),
    .flush_req_id(token_flush_req_id),
    .flush_branch_mask(token_flush_branch_mask),
    .flush_node_mask(token_flush_node_mask),
    .entry_count(token_entry_count),
    .error_flag(token_error_flag)
);

request_controller u_request_controller (
    .clk(clk),
    .rst_n(rst_n),
    .req_in_valid(pe_req_valid),
    .req_in_ready(pe_req_ready),
    .req_in_write(pe_req_write),
    .req_in_addr(pe_req_addr),
    .req_in_wdata(pe_req_wdata),
    .req_in_req_id(pe_req_req_id),
    .req_in_pe_mask(pe_req_pe_mask),
    .req_in_priority(pe_req_priority),
    .req_in_bank_id(pe_req_bank_id),
    .req_in_subbank_id(pe_req_subbank_id),
    .mem_req_valid(rc_mem_req_valid),
    .mem_req_ready(rc_mem_req_ready),
    .mem_req_write(rc_mem_req_write),
    .mem_req_addr(rc_mem_req_addr),
    .mem_req_wdata(rc_mem_req_wdata),
    .mem_req_id(rc_mem_req_id),
    .mem_resp_valid(sram_mem_resp_valid),
    .mem_resp_rdata(sram_mem_resp_rdata),
    .mem_resp_id(sram_mem_resp_id),
    .mem_resp_last(sram_mem_resp_last),
    .resp_out_valid(pe_resp_valid),
    .resp_out_ready(pe_resp_ready_bus),
    .resp_out_rdata(pe_resp_rdata),
    .resp_out_req_id(pe_resp_req_id),
    .resp_out_pe_mask(pe_resp_pe_mask),
    .resp_out_last(pe_resp_last)
);

sram_subsystem u_sram_subsystem (
    .clk(clk),
    .rst_n(rst_n),
    .mem_req_valid(sram_mem_req_valid),
    .mem_req_ready(sram_mem_req_ready),
    .mem_req_write(sram_mem_req_write),
    .mem_req_addr(sram_mem_req_addr),
    .mem_req_wdata(sram_mem_req_wdata),
    .mem_req_id(sram_mem_req_id),
    .mem_resp_valid(sram_mem_resp_valid),
    .mem_resp_rdata(sram_mem_resp_rdata),
    .mem_resp_id(sram_mem_resp_id),
    .mem_resp_last(sram_mem_resp_last)
);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        scenario_busy_r <= 1'b0;
        victim_seen_r <= 1'b0;
        token_wr_index_r <= {`TOKEN_REG_INDEX_W{1'b0}};
        seen_first_scenario_r <= 1'b0;
        scenario_reentry_mode_r <= 1'b0;
        scenario_second_flush_mode_r <= 1'b0;
        scenario_second_flush_writeback_mode_r <= 1'b0;
        scenario_post_reentry_flush_writeback_mode_r <= 1'b0;
        scenario_third_flush_mode_r <= 1'b0;
        scenario_third_flush_writeback_mode_r <= 1'b0;
        scenario_second_post_reentry_flush_writeback_mode_r <= 1'b0;
        scenario_variable_len_token_writeback_mode_r <= 1'b0;
        scenario_dual_tree_near_steady_state_mode_r <= 1'b0;
        scenario_tree_driven_strict_serial_mode_r <= 1'b0;
        scenario_tree_driven_serial_long_span_mode_r <= 1'b0;
        scenario_tree_driven_reusable_idle_final_mode_r <= 1'b0;
        scenario_variable_len_token_count_sel_r <= 2'b00;
        scenario_dual_tree_flush_target_r <= 2'b00;
        scenario_tree_descriptor_id_r <= 8'h00;
    end else begin
        if (scenario_dual_tree_near_steady_state_mode_r) begin
            victim_seen_r <= 1'b0;
        end

        if (scenario_start) begin
            scenario_busy_r <= 1'b1;
            victim_seen_r <= 1'b0;
            token_wr_index_r <= {`TOKEN_REG_INDEX_W{1'b0}};
            scenario_reentry_mode_r <=
                seen_first_scenario_r &&
                (cfg_data[23:20] != 4'h8) &&
                (cfg_data[23:20] != 4'hc) &&
                (cfg_data[23:20] != 4'hd) &&
                (cfg_data[23:20] != 4'he) &&
                (cfg_data[23:20] != 4'hf);
            // Use one extra bounded mode bit so run_043 can extend wave 2
            // beyond run_042 without changing the real lower-level ownership.
            scenario_second_flush_mode_r <=
                seen_first_scenario_r && (cfg_data[23:20] == 4'h3);
            // Use one more bounded mode bit so run_044 can extend the proven
            // run_043 second-flush checkpoint into one bounded writeback
            // closure without changing the real lower-level ownership.
            scenario_second_flush_writeback_mode_r <=
                seen_first_scenario_r && (cfg_data[23:20] == 4'h4);
            // Use one dedicated bounded mode so run_050 can extend the proven
            // run_049 post-writeback re-entry slice into one later wave-2
            // flush plus postflush writeback closure without overloading the
            // historical run_044 selector.
            scenario_post_reentry_flush_writeback_mode_r <=
                seen_first_scenario_r && (cfg_data[23:20] == 4'ha);
            // Use one more bounded mode bit so run_046 can extend the
            // run_045 third-wave re-entry prefix into one bounded third flush
            // without changing the real lower-level ownership.
            scenario_third_flush_mode_r <=
                seen_first_scenario_r && (cfg_data[23:20] == 4'h6);
            // Use one more bounded mode bit so run_047 can extend the proven
            // run_046 third-flush checkpoint into one bounded wave-3
            // writeback closure without changing the real lower-level
            // ownership.
            scenario_third_flush_writeback_mode_r <=
                seen_first_scenario_r && (cfg_data[23:20] == 4'h7);
            // Use one dedicated bounded mode so run_051 can extend the proven
            // run_050 post-reentry flush/writeback closure into one later
            // wave-3 flush plus postflush writeback chain without overloading
            // the historical run_047 selector.
            scenario_second_post_reentry_flush_writeback_mode_r <=
                seen_first_scenario_r && (cfg_data[23:20] == 4'hb);
            // Use one dedicated bounded mode so run_048 can prove one
            // single-beat variable-length accepted-token writeback packet
            // without pulling a new flush event back into the same proof.
            scenario_variable_len_token_writeback_mode_r <=
                (cfg_data[23:20] == 4'h8);
            // Use one dedicated bounded mode so run_052 can script one
            // dual-tree near-steady-state witness without changing the real
            // lower-level ownership or adding SRAM-internal flush behavior.
            scenario_dual_tree_near_steady_state_mode_r <=
                (cfg_data[23:20] == 4'hc);
            // Use one dedicated bounded mode so run_055 can move from
            // helper-prewritten truth toward tree-driven strict-serial
            // descriptor selection without overloading historical selectors.
            scenario_tree_driven_strict_serial_mode_r <=
                (cfg_data[23:20] == 4'hd);
            // Use one dedicated bounded mode so run_056 can extend the
            // proven run_055 five-tree witness into one longer tree-driven
            // strict-serial long-span witness without overloading `4'hd`.
            scenario_tree_driven_serial_long_span_mode_r <=
                (cfg_data[23:20] == 4'he);
            // Use one dedicated bounded mode so run_057 can prove the final
            // strict-serial reusable-idle closure without overloading `4'he`.
            scenario_tree_driven_reusable_idle_final_mode_r <=
                (cfg_data[23:20] == 4'hf);
            scenario_variable_len_token_count_sel_r <= cfg_data[1:0];
            scenario_dual_tree_flush_target_r <= cfg_data[5:4];
            scenario_tree_descriptor_id_r <= cfg_data[7:0];
            seen_first_scenario_r <= 1'b1;
        end else begin
            if (scenario_done) begin
                scenario_busy_r <= 1'b0;
            end

            if (token_wr_valid) begin
                token_wr_index_r <= token_wr_index_r + 1'b1;
            end

            if (token_wr_valid &&
                (token_wr_req_id == FLUSH_REQ_ID) &&
                (scenario_dual_tree_near_steady_state_mode_r ||
                 ((token_wr_branch_id == VICTIM_BRANCH_ID) &&
                  (token_wr_node_id == VICTIM_NODE_ID)))) begin
                victim_seen_r <= 1'b1;
            end
        end
    end
end

endmodule
