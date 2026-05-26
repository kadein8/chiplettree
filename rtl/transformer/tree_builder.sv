`include "config/interface_params.vh"
`include "config/prediction_params.vh"
`timescale 1ns/1ps

// tree_builder
// Collects HHT candidate predictions and organizes them into the
// branch/level structure expected by tree_verify_dispatcher.
//
// Strategy:
//   - Seed token provided externally (from prefill or previous commit).
//   - HHT produces candidates one per cycle (cand_valid).
//   - Each candidate has a parent_node_id; tree_builder assigns to branches:
//     * Parent == seed_node_id → new branch at level 0
//     * Parent == existing branch tip → extend that branch
//     * Otherwise discard
//   - Collection ends on: all slots filled, timeout, or hht_done.
//   - Then tree_req_valid asserted with complete tree structure.

module tree_builder #(
    parameter integer BRANCH_NUM     = `BRANCH_NUM,
    parameter integer MAX_LEVELS     = `MAX_PRIVATE_NODES_PER_BRANCH,
    parameter integer TOKEN_ID_W     = `TOKEN_ID_W,
    parameter integer POSITION_ID_W  = `POSITION_ID_W,
    parameter integer NODE_ID_W      = `NODE_ID_W,
    parameter integer TIMEOUT_CYCLES = 32
) (
    input  logic                          clk,
    input  logic                          rst_n,

    // Control
    input  logic                          start,
    output logic                          done,
    output logic                          busy,

    // Seed info
    input  logic [NODE_ID_W-1:0]          seed_node_id,
    input  logic [TOKEN_ID_W-1:0]         seed_token_id,
    input  logic [POSITION_ID_W-1:0]      seed_position,
    input  logic [15:0]                   committed_prefix_len_in,

    // HHT candidate interface
    input  logic                          cand_valid,
    input  logic [NODE_ID_W-1:0]          cand_parent_node_id,
    input  logic [TOKEN_ID_W-1:0]         cand_token_id,
    input  logic [POSITION_ID_W-1:0]      cand_referenced_position,
    input  logic                          hht_done,

    // HHT speculative lookup (for multi-level tree exploration)
    output logic [TOKEN_ID_W-1:0]         spec_token_0,
    output logic [TOKEN_ID_W-1:0]         spec_token_1,
    output logic                          spec_query_valid,
    input  logic                          spec_hit,
    input  logic [TOKEN_ID_W-1:0]         spec_prediction,

    // Output: tree request to tree_verify_dispatcher
    output logic                          tree_req_valid,
    input  logic                          tree_req_ready,
    output logic [NODE_ID_W-1:0]          out_seed_node_id,
    output logic [TOKEN_ID_W-1:0]         out_seed_token_id,
    output logic [POSITION_ID_W-1:0]      out_seed_position,
    output logic [BRANCH_NUM-1:0]         out_branch_valid,
    output logic [BRANCH_NUM*MAX_LEVELS*NODE_ID_W-1:0]     out_branch_node_ids,
    output logic [BRANCH_NUM*MAX_LEVELS*NODE_ID_W-1:0]     out_branch_parent_node_ids,
    output logic [BRANCH_NUM*MAX_LEVELS*TOKEN_ID_W-1:0]    out_branch_draft_tokens,
    output logic [BRANCH_NUM*MAX_LEVELS*POSITION_ID_W-1:0] out_branch_draft_positions,
    output logic [BRANCH_NUM*MAX_LEVELS-1:0]               out_branch_levels_valid,
    output logic [15:0]                   out_committed_prefix_len
);

    // State encoding
    localparam [1:0] ST_IDLE    = 2'd0,
                     ST_COLLECT = 2'd1,
                     ST_OUTPUT  = 2'd2;

    logic [1:0] state_r;
    logic [15:0] timeout_cnt_r;

    // Branch tracking: tip node_id per branch, current depth per branch
    logic [BRANCH_NUM-1:0]         branch_active_r;
    logic [NODE_ID_W-1:0]          branch_tip_node_r [0:BRANCH_NUM-1];
    logic [2:0]                    branch_depth_r [0:BRANCH_NUM-1];

    // Per-branch token tracking for speculative lookup (packed to avoid VCS bug)
    logic [BRANCH_NUM*TOKEN_ID_W-1:0]  branch_tip_token_r;
    logic [BRANCH_NUM*TOKEN_ID_W-1:0]  branch_prev_token_r;
    logic [1:0]                    explore_branch_r;
    logic                          explore_phase_r; // 0=cand_valid, 1=spec lookup
    logic [1:0]                    spec_wait_r;     // 0=register tokens, 1=query active, 2=check result

    // Storage for tree structure
    logic [BRANCH_NUM*MAX_LEVELS*NODE_ID_W-1:0]     node_ids_r;
    logic [BRANCH_NUM*MAX_LEVELS*NODE_ID_W-1:0]     parent_node_ids_r;
    logic [BRANCH_NUM*MAX_LEVELS*TOKEN_ID_W-1:0]    draft_tokens_r;
    logic [BRANCH_NUM*MAX_LEVELS*POSITION_ID_W-1:0] draft_positions_r;
    logic [BRANCH_NUM*MAX_LEVELS-1:0]               levels_valid_r;

    // Node ID allocator (simple counter)
    logic [NODE_ID_W-1:0] next_node_id_r;

    // Combinational: find which branch a candidate belongs to
    logic found_branch;
    logic [1:0] target_branch;
    logic is_new_branch;
    integer bi;

    always_comb begin
        found_branch = 1'b0;
        target_branch = 2'd0;
        is_new_branch = 1'b0;

        // Check if parent matches any existing branch tip
        for (bi = 0; bi < BRANCH_NUM; bi = bi + 1) begin
            if (branch_active_r[bi] &&
                (cand_parent_node_id == branch_tip_node_r[bi]) &&
                (branch_depth_r[bi] < MAX_LEVELS[2:0])) begin
                found_branch = 1'b1;
                target_branch = bi[1:0];
            end
        end

        // If not found, check if parent is seed (new branch)
        if (!found_branch && (cand_parent_node_id == seed_node_id)) begin
            for (bi = 0; bi < BRANCH_NUM; bi = bi + 1) begin
                if (!branch_active_r[bi] && !found_branch) begin
                    found_branch = 1'b1;
                    target_branch = bi[1:0];
                    is_new_branch = 1'b1;
                end
            end
        end
    end

    // Speculative lookup query: active when spec_wait_r==1 (tokens registered on cycle 0)
    assign spec_query_valid = (state_r == ST_COLLECT) && explore_phase_r && (spec_wait_r == 2'd1);

    // Outputs
    assign out_seed_node_id = seed_node_id;
    assign out_seed_token_id = seed_token_id;
    assign out_seed_position = seed_position;
    assign out_branch_valid = branch_active_r;
    assign out_branch_node_ids = node_ids_r;
    assign out_branch_parent_node_ids = parent_node_ids_r;
    assign out_branch_draft_tokens = draft_tokens_r;
    assign out_branch_draft_positions = draft_positions_r;
    assign out_branch_levels_valid = levels_valid_r;
    assign out_committed_prefix_len = committed_prefix_len_in;

    integer init_i;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_r <= ST_IDLE;
            busy <= 1'b0;
            done <= 1'b0;
            tree_req_valid <= 1'b0;
            timeout_cnt_r <= 16'd0;
            branch_active_r <= {BRANCH_NUM{1'b0}};
            node_ids_r <= '0;
            parent_node_ids_r <= '0;
            draft_tokens_r <= '0;
            draft_positions_r <= '0;
            levels_valid_r <= '0;
            next_node_id_r <= '0;
            explore_branch_r <= 2'd0;
            explore_phase_r <= 1'b0;
            spec_wait_r <= 2'd0;
            for (init_i = 0; init_i < BRANCH_NUM; init_i = init_i + 1) begin
                branch_tip_node_r[init_i] <= '0;
                branch_depth_r[init_i] <= 3'd0;
                branch_tip_token_r[init_i*TOKEN_ID_W +: TOKEN_ID_W] <= '0;
                branch_prev_token_r[init_i*TOKEN_ID_W +: TOKEN_ID_W] <= '0;
            end
        end else begin
            done <= 1'b0;

            case (state_r)
            ST_IDLE: begin
                tree_req_valid <= 1'b0;
                if (start) begin
                    state_r <= ST_COLLECT;
                    busy <= 1'b1;
                    timeout_cnt_r <= 16'd0;
                    branch_active_r <= {BRANCH_NUM{1'b0}};
                    levels_valid_r <= '0;
                    next_node_id_r <= seed_node_id + {{(NODE_ID_W-1){1'b0}}, 1'b1};
                    explore_branch_r <= 2'd0;
                    explore_phase_r <= 1'b0;
                    spec_wait_r <= 2'd0;
                    for (init_i = 0; init_i < BRANCH_NUM; init_i = init_i + 1) begin
                        branch_tip_node_r[init_i] <= '0;
                        branch_depth_r[init_i] <= 3'd0;
                        branch_tip_token_r[init_i*TOKEN_ID_W +: TOKEN_ID_W] <= '0;
                        branch_prev_token_r[init_i*TOKEN_ID_W +: TOKEN_ID_W] <= '0;
                    end
                end
            end

            ST_COLLECT: begin
                timeout_cnt_r <= timeout_cnt_r + 16'd1;

                if (!explore_phase_r) begin
                    // === Phase 0: fill level 0 from HHT cand_valid ===
                    if (cand_valid && found_branch) begin
                        automatic integer flat_idx;
                        flat_idx = target_branch * MAX_LEVELS + branch_depth_r[target_branch];

                        node_ids_r[flat_idx*NODE_ID_W +: NODE_ID_W] <= next_node_id_r;
                        parent_node_ids_r[flat_idx*NODE_ID_W +: NODE_ID_W] <= cand_parent_node_id;
                        draft_tokens_r[flat_idx*TOKEN_ID_W +: TOKEN_ID_W] <= cand_token_id;
                        draft_positions_r[flat_idx*POSITION_ID_W +: POSITION_ID_W] <=
                            seed_position + {{(POSITION_ID_W-3){1'b0}}, branch_depth_r[target_branch]} +
                            {{(POSITION_ID_W-1){1'b0}}, 1'b1};
                        levels_valid_r[flat_idx] <= 1'b1;

                        branch_active_r[target_branch] <= 1'b1;
                        branch_tip_node_r[target_branch] <= next_node_id_r;
                        branch_depth_r[target_branch] <= branch_depth_r[target_branch] + 3'd1;
                        next_node_id_r <= next_node_id_r + {{(NODE_ID_W-1){1'b0}}, 1'b1};
                        // Track tokens for speculative exploration
                        branch_prev_token_r[target_branch*TOKEN_ID_W +: TOKEN_ID_W] <= seed_token_id;
                        branch_tip_token_r[target_branch*TOKEN_ID_W +: TOKEN_ID_W] <= cand_token_id;
                    end

                    // Switch to phase 1 when all branches have level 0, or timeout
                    if (&branch_active_r || (timeout_cnt_r >= 16'd5)) begin
                        explore_phase_r <= 1'b1;
                        explore_branch_r <= 2'd0;
                    end
                end else begin
                    // === Phase 1: extend branches using speculative lookup ===
                    // 3-cycle pattern: 0=register tokens, 1=query active, 2=check result
                    if (spec_wait_r == 2'd0) begin
                        spec_wait_r <= 2'd1;
                        // Register tokens for spec query (in same always_ff to avoid timing issues)
                        spec_token_0 <= branch_prev_token_r[explore_branch_r*TOKEN_ID_W +: TOKEN_ID_W];
                        spec_token_1 <= branch_tip_token_r[explore_branch_r*TOKEN_ID_W +: TOKEN_ID_W];
                    end else if (spec_wait_r == 2'd1) begin
                        spec_wait_r <= 2'd2;
                    end else begin
                        spec_wait_r <= 2'd0;
                        // synthesis translate_off
                        $display("[TB] phase1: br=%0d depth=%0d hit=%b pred=%0d prev=%0d tip=%0d",
                            explore_branch_r, branch_depth_r[explore_branch_r],
                            spec_hit, spec_prediction,
                            branch_prev_token_r[explore_branch_r*TOKEN_ID_W +: TOKEN_ID_W],
                            branch_tip_token_r[explore_branch_r*TOKEN_ID_W +: TOKEN_ID_W]);
                        // synthesis translate_on
                        if (spec_hit && branch_active_r[explore_branch_r] &&
                            branch_depth_r[explore_branch_r] < MAX_LEVELS[2:0]) begin
                            automatic integer flat_idx;
                            flat_idx = explore_branch_r * MAX_LEVELS + branch_depth_r[explore_branch_r];

                            node_ids_r[flat_idx*NODE_ID_W +: NODE_ID_W] <= next_node_id_r;
                            parent_node_ids_r[flat_idx*NODE_ID_W +: NODE_ID_W] <= branch_tip_node_r[explore_branch_r];
                            draft_tokens_r[flat_idx*TOKEN_ID_W +: TOKEN_ID_W] <= spec_prediction;
                            draft_positions_r[flat_idx*POSITION_ID_W +: POSITION_ID_W] <=
                                seed_position + {{(POSITION_ID_W-3){1'b0}}, branch_depth_r[explore_branch_r]} +
                                {{(POSITION_ID_W-1){1'b0}}, 1'b1};
                            levels_valid_r[flat_idx] <= 1'b1;

                            branch_tip_node_r[explore_branch_r] <= next_node_id_r;
                            branch_depth_r[explore_branch_r] <= branch_depth_r[explore_branch_r] + 3'd1;
                            next_node_id_r <= next_node_id_r + {{(NODE_ID_W-1){1'b0}}, 1'b1};
                            branch_prev_token_r[explore_branch_r*TOKEN_ID_W +: TOKEN_ID_W] <= branch_tip_token_r[explore_branch_r*TOKEN_ID_W +: TOKEN_ID_W];
                            branch_tip_token_r[explore_branch_r*TOKEN_ID_W +: TOKEN_ID_W] <= spec_prediction;
                        end else begin
                            if (explore_branch_r == BRANCH_NUM[1:0] - 2'd1) begin
                                state_r <= ST_OUTPUT;
                            end else begin
                                explore_branch_r <= explore_branch_r + 2'd1;
                            end
                        end
                    end
                end

                // Timeout fallback
                if (timeout_cnt_r >= TIMEOUT_CYCLES[15:0]) begin
                    state_r <= ST_OUTPUT;
                end
            end

            ST_OUTPUT: begin
                if (|branch_active_r) begin
                    tree_req_valid <= 1'b1;
                    if (tree_req_ready) begin
                        tree_req_valid <= 1'b0;
                        done <= 1'b1;
                        busy <= 1'b0;
                        state_r <= ST_IDLE;
                    end
                end else begin
                    // No candidates collected, skip verification
                    done <= 1'b1;
                    busy <= 1'b0;
                    state_r <= ST_IDLE;
                end
            end

            default: state_r <= ST_IDLE;
            endcase
        end
    end

endmodule
