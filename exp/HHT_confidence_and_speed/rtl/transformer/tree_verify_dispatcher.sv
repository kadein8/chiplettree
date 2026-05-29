`include "config/interface_params.vh"
`include "config/prediction_params.vh"
`timescale 1ns/1ps

// tree_verify_dispatcher
//
// Implements the tree-parallel verification pipeline:
//   1. FLATTEN: receive tree from tree_builder, flatten into verify window
//   2. MASK:    generate tree_mask (ancestor visibility per slot)
//   3. BATCH:   output batch to transformer (token_ids, positions, tree_mask)
//   4. COMPARE: receive argmax results, find longest matching path per branch
//   5. COMMIT:  output winning branch, depth, bonus token, flush mask
//
// Tree mask semantics:
//   - Slot 0 = seed (sees only itself + committed prefix via KV cache)
//   - Slot i on branch b, level l sees:
//     * Slot 0 (seed)
//     * All ancestor slots on same branch (levels 0..l-1)
//     * Itself
//   - Does NOT see sibling/cousin slots on other branches
//
// Comparator logic:
//   - For each branch, check if model's argmax at parent slot matches draft token
//   - Longest consecutive match = accepted depth
//   - Bonus token = model's prediction after last accepted token

module tree_verify_dispatcher #(
    parameter integer BRANCH_NUM   = `BRANCH_NUM,
    parameter integer MAX_LEVELS   = `MAX_PRIVATE_NODES_PER_BRANCH,
    parameter integer WINDOW_SIZE  = `VERIFY_WINDOW_SIZE,
    parameter integer TOKEN_ID_W   = `TOKEN_ID_W,
    parameter integer POSITION_ID_W = `POSITION_ID_W,
    parameter integer NODE_ID_W    = `NODE_ID_W,
    parameter integer BRANCH_ID_W  = `BRANCH_ID_W,
    parameter integer SLOT_ID_W    = `SLOT_ID_W
) (
    input  logic                          clk,
    input  logic                          rst_n,

    // Tree request from tree_builder
    input  logic                          tree_req_valid,
    output logic                          tree_req_ready,
    input  logic [NODE_ID_W-1:0]          seed_node_id,
    input  logic [TOKEN_ID_W-1:0]         seed_token_id,
    input  logic [POSITION_ID_W-1:0]      seed_position,
    input  logic [BRANCH_NUM-1:0]         branch_valid,
    input  logic [BRANCH_NUM*MAX_LEVELS*NODE_ID_W-1:0]     branch_node_ids,
    input  logic [BRANCH_NUM*MAX_LEVELS*NODE_ID_W-1:0]     branch_parent_node_ids,
    input  logic [BRANCH_NUM*MAX_LEVELS*TOKEN_ID_W-1:0]    branch_draft_tokens,
    input  logic [BRANCH_NUM*MAX_LEVELS*POSITION_ID_W-1:0] branch_draft_positions,
    input  logic [BRANCH_NUM*MAX_LEVELS-1:0]               branch_levels_valid,
    input  logic [15:0]                   committed_prefix_len,

    // Batch output to transformer (layer controller)
    output logic                          batch_out_valid,
    input  logic                          batch_out_ready,
    output logic [4:0]                    batch_out_count,
    output logic [WINDOW_SIZE*32-1:0]     batch_out_token_ids,
    output logic [WINDOW_SIZE*16-1:0]     batch_out_positions,
    output logic [WINDOW_SIZE*WINDOW_SIZE-1:0] batch_out_tree_mask,
    output logic [15:0]                   batch_out_prefix_len,
    output logic                          batch_out_seed_kv_valid,
    output logic [WINDOW_SIZE-1:0]        batch_out_slot_is_seed,

    // Forward results from transformer (argmax token per slot)
    input  logic                          fwd_result_valid,
    output logic                          fwd_result_ready,
    input  logic [4:0]                    fwd_result_count,
    input  logic [WINDOW_SIZE*32-1:0]     fwd_result_token_ids,

    // Commit output
    output logic                          commit_valid,
    output logic [BRANCH_ID_W-1:0]        commit_branch_id,
    output logic [2:0]                    commit_depth,
    output logic [TOKEN_ID_W-1:0]         commit_bonus_token_id,
    output logic [BRANCH_NUM-1:0]         commit_flush_mask,
    output logic [MAX_LEVELS*SLOT_ID_W-1:0] commit_slots,
    output logic [MAX_LEVELS*16-1:0]      commit_slot_positions,

    // Status
    output logic                          busy
);

// =========================================================================
// State machine
// =========================================================================
localparam [2:0]
    ST_IDLE    = 3'd0,
    ST_FLATTEN = 3'd1,
    ST_BATCH   = 3'd2,
    ST_WAIT    = 3'd3,
    ST_COMPARE = 3'd4,
    ST_SELECT  = 3'd5,
    ST_COMMIT  = 3'd6;

logic [2:0] state_r;

// =========================================================================
// Flatten registers: map tree branches into linear window slots
// =========================================================================
// Slot layout: slot 0 = seed, slots 1..WINDOW_SIZE-1 = draft nodes
// Mapping: branch b, level l → slot = 1 + b*MAX_LEVELS + l
logic [TOKEN_ID_W-1:0]    slot_token_r    [0:WINDOW_SIZE-1];
logic [POSITION_ID_W-1:0] slot_position_r [0:WINDOW_SIZE-1];
logic [WINDOW_SIZE-1:0]   slot_valid_r;
logic [4:0]               slot_count_r;

// Per-slot: which branch and level does it belong to
logic [BRANCH_ID_W-1:0]   slot_branch_r [0:WINDOW_SIZE-1];
logic [2:0]                slot_level_r  [0:WINDOW_SIZE-1];

// Tree mask: WINDOW_SIZE x WINDOW_SIZE bit matrix
// tree_mask[i][j] = 1 means slot i can attend to slot j
logic [WINDOW_SIZE*WINDOW_SIZE-1:0] tree_mask_r;

// Comparator results
logic [2:0]               branch_match_depth_r [0:BRANCH_NUM-1];
logic [TOKEN_ID_W-1:0]    branch_bonus_token_r [0:BRANCH_NUM-1];
logic [BRANCH_ID_W-1:0]   best_branch_r;
logic [2:0]               best_depth_r;

// Forward result storage
logic [TOKEN_ID_W-1:0]    fwd_token_r [0:WINDOW_SIZE-1];

// =========================================================================
// Flatten + Mask generation + State machine
// =========================================================================
integer fi, fj, fb, fl;

assign tree_req_ready = tree_req_valid && (state_r == ST_IDLE);
assign fwd_result_ready = (state_r == ST_WAIT);

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state_r <= ST_IDLE;
        busy <= 1'b0;
        batch_out_valid <= 1'b0;
        batch_out_count <= 5'd0;
        batch_out_token_ids <= '0;
        batch_out_positions <= '0;
        batch_out_tree_mask <= '0;
        batch_out_prefix_len <= 16'd0;
        batch_out_seed_kv_valid <= 1'b0;
        batch_out_slot_is_seed <= '0;
        commit_valid <= 1'b0;
        commit_branch_id <= '0;
        commit_depth <= 3'd0;
        commit_bonus_token_id <= '0;
        commit_flush_mask <= '0;
        commit_slots <= '0;
        commit_slot_positions <= '0;
        slot_valid_r <= '0;
        slot_count_r <= 5'd0;
        tree_mask_r <= '0;
        best_branch_r <= '0;
        best_depth_r <= 3'd0;
        for (fi = 0; fi < WINDOW_SIZE; fi = fi + 1) begin
            slot_token_r[fi] <= '0;
            slot_position_r[fi] <= '0;
            slot_branch_r[fi] <= '0;
            slot_level_r[fi] <= 3'd0;
            fwd_token_r[fi] <= '0;
        end
        for (fi = 0; fi < BRANCH_NUM; fi = fi + 1) begin
            branch_match_depth_r[fi] <= 3'd0;
            branch_bonus_token_r[fi] <= '0;
        end
    end else begin
        commit_valid <= 1'b0;
        batch_out_valid <= 1'b0;

        case (state_r)
        // =================================================================
        ST_IDLE: begin
            if (tree_req_valid) begin
                busy <= 1'b1;
                state_r <= ST_FLATTEN;

                // --- Flatten tree into window slots ---
                // Slot 0 = seed
                slot_token_r[0] <= seed_token_id;
                slot_position_r[0] <= seed_position;
                slot_valid_r[0] <= 1'b1;
                slot_branch_r[0] <= '0;
                slot_level_r[0] <= 3'd0;
                // Slots 1..N: draft nodes, layout = branch * MAX_LEVELS + level + 1
                slot_count_r <= 5'd1; // start with seed
                for (fb = 0; fb < BRANCH_NUM; fb = fb + 1) begin
                    for (fl = 0; fl < MAX_LEVELS; fl = fl + 1) begin : flatten_loop
                        integer sidx;
                        sidx = 1 + fb * MAX_LEVELS + fl;
                        if (branch_valid[fb] &&
                            branch_levels_valid[fb*MAX_LEVELS + fl]) begin
                            slot_token_r[sidx] <=
                                branch_draft_tokens[(fb*MAX_LEVELS+fl)*TOKEN_ID_W +: TOKEN_ID_W];
                            slot_position_r[sidx] <=
                                branch_draft_positions[(fb*MAX_LEVELS+fl)*POSITION_ID_W +: POSITION_ID_W];
                            slot_valid_r[sidx] <= 1'b1;
                            slot_branch_r[sidx] <= fb[BRANCH_ID_W-1:0];
                            slot_level_r[sidx] <= fl[2:0];
                        end else begin
                            slot_valid_r[sidx] <= 1'b0;
                            slot_token_r[sidx] <= '0;
                            slot_position_r[sidx] <= '0;
                            slot_branch_r[sidx] <= '0;
                            slot_level_r[sidx] <= 3'd0;
                        end
                    end
                end
            end
        end

        // =================================================================
        ST_FLATTEN: begin
            // Count valid slots (combinational count, assign once)
            begin : count_valid_slots
                integer cnt;
                cnt = 0;
                for (fi = 0; fi < WINDOW_SIZE; fi = fi + 1)
                    if (slot_valid_r[fi]) cnt = cnt + 1;
                slot_count_r <= cnt[4:0];
            end

            // Generate tree mask
            // Rule: slot i sees slot j iff:
            //   (j == 0) [seed always visible] OR
            //   (j == i) [self always visible] OR
            //   (same branch AND j's level < i's level) [ancestor on same branch]
            for (fi = 0; fi < WINDOW_SIZE; fi = fi + 1) begin
                for (fj = 0; fj < WINDOW_SIZE; fj = fj + 1) begin
                    if (!slot_valid_r[fi] || !slot_valid_r[fj]) begin
                        tree_mask_r[fi*WINDOW_SIZE + fj] <= 1'b0;
                    end else if (fj == 0) begin
                        // Everyone sees seed
                        tree_mask_r[fi*WINDOW_SIZE + fj] <= 1'b1;
                    end else if (fi == fj) begin
                        // Self-attention
                        tree_mask_r[fi*WINDOW_SIZE + fj] <= 1'b1;
                    end else if (fi == 0) begin
                        // Seed only sees itself (j!=0 here)
                        tree_mask_r[fi*WINDOW_SIZE + fj] <= 1'b0;
                    end else if (slot_branch_r[fi] == slot_branch_r[fj] &&
                               slot_level_r[fj] < slot_level_r[fi]) begin
                        // Ancestor on same branch (lower level)
                        tree_mask_r[fi*WINDOW_SIZE + fj] <= 1'b1;
                    end else begin
                        // Different branch or not ancestor → invisible
                        tree_mask_r[fi*WINDOW_SIZE + fj] <= 1'b0;
                    end
                end
            end

            state_r <= ST_BATCH;
        end

        // =================================================================
        ST_BATCH: begin
            // Output batch to transformer
            batch_out_valid <= 1'b1;
            batch_out_count <= slot_count_r;
            batch_out_tree_mask <= tree_mask_r;
            batch_out_prefix_len <= committed_prefix_len;
            batch_out_seed_kv_valid <= 1'b1;
            batch_out_slot_is_seed <= {{(WINDOW_SIZE-1){1'b0}}, 1'b1};

            // Pack token_ids and positions into flat buses
            for (fi = 0; fi < WINDOW_SIZE; fi = fi + 1) begin
                batch_out_token_ids[fi*32 +: 32] <=
                    {{(32-TOKEN_ID_W){1'b0}}, slot_token_r[fi]};
                batch_out_positions[fi*16 +: 16] <=
                    {{(16-POSITION_ID_W){1'b0}}, slot_position_r[fi]};
            end

            if (batch_out_ready) begin
                batch_out_valid <= 1'b0;
                state_r <= ST_WAIT;
            end
        end

        // =================================================================
        ST_WAIT: begin
            // Wait for transformer forward results
            if (fwd_result_valid) begin
                // Latch argmax results
                for (fi = 0; fi < WINDOW_SIZE; fi = fi + 1) begin
                    fwd_token_r[fi] <= fwd_result_token_ids[fi*32 +: TOKEN_ID_W];
                end
                state_r <= ST_COMPARE;
            end
        end

        // =================================================================
        ST_COMPARE: begin
            // Comparator: for each branch, find longest prefix match
            // fwd_token_r[parent_slot] should equal draft_token[branch][level]
            //
            // Slot 0 (seed) predicts → should match branch level 0 token
            // Slot (1+b*MAX_LEVELS+l) predicts → should match level l+1 token
            for (fb = 0; fb < BRANCH_NUM; fb = fb + 1) begin
                branch_match_depth_r[fb] <= 3'd0;
                branch_bonus_token_r[fb] <= '0;
            end

            for (fb = 0; fb < BRANCH_NUM; fb = fb + 1) begin : compare_branch
                if (branch_valid[fb]) begin : compare_valid
                    // Level 0: seed (slot 0) predicts → compare with draft level 0
                    // Level l: slot(1+b*MAX_LEVELS+l-1) predicts → compare with draft level l
                    automatic logic match_chain;
                    match_chain = 1'b1;
                    for (fl = 0; fl < MAX_LEVELS; fl = fl + 1) begin : compare_level
                        if (branch_levels_valid[fb*MAX_LEVELS + fl] && match_chain) begin
                            automatic integer parent_slot;
                            automatic logic [TOKEN_ID_W-1:0] predicted_token;
                            automatic logic [TOKEN_ID_W-1:0] draft_token;

                            // Parent slot for level l:
                            //   level 0 → parent is seed (slot 0)
                            //   level l>0 → parent is slot(1 + b*MAX_LEVELS + l-1)
                            if (fl == 0)
                                parent_slot = 0;
                            else
                                parent_slot = 1 + fb*MAX_LEVELS + fl - 1;

                            predicted_token = fwd_token_r[parent_slot];
                            draft_token = branch_draft_tokens[
                                (fb*MAX_LEVELS+fl)*TOKEN_ID_W +: TOKEN_ID_W];

                            if (predicted_token == draft_token) begin
                                branch_match_depth_r[fb] <= fl[2:0] + 3'd1;
                            end else begin
                                // Mismatch: bonus = predicted token at parent
                                branch_bonus_token_r[fb] <= predicted_token;
                                match_chain = 1'b0;
                            end
                        end
                    end
                    // If all levels matched, bonus = prediction at last slot
                    if (match_chain && branch_levels_valid[fb*MAX_LEVELS]) begin
                        automatic integer last_slot;
                        automatic integer last_level;
                        last_level = 0;
                        for (fl = 0; fl < MAX_LEVELS; fl = fl + 1)
                            if (branch_levels_valid[fb*MAX_LEVELS + fl])
                                last_level = fl;
                        last_slot = 1 + fb*MAX_LEVELS + last_level;
                        branch_bonus_token_r[fb] <= fwd_token_r[last_slot];
                    end
                end
            end

            // Find best branch (longest match) — done in next cycle (ST_SELECT)
            // since branch_match_depth_r is updated via NBA in this cycle
            state_r <= ST_SELECT;
        end

        // =================================================================
        ST_SELECT: begin
            // Now branch_match_depth_r has settled; pick best branch
            begin : select_best
                integer sel_b;
                reg [2:0] sel_depth;
                reg [BRANCH_ID_W-1:0] sel_branch;
                sel_depth = 3'd0;
                sel_branch = '0;
                for (sel_b = 0; sel_b < BRANCH_NUM; sel_b = sel_b + 1) begin
                    if (branch_valid[sel_b] &&
                        branch_match_depth_r[sel_b] > sel_depth) begin
                        sel_depth = branch_match_depth_r[sel_b];
                        sel_branch = sel_b[BRANCH_ID_W-1:0];
                    end
                end
                best_depth_r <= sel_depth;
                best_branch_r <= sel_branch;
            end

            state_r <= ST_COMMIT;
        end

        // =================================================================
        ST_COMMIT: begin
            commit_valid <= 1'b1;
            commit_branch_id <= best_branch_r;
            commit_depth <= best_depth_r;
            commit_bonus_token_id <= branch_bonus_token_r[best_branch_r];

            // Flush mask: all branches except winner
            for (fb = 0; fb < BRANCH_NUM; fb = fb + 1)
                commit_flush_mask[fb] <= (fb[BRANCH_ID_W-1:0] != best_branch_r) &&
                                          branch_valid[fb];

            // Commit slots and positions for accepted path
            for (fl = 0; fl < MAX_LEVELS; fl = fl + 1) begin
                commit_slots[fl*SLOT_ID_W +: SLOT_ID_W] <=
                    (fl < best_depth_r) ?
                        (5'd1 + {best_branch_r, fl[1:0]}*5'd1) :  // simplified
                        5'd0;
                commit_slot_positions[fl*16 +: 16] <=
                    (fl < best_depth_r) ?
                        {{(16-POSITION_ID_W){1'b0}},
                         slot_position_r[1 + best_branch_r*MAX_LEVELS + fl]} :
                        16'd0;
            end

            state_r <= ST_IDLE;
            busy <= 1'b0;
        end

        default: state_r <= ST_IDLE;
        endcase
    end
end

endmodule





