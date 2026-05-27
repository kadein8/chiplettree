`timescale 1ns/1ps
`include "config/interface_params.vh"
`include "config/prediction_params.vh"
`include "config/model_params.vh"
`include "config/memory_params.vh"

// branch_parallel_scheduler
//
// Splits the verification tree into BRANCH_NUM independent branch tasks
// and launches them on BRANCH_NUM parallel LC instances simultaneously.
//
// Each branch does a standard causal transformer forward pass:
//   - Read committed prefix KV from SRAM (already present)
//   - Prefill draft tokens (compute KV, write to SRAM)
//   - Decode tip (generate next token via argmax)
//
// All branches run in parallel. Latency = deepest branch's forward pass.

module branch_parallel_scheduler #(
    parameter integer BRANCH_NUM = `BRANCH_NUM,
    parameter integer MAX_DEPTH  = `MAX_PRIVATE_NODES_PER_BRANCH,
    parameter integer TOKEN_ID_W = `TOKEN_ID_W,
    parameter integer POSITION_ID_W = `POSITION_ID_W,
    parameter integer NODE_ID_W  = `NODE_ID_W,
    // Max tokens per branch = 1 (seed/committed tip) + MAX_DEPTH (draft) + 1 (decode tip)
    // But LC slot count is TREE_FRONTIER_SLOTS; we use up to MAX_DEPTH+1 slots per branch
    parameter integer SLOTS_PER_BRANCH = MAX_DEPTH + 1,
    parameter integer LC_SLOTS = `TREE_FRONTIER_SLOTS
) (
    input                              clk,
    input                              rst_n,

    // --- Control ---
    input                              start,
    output reg                         all_done,

    // --- Tree structure from tree_builder ---
    input  [BRANCH_NUM-1:0]           branch_valid,
    input  [BRANCH_NUM*MAX_DEPTH*TOKEN_ID_W-1:0]    branch_draft_tokens,
    input  [BRANCH_NUM*MAX_DEPTH*POSITION_ID_W-1:0] branch_draft_positions,
    input  [BRANCH_NUM*MAX_DEPTH-1:0]               branch_levels_valid,
    input  [TOKEN_ID_W-1:0]           seed_token_id,
    input  [POSITION_ID_W-1:0]        seed_position,
    input  [15:0]                      committed_prefix_len,

    // --- To/From BRANCH_NUM LC instances ---
    // Start signals (active one cycle)
    output reg [BRANCH_NUM-1:0]       lc_start,
    input  [BRANCH_NUM-1:0]           lc_done,
    input  [BRANCH_NUM-1:0]           lc_busy,

    // Per-LC slot configuration (active when lc_start asserts)
    output reg [BRANCH_NUM*LC_SLOTS-1:0]                    lc_slot_valid,
    output reg [BRANCH_NUM*LC_SLOTS*TOKEN_ID_W-1:0]         lc_slot_token_id,
    output reg [BRANCH_NUM*LC_SLOTS*POSITION_ID_W-1:0]      lc_slot_position_id,
    output reg [BRANCH_NUM*LC_SLOTS*LC_SLOTS-1:0]           lc_tree_mask,

    // Per-LC argmax results
    input  [BRANCH_NUM*LC_SLOTS*TOKEN_ID_W-1:0]            lc_out_token_id,

    // --- Results ---
    output reg [BRANCH_NUM-1:0]       branch_result_valid,
    output reg [BRANCH_NUM*TOKEN_ID_W-1:0] branch_generated_token,
    // Also expose the draft tokens for comparator use
    output reg [BRANCH_NUM*MAX_DEPTH*TOKEN_ID_W-1:0] branch_draft_tokens_out
);

// =========================================================================
// FSM
// =========================================================================
localparam [1:0] ST_IDLE = 2'd0, ST_LAUNCH = 2'd1, ST_WAIT = 2'd2, ST_DONE = 2'd3;
reg [1:0] state_r;

// Track which branches are active and pending
reg [BRANCH_NUM-1:0] branch_active_r;
reg [BRANCH_NUM-1:0] branch_done_r;

integer bi, li;

// =========================================================================
// Main FSM
// =========================================================================
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state_r <= ST_IDLE;
        all_done <= 1'b0;
        lc_start <= {BRANCH_NUM{1'b0}};
        lc_slot_valid <= '0;
        lc_slot_token_id <= '0;
        lc_slot_position_id <= '0;
        lc_tree_mask <= '0;
        branch_result_valid <= {BRANCH_NUM{1'b0}};
        branch_generated_token <= '0;
        branch_draft_tokens_out <= '0;
        branch_active_r <= {BRANCH_NUM{1'b0}};
        branch_done_r <= {BRANCH_NUM{1'b0}};
    end else begin
        all_done <= 1'b0;
        lc_start <= {BRANCH_NUM{1'b0}};

        case (state_r)
        // -----------------------------------------------------------------
        ST_IDLE: begin
            if (start) begin
                state_r <= ST_LAUNCH;
                // Branch 0 is ALWAYS active (main verification path, no injection)
                branch_active_r <= branch_valid | {{(BRANCH_NUM-1){1'b0}}, 1'b1};
                branch_done_r <= {BRANCH_NUM{1'b0}};
                branch_result_valid <= {BRANCH_NUM{1'b0}};
                branch_generated_token <= '0;
                branch_draft_tokens_out <= branch_draft_tokens;
            end
        end

        // -----------------------------------------------------------------
        // LAUNCH: Configure and start all LC instances simultaneously
        // -----------------------------------------------------------------
        ST_LAUNCH: begin
            for (bi = 0; bi < BRANCH_NUM; bi = bi + 1) begin
                if (branch_active_r[bi]) begin
                    lc_start[bi] <= 1'b1;

                    // Pack this branch's tokens into LC slots:
                    // Slot 0 = seed (last committed token, for KV read)
                    // Slot 1..N = draft tokens (prefill + decode tip is last valid)
                    //
                    // For Branch b with depth D:
                    //   slot 0: seed_token @ seed_position (KV already in cache)
                    //   slot 1: draft[0] @ draft_pos[0]
                    //   ...
                    //   slot D: draft[D-1] @ draft_pos[D-1]  ← this is the tip
                    //
                    // The LC will process all slots as a standard causal sequence.
                    // Argmax output comes from the last valid slot.

                    // Slot 0 = seed
                    lc_slot_valid[bi*LC_SLOTS + 0] <= 1'b1;
                    lc_slot_token_id[(bi*LC_SLOTS + 0)*TOKEN_ID_W +: TOKEN_ID_W] <= seed_token_id;
                    lc_slot_position_id[(bi*LC_SLOTS + 0)*POSITION_ID_W +: POSITION_ID_W] <= seed_position;

                    // Slots 1..MAX_DEPTH = draft tokens
                    // IMPORTANT: Branch 0 is the main verification path — NO draft injection.
                    // It only has the seed token and generates the "ground truth" next token.
                    for (li = 0; li < MAX_DEPTH; li = li + 1) begin
                        if (bi != 0 && branch_levels_valid[bi*MAX_DEPTH + li]) begin
                            lc_slot_valid[bi*LC_SLOTS + 1 + li] <= 1'b1;
                            lc_slot_token_id[(bi*LC_SLOTS + 1 + li)*TOKEN_ID_W +: TOKEN_ID_W] <=
                                branch_draft_tokens[(bi*MAX_DEPTH + li)*TOKEN_ID_W +: TOKEN_ID_W];
                            lc_slot_position_id[(bi*LC_SLOTS + 1 + li)*POSITION_ID_W +: POSITION_ID_W] <=
                                branch_draft_positions[(bi*MAX_DEPTH + li)*POSITION_ID_W +: POSITION_ID_W];
                        end else begin
                            lc_slot_valid[bi*LC_SLOTS + 1 + li] <= 1'b0;
                        end
                    end

                    // Clear remaining slots
                    for (li = MAX_DEPTH + 1; li < LC_SLOTS; li = li + 1) begin
                        lc_slot_valid[bi*LC_SLOTS + li] <= 1'b0;
                    end

                    // Tree mask: set to all zeros (LC uses default causal attention)
                    // The LC internally handles causal masking based on slot positions.
                    for (li = 0; li < LC_SLOTS*LC_SLOTS; li = li + 1) begin
                        lc_tree_mask[bi*LC_SLOTS*LC_SLOTS + li] <= 1'b0;
                    end

                end else begin
                    // Inactive branch: clear everything
                    for (li = 0; li < LC_SLOTS; li = li + 1) begin
                        lc_slot_valid[bi*LC_SLOTS + li] <= 1'b0;
                    end
                    // Mark as already done
                    branch_done_r[bi] <= 1'b1;
                end
            end

            state_r <= ST_WAIT;
        end

        // -----------------------------------------------------------------
        // WAIT: Wait for all active LCs to complete
        // -----------------------------------------------------------------
        ST_WAIT: begin
            for (bi = 0; bi < BRANCH_NUM; bi = bi + 1) begin
                if (branch_active_r[bi] && lc_done[bi] && !branch_done_r[bi]) begin
                    branch_done_r[bi] <= 1'b1;
                    branch_result_valid[bi] <= 1'b1;

                    // Find the last valid slot's argmax output (= branch tip result)
                    // The tip is at slot index = 1 + (number of valid draft levels) - 1
                    // But since we don't store depth separately, scan for last valid
                    begin : find_tip_result
                        integer si;
                        reg [TOKEN_ID_W-1:0] tip_token;
                        tip_token = lc_out_token_id[bi*LC_SLOTS*TOKEN_ID_W +: TOKEN_ID_W]; // default slot 0
                        for (si = 0; si < LC_SLOTS; si = si + 1) begin
                            if (lc_slot_valid[bi*LC_SLOTS + si])
                                tip_token = lc_out_token_id[(bi*LC_SLOTS + si)*TOKEN_ID_W +: TOKEN_ID_W];
                        end
                        branch_generated_token[bi*TOKEN_ID_W +: TOKEN_ID_W] <= tip_token;
                    end
                end
            end

            // Check if all branches done
            if ((branch_done_r | ~branch_active_r) == {BRANCH_NUM{1'b1}}) begin
                state_r <= ST_DONE;
            end
        end

        // -----------------------------------------------------------------
        ST_DONE: begin
            all_done <= 1'b1;
            state_r <= ST_IDLE;

            // synthesis translate_off
            $display("[BR_SCHED] all_done: gen[0]=%0d gen[1]=%0d gen[2]=%0d gen[3]=%0d",
                branch_generated_token[0*TOKEN_ID_W +: TOKEN_ID_W],
                branch_generated_token[1*TOKEN_ID_W +: TOKEN_ID_W],
                branch_generated_token[2*TOKEN_ID_W +: TOKEN_ID_W],
                branch_generated_token[3*TOKEN_ID_W +: TOKEN_ID_W]);
            // synthesis translate_on
        end

        default: state_r <= ST_IDLE;
        endcase
    end
end

endmodule
