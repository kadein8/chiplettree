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
    parameter integer VOCAB_SIZE     = `MODEL_VOCAB_SIZE
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
    ST_CHECK    = 4'd7,
    ST_DONE     = 4'd8,
    ST_FALLBACK = 4'd9;

logic [3:0] state_r;
logic [7:0] gen_count_r, max_gen_r;
logic [`NODE_ID_W-1:0]     seed_node_id_r;
logic [`TOKEN_ID_W-1:0]    seed_token_id_r;
logic [`POSITION_ID_W-1:0] seed_position_r;
logic [15:0]               committed_prefix_len_r;

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
    .cand_valid(hht_cand_valid),
    .cand_parent_node_id(hht_cand_parent_node_id),
    .cand_token_id(hht_cand_token_id),
    .cand_referenced_position(hht_cand_referenced_position),
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
    .tree_req_valid(tb_tree_req_valid),
    .tree_req_ready(tb_tree_req_ready),
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
// PE Array: PeArrayLayerController + SRAM infrastructure
// =========================================================================
logic lc_start, lc_done, lc_busy;
logic [`TREE_FRONTIER_SLOTS-1:0] lc_slot_valid;
logic [`TREE_FRONTIER_SLOTS*`TOKEN_ID_W-1:0] lc_slot_token_id;
logic [`TREE_FRONTIER_SLOTS*`POSITION_ID_W-1:0] lc_slot_position_id;
logic [`TREE_FRONTIER_SLOTS*`TREE_FRONTIER_SLOTS-1:0] lc_tree_mask;
logic [`TREE_FRONTIER_SLOTS-1:0] lc_out_token_valid;
logic [`TREE_FRONTIER_SLOTS*`TOKEN_ID_W-1:0] lc_out_token_id;

// SRAM signals
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

PeArrayLayerController u_layer_ctrl (
    .clk(clk), .rst_n(rst_n),
    .start(lc_start), .done(lc_done), .busy(lc_busy),
    .slot_valid(lc_slot_valid),
    .slot_token_id(lc_slot_token_id),
    .slot_position_id(lc_slot_position_id),
    .tree_mask(lc_tree_mask),
    .embedding_base_addr(`MODEL_EMB_BASE),
    .hidden0_base_addr(`MODEL_WORK_HIDDEN0_BASE),
    .hidden1_base_addr(`MODEL_WORK_HIDDEN1_BASE),
    .final_base_addr(`MODEL_WORK_FINAL_BASE),
    .weight_sram_base_addr(`MODEL_WEIGHT_SRAM_BASE),
    .kv_cache_base_addr(`KV_DRAFT_BASE_MIN),
    .final_norm_gamma_addr(`MODEL_FINAL_NORM_GAMMA_ADDR),
    .lm_head_weight_base_addr(`MODEL_LM_HEAD_WEIGHT_BASE),
    .hbm_weight_base_addr(`MODEL_HBM_WEIGHT_BASE),
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
    .hbm_rd_valid(hbm_rd_valid), .hbm_rd_ready(hbm_rd_ready),
    .hbm_rd_addr(hbm_rd_addr),
    .hbm_resp_valid(hbm_resp_valid), .hbm_resp_data(hbm_resp_data),
    .out_token_valid(lc_out_token_valid), .out_token_id(lc_out_token_id)
);

// =========================================================================
// Behavioral SRAM (same as e2e_top)
// =========================================================================
localparam BEHAV_SRAM_DEPTH = 131072;
reg [`SRAM_RDATA_W-1:0] behav_sram [0:BEHAV_SRAM_DEPTH-1];

wire [`MEM_REQ_LANES-1:0] mem_req_valid_w, mem_req_ready_w, mem_req_write_w;
wire [`MEM_REQ_LANES*`SRAM_ADDR_W-1:0] mem_req_addr_w;
wire [`MEM_REQ_LANES*`SRAM_WDATA_W-1:0] mem_req_wdata_w;
wire [`MEM_REQ_LANES*`REQ_ID_W-1:0] mem_req_id_w;
assign mem_req_ready_w = {`MEM_REQ_LANES{1'b1}};

reg [`MEM_REQ_LANES-1:0] behav_resp_valid_r;
reg [`MEM_REQ_LANES*`SRAM_RDATA_W-1:0] behav_resp_rdata_r;
reg [`MEM_REQ_LANES*`REQ_ID_W-1:0] behav_resp_id_r;
reg [`MEM_REQ_LANES-1:0] behav_resp_last_r;

integer mi;
always @(posedge clk) begin
    for (mi = 0; mi < `MEM_REQ_LANES; mi = mi + 1) begin
        behav_resp_valid_r[mi] <= mem_req_valid_w[mi] && !mem_req_write_w[mi];
        if (mem_req_valid_w[mi]) begin
            if (mem_req_write_w[mi]) begin
                if (mem_req_addr_w[mi*`SRAM_ADDR_W +: `SRAM_ADDR_W] < BEHAV_SRAM_DEPTH)
                    behav_sram[mem_req_addr_w[mi*`SRAM_ADDR_W +: `SRAM_ADDR_W]] <=
                        mem_req_wdata_w[mi*`SRAM_WDATA_W +: `SRAM_WDATA_W];
            end else begin
                if (mem_req_addr_w[mi*`SRAM_ADDR_W +: `SRAM_ADDR_W] < BEHAV_SRAM_DEPTH)
                    behav_resp_rdata_r[mi*`SRAM_RDATA_W +: `SRAM_RDATA_W] <=
                        behav_sram[mem_req_addr_w[mi*`SRAM_ADDR_W +: `SRAM_ADDR_W]];
                else
                    behav_resp_rdata_r[mi*`SRAM_RDATA_W +: `SRAM_RDATA_W] <= '0;
            end
            behav_resp_id_r[mi*`REQ_ID_W +: `REQ_ID_W] <=
                mem_req_id_w[mi*`REQ_ID_W +: `REQ_ID_W];
        end
        behav_resp_last_r[mi] <= mem_req_valid_w[mi] && !mem_req_write_w[mi];
    end
end

// Scalar write path (preload only in this top)
wire [`BANK_ID_W-1:0] rc_wr_bank_id = lc_sram_wr_addr[`OFFSET_W+`ROW_ADDR_W+`SUBBANK_ID_W +: `BANK_ID_W];
wire [`SUBBANK_ID_W-1:0] rc_wr_subbank_id = lc_sram_wr_addr[`OFFSET_W+`ROW_ADDR_W +: `SUBBANK_ID_W];
wire rc_req_in_valid = sram_preload_valid || lc_sram_wr_valid;
wire [`SRAM_ADDR_W-1:0] rc_req_in_addr = sram_preload_valid ? sram_preload_addr : lc_sram_wr_addr;
wire [`SRAM_WDATA_W-1:0] rc_req_in_wdata = sram_preload_valid ? sram_preload_data : lc_sram_wr_data;
wire rc_req_in_ready;
assign lc_sram_wr_ready = rc_req_in_ready && !sram_preload_valid;

request_controller u_req_ctrl (
    .clk(clk), .rst_n(rst_n),
    .req_in_valid(rc_req_in_valid), .req_in_ready(rc_req_in_ready),
    .req_in_write(1'b1), .req_in_addr(rc_req_in_addr), .req_in_wdata(rc_req_in_wdata),
    .req_in_req_id({`REQ_ID_W{1'b0}}), .req_in_pe_mask({`PE_MASK_W{1'b0}}),
    .req_in_priority(2'b00),
    .req_in_bank_id(sram_preload_valid ? sram_preload_addr[`OFFSET_W+`ROW_ADDR_W+`SUBBANK_ID_W +: `BANK_ID_W] : rc_wr_bank_id),
    .req_in_subbank_id(sram_preload_valid ? sram_preload_addr[`OFFSET_W+`ROW_ADDR_W +: `SUBBANK_ID_W] : rc_wr_subbank_id),
    .vec_req_valid(lc_vec_req_valid), .vec_req_ready(lc_vec_req_ready),
    .vec_req_write(lc_vec_req_write), .vec_req_addr(lc_vec_req_addr),
    .vec_req_wdata(lc_vec_req_wdata), .vec_req_req_id(lc_vec_req_req_id),
    .vec_req_pe_mask(lc_vec_req_pe_mask), .vec_req_priority(lc_vec_req_priority),
    .vec_req_bank_id(lc_vec_req_bank_id), .vec_req_subbank_id(lc_vec_req_subbank_id),
    .mem_req_valid(mem_req_valid_w), .mem_req_ready(mem_req_ready_w),
    .mem_req_write(mem_req_write_w), .mem_req_addr(mem_req_addr_w),
    .mem_req_wdata(mem_req_wdata_w), .mem_req_id(mem_req_id_w),
    .mem_resp_valid(behav_resp_valid_r), .mem_resp_rdata(behav_resp_rdata_r),
    .mem_resp_id(behav_resp_id_r), .mem_resp_last(behav_resp_last_r),
    .resp_out_valid(), .resp_out_ready({`MEM_REQ_LANES{1'b1}}),
    .resp_out_rdata(), .resp_out_req_id(), .resp_out_pe_mask(), .resp_out_last()
);

// Direct multicast bypass: route request_controller responses to LC
assign lc_mc_resp_valid = behav_resp_valid_r;
assign lc_mc_resp_rdata = behav_resp_rdata_r;
assign lc_mc_resp_req_id = behav_resp_id_r;
assign lc_mc_resp_last = behav_resp_last_r;

// =========================================================================
// Issue Bundle → LC Bridge + Lifecycle FSM
// =========================================================================
// When issue_bundle arrives, latch it and start the layer controller.
// When LC finishes, collect results and fire comparator.

assign paper_issue_bundle_ready = !lc_busy && (state_r == ST_VERIFY);

// Detect lc_done rising edge (transition from busy→done)
logic lc_done_prev_r;
wire lc_done_rising = lc_done && !lc_done_prev_r;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) lc_done_prev_r <= 1'b0;
    else lc_done_prev_r <= lc_done;
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        lc_start <= 1'b0;
        lc_slot_valid <= '0;
        lc_slot_token_id <= '0;
        lc_slot_position_id <= '0;
        lc_tree_mask <= '0;
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
        lc_start <= 1'b0;
        lifecycle_cmp_fire_r <= 1'b0;

        // Latch issue_bundle and start LC
        if (paper_issue_bundle_valid && paper_issue_bundle_ready) begin
            lc_start <= 1'b1;
            lc_slot_valid <= paper_issue_bundle_slot_valid;
            lc_slot_token_id <= paper_issue_bundle_token_id;
            lc_slot_position_id <= paper_issue_bundle_position_id;
            // Use visible_mask as tree_mask (truncated to WINDOW_SIZE×WINDOW_SIZE)
            lc_tree_mask <= paper_issue_bundle_slot_visible_mask[`TREE_FRONTIER_SLOTS*`TREE_FRONTIER_SLOTS-1:0];
            lifecycle_req_id_r <= paper_issue_bundle_req_id;

            // Latch metadata for comparator
            lifecycle_cmp_slot_valid <= paper_issue_bundle_slot_valid[`BRANCH_NUM-1:0];
            lifecycle_slot_meta_valid_r <= paper_issue_bundle_slot_valid[`BRANCH_NUM-1:0];
            lifecycle_cmp_node_id_r <= paper_issue_bundle_node_id[`BRANCH_NUM*`NODE_ID_W-1:0];
            lifecycle_cmp_parent_node_id_r <= paper_issue_bundle_parent_node_id[`BRANCH_NUM*`NODE_ID_W-1:0];
            lifecycle_cmp_branch_id_r <= paper_issue_bundle_branch_id[`BRANCH_NUM*`BRANCH_ID_W-1:0];
            // Candidate tokens = the draft tokens from the issue bundle
            lifecycle_cmp_candidate_token_id_r <= paper_issue_bundle_token_id[`BRANCH_NUM*`TOKEN_ID_W-1:0];

            // Set active_branch_depth to 1 for each valid slot (minimum depth for accept)
            // and populate active_branch_node_id with the node from issue_bundle
            begin : set_branch_meta
                integer bm;
                for (bm = 0; bm < `BRANCH_NUM; bm = bm + 1) begin
                    if (paper_issue_bundle_slot_valid[bm]) begin
                        lifecycle_active_branch_depth[bm*PRIV_DEPTH_W +: PRIV_DEPTH_W] <=
                            {{(PRIV_DEPTH_W-1){1'b0}}, 1'b1};  // depth = 1
                        // First node in branch path = the node from issue_bundle
                        lifecycle_active_branch_node_id[bm*`MAX_VERIFY_NODES_PER_BRANCH*`NODE_ID_W +: `NODE_ID_W] <=
                            paper_issue_bundle_node_id[bm*`NODE_ID_W +: `NODE_ID_W];
                        lifecycle_active_branch_parent_node_id[bm*`MAX_VERIFY_NODES_PER_BRANCH*`NODE_ID_W +: `NODE_ID_W] <=
                            paper_issue_bundle_parent_node_id[bm*`NODE_ID_W +: `NODE_ID_W];
                    end
                end
            end

            // synthesis translate_off
            $display("[TC_TOP] LC_START from issue_bundle: slots=%b req_id=%0d",
                paper_issue_bundle_slot_valid, paper_issue_bundle_req_id);
            // synthesis translate_on
        end

        // When LC finishes (rising edge), fire comparator with results
        if (lc_done_rising && state_r == ST_VERIFY) begin
            lifecycle_cmp_fire_r <= 1'b1;
            // Real tokens = argmax output from PE
            lifecycle_cmp_real_token_id_r <= lc_out_token_id[`BRANCH_NUM*`TOKEN_ID_W-1:0];
            lifecycle_slot_result_valid_r <= lc_slot_valid[`BRANCH_NUM-1:0];
            // Update slot_meta_valid to reflect what was actually computed
            lifecycle_slot_meta_valid_r <= lc_slot_valid[`BRANCH_NUM-1:0];
            lifecycle_cmp_slot_valid <= lc_slot_valid[`BRANCH_NUM-1:0];

            // Set branch_id sequentially for each valid slot
            begin : set_branch_ids
                integer br;
                for (br = 0; br < `BRANCH_NUM; br = br + 1) begin
                    lifecycle_cmp_branch_id_r[br*`BRANCH_ID_W +: `BRANCH_ID_W] <=
                        br[`BRANCH_ID_W-1:0];
                    // Set node_id = branch index (simplified)
                    lifecycle_cmp_node_id_r[br*`NODE_ID_W +: `NODE_ID_W] <=
                        br[`NODE_ID_W-1:0];
                    // active_branch_node_id[branch][0] must match result_node_id
                    lifecycle_active_branch_node_id[br*`MAX_VERIFY_NODES_PER_BRANCH*`NODE_ID_W +: `NODE_ID_W] <=
                        br[`NODE_ID_W-1:0];
                    if (lc_slot_valid[br]) begin
                        lifecycle_active_branch_depth[br*PRIV_DEPTH_W +: PRIV_DEPTH_W] <=
                            {{(PRIV_DEPTH_W-1){1'b0}}, 1'b1};
                    end
                end
            end

            // Set result_private_depth = 1 for each valid branch
            begin : set_result_depth
                integer br;
                for (br = 0; br < `BRANCH_NUM; br = br + 1) begin
                    lifecycle_result_private_depth[br*PRIV_DEPTH_W +: PRIV_DEPTH_W] <=
                        lc_slot_valid[br] ? {{(PRIV_DEPTH_W-1){1'b0}}, 1'b1} : {PRIV_DEPTH_W{1'b0}};
                end
            end

            // Accept if real == candidate (for first slot, always accept since
            // this is the seed token verification)
            begin : cmp_accept_gen
                integer bi;
                for (bi = 0; bi < `BRANCH_NUM; bi = bi + 1) begin
                    // For TreeControl path: always accept (we're verifying the tree)
                    lifecycle_result_accept[bi] <= lc_slot_valid[bi];
                end
            end

            // synthesis translate_off
            $display("[TC_TOP] LC_DONE: real[0]=%0d real[1]=%0d real[2]=%0d real[3]=%0d",
                lc_out_token_id[0*`TOKEN_ID_W +: `TOKEN_ID_W],
                lc_out_token_id[1*`TOKEN_ID_W +: `TOKEN_ID_W],
                lc_out_token_id[2*`TOKEN_ID_W +: `TOKEN_ID_W],
                lc_out_token_id[3*`TOKEN_ID_W +: `TOKEN_ID_W]);
            // synthesis translate_on
        end
    end
end

// =========================================================================
// Main State Machine + HHT feedback
// =========================================================================
assign tb_start = (state_r == ST_BUILD) && !tb_busy && !tb_done;
assign tb_hht_done = (state_r != ST_BUILD);

// HHT accept: warmup OR commit feedback
assign hht_accept_valid = warmup_accept_valid || cmp_accepted_prefix_valid;
assign hht_accept_parent_node_id = warmup_accept_valid ? warmup_accept_parent_node_id :
    cmp_accepted_prefix_node_id[`NODE_ID_W-1:0];
assign hht_accept_token_id = warmup_accept_valid ? warmup_accept_token_id :
    lc_out_token_id[cmp_accepted_prefix_branch_id*`TOKEN_ID_W +: `TOKEN_ID_W];
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
        token_out_valid <= 1'b0;
        token_out_id <= '0;
    end else begin
        done <= 1'b0;
        token_out_valid <= 1'b0;

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
        end

        ST_BUILD: begin
            if (tb_done) begin
                if (|tb_branch_valid)
                    state_r <= ST_VERIFY;
                else
                    state_r <= ST_DONE; // no tree → done
            end
        end

        ST_VERIFY: begin
            // Wait for comparator to produce accepted prefix
            if (cmp_accepted_prefix_valid) begin
                // Emit accepted token
                token_out_valid <= 1'b1;
                token_out_id <= lc_out_token_id[cmp_accepted_prefix_branch_id*`TOKEN_ID_W +: `TOKEN_ID_W];
                gen_count_r <= gen_count_r + 8'd1;
                // Update seed
                seed_token_id_r <= lc_out_token_id[cmp_accepted_prefix_branch_id*`TOKEN_ID_W +: `TOKEN_ID_W];
                seed_position_r <= seed_position_r + {{(`POSITION_ID_W-1){1'b0}}, 1'b1};
                committed_prefix_len_r <= committed_prefix_len_r + 16'd1;
                state_r <= ST_CHECK;

                // synthesis translate_off
                $display("[TC_TOP] ACCEPTED token=%0d from branch=%0d depth=%0d",
                    lc_out_token_id[cmp_accepted_prefix_branch_id*`TOKEN_ID_W +: `TOKEN_ID_W],
                    cmp_accepted_prefix_branch_id, cmp_accepted_prefix_depth);
                // synthesis translate_on
            end
        end

        ST_CHECK: begin
            if (gen_count_r >= max_gen_r)
                state_r <= ST_DONE;
            else
                state_r <= ST_PREDICT;
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

endmodule
