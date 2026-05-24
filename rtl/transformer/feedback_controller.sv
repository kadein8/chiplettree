`include "config/interface_params.vh"
`include "config/prediction_params.vh"
`timescale 1ns/1ps

// feedback_controller
// Routes commit results from tree_verify_dispatcher back to HHTContextPredictor
// and emits accepted tokens to the output stream.
//
// On commit_valid:
//   1. Extract accepted tokens from winning branch (commit_depth levels)
//   2. Feed each accepted token sequentially to HHT accept interface
//   3. Emit bonus_token as new seed for next iteration
//   4. Update committed_prefix_len

module feedback_controller #(
    parameter integer BRANCH_NUM    = `BRANCH_NUM,
    parameter integer MAX_LEVELS    = `MAX_PRIVATE_NODES_PER_BRANCH,
    parameter integer TOKEN_ID_W    = `TOKEN_ID_W,
    parameter integer POSITION_ID_W = `POSITION_ID_W,
    parameter integer NODE_ID_W     = `NODE_ID_W,
    parameter integer BRANCH_ID_W   = `BRANCH_ID_W,
    parameter integer SLOT_ID_W     = `SLOT_ID_W
) (
    input  logic                          clk,
    input  logic                          rst_n,

    // Commit input from tree_verify_dispatcher
    input  logic                          commit_valid,
    input  logic [BRANCH_ID_W-1:0]        commit_branch_id,
    input  logic [2:0]                    commit_depth,
    input  logic [TOKEN_ID_W-1:0]         commit_bonus_token_id,
    input  logic [BRANCH_NUM-1:0]         commit_flush_mask,
    input  logic [MAX_LEVELS*SLOT_ID_W-1:0] commit_slots,
    input  logic [MAX_LEVELS*16-1:0]      commit_slot_positions,

    // Token mapping from tree_builder (to resolve slot→token)
    input  logic [BRANCH_NUM*MAX_LEVELS*TOKEN_ID_W-1:0]    branch_draft_tokens,
    input  logic [BRANCH_NUM*MAX_LEVELS*NODE_ID_W-1:0]     branch_node_ids,
    input  logic [BRANCH_NUM*MAX_LEVELS*POSITION_ID_W-1:0] branch_draft_positions,

    // HHT accept interface (sequential, one per cycle)
    output logic                          hht_accept_valid,
    output logic [NODE_ID_W-1:0]          hht_accept_parent_node_id,
    output logic [TOKEN_ID_W-1:0]         hht_accept_token_id,
    output logic [POSITION_ID_W-1:0]      hht_accept_position,

    // Output token stream
    output logic                          out_token_valid,
    output logic [TOKEN_ID_W-1:0]         out_token_id,
    output logic [POSITION_ID_W-1:0]      out_token_position,

    // New seed for next iteration
    output logic                          new_seed_valid,
    output logic [NODE_ID_W-1:0]          new_seed_node_id,
    output logic [TOKEN_ID_W-1:0]         new_seed_token_id,
    output logic [POSITION_ID_W-1:0]      new_seed_position,

    // Status
    output logic                          busy,
    output logic                          done
);

    localparam [1:0] ST_IDLE    = 2'd0,
                     ST_EMIT    = 2'd1,
                     ST_BONUS   = 2'd2,
                     ST_DONE    = 2'd3;

    logic [1:0] state_r;
    logic [2:0] emit_idx_r;
    logic [BRANCH_ID_W-1:0] win_branch_r;
    logic [2:0] win_depth_r;
    logic [TOKEN_ID_W-1:0] bonus_token_r;

    // Resolve token for winning branch at given level
    wire [TOKEN_ID_W-1:0] cur_token_w =
        branch_draft_tokens[(win_branch_r*MAX_LEVELS + emit_idx_r)*TOKEN_ID_W +: TOKEN_ID_W];
    wire [NODE_ID_W-1:0] cur_node_w =
        branch_node_ids[(win_branch_r*MAX_LEVELS + emit_idx_r)*NODE_ID_W +: NODE_ID_W];
    wire [POSITION_ID_W-1:0] cur_position_w =
        branch_draft_positions[(win_branch_r*MAX_LEVELS + emit_idx_r)*POSITION_ID_W +: POSITION_ID_W];
    wire [NODE_ID_W-1:0] cur_parent_w =
        (emit_idx_r == 3'd0) ? {NODE_ID_W{1'b0}} :
        branch_node_ids[(win_branch_r*MAX_LEVELS + emit_idx_r - 3'd1)*NODE_ID_W +: NODE_ID_W];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_r <= ST_IDLE;
            emit_idx_r <= 3'd0;
            win_branch_r <= '0;
            win_depth_r <= 3'd0;
            bonus_token_r <= '0;
            busy <= 1'b0;
            done <= 1'b0;
            hht_accept_valid <= 1'b0;
            out_token_valid <= 1'b0;
            new_seed_valid <= 1'b0;
            out_token_id <= '0;
            out_token_position <= '0;
            hht_accept_parent_node_id <= '0;
            hht_accept_token_id <= '0;
            hht_accept_position <= '0;
            new_seed_node_id <= '0;
            new_seed_token_id <= '0;
            new_seed_position <= '0;
        end else begin
            done <= 1'b0;
            hht_accept_valid <= 1'b0;
            out_token_valid <= 1'b0;
            new_seed_valid <= 1'b0;

            case (state_r)
            ST_IDLE: begin
                if (commit_valid) begin
                    win_branch_r <= commit_branch_id;
                    win_depth_r <= commit_depth;
                    bonus_token_r <= commit_bonus_token_id;
                    emit_idx_r <= 3'd0;
                    busy <= 1'b1;
                    if (commit_depth > 3'd0)
                        state_r <= ST_EMIT;
                    else
                        state_r <= ST_BONUS;
                end
            end

            // Emit accepted tokens one per cycle
            ST_EMIT: begin
                out_token_valid <= 1'b1;
                out_token_id <= cur_token_w;
                out_token_position <= cur_position_w;

                hht_accept_valid <= 1'b1;
                hht_accept_parent_node_id <= cur_parent_w;
                hht_accept_token_id <= cur_token_w;
                hht_accept_position <= cur_position_w;

                if (emit_idx_r == win_depth_r - 3'd1) begin
                    state_r <= ST_BONUS;
                end else begin
                    emit_idx_r <= emit_idx_r + 3'd1;
                end
            end

            // Emit bonus token (model's prediction at the mismatch point)
            ST_BONUS: begin
                out_token_valid <= 1'b1;
                out_token_id <= bonus_token_r;
                out_token_position <= cur_position_w +
                    {{(POSITION_ID_W-1){1'b0}}, 1'b1};

                // Bonus token becomes new seed
                new_seed_valid <= 1'b1;
                new_seed_node_id <= cur_node_w + {{(NODE_ID_W-1){1'b0}}, 1'b1};
                new_seed_token_id <= bonus_token_r;
                new_seed_position <= cur_position_w +
                    {{(POSITION_ID_W-1){1'b0}}, 1'b1};

                // Feed bonus to HHT
                hht_accept_valid <= 1'b1;
                hht_accept_parent_node_id <= cur_node_w;
                hht_accept_token_id <= bonus_token_r;
                hht_accept_position <= cur_position_w +
                    {{(POSITION_ID_W-1){1'b0}}, 1'b1};

                state_r <= ST_DONE;
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
