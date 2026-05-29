`timescale 1ns/1ps
`include "config/interface_params.vh"
`include "config/prediction_params.vh"
`include "config/model_params.vh"
`include "config/memory_params.vh"

// tree_to_native_bridge
//
// Converts tree_builder output (flat branch arrays) into the native tree
// request format expected by StrictTreeMaskPaperPath.
//
// tree_builder output:
//   - branch_valid[BRANCH_NUM-1:0]
//   - branch_node_ids[BRANCH_NUM*MAX_LEVELS*NODE_ID_W-1:0]
//   - branch_parent_node_ids[...]
//   - branch_draft_tokens[BRANCH_NUM*MAX_LEVELS*TOKEN_ID_W-1:0]
//   - branch_draft_positions[BRANCH_NUM*MAX_LEVELS*POSITION_ID_W-1:0]
//   - branch_levels_valid[BRANCH_NUM*MAX_LEVELS-1:0]
//   - seed_node_id, seed_token_id, seed_position
//   - committed_prefix_len
//
// StrictTreeMaskPaperPath input:
//   - src_prefix_slot_valid[TREE_MAX_PREFIX_NODES-1:0]
//   - src_prefix_node_id, src_prefix_token_id, src_prefix_position_id
//   - src_committed_len
//   - src_frontier_level_valid[TREE_MAX_FRONTIER_LEVELS-1:0]
//   - src_frontier_slot_valid[LEVELS*SLOTS-1:0]
//   - src_frontier_node_id, parent_node_id, token_id, etc.
//
// The bridge maps:
//   prefix = [seed] (committed tokens are already in KV, only seed is new prefix)
//   frontier = branch draft tokens organized by level

module tree_to_native_bridge #(
    parameter integer BRANCH_NUM  = `BRANCH_NUM,
    parameter integer MAX_LEVELS  = `MAX_PRIVATE_NODES_PER_BRANCH,
    parameter integer NODE_ID_W   = `NODE_ID_W,
    parameter integer TOKEN_ID_W  = `TOKEN_ID_W,
    parameter integer POSITION_ID_W = `POSITION_ID_W,
    parameter integer BRANCH_ID_W = `BRANCH_ID_W,
    parameter integer TREE_LEVEL_ID_W = `TREE_LEVEL_ID_W,
    parameter integer TREE_MAX_PREFIX_NODES = `TREE_MAX_PREFIX_NODES,
    parameter integer TREE_MAX_FRONTIER_LEVELS = `TREE_MAX_FRONTIER_LEVELS,
    parameter integer TREE_FRONTIER_SLOTS = `TREE_FRONTIER_SLOTS
) (
    input                              clk,
    input                              rst_n,

    // --- Input from tree_builder ---
    input                              tree_req_valid,
    output reg                         tree_req_ready,
    input  [NODE_ID_W-1:0]            seed_node_id,
    input  [TOKEN_ID_W-1:0]           seed_token_id,
    input  [POSITION_ID_W-1:0]        seed_position,
    input  [BRANCH_NUM-1:0]           branch_valid,
    input  [BRANCH_NUM*MAX_LEVELS*NODE_ID_W-1:0]     branch_node_ids,
    input  [BRANCH_NUM*MAX_LEVELS*NODE_ID_W-1:0]     branch_parent_node_ids,
    input  [BRANCH_NUM*MAX_LEVELS*TOKEN_ID_W-1:0]    branch_draft_tokens,
    input  [BRANCH_NUM*MAX_LEVELS*POSITION_ID_W-1:0] branch_draft_positions,
    input  [BRANCH_NUM*MAX_LEVELS-1:0]               branch_levels_valid,
    input  [15:0]                      committed_prefix_len,

    // --- Output to StrictTreeMaskPaperPath ---
    output reg                         req_valid,
    input                              req_ready,
    output reg [`REQ_ID_W-1:0]         req_id,

    // Prefix (seed token only — committed prefix KV already cached)
    output reg [TREE_MAX_PREFIX_NODES-1:0]                    prefix_slot_valid,
    output reg [TREE_MAX_PREFIX_NODES*NODE_ID_W-1:0]          prefix_node_id,
    output reg [TREE_MAX_PREFIX_NODES*TOKEN_ID_W-1:0]         prefix_token_id,
    output reg [TREE_MAX_PREFIX_NODES*POSITION_ID_W-1:0]      prefix_position_id,
    output reg [POSITION_ID_W-1:0]                            committed_len,

    // Frontier (draft tokens organized by level)
    output reg [TREE_MAX_FRONTIER_LEVELS-1:0]                 frontier_level_valid,
    output reg [TREE_MAX_FRONTIER_LEVELS*TREE_FRONTIER_SLOTS-1:0]
                                                              frontier_slot_valid,
    output reg [TREE_MAX_FRONTIER_LEVELS*TREE_FRONTIER_SLOTS*NODE_ID_W-1:0]
                                                              frontier_node_id,
    output reg [TREE_MAX_FRONTIER_LEVELS*TREE_FRONTIER_SLOTS*NODE_ID_W-1:0]
                                                              frontier_parent_node_id,
    output reg [TREE_MAX_FRONTIER_LEVELS*TREE_FRONTIER_SLOTS*TOKEN_ID_W-1:0]
                                                              frontier_token_id,
    output reg [TREE_MAX_FRONTIER_LEVELS*TREE_FRONTIER_SLOTS*TOKEN_ID_W-1:0]
                                                              frontier_referenced_token_id,
    output reg [TREE_MAX_FRONTIER_LEVELS*TREE_FRONTIER_SLOTS*POSITION_ID_W-1:0]
                                                              frontier_position_id,
    output reg [TREE_MAX_FRONTIER_LEVELS*TREE_FRONTIER_SLOTS*POSITION_ID_W-1:0]
                                                              frontier_referenced_position_id,
    output reg [TREE_MAX_FRONTIER_LEVELS*TREE_FRONTIER_SLOTS*BRANCH_ID_W-1:0]
                                                              frontier_branch_id,
    output reg [TREE_MAX_FRONTIER_LEVELS*TREE_FRONTIER_SLOTS*TREE_LEVEL_ID_W-1:0]
                                                              frontier_level_id,
    output reg [TREE_MAX_FRONTIER_LEVELS*TREE_FRONTIER_SLOTS-1:0]
                                                              frontier_tree_mask_en,

    // Done signal
    output reg                         done
);

// =========================================================================
// Conversion logic
// =========================================================================
// The tree_builder produces a flat array per branch:
//   branch b, level l → index = b*MAX_LEVELS + l
//
// StrictTreeMaskPaperPath expects:
//   prefix: committed tokens (we only pass seed as prefix[0])
//   frontier: organized by level, each level has TREE_FRONTIER_SLOTS slots
//     level 0: all branches' depth-0 nodes
//     level 1: all branches' depth-1 nodes
//     ...
//
// Mapping: frontier[level][slot] where slot = branch_id

localparam integer SLOTS = TREE_FRONTIER_SLOTS;
localparam integer LEVELS = TREE_MAX_FRONTIER_LEVELS;

integer bi, li;
integer flat_idx;

// FSM: IDLE → CONVERT → OUTPUT
localparam [1:0] ST_IDLE = 2'd0, ST_CONVERT = 2'd1, ST_OUTPUT = 2'd2;
reg [1:0] state_r;
reg [`REQ_ID_W-1:0] req_id_r;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state_r <= ST_IDLE;
        tree_req_ready <= 1'b0;  // don't pre-assert on reset
        req_valid <= 1'b0;
        done <= 1'b0;
        req_id_r <= '0;
        req_id <= '0;
        prefix_slot_valid <= '0;
        prefix_node_id <= '0;
        prefix_token_id <= '0;
        prefix_position_id <= '0;
        committed_len <= '0;
        frontier_level_valid <= '0;
        frontier_slot_valid <= '0;
        frontier_node_id <= '0;
        frontier_parent_node_id <= '0;
        frontier_token_id <= '0;
        frontier_referenced_token_id <= '0;
        frontier_position_id <= '0;
        frontier_referenced_position_id <= '0;
        frontier_branch_id <= '0;
        frontier_level_id <= '0;
        frontier_tree_mask_en <= '0;
    end else begin
        done <= 1'b0;
        // NOTE: do NOT default-clear req_valid here — it must stay high in ST_OUTPUT
        //       until the handshake completes on the NEXT cycle.

        case (state_r)
        ST_IDLE: begin
            req_valid <= 1'b0;  // only clear in IDLE
            // IMPORTANT: only assert ready one cycle AFTER seeing valid.
            // The tree_builder clears tree_req_valid on the same cycle if ready
            // is pre-asserted (last-assignment-wins in its always block).
            if (tree_req_valid && !tree_req_ready) begin
                tree_req_ready <= 1'b1;  // assert ready next cycle
            end else if (tree_req_valid && tree_req_ready) begin
                tree_req_ready <= 1'b0;
                state_r <= ST_CONVERT;
                req_id_r <= req_id_r + {{(`REQ_ID_W-1){1'b0}}, 1'b1};
            end else begin
                tree_req_ready <= 1'b0;  // don't pre-assert
            end
        end

        ST_CONVERT: begin
            // --- Build prefix: just the seed token ---
            prefix_slot_valid <= {{(TREE_MAX_PREFIX_NODES-1){1'b0}}, 1'b1};
            prefix_node_id[NODE_ID_W-1:0] <= seed_node_id;
            prefix_token_id[TOKEN_ID_W-1:0] <= seed_token_id;
            prefix_position_id[POSITION_ID_W-1:0] <= seed_position;
            committed_len <= committed_prefix_len[POSITION_ID_W-1:0];

            // --- Build frontier: level-major layout ---
            // Clear all first
            frontier_level_valid <= '0;
            frontier_slot_valid <= '0;
            frontier_node_id <= '0;
            frontier_parent_node_id <= '0;
            frontier_token_id <= '0;
            frontier_referenced_token_id <= '0;
            frontier_position_id <= '0;
            frontier_referenced_position_id <= '0;
            frontier_branch_id <= '0;
            frontier_level_id <= '0;
            frontier_tree_mask_en <= '0;

            // Fill frontier: for each level, place each branch's node at slot=branch_id
            for (li = 0; li < MAX_LEVELS && li < LEVELS; li = li + 1) begin
                for (bi = 0; bi < BRANCH_NUM && bi < SLOTS; bi = bi + 1) begin
                    flat_idx = bi * MAX_LEVELS + li;
                    if (branch_valid[bi] && branch_levels_valid[flat_idx]) begin
                        frontier_level_valid[li] <= 1'b1;
                        frontier_slot_valid[li*SLOTS + bi] <= 1'b1;
                        frontier_node_id[(li*SLOTS + bi)*NODE_ID_W +: NODE_ID_W] <=
                            branch_node_ids[flat_idx*NODE_ID_W +: NODE_ID_W];
                        frontier_parent_node_id[(li*SLOTS + bi)*NODE_ID_W +: NODE_ID_W] <=
                            branch_parent_node_ids[flat_idx*NODE_ID_W +: NODE_ID_W];
                        frontier_token_id[(li*SLOTS + bi)*TOKEN_ID_W +: TOKEN_ID_W] <=
                            branch_draft_tokens[flat_idx*TOKEN_ID_W +: TOKEN_ID_W];
                        frontier_position_id[(li*SLOTS + bi)*POSITION_ID_W +: POSITION_ID_W] <=
                            branch_draft_positions[flat_idx*POSITION_ID_W +: POSITION_ID_W];
                        frontier_branch_id[(li*SLOTS + bi)*BRANCH_ID_W +: BRANCH_ID_W] <=
                            bi[BRANCH_ID_W-1:0];
                        frontier_level_id[(li*SLOTS + bi)*TREE_LEVEL_ID_W +: TREE_LEVEL_ID_W] <=
                            li[TREE_LEVEL_ID_W-1:0];
                        frontier_tree_mask_en[li*SLOTS + bi] <= 1'b1;
                    end
                end
            end

            state_r <= ST_OUTPUT;
        end

        ST_OUTPUT: begin
            req_valid <= 1'b1;
            req_id <= req_id_r;
            // Only check req_ready on the cycle AFTER req_valid is first asserted.
            // Use req_valid itself as the "already asserted" indicator (it was 0 before).
            if (req_valid && req_ready) begin
                req_valid <= 1'b0;
                done <= 1'b1;
                state_r <= ST_IDLE;
                // synthesis translate_off
                $display("[BRIDGE] native tree request sent: req_id=%0d levels=%b",
                    req_id_r, frontier_level_valid);
                // synthesis translate_on
            end
        end

        default: state_r <= ST_IDLE;
        endcase
    end
end

endmodule
