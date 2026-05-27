`timescale 1ns/1ps
`include "config/interface_params.vh"
`include "config/prediction_params.vh"

// draft_injection_interface
// Behavioral model simulating external draft chiplet predictions.
// Dynamic prediction: maintains committed_seq buffer from commit feedback.

module draft_injection_interface #(
    parameter integer BRANCH_NUM = `BRANCH_NUM,
    parameter integer MAX_DEPTH  = `MAX_PRIVATE_NODES_PER_BRANCH
) (
    input                              clk,
    input                              rst_n,
    input                              inject_start,
    input  [`TOKEN_ID_W-1:0]           seed_token_id,
    input  [`POSITION_ID_W-1:0]        seed_position,
    input  [`NODE_ID_W-1:0]            seed_node_id,
    // Commit feedback for dynamic prediction
    input                              commit_feedback_valid,
    input  [`TOKEN_ID_W-1:0]           commit_feedback_token,
    // Draft outputs
    output reg                         draft_valid,
    output reg [`TOKEN_ID_W-1:0]       draft_token_id,
    output reg [`NODE_ID_W-1:0]        draft_parent_node_id,
    output reg [`POSITION_ID_W-1:0]    draft_position,
    output reg [1:0]                   draft_branch_id,
    output reg [2:0]                   draft_depth,
    output reg                         draft_done,
    output reg [BRANCH_NUM-1:0]        branch_active,
    output reg [BRANCH_NUM*MAX_DEPTH*`TOKEN_ID_W-1:0] branch_injected_tokens,
    output reg [BRANCH_NUM*3-1:0]      branch_depth_out
);

localparam [1:0] ST_IDLE = 2'd0, ST_INJECT = 2'd1, ST_DONE = 2'd2;
reg [1:0] state_r;
reg [1:0] cur_branch_r;
reg [2:0] cur_depth_r;
reg [`NODE_ID_W-1:0] next_node_id_r;

// Dynamic committed sequence buffer
reg [`TOKEN_ID_W-1:0] committed_seq [0:31];
reg [4:0] committed_len;

integer ci;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        committed_len <= 5'd0;
        for (ci = 0; ci < 32; ci = ci + 1)
            committed_seq[ci] <= {`TOKEN_ID_W{1'b0}};
    end else if (commit_feedback_valid) begin
        committed_seq[committed_len] <= commit_feedback_token;
        committed_len <= committed_len + 5'd1;
        // synthesis translate_off
        $display("[DRAFT] commit_feedback: token=%0d -> seq[%0d]", commit_feedback_token, committed_len);
        // synthesis translate_on
    end
end

// Dynamic prediction: combines static draft model knowledge + runtime learning
// In real hardware, this would be a separate draft model doing inference.
// For behavioral sim, we use:
//   1. Static known sequence (simulates draft model's prediction)
//   2. Runtime committed_seq for tokens beyond known sequence
//   3. Hash fallback for completely unknown seeds
function [`TOKEN_ID_W-1:0] predict_token;
    input [`TOKEN_ID_W-1:0] seed;
    input [1:0] branch;
    input [2:0] depth;
    integer match_idx, k;
    reg [`TOKEN_ID_W-1:0] known_seq [0:4];
    begin
        // Static known sequence (draft model's built-in knowledge)
        known_seq[0] = 16'd0;
        known_seq[1] = 16'd13;
        known_seq[2] = 16'd6;
        known_seq[3] = 16'd14;
        known_seq[4] = 16'd11;

        // First try static sequence
        match_idx = -1;
        for (k = 0; k < 5; k = k + 1)
            if (known_seq[k] == seed) match_idx = k;
        if (match_idx >= 0 && (match_idx + 1 + depth) < 5) begin
            predict_token = known_seq[match_idx + 1 + depth];
        end else begin
            // Try committed_seq (runtime learned)
            match_idx = -1;
            for (k = 0; k < 32; k = k + 1)
                if (k < committed_len && committed_seq[k] == seed)
                    match_idx = k;
            if (match_idx >= 0 && (match_idx + 1 + depth) < committed_len)
                predict_token = committed_seq[match_idx + 1 + depth];
            else
                predict_token = seed ^ ({14'd0, branch} * 16'd37 + {13'd0, depth} * 16'd13);
        end
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
                cur_branch_r <= 2'd1;
                cur_depth_r <= 3'd0;
                next_node_id_r <= seed_node_id + {{(`NODE_ID_W-1){1'b0}}, 1'b1};
                branch_active <= {BRANCH_NUM{1'b1}};
                branch_injected_tokens <= {(BRANCH_NUM*MAX_DEPTH*`TOKEN_ID_W){1'b0}};
                for (bi = 0; bi < BRANCH_NUM; bi = bi + 1)
                    branch_depth_out[bi*3 +: 3] <= 3'd0;
                // synthesis translate_off
                $display("[DRAFT] inject_start: seed=%0d pos=%0d committed_len=%0d",
                    seed_token_id, seed_position, committed_len);
                // synthesis translate_on
            end
        end

        ST_INJECT: begin
            draft_valid <= 1'b1;
            draft_token_id <= predict_token(seed_token_id, cur_branch_r, cur_depth_r);
            draft_parent_node_id <= (cur_depth_r == 3'd0) ? seed_node_id :
                (next_node_id_r - {{(`NODE_ID_W-1){1'b0}}, 1'b1});
            draft_position <= seed_position + {{(`POSITION_ID_W-3){1'b0}}, cur_depth_r} +
                {{(`POSITION_ID_W-1){1'b0}}, 1'b1};
            draft_branch_id <= cur_branch_r;
            draft_depth <= cur_depth_r;

            // Record injected token for comparator
            branch_injected_tokens[(cur_branch_r*MAX_DEPTH + cur_depth_r)*`TOKEN_ID_W +: `TOKEN_ID_W] <=
                predict_token(seed_token_id, cur_branch_r, cur_depth_r);
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
                state_r <= ST_DONE;
            end

            // synthesis translate_off
            $display("[DRAFT] inject: branch=%0d depth=%0d token=%0d",
                cur_branch_r, cur_depth_r,
                predict_token(seed_token_id, cur_branch_r, cur_depth_r));
            // synthesis translate_on
        end

        ST_DONE: begin
            draft_done <= 1'b1;
            state_r <= ST_IDLE;
            // synthesis translate_off
            $display("[DRAFT] done: depths=[%0d,%0d,%0d,%0d]",
                branch_depth_out[0*3 +: 3], branch_depth_out[1*3 +: 3],
                branch_depth_out[2*3 +: 3], branch_depth_out[3*3 +: 3]);
            // synthesis translate_on
        end

        default: state_r <= ST_IDLE;
        endcase
    end
end

endmodule
