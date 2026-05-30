`timescale 1ns/1ps
`include "config/interface_params.vh"
`include "config/prediction_params.vh"

// draft_injection_interface
// Behavioral model simulating external draft chiplet predictions.
//
// Fully parameterized over tree shape:
//   BRANCH_NUM : number of speculative branches (any N >= 1)
//   MAX_DEPTH  : max injected (private) tokens per branch (any D >= 0)
//
// Canonical linear verification chain:
//   Branch 0      : main path, no injection (generates truth[0])
//   Branch b (>=1): injects oracle predictions at depths 0..min(b,MAX_DEPTH)-1
//                   (i.e. b tokens, capped at MAX_DEPTH), generates truth[b]
//
// This produces an increasing-depth chain so the comparator can verify
// depth 0 -> 1 -> ... and accept up to BRANCH_NUM tokens in one round.
//
// PREDICT_ACCURACY (0-100) controls how many leading depths are predicted
// correctly: depth d is correct iff (d+1)*100 <= PREDICT_ACCURACY*MAX_DEPTH.

module draft_injection_interface #(
    parameter integer BRANCH_NUM = `BRANCH_NUM,
    parameter integer MAX_DEPTH  = `MAX_PRIVATE_NODES_PER_BRANCH,
    parameter integer PREDICT_ACCURACY = 100,  // 0-100: percentage of correct predictions
    parameter integer BR_W    = $clog2(BRANCH_NUM),
    parameter integer DEP_W   = $clog2(MAX_DEPTH + 1)
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
    output reg [BR_W-1:0]              draft_branch_id,
    output reg [DEP_W-1:0]             draft_depth,
    output reg                         draft_done,
    output reg [BRANCH_NUM-1:0]        branch_active,
    output reg [BRANCH_NUM*MAX_DEPTH*`TOKEN_ID_W-1:0] branch_injected_tokens,
    output reg [BRANCH_NUM*DEP_W-1:0]  branch_depth_out
);

localparam [1:0] ST_IDLE = 2'd0, ST_INJECT = 2'd1, ST_DONE = 2'd2;
reg [1:0] state_r;
reg [BR_W-1:0]  cur_branch_r;
reg [DEP_W-1:0] cur_depth_r;
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

reg [31:0] predict_call_cnt_r;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) predict_call_cnt_r <= 32'd7;  // non-zero seed
    else if (inject_start || (state_r != ST_IDLE))
        predict_call_cnt_r <= predict_call_cnt_r + 32'd1;
end

// Number of injected tokens for a given branch index = min(branch, MAX_DEPTH).
// Branch 0 -> 0 (main path, no injection); branch b -> b (capped at MAX_DEPTH).
function automatic [DEP_W:0] levels_for_branch;
    input [BR_W-1:0] branch;
    integer br_ext;
    begin
        br_ext = branch;  // zero-extend to integer for a clean min()
        levels_for_branch = (br_ext > MAX_DEPTH) ?
            MAX_DEPTH[DEP_W:0] : br_ext[DEP_W:0];
    end
endfunction

function [`TOKEN_ID_W-1:0] predict_token;
    input [`TOKEN_ID_W-1:0] seed;
    input [BR_W-1:0] branch;
    input [DEP_W-1:0] depth;
    input [31:0] call_cnt;
    reg [`TOKEN_ID_W-1:0] correct_pred;
    reg found;
    begin
        found = 1'b0;
        correct_pred = 16'd0;

        begin
            integer target_pos;
            reg [`TOKEN_ID_W-1:0] oracle_seq [0:15];
            // True greedy continuation of the toy model M[k] = token the model
            // actually generates at step k (captured from the bare branch-0 path
            // with NO draft injection, i.e. the tree's own ground truth — NOT an
            // external serial model). PREDICT_ACCURACY is therefore measured
            // against the model's own output: a "correct" prediction is one that
            // equals what the model itself would emit, so 100% means every
            // injected token matches truth and the whole chain commits.
            oracle_seq[0]  = 16'd11; oracle_seq[1]  = 16'd14;
            oracle_seq[2]  = 16'd6;  oracle_seq[3]  = 16'd0;
            oracle_seq[4]  = 16'd14; oracle_seq[5]  = 16'd0;
            oracle_seq[6]  = 16'd14; oracle_seq[7]  = 16'd0;
            oracle_seq[8]  = 16'd11; oracle_seq[9]  = 16'd14;
            oracle_seq[10] = 16'd6;  oracle_seq[11] = 16'd0;
            oracle_seq[12] = 16'd14; oracle_seq[13] = 16'd0;
            oracle_seq[14] = 16'd14; oracle_seq[15] = 16'd0;

            // Target position = committed_len + depth
            target_pos = committed_len + depth;
            if (target_pos < 16) begin
                correct_pred = oracle_seq[target_pos];
                found = 1'b1;
            end
        end

        // Accuracy control, generalized over MAX_DEPTH:
        //   depth d is predicted correctly iff (d+1)*100 <= ACC * MAX_DEPTH
        // ACC=0   -> no depth correct        (commit 1)
        // ACC=100 -> all depths correct      (commit up to BRANCH_NUM)
        if (found && (((depth + 1) * 100) <= (PREDICT_ACCURACY * MAX_DEPTH))) begin
            predict_token = correct_pred;
        end else if (found) begin
            // Deterministically WRONG: differs from the true token but stays in
            // vocab range, so it can never accidentally equal truth (vocab=16,
            // a random wrong guess would match ~1/16 of the time and blur the
            // accuracy levels). +5 mod 16 is guaranteed != correct_pred.
            predict_token = (correct_pred + 16'd5) & 16'd15;
        end else begin
            // No oracle entry (position past sequence): keep prior behavior.
            predict_token = seed ^ ({{(16-BR_W){1'b0}}, branch} * 16'd37
                                  + {{(16-DEP_W){1'b0}}, depth} * 16'd13
                                  + call_cnt[15:0]);
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
        draft_branch_id <= {BR_W{1'b0}};
        draft_depth <= {DEP_W{1'b0}};
        cur_branch_r <= {BR_W{1'b0}};
        cur_depth_r <= {DEP_W{1'b0}};
        next_node_id_r <= {`NODE_ID_W{1'b0}};
        branch_active <= {BRANCH_NUM{1'b0}};
        branch_injected_tokens <= {(BRANCH_NUM*MAX_DEPTH*`TOKEN_ID_W){1'b0}};
        for (bi = 0; bi < BRANCH_NUM; bi = bi + 1)
            branch_depth_out[bi*DEP_W +: DEP_W] <= {DEP_W{1'b0}};
    end else begin
        draft_valid <= 1'b0;
        draft_done <= 1'b0;

        case (state_r)
        ST_IDLE: begin
            if (inject_start) begin
                state_r <= ST_INJECT;
                cur_branch_r <= {{(BR_W-1){1'b0}}, 1'b1};  // start at branch 1
                cur_depth_r <= {DEP_W{1'b0}};
                next_node_id_r <= seed_node_id + {{(`NODE_ID_W-1){1'b0}}, 1'b1};
                branch_active <= {BRANCH_NUM{1'b1}};
                branch_injected_tokens <= {(BRANCH_NUM*MAX_DEPTH*`TOKEN_ID_W){1'b0}};
                for (bi = 0; bi < BRANCH_NUM; bi = bi + 1)
                    branch_depth_out[bi*DEP_W +: DEP_W] <= {DEP_W{1'b0}};
                // synthesis translate_off
                $display("[DRAFT] inject_start: seed=%0d pos=%0d committed_len=%0d branches=%0d max_depth=%0d",
                    seed_token_id, seed_position, committed_len, BRANCH_NUM, MAX_DEPTH);
                // synthesis translate_on
            end
        end

        ST_INJECT: begin
            draft_valid <= 1'b1;
            draft_token_id <= predict_token(seed_token_id, cur_branch_r, cur_depth_r, predict_call_cnt_r);
            draft_parent_node_id <= (cur_depth_r == {DEP_W{1'b0}}) ? seed_node_id :
                (next_node_id_r - {{(`NODE_ID_W-1){1'b0}}, 1'b1});
            draft_position <= seed_position +
                {{(`POSITION_ID_W-DEP_W){1'b0}}, cur_depth_r} +
                {{(`POSITION_ID_W-1){1'b0}}, 1'b1};
            draft_branch_id <= cur_branch_r;
            draft_depth <= cur_depth_r;

            // Record injected token + running depth count for comparator
            branch_injected_tokens[(cur_branch_r*MAX_DEPTH + cur_depth_r)*`TOKEN_ID_W +: `TOKEN_ID_W] <=
                predict_token(seed_token_id, cur_branch_r, cur_depth_r, predict_call_cnt_r);
            branch_depth_out[cur_branch_r*DEP_W +: DEP_W] <= cur_depth_r + {{(DEP_W-1){1'b0}}, 1'b1};

            next_node_id_r <= next_node_id_r + {{(`NODE_ID_W-1){1'b0}}, 1'b1};

            // Generic linear-chain advance:
            //   within a branch, walk depths 0..levels_for_branch(branch)-1
            //   then move to the next branch (reset depth to 0)
            // Compare against (BRANCH_NUM-1) which always fits in BR_W bits
            // (BRANCH_NUM itself can overflow when BRANCH_NUM is a power of 2).
            if ((cur_depth_r + 1) < levels_for_branch(cur_branch_r)) begin
                cur_depth_r <= cur_depth_r + {{(DEP_W-1){1'b0}}, 1'b1};
            end else if (cur_branch_r != (BRANCH_NUM-1)) begin
                cur_branch_r <= cur_branch_r + {{(BR_W-1){1'b0}}, 1'b1};
                cur_depth_r <= {DEP_W{1'b0}};
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
            begin
                integer db;
                $write("[DRAFT] done: depths=[");
                for (db = 0; db < BRANCH_NUM; db = db + 1)
                    $write("%0d ", branch_depth_out[db*DEP_W +: DEP_W]);
                $write("]\n");
            end
            // synthesis translate_on
        end

        default: state_r <= ST_IDLE;
        endcase
    end
end

endmodule
