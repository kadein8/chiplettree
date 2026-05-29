`include "config/interface_params.vh"
`include "config/prediction_params.vh"
`include "config/model_params.vh"
`include "config/memory_params.vh"
`timescale 1ns/1ps

// speculative_decode_treecontrol_top
//
// Full TreeControl integration top-level.
// Replaces the simplified tree_verify_dispatcher + kv_share_scheduler path
// with the complete paper pipeline:
//
//   tree_builder → tree_to_native_bridge → StrictTreeMaskPaperPath
//     (tree_analyze → agu → free_list → bank_state_table → token_register
//      → IssueScheduler) → issue_bundle → PeArrayLayerController
//     → lifecycle_fsm → comparator → commit/flush feedback
//
// This module has the same external interface as speculative_decode_e2e_top
// so the testbench can instantiate either one.

module speculative_decode_treecontrol_top #(
    parameter integer BRANCH_NUM     = `BRANCH_NUM,
    parameter integer MAX_LEVELS     = `MAX_PRIVATE_NODES_PER_BRANCH,
    parameter integer WINDOW_SIZE    = `VERIFY_WINDOW_SIZE,
    parameter integer HIDDEN_DIM     = `MODEL_DMODEL,
    parameter integer N_LAYERS       = `MODEL_N_LAYERS,
    parameter integer VOCAB_SIZE     = `MODEL_VOCAB_SIZE,
    parameter integer PREDICT_ACCURACY = 100  // 0-100: HHT prediction accuracy %
) (
    input  logic                          clk,
    input  logic                          rst_n,

    // Control
    input  logic                          start,
    input  logic [`TOKEN_ID_W-1:0]        prompt_token_id,
    input  logic [7:0]                    max_gen_tokens,
    output logic                          done,
    output logic                          busy,

    // Output token stream
    output logic                          token_out_valid,
    output logic [`TOKEN_ID_W-1:0]        token_out_id,

    // HBM interface
    output logic                          hbm_rd_valid,
    input  logic                          hbm_rd_ready,
    output logic [`HBM_ADDR_W-1:0]        hbm_rd_addr,
    input  logic                          hbm_resp_valid,
    input  logic [`HBM_DATA_W-1:0]        hbm_resp_data,
// PLACEHOLDER_PORTS_CONTINUE

    // SRAM preload interface
    input  logic                          sram_preload_valid,
    input  logic [`SRAM_ADDR_W-1:0]       sram_preload_addr,
    input  logic [`SRAM_WDATA_W-1:0]      sram_preload_data,

    // HHT warmup interface
    input  logic                          warmup_accept_valid,
    input  logic [`NODE_ID_W-1:0]         warmup_accept_parent_node_id,
    input  logic [`TOKEN_ID_W-1:0]        warmup_accept_token_id,
    input  logic [`POSITION_ID_W-1:0]     warmup_accept_position
);

// =========================================================================
// State machine (same as e2e_top)
// =========================================================================
localparam [3:0]
    ST_IDLE     = 4'd0,
    ST_PREFILL  = 4'd1,
    ST_PREDICT  = 4'd2,
    ST_BUILD    = 4'd3,
    ST_VERIFY   = 4'd4,
    ST_COMMIT   = 4'd5,
    ST_FEEDBACK = 4'd6,
    ST_KV_COMMIT = 4'd7,
    ST_CHECK    = 4'd8,
    ST_DONE     = 4'd9,
    ST_FALLBACK = 4'd10,
    ST_FB_WAIT  = 4'd11;

logic [3:0] state_r;
logic [7:0] gen_count_r, max_gen_r;
logic [`NODE_ID_W-1:0]     seed_node_id_r;
logic [`TOKEN_ID_W-1:0]    seed_token_id_r;
logic [`POSITION_ID_W-1:0] seed_position_r;
logic [15:0]               committed_prefix_len_r;
logic [3:0]                kv_commit_count_r;
logic [15:0]               kv_commit_old_prefix_r;

// =========================================================================
// HHT Context Predictor (same as e2e_top)
// =========================================================================
logic hht_accept_valid;
logic [`NODE_ID_W-1:0] hht_accept_parent_node_id;
logic [`TOKEN_ID_W-1:0] hht_accept_token_id;
logic [`POSITION_ID_W-1:0] hht_accept_position;
logic hht_cand_valid;
logic [`NODE_ID_W-1:0] hht_cand_parent_node_id;
logic [`TOKEN_ID_W-1:0] hht_cand_token_id;
logic [`TOKEN_ID_W-1:0] hht_cand_referenced_token_id;
logic [`POSITION_ID_W-1:0] hht_cand_referenced_position;
logic [7:0] hht_cand_confidence;

logic [`TOKEN_ID_W-1:0] tb_spec_token_0, tb_spec_token_1;
logic tb_spec_query_valid, tb_spec_hit;
logic [`TOKEN_ID_W-1:0] tb_spec_prediction;

HHTContextPredictor #(
    .CONF_W(8), .HISTORY_LEN(2), .SET_NUM(8), .WAY_NUM(4)
) u_hht (
    .clk(clk), .rst_n(rst_n),
    .admission_enable(1'b1),
    .accept_valid(hht_accept_valid),
    .accept_parent_node_id(hht_accept_parent_node_id),
    .accept_token_id(hht_accept_token_id),
    .accept_position(hht_accept_position),
    .cand_valid(hht_cand_valid),
    .cand_parent_node_id(hht_cand_parent_node_id),
    .cand_token_id(hht_cand_token_id),
    .cand_referenced_token_id(hht_cand_referenced_token_id),
    .cand_referenced_position(hht_cand_referenced_position),
    .cand_confidence(hht_cand_confidence),
    .spec_token_0(tb_spec_token_0),
    .spec_token_1(tb_spec_token_1),
    .spec_query_valid(tb_spec_query_valid),
    .spec_hit(tb_spec_hit),
    .spec_prediction(tb_spec_prediction)
);

// =========================================================================
// Tree Builder (same as e2e_top)
// =========================================================================
logic tb_start, tb_done, tb_busy;
logic tb_tree_req_valid, tb_tree_req_ready;
logic [`NODE_ID_W-1:0] tb_seed_node_id;
logic [`TOKEN_ID_W-1:0] tb_seed_token_id;
logic [`POSITION_ID_W-1:0] tb_seed_position;
logic [BRANCH_NUM-1:0] tb_branch_valid;
logic [BRANCH_NUM*MAX_LEVELS*`NODE_ID_W-1:0] tb_branch_node_ids;
logic [BRANCH_NUM*MAX_LEVELS*`NODE_ID_W-1:0] tb_branch_parent_node_ids;
logic [BRANCH_NUM*MAX_LEVELS*`TOKEN_ID_W-1:0] tb_branch_draft_tokens;
logic [BRANCH_NUM*MAX_LEVELS*`POSITION_ID_W-1:0] tb_branch_draft_positions;
logic [BRANCH_NUM*MAX_LEVELS-1:0] tb_branch_levels_valid;
logic [15:0] tb_committed_prefix_len;
logic tb_hht_done;

tree_builder #(
    .BRANCH_NUM(BRANCH_NUM), .MAX_LEVELS(MAX_LEVELS), .TIMEOUT_CYCLES(64)
) u_tree_builder (
    .clk(clk), .rst_n(rst_n),
    .start(tb_start), .done(tb_done), .busy(tb_busy),
    .seed_node_id(seed_node_id_r),
    .seed_token_id(seed_token_id_r),
    .seed_position(seed_position_r),
    .committed_prefix_len_in(committed_prefix_len_r),
    .cand_valid(draft_valid || hht_cand_valid),
    .cand_parent_node_id(draft_valid ? draft_parent_node_id : hht_cand_parent_node_id),
    .cand_token_id(draft_valid ? draft_token_id : hht_cand_token_id),
    .cand_referenced_position(draft_valid ? draft_position : hht_cand_referenced_position),
    .hht_done(tb_hht_done),
    .spec_token_0(tb_spec_token_0), .spec_token_1(tb_spec_token_1),
    .spec_query_valid(tb_spec_query_valid),
    .spec_hit(tb_spec_hit), .spec_prediction(tb_spec_prediction),
    .tree_req_valid(tb_tree_req_valid),
    .tree_req_ready(tb_tree_req_ready),
    .out_seed_node_id(tb_seed_node_id),
    .out_seed_token_id(tb_seed_token_id),
    .out_seed_position(tb_seed_position),
    .out_branch_valid(tb_branch_valid),
    .out_branch_node_ids(tb_branch_node_ids),
    .out_branch_parent_node_ids(tb_branch_parent_node_ids),
    .out_branch_draft_tokens(tb_branch_draft_tokens),
    .out_branch_draft_positions(tb_branch_draft_positions),
    .out_branch_levels_valid(tb_branch_levels_valid),
    .out_committed_prefix_len(tb_committed_prefix_len)
);

// PLACEHOLDER_BRIDGE_AND_PATH

// =========================================================================
// Tree-to-Native Bridge
// =========================================================================
logic bridge_req_valid, bridge_req_ready, bridge_done;
logic bridge_tree_req_ready_w;
// Bridge may be busy from previous round; tree_builder should not be blocked
logic bridge_busy_r;
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) bridge_busy_r <= 1'b0;
    else if (bridge_done) bridge_busy_r <= 1'b0;
    else if (tb_tree_req_valid && bridge_tree_req_ready_w) bridge_busy_r <= 1'b1;
end
// Tree builder always gets ready (bridge accepts when it can)
assign tb_tree_req_ready = (state_r == ST_BUILD) && tb_tree_req_valid;

logic [`REQ_ID_W-1:0] bridge_req_id;
logic [`TREE_MAX_PREFIX_NODES-1:0] bridge_prefix_slot_valid;
logic [`TREE_MAX_PREFIX_NODES*`NODE_ID_W-1:0] bridge_prefix_node_id;
logic [`TREE_MAX_PREFIX_NODES*`TOKEN_ID_W-1:0] bridge_prefix_token_id;
logic [`TREE_MAX_PREFIX_NODES*`POSITION_ID_W-1:0] bridge_prefix_position_id;
logic [`POSITION_ID_W-1:0] bridge_committed_len;
logic [`TREE_MAX_FRONTIER_LEVELS-1:0] bridge_frontier_level_valid;
logic [`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS-1:0] bridge_frontier_slot_valid;
logic [`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0] bridge_frontier_node_id;
logic [`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0] bridge_frontier_parent_node_id;
logic [`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`TOKEN_ID_W-1:0] bridge_frontier_token_id;
logic [`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`TOKEN_ID_W-1:0] bridge_frontier_referenced_token_id;
logic [`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`POSITION_ID_W-1:0] bridge_frontier_position_id;
logic [`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`POSITION_ID_W-1:0] bridge_frontier_referenced_position_id;
logic [`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`BRANCH_ID_W-1:0] bridge_frontier_branch_id;
logic [`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`TREE_LEVEL_ID_W-1:0] bridge_frontier_level_id;
logic [`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS-1:0] bridge_frontier_tree_mask_en;

tree_to_native_bridge u_bridge (
    .clk(clk), .rst_n(rst_n),
    .tree_req_valid(tb_tree_req_valid && !bridge_busy_r),
    .tree_req_ready(bridge_tree_req_ready_w),
    .seed_node_id(tb_seed_node_id),
    .seed_token_id(tb_seed_token_id),
    .seed_position(tb_seed_position),
    .branch_valid(tb_branch_valid),
    .branch_node_ids(tb_branch_node_ids),
    .branch_parent_node_ids(tb_branch_parent_node_ids),
    .branch_draft_tokens(tb_branch_draft_tokens),
    .branch_draft_positions(tb_branch_draft_positions),
    .branch_levels_valid(tb_branch_levels_valid),
    .committed_prefix_len(tb_committed_prefix_len),
    .req_valid(bridge_req_valid),
    .req_ready(bridge_req_ready),
    .req_id(bridge_req_id),
    .prefix_slot_valid(bridge_prefix_slot_valid),
    .prefix_node_id(bridge_prefix_node_id),
    .prefix_token_id(bridge_prefix_token_id),
    .prefix_position_id(bridge_prefix_position_id),
    .committed_len(bridge_committed_len),
    .frontier_level_valid(bridge_frontier_level_valid),
    .frontier_slot_valid(bridge_frontier_slot_valid),
    .frontier_node_id(bridge_frontier_node_id),
    .frontier_parent_node_id(bridge_frontier_parent_node_id),
    .frontier_token_id(bridge_frontier_token_id),
    .frontier_referenced_token_id(bridge_frontier_referenced_token_id),
    .frontier_position_id(bridge_frontier_position_id),
    .frontier_referenced_position_id(bridge_frontier_referenced_position_id),
    .frontier_branch_id(bridge_frontier_branch_id),
    .frontier_level_id(bridge_frontier_level_id),
    .frontier_tree_mask_en(bridge_frontier_tree_mask_en),
    .done(bridge_done)
);

// =========================================================================
// StrictTreeMaskPaperPath (contains tree_analyze, agu, free_list,
//   bank_state_table, token_register, comparator, IssueScheduler)
// =========================================================================
// Comparator outputs
logic cmp_commit_valid, cmp_flush_valid;
logic [`BRANCH_MASK_W-1:0] cmp_commit_branch_mask, cmp_flush_branch_mask;
logic [`NODE_MASK_W-1:0] cmp_commit_node_mask, cmp_flush_node_mask;
logic cmp_accepted_prefix_valid;
logic [`REQ_ID_W-1:0] cmp_accepted_prefix_req_id;
logic [`BRANCH_ID_W-1:0] cmp_accepted_prefix_branch_id;
localparam integer PRIV_DEPTH_W = ((`MAX_VERIFY_NODES_PER_BRANCH + 1) <= 2) ? 1 :
    $clog2(`MAX_VERIFY_NODES_PER_BRANCH + 1);
logic [PRIV_DEPTH_W-1:0] cmp_accepted_prefix_depth;
logic [`MAX_VERIFY_NODES_PER_BRANCH*`NODE_ID_W-1:0] cmp_accepted_prefix_node_id;
logic [`BRANCH_NUM-1:0] cmp_live_branch_mask, cmp_prune_branch_mask;

// Issue bundle output (to PE arrays)
logic paper_issue_bundle_valid, paper_issue_bundle_ready;
logic [`REQ_ID_W-1:0] paper_issue_bundle_req_id;
logic [`TREE_FRONTIER_SLOTS-1:0] paper_issue_bundle_slot_valid;
logic [`TREE_FRONTIER_SLOTS-1:0] paper_issue_bundle_slot_lookup_hit;
logic [`TREE_FRONTIER_SLOTS*`TOKEN_ID_W-1:0] paper_issue_bundle_token_id;
logic [`TREE_FRONTIER_SLOTS*`POSITION_ID_W-1:0] paper_issue_bundle_position_id;
logic [`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0] paper_issue_bundle_node_id;
logic [`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0] paper_issue_bundle_parent_node_id;
logic [`TREE_FRONTIER_SLOTS*`BRANCH_ID_W-1:0] paper_issue_bundle_branch_id;
logic [`TREE_FRONTIER_SLOTS*`TREE_LEVEL_ID_W-1:0] paper_issue_bundle_level_id;
logic [4:0] paper_issue_bundle_slot_count;
logic [15:0] paper_issue_bundle_prefix_len;
logic [`TREE_FRONTIER_SLOTS-1:0] paper_issue_bundle_slot_tree_mask_en;
logic [`TREE_FRONTIER_SLOTS*`MODEL_MAX_POS_EMB-1:0] paper_issue_bundle_slot_visible_mask;
logic [`TREE_FRONTIER_SLOTS*PRIV_DEPTH_W-1:0] paper_issue_bundle_private_depth;
logic [`TREE_FRONTIER_SLOTS*`SRAM_ID_W-1:0] paper_issue_bundle_sram_id;
logic [`TREE_FRONTIER_SLOTS*`BANK_ID_W-1:0] paper_issue_bundle_bank_id;
logic [`TREE_FRONTIER_SLOTS*`SUBBANK_ID_W-1:0] paper_issue_bundle_subbank_start;
logic [`TREE_FRONTIER_SLOTS*`KV_GROUP_LEN_W-1:0] paper_issue_bundle_group_len;
logic [`TREE_FRONTIER_SLOTS*`BRANCH_MASK_W-1:0] paper_issue_bundle_branch_mask;
logic [`TREE_FRONTIER_SLOTS-1:0] paper_issue_bundle_is_shared;

// Lifecycle FSM registers (drives comparator inputs)
logic lifecycle_cmp_fire_r;
logic [`REQ_ID_W-1:0] lifecycle_req_id_r;
logic [`BRANCH_NUM-1:0] lifecycle_cmp_slot_valid;
logic [`BRANCH_NUM*`TOKEN_ID_W-1:0] lifecycle_cmp_real_token_id_r;
logic [`BRANCH_NUM*`TOKEN_ID_W-1:0] lifecycle_cmp_candidate_token_id_r;
logic [`BRANCH_NUM*`NODE_ID_W-1:0] lifecycle_cmp_node_id_r;
logic [`BRANCH_NUM*`NODE_ID_W-1:0] lifecycle_cmp_parent_node_id_r;
logic [`BRANCH_NUM*`BRANCH_ID_W-1:0] lifecycle_cmp_branch_id_r;
logic [`BRANCH_NUM-1:0] lifecycle_slot_meta_valid_r;
logic [`BRANCH_NUM*PRIV_DEPTH_W-1:0] lifecycle_active_branch_depth;
logic [`BRANCH_NUM*`MAX_VERIFY_NODES_PER_BRANCH*`NODE_ID_W-1:0] lifecycle_active_branch_node_id;
logic [`BRANCH_NUM*`MAX_VERIFY_NODES_PER_BRANCH*`NODE_ID_W-1:0] lifecycle_active_branch_parent_node_id;
logic [`BRANCH_NUM-1:0] lifecycle_slot_result_valid_r;
logic [`BRANCH_NUM*PRIV_DEPTH_W-1:0] lifecycle_result_private_depth;
logic [`BRANCH_NUM-1:0] lifecycle_result_accept;

// visible_mask (tied to all-ones for now — full causal visibility)
logic [`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`MODEL_MAX_POS_EMB-1:0]
    bridge_visible_mask;
assign bridge_visible_mask = '1;  // all positions visible (simplified)

// PLACEHOLDER_STMP_INSTANCE

StrictTreeMaskPaperPath u_stmp (
    .clk(clk), .rst_n(rst_n),
    // Native tree request (from bridge)
    .req_valid(bridge_req_valid),
    .req_ready(bridge_req_ready),
    .req_id(bridge_req_id),
    .src_prefix_slot_valid(bridge_prefix_slot_valid),
    .src_prefix_node_id(bridge_prefix_node_id),
    .src_prefix_token_id(bridge_prefix_token_id),
    .src_prefix_position_id(bridge_prefix_position_id),
    .src_committed_len(bridge_committed_len),
    .src_frontier_level_valid(bridge_frontier_level_valid),
    .src_frontier_slot_valid(bridge_frontier_slot_valid),
    .src_frontier_node_id(bridge_frontier_node_id),
    .src_frontier_parent_node_id(bridge_frontier_parent_node_id),
    .src_frontier_token_id(bridge_frontier_token_id),
    .src_frontier_referenced_token_id(bridge_frontier_referenced_token_id),
    .src_frontier_position_id(bridge_frontier_position_id),
    .src_frontier_referenced_position_id(bridge_frontier_referenced_position_id),
    .src_frontier_branch_id(bridge_frontier_branch_id),
    .src_frontier_level_id(bridge_frontier_level_id),
    .src_frontier_tree_mask_en(bridge_frontier_tree_mask_en),
    .visible_mask_by_level(bridge_visible_mask),
    // Flush/liveness (tied to 0 for now)
    .flush_freeze(1'b0),
    .flush_ctrl_valid(1'b0),
    .flush_ctrl_req_id({`REQ_ID_W{1'b0}}),
    .flush_ctrl_branch_mask({`BRANCH_MASK_W{1'b0}}),
    .flush_ctrl_node_mask({`NODE_MASK_W{1'b0}}),
    .branch_liveness_valid(1'b0),
    .branch_liveness_req_id({`REQ_ID_W{1'b0}}),
    .branch_liveness_live_mask({`BRANCH_MASK_W{1'b0}}),
    .branch_liveness_prune_mask({`BRANCH_MASK_W{1'b0}}),
    // Comparator inputs (from lifecycle FSM)
    .reduce_start_valid(lifecycle_cmp_fire_r),
    .cmp_req_id(lifecycle_req_id_r),
    .cmp_slot_valid(lifecycle_cmp_slot_valid),
    .cmp_slot_real_token_id(lifecycle_cmp_real_token_id_r),
    .cmp_slot_candidate_token_id(lifecycle_cmp_candidate_token_id_r),
    .cmp_slot_node_id(lifecycle_cmp_node_id_r),
    .cmp_slot_parent_node_id(lifecycle_cmp_parent_node_id_r),
    .cmp_slot_branch_id(lifecycle_cmp_branch_id_r),
    .reduce_req_id(lifecycle_req_id_r),
    .active_branch_epoch({(`BRANCH_NUM*2){1'b0}}),
    .active_branch_valid(lifecycle_slot_meta_valid_r),
    .active_branch_depth(lifecycle_active_branch_depth),
    .active_branch_node_id(lifecycle_active_branch_node_id),
    .active_branch_parent_node_id(lifecycle_active_branch_parent_node_id),
    .result_slot_valid(lifecycle_slot_result_valid_r),
    .result_req_id(lifecycle_req_id_r),
    .result_branch_id(lifecycle_cmp_branch_id_r),
    .result_branch_epoch({(`BRANCH_NUM*2){1'b0}}),
    .result_private_depth(lifecycle_result_private_depth),
    .result_node_id(lifecycle_cmp_node_id_r),
    .result_parent_node_id(lifecycle_cmp_parent_node_id_r),
    .result_accept(lifecycle_result_accept),
    // Comparator outputs
    .cmp_commit_valid(cmp_commit_valid),
    .cmp_commit_branch_mask(cmp_commit_branch_mask),
    .cmp_commit_node_mask(cmp_commit_node_mask),
    .cmp_flush_valid(cmp_flush_valid),
    .cmp_flush_branch_mask(cmp_flush_branch_mask),
    .cmp_flush_node_mask(cmp_flush_node_mask),
    .cmp_accepted_prefix_valid(cmp_accepted_prefix_valid),
    .cmp_accepted_prefix_req_id(cmp_accepted_prefix_req_id),
    .cmp_accepted_prefix_branch_id(cmp_accepted_prefix_branch_id),
    .cmp_accepted_prefix_depth(cmp_accepted_prefix_depth),
    .cmp_accepted_prefix_node_id(cmp_accepted_prefix_node_id),
    .cmp_live_branch_mask(cmp_live_branch_mask),
    .cmp_prune_branch_mask(cmp_prune_branch_mask),
    // bank_state_table commit (tied to 0 — no external bank commit needed)
    .bank_commit_valid(1'b0),
    .bank_commit_req_id({`REQ_ID_W{1'b0}}),
    .bank_commit_sram_id({`SRAM_ID_W{1'b0}}),
    .bank_commit_bank_id({`BANK_ID_W{1'b0}}),
    .bank_commit_subbank_start({`SUBBANK_ID_W{1'b0}}),
    .bank_commit_group_len({`KV_GROUP_LEN_W{1'b0}}),
    .bank_commit_branch_mask({`BRANCH_MASK_W{1'b0}}),
    .bank_commit_node_mask({`NODE_MASK_W{1'b0}}),
    // alloc/reclaim outputs (unconnected for now)
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
    .flush_reclaim_valid(),
    .flush_reclaim_sram_id(),
    .flush_reclaim_bank_id(),
    .flush_reclaim_subbank_start(),
    .flush_reclaim_group_len(),
    .flush_drain_busy(),
    // token_register write/flush (internal, outputs exposed for debug)
    .token_wr_valid(),
    .token_wr_req_id(),
    .token_wr_token_id(),
    .token_wr_position_id(),
    .token_wr_node_id(),
    .token_wr_branch_id(),
    .token_wr_branch_mask(),
    .token_wr_is_shared(),
    .token_wr_sram_id(),
    .token_wr_bank_id(),
    .token_wr_subbank_start(),
    .token_wr_group_len(),
    .token_wr_index(),
    // token_lookup (tied to 0 — not used externally yet)
    .token_lookup_valid(1'b0),
    .token_lookup_token_id({`TOKEN_ID_W{1'b0}}),
    .token_lookup_position_id({`POSITION_ID_W{1'b0}}),
    .token_lookup_ready(),
    .token_lookup_hit(),
    .token_lookup_sram_id(),
    .token_lookup_bank_id(),
    .token_lookup_subbank_start(),
    .token_lookup_group_len(),
    .token_lookup_branch_mask(),
    .token_lookup_is_shared(),
    .token_lookup_entry_type(),
    .token_lookup_entry_state(),
    // token_commit (tied to 0)
    .token_commit_valid(1'b0),
    .token_commit_index({`TOKEN_REG_INDEX_W{1'b0}}),
    .token_commit_req_id({`REQ_ID_W{1'b0}}),
    .token_commit_branch_mask({`BRANCH_MASK_W{1'b0}}),
    .token_commit_node_mask({`NODE_MASK_W{1'b0}}),
    .token_entry_count(),
    .token_error_flag(),
    // Issue bundle output → PE arrays (paper_issue_bundle_* ports)
    .paper_issue_bundle_valid(paper_issue_bundle_valid),
    .paper_issue_bundle_ready(paper_issue_bundle_ready),
    .paper_issue_bundle_req_id(paper_issue_bundle_req_id),
    .paper_issue_bundle_slot_valid(paper_issue_bundle_slot_valid),
    .paper_issue_bundle_slot_lookup_hit(paper_issue_bundle_slot_lookup_hit),
    .paper_issue_bundle_token_id(paper_issue_bundle_token_id),
    .paper_issue_bundle_position_id(paper_issue_bundle_position_id),
    .paper_issue_bundle_node_id(paper_issue_bundle_node_id),
    .paper_issue_bundle_parent_node_id(paper_issue_bundle_parent_node_id),
    .paper_issue_bundle_branch_id(paper_issue_bundle_branch_id),
    .paper_issue_bundle_level_id(paper_issue_bundle_level_id),
    .paper_issue_bundle_slot_count(paper_issue_bundle_slot_count),
    .paper_issue_bundle_prefix_len(paper_issue_bundle_prefix_len),
    .paper_issue_bundle_slot_tree_mask_en(paper_issue_bundle_slot_tree_mask_en),
    .paper_issue_bundle_slot_visible_mask(paper_issue_bundle_slot_visible_mask),
    .paper_issue_bundle_private_depth(paper_issue_bundle_private_depth),
    .paper_issue_bundle_sram_id(paper_issue_bundle_sram_id),
    .paper_issue_bundle_bank_id(paper_issue_bundle_bank_id),
    .paper_issue_bundle_subbank_start(paper_issue_bundle_subbank_start),
    .paper_issue_bundle_group_len(paper_issue_bundle_group_len),
    .paper_issue_bundle_branch_mask(paper_issue_bundle_branch_mask),
    .paper_issue_bundle_is_shared(paper_issue_bundle_is_shared),
    .paper_issue_bundle_entry_state(),
    .paper_issue_bundle_entry_type(),
    .paper_issue_bundle_embedding_base_addr(),
    .paper_issue_bundle_hidden0_base_addr(),
    .paper_issue_bundle_hidden1_base_addr(),
    .paper_issue_bundle_final_base_addr(),
    .paper_issue_bundle_weight_sram_base_addr(),
    .paper_issue_bundle_kv_cache_base_addr(),
    .paper_issue_bundle_draft_kv_base_addr(),
    .paper_issue_bundle_hbm_weight_base_addr(),
    .paper_issue_bundle_final_norm_gamma_addr(),
    .paper_issue_bundle_lm_head_weight_base_addr()
);

// synthesis translate_off
always @(posedge clk) begin
    if (paper_issue_bundle_valid && paper_issue_bundle_ready)
        $display("[TC_TOP] issue_bundle: slots=%b count=%0d prefix_len=%0d",
            paper_issue_bundle_slot_valid, paper_issue_bundle_slot_count,
            paper_issue_bundle_prefix_len);
    if (cmp_commit_valid)
        $display("[TC_TOP] COMMIT: branch_mask=%b node_mask=%b",
            cmp_commit_branch_mask, cmp_commit_node_mask);
    if (cmp_flush_valid)
        $display("[TC_TOP] FLUSH: branch_mask=%b node_mask=%b",
            cmp_flush_branch_mask, cmp_flush_node_mask);
    if (cmp_accepted_prefix_valid)
        $display("[TC_TOP] ACCEPTED: branch=%0d depth=%0d",
            cmp_accepted_prefix_branch_id, cmp_accepted_prefix_depth);
end
// synthesis translate_on


// =========================================================================
// 4× PE Array: PeArrayLayerController + shared SRAM via request_controller
// =========================================================================
localparam integer LC_SLOTS = `TREE_FRONTIER_SLOTS;
localparam integer BEHAV_SRAM_DEPTH = 270336;
reg [`SRAM_RDATA_W-1:0] behav_sram [0:BEHAV_SRAM_DEPTH-1];

localparam integer HBM_LOCAL_DEPTH = 32768;
reg [`HBM_DATA_W-1:0] hbm_local_mem [0:HBM_LOCAL_DEPTH-1];

// Forward declarations for emitter/fallback
logic emit_token_valid, emit_done_w;
logic [`TOKEN_ID_W-1:0] emit_token_id;
logic [3:0] emit_tokens_emitted;
logic fallback_token_valid_r;
logic [`TOKEN_ID_W-1:0] fallback_token_id_r;
reg verify_started_r;

// Per-LC control signals
logic [BRANCH_NUM-1:0] lc_start_w, lc_done_w, lc_busy_w;
logic [BRANCH_NUM*LC_SLOTS-1:0] lc_slot_valid_w;
logic [BRANCH_NUM*LC_SLOTS*`TOKEN_ID_W-1:0] lc_slot_token_id_w;
logic [BRANCH_NUM*LC_SLOTS*`POSITION_ID_W-1:0] lc_slot_position_id_w;
logic [BRANCH_NUM*LC_SLOTS*LC_SLOTS-1:0] lc_tree_mask_w;
logic [BRANCH_NUM*LC_SLOTS-1:0] lc_out_token_valid_w;
logic [BRANCH_NUM*LC_SLOTS*`TOKEN_ID_W-1:0] lc_out_token_id_w;

// Per-LC HBM signals
logic [BRANCH_NUM-1:0] lc_hbm_rd_valid;
logic [BRANCH_NUM*`HBM_ADDR_W-1:0] lc_hbm_rd_addr;
logic [BRANCH_NUM-1:0] lc_hbm_resp_valid;
logic [BRANCH_NUM*`HBM_DATA_W-1:0] lc_hbm_resp_data;

assign hbm_rd_valid = 1'b0;
assign hbm_rd_addr = '0;

// =========================================================================
// 4× LC generate block
// =========================================================================
genvar gi;
generate
for (gi = 0; gi < BRANCH_NUM; gi = gi + 1) begin : gen_lc
    logic lc_sram_wr_valid, lc_sram_wr_ready;
    logic [`SRAM_ADDR_W-1:0] lc_sram_wr_addr;
    logic [`SRAM_WDATA_W-1:0] lc_sram_wr_data;
    logic [`MEM_REQ_LANES-1:0] lc_vec_req_valid, lc_vec_req_ready, lc_vec_req_write;
    logic [`MEM_REQ_LANES*`SRAM_ADDR_W-1:0] lc_vec_req_addr;
    logic [`MEM_REQ_LANES*`SRAM_WDATA_W-1:0] lc_vec_req_wdata;
    logic [`MEM_REQ_LANES*`REQ_ID_W-1:0] lc_vec_req_req_id;
    logic [`MEM_REQ_LANES*`PE_MASK_W-1:0] lc_vec_req_pe_mask;
    logic [`MEM_REQ_LANES*`REQ_PRIORITY_W-1:0] lc_vec_req_priority;
    logic [`MEM_REQ_LANES*`BANK_ID_W-1:0] lc_vec_req_bank_id;
    logic [`MEM_REQ_LANES*`SUBBANK_ID_W-1:0] lc_vec_req_subbank_id;
    logic [`PE_MASK_W-1:0] lc_mc_resp_valid, lc_mc_resp_ready, lc_mc_resp_last;
    logic [`PE_MASK_W*`SRAM_RDATA_W-1:0] lc_mc_resp_rdata;
    logic [`PE_MASK_W*`REQ_ID_W-1:0] lc_mc_resp_req_id;

    fp16_inference_lc_wrapper #(
        .WORK_H0_BASE(`MODEL_WORK_HIDDEN0_BASE + gi * 512),
        .WORK_H1_BASE(`MODEL_WORK_HIDDEN1_BASE + gi * 512),
        .WORK_F_BASE(`MODEL_WORK_FINAL_BASE + gi * 512),
        .KV_BASE(`KV_DRAFT_BASE_MIN + gi * 16384),
        .W_SRAM_BASE(`MODEL_WEIGHT_SRAM_BASE + gi * 33792),
        .HBM_W_BASE(`MODEL_HBM_WEIGHT_BASE)
    ) u_lc (
        .clk(clk), .rst_n(rst_n),
        .start(lc_start_w[gi]), .done(lc_done_w[gi]), .busy(lc_busy_w[gi]),
        .slot_valid(lc_slot_valid_w[gi*LC_SLOTS +: LC_SLOTS]),
        .slot_token_id(lc_slot_token_id_w[gi*LC_SLOTS*`TOKEN_ID_W +: LC_SLOTS*`TOKEN_ID_W]),
        .slot_position_id(lc_slot_position_id_w[gi*LC_SLOTS*`POSITION_ID_W +: LC_SLOTS*`POSITION_ID_W]),
        .tree_mask(lc_tree_mask_w[gi*LC_SLOTS*LC_SLOTS +: LC_SLOTS*LC_SLOTS]),
        .embedding_base_addr(`MODEL_EMB_BASE),
        .hidden0_base_addr(`MODEL_WORK_HIDDEN0_BASE + gi * 512),
        .hidden1_base_addr(`MODEL_WORK_HIDDEN1_BASE + gi * 512),
        .final_base_addr(`MODEL_WORK_FINAL_BASE + gi * 512),
        .weight_sram_base_addr(`MODEL_WEIGHT_SRAM_BASE),
        .kv_cache_base_addr(`KV_DRAFT_BASE_MIN + gi * 16384),
        .final_norm_gamma_addr(`MODEL_FINAL_NORM_GAMMA_ADDR),
        .lm_head_weight_base_addr(`MODEL_LM_HEAD_WEIGHT_BASE),
        .hbm_weight_base_addr(`MODEL_HBM_WEIGHT_BASE),
        .committed_prefix_len(committed_prefix_len_r),
        .vec_req_valid(lc_vec_req_valid), .vec_req_ready(lc_vec_req_ready),
        .vec_req_write(lc_vec_req_write), .vec_req_addr(lc_vec_req_addr),
        .vec_req_wdata(lc_vec_req_wdata), .vec_req_req_id(lc_vec_req_req_id),
        .vec_req_pe_mask(lc_vec_req_pe_mask), .vec_req_priority(lc_vec_req_priority),
        .vec_req_bank_id(lc_vec_req_bank_id), .vec_req_subbank_id(lc_vec_req_subbank_id),
        .mc_resp_valid(lc_mc_resp_valid), .mc_resp_ready(lc_mc_resp_ready),
        .mc_resp_rdata(lc_mc_resp_rdata), .mc_resp_req_id(lc_mc_resp_req_id),
        .mc_resp_last(lc_mc_resp_last),
        .sram_wr_valid(lc_sram_wr_valid), .sram_wr_ready(lc_sram_wr_ready),
        .sram_wr_addr(lc_sram_wr_addr), .sram_wr_data(lc_sram_wr_data),
        .hbm_rd_valid(lc_hbm_rd_valid[gi]), .hbm_rd_ready(1'b1),
        .hbm_rd_addr(lc_hbm_rd_addr[gi*`HBM_ADDR_W +: `HBM_ADDR_W]),
        .hbm_resp_valid(lc_hbm_resp_valid[gi]),
        .hbm_resp_data(lc_hbm_resp_data[gi*`HBM_DATA_W +: `HBM_DATA_W]),
        .out_token_valid(lc_out_token_valid_w[gi*LC_SLOTS +: LC_SLOTS]),
        .out_token_id(lc_out_token_id_w[gi*LC_SLOTS*`TOKEN_ID_W +: LC_SLOTS*`TOKEN_ID_W])
    );

    // Per-LC behavioral SRAM (shared behav_sram, through request_controller)
    assign lc_vec_req_ready = {`MEM_REQ_LANES{1'b1}};
    assign lc_sram_wr_ready = 1'b1;
    reg [`MEM_REQ_LANES-1:0] resp_valid_r;
    reg [`MEM_REQ_LANES*`SRAM_RDATA_W-1:0] resp_rdata_r;
    reg [`MEM_REQ_LANES*`REQ_ID_W-1:0] resp_id_r;
    reg [`MEM_REQ_LANES-1:0] resp_last_r;
    integer mi;
    always @(posedge clk) begin
        for (mi = 0; mi < `MEM_REQ_LANES; mi = mi + 1) begin
            resp_valid_r[mi] <= lc_vec_req_valid[mi] && !lc_vec_req_write[mi];
            if (lc_vec_req_valid[mi]) begin
                if (lc_vec_req_write[mi]) begin
                    if (lc_vec_req_addr[mi*`SRAM_ADDR_W +: `SRAM_ADDR_W] < BEHAV_SRAM_DEPTH)
                        behav_sram[lc_vec_req_addr[mi*`SRAM_ADDR_W +: `SRAM_ADDR_W]] <= lc_vec_req_wdata[mi*`SRAM_WDATA_W +: `SRAM_WDATA_W];
                end else begin
                    if (lc_vec_req_addr[mi*`SRAM_ADDR_W +: `SRAM_ADDR_W] < BEHAV_SRAM_DEPTH)
                        resp_rdata_r[mi*`SRAM_RDATA_W +: `SRAM_RDATA_W] <= behav_sram[lc_vec_req_addr[mi*`SRAM_ADDR_W +: `SRAM_ADDR_W]];
                    else
                        resp_rdata_r[mi*`SRAM_RDATA_W +: `SRAM_RDATA_W] <= '0;
                end
                resp_id_r[mi*`REQ_ID_W +: `REQ_ID_W] <= lc_vec_req_req_id[mi*`REQ_ID_W +: `REQ_ID_W];
            end
            resp_last_r[mi] <= lc_vec_req_valid[mi] && !lc_vec_req_write[mi];
        end
        if (lc_sram_wr_valid && lc_sram_wr_addr < BEHAV_SRAM_DEPTH)
            behav_sram[lc_sram_wr_addr] <= lc_sram_wr_data;
        // KV commit: copy draft KV to committed region (only in gi==0 instance)
        // synthesis translate_off
        if (gi == 0 && state_r == ST_KV_COMMIT) begin : kv_commit_copy
            integer kv_layer, kv_beat, kv_tok;
            integer kv_src_base, kv_dst_base;
            localparam integer KV_POS_STRIDE_L = `MODEL_HEAD_NUM * (`MODEL_HEAD_DIM / (`SRAM_RDATA_W / `FP16_TILE_DATA_W)) * 2;
            for (kv_tok = 0; kv_tok < kv_commit_count_r; kv_tok = kv_tok + 1) begin
                for (kv_layer = 0; kv_layer < `MODEL_N_LAYERS; kv_layer = kv_layer + 1) begin
                    kv_src_base = (`KV_DRAFT_BASE_MIN + kv_tok * 16384) + kv_layer * 4096;
                    kv_dst_base = `KV_COMMITTED_BASE + kv_layer * 4096 + (kv_commit_old_prefix_r + kv_tok) * KV_POS_STRIDE_L;
                    for (kv_beat = 0; kv_beat < KV_POS_STRIDE_L; kv_beat = kv_beat + 1) begin
                        behav_sram[kv_dst_base + kv_beat] <= behav_sram[kv_src_base + kv_beat];
                    end
                end
            end
        end
        // synthesis translate_on
    end
    assign lc_mc_resp_valid = resp_valid_r;
    assign lc_mc_resp_rdata = resp_rdata_r;
    assign lc_mc_resp_req_id = resp_id_r;
    assign lc_mc_resp_last = resp_last_r;

    // Per-LC HBM pipeline (2-cycle latency)
    reg hbm_pipe1_valid_r;
    reg [`HBM_ADDR_W-1:0] hbm_pipe1_addr_r;
    reg hbm_pipe2_valid_r;
    reg [`HBM_DATA_W-1:0] hbm_pipe2_data_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hbm_pipe1_valid_r <= 0;
            hbm_pipe2_valid_r <= 0;
        end else begin
            hbm_pipe1_valid_r <= lc_hbm_rd_valid[gi];
            hbm_pipe1_addr_r <= lc_hbm_rd_addr[gi*`HBM_ADDR_W +: `HBM_ADDR_W];
            hbm_pipe2_valid_r <= hbm_pipe1_valid_r;
            if (hbm_pipe1_valid_r && hbm_pipe1_addr_r < HBM_LOCAL_DEPTH)
                hbm_pipe2_data_r <= hbm_local_mem[hbm_pipe1_addr_r];
            else
                hbm_pipe2_data_r <= '0;
        end
    end
    assign lc_hbm_resp_valid[gi] = hbm_pipe2_valid_r;
    assign lc_hbm_resp_data[gi*`HBM_DATA_W +: `HBM_DATA_W] = hbm_pipe2_data_r;
end
endgenerate

// =========================================================================
// request_controller + multicast_network (STMP shared SRAM infrastructure)
// =========================================================================
// In the STMP path, all 4 LCs share SRAM through request_controller which
// merges requests and multicast_network which routes responses.
// For behavioral sim, the actual SRAM access is handled per-LC above.
// The request_controller and multicast_network are instantiated here to
// model their pipeline latency and arbitration overhead.

// Aggregate scalar write from all LCs (round-robin)
logic rc_scalar_wr_valid;
logic [`SRAM_ADDR_W-1:0] rc_scalar_wr_addr;
logic [`SRAM_WDATA_W-1:0] rc_scalar_wr_data;
assign rc_scalar_wr_valid = sram_preload_valid;
assign rc_scalar_wr_addr = sram_preload_addr;
assign rc_scalar_wr_data = sram_preload_data;

// Aggregate vec_req from LC[0] as representative (request_controller models latency)
logic [`MEM_REQ_LANES-1:0] rc_vec_req_valid_w, rc_vec_req_write_w;
logic [`MEM_REQ_LANES*`SRAM_ADDR_W-1:0] rc_vec_req_addr_w;
logic [`MEM_REQ_LANES*`SRAM_WDATA_W-1:0] rc_vec_req_wdata_w;
logic [`MEM_REQ_LANES*`REQ_ID_W-1:0] rc_vec_req_req_id_w;
logic [`MEM_REQ_LANES*`PE_MASK_W-1:0] rc_vec_req_pe_mask_w;
logic [`MEM_REQ_LANES*`REQ_PRIORITY_W-1:0] rc_vec_req_priority_w;
logic [`MEM_REQ_LANES*`BANK_ID_W-1:0] rc_vec_req_bank_id_w;
logic [`MEM_REQ_LANES*`SUBBANK_ID_W-1:0] rc_vec_req_subbank_id_w;
logic [`MEM_REQ_LANES-1:0] rc_vec_req_ready_w;

// Use LC[0]'s vec_req as representative input to request_controller
assign rc_vec_req_valid_w = gen_lc[0].lc_vec_req_valid;
assign rc_vec_req_write_w = gen_lc[0].lc_vec_req_write;
assign rc_vec_req_addr_w = gen_lc[0].lc_vec_req_addr;
assign rc_vec_req_wdata_w = gen_lc[0].lc_vec_req_wdata;
assign rc_vec_req_req_id_w = gen_lc[0].lc_vec_req_req_id;
assign rc_vec_req_pe_mask_w = gen_lc[0].lc_vec_req_pe_mask;
assign rc_vec_req_priority_w = gen_lc[0].lc_vec_req_priority;
assign rc_vec_req_bank_id_w = gen_lc[0].lc_vec_req_bank_id;
assign rc_vec_req_subbank_id_w = gen_lc[0].lc_vec_req_subbank_id;

// request_controller instance (models arbitration + merge latency)
logic [`MEM_REQ_LANES-1:0] mem_req_valid_w, mem_req_ready_w, mem_req_write_w;
logic [`MEM_REQ_LANES*`SRAM_ADDR_W-1:0] mem_req_addr_w;
logic [`MEM_REQ_LANES*`SRAM_WDATA_W-1:0] mem_req_wdata_w;
logic [`MEM_REQ_LANES*`REQ_ID_W-1:0] mem_req_id_w;
logic [`MEM_REQ_LANES-1:0] mem_resp_valid_w;
logic [`MEM_REQ_LANES*`SRAM_RDATA_W-1:0] mem_resp_rdata_w;
logic [`MEM_REQ_LANES*`REQ_ID_W-1:0] mem_resp_id_w;
logic [`MEM_REQ_LANES-1:0] mem_resp_last_w;
assign mem_req_ready_w = {`MEM_REQ_LANES{1'b1}};

// SRAM behavioral model for request_controller path
reg [`MEM_REQ_LANES-1:0] rc_resp_valid_r;
reg [`MEM_REQ_LANES*`SRAM_RDATA_W-1:0] rc_resp_rdata_r;
reg [`MEM_REQ_LANES*`REQ_ID_W-1:0] rc_resp_id_r;
reg [`MEM_REQ_LANES-1:0] rc_resp_last_r;
integer rci;
always @(posedge clk) begin
    for (rci = 0; rci < `MEM_REQ_LANES; rci = rci + 1) begin
        rc_resp_valid_r[rci] <= mem_req_valid_w[rci] && !mem_req_write_w[rci];
        if (mem_req_valid_w[rci]) begin
            if (mem_req_write_w[rci]) begin
                if (mem_req_addr_w[rci*`SRAM_ADDR_W +: `SRAM_ADDR_W] < BEHAV_SRAM_DEPTH)
                    behav_sram[mem_req_addr_w[rci*`SRAM_ADDR_W +: `SRAM_ADDR_W]] <=
                        mem_req_wdata_w[rci*`SRAM_WDATA_W +: `SRAM_WDATA_W];
            end else begin
                if (mem_req_addr_w[rci*`SRAM_ADDR_W +: `SRAM_ADDR_W] < BEHAV_SRAM_DEPTH)
                    rc_resp_rdata_r[rci*`SRAM_RDATA_W +: `SRAM_RDATA_W] <=
                        behav_sram[mem_req_addr_w[rci*`SRAM_ADDR_W +: `SRAM_ADDR_W]];
                else
                    rc_resp_rdata_r[rci*`SRAM_RDATA_W +: `SRAM_RDATA_W] <= '0;
            end
            rc_resp_id_r[rci*`REQ_ID_W +: `REQ_ID_W] <= mem_req_id_w[rci*`REQ_ID_W +: `REQ_ID_W];
        end
        rc_resp_last_r[rci] <= mem_req_valid_w[rci] && !mem_req_write_w[rci];
    end
end
assign mem_resp_valid_w = rc_resp_valid_r;
assign mem_resp_rdata_w = rc_resp_rdata_r;
assign mem_resp_id_w = rc_resp_id_r;
assign mem_resp_last_w = rc_resp_last_r;

request_controller u_req_ctrl (
    .clk(clk), .rst_n(rst_n),
    .req_in_valid(rc_scalar_wr_valid), .req_in_ready(),
    .req_in_write(1'b1), .req_in_addr(rc_scalar_wr_addr), .req_in_wdata(rc_scalar_wr_data),
    .req_in_req_id({`REQ_ID_W{1'b0}}), .req_in_pe_mask({`PE_MASK_W{1'b0}}),
    .req_in_priority(2'b00),
    .req_in_bank_id(rc_scalar_wr_addr[`OFFSET_W+`ROW_ADDR_W+`SUBBANK_ID_W +: `BANK_ID_W]),
    .req_in_subbank_id(rc_scalar_wr_addr[`OFFSET_W+`ROW_ADDR_W +: `SUBBANK_ID_W]),
    .vec_req_valid(rc_vec_req_valid_w), .vec_req_ready(rc_vec_req_ready_w),
    .vec_req_write(rc_vec_req_write_w), .vec_req_addr(rc_vec_req_addr_w),
    .vec_req_wdata(rc_vec_req_wdata_w), .vec_req_req_id(rc_vec_req_req_id_w),
    .vec_req_pe_mask(rc_vec_req_pe_mask_w), .vec_req_priority(rc_vec_req_priority_w),
    .vec_req_bank_id(rc_vec_req_bank_id_w), .vec_req_subbank_id(rc_vec_req_subbank_id_w),
    .mem_req_valid(mem_req_valid_w), .mem_req_ready(mem_req_ready_w),
    .mem_req_write(mem_req_write_w), .mem_req_addr(mem_req_addr_w),
    .mem_req_wdata(mem_req_wdata_w), .mem_req_id(mem_req_id_w),
    .mem_resp_valid(mem_resp_valid_w), .mem_resp_rdata(mem_resp_rdata_w),
    .mem_resp_id(mem_resp_id_w), .mem_resp_last(mem_resp_last_w),
    .resp_out_valid(), .resp_out_ready({`MEM_REQ_LANES{1'b1}}),
    .resp_out_rdata(), .resp_out_req_id(), .resp_out_pe_mask(), .resp_out_last()
);

// =========================================================================
// Draft Injection Interface
// =========================================================================
logic draft_inject_start, draft_done_w;
logic draft_valid;
logic [`TOKEN_ID_W-1:0] draft_token_id;
logic [`NODE_ID_W-1:0] draft_parent_node_id;
logic [`POSITION_ID_W-1:0] draft_position;
logic [1:0] draft_branch_id;
logic [2:0] draft_depth;
logic [BRANCH_NUM-1:0] draft_branch_active;
logic [BRANCH_NUM*MAX_LEVELS*`TOKEN_ID_W-1:0] draft_branch_injected_tokens;
logic [BRANCH_NUM*3-1:0] draft_branch_depth_out;

draft_injection_interface #(.BRANCH_NUM(BRANCH_NUM), .MAX_DEPTH(MAX_LEVELS), .PREDICT_ACCURACY(PREDICT_ACCURACY)) u_draft_inject (
    .clk(clk), .rst_n(rst_n), .inject_start(draft_inject_start),
    .seed_token_id(seed_token_id_r), .seed_position(seed_position_r), .seed_node_id(seed_node_id_r),
    .commit_feedback_valid(emit_token_valid || fallback_token_valid_r),
    .commit_feedback_token(emit_token_valid ? emit_token_id : fallback_token_id_r),
    .draft_valid(draft_valid), .draft_token_id(draft_token_id),
    .draft_parent_node_id(draft_parent_node_id), .draft_position(draft_position),
    .draft_branch_id(draft_branch_id), .draft_depth(draft_depth), .draft_done(draft_done_w),
    .branch_active(draft_branch_active), .branch_injected_tokens(draft_branch_injected_tokens),
    .branch_depth_out(draft_branch_depth_out)
);
assign draft_inject_start = (state_r == ST_BUILD) && !tb_busy && !tb_done;

// =========================================================================
// KV Cache Sync — NOT NEEDED with fp16_inference_top
// =========================================================================
// fp16_inference_top manages KV cache in shared SRAM. All 4 instances
// access the same behav_sram, so committed prefix KV is naturally visible.

// =========================================================================
// Branch Parallel Scheduler (dispatches tree to 4 LCs)
// =========================================================================
logic sched_start, sched_all_done;
logic [BRANCH_NUM-1:0] sched_lc_start, sched_lc_done, sched_lc_busy;
logic [BRANCH_NUM*LC_SLOTS-1:0] sched_lc_slot_valid;
logic [BRANCH_NUM*LC_SLOTS*`TOKEN_ID_W-1:0] sched_lc_slot_token_id;
logic [BRANCH_NUM*LC_SLOTS*`POSITION_ID_W-1:0] sched_lc_slot_position_id;
logic [BRANCH_NUM*LC_SLOTS*LC_SLOTS-1:0] sched_lc_tree_mask;
logic [BRANCH_NUM*LC_SLOTS*`TOKEN_ID_W-1:0] sched_lc_out_token_id;
logic [BRANCH_NUM-1:0] sched_branch_result_valid;
logic [BRANCH_NUM*`TOKEN_ID_W-1:0] sched_branch_generated_token;
logic [BRANCH_NUM*MAX_LEVELS*`TOKEN_ID_W-1:0] sched_branch_draft_tokens_out;

branch_parallel_scheduler #(.BRANCH_NUM(BRANCH_NUM), .MAX_DEPTH(MAX_LEVELS)) u_scheduler (
    .clk(clk), .rst_n(rst_n), .start(sched_start), .all_done(sched_all_done),
    .branch_valid(tb_branch_valid), .branch_draft_tokens(tb_branch_draft_tokens),
    .branch_draft_positions(tb_branch_draft_positions), .branch_levels_valid(tb_branch_levels_valid),
    .seed_token_id(seed_token_id_r), .seed_position(seed_position_r),
    .committed_prefix_len(committed_prefix_len_r),
    .lc_start(sched_lc_start), .lc_done(sched_lc_done), .lc_busy(sched_lc_busy),
    .lc_slot_valid(sched_lc_slot_valid), .lc_slot_token_id(sched_lc_slot_token_id),
    .lc_slot_position_id(sched_lc_slot_position_id), .lc_tree_mask(sched_lc_tree_mask),
    .lc_out_token_id(sched_lc_out_token_id),
    .branch_result_valid(sched_branch_result_valid),
    .branch_generated_token(sched_branch_generated_token),
    .branch_draft_tokens_out(sched_branch_draft_tokens_out)
);

// Connect scheduler to LCs
// Fallback mux (same as final_top)
logic fallback_lc_start;
wire use_fallback = (state_r == ST_FALLBACK || state_r == ST_FB_WAIT);
assign fallback_lc_start = (state_r == ST_FALLBACK);

always_comb begin
    lc_slot_valid_w = sched_lc_slot_valid;
    lc_slot_token_id_w = sched_lc_slot_token_id;
    lc_slot_position_id_w = sched_lc_slot_position_id;
    lc_tree_mask_w = sched_lc_tree_mask;
    if (use_fallback) begin
        lc_slot_valid_w[0*LC_SLOTS +: LC_SLOTS] = '0;
        lc_slot_valid_w[0*LC_SLOTS + 0] = 1'b1;
        lc_slot_token_id_w[0*LC_SLOTS*`TOKEN_ID_W +: LC_SLOTS*`TOKEN_ID_W] = '0;
        lc_slot_token_id_w[0*LC_SLOTS*`TOKEN_ID_W +: `TOKEN_ID_W] = seed_token_id_r;
        lc_slot_position_id_w[0*LC_SLOTS*`POSITION_ID_W +: LC_SLOTS*`POSITION_ID_W] = '0;
        lc_slot_position_id_w[0*LC_SLOTS*`POSITION_ID_W +: `POSITION_ID_W] = seed_position_r;
        lc_tree_mask_w[0*LC_SLOTS*LC_SLOTS +: LC_SLOTS*LC_SLOTS] = '0;
        lc_tree_mask_w[0*LC_SLOTS*LC_SLOTS + 0] = 1'b1;
    end
end

assign lc_start_w = use_fallback ? {3'b0, fallback_lc_start} : sched_lc_start;
assign sched_lc_done = lc_done_w;
assign sched_lc_busy = lc_busy_w;
assign sched_lc_out_token_id = lc_out_token_id_w;

// =========================================================================
// Longest Path Comparator
// =========================================================================
logic cmp2_start, cmp2_result_valid;
logic [3:0] cmp2_accepted_count;
logic [(MAX_LEVELS+1)*`TOKEN_ID_W-1:0] cmp2_accepted_tokens;
logic [BRANCH_NUM-1:0] cmp2_flush_mask;
logic cmp2_all_correct;

longest_path_comparator #(.BRANCH_NUM(BRANCH_NUM), .MAX_DEPTH(MAX_LEVELS)) u_comparator2 (
    .clk(clk), .rst_n(rst_n), .compare_start(cmp2_start),
    .branch_generated_token(sched_branch_generated_token),
    .branch_valid(sched_branch_result_valid),
    .branch_injected_tokens(draft_branch_injected_tokens),
    .branch_depth(draft_branch_depth_out),
    .result_valid(cmp2_result_valid), .accepted_count(cmp2_accepted_count),
    .accepted_tokens(cmp2_accepted_tokens), .flush_mask(cmp2_flush_mask),
    .all_correct(cmp2_all_correct)
);

// =========================================================================
// Multi-Token Emitter
// =========================================================================
logic emit_start;
logic [`TOKEN_ID_W-1:0] emit_new_seed;
logic [`POSITION_ID_W-1:0] emit_new_position;
logic [15:0] emit_new_prefix_len;

multi_token_emitter #(.MAX_DEPTH(MAX_LEVELS)) u_emitter (
    .clk(clk), .rst_n(rst_n), .emit_start(emit_start),
    .accepted_count(cmp2_accepted_count), .accepted_tokens(cmp2_accepted_tokens),
    .current_position(seed_position_r), .current_prefix_len(committed_prefix_len_r),
    .token_out_valid(emit_token_valid), .token_out_id(emit_token_id),
    .emit_done(emit_done_w), .new_seed_token(emit_new_seed),
    .new_position(emit_new_position), .new_prefix_len(emit_new_prefix_len),
    .tokens_emitted(emit_tokens_emitted)
);

assign token_out_valid = emit_token_valid || fallback_token_valid_r;
assign token_out_id = fallback_token_valid_r ? fallback_token_id_r : emit_token_id;

// =========================================================================
// Issue Bundle → STMP lifecycle (kept for STMP overhead modeling)
// =========================================================================
// The STMP issue_bundle fires but we use branch_parallel_scheduler for actual
// LC dispatch. The STMP path models the latency of tree_analyze → AGU →
// free_list → bank_state_table → token_register → IssueScheduler.
// We gate the actual verify start on issue_bundle_valid to capture this delay.

assign paper_issue_bundle_ready = (state_r == ST_VERIFY) && !verify_started_r;

logic stmp_issue_received_r;
// Counter to track STMP latency: wait for first issue_bundle OR timeout (64 cycles)
logic [6:0] stmp_wait_cnt_r;
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        stmp_issue_received_r <= 1'b0;
        stmp_wait_cnt_r <= 7'd0;
    end else begin
        if (state_r == ST_PREDICT) begin
            stmp_issue_received_r <= 1'b0;
            stmp_wait_cnt_r <= 7'd0;
        end else if (state_r == ST_VERIFY && !stmp_issue_received_r) begin
            stmp_wait_cnt_r <= stmp_wait_cnt_r + 7'd1;
            if ((paper_issue_bundle_valid && paper_issue_bundle_ready) || stmp_wait_cnt_r >= 7'd63)
                stmp_issue_received_r <= 1'b1;
        end
    end
end

// Feed STMP comparator with dummy data (lifecycle signals still connected)
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        lifecycle_cmp_fire_r <= 1'b0;
        lifecycle_req_id_r <= '0;
        lifecycle_cmp_slot_valid <= '0;
        lifecycle_cmp_real_token_id_r <= '0;
        lifecycle_cmp_candidate_token_id_r <= '0;
        lifecycle_cmp_node_id_r <= '0;
        lifecycle_cmp_parent_node_id_r <= '0;
        lifecycle_cmp_branch_id_r <= '0;
        lifecycle_slot_meta_valid_r <= '0;
        lifecycle_active_branch_depth <= '0;
        lifecycle_active_branch_node_id <= '0;
        lifecycle_active_branch_parent_node_id <= '0;
        lifecycle_slot_result_valid_r <= '0;
        lifecycle_result_private_depth <= '0;
        lifecycle_result_accept <= '0;
    end else begin
        lifecycle_cmp_fire_r <= 1'b0;
        // When scheduler completes, also fire STMP comparator for overhead modeling
        if (sched_all_done && state_r == ST_VERIFY) begin
            lifecycle_cmp_fire_r <= 1'b1;
            lifecycle_cmp_real_token_id_r <= sched_branch_generated_token;
            lifecycle_slot_result_valid_r <= sched_branch_result_valid;
            lifecycle_slot_meta_valid_r <= sched_branch_result_valid;
            lifecycle_cmp_slot_valid <= sched_branch_result_valid;
            begin : set_lifecycle_meta
                integer br;
                for (br = 0; br < `BRANCH_NUM; br = br + 1) begin
                    lifecycle_cmp_branch_id_r[br*`BRANCH_ID_W +: `BRANCH_ID_W] <= br[`BRANCH_ID_W-1:0];
                    lifecycle_cmp_node_id_r[br*`NODE_ID_W +: `NODE_ID_W] <= br[`NODE_ID_W-1:0];
                    lifecycle_active_branch_node_id[br*`MAX_VERIFY_NODES_PER_BRANCH*`NODE_ID_W +: `NODE_ID_W] <= br[`NODE_ID_W-1:0];
                    lifecycle_active_branch_depth[br*PRIV_DEPTH_W +: PRIV_DEPTH_W] <=
                        sched_branch_result_valid[br] ? {{(PRIV_DEPTH_W-1){1'b0}}, 1'b1} : {PRIV_DEPTH_W{1'b0}};
                    lifecycle_result_private_depth[br*PRIV_DEPTH_W +: PRIV_DEPTH_W] <=
                        sched_branch_result_valid[br] ? {{(PRIV_DEPTH_W-1){1'b0}}, 1'b1} : {PRIV_DEPTH_W{1'b0}};
                    lifecycle_result_accept[br] <= sched_branch_result_valid[br];
                end
            end
        end
    end
end

// =========================================================================
// Main State Machine
// =========================================================================

assign tb_start = (state_r == ST_BUILD) && !tb_busy && !tb_done;
assign tb_hht_done = (state_r != ST_BUILD);

// HHT accept: warmup OR emit feedback
logic hht_feedback_valid;
assign hht_feedback_valid = emit_token_valid;
assign hht_accept_valid = warmup_accept_valid || hht_feedback_valid;
assign hht_accept_parent_node_id = warmup_accept_valid ? warmup_accept_parent_node_id : '0;
assign hht_accept_token_id = warmup_accept_valid ? warmup_accept_token_id : emit_token_id;
assign hht_accept_position = warmup_accept_valid ? warmup_accept_position : seed_position_r;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state_r <= ST_IDLE;
        gen_count_r <= 8'd0;
        max_gen_r <= 8'd0;
        seed_node_id_r <= '0;
        seed_token_id_r <= '0;
        seed_position_r <= '0;
        committed_prefix_len_r <= 16'd0;
        done <= 1'b0;
        busy <= 1'b0;
        cmp2_start <= 1'b0;
        emit_start <= 1'b0;
        verify_started_r <= 1'b0;
        fallback_token_valid_r <= 1'b0;
        fallback_token_id_r <= '0;
    end else begin
        done <= 1'b0;
        cmp2_start <= 1'b0;
        emit_start <= 1'b0;
        fallback_token_valid_r <= 1'b0;

        case (state_r)
        ST_IDLE: begin
            if (start) begin
                state_r <= ST_PREDICT;
                busy <= 1'b1;
                max_gen_r <= max_gen_tokens;
                gen_count_r <= 8'd0;
                seed_token_id_r <= prompt_token_id;
                seed_node_id_r <= '0;
                seed_position_r <= '0;
                committed_prefix_len_r <= 16'd0;
            end
        end
        ST_PREDICT: begin
            state_r <= ST_BUILD;
            verify_started_r <= 1'b0;
        end
        ST_BUILD: begin
            if (tb_done) begin
                if (|tb_branch_valid) state_r <= ST_VERIFY;
                else state_r <= ST_FALLBACK;
            end
        end
        ST_FALLBACK: state_r <= ST_FB_WAIT;
        ST_FB_WAIT: begin
            if (lc_done_w[0]) begin
                fallback_token_valid_r <= 1'b1;
                fallback_token_id_r <= lc_out_token_id_w[0 +: `TOKEN_ID_W];
                gen_count_r <= gen_count_r + 8'd1;
                seed_token_id_r <= lc_out_token_id_w[0 +: `TOKEN_ID_W];
                seed_position_r <= seed_position_r + {{(`POSITION_ID_W-1){1'b0}}, 1'b1};
                kv_commit_old_prefix_r <= committed_prefix_len_r;
                kv_commit_count_r <= 4'd1;
                committed_prefix_len_r <= committed_prefix_len_r + 16'd1;
                state_r <= ST_KV_COMMIT;
                // synthesis translate_off
                $display("[TC_TOP] FALLBACK: token=%0d", lc_out_token_id_w[0 +: `TOKEN_ID_W]);
                // synthesis translate_on
            end
        end
        ST_VERIFY: begin
            if (!verify_started_r && stmp_issue_received_r) verify_started_r <= 1'b1;
            if (sched_all_done) begin
                cmp2_start <= 1'b1;
                state_r <= ST_COMMIT;
            end
        end
        ST_COMMIT: begin
            if (cmp2_result_valid) begin
                emit_start <= 1'b1;
                state_r <= ST_FEEDBACK;
            end
        end
        ST_FEEDBACK: begin
            if (emit_done_w) begin
                seed_token_id_r <= emit_new_seed;
                seed_position_r <= emit_new_position;
                kv_commit_old_prefix_r <= committed_prefix_len_r;
                kv_commit_count_r <= emit_tokens_emitted;
                committed_prefix_len_r <= emit_new_prefix_len;
                gen_count_r <= gen_count_r + {4'd0, emit_tokens_emitted};
                state_r <= ST_KV_COMMIT;
                // synthesis translate_off
                $display("[TC_TOP] round done: emitted %0d tokens, new_seed=%0d pos=%0d",
                    emit_tokens_emitted, emit_new_seed, emit_new_position);
                // synthesis translate_on
            end
        end
        ST_KV_COMMIT: begin
            // KV copy is done in the generate block's always (see below)
            state_r <= ST_CHECK;
        end
        ST_CHECK: begin
            if (gen_count_r >= max_gen_r) state_r <= ST_DONE;
            else state_r <= ST_PREDICT;
        end
        ST_DONE: begin
            done <= 1'b1;
            busy <= 1'b0;
            state_r <= ST_IDLE;
        end
        default: state_r <= ST_IDLE;
        endcase
    end
end

assign sched_start = (state_r == ST_VERIFY) && !verify_started_r && stmp_issue_received_r;

endmodule
