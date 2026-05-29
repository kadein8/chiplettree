`timescale 1ns/1ps

`include "config/prediction_params.vh"
`include "config/interface_params.vh"
`include "config/memory_params.vh"

module tb_token_register_tree_stream_entry;

localparam [`REQ_ID_W-1:0] TEST_REQ_ID = 4'h7;
localparam [`TOKEN_REG_INDEX_W-1:0] TREE_INDEX =
    {`TOKEN_REG_INDEX_W{1'b0}};
localparam [`TOKEN_REG_INDEX_W-1:0] VICTIM_INDEX =
    {{(`TOKEN_REG_INDEX_W-1){1'b0}}, 1'b1};
localparam [`BRANCH_MASK_W-1:0] BRANCH0_MASK =
    {{(`BRANCH_MASK_W-1){1'b0}}, 1'b1};
localparam [`NODE_MASK_W-1:0] NODE0_MASK =
    ({{(`NODE_MASK_W-1){1'b0}}, 1'b1} <<
     ((0 * `MAX_VERIFY_NODES_PER_BRANCH) + 0));
localparam [`NODE_MASK_W-1:0] NODE1_MASK =
    ({{(`NODE_MASK_W-1){1'b0}}, 1'b1} <<
     ((0 * `MAX_VERIFY_NODES_PER_BRANCH) + 1));

reg clk;
reg rst_n;

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
wire [`BRANCH_MASK_W-1:0] lookup_resp_branch_mask;
wire lookup_resp_is_shared;
wire [`TOKEN_STATE_W-1:0] lookup_resp_state;
wire [`TOKEN_ENTRY_TYPE_W-1:0] lookup_resp_entry_type;

reg commit_valid;
reg [`TOKEN_REG_INDEX_W-1:0] commit_index;
reg [`REQ_ID_W-1:0] commit_req_id;
reg [`BRANCH_MASK_W-1:0] commit_branch_mask;
reg [`NODE_MASK_W-1:0] commit_node_mask;

reg flush_valid;
reg [`REQ_ID_W-1:0] flush_req_id;
reg [`BRANCH_MASK_W-1:0] flush_branch_mask;
reg [`NODE_MASK_W-1:0] flush_node_mask;

wire [`TOKEN_REG_INDEX_W:0] entry_count;
wire error_flag;

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
    .lookup_resp_state(lookup_resp_state),
    .lookup_resp_entry_type(lookup_resp_entry_type),
    .commit_valid(commit_valid),
    .commit_index(commit_index),
    .commit_req_id(commit_req_id),
    .commit_branch_mask(commit_branch_mask),
    .commit_node_mask(commit_node_mask),
    .flush_valid(flush_valid),
    .flush_req_id(flush_req_id),
    .flush_branch_mask(flush_branch_mask),
    .flush_node_mask(flush_node_mask),
    .entry_count(entry_count),
    .error_flag(error_flag)
);

always #5 clk = ~clk;

task clear_controls;
    begin
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
        commit_valid = 1'b0;
        commit_index = {`TOKEN_REG_INDEX_W{1'b0}};
        commit_req_id = {`REQ_ID_W{1'b0}};
        commit_branch_mask = {`BRANCH_MASK_W{1'b0}};
        commit_node_mask = {`NODE_MASK_W{1'b0}};
        flush_valid = 1'b0;
        flush_req_id = {`REQ_ID_W{1'b0}};
        flush_branch_mask = {`BRANCH_MASK_W{1'b0}};
        flush_node_mask = {`NODE_MASK_W{1'b0}};
    end
endtask

task write_entry;
    input [`TOKEN_REG_INDEX_W-1:0] index_i;
    input [`TOKEN_ID_W-1:0] token_i;
    input [`POSITION_ID_W-1:0] pos_i;
    input [`NODE_ID_W-1:0] node_i;
    begin
        @(posedge clk);
        wr_valid <= 1'b1;
        wr_index <= index_i;
        wr_req_id <= TEST_REQ_ID;
        wr_token_id <= token_i;
        wr_position_id <= pos_i;
        wr_node_id <= node_i;
        wr_branch_id <= {`BRANCH_ID_W{1'b0}};
        wr_sram_id <= {`SRAM_ID_W{1'b0}};
        wr_bank_id <= {`BANK_ID_W{1'b0}};
        wr_subbank_start <= {`SUBBANK_ID_W{1'b0}};
        wr_group_len <= {{(`KV_GROUP_LEN_W-1){1'b0}}, 1'b1};
        wr_branch_mask <= BRANCH0_MASK;
        wr_is_shared <= 1'b0;
        @(posedge clk);
        wr_valid <= 1'b0;
    end
endtask

task lookup_and_expect;
    input [`TOKEN_ID_W-1:0] token_i;
    input [`POSITION_ID_W-1:0] pos_i;
    input expect_hit_i;
    input [`TOKEN_STATE_W-1:0] expect_state_i;
    input [`TOKEN_ENTRY_TYPE_W-1:0] expect_type_i;
    begin
        @(posedge clk);
        lookup_valid <= 1'b1;
        lookup_req_id <= TEST_REQ_ID;
        lookup_token_id <= token_i;
        lookup_position_id <= pos_i;
        @(posedge clk);
        lookup_valid <= 1'b0;
        @(posedge clk);
        if (!lookup_resp_valid) begin
            $fatal(1, "lookup response missing");
        end
        if (lookup_resp_hit !== expect_hit_i) begin
            $fatal(1, "lookup hit mismatch");
        end
        if (expect_hit_i) begin
            if (lookup_resp_state !== expect_state_i) begin
                $fatal(1, "lookup state mismatch");
            end
            if (lookup_resp_entry_type !== expect_type_i) begin
                $fatal(1, "lookup entry_type mismatch");
            end
        end
    end
endtask

initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    clear_controls();

    repeat (3) @(posedge clk);
    rst_n = 1'b1;

    write_entry(TREE_INDEX, 16'h0011, 12'h011, 4'd0);
    write_entry(VICTIM_INDEX, 16'h0012, 12'h012, 4'd1);

    lookup_and_expect(16'h0011, 12'h011,
                      1'b1,
                      {{(`TOKEN_STATE_W-1){1'b0}}, 1'b1},
                      `TOKEN_ENTRY_TREE);

    @(posedge clk);
    commit_valid <= 1'b1;
    commit_index <= TREE_INDEX;
    commit_req_id <= TEST_REQ_ID;
    commit_branch_mask <= BRANCH0_MASK;
    commit_node_mask <= NODE0_MASK;
    @(posedge clk);
    commit_valid <= 1'b0;

    lookup_and_expect(16'h0011, 12'h011,
                      1'b1,
                      {{(`TOKEN_STATE_W-2){1'b0}}, 2'b10},
                      `TOKEN_ENTRY_STREAM);

    @(posedge clk);
    flush_valid <= 1'b1;
    flush_req_id <= TEST_REQ_ID;
    flush_branch_mask <= BRANCH0_MASK;
    flush_node_mask <= (NODE0_MASK | NODE1_MASK);
    @(posedge clk);
    flush_valid <= 1'b0;

    lookup_and_expect(16'h0011, 12'h011,
                      1'b1,
                      {{(`TOKEN_STATE_W-2){1'b0}}, 2'b10},
                      `TOKEN_ENTRY_STREAM);
    lookup_and_expect(16'h0012, 12'h012,
                      1'b0,
                      {`TOKEN_STATE_W{1'b0}},
                      `TOKEN_ENTRY_TREE);

    if (entry_count !== {{`TOKEN_REG_INDEX_W{1'b0}}, 1'b1}) begin
        $fatal(1, "entry_count mismatch after stream-preserving flush");
    end
    if (error_flag) begin
        $fatal(1, "token_register error_flag should remain low");
    end

    $display("tb_token_register_tree_stream_entry PASS");
    $finish;
end

endmodule
