`timescale 1ns/1ps

`include "config/prediction_params.vh"
`include "config/interface_params.vh"
`include "config/memory_params.vh"

module tb_agu_tree_stage_b_dispatch;

localparam [`REQ_ID_W-1:0] TEST_REQ_ID = 4'h6;
localparam [`NODE_ID_W-1:0] NODE_A = 4'h1;
localparam [`NODE_ID_W-1:0] NODE_C1 = 4'h3;

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
wire [`BANK_OCC_BITMAP_W-1:0] alloc_resp_occ_bitmap;

reg flush_freeze;

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
    .flush_drain_busy(1'b0),
    .flush_ctrl_valid(1'b0),
    .flush_ctrl_req_id({`REQ_ID_W{1'b0}}),
    .flush_ctrl_branch_mask({`BRANCH_MASK_W{1'b0}}),
    .flush_ctrl_node_mask({`NODE_MASK_W{1'b0}}),
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
    .prefetch_flush_valid(),
    .prefetch_flush_req_id(),
    .prefetch_flush_branch_mask(),
    .prefetch_flush_node_mask()
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

task load_simple_tree;
    begin
        clear_tree_request();
        req_valid = 1'b1;
        req_id = TEST_REQ_ID;
        src_prefix_slot_valid[0] = 1'b1;
        src_prefix_node_id[(0*`NODE_ID_W) +: `NODE_ID_W] = NODE_A;
        src_frontier_level_valid[0] = 1'b1;
        src_frontier_slot_valid[0] = 1'b1;
        src_frontier_node_id[(0*`NODE_ID_W) +: `NODE_ID_W] = NODE_C1;
        src_frontier_parent_node_id[(0*`NODE_ID_W) +: `NODE_ID_W] = NODE_A;
    end
endtask

task wait_for_prefetch_dispatch;
    input [`NODE_ID_W-1:0] expected_node_id;
    input [`BRANCH_ID_W-1:0] expected_branch_id;
    input [`LAYER_ID_W-1:0] expected_layer_id;
    input expected_shared;
    integer wait_i;
    reg seen;
    begin
        seen = 1'b0;
        for (wait_i = 0; wait_i < 8; wait_i = wait_i + 1) begin
            @(negedge clk);
            #1;
            if (prefetch_enq_valid) begin
                seen = 1'b1;
                if (prefetch_enq_req_id != TEST_REQ_ID ||
                    prefetch_enq_branch_id != expected_branch_id ||
                    prefetch_enq_node_id != expected_node_id ||
                    prefetch_enq_layer_id != expected_layer_id ||
                    prefetch_enq_size_subbank != `KV_GROUP_SIZE_SUBBANK ||
                    prefetch_enq_shared != expected_shared) begin
                    $fatal(1, "tree-driven prefetch payload mismatch");
                end
                disable wait_for_prefetch_dispatch;
            end
        end
        if (!seen) begin
            $fatal(
                1,
                "tree-driven Stage B path did not emit prefetch work; final state=%0d prefix_valid=%0b frontier_valid=%0b treeq_count=%0d",
                u_agu.agu_state_r,
                prefix_valid,
                frontier_valid,
                u_agu.treeq_count_r
            );
        end
    end
endtask

task wait_for_alloc_and_token;
    input [`NODE_ID_W-1:0] expected_node_id;
    input [`BRANCH_ID_W-1:0] expected_branch_id;
    input [`BRANCH_MASK_W-1:0] expected_branch_mask;
    input expected_shared;
    integer wait_i;
    reg seen;
    begin
        seen = 1'b0;
        for (wait_i = 0; wait_i < 8; wait_i = wait_i + 1) begin
            @(posedge clk);
            #1;
            if (token_wr_valid) begin
                if (token_wr_req_id != TEST_REQ_ID ||
                    token_wr_node_id != expected_node_id ||
                    token_wr_branch_id != expected_branch_id ||
                    token_wr_branch_mask != expected_branch_mask ||
                    token_wr_is_shared != expected_shared ||
                    token_wr_group_len != `KV_GROUP_SIZE_SUBBANK ||
                    token_wr_sram_id != alloc_cand_sram_id ||
                    token_wr_bank_id != alloc_cand_bank_id ||
                    token_wr_subbank_start != alloc_cand_subbank_start) begin
                    $fatal(1, "tree-driven token write mismatch");
                end
                if (!alloc_resp_valid ||
                    !alloc_resp_grant ||
                    alloc_resp_req_id != TEST_REQ_ID ||
                    alloc_resp_sram_id != alloc_cand_sram_id ||
                    alloc_resp_bank_id != alloc_cand_bank_id ||
                    alloc_resp_subbank_start != alloc_cand_subbank_start ||
                    alloc_resp_group_len != alloc_cand_group_len) begin
                    $fatal(1, "tree-driven bank_state_table response mismatch");
                end
                disable wait_for_alloc_and_token;
            end
        end
        if (!seen) begin
            $fatal(1, "tree-driven Stage B path did not reach alloc/token side effects");
        end
    end
endtask

initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    clear_tree_request();
    flush_freeze = 1'b0;

    repeat (3) @(posedge clk);
    rst_n = 1'b1;

    #1;
    if (!req_ready || !prefix_ready || !frontier_ready) begin
        $fatal(1, "tree front-end should be ready after reset");
    end

    load_simple_tree();
    @(posedge clk);
    #1;
    req_valid = 1'b0;

    wait_for_prefetch_dispatch(
        NODE_A,
        {`BRANCH_ID_W{1'b0}},
        {`LAYER_ID_W{1'b0}},
        1'b1
    );
    wait_for_alloc_and_token(
        NODE_A,
        {`BRANCH_ID_W{1'b0}},
        {`BRANCH_MASK_W{1'b1}},
        1'b1
    );

    wait_for_prefetch_dispatch(
        NODE_C1,
        {`BRANCH_ID_W{1'b0}},
        {`LAYER_ID_W{1'b0}},
        1'b0
    );
    wait_for_alloc_and_token(
        NODE_C1,
        {`BRANCH_ID_W{1'b0}},
        {{(`BRANCH_MASK_W-1){1'b0}}, 1'b1},
        1'b0
    );

    $display("tb_agu_tree_stage_b_dispatch PASS");
    $finish;
end

endmodule
