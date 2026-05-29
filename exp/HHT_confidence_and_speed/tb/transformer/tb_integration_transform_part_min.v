`timescale 1ns/1ps

`include "config/interface_params.vh"
`include "config/memory_params.vh"

module tb_integration_transform_part_min;

localparam MODEL_ID_W = 8;
localparam OP_CLASS_W = 8;
localparam TOKEN_LEN_W = 16;
localparam RESULT_STATUS_W = 2;

reg clk;
reg rst_n;

reg issue_valid;
wire issue_ready;
reg [`TOKEN_ID_W-1:0] issue_token_id;
reg [`BRANCH_ID_W-1:0] issue_branch_id;
reg [1:0] issue_epoch;
reg [MODEL_ID_W-1:0] issue_model_id;
reg [OP_CLASS_W-1:0] issue_op_class;
reg [`SRAM_ADDR_W-1:0] issue_src_addr;
reg [`SRAM_ADDR_W-1:0] issue_dst_addr;
reg [TOKEN_LEN_W-1:0] issue_token_len;
reg [`REQ_ID_W-1:0] issue_req_id;
reg [1:0] issue_flush_epoch;

wire op_req_valid;
reg op_req_ready;
wire op_req_write;
wire [`SRAM_ADDR_W-1:0] op_req_addr;
wire [`SRAM_WDATA_W-1:0] op_req_wdata;
wire [`REQ_ID_W-1:0] op_req_id;
wire op_req_last;
wire [`TOKEN_ID_W-1:0] op_req_tag;

reg op_resp_valid;
wire op_resp_ready;
reg [`SRAM_RDATA_W-1:0] op_resp_rdata;
reg [`REQ_ID_W-1:0] op_resp_id;
reg op_resp_last;

wire result_valid;
reg result_ready;
wire [`TOKEN_ID_W-1:0] result_token_id;
wire [`SRAM_ADDR_W-1:0] result_addr;
wire [`SRAM_WDATA_W-1:0] result_data;
wire [RESULT_STATUS_W-1:0] result_status;

localparam [`TOKEN_ID_W-1:0] EXP_TOKEN_ID = 16'h1201;
localparam [`SRAM_ADDR_W-1:0] EXP_SRC_ADDR = {`SRAM_ADDR_W{1'b1}} ^ 16'h0034;
localparam [`SRAM_ADDR_W-1:0] EXP_DST_ADDR = {`SRAM_ADDR_W{1'b0}} | 16'h00a8;
localparam [`REQ_ID_W-1:0] EXP_REQ_ID = 4'h5;
localparam [`SRAM_RDATA_W-1:0] EXP_RDATA = 128'h0123_4567_89ab_cdef_fedc_ba98_7654_3210;

IntegrationTransformPart #(
    .MODEL_ID_W(MODEL_ID_W),
    .OP_CLASS_W(OP_CLASS_W),
    .TOKEN_LEN_W(TOKEN_LEN_W),
    .RESULT_STATUS_W(RESULT_STATUS_W)
) u_integration_transform_part (
    .clk(clk),
    .rst_n(rst_n),
    .issue_valid(issue_valid),
    .issue_ready(issue_ready),
    .issue_token_id(issue_token_id),
    .issue_branch_id(issue_branch_id),
    .issue_epoch(issue_epoch),
    .issue_model_id(issue_model_id),
    .issue_op_class(issue_op_class),
    .issue_src_addr(issue_src_addr),
    .issue_dst_addr(issue_dst_addr),
    .issue_token_len(issue_token_len),
    .issue_req_id(issue_req_id),
    .issue_flush_epoch(issue_flush_epoch),
    .op_req_valid(op_req_valid),
    .op_req_ready(op_req_ready),
    .op_req_write(op_req_write),
    .op_req_addr(op_req_addr),
    .op_req_wdata(op_req_wdata),
    .op_req_id(op_req_id),
    .op_req_last(op_req_last),
    .op_req_tag(op_req_tag),
    .op_resp_valid(op_resp_valid),
    .op_resp_ready(op_resp_ready),
    .op_resp_rdata(op_resp_rdata),
    .op_resp_id(op_resp_id),
    .op_resp_last(op_resp_last),
    .result_valid(result_valid),
    .result_ready(result_ready),
    .result_token_id(result_token_id),
    .result_addr(result_addr),
    .result_data(result_data),
    .result_status(result_status)
);

always #5 clk = ~clk;

task clear_inputs;
    begin
        issue_valid = 1'b0;
        issue_token_id = {`TOKEN_ID_W{1'b0}};
        issue_branch_id = {`BRANCH_ID_W{1'b0}};
        issue_epoch = 2'b00;
        issue_model_id = {MODEL_ID_W{1'b0}};
        issue_op_class = {OP_CLASS_W{1'b0}};
        issue_src_addr = {`SRAM_ADDR_W{1'b0}};
        issue_dst_addr = {`SRAM_ADDR_W{1'b0}};
        issue_token_len = {TOKEN_LEN_W{1'b0}};
        issue_req_id = {`REQ_ID_W{1'b0}};
        issue_flush_epoch = 2'b00;

        op_req_ready = 1'b0;
        op_resp_valid = 1'b0;
        op_resp_rdata = {`SRAM_RDATA_W{1'b0}};
        op_resp_id = {`REQ_ID_W{1'b0}};
        op_resp_last = 1'b0;
        result_ready = 1'b0;
    end
endtask

task expect_idle;
    begin
        #1;
        if ((issue_ready !== 1'b1) ||
            (op_req_valid !== 1'b0) ||
            (result_valid !== 1'b0)) begin
            $fatal(1, "integration transform should be idle");
        end
    end
endtask

task expect_mem_req;
    begin
        #1;
        if ((op_req_valid !== 1'b1) ||
            (op_req_write !== 1'b0) ||
            (op_req_addr != EXP_SRC_ADDR) ||
            (op_req_id != EXP_REQ_ID) ||
            (op_req_last !== 1'b1) ||
            (op_req_tag != EXP_TOKEN_ID) ||
            (op_req_wdata != {`SRAM_WDATA_W{1'b0}})) begin
            $fatal(1, "integration transform request mismatch");
        end
    end
endtask

task expect_result;
    begin
        #1;
        if ((result_valid !== 1'b1) ||
            (result_token_id != EXP_TOKEN_ID) ||
            (result_addr != EXP_DST_ADDR) ||
            (result_data != EXP_RDATA) ||
            (result_status != {RESULT_STATUS_W{1'b0}})) begin
            $fatal(1, "integration transform result mismatch");
        end
    end
endtask

task send_issue_once;
    begin
        issue_valid = 1'b1;
        issue_token_id = EXP_TOKEN_ID;
        issue_branch_id = 2'd1;
        issue_epoch = 2'd2;
        issue_model_id = 8'h11;
        issue_op_class = 8'h22;
        issue_src_addr = EXP_SRC_ADDR;
        issue_dst_addr = EXP_DST_ADDR;
        issue_token_len = 16'd1;
        issue_req_id = EXP_REQ_ID;
        issue_flush_epoch = 2'd0;

        @(posedge clk);
        #1;
        issue_valid = 1'b0;
    end
endtask

task accept_mem_req_once;
    begin
        op_req_ready = 1'b1;
        @(posedge clk);
        #1;
        op_req_ready = 1'b0;
    end
endtask

task send_mem_resp_once;
    begin
        op_resp_valid = 1'b1;
        op_resp_rdata = EXP_RDATA;
        op_resp_id = EXP_REQ_ID;
        op_resp_last = 1'b1;
        #1;
        if (op_resp_ready !== 1'b1) begin
            $fatal(1, "integration transform response should be ready");
        end
        @(posedge clk);
        #1;
        op_resp_valid = 1'b0;
        op_resp_last = 1'b0;
    end
endtask

task consume_result_once;
    begin
        result_ready = 1'b1;
        @(posedge clk);
        #1;
        result_ready = 1'b0;
    end
endtask

initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    clear_inputs();

    repeat (2) @(posedge clk);
    rst_n = 1'b1;
    expect_idle();

    send_issue_once();
    expect_mem_req();

    accept_mem_req_once();

    send_mem_resp_once();
    expect_result();

    consume_result_once();
    expect_idle();

    $display("tb_integration_transform_part_min PASS");
    $finish;
end

endmodule
