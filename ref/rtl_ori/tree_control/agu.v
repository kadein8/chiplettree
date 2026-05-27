`timescale 1ns/1ps

`include "config/prediction_params.vh"
`include "config/interface_params.vh"
`include "config/memory_params.vh"

module agu (
    input                        clk,
    input                        rst_n,
    input                        tree_in_valid,
    output                       tree_in_ready,
    input  [`REQ_ID_W-1:0]       tree_in_req_id,
    input  [`BRANCH_ID_W-1:0]    tree_in_branch_id,
    input  [`NODE_ID_W-1:0]      tree_in_node_id,
    input                        prefix_valid,
    output                       prefix_ready,
    input  [`REQ_ID_W-1:0]       prefix_req_id,
    input                        prefix_node_valid,
    input  [`NODE_ID_W-1:0]      prefix_node_id,
    input  [`NODE_ID_W-1:0]      prefix_parent_node_id,
    input  [`TOKEN_ID_W-1:0]     prefix_token_id,
    input  [`POSITION_ID_W-1:0]  prefix_position_id,
    input  [`LAYER_ID_W-1:0]     prefix_layer_id,
    input                        prefix_is_last,
    input                        frontier_valid,
    output                       frontier_ready,
    input  [`REQ_ID_W-1:0]       frontier_req_id,
    input  [`TREE_LEVEL_ID_W-1:0] frontier_level_id,
    input  [`TREE_FRONTIER_SLOTS-1:0] frontier_slot_valid,
    input  [`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0] frontier_node_id,
    input  [`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0] frontier_parent_node_id,
    input  [`TREE_FRONTIER_SLOTS*`TOKEN_ID_W-1:0] frontier_token_id,
    input  [`TREE_FRONTIER_SLOTS*`POSITION_ID_W-1:0] frontier_position_id,
    input                        prefetch_enq_ready,
    input                        cand_resp_valid,
    input                        cand_resp_grant,
    input  [`REQ_ID_W-1:0]       cand_resp_req_id,
    input  [`SRAM_ID_W-1:0]      cand_resp_sram_id,
    input  [`BANK_ID_W-1:0]      cand_resp_bank_id,
    input  [`SUBBANK_ID_W-1:0]   cand_resp_subbank_start,
    input  [`KV_GROUP_LEN_W-1:0] cand_resp_group_len,
    input                        alloc_resp_valid,
    input                        alloc_resp_grant,
    input  [`REQ_ID_W-1:0]       alloc_resp_req_id,
    input  [`SRAM_ID_W-1:0]      alloc_resp_sram_id,
    input  [`BANK_ID_W-1:0]      alloc_resp_bank_id,
    input  [`SUBBANK_ID_W-1:0]   alloc_resp_subbank_start,
    input  [`KV_GROUP_LEN_W-1:0] alloc_resp_group_len,
    input                        flush_freeze,
    input                        flush_drain_busy,
    input                        flush_ctrl_valid,
    input  [`REQ_ID_W-1:0]       flush_ctrl_req_id,
    input  [`BRANCH_MASK_W-1:0]  flush_ctrl_branch_mask,
    input  [`NODE_MASK_W-1:0]    flush_ctrl_node_mask,
    input                        branch_liveness_valid,
    input  [`REQ_ID_W-1:0]       branch_liveness_req_id,
    input  [`BRANCH_MASK_W-1:0]  branch_liveness_live_mask,
    input  [`BRANCH_MASK_W-1:0]  branch_liveness_prune_mask,
    output                       prefix_norm_valid,
    output [`REQ_ID_W-1:0]       prefix_norm_req_id,
    output                       prefix_norm_node_valid,
    output [`NODE_ID_W-1:0]      prefix_norm_node_id,
    output [`NODE_ID_W-1:0]      prefix_norm_parent_node_id,
    output [`TOKEN_ID_W-1:0]     prefix_norm_token_id,
    output [`POSITION_ID_W-1:0]  prefix_norm_position_id,
    output [`LAYER_ID_W-1:0]     prefix_norm_layer_id,
    output                       prefix_norm_is_last,
    output                       prefix_norm_is_shared,
    output                       frontier_norm_valid,
    output [`REQ_ID_W-1:0]       frontier_norm_req_id,
    output [`TREE_LEVEL_ID_W-1:0] frontier_norm_level_id,
    output [`TREE_FRONTIER_SLOTS-1:0] frontier_norm_slot_valid,
    output [`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0] frontier_norm_node_id,
    output [`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0] frontier_norm_parent_node_id,
    output [`TREE_FRONTIER_SLOTS*`TOKEN_ID_W-1:0] frontier_norm_token_id,
    output [`TREE_FRONTIER_SLOTS*`POSITION_ID_W-1:0] frontier_norm_position_id,
    output [`TREE_FRONTIER_SLOTS*`KV_GROUP_LEN_W-1:0] frontier_norm_size_subbank,
    output [`TREE_FRONTIER_SLOTS-1:0] frontier_norm_slot_shared,
    output                       alloc_cand_valid,
    output [`REQ_ID_W-1:0]       alloc_cand_req_id,
    output [`BRANCH_ID_W-1:0]    alloc_cand_branch_id,
    output [`NODE_ID_W-1:0]      alloc_cand_node_id,
    output [`KV_GROUP_LEN_W-1:0] alloc_cand_size_subbank,
    output                       alloc_cand_shared,
    output [`SRAM_ID_W-1:0]      alloc_cand_sram_id,
    output [`BANK_ID_W-1:0]      alloc_cand_bank_id,
    output [`SUBBANK_ID_W-1:0]   alloc_cand_subbank_start,
    output [`KV_GROUP_LEN_W-1:0] alloc_cand_group_len,
    output                       token_wr_valid,
    output [`REQ_ID_W-1:0]       token_wr_req_id,
    output [`TOKEN_ID_W-1:0]     token_wr_token_id,
    output [`POSITION_ID_W-1:0]  token_wr_position_id,
    output [`NODE_ID_W-1:0]      token_wr_node_id,
    output [`BRANCH_ID_W-1:0]    token_wr_branch_id,
    output [`BRANCH_MASK_W-1:0]  token_wr_branch_mask,
    output                       token_wr_is_shared,
    output [`SRAM_ID_W-1:0]      token_wr_sram_id,
    output [`BANK_ID_W-1:0]      token_wr_bank_id,
    output [`SUBBANK_ID_W-1:0]   token_wr_subbank_start,
    output [`KV_GROUP_LEN_W-1:0] token_wr_group_len,
    output                       prefetch_enq_valid,
    output [`REQ_ID_W-1:0]       prefetch_enq_req_id,
    output [`BRANCH_ID_W-1:0]    prefetch_enq_branch_id,
    output [`NODE_ID_W-1:0]      prefetch_enq_node_id,
    output [`LAYER_ID_W-1:0]     prefetch_enq_layer_id,
    output [`KV_GROUP_LEN_W-1:0] prefetch_enq_size_subbank,
    output                       prefetch_enq_shared,
    output                       prefetch_flush_valid,
    output [`REQ_ID_W-1:0]       prefetch_flush_req_id,
    output [`BRANCH_MASK_W-1:0]  prefetch_flush_branch_mask,
    output [`NODE_MASK_W-1:0]    prefetch_flush_node_mask,
    output                       free_list_flush_valid,
    output [`REQ_ID_W-1:0]       free_list_flush_req_id,
    output [`BRANCH_MASK_W-1:0]  free_list_flush_branch_mask,
    output [`NODE_MASK_W-1:0]    free_list_flush_node_mask,
    output                       token_flush_valid,
    output [`REQ_ID_W-1:0]       token_flush_req_id,
    output [`BRANCH_MASK_W-1:0]  token_flush_branch_mask,
    output [`NODE_MASK_W-1:0]    token_flush_node_mask
);

localparam [1:0] AGU_STATE_IDLE       = 2'd0;
localparam [1:0] AGU_STATE_WAIT_CAND  = 2'd1;
localparam [1:0] AGU_STATE_WAIT_ALLOC = 2'd2;

localparam integer TREE_WORK_QUEUE_DEPTH =
    `TREE_MAX_PREFIX_NODES + (`TREE_MAX_FRONTIER_LEVELS * `TREE_FRONTIER_SLOTS);
localparam integer TREE_WORK_COUNT_W =
    ((TREE_WORK_QUEUE_DEPTH <= 1) ? 1 : $clog2(TREE_WORK_QUEUE_DEPTH + 1));

reg [1:0] agu_state_r;

reg [`REQ_ID_W-1:0] pending_req_id_r;
reg [`BRANCH_ID_W-1:0] pending_branch_id_r;
reg [`NODE_ID_W-1:0] pending_node_id_r;
reg pending_shared_r;
reg [`TOKEN_ID_W-1:0] pending_token_id_r;
reg [`POSITION_ID_W-1:0] pending_position_id_r;
reg [`LAYER_ID_W-1:0] pending_layer_id_r;

reg [`SRAM_ID_W-1:0] cand_sram_id_r;
reg [`BANK_ID_W-1:0] cand_bank_id_r;
reg [`SUBBANK_ID_W-1:0] cand_subbank_start_r;
reg [`KV_GROUP_LEN_W-1:0] cand_group_len_r;

reg token_wr_valid_r;

reg prefix_norm_valid_r;
reg [`REQ_ID_W-1:0] prefix_norm_req_id_r;
reg prefix_norm_node_valid_r;
reg [`NODE_ID_W-1:0] prefix_norm_node_id_r;
reg [`NODE_ID_W-1:0] prefix_norm_parent_node_id_r;
reg [`TOKEN_ID_W-1:0] prefix_norm_token_id_r;
reg [`POSITION_ID_W-1:0] prefix_norm_position_id_r;
reg [`LAYER_ID_W-1:0] prefix_norm_layer_id_r;
reg prefix_norm_is_last_r;
reg prefix_norm_is_shared_r;

reg frontier_norm_valid_r;
reg [`REQ_ID_W-1:0] frontier_norm_req_id_r;
reg [`TREE_LEVEL_ID_W-1:0] frontier_norm_level_id_r;
reg [`TREE_FRONTIER_SLOTS-1:0] frontier_norm_slot_valid_r;
reg [`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0] frontier_norm_node_id_r;
reg [`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0] frontier_norm_parent_node_id_r;
reg [`TREE_FRONTIER_SLOTS*`TOKEN_ID_W-1:0] frontier_norm_token_id_r;
reg [`TREE_FRONTIER_SLOTS*`POSITION_ID_W-1:0] frontier_norm_position_id_r;
reg [`TREE_FRONTIER_SLOTS*`KV_GROUP_LEN_W-1:0] frontier_norm_size_subbank_r;
reg [`TREE_FRONTIER_SLOTS-1:0] frontier_norm_slot_shared_r;

reg treeq_valid_r [0:TREE_WORK_QUEUE_DEPTH-1];
reg [`REQ_ID_W-1:0] treeq_req_id_r [0:TREE_WORK_QUEUE_DEPTH-1];
reg [`BRANCH_ID_W-1:0] treeq_branch_id_r [0:TREE_WORK_QUEUE_DEPTH-1];
reg [`NODE_ID_W-1:0] treeq_node_id_r [0:TREE_WORK_QUEUE_DEPTH-1];
reg treeq_shared_r [0:TREE_WORK_QUEUE_DEPTH-1];
reg [`TOKEN_ID_W-1:0] treeq_token_id_r [0:TREE_WORK_QUEUE_DEPTH-1];
reg [`POSITION_ID_W-1:0] treeq_position_id_r [0:TREE_WORK_QUEUE_DEPTH-1];
reg [`LAYER_ID_W-1:0] treeq_layer_id_r [0:TREE_WORK_QUEUE_DEPTH-1];
reg [TREE_WORK_COUNT_W-1:0] treeq_count_r;

reg treeq_valid_n [0:TREE_WORK_QUEUE_DEPTH-1];
reg [`REQ_ID_W-1:0] treeq_req_id_n [0:TREE_WORK_QUEUE_DEPTH-1];
reg [`BRANCH_ID_W-1:0] treeq_branch_id_n [0:TREE_WORK_QUEUE_DEPTH-1];
reg [`NODE_ID_W-1:0] treeq_node_id_n [0:TREE_WORK_QUEUE_DEPTH-1];
reg treeq_shared_n [0:TREE_WORK_QUEUE_DEPTH-1];
reg [`TOKEN_ID_W-1:0] treeq_token_id_n [0:TREE_WORK_QUEUE_DEPTH-1];
reg [`POSITION_ID_W-1:0] treeq_position_id_n [0:TREE_WORK_QUEUE_DEPTH-1];
reg [`LAYER_ID_W-1:0] treeq_layer_id_n [0:TREE_WORK_QUEUE_DEPTH-1];
reg [TREE_WORK_COUNT_W-1:0] treeq_count_n;

reg treeq_head_valid_comb;
reg [`REQ_ID_W-1:0] treeq_head_req_id_comb;
reg [`BRANCH_ID_W-1:0] treeq_head_branch_id_comb;
reg [`NODE_ID_W-1:0] treeq_head_node_id_comb;
reg treeq_head_shared_comb;
reg [`TOKEN_ID_W-1:0] treeq_head_token_id_comb;
reg [`POSITION_ID_W-1:0] treeq_head_position_id_comb;
reg [`LAYER_ID_W-1:0] treeq_head_layer_id_comb;

reg [`BRANCH_MASK_W-1:0] pending_branch_mask_comb;
reg [`TOKEN_ID_W-1:0] scalar_token_id_placeholder_comb;
reg [`POSITION_ID_W-1:0] scalar_position_id_placeholder_comb;
reg branch_liveness_valid_r;
reg [`REQ_ID_W-1:0] branch_liveness_req_id_r;
reg [`BRANCH_MASK_W-1:0] branch_liveness_live_mask_r;
reg branch_liveness_state_valid_comb;
reg [`REQ_ID_W-1:0] branch_liveness_state_req_id_comb;
reg [`BRANCH_MASK_W-1:0] branch_liveness_state_live_mask_comb;
reg tree_in_live_comb;
reg treeq_head_live_comb;
reg queue_entry_live_comb;
reg frontier_slot_live_comb;

reg scalar_dispatch_fire_comb;
reg treeq_dispatch_fire_comb;
reg pending_flush_hit_comb;
integer pending_flush_node_bit_i;

integer slot_i;
integer queue_i;
integer pack_idx_i;
integer frontier_slot_i;
reg [`LAYER_ID_W-1:0] frontier_layer_id_comb;

function branch_live_for_req;
    input is_shared_in;
    input [`REQ_ID_W-1:0] req_id_in;
    input [`BRANCH_ID_W-1:0] branch_id_in;
    input liveness_valid_in;
    input [`REQ_ID_W-1:0] liveness_req_id_in;
    input [`BRANCH_MASK_W-1:0] liveness_mask_in;
    begin
        branch_live_for_req = 1'b1;
        if (!is_shared_in &&
            liveness_valid_in &&
            (req_id_in == liveness_req_id_in) &&
            (branch_id_in < `BRANCH_NUM) &&
            !liveness_mask_in[branch_id_in]) begin
            branch_live_for_req = 1'b0;
        end
    end
endfunction

assign tree_in_ready =
    (agu_state_r == AGU_STATE_IDLE) &&
    !flush_freeze &&
    !flush_drain_busy &&
    prefetch_enq_ready &&
    (!tree_in_valid || tree_in_live_comb);

assign prefix_ready =
    !flush_freeze &&
    !flush_drain_busy &&
    (treeq_count_r < TREE_WORK_QUEUE_DEPTH);

assign frontier_ready =
    !flush_freeze &&
    !flush_drain_busy &&
    (treeq_count_r <= (TREE_WORK_QUEUE_DEPTH - `TREE_FRONTIER_SLOTS));

assign prefix_norm_valid = prefix_norm_valid_r;
assign prefix_norm_req_id = prefix_norm_req_id_r;
assign prefix_norm_node_valid = prefix_norm_node_valid_r;
assign prefix_norm_node_id = prefix_norm_node_id_r;
assign prefix_norm_parent_node_id = prefix_norm_parent_node_id_r;
assign prefix_norm_token_id = prefix_norm_token_id_r;
assign prefix_norm_position_id = prefix_norm_position_id_r;
assign prefix_norm_layer_id = prefix_norm_layer_id_r;
assign prefix_norm_is_last = prefix_norm_is_last_r;
assign prefix_norm_is_shared = prefix_norm_is_shared_r;

assign frontier_norm_valid = frontier_norm_valid_r;
assign frontier_norm_req_id = frontier_norm_req_id_r;
assign frontier_norm_level_id = frontier_norm_level_id_r;
assign frontier_norm_slot_valid = frontier_norm_slot_valid_r;
assign frontier_norm_node_id = frontier_norm_node_id_r;
assign frontier_norm_parent_node_id = frontier_norm_parent_node_id_r;
assign frontier_norm_token_id = frontier_norm_token_id_r;
assign frontier_norm_position_id = frontier_norm_position_id_r;
assign frontier_norm_size_subbank = frontier_norm_size_subbank_r;
assign frontier_norm_slot_shared = frontier_norm_slot_shared_r;

// Legacy compatibility only. The effective Stage B candidate handoff is now
// driven directly from free_list into bank_state_table in the same timing step
// that free_list returns the selected candidate back to AGU.
assign alloc_cand_valid = 1'b0;
assign alloc_cand_req_id = {`REQ_ID_W{1'b0}};
assign alloc_cand_branch_id = {`BRANCH_ID_W{1'b0}};
assign alloc_cand_node_id = {`NODE_ID_W{1'b0}};
assign alloc_cand_size_subbank = {`KV_GROUP_LEN_W{1'b0}};
assign alloc_cand_shared = 1'b0;
assign alloc_cand_sram_id = {`SRAM_ID_W{1'b0}};
assign alloc_cand_bank_id = {`BANK_ID_W{1'b0}};
assign alloc_cand_subbank_start = {`SUBBANK_ID_W{1'b0}};
assign alloc_cand_group_len = {`KV_GROUP_LEN_W{1'b0}};

assign token_wr_valid = token_wr_valid_r;
assign token_wr_req_id = pending_req_id_r;
assign token_wr_token_id = pending_token_id_r;
assign token_wr_position_id = pending_position_id_r;
assign token_wr_node_id = pending_node_id_r;
assign token_wr_branch_id = pending_branch_id_r;
assign token_wr_branch_mask = pending_branch_mask_comb;
assign token_wr_is_shared = pending_shared_r;
assign token_wr_sram_id = cand_sram_id_r;
assign token_wr_bank_id = cand_bank_id_r;
assign token_wr_subbank_start = cand_subbank_start_r;
assign token_wr_group_len = cand_group_len_r;

assign prefetch_enq_valid =
    (agu_state_r == AGU_STATE_IDLE) &&
    !flush_freeze &&
    !flush_drain_busy &&
    ((tree_in_valid && tree_in_live_comb) ||
     (!tree_in_valid && treeq_head_valid_comb && treeq_head_live_comb));
assign prefetch_enq_req_id =
    (tree_in_valid && tree_in_live_comb) ? tree_in_req_id : treeq_head_req_id_comb;
assign prefetch_enq_branch_id =
    (tree_in_valid && tree_in_live_comb) ? tree_in_branch_id : treeq_head_branch_id_comb;
assign prefetch_enq_node_id =
    (tree_in_valid && tree_in_live_comb) ? tree_in_node_id : treeq_head_node_id_comb;
assign prefetch_enq_layer_id =
    (tree_in_valid && tree_in_live_comb) ? {`LAYER_ID_W{1'b0}} : treeq_head_layer_id_comb;
assign prefetch_enq_size_subbank = `KV_GROUP_SIZE_SUBBANK;
assign prefetch_enq_shared =
    (tree_in_valid && tree_in_live_comb) ? 1'b0 : treeq_head_shared_comb;
assign prefetch_flush_valid = flush_ctrl_valid;
assign prefetch_flush_req_id = flush_ctrl_req_id;
assign prefetch_flush_branch_mask = flush_ctrl_branch_mask;
assign prefetch_flush_node_mask = flush_ctrl_node_mask;
assign free_list_flush_valid = flush_ctrl_valid;
assign free_list_flush_req_id = flush_ctrl_req_id;
assign free_list_flush_branch_mask = flush_ctrl_branch_mask;
assign free_list_flush_node_mask = flush_ctrl_node_mask;
assign token_flush_valid = flush_ctrl_valid;
assign token_flush_req_id = flush_ctrl_req_id;
assign token_flush_branch_mask = flush_ctrl_branch_mask;
assign token_flush_node_mask = flush_ctrl_node_mask;

always @* begin
    pending_branch_mask_comb = {`BRANCH_MASK_W{1'b0}};
    if (pending_shared_r) begin
        pending_branch_mask_comb = {`BRANCH_MASK_W{1'b1}};
    end else if (pending_branch_id_r < `BRANCH_NUM) begin
        pending_branch_mask_comb[pending_branch_id_r] = 1'b1;
    end

    scalar_token_id_placeholder_comb = {`TOKEN_ID_W{1'b0}};
    scalar_token_id_placeholder_comb[`NODE_ID_W-1:0] = tree_in_node_id;

    scalar_position_id_placeholder_comb = {`POSITION_ID_W{1'b0}};
    scalar_position_id_placeholder_comb[`NODE_ID_W-1:0] = tree_in_node_id;

    branch_liveness_state_valid_comb = branch_liveness_valid_r;
    branch_liveness_state_req_id_comb = branch_liveness_req_id_r;
    branch_liveness_state_live_mask_comb = branch_liveness_live_mask_r;
    if (branch_liveness_valid) begin
        branch_liveness_state_valid_comb = 1'b1;
        branch_liveness_state_req_id_comb = branch_liveness_req_id;
        branch_liveness_state_live_mask_comb = branch_liveness_live_mask;
    end

    tree_in_live_comb = branch_live_for_req(
        1'b0,
        tree_in_req_id,
        tree_in_branch_id,
        branch_liveness_state_valid_comb,
        branch_liveness_state_req_id_comb,
        branch_liveness_state_live_mask_comb
    );

    treeq_head_valid_comb = (treeq_count_r != {TREE_WORK_COUNT_W{1'b0}});
    treeq_head_req_id_comb = {`REQ_ID_W{1'b0}};
    treeq_head_branch_id_comb = {`BRANCH_ID_W{1'b0}};
    treeq_head_node_id_comb = {`NODE_ID_W{1'b0}};
    treeq_head_shared_comb = 1'b0;
    treeq_head_token_id_comb = {`TOKEN_ID_W{1'b0}};
    treeq_head_position_id_comb = {`POSITION_ID_W{1'b0}};
    treeq_head_layer_id_comb = {`LAYER_ID_W{1'b0}};
    if (treeq_head_valid_comb) begin
        treeq_head_req_id_comb = treeq_req_id_r[0];
        treeq_head_branch_id_comb = treeq_branch_id_r[0];
        treeq_head_node_id_comb = treeq_node_id_r[0];
        treeq_head_shared_comb = treeq_shared_r[0];
        treeq_head_token_id_comb = treeq_token_id_r[0];
        treeq_head_position_id_comb = treeq_position_id_r[0];
        treeq_head_layer_id_comb = treeq_layer_id_r[0];
    end
    treeq_head_live_comb = branch_live_for_req(
        treeq_head_shared_comb,
        treeq_head_req_id_comb,
        treeq_head_branch_id_comb,
        branch_liveness_state_valid_comb,
        branch_liveness_state_req_id_comb,
        branch_liveness_state_live_mask_comb
    );

    scalar_dispatch_fire_comb =
        (agu_state_r == AGU_STATE_IDLE) &&
        !flush_freeze &&
        !flush_drain_busy &&
        prefetch_enq_ready &&
        tree_in_valid &&
        tree_in_live_comb;

    treeq_dispatch_fire_comb =
        (agu_state_r == AGU_STATE_IDLE) &&
        !flush_freeze &&
        !flush_drain_busy &&
        prefetch_enq_ready &&
        !tree_in_valid &&
        treeq_head_valid_comb &&
        treeq_head_live_comb;

    pending_flush_hit_comb = 1'b0;
    pending_flush_node_bit_i = 0;
    if (flush_ctrl_valid &&
        !pending_shared_r &&
        (agu_state_r != AGU_STATE_IDLE) &&
        (pending_req_id_r == flush_ctrl_req_id) &&
        (pending_branch_id_r < `BRANCH_NUM)) begin
        pending_flush_node_bit_i =
            (pending_branch_id_r * `MAX_VERIFY_NODES_PER_BRANCH) +
            pending_node_id_r;

        if ((pending_flush_node_bit_i < `NODE_MASK_W) &&
            flush_ctrl_branch_mask[pending_branch_id_r] &&
            flush_ctrl_node_mask[pending_flush_node_bit_i]) begin
            pending_flush_hit_comb = 1'b1;
        end
    end
end

always @* begin
    for (queue_i = 0; queue_i < TREE_WORK_QUEUE_DEPTH; queue_i = queue_i + 1) begin
        treeq_valid_n[queue_i] = 1'b0;
        treeq_req_id_n[queue_i] = {`REQ_ID_W{1'b0}};
        treeq_branch_id_n[queue_i] = {`BRANCH_ID_W{1'b0}};
        treeq_node_id_n[queue_i] = {`NODE_ID_W{1'b0}};
        treeq_shared_n[queue_i] = 1'b0;
        treeq_token_id_n[queue_i] = {`TOKEN_ID_W{1'b0}};
        treeq_position_id_n[queue_i] = {`POSITION_ID_W{1'b0}};
        treeq_layer_id_n[queue_i] = {`LAYER_ID_W{1'b0}};
    end

    pack_idx_i = 0;
    for (queue_i = 0; queue_i < TREE_WORK_QUEUE_DEPTH; queue_i = queue_i + 1) begin
        queue_entry_live_comb = branch_live_for_req(
            treeq_shared_r[queue_i],
            treeq_req_id_r[queue_i],
            treeq_branch_id_r[queue_i],
            branch_liveness_state_valid_comb,
            branch_liveness_state_req_id_comb,
            branch_liveness_state_live_mask_comb
        );
        if (treeq_valid_r[queue_i] &&
            !(treeq_dispatch_fire_comb && (queue_i == 0)) &&
            queue_entry_live_comb) begin
            treeq_valid_n[pack_idx_i] = 1'b1;
            treeq_req_id_n[pack_idx_i] = treeq_req_id_r[queue_i];
            treeq_branch_id_n[pack_idx_i] = treeq_branch_id_r[queue_i];
            treeq_node_id_n[pack_idx_i] = treeq_node_id_r[queue_i];
            treeq_shared_n[pack_idx_i] = treeq_shared_r[queue_i];
            treeq_token_id_n[pack_idx_i] = treeq_token_id_r[queue_i];
            treeq_position_id_n[pack_idx_i] = treeq_position_id_r[queue_i];
            treeq_layer_id_n[pack_idx_i] = treeq_layer_id_r[queue_i];
            pack_idx_i = pack_idx_i + 1;
        end
    end

    if (prefix_valid && prefix_ready && prefix_node_valid) begin
        treeq_valid_n[pack_idx_i] = 1'b1;
        treeq_req_id_n[pack_idx_i] = prefix_req_id;
        treeq_branch_id_n[pack_idx_i] = {`BRANCH_ID_W{1'b0}};
        treeq_node_id_n[pack_idx_i] = prefix_node_id;
        treeq_shared_n[pack_idx_i] = 1'b1;
        treeq_token_id_n[pack_idx_i] = prefix_token_id;
        treeq_position_id_n[pack_idx_i] = prefix_position_id;
        treeq_layer_id_n[pack_idx_i] = prefix_layer_id;
        pack_idx_i = pack_idx_i + 1;
    end

    frontier_layer_id_comb = {`LAYER_ID_W{1'b0}};
    frontier_layer_id_comb[`TREE_LEVEL_ID_W-1:0] = frontier_level_id;
    if (frontier_valid && frontier_ready) begin
        for (frontier_slot_i = 0;
             frontier_slot_i < `TREE_FRONTIER_SLOTS;
             frontier_slot_i = frontier_slot_i + 1) begin
            frontier_slot_live_comb = branch_live_for_req(
                1'b0,
                frontier_req_id,
                frontier_slot_i[`BRANCH_ID_W-1:0],
                branch_liveness_state_valid_comb,
                branch_liveness_state_req_id_comb,
                branch_liveness_state_live_mask_comb
            );
            if (frontier_slot_valid[frontier_slot_i] &&
                frontier_slot_live_comb) begin
                treeq_valid_n[pack_idx_i] = 1'b1;
                treeq_req_id_n[pack_idx_i] = frontier_req_id;
                treeq_branch_id_n[pack_idx_i] =
                    frontier_slot_i[`BRANCH_ID_W-1:0];
                treeq_node_id_n[pack_idx_i] =
                    frontier_node_id[(frontier_slot_i*`NODE_ID_W) +: `NODE_ID_W];
                treeq_shared_n[pack_idx_i] = 1'b0;
                treeq_token_id_n[pack_idx_i] =
                    frontier_token_id[(frontier_slot_i*`TOKEN_ID_W) +: `TOKEN_ID_W];
                treeq_position_id_n[pack_idx_i] =
                    frontier_position_id[(frontier_slot_i*`POSITION_ID_W) +: `POSITION_ID_W];
                treeq_layer_id_n[pack_idx_i] = frontier_layer_id_comb;
                pack_idx_i = pack_idx_i + 1;
            end
        end
    end

    treeq_count_n = pack_idx_i[TREE_WORK_COUNT_W-1:0];
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        agu_state_r <= AGU_STATE_IDLE;
        pending_req_id_r <= {`REQ_ID_W{1'b0}};
        pending_branch_id_r <= {`BRANCH_ID_W{1'b0}};
        pending_node_id_r <= {`NODE_ID_W{1'b0}};
        pending_shared_r <= 1'b0;
        pending_token_id_r <= {`TOKEN_ID_W{1'b0}};
        pending_position_id_r <= {`POSITION_ID_W{1'b0}};
        pending_layer_id_r <= {`LAYER_ID_W{1'b0}};
        cand_sram_id_r <= {`SRAM_ID_W{1'b0}};
        cand_bank_id_r <= {`BANK_ID_W{1'b0}};
        cand_subbank_start_r <= {`SUBBANK_ID_W{1'b0}};
        cand_group_len_r <= {`KV_GROUP_LEN_W{1'b0}};
        token_wr_valid_r <= 1'b0;
        prefix_norm_valid_r <= 1'b0;
        prefix_norm_req_id_r <= {`REQ_ID_W{1'b0}};
        prefix_norm_node_valid_r <= 1'b0;
        prefix_norm_node_id_r <= {`NODE_ID_W{1'b0}};
        prefix_norm_parent_node_id_r <= {`NODE_ID_W{1'b0}};
        prefix_norm_token_id_r <= {`TOKEN_ID_W{1'b0}};
        prefix_norm_position_id_r <= {`POSITION_ID_W{1'b0}};
        prefix_norm_layer_id_r <= {`LAYER_ID_W{1'b0}};
        prefix_norm_is_last_r <= 1'b0;
        prefix_norm_is_shared_r <= 1'b0;
        frontier_norm_valid_r <= 1'b0;
        frontier_norm_req_id_r <= {`REQ_ID_W{1'b0}};
        frontier_norm_level_id_r <= {`TREE_LEVEL_ID_W{1'b0}};
        frontier_norm_slot_valid_r <= {`TREE_FRONTIER_SLOTS{1'b0}};
        frontier_norm_node_id_r <= {(`TREE_FRONTIER_SLOTS*`NODE_ID_W){1'b0}};
        frontier_norm_parent_node_id_r <= {(`TREE_FRONTIER_SLOTS*`NODE_ID_W){1'b0}};
        frontier_norm_token_id_r <= {(`TREE_FRONTIER_SLOTS*`TOKEN_ID_W){1'b0}};
        frontier_norm_position_id_r <= {(`TREE_FRONTIER_SLOTS*`POSITION_ID_W){1'b0}};
        frontier_norm_size_subbank_r <= {(`TREE_FRONTIER_SLOTS*`KV_GROUP_LEN_W){1'b0}};
        frontier_norm_slot_shared_r <= {`TREE_FRONTIER_SLOTS{1'b0}};
        branch_liveness_valid_r <= 1'b0;
        branch_liveness_req_id_r <= {`REQ_ID_W{1'b0}};
        branch_liveness_live_mask_r <= {`BRANCH_MASK_W{1'b1}};
        treeq_count_r <= {TREE_WORK_COUNT_W{1'b0}};
        for (queue_i = 0; queue_i < TREE_WORK_QUEUE_DEPTH; queue_i = queue_i + 1) begin
            treeq_valid_r[queue_i] <= 1'b0;
            treeq_req_id_r[queue_i] <= {`REQ_ID_W{1'b0}};
            treeq_branch_id_r[queue_i] <= {`BRANCH_ID_W{1'b0}};
            treeq_node_id_r[queue_i] <= {`NODE_ID_W{1'b0}};
            treeq_shared_r[queue_i] <= 1'b0;
            treeq_token_id_r[queue_i] <= {`TOKEN_ID_W{1'b0}};
            treeq_position_id_r[queue_i] <= {`POSITION_ID_W{1'b0}};
            treeq_layer_id_r[queue_i] <= {`LAYER_ID_W{1'b0}};
        end
    end else begin
        token_wr_valid_r <= 1'b0;
        prefix_norm_valid_r <= 1'b0;
        frontier_norm_valid_r <= 1'b0;
        if (branch_liveness_valid) begin
            branch_liveness_valid_r <= 1'b1;
            branch_liveness_req_id_r <= branch_liveness_req_id;
            branch_liveness_live_mask_r <= branch_liveness_live_mask;
        end

        treeq_count_r <= treeq_count_n;
        for (queue_i = 0; queue_i < TREE_WORK_QUEUE_DEPTH; queue_i = queue_i + 1) begin
            treeq_valid_r[queue_i] <= treeq_valid_n[queue_i];
            treeq_req_id_r[queue_i] <= treeq_req_id_n[queue_i];
            treeq_branch_id_r[queue_i] <= treeq_branch_id_n[queue_i];
            treeq_node_id_r[queue_i] <= treeq_node_id_n[queue_i];
            treeq_shared_r[queue_i] <= treeq_shared_n[queue_i];
            treeq_token_id_r[queue_i] <= treeq_token_id_n[queue_i];
            treeq_position_id_r[queue_i] <= treeq_position_id_n[queue_i];
            treeq_layer_id_r[queue_i] <= treeq_layer_id_n[queue_i];
        end

        if (!flush_freeze && prefix_valid && prefix_ready) begin
            prefix_norm_valid_r <= 1'b1;
            prefix_norm_req_id_r <= prefix_req_id;
            prefix_norm_node_valid_r <= prefix_node_valid;
            prefix_norm_node_id_r <= prefix_node_id;
            prefix_norm_parent_node_id_r <= prefix_parent_node_id;
            prefix_norm_token_id_r <= prefix_token_id;
            prefix_norm_position_id_r <= prefix_position_id;
            prefix_norm_layer_id_r <= prefix_layer_id;
            prefix_norm_is_last_r <= prefix_is_last;
            prefix_norm_is_shared_r <= 1'b1;
        end else if (!flush_freeze && frontier_valid && frontier_ready) begin
            frontier_norm_valid_r <= 1'b1;
            frontier_norm_req_id_r <= frontier_req_id;
            frontier_norm_level_id_r <= frontier_level_id;
            frontier_norm_slot_valid_r <= frontier_slot_valid;
            frontier_norm_node_id_r <= frontier_node_id;
            frontier_norm_parent_node_id_r <= frontier_parent_node_id;
            frontier_norm_token_id_r <= frontier_token_id;
            frontier_norm_position_id_r <= frontier_position_id;
            frontier_norm_slot_shared_r <= {`TREE_FRONTIER_SLOTS{1'b0}};
            for (slot_i = 0; slot_i < `TREE_FRONTIER_SLOTS; slot_i = slot_i + 1) begin
                if (frontier_slot_valid[slot_i]) begin
                    frontier_norm_size_subbank_r[(slot_i*`KV_GROUP_LEN_W) +: `KV_GROUP_LEN_W] <=
                        `KV_GROUP_SIZE_SUBBANK;
                end else begin
                    frontier_norm_size_subbank_r[(slot_i*`KV_GROUP_LEN_W) +: `KV_GROUP_LEN_W] <=
                        {`KV_GROUP_LEN_W{1'b0}};
                end
            end
        end

        if (pending_flush_hit_comb) begin
            agu_state_r <= AGU_STATE_IDLE;
            pending_req_id_r <= {`REQ_ID_W{1'b0}};
            pending_branch_id_r <= {`BRANCH_ID_W{1'b0}};
            pending_node_id_r <= {`NODE_ID_W{1'b0}};
            pending_shared_r <= 1'b0;
            pending_token_id_r <= {`TOKEN_ID_W{1'b0}};
            pending_position_id_r <= {`POSITION_ID_W{1'b0}};
            pending_layer_id_r <= {`LAYER_ID_W{1'b0}};
            cand_sram_id_r <= {`SRAM_ID_W{1'b0}};
            cand_bank_id_r <= {`BANK_ID_W{1'b0}};
            cand_subbank_start_r <= {`SUBBANK_ID_W{1'b0}};
            cand_group_len_r <= {`KV_GROUP_LEN_W{1'b0}};
        end else begin
            case (agu_state_r)
                AGU_STATE_IDLE: begin
                    if (scalar_dispatch_fire_comb) begin
                        pending_req_id_r <= tree_in_req_id;
                        pending_branch_id_r <= tree_in_branch_id;
                        pending_node_id_r <= tree_in_node_id;
                        pending_shared_r <= 1'b0;
                        pending_token_id_r <= scalar_token_id_placeholder_comb;
                        pending_position_id_r <= scalar_position_id_placeholder_comb;
                        pending_layer_id_r <= {`LAYER_ID_W{1'b0}};
                        agu_state_r <= AGU_STATE_WAIT_CAND;
                    end else if (treeq_dispatch_fire_comb) begin
                        pending_req_id_r <= treeq_head_req_id_comb;
                        pending_branch_id_r <= treeq_head_branch_id_comb;
                        pending_node_id_r <= treeq_head_node_id_comb;
                        pending_shared_r <= treeq_head_shared_comb;
                        pending_token_id_r <= treeq_head_token_id_comb;
                        pending_position_id_r <= treeq_head_position_id_comb;
                        pending_layer_id_r <= treeq_head_layer_id_comb;
                        agu_state_r <= AGU_STATE_WAIT_CAND;
                    end
                end

                AGU_STATE_WAIT_CAND: begin
                    if (cand_resp_valid && (cand_resp_req_id == pending_req_id_r)) begin
                        if (cand_resp_grant) begin
                            cand_sram_id_r <= cand_resp_sram_id;
                            cand_bank_id_r <= cand_resp_bank_id;
                            cand_subbank_start_r <= cand_resp_subbank_start;
                            cand_group_len_r <= cand_resp_group_len;
                            token_wr_valid_r <= 1'b1;
                            agu_state_r <= AGU_STATE_WAIT_ALLOC;
                        end else begin
                            agu_state_r <= AGU_STATE_IDLE;
                            pending_req_id_r <= {`REQ_ID_W{1'b0}};
                            pending_branch_id_r <= {`BRANCH_ID_W{1'b0}};
                            pending_node_id_r <= {`NODE_ID_W{1'b0}};
                            pending_shared_r <= 1'b0;
                            pending_token_id_r <= {`TOKEN_ID_W{1'b0}};
                            pending_position_id_r <= {`POSITION_ID_W{1'b0}};
                            pending_layer_id_r <= {`LAYER_ID_W{1'b0}};
                            cand_sram_id_r <= {`SRAM_ID_W{1'b0}};
                            cand_bank_id_r <= {`BANK_ID_W{1'b0}};
                            cand_subbank_start_r <= {`SUBBANK_ID_W{1'b0}};
                            cand_group_len_r <= {`KV_GROUP_LEN_W{1'b0}};
                        end
                    end
                end

                AGU_STATE_WAIT_ALLOC: begin
                    if (alloc_resp_valid && (alloc_resp_req_id == pending_req_id_r)) begin
                        agu_state_r <= AGU_STATE_IDLE;
                        pending_req_id_r <= {`REQ_ID_W{1'b0}};
                        pending_branch_id_r <= {`BRANCH_ID_W{1'b0}};
                        pending_node_id_r <= {`NODE_ID_W{1'b0}};
                        pending_shared_r <= 1'b0;
                        pending_token_id_r <= {`TOKEN_ID_W{1'b0}};
                        pending_position_id_r <= {`POSITION_ID_W{1'b0}};
                        pending_layer_id_r <= {`LAYER_ID_W{1'b0}};
                    end
                end

                default: begin
                    agu_state_r <= AGU_STATE_IDLE;
                end
            endcase
        end

        if (flush_freeze && (agu_state_r == AGU_STATE_IDLE)) begin
            pending_shared_r <= 1'b0;
        end
    end
end

endmodule
