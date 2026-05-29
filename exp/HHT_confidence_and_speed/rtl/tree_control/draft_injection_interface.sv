`timescale 1ns/1ps
`include "config/interface_params.vh"
`include "config/prediction_params.vh"

// draft_injection_interface
// Behavioral model simulating external draft chiplet predictions.
// Dynamic prediction: maintains committed_seq buffer from commit feedback.

module draft_injection_interface #(
    parameter integer BRANCH_NUM = `BRANCH_NUM,
    parameter integer MAX_DEPTH  = `MAX_PRIVATE_NODES_PER_BRANCH,
    parameter integer PREDICT_ACCURACY = 100  // 0-100: percentage of correct predictions
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
reg [`NODE_ID_W-1:0] branch2_tip_node_r;  // node_id of B2's last node (parent for B3)

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
// PREDICT_ACCURACY parameter controls hit rate (0=always wrong, 100=always correct)
// Use a counter-based approach: every prediction call increments counter,
// prediction is correct if (counter % 100) < PREDICT_ACCURACY
reg [31:0] predict_call_cnt_r;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) predict_call_cnt_r <= 32'd7;  // non-zero seed
    else if (inject_start || (state_r != 3'd0))
        predict_call_cnt_r <= predict_call_cnt_r + 32'd1;
end

function [`TOKEN_ID_W-1:0] predict_token;
    input [`TOKEN_ID_W-1:0] seed;
    input [1:0] branch;
    input [2:0] depth;
    input [31:0] call_cnt;
    integer match_idx, k;
    reg [`TOKEN_ID_W-1:0] known_seq [0:4];
    reg [`TOKEN_ID_W-1:0] correct_pred;
    reg found;
    begin
        // Static known sequence
        known_seq[0] = 16'd0;
        known_seq[1] = 16'd13;
        known_seq[2] = 16'd13;
        known_seq[3] = 16'd13;
        known_seq[4] = 16'd13;

        // Oracle-based prediction: hardcoded correct output sequence
        // This simulates a perfect draft model that knows the future
        // PREDICT_ACCURACY controls how often we use the oracle vs random
        found = 1'b0;
        correct_pred = 16'd0;

        begin
            integer target_pos;
            reg [`TOKEN_ID_W-1:0] oracle_seq [0:15];
            // Full correct output sequence (pre-determined from RTL behavior)
            oracle_seq[0]  = 16'd13; oracle_seq[1]  = 16'd13;
            oracle_seq[2]  = 16'd13; oracle_seq[3]  = 16'd11;
            oracle_seq[4]  = 16'd15; oracle_seq[5]  = 16'd11;
            oracle_seq[6]  = 16'd10; oracle_seq[7]  = 16'd12;
            oracle_seq[8]  = 16'd13; oracle_seq[9]  = 16'd11;
            oracle_seq[10] = 16'd15; oracle_seq[11] = 16'd11;
            oracle_seq[12] = 16'd10; oracle_seq[13] = 16'd12;
            oracle_seq[14] = 16'd13; oracle_seq[15] = 16'd11;

            // Target position = committed_len + depth
            // (committed_len tokens already generated, we're predicting depth steps ahead)
            target_pos = committed_len + depth;
            if (target_pos < 16) begin
                correct_pred = oracle_seq[target_pos];
                found = 1'b1;
            end
        end

        // Apply accuracy control: depth-based
        // PREDICT_ACCURACY controls max correct depth:
        //   0%: all wrong
        //   25%: depth 0 correct (commit up to 2 tokens/round)
        //   50%: depth 0-1 correct (commit up to 3 tokens/round)
        //   75%: depth 0-2 correct (commit up to 4 tokens/round)
        //   100%: all depths correct
        if (found && (depth * 34) < PREDICT_ACCURACY) begin
            predict_token = correct_pred;
        end else begin
            // Wrong prediction
            predict_token = seed ^ ({14'd0, branch} * 16'd37 + {13'd0, depth} * 16'd13 + {16'd0, call_cnt[15:0]});
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
            draft_token_id <= predict_token(seed_token_id, cur_branch_r, cur_depth_r, predict_call_cnt_r);
            draft_parent_node_id <= (cur_depth_r == 3'd0) ? seed_node_id :
                (next_node_id_r - {{(`NODE_ID_W-1){1'b0}}, 1'b1});
            draft_position <= seed_position + {{(`POSITION_ID_W-3){1'b0}}, cur_depth_r} +
                {{(`POSITION_ID_W-1){1'b0}}, 1'b1};
            draft_branch_id <= cur_branch_r;
            draft_depth <= cur_depth_r;

            // Record injected token for comparator
            branch_injected_tokens[(cur_branch_r*MAX_DEPTH + cur_depth_r)*`TOKEN_ID_W +: `TOKEN_ID_W] <=
                predict_token(seed_token_id, cur_branch_r, cur_depth_r, predict_call_cnt_r);
            branch_depth_out[cur_branch_r*3 +: 3] <= cur_depth_r + 3'd1;

            next_node_id_r <= next_node_id_r + {{(`NODE_ID_W-1){1'b0}}, 1'b1};

            // Linear main chain: B1(d0), B2(d0,d1), B3(d0,d1,d2)
            // B2 is extension of B1, B3 is extension of B2 (all on same path)
            // This lets comparator verify depth 0→1→2 and distinguish 25/50/75%
            if (cur_branch_r == 2'd1 && cur_depth_r == 3'd0) begin
                cur_branch_r <= 2'd2;
                cur_depth_r <= 3'd0;
            end else if (cur_branch_r == 2'd2 && cur_depth_r < 3'd1) begin
                cur_depth_r <= cur_depth_r + 3'd1;
            end else if (cur_branch_r == 2'd2 && cur_depth_r == 3'd1) begin
                cur_branch_r <= 2'd3;
                cur_depth_r <= 3'd0;
            end else if (cur_branch_r == 2'd3 && cur_depth_r < 3'd2) begin
                cur_depth_r <= cur_depth_r + 3'd1;
            end else begin
                state_r <= ST_DONE;
            end

            // synthesis translate_off
            $display("[DRAFT] inject: branch=%0d depth=%0d token=%0d",
                cur_branch_r, cur_depth_r,
                predict_token(seed_token_id, cur_branch_r, cur_depth_r, predict_call_cnt_r));
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
