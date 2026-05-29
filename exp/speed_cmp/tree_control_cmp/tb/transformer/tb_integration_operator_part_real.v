`timescale 1ns/1ps

`include "config/interface_params.vh"
`include "config/memory_params.vh"

module tb_integration_operator_part_real;

localparam MODEL_ID_W = 8;
localparam OP_CLASS_W = 8;
localparam TOKEN_LEN_W = 16;
localparam RESULT_STATUS_W = 2;
localparam DECODER_DATA_WIDTH = 16;
localparam [RESULT_STATUS_W-1:0] STATUS_OK = 2'b00;

localparam [`TOKEN_ID_W-1:0] EXP_TOKEN_ID = 16'h5510;
localparam [`SRAM_ADDR_W-1:0] EXP_SRC_ADDR =
    {2'd0, 4'd3, 5'd4, 8'h18, 4'h0};
localparam [`SRAM_ADDR_W-1:0] EXP_DST_ADDR =
    {2'd0, 4'd3, 5'd5, 8'h1c, 4'h0};
localparam [`REQ_ID_W-1:0] EXP_REQ_ID = 4'h6;
localparam [DECODER_DATA_WIDTH-1:0] EXP_TOKEN_VECTOR = 16'h3c00;
localparam [DECODER_DATA_WIDTH-1:0] EXP_KV_VECTOR = 16'h4000;
localparam [`SRAM_RDATA_W-1:0] EXP_RDATA = {
    {(`SRAM_RDATA_W-(2*DECODER_DATA_WIDTH)){1'b0}},
    EXP_KV_VECTOR,
    EXP_TOKEN_VECTOR
};
localparam [`SRAM_WDATA_W-1:0] EXP_RESULT_DATA = {
    {(`SRAM_WDATA_W-DECODER_DATA_WIDTH){1'b0}},
    EXP_KV_VECTOR
};

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
reg hbm_resp_valid;
reg [`HBM_DATA_W-1:0] hbm_resp_rdata;
reg [`REQ_ID_W-1:0] hbm_resp_id;

wire result_valid;
reg result_ready;
wire [`TOKEN_ID_W-1:0] result_token_id;
wire [`SRAM_ADDR_W-1:0] result_addr;
wire [`SRAM_WDATA_W-1:0] result_data;
wire [RESULT_STATUS_W-1:0] result_status;
wire hbm_req_valid;
wire hbm_req_write;
wire [`HBM_ADDR_W-1:0] hbm_req_addr;
wire [`HBM_DATA_W-1:0] hbm_req_wdata;
wire [`REQ_ID_W-1:0] hbm_req_id;
wire debug_decoder_qkv_valid;
wire debug_decoder_score_valid;
wire debug_decoder_softmax_valid;
wire debug_decoder_value_valid;
wire debug_decoder_ffn_valid;

integer cycle_count;
reg qkv_seen_r;
reg score_seen_r;
reg softmax_seen_r;
reg value_seen_r;
reg ffn_seen_r;

IntegrationOperatorPart #(
    .MODEL_ID_W(MODEL_ID_W),
    .OP_CLASS_W(OP_CLASS_W),
    .TOKEN_LEN_W(TOKEN_LEN_W),
    .RESULT_STATUS_W(RESULT_STATUS_W),
    .ENABLE_DECODER_CHAIN(1),
    .DECODER_DATA_WIDTH(DECODER_DATA_WIDTH)
) u_integration_operator_part (
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
    .issue_tree_mask_en(1'b0),
    .issue_tree_mask_branch_id({`BRANCH_ID_W{1'b0}}),
    .issue_prefix_len(16'd0),
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
    .hbm_resp_valid(hbm_resp_valid),
    .hbm_resp_rdata(hbm_resp_rdata),
    .hbm_resp_id(hbm_resp_id),
    .hbm_req_valid(hbm_req_valid),
    .hbm_req_write(hbm_req_write),
    .hbm_req_addr(hbm_req_addr),
    .hbm_req_wdata(hbm_req_wdata),
    .hbm_req_id(hbm_req_id),
    .result_valid(result_valid),
    .result_ready(result_ready),
    .result_token_id(result_token_id),
    .result_addr(result_addr),
    .result_data(result_data),
    .result_status(result_status),
    .debug_decoder_qkv_valid(debug_decoder_qkv_valid),
    .debug_decoder_score_valid(debug_decoder_score_valid),
    .debug_decoder_softmax_valid(debug_decoder_softmax_valid),
    .debug_decoder_value_valid(debug_decoder_value_valid),
    .debug_decoder_ffn_valid(debug_decoder_ffn_valid)
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
        hbm_resp_valid = 1'b0;
        hbm_resp_rdata = {`HBM_DATA_W{1'b0}};
        hbm_resp_id = {`REQ_ID_W{1'b0}};
        result_ready = 1'b0;
    end
endtask

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        qkv_seen_r <= 1'b0;
        score_seen_r <= 1'b0;
        softmax_seen_r <= 1'b0;
        value_seen_r <= 1'b0;
        ffn_seen_r <= 1'b0;
    end else begin
        if (debug_decoder_qkv_valid) begin
            qkv_seen_r <= 1'b1;
        end
        if (debug_decoder_score_valid) begin
            score_seen_r <= 1'b1;
        end
        if (debug_decoder_softmax_valid) begin
            softmax_seen_r <= 1'b1;
        end
        if (debug_decoder_value_valid) begin
            value_seen_r <= 1'b1;
        end
        if (debug_decoder_ffn_valid) begin
            ffn_seen_r <= 1'b1;
        end
    end
end

initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    clear_inputs();

    repeat (2) @(posedge clk);
    rst_n = 1'b1;

    @(posedge clk);
    if (!issue_ready) begin
        $fatal(1, "integration operator should be ready after reset");
    end

    issue_valid = 1'b1;
    issue_token_id = EXP_TOKEN_ID;
    issue_branch_id = 2'd1;
    issue_epoch = 2'd0;
    issue_model_id = 8'h11;
    issue_op_class = 8'h22;
    issue_src_addr = EXP_SRC_ADDR;
    issue_dst_addr = EXP_DST_ADDR;
    issue_token_len = 16'd1;
    issue_req_id = EXP_REQ_ID;
    issue_flush_epoch = 2'd0;

    @(posedge clk);
    issue_valid = 1'b0;

    #1;
    if (!op_req_valid || op_req_write || (op_req_addr != EXP_SRC_ADDR) ||
        (op_req_id != EXP_REQ_ID) || !op_req_last || (op_req_tag != EXP_TOKEN_ID)) begin
        $fatal(1, "integration operator request mismatch");
    end

    op_req_ready = 1'b1;
    @(posedge clk);
    #1;
    op_req_ready = 1'b0;

    op_resp_valid = 1'b1;
    op_resp_rdata = EXP_RDATA;
    op_resp_id = EXP_REQ_ID;
    op_resp_last = 1'b1;
    #1;
    if (op_resp_ready !== 1'b1) begin
        $fatal(1, "integration operator response should be ready");
    end
    @(posedge clk);
    #1;
    op_resp_valid = 1'b0;
    op_resp_last = 1'b0;

    cycle_count = 0;
    while (!result_valid && (cycle_count < 128)) begin
        @(posedge clk);
        cycle_count = cycle_count + 1;
    end

    if (!result_valid) begin
        $fatal(1, "integration operator did not produce result");
    end

    #1;
    if ((result_token_id != EXP_TOKEN_ID) ||
        (result_addr != EXP_DST_ADDR) ||
        (result_status != STATUS_OK) ||
        (result_data != EXP_RESULT_DATA)) begin
        $fatal(1, "integration operator result mismatch");
    end
    if (!qkv_seen_r || !score_seen_r || !softmax_seen_r ||
        !value_seen_r || !ffn_seen_r) begin
        $fatal(1, "integration operator did not traverse full decoder chain");
    end

    result_ready = 1'b1;
    @(posedge clk);
    result_ready = 1'b0;

    $display("tb_integration_operator_part_real PASS");
    $finish;
end

endmodule
