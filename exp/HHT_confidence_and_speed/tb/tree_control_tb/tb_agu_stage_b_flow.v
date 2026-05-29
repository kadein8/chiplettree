`timescale 1ns/1ps

`include "config/prediction_params.vh"
`include "config/interface_params.vh"
`include "config/memory_params.vh"

module tb_agu_stage_b_flow;

reg clk;
reg rst_n;

reg tree_in_valid;
wire tree_in_ready;
reg [`REQ_ID_W-1:0] tree_in_req_id;
reg [`BRANCH_ID_W-1:0] tree_in_branch_id;
reg [`NODE_ID_W-1:0] tree_in_node_id;

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
reg saw_parallel_cand;
reg saw_token_wr;
integer response_wait_i;
integer response_seen_cycle_i;

agu u_agu (
    .clk(clk),
    .rst_n(rst_n),
    .tree_in_valid(tree_in_valid),
    .tree_in_ready(tree_in_ready),
    .tree_in_req_id(tree_in_req_id),
    .tree_in_branch_id(tree_in_branch_id),
    .tree_in_node_id(tree_in_node_id),
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
    .frontier_valid(1'b0),
    .frontier_ready(),
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

initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    tree_in_valid = 1'b0;
    tree_in_req_id = {`REQ_ID_W{1'b0}};
    tree_in_branch_id = {`BRANCH_ID_W{1'b0}};
    tree_in_node_id = {`NODE_ID_W{1'b0}};
    flush_freeze = 1'b0;

    repeat (3) @(posedge clk);
    rst_n = 1'b1;

    #1;
    if (!tree_in_ready) begin
        $fatal(1, "AGU should be ready after reset when prefetch queue is ready");
    end

    tree_in_valid = 1'b1;
    tree_in_req_id = 4'h3;
    tree_in_branch_id = 2'd2;
    tree_in_node_id = 4'h1;

    #1;
    if (!prefetch_enq_valid) begin
        $fatal(1, "AGU did not issue prefetch enqueue before allocation");
    end

    if (prefetch_enq_req_id != 4'h3 ||
        prefetch_enq_branch_id != 2'd2 ||
        prefetch_enq_node_id != 4'h1 ||
        prefetch_enq_layer_id != {`LAYER_ID_W{1'b0}} ||
        prefetch_enq_size_subbank != `KV_GROUP_SIZE_SUBBANK ||
        prefetch_enq_shared != 1'b0) begin
        $fatal(1, "AGU prefetch enqueue payload mismatch");
    end

    @(posedge clk);
    // Avoid a same-edge TB/DUT race on the acceptance cycle.
    #1;
    tree_in_valid = 1'b0;

    #1;
    if (!prefetch_deq_valid) begin
        $fatal(1, "prefetch_queue did not present allocation work to free_list");
    end

    if (prefetch_deq_req_id != 4'h3 ||
        prefetch_deq_branch_id != 2'd2 ||
        prefetch_deq_node_id != 4'h1 ||
        prefetch_deq_layer_id != {`LAYER_ID_W{1'b0}} ||
        prefetch_deq_size_subbank != `KV_GROUP_SIZE_SUBBANK ||
        prefetch_deq_shared != 1'b0) begin
        $fatal(1, "prefetch_queue dequeue payload mismatch");
    end

    @(posedge clk);
    #1;
    if (!cand_resp_valid || !cand_resp_grant) begin
        $fatal(1, "free_list did not return a granted candidate");
    end

    if (cand_resp_req_id != 4'h3 ||
        cand_resp_sram_id != 2'd0 ||
        cand_resp_bank_id != 4'd0 ||
        cand_resp_subbank_start != 5'd0 ||
        cand_resp_group_len != `KV_GROUP_SIZE_SUBBANK) begin
        $fatal(1, "free_list candidate payload mismatch");
    end

    if (!alloc_cand_valid ||
        alloc_cand_req_id != cand_resp_req_id ||
        alloc_cand_branch_id != 2'd2 ||
        alloc_cand_node_id != 4'h1 ||
        alloc_cand_size_subbank != `KV_GROUP_SIZE_SUBBANK ||
        alloc_cand_shared != 1'b0 ||
        alloc_cand_sram_id != cand_resp_sram_id ||
        alloc_cand_bank_id != cand_resp_bank_id ||
        alloc_cand_subbank_start != cand_resp_subbank_start ||
        alloc_cand_group_len != `KV_GROUP_SIZE_SUBBANK) begin
        $fatal(1, "free_list did not present the direct bank_state_table candidate handoff");
    end

    if (token_wr_valid) begin
        $fatal(1, "token write should not pulse until AGU consumes the free_list feedback");
    end

    saw_parallel_cand = 1'b1;
    saw_token_wr = 1'b0;
    response_seen_cycle_i = -1;
    begin : wait_for_agu_response
        for (response_wait_i = 0; response_wait_i < 4; response_wait_i = response_wait_i + 1) begin
            @(posedge clk);
            #1;
            $display(
                "tb_agu_stage_b_flow debug: step=%0d state=%0d cand_resp_valid=%0b cand_resp_req_id=0x%0h pending_req_id=0x%0h alloc_cand_valid=%0b token_wr_valid=%0b alloc_resp_valid=%0b",
                response_wait_i,
                u_agu.agu_state_r,
                cand_resp_valid,
                cand_resp_req_id,
                u_agu.pending_req_id_r,
                alloc_cand_valid,
                token_wr_valid,
                alloc_resp_valid
            );
            saw_token_wr = saw_token_wr | token_wr_valid;
            if (saw_token_wr) begin
                response_seen_cycle_i = response_wait_i;
                disable wait_for_agu_response;
            end
        end
    end

    if (!saw_token_wr) begin
        $fatal(
            1,
            "AGU did not emit token write after free_list candidate within bounded wait window; final state=%0d",
            u_agu.agu_state_r
        );
    end

    $display("tb_agu_stage_b_flow debug: response_seen_cycle=%0d", response_seen_cycle_i);

    if (token_wr_req_id != 4'h3 ||
        token_wr_node_id != 4'h1 ||
        token_wr_branch_id != 2'd2 ||
        token_wr_branch_mask != 4'b0100 ||
        token_wr_sram_id != cand_resp_sram_id ||
        token_wr_bank_id != cand_resp_bank_id ||
        token_wr_subbank_start != cand_resp_subbank_start ||
        token_wr_group_len != `KV_GROUP_SIZE_SUBBANK) begin
        $fatal(1, "AGU token write should use the free_list candidate immediately");
    end

    if (prefetch_enq_valid) begin
        $fatal(1, "prefetch enqueue should have completed before token write timing");
    end

    if (!alloc_resp_valid ||
        !alloc_resp_grant ||
        alloc_resp_req_id != 4'h3 ||
        alloc_resp_sram_id != cand_resp_sram_id ||
        alloc_resp_bank_id != cand_resp_bank_id ||
        alloc_resp_subbank_start != cand_resp_subbank_start ||
        alloc_resp_group_len != cand_resp_group_len) begin
        $fatal(1, "bank_state_table did not validate the direct free_list candidate");
    end

    @(posedge clk);
    #1;
    if (!tree_in_ready) begin
        $fatal(1, "AGU should return to ready after alloc response");
    end

    flush_freeze = 1'b1;
    @(posedge clk);
    #1;
    if (tree_in_ready) begin
        $fatal(1, "AGU should not accept new tree input during flush freeze");
    end

    $display("tb_agu_stage_b_flow PASS");
    $finish;
end

endmodule




