`include "config/interface_params.vh"
`include "config/prediction_params.vh"
`include "config/model_params.vh"
`include "tree_control/tree_flatten.v"
`timescale 1ns/1ps

module tree_verify_dispatcher #(
    parameter integer BRANCH_NUM = `BRANCH_NUM,
    parameter integer MAX_LEVELS = `MAX_PRIVATE_NODES_PER_BRANCH,
    parameter integer WINDOW_SIZE = `VERIFY_WINDOW_SIZE,
    parameter integer TOKEN_ID_W = `TOKEN_ID_W,
    parameter integer POSITION_ID_W = `POSITION_ID_W,
    parameter integer BRANCH_ID_W = `BRANCH_ID_W,
    parameter integer SLOT_ID_W = `SLOT_ID_W,
    parameter integer ADDR_W = `SRAM_ADDR_W
) (
    input  logic clk,
    input  logic rst_n,

    // --- Tree input (from NativeTreeMainFrontend or stimulus) ---
    input  logic                          tree_req_valid,
    output logic                          tree_req_ready,
    input  logic [`NODE_ID_W-1:0]         seed_node_id,
    input  logic [TOKEN_ID_W-1:0]         seed_token_id,
    input  logic [POSITION_ID_W-1:0]      seed_position,
    input  logic [BRANCH_NUM-1:0]         branch_valid,
    input  logic [BRANCH_NUM*MAX_LEVELS*`NODE_ID_W-1:0] branch_node_ids,
    input  logic [BRANCH_NUM*MAX_LEVELS*`NODE_ID_W-1:0] branch_parent_node_ids,
    input  logic [BRANCH_NUM*MAX_LEVELS*TOKEN_ID_W-1:0] branch_draft_tokens,
    input  logic [BRANCH_NUM*MAX_LEVELS*POSITION_ID_W-1:0] branch_draft_positions,
    input  logic [BRANCH_NUM*MAX_LEVELS-1:0] branch_levels_valid,
    input  logic [15:0]                   committed_prefix_len,

    // --- Batch forward interface (to fp16_inference_top) ---
    output logic                          batch_out_valid,
    input  logic                          batch_out_ready,
    output logic [4:0]                    batch_out_count,
    output logic [WINDOW_SIZE*32-1:0]     batch_out_token_ids,
    output logic [WINDOW_SIZE*16-1:0]     batch_out_positions,
    output logic [WINDOW_SIZE*WINDOW_SIZE-1:0] batch_out_tree_mask,
    output logic [15:0]                   batch_out_prefix_len,
    output logic                          batch_out_seed_kv_valid,
    output logic [WINDOW_SIZE-1:0]        batch_out_slot_is_seed,

    // --- Forward results (from fp16_inference_top) ---
    input  logic                          fwd_result_valid,
    output logic                          fwd_result_ready,
    input  logic [4:0]                    fwd_result_count,
    input  logic [WINDOW_SIZE*32-1:0]     fwd_result_token_ids,

    // --- Commit output ---
    output logic                          commit_valid,
    output logic [BRANCH_ID_W-1:0]        commit_branch_id,
    output logic [2:0]                    commit_depth,
    output logic [TOKEN_ID_W-1:0]         commit_bonus_token_id,
    output logic [BRANCH_NUM-1:0]         commit_flush_mask,
    output logic [MAX_LEVELS*SLOT_ID_W-1:0] commit_slots,
    output logic [MAX_LEVELS*16-1:0]      commit_slot_positions,

    // --- Status ---
    output logic                          busy
);

    // =========================================================================
    // State encoding
    // =========================================================================
    localparam [2:0] ST_IDLE     = 3'd0,
                     ST_FLATTEN  = 3'd1,
                     ST_GEN_MASK = 3'd2,
                     ST_DISPATCH = 3'd3,
                     ST_WAIT_FWD = 3'd4,
                     ST_COMPARE  = 3'd5,
                     ST_COMMIT   = 3'd6,
                     ST_DONE     = 3'd7;

    logic [2:0] state, state_next;

    // =========================================================================
    // Latched tree inputs
    // =========================================================================
    logic [`NODE_ID_W-1:0]                          lat_seed_node_id;
    logic [TOKEN_ID_W-1:0]                         lat_seed_token_id;
    logic [POSITION_ID_W-1:0]                      lat_seed_position;
    logic [BRANCH_NUM-1:0]                         lat_branch_valid;
    logic [BRANCH_NUM*MAX_LEVELS*`NODE_ID_W-1:0]   lat_branch_node_ids;
    logic [BRANCH_NUM*MAX_LEVELS*`NODE_ID_W-1:0]   lat_branch_parent_node_ids;
    logic [BRANCH_NUM*MAX_LEVELS*TOKEN_ID_W-1:0]   lat_branch_draft_tokens;
    logic [BRANCH_NUM*MAX_LEVELS*POSITION_ID_W-1:0] lat_branch_draft_positions;
    logic [BRANCH_NUM*MAX_LEVELS-1:0]              lat_branch_levels_valid;
    logic [15:0]                                   lat_committed_prefix_len;

    // =========================================================================
    // tree_flatten outputs (combinational, latched in ST_FLATTEN)
    // =========================================================================
    wire [4:0]                                     flat_unique_slot_count;
    wire [WINDOW_SIZE*TOKEN_ID_W-1:0]              flat_slot_token_id;
    wire [WINDOW_SIZE*POSITION_ID_W-1:0]           flat_slot_position;
    wire [WINDOW_SIZE*SLOT_ID_W-1:0]               flat_slot_parent_slot;
    wire [WINDOW_SIZE-1:0]                         flat_slot_is_seed;
    wire [BRANCH_NUM*MAX_LEVELS*SLOT_ID_W-1:0]     flat_branch_slot_map;

    // Latched flatten results
    logic [4:0]                                    lat_slot_count;
    logic [WINDOW_SIZE*TOKEN_ID_W-1:0]             lat_slot_token_id;
    logic [WINDOW_SIZE*POSITION_ID_W-1:0]          lat_slot_position;
    logic [WINDOW_SIZE*SLOT_ID_W-1:0]              lat_slot_parent_slot;
    logic [WINDOW_SIZE-1:0]                        lat_slot_is_seed;
    logic [BRANCH_NUM*MAX_LEVELS*SLOT_ID_W-1:0]    lat_branch_slot_map;

    // =========================================================================
    // Mask generator output (combinational, latched in ST_GEN_MASK)
    // =========================================================================
    logic [WINDOW_SIZE*WINDOW_SIZE-1:0]            gen_tree_mask;
    logic [WINDOW_SIZE*WINDOW_SIZE-1:0]            lat_tree_mask;

    // =========================================================================
    // Forward result latch
    // =========================================================================
    logic [4:0]                                    lat_fwd_count;
    logic [WINDOW_SIZE*32-1:0]                     lat_fwd_token_ids;

    // =========================================================================
    // Comparator results (simple per-slot match)
    // =========================================================================
    logic [BRANCH_ID_W-1:0]                        cmp_best_branch;
    logic [2:0]                                    cmp_best_depth;
    logic [TOKEN_ID_W-1:0]                         cmp_bonus_token;
    logic [BRANCH_NUM-1:0]                         cmp_flush_mask;
    logic [MAX_LEVELS*SLOT_ID_W-1:0]               cmp_commit_slots;
    logic [MAX_LEVELS*16-1:0]                      cmp_commit_slot_positions;

    // =========================================================================
    // tree_flatten instantiation (combinational)
    // =========================================================================
    tree_flatten #(
        .BRANCH_NUM   (BRANCH_NUM),
        .MAX_LEVELS   (MAX_LEVELS),
        .WINDOW_SIZE  (WINDOW_SIZE),
        .TOKEN_ID_W   (TOKEN_ID_W),
        .POSITION_ID_W(POSITION_ID_W),
        .NODE_ID_W    (`NODE_ID_W),
        .SLOT_ID_W    (SLOT_ID_W)
    ) u_tree_flatten (
        .clk                  (clk),
        .rst_n                (rst_n),
        .seed_node_id         (lat_seed_node_id),
        .seed_token_id        (lat_seed_token_id),
        .seed_position        (lat_seed_position),
        .branch_valid(lat_branch_valid),
        .branch_node_ids(lat_branch_node_ids),
        .branch_parent_node_ids(lat_branch_parent_node_ids),
        .branch_draft_tokens(lat_branch_draft_tokens),
        .branch_draft_positions(lat_branch_draft_positions),
        .branch_levels_valid(lat_branch_levels_valid),
        .unique_slot_count(flat_unique_slot_count),
        .slot_token_id(flat_slot_token_id),
        .slot_position(flat_slot_position),
        .slot_parent_slot(flat_slot_parent_slot),
        .slot_is_seed(flat_slot_is_seed),
        .branch_slot_map(flat_branch_slot_map)
    );

    // =========================================================================
    // Inline tree mask generator (parent-chain walk)
    // For each slot i, mark slot j as visible if j is an ancestor of i
    // (walk parent_slot chain from i back to root) or j == i (self).
    // Also, all slots see the seed (slot 0) via the committed prefix.
    // =========================================================================
    localparam [SLOT_ID_W-1:0] PARENT_INVALID = {SLOT_ID_W{1'b1}};

    integer mi, mj, mstep;
    logic [SLOT_ID_W-1:0] walk_cursor;

    // Use explicit source sensitivities so temporary walk/comparison variables
    // do not self-trigger zero-delay reevaluation in VCS.
    always @(lat_slot_count or lat_slot_parent_slot) begin : mask_gen_logic
        gen_tree_mask = {WINDOW_SIZE*WINDOW_SIZE{1'b0}};
        for (mi = 0; mi < WINDOW_SIZE; mi = mi + 1) begin
            if (mi < lat_slot_count) begin
                // Self-attention: slot sees itself
                gen_tree_mask[mi*WINDOW_SIZE + mi] = 1'b1;
                // All draft slots can see the seed (slot 0)
                gen_tree_mask[mi*WINDOW_SIZE + 0] = 1'b1;
                // Walk parent chain
                walk_cursor = lat_slot_parent_slot[mi*SLOT_ID_W +: SLOT_ID_W];
                for (mstep = 0; mstep < MAX_LEVELS; mstep = mstep + 1) begin
                    if (walk_cursor != PARENT_INVALID &&
                        walk_cursor < lat_slot_count[SLOT_ID_W-1:0]) begin
                        gen_tree_mask[mi*WINDOW_SIZE + walk_cursor] = 1'b1;
                        walk_cursor = lat_slot_parent_slot[walk_cursor*SLOT_ID_W +: SLOT_ID_W];
                    end
                end
            end
        end
    end

    // =========================================================================
    // Inline comparator logic
    // For each branch, walk its slot map and compare forward result tokens
    // against the draft tokens. Find the branch with the longest accepted prefix.
    // The bonus token is the model's prediction at the first mismatch point.
    // =========================================================================
    integer ci, cb, cl;
    logic [BRANCH_ID_W-1:0] best_branch;
    logic [2:0]             best_depth;
    logic [TOKEN_ID_W-1:0]  bonus_token;
    logic [2:0]             branch_accept_depth [0:BRANCH_NUM-1];
    logic [2:0]             branch_total_depth [0:BRANCH_NUM-1];
    logic [SLOT_ID_W-1:0]   cur_slot_idx;
    logic [SLOT_ID_W-1:0]   winner_last_slot_idx;
    logic [SLOT_ID_W-1:0]   winner_predict_slot_idx;
    logic [TOKEN_ID_W-1:0]  draft_tok;
    logic [TOKEN_ID_W-1:0]  model_tok;
    logic                   mismatch_found;
    logic                   winner_has_unaccepted_suffix;

    always @(lat_branch_valid or lat_branch_levels_valid or lat_branch_slot_map or
             lat_slot_token_id or lat_fwd_token_ids) begin : comparator_logic
        best_branch = {BRANCH_ID_W{1'b0}};
        best_depth  = 3'd0;
        bonus_token = {TOKEN_ID_W{1'b0}};
        winner_last_slot_idx = {SLOT_ID_W{1'b0}};
        winner_predict_slot_idx = {SLOT_ID_W{1'b0}};

        for (cb = 0; cb < BRANCH_NUM; cb = cb + 1) begin
            branch_accept_depth[cb] = 3'd0;
            branch_total_depth[cb] = 3'd0;
        end

        // For each branch, check how many consecutive levels match
        for (cb = 0; cb < BRANCH_NUM; cb = cb + 1) begin
            if (lat_branch_valid[cb]) begin
                mismatch_found = 1'b0;
                for (cl = 0; cl < MAX_LEVELS; cl = cl + 1) begin
                    if (!mismatch_found && lat_branch_levels_valid[cb*MAX_LEVELS + cl]) begin
                        branch_total_depth[cb] = cl[2:0] + 3'd1;
                        // Get the slot index for this branch/level
                        cur_slot_idx = lat_branch_slot_map[(cb*MAX_LEVELS + cl)*SLOT_ID_W +: SLOT_ID_W];
                        // Draft token at this node
                        draft_tok = lat_slot_token_id[cur_slot_idx*TOKEN_ID_W +: TOKEN_ID_W];
                        // Model's output for the parent slot (shifted by 1):
                        // The model predicts the next token given the parent context.
                        // For level 0, parent is seed (slot 0), so model output is at slot 0.
                        // For level L, model output is at the slot of level L-1.
                        if (cl == 0) begin
                            model_tok = lat_fwd_token_ids[0 +: TOKEN_ID_W];
                        end else begin
                            model_tok = lat_fwd_token_ids[
                                lat_branch_slot_map[(cb*MAX_LEVELS + (cl-1))*SLOT_ID_W +: SLOT_ID_W]
                                * 32 +: TOKEN_ID_W];
                        end

                        if (draft_tok == model_tok[TOKEN_ID_W-1:0]) begin
                            branch_accept_depth[cb] = cl[2:0] + 3'd1;
                        end else begin
                            mismatch_found = 1'b1;
                        end
                    end
                end
            end
        end

        // Select best branch (highest accepted depth)
        for (cb = 0; cb < BRANCH_NUM; cb = cb + 1) begin
            if (branch_accept_depth[cb] > best_depth) begin
                best_depth  = branch_accept_depth[cb];
                best_branch = cb[BRANCH_ID_W-1:0];
            end
        end

        // Bonus token is the prediction produced by the context immediately
        // before the first rejected node, or by the last accepted node if all
        // visible branch nodes matched.
        if (best_depth > 3'd0) begin
            winner_last_slot_idx = lat_branch_slot_map[
                (best_branch*MAX_LEVELS + best_depth - 1)*SLOT_ID_W +: SLOT_ID_W];
            winner_predict_slot_idx = winner_last_slot_idx;
            if (branch_total_depth[best_branch] > best_depth) begin
                if (best_depth == 3'd0) begin
                    winner_predict_slot_idx = {SLOT_ID_W{1'b0}};
                end else begin
                    winner_predict_slot_idx = winner_last_slot_idx;
                end
            end
            bonus_token =
                lat_fwd_token_ids[winner_predict_slot_idx*32 +: TOKEN_ID_W];
        end else begin
            // No match at all: bonus is model's prediction for seed
            bonus_token = lat_fwd_token_ids[0 +: TOKEN_ID_W];
        end
    end

    // Derive flush mask and commit slots from comparator results
    always @(best_branch or best_depth or bonus_token or branch_total_depth or
             lat_branch_valid or lat_branch_slot_map or lat_slot_position)
        begin : commit_derive_logic
        cmp_best_branch = best_branch;
        cmp_best_depth  = best_depth;
        cmp_bonus_token = bonus_token;

        winner_has_unaccepted_suffix = 1'b0;
        if (best_branch < BRANCH_NUM) begin
            winner_has_unaccepted_suffix =
                (branch_total_depth[best_branch] > best_depth);
        end

        // Flush all non-winner branches. If the winner has deeper unaccepted
        // levels, mark it too so downstream selective flush can drop the
        // loser suffix while preserving accepted-prefix liveness separately.
        cmp_flush_mask = lat_branch_valid;
        if (winner_has_unaccepted_suffix) begin
            cmp_flush_mask[best_branch] = 1'b1;
        end else begin
            cmp_flush_mask[best_branch] = 1'b0;
        end

        // Collect winner's accepted slot indices
        cmp_commit_slots = {MAX_LEVELS*SLOT_ID_W{1'b0}};
        cmp_commit_slot_positions = {MAX_LEVELS*16{1'b0}};
        for (ci = 0; ci < MAX_LEVELS; ci = ci + 1) begin
            if (ci < best_depth) begin
                cmp_commit_slots[ci*SLOT_ID_W +: SLOT_ID_W] =
                    lat_branch_slot_map[(best_branch*MAX_LEVELS + ci)*SLOT_ID_W +: SLOT_ID_W];
                cur_slot_idx =
                    lat_branch_slot_map[(best_branch*MAX_LEVELS + ci)*SLOT_ID_W +: SLOT_ID_W];
                cmp_commit_slot_positions[ci*16 +: 16] =
                    {{(16-POSITION_ID_W){1'b0}},
                     lat_slot_position[cur_slot_idx*POSITION_ID_W +: POSITION_ID_W]};
            end
        end
    end

    // =========================================================================
    // State machine
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            state <= ST_IDLE;
        else
            state <= state_next;
    end

    always @(*) begin : fsm_next_state
        state_next = state;
        case (state)
            ST_IDLE:     if (tree_req_valid)    state_next = ST_FLATTEN;
            ST_FLATTEN:                         state_next = ST_GEN_MASK;
            ST_GEN_MASK:                        state_next = ST_DISPATCH;
            ST_DISPATCH: if (batch_out_ready)   state_next = ST_WAIT_FWD;
            ST_WAIT_FWD: if (fwd_result_valid)  state_next = ST_COMPARE;
            ST_COMPARE:                         state_next = ST_COMMIT;
            ST_COMMIT:                          state_next = ST_DONE;
            ST_DONE:                            state_next = ST_IDLE;
            default:                            state_next = ST_IDLE;
        endcase
    end

    // =========================================================================
    // Datapath registers
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lat_seed_node_id        <= {`NODE_ID_W{1'b0}};
            lat_seed_token_id       <= {TOKEN_ID_W{1'b0}};
            lat_seed_position       <= {POSITION_ID_W{1'b0}};
            lat_branch_valid        <= {BRANCH_NUM{1'b0}};
            lat_branch_node_ids     <= {BRANCH_NUM*MAX_LEVELS*`NODE_ID_W{1'b0}};
            lat_branch_parent_node_ids <=
                {BRANCH_NUM*MAX_LEVELS*`NODE_ID_W{1'b0}};
            lat_branch_draft_tokens <= {BRANCH_NUM*MAX_LEVELS*TOKEN_ID_W{1'b0}};
            lat_branch_draft_positions <= {BRANCH_NUM*MAX_LEVELS*POSITION_ID_W{1'b0}};
            lat_branch_levels_valid <= {BRANCH_NUM*MAX_LEVELS{1'b0}};
            lat_committed_prefix_len <= 16'd0;
            lat_slot_count          <= 5'd0;
            lat_slot_token_id       <= {WINDOW_SIZE*TOKEN_ID_W{1'b0}};
            lat_slot_position       <= {WINDOW_SIZE*POSITION_ID_W{1'b0}};
            lat_slot_parent_slot    <= {WINDOW_SIZE*SLOT_ID_W{1'b0}};
            lat_slot_is_seed        <= {WINDOW_SIZE{1'b0}};
            lat_branch_slot_map     <= {BRANCH_NUM*MAX_LEVELS*SLOT_ID_W{1'b0}};

            lat_tree_mask           <= {WINDOW_SIZE*WINDOW_SIZE{1'b0}};

            lat_fwd_count           <= 5'd0;
            lat_fwd_token_ids       <= {WINDOW_SIZE*32{1'b0}};
        end else begin
            case (state)
                ST_IDLE: begin
                    if (tree_req_valid) begin
                        lat_seed_node_id        <= seed_node_id;
                        lat_seed_token_id       <= seed_token_id;
                        lat_seed_position       <= seed_position;
                        lat_branch_valid        <= branch_valid;
                        lat_branch_node_ids     <= branch_node_ids;
                        lat_branch_parent_node_ids <= branch_parent_node_ids;
                        lat_branch_draft_tokens <= branch_draft_tokens;
                        lat_branch_draft_positions <= branch_draft_positions;
                        lat_branch_levels_valid <= branch_levels_valid;
                        lat_committed_prefix_len <= committed_prefix_len;
                    end
                end

                ST_FLATTEN: begin
                    lat_slot_count       <= flat_unique_slot_count;
                    lat_slot_token_id    <= flat_slot_token_id;
                    lat_slot_position    <= flat_slot_position;
                    lat_slot_parent_slot <= flat_slot_parent_slot;
                    lat_slot_is_seed     <= flat_slot_is_seed;
                    lat_branch_slot_map  <= flat_branch_slot_map;
                end

                ST_GEN_MASK: begin
                    lat_tree_mask <= gen_tree_mask;
                end

                ST_WAIT_FWD: begin
                    if (fwd_result_valid) begin
                        lat_fwd_count     <= fwd_result_count;
                        lat_fwd_token_ids <= fwd_result_token_ids;
                    end
                end

                default: ;
            endcase
        end
    end

    // =========================================================================
    // Output assignments
    // =========================================================================

    // Handshake
    assign tree_req_ready = (state == ST_IDLE);
    assign busy           = (state != ST_IDLE);

    // Batch forward output
    assign batch_out_valid        = (state == ST_DISPATCH);
    assign batch_out_count        = lat_slot_count;
    assign batch_out_prefix_len   = lat_committed_prefix_len;
    assign batch_out_seed_kv_valid = 1'b1;
    assign batch_out_slot_is_seed = lat_slot_is_seed;
    assign batch_out_tree_mask    = lat_tree_mask;

    // Zero-extend token IDs from TOKEN_ID_W to 32 bits for batch output
    genvar gi;
    generate
        for (gi = 0; gi < WINDOW_SIZE; gi = gi + 1) begin : gen_token_extend
            assign batch_out_token_ids[gi*32 +: 32] =
                {{(32-TOKEN_ID_W){1'b0}}, lat_slot_token_id[gi*TOKEN_ID_W +: TOKEN_ID_W]};
            assign batch_out_positions[gi*16 +: 16] =
                {{(16-POSITION_ID_W){1'b0}}, lat_slot_position[gi*POSITION_ID_W +: POSITION_ID_W]};
        end
    endgenerate

    // Forward result ready
    assign fwd_result_ready = (state == ST_WAIT_FWD);

    // Commit output
    assign commit_valid        = (state == ST_COMMIT);
    assign commit_branch_id    = cmp_best_branch;
    assign commit_depth        = cmp_best_depth;
    assign commit_bonus_token_id = cmp_bonus_token;
    assign commit_flush_mask   = cmp_flush_mask;
    assign commit_slots        = cmp_commit_slots;
    assign commit_slot_positions = cmp_commit_slot_positions;

endmodule
