`timescale 1ns/1ps

`include "config/prediction_params.vh"
`include "config/interface_params.vh"
`include "config/memory_params.vh"

module tb_alloc_metadata_flow;

reg clk;
reg rst_n;

reg cand_req_valid;
wire cand_req_ready;
reg [`REQ_ID_W-1:0] cand_req_req_id;
reg [`BRANCH_ID_W-1:0] cand_req_branch_id;
reg [`NODE_ID_W-1:0] cand_node_id;
reg [`KV_GROUP_LEN_W-1:0] cand_req_size_subbank;
reg cand_req_shared;

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
wire bst_cand_ready;
wire alloc_resp_valid;
wire alloc_resp_grant;
wire [`REQ_ID_W-1:0] alloc_resp_req_id;
wire [`SRAM_ID_W-1:0] alloc_resp_sram_id;
wire [`BANK_ID_W-1:0] alloc_resp_bank_id;
wire [`SUBBANK_ID_W-1:0] alloc_resp_subbank_start;
wire [`KV_GROUP_LEN_W-1:0] alloc_resp_group_len;
wire [`BANK_OCC_BITMAP_W-1:0] alloc_resp_occ_bitmap;

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

free_list u_free_list (
    .clk(clk),
    .rst_n(rst_n),
    .cand_req_valid(cand_req_valid),
    .cand_req_ready(cand_req_ready),
    .cand_req_req_id(cand_req_req_id),
    .cand_req_branch_id(cand_req_branch_id),
    .cand_req_node_id(cand_node_id),
    .cand_req_size_subbank(cand_req_size_subbank),
    .cand_req_shared(cand_req_shared),
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
    .cand_ready(bst_cand_ready),
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
    .lookup_resp_branch_mask(),
    .lookup_resp_is_shared(),
        .lookup_resp_entry_type(),
.lookup_resp_state(),
    .commit_valid(1'b0),
    .commit_index({`TOKEN_REG_INDEX_W{1'b0}}),
    .commit_req_id({`REQ_ID_W{1'b0}}),
    .commit_branch_mask({`BRANCH_MASK_W{1'b0}}),
    .commit_node_mask({`NODE_MASK_W{1'b0}}),
    .flush_valid(1'b0),
    .flush_req_id({`REQ_ID_W{1'b0}}),
    .flush_branch_mask({`BRANCH_MASK_W{1'b0}}),
    .flush_node_mask({`NODE_MASK_W{1'b0}}),
    .entry_count(),
    .error_flag()
);

always #5 clk = ~clk;

initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    cand_req_valid = 1'b0;
    cand_req_req_id = {`REQ_ID_W{1'b0}};
    cand_req_branch_id = {`BRANCH_ID_W{1'b0}};
    cand_node_id = {`NODE_ID_W{1'b0}};
    cand_req_size_subbank = {`KV_GROUP_LEN_W{1'b0}};
    cand_req_shared = 1'b0;
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

    @(posedge clk);
    cand_req_valid <= 1'b1;
    cand_req_req_id <= 4'h1;
    cand_req_branch_id <= 2'd1;
    cand_node_id <= 4'h1;
    cand_req_size_subbank <= 4'd2;
    cand_req_shared <= 1'b0;

    @(posedge clk);
    cand_req_valid <= 1'b0;

    @(posedge clk);
    if (!cand_resp_valid || !cand_resp_grant) begin
        $fatal(1, "free_list did not return a granted candidate");
    end
    if (!alloc_cand_valid ||
        alloc_cand_req_id != cand_resp_req_id ||
        alloc_cand_branch_id != cand_req_branch_id ||
        alloc_cand_node_id != cand_node_id ||
        alloc_cand_size_subbank != cand_req_size_subbank ||
        alloc_cand_shared != cand_req_shared ||
        alloc_cand_sram_id != cand_resp_sram_id ||
        alloc_cand_bank_id != cand_resp_bank_id ||
        alloc_cand_subbank_start != cand_resp_subbank_start ||
        alloc_cand_group_len != cand_resp_group_len) begin
        $fatal(1, "free_list did not present the bank_state_table candidate handoff");
    end

    @(posedge clk);
    if (!alloc_resp_valid || !alloc_resp_grant) begin
        $fatal(1, "bank_state_table did not validate the candidate");
    end

    wr_valid <= 1'b1;
    wr_index <= {`TOKEN_REG_INDEX_W{1'b0}};
    wr_req_id <= alloc_resp_req_id;
    wr_token_id <= 16'h0010;
    wr_position_id <= 12'h001;
    wr_node_id <= 4'h1;
    wr_branch_id <= 2'd1;
    wr_sram_id <= alloc_resp_sram_id;
    wr_bank_id <= alloc_resp_bank_id;
    wr_subbank_start <= alloc_resp_subbank_start;
    wr_group_len <= alloc_resp_group_len;
    wr_branch_mask <= 4'b0010;
    wr_is_shared <= 1'b0;

    @(posedge clk);
    wr_valid <= 1'b0;

    lookup_valid <= 1'b1;
    lookup_req_id <= 4'h1;
    lookup_token_id <= 16'h0010;
    lookup_position_id <= 12'h001;

    @(posedge clk);
    lookup_valid <= 1'b0;

    @(posedge clk);
    if (!lookup_resp_valid || !lookup_resp_hit) begin
        $fatal(1, "token_register lookup did not hit");
    end

    if (lookup_resp_sram_id != alloc_resp_sram_id ||
        lookup_resp_bank_id != alloc_resp_bank_id ||
        lookup_resp_subbank_start != alloc_resp_subbank_start ||
        lookup_resp_group_len != alloc_resp_group_len) begin
        $fatal(1, "token_register lookup mapping mismatch");
    end

    $display("tb_alloc_metadata_flow PASS");
    $finish;
end

endmodule
