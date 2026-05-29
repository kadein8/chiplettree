`timescale 1ns/1ps

`include "config/prediction_params.vh"
`include "config/interface_params.vh"
`include "config/memory_params.vh"

module tb_commit_flush_lifecycle;

localparam [`BRANCH_MASK_W-1:0] BRANCH1_MASK =
    ({{(`BRANCH_MASK_W-1){1'b0}}, 1'b1} << 1);
localparam [`NODE_MASK_W-1:0] BR1_NODE1_MASK =
    ({{(`NODE_MASK_W-1){1'b0}}, 1'b1} <<
     ((1 * `MAX_VERIFY_NODES_PER_BRANCH) + 1));
localparam [`NODE_MASK_W-1:0] BR1_NODE2_MASK =
    ({{(`NODE_MASK_W-1){1'b0}}, 1'b1} <<
     ((1 * `MAX_VERIFY_NODES_PER_BRANCH) + 2));

reg clk;
reg rst_n;

reg bst_cand_valid;
wire bst_cand_ready;
reg [`REQ_ID_W-1:0] bst_cand_req_id;
reg [`BRANCH_ID_W-1:0] bst_cand_branch_id;
reg [`NODE_ID_W-1:0] bst_cand_node_id;
reg [`KV_GROUP_LEN_W-1:0] bst_cand_size_subbank;
reg bst_cand_shared;
reg [`SRAM_ID_W-1:0] bst_cand_sram_id;
reg [`BANK_ID_W-1:0] bst_cand_bank_id;
reg [`SUBBANK_ID_W-1:0] bst_cand_subbank_start;
reg [`KV_GROUP_LEN_W-1:0] bst_cand_group_len;
wire alloc_resp_valid;
wire alloc_resp_grant;
wire [`REQ_ID_W-1:0] alloc_resp_req_id;
wire [`SRAM_ID_W-1:0] alloc_resp_sram_id;
wire [`BANK_ID_W-1:0] alloc_resp_bank_id;
wire [`SUBBANK_ID_W-1:0] alloc_resp_subbank_start;
wire [`KV_GROUP_LEN_W-1:0] alloc_resp_group_len;
wire [`BANK_OCC_BITMAP_W-1:0] alloc_resp_occ_bitmap;

reg commit_valid;
reg [`REQ_ID_W-1:0] commit_req_id;
reg [`SRAM_ID_W-1:0] commit_sram_id;
reg [`BANK_ID_W-1:0] commit_bank_id;
reg [`SUBBANK_ID_W-1:0] commit_subbank_start;
reg [`KV_GROUP_LEN_W-1:0] commit_group_len;
reg [`BRANCH_MASK_W-1:0] commit_branch_mask;
reg [`NODE_MASK_W-1:0] commit_node_mask;

reg flush_valid;
reg [`REQ_ID_W-1:0] flush_req_id;
reg [`BRANCH_MASK_W-1:0] flush_branch_mask;
reg [`NODE_MASK_W-1:0] flush_node_mask;

reg query_valid;
reg [`SRAM_ID_W-1:0] query_sram_id;
reg [`BANK_ID_W-1:0] query_bank_id;
wire query_resp_valid;
wire [`BANK_OCC_BITMAP_W-1:0] query_resp_occ_bitmap;
wire [`BANK_STATE_W-1:0] query_resp_state;
wire [`BRANCH_MASK_W-1:0] query_resp_branch_mask;
wire [`REFCNT_W-1:0] query_resp_refcnt;

reg wr_valid;
wire wr_ready;
reg [`TOKEN_REG_INDEX_W-1:0] wr_index;
reg [`REQ_ID_W-1:0] wr_req_id;
reg [`TOKEN_ID_W-1:0] wr_token_id;
reg [`POSITION_ID_W-1:0] wr_position_id;
reg [`NODE_ID_W-1:0] wr_node_id;
reg [`BRANCH_ID_W-1:0] wr_branch_id;
reg [`SRAM_ID_W-1:0] wr_sram_id;
reg [`BANK_ID_W-1:0] wr_bank_id;
reg [`SUBBANK_ID_W-1:0] wr_subbank_start;
reg [`KV_GROUP_LEN_W-1:0] wr_group_len;
reg [`BRANCH_MASK_W-1:0] wr_branch_mask;
reg wr_is_shared;
reg [`TOKEN_REG_INDEX_W-1:0] commit_index;

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

bank_state_table u_bank_state_table (
    .clk(clk),
    .rst_n(rst_n),
    .cand_valid(bst_cand_valid),
    .cand_ready(bst_cand_ready),
    .cand_req_id(bst_cand_req_id),
    .cand_branch_id(bst_cand_branch_id),
    .cand_node_id(bst_cand_node_id),
    .cand_size_subbank(bst_cand_size_subbank),
    .cand_shared(bst_cand_shared),
    .cand_sram_id(bst_cand_sram_id),
    .cand_bank_id(bst_cand_bank_id),
    .cand_subbank_start(bst_cand_subbank_start),
    .cand_group_len(bst_cand_group_len),
    .alloc_resp_valid(alloc_resp_valid),
    .alloc_resp_grant(alloc_resp_grant),
    .alloc_resp_req_id(alloc_resp_req_id),
    .alloc_resp_sram_id(alloc_resp_sram_id),
    .alloc_resp_bank_id(alloc_resp_bank_id),
    .alloc_resp_subbank_start(alloc_resp_subbank_start),
    .alloc_resp_group_len(alloc_resp_group_len),
    .alloc_resp_occ_bitmap(alloc_resp_occ_bitmap),
    .commit_valid(commit_valid),
    .commit_req_id(commit_req_id),
    .commit_sram_id(commit_sram_id),
    .commit_bank_id(commit_bank_id),
    .commit_subbank_start(commit_subbank_start),
    .commit_group_len(commit_group_len),
    .commit_branch_mask(commit_branch_mask),
    .commit_node_mask(commit_node_mask),
    .flush_valid(flush_valid),
    .flush_req_id(flush_req_id),
    .flush_branch_mask(flush_branch_mask),
    .flush_node_mask(flush_node_mask),
    .reclaim_valid(1'b0),
    .reclaim_sram_id({`SRAM_ID_W{1'b0}}),
    .reclaim_bank_id({`BANK_ID_W{1'b0}}),
    .reclaim_subbank_start({`SUBBANK_ID_W{1'b0}}),
    .reclaim_group_len({`KV_GROUP_LEN_W{1'b0}}),
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
    .wr_valid(wr_valid),
    .wr_ready(wr_ready),
    .wr_index(wr_index),
    .wr_req_id(wr_req_id),
    .wr_token_id(wr_token_id),
    .wr_position_id(wr_position_id),
    .wr_node_id(wr_node_id),
    .wr_branch_id(wr_branch_id),
    .wr_sram_id(wr_sram_id),
    .wr_bank_id(wr_bank_id),
    .wr_subbank_start(wr_subbank_start),
    .wr_group_len(wr_group_len),
    .wr_branch_mask(wr_branch_mask),
    .wr_is_shared(wr_is_shared),
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
    .commit_valid(commit_valid),
    .commit_index(commit_index),
    .commit_req_id(commit_req_id),
    .commit_branch_mask(commit_branch_mask),
    .commit_node_mask(commit_node_mask),
    .flush_valid(flush_valid),
    .flush_req_id(flush_req_id),
    .flush_branch_mask(flush_branch_mask),
    .flush_node_mask(flush_node_mask),
    .entry_count(),
    .error_flag()
);

always #5 clk = ~clk;

task allocate_and_install;
    input [`NODE_ID_W-1:0] node_id;
    input [`SUBBANK_ID_W-1:0] subbank_start;
    input [`TOKEN_REG_INDEX_W-1:0] index_id;
    input [`TOKEN_ID_W-1:0] token_id;
    input [`POSITION_ID_W-1:0] position_id;
    begin
        bst_cand_valid <= 1'b1;
        bst_cand_req_id <= 4'h1;
        bst_cand_branch_id <= 2'd1;
        bst_cand_node_id <= node_id;
        bst_cand_size_subbank <= 4'd2;
        bst_cand_shared <= 1'b0;
        bst_cand_sram_id <= {`SRAM_ID_W{1'b0}};
        bst_cand_bank_id <= {`BANK_ID_W{1'b0}};
        bst_cand_subbank_start <= subbank_start;
        bst_cand_group_len <= 4'd2;

        @(posedge clk);
        bst_cand_valid <= 1'b0;

        @(posedge clk);
        if (!alloc_resp_valid || !alloc_resp_grant) begin
            $fatal(1, "bank_state_table allocation failed for node %0d", node_id);
        end

        wr_valid <= 1'b1;
        wr_index <= index_id;
        wr_req_id <= alloc_resp_req_id;
        wr_token_id <= token_id;
        wr_position_id <= position_id;
        wr_node_id <= node_id;
        wr_branch_id <= 2'd1;
        wr_sram_id <= alloc_resp_sram_id;
        wr_bank_id <= alloc_resp_bank_id;
        wr_subbank_start <= alloc_resp_subbank_start;
        wr_group_len <= alloc_resp_group_len;
        wr_branch_mask <= BRANCH1_MASK;
        wr_is_shared <= 1'b0;

        @(posedge clk);
        wr_valid <= 1'b0;
    end
endtask

task lookup_expect;
    input [`TOKEN_ID_W-1:0] token_id;
    input [`POSITION_ID_W-1:0] position_id;
    input expect_hit;
    input [`TOKEN_STATE_W-1:0] expect_state;
    begin
        lookup_valid <= 1'b1;
        lookup_req_id <= 4'h1;
        lookup_token_id <= token_id;
        lookup_position_id <= position_id;

        @(posedge clk);
        lookup_valid <= 1'b0;

        @(posedge clk);
        if (!lookup_resp_valid) begin
            $fatal(1, "lookup response missing");
        end
        if (lookup_resp_hit != expect_hit) begin
            $fatal(1, "lookup hit expectation mismatch");
        end
        if (expect_hit && (lookup_resp_state != expect_state)) begin
            $fatal(1, "lookup state expectation mismatch");
        end
    end
endtask

initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    bst_cand_valid = 1'b0;
    bst_cand_req_id = {`REQ_ID_W{1'b0}};
    bst_cand_branch_id = {`BRANCH_ID_W{1'b0}};
    bst_cand_node_id = {`NODE_ID_W{1'b0}};
    bst_cand_size_subbank = {`KV_GROUP_LEN_W{1'b0}};
    bst_cand_shared = 1'b0;
    bst_cand_sram_id = {`SRAM_ID_W{1'b0}};
    bst_cand_bank_id = {`BANK_ID_W{1'b0}};
    bst_cand_subbank_start = {`SUBBANK_ID_W{1'b0}};
    bst_cand_group_len = {`KV_GROUP_LEN_W{1'b0}};
    commit_valid = 1'b0;
    commit_index = {`TOKEN_REG_INDEX_W{1'b0}};
    commit_req_id = {`REQ_ID_W{1'b0}};
    commit_sram_id = {`SRAM_ID_W{1'b0}};
    commit_bank_id = {`BANK_ID_W{1'b0}};
    commit_subbank_start = {`SUBBANK_ID_W{1'b0}};
    commit_group_len = {`KV_GROUP_LEN_W{1'b0}};
    commit_branch_mask = {`BRANCH_MASK_W{1'b0}};
    commit_node_mask = {`NODE_MASK_W{1'b0}};
    flush_valid = 1'b0;
    flush_req_id = {`REQ_ID_W{1'b0}};
    flush_branch_mask = {`BRANCH_MASK_W{1'b0}};
    flush_node_mask = {`NODE_MASK_W{1'b0}};
    query_valid = 1'b0;
    query_sram_id = {`SRAM_ID_W{1'b0}};
    query_bank_id = {`BANK_ID_W{1'b0}};
    wr_valid = 1'b0;
    wr_index = {`TOKEN_REG_INDEX_W{1'b0}};
    wr_req_id = {`REQ_ID_W{1'b0}};
    wr_token_id = {`TOKEN_ID_W{1'b0}};
    wr_position_id = {`POSITION_ID_W{1'b0}};
    wr_node_id = {`NODE_ID_W{1'b0}};
    wr_branch_id = {`BRANCH_ID_W{1'b0}};
    wr_sram_id = {`SRAM_ID_W{1'b0}};
    wr_bank_id = {`BANK_ID_W{1'b0}};
    wr_subbank_start = {`SUBBANK_ID_W{1'b0}};
    wr_group_len = {`KV_GROUP_LEN_W{1'b0}};
    wr_branch_mask = {`BRANCH_MASK_W{1'b0}};
    wr_is_shared = 1'b0;
    lookup_valid = 1'b0;
    lookup_req_id = {`REQ_ID_W{1'b0}};
    lookup_token_id = {`TOKEN_ID_W{1'b0}};
    lookup_position_id = {`POSITION_ID_W{1'b0}};

    repeat (3) @(posedge clk);
    rst_n = 1'b1;

    allocate_and_install(4'd1, 5'd0, {`TOKEN_REG_INDEX_W{1'b0}}, 16'h0011, 12'h011);
    allocate_and_install(4'd2, 5'd2, {{(`TOKEN_REG_INDEX_W-1){1'b0}}, 1'b1}, 16'h0012, 12'h012);

    commit_valid <= 1'b1;
    commit_index <= {`TOKEN_REG_INDEX_W{1'b0}};
    commit_req_id <= 4'h1;
    commit_sram_id <= {`SRAM_ID_W{1'b0}};
    commit_bank_id <= {`BANK_ID_W{1'b0}};
    commit_subbank_start <= 5'd0;
    commit_group_len <= 4'd2;
    commit_branch_mask <= BRANCH1_MASK;
    commit_node_mask <= BR1_NODE1_MASK;

    @(posedge clk);
    commit_valid <= 1'b0;

    lookup_expect(16'h0011, 12'h011, 1'b1, 2'b10);

    flush_valid <= 1'b1;
    flush_req_id <= 4'h1;
    flush_branch_mask <= BRANCH1_MASK;
    flush_node_mask <= BR1_NODE2_MASK;

    @(posedge clk);
    flush_valid <= 1'b0;

    lookup_expect(16'h0011, 12'h011, 1'b1, 2'b10);
    lookup_expect(16'h0012, 12'h012, 1'b0, 2'b00);

    query_valid <= 1'b1;
    query_sram_id <= {`SRAM_ID_W{1'b0}};
    query_bank_id <= {`BANK_ID_W{1'b0}};
    #1;
    if (!query_resp_valid) begin
        $fatal(1, "query response missing");
    end
    if (query_resp_occ_bitmap[1:0] != 2'b11 || query_resp_occ_bitmap[3:2] != 2'b00) begin
        $fatal(1, "bank_state_table occupancy mismatch after commit/flush lifecycle");
    end
    if (query_resp_branch_mask != BRANCH1_MASK) begin
        $fatal(1, "bank_state_table branch ownership mismatch after lifecycle");
    end
    query_valid <= 1'b0;

    $display("tb_commit_flush_lifecycle PASS");
    $finish;
end

endmodule
