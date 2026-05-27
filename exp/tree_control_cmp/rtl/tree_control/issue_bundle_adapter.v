`timescale 1ns/1ps

`include "config/prediction_params.vh"
`include "config/interface_params.vh"
`include "config/memory_params.vh"
`include "config/model_params.vh"

/*
 * issue_bundle_adapter
 *
 * Converts tree_verify_dispatcher batch output into the issue_bundle format
 * consumed by StrictTreeMaskPaperMeshBackend.
 *
 * Input:  dispatcher batch (slot_valid, token_ids, positions, tree_mask, prefix_len)
 * Output: issue_bundle (all fields required by PaperPeArrays16x128Mesh)
 *
 * Field mapping:
 *   slot_valid          <- batch valid slots
 *   slot_lookup_hit     <- all 1 (e2e: no token_register lookup needed)
 *   token_id            <- batch token_ids
 *   position_id         <- batch positions
 *   node_id             <- sequential from 0
 *   parent_node_id      <- derived from tree_mask (first visible predecessor)
 *   branch_id           <- 0 for all (single-issue mode)
 *   slot_tree_mask_en   <- non-zero tree_mask row means enabled
 *   slot_visible_mask   <- tree_mask rows (padded to MODEL_MAX_POS_EMB)
 *   private_depth       <- 0 (not used in e2e)
 *   sram_id/bank_id/subbank_start <- 0 (behavioral SRAM ignores these)
 *   group_len/branch_mask/is_shared/entry_state/entry_type <- defaults
 *   base addresses      <- passed through from top-level constants
 */
module issue_bundle_adapter #(
    parameter integer WINDOW_SIZE = `VERIFY_WINDOW_SIZE,
    parameter integer PRIVATE_DEPTH_W =
        (((`MAX_VERIFY_NODES_PER_BRANCH + 1) <= 2) ? 1 :
         $clog2(`MAX_VERIFY_NODES_PER_BRANCH + 1))
) (
    input                             clk,
    input                             rst_n,

    // From tree_verify_dispatcher batch output
    input                             batch_valid,
    output                            batch_ready,
    input  [4:0]                      batch_count,
    input  [WINDOW_SIZE*32-1:0]       batch_token_ids,
    input  [WINDOW_SIZE*16-1:0]       batch_positions,
    input  [WINDOW_SIZE*WINDOW_SIZE-1:0] batch_tree_mask,
    input  [15:0]                     batch_prefix_len,

    // Base address constants (from top-level)
    input  [`SRAM_ADDR_W-1:0]         embedding_base_addr,
    input  [`SRAM_ADDR_W-1:0]         hidden0_base_addr,
    input  [`SRAM_ADDR_W-1:0]         hidden1_base_addr,
    input  [`SRAM_ADDR_W-1:0]         final_base_addr,
    input  [`SRAM_ADDR_W-1:0]         weight_sram_base_addr,
    input  [`SRAM_ADDR_W-1:0]         kv_cache_base_addr,
    input  [`SRAM_ADDR_W-1:0]         draft_kv_base_addr,
    input  [`HBM_ADDR_W-1:0]          hbm_weight_base_addr,
    input  [`SRAM_ADDR_W-1:0]         final_norm_gamma_addr,
    input  [`SRAM_ADDR_W-1:0]         lm_head_weight_base_addr,

    // To StrictTreeMaskPaperMeshBackend issue_bundle
    output reg                        issue_bundle_valid,
    input                             issue_bundle_ready,
    output [`REQ_ID_W-1:0]            issue_bundle_req_id,
    output [WINDOW_SIZE-1:0]          issue_bundle_slot_valid,
    output [WINDOW_SIZE-1:0]          issue_bundle_slot_lookup_hit,
    output [WINDOW_SIZE*`TOKEN_ID_W-1:0]       issue_bundle_token_id,
    output [WINDOW_SIZE*`POSITION_ID_W-1:0]    issue_bundle_position_id,
    output [WINDOW_SIZE*`NODE_ID_W-1:0]        issue_bundle_node_id,
    output [WINDOW_SIZE*`NODE_ID_W-1:0]        issue_bundle_parent_node_id,
    output [WINDOW_SIZE*`BRANCH_ID_W-1:0]      issue_bundle_branch_id,
    output [`TREE_LEVEL_ID_W-1:0]     issue_bundle_level_id,
    output [4:0]                      issue_bundle_slot_count,
    output [15:0]                     issue_bundle_prefix_len,
    output [WINDOW_SIZE-1:0]          issue_bundle_slot_tree_mask_en,
    output [WINDOW_SIZE*`MODEL_MAX_POS_EMB-1:0] issue_bundle_slot_visible_mask,
    output [WINDOW_SIZE*PRIVATE_DEPTH_W-1:0]   issue_bundle_private_depth,
    output [WINDOW_SIZE*`SRAM_ID_W-1:0]        issue_bundle_sram_id,
    output [WINDOW_SIZE*`BANK_ID_W-1:0]        issue_bundle_bank_id,
    output [WINDOW_SIZE*`SUBBANK_ID_W-1:0]     issue_bundle_subbank_start,
    output [WINDOW_SIZE*`KV_GROUP_LEN_W-1:0]   issue_bundle_group_len,
    output [WINDOW_SIZE*`BRANCH_MASK_W-1:0]    issue_bundle_branch_mask,
    output [WINDOW_SIZE-1:0]          issue_bundle_is_shared,
    output [WINDOW_SIZE*`TOKEN_STATE_W-1:0]    issue_bundle_entry_state,
    output [WINDOW_SIZE*`TOKEN_ENTRY_TYPE_W-1:0] issue_bundle_entry_type,
    output [`SRAM_ADDR_W-1:0]         issue_bundle_embedding_base_addr,
    output [`SRAM_ADDR_W-1:0]         issue_bundle_hidden0_base_addr,
    output [`SRAM_ADDR_W-1:0]         issue_bundle_hidden1_base_addr,
    output [`SRAM_ADDR_W-1:0]         issue_bundle_final_base_addr,
    output [`SRAM_ADDR_W-1:0]         issue_bundle_weight_sram_base_addr,
    output [`SRAM_ADDR_W-1:0]         issue_bundle_kv_cache_base_addr,
    output [`SRAM_ADDR_W-1:0]         issue_bundle_draft_kv_base_addr,
    output [`HBM_ADDR_W-1:0]          issue_bundle_hbm_weight_base_addr,
    output [`SRAM_ADDR_W-1:0]         issue_bundle_final_norm_gamma_addr,
    output [`SRAM_ADDR_W-1:0]         issue_bundle_lm_head_weight_base_addr,

    // Done signal: pulses when mesh backend finishes
    output                            adapter_busy
);

// =========================================================================
// Handshake: pass batch_valid through to issue_bundle_valid
// =========================================================================
assign batch_ready = issue_bundle_ready;

always @(*) begin
    issue_bundle_valid = batch_valid;
end

assign adapter_busy = batch_valid && !issue_bundle_ready;

// =========================================================================
// Field mapping
// =========================================================================
reg [`REQ_ID_W-1:0] req_id_cnt_r;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        req_id_cnt_r <= {`REQ_ID_W{1'b0}};
    else if (batch_valid && issue_bundle_ready)
        req_id_cnt_r <= req_id_cnt_r + {{(`REQ_ID_W-1){1'b0}}, 1'b1};
end

assign issue_bundle_req_id = req_id_cnt_r;
assign issue_bundle_slot_count = batch_count;
assign issue_bundle_prefix_len = batch_prefix_len;
assign issue_bundle_level_id = {`TREE_LEVEL_ID_W{1'b0}};

// Slot valid: first batch_count slots are valid
reg [WINDOW_SIZE-1:0] slot_valid_w;
integer svi;
always @(*) begin
    for (svi = 0; svi < WINDOW_SIZE; svi = svi + 1)
        slot_valid_w[svi] = (svi < batch_count) ? 1'b1 : 1'b0;
end
assign issue_bundle_slot_valid = slot_valid_w;

// All slots have lookup_hit = 1 (no token_register in e2e)
assign issue_bundle_slot_lookup_hit = slot_valid_w;

// Token IDs: truncate from 32-bit dispatcher format to TOKEN_ID_W
reg [WINDOW_SIZE*`TOKEN_ID_W-1:0] token_id_w;
integer ti;
always @(*) begin
    for (ti = 0; ti < WINDOW_SIZE; ti = ti + 1)
        token_id_w[ti*`TOKEN_ID_W +: `TOKEN_ID_W] =
            batch_token_ids[ti*32 +: `TOKEN_ID_W];
end
assign issue_bundle_token_id = token_id_w;

// Position IDs: truncate from 16-bit to POSITION_ID_W
reg [WINDOW_SIZE*`POSITION_ID_W-1:0] position_id_w;
integer pi;
always @(*) begin
    for (pi = 0; pi < WINDOW_SIZE; pi = pi + 1)
        position_id_w[pi*`POSITION_ID_W +: `POSITION_ID_W] =
            batch_positions[pi*16 +: `POSITION_ID_W];
end
assign issue_bundle_position_id = position_id_w;

// Node IDs: sequential 0, 1, 2, ...
reg [WINDOW_SIZE*`NODE_ID_W-1:0] node_id_w;
integer ni;
always @(*) begin
    for (ni = 0; ni < WINDOW_SIZE; ni = ni + 1)
        node_id_w[ni*`NODE_ID_W +: `NODE_ID_W] = ni[`NODE_ID_W-1:0];
end
assign issue_bundle_node_id = node_id_w;

// Parent node IDs: slot 0 has no parent (all-ones), others = 0 (seed)
// In tree verification, all draft tokens see the seed as parent for simplicity
reg [WINDOW_SIZE*`NODE_ID_W-1:0] parent_node_id_w;
integer pni;
always @(*) begin
    for (pni = 0; pni < WINDOW_SIZE; pni = pni + 1) begin
        if (pni == 0)
            parent_node_id_w[pni*`NODE_ID_W +: `NODE_ID_W] = {`NODE_ID_W{1'b1}};
        else
            parent_node_id_w[pni*`NODE_ID_W +: `NODE_ID_W] = {`NODE_ID_W{1'b0}};
    end
end
assign issue_bundle_parent_node_id = parent_node_id_w;

// Branch ID: all 0 (single-issue batch mode)
assign issue_bundle_branch_id = {(WINDOW_SIZE*`BRANCH_ID_W){1'b0}};

// Tree mask enable: slot has tree_mask if its row is non-zero
reg [WINDOW_SIZE-1:0] tree_mask_en_w;
integer tmi;
always @(*) begin
    for (tmi = 0; tmi < WINDOW_SIZE; tmi = tmi + 1)
        tree_mask_en_w[tmi] =
            |batch_tree_mask[tmi*WINDOW_SIZE +: WINDOW_SIZE];
end
assign issue_bundle_slot_tree_mask_en = tree_mask_en_w;

// Visible mask: expand tree_mask rows into MODEL_MAX_POS_EMB-wide masks
// The tree_mask is WINDOW_SIZE x WINDOW_SIZE. We pad to MODEL_MAX_POS_EMB width.
reg [WINDOW_SIZE*`MODEL_MAX_POS_EMB-1:0] visible_mask_w;
integer vmi, vmj;
always @(*) begin
    visible_mask_w = {(WINDOW_SIZE*`MODEL_MAX_POS_EMB){1'b0}};
    for (vmi = 0; vmi < WINDOW_SIZE; vmi = vmi + 1) begin
        for (vmj = 0; vmj < WINDOW_SIZE; vmj = vmj + 1) begin
            visible_mask_w[vmi*`MODEL_MAX_POS_EMB + vmj] =
                batch_tree_mask[vmi*WINDOW_SIZE + vmj];
        end
    end
end
assign issue_bundle_slot_visible_mask = visible_mask_w;

// Private depth: all 0
assign issue_bundle_private_depth = {(WINDOW_SIZE*PRIVATE_DEPTH_W){1'b0}};

// SRAM addressing fields: all 0 (behavioral SRAM ignores bank/subbank routing)
assign issue_bundle_sram_id = {(WINDOW_SIZE*`SRAM_ID_W){1'b0}};
assign issue_bundle_bank_id = {(WINDOW_SIZE*`BANK_ID_W){1'b0}};
assign issue_bundle_subbank_start = {(WINDOW_SIZE*`SUBBANK_ID_W){1'b0}};
assign issue_bundle_group_len = {(WINDOW_SIZE*`KV_GROUP_LEN_W){1'b0}};
assign issue_bundle_branch_mask = {(WINDOW_SIZE*`BRANCH_MASK_W){1'b0}};
assign issue_bundle_is_shared = {WINDOW_SIZE{1'b0}};
assign issue_bundle_entry_state = {(WINDOW_SIZE*`TOKEN_STATE_W){1'b0}};
assign issue_bundle_entry_type = {(WINDOW_SIZE*`TOKEN_ENTRY_TYPE_W){1'b0}};

// Base addresses: pass through
assign issue_bundle_embedding_base_addr = embedding_base_addr;
assign issue_bundle_hidden0_base_addr = hidden0_base_addr;
assign issue_bundle_hidden1_base_addr = hidden1_base_addr;
assign issue_bundle_final_base_addr = final_base_addr;
assign issue_bundle_weight_sram_base_addr = weight_sram_base_addr;
assign issue_bundle_kv_cache_base_addr = kv_cache_base_addr;
assign issue_bundle_draft_kv_base_addr = draft_kv_base_addr;
assign issue_bundle_hbm_weight_base_addr = hbm_weight_base_addr;
assign issue_bundle_final_norm_gamma_addr = final_norm_gamma_addr;
assign issue_bundle_lm_head_weight_base_addr = lm_head_weight_base_addr;

// synthesis translate_off
always @(posedge clk) begin
    if (batch_valid && issue_bundle_ready)
        $display("[ADAPTER] issue_bundle fired: count=%0d prefix_len=%0d token[0]=%0d pos[0]=%0d",
            batch_count, batch_prefix_len,
            batch_token_ids[`TOKEN_ID_W-1:0],
            batch_positions[`POSITION_ID_W-1:0]);
end
// synthesis translate_on

endmodule
