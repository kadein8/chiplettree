`timescale 1ns/1ps

`include "config/prediction_params.vh"
`include "config/interface_params.vh"

module tb_comparator_multi_branch_basic;

localparam [`BRANCH_MASK_W-1:0] BRANCH0_MASK =
    ({{(`BRANCH_MASK_W-1){1'b0}}, 1'b1} << 0);
localparam [`BRANCH_MASK_W-1:0] BRANCH2_MASK =
    ({{(`BRANCH_MASK_W-1){1'b0}}, 1'b1} << 2);
localparam [`BRANCH_MASK_W-1:0] EXPECT_FLUSH_BRANCH_MASK =
    BRANCH0_MASK | BRANCH2_MASK;

localparam [`NODE_MASK_W-1:0] BRANCH0_NODE1_MASK =
    ({{(`NODE_MASK_W-1){1'b0}}, 1'b1} <<
     ((0 * `MAX_VERIFY_NODES_PER_BRANCH) + 1));
localparam [`NODE_MASK_W-1:0] BRANCH2_NODE3_MASK =
    ({{(`NODE_MASK_W-1){1'b0}}, 1'b1} <<
     ((2 * `MAX_VERIFY_NODES_PER_BRANCH) + 3));
localparam [`NODE_MASK_W-1:0] EXPECT_FLUSH_NODE_MASK =
    BRANCH0_NODE1_MASK | BRANCH2_NODE3_MASK;

reg clk;
reg rst_n;
reg [`REQ_ID_W-1:0] cmp_req_id;
reg [`BRANCH_NUM-1:0] cmp_slot_valid;
reg [`BRANCH_NUM*`TOKEN_ID_W-1:0] cmp_slot_real_token_id;
reg [`BRANCH_NUM*`TOKEN_ID_W-1:0] cmp_slot_candidate_token_id;
reg [`BRANCH_NUM*`NODE_ID_W-1:0] cmp_slot_node_id;
reg [`BRANCH_NUM*`NODE_ID_W-1:0] cmp_slot_parent_node_id;
reg [`BRANCH_NUM*`BRANCH_ID_W-1:0] cmp_slot_branch_id;

wire commit_valid;
wire [`BRANCH_MASK_W-1:0] commit_branch_mask;
wire [`NODE_MASK_W-1:0] commit_node_mask;
wire flush_valid;
wire [`BRANCH_MASK_W-1:0] flush_branch_mask;
wire [`NODE_MASK_W-1:0] flush_node_mask;

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

always #5 clk = ~clk;

task clear_inputs;
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

task expect_multi_branch_flush_only;
    begin
        #1;
        if (commit_valid ||
            (commit_branch_mask != {`BRANCH_MASK_W{1'b0}}) ||
            (commit_node_mask != {`NODE_MASK_W{1'b0}}) ||
            !flush_valid ||
            (flush_branch_mask != EXPECT_FLUSH_BRANCH_MASK) ||
            (flush_node_mask != EXPECT_FLUSH_NODE_MASK)) begin
            $fatal(1, "comparator multi-branch flush aggregation mismatch");
        end
    end
endtask

initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    clear_inputs();

    repeat (3) @(posedge clk);
    rst_n = 1'b1;

    cmp_req_id = 4'h7;
    cmp_slot_valid[0] = 1'b1;
    cmp_slot_real_token_id[(`TOKEN_ID_W*0) +: `TOKEN_ID_W] = 16'h1001;
    cmp_slot_candidate_token_id[(`TOKEN_ID_W*0) +: `TOKEN_ID_W] = 16'h2002;
    cmp_slot_node_id[(`NODE_ID_W*0) +: `NODE_ID_W] = 4'd1;
    cmp_slot_parent_node_id[(`NODE_ID_W*0) +: `NODE_ID_W] = 4'd0;
    cmp_slot_branch_id[(`BRANCH_ID_W*0) +: `BRANCH_ID_W] = 2'd0;

    cmp_slot_valid[2] = 1'b1;
    cmp_slot_real_token_id[(`TOKEN_ID_W*2) +: `TOKEN_ID_W] = 16'h3003;
    cmp_slot_candidate_token_id[(`TOKEN_ID_W*2) +: `TOKEN_ID_W] = 16'h4004;
    cmp_slot_node_id[(`NODE_ID_W*2) +: `NODE_ID_W] = 4'd3;
    cmp_slot_parent_node_id[(`NODE_ID_W*2) +: `NODE_ID_W] = 4'd2;
    cmp_slot_branch_id[(`BRANCH_ID_W*2) +: `BRANCH_ID_W] = 2'd2;

    expect_multi_branch_flush_only();

    $display("tb_comparator_multi_branch_basic PASS");
    $finish;
end

endmodule
