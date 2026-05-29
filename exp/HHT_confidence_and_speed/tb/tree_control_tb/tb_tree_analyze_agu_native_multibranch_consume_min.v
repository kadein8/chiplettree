`timescale 1ns/1ps

`include "config/prediction_params.vh"
`include "config/interface_params.vh"
`include "config/memory_params.vh"

module tb_tree_analyze_agu_native_multibranch_consume_min;

localparam [`REQ_ID_W-1:0] TEST_REQ_ID = 4'hd;
localparam integer PREFIX_EXPECT_COUNT = 2;
localparam integer FRONTIER_EXPECT_COUNT = 2;
localparam integer PREFETCH_EXPECT_COUNT = 6;
localparam integer TOKEN_EXPECT_COUNT = 6;

localparam [`NODE_ID_W-1:0] NODE_A  = 4'h1;
localparam [`NODE_ID_W-1:0] NODE_B  = 4'h2;
localparam [`NODE_ID_W-1:0] NODE_C0 = 4'h3;
localparam [`NODE_ID_W-1:0] NODE_C1 = 4'h4;
localparam [`NODE_ID_W-1:0] NODE_D0 = 4'h5;
localparam [`NODE_ID_W-1:0] NODE_D1 = 4'h6;

localparam [`BRANCH_ID_W-1:0] BRANCH_0 = {`BRANCH_ID_W{1'b0}};
localparam [`BRANCH_ID_W-1:0] BRANCH_1 =
    {{(`BRANCH_ID_W-1){1'b0}}, 1'b1};
localparam [`BRANCH_MASK_W-1:0] BRANCH_MASK_ALL = {`BRANCH_MASK_W{1'b1}};
localparam [`BRANCH_MASK_W-1:0] BRANCH_MASK_0 =
    {{(`BRANCH_MASK_W-1){1'b0}}, 1'b1};
localparam [`BRANCH_MASK_W-1:0] BRANCH_MASK_1 =
    {{(`BRANCH_MASK_W-2){1'b0}}, 2'b10};

reg clk;
reg rst_n;

reg req_valid;
wire req_ready;
reg [`REQ_ID_W-1:0] req_id;
reg [`TREE_MAX_PREFIX_NODES-1:0] src_prefix_slot_valid;
reg [`TREE_MAX_PREFIX_NODES*`NODE_ID_W-1:0] src_prefix_node_id;
reg [`TREE_MAX_FRONTIER_LEVELS-1:0] src_frontier_level_valid;
reg [`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS-1:0]
    src_frontier_slot_valid;
reg [`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0]
    src_frontier_node_id;
reg [`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0]
    src_frontier_parent_node_id;

wire prefix_valid;
wire prefix_ready;
wire [`REQ_ID_W-1:0] prefix_req_id;
wire prefix_node_valid;
wire [`NODE_ID_W-1:0] prefix_node_id;
wire [`NODE_ID_W-1:0] prefix_parent_node_id;
wire [`TOKEN_ID_W-1:0] prefix_token_id;
wire [`POSITION_ID_W-1:0] prefix_position_id;
wire [`LAYER_ID_W-1:0] prefix_layer_id;
wire prefix_is_last;

wire frontier_valid;
wire frontier_ready;
wire [`REQ_ID_W-1:0] frontier_req_id;
wire [`TREE_LEVEL_ID_W-1:0] frontier_level_id;
wire [`TREE_FRONTIER_SLOTS-1:0] frontier_slot_valid;
wire [`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0] frontier_node_id;
wire [`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0] frontier_parent_node_id;
wire [`TREE_FRONTIER_SLOTS*`TOKEN_ID_W-1:0] frontier_token_id;
wire [`TREE_FRONTIER_SLOTS*`POSITION_ID_W-1:0] frontier_position_id;

wire prefix_norm_valid;
wire [`REQ_ID_W-1:0] prefix_norm_req_id;
wire prefix_norm_node_valid;
wire [`NODE_ID_W-1:0] prefix_norm_node_id;
wire [`NODE_ID_W-1:0] prefix_norm_parent_node_id;
wire [`TOKEN_ID_W-1:0] prefix_norm_token_id;
wire [`POSITION_ID_W-1:0] prefix_norm_position_id;
wire [`LAYER_ID_W-1:0] prefix_norm_layer_id;
wire prefix_norm_is_last;
wire prefix_norm_is_shared;

wire frontier_norm_valid;
wire [`REQ_ID_W-1:0] frontier_norm_req_id;
wire [`TREE_LEVEL_ID_W-1:0] frontier_norm_level_id;
wire [`TREE_FRONTIER_SLOTS-1:0] frontier_norm_slot_valid;
wire [`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0] frontier_norm_node_id;
wire [`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0] frontier_norm_parent_node_id;
wire [`TREE_FRONTIER_SLOTS*`TOKEN_ID_W-1:0] frontier_norm_token_id;
wire [`TREE_FRONTIER_SLOTS*`POSITION_ID_W-1:0] frontier_norm_position_id;
wire [`TREE_FRONTIER_SLOTS*`KV_GROUP_LEN_W-1:0] frontier_norm_size_subbank;
wire [`TREE_FRONTIER_SLOTS-1:0] frontier_norm_slot_shared;

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

wire prefetch_deq_valid;
wire prefetch_deq_ready;
wire [`REQ_ID_W-1:0] prefetch_deq_req_id;
wire [`BRANCH_ID_W-1:0] prefetch_deq_branch_id;
wire [`NODE_ID_W-1:0] prefetch_deq_node_id;
wire [`LAYER_ID_W-1:0] prefetch_deq_layer_id;
wire [`KV_GROUP_LEN_W-1:0] prefetch_deq_size_subbank;
wire prefetch_deq_shared;

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

wire alloc_resp_valid;
wire alloc_resp_grant;
wire [`REQ_ID_W-1:0] alloc_resp_req_id;
wire [`SRAM_ID_W-1:0] alloc_resp_sram_id;
wire [`BANK_ID_W-1:0] alloc_resp_bank_id;
wire [`SUBBANK_ID_W-1:0] alloc_resp_subbank_start;
wire [`KV_GROUP_LEN_W-1:0] alloc_resp_group_len;
wire [`BANK_OCC_BITMAP_W-1:0] alloc_resp_occ_bitmap;

wire flush_drain_busy;
wire free_list_flush_valid;
wire [`REQ_ID_W-1:0] free_list_flush_req_id;
wire [`BRANCH_MASK_W-1:0] free_list_flush_branch_mask;
wire [`NODE_MASK_W-1:0] free_list_flush_node_mask;
wire flush_reclaim_valid;
wire [`SRAM_ID_W-1:0] flush_reclaim_sram_id;
wire [`BANK_ID_W-1:0] flush_reclaim_bank_id;
wire [`SUBBANK_ID_W-1:0] flush_reclaim_subbank_start;
wire [`KV_GROUP_LEN_W-1:0] flush_reclaim_group_len;

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
wire token_flush_valid;
wire [`REQ_ID_W-1:0] token_flush_req_id;
wire [`BRANCH_MASK_W-1:0] token_flush_branch_mask;
wire [`NODE_MASK_W-1:0] token_flush_node_mask;

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

reg [`TOKEN_REG_INDEX_W-1:0] token_wr_index_r;

integer prefix_event_count;
integer frontier_event_count;
integer prefetch_event_count;
integer token_event_count;

reg [`NODE_ID_W-1:0] prefix_node_log [0:PREFIX_EXPECT_COUNT-1];
reg [`NODE_ID_W-1:0] prefix_parent_log [0:PREFIX_EXPECT_COUNT-1];
reg [`LAYER_ID_W-1:0] prefix_layer_log [0:PREFIX_EXPECT_COUNT-1];
reg prefix_last_log [0:PREFIX_EXPECT_COUNT-1];
reg prefix_shared_log [0:PREFIX_EXPECT_COUNT-1];

reg [`TREE_LEVEL_ID_W-1:0] frontier_level_log [0:FRONTIER_EXPECT_COUNT-1];
reg [`TREE_FRONTIER_SLOTS-1:0]
    frontier_slot_valid_log [0:FRONTIER_EXPECT_COUNT-1];
reg [`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0]
    frontier_node_log [0:FRONTIER_EXPECT_COUNT-1];
reg [`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0]
    frontier_parent_log [0:FRONTIER_EXPECT_COUNT-1];
reg [`TREE_FRONTIER_SLOTS*`KV_GROUP_LEN_W-1:0]
    frontier_size_subbank_log [0:FRONTIER_EXPECT_COUNT-1];
reg [`TREE_FRONTIER_SLOTS-1:0]
    frontier_slot_shared_log [0:FRONTIER_EXPECT_COUNT-1];

reg [`NODE_ID_W-1:0] prefetch_node_log [0:PREFETCH_EXPECT_COUNT-1];
reg [`BRANCH_ID_W-1:0] prefetch_branch_log [0:PREFETCH_EXPECT_COUNT-1];
reg [`LAYER_ID_W-1:0] prefetch_layer_log [0:PREFETCH_EXPECT_COUNT-1];
reg prefetch_shared_log [0:PREFETCH_EXPECT_COUNT-1];

reg [`NODE_ID_W-1:0] token_node_log [0:TOKEN_EXPECT_COUNT-1];
reg [`BRANCH_ID_W-1:0] token_branch_log [0:TOKEN_EXPECT_COUNT-1];
reg [`BRANCH_MASK_W-1:0] token_branch_mask_log [0:TOKEN_EXPECT_COUNT-1];
reg token_shared_log [0:TOKEN_EXPECT_COUNT-1];

reg [`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0] expected_frontier_nodes_level0;
reg [`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0] expected_frontier_parents_level0;
reg [`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0] expected_frontier_nodes_level1;
reg [`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0] expected_frontier_parents_level1;

tree_analyze u_tree_analyze (
    .clk(clk),
    .rst_n(rst_n),
    .req_valid(req_valid),
    .req_ready(req_ready),
    .req_id(req_id),
    .src_prefix_slot_valid(src_prefix_slot_valid),
    .src_prefix_node_id(src_prefix_node_id),
    .src_frontier_level_valid(src_frontier_level_valid),
    .src_frontier_slot_valid(src_frontier_slot_valid),
    .src_frontier_node_id(src_frontier_node_id),
    .src_frontier_parent_node_id(src_frontier_parent_node_id),
    .prefix_valid(prefix_valid),
    .prefix_ready(prefix_ready),
    .prefix_req_id(prefix_req_id),
    .prefix_node_valid(prefix_node_valid),
    .prefix_node_id(prefix_node_id),
    .prefix_parent_node_id(prefix_parent_node_id),
    .prefix_token_id(prefix_token_id),
    .prefix_position_id(prefix_position_id),
    .prefix_layer_id(prefix_layer_id),
    .prefix_is_last(prefix_is_last),
    .frontier_valid(frontier_valid),
    .frontier_ready(frontier_ready),
    .frontier_req_id(frontier_req_id),
    .frontier_level_id(frontier_level_id),
    .frontier_slot_valid(frontier_slot_valid),
    .frontier_node_id(frontier_node_id),
    .frontier_parent_node_id(frontier_parent_node_id),
    .frontier_token_id(frontier_token_id),
    .frontier_position_id(frontier_position_id)
);

agu u_agu (
    .clk(clk),
    .rst_n(rst_n),
    .tree_in_valid(1'b0),
    .tree_in_ready(),
    .tree_in_req_id({`REQ_ID_W{1'b0}}),
    .tree_in_branch_id({`BRANCH_ID_W{1'b0}}),
    .tree_in_node_id({`NODE_ID_W{1'b0}}),
    .prefix_valid(prefix_valid),
    .prefix_ready(prefix_ready),
    .prefix_req_id(prefix_req_id),
    .prefix_node_valid(prefix_node_valid),
    .prefix_node_id(prefix_node_id),
    .prefix_parent_node_id(prefix_parent_node_id),
    .prefix_token_id(prefix_token_id),
    .prefix_position_id(prefix_position_id),
    .prefix_layer_id(prefix_layer_id),
    .prefix_is_last(prefix_is_last),
    .frontier_valid(frontier_valid),
    .frontier_ready(frontier_ready),
    .frontier_req_id(frontier_req_id),
    .frontier_level_id(frontier_level_id),
    .frontier_slot_valid(frontier_slot_valid),
    .frontier_node_id(frontier_node_id),
    .frontier_parent_node_id(frontier_parent_node_id),
    .frontier_token_id(frontier_token_id),
    .frontier_position_id(frontier_position_id),
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
    .flush_freeze(1'b0),
    .flush_drain_busy(flush_drain_busy),
    .flush_ctrl_valid(1'b0),
    .flush_ctrl_req_id({`REQ_ID_W{1'b0}}),
    .flush_ctrl_branch_mask({`BRANCH_MASK_W{1'b0}}),
    .flush_ctrl_node_mask({`NODE_MASK_W{1'b0}}),
    .branch_liveness_valid(1'b0),
    .branch_liveness_req_id({`REQ_ID_W{1'b0}}),
    .branch_liveness_live_mask({`BRANCH_MASK_W{1'b1}}),
    .branch_liveness_prune_mask({`BRANCH_MASK_W{1'b0}}),
    .prefix_norm_valid(prefix_norm_valid),
    .prefix_norm_req_id(prefix_norm_req_id),
    .prefix_norm_node_valid(prefix_norm_node_valid),
    .prefix_norm_node_id(prefix_norm_node_id),
    .prefix_norm_parent_node_id(prefix_norm_parent_node_id),
    .prefix_norm_token_id(prefix_norm_token_id),
    .prefix_norm_position_id(prefix_norm_position_id),
    .prefix_norm_layer_id(prefix_norm_layer_id),
    .prefix_norm_is_last(prefix_norm_is_last),
    .prefix_norm_is_shared(prefix_norm_is_shared),
    .frontier_norm_valid(frontier_norm_valid),
    .frontier_norm_req_id(frontier_norm_req_id),
    .frontier_norm_level_id(frontier_norm_level_id),
    .frontier_norm_slot_valid(frontier_norm_slot_valid),
    .frontier_norm_node_id(frontier_norm_node_id),
    .frontier_norm_parent_node_id(frontier_norm_parent_node_id),
    .frontier_norm_token_id(frontier_norm_token_id),
    .frontier_norm_position_id(frontier_norm_position_id),
    .frontier_norm_size_subbank(frontier_norm_size_subbank),
    .frontier_norm_slot_shared(frontier_norm_slot_shared),
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
    .deq_valid(prefetch_deq_valid),
    .deq_ready(prefetch_deq_ready),
    .deq_req_id(prefetch_deq_req_id),
    .deq_branch_id(prefetch_deq_branch_id),
    .deq_node_id(prefetch_deq_node_id),
    .deq_layer_id(prefetch_deq_layer_id),
    .deq_size_subbank(prefetch_deq_size_subbank),
    .deq_shared(prefetch_deq_shared)
);

free_list u_free_list (
    .clk(clk),
    .rst_n(rst_n),
    .cand_req_valid(prefetch_deq_valid),
    .cand_req_ready(prefetch_deq_ready),
    .cand_req_req_id(prefetch_deq_req_id),
    .cand_req_branch_id(prefetch_deq_branch_id),
    .cand_req_node_id(prefetch_deq_node_id),
    .cand_req_size_subbank(prefetch_deq_size_subbank),
    .cand_req_shared(prefetch_deq_shared),
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
    .flush_drain_busy(flush_drain_busy),
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
    .query_valid(1'b0),
    .query_sram_id({`SRAM_ID_W{1'b0}}),
    .query_bank_id({`BANK_ID_W{1'b0}}),
    .query_resp_valid(),
    .query_resp_occ_bitmap(),
    .query_resp_state(),
    .query_resp_branch_mask(),
    .query_resp_refcnt()
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
    .error_flag()
);

always #5 clk = ~clk;

function [`TOKEN_ID_W-1:0] node_to_token_id;
    input [`NODE_ID_W-1:0] node_id_i;
    begin
        node_to_token_id = {`TOKEN_ID_W{1'b0}};
        node_to_token_id[`NODE_ID_W-1:0] = node_id_i;
    end
endfunction

function [`POSITION_ID_W-1:0] node_to_position_id;
    input [`NODE_ID_W-1:0] node_id_i;
    begin
        node_to_position_id = {`POSITION_ID_W{1'b0}};
        node_to_position_id[`NODE_ID_W-1:0] = node_id_i;
    end
endfunction

task clear_tree_request;
    begin
        req_valid = 1'b0;
        req_id = {`REQ_ID_W{1'b0}};
        src_prefix_slot_valid = {`TREE_MAX_PREFIX_NODES{1'b0}};
        src_prefix_node_id = {(`TREE_MAX_PREFIX_NODES*`NODE_ID_W){1'b0}};
        src_frontier_level_valid = {`TREE_MAX_FRONTIER_LEVELS{1'b0}};
        src_frontier_slot_valid =
            {(`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS){1'b0}};
        src_frontier_node_id =
            {(`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`NODE_ID_W){1'b0}};
        src_frontier_parent_node_id =
            {(`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`NODE_ID_W){1'b0}};
    end
endtask

task load_native_multibranch_tree;
    begin
        clear_tree_request();
        req_valid = 1'b1;
        req_id = TEST_REQ_ID;

        src_prefix_slot_valid[0] = 1'b1;
        src_prefix_slot_valid[1] = 1'b1;
        src_prefix_node_id[(0*`NODE_ID_W) +: `NODE_ID_W] = NODE_A;
        src_prefix_node_id[(1*`NODE_ID_W) +: `NODE_ID_W] = NODE_B;

        src_frontier_level_valid[0] = 1'b1;
        src_frontier_level_valid[1] = 1'b1;

        src_frontier_slot_valid[(0*`TREE_FRONTIER_SLOTS) + 0] = 1'b1;
        src_frontier_slot_valid[(0*`TREE_FRONTIER_SLOTS) + 1] = 1'b1;
        src_frontier_node_id[(((0*`TREE_FRONTIER_SLOTS) + 0)*`NODE_ID_W) +:
            `NODE_ID_W] = NODE_C0;
        src_frontier_node_id[(((0*`TREE_FRONTIER_SLOTS) + 1)*`NODE_ID_W) +:
            `NODE_ID_W] = NODE_C1;
        src_frontier_parent_node_id[
            (((0*`TREE_FRONTIER_SLOTS) + 0)*`NODE_ID_W) +: `NODE_ID_W] = NODE_B;
        src_frontier_parent_node_id[
            (((0*`TREE_FRONTIER_SLOTS) + 1)*`NODE_ID_W) +: `NODE_ID_W] = NODE_B;

        src_frontier_slot_valid[(1*`TREE_FRONTIER_SLOTS) + 0] = 1'b1;
        src_frontier_slot_valid[(1*`TREE_FRONTIER_SLOTS) + 1] = 1'b1;
        src_frontier_node_id[(((1*`TREE_FRONTIER_SLOTS) + 0)*`NODE_ID_W) +:
            `NODE_ID_W] = NODE_D0;
        src_frontier_node_id[(((1*`TREE_FRONTIER_SLOTS) + 1)*`NODE_ID_W) +:
            `NODE_ID_W] = NODE_D1;
        src_frontier_parent_node_id[
            (((1*`TREE_FRONTIER_SLOTS) + 0)*`NODE_ID_W) +: `NODE_ID_W] = NODE_C0;
        src_frontier_parent_node_id[
            (((1*`TREE_FRONTIER_SLOTS) + 1)*`NODE_ID_W) +: `NODE_ID_W] = NODE_C1;
    end
endtask

task wait_for_all_events;
    integer wait_i;
    begin
        for (wait_i = 0; wait_i < 80; wait_i = wait_i + 1) begin
            @(negedge clk);
            if ((prefix_event_count == PREFIX_EXPECT_COUNT) &&
                (frontier_event_count == FRONTIER_EXPECT_COUNT) &&
                (prefetch_event_count == PREFETCH_EXPECT_COUNT) &&
                (token_event_count == TOKEN_EXPECT_COUNT)) begin
                disable wait_for_all_events;
            end
        end

        $fatal(
            1,
            "20_ event collection timeout: prefix=%0d frontier=%0d prefetch=%0d token=%0d",
            prefix_event_count,
            frontier_event_count,
            prefetch_event_count,
            token_event_count
        );
    end
endtask

task drive_lookup_and_expect;
    input [`NODE_ID_W-1:0] expected_node_id;
    input expected_is_shared;
    input [`BRANCH_MASK_W-1:0] expected_branch_mask;
    integer wait_i;
    begin
        @(negedge clk);
        lookup_valid = 1'b1;
        lookup_req_id = TEST_REQ_ID;
        lookup_token_id = node_to_token_id(expected_node_id);
        lookup_position_id = node_to_position_id(expected_node_id);

        @(negedge clk);
        lookup_valid = 1'b0;

        for (wait_i = 0; wait_i < 6; wait_i = wait_i + 1) begin
            if (lookup_resp_valid) begin
                if (!lookup_resp_hit ||
                    (lookup_resp_req_id != TEST_REQ_ID) ||
                    (lookup_resp_group_len != `KV_GROUP_SIZE_SUBBANK) ||
                    (lookup_resp_is_shared != expected_is_shared) ||
                    (lookup_resp_branch_mask != expected_branch_mask) ||
                    (lookup_resp_state == {`TOKEN_STATE_W{1'b0}})) begin
                    $fatal(1, "20_ token lookup mismatch for node %0d", expected_node_id);
                end
                disable drive_lookup_and_expect;
            end
            @(negedge clk);
        end

        $fatal(1, "20_ token lookup timeout for node %0d", expected_node_id);
    end
endtask

always @(negedge clk) begin
    if (rst_n && prefix_norm_valid) begin
        if (prefix_event_count >= PREFIX_EXPECT_COUNT) begin
            $fatal(1, "20_ observed unexpected extra prefix_norm event");
        end

        if (prefix_norm_req_id != TEST_REQ_ID || !prefix_norm_node_valid) begin
            $fatal(1, "20_ prefix normalized payload metadata mismatch");
        end

        prefix_node_log[prefix_event_count] = prefix_norm_node_id;
        prefix_parent_log[prefix_event_count] = prefix_norm_parent_node_id;
        prefix_layer_log[prefix_event_count] = prefix_norm_layer_id;
        prefix_last_log[prefix_event_count] = prefix_norm_is_last;
        prefix_shared_log[prefix_event_count] = prefix_norm_is_shared;
        prefix_event_count = prefix_event_count + 1;
    end

    if (rst_n && frontier_norm_valid) begin
        if (frontier_event_count >= FRONTIER_EXPECT_COUNT) begin
            $fatal(1, "20_ observed unexpected extra frontier_norm event");
        end

        if (frontier_norm_req_id != TEST_REQ_ID) begin
            $fatal(1, "20_ frontier normalized payload metadata mismatch");
        end

        frontier_level_log[frontier_event_count] = frontier_norm_level_id;
        frontier_slot_valid_log[frontier_event_count] = frontier_norm_slot_valid;
        frontier_node_log[frontier_event_count] = frontier_norm_node_id;
        frontier_parent_log[frontier_event_count] = frontier_norm_parent_node_id;
        frontier_size_subbank_log[frontier_event_count] =
            frontier_norm_size_subbank;
        frontier_slot_shared_log[frontier_event_count] =
            frontier_norm_slot_shared;
        frontier_event_count = frontier_event_count + 1;
    end

    if (rst_n && prefetch_enq_valid && prefetch_enq_ready) begin
        if (prefetch_event_count >= PREFETCH_EXPECT_COUNT) begin
            $fatal(1, "20_ observed unexpected extra prefetch event");
        end

        if (prefetch_enq_req_id != TEST_REQ_ID ||
            prefetch_enq_size_subbank != `KV_GROUP_SIZE_SUBBANK) begin
            $fatal(1, "20_ prefetch metadata mismatch");
        end

        prefetch_node_log[prefetch_event_count] = prefetch_enq_node_id;
        prefetch_branch_log[prefetch_event_count] = prefetch_enq_branch_id;
        prefetch_layer_log[prefetch_event_count] = prefetch_enq_layer_id;
        prefetch_shared_log[prefetch_event_count] = prefetch_enq_shared;
        prefetch_event_count = prefetch_event_count + 1;
    end

    if (rst_n && token_wr_valid) begin
        if (token_event_count >= TOKEN_EXPECT_COUNT) begin
            $fatal(1, "20_ observed unexpected extra token event");
        end

        if (token_wr_req_id != TEST_REQ_ID ||
            token_wr_group_len != `KV_GROUP_SIZE_SUBBANK) begin
            $fatal(1, "20_ token write metadata mismatch");
        end

        token_node_log[token_event_count] = token_wr_node_id;
        token_branch_log[token_event_count] = token_wr_branch_id;
        token_branch_mask_log[token_event_count] = token_wr_branch_mask;
        token_shared_log[token_event_count] = token_wr_is_shared;
        token_event_count = token_event_count + 1;
    end
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        token_wr_index_r <= {`TOKEN_REG_INDEX_W{1'b0}};
    end else if (token_wr_valid) begin
        token_wr_index_r <= token_wr_index_r + 1'b1;
    end
end

initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    clear_tree_request();
    lookup_valid = 1'b0;
    lookup_req_id = {`REQ_ID_W{1'b0}};
    lookup_token_id = {`TOKEN_ID_W{1'b0}};
    lookup_position_id = {`POSITION_ID_W{1'b0}};
    token_wr_index_r = {`TOKEN_REG_INDEX_W{1'b0}};

    prefix_event_count = 0;
    frontier_event_count = 0;
    prefetch_event_count = 0;
    token_event_count = 0;

    expected_frontier_nodes_level0 = {(`TREE_FRONTIER_SLOTS*`NODE_ID_W){1'b0}};
    expected_frontier_parents_level0 = {(`TREE_FRONTIER_SLOTS*`NODE_ID_W){1'b0}};
    expected_frontier_nodes_level1 = {(`TREE_FRONTIER_SLOTS*`NODE_ID_W){1'b0}};
    expected_frontier_parents_level1 = {(`TREE_FRONTIER_SLOTS*`NODE_ID_W){1'b0}};

    expected_frontier_nodes_level0[(0*`NODE_ID_W) +: `NODE_ID_W] = NODE_C0;
    expected_frontier_nodes_level0[(1*`NODE_ID_W) +: `NODE_ID_W] = NODE_C1;
    expected_frontier_parents_level0[(0*`NODE_ID_W) +: `NODE_ID_W] = NODE_B;
    expected_frontier_parents_level0[(1*`NODE_ID_W) +: `NODE_ID_W] = NODE_B;

    expected_frontier_nodes_level1[(0*`NODE_ID_W) +: `NODE_ID_W] = NODE_D0;
    expected_frontier_nodes_level1[(1*`NODE_ID_W) +: `NODE_ID_W] = NODE_D1;
    expected_frontier_parents_level1[(0*`NODE_ID_W) +: `NODE_ID_W] = NODE_C0;
    expected_frontier_parents_level1[(1*`NODE_ID_W) +: `NODE_ID_W] = NODE_C1;

    repeat (3) @(posedge clk);
    rst_n = 1'b1;

    @(negedge clk);
    if (!req_ready || !prefix_ready || !frontier_ready || !lookup_ready) begin
        $fatal(1, "20_ front-end should be ready after reset");
    end

    load_native_multibranch_tree();
    @(posedge clk);
    #1;
    req_valid = 1'b0;

    wait_for_all_events();

    if (prefix_event_count != PREFIX_EXPECT_COUNT ||
        frontier_event_count != FRONTIER_EXPECT_COUNT ||
        prefetch_event_count != PREFETCH_EXPECT_COUNT ||
        token_event_count != TOKEN_EXPECT_COUNT) begin
        $fatal(1, "20_ event count mismatch after wait");
    end

    if (prefix_node_log[0] != NODE_A ||
        prefix_parent_log[0] != `TREE_PARENT_NONE_NODE_ID ||
        prefix_layer_log[0] != {`LAYER_ID_W{1'b0}} ||
        prefix_last_log[0] != 1'b0 ||
        prefix_shared_log[0] != 1'b1) begin
        $fatal(1, "20_ prefix event 0 mismatch");
    end

    if (prefix_node_log[1] != NODE_B ||
        prefix_parent_log[1] != NODE_A ||
        prefix_layer_log[1] != {{(`LAYER_ID_W-1){1'b0}}, 1'b1} ||
        prefix_last_log[1] != 1'b1 ||
        prefix_shared_log[1] != 1'b1) begin
        $fatal(1, "20_ prefix event 1 mismatch");
    end

    if (frontier_level_log[0] != {`TREE_LEVEL_ID_W{1'b0}} ||
        frontier_slot_valid_log[0] != 4'b0011 ||
        frontier_node_log[0] != expected_frontier_nodes_level0 ||
        frontier_parent_log[0] != expected_frontier_parents_level0 ||
        frontier_slot_shared_log[0] != {`TREE_FRONTIER_SLOTS{1'b0}} ||
        frontier_size_subbank_log[0][(0*`KV_GROUP_LEN_W) +: `KV_GROUP_LEN_W] !=
            `KV_GROUP_SIZE_SUBBANK ||
        frontier_size_subbank_log[0][(1*`KV_GROUP_LEN_W) +: `KV_GROUP_LEN_W] !=
            `KV_GROUP_SIZE_SUBBANK) begin
        $fatal(1, "20_ frontier level0 mismatch");
    end

    if (frontier_level_log[1] != {{(`TREE_LEVEL_ID_W-1){1'b0}}, 1'b1} ||
        frontier_slot_valid_log[1] != 4'b0011 ||
        frontier_node_log[1] != expected_frontier_nodes_level1 ||
        frontier_parent_log[1] != expected_frontier_parents_level1 ||
        frontier_slot_shared_log[1] != {`TREE_FRONTIER_SLOTS{1'b0}} ||
        frontier_size_subbank_log[1][(0*`KV_GROUP_LEN_W) +: `KV_GROUP_LEN_W] !=
            `KV_GROUP_SIZE_SUBBANK ||
        frontier_size_subbank_log[1][(1*`KV_GROUP_LEN_W) +: `KV_GROUP_LEN_W] !=
            `KV_GROUP_SIZE_SUBBANK) begin
        $fatal(1, "20_ frontier level1 mismatch");
    end

    if (prefetch_node_log[0] != NODE_A ||
        prefetch_branch_log[0] != BRANCH_0 ||
        prefetch_layer_log[0] != {`LAYER_ID_W{1'b0}} ||
        !prefetch_shared_log[0]) begin
        $fatal(1, "20_ prefetch event 0 mismatch");
    end

    if (prefetch_node_log[1] != NODE_B ||
        prefetch_branch_log[1] != BRANCH_0 ||
        prefetch_layer_log[1] != {{(`LAYER_ID_W-1){1'b0}}, 1'b1} ||
        !prefetch_shared_log[1]) begin
        $fatal(1, "20_ prefetch event 1 mismatch");
    end

    if (prefetch_node_log[2] != NODE_C0 ||
        prefetch_branch_log[2] != BRANCH_0 ||
        prefetch_layer_log[2] != {`LAYER_ID_W{1'b0}} ||
        prefetch_shared_log[2]) begin
        $fatal(1, "20_ prefetch event 2 mismatch");
    end

    if (prefetch_node_log[3] != NODE_C1 ||
        prefetch_branch_log[3] != BRANCH_1 ||
        prefetch_layer_log[3] != {`LAYER_ID_W{1'b0}} ||
        prefetch_shared_log[3]) begin
        $fatal(1, "20_ prefetch event 3 mismatch");
    end

    if (prefetch_node_log[4] != NODE_D0 ||
        prefetch_branch_log[4] != BRANCH_0 ||
        prefetch_layer_log[4] != {{(`LAYER_ID_W-1){1'b0}}, 1'b1} ||
        prefetch_shared_log[4]) begin
        $fatal(1, "20_ prefetch event 4 mismatch");
    end

    if (prefetch_node_log[5] != NODE_D1 ||
        prefetch_branch_log[5] != BRANCH_1 ||
        prefetch_layer_log[5] != {{(`LAYER_ID_W-1){1'b0}}, 1'b1} ||
        prefetch_shared_log[5]) begin
        $fatal(1, "20_ prefetch event 5 mismatch");
    end

    if (token_node_log[0] != NODE_A ||
        token_branch_log[0] != BRANCH_0 ||
        token_branch_mask_log[0] != BRANCH_MASK_ALL ||
        !token_shared_log[0]) begin
        $fatal(1, "20_ token event 0 mismatch");
    end

    if (token_node_log[1] != NODE_B ||
        token_branch_log[1] != BRANCH_0 ||
        token_branch_mask_log[1] != BRANCH_MASK_ALL ||
        !token_shared_log[1]) begin
        $fatal(1, "20_ token event 1 mismatch");
    end

    if (token_node_log[2] != NODE_C0 ||
        token_branch_log[2] != BRANCH_0 ||
        token_branch_mask_log[2] != BRANCH_MASK_0 ||
        token_shared_log[2]) begin
        $fatal(1, "20_ token event 2 mismatch");
    end

    if (token_node_log[3] != NODE_C1 ||
        token_branch_log[3] != BRANCH_1 ||
        token_branch_mask_log[3] != BRANCH_MASK_1 ||
        token_shared_log[3]) begin
        $fatal(1, "20_ token event 3 mismatch");
    end

    if (token_node_log[4] != NODE_D0 ||
        token_branch_log[4] != BRANCH_0 ||
        token_branch_mask_log[4] != BRANCH_MASK_0 ||
        token_shared_log[4]) begin
        $fatal(1, "20_ token event 4 mismatch");
    end

    if (token_node_log[5] != NODE_D1 ||
        token_branch_log[5] != BRANCH_1 ||
        token_branch_mask_log[5] != BRANCH_MASK_1 ||
        token_shared_log[5]) begin
        $fatal(1, "20_ token event 5 mismatch");
    end

    if (token_entry_count != TOKEN_EXPECT_COUNT ||
        token_wr_index_r != TOKEN_EXPECT_COUNT) begin
        $fatal(1, "20_ token register entry count mismatch");
    end

    drive_lookup_and_expect(NODE_B, 1'b1, BRANCH_MASK_ALL);
    drive_lookup_and_expect(NODE_C1, 1'b0, BRANCH_MASK_1);
    drive_lookup_and_expect(NODE_D1, 1'b0, BRANCH_MASK_1);

    $display("tb_tree_analyze_agu_native_multibranch_consume_min PASS");
    $finish;
end

endmodule
