`timescale 1ns/1ps
`include "config/interface_params.vh"
`include "config/prediction_params.vh"

// longest_path_comparator
// Compares branch verification results to find the longest correct path.
//
// Input: per-branch {injected prediction tokens, generated next token}
// Logic: shallow branch generated vs deeper branch injected, level by level
// Output: longest match depth + accepted tokens + flush mask
//
// Algorithm:
//   1. Branch 0 generates token_0 (ground truth for position seed+1)
//   2. Check branch 1's injected[0] == token_0? If yes, branch 1 is valid at depth 0
//   3. Branch 1 generates token_1 (ground truth for position seed+2)
//   4. Check branch 2's injected[1] == token_1? If yes, branch 2 is valid at depth 1
//   5. Continue until mismatch or no deeper branch
//   6. Also check alternative branches (e.g., branch 3 injected[0] vs token_0)
//
// The longest consecutive correct chain = number of accepted tokens.
// If all predictions wrong, accept only branch 0's generated token (1 token).

module longest_path_comparator #(
    parameter integer BRANCH_NUM = `BRANCH_NUM,
    parameter integer MAX_DEPTH  = `MAX_PRIVATE_NODES_PER_BRANCH
) (
    input                              clk,
    input                              rst_n,

    // Trigger
    input                              compare_start,

    // Per-branch generated next token (from PE groups)
    input  [BRANCH_NUM*`TOKEN_ID_W-1:0] branch_generated_token,
    input  [BRANCH_NUM-1:0]            branch_valid,

    // Per-branch injected prediction tokens (from draft_injection_interface)
    input  [BRANCH_NUM*MAX_DEPTH*`TOKEN_ID_W-1:0] branch_injected_tokens,
    input  [BRANCH_NUM*3-1:0]              branch_depth,

    // Output
    output reg                         result_valid,
    output reg [2:0]                   accepted_depth,  // number of extra tokens accepted (0 = only branch0's token)
    output reg [(MAX_DEPTH+1)*`TOKEN_ID_W-1:0] accepted_tokens,  // accepted token sequence
    output reg [BRANCH_NUM-1:0]        flush_mask,      // branches to discard
    output reg                         all_correct      // all predictions matched
);

// Combinational comparison logic
reg [2:0] match_depth_c;
reg [BRANCH_NUM-1:0] branch_match_c;
reg [(MAX_DEPTH+1)*`TOKEN_ID_W-1:0] tokens_c;

// Branch ordering for depth-progressive verification:
// Branch 0: depth 0 (main path, no injection)
// Branch 1: depth 1 (1 injected token)
// Branch 2: depth 2 (2 injected tokens)
// Branch 3: depth 1 (alternative, 1 injected token)
//
// Verification chain: branch0.gen → branch1.injected[0]?
//                     branch1.gen → branch2.injected[1]?

integer ci;
reg [`TOKEN_ID_W-1:0] ground_truth_at_depth [0:MAX_DEPTH-1];

always @(*) begin
    match_depth_c = 3'd0;
    branch_match_c = {BRANCH_NUM{1'b0}};
    tokens_c = {((MAX_DEPTH+1)*`TOKEN_ID_W){1'b0}};

    // Branch 0 always contributes its generated token (ground truth at depth 0)
    tokens_c[0 +: `TOKEN_ID_W] = branch_generated_token[0 +: `TOKEN_ID_W];
    ground_truth_at_depth[0] = branch_generated_token[0 +: `TOKEN_ID_W];

    // Check each branch's injection against ground truth
    for (ci = 1; ci < BRANCH_NUM; ci = ci + 1) begin
        if (branch_valid[ci] && branch_depth[ci*3 +: 3] > 3'd0) begin
            // Check if this branch's first injected token matches ground truth at depth 0
            if (branch_injected_tokens[ci*MAX_DEPTH*`TOKEN_ID_W +: `TOKEN_ID_W] ==
                ground_truth_at_depth[0]) begin
                branch_match_c[ci] = 1'b1;
            end
        end
    end

    // Find the deepest matching chain
    // Branch 1 matched at depth 0 → its generated token is ground truth at depth 1
    if (branch_match_c[1] && branch_valid[1]) begin
        match_depth_c = 3'd1;
        ground_truth_at_depth[1] = branch_generated_token[1*`TOKEN_ID_W +: `TOKEN_ID_W];
        tokens_c[1*`TOKEN_ID_W +: `TOKEN_ID_W] =
            branch_generated_token[1*`TOKEN_ID_W +: `TOKEN_ID_W];

        // Check branch 2's second injected token against depth 1 ground truth
        if (branch_valid[2] && branch_depth[2*3 +: 3] > 3'd1) begin
            if (branch_injected_tokens[(2*MAX_DEPTH+1)*`TOKEN_ID_W +: `TOKEN_ID_W] ==
                ground_truth_at_depth[1]) begin
                match_depth_c = 3'd2;
                tokens_c[2*`TOKEN_ID_W +: `TOKEN_ID_W] =
                    branch_generated_token[2*`TOKEN_ID_W +: `TOKEN_ID_W];
            end
        end
    end
end

// Sequential output
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        result_valid <= 1'b0;
        accepted_depth <= 3'd0;
        accepted_tokens <= {((MAX_DEPTH+1)*`TOKEN_ID_W){1'b0}};
        flush_mask <= {BRANCH_NUM{1'b0}};
        all_correct <= 1'b0;
    end else begin
        result_valid <= 1'b0;
        if (compare_start) begin
            result_valid <= 1'b1;
            accepted_depth <= match_depth_c;
            accepted_tokens <= tokens_c;
            // Flush branches that didn't match
            flush_mask <= branch_valid & ~branch_match_c & ~{{(BRANCH_NUM-1){1'b0}}, 1'b1};
            all_correct <= (match_depth_c == MAX_DEPTH[2:0]);

            // synthesis translate_off
            $display("[COMPARATOR] depth=%0d tokens[0]=%0d tokens[1]=%0d tokens[2]=%0d flush=%b",
                match_depth_c,
                tokens_c[0 +: `TOKEN_ID_W],
                tokens_c[1*`TOKEN_ID_W +: `TOKEN_ID_W],
                tokens_c[2*`TOKEN_ID_W +: `TOKEN_ID_W],
                branch_valid & ~branch_match_c & ~{{(BRANCH_NUM-1){1'b0}}, 1'b1});
            $display("[COMPARATOR] branch_match=%b gen[0]=%0d gen[1]=%0d gen[2]=%0d gen[3]=%0d",
                branch_match_c,
                branch_generated_token[0*`TOKEN_ID_W +: `TOKEN_ID_W],
                branch_generated_token[1*`TOKEN_ID_W +: `TOKEN_ID_W],
                branch_generated_token[2*`TOKEN_ID_W +: `TOKEN_ID_W],
                branch_generated_token[3*`TOKEN_ID_W +: `TOKEN_ID_W]);
            // synthesis translate_on
        end
    end
end

endmodule
