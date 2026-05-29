`timescale 1ns/1ps

`include "config/prediction_params.vh"
`include "config/interface_params.vh"
`include "config/memory_params.vh"

module tb_prediction_window_ownership_split_bounded_integration;

localparam integer DRAFT_PORTS = 4;
localparam integer CONF_W = 8;
localparam integer TOKEN_EXPECT_COUNT = 2;
localparam integer SOURCE_ID_W =
    ((DRAFT_PORTS + 1) <= 2) ? 1 : $clog2(DRAFT_PORTS + 1);
localparam integer WINDOW_BRANCH_SLOTS = `TREE_FRONTIER_SLOTS;
localparam [`REQ_ID_W-1:0] TEST_REQ_ID = 4'he;
localparam integer SRAM_LANE = 0;
localparam [`NODE_ID_W-1:0] WINDOW_PARENT_NODE_ID =
    {{(`NODE_ID_W-4){1'b0}}, 4'h5};
localparam [`NODE_ID_W-1:0] BRIDGE_SYNTH_NODE_BASE =
    {{(`NODE_ID_W-4){1'b0}}, 4'h8};
localparam [`NODE_ID_W-1:0] SLOT0_SYNTH_NODE = BRIDGE_SYNTH_NODE_BASE;
localparam [`NODE_ID_W-1:0] SLOT1_SYNTH_NODE = BRIDGE_SYNTH_NODE_BASE + 1'b1;
localparam [SOURCE_ID_W-1:0] SOURCE_HHT = {SOURCE_ID_W{1'b0}};
localparam [SOURCE_ID_W-1:0] SOURCE_DRAFT0 =
    {{(SOURCE_ID_W-1){1'b0}}, 1'b1};
localparam [`BRANCH_ID_W-1:0] BRANCH_0 = {`BRANCH_ID_W{1'b0}};
localparam [`BRANCH_ID_W-1:0] BRANCH_1 =
    {{(`BRANCH_ID_W-1){1'b0}}, 1'b1};
localparam [`BRANCH_MASK_W-1:0] BRANCH_MASK_0 =
    {{(`BRANCH_MASK_W-1){1'b0}}, 1'b1};
localparam [`BRANCH_MASK_W-1:0] BRANCH_MASK_1 =
    {{(`BRANCH_MASK_W-2){1'b0}}, 2'b10};
localparam [`TOKEN_ID_W-1:0] HHT_TOKEN_ID =
    {{(`TOKEN_ID_W-8){1'b0}}, 8'h31};
localparam [`TOKEN_ID_W-1:0] HHT_REFERENCED_TOKEN_ID =
    {{(`TOKEN_ID_W-8){1'b0}}, 8'h41};
localparam [`POSITION_ID_W-1:0] HHT_REFERENCED_POSITION =
    {{(`POSITION_ID_W-8){1'b0}}, 8'h21};
localparam [CONF_W-1:0] HHT_CONFIDENCE = 8'd130;
localparam [`TOKEN_ID_W-1:0] DRAFT0_TOKEN_ID =
    {{(`TOKEN_ID_W-8){1'b0}}, 8'h51};
localparam [`TOKEN_ID_W-1:0] DRAFT0_REFERENCED_TOKEN_ID =
    {{(`TOKEN_ID_W-8){1'b0}}, 8'h61};
localparam [`POSITION_ID_W-1:0] DRAFT0_REFERENCED_POSITION =
    {{(`POSITION_ID_W-8){1'b0}}, 8'h7c};
localparam [CONF_W-1:0] DRAFT0_CONFIDENCE = 8'd160;
localparam [`PE_MASK_W-1:0] PE_MASK_TEST = 16'h0f0f;
localparam [`REQ_ID_W-1:0] PE_READ_REQ_ID = 4'h9;
localparam [`SRAM_WDATA_W-1:0] TEST_DATA =
    128'h01234567_89abcdef_fedcba98_76543210;

reg clk;
reg rst_n;

reg hht_cand_valid;
wire hht_cand_ready;
reg [`NODE_ID_W-1:0] hht_parent_node_id;
reg [`TOKEN_ID_W-1:0] hht_token_id;
reg [`TOKEN_ID_W-1:0] hht_referenced_token_id;
reg [`POSITION_ID_W-1:0] hht_referenced_position;
reg [CONF_W-1:0] hht_confidence;

reg [DRAFT_PORTS-1:0] draft_cand_valid;
wire [DRAFT_PORTS-1:0] draft_cand_ready;
reg [DRAFT_PORTS*`NODE_ID_W-1:0] draft_parent_node_id;
reg [DRAFT_PORTS*`TOKEN_ID_W-1:0] draft_token_id;
reg [DRAFT_PORTS*`TOKEN_ID_W-1:0] draft_referenced_token_id;
reg [DRAFT_PORTS*`POSITION_ID_W-1:0] draft_referenced_position;
reg [DRAFT_PORTS*CONF_W-1:0] draft_confidence;

wire pred_valid;
wire [SOURCE_ID_W-1:0] pred_source_id;
wire [`NODE_ID_W-1:0] pred_parent_node_id;
wire [`TOKEN_ID_W-1:0] pred_token_id;
wire [`TOKEN_ID_W-1:0] pred_referenced_token_id;
wire [`POSITION_ID_W-1:0] pred_referenced_position;
wire [CONF_W-1:0] pred_confidence;
wire pred_is_last_in_window;

wire tree_window_valid;
wire tree_window_ready;
wire [`NODE_ID_W-1:0] tree_window_parent_node_id;
wire [WINDOW_BRANCH_SLOTS-1:0] tree_window_slot_valid;
wire [WINDOW_BRANCH_SLOTS*SOURCE_ID_W-1:0] tree_window_source_id;
wire [WINDOW_BRANCH_SLOTS*`TOKEN_ID_W-1:0] tree_window_token_id;
wire [WINDOW_BRANCH_SLOTS*`TOKEN_ID_W-1:0] tree_window_referenced_token_id;
wire [WINDOW_BRANCH_SLOTS*`POSITION_ID_W-1:0] tree_window_referenced_position;
wire [WINDOW_BRANCH_SLOTS*CONF_W-1:0] tree_window_confidence;

wire frontier_valid;
wire frontier_ready;
wire [`REQ_ID_W-1:0] frontier_req_id;
wire [`TREE_LEVEL_ID_W-1:0] frontier_level_id;
wire [WINDOW_BRANCH_SLOTS-1:0] frontier_slot_valid;
wire [WINDOW_BRANCH_SLOTS*`NODE_ID_W-1:0] frontier_node_id;
wire [WINDOW_BRANCH_SLOTS*`NODE_ID_W-1:0] frontier_parent_node_id;
wire [WINDOW_BRANCH_SLOTS*`TOKEN_ID_W-1:0] frontier_token_id;
wire [WINDOW_BRANCH_SLOTS*`POSITION_ID_W-1:0] frontier_position_id;

wire prefix_norm_valid;
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

reg [`TOKEN_REG_INDEX_W-1:0] token_wr_index_r;
wire [`TOKEN_REG_INDEX_W:0] token_entry_count;

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

reg pe_req_valid;
wire pe_req_ready;
reg pe_req_write;
reg [`SRAM_ADDR_W-1:0] pe_req_addr;
reg [`SRAM_WDATA_W-1:0] pe_req_wdata;
reg [`REQ_ID_W-1:0] pe_req_req_id;
reg [`PE_MASK_W-1:0] pe_req_pe_mask;
reg [`REQ_PRIORITY_W-1:0] pe_req_priority;
reg [`BANK_ID_W-1:0] pe_req_bank_id;
reg [`SUBBANK_ID_W-1:0] pe_req_subbank_id;

wire [`MEM_REQ_LANES-1:0] rc_mem_req_valid;
wire [`MEM_REQ_LANES-1:0] rc_mem_req_ready;
wire [`MEM_REQ_LANES-1:0] rc_mem_req_write;
wire [`MEM_REQ_LANES*`SRAM_ADDR_W-1:0] rc_mem_req_addr;
wire [`MEM_REQ_LANES*`SRAM_WDATA_W-1:0] rc_mem_req_wdata;
wire [`MEM_REQ_LANES*`REQ_ID_W-1:0] rc_mem_req_id;
wire [`MEM_REQ_LANES-1:0] sram_mem_resp_valid;
wire [`MEM_REQ_LANES*`SRAM_RDATA_W-1:0] sram_mem_resp_rdata;
wire [`MEM_REQ_LANES*`REQ_ID_W-1:0] sram_mem_resp_id;
wire [`MEM_REQ_LANES-1:0] sram_mem_resp_last;

wire [`MEM_REQ_LANES-1:0] pe_resp_valid;
reg [`MEM_REQ_LANES-1:0] pe_resp_ready;
wire [`MEM_REQ_LANES*`SRAM_RDATA_W-1:0] pe_resp_rdata;
wire [`MEM_REQ_LANES*`REQ_ID_W-1:0] pe_resp_req_id;
wire [`MEM_REQ_LANES*`PE_MASK_W-1:0] pe_resp_pe_mask;
wire [`MEM_REQ_LANES-1:0] pe_resp_last;

reg prep_active;
reg [`MEM_REQ_LANES-1:0] prep_mem_req_valid;
reg [`MEM_REQ_LANES-1:0] prep_mem_req_write;
reg [`MEM_REQ_LANES*`SRAM_ADDR_W-1:0] prep_mem_req_addr;
reg [`MEM_REQ_LANES*`SRAM_WDATA_W-1:0] prep_mem_req_wdata;
reg [`MEM_REQ_LANES*`REQ_ID_W-1:0] prep_mem_req_id;

wire [`MEM_REQ_LANES-1:0] sram_mem_req_valid;
wire [`MEM_REQ_LANES-1:0] sram_mem_req_ready;
wire [`MEM_REQ_LANES-1:0] sram_mem_req_write;
wire [`MEM_REQ_LANES*`SRAM_ADDR_W-1:0] sram_mem_req_addr;
wire [`MEM_REQ_LANES*`SRAM_WDATA_W-1:0] sram_mem_req_wdata;
wire [`MEM_REQ_LANES*`REQ_ID_W-1:0] sram_mem_req_id;

reg [`SRAM_ID_W-1:0] last_lookup_sram_id_r;
reg [`BANK_ID_W-1:0] last_lookup_bank_id_r;
reg [`SUBBANK_ID_W-1:0] last_lookup_subbank_start_r;
integer token_event_count_r;
reg [`NODE_ID_W-1:0] token_node_log [0:TOKEN_EXPECT_COUNT-1];
reg [`TOKEN_ID_W-1:0] token_id_log [0:TOKEN_EXPECT_COUNT-1];
reg [`POSITION_ID_W-1:0] token_position_log [0:TOKEN_EXPECT_COUNT-1];
reg [`BRANCH_ID_W-1:0] token_branch_log [0:TOKEN_EXPECT_COUNT-1];
reg [`BRANCH_MASK_W-1:0] token_branch_mask_log [0:TOKEN_EXPECT_COUNT-1];
reg token_shared_log [0:TOKEN_EXPECT_COUNT-1];
reg token_alloc_resp_valid_log [0:TOKEN_EXPECT_COUNT-1];
reg token_alloc_resp_grant_log [0:TOKEN_EXPECT_COUNT-1];
reg [`REQ_ID_W-1:0] token_alloc_resp_req_id_log [0:TOKEN_EXPECT_COUNT-1];

assign sram_mem_req_valid = prep_active ? prep_mem_req_valid : rc_mem_req_valid;
assign sram_mem_req_write = prep_active ? prep_mem_req_write : rc_mem_req_write;
assign sram_mem_req_addr = prep_active ? prep_mem_req_addr : rc_mem_req_addr;
assign sram_mem_req_wdata = prep_active ? prep_mem_req_wdata : rc_mem_req_wdata;
assign sram_mem_req_id = prep_active ? prep_mem_req_id : rc_mem_req_id;
assign rc_mem_req_ready = prep_active ? {`MEM_REQ_LANES{1'b0}} :
                                        sram_mem_req_ready;

IntegrationPredictionPart #(
    .DRAFT_PORTS(DRAFT_PORTS),
    .CONF_W(CONF_W),
    .ENABLE_MULTI_BRANCH_WINDOW(1),
    .WINDOW_BRANCH_SLOTS(WINDOW_BRANCH_SLOTS),
    .ENABLE_HHT_LIFECYCLE(0)
) u_prediction (
    .clk(clk),
    .rst_n(rst_n),
    .hht_cand_valid(hht_cand_valid),
    .hht_cand_ready(hht_cand_ready),
    .hht_parent_node_id(hht_parent_node_id),
    .hht_token_id(hht_token_id),
    .hht_referenced_token_id(hht_referenced_token_id),
    .hht_referenced_position(hht_referenced_position),
    .hht_confidence(hht_confidence),
    .draft_cand_valid(draft_cand_valid),
    .draft_cand_ready(draft_cand_ready),
    .draft_parent_node_id(draft_parent_node_id),
    .draft_token_id(draft_token_id),
    .draft_referenced_token_id(draft_referenced_token_id),
    .draft_referenced_position(draft_referenced_position),
    .draft_confidence(draft_confidence),
    .hht_update_valid(1'b0),
    .hht_update_ready(),
    .hht_update_parent_node_id({`NODE_ID_W{1'b0}}),
    .hht_update_token_id({`TOKEN_ID_W{1'b0}}),
    .hht_update_referenced_token_id({`TOKEN_ID_W{1'b0}}),
    .hht_update_referenced_position({`POSITION_ID_W{1'b0}}),
    .hht_update_confidence({CONF_W{1'b0}}),
    .pred_valid(pred_valid),
    .pred_ready(1'b1),
    .pred_source_id(pred_source_id),
    .pred_parent_node_id(pred_parent_node_id),
    .pred_token_id(pred_token_id),
    .pred_referenced_token_id(pred_referenced_token_id),
    .pred_referenced_position(pred_referenced_position),
    .pred_confidence(pred_confidence),
    .pred_is_last_in_window(pred_is_last_in_window),
    .tree_window_valid(tree_window_valid),
    .tree_window_ready(tree_window_ready),
    .tree_window_parent_node_id(tree_window_parent_node_id),
    .tree_window_slot_valid(tree_window_slot_valid),
    .tree_window_source_id(tree_window_source_id),
    .tree_window_token_id(tree_window_token_id),
    .tree_window_referenced_token_id(tree_window_referenced_token_id),
    .tree_window_referenced_position(tree_window_referenced_position),
    .tree_window_confidence(tree_window_confidence)
);

PredictionWindowAguBridge #(
    .SOURCE_ID_W(SOURCE_ID_W),
    .CONF_W(CONF_W),
    .WINDOW_BRANCH_SLOTS(WINDOW_BRANCH_SLOTS),
    .BRIDGE_SYNTH_NODE_BASE(BRIDGE_SYNTH_NODE_BASE)
) u_bridge (
    .clk(clk),
    .rst_n(rst_n),
    .src_tree_window_valid(tree_window_valid),
    .src_tree_window_ready(tree_window_ready),
    .src_tree_window_req_id(TEST_REQ_ID),
    .src_tree_window_parent_node_id(tree_window_parent_node_id),
    .src_tree_window_slot_valid(tree_window_slot_valid),
    .src_tree_window_source_id(tree_window_source_id),
    .src_tree_window_token_id(tree_window_token_id),
    .src_tree_window_referenced_token_id(tree_window_referenced_token_id),
    .src_tree_window_referenced_position(tree_window_referenced_position),
    .src_tree_window_confidence(tree_window_confidence),
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
    .prefix_valid(1'b0),
    .prefix_ready(),
    .prefix_req_id({`REQ_ID_W{1'b0}}),
    .prefix_node_valid(1'b0),
    .prefix_node_id({`NODE_ID_W{1'b0}}),
    .prefix_parent_node_id({`NODE_ID_W{1'b0}}),
    .prefix_token_id({`TOKEN_ID_W{1'b0}}),
    .prefix_position_id({`POSITION_ID_W{1'b0}}),
    .prefix_layer_id({`LAYER_ID_W{1'b0}}),
    .prefix_is_last(1'b0),
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
    .flush_drain_busy(1'b0),
    .flush_ctrl_valid(1'b0),
    .flush_ctrl_req_id({`REQ_ID_W{1'b0}}),
    .flush_ctrl_branch_mask({`BRANCH_MASK_W{1'b0}}),
    .flush_ctrl_node_mask({`NODE_MASK_W{1'b0}}),
    .branch_liveness_valid(1'b0),
    .branch_liveness_req_id({`REQ_ID_W{1'b0}}),
    .branch_liveness_live_mask({`BRANCH_MASK_W{1'b1}}),
    .branch_liveness_prune_mask({`BRANCH_MASK_W{1'b0}}),
    .prefix_norm_valid(prefix_norm_valid),
    .prefix_norm_req_id(),
    .prefix_norm_node_valid(),
    .prefix_norm_node_id(),
    .prefix_norm_parent_node_id(),
    .prefix_norm_token_id(),
    .prefix_norm_position_id(),
    .prefix_norm_layer_id(),
    .prefix_norm_is_last(),
    .prefix_norm_is_shared(),
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
    .prefetch_flush_valid(),
    .prefetch_flush_req_id(),
    .prefetch_flush_branch_mask(),
    .prefetch_flush_node_mask(),
    .free_list_flush_valid(),
    .free_list_flush_req_id(),
    .free_list_flush_branch_mask(),
    .free_list_flush_node_mask(),
    .token_flush_valid(),
    .token_flush_req_id(),
    .token_flush_branch_mask(),
    .token_flush_node_mask()
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
    .flush_valid(1'b0),
    .flush_req_id({`REQ_ID_W{1'b0}}),
    .flush_branch_mask({`BRANCH_MASK_W{1'b0}}),
    .flush_node_mask({`NODE_MASK_W{1'b0}}),
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
    .flush_valid(1'b0),
    .flush_req_id({`REQ_ID_W{1'b0}}),
    .flush_branch_mask({`BRANCH_MASK_W{1'b0}}),
    .flush_node_mask({`NODE_MASK_W{1'b0}}),
    .flush_drain_busy(),
    .flush_reclaim_valid(),
    .flush_reclaim_sram_id(),
    .flush_reclaim_bank_id(),
    .flush_reclaim_subbank_start(),
    .flush_reclaim_group_len(),
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
    .alloc_resp_occ_bitmap(),
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
    .reclaim_valid(1'b0),
    .reclaim_sram_id({`SRAM_ID_W{1'b0}}),
    .reclaim_bank_id({`BANK_ID_W{1'b0}}),
    .reclaim_subbank_start({`SUBBANK_ID_W{1'b0}}),
    .reclaim_group_len({`KV_GROUP_LEN_W{1'b0}}),
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
    .flush_valid(1'b0),
    .flush_req_id({`REQ_ID_W{1'b0}}),
    .flush_branch_mask({`BRANCH_MASK_W{1'b0}}),
    .flush_node_mask({`NODE_MASK_W{1'b0}}),
    .entry_count(token_entry_count),
    .error_flag()
);

request_controller u_request_controller (
    .clk(clk),
    .rst_n(rst_n),
    .req_in_valid(pe_req_valid),
    .req_in_ready(pe_req_ready),
    .req_in_write(pe_req_write),
    .req_in_addr(pe_req_addr),
    .req_in_wdata(pe_req_wdata),
    .req_in_req_id(pe_req_req_id),
    .req_in_pe_mask(pe_req_pe_mask),
    .req_in_priority(pe_req_priority),
    .req_in_bank_id(pe_req_bank_id),
    .req_in_subbank_id(pe_req_subbank_id),
    .mem_req_valid(rc_mem_req_valid),
    .mem_req_ready(rc_mem_req_ready),
    .mem_req_write(rc_mem_req_write),
    .mem_req_addr(rc_mem_req_addr),
    .mem_req_wdata(rc_mem_req_wdata),
    .mem_req_id(rc_mem_req_id),
    .mem_resp_valid(sram_mem_resp_valid),
    .mem_resp_rdata(sram_mem_resp_rdata),
    .mem_resp_id(sram_mem_resp_id),
    .mem_resp_last(sram_mem_resp_last),
    .resp_out_valid(pe_resp_valid),
    .resp_out_ready(pe_resp_ready),
    .resp_out_rdata(pe_resp_rdata),
    .resp_out_req_id(pe_resp_req_id),
    .resp_out_pe_mask(pe_resp_pe_mask),
    .resp_out_last(pe_resp_last)
);

sram_subsystem u_sram_subsystem (
    .clk(clk),
    .rst_n(rst_n),
    .mem_req_valid(sram_mem_req_valid),
    .mem_req_ready(sram_mem_req_ready),
    .mem_req_write(sram_mem_req_write),
    .mem_req_addr(sram_mem_req_addr),
    .mem_req_wdata(sram_mem_req_wdata),
    .mem_req_id(sram_mem_req_id),
    .mem_resp_valid(sram_mem_resp_valid),
    .mem_resp_rdata(sram_mem_resp_rdata),
    .mem_resp_id(sram_mem_resp_id),
    .mem_resp_last(sram_mem_resp_last)
);

always #5 clk = ~clk;

function [`SRAM_ADDR_W-1:0] pack_addr;
    input [`SRAM_ID_W-1:0] sram_i;
    input [`BANK_ID_W-1:0] bank_i;
    input [`SUBBANK_ID_W-1:0] subbank_i;
    input [`ROW_ADDR_W-1:0] row_i;
    input [`OFFSET_W-1:0] offset_i;
    begin
        pack_addr = {sram_i, bank_i, subbank_i, row_i, offset_i};
    end
endfunction

task clear_prediction_inputs;
    begin
        hht_cand_valid = 1'b0;
        hht_parent_node_id = {`NODE_ID_W{1'b0}};
        hht_token_id = {`TOKEN_ID_W{1'b0}};
        hht_referenced_token_id = {`TOKEN_ID_W{1'b0}};
        hht_referenced_position = {`POSITION_ID_W{1'b0}};
        hht_confidence = {CONF_W{1'b0}};
        draft_cand_valid = {DRAFT_PORTS{1'b0}};
        draft_parent_node_id = {(DRAFT_PORTS*`NODE_ID_W){1'b0}};
        draft_token_id = {(DRAFT_PORTS*`TOKEN_ID_W){1'b0}};
        draft_referenced_token_id = {(DRAFT_PORTS*`TOKEN_ID_W){1'b0}};
        draft_referenced_position = {(DRAFT_PORTS*`POSITION_ID_W){1'b0}};
        draft_confidence = {(DRAFT_PORTS*CONF_W){1'b0}};
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

task clear_pe_req;
    begin
        pe_req_valid = 1'b0;
        pe_req_write = 1'b0;
        pe_req_addr = {`SRAM_ADDR_W{1'b0}};
        pe_req_wdata = {`SRAM_WDATA_W{1'b0}};
        pe_req_req_id = {`REQ_ID_W{1'b0}};
        pe_req_pe_mask = {`PE_MASK_W{1'b0}};
        pe_req_priority = {`REQ_PRIORITY_W{1'b0}};
        pe_req_bank_id = {`BANK_ID_W{1'b0}};
        pe_req_subbank_id = {`SUBBANK_ID_W{1'b0}};
    end
endtask

task clear_prep_req;
    begin
        prep_active = 1'b0;
        prep_mem_req_valid = {`MEM_REQ_LANES{1'b0}};
        prep_mem_req_write = {`MEM_REQ_LANES{1'b0}};
        prep_mem_req_addr = {(`MEM_REQ_LANES*`SRAM_ADDR_W){1'b0}};
        prep_mem_req_wdata = {(`MEM_REQ_LANES*`SRAM_WDATA_W){1'b0}};
        prep_mem_req_id = {(`MEM_REQ_LANES*`REQ_ID_W){1'b0}};
    end
endtask

task drive_prediction_window_sources;
    begin
        clear_prediction_inputs();
        hht_cand_valid = 1'b1;
        hht_parent_node_id = WINDOW_PARENT_NODE_ID;
        hht_token_id = HHT_TOKEN_ID;
        hht_referenced_token_id = HHT_REFERENCED_TOKEN_ID;
        hht_referenced_position = HHT_REFERENCED_POSITION;
        hht_confidence = HHT_CONFIDENCE;
        draft_cand_valid[0] = 1'b1;
        draft_parent_node_id[(0*`NODE_ID_W) +: `NODE_ID_W] =
            WINDOW_PARENT_NODE_ID;
        draft_token_id[(0*`TOKEN_ID_W) +: `TOKEN_ID_W] = DRAFT0_TOKEN_ID;
        draft_referenced_token_id[(0*`TOKEN_ID_W) +: `TOKEN_ID_W] =
            DRAFT0_REFERENCED_TOKEN_ID;
        draft_referenced_position[(0*`POSITION_ID_W) +: `POSITION_ID_W] =
            DRAFT0_REFERENCED_POSITION;
        draft_confidence[(0*CONF_W) +: CONF_W] = DRAFT0_CONFIDENCE;
        #1;
        if ((hht_cand_ready !== 1'b1) ||
            (draft_cand_ready !== 4'b0001)) begin
            $fatal(1,
                   "21_ prediction ready mask mismatch hht=%b draft=%b",
                   hht_cand_ready,
                   draft_cand_ready);
        end
        @(posedge clk);
        #1;
        clear_prediction_inputs();
    end
endtask

task wait_for_window_fire_and_check;
    integer wait_i;
    reg seen;
    begin
        seen = 1'b0;
        for (wait_i = 0; wait_i < 10; wait_i = wait_i + 1) begin
            @(negedge clk);
            if (tree_window_valid && tree_window_ready) begin
                seen = 1'b1;
                if (!pred_valid ||
                    (pred_source_id != SOURCE_DRAFT0) ||
                    (pred_parent_node_id != WINDOW_PARENT_NODE_ID) ||
                    (pred_token_id != DRAFT0_TOKEN_ID) ||
                    (pred_referenced_token_id != DRAFT0_REFERENCED_TOKEN_ID) ||
                    (pred_referenced_position != DRAFT0_REFERENCED_POSITION) ||
                    (pred_confidence != DRAFT0_CONFIDENCE) ||
                    !pred_is_last_in_window ||
                    (tree_window_parent_node_id != WINDOW_PARENT_NODE_ID) ||
                    (tree_window_slot_valid[1:0] != 2'b11) ||
                    (tree_window_source_id[(0*SOURCE_ID_W) +: SOURCE_ID_W] !=
                     SOURCE_DRAFT0) ||
                    (tree_window_source_id[(1*SOURCE_ID_W) +: SOURCE_ID_W] !=
                     SOURCE_HHT) ||
                    (tree_window_token_id[(0*`TOKEN_ID_W) +: `TOKEN_ID_W] !=
                     DRAFT0_TOKEN_ID) ||
                    (tree_window_token_id[(1*`TOKEN_ID_W) +: `TOKEN_ID_W] !=
                     HHT_TOKEN_ID) ||
                    (tree_window_referenced_token_id[
                        (0*`TOKEN_ID_W) +: `TOKEN_ID_W] !=
                     DRAFT0_REFERENCED_TOKEN_ID) ||
                    (tree_window_referenced_token_id[
                        (1*`TOKEN_ID_W) +: `TOKEN_ID_W] !=
                     HHT_REFERENCED_TOKEN_ID) ||
                    (tree_window_referenced_position[
                        (0*`POSITION_ID_W) +: `POSITION_ID_W] !=
                     DRAFT0_REFERENCED_POSITION) ||
                    (tree_window_referenced_position[
                        (1*`POSITION_ID_W) +: `POSITION_ID_W] !=
                     HHT_REFERENCED_POSITION)) begin
                    $fatal(1, "21_ tree_window payload mismatch");
                end
                disable wait_for_window_fire_and_check;
            end
        end
        if (!seen) begin
            $fatal(1, "21_ tree_window handshake timeout");
        end
    end
endtask

task wait_for_frontier_norm_and_check;
    integer wait_i;
    reg seen;
    begin
        seen = 1'b0;
        for (wait_i = 0; wait_i < 10; wait_i = wait_i + 1) begin
            @(negedge clk);
            if (frontier_norm_valid) begin
                seen = 1'b1;
                if ((frontier_norm_req_id != TEST_REQ_ID) ||
                    (frontier_norm_level_id != {`TREE_LEVEL_ID_W{1'b0}}) ||
                    (frontier_norm_slot_valid[1:0] != 2'b11) ||
                    (frontier_norm_node_id[(0*`NODE_ID_W) +: `NODE_ID_W] !=
                     SLOT0_SYNTH_NODE) ||
                    (frontier_norm_node_id[(1*`NODE_ID_W) +: `NODE_ID_W] !=
                     SLOT1_SYNTH_NODE) ||
                    (frontier_norm_parent_node_id[
                        (0*`NODE_ID_W) +: `NODE_ID_W] != WINDOW_PARENT_NODE_ID) ||
                    (frontier_norm_parent_node_id[
                        (1*`NODE_ID_W) +: `NODE_ID_W] != WINDOW_PARENT_NODE_ID) ||
                    (frontier_norm_token_id[(0*`TOKEN_ID_W) +: `TOKEN_ID_W] !=
                     DRAFT0_TOKEN_ID) ||
                    (frontier_norm_token_id[(1*`TOKEN_ID_W) +: `TOKEN_ID_W] !=
                     HHT_TOKEN_ID) ||
                    (frontier_norm_position_id[
                        (0*`POSITION_ID_W) +: `POSITION_ID_W] !=
                     DRAFT0_REFERENCED_POSITION) ||
                    (frontier_norm_position_id[
                        (1*`POSITION_ID_W) +: `POSITION_ID_W] !=
                     HHT_REFERENCED_POSITION) ||
                    (frontier_norm_size_subbank[
                        (0*`KV_GROUP_LEN_W) +: `KV_GROUP_LEN_W] !=
                     `KV_GROUP_SIZE_SUBBANK) ||
                    (frontier_norm_size_subbank[
                        (1*`KV_GROUP_LEN_W) +: `KV_GROUP_LEN_W] !=
                     `KV_GROUP_SIZE_SUBBANK) ||
                    (frontier_norm_slot_shared != {`TREE_FRONTIER_SLOTS{1'b0}})) begin
                    $fatal(1, "21_ frontier_norm payload mismatch");
                end
                disable wait_for_frontier_norm_and_check;
            end
        end
        if (!seen) begin
            $fatal(1, "21_ frontier_norm timeout");
        end
    end
endtask

task wait_for_alloc_and_token;
    input integer expected_event_count;
    input [`NODE_ID_W-1:0] expected_node_id;
    input [`TOKEN_ID_W-1:0] expected_token_id;
    input [`POSITION_ID_W-1:0] expected_position_id;
    input [`BRANCH_ID_W-1:0] expected_branch_id;
    input [`BRANCH_MASK_W-1:0] expected_branch_mask;
    integer wait_i;
    reg seen;
    begin
        seen = 1'b0;
        for (wait_i = 0; wait_i < 16; wait_i = wait_i + 1) begin
            @(posedge clk);
            #1;
            if (token_event_count_r == expected_event_count) begin
                if ((token_node_log[expected_event_count - 1] != expected_node_id) ||
                    (token_id_log[expected_event_count - 1] != expected_token_id) ||
                    (token_position_log[expected_event_count - 1] != expected_position_id) ||
                    (token_branch_log[expected_event_count - 1] != expected_branch_id) ||
                    (token_branch_mask_log[expected_event_count - 1] != expected_branch_mask) ||
                    token_shared_log[expected_event_count - 1] ||
                    !token_alloc_resp_valid_log[expected_event_count - 1] ||
                    !token_alloc_resp_grant_log[expected_event_count - 1] ||
                    (token_alloc_resp_req_id_log[expected_event_count - 1] != TEST_REQ_ID)) begin
                    $fatal(1, "21_ token write mismatch");
                end
                seen = 1'b1;
                disable wait_for_alloc_and_token;
            end
        end
        if (!seen) begin
            $fatal(1, "21_ token write timeout");
        end
    end
endtask

task drive_lookup_and_expect;
    input [`TOKEN_ID_W-1:0] expected_token_id;
    input [`POSITION_ID_W-1:0] expected_position_id;
    input [`BRANCH_MASK_W-1:0] expected_branch_mask;
    input expected_is_shared;
    integer wait_i;
    reg seen;
    begin
        @(negedge clk);
        lookup_valid = 1'b1;
        lookup_req_id = TEST_REQ_ID;
        lookup_token_id = expected_token_id;
        lookup_position_id = expected_position_id;

        @(negedge clk);
        lookup_valid = 1'b0;

        seen = 1'b0;
        for (wait_i = 0; wait_i < 6; wait_i = wait_i + 1) begin
            if (lookup_resp_valid) begin
                seen = 1'b1;
                if (!lookup_resp_hit ||
                    (lookup_resp_req_id != TEST_REQ_ID) ||
                    (lookup_resp_group_len != `KV_GROUP_SIZE_SUBBANK) ||
                    (lookup_resp_branch_mask != expected_branch_mask) ||
                    (lookup_resp_is_shared != expected_is_shared) ||
                    (lookup_resp_state == {`TOKEN_STATE_W{1'b0}})) begin
                    $fatal(1, "21_ token lookup mismatch");
                end
                last_lookup_sram_id_r = lookup_resp_sram_id;
                last_lookup_bank_id_r = lookup_resp_bank_id;
                last_lookup_subbank_start_r = lookup_resp_subbank_start;
                disable drive_lookup_and_expect;
            end
            @(negedge clk);
        end

        if (!seen) begin
            $fatal(1, "21_ token lookup timeout");
        end
    end
endtask

task token_sram_prepare_write;
    input [`SRAM_ADDR_W-1:0] addr_i;
    input [`SRAM_WDATA_W-1:0] data_i;
    begin
        @(posedge clk);
        #1;
        clear_prep_req();
        prep_active = 1'b1;
        prep_mem_req_valid[SRAM_LANE] = 1'b1;
        prep_mem_req_write[SRAM_LANE] = 1'b1;
        prep_mem_req_addr[(SRAM_LANE*`SRAM_ADDR_W) +: `SRAM_ADDR_W] = addr_i;
        prep_mem_req_wdata[(SRAM_LANE*`SRAM_WDATA_W) +: `SRAM_WDATA_W] = data_i;
        prep_mem_req_id[(SRAM_LANE*`REQ_ID_W) +: `REQ_ID_W] = TEST_REQ_ID;
        #1;
        if (!sram_mem_req_ready[SRAM_LANE]) begin
            $fatal(1, "21_ SRAM prepare write was not accepted");
        end
        @(posedge clk);
        #1;
        clear_prep_req();
    end
endtask

task pe_stub_drive_read;
    input [`SRAM_ADDR_W-1:0] addr_i;
    input [`BANK_ID_W-1:0] bank_i;
    input [`SUBBANK_ID_W-1:0] subbank_i;
    begin
        @(posedge clk);
        #1;
        pe_req_valid = 1'b1;
        pe_req_write = 1'b0;
        pe_req_addr = addr_i;
        pe_req_wdata = {`SRAM_WDATA_W{1'b0}};
        pe_req_req_id = PE_READ_REQ_ID;
        pe_req_pe_mask = PE_MASK_TEST;
        pe_req_priority = {`REQ_PRIORITY_W{1'b0}};
        pe_req_bank_id = bank_i;
        pe_req_subbank_id = subbank_i;
        #1;
        if (!pe_req_ready) begin
            $fatal(1, "21_ PE read request was not accepted");
        end
        @(posedge clk);
        #1;
        clear_pe_req();
    end
endtask

task wait_for_pe_response;
    integer wait_i;
    reg seen;
    begin
        seen = 1'b0;
        for (wait_i = 0; wait_i < 12; wait_i = wait_i + 1) begin
            @(posedge clk);
            #1;
            if (pe_resp_valid[SRAM_LANE]) begin
                seen = 1'b1;
                disable wait_for_pe_response;
            end
        end
        if (!seen) begin
            $fatal(1, "21_ PE response timeout");
        end
    end
endtask

always @(negedge clk) begin
    if (rst_n && prefix_norm_valid) begin
        $fatal(1, "21_ bridge must not drive prefix_norm path");
    end
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        token_wr_index_r <= {`TOKEN_REG_INDEX_W{1'b0}};
        token_event_count_r <= 0;
    end else if (token_wr_valid) begin
        if (token_event_count_r >= TOKEN_EXPECT_COUNT) begin
            $fatal(1, "21_ observed unexpected extra token event");
        end
        if ((token_wr_req_id != TEST_REQ_ID) ||
            (token_wr_group_len != `KV_GROUP_SIZE_SUBBANK)) begin
            $fatal(1, "21_ token write metadata mismatch");
        end
        token_node_log[token_event_count_r] <= token_wr_node_id;
        token_id_log[token_event_count_r] <= token_wr_token_id;
        token_position_log[token_event_count_r] <= token_wr_position_id;
        token_branch_log[token_event_count_r] <= token_wr_branch_id;
        token_branch_mask_log[token_event_count_r] <= token_wr_branch_mask;
        token_shared_log[token_event_count_r] <= token_wr_is_shared;
        token_alloc_resp_valid_log[token_event_count_r] <= alloc_resp_valid;
        token_alloc_resp_grant_log[token_event_count_r] <= alloc_resp_grant;
        token_alloc_resp_req_id_log[token_event_count_r] <= alloc_resp_req_id;
        token_event_count_r <= token_event_count_r + 1;
        token_wr_index_r <= token_wr_index_r + 1'b1;
    end
end

initial begin
    reg [`SRAM_ADDR_W-1:0] lookup_addr;

    clk = 1'b0;
    rst_n = 1'b0;
    clear_prediction_inputs();
    clear_lookup();
    clear_pe_req();
    clear_prep_req();
    pe_resp_ready = {`MEM_REQ_LANES{1'b0}};
    token_wr_index_r = {`TOKEN_REG_INDEX_W{1'b0}};
    token_event_count_r = 0;
    last_lookup_sram_id_r = {`SRAM_ID_W{1'b0}};
    last_lookup_bank_id_r = {`BANK_ID_W{1'b0}};
    last_lookup_subbank_start_r = {`SUBBANK_ID_W{1'b0}};

    repeat (3) @(posedge clk);
    rst_n = 1'b1;

    @(negedge clk);
    if (!lookup_ready || !tree_window_ready || !frontier_ready || !pe_req_ready) begin
        $fatal(1, "21_ expected ready signals are not open after reset");
    end

    drive_prediction_window_sources();
    wait_for_window_fire_and_check();
    wait_for_frontier_norm_and_check();

    wait_for_alloc_and_token(
        1,
        SLOT0_SYNTH_NODE,
        DRAFT0_TOKEN_ID,
        DRAFT0_REFERENCED_POSITION,
        BRANCH_0,
        BRANCH_MASK_0
    );
    wait_for_alloc_and_token(
        2,
        SLOT1_SYNTH_NODE,
        HHT_TOKEN_ID,
        HHT_REFERENCED_POSITION,
        BRANCH_1,
        BRANCH_MASK_1
    );

    if ((token_event_count_r != TOKEN_EXPECT_COUNT) ||
        (token_entry_count != TOKEN_EXPECT_COUNT) ||
        (token_wr_index_r != TOKEN_EXPECT_COUNT)) begin
        $fatal(1, "21_ token register count mismatch");
    end

    drive_lookup_and_expect(
        DRAFT0_TOKEN_ID,
        DRAFT0_REFERENCED_POSITION,
        BRANCH_MASK_0,
        1'b0
    );
    drive_lookup_and_expect(
        HHT_TOKEN_ID,
        HHT_REFERENCED_POSITION,
        BRANCH_MASK_1,
        1'b0
    );

    lookup_addr = pack_addr(
        last_lookup_sram_id_r,
        last_lookup_bank_id_r,
        last_lookup_subbank_start_r,
        8'h06,
        4'h4
    );

    token_sram_prepare_write(lookup_addr, TEST_DATA);
    pe_stub_drive_read(
        lookup_addr,
        last_lookup_bank_id_r,
        last_lookup_subbank_start_r
    );

    wait_for_pe_response();
    if (pe_resp_rdata[(SRAM_LANE*`SRAM_RDATA_W) +: `SRAM_RDATA_W] != TEST_DATA ||
        pe_resp_req_id[(SRAM_LANE*`REQ_ID_W) +: `REQ_ID_W] != PE_READ_REQ_ID ||
        pe_resp_pe_mask[(SRAM_LANE*`PE_MASK_W) +: `PE_MASK_W] != PE_MASK_TEST ||
        !pe_resp_last[SRAM_LANE]) begin
        $fatal(1, "21_ PE response payload mismatch");
    end

    @(posedge clk);
    #1;
    if (!pe_resp_valid[SRAM_LANE]) begin
        $fatal(1, "21_ PE response should hold until ready");
    end

    pe_resp_ready[SRAM_LANE] = 1'b1;
    @(posedge clk);
    #1;
    pe_resp_ready = {`MEM_REQ_LANES{1'b0}};
    if (pe_resp_valid[SRAM_LANE]) begin
        $fatal(1, "21_ PE response did not clear after handshake");
    end

    $display("tb_prediction_window_ownership_split_bounded_integration PASS");
    $finish;
end

endmodule
