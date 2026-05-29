`include "config/interface_params.vh"
`include "config/prediction_params.vh"
`include "config/model_params.vh"
`include "config/memory_params.vh"
`timescale 1ns/1ps

// speculative_decode_e2e_top
//
// Top-level closed-loop speculative decoding for a single chiplet.
// Implements the full paper pipeline:
//   HHT prediction → tree_builder → tree_verify_dispatcher →
//   PeArrayLayerController (real transformer) → comparator → feedback → HHT
//
// Autoregressive loop:
//   1. Prefill: process prompt token through transformer, get first output
//   2. Predict: HHT generates draft candidates
//   3. Build: tree_builder organizes candidates into branch/level structure
//   4. Verify: tree_verify_dispatcher flattens tree, generates mask,
//              dispatches to transformer, compares results
//   5. Commit: feedback_controller emits accepted tokens, updates HHT
//   6. Repeat from step 2 until max_gen_tokens reached

module speculative_decode_e2e_top #(
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

    // HBM interface (retained for weight preload to SRAM)
    output logic                          hbm_rd_valid,
    input  logic                          hbm_rd_ready,
    output logic [`HBM_ADDR_W-1:0]        hbm_rd_addr,
    input  logic                          hbm_resp_valid,
    input  logic [`HBM_DATA_W-1:0]        hbm_resp_data,

    // SRAM preload interface (testbench writes weights before start)
    input  logic                          sram_preload_valid,
    input  logic [`SRAM_ADDR_W-1:0]       sram_preload_addr,
    input  logic [`SRAM_WDATA_W-1:0]      sram_preload_data,

    // HHT warmup interface (testbench injects accept records before start)
    input  logic                          warmup_accept_valid,
    input  logic [`NODE_ID_W-1:0]         warmup_accept_parent_node_id,
    input  logic [`TOKEN_ID_W-1:0]        warmup_accept_token_id,
    input  logic [`POSITION_ID_W-1:0]     warmup_accept_position
);

// =========================================================================
// State machine
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
logic [7:0] gen_count_r;
logic [7:0] max_gen_r;

// Seed state (updated after each commit)
logic [`NODE_ID_W-1:0]     seed_node_id_r;
logic [`TOKEN_ID_W-1:0]    seed_token_id_r;
logic [`POSITION_ID_W-1:0] seed_position_r;
logic [15:0]               committed_prefix_len_r;

// =========================================================================
// HHT Context Predictor
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

// Speculative lookup wires (tree_builder ↔ HHT) — must be declared before instantiation
logic [`TOKEN_ID_W-1:0] tb_spec_token_0, tb_spec_token_1;
logic tb_spec_query_valid, tb_spec_hit;
logic [`TOKEN_ID_W-1:0] tb_spec_prediction;

HHTContextPredictor #(
    .CONF_W(8),
    .HISTORY_LEN(2),
    .SET_NUM(8),
    .WAY_NUM(4)
) u_hht (
    .clk(clk),
    .rst_n(rst_n),
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
// Tree Builder
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
    .BRANCH_NUM(BRANCH_NUM),
    .MAX_LEVELS(MAX_LEVELS),
    .TIMEOUT_CYCLES(64)
) u_tree_builder (
    .clk(clk),
    .rst_n(rst_n),
    .start(tb_start),
    .done(tb_done),
    .busy(tb_busy),
    .seed_node_id(seed_node_id_r),
    .seed_token_id(seed_token_id_r),
    .seed_position(seed_position_r),
    .committed_prefix_len_in(committed_prefix_len_r),
    .cand_valid(hht_cand_valid),
    .cand_parent_node_id(hht_cand_parent_node_id),
    .cand_token_id(hht_cand_token_id),
    .cand_referenced_position(hht_cand_referenced_position),
    .hht_done(tb_hht_done),
    .spec_token_0(tb_spec_token_0),
    .spec_token_1(tb_spec_token_1),
    .spec_query_valid(tb_spec_query_valid),
    .spec_hit(tb_spec_hit),
    .spec_prediction(tb_spec_prediction),
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

// =========================================================================
// Tree Verify Dispatcher (existing module)
// =========================================================================
logic tvd_batch_out_valid, tvd_batch_out_ready;
logic [4:0] tvd_batch_out_count;
logic [WINDOW_SIZE*32-1:0] tvd_batch_out_token_ids;
logic [WINDOW_SIZE*16-1:0] tvd_batch_out_positions;
logic [WINDOW_SIZE*WINDOW_SIZE-1:0] tvd_batch_out_tree_mask;
logic [15:0] tvd_batch_out_prefix_len;
logic tvd_batch_out_seed_kv_valid;
logic [WINDOW_SIZE-1:0] tvd_batch_out_slot_is_seed;

logic tvd_fwd_result_valid, tvd_fwd_result_ready;
logic [4:0] tvd_fwd_result_count;
logic [WINDOW_SIZE*32-1:0] tvd_fwd_result_token_ids;

logic tvd_commit_valid;
logic [`BRANCH_ID_W-1:0] tvd_commit_branch_id;
logic [2:0] tvd_commit_depth;
logic [`TOKEN_ID_W-1:0] tvd_commit_bonus_token_id;
logic [BRANCH_NUM-1:0] tvd_commit_flush_mask;
logic [MAX_LEVELS*`SLOT_ID_W-1:0] tvd_commit_slots;
logic [MAX_LEVELS*16-1:0] tvd_commit_slot_positions;
logic tvd_busy;

tree_verify_dispatcher #(
    .BRANCH_NUM(BRANCH_NUM),
    .MAX_LEVELS(MAX_LEVELS),
    .WINDOW_SIZE(WINDOW_SIZE)
) u_dispatcher (
    .clk(clk),
    .rst_n(rst_n),
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
    .batch_out_valid(tvd_batch_out_valid),
    .batch_out_ready(tvd_batch_out_ready),
    .batch_out_count(tvd_batch_out_count),
    .batch_out_token_ids(tvd_batch_out_token_ids),
    .batch_out_positions(tvd_batch_out_positions),
    .batch_out_tree_mask(tvd_batch_out_tree_mask),
    .batch_out_prefix_len(tvd_batch_out_prefix_len),
    .batch_out_seed_kv_valid(tvd_batch_out_seed_kv_valid),
    .batch_out_slot_is_seed(tvd_batch_out_slot_is_seed),
    .fwd_result_valid(tvd_fwd_result_valid),
    .fwd_result_ready(tvd_fwd_result_ready),
    .fwd_result_count(tvd_fwd_result_count),
    .fwd_result_token_ids(tvd_fwd_result_token_ids),
    .commit_valid(tvd_commit_valid),
    .commit_branch_id(tvd_commit_branch_id),
    .commit_depth(tvd_commit_depth),
    .commit_bonus_token_id(tvd_commit_bonus_token_id),
    .commit_flush_mask(tvd_commit_flush_mask),
    .commit_slots(tvd_commit_slots),
    .commit_slot_positions(tvd_commit_slot_positions),
    .busy(tvd_busy)
);

// =========================================================================
// Feedback Controller
// =========================================================================
logic fb_busy, fb_done;
logic fb_out_token_valid;
logic [`TOKEN_ID_W-1:0] fb_out_token_id;
logic [`POSITION_ID_W-1:0] fb_out_token_position;
logic fb_new_seed_valid;
logic [`NODE_ID_W-1:0] fb_new_seed_node_id;
logic [`TOKEN_ID_W-1:0] fb_new_seed_token_id;
logic [`POSITION_ID_W-1:0] fb_new_seed_position;
logic fb_hht_accept_valid;
logic [`NODE_ID_W-1:0] fb_hht_accept_parent_node_id;
logic [`TOKEN_ID_W-1:0] fb_hht_accept_token_id;
logic [`POSITION_ID_W-1:0] fb_hht_accept_position;

feedback_controller #(
    .BRANCH_NUM(BRANCH_NUM),
    .MAX_LEVELS(MAX_LEVELS)
) u_feedback (
    .clk(clk),
    .rst_n(rst_n),
    .commit_valid(tvd_commit_valid),
    .commit_branch_id(tvd_commit_branch_id),
    .commit_depth(tvd_commit_depth),
    .commit_bonus_token_id(tvd_commit_bonus_token_id),
    .commit_flush_mask(tvd_commit_flush_mask),
    .commit_slots(tvd_commit_slots),
    .commit_slot_positions(tvd_commit_slot_positions),
    .branch_draft_tokens(tb_branch_draft_tokens),
    .branch_node_ids(tb_branch_node_ids),
    .branch_draft_positions(tb_branch_draft_positions),
    .hht_accept_valid(fb_hht_accept_valid),
    .hht_accept_parent_node_id(fb_hht_accept_parent_node_id),
    .hht_accept_token_id(fb_hht_accept_token_id),
    .hht_accept_position(fb_hht_accept_position),
    .out_token_valid(fb_out_token_valid),
    .out_token_id(fb_out_token_id),
    .out_token_position(fb_out_token_position),
    .new_seed_valid(fb_new_seed_valid),
    .new_seed_node_id(fb_new_seed_node_id),
    .new_seed_token_id(fb_new_seed_token_id),
    .new_seed_position(fb_new_seed_position),
    .busy(fb_busy),
    .done(fb_done)
);

// =========================================================================
// Forward declarations for signals used before their module instantiation
// =========================================================================
logic lc_done;
logic [`TREE_FRONTIER_SLOTS*`TOKEN_ID_W-1:0] lc_out_token_id;

// =========================================================================
// Draft Injection Interface (behavioral simulation of external draft chiplet)
// =========================================================================
logic draft_inject_start;
logic draft_valid, draft_done_w;
logic [`TOKEN_ID_W-1:0] draft_token_id;
logic [`NODE_ID_W-1:0] draft_parent_node_id;
logic [`POSITION_ID_W-1:0] draft_position;
logic [1:0] draft_branch_id;
logic [2:0] draft_depth;
logic [BRANCH_NUM-1:0] draft_branch_active;
logic [BRANCH_NUM*MAX_LEVELS*`TOKEN_ID_W-1:0] draft_branch_injected_tokens;

draft_injection_interface #(
    .BRANCH_NUM(BRANCH_NUM),
    .MAX_DEPTH(MAX_LEVELS)
) u_draft_inject (
    .clk(clk),
    .rst_n(rst_n),
    .inject_start(draft_inject_start),
    .seed_token_id(seed_token_id_r),
    .seed_position(seed_position_r),
    .seed_node_id(seed_node_id_r),
    .commit_feedback_valid(1'b0),
    .commit_feedback_token({`TOKEN_ID_W{1'b0}}),
    .draft_valid(draft_valid),
    .draft_token_id(draft_token_id),
    .draft_parent_node_id(draft_parent_node_id),
    .draft_position(draft_position),
    .draft_branch_id(draft_branch_id),
    .draft_depth(draft_depth),
    .draft_done(draft_done_w),
    .branch_active(draft_branch_active),
    .branch_injected_tokens(draft_branch_injected_tokens),
    .branch_depth_out()  // unused for now
);

// Draft injection triggers at the same time as tree building
assign draft_inject_start = (state_r == ST_BUILD) && !tb_busy && !tb_done;

// =========================================================================
// Longest Path Comparator (branch-level verification)
// =========================================================================
logic comparator_start;
logic comparator_result_valid;
logic [3:0] comparator_accepted_count;
logic [(MAX_LEVELS+1)*`TOKEN_ID_W-1:0] comparator_accepted_tokens;
logic [BRANCH_NUM-1:0] comparator_flush_mask;
logic comparator_all_correct;

// Forward declarations for scheduler signals (defined later with kv_share_scheduler)
logic sched_all_done;
logic [BRANCH_NUM-1:0] sched_branch_valid;
logic [BRANCH_NUM*`TOKEN_ID_W-1:0] sched_branch_generated_token;

// Per-branch generated tokens: now from kv_share_scheduler
wire [BRANCH_NUM*`TOKEN_ID_W-1:0] branch_gen_tokens = sched_branch_generated_token;

longest_path_comparator #(
    .BRANCH_NUM(BRANCH_NUM),
    .MAX_DEPTH(MAX_LEVELS)
) u_comparator (
    .clk(clk),
    .rst_n(rst_n),
    .compare_start(comparator_start),
    .branch_generated_token(branch_gen_tokens),
    .branch_valid(sched_branch_valid),
    .branch_injected_tokens(draft_branch_injected_tokens),
    .branch_depth({3'd1, 3'd2, 3'd1, 3'd0}),  // packed: branch3=1, branch2=2, branch1=1, branch0=0
    .result_valid(comparator_result_valid),
    .accepted_count(comparator_accepted_count),
    .accepted_tokens(comparator_accepted_tokens),
    .flush_mask(comparator_flush_mask),
    .all_correct(comparator_all_correct)
);

// Comparator triggers when kv_share_scheduler finishes all branches
assign comparator_start = sched_all_done;

// HHT accept mux: from feedback controller, prefill/startup, or testbench warmup
wire prefill_done_accept = (state_r == ST_PREFILL && lc_done);
assign hht_accept_valid = fb_hht_accept_valid ||
    prefill_done_accept ||
    (state_r == ST_IDLE && start) ||
    warmup_accept_valid;
// When prefill completes, the accept's parent must be the NEW seed_node_id (1),
// not the old value (0). Otherwise tree_builder's seed_node_id won't match
// cand_parent_node_id and the candidate will be discarded.
wire [`NODE_ID_W-1:0] prefill_done_node_id = {{(`NODE_ID_W-1){1'b0}}, 1'b1};
assign hht_accept_parent_node_id = warmup_accept_valid ? warmup_accept_parent_node_id :
    (fb_hht_accept_valid ? fb_hht_accept_parent_node_id :
     (prefill_done_accept ? prefill_done_node_id : seed_node_id_r));
assign hht_accept_token_id = warmup_accept_valid ? warmup_accept_token_id :
    (fb_hht_accept_valid ? fb_hht_accept_token_id :
     (start ? prompt_token_id :
      (prefill_done_accept ? lc_out_token_id[`TOKEN_ID_W-1:0] : seed_token_id_r)));
assign hht_accept_position = warmup_accept_valid ? warmup_accept_position :
    (fb_hht_accept_valid ? fb_hht_accept_position :
     (prefill_done_accept ? {{(`POSITION_ID_W-1){1'b0}}, 1'b1} : seed_position_r));

// =========================================================================
// Layer Controller (transformer compute)
// =========================================================================
// LC signals are muxed between main FSM (prefill/fallback) and kv_share_scheduler (verify)
wire lc_start;
logic lc_busy;
wire [`TREE_FRONTIER_SLOTS-1:0] lc_slot_valid;
wire [`TREE_FRONTIER_SLOTS*`TOKEN_ID_W-1:0] lc_slot_token_id;
wire [`TREE_FRONTIER_SLOTS*`POSITION_ID_W-1:0] lc_slot_position_id;
wire [`TREE_FRONTIER_SLOTS*`TREE_FRONTIER_SLOTS-1:0] lc_tree_mask;
logic [`TREE_FRONTIER_SLOTS-1:0] lc_out_token_valid;

// FSM-driven LC signals (for prefill/fallback)
logic fsm_lc_start;
logic [`TREE_FRONTIER_SLOTS-1:0] fsm_lc_slot_valid;
logic [`TREE_FRONTIER_SLOTS*`TOKEN_ID_W-1:0] fsm_lc_slot_token_id;
logic [`TREE_FRONTIER_SLOTS*`POSITION_ID_W-1:0] fsm_lc_slot_position_id;
logic [`TREE_FRONTIER_SLOTS*`TREE_FRONTIER_SLOTS-1:0] fsm_lc_tree_mask;

// Scheduler-driven LC signals (for verify phase)
logic sched_lc_start;
logic [`TREE_FRONTIER_SLOTS-1:0] sched_lc_slot_valid;
logic [`TREE_FRONTIER_SLOTS*`TOKEN_ID_W-1:0] sched_lc_slot_token_id;
logic [`TREE_FRONTIER_SLOTS*`POSITION_ID_W-1:0] sched_lc_slot_position_id;
logic [`TREE_FRONTIER_SLOTS*`TREE_FRONTIER_SLOTS-1:0] sched_lc_tree_mask;

// Mux: scheduler owns LC during ST_VERIFY, FSM owns otherwise
wire sched_owns_lc = (state_r == ST_VERIFY);
assign lc_start          = sched_owns_lc ? sched_lc_start          : fsm_lc_start;
assign lc_slot_valid     = sched_owns_lc ? sched_lc_slot_valid     : fsm_lc_slot_valid;
assign lc_slot_token_id  = sched_owns_lc ? sched_lc_slot_token_id  : fsm_lc_slot_token_id;
assign lc_slot_position_id = sched_owns_lc ? sched_lc_slot_position_id : fsm_lc_slot_position_id;
assign lc_tree_mask      = sched_owns_lc ? sched_lc_tree_mask      : fsm_lc_tree_mask;

// =========================================================================
// KV Share Scheduler (drives LC during verify phase)
// =========================================================================
logic sched_batch_valid, sched_batch_ready;
// sched_all_done, sched_branch_valid, sched_branch_generated_token declared above (forward decl)

kv_share_scheduler #(
    .BRANCH_NUM(BRANCH_NUM),
    .MAX_DEPTH(MAX_LEVELS),
    .WINDOW_SIZE(WINDOW_SIZE)
) u_kv_sched (
    .clk(clk),
    .rst_n(rst_n),
    .batch_valid(sched_batch_valid),
    .batch_ready(sched_batch_ready),
    .batch_count(tvd_batch_out_count),
    .batch_token_ids(tvd_batch_out_token_ids),
    .batch_positions(tvd_batch_out_positions),
    .batch_tree_mask(tvd_batch_out_tree_mask),
    .batch_prefix_len(tvd_batch_out_prefix_len),
    .batch_slot_is_seed(tvd_batch_out_slot_is_seed),
    .lc_start(sched_lc_start),
    .lc_done(lc_done),
    .lc_busy(lc_busy),
    .lc_slot_valid(sched_lc_slot_valid),
    .lc_slot_token_id(sched_lc_slot_token_id),
    .lc_slot_position_id(sched_lc_slot_position_id),
    .lc_tree_mask(sched_lc_tree_mask),
    .all_done(sched_all_done),
    .branch_valid_out(sched_branch_valid),
    .branch_generated_token(sched_branch_generated_token),
    .lc_out_token_valid(lc_out_token_valid),
    .lc_out_token_id(lc_out_token_id)
);

// Internal SRAM signals between layer_ctrl and request_controller
logic        lc_sram_wr_valid, lc_sram_wr_ready;
logic [`SRAM_ADDR_W-1:0] lc_sram_wr_addr;
logic [`SRAM_WDATA_W-1:0] lc_sram_wr_data;

// vec_req from layer_ctrl → request_controller
logic [`MEM_REQ_LANES-1:0]                    lc_vec_req_valid;
logic [`MEM_REQ_LANES-1:0]                    lc_vec_req_ready;
logic [`MEM_REQ_LANES-1:0]                    lc_vec_req_write;
logic [`MEM_REQ_LANES*`SRAM_ADDR_W-1:0]       lc_vec_req_addr;
logic [`MEM_REQ_LANES*`SRAM_WDATA_W-1:0]      lc_vec_req_wdata;
logic [`MEM_REQ_LANES*`REQ_ID_W-1:0]          lc_vec_req_req_id;
logic [`MEM_REQ_LANES*`PE_MASK_W-1:0]         lc_vec_req_pe_mask;
logic [`MEM_REQ_LANES*`REQ_PRIORITY_W-1:0]    lc_vec_req_priority;
logic [`MEM_REQ_LANES*`BANK_ID_W-1:0]         lc_vec_req_bank_id;
logic [`MEM_REQ_LANES*`SUBBANK_ID_W-1:0]      lc_vec_req_subbank_id;

// mc_resp from multicast_network → layer_ctrl
logic [`PE_MASK_W-1:0]                        lc_mc_resp_valid;
logic [`PE_MASK_W-1:0]                        lc_mc_resp_ready;
logic [`PE_MASK_W*`SRAM_RDATA_W-1:0]          lc_mc_resp_rdata;
logic [`PE_MASK_W*`REQ_ID_W-1:0]              lc_mc_resp_req_id;
logic [`PE_MASK_W-1:0]                        lc_mc_resp_last;

PeArrayLayerController u_layer_ctrl (
    .clk(clk),
    .rst_n(rst_n),
    .start(lc_start),
    .done(lc_done),
    .busy(lc_busy),
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
    // vec_req → request_controller
    .vec_req_valid(lc_vec_req_valid),
    .vec_req_ready(lc_vec_req_ready),
    .vec_req_write(lc_vec_req_write),
    .vec_req_addr(lc_vec_req_addr),
    .vec_req_wdata(lc_vec_req_wdata),
    .vec_req_req_id(lc_vec_req_req_id),
    .vec_req_pe_mask(lc_vec_req_pe_mask),
    .vec_req_priority(lc_vec_req_priority),
    .vec_req_bank_id(lc_vec_req_bank_id),
    .vec_req_subbank_id(lc_vec_req_subbank_id),
    // mc_resp ← multicast_network
    .mc_resp_valid(lc_mc_resp_valid),
    .mc_resp_ready(lc_mc_resp_ready),
    .mc_resp_rdata(lc_mc_resp_rdata),
    .mc_resp_req_id(lc_mc_resp_req_id),
    .mc_resp_last(lc_mc_resp_last),
    // Scalar write
    .sram_wr_valid(lc_sram_wr_valid),
    .sram_wr_ready(lc_sram_wr_ready),
    .sram_wr_addr(lc_sram_wr_addr),
    .sram_wr_data(lc_sram_wr_data),
    // HBM
    .hbm_rd_valid(hbm_rd_valid),
    .hbm_rd_ready(hbm_rd_ready),
    .hbm_rd_addr(hbm_rd_addr),
    .hbm_resp_valid(hbm_resp_valid),
    .hbm_resp_data(hbm_resp_data),
    .out_token_valid(lc_out_token_valid),
    .out_token_id(lc_out_token_id)
);

// =========================================================================
// Shared SRAM Infrastructure: request_controller + sram_subsystem + multicast
// =========================================================================

// Address field extraction for scalar write path
wire [`BANK_ID_W-1:0] rc_wr_bank_id =
    lc_sram_wr_addr[`OFFSET_W + `ROW_ADDR_W + `SUBBANK_ID_W +: `BANK_ID_W];
wire [`SUBBANK_ID_W-1:0] rc_wr_subbank_id =
    lc_sram_wr_addr[`OFFSET_W + `ROW_ADDR_W +: `SUBBANK_ID_W];

// request_controller ↔ sram_subsystem wires
wire [`MEM_REQ_LANES-1:0] mem_req_valid_w;
wire [`MEM_REQ_LANES-1:0] mem_req_ready_w;
wire [`MEM_REQ_LANES-1:0] mem_req_write_w;
wire [`MEM_REQ_LANES*`SRAM_ADDR_W-1:0] mem_req_addr_w;
wire [`MEM_REQ_LANES*`SRAM_WDATA_W-1:0] mem_req_wdata_w;
wire [`MEM_REQ_LANES*`REQ_ID_W-1:0] mem_req_id_w;
wire [`MEM_REQ_LANES-1:0] mem_resp_valid_w;
wire [`MEM_REQ_LANES*`SRAM_RDATA_W-1:0] mem_resp_rdata_w;
wire [`MEM_REQ_LANES*`REQ_ID_W-1:0] mem_resp_id_w;
wire [`MEM_REQ_LANES-1:0] mem_resp_last_w;

// request_controller → multicast_network wires
wire [`MEM_REQ_LANES-1:0] rc_resp_out_valid_w;
wire [`MEM_REQ_LANES-1:0] rc_resp_out_ready_w;
wire [`MEM_REQ_LANES*`SRAM_RDATA_W-1:0] rc_resp_out_rdata_w;
wire [`MEM_REQ_LANES*`REQ_ID_W-1:0] rc_resp_out_req_id_w;
wire [`MEM_REQ_LANES*`PE_MASK_W-1:0] rc_resp_out_pe_mask_w;
wire [`MEM_REQ_LANES-1:0] rc_resp_out_last_w;

// multicast_network → PE outputs (directly to layer_ctrl)
wire [`PE_MASK_W-1:0] mc_pe_valid_w;
wire [`PE_MASK_W-1:0] mc_pe_ready_w;
wire [`PE_MASK_W*`SRAM_RDATA_W-1:0] mc_pe_rdata_w;
wire [`PE_MASK_W*`REQ_ID_W-1:0] mc_pe_req_id_w;
wire [`PE_MASK_W*`PE_MASK_W-1:0] mc_pe_mask_w;
wire [`PE_MASK_W-1:0] mc_pe_last_w;
assign lc_mc_resp_valid = mc_pe_valid_w;
assign lc_mc_resp_rdata = mc_pe_rdata_w;
assign lc_mc_resp_req_id = mc_pe_req_id_w;
assign lc_mc_resp_last = mc_pe_last_w;
assign mc_pe_ready_w = lc_mc_resp_ready;

// Scalar write path: mux preload / compute_write into req_in
// Priority: preload > compute_write
wire rc_req_in_valid = sram_preload_valid || lc_sram_wr_valid;
wire rc_req_in_write = 1'b1;  // req_in is always write now (reads go via vec_req)
wire [`SRAM_ADDR_W-1:0] rc_req_in_addr =
    sram_preload_valid ? sram_preload_addr : lc_sram_wr_addr;
wire [`SRAM_WDATA_W-1:0] rc_req_in_wdata =
    sram_preload_valid ? sram_preload_data : lc_sram_wr_data;
wire [`BANK_ID_W-1:0] rc_req_in_bank_id =
    sram_preload_valid ?
        sram_preload_addr[`OFFSET_W + `ROW_ADDR_W + `SUBBANK_ID_W +: `BANK_ID_W] :
        rc_wr_bank_id;
wire [`SUBBANK_ID_W-1:0] rc_req_in_subbank_id =
    sram_preload_valid ?
        sram_preload_addr[`OFFSET_W + `ROW_ADDR_W +: `SUBBANK_ID_W] :
        rc_wr_subbank_id;
wire rc_req_in_ready;

assign lc_sram_wr_ready = rc_req_in_ready && !sram_preload_valid;

request_controller u_req_ctrl (
    .clk(clk),
    .rst_n(rst_n),
    // Scalar input (writes only: preload + KV commit)
    .req_in_valid(rc_req_in_valid),
    .req_in_ready(rc_req_in_ready),
    .req_in_write(rc_req_in_write),
    .req_in_addr(rc_req_in_addr),
    .req_in_wdata(rc_req_in_wdata),
    .req_in_req_id({`REQ_ID_W{1'b0}}),
    .req_in_pe_mask({`PE_MASK_W{1'b0}}),
    .req_in_priority(2'b00),
    .req_in_bank_id(rc_req_in_bank_id),
    .req_in_subbank_id(rc_req_in_subbank_id),
    // Vector input from layer_ctrl (reads + broadcast)
    .vec_req_valid(lc_vec_req_valid),
    .vec_req_ready(lc_vec_req_ready),
    .vec_req_write(lc_vec_req_write),
    .vec_req_addr(lc_vec_req_addr),
    .vec_req_wdata(lc_vec_req_wdata),
    .vec_req_req_id(lc_vec_req_req_id),
    .vec_req_pe_mask(lc_vec_req_pe_mask),
    .vec_req_priority(lc_vec_req_priority),
    .vec_req_bank_id(lc_vec_req_bank_id),
    .vec_req_subbank_id(lc_vec_req_subbank_id),
    // To sram_subsystem
    .mem_req_valid(mem_req_valid_w),
    .mem_req_ready(mem_req_ready_w),
    .mem_req_write(mem_req_write_w),
    .mem_req_addr(mem_req_addr_w),
    .mem_req_wdata(mem_req_wdata_w),
    .mem_req_id(mem_req_id_w),
    .mem_resp_valid(mem_resp_valid_w),
    .mem_resp_rdata(mem_resp_rdata_w),
    .mem_resp_id(mem_resp_id_w),
    .mem_resp_last(mem_resp_last_w),
    // To multicast_network
    .resp_out_valid(rc_resp_out_valid_w),
    .resp_out_ready(rc_resp_out_ready_w),
    .resp_out_rdata(rc_resp_out_rdata_w),
    .resp_out_req_id(rc_resp_out_req_id_w),
    .resp_out_pe_mask(rc_resp_out_pe_mask_w),
    .resp_out_last(rc_resp_out_last_w)
);

// =========================================================================
// Behavioral SRAM model (sram_subsystem has VCS unpacked-array issue)
// Single flat array, 1-cycle read latency, always ready
// Depth sized for qwen3: weight_base(280000) + 2 layers * 3145984 = ~6.6M
// =========================================================================
localparam BEHAV_SRAM_DEPTH = 131072;  // 128K entries (enough for toy profile)
reg [`SRAM_RDATA_W-1:0] behav_sram [0:BEHAV_SRAM_DEPTH-1];
assign mem_req_ready_w = {`MEM_REQ_LANES{1'b1}};
reg [`MEM_REQ_LANES-1:0]                  behav_resp_valid_r;
reg [`MEM_REQ_LANES*`SRAM_RDATA_W-1:0]   behav_resp_rdata_r;
reg [`MEM_REQ_LANES*`REQ_ID_W-1:0]       behav_resp_id_r;
reg [`MEM_REQ_LANES-1:0]                  behav_resp_last_r;
assign mem_resp_valid_w = behav_resp_valid_r;
assign mem_resp_rdata_w = behav_resp_rdata_r;
assign mem_resp_id_w = behav_resp_id_r;
assign mem_resp_last_w = behav_resp_last_r;
integer sram_lane_i;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        behav_resp_valid_r <= {`MEM_REQ_LANES{1'b0}};
        behav_resp_rdata_r <= {(`MEM_REQ_LANES*`SRAM_RDATA_W){1'b0}};
        behav_resp_id_r <= {(`MEM_REQ_LANES*`REQ_ID_W){1'b0}};
        behav_resp_last_r <= {`MEM_REQ_LANES{1'b0}};
    end else begin
        behav_resp_valid_r <= {`MEM_REQ_LANES{1'b0}};
        for (sram_lane_i = 0; sram_lane_i < `MEM_REQ_LANES; sram_lane_i = sram_lane_i + 1) begin
            if (mem_req_valid_w[sram_lane_i]) begin
                if (mem_req_write_w[sram_lane_i])
                    behav_sram[mem_req_addr_w[sram_lane_i*`SRAM_ADDR_W +: `SRAM_ADDR_W]] <=
                        mem_req_wdata_w[sram_lane_i*`SRAM_WDATA_W +: `SRAM_WDATA_W];
                else begin
                    behav_resp_valid_r[sram_lane_i] <= 1'b1;
                    behav_resp_rdata_r[sram_lane_i*`SRAM_RDATA_W +: `SRAM_RDATA_W] <=
                        behav_sram[mem_req_addr_w[sram_lane_i*`SRAM_ADDR_W +: `SRAM_ADDR_W]];
                    behav_resp_id_r[sram_lane_i*`REQ_ID_W +: `REQ_ID_W] <=
                        mem_req_id_w[sram_lane_i*`REQ_ID_W +: `REQ_ID_W];
                    behav_resp_last_r[sram_lane_i] <= 1'b1;
                end
            end
        end
    end
end

multicast_network u_multicast (
    .resp_in_valid(rc_resp_out_valid_w),
    .resp_in_ready(rc_resp_out_ready_w),
    .resp_in_rdata(rc_resp_out_rdata_w),
    .resp_in_req_id(rc_resp_out_req_id_w),
    .resp_in_pe_mask(rc_resp_out_pe_mask_w),
    .resp_in_last(rc_resp_out_last_w),
    .pe_valid(mc_pe_valid_w),
    .pe_ready(mc_pe_ready_w),
    .pe_rdata(mc_pe_rdata_w),
    .pe_req_id(mc_pe_req_id_w),
    .pe_mask(mc_pe_mask_w),
    .pe_last(mc_pe_last_w)
);

// synthesis translate_off
reg [31:0] dbg_cycle_cnt;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) dbg_cycle_cnt <= 0;
    else dbg_cycle_cnt <= dbg_cycle_cnt + 1;
end
// Tree path debug: show key state transitions only
always @(posedge clk) begin
    if (tb_done)
        $display("[DBG c%0d] TREE: tree_builder done, branch_valid=%b seed_node=%0d",
            dbg_cycle_cnt, tb_branch_valid, seed_node_id_r);
    if (state_r == ST_VERIFY && tvd_batch_out_valid)
        $display("[DBG c%0d] VERIFY: batch count=%0d tokens[0]=%0d",
            dbg_cycle_cnt, tvd_batch_out_count,
            tvd_batch_out_token_ids[`TOKEN_ID_W-1:0]);
    if (state_r == ST_VERIFY && sched_all_done)
        $display("[DBG c%0d] VERIFY: sched_all_done", dbg_cycle_cnt);
    // Debug scheduler handshake
    if (state_r == ST_VERIFY && dbg_cycle_cnt[7:0] == 8'd0)
        $display("[DBG c%0d] VERIFY_POLL: tvd_valid=%b sched_ready=%b tvd_busy=%b",
            dbg_cycle_cnt, tvd_batch_out_valid, sched_batch_ready, tvd_busy);
    if (state_r == ST_VERIFY && lc_done)
        $display("[DBG c%0d] VERIFY: lc_done, sending fwd results", dbg_cycle_cnt);
    // Debug layer controller start and request_controller state
    if (lc_start)
        $display("[DBG c%0d] LC_START: slots=%b rc_state=%0d req_in_valid=%b",
            dbg_cycle_cnt, lc_slot_valid, u_req_ctrl.state_r, rc_req_in_valid);
    if (comparator_result_valid)
        $display("[DBG c%0d] COMPARATOR: accepted_count=%0d flush=%b all_correct=%b token[0]=%0d",
            dbg_cycle_cnt, comparator_accepted_count, comparator_flush_mask,
            comparator_all_correct, comparator_accepted_tokens[`TOKEN_ID_W-1:0]);
    // Debug HHT state entering ST_BUILD
    if (state_r == ST_PREDICT)
        $display("[DBG c%0d] PREDICT: seed_node=%0d hht_cand_valid=%b cand_parent=%0d cand_token=%0d",
            dbg_cycle_cnt, seed_node_id_r, hht_cand_valid, hht_cand_parent_node_id, hht_cand_token_id);
    // Debug feedback accept
    if (fb_hht_accept_valid)
        $display("[DBG c%0d] FB_ACCEPT: token=%0d parent=%0d",
            dbg_cycle_cnt, fb_hht_accept_token_id, fb_hht_accept_parent_node_id);
    if (fb_new_seed_valid)
        $display("[DBG c%0d] FB_NEW_SEED: node=%0d token=%0d",
            dbg_cycle_cnt, fb_new_seed_node_id, fb_new_seed_token_id);
end
// synthesis translate_on

// =========================================================================
// Prefill logic
// =========================================================================
logic prefill_done_w;
assign prefill_done_w = lc_done && (state_r == ST_PREFILL);

// Connect batch forward results from layer controller to dispatcher
// When dispatcher sends batch, we route it to kv_share_scheduler
// IMPORTANT: ready must gate on valid (valid-before-ready protocol).
// The dispatcher clears batch_out_valid in the same cycle if ready is pre-asserted.
assign tvd_batch_out_ready = tvd_batch_out_valid && sched_batch_ready && (state_r == ST_VERIFY);
assign sched_batch_valid = tvd_batch_out_valid && (state_r == ST_VERIFY);

// =========================================================================
// Main state machine
// =========================================================================
assign tb_start = (state_r == ST_BUILD) && !tb_busy && !tb_done;
assign tb_hht_done = (state_r != ST_BUILD);

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
        fsm_lc_start <= 1'b0;
        fsm_lc_slot_valid <= '0;
        fsm_lc_slot_token_id <= '0;
        fsm_lc_slot_position_id <= '0;
        fsm_lc_tree_mask <= '0;
        tvd_fwd_result_valid <= 1'b0;
        tvd_fwd_result_count <= 5'd0;
        tvd_fwd_result_token_ids <= '0;
    end else begin
        done <= 1'b0;
        token_out_valid <= 1'b0;
        fsm_lc_start <= 1'b0;
        tvd_fwd_result_valid <= 1'b0;

        // Forward feedback tokens to output
        if (fb_out_token_valid) begin
            token_out_valid <= 1'b1;
            token_out_id <= fb_out_token_id;
            gen_count_r <= gen_count_r + 8'd1;
        end

        case (state_r)
        ST_IDLE: begin
            if (start) begin
                state_r <= ST_PREFILL;
                busy <= 1'b1;
                max_gen_r <= max_gen_tokens;
                gen_count_r <= 8'd0;
                seed_token_id_r <= prompt_token_id;
                seed_node_id_r <= '0;
                seed_position_r <= '0;
                committed_prefix_len_r <= 16'd0;
                // Start prefill: run prompt through transformer
                fsm_lc_start <= 1'b1;
                fsm_lc_slot_valid <= {{(`TREE_FRONTIER_SLOTS-1){1'b0}}, 1'b1};
                fsm_lc_slot_token_id <= {{((`TREE_FRONTIER_SLOTS-1)*`TOKEN_ID_W){1'b0}},
                                     prompt_token_id};
                fsm_lc_slot_position_id <= '0;
                fsm_lc_tree_mask <= '0; // causal mode for prefill
            end
        end

        ST_PREFILL: begin
            if (lc_done) begin
                // Prefill complete, first output token ready
                seed_token_id_r <= lc_out_token_id[`TOKEN_ID_W-1:0];
                seed_position_r <= {{(`POSITION_ID_W-1){1'b0}}, 1'b1};
                seed_node_id_r <= {{(`NODE_ID_W-1){1'b0}}, 1'b1};
                committed_prefix_len_r <= 16'd1;
                token_out_valid <= 1'b1;
                token_out_id <= lc_out_token_id[`TOKEN_ID_W-1:0];
                gen_count_r <= 8'd1;
                state_r <= ST_PREDICT;
            end
        end

        ST_PREDICT: begin
            // Let HHT generate predictions for a few cycles
            // Then start tree building
            state_r <= ST_BUILD;
        end

        ST_BUILD: begin
            if (tb_done) begin
                if (|tb_branch_valid) begin
                    state_r <= ST_VERIFY;
                end else begin
                    // No tree built: fallback single-token generation
                    // Run transformer on seed token to get next token
                    fsm_lc_start <= 1'b1;
                    fsm_lc_slot_valid <= {{(`TREE_FRONTIER_SLOTS-1){1'b0}}, 1'b1};
                    fsm_lc_slot_token_id <= {{((`TREE_FRONTIER_SLOTS-1)*`TOKEN_ID_W){1'b0}},
                                         seed_token_id_r};
                    fsm_lc_slot_position_id <= {{((`TREE_FRONTIER_SLOTS-1)*`POSITION_ID_W){1'b0}},
                                            seed_position_r};
                    fsm_lc_tree_mask <= '0; // causal mode for fallback
                    state_r <= ST_FALLBACK;
                end
            end
        end

        ST_VERIFY: begin
            // kv_share_scheduler handles the batch → LC interaction.
            // We just wait for scheduler to finish all branches, then
            // the comparator fires (triggered by sched_all_done).

            // Forward scheduler results to dispatcher (for commit logic)
            if (sched_all_done) begin
                tvd_fwd_result_valid <= 1'b1;
                tvd_fwd_result_count <= tvd_batch_out_count;
                // Pack branch results into fwd_result_token_ids
                // Map branch tips back to their slot positions
                begin : pack_sched_results
                    integer vi;
                    for (vi = 0; vi < WINDOW_SIZE; vi = vi + 1) begin
                        tvd_fwd_result_token_ids[vi*32 +: 32] <=
                            {{(32-`TOKEN_ID_W){1'b0}},
                             lc_out_token_id[vi*`TOKEN_ID_W +: `TOKEN_ID_W]};
                    end
                end
            end

            // Wait for commit from dispatcher
            if (tvd_commit_valid) begin
                state_r <= ST_FEEDBACK;
            end
        end

        ST_FEEDBACK: begin
            // Latch new seed when feedback emits it (fires 1 cycle before fb_done)
            if (fb_new_seed_valid) begin
                seed_node_id_r <= fb_new_seed_node_id;
                seed_token_id_r <= fb_new_seed_token_id;
                seed_position_r <= fb_new_seed_position;
                committed_prefix_len_r <= committed_prefix_len_r +
                    {13'd0, tvd_commit_depth} + 16'd1;
            end
            if (fb_done) begin
                state_r <= ST_CHECK;
            end
        end

        ST_CHECK: begin
            if (gen_count_r >= max_gen_r) begin
                state_r <= ST_DONE;
            end else begin
                state_r <= ST_PREDICT;
            end
        end

        ST_FALLBACK: begin
            // Wait for single-token transformer inference to complete
            if (lc_done) begin
                // Emit the output token
                token_out_valid <= 1'b1;
                token_out_id <= lc_out_token_id[`TOKEN_ID_W-1:0];
                gen_count_r <= gen_count_r + 8'd1;
                // Update seed for next round
                seed_token_id_r <= lc_out_token_id[`TOKEN_ID_W-1:0];
                seed_position_r <= seed_position_r +
                    {{(`POSITION_ID_W-1){1'b0}}, 1'b1};
                state_r <= ST_CHECK;
            end
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
