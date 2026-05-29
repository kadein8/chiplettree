`ifndef TREE_FLATTEN_V
`define TREE_FLATTEN_V
`timescale 1ns/1ps
`include "config/interface_params.vh"
`include "config/prediction_params.vh"

// tree_flatten
// Flattens a tree of draft tokens (4 branches x 4 levels) into unique
// window slots for tree-attention parallel forward.
// Pure combinational logic; clk/rst_n reserved for future pipelining.

module tree_flatten #(
    parameter BRANCH_NUM   = `BRANCH_NUM,
    parameter MAX_LEVELS   = `MAX_PRIVATE_NODES_PER_BRANCH,
    parameter WINDOW_SIZE  = `VERIFY_WINDOW_SIZE,
    parameter TOKEN_ID_W   = `TOKEN_ID_W,
    parameter POSITION_ID_W = `POSITION_ID_W,
    parameter NODE_ID_W    = `NODE_ID_W,
    parameter SLOT_ID_W    = `SLOT_ID_W
)(
    input  wire                                          clk,
    input  wire                                          rst_n,

    // Seed token (recovery point)
    input  wire [NODE_ID_W-1:0]                          seed_node_id,
    input  wire [TOKEN_ID_W-1:0]                         seed_token_id,
    input  wire [POSITION_ID_W-1:0]                      seed_position,

    // Branch-level inputs
    input  wire [BRANCH_NUM-1:0]                         branch_valid,
    input  wire [BRANCH_NUM*MAX_LEVELS*NODE_ID_W-1:0]    branch_node_ids,
    input  wire [BRANCH_NUM*MAX_LEVELS*NODE_ID_W-1:0]    branch_parent_node_ids,
    input  wire [BRANCH_NUM*MAX_LEVELS*TOKEN_ID_W-1:0]   branch_draft_tokens,
    input  wire [BRANCH_NUM*MAX_LEVELS*POSITION_ID_W-1:0] branch_draft_positions,
    input  wire [BRANCH_NUM*MAX_LEVELS-1:0]              branch_levels_valid,

    // Outputs
    output reg  [4:0]                                    unique_slot_count,
    output reg  [WINDOW_SIZE*TOKEN_ID_W-1:0]             slot_token_id,
    output reg  [WINDOW_SIZE*POSITION_ID_W-1:0]          slot_position,
    output reg  [WINDOW_SIZE*SLOT_ID_W-1:0]              slot_parent_slot,
    output reg  [WINDOW_SIZE-1:0]                        slot_is_seed,
    output reg  [BRANCH_NUM*MAX_LEVELS*SLOT_ID_W-1:0]    branch_slot_map
);

    // Invalid parent marker
    localparam [SLOT_ID_W-1:0] PARENT_INVALID = {SLOT_ID_W{1'b1}};

    // Internal variables for combinational scan
    integer b, l, s;
    reg [4:0] alloc_count;
    reg       found;
    reg [SLOT_ID_W-1:0] matched_slot;

    // Temporary storage for current node being examined
    reg [TOKEN_ID_W-1:0]    cur_token_id;
    reg [POSITION_ID_W-1:0] cur_position;
    reg [NODE_ID_W-1:0]     cur_node_id;
    reg [NODE_ID_W-1:0]     cur_parent_node_id;
    reg [SLOT_ID_W-1:0]     cur_parent_slot;
    reg                     found_parent;

    // Allocated slot arrays for linear scan comparison
    reg [NODE_ID_W-1:0]     alloc_node_id   [0:WINDOW_SIZE-1];
    reg [TOKEN_ID_W-1:0]    alloc_token_id  [0:WINDOW_SIZE-1];
    reg [POSITION_ID_W-1:0] alloc_position  [0:WINDOW_SIZE-1];
    reg [SLOT_ID_W-1:0]     alloc_parent    [0:WINDOW_SIZE-1];

    // Use an explicit input sensitivity list so module-scope temporaries do not
    // self-trigger zero-delay reevaluation in VCS.
    always @(seed_node_id or seed_token_id or seed_position or
             branch_valid or branch_node_ids or branch_parent_node_ids or
             branch_draft_tokens or branch_draft_positions or
             branch_levels_valid) begin : flatten_logic
        // Default all outputs to zero
        unique_slot_count = 5'd0;
        slot_token_id     = {WINDOW_SIZE*TOKEN_ID_W{1'b0}};
        slot_position     = {WINDOW_SIZE*POSITION_ID_W{1'b0}};
        slot_parent_slot  = {WINDOW_SIZE*SLOT_ID_W{1'b0}};
        slot_is_seed      = {WINDOW_SIZE{1'b0}};
        branch_slot_map   = {BRANCH_NUM*MAX_LEVELS*SLOT_ID_W{1'b0}};

        // Initialize allocated slot tracking
        for (s = 0; s < WINDOW_SIZE; s = s + 1) begin
            alloc_node_id[s] = {NODE_ID_W{1'b0}};
            alloc_token_id[s] = {TOKEN_ID_W{1'b0}};
            alloc_position[s] = {POSITION_ID_W{1'b0}};
            alloc_parent[s]   = {SLOT_ID_W{1'b0}};
        end

        // -----------------------------------------------------------
        // Step 1: Slot 0 = seed token
        // -----------------------------------------------------------
        slot_token_id[0 +: TOKEN_ID_W]      = seed_token_id;
        slot_position[0 +: POSITION_ID_W]    = seed_position;
        slot_parent_slot[0 +: SLOT_ID_W]     = PARENT_INVALID;
        slot_is_seed[0]                      = 1'b1;

        alloc_node_id[0] = seed_node_id;
        alloc_token_id[0] = seed_token_id;
        alloc_position[0] = seed_position;
        alloc_parent[0]   = PARENT_INVALID;

        alloc_count = 5'd1;

        // -----------------------------------------------------------
        // Step 2: Iterate branches and levels, deduplicate into slots
        // -----------------------------------------------------------
        for (b = 0; b < BRANCH_NUM; b = b + 1) begin
            for (l = 0; l < MAX_LEVELS; l = l + 1) begin
                if (branch_valid[b] && branch_levels_valid[b*MAX_LEVELS + l]) begin
                    // Extract current node fields
                    cur_node_id    = branch_node_ids[(b*MAX_LEVELS + l)*NODE_ID_W +: NODE_ID_W];
                    cur_parent_node_id =
                        branch_parent_node_ids[(b*MAX_LEVELS + l)*NODE_ID_W +: NODE_ID_W];
                    cur_token_id   = branch_draft_tokens[(b*MAX_LEVELS + l)*TOKEN_ID_W +: TOKEN_ID_W];
                    cur_position   = branch_draft_positions[(b*MAX_LEVELS + l)*POSITION_ID_W +: POSITION_ID_W];
                    cur_parent_slot = PARENT_INVALID;
                    found_parent = 1'b0;

                    for (s = 0; s < WINDOW_SIZE; s = s + 1) begin
                        if (!found_parent && (s < alloc_count)) begin
                            if (alloc_node_id[s] == cur_parent_node_id) begin
                                found_parent = 1'b1;
                                cur_parent_slot = s[SLOT_ID_W-1:0];
                            end
                        end
                    end

                    // Shared-slot reuse is only legal when the candidate keeps
                    // the same tree topology and token identity as an already
                    // allocated node in the window.
                    found        = 1'b0;
                    matched_slot = {SLOT_ID_W{1'b0}};

                    for (s = 0; s < WINDOW_SIZE; s = s + 1) begin
                        if (!found && (s < alloc_count)) begin
                            if ((alloc_parent[s] == cur_parent_slot) &&
                                (alloc_token_id[s] == cur_token_id) &&
                                (alloc_position[s] == cur_position)) begin
                                found        = 1'b1;
                                matched_slot = s[SLOT_ID_W-1:0];
                            end
                        end
                    end

                    if (found) begin
                        // Shared node: reuse existing slot
                        branch_slot_map[(b*MAX_LEVELS + l)*SLOT_ID_W +: SLOT_ID_W] = matched_slot;
                    end else begin
                        // Allocate new slot
                        slot_token_id[alloc_count*TOKEN_ID_W +: TOKEN_ID_W]         = cur_token_id;
                        slot_position[alloc_count*POSITION_ID_W +: POSITION_ID_W]   = cur_position;
                        slot_parent_slot[alloc_count*SLOT_ID_W +: SLOT_ID_W]        = cur_parent_slot;
                        slot_is_seed[alloc_count]                                   = 1'b0;

                        alloc_node_id[alloc_count] = cur_node_id;
                        alloc_token_id[alloc_count] = cur_token_id;
                        alloc_position[alloc_count] = cur_position;
                        alloc_parent[alloc_count]   = cur_parent_slot;

                        branch_slot_map[(b*MAX_LEVELS + l)*SLOT_ID_W +: SLOT_ID_W] = alloc_count[SLOT_ID_W-1:0];

                        alloc_count = alloc_count + 5'd1;
                    end
                end else begin
                    // Invalid level: map to slot 0 (don't-care, but deterministic)
                    branch_slot_map[(b*MAX_LEVELS + l)*SLOT_ID_W +: SLOT_ID_W] = {SLOT_ID_W{1'b0}};
                end
            end
        end

        // -----------------------------------------------------------
        // Step 3: Output total allocated slot count
        // -----------------------------------------------------------
        unique_slot_count = alloc_count;
    end

endmodule
`endif
