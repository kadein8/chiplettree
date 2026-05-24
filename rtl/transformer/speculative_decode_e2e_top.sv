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

    // SRAM interface
    output logic                          sram_rd_valid,
    input  logic                          sram_rd_ready,
    output logic [`SRAM_ADDR_W-1:0]       sram_rd_addr,
    input  logic                          sram_resp_valid,
    input  logic [`SRAM_RDATA_W-1:0]      sram_resp_data,
    output logic                          sram_wr_valid,
    input  logic                          sram_wr_ready,
    output logic [`SRAM_ADDR_W-1:0]       sram_wr_addr,
    output logic [`SRAM_WDATA_W-1:0]      sram_wr_data,

    // HBM interface
    output logic                          hbm_rd_valid,
    input  logic                          hbm_rd_ready,
    output logic [`HBM_ADDR_W-1:0]        hbm_rd_addr,
    input  logic                          hbm_resp_valid,
    input  logic [`HBM_DATA_W-1:0]        hbm_resp_data
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
    ST_DONE     = 4'd8;

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

HHTContextPredictor #(
    .CONF_W(8),
    .HISTORY_LEN(2),
    .SET_NUM(2),
    .WAY_NUM(2)
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
    .cand_confidence(hht_cand_confidence)
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
    .TIMEOUT_CYCLES(32)
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

// Forward declarations for signals used before their module instantiation
logic lc_done;

// HHT accept mux: from feedback controller or from prefill/startup
// Feed HHT during prefill completion AND during ST_PREDICT (to warm up history)
assign hht_accept_valid = fb_hht_accept_valid ||
    (state_r == ST_PREFILL && lc_done) ||
    (state_r == ST_IDLE && start);
assign hht_accept_parent_node_id = fb_hht_accept_valid ?
    fb_hht_accept_parent_node_id : seed_node_id_r;
assign hht_accept_token_id = fb_hht_accept_valid ?
    fb_hht_accept_token_id : (start ? prompt_token_id : seed_token_id_r);
assign hht_accept_position = fb_hht_accept_valid ?
    fb_hht_accept_position : seed_position_r;

// =========================================================================
// Layer Controller (transformer compute)
// =========================================================================
logic lc_start, lc_busy;
logic [`TREE_FRONTIER_SLOTS-1:0] lc_slot_valid;
logic [`TREE_FRONTIER_SLOTS*`TOKEN_ID_W-1:0] lc_slot_token_id;
logic [`TREE_FRONTIER_SLOTS*`POSITION_ID_W-1:0] lc_slot_position_id;
logic [`TREE_FRONTIER_SLOTS-1:0] lc_out_token_valid;
logic [`TREE_FRONTIER_SLOTS*`TOKEN_ID_W-1:0] lc_out_token_id;

PeArrayLayerController u_layer_ctrl (
    .clk(clk),
    .rst_n(rst_n),
    .start(lc_start),
    .done(lc_done),
    .busy(lc_busy),
    .slot_valid(lc_slot_valid),
    .slot_token_id(lc_slot_token_id),
    .slot_position_id(lc_slot_position_id),
    .embedding_base_addr(`MODEL_EMB_BASE),
    .hidden0_base_addr(`MODEL_WORK_HIDDEN0_BASE),
    .hidden1_base_addr(`MODEL_WORK_HIDDEN1_BASE),
    .final_base_addr(`MODEL_WORK_FINAL_BASE),
    .weight_sram_base_addr(`MODEL_WEIGHT_SRAM_BASE),
    .kv_cache_base_addr(`KV_DRAFT_BASE_MIN),
    .final_norm_gamma_addr(`MODEL_FINAL_NORM_GAMMA_ADDR),
    .lm_head_weight_base_addr(`MODEL_LM_HEAD_WEIGHT_BASE),
    .hbm_weight_base_addr(`MODEL_HBM_WEIGHT_BASE),
    .sram_rd_valid(sram_rd_valid),
    .sram_rd_ready(sram_rd_ready),
    .sram_rd_addr(sram_rd_addr),
    .sram_resp_valid(sram_resp_valid),
    .sram_resp_data(sram_resp_data),
    .sram_wr_valid(sram_wr_valid),
    .sram_wr_ready(sram_wr_ready),
    .sram_wr_addr(sram_wr_addr),
    .sram_wr_data(sram_wr_data),
    .hbm_rd_valid(hbm_rd_valid),
    .hbm_rd_ready(hbm_rd_ready),
    .hbm_rd_addr(hbm_rd_addr),
    .hbm_resp_valid(hbm_resp_valid),
    .hbm_resp_data(hbm_resp_data),
    .out_token_valid(lc_out_token_valid),
    .out_token_id(lc_out_token_id)
);

// =========================================================================
// Prefill logic
// =========================================================================
logic prefill_done_w;
assign prefill_done_w = lc_done && (state_r == ST_PREFILL);

// Connect batch forward results from layer controller to dispatcher
// When dispatcher sends batch, we run layer controller and return results
assign tvd_batch_out_ready = (state_r == ST_VERIFY) && !lc_busy;

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
        lc_start <= 1'b0;
        lc_slot_valid <= '0;
        lc_slot_token_id <= '0;
        lc_slot_position_id <= '0;
        tvd_fwd_result_valid <= 1'b0;
        tvd_fwd_result_count <= 5'd0;
        tvd_fwd_result_token_ids <= '0;
    end else begin
        done <= 1'b0;
        token_out_valid <= 1'b0;
        lc_start <= 1'b0;
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
                lc_start <= 1'b1;
                lc_slot_valid <= {{(`TREE_FRONTIER_SLOTS-1){1'b0}}, 1'b1};
                lc_slot_token_id <= {{((`TREE_FRONTIER_SLOTS-1)*`TOKEN_ID_W){1'b0}},
                                     prompt_token_id};
                lc_slot_position_id <= '0;
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
                    // Emit current seed as output and advance
                    token_out_valid <= 1'b1;
                    token_out_id <= seed_token_id_r;
                    gen_count_r <= gen_count_r + 8'd1;
                    seed_position_r <= seed_position_r +
                        {{(`POSITION_ID_W-1){1'b0}}, 1'b1};
                    state_r <= ST_CHECK;
                end
            end
        end

        ST_VERIFY: begin
            // Wait for dispatcher to send batch, then run transformer
            if (tvd_batch_out_valid && !lc_busy) begin
                // Start layer controller with batch tokens
                lc_start <= 1'b1;
                lc_slot_valid <= {`TREE_FRONTIER_SLOTS{1'b1}};
                // Map batch tokens to slot inputs (simplified)
                lc_slot_token_id <= tvd_batch_out_token_ids[`TREE_FRONTIER_SLOTS*`TOKEN_ID_W-1:0];
                lc_slot_position_id <=
                    tvd_batch_out_positions[`TREE_FRONTIER_SLOTS*`POSITION_ID_W-1:0];
            end

            // When layer controller finishes, send results back to dispatcher
            if (lc_done) begin
                tvd_fwd_result_valid <= 1'b1;
                tvd_fwd_result_count <= tvd_batch_out_count;
                tvd_fwd_result_token_ids <= {(WINDOW_SIZE*32){1'b0}};
                // Fill in argmax results from layer controller
                tvd_fwd_result_token_ids[`TOKEN_ID_W-1:0] <=
                    lc_out_token_id[`TOKEN_ID_W-1:0];
            end

            // Wait for commit
            if (tvd_commit_valid) begin
                state_r <= ST_FEEDBACK;
            end
        end

        ST_FEEDBACK: begin
            if (fb_done) begin
                // Update seed from feedback
                if (fb_new_seed_valid) begin
                    seed_node_id_r <= fb_new_seed_node_id;
                    seed_token_id_r <= fb_new_seed_token_id;
                    seed_position_r <= fb_new_seed_position;
                    committed_prefix_len_r <= committed_prefix_len_r +
                        {13'd0, tvd_commit_depth} + 16'd1;
                end
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
