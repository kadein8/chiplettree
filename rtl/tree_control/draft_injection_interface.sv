`timescale 1ns/1ps
`include "config/interface_params.vh"
`include "config/prediction_params.vh"

// draft_injection_interface
// Behavioral model simulating external draft chiplet predictions.
// Injects prediction tokens into tree_builder to form verification tree.
//
// In real hardware, this would be an inter-chiplet interface receiving
// draft tokens from a separate draft model chiplet. For simulation,
// we generate deterministic predictions based on the seed token.
//
// Tree structure produced (4 branches, depth-progressive):
//   Branch 0: [committed prefix only] → generates next token (main path)
//   Branch 1: [prefix + predicted_C] → generates next token
//   Branch 2: [prefix + predicted_C + predicted_D] → generates next token
//   Branch 3: [prefix + predicted_C2] → generates next token (alternative)

module draft_injection_interface #(
    parameter integer BRANCH_NUM = `BRANCH_NUM,
    parameter integer MAX_DEPTH  = `MAX_PRIVATE_NODES_PER_BRANCH
) (
    input                              clk,
    input                              rst_n,

    // Trigger: start generating draft predictions for current seed
    input                              inject_start,
    input  [`TOKEN_ID_W-1:0]           seed_token_id,
    input  [`POSITION_ID_W-1:0]        seed_position,
    input  [`NODE_ID_W-1:0]            seed_node_id,

    // Output: draft predictions (one per branch per level)
    output reg                         draft_valid,
    output reg [`TOKEN_ID_W-1:0]       draft_token_id,
    output reg [`NODE_ID_W-1:0]        draft_parent_node_id,
    output reg [`POSITION_ID_W-1:0]    draft_position,
    output reg [1:0]                   draft_branch_id,
    output reg [2:0]                   draft_depth,
    output reg                         draft_done,

    // Per-branch injection summary (for comparator)
    output reg [BRANCH_NUM-1:0]        branch_active,
    output reg [BRANCH_NUM*MAX_DEPTH*`TOKEN_ID_W-1:0] branch_injected_tokens,
    output reg [BRANCH_NUM*3-1:0]          branch_depth_out
);

// State machine
localparam [1:0] ST_IDLE = 2'd0, ST_INJECT = 2'd1, ST_DONE = 2'd2;
reg [1:0] state_r;
reg [1:0] cur_branch_r;
reg [2:0] cur_depth_r;
reg [`NODE_ID_W-1:0] next_node_id_r;

// Deterministic prediction generation (behavioral model)
// Uses simple hash of seed to generate different predictions per branch
function [`TOKEN_ID_W-1:0] predict_token;
    input [`TOKEN_ID_W-1:0] seed;
    input [1:0] branch;
    input [2:0] depth;
    begin
        // Simple deterministic prediction: seed XOR (branch*37 + depth*13)
        predict_token = seed ^ ({14'd0, branch} * 16'd37 + {13'd0, depth} * 16'd13);
    end
endfunction

integer bi;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state_r <= ST_IDLE;
        draft_valid <= 1'b0;
        draft_done <= 1'b0;
        draft_token_id <= {`TOKEN_ID_W{1'b0}};
        draft_parent_node_id <= {`NODE_ID_W{1'b0}};
        draft_position <= {`POSITION_ID_W{1'b0}};
        draft_branch_id <= 2'd0;
        draft_depth <= 3'd0;
        cur_branch_r <= 2'd0;
        cur_depth_r <= 3'd0;
        next_node_id_r <= {`NODE_ID_W{1'b0}};
        branch_active <= {BRANCH_NUM{1'b0}};
        branch_injected_tokens <= {(BRANCH_NUM*MAX_DEPTH*`TOKEN_ID_W){1'b0}};
        for (bi = 0; bi < BRANCH_NUM; bi = bi + 1)
            branch_depth_out[bi*3 +: 3] <= 3'd0;
    end else begin
        draft_valid <= 1'b0;
        draft_done <= 1'b0;

        case (state_r)
        ST_IDLE: begin
            if (inject_start) begin
                state_r <= ST_INJECT;
                cur_branch_r <= 2'd1;  // Branch 0 has no injection (main path)
                cur_depth_r <= 3'd0;
                next_node_id_r <= seed_node_id + {{(`NODE_ID_W-1){1'b0}}, 1'b1};
                branch_active <= {BRANCH_NUM{1'b1}};  // All branches active
                branch_injected_tokens <= {(BRANCH_NUM*MAX_DEPTH*`TOKEN_ID_W){1'b0}};
                for (bi = 0; bi < BRANCH_NUM; bi = bi + 1)
                    branch_depth_out[bi*3 +: 3] <= 3'd0;
                // Branch 0 depth = 0 (no injected tokens, just generates next)
                // synthesis translate_off
                $display("[DRAFT] inject_start: seed=%0d pos=%0d",
                    seed_token_id, seed_position);
                // synthesis translate_on
            end
        end

        ST_INJECT: begin
            // Inject tokens for branches 1..3 with increasing depth
            // Branch 1: depth 1 (inject 1 token)
            // Branch 2: depth 2 (inject 2 tokens)
            // Branch 3: depth 1 (inject 1 different token)
            draft_valid <= 1'b1;
            draft_token_id <= predict_token(seed_token_id, cur_branch_r, cur_depth_r);
            draft_parent_node_id <= (cur_depth_r == 3'd0) ?
                seed_node_id : (next_node_id_r - {{(`NODE_ID_W-1){1'b0}}, 1'b1});
            draft_position <= seed_position +
                {{(`POSITION_ID_W-3){1'b0}}, cur_depth_r} +
                {{(`POSITION_ID_W-1){1'b0}}, 1'b1};
            draft_branch_id <= cur_branch_r;
            draft_depth <= cur_depth_r;

            // Store in summary
            branch_injected_tokens[
                (cur_branch_r*MAX_DEPTH + cur_depth_r)*`TOKEN_ID_W +: `TOKEN_ID_W
            ] <= predict_token(seed_token_id, cur_branch_r, cur_depth_r);
            branch_depth_out[cur_branch_r*3 +: 3] <= cur_depth_r + 3'd1;

            next_node_id_r <= next_node_id_r + {{(`NODE_ID_W-1){1'b0}}, 1'b1};

            // Advance: branch 1 gets 1 token, branch 2 gets 2, branch 3 gets 1
            if (cur_branch_r == 2'd1 && cur_depth_r == 3'd0) begin
                cur_branch_r <= 2'd2;
                cur_depth_r <= 3'd0;
            end else if (cur_branch_r == 2'd2 && cur_depth_r < 3'd1) begin
                cur_depth_r <= cur_depth_r + 3'd1;
            end else if (cur_branch_r == 2'd2 && cur_depth_r == 3'd1) begin
                cur_branch_r <= 2'd3;
                cur_depth_r <= 3'd0;
            end else begin
                // All injections done
                state_r <= ST_DONE;
            end

            // synthesis translate_off
            $display("[DRAFT] inject: branch=%0d depth=%0d token=%0d parent=%0d",
                cur_branch_r, cur_depth_r,
                predict_token(seed_token_id, cur_branch_r, cur_depth_r),
                (cur_depth_r == 3'd0) ? seed_node_id :
                    (next_node_id_r - {{(`NODE_ID_W-1){1'b0}}, 1'b1}));
            // synthesis translate_on
        end

        ST_DONE: begin
            draft_done <= 1'b1;
            state_r <= ST_IDLE;
            // synthesis translate_off
            $display("[DRAFT] injection complete: branch_active=%b depths=[%0d,%0d,%0d,%0d]",
                branch_active,
                branch_depth_out[0*3 +: 3], branch_depth_out[1*3 +: 3],
                branch_depth_out[2*3 +: 3], branch_depth_out[3*3 +: 3]);
            // synthesis translate_on
        end

        default: state_r <= ST_IDLE;
        endcase
    end
end

endmodule
