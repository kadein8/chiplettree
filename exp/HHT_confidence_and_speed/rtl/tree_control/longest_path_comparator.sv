`timescale 1ns/1ps
`include "config/interface_params.vh"
`include "config/prediction_params.vh"

// longest_path_comparator
//
// Compares branch verification results to find the longest correct path.
// Supports multi-token commit: one verification round can accept up to
// MAX_DEPTH+1 tokens (all predictions correct + deepest branch generation).
//
// Tree structure (4 branches, increasing depth):
//   Branch 0: [committed_prefix]           → generates C1 (main path, no injection)
//   Branch 1: [committed_prefix] C1        → generates D1 (injected C1)
//   Branch 2: [committed_prefix] C1 D1     → generates E2 (injected C1, D1)
//   Branch 3: [committed_prefix] C2        → generates D2 (alternative, injected C2)
//
// Verification logic:
//   Branch 0 gen C1 vs Branch 1 injected[0] C1 → match → accept C1
//   Branch 1 gen D1 vs Branch 2 injected[1] D1 → match → accept D1
//   Branch 2 gen E2: deepest verified branch → accept E2 (no further verification needed)
//   Branch 3 injected[0] C2 ≠ C1 → truncate
//
// Result: accepted_count = 3 (C1, D1, E2), flush Branch 3
//
// Key insight: the deepest branch whose prefix is fully verified always
// contributes its generated token. It's a normal transformer output on a
// verified-correct prefix.

module longest_path_comparator #(
    parameter integer BRANCH_NUM = `BRANCH_NUM,
    parameter integer MAX_DEPTH  = `MAX_PRIVATE_NODES_PER_BRANCH,
    parameter integer DEP_W      = $clog2(MAX_DEPTH + 1),
    parameter integer CNT_W      = $clog2(BRANCH_NUM + 2)
) (
    input                              clk,
    input                              rst_n,

    // Trigger
    input                              compare_start,

    // Per-branch generated next token (from PE groups)
    input  [BRANCH_NUM*`TOKEN_ID_W-1:0] branch_generated_token,
    input  [BRANCH_NUM-1:0]            branch_valid,

    // Per-branch injected prediction tokens (from tree_builder/draft)
    // Layout: branch_injected_tokens[branch*MAX_DEPTH + level] = token at that depth
    input  [BRANCH_NUM*MAX_DEPTH*`TOKEN_ID_W-1:0] branch_injected_tokens,
    // Per-branch depth (number of injected tokens)
    input  [BRANCH_NUM*DEP_W-1:0]      branch_depth,

    // Output
    output reg                         result_valid,
    output reg [CNT_W-1:0]             accepted_count,  // total tokens to commit (1..BRANCH_NUM)
    output reg [(MAX_DEPTH+1)*`TOKEN_ID_W-1:0] accepted_tokens,  // token sequence to emit
    output reg [BRANCH_NUM-1:0]        flush_mask,      // branches to discard (KV reclaim)
    output reg                         all_correct      // all predictions in main chain matched
);

// =========================================================================
// Combinational comparison logic
// =========================================================================
reg [CNT_W-1:0] count_c;
reg [BRANCH_NUM-1:0] flush_c;
reg [(MAX_DEPTH+1)*`TOKEN_ID_W-1:0] tokens_c;
reg all_correct_c;

// Ground truth at each depth level (from the branch that generates it)
reg [`TOKEN_ID_W-1:0] truth [0:MAX_DEPTH];
reg chain_broken;

integer ci, di;

always @(*) begin
    count_c = {{(CNT_W-1){1'b0}}, 1'b1};  // minimum: always accept Branch 0's generated token
    flush_c = {BRANCH_NUM{1'b0}};
    tokens_c = {((MAX_DEPTH+1)*`TOKEN_ID_W){1'b0}};
    all_correct_c = 1'b0;
    chain_broken = 1'b0;

    // Initialize truth array
    for (di = 0; di <= MAX_DEPTH; di = di + 1)
        truth[di] = {`TOKEN_ID_W{1'b0}};

    // Branch 0 always contributes (it's the main path with no injection)
    if (branch_valid[0]) begin
        truth[0] = branch_generated_token[0*`TOKEN_ID_W +: `TOKEN_ID_W];
        tokens_c[0*`TOKEN_ID_W +: `TOKEN_ID_W] = truth[0];
    end

    // Walk the verification chain: branch[i] generates truth[i],
    // branch[i+1] must have injected truth[i] at its depth position i.
    //
    // Branch ordering (linear chain): branch b injects b tokens at depths
    // 0..b-1 and generates truth[b] if its prefix verifies.

    for (ci = 1; ci < BRANCH_NUM && ci <= MAX_DEPTH; ci = ci + 1) begin
        if (!chain_broken && branch_valid[ci] && branch_depth[ci*DEP_W +: DEP_W] >= ci[DEP_W-1:0]) begin
            // Check: branch[ci]'s injected token at level (ci-1) must match truth[ci-1]
            if (branch_injected_tokens[(ci*MAX_DEPTH + (ci-1))*`TOKEN_ID_W +: `TOKEN_ID_W] == truth[ci-1]) begin
                // Match! This branch's prefix is verified correct.
                // Its generated token becomes truth at the next depth.
                truth[ci] = branch_generated_token[ci*`TOKEN_ID_W +: `TOKEN_ID_W];
                tokens_c[ci*`TOKEN_ID_W +: `TOKEN_ID_W] = truth[ci];
                count_c = count_c + {{(CNT_W-1){1'b0}}, 1'b1};
            end else begin
                // Mismatch: chain broken, flush this branch
                chain_broken = 1'b1;
                flush_c[ci] = 1'b1;
            end
        end else if (!chain_broken && branch_valid[ci]) begin
            // Branch exists but doesn't have enough depth for this chain position
            chain_broken = 1'b1;
        end
    end

    // Flush alternative branches that don't match at depth 0
    for (ci = 1; ci < BRANCH_NUM; ci = ci + 1) begin
        if (branch_valid[ci] && !flush_c[ci]) begin
            // If this branch's first injected token doesn't match truth[0], flush it
            if (branch_depth[ci*DEP_W +: DEP_W] > {DEP_W{1'b0}} &&
                branch_injected_tokens[ci*MAX_DEPTH*`TOKEN_ID_W +: `TOKEN_ID_W] != truth[0]) begin
                flush_c[ci] = 1'b1;
            end
        end
    end

    // All correct if chain reached maximum possible depth
    if (count_c > MAX_DEPTH[CNT_W-1:0])
        all_correct_c = 1'b1;
end

// =========================================================================
// Sequential output (1-cycle latency from compare_start)
// =========================================================================
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        result_valid <= 1'b0;
        accepted_count <= {CNT_W{1'b0}};
        accepted_tokens <= '0;
        flush_mask <= {BRANCH_NUM{1'b0}};
        all_correct <= 1'b0;
    end else begin
        result_valid <= 1'b0;
        if (compare_start) begin
            result_valid <= 1'b1;
            accepted_count <= count_c;
            accepted_tokens <= tokens_c;
            flush_mask <= flush_c;
            all_correct <= all_correct_c;

            // synthesis translate_off
            begin
                integer pk;
                $write("[COMPARATOR] accepted_count=%0d tokens=[", count_c);
                for (pk = 0; pk <= MAX_DEPTH; pk = pk + 1)
                    $write("%0d ", tokens_c[pk*`TOKEN_ID_W +: `TOKEN_ID_W]);
                $write("] flush=%b\n", flush_c);
                $write("[COMPARATOR] gen=[");
                for (pk = 0; pk < BRANCH_NUM; pk = pk + 1)
                    $write("%0d ", branch_generated_token[pk*`TOKEN_ID_W +: `TOKEN_ID_W]);
                $write("]\n");
            end
            // synthesis translate_on
        end
    end
end

endmodule
