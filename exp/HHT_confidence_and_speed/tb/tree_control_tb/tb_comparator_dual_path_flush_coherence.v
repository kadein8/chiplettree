`timescale 1ns/1ps

`include "config/prediction_params.vh"
`include "config/interface_params.vh"
`include "config/memory_params.vh"

module tb_comparator_dual_path_flush_coherence;

localparam [`REQ_ID_W-1:0] TEST_REQ_ID = 4'h3;
localparam [`REQ_ID_W-1:0] FILLER_REQ_ID = 4'h4;
localparam [`REQ_ID_W-1:0] FULL_REQ_ID = 4'h5;
localparam [`REQ_ID_W-1:0] REUSE_REQ_ID = 4'h6;

localparam [`BRANCH_ID_W-1:0] VICTIM_BRANCH_ID = 2'd1;
localparam [`NODE_ID_W-1:0]   VICTIM_NODE_ID   = 4'd2;
localparam [`BRANCH_ID_W-1:0] SURVIVOR_BRANCH_ID = 2'd0;
localparam [`NODE_ID_W-1:0]   SURVIVOR_NODE_ID   = 4'd1;
localparam [`BRANCH_ID_W-1:0] REUSE_BRANCH_ID = 2'd3;
localparam [`NODE_ID_W-1:0]   REUSE_NODE_ID   = 4'd0;

localparam [`TOKEN_ID_W-1:0] VICTIM_TOKEN_ID = VICTIM_NODE_ID;
localparam [`POSITION_ID_W-1:0] VICTIM_POSITION_ID = VICTIM_NODE_ID;
localparam [`TOKEN_ID_W-1:0] SURVIVOR_TOKEN_ID = SURVIVOR_NODE_ID;
localparam [`POSITION_ID_W-1:0] SURVIVOR_POSITION_ID = SURVIVOR_NODE_ID;

localparam integer TOTAL_BANKS = `SRAM_NUM * `SRAM_BANK_NUM;

reg clk;
reg rst_n;

reg [`REQ_ID_W-1:0] cmp_req_id;
reg [`BRANCH_NUM-1:0] cmp_slot_valid;
reg [`BRANCH_NUM*`TOKEN_ID_W-1:0] cmp_slot_real_token_id;
reg [`BRANCH_NUM*`TOKEN_ID_W-1:0] cmp_slot_candidate_token_id;
reg [`BRANCH_NUM*`NODE_ID_W-1:0] cmp_slot_node_id;
reg [`BRANCH_NUM*`NODE_ID_W-1:0] cmp_slot_parent_node_id;
reg [`BRANCH_NUM*`BRANCH_ID_W-1:0] cmp_slot_branch_id;

wire commit_valid;
wire [`BRANCH_MASK_W-1:0] commit_branch_mask;
wire [`NODE_MASK_W-1:0] commit_node_mask;
wire flush_valid;
wire [`BRANCH_MASK_W-1:0] flush_branch_mask;
wire [`NODE_MASK_W-1:0] flush_node_mask;
wire flush_freeze;

reg tree_in_valid;
wire tree_in_ready;
reg [`REQ_ID_W-1:0] tree_in_req_id;
reg [`BRANCH_ID_W-1:0] tree_in_branch_id;
reg [`NODE_ID_W-1:0] tree_in_node_id;

wire prefix_ready;
wire frontier_ready;

wire prefetch_enq_ready;
wire prefetch_enq_valid;
wire [`REQ_ID_W-1:0] prefetch_enq_req_id;
wire [`BRANCH_ID_W-1:0] prefetch_enq_branch_id;
wire [`NODE_ID_W-1:0] prefetch_enq_node_id;
wire [`LAYER_ID_W-1:0] prefetch_enq_layer_id;
wire [`KV_GROUP_LEN_W-1:0] prefetch_enq_size_subbank;
wire prefetch_enq_shared;

wire prefetch_flush_valid;
wire [`REQ_ID_W-1:0] prefetch_flush_req_id;
wire [`BRANCH_MASK_W-1:0] prefetch_flush_branch_mask;
wire [`NODE_MASK_W-1:0] prefetch_flush_node_mask;

wire free_list_flush_valid;
wire [`REQ_ID_W-1:0] free_list_flush_req_id;
wire [`BRANCH_MASK_W-1:0] free_list_flush_branch_mask;
wire [`NODE_MASK_W-1:0] free_list_flush_node_mask;

wire token_flush_valid;
wire [`REQ_ID_W-1:0] token_flush_req_id;
wire [`BRANCH_MASK_W-1:0] token_flush_branch_mask;
wire [`NODE_MASK_W-1:0] token_flush_node_mask;

wire queue_deq_valid;
wire queue_deq_ready;
wire [`REQ_ID_W-1:0] queue_deq_req_id;
wire [`BRANCH_ID_W-1:0] queue_deq_branch_id;
wire [`NODE_ID_W-1:0] queue_deq_node_id;
wire [`LAYER_ID_W-1:0] queue_deq_layer_id;
wire [`KV_GROUP_LEN_W-1:0] queue_deq_size_subbank;
wire queue_deq_shared;

wire cand_resp_valid;
wire cand_resp_grant;
wire [`REQ_ID_W-1:0] cand_resp_req_id;
wire [`SRAM_ID_W-1:0] cand_resp_sram_id;
wire [`BANK_ID_W-1:0] cand_resp_bank_id;
wire [`SUBBANK_ID_W-1:0] cand_resp_subbank_start;
wire [`KV_GROUP_LEN_W-1:0] cand_resp_group_len;

wire alloc_cand_valid;
wire [`REQ_ID_W-1:0] alloc_cand_req_id;
wire [`BRANCH_ID_W-1:0] alloc_cand_branch_id;
wire [`NODE_ID_W-1:0] alloc_cand_node_id;
wire [`KV_GROUP_LEN_W-1:0] alloc_cand_size_subbank;
wire alloc_cand_shared;
wire [`SRAM_ID_W-1:0] alloc_cand_sram_id;
wire [`BANK_ID_W-1:0] alloc_cand_bank_id;
wire [`SUBBANK_ID_W-1:0] alloc_cand_subbank_start;
wire [`KV_GROUP_LEN_W-1:0] alloc_cand_group_len;

wire flush_reclaim_valid;
wire [`SRAM_ID_W-1:0] flush_reclaim_sram_id;
wire [`BANK_ID_W-1:0] flush_reclaim_bank_id;
wire [`SUBBANK_ID_W-1:0] flush_reclaim_subbank_start;
wire [`KV_GROUP_LEN_W-1:0] flush_reclaim_group_len;

wire alloc_resp_valid;
wire alloc_resp_grant;
wire [`REQ_ID_W-1:0] alloc_resp_req_id;
wire [`SRAM_ID_W-1:0] alloc_resp_sram_id;
wire [`BANK_ID_W-1:0] alloc_resp_bank_id;
wire [`SUBBANK_ID_W-1:0] alloc_resp_subbank_start;
wire [`KV_GROUP_LEN_W-1:0] alloc_resp_group_len;
wire [`BANK_OCC_BITMAP_W-1:0] alloc_resp_occ_bitmap;

wire token_wr_valid;
wire [`REQ_ID_W-1:0] token_wr_req_id;
wire [`TOKEN_ID_W-1:0] token_wr_token_id;
wire [`POSITION_ID_W-1:0] token_wr_position_id;
wire [`NODE_ID_W-1:0] token_wr_node_id;
wire [`BRANCH_ID_W-1:0] token_wr_branch_id;
wire [`BRANCH_MASK_W-1:0] token_wr_branch_mask;
wire token_wr_is_shared;
wire [`SRAM_ID_W-1:0] token_wr_sram_id;
wire [`BANK_ID_W-1:0] token_wr_bank_id;
wire [`SUBBANK_ID_W-1:0] token_wr_subbank_start;
wire [`KV_GROUP_LEN_W-1:0] token_wr_group_len;

reg query_valid;
reg [`SRAM_ID_W-1:0] query_sram_id;
reg [`BANK_ID_W-1:0] query_bank_id;
wire query_resp_valid;
wire [`BANK_OCC_BITMAP_W-1:0] query_resp_occ_bitmap;
wire [`BANK_STATE_W-1:0] query_resp_state;
wire [`BRANCH_MASK_W-1:0] query_resp_branch_mask;
wire [`REFCNT_W-1:0] query_resp_refcnt;

reg lookup_valid;
wire lookup_ready;
reg [`REQ_ID_W-1:0] lookup_req_id;
reg [`TOKEN_ID_W-1:0] lookup_token_id;
reg [`POSITION_ID_W-1:0] lookup_position_id;
wire lookup_resp_valid;
wire lookup_resp_hit;
wire [`REQ_ID_W-1:0] lookup_resp_req_id;
wire [`SRAM_ID_W-1:0] lookup_resp_sram_id;
wire [`BANK_ID_W-1:0] lookup_resp_bank_id;
wire [`SUBBANK_ID_W-1:0] lookup_resp_subbank_start;
wire [`KV_GROUP_LEN_W-1:0] lookup_resp_group_len;
wire [`BRANCH_MASK_W-1:0] lookup_resp_branch_mask;
wire lookup_resp_is_shared;
wire [`TOKEN_STATE_W-1:0] lookup_resp_state;
wire [`TOKEN_REG_INDEX_W:0] token_entry_count;
wire token_error_flag;

reg [`TOKEN_REG_INDEX_W-1:0] token_wr_index_r;

reg [`SRAM_ID_W-1:0] victim_sram_id_r;
reg [`BANK_ID_W-1:0] victim_bank_id_r;
reg [`SUBBANK_ID_W-1:0] victim_subbank_start_r;
reg [`KV_GROUP_LEN_W-1:0] victim_group_len_r;

reg [`SRAM_ID_W-1:0] survivor_sram_id_r;
reg [`BANK_ID_W-1:0] survivor_bank_id_r;
reg [`SUBBANK_ID_W-1:0] survivor_subbank_start_r;
reg [`KV_GROUP_LEN_W-1:0] survivor_group_len_r;

reg [`SRAM_ID_W-1:0] reuse_sram_id_r;
reg [`BANK_ID_W-1:0] reuse_bank_id_r;
reg [`SUBBANK_ID_W-1:0] reuse_subbank_start_r;
reg [`KV_GROUP_LEN_W-1:0] reuse_group_len_r;

reg [`BANK_OCC_BITMAP_W-1:0] query_bitmap_r;

comparator u_comparator (
    .clk(clk),
    .rst_n(rst_n),
    .cmp_req_id(cmp_req_id),
    .cmp_slot_valid(cmp_slot_valid),
    .cmp_slot_real_token_id(cmp_slot_real_token_id),
    .cmp_slot_candidate_token_id(cmp_slot_candidate_token_id),
    .cmp_slot_node_id(cmp_slot_node_id),
    .cmp_slot_parent_node_id(cmp_slot_parent_node_id),
    .cmp_slot_branch_id(cmp_slot_branch_id),
    .commit_valid(commit_valid),
    .commit_branch_mask(commit_branch_mask),
    .commit_node_mask(commit_node_mask),
    .flush_valid(flush_valid),
    .flush_branch_mask(flush_branch_mask),
    .flush_node_mask(flush_node_mask)
);

assign flush_freeze = flush_valid;

agu u_agu (
    .clk(clk),
    .rst_n(rst_n),
    .tree_in_valid(tree_in_valid),
    .tree_in_ready(tree_in_ready),
    .tree_in_req_id(tree_in_req_id),
    .tree_in_branch_id(tree_in_branch_id),
    .tree_in_node_id(tree_in_node_id),
    .prefix_valid(1'b0),
    .prefix_ready(prefix_ready),
    .prefix_req_id({`REQ_ID_W{1'b0}}),
    .prefix_node_valid(1'b0),
    .prefix_node_id({`NODE_ID_W{1'b0}}),
    .prefix_parent_node_id({`NODE_ID_W{1'b0}}),
    .prefix_token_id({`TOKEN_ID_W{1'b0}}),
    .prefix_position_id({`POSITION_ID_W{1'b0}}),
    .prefix_layer_id({`LAYER_ID_W{1'b0}}),
    .prefix_is_last(1'b0),
    .frontier_valid(1'b0),
    .frontier_ready(frontier_ready),
    .frontier_req_id({`REQ_ID_W{1'b0}}),
    .frontier_level_id({`TREE_LEVEL_ID_W{1'b0}}),
    .frontier_slot_valid({`TREE_FRONTIER_SLOTS{1'b0}}),
    .frontier_node_id({(`TREE_FRONTIER_SLOTS*`NODE_ID_W){1'b0}}),
    .frontier_parent_node_id({(`TREE_FRONTIER_SLOTS*`NODE_ID_W){1'b0}}),
    .frontier_token_id({(`TREE_FRONTIER_SLOTS*`TOKEN_ID_W){1'b0}}),
    .frontier_position_id({(`TREE_FRONTIER_SLOTS*`POSITION_ID_W){1'b0}}),
    .prefetch_enq_ready(prefetch_enq_ready),
    .cand_resp_valid(cand_resp_valid),
    .cand_resp_grant(cand_resp_grant),
    .cand_resp_req_id(cand_resp_req_id),
    .cand_resp_sram_id(cand_resp_sram_id),
    .cand_resp_bank_id(cand_resp_bank_id),
    .cand_resp_subbank_start(cand_resp_subbank_start),
    .cand_resp_group_len(cand_resp_group_len),
    .alloc_resp_valid(alloc_resp_valid),
    .alloc_resp_grant(alloc_resp_grant),
    .alloc_resp_req_id(alloc_resp_req_id),
    .alloc_resp_sram_id(alloc_resp_sram_id),
    .alloc_resp_bank_id(alloc_resp_bank_id),
    .alloc_resp_subbank_start(alloc_resp_subbank_start),
    .alloc_resp_group_len(alloc_resp_group_len),
    .flush_freeze(flush_valid),
    .flush_drain_busy(1'b0),
    .flush_ctrl_valid(flush_valid),
    .flush_ctrl_req_id(cmp_req_id),
    .flush_ctrl_branch_mask(flush_branch_mask),
    .flush_ctrl_node_mask(flush_node_mask),
    .prefix_norm_valid(),
    .prefix_norm_req_id(),
    .prefix_norm_node_valid(),
    .prefix_norm_node_id(),
    .prefix_norm_parent_node_id(),
    .prefix_norm_token_id(),
    .prefix_norm_position_id(),
    .prefix_norm_layer_id(),
    .prefix_norm_is_last(),
    .prefix_norm_is_shared(),
    .frontier_norm_valid(),
    .frontier_norm_req_id(),
    .frontier_norm_level_id(),
    .frontier_norm_slot_valid(),
    .frontier_norm_node_id(),
    .frontier_norm_parent_node_id(),
    .frontier_norm_token_id(),
    .frontier_norm_position_id(),
    .frontier_norm_size_subbank(),
    .frontier_norm_slot_shared(),
    .alloc_cand_valid(),
    .alloc_cand_req_id(),
    .alloc_cand_branch_id(),
    .alloc_cand_node_id(),
    .alloc_cand_size_subbank(),
    .alloc_cand_shared(),
    .alloc_cand_sram_id(),
    .alloc_cand_bank_id(),
    .alloc_cand_subbank_start(),
    .alloc_cand_group_len(),
    .token_wr_valid(token_wr_valid),
    .token_wr_req_id(token_wr_req_id),
    .token_wr_token_id(token_wr_token_id),
    .token_wr_position_id(token_wr_position_id),
    .token_wr_node_id(token_wr_node_id),
    .token_wr_branch_id(token_wr_branch_id),
    .token_wr_branch_mask(token_wr_branch_mask),
    .token_wr_is_shared(token_wr_is_shared),
    .token_wr_sram_id(token_wr_sram_id),
    .token_wr_bank_id(token_wr_bank_id),
    .token_wr_subbank_start(token_wr_subbank_start),
    .token_wr_group_len(token_wr_group_len),
    .prefetch_enq_valid(prefetch_enq_valid),
    .prefetch_enq_req_id(prefetch_enq_req_id),
    .prefetch_enq_branch_id(prefetch_enq_branch_id),
    .prefetch_enq_node_id(prefetch_enq_node_id),
    .prefetch_enq_layer_id(prefetch_enq_layer_id),
    .prefetch_enq_size_subbank(prefetch_enq_size_subbank),
    .prefetch_enq_shared(prefetch_enq_shared),
    .prefetch_flush_valid(prefetch_flush_valid),
    .prefetch_flush_req_id(prefetch_flush_req_id),
    .prefetch_flush_branch_mask(prefetch_flush_branch_mask),
    .prefetch_flush_node_mask(prefetch_flush_node_mask),
    .free_list_flush_valid(free_list_flush_valid),
    .free_list_flush_req_id(free_list_flush_req_id),
    .free_list_flush_branch_mask(free_list_flush_branch_mask),
    .free_list_flush_node_mask(free_list_flush_node_mask),
    .token_flush_valid(token_flush_valid),
    .token_flush_req_id(token_flush_req_id),
    .token_flush_branch_mask(token_flush_branch_mask),
    .token_flush_node_mask(token_flush_node_mask)
);

prefetch_queue u_prefetch_queue (
    .clk(clk),
    .rst_n(rst_n),
    .enq_valid(prefetch_enq_valid),
    .enq_ready(prefetch_enq_ready),
    .enq_req_id(prefetch_enq_req_id),
    .enq_branch_id(prefetch_enq_branch_id),
    .enq_node_id(prefetch_enq_node_id),
    .enq_layer_id(prefetch_enq_layer_id),
    .enq_size_subbank(prefetch_enq_size_subbank),
    .enq_shared(prefetch_enq_shared),
    .flush_valid(prefetch_flush_valid),
    .flush_req_id(prefetch_flush_req_id),
    .flush_branch_mask(prefetch_flush_branch_mask),
    .flush_node_mask(prefetch_flush_node_mask),
    .deq_valid(queue_deq_valid),
    .deq_ready(queue_deq_ready),
    .deq_req_id(queue_deq_req_id),
    .deq_branch_id(queue_deq_branch_id),
    .deq_node_id(queue_deq_node_id),
    .deq_layer_id(queue_deq_layer_id),
    .deq_size_subbank(queue_deq_size_subbank),
    .deq_shared(queue_deq_shared)
);

free_list u_free_list (
    .clk(clk),
    .rst_n(rst_n),
    .cand_req_valid(queue_deq_valid),
    .cand_req_ready(queue_deq_ready),
    .cand_req_req_id(queue_deq_req_id),
    .cand_req_branch_id(queue_deq_branch_id),
    .cand_req_node_id(queue_deq_node_id),
    .cand_req_size_subbank(queue_deq_size_subbank),
    .cand_req_shared(queue_deq_shared),
    .cand_resp_valid(cand_resp_valid),
    .cand_resp_grant(cand_resp_grant),
    .cand_resp_req_id(cand_resp_req_id),
    .cand_resp_sram_id(cand_resp_sram_id),
    .cand_resp_bank_id(cand_resp_bank_id),
    .cand_resp_subbank_start(cand_resp_subbank_start),
    .cand_resp_group_len(cand_resp_group_len),
    .alloc_cand_valid(alloc_cand_valid),
    .alloc_cand_req_id(alloc_cand_req_id),
    .alloc_cand_branch_id(alloc_cand_branch_id),
    .alloc_cand_node_id(alloc_cand_node_id),
    .alloc_cand_size_subbank(alloc_cand_size_subbank),
    .alloc_cand_shared(alloc_cand_shared),
    .alloc_cand_sram_id(alloc_cand_sram_id),
    .alloc_cand_bank_id(alloc_cand_bank_id),
    .alloc_cand_subbank_start(alloc_cand_subbank_start),
    .alloc_cand_group_len(alloc_cand_group_len),
    .flush_valid(free_list_flush_valid),
    .flush_req_id(free_list_flush_req_id),
    .flush_branch_mask(free_list_flush_branch_mask),
    .flush_node_mask(free_list_flush_node_mask),
    .flush_reclaim_valid(flush_reclaim_valid),
    .flush_reclaim_sram_id(flush_reclaim_sram_id),
    .flush_reclaim_bank_id(flush_reclaim_bank_id),
    .flush_reclaim_subbank_start(flush_reclaim_subbank_start),
    .flush_reclaim_group_len(flush_reclaim_group_len),
    .release_valid(1'b0),
    .release_sram_id({`SRAM_ID_W{1'b0}}),
    .release_bank_id({`BANK_ID_W{1'b0}}),
    .release_subbank_start({`SUBBANK_ID_W{1'b0}}),
    .release_group_len({`KV_GROUP_LEN_W{1'b0}})
);

bank_state_table u_bank_state_table (
    .clk(clk),
    .rst_n(rst_n),
    .cand_valid(alloc_cand_valid),
    .cand_ready(),
    .cand_req_id(alloc_cand_req_id),
    .cand_branch_id(alloc_cand_branch_id),
    .cand_node_id(alloc_cand_node_id),
    .cand_size_subbank(alloc_cand_size_subbank),
    .cand_shared(alloc_cand_shared),
    .cand_sram_id(alloc_cand_sram_id),
    .cand_bank_id(alloc_cand_bank_id),
    .cand_subbank_start(alloc_cand_subbank_start),
    .cand_group_len(alloc_cand_group_len),
    .alloc_resp_valid(alloc_resp_valid),
    .alloc_resp_grant(alloc_resp_grant),
    .alloc_resp_req_id(alloc_resp_req_id),
    .alloc_resp_sram_id(alloc_resp_sram_id),
    .alloc_resp_bank_id(alloc_resp_bank_id),
    .alloc_resp_subbank_start(alloc_resp_subbank_start),
    .alloc_resp_group_len(alloc_resp_group_len),
    .alloc_resp_occ_bitmap(alloc_resp_occ_bitmap),
    .commit_valid(1'b0),
    .commit_req_id({`REQ_ID_W{1'b0}}),
    .commit_sram_id({`SRAM_ID_W{1'b0}}),
    .commit_bank_id({`BANK_ID_W{1'b0}}),
    .commit_subbank_start({`SUBBANK_ID_W{1'b0}}),
    .commit_group_len({`KV_GROUP_LEN_W{1'b0}}),
    .commit_branch_mask({`BRANCH_MASK_W{1'b0}}),
    .commit_node_mask({`NODE_MASK_W{1'b0}}),
    .flush_valid(1'b0),
    .flush_req_id({`REQ_ID_W{1'b0}}),
    .flush_branch_mask({`BRANCH_MASK_W{1'b0}}),
    .flush_node_mask({`NODE_MASK_W{1'b0}}),
    .reclaim_valid(flush_reclaim_valid),
    .reclaim_sram_id(flush_reclaim_sram_id),
    .reclaim_bank_id(flush_reclaim_bank_id),
    .reclaim_subbank_start(flush_reclaim_subbank_start),
    .reclaim_group_len(flush_reclaim_group_len),
    .query_valid(query_valid),
    .query_sram_id(query_sram_id),
    .query_bank_id(query_bank_id),
    .query_resp_valid(query_resp_valid),
    .query_resp_occ_bitmap(query_resp_occ_bitmap),
    .query_resp_state(query_resp_state),
    .query_resp_branch_mask(query_resp_branch_mask),
    .query_resp_refcnt(query_resp_refcnt)
);

token_register u_token_register (
    .clk(clk),
    .rst_n(rst_n),
    .wr_valid(token_wr_valid),
    .wr_ready(),
    .wr_index(token_wr_index_r),
    .wr_req_id(token_wr_req_id),
    .wr_token_id(token_wr_token_id),
    .wr_position_id(token_wr_position_id),
    .wr_node_id(token_wr_node_id),
    .wr_branch_id(token_wr_branch_id),
    .wr_sram_id(token_wr_sram_id),
    .wr_bank_id(token_wr_bank_id),
    .wr_subbank_start(token_wr_subbank_start),
    .wr_group_len(token_wr_group_len),
    .wr_branch_mask(token_wr_branch_mask),
    .wr_is_shared(token_wr_is_shared),
    .lookup_valid(lookup_valid),
    .lookup_ready(lookup_ready),
    .lookup_req_id(lookup_req_id),
    .lookup_token_id(lookup_token_id),
    .lookup_position_id(lookup_position_id),
    .lookup_resp_valid(lookup_resp_valid),
    .lookup_resp_hit(lookup_resp_hit),
    .lookup_resp_req_id(lookup_resp_req_id),
    .lookup_resp_sram_id(lookup_resp_sram_id),
    .lookup_resp_bank_id(lookup_resp_bank_id),
    .lookup_resp_subbank_start(lookup_resp_subbank_start),
    .lookup_resp_group_len(lookup_resp_group_len),
    .lookup_resp_branch_mask(lookup_resp_branch_mask),
    .lookup_resp_is_shared(lookup_resp_is_shared),
        .lookup_resp_entry_type(),
.lookup_resp_state(lookup_resp_state),
    .commit_valid(1'b0),
    .commit_index({`TOKEN_REG_INDEX_W{1'b0}}),
    .commit_req_id({`REQ_ID_W{1'b0}}),
    .commit_branch_mask({`BRANCH_MASK_W{1'b0}}),
    .commit_node_mask({`NODE_MASK_W{1'b0}}),
    .flush_valid(token_flush_valid),
    .flush_req_id(token_flush_req_id),
    .flush_branch_mask(token_flush_branch_mask),
    .flush_node_mask(token_flush_node_mask),
    .entry_count(token_entry_count),
    .error_flag(token_error_flag)
);

always #5 clk = ~clk;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        token_wr_index_r <= {`TOKEN_REG_INDEX_W{1'b0}};
    end else if (token_wr_valid) begin
        token_wr_index_r <= token_wr_index_r + 1'b1;
    end
end

task clear_comparator_inputs;
    begin
        cmp_req_id = {`REQ_ID_W{1'b0}};
        cmp_slot_valid = {`BRANCH_NUM{1'b0}};
        cmp_slot_real_token_id = {(`BRANCH_NUM*`TOKEN_ID_W){1'b0}};
        cmp_slot_candidate_token_id = {(`BRANCH_NUM*`TOKEN_ID_W){1'b0}};
        cmp_slot_node_id = {(`BRANCH_NUM*`NODE_ID_W){1'b0}};
        cmp_slot_parent_node_id = {(`BRANCH_NUM*`NODE_ID_W){1'b0}};
        cmp_slot_branch_id = {(`BRANCH_NUM*`BRANCH_ID_W){1'b0}};
    end
endtask

task clear_tree_input;
    begin
        tree_in_valid = 1'b0;
        tree_in_req_id = {`REQ_ID_W{1'b0}};
        tree_in_branch_id = {`BRANCH_ID_W{1'b0}};
        tree_in_node_id = {`NODE_ID_W{1'b0}};
    end
endtask

task clear_query;
    begin
        query_valid = 1'b0;
        query_sram_id = {`SRAM_ID_W{1'b0}};
        query_bank_id = {`BANK_ID_W{1'b0}};
    end
endtask

task clear_lookup;
    begin
        lookup_valid = 1'b0;
        lookup_req_id = {`REQ_ID_W{1'b0}};
        lookup_token_id = {`TOKEN_ID_W{1'b0}};
        lookup_position_id = {`POSITION_ID_W{1'b0}};
    end
endtask

task drive_scalar_req;
    input [`REQ_ID_W-1:0] req_id;
    input [`BRANCH_ID_W-1:0] branch_id;
    input [`NODE_ID_W-1:0] node_id;
    begin
        @(posedge clk);
        #1;
        if (!tree_in_ready) begin
            $fatal(1, "AGU not ready for scalar request");
        end

        tree_in_valid = 1'b1;
        tree_in_req_id = req_id;
        tree_in_branch_id = branch_id;
        tree_in_node_id = node_id;

        @(posedge clk);
        #1;
        clear_tree_input();
    end
endtask

task wait_for_cand_resp;
    input [255:0] scenario_name;
    input [`REQ_ID_W-1:0] expect_req_id;
    input expect_grant;
    input [1:0] capture_kind;
    integer wait_i;
    reg seen;
    begin
        seen = 1'b0;
        for (wait_i = 0; wait_i < 40; wait_i = wait_i + 1) begin
            @(negedge clk);
            #1;
            if (cand_resp_valid) begin
                if (cand_resp_req_id != expect_req_id) begin
                    $fatal(1, "%0s: cand_resp req_id mismatch", scenario_name);
                end
                if (cand_resp_grant != expect_grant) begin
                    $fatal(1, "%0s: cand_resp grant mismatch", scenario_name);
                end
                if (expect_grant &&
                    (cand_resp_group_len != `KV_GROUP_SIZE_SUBBANK)) begin
                    $fatal(1, "%0s: cand_resp group length mismatch", scenario_name);
                end

                if (expect_grant && (capture_kind == 2'd1)) begin
                    victim_sram_id_r = cand_resp_sram_id;
                    victim_bank_id_r = cand_resp_bank_id;
                    victim_subbank_start_r = cand_resp_subbank_start;
                    victim_group_len_r = cand_resp_group_len;
                end else if (expect_grant && (capture_kind == 2'd2)) begin
                    survivor_sram_id_r = cand_resp_sram_id;
                    survivor_bank_id_r = cand_resp_bank_id;
                    survivor_subbank_start_r = cand_resp_subbank_start;
                    survivor_group_len_r = cand_resp_group_len;
                end else if (expect_grant && (capture_kind == 2'd3)) begin
                    reuse_sram_id_r = cand_resp_sram_id;
                    reuse_bank_id_r = cand_resp_bank_id;
                    reuse_subbank_start_r = cand_resp_subbank_start;
                    reuse_group_len_r = cand_resp_group_len;
                end

                seen = 1'b1;
                disable wait_for_cand_resp;
            end
        end

        if (!seen) begin
            $fatal(1, "%0s: cand_resp did not appear within bounded wait", scenario_name);
        end
    end
endtask

task wait_for_alloc_resp;
    input [255:0] scenario_name;
    input [`REQ_ID_W-1:0] expect_req_id;
    integer wait_i;
    reg seen;
    begin
        seen = 1'b0;
        for (wait_i = 0; wait_i < 40; wait_i = wait_i + 1) begin
            @(negedge clk);
            #1;
            if (alloc_resp_valid) begin
                if (!alloc_resp_grant) begin
                    $fatal(1, "%0s: alloc_resp grant mismatch", scenario_name);
                end
                if (alloc_resp_req_id != expect_req_id) begin
                    $fatal(1, "%0s: alloc_resp req_id mismatch", scenario_name);
                end
                seen = 1'b1;
                disable wait_for_alloc_resp;
            end
        end

        if (!seen) begin
            $fatal(1, "%0s: alloc_resp did not appear within bounded wait", scenario_name);
        end
    end
endtask

task issue_req_expect_grant;
    input [255:0] scenario_name;
    input [`REQ_ID_W-1:0] req_id;
    input [`BRANCH_ID_W-1:0] branch_id;
    input [`NODE_ID_W-1:0] node_id;
    input [1:0] capture_kind;
    begin
        drive_scalar_req(req_id, branch_id, node_id);
        wait_for_cand_resp(scenario_name, req_id, 1'b1, capture_kind);
        wait_for_alloc_resp(scenario_name, req_id);
    end
endtask

task issue_req_expect_deny;
    input [255:0] scenario_name;
    input [`REQ_ID_W-1:0] req_id;
    input [`BRANCH_ID_W-1:0] branch_id;
    input [`NODE_ID_W-1:0] node_id;
    begin
        drive_scalar_req(req_id, branch_id, node_id);
        wait_for_cand_resp(scenario_name, req_id, 1'b0, 2'd0);
    end
endtask

task query_bank_bitmap;
    input [`SRAM_ID_W-1:0] sram_id;
    input [`BANK_ID_W-1:0] bank_id;
    begin
        @(posedge clk);
        #1;
        query_valid = 1'b1;
        query_sram_id = sram_id;
        query_bank_id = bank_id;
        #1;
        if (!query_resp_valid) begin
            $fatal(1, "bank_state_table query response missing");
        end
        query_bitmap_r = query_resp_occ_bitmap;
        @(posedge clk);
        #1;
        clear_query();
    end
endtask

task expect_range_occupied;
    input [255:0] scenario_name;
    input [`BANK_OCC_BITMAP_W-1:0] bitmap;
    input [`SUBBANK_ID_W-1:0] subbank_start;
    input [`KV_GROUP_LEN_W-1:0] group_len;
    integer bit_i;
    begin
        for (bit_i = 0; bit_i < group_len; bit_i = bit_i + 1) begin
            if (!bitmap[subbank_start + bit_i]) begin
                $fatal(1, "%0s: expected occupied range bit missing", scenario_name);
            end
        end
    end
endtask

task expect_range_free;
    input [255:0] scenario_name;
    input [`BANK_OCC_BITMAP_W-1:0] bitmap;
    input [`SUBBANK_ID_W-1:0] subbank_start;
    input [`KV_GROUP_LEN_W-1:0] group_len;
    integer bit_i;
    begin
        for (bit_i = 0; bit_i < group_len; bit_i = bit_i + 1) begin
            if (bitmap[subbank_start + bit_i]) begin
                $fatal(1, "%0s: expected free range bit still occupied", scenario_name);
            end
        end
    end
endtask

task lookup_expect;
    input [255:0] scenario_name;
    input [`REQ_ID_W-1:0] req_id;
    input [`TOKEN_ID_W-1:0] token_id;
    input [`POSITION_ID_W-1:0] position_id;
    input expect_hit;
    input [`BRANCH_MASK_W-1:0] expect_branch_mask;
    begin
        @(posedge clk);
        #1;
        lookup_valid = 1'b1;
        lookup_req_id = req_id;
        lookup_token_id = token_id;
        lookup_position_id = position_id;

        @(posedge clk);
        #1;
        if (!lookup_resp_valid) begin
            $fatal(1, "%0s: lookup response missing", scenario_name);
        end
        if (lookup_resp_req_id != req_id) begin
            $fatal(1, "%0s: lookup req_id mismatch", scenario_name);
        end
        if (lookup_resp_hit != expect_hit) begin
            $fatal(1, "%0s: lookup hit mismatch", scenario_name);
        end

        if (expect_hit) begin
            if (lookup_resp_branch_mask != expect_branch_mask) begin
                $fatal(1, "%0s: lookup branch mask mismatch", scenario_name);
            end
            if (lookup_resp_state == {`TOKEN_STATE_W{1'b0}}) begin
                $fatal(1, "%0s: expected non-invalid token state", scenario_name);
            end
        end else begin
            if (lookup_resp_state != {`TOKEN_STATE_W{1'b0}}) begin
                $fatal(1, "%0s: expected invalid token state on miss", scenario_name);
            end
        end

        @(posedge clk);
        #1;
        clear_lookup();
    end
endtask

task expect_accept_open;
    input [255:0] scenario_name;
    begin
        #1;
        if (flush_valid ||
            (flush_freeze !== 1'b0) ||
            !tree_in_ready ||
            !prefix_ready ||
            !frontier_ready ||
            prefetch_flush_valid ||
            free_list_flush_valid ||
            token_flush_valid) begin
            $fatal(1, "%0s: AGU acceptance should be open without flush", scenario_name);
        end
    end
endtask

task hold_queue_deq;
    begin
        force queue_deq_ready = 1'b0;
    end
endtask

task release_queue_deq;
    begin
        release queue_deq_ready;
    end
endtask

task preload_prefetch_queue_victim_survivor;
    integer clear_slot_i;
    begin
        for (clear_slot_i = 0; clear_slot_i < `PREFETCH_Q_DEPTH; clear_slot_i = clear_slot_i + 1) begin
            u_prefetch_queue.entry_valid_r[clear_slot_i] = 1'b0;
            u_prefetch_queue.entry_req_id_r[clear_slot_i] = {`REQ_ID_W{1'b0}};
            u_prefetch_queue.entry_branch_id_r[clear_slot_i] = {`BRANCH_ID_W{1'b0}};
            u_prefetch_queue.entry_node_id_r[clear_slot_i] = {`NODE_ID_W{1'b0}};
            u_prefetch_queue.entry_layer_id_r[clear_slot_i] = {`LAYER_ID_W{1'b0}};
            u_prefetch_queue.entry_size_subbank_r[clear_slot_i] = {`KV_GROUP_LEN_W{1'b0}};
            u_prefetch_queue.entry_shared_r[clear_slot_i] = 1'b0;
        end

        u_prefetch_queue.entry_valid_r[0] = 1'b1;
        u_prefetch_queue.entry_req_id_r[0] = TEST_REQ_ID;
        u_prefetch_queue.entry_branch_id_r[0] = VICTIM_BRANCH_ID;
        u_prefetch_queue.entry_node_id_r[0] = VICTIM_NODE_ID;
        u_prefetch_queue.entry_layer_id_r[0] = {`LAYER_ID_W{1'b0}};
        u_prefetch_queue.entry_size_subbank_r[0] = `KV_GROUP_SIZE_SUBBANK;
        u_prefetch_queue.entry_shared_r[0] = 1'b0;

        u_prefetch_queue.entry_valid_r[1] = 1'b1;
        u_prefetch_queue.entry_req_id_r[1] = TEST_REQ_ID;
        u_prefetch_queue.entry_branch_id_r[1] = SURVIVOR_BRANCH_ID;
        u_prefetch_queue.entry_node_id_r[1] = SURVIVOR_NODE_ID;
        u_prefetch_queue.entry_layer_id_r[1] = {`LAYER_ID_W{1'b0}};
        u_prefetch_queue.entry_size_subbank_r[1] = `KV_GROUP_SIZE_SUBBANK;
        u_prefetch_queue.entry_shared_r[1] = 1'b0;

        u_prefetch_queue.entry_count_r = 2;
    end
endtask

task clear_prefetch_queue_state;
    integer clear_slot_i;
    begin
        for (clear_slot_i = 0; clear_slot_i < `PREFETCH_Q_DEPTH; clear_slot_i = clear_slot_i + 1) begin
            u_prefetch_queue.entry_valid_r[clear_slot_i] = 1'b0;
            u_prefetch_queue.entry_req_id_r[clear_slot_i] = {`REQ_ID_W{1'b0}};
            u_prefetch_queue.entry_branch_id_r[clear_slot_i] = {`BRANCH_ID_W{1'b0}};
            u_prefetch_queue.entry_node_id_r[clear_slot_i] = {`NODE_ID_W{1'b0}};
            u_prefetch_queue.entry_layer_id_r[clear_slot_i] = {`LAYER_ID_W{1'b0}};
            u_prefetch_queue.entry_size_subbank_r[clear_slot_i] = {`KV_GROUP_LEN_W{1'b0}};
            u_prefetch_queue.entry_shared_r[clear_slot_i] = 1'b0;
        end

        u_prefetch_queue.entry_count_r = 0;
    end
endtask

task expect_preloaded_queue_state;
    begin
        #1;
        if (u_prefetch_queue.entry_count_r != 2 ||
            !u_prefetch_queue.entry_valid_r[0] ||
            !u_prefetch_queue.entry_valid_r[1] ||
            (queue_deq_req_id != TEST_REQ_ID) ||
            (queue_deq_branch_id != VICTIM_BRANCH_ID) ||
            (queue_deq_node_id != VICTIM_NODE_ID)) begin
            $fatal(1, "preloaded prefetch_queue state mismatch");
        end
    end
endtask

task expect_flush_bridge_active;
    begin
        #1;
        if (!flush_valid || commit_valid) begin
            $fatal(1, "comparator mismatch should generate flush-only behavior");
        end
        if ((flush_freeze !== 1'b1) ||
            tree_in_ready ||
            prefix_ready ||
            frontier_ready ||
            prefetch_enq_valid) begin
            $fatal(1, "comparator flush should freeze AGU front-end acceptance");
        end
        if (!prefetch_flush_valid ||
            (prefetch_flush_req_id != TEST_REQ_ID) ||
            (prefetch_flush_branch_mask != flush_branch_mask) ||
            (prefetch_flush_node_mask != flush_node_mask)) begin
            $fatal(1, "AGU should own prefetch_queue flush controls");
        end
        if (!free_list_flush_valid ||
            (free_list_flush_req_id != TEST_REQ_ID) ||
            (free_list_flush_branch_mask != flush_branch_mask) ||
            (free_list_flush_node_mask != flush_node_mask)) begin
            $fatal(1, "AGU should own free_list flush controls");
        end
        if (!token_flush_valid ||
            (token_flush_req_id != TEST_REQ_ID) ||
            (token_flush_branch_mask != flush_branch_mask) ||
            (token_flush_node_mask != flush_node_mask)) begin
            $fatal(1, "AGU should own token_register flush controls");
        end
    end
endtask

task expect_reclaim_handoff_victim_only;
    integer wait_i;
    reg seen;
    begin
        seen = 1'b0;
        for (wait_i = 0; wait_i < 20; wait_i = wait_i + 1) begin
            @(negedge clk);
            #1;
            if (flush_reclaim_valid) begin
                if ((flush_reclaim_sram_id != victim_sram_id_r) ||
                    (flush_reclaim_bank_id != victim_bank_id_r) ||
                    (flush_reclaim_subbank_start != victim_subbank_start_r) ||
                    (flush_reclaim_group_len != victim_group_len_r)) begin
                    $fatal(1, "free_list reclaim handoff did not match victim range");
                end
                seen = 1'b1;
                disable expect_reclaim_handoff_victim_only;
            end
        end

        if (!seen) begin
            $fatal(1, "free_list reclaim handoff did not appear");
        end
    end
endtask

task expect_prefetch_queue_victim_removed_survivor_kept;
    begin
        @(posedge clk);
        #1;
        if (u_prefetch_queue.entry_count_r != 1 ||
            !u_prefetch_queue.entry_valid_r[0] ||
            (u_prefetch_queue.entry_req_id_r[0] != TEST_REQ_ID) ||
            (u_prefetch_queue.entry_branch_id_r[0] != SURVIVOR_BRANCH_ID) ||
            (u_prefetch_queue.entry_node_id_r[0] != SURVIVOR_NODE_ID) ||
            (u_prefetch_queue.entry_size_subbank_r[0] != `KV_GROUP_SIZE_SUBBANK) ||
            u_prefetch_queue.entry_shared_r[0] ||
            queue_deq_shared) begin
            $fatal(1, "prefetch_queue should keep only the survivor entry after flush");
        end
    end
endtask

task expect_free_list_range_state;
    input [255:0] scenario_name;
    input [`SRAM_ID_W-1:0] sram_id;
    input [`BANK_ID_W-1:0] bank_id;
    input [`SUBBANK_ID_W-1:0] subbank_start;
    input [`KV_GROUP_LEN_W-1:0] group_len;
    input expect_free;
    input [`REQ_ID_W-1:0] expect_req_id;
    input [`BRANCH_ID_W-1:0] expect_branch_id;
    input [`NODE_ID_W-1:0] expect_node_id;
    integer flat_i;
    integer bit_i;
    begin
        flat_i = (sram_id * `SRAM_BANK_NUM) + bank_id;
        for (bit_i = 0; bit_i < group_len; bit_i = bit_i + 1) begin
            if (expect_free) begin
                if (!u_free_list.free_bitmap[flat_i][subbank_start + bit_i]) begin
                    $fatal(1, "%0s: free_list bit should be free", scenario_name);
                end
                if (u_free_list.entry_req_id[flat_i][subbank_start + bit_i] != {`REQ_ID_W{1'b0}} ||
                    u_free_list.entry_branch_id[flat_i][subbank_start + bit_i] != {`BRANCH_ID_W{1'b0}} ||
                    u_free_list.entry_node_id[flat_i][subbank_start + bit_i] != {`NODE_ID_W{1'b0}} ||
                    u_free_list.entry_shared[flat_i][subbank_start + bit_i]) begin
                    $fatal(1, "%0s: free_list metadata should clear on reclaimed victim", scenario_name);
                end
            end else begin
                if (u_free_list.free_bitmap[flat_i][subbank_start + bit_i]) begin
                    $fatal(1, "%0s: free_list bit should remain allocated", scenario_name);
                end
                if (u_free_list.entry_req_id[flat_i][subbank_start + bit_i] != expect_req_id ||
                    u_free_list.entry_branch_id[flat_i][subbank_start + bit_i] != expect_branch_id ||
                    u_free_list.entry_node_id[flat_i][subbank_start + bit_i] != expect_node_id ||
                    u_free_list.entry_shared[flat_i][subbank_start + bit_i]) begin
                    $fatal(1, "%0s: free_list survivor metadata mismatch", scenario_name);
                end
            end
        end
    end
endtask

task expect_reuse_matches_victim;
    begin
        if ((reuse_sram_id_r != victim_sram_id_r) ||
            (reuse_bank_id_r != victim_bank_id_r) ||
            (reuse_subbank_start_r != victim_subbank_start_r) ||
            (reuse_group_len_r != victim_group_len_r)) begin
            $fatal(1, "post-flush allocation did not reuse victim-reclaimed capacity");
        end
    end
endtask

task preload_remaining_capacity_as_filler;
    integer flat_i;
    integer bit_i;
    reg victim_hit;
    reg survivor_hit;
    begin
        for (flat_i = 0; flat_i < TOTAL_BANKS; flat_i = flat_i + 1) begin
            for (bit_i = 0; bit_i < `SUBBANK_NUM_PER_BANK; bit_i = bit_i + 1) begin
                victim_hit =
                    (flat_i == ((victim_sram_id_r * `SRAM_BANK_NUM) + victim_bank_id_r)) &&
                    (bit_i >= victim_subbank_start_r) &&
                    (bit_i < (victim_subbank_start_r + victim_group_len_r));
                survivor_hit =
                    (flat_i == ((survivor_sram_id_r * `SRAM_BANK_NUM) + survivor_bank_id_r)) &&
                    (bit_i >= survivor_subbank_start_r) &&
                    (bit_i < (survivor_subbank_start_r + survivor_group_len_r));

                if (!victim_hit && !survivor_hit) begin
                    u_free_list.free_bitmap[flat_i][bit_i] = 1'b0;
                    u_free_list.entry_req_id[flat_i][bit_i] = FILLER_REQ_ID;
                    u_free_list.entry_branch_id[flat_i][bit_i] = 2'd2;
                    u_free_list.entry_node_id[flat_i][bit_i] = 4'd0;
                    u_free_list.entry_shared[flat_i][bit_i] = 1'b0;

                    u_bank_state_table.occ_bitmap[flat_i][bit_i] = 1'b1;
                    u_bank_state_table.committed_bitmap[flat_i][bit_i] = 1'b0;
                    u_bank_state_table.owner_mask[flat_i][bit_i] =
                        {{(`BRANCH_MASK_W-3){1'b0}}, 3'b100};
                    u_bank_state_table.entry_req_id[flat_i][bit_i] = FILLER_REQ_ID;
                    u_bank_state_table.entry_node_id[flat_i][bit_i] = 4'd0;
                end
            end
        end

        // Mirror the effective post-fill search cursor that a real sequence of
        // filler allocations would leave behind: the next round-robin search
        // should begin at the oldest remaining range, which is the victim slot.
        u_free_list.cursor_sram = victim_sram_id_r;
        u_free_list.cursor_bank = victim_bank_id_r;
        u_free_list.cursor_subbank = victim_subbank_start_r;
    end
endtask

initial begin
    clk = 1'b0;
    rst_n = 1'b0;

    clear_comparator_inputs();
    clear_tree_input();
    clear_query();
    clear_lookup();
    token_wr_index_r = {`TOKEN_REG_INDEX_W{1'b0}};

    victim_sram_id_r = {`SRAM_ID_W{1'b0}};
    victim_bank_id_r = {`BANK_ID_W{1'b0}};
    victim_subbank_start_r = {`SUBBANK_ID_W{1'b0}};
    victim_group_len_r = {`KV_GROUP_LEN_W{1'b0}};
    survivor_sram_id_r = {`SRAM_ID_W{1'b0}};
    survivor_bank_id_r = {`BANK_ID_W{1'b0}};
    survivor_subbank_start_r = {`SUBBANK_ID_W{1'b0}};
    survivor_group_len_r = {`KV_GROUP_LEN_W{1'b0}};
    reuse_sram_id_r = {`SRAM_ID_W{1'b0}};
    reuse_bank_id_r = {`BANK_ID_W{1'b0}};
    reuse_subbank_start_r = {`SUBBANK_ID_W{1'b0}};
    reuse_group_len_r = {`KV_GROUP_LEN_W{1'b0}};
    query_bitmap_r = {`BANK_OCC_BITMAP_W{1'b0}};

    repeat (3) @(posedge clk);
    rst_n = 1'b1;

    #1;
    expect_accept_open("reset_release");

    issue_req_expect_grant("victim_alloc", TEST_REQ_ID,
                           VICTIM_BRANCH_ID, VICTIM_NODE_ID, 2'd1);
    issue_req_expect_grant("survivor_alloc", TEST_REQ_ID,
                           SURVIVOR_BRANCH_ID, SURVIVOR_NODE_ID, 2'd2);

    lookup_expect("victim_before_flush", TEST_REQ_ID,
                  VICTIM_TOKEN_ID, VICTIM_POSITION_ID, 1'b1,
                  {{(`BRANCH_MASK_W-2){1'b0}}, 2'b10});
    lookup_expect("survivor_before_flush", TEST_REQ_ID,
                  SURVIVOR_TOKEN_ID, SURVIVOR_POSITION_ID, 1'b1,
                  {{(`BRANCH_MASK_W-1){1'b0}}, 1'b1});

    query_bank_bitmap(victim_sram_id_r, victim_bank_id_r);
    expect_range_occupied("victim_bank_state_before_flush", query_bitmap_r,
                          victim_subbank_start_r, victim_group_len_r);
    if ((victim_sram_id_r == survivor_sram_id_r) &&
        (victim_bank_id_r == survivor_bank_id_r)) begin
        expect_range_occupied("survivor_same_bank_before_flush", query_bitmap_r,
                              survivor_subbank_start_r, survivor_group_len_r);
    end else begin
        query_bank_bitmap(survivor_sram_id_r, survivor_bank_id_r);
        expect_range_occupied("survivor_other_bank_before_flush", query_bitmap_r,
                              survivor_subbank_start_r, survivor_group_len_r);
    end

    expect_free_list_range_state("victim_free_list_before_flush",
                                 victim_sram_id_r, victim_bank_id_r,
                                 victim_subbank_start_r, victim_group_len_r,
                                 1'b0, TEST_REQ_ID,
                                 VICTIM_BRANCH_ID, VICTIM_NODE_ID);
    expect_free_list_range_state("survivor_free_list_before_flush",
                                 survivor_sram_id_r, survivor_bank_id_r,
                                 survivor_subbank_start_r, survivor_group_len_r,
                                 1'b0, TEST_REQ_ID,
                                 SURVIVOR_BRANCH_ID, SURVIVOR_NODE_ID);

    preload_remaining_capacity_as_filler();

    issue_req_expect_deny("full_before_flush", FULL_REQ_ID, 2'd3, 4'd0);

    hold_queue_deq();
    preload_prefetch_queue_victim_survivor();
    expect_preloaded_queue_state();

    @(posedge clk);
    #1;
    cmp_req_id = TEST_REQ_ID;
    cmp_slot_valid[0] = 1'b1;
    cmp_slot_real_token_id[`TOKEN_ID_W-1:0] = 16'h0101;
    cmp_slot_candidate_token_id[`TOKEN_ID_W-1:0] = 16'h0202;
    cmp_slot_node_id[`NODE_ID_W-1:0] = VICTIM_NODE_ID;
    cmp_slot_parent_node_id[`NODE_ID_W-1:0] = 4'd1;
    cmp_slot_branch_id[`BRANCH_ID_W-1:0] = VICTIM_BRANCH_ID;

    expect_flush_bridge_active();
    expect_reclaim_handoff_victim_only();
    expect_prefetch_queue_victim_removed_survivor_kept();

    clear_comparator_inputs();

    query_bank_bitmap(victim_sram_id_r, victim_bank_id_r);
    expect_range_free("victim_bank_state_after_flush", query_bitmap_r,
                      victim_subbank_start_r, victim_group_len_r);
    if ((victim_sram_id_r == survivor_sram_id_r) &&
        (victim_bank_id_r == survivor_bank_id_r)) begin
        expect_range_occupied("survivor_same_bank_after_flush", query_bitmap_r,
                              survivor_subbank_start_r, survivor_group_len_r);
    end else begin
        query_bank_bitmap(survivor_sram_id_r, survivor_bank_id_r);
        expect_range_occupied("survivor_other_bank_after_flush", query_bitmap_r,
                              survivor_subbank_start_r, survivor_group_len_r);
    end

    expect_free_list_range_state("victim_free_list_after_flush",
                                 victim_sram_id_r, victim_bank_id_r,
                                 victim_subbank_start_r, victim_group_len_r,
                                 1'b1, {`REQ_ID_W{1'b0}},
                                 {`BRANCH_ID_W{1'b0}}, {`NODE_ID_W{1'b0}});
    expect_free_list_range_state("survivor_free_list_after_flush",
                                 survivor_sram_id_r, survivor_bank_id_r,
                                 survivor_subbank_start_r, survivor_group_len_r,
                                 1'b0, TEST_REQ_ID,
                                 SURVIVOR_BRANCH_ID, SURVIVOR_NODE_ID);

    lookup_expect("victim_after_flush", TEST_REQ_ID,
                  VICTIM_TOKEN_ID, VICTIM_POSITION_ID, 1'b0,
                  {`BRANCH_MASK_W{1'b0}});
    lookup_expect("survivor_after_flush", TEST_REQ_ID,
                  SURVIVOR_TOKEN_ID, SURVIVOR_POSITION_ID, 1'b1,
                  {{(`BRANCH_MASK_W-1){1'b0}}, 1'b1});

    clear_prefetch_queue_state();
    release_queue_deq();

    #1;
    expect_accept_open("post_flush_accept_reopen");

    issue_req_expect_grant("post_flush_reuse_alloc", REUSE_REQ_ID,
                           REUSE_BRANCH_ID, REUSE_NODE_ID, 2'd3);
    expect_reuse_matches_victim();

    lookup_expect("victim_lookup_stays_miss", TEST_REQ_ID,
                  VICTIM_TOKEN_ID, VICTIM_POSITION_ID, 1'b0,
                  {`BRANCH_MASK_W{1'b0}});
    lookup_expect("survivor_lookup_stays_hit", TEST_REQ_ID,
                  SURVIVOR_TOKEN_ID, SURVIVOR_POSITION_ID, 1'b1,
                  {{(`BRANCH_MASK_W-1){1'b0}}, 1'b1});

    if (token_error_flag) begin
        $fatal(1, "token_register error_flag should remain low");
    end

    $display("tb_comparator_dual_path_flush_coherence PASS");
    $finish;
end

endmodule
