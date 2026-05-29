`timescale 1ns/1ps
`include "config/interface_params.vh"
`include "config/prediction_params.vh"
`include "config/model_params.vh"
`include "config/memory_params.vh"

// kv_share_scheduler
//
// Analyzes the 17-slot verify batch from tree_verify_dispatcher and schedules
// computation with KV cache sharing:
//
// Phase 1 (PREFILL): Compute shared prefix tokens serially (KV written to cache).
//   - Committed prefix KV is already in cache (skip).
//   - Shared injected tokens (e.g., C1 shared by branch 1 and 2) computed once.
//
// Phase 2 (DECODE): Decode branch tip tokens in parallel (4 branches).
//   - Each branch tip uses cached KV from prefix + shared tokens.
//   - Only the tip token needs full forward + argmax.
//
// This reduces 17 independent forward passes to ~5 steps:
//   1 shared prefill (if any new shared tokens) + 4 parallel decodes.
//
// Interface: sits between tree_verify_dispatcher and PeArrayLayerController.
// Drives the layer controller multiple times (once per phase step).

module kv_share_scheduler #(
    parameter integer BRANCH_NUM  = `BRANCH_NUM,
    parameter integer MAX_DEPTH   = `MAX_PRIVATE_NODES_PER_BRANCH,
    parameter integer WINDOW_SIZE = `VERIFY_WINDOW_SIZE
) (
    input                              clk,
    input                              rst_n,

    // --- Input from tree_verify_dispatcher ---
    input                              batch_valid,
    output reg                         batch_ready,
    input  [4:0]                       batch_count,
    input  [WINDOW_SIZE*32-1:0]        batch_token_ids,
    input  [WINDOW_SIZE*16-1:0]        batch_positions,
    input  [WINDOW_SIZE*WINDOW_SIZE-1:0] batch_tree_mask,
    input  [15:0]                      batch_prefix_len,
    input  [WINDOW_SIZE-1:0]           batch_slot_is_seed,

    // --- Output to PeArrayLayerController (single-slot issue) ---
    output reg                         lc_start,
    input                              lc_done,
    input                              lc_busy,
    output reg [`TREE_FRONTIER_SLOTS-1:0] lc_slot_valid,
    output reg [`TREE_FRONTIER_SLOTS*`TOKEN_ID_W-1:0] lc_slot_token_id,
    output reg [`TREE_FRONTIER_SLOTS*`POSITION_ID_W-1:0] lc_slot_position_id,
    output reg [`TREE_FRONTIER_SLOTS*`TREE_FRONTIER_SLOTS-1:0] lc_tree_mask,

    // --- Output: per-branch generated token (after all phases complete) ---
    output reg                         all_done,
    output reg [BRANCH_NUM-1:0]        branch_valid_out,
    output reg [BRANCH_NUM*`TOKEN_ID_W-1:0] branch_generated_token,

    // --- Layer controller output token capture ---
    input  [`TREE_FRONTIER_SLOTS-1:0]  lc_out_token_valid,
    input  [`TREE_FRONTIER_SLOTS*`TOKEN_ID_W-1:0] lc_out_token_id
);

// =========================================================================
// Internal state
// =========================================================================
localparam [2:0]
    ST_IDLE     = 3'd0,
    ST_ANALYZE  = 3'd1,
    ST_PREFILL  = 3'd2,
    ST_DECODE   = 3'd3,
    ST_WAIT_LC  = 3'd4,
    ST_COLLECT  = 3'd5,
    ST_DONE     = 3'd6;

reg [2:0] state_r;

// Latched batch
reg [4:0]  batch_count_r;
reg [31:0] slot_token_r  [0:WINDOW_SIZE-1];
reg [15:0] slot_pos_r    [0:WINDOW_SIZE-1];
reg [WINDOW_SIZE-1:0] slot_mask_r [0:WINDOW_SIZE-1]; // tree_mask row per slot
reg [WINDOW_SIZE-1:0] slot_is_seed_r;
reg [15:0] prefix_len_r;

// Analysis results
// shared_slots: slots visible to ALL active branches (shared prefix/injected)
// tip_slots: the last slot of each branch (needs argmax)
reg [WINDOW_SIZE-1:0] shared_slot_mask_r;
reg [4:0] tip_slot_idx_r [0:BRANCH_NUM-1]; // slot index of each branch tip
reg [BRANCH_NUM-1:0]  branch_active_r;

// Phase tracking
reg [4:0] prefill_idx_r;     // current shared slot being prefilled
reg [4:0] prefill_count_r;   // total shared slots to prefill
reg [4:0] shared_order_r [0:WINDOW_SIZE-1]; // ordered list of shared slots
reg [1:0] decode_branch_r;   // current branch being decoded (for serial fallback)
reg       decode_parallel_r; // 1 = issue all 4 tips at once

// KV position counter (tracks how many tokens are in KV cache)
reg [15:0] kv_len_r;

integer si, bi2;
integer si2, bi3;  // separate loop vars for combinational block

// =========================================================================
// Batch latch
// =========================================================================
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        batch_count_r <= 5'd0;
        slot_is_seed_r <= {WINDOW_SIZE{1'b0}};
        prefix_len_r <= 16'd0;
        for (si = 0; si < WINDOW_SIZE; si = si + 1) begin
            slot_token_r[si] <= 32'd0;
            slot_pos_r[si] <= 16'd0;
            slot_mask_r[si] <= {WINDOW_SIZE{1'b0}};
        end
    end else if (batch_valid && batch_ready) begin
        batch_count_r <= batch_count;
        slot_is_seed_r <= batch_slot_is_seed;
        prefix_len_r <= batch_prefix_len;
        for (si = 0; si < WINDOW_SIZE; si = si + 1) begin
            slot_token_r[si] <= batch_token_ids[si*32 +: 32];
            slot_pos_r[si] <= batch_positions[si*16 +: 16];
            slot_mask_r[si] <= batch_tree_mask[si*WINDOW_SIZE +: WINDOW_SIZE];
        end
    end
end

// =========================================================================
// Tree analysis: identify shared slots vs branch tips
// =========================================================================
// Strategy: A slot is a "branch tip" if no other slot's mask includes it as
// a non-tip dependency AND it's the deepest slot in its branch.
// Simpler heuristic for the dispatcher's layout:
//   - Slot 0 = seed (already in KV cache, skip prefill)
//   - Slots 1..prefix_len-1 = committed prefix (already in KV, skip)
//   - Remaining slots: group by branch. The last valid slot per branch = tip.
//   - Non-tip, non-prefix slots = shared injected tokens (need prefill)
//
// The dispatcher layout (VERIFY_WINDOW_SIZE=17, 4 branches, max_depth=4):
//   slot 0: seed
//   slots 1..4: branch 0 (depth 0..3), tip = last valid
//   slots 5..8: branch 1 (depth 0..3), tip = last valid
//   slots 9..12: branch 2 (depth 0..3), tip = last valid
//   slots 13..16: branch 3 (depth 0..3), tip = last valid
//
// Branch tip = the slot that produces the "generated next token" for comparison.
// All other slots in a branch are prefill (their KV is needed by the tip).
// Shared slots across branches: if branch 1 slot[5] has same token+position as
// branch 2 slot[9], they share KV (compute once).

localparam integer SLOTS_PER_BRANCH = MAX_DEPTH;  // 4
localparam integer BRANCH_BASE_SLOT = 1;          // slot 1 is start of branch 0

reg [4:0] branch_tip_found;
reg [4:0] branch_slot_start;
reg [4:0] branch_slot_end;
reg [WINDOW_SIZE-1:0] tip_mask_c;
reg [WINDOW_SIZE-1:0] prefill_mask_c;
reg [4:0] prefill_order_c [0:WINDOW_SIZE-1];
reg [4:0] prefill_cnt_c;
reg       is_duplicate;  // temp flag for dedup check
integer   dk;            // dedup inner loop var

// Separate variable for sequential block to avoid multi-driver
reg [4:0] seq_branch_slot_start;

always @(*) begin
    tip_mask_c = {WINDOW_SIZE{1'b0}};
    prefill_mask_c = {WINDOW_SIZE{1'b0}};
    prefill_cnt_c = 5'd0;
    for (si2 = 0; si2 < WINDOW_SIZE; si2 = si2 + 1)
        prefill_order_c[si2] = 5'd0;

    // Find tip of each branch (last valid slot in branch's range)
    for (bi3 = 0; bi3 < BRANCH_NUM; bi3 = bi3 + 1) begin
        branch_slot_start = BRANCH_BASE_SLOT[4:0] + bi3[4:0] * SLOTS_PER_BRANCH[4:0];
        branch_slot_end = branch_slot_start + SLOTS_PER_BRANCH[4:0] - 5'd1;
        branch_tip_found = 5'd31; // invalid

        // Scan from deepest to shallowest to find last valid
        for (si2 = 0; si2 < SLOTS_PER_BRANCH; si2 = si2 + 1) begin
            if ((branch_slot_start + si2[4:0]) < batch_count_r) begin
                branch_tip_found = branch_slot_start + si2[4:0];
            end
        end

        if (branch_tip_found != 5'd31) begin
            tip_mask_c[branch_tip_found] = 1'b1;
        end
    end

    // Non-tip, non-seed slots need prefill — with cross-branch deduplication.
    // A slot is a duplicate if an earlier slot (lower index) has the same
    // token_id and position. Only the first occurrence gets prefilled.
    for (si2 = 0; si2 < WINDOW_SIZE; si2 = si2 + 1) begin
        if (si2 > 0 && si2 < batch_count_r && !tip_mask_c[si2] && !slot_is_seed_r[si2]) begin
            // Check if this slot duplicates an earlier non-tip slot
            is_duplicate = 1'b0;
            for (dk = 1; dk < WINDOW_SIZE; dk = dk + 1) begin
                if (dk < si2 && dk < batch_count_r &&
                    !tip_mask_c[dk] && !slot_is_seed_r[dk] &&
                    slot_token_r[dk][`TOKEN_ID_W-1:0] == slot_token_r[si2][`TOKEN_ID_W-1:0] &&
                    slot_pos_r[dk][`POSITION_ID_W-1:0] == slot_pos_r[si2][`POSITION_ID_W-1:0]) begin
                    is_duplicate = 1'b1;
                end
            end
            if (!is_duplicate) begin
                prefill_mask_c[si2] = 1'b1;
                prefill_order_c[prefill_cnt_c] = si2[4:0];
                prefill_cnt_c = prefill_cnt_c + 5'd1;
            end
        end
    end
end

// =========================================================================
// Main FSM
// =========================================================================
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state_r <= ST_IDLE;
        batch_ready <= 1'b1;
        lc_start <= 1'b0;
        lc_slot_valid <= {`TREE_FRONTIER_SLOTS{1'b0}};
        lc_slot_token_id <= {(`TREE_FRONTIER_SLOTS*`TOKEN_ID_W){1'b0}};
        lc_slot_position_id <= {(`TREE_FRONTIER_SLOTS*`POSITION_ID_W){1'b0}};
        lc_tree_mask <= {(`TREE_FRONTIER_SLOTS*`TREE_FRONTIER_SLOTS){1'b0}};
        all_done <= 1'b0;
        branch_valid_out <= {BRANCH_NUM{1'b0}};
        branch_generated_token <= {(BRANCH_NUM*`TOKEN_ID_W){1'b0}};
        shared_slot_mask_r <= {WINDOW_SIZE{1'b0}};
        branch_active_r <= {BRANCH_NUM{1'b0}};
        prefill_idx_r <= 5'd0;
        prefill_count_r <= 5'd0;
        decode_branch_r <= 2'd0;
        decode_parallel_r <= 1'b0;
        kv_len_r <= 16'd0;
        for (si = 0; si < WINDOW_SIZE; si = si + 1)
            shared_order_r[si] <= 5'd0;
        for (bi2 = 0; bi2 < BRANCH_NUM; bi2 = bi2 + 1)
            tip_slot_idx_r[bi2] <= 5'd0;
    end else begin
        lc_start <= 1'b0;
        all_done <= 1'b0;

        case (state_r)
        // -----------------------------------------------------------------
        ST_IDLE: begin
            batch_ready <= 1'b1;
            if (batch_valid && batch_ready) begin
                batch_ready <= 1'b0;
                state_r <= ST_ANALYZE;
                // synthesis translate_off
                $display("[KV_SCHED] batch received: count=%0d prefix_len=%0d",
                    batch_count, batch_prefix_len);
                // synthesis translate_on
            end
        end

        // -----------------------------------------------------------------
        ST_ANALYZE: begin
            // Latch analysis results
            shared_slot_mask_r <= prefill_mask_c;
            prefill_count_r <= prefill_cnt_c;
            prefill_idx_r <= 5'd0;
            for (si = 0; si < WINDOW_SIZE; si = si + 1)
                shared_order_r[si] <= prefill_order_c[si];

            // Find branch tips
            for (bi2 = 0; bi2 < BRANCH_NUM; bi2 = bi2 + 1) begin
                seq_branch_slot_start = BRANCH_BASE_SLOT[4:0] + bi2[4:0] * SLOTS_PER_BRANCH[4:0];
                tip_slot_idx_r[bi2] <= 5'd31;
                for (si = 0; si < SLOTS_PER_BRANCH; si = si + 1) begin
                    if ((seq_branch_slot_start + si[4:0]) < batch_count_r)
                        tip_slot_idx_r[bi2] <= seq_branch_slot_start + si[4:0];
                end
                branch_active_r[bi2] <= (seq_branch_slot_start < batch_count_r) ? 1'b1 : 1'b0;
            end

            // KV cache starts with committed prefix already present
            kv_len_r <= prefix_len_r;

            if (prefill_cnt_c > 5'd0) begin
                state_r <= ST_PREFILL;
            end else begin
                state_r <= ST_DECODE;
                decode_branch_r <= 2'd0;
            end

            // synthesis translate_off
            $display("[KV_SCHED] analyze: prefill_count=%0d tip_mask=%b",
                prefill_cnt_c, tip_mask_c);
            // synthesis translate_on
        end

        // -----------------------------------------------------------------
        // PREFILL: issue shared tokens one at a time to build KV cache
        // -----------------------------------------------------------------
        ST_PREFILL: begin
            if (!lc_busy && !lc_start) begin
                // Issue next shared slot for prefill
                lc_start <= 1'b1;
                lc_slot_valid <= {{(`TREE_FRONTIER_SLOTS-1){1'b0}}, 1'b1};
                lc_slot_token_id <= {
                    {((`TREE_FRONTIER_SLOTS-1)*`TOKEN_ID_W){1'b0}},
                    slot_token_r[shared_order_r[prefill_idx_r]][`TOKEN_ID_W-1:0]
                };
                lc_slot_position_id <= {
                    {((`TREE_FRONTIER_SLOTS-1)*`POSITION_ID_W){1'b0}},
                    slot_pos_r[shared_order_r[prefill_idx_r]][`POSITION_ID_W-1:0]
                };
                // Prefill uses causal mask (sees all prior KV)
                lc_tree_mask <= {(`TREE_FRONTIER_SLOTS*`TREE_FRONTIER_SLOTS){1'b0}};

                // synthesis translate_off
                $display("[KV_SCHED] PREFILL[%0d/%0d]: slot=%0d token=%0d pos=%0d",
                    prefill_idx_r, prefill_count_r,
                    shared_order_r[prefill_idx_r],
                    slot_token_r[shared_order_r[prefill_idx_r]][`TOKEN_ID_W-1:0],
                    slot_pos_r[shared_order_r[prefill_idx_r]][`POSITION_ID_W-1:0]);
                // synthesis translate_on

                state_r <= ST_WAIT_LC;
            end
        end

        // -----------------------------------------------------------------
        // DECODE: issue ALL branch tips in parallel (single multi-slot LC call)
        // -----------------------------------------------------------------
        ST_DECODE: begin
            if (!lc_busy && !lc_start) begin
                // Pack all active branch tips into slots 0..BRANCH_NUM-1
                lc_start <= 1'b1;
                lc_slot_valid <= {`TREE_FRONTIER_SLOTS{1'b0}};
                lc_slot_token_id <= {(`TREE_FRONTIER_SLOTS*`TOKEN_ID_W){1'b0}};
                lc_slot_position_id <= {(`TREE_FRONTIER_SLOTS*`POSITION_ID_W){1'b0}};
                lc_tree_mask <= {(`TREE_FRONTIER_SLOTS*`TREE_FRONTIER_SLOTS){1'b0}};

                for (bi2 = 0; bi2 < BRANCH_NUM; bi2 = bi2 + 1) begin
                    if (branch_active_r[bi2] && tip_slot_idx_r[bi2] != 5'd31) begin
                        lc_slot_valid[bi2] <= 1'b1;
                        lc_slot_token_id[bi2*`TOKEN_ID_W +: `TOKEN_ID_W] <=
                            slot_token_r[tip_slot_idx_r[bi2]][`TOKEN_ID_W-1:0];
                        lc_slot_position_id[bi2*`POSITION_ID_W +: `POSITION_ID_W] <=
                            slot_pos_r[tip_slot_idx_r[bi2]][`POSITION_ID_W-1:0];
                    end
                end

                // synthesis translate_off
                $display("[KV_SCHED] DECODE PARALLEL: active=%b tips=[%0d,%0d,%0d,%0d]",
                    branch_active_r,
                    tip_slot_idx_r[0], tip_slot_idx_r[1],
                    tip_slot_idx_r[2], tip_slot_idx_r[3]);
                // synthesis translate_on

                decode_parallel_r <= 1'b1;
                state_r <= ST_WAIT_LC;
            end
        end

        // -----------------------------------------------------------------
        // WAIT_LC: wait for layer controller to finish current step
        // -----------------------------------------------------------------
        ST_WAIT_LC: begin
            if (lc_done) begin
                state_r <= ST_COLLECT;
            end
        end

        // -----------------------------------------------------------------
        // COLLECT: capture result and advance to next step
        // -----------------------------------------------------------------
        ST_COLLECT: begin
            if (shared_slot_mask_r != {WINDOW_SIZE{1'b0}} && prefill_idx_r < prefill_count_r - 5'd1) begin
                // More prefill slots remaining
                prefill_idx_r <= prefill_idx_r + 5'd1;
                kv_len_r <= kv_len_r + 16'd1;
                state_r <= ST_PREFILL;
            end else if (shared_slot_mask_r != {WINDOW_SIZE{1'b0}} && prefill_idx_r == prefill_count_r - 5'd1) begin
                // Last prefill done, move to decode
                prefill_idx_r <= prefill_idx_r + 5'd1;
                kv_len_r <= kv_len_r + 16'd1;
                shared_slot_mask_r <= {WINDOW_SIZE{1'b0}}; // clear to signal prefill done
                decode_branch_r <= 2'd0;
                decode_parallel_r <= 1'b0;
                state_r <= ST_DECODE;
                // synthesis translate_off
                $display("[KV_SCHED] PREFILL complete, starting DECODE");
                // synthesis translate_on
            end else begin
                // In decode phase (parallel): capture all branch results at once
                for (bi2 = 0; bi2 < BRANCH_NUM; bi2 = bi2 + 1) begin
                    if (branch_active_r[bi2] && tip_slot_idx_r[bi2] != 5'd31) begin
                        branch_generated_token[bi2*`TOKEN_ID_W +: `TOKEN_ID_W] <=
                            lc_out_token_id[bi2*`TOKEN_ID_W +: `TOKEN_ID_W];
                        branch_valid_out[bi2] <= 1'b1;
                    end
                end

                // synthesis translate_off
                $display("[KV_SCHED] DECODE PARALLEL result: gen[0]=%0d gen[1]=%0d gen[2]=%0d gen[3]=%0d",
                    lc_out_token_id[0*`TOKEN_ID_W +: `TOKEN_ID_W],
                    lc_out_token_id[1*`TOKEN_ID_W +: `TOKEN_ID_W],
                    lc_out_token_id[2*`TOKEN_ID_W +: `TOKEN_ID_W],
                    lc_out_token_id[3*`TOKEN_ID_W +: `TOKEN_ID_W]);
                // synthesis translate_on

                state_r <= ST_DONE;
            end
        end

        // -----------------------------------------------------------------
        // DONE: signal completion
        // -----------------------------------------------------------------
        ST_DONE: begin
            all_done <= 1'b1;
            batch_ready <= 1'b1;
            state_r <= ST_IDLE;
            // synthesis translate_off
            $display("[KV_SCHED] ALL DONE: branch_valid=%b gen[0]=%0d gen[1]=%0d gen[2]=%0d gen[3]=%0d",
                branch_valid_out,
                branch_generated_token[0*`TOKEN_ID_W +: `TOKEN_ID_W],
                branch_generated_token[1*`TOKEN_ID_W +: `TOKEN_ID_W],
                branch_generated_token[2*`TOKEN_ID_W +: `TOKEN_ID_W],
                branch_generated_token[3*`TOKEN_ID_W +: `TOKEN_ID_W]);
            // synthesis translate_on
        end
        default: state_r <= ST_IDLE;
        endcase
    end
end

endmodule
