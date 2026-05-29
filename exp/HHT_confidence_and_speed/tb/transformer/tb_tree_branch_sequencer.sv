`include "config/interface_params.vh"
`include "config/prediction_params.vh"
`timescale 1ns/1ps

module tb_tree_branch_sequencer;

localparam integer BRANCH_NUM = `BRANCH_NUM;
localparam integer TOKEN_ID_W = `TOKEN_ID_W;
localparam integer BRANCH_ID_W = `BRANCH_ID_W;

logic clk;
logic rst_n;
logic cfg_valid;
logic cfg_ready;
logic [BRANCH_NUM-1:0] cfg_branch_valid;
logic cfg_tree_mask_en;
logic [15:0] cfg_prefix_len;
logic [BRANCH_NUM*TOKEN_ID_W-1:0] cfg_token_ids;
logic [BRANCH_NUM*BRANCH_ID_W-1:0] cfg_branch_ids;
logic issue_valid;
logic issue_ready;
logic [TOKEN_ID_W-1:0] issue_token_id;
logic [BRANCH_ID_W-1:0] issue_branch_id;
logic issue_tree_mask_en;
logic [15:0] issue_prefix_len;
logic issue_prefix_kv_cached;
logic result_valid;
logic result_ready;
logic all_branches_done;
logic [BRANCH_NUM-1:0] completed_branches;

integer seen_issue_count_i;

always #5 clk = ~clk;

tree_branch_sequencer u_dut (
    .clk(clk),
    .rst_n(rst_n),
    .cfg_valid(cfg_valid),
    .cfg_ready(cfg_ready),
    .cfg_branch_valid(cfg_branch_valid),
    .cfg_tree_mask_en(cfg_tree_mask_en),
    .cfg_prefix_len(cfg_prefix_len),
    .cfg_token_ids(cfg_token_ids),
    .cfg_branch_ids(cfg_branch_ids),
    .issue_valid(issue_valid),
    .issue_ready(issue_ready),
    .issue_token_id(issue_token_id),
    .issue_branch_id(issue_branch_id),
    .issue_tree_mask_en(issue_tree_mask_en),
    .issue_prefix_len(issue_prefix_len),
    .issue_prefix_kv_cached(issue_prefix_kv_cached),
    .result_valid(result_valid),
    .result_ready(result_ready),
    .all_branches_done(all_branches_done),
    .completed_branches(completed_branches)
);

task automatic drive_cfg_once;
    begin
        wait (cfg_ready);
        @(negedge clk);
        cfg_valid = 1'b1;
        cfg_branch_valid = 4'b1011;
        cfg_tree_mask_en = 1'b0;
        cfg_prefix_len = 16'd2;
        cfg_token_ids[(0*TOKEN_ID_W) +: TOKEN_ID_W] = 16'h1001;
        cfg_token_ids[(1*TOKEN_ID_W) +: TOKEN_ID_W] = 16'h1002;
        cfg_token_ids[(2*TOKEN_ID_W) +: TOKEN_ID_W] = 16'h1003;
        cfg_token_ids[(3*TOKEN_ID_W) +: TOKEN_ID_W] = 16'h1004;
        cfg_branch_ids[(0*BRANCH_ID_W) +: BRANCH_ID_W] = 2'd0;
        cfg_branch_ids[(1*BRANCH_ID_W) +: BRANCH_ID_W] = 2'd1;
        cfg_branch_ids[(2*BRANCH_ID_W) +: BRANCH_ID_W] = 2'd2;
        cfg_branch_ids[(3*BRANCH_ID_W) +: BRANCH_ID_W] = 2'd3;
        @(negedge clk);
        cfg_valid = 1'b0;
    end
endtask

task automatic complete_one_branch;
    begin
        wait (issue_valid);
        @(posedge clk);
        #1;
        if (issue_tree_mask_en !== cfg_tree_mask_en)
            $fatal(1, "issue_tree_mask_en should follow cfg_tree_mask_en");
        if (issue_prefix_len !== 16'd2)
            $fatal(1, "issue_prefix_len mismatch");
        if ((seen_issue_count_i == 0) && (issue_prefix_kv_cached !== 1'b0))
            $fatal(1, "first branch should not see cached prefix");
        if ((seen_issue_count_i > 0) && (issue_prefix_kv_cached !== 1'b1))
            $fatal(1, "later branches should see cached prefix");

        seen_issue_count_i = seen_issue_count_i + 1;
        result_valid = 1'b1;
        @(posedge clk);
        #1;
        result_valid = 1'b0;
    end
endtask

initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    cfg_valid = 1'b0;
    cfg_branch_valid = '0;
    cfg_tree_mask_en = 1'b0;
    cfg_prefix_len = 16'd0;
    cfg_token_ids = '0;
    cfg_branch_ids = '0;
    issue_ready = 1'b1;
    result_valid = 1'b0;
    seen_issue_count_i = 0;

    repeat (3) @(posedge clk);
    rst_n = 1'b1;

    drive_cfg_once();
    complete_one_branch();
    complete_one_branch();
    complete_one_branch();

    wait (cfg_ready);
    @(negedge clk);
    cfg_valid = 1'b1;
    cfg_branch_valid = 4'b0001;
    cfg_tree_mask_en = 1'b1;
    cfg_prefix_len = 16'd0;
    cfg_token_ids = '0;
    cfg_branch_ids = '0;
    cfg_token_ids[(0*TOKEN_ID_W) +: TOKEN_ID_W] = 16'h2001;
    cfg_branch_ids[(0*BRANCH_ID_W) +: BRANCH_ID_W] = '0;
    @(negedge clk);
    cfg_valid = 1'b0;

    wait (issue_valid);
    @(posedge clk);
    #1;
    if (issue_tree_mask_en !== 1'b1)
        $fatal(1, "issue_tree_mask_en should stay high when cfg enables it");
    if (issue_prefix_len !== 16'd0)
        $fatal(1, "issue_prefix_len should allow zero-length prefixes");
    result_valid = 1'b1;
    @(posedge clk);
    #1;
    result_valid = 1'b0;

    repeat (3) @(posedge clk);

    if (seen_issue_count_i !== 3)
        $fatal(1, "expected 3 issued branches from first config, got %0d", seen_issue_count_i);
    if (completed_branches !== 4'b0001)
        $fatal(1, "completed_branches mismatch after second config actual=%b", completed_branches);
    if (all_branches_done !== 1'b1)
        $fatal(1, "all_branches_done should assert");

    $display("tb_tree_branch_sequencer PASS");
    $finish;
end

endmodule
