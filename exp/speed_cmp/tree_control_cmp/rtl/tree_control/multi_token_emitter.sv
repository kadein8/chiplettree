`timescale 1ns/1ps
`include "config/interface_params.vh"
`include "config/prediction_params.vh"

// multi_token_emitter
//
// After the comparator determines accepted_count tokens, this module
// emits them one per cycle via token_out_valid/token_out_id.
// Also updates seed/position/committed_prefix_len for the next round.
//
// Interface:
//   - Input: comparator result (accepted_count, accepted_tokens)
//   - Output: burst token_out_valid pulses + updated state

module multi_token_emitter #(
    parameter integer MAX_DEPTH  = `MAX_PRIVATE_NODES_PER_BRANCH,
    parameter integer TOKEN_ID_W = `TOKEN_ID_W,
    parameter integer POSITION_ID_W = `POSITION_ID_W
) (
    input                              clk,
    input                              rst_n,

    // --- Trigger from comparator ---
    input                              emit_start,
    input  [3:0]                       accepted_count,   // 1..MAX_DEPTH+1
    input  [(MAX_DEPTH+1)*TOKEN_ID_W-1:0] accepted_tokens,

    // --- Current state (read) ---
    input  [POSITION_ID_W-1:0]        current_position,
    input  [15:0]                      current_prefix_len,

    // --- Token output (one per cycle) ---
    output reg                         token_out_valid,
    output reg [TOKEN_ID_W-1:0]        token_out_id,

    // --- Updated state after all tokens emitted ---
    output reg                         emit_done,
    output reg [TOKEN_ID_W-1:0]        new_seed_token,
    output reg [POSITION_ID_W-1:0]    new_position,
    output reg [15:0]                  new_prefix_len,
    output reg [3:0]                   tokens_emitted    // how many were actually emitted
);

// =========================================================================
// FSM
// =========================================================================
localparam [1:0] ST_IDLE = 2'd0, ST_EMIT = 2'd1, ST_DONE = 2'd2;
reg [1:0] state_r;

reg [3:0] count_r;       // total to emit
reg [3:0] idx_r;         // current emit index
reg [(MAX_DEPTH+1)*TOKEN_ID_W-1:0] tokens_r;  // latched tokens

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state_r <= ST_IDLE;
        token_out_valid <= 1'b0;
        token_out_id <= '0;
        emit_done <= 1'b0;
        new_seed_token <= '0;
        new_position <= '0;
        new_prefix_len <= 16'd0;
        tokens_emitted <= 4'd0;
        count_r <= 4'd0;
        idx_r <= 4'd0;
        tokens_r <= '0;
    end else begin
        token_out_valid <= 1'b0;
        emit_done <= 1'b0;

        case (state_r)
        ST_IDLE: begin
            if (emit_start && accepted_count > 4'd0) begin
                state_r <= ST_EMIT;
                count_r <= accepted_count;
                idx_r <= 4'd0;
                tokens_r <= accepted_tokens;
                tokens_emitted <= 4'd0;
            end
        end

        ST_EMIT: begin
            // Emit one token per cycle
            token_out_valid <= 1'b1;
            token_out_id <= tokens_r[idx_r*TOKEN_ID_W +: TOKEN_ID_W];
            idx_r <= idx_r + 4'd1;
            tokens_emitted <= tokens_emitted + 4'd1;

            if (idx_r == count_r - 4'd1) begin
                // Last token
                state_r <= ST_DONE;
            end
        end

        ST_DONE: begin
            emit_done <= 1'b1;
            // New seed = last emitted token
            new_seed_token <= tokens_r[(count_r - 4'd1)*TOKEN_ID_W +: TOKEN_ID_W];
            new_position <= current_position + {{(POSITION_ID_W-4){1'b0}}, count_r};
            new_prefix_len <= current_prefix_len + {12'd0, count_r};
            state_r <= ST_IDLE;

            // synthesis translate_off
            $display("[EMITTER] done: emitted %0d tokens, new_seed=%0d new_pos=%0d",
                count_r,
                tokens_r[(count_r - 4'd1)*TOKEN_ID_W +: TOKEN_ID_W],
                current_position + {{(POSITION_ID_W-4){1'b0}}, count_r});
            // synthesis translate_on
        end

        default: state_r <= ST_IDLE;
        endcase
    end
end

endmodule
