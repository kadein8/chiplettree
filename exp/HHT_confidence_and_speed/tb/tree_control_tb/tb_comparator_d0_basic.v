`timescale 1ns/1ps

`include "config/prediction_params.vh"
`include "config/interface_params.vh"

module tb_comparator_d0_basic;

localparam [`BRANCH_MASK_W-1:0] BRANCH0_MASK =
    ({{(`BRANCH_MASK_W-1){1'b0}}, 1'b1} << 0);
localparam [`BRANCH_MASK_W-1:0] BRANCH3_MASK =
    ({{(`BRANCH_MASK_W-1){1'b0}}, 1'b1} << (`BRANCH_NUM - 1));
localparam [`NODE_MASK_W-1:0] BRANCH0_NODE0_MASK =
    ({{(`NODE_MASK_W-1){1'b0}}, 1'b1} << 0);
localparam [`NODE_MASK_W-1:0] BRANCH3_NODE3_MASK =
    ({{(`NODE_MASK_W-1){1'b0}}, 1'b1} <<
     (((`BRANCH_NUM - 1) * `MAX_VERIFY_NODES_PER_BRANCH) +
      (`MAX_VERIFY_NODES_PER_BRANCH - 1)));

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

task expect_all_zero;
    begin
        #1;
        if (commit_valid ||
            (commit_branch_mask != {`BRANCH_MASK_W{1'b0}}) ||
            (commit_node_mask != {`NODE_MASK_W{1'b0}}) ||
            flush_valid ||
            (flush_branch_mask != {`BRANCH_MASK_W{1'b0}}) ||
            (flush_node_mask != {`NODE_MASK_W{1'b0}})) begin
            $fatal(1, "comparator should drive all-zero outputs in the no-op case");
        end
    end
endtask

task expect_commit_only;
    input [`BRANCH_MASK_W-1:0] expect_branch_mask;
    input [`NODE_MASK_W-1:0] expect_node_mask;
    begin
        #1;
        if (!commit_valid ||
            (commit_branch_mask != expect_branch_mask) ||
            (commit_node_mask != expect_node_mask) ||
            flush_valid ||
            (flush_branch_mask != {`BRANCH_MASK_W{1'b0}}) ||
            (flush_node_mask != {`NODE_MASK_W{1'b0}})) begin
            $fatal(1, "comparator commit-only decision mismatch");
        end
    end
endtask

task expect_flush_only;
    input [`BRANCH_MASK_W-1:0] expect_branch_mask;
    input [`NODE_MASK_W-1:0] expect_node_mask;
    begin
        #1;
        if (commit_valid ||
            (commit_branch_mask != {`BRANCH_MASK_W{1'b0}}) ||
            (commit_node_mask != {`NODE_MASK_W{1'b0}}) ||
            !flush_valid ||
            (flush_branch_mask != expect_branch_mask) ||
            (flush_node_mask != expect_node_mask)) begin
            $fatal(1, "comparator flush-only decision mismatch");
        end
    end
endtask

initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    clear_inputs();

    repeat (3) @(posedge clk);
    rst_n = 1'b1;

    clear_inputs();
    expect_all_zero();

    cmp_req_id = 4'h1;
    cmp_slot_valid[0] = 1'b1;
    cmp_slot_real_token_id[`TOKEN_ID_W-1:0] = 16'h00aa;
    cmp_slot_candidate_token_id[`TOKEN_ID_W-1:0] = 16'h00aa;
    cmp_slot_node_id[`NODE_ID_W-1:0] = 4'd0;
    cmp_slot_parent_node_id[`NODE_ID_W-1:0] = 4'hf;
    cmp_slot_branch_id[`BRANCH_ID_W-1:0] = 2'd0;
    expect_commit_only(BRANCH0_MASK, BRANCH0_NODE0_MASK);

    clear_inputs();
    cmp_req_id = 4'h2;
    cmp_slot_valid[0] = 1'b1;
    cmp_slot_real_token_id[`TOKEN_ID_W-1:0] = 16'h0101;
    cmp_slot_candidate_token_id[`TOKEN_ID_W-1:0] = 16'h0202;
    cmp_slot_node_id[`NODE_ID_W-1:0] = `MAX_VERIFY_NODES_PER_BRANCH - 1;
    cmp_slot_parent_node_id[`NODE_ID_W-1:0] = 4'd2;
    cmp_slot_branch_id[`BRANCH_ID_W-1:0] = `BRANCH_NUM - 1;
    expect_flush_only(BRANCH3_MASK, BRANCH3_NODE3_MASK);

    clear_inputs();
    expect_all_zero();

    $display("tb_comparator_d0_basic PASS");
    $finish;
end

endmodule
