`timescale 1ns/1ps

`include "config/prediction_params.vh"
`include "config/interface_params.vh"
`include "config/memory_params.vh"

module tb_tree_analyze_agu_layered_frontier;

localparam integer SLOT_NUM = `TREE_FRONTIER_SLOTS;
localparam integer LEVEL_NUM = `TREE_MAX_FRONTIER_LEVELS;
localparam [`NODE_ID_W-1:0] NODE_A = 4'h1;
localparam [`NODE_ID_W-1:0] NODE_B = 4'h2;
localparam [`NODE_ID_W-1:0] NODE_C1 = 4'h3;
localparam [`NODE_ID_W-1:0] NODE_C2 = 4'h4;
localparam [`NODE_ID_W-1:0] NODE_D1 = 4'h5;

reg clk;
reg rst_n;

reg req_valid;
wire req_ready;
reg [`REQ_ID_W-1:0] req_id;
reg [`TREE_MAX_PREFIX_NODES-1:0] src_prefix_slot_valid;
reg [`TREE_MAX_PREFIX_NODES*`NODE_ID_W-1:0] src_prefix_node_id;
reg [`TREE_MAX_FRONTIER_LEVELS-1:0] src_frontier_level_valid;
reg [`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS-1:0] src_frontier_slot_valid;
reg [`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0] src_frontier_node_id;
reg [`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0] src_frontier_parent_node_id;

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

reg flush_freeze;

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
    .prefetch_enq_ready(1'b1),
    .cand_resp_valid(1'b0),
    .cand_resp_grant(1'b0),
    .cand_resp_req_id({`REQ_ID_W{1'b0}}),
    .cand_resp_sram_id({`SRAM_ID_W{1'b0}}),
    .cand_resp_bank_id({`BANK_ID_W{1'b0}}),
    .cand_resp_subbank_start({`SUBBANK_ID_W{1'b0}}),
    .cand_resp_group_len({`KV_GROUP_LEN_W{1'b0}}),
    .alloc_resp_valid(1'b0),
    .alloc_resp_grant(1'b0),
    .alloc_resp_req_id({`REQ_ID_W{1'b0}}),
    .alloc_resp_sram_id({`SRAM_ID_W{1'b0}}),
    .alloc_resp_bank_id({`BANK_ID_W{1'b0}}),
    .alloc_resp_subbank_start({`SUBBANK_ID_W{1'b0}}),
    .alloc_resp_group_len({`KV_GROUP_LEN_W{1'b0}}),
    .flush_freeze(1'b0),
    .flush_drain_busy(1'b0),
    .flush_ctrl_valid(1'b0),
    .flush_ctrl_req_id({`REQ_ID_W{1'b0}}),
    .flush_ctrl_branch_mask({`BRANCH_MASK_W{1'b0}}),
    .flush_ctrl_node_mask({`NODE_MASK_W{1'b0}}),
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
    .token_wr_valid(),
    .token_wr_req_id(),
    .token_wr_token_id(),
    .token_wr_position_id(),
    .token_wr_node_id(),
    .token_wr_branch_id(),
    .token_wr_branch_mask(),
    .token_wr_is_shared(),
    .token_wr_sram_id(),
    .token_wr_bank_id(),
    .token_wr_subbank_start(),
    .token_wr_group_len(),
    .prefetch_enq_valid(),
    .prefetch_enq_req_id(),
    .prefetch_enq_branch_id(),
    .prefetch_enq_node_id(),
    .prefetch_enq_layer_id(),
    .prefetch_enq_size_subbank(),
    .prefetch_enq_shared(),
    .prefetch_flush_valid(),
    .prefetch_flush_req_id(),
    .prefetch_flush_branch_mask(),
    .prefetch_flush_node_mask()
);

always #5 clk = ~clk;

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

task load_example_tree;
    begin
        clear_tree_request();
        req_valid = 1'b1;
        req_id = 4'h9;

        src_prefix_slot_valid[0] = 1'b1;
        src_prefix_slot_valid[1] = 1'b1;
        src_prefix_node_id[(0*`NODE_ID_W) +: `NODE_ID_W] = NODE_A;
        src_prefix_node_id[(1*`NODE_ID_W) +: `NODE_ID_W] = NODE_B;

        src_frontier_level_valid[0] = 1'b1;
        src_frontier_level_valid[1] = 1'b1;

        src_frontier_slot_valid[(0*SLOT_NUM) + 0] = 1'b1;
        src_frontier_slot_valid[(0*SLOT_NUM) + 1] = 1'b1;
        src_frontier_node_id[(((0*SLOT_NUM) + 0)*`NODE_ID_W) +: `NODE_ID_W] = NODE_C1;
        src_frontier_node_id[(((0*SLOT_NUM) + 1)*`NODE_ID_W) +: `NODE_ID_W] = NODE_C2;
        src_frontier_parent_node_id[(((0*SLOT_NUM) + 0)*`NODE_ID_W) +: `NODE_ID_W] = NODE_B;
        src_frontier_parent_node_id[(((0*SLOT_NUM) + 1)*`NODE_ID_W) +: `NODE_ID_W] = NODE_B;

        src_frontier_slot_valid[(1*SLOT_NUM) + 0] = 1'b1;
        src_frontier_node_id[(((1*SLOT_NUM) + 0)*`NODE_ID_W) +: `NODE_ID_W] = NODE_D1;
        src_frontier_parent_node_id[(((1*SLOT_NUM) + 0)*`NODE_ID_W) +: `NODE_ID_W] = NODE_C1;
    end
endtask

task expect_prefix_norm;
    input [`NODE_ID_W-1:0] expected_node_id;
    input [`NODE_ID_W-1:0] expected_parent_node_id;
    input [`LAYER_ID_W-1:0] expected_layer_id;
    input expected_is_last;
    begin
        @(posedge clk);
        #1;
        if (!prefix_norm_valid) begin
            $fatal(1, "expected normalized prefix output");
        end
        if (prefix_norm_req_id != 4'h9 ||
            !prefix_norm_node_valid ||
            prefix_norm_node_id != expected_node_id ||
            prefix_norm_parent_node_id != expected_parent_node_id ||
            prefix_norm_layer_id != expected_layer_id ||
            prefix_norm_is_last != expected_is_last ||
            !prefix_norm_is_shared) begin
            $fatal(1, "normalized prefix payload mismatch");
        end
    end
endtask

task expect_frontier_norm;
    input [`TREE_LEVEL_ID_W-1:0] expected_level_id;
    input [`TREE_FRONTIER_SLOTS-1:0] expected_slot_valid;
    input [`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0] expected_node_id;
    input [`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0] expected_parent_node_id;
    integer slot_i;
    begin
        @(posedge clk);
        #1;
        if (!frontier_norm_valid) begin
            $fatal(1, "expected normalized frontier output");
        end
        if (frontier_norm_req_id != 4'h9 ||
            frontier_norm_level_id != expected_level_id ||
            frontier_norm_slot_valid != expected_slot_valid ||
            frontier_norm_node_id != expected_node_id ||
            frontier_norm_parent_node_id != expected_parent_node_id) begin
            $fatal(1, "normalized frontier payload mismatch");
        end
        for (slot_i = 0; slot_i < SLOT_NUM; slot_i = slot_i + 1) begin
            if (expected_slot_valid[slot_i]) begin
                if (frontier_norm_size_subbank[(slot_i*`KV_GROUP_LEN_W) +: `KV_GROUP_LEN_W] !=
                        `KV_GROUP_SIZE_SUBBANK ||
                    frontier_norm_slot_shared[slot_i] != 1'b0) begin
                    $fatal(1, "normalized frontier slot metadata mismatch");
                end
            end
        end
    end
endtask

initial begin
    reg [`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0] expected_nodes_level0;
    reg [`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0] expected_parents_level0;
    reg [`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0] expected_nodes_level1;
    reg [`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0] expected_parents_level1;

    clk = 1'b0;
    rst_n = 1'b0;
    flush_freeze = 1'b0;
    clear_tree_request();

    expected_nodes_level0 = {(SLOT_NUM*`NODE_ID_W){1'b0}};
    expected_parents_level0 = {(SLOT_NUM*`NODE_ID_W){1'b0}};
    expected_nodes_level1 = {(SLOT_NUM*`NODE_ID_W){1'b0}};
    expected_parents_level1 = {(SLOT_NUM*`NODE_ID_W){1'b0}};

    expected_nodes_level0[(0*`NODE_ID_W) +: `NODE_ID_W] = NODE_C1;
    expected_nodes_level0[(1*`NODE_ID_W) +: `NODE_ID_W] = NODE_C2;
    expected_parents_level0[(0*`NODE_ID_W) +: `NODE_ID_W] = NODE_B;
    expected_parents_level0[(1*`NODE_ID_W) +: `NODE_ID_W] = NODE_B;

    expected_nodes_level1[(0*`NODE_ID_W) +: `NODE_ID_W] = NODE_D1;
    expected_parents_level1[(0*`NODE_ID_W) +: `NODE_ID_W] = NODE_C1;

    repeat (3) @(posedge clk);
    rst_n = 1'b1;

    #1;
    if (!req_ready || !prefix_ready || !frontier_ready) begin
        $fatal(1, "front-end should be ready after reset");
    end

    load_example_tree();
    @(posedge clk);
    #1;
    req_valid = 1'b0;

    expect_prefix_norm(NODE_A, `TREE_PARENT_NONE_NODE_ID, {`LAYER_ID_W{1'b0}}, 1'b0);
    expect_prefix_norm(NODE_B, NODE_A, {{(`LAYER_ID_W-1){1'b0}}, 1'b1}, 1'b1);
    expect_frontier_norm(
        {`TREE_LEVEL_ID_W{1'b0}},
        4'b0011,
        expected_nodes_level0,
        expected_parents_level0
    );
    expect_frontier_norm(
        {{(`TREE_LEVEL_ID_W-1){1'b0}}, 1'b1},
        4'b0001,
        expected_nodes_level1,
        expected_parents_level1
    );

    @(posedge clk);
    #1;
    if (prefix_norm_valid || frontier_norm_valid) begin
        $fatal(1, "normalized outputs should drain after the programmed tree");
    end

    $display("tb_tree_analyze_agu_layered_frontier PASS");
    $finish;
end

endmodule
