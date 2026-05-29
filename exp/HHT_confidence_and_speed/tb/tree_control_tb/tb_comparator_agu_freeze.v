`timescale 1ns/1ps

`include "config/prediction_params.vh"
`include "config/interface_params.vh"
`include "config/memory_params.vh"

module tb_comparator_agu_freeze;

reg clk;
reg rst_n;

reg [`REQ_ID_W-1:0] cmp_req_id;
reg [`BRANCH_NUM-1:0] cmp_slot_valid;
reg [`BRANCH_NUM*`TOKEN_ID_W-1:0] cmp_slot_real_token_id;
reg [`BRANCH_NUM*`TOKEN_ID_W-1:0] cmp_slot_candidate_token_id;
reg [`BRANCH_NUM*`NODE_ID_W-1:0] cmp_slot_node_id;
reg [`BRANCH_NUM*`NODE_ID_W-1:0] cmp_slot_parent_node_id;
reg [`BRANCH_NUM*`BRANCH_ID_W-1:0] cmp_slot_branch_id;

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

wire commit_valid;
wire [`BRANCH_MASK_W-1:0] commit_branch_mask;
wire [`NODE_MASK_W-1:0] commit_node_mask;
wire flush_valid;
wire [`BRANCH_MASK_W-1:0] flush_branch_mask;
wire [`NODE_MASK_W-1:0] flush_node_mask;
wire flush_freeze;

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

assign flush_freeze = flush_valid;

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
    .flush_freeze(flush_valid),
    .flush_drain_busy(1'b0),
    .flush_ctrl_valid(flush_valid),
    .flush_ctrl_req_id(cmp_req_id),
    .flush_ctrl_branch_mask(flush_branch_mask),
    .flush_ctrl_node_mask(flush_node_mask),
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
    .prefetch_flush_valid(),
    .prefetch_flush_req_id(),
    .prefetch_flush_branch_mask(),
    .prefetch_flush_node_mask()
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
        prefetch_enq_ready = 1'b1;
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
    end
endtask

task drive_frontend_accept_inputs;
    begin
        tree_in_valid = 1'b1;
        tree_in_req_id = 4'h3;
        tree_in_branch_id = 2'd1;
        tree_in_node_id = 4'd2;

        prefix_valid = 1'b1;
        prefix_req_id = 4'h4;
        prefix_node_valid = 1'b1;
        prefix_node_id = 4'd1;
        prefix_parent_node_id = 4'd0;
        prefix_token_id = 16'h0011;
        prefix_position_id = 16'h0022;
        prefix_layer_id = {`LAYER_ID_W{1'b0}};
        prefix_is_last = 1'b0;

        frontier_valid = 1'b1;
        frontier_req_id = 4'h5;
        frontier_level_id = {`TREE_LEVEL_ID_W{1'b0}};
        frontier_slot_valid = {`TREE_FRONTIER_SLOTS{1'b0}};
        frontier_slot_valid[0] = 1'b1;
        frontier_node_id = {(`TREE_FRONTIER_SLOTS*`NODE_ID_W){1'b0}};
        frontier_parent_node_id = {(`TREE_FRONTIER_SLOTS*`NODE_ID_W){1'b0}};
        frontier_token_id = {(`TREE_FRONTIER_SLOTS*`TOKEN_ID_W){1'b0}};
        frontier_position_id = {(`TREE_FRONTIER_SLOTS*`POSITION_ID_W){1'b0}};
        frontier_node_id[`NODE_ID_W-1:0] = 4'd3;
        frontier_parent_node_id[`NODE_ID_W-1:0] = 4'd1;
        frontier_token_id[`TOKEN_ID_W-1:0] = 16'h0033;
        frontier_position_id[`POSITION_ID_W-1:0] = 16'h0044;
    end
endtask

task expect_accept_open;
    input [127:0] scenario_name;
    begin
        #1;
        if (flush_freeze !== flush_valid) begin
            $fatal(1, "%0s: comparator flush_valid is not the AGU freeze source", scenario_name);
        end
        if (flush_valid ||
            !tree_in_ready ||
            !prefix_ready ||
            !frontier_ready ||
            !prefetch_enq_valid) begin
            $fatal(1, "%0s: AGU should accept work when comparator is not flushing", scenario_name);
        end
    end
endtask

task expect_accept_frozen;
    begin
        #1;
        if (!flush_valid ||
            flush_freeze !== 1'b1 ||
            commit_valid ||
            tree_in_ready ||
            prefix_ready ||
            frontier_ready ||
            prefetch_enq_valid) begin
            $fatal(1, "mismatch compare should freeze AGU front-end acceptance");
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

    // Keep the DUT idle through reset release so the baseline acceptance
    // checks are not polluted by same-edge post-reset consumption.
    #1;
    drive_frontend_accept_inputs();

    expect_accept_open("cmp_valid_0");

    cmp_req_id = 4'h1;
    cmp_slot_valid[0] = 1'b1;
    cmp_slot_real_token_id[`TOKEN_ID_W-1:0] = 16'h00aa;
    cmp_slot_candidate_token_id[`TOKEN_ID_W-1:0] = 16'h00aa;
    cmp_slot_node_id[`NODE_ID_W-1:0] = 4'd2;
    cmp_slot_parent_node_id[`NODE_ID_W-1:0] = 4'd1;
    cmp_slot_branch_id[`BRANCH_ID_W-1:0] = 2'd1;
    expect_accept_open("token_match");
    if (!commit_valid || flush_valid) begin
        $fatal(1, "matching tokens should keep commit-only comparator behavior");
    end

    cmp_req_id = 4'h2;
    cmp_slot_valid[0] = 1'b1;
    cmp_slot_real_token_id[`TOKEN_ID_W-1:0] = 16'h0101;
    cmp_slot_candidate_token_id[`TOKEN_ID_W-1:0] = 16'h0202;
    cmp_slot_node_id[`NODE_ID_W-1:0] = 4'd2;
    cmp_slot_parent_node_id[`NODE_ID_W-1:0] = 4'd1;
    cmp_slot_branch_id[`BRANCH_ID_W-1:0] = 2'd1;
    expect_accept_frozen();

    clear_comparator_inputs();
    expect_accept_open("flush_removed");

    $display("tb_comparator_agu_freeze PASS");
    $finish;
end

endmodule
