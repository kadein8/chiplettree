`timescale 1ns/1ps

`include "config/prediction_params.vh"
`include "config/interface_params.vh"
`include "config/memory_params.vh"

module tb_comparator_async_ordering;

localparam integer PRIVATE_DEPTH_W =
    (((`MAX_VERIFY_NODES_PER_BRANCH + 1) <= 2) ? 1 :
     $clog2(`MAX_VERIFY_NODES_PER_BRANCH + 1));
localparam integer BRANCH_EPOCH_W = 2;
localparam integer PATH_PACK_W =
    (`BRANCH_NUM * `MAX_VERIFY_NODES_PER_BRANCH * `NODE_ID_W);
localparam integer DEPTH_PACK_W =
    (`BRANCH_NUM * PRIVATE_DEPTH_W);
localparam integer EPOCH_PACK_W =
    (`BRANCH_NUM * BRANCH_EPOCH_W);

localparam [`REQ_ID_W-1:0] TEST_REQ_ID = 4'hA;
localparam [`REQ_ID_W-1:0] STALE_REQ_ID = 4'hB;

localparam [`BRANCH_ID_W-1:0] BRANCH_ABC1   = 2'd0;
localparam [`BRANCH_ID_W-1:0] BRANCH_ABC1D1 = 2'd1;
localparam [`BRANCH_ID_W-1:0] BRANCH_ABC2   = 2'd2;
localparam [`BRANCH_ID_W-1:0] BRANCH_ABC2D2 = 2'd3;

localparam [`NODE_ID_W-1:0] NODE_C1 = 4'd0;
localparam [`NODE_ID_W-1:0] NODE_D1 = 4'd1;
localparam [`NODE_ID_W-1:0] NODE_C2 = 4'd2;
localparam [`NODE_ID_W-1:0] NODE_D2 = 4'd3;
localparam [`NODE_ID_W-1:0] NODE_NONE = `TREE_PARENT_NONE_NODE_ID;

localparam integer FLUSH_NODE_BIT_C2 =
    (BRANCH_ABC2 * `MAX_VERIFY_NODES_PER_BRANCH) + NODE_C2;
localparam integer FLUSH_NODE_BIT_D2 =
    (BRANCH_ABC2D2 * `MAX_VERIFY_NODES_PER_BRANCH) + NODE_D2;

reg clk;
reg rst_n;

reg [`REQ_ID_W-1:0] cmp_req_id;
reg [`BRANCH_NUM-1:0] cmp_slot_valid;
reg [`BRANCH_NUM*`TOKEN_ID_W-1:0] cmp_slot_real_token_id;
reg [`BRANCH_NUM*`TOKEN_ID_W-1:0] cmp_slot_candidate_token_id;
reg [`BRANCH_NUM*`NODE_ID_W-1:0] cmp_slot_node_id;
reg [`BRANCH_NUM*`NODE_ID_W-1:0] cmp_slot_parent_node_id;
reg [`BRANCH_NUM*`BRANCH_ID_W-1:0] cmp_slot_branch_id;

reg                         reduce_start_valid;
reg [`REQ_ID_W-1:0]        reduce_req_id;
reg [`BRANCH_NUM-1:0]      active_branch_valid;
reg [EPOCH_PACK_W-1:0]     active_branch_epoch;
reg [DEPTH_PACK_W-1:0]     active_branch_depth;
reg [PATH_PACK_W-1:0]      active_branch_node_id;
reg [PATH_PACK_W-1:0]      active_branch_parent_node_id;
reg [`BRANCH_NUM-1:0]      result_slot_valid;
reg [`REQ_ID_W-1:0]        result_req_id;
reg [`BRANCH_NUM*`BRANCH_ID_W-1:0] result_branch_id;
reg [EPOCH_PACK_W-1:0]     result_branch_epoch;
reg [DEPTH_PACK_W-1:0]     result_private_depth;
reg [`BRANCH_NUM*`NODE_ID_W-1:0] result_node_id;
reg [`BRANCH_NUM*`NODE_ID_W-1:0] result_parent_node_id;
reg [`BRANCH_NUM-1:0]      result_accept;

wire commit_valid;
wire [`BRANCH_MASK_W-1:0] commit_branch_mask;
wire [`NODE_MASK_W-1:0] commit_node_mask;
wire flush_valid;
wire [`BRANCH_MASK_W-1:0] flush_branch_mask;
wire [`NODE_MASK_W-1:0] flush_node_mask;
wire accepted_prefix_valid;
wire [`REQ_ID_W-1:0] accepted_prefix_req_id;
wire [PRIVATE_DEPTH_W-1:0] accepted_prefix_depth;
wire [(`MAX_VERIFY_NODES_PER_BRANCH*`NODE_ID_W)-1:0] accepted_prefix_node_id;
wire [`BRANCH_NUM-1:0] live_branch_mask;
wire [`BRANCH_NUM-1:0] prune_branch_mask;

reg tree_in_valid;
wire tree_in_ready;
reg [`REQ_ID_W-1:0] tree_in_req_id;
reg [`BRANCH_ID_W-1:0] tree_in_branch_id;
reg [`NODE_ID_W-1:0] tree_in_node_id;

reg prefix_valid;
wire prefix_ready;
reg [`REQ_ID_W-1:0] prefix_req_id;
reg prefix_node_valid;
reg [`NODE_ID_W-1:0] prefix_node_id;
reg [`NODE_ID_W-1:0] prefix_parent_node_id;
reg [`TOKEN_ID_W-1:0] prefix_token_id;
reg [`POSITION_ID_W-1:0] prefix_position_id;
reg [`LAYER_ID_W-1:0] prefix_layer_id;
reg prefix_is_last;

reg frontier_valid;
wire frontier_ready;
reg [`REQ_ID_W-1:0] frontier_req_id;
reg [`TREE_LEVEL_ID_W-1:0] frontier_level_id;
reg [`TREE_FRONTIER_SLOTS-1:0] frontier_slot_valid;
reg [`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0] frontier_node_id;
reg [`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0] frontier_parent_node_id;
reg [`TREE_FRONTIER_SLOTS*`TOKEN_ID_W-1:0] frontier_token_id;
reg [`TREE_FRONTIER_SLOTS*`POSITION_ID_W-1:0] frontier_position_id;

reg prefetch_enq_ready;
reg cand_resp_valid;
reg cand_resp_grant;
reg [`REQ_ID_W-1:0] cand_resp_req_id;
reg [`SRAM_ID_W-1:0] cand_resp_sram_id;
reg [`BANK_ID_W-1:0] cand_resp_bank_id;
reg [`SUBBANK_ID_W-1:0] cand_resp_subbank_start;
reg [`KV_GROUP_LEN_W-1:0] cand_resp_group_len;
reg alloc_resp_valid;
reg alloc_resp_grant;
reg [`REQ_ID_W-1:0] alloc_resp_req_id;
reg [`SRAM_ID_W-1:0] alloc_resp_sram_id;
reg [`BANK_ID_W-1:0] alloc_resp_bank_id;
reg [`SUBBANK_ID_W-1:0] alloc_resp_subbank_start;
reg [`KV_GROUP_LEN_W-1:0] alloc_resp_group_len;
reg flush_freeze;
reg flush_drain_busy;
reg flush_ctrl_valid;
reg [`REQ_ID_W-1:0] flush_ctrl_req_id;
reg [`BRANCH_MASK_W-1:0] flush_ctrl_branch_mask;
reg [`NODE_MASK_W-1:0] flush_ctrl_node_mask;

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
    .reduce_start_valid(reduce_start_valid),
    .reduce_req_id(reduce_req_id),
    .active_branch_valid(active_branch_valid),
    .active_branch_epoch(active_branch_epoch),
    .active_branch_depth(active_branch_depth),
    .active_branch_node_id(active_branch_node_id),
    .active_branch_parent_node_id(active_branch_parent_node_id),
    .result_slot_valid(result_slot_valid),
    .result_req_id(result_req_id),
    .result_branch_id(result_branch_id),
    .result_branch_epoch(result_branch_epoch),
    .result_private_depth(result_private_depth),
    .result_node_id(result_node_id),
    .result_parent_node_id(result_parent_node_id),
    .result_accept(result_accept),
    .commit_valid(commit_valid),
    .commit_branch_mask(commit_branch_mask),
    .commit_node_mask(commit_node_mask),
    .flush_valid(flush_valid),
    .flush_branch_mask(flush_branch_mask),
    .flush_node_mask(flush_node_mask),
    .accepted_prefix_valid(accepted_prefix_valid),
    .accepted_prefix_req_id(accepted_prefix_req_id),
    .accepted_prefix_depth(accepted_prefix_depth),
    .accepted_prefix_node_id(accepted_prefix_node_id),
    .live_branch_mask(live_branch_mask),
    .prune_branch_mask(prune_branch_mask)
);

agu u_agu (
    .clk(clk),
    .rst_n(rst_n),
    .tree_in_valid(tree_in_valid),
    .tree_in_ready(tree_in_ready),
    .tree_in_req_id(tree_in_req_id),
    .tree_in_branch_id(tree_in_branch_id),
    .tree_in_node_id(tree_in_node_id),
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
    .flush_freeze(flush_freeze),
    .flush_drain_busy(flush_drain_busy),
    .flush_ctrl_valid(flush_ctrl_valid),
    .flush_ctrl_req_id(flush_ctrl_req_id),
    .flush_ctrl_branch_mask(flush_ctrl_branch_mask),
    .flush_ctrl_node_mask(flush_ctrl_node_mask),
    .branch_liveness_valid(accepted_prefix_valid),
    .branch_liveness_req_id(accepted_prefix_req_id),
    .branch_liveness_live_mask(live_branch_mask),
    .branch_liveness_prune_mask(prune_branch_mask),
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

always #5 clk = ~clk;

task clear_comparator_inputs;
    begin
        cmp_req_id = {`REQ_ID_W{1'b0}};
        cmp_slot_valid = {`BRANCH_NUM{1'b0}};
        cmp_slot_real_token_id = {(`BRANCH_NUM*`TOKEN_ID_W){1'b0}};
        cmp_slot_candidate_token_id = {(`BRANCH_NUM*`TOKEN_ID_W){1'b0}};
        cmp_slot_node_id = {(`BRANCH_NUM*`NODE_ID_W){1'b0}};
        cmp_slot_parent_node_id = {(`BRANCH_NUM*`NODE_ID_W){1'b0}};
        cmp_slot_branch_id = {(`BRANCH_NUM*`BRANCH_ID_W){1'b0}};
        reduce_start_valid = 1'b0;
        reduce_req_id = {`REQ_ID_W{1'b0}};
        active_branch_valid = {`BRANCH_NUM{1'b0}};
        active_branch_epoch = {EPOCH_PACK_W{1'b0}};
        active_branch_depth = {DEPTH_PACK_W{1'b0}};
        active_branch_node_id = {PATH_PACK_W{1'b0}};
        active_branch_parent_node_id = {PATH_PACK_W{1'b0}};
        result_slot_valid = {`BRANCH_NUM{1'b0}};
        result_req_id = {`REQ_ID_W{1'b0}};
        result_branch_id = {(`BRANCH_NUM*`BRANCH_ID_W){1'b0}};
        result_branch_epoch = {EPOCH_PACK_W{1'b0}};
        result_private_depth = {DEPTH_PACK_W{1'b0}};
        result_node_id = {(`BRANCH_NUM*`NODE_ID_W){1'b0}};
        result_parent_node_id = {(`BRANCH_NUM*`NODE_ID_W){1'b0}};
        result_accept = {`BRANCH_NUM{1'b0}};
    end
endtask

task clear_agu_inputs;
    begin
        tree_in_valid = 1'b0;
        tree_in_req_id = {`REQ_ID_W{1'b0}};
        tree_in_branch_id = {`BRANCH_ID_W{1'b0}};
        tree_in_node_id = {`NODE_ID_W{1'b0}};
        prefix_valid = 1'b0;
        prefix_req_id = {`REQ_ID_W{1'b0}};
        prefix_node_valid = 1'b0;
        prefix_node_id = {`NODE_ID_W{1'b0}};
        prefix_parent_node_id = {`NODE_ID_W{1'b0}};
        prefix_token_id = {`TOKEN_ID_W{1'b0}};
        prefix_position_id = {`POSITION_ID_W{1'b0}};
        prefix_layer_id = {`LAYER_ID_W{1'b0}};
        prefix_is_last = 1'b0;
        frontier_valid = 1'b0;
        frontier_req_id = {`REQ_ID_W{1'b0}};
        frontier_level_id = {`TREE_LEVEL_ID_W{1'b0}};
        frontier_slot_valid = {`TREE_FRONTIER_SLOTS{1'b0}};
        frontier_node_id = {(`TREE_FRONTIER_SLOTS*`NODE_ID_W){1'b0}};
        frontier_parent_node_id = {(`TREE_FRONTIER_SLOTS*`NODE_ID_W){1'b0}};
        frontier_token_id = {(`TREE_FRONTIER_SLOTS*`TOKEN_ID_W){1'b0}};
        frontier_position_id = {(`TREE_FRONTIER_SLOTS*`POSITION_ID_W){1'b0}};
        prefetch_enq_ready = 1'b0;
        cand_resp_valid = 1'b0;
        cand_resp_grant = 1'b0;
        cand_resp_req_id = {`REQ_ID_W{1'b0}};
        cand_resp_sram_id = {`SRAM_ID_W{1'b0}};
        cand_resp_bank_id = {`BANK_ID_W{1'b0}};
        cand_resp_subbank_start = {`SUBBANK_ID_W{1'b0}};
        cand_resp_group_len = {`KV_GROUP_LEN_W{1'b0}};
        alloc_resp_valid = 1'b0;
        alloc_resp_grant = 1'b0;
        alloc_resp_req_id = {`REQ_ID_W{1'b0}};
        alloc_resp_sram_id = {`SRAM_ID_W{1'b0}};
        alloc_resp_bank_id = {`BANK_ID_W{1'b0}};
        alloc_resp_subbank_start = {`SUBBANK_ID_W{1'b0}};
        alloc_resp_group_len = {`KV_GROUP_LEN_W{1'b0}};
        flush_freeze = 1'b0;
        flush_drain_busy = 1'b0;
        flush_ctrl_valid = 1'b0;
        flush_ctrl_req_id = {`REQ_ID_W{1'b0}};
        flush_ctrl_branch_mask = {`BRANCH_MASK_W{1'b0}};
        flush_ctrl_node_mask = {`NODE_MASK_W{1'b0}};
    end
endtask

task preload_active_branches;
    begin
        reduce_start_valid = 1'b1;
        reduce_req_id = TEST_REQ_ID;
        active_branch_valid = 4'b1111;
        active_branch_epoch[(BRANCH_ABC1*BRANCH_EPOCH_W) +: BRANCH_EPOCH_W] = 2'd0;
        active_branch_epoch[(BRANCH_ABC1D1*BRANCH_EPOCH_W) +: BRANCH_EPOCH_W] = 2'd0;
        active_branch_epoch[(BRANCH_ABC2*BRANCH_EPOCH_W) +: BRANCH_EPOCH_W] = 2'd0;
        active_branch_epoch[(BRANCH_ABC2D2*BRANCH_EPOCH_W) +: BRANCH_EPOCH_W] = 2'd0;
        active_branch_depth[(BRANCH_ABC1*PRIVATE_DEPTH_W) +: PRIVATE_DEPTH_W] = PRIVATE_DEPTH_W'(1);
        active_branch_depth[(BRANCH_ABC1D1*PRIVATE_DEPTH_W) +: PRIVATE_DEPTH_W] = PRIVATE_DEPTH_W'(2);
        active_branch_depth[(BRANCH_ABC2*PRIVATE_DEPTH_W) +: PRIVATE_DEPTH_W] = PRIVATE_DEPTH_W'(1);
        active_branch_depth[(BRANCH_ABC2D2*PRIVATE_DEPTH_W) +: PRIVATE_DEPTH_W] = PRIVATE_DEPTH_W'(2);
        active_branch_node_id[(((BRANCH_ABC1*`MAX_VERIFY_NODES_PER_BRANCH)+0)*`NODE_ID_W) +: `NODE_ID_W] = NODE_C1;
        active_branch_parent_node_id[(((BRANCH_ABC1*`MAX_VERIFY_NODES_PER_BRANCH)+0)*`NODE_ID_W) +: `NODE_ID_W] = NODE_NONE;
        active_branch_node_id[(((BRANCH_ABC1D1*`MAX_VERIFY_NODES_PER_BRANCH)+0)*`NODE_ID_W) +: `NODE_ID_W] = NODE_C1;
        active_branch_parent_node_id[(((BRANCH_ABC1D1*`MAX_VERIFY_NODES_PER_BRANCH)+0)*`NODE_ID_W) +: `NODE_ID_W] = NODE_NONE;
        active_branch_node_id[(((BRANCH_ABC1D1*`MAX_VERIFY_NODES_PER_BRANCH)+1)*`NODE_ID_W) +: `NODE_ID_W] = NODE_D1;
        active_branch_parent_node_id[(((BRANCH_ABC1D1*`MAX_VERIFY_NODES_PER_BRANCH)+1)*`NODE_ID_W) +: `NODE_ID_W] = NODE_C1;
        active_branch_node_id[(((BRANCH_ABC2*`MAX_VERIFY_NODES_PER_BRANCH)+0)*`NODE_ID_W) +: `NODE_ID_W] = NODE_C2;
        active_branch_parent_node_id[(((BRANCH_ABC2*`MAX_VERIFY_NODES_PER_BRANCH)+0)*`NODE_ID_W) +: `NODE_ID_W] = NODE_NONE;
        active_branch_node_id[(((BRANCH_ABC2D2*`MAX_VERIFY_NODES_PER_BRANCH)+0)*`NODE_ID_W) +: `NODE_ID_W] = NODE_C2;
        active_branch_parent_node_id[(((BRANCH_ABC2D2*`MAX_VERIFY_NODES_PER_BRANCH)+0)*`NODE_ID_W) +: `NODE_ID_W] = NODE_NONE;
        active_branch_node_id[(((BRANCH_ABC2D2*`MAX_VERIFY_NODES_PER_BRANCH)+1)*`NODE_ID_W) +: `NODE_ID_W] = NODE_D2;
        active_branch_parent_node_id[(((BRANCH_ABC2D2*`MAX_VERIFY_NODES_PER_BRANCH)+1)*`NODE_ID_W) +: `NODE_ID_W] = NODE_C2;
    end
endtask

task drive_first_discriminating_results;
    begin
        result_slot_valid = 4'b0101;
        result_req_id = TEST_REQ_ID;
        result_branch_id[(0*`BRANCH_ID_W) +: `BRANCH_ID_W] = BRANCH_ABC1;
        result_branch_epoch[(0*BRANCH_EPOCH_W) +: BRANCH_EPOCH_W] = 2'd0;
        result_private_depth[(0*PRIVATE_DEPTH_W) +: PRIVATE_DEPTH_W] = PRIVATE_DEPTH_W'(1);
        result_node_id[(0*`NODE_ID_W) +: `NODE_ID_W] = NODE_C1;
        result_parent_node_id[(0*`NODE_ID_W) +: `NODE_ID_W] = NODE_NONE;
        result_accept[0] = 1'b1;
        result_branch_id[(2*`BRANCH_ID_W) +: `BRANCH_ID_W] = BRANCH_ABC2;
        result_branch_epoch[(2*BRANCH_EPOCH_W) +: BRANCH_EPOCH_W] = 2'd0;
        result_private_depth[(2*PRIVATE_DEPTH_W) +: PRIVATE_DEPTH_W] = PRIVATE_DEPTH_W'(1);
        result_node_id[(2*`NODE_ID_W) +: `NODE_ID_W] = NODE_C2;
        result_parent_node_id[(2*`NODE_ID_W) +: `NODE_ID_W] = NODE_NONE;
        result_accept[2] = 1'b0;
    end
endtask

task drive_stale_wrong_request_result;
    begin
        result_slot_valid = 4'b0010;
        result_req_id = STALE_REQ_ID;
        result_branch_id[(1*`BRANCH_ID_W) +: `BRANCH_ID_W] = BRANCH_ABC1D1;
        result_branch_epoch[(1*BRANCH_EPOCH_W) +: BRANCH_EPOCH_W] = 2'd0;
        result_private_depth[(1*PRIVATE_DEPTH_W) +: PRIVATE_DEPTH_W] = PRIVATE_DEPTH_W'(2);
        result_node_id[(1*`NODE_ID_W) +: `NODE_ID_W] = NODE_D1;
        result_parent_node_id[(1*`NODE_ID_W) +: `NODE_ID_W] = NODE_C1;
        result_accept[1] = 1'b1;
    end
endtask

task expect_prefix_state;
    input [255:0] scenario_name;
    input [`BRANCH_NUM-1:0] expect_prune_mask;
    begin
        #1;
        if (!accepted_prefix_valid ||
            (accepted_prefix_req_id != TEST_REQ_ID) ||
            (accepted_prefix_depth != PRIVATE_DEPTH_W'(1)) ||
            (accepted_prefix_node_id[`NODE_ID_W-1:0] != NODE_C1) ||
            (live_branch_mask != 4'b0011) ||
            (prune_branch_mask != expect_prune_mask)) begin
            $fatal(1, "%0s: accepted-prefix or branch-liveness state mismatch", scenario_name);
        end
    end
endtask

task expect_no_spontaneous_issue;
    input [255:0] scenario_name;
    input integer cycle_count;
    integer wait_i;
    begin
        for (wait_i = 0; wait_i < cycle_count; wait_i = wait_i + 1) begin
            @(negedge clk);
            #1;
            if (prefetch_enq_valid) begin
                $fatal(1, "%0s: unexpected AGU issue observed", scenario_name);
            end
        end
    end
endtask

task complete_candidate_and_alloc;
    input [`REQ_ID_W-1:0] req_id_in;
    begin
        @(posedge clk);
        #1;
        cand_resp_valid = 1'b1;
        cand_resp_grant = 1'b1;
        cand_resp_req_id = req_id_in;
        cand_resp_group_len = `KV_GROUP_SIZE_SUBBANK;
        @(posedge clk);
        #1;
        cand_resp_valid = 1'b0;
        cand_resp_grant = 1'b0;
        alloc_resp_valid = 1'b1;
        alloc_resp_grant = 1'b1;
        alloc_resp_req_id = req_id_in;
        alloc_resp_group_len = `KV_GROUP_SIZE_SUBBANK;
        @(posedge clk);
        #1;
        alloc_resp_valid = 1'b0;
        alloc_resp_grant = 1'b0;
    end
endtask

task issue_branch_and_complete;
    input [255:0] scenario_name;
    input [`BRANCH_ID_W-1:0] branch_id_in;
    input [`NODE_ID_W-1:0] node_id_in;
    begin
        @(negedge clk);
        #1;
        tree_in_valid = 1'b1;
        tree_in_req_id = TEST_REQ_ID;
        tree_in_branch_id = branch_id_in;
        tree_in_node_id = node_id_in;
        #1;
        if (!tree_in_ready ||
            !prefetch_enq_valid ||
            (prefetch_enq_req_id != TEST_REQ_ID) ||
            (prefetch_enq_branch_id != branch_id_in) ||
            (prefetch_enq_node_id != node_id_in)) begin
            $fatal(1, "%0s: expected branch dispatch missing", scenario_name);
        end
        @(posedge clk);
        #1;
        tree_in_valid = 1'b0;
        complete_candidate_and_alloc(TEST_REQ_ID);
    end
endtask

task expect_branch_blocked;
    input [255:0] scenario_name;
    input [`BRANCH_ID_W-1:0] branch_id_in;
    input [`NODE_ID_W-1:0] node_id_in;
    begin
        @(negedge clk);
        #1;
        tree_in_valid = 1'b1;
        tree_in_req_id = TEST_REQ_ID;
        tree_in_branch_id = branch_id_in;
        tree_in_node_id = node_id_in;
        #1;
        if (tree_in_ready || prefetch_enq_valid) begin
            $fatal(1, "%0s: branch should remain blocked", scenario_name);
        end
        @(posedge clk);
        #1;
        tree_in_valid = 1'b0;
    end
endtask

task start_flush_window;
    reg [`NODE_MASK_W-1:0] local_node_mask;
    begin
        local_node_mask = {`NODE_MASK_W{1'b0}};
        local_node_mask[FLUSH_NODE_BIT_C2] = 1'b1;
        local_node_mask[FLUSH_NODE_BIT_D2] = 1'b1;

        flush_freeze = 1'b1;
        flush_ctrl_valid = 1'b1;
        flush_ctrl_req_id = TEST_REQ_ID;
        flush_ctrl_branch_mask = 4'b1100;
        flush_ctrl_node_mask = local_node_mask;
    end
endtask

task hold_flush_window;
    begin
        flush_ctrl_valid = 1'b0;
        flush_ctrl_req_id = {`REQ_ID_W{1'b0}};
        flush_ctrl_branch_mask = {`BRANCH_MASK_W{1'b0}};
        flush_ctrl_node_mask = {`NODE_MASK_W{1'b0}};
        flush_freeze = 1'b1;
    end
endtask

task clear_flush_window;
    begin
        flush_freeze = 1'b0;
        flush_ctrl_valid = 1'b0;
        flush_ctrl_req_id = {`REQ_ID_W{1'b0}};
        flush_ctrl_branch_mask = {`BRANCH_MASK_W{1'b0}};
        flush_ctrl_node_mask = {`NODE_MASK_W{1'b0}};
    end
endtask

task expect_flush_window_closed;
    input [255:0] scenario_name;
    begin
        #1;
        if (!flush_freeze ||
            !prefetch_flush_valid ||
            (prefetch_flush_req_id != TEST_REQ_ID) ||
            (prefetch_flush_branch_mask != 4'b1100) ||
            tree_in_ready ||
            prefix_ready ||
            frontier_ready ||
            prefetch_enq_valid) begin
            $fatal(1, "%0s: flush window did not close AGU acceptance as expected", scenario_name);
        end
    end
endtask

initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    clear_comparator_inputs();
    clear_agu_inputs();

    repeat (3) @(posedge clk);
    rst_n = 1'b1;

    prefetch_enq_ready = 1'b1;

    preload_active_branches();
    drive_first_discriminating_results();
    expect_prefix_state("phase_a_reduction", 4'b1100);

    @(posedge clk);
    #1;
    clear_comparator_inputs();

    issue_branch_and_complete("phase_b_survivor_pre_stale", BRANCH_ABC1, NODE_C1);
    expect_branch_blocked("phase_b_killed_pre_stale", BRANCH_ABC2, NODE_C2);

    drive_stale_wrong_request_result();
    expect_prefix_state("phase_c_stale_state", 4'b0000);
    expect_no_spontaneous_issue("phase_c_stale_drop", 4);
    expect_branch_blocked("phase_c_killed_still_blocked", BRANCH_ABC2D2, NODE_D2);

    @(posedge clk);
    #1;
    clear_comparator_inputs();

    start_flush_window();
    expect_prefix_state("phase_d_flush_keeps_prefix", 4'b0000);
    expect_flush_window_closed("phase_d_flush_accept_closed");
    expect_branch_blocked("phase_d_survivor_blocked_by_freeze", BRANCH_ABC1, NODE_C1);

    @(posedge clk);
    #1;
    hold_flush_window();
    expect_prefix_state("phase_d_flush_hold_keeps_prefix", 4'b0000);
    expect_branch_blocked("phase_d_survivor_blocked_during_freeze_hold", BRANCH_ABC1D1, NODE_D1);

    @(posedge clk);
    #1;
    clear_flush_window();

    issue_branch_and_complete("phase_e_survivor_post_flush", BRANCH_ABC1D1, NODE_D1);
    expect_branch_blocked("phase_e_killed_post_flush", BRANCH_ABC2, NODE_C2);
    expect_prefix_state("phase_e_post_flush_prefix_stable", 4'b0000);

    $display("tb_comparator_async_ordering PASS");
    $finish;
end

endmodule
