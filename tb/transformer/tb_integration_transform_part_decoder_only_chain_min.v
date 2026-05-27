`timescale 1ns/1ps

`include "config/interface_params.vh"
`include "config/memory_params.vh"

module tb_integration_transform_part_decoder_only_chain_min;

localparam MODEL_ID_W = 8;
localparam OP_CLASS_W = 8;
localparam TOKEN_LEN_W = 16;
localparam CONF_W = 8;
localparam RESULT_STATUS_W = 2;
localparam DECODER_DATA_WIDTH = 16;
localparam [RESULT_STATUS_W-1:0] STATUS_OK = 2'b00;

localparam [`TOKEN_ID_W-1:0] EXP_TOKEN_ID = 16'h4a10;
localparam [`NODE_ID_W-1:0] EXP_PARENT_NODE_ID = 4'h7;
localparam [CONF_W-1:0] EXP_CONFIDENCE = 8'd210;
localparam [`SRAM_ADDR_W-1:0] EXP_SRC_ADDR =
    {2'd0, 4'd3, 5'd4, 8'h18, 4'h0};
localparam [`SRAM_ADDR_W-1:0] EXP_DST_ADDR =
    {2'd0, 4'd3, 5'd5, 8'h1c, 4'h0};
localparam [`REQ_ID_W-1:0] EXP_REQ_ID = 4'h9;
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
reg [`NODE_ID_W-1:0] issue_parent_node_id;
reg [CONF_W-1:0] issue_confidence;

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
wire debug_decoder_qkv_valid;
wire debug_decoder_score_valid;
wire debug_decoder_softmax_valid;
wire debug_decoder_value_valid;
wire debug_decoder_ffn_valid;

reg qkv_seen_r;
reg score_seen_r;
reg softmax_seen_r;
reg value_seen_r;
reg ffn_seen_r;
integer stage_index_r;

IntegrationTransformPart #(
    .MODEL_ID_W(MODEL_ID_W),
    .OP_CLASS_W(OP_CLASS_W),
    .TOKEN_LEN_W(TOKEN_LEN_W),
    .CONF_W(CONF_W),
    .ENABLE_DECODER_CHAIN(1),
    .DECODER_DATA_WIDTH(DECODER_DATA_WIDTH),
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
    .issue_parent_node_id(issue_parent_node_id),
    .issue_confidence(issue_confidence),
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
        issue_parent_node_id = {`NODE_ID_W{1'b0}};
        issue_confidence = {CONF_W{1'b0}};

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
            $fatal(1, "decoder-only transform should be idle");
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
            $fatal(1, "decoder-only transform request mismatch");
        end
    end
endtask

task expect_result;
    begin
        #1;
        if (result_valid !== 1'b1) begin
            $display("DBG10 result_valid=%0b expected=1", result_valid);
            $fatal(1, "decoder-only transform result_valid mismatch");
        end
        if (result_token_id != EXP_TOKEN_ID) begin
            $display("DBG10 result_token_id actual=%h expected=%h",
                     result_token_id, EXP_TOKEN_ID);
            $fatal(1, "decoder-only transform result_token_id mismatch");
        end
        if (result_addr != EXP_DST_ADDR) begin
            $display("DBG10 result_addr actual=%h expected=%h",
                     result_addr, EXP_DST_ADDR);
            $fatal(1, "decoder-only transform result_addr mismatch");
        end
        if (result_status != STATUS_OK) begin
            $display("DBG10 result_status actual=%h expected=%h",
                     result_status, STATUS_OK);
            $fatal(1, "decoder-only transform result_status mismatch");
        end
        if (result_data != EXP_RESULT_DATA) begin
            $display("DBG10 result_data actual=%h expected=%h",
                     result_data, EXP_RESULT_DATA);
            $display("DBG10 chain q=%h k=%h v=%h score=%h softmax=%h context=%h",
                     u_integration_transform_part.u_decoder_only_transformer_chain.q_value_r,
                     u_integration_transform_part.u_decoder_only_transformer_chain.k_value_r,
                     u_integration_transform_part.u_decoder_only_transformer_chain.v_value_r,
                     u_integration_transform_part.u_decoder_only_transformer_chain.score_value_r,
                     u_integration_transform_part.u_decoder_only_transformer_chain.softmax_value_r,
                     u_integration_transform_part.u_decoder_only_transformer_chain.context_value_r);
            $display("DBG10 integration result_data_r=%h decoder_chain_result_w=%h",
                     u_integration_transform_part.result_data_r,
                     u_integration_transform_part.decoder_chain_result_w);
            $fatal(1, "decoder-only transform result_data mismatch");
        end
    end
endtask

task send_issue_once;
    begin
        issue_valid = 1'b1;
        issue_token_id = EXP_TOKEN_ID;
        issue_branch_id = 2'd1;
        issue_epoch = 2'd2;
        issue_model_id = 8'h31;
        issue_op_class = 8'h41;
        issue_src_addr = EXP_SRC_ADDR;
        issue_dst_addr = EXP_DST_ADDR;
        issue_token_len = 16'd1;
        issue_req_id = EXP_REQ_ID;
        issue_flush_epoch = 2'd0;
        issue_parent_node_id = EXP_PARENT_NODE_ID;
        issue_confidence = EXP_CONFIDENCE;

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
            $fatal(1, "decoder-only transform response should be ready");
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

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        qkv_seen_r <= 1'b0;
        score_seen_r <= 1'b0;
        softmax_seen_r <= 1'b0;
        value_seen_r <= 1'b0;
        ffn_seen_r <= 1'b0;
        stage_index_r <= 0;
    end else begin
        if (debug_decoder_qkv_valid) begin
            if (stage_index_r != 0) begin
                $fatal(1, "decoder stage order mismatch at qkv");
            end
            qkv_seen_r <= 1'b1;
            stage_index_r <= 1;
        end

        if (debug_decoder_score_valid) begin
            if (stage_index_r != 1) begin
                $fatal(1, "decoder stage order mismatch at score");
            end
            score_seen_r <= 1'b1;
            stage_index_r <= 2;
        end

        if (debug_decoder_softmax_valid) begin
            if (stage_index_r != 2) begin
                $fatal(1, "decoder stage order mismatch at softmax");
            end
            softmax_seen_r <= 1'b1;
            stage_index_r <= 3;
        end

        if (debug_decoder_value_valid) begin
            if (stage_index_r != 3) begin
                $fatal(1, "decoder stage order mismatch at value");
            end
            value_seen_r <= 1'b1;
            stage_index_r <= 4;
        end

        if (debug_decoder_ffn_valid) begin
            if (stage_index_r != 4) begin
                $fatal(1, "decoder stage order mismatch at ffn");
            end
            ffn_seen_r <= 1'b1;
            stage_index_r <= 5;
        end
    end
end

integer cycle_count;

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

    cycle_count = 0;
    while ((!qkv_seen_r || !score_seen_r || !softmax_seen_r ||
            !value_seen_r || !ffn_seen_r || !result_valid) &&
           (cycle_count < 64)) begin
        @(posedge clk);
        #1;
        cycle_count = cycle_count + 1;
    end

    if (!qkv_seen_r) begin
        $fatal(1, "decoder qkv stage was not observed");
    end
    if (!score_seen_r) begin
        $fatal(1, "decoder score stage was not observed");
    end
    if (!softmax_seen_r) begin
        $fatal(1, "decoder softmax stage was not observed");
    end
    if (!value_seen_r) begin
        $fatal(1, "decoder value stage was not observed");
    end
    if (!ffn_seen_r) begin
        $fatal(1, "decoder ffn stage was not observed");
    end
    if (stage_index_r != 5) begin
        $fatal(1, "decoder stage completion count mismatch");
    end

    expect_result();
    consume_result_once();
    expect_idle();

    $display("tb_integration_transform_part_decoder_only_chain_min PASS");
    $finish;
end

endmodule
