`include "config/interface_params.vh"
`include "config/prediction_params.vh"
`include "config/memory_params.vh"
`include "config/model_params.vh"
`timescale 1ns/1ps

// issue_bundle_adapter
//
// Converts tree_verify_dispatcher batch_out signals into the formal
// issue_bundle format expected by StrictTreeMaskPaperMeshBackend.
//
// In the full paper path, the IssueScheduler queries token_register
// for SRAM location metadata. In this e2e adapter, we bypass that
// and fill in default/derived values directly.

module issue_bundle_adapter #(
    parameter integer WINDOW_SIZE   = `VERIFY_WINDOW_SIZE,
    parameter integer BRANCH_NUM    = `BRANCH_NUM,
    parameter integer MAX_LEVELS    = `MAX_PRIVATE_NODES_PER_BRANCH,
    parameter integer PRIVATE_DEPTH_W =
        (((`MAX_VERIFY_NODES_PER_BRANCH + 1) <= 2) ? 1 :
         $clog2(`MAX_VERIFY_NODES_PER_BRANCH + 1))
) (
    input  logic                          clk,
    input  logic                          rst_n,

    // --- From tree_verify_dispatcher batch_out ---
    input  logic                          batch_in_valid,
    output logic                          batch_in_ready,
    input  logic [4:0]                    batch_in_count,
    input  logic [WINDOW_SIZE*32-1:0]     batch_in_token_ids,
    input  logic [WINDOW_SIZE*16-1:0]     batch_in_positions,
    input  logic [WINDOW_SIZE*WINDOW_SIZE-1:0] batch_in_tree_mask,
    input  logic [15:0]                   batch_in_prefix_len,

    // --- To StrictTreeMaskPaperMeshBackend issue_bundle ---
    output logic                          issue_bundle_valid,
    input  logic                          issue_bundle_ready,
    output logic [`REQ_ID_W-1:0]          issue_bundle_req_id,
    output logic [`TREE_FRONTIER_SLOTS-1:0] issue_bundle_slot_valid,
    output logic [`TREE_FRONTIER_SLOTS-1:0] issue_bundle_slot_lookup_hit,
    output logic [`TREE_FRONTIER_SLOTS*`TOKEN_ID_W-1:0]
                                          issue_bundle_token_id,
    output logic [`TREE_FRONTIER_SLOTS*`POSITION_ID_W-1:0]
                                          issue_bundle_position_id,
    output logic [`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0]
                                          issue_bundle_node_id,
    output logic [`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0]
                                          issue_bundle_parent_node_id,
    output logic [`TREE_FRONTIER_SLOTS*`BRANCH_ID_W-1:0]
                                          issue_bundle_branch_id,
    output logic [`TREE_LEVEL_ID_W-1:0]   issue_bundle_level_id,
    output logic [4:0]                    issue_bundle_slot_count,
    output logic [15:0]                   issue_bundle_prefix_len,
    output logic [`TREE_FRONTIER_SLOTS-1:0] issue_bundle_slot_tree_mask_en,
    output logic [`TREE_FRONTIER_SLOTS*`MODEL_MAX_POS_EMB-1:0]
                                          issue_bundle_slot_visible_mask,
    output logic [`TREE_FRONTIER_SLOTS*PRIVATE_DEPTH_W-1:0]
                                          issue_bundle_private_depth,
    output logic [`TREE_FRONTIER_SLOTS*`SRAM_ID_W-1:0]
                                          issue_bundle_sram_id,
    output logic [`TREE_FRONTIER_SLOTS*`BANK_ID_W-1:0]
                                          issue_bundle_bank_id,
    output logic [`TREE_FRONTIER_SLOTS*`SUBBANK_ID_W-1:0]
                                          issue_bundle_subbank_start,
    output logic [`TREE_FRONTIER_SLOTS*`KV_GROUP_LEN_W-1:0]
                                          issue_bundle_group_len,
    output logic [`TREE_FRONTIER_SLOTS*`BRANCH_MASK_W-1:0]
                                          issue_bundle_branch_mask,
    output logic [`TREE_FRONTIER_SLOTS-1:0] issue_bundle_is_shared,
    output logic [`TREE_FRONTIER_SLOTS*`TOKEN_STATE_W-1:0]
                                          issue_bundle_entry_state,
    output logic [`TREE_FRONTIER_SLOTS*`TOKEN_ENTRY_TYPE_W-1:0]
                                          issue_bundle_entry_type,
    output logic [`SRAM_ADDR_W-1:0]       issue_bundle_embedding_base_addr,
    output logic [`SRAM_ADDR_W-1:0]       issue_bundle_hidden0_base_addr,
    output logic [`SRAM_ADDR_W-1:0]       issue_bundle_hidden1_base_addr,
    output logic [`SRAM_ADDR_W-1:0]       issue_bundle_final_base_addr,
    output logic [`SRAM_ADDR_W-1:0]       issue_bundle_weight_sram_base_addr,
    output logic [`SRAM_ADDR_W-1:0]       issue_bundle_kv_cache_base_addr,
    output logic [`SRAM_ADDR_W-1:0]       issue_bundle_draft_kv_base_addr,
    output logic [`HBM_ADDR_W-1:0]        issue_bundle_hbm_weight_base_addr,
    output logic [`SRAM_ADDR_W-1:0]       issue_bundle_final_norm_gamma_addr,
    output logic [`SRAM_ADDR_W-1:0]       issue_bundle_lm_head_weight_base_addr
);

// =========================================================================
// Request ID counter
// =========================================================================
logic [`REQ_ID_W-1:0] req_id_cnt_r;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        req_id_cnt_r <= '0;
    else if (batch_in_valid && batch_in_ready)
        req_id_cnt_r <= req_id_cnt_r + {{(`REQ_ID_W-1){1'b0}}, 1'b1};
end

// =========================================================================
// Combinational adapter: direct pass-through with field mapping
// =========================================================================
assign batch_in_ready = issue_bundle_ready;
assign issue_bundle_valid = batch_in_valid;
assign issue_bundle_req_id = req_id_cnt_r;
assign issue_bundle_slot_count = batch_in_count;
assign issue_bundle_prefix_len = batch_in_prefix_len;

// Fixed base addresses (same as used by PeArrayLayerController)
assign issue_bundle_embedding_base_addr = `MODEL_EMB_BASE;
assign issue_bundle_hidden0_base_addr = `MODEL_WORK_HIDDEN0_BASE;
assign issue_bundle_hidden1_base_addr = `MODEL_WORK_HIDDEN1_BASE;
assign issue_bundle_final_base_addr = `MODEL_WORK_FINAL_BASE;
assign issue_bundle_weight_sram_base_addr = `MODEL_WEIGHT_SRAM_BASE;
assign issue_bundle_kv_cache_base_addr = `KV_COMMITTED_BASE;
assign issue_bundle_draft_kv_base_addr = `KV_DRAFT_BASE_MIN;
assign issue_bundle_hbm_weight_base_addr = `MODEL_HBM_WEIGHT_BASE;
assign issue_bundle_final_norm_gamma_addr = `MODEL_FINAL_NORM_GAMMA_ADDR;
assign issue_bundle_lm_head_weight_base_addr = `MODEL_LM_HEAD_WEIGHT_BASE;

// Level ID: always 0 for e2e (single-level dispatch)
assign issue_bundle_level_id = '0;

// All slots have lookup hit (bypass token_register in e2e)
assign issue_bundle_slot_lookup_hit = {`TREE_FRONTIER_SLOTS{1'b1}};

// Default metadata fields
assign issue_bundle_sram_id = '0;
assign issue_bundle_bank_id = '0;
assign issue_bundle_subbank_start = '0;
assign issue_bundle_group_len = '0;
assign issue_bundle_branch_mask = '0;
assign issue_bundle_is_shared = '0;
assign issue_bundle_entry_state = '0;
assign issue_bundle_entry_type = '0;
assign issue_bundle_private_depth = '0;

// =========================================================================
// Per-slot field mapping
// =========================================================================
integer si;

always_comb begin
    issue_bundle_slot_valid = '0;
    issue_bundle_token_id = '0;
    issue_bundle_position_id = '0;
    issue_bundle_node_id = '0;
    issue_bundle_parent_node_id = '0;
    issue_bundle_branch_id = '0;
    issue_bundle_slot_tree_mask_en = '0;
    issue_bundle_slot_visible_mask = '0;

    for (si = 0; si < WINDOW_SIZE; si = si + 1) begin
        if (si < batch_in_count) begin
            issue_bundle_slot_valid[si] = 1'b1;
            issue_bundle_token_id[si*`TOKEN_ID_W +: `TOKEN_ID_W] =
                batch_in_token_ids[si*32 +: `TOKEN_ID_W];
            issue_bundle_position_id[si*`POSITION_ID_W +: `POSITION_ID_W] =
                batch_in_positions[si*16 +: `POSITION_ID_W];
            // Node ID = slot index (simple assignment for e2e)
            issue_bundle_node_id[si*`NODE_ID_W +: `NODE_ID_W] =
                si[`NODE_ID_W-1:0];
            // Parent node ID = 0 for seed, slot-1 for others (simplified)
            issue_bundle_parent_node_id[si*`NODE_ID_W +: `NODE_ID_W] =
                (si == 0) ? {`NODE_ID_W{1'b1}} : (si[`NODE_ID_W-1:0] - 1);
            // Branch ID derived from slot layout (branch = (si-1)/MAX_LEVELS)
            if (si > 0)
                issue_bundle_branch_id[si*`BRANCH_ID_W +: `BRANCH_ID_W] =
                    ((si - 1) / MAX_LEVELS);

            // Tree mask enable: non-zero if tree_mask row has any bit set
            issue_bundle_slot_tree_mask_en[si] =
                |batch_in_tree_mask[si*WINDOW_SIZE +: WINDOW_SIZE];

            // Convert tree_mask row to visible_mask (position-based)
            // Each visible slot's position becomes visible in the mask
            begin : gen_vis_mask
                integer vj;
                for (vj = 0; vj < WINDOW_SIZE; vj = vj + 1) begin
                    if (batch_in_tree_mask[si*WINDOW_SIZE + vj] &&
                        (vj < batch_in_count)) begin
                        issue_bundle_slot_visible_mask[
                            si*`MODEL_MAX_POS_EMB +
                            batch_in_positions[vj*16 +: `POSITION_ID_W]] = 1'b1;
                    end
                end
                // Also mark committed prefix positions as visible
                begin : gen_prefix_vis
                    integer pi;
                    for (pi = 0; pi < `MODEL_MAX_POS_EMB; pi = pi + 1) begin
                        if (pi < batch_in_prefix_len)
                            issue_bundle_slot_visible_mask[
                                si*`MODEL_MAX_POS_EMB + pi] = 1'b1;
                    end
                end
            end
        end
    end
end

endmodule
