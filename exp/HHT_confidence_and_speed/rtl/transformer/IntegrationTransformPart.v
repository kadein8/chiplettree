`include "config/interface_params.vh"
`include "config/memory_params.vh"
`timescale 1ns/1ps

module IntegrationTransformPart #(
    parameter MODEL_ID_W = 8,
    parameter OP_CLASS_W = 8,
    parameter TOKEN_LEN_W = 16,
    parameter CONF_W = 8,
    parameter ENABLE_DECODER_CHAIN = 0,
    parameter DECODER_DATA_WIDTH = 16,
    parameter integer DECODER_VECTOR_DIM = 4,
    parameter RESULT_STATUS_W = 2,
    parameter [RESULT_STATUS_W-1:0] RESULT_STATUS_OK = 2'b00
) (
    input                         clk,
    input                         rst_n,

    input                         issue_valid,
    output                        issue_ready,
    input  [`TOKEN_ID_W-1:0]      issue_token_id,
    input  [`BRANCH_ID_W-1:0]     issue_branch_id,
    input  [1:0]                  issue_epoch,
    input  [MODEL_ID_W-1:0]       issue_model_id,
    input  [OP_CLASS_W-1:0]       issue_op_class,
    input  [`SRAM_ADDR_W-1:0]     issue_src_addr,
    input  [`SRAM_ADDR_W-1:0]     issue_dst_addr,
    input  [TOKEN_LEN_W-1:0]      issue_token_len,
    input  [`REQ_ID_W-1:0]        issue_req_id,
    input  [1:0]                  issue_flush_epoch,
    input  [`NODE_ID_W-1:0]       issue_parent_node_id,
    input  [CONF_W-1:0]           issue_confidence,

    output                        op_req_valid,
    input                         op_req_ready,
    output                        op_req_write,
    output [`SRAM_ADDR_W-1:0]     op_req_addr,
    output [`SRAM_WDATA_W-1:0]    op_req_wdata,
    output [`REQ_ID_W-1:0]        op_req_id,
    output                        op_req_last,
    output [`TOKEN_ID_W-1:0]      op_req_tag,

    input                         op_resp_valid,
    output                        op_resp_ready,
    input  [`SRAM_RDATA_W-1:0]    op_resp_rdata,
    input  [`REQ_ID_W-1:0]        op_resp_id,
    input                         op_resp_last,

    output                        result_valid,
    input                         result_ready,
    output [`TOKEN_ID_W-1:0]      result_token_id,
    output [`SRAM_ADDR_W-1:0]     result_addr,
    output [`SRAM_WDATA_W-1:0]    result_data,
    output [RESULT_STATUS_W-1:0]  result_status,
    output                        debug_decoder_qkv_valid,
    output                        debug_decoder_score_valid,
    output                        debug_decoder_softmax_valid,
    output                        debug_decoder_value_valid,
    output                        debug_decoder_ffn_valid
);

localparam [2:0]
    ST_IDLE        = 3'd0,
    ST_WAIT_REQ    = 3'd1,
    ST_WAIT_RESP   = 3'd2,
    ST_WAIT_CHAIN  = 3'd3,
    ST_HOLD_RESULT = 3'd4;

reg [2:0] state_r;
reg [`TOKEN_ID_W-1:0] token_id_r;
reg [`SRAM_ADDR_W-1:0] src_addr_r;
reg [`SRAM_ADDR_W-1:0] dst_addr_r;
reg [`REQ_ID_W-1:0] req_id_r;
reg [`SRAM_WDATA_W-1:0] result_data_r;
reg [RESULT_STATUS_W-1:0] result_status_r;
reg chain_start_pending_r;
reg [(DECODER_VECTOR_DIM*DECODER_DATA_WIDTH)-1:0] chain_token_vector_r;
reg [(DECODER_VECTOR_DIM*DECODER_DATA_WIDTH)-1:0] chain_kv_vector_r;
wire legacy_compact_payload_w;
wire [(DECODER_VECTOR_DIM*DECODER_DATA_WIDTH)-1:0] legacy_token_vector_w;
wire [(DECODER_VECTOR_DIM*DECODER_DATA_WIDTH)-1:0] legacy_kv_vector_w;

wire decoder_chain_start_valid_w;
wire decoder_chain_start_ready_w;
wire decoder_chain_result_valid_w;
wire [(DECODER_VECTOR_DIM*DECODER_DATA_WIDTH)-1:0] decoder_chain_result_w;
wire decoder_chain_qkv_valid_w;
wire decoder_chain_score_valid_w;
wire decoder_chain_softmax_valid_w;
wire decoder_chain_value_valid_w;
wire decoder_chain_ffn_valid_w;
wire [`SRAM_WDATA_W-1:0] decoder_chain_result_packed_w;

wire issue_fire_w;
wire op_req_fire_w;
wire op_resp_fire_w;
wire result_fire_w;
wire resp_id_match_w;

assign issue_ready = (state_r == ST_IDLE);
assign issue_fire_w = issue_valid && issue_ready;

assign op_req_valid = (state_r == ST_WAIT_REQ);
assign op_req_write = 1'b0;
assign op_req_addr = src_addr_r;
assign op_req_wdata = {`SRAM_WDATA_W{1'b0}};
assign op_req_id = req_id_r;
assign op_req_last = 1'b1;
assign op_req_tag = token_id_r;
assign op_req_fire_w = op_req_valid && op_req_ready;

assign resp_id_match_w = (op_resp_id == req_id_r);
assign op_resp_ready =
    (state_r == ST_WAIT_RESP) && resp_id_match_w && op_resp_last;
assign op_resp_fire_w = op_resp_valid && op_resp_ready;

assign result_valid = (state_r == ST_HOLD_RESULT);
assign result_token_id = token_id_r;
assign result_addr = dst_addr_r;
assign result_data = result_data_r;
assign result_status = result_status_r;
assign result_fire_w = result_valid && result_ready;
assign decoder_chain_start_valid_w =
    ENABLE_DECODER_CHAIN &&
    (state_r == ST_WAIT_CHAIN) &&
    chain_start_pending_r;
assign decoder_chain_result_packed_w =
    {{(`SRAM_WDATA_W-(DECODER_VECTOR_DIM*DECODER_DATA_WIDTH)){1'b0}},
     decoder_chain_result_w};
assign legacy_compact_payload_w =
    (op_resp_rdata[`SRAM_RDATA_W-1:(2*DECODER_DATA_WIDTH)] ==
     {(`SRAM_RDATA_W-(2*DECODER_DATA_WIDTH)){1'b0}});
assign legacy_token_vector_w =
    {{((DECODER_VECTOR_DIM-1)*DECODER_DATA_WIDTH){1'b0}},
     op_resp_rdata[0 +: DECODER_DATA_WIDTH]};
assign legacy_kv_vector_w =
    {{((DECODER_VECTOR_DIM-1)*DECODER_DATA_WIDTH){1'b0}},
     op_resp_rdata[DECODER_DATA_WIDTH +: DECODER_DATA_WIDTH]};
assign debug_decoder_qkv_valid =
    ENABLE_DECODER_CHAIN ? decoder_chain_qkv_valid_w : 1'b0;
assign debug_decoder_score_valid =
    ENABLE_DECODER_CHAIN ? decoder_chain_score_valid_w : 1'b0;
assign debug_decoder_softmax_valid =
    ENABLE_DECODER_CHAIN ? decoder_chain_softmax_valid_w : 1'b0;
assign debug_decoder_value_valid =
    ENABLE_DECODER_CHAIN ? decoder_chain_value_valid_w : 1'b0;
assign debug_decoder_ffn_valid =
    ENABLE_DECODER_CHAIN ? decoder_chain_ffn_valid_w : 1'b0;

decoderOnlyTransformerChain #(
    .DATA_WIDTH(DECODER_DATA_WIDTH),
    .VECTOR_DIM(DECODER_VECTOR_DIM)
) u_decoder_only_transformer_chain (
    .clk(clk),
    .rst_n(rst_n),
    .start_valid(decoder_chain_start_valid_w),
    .start_ready(decoder_chain_start_ready_w),
    .token_vector_i(chain_token_vector_r),
    .kv_vector_i(chain_kv_vector_r),
    .result_valid(decoder_chain_result_valid_w),
    .result_vector_o(decoder_chain_result_w),
    .debug_qkv_valid(decoder_chain_qkv_valid_w),
    .debug_score_valid(decoder_chain_score_valid_w),
    .debug_softmax_valid(decoder_chain_softmax_valid_w),
    .debug_value_valid(decoder_chain_value_valid_w),
    .debug_ffn_valid(decoder_chain_ffn_valid_w)
);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state_r <= ST_IDLE;
        token_id_r <= {`TOKEN_ID_W{1'b0}};
        src_addr_r <= {`SRAM_ADDR_W{1'b0}};
        dst_addr_r <= {`SRAM_ADDR_W{1'b0}};
        req_id_r <= {`REQ_ID_W{1'b0}};
        result_data_r <= {`SRAM_WDATA_W{1'b0}};
        result_status_r <= {RESULT_STATUS_W{1'b0}};
        chain_start_pending_r <= 1'b0;
        chain_token_vector_r <= {(DECODER_VECTOR_DIM*DECODER_DATA_WIDTH){1'b0}};
        chain_kv_vector_r <= {(DECODER_VECTOR_DIM*DECODER_DATA_WIDTH){1'b0}};
    end else begin
        case (state_r)
            ST_IDLE: begin
                if (issue_fire_w) begin
                    token_id_r <= issue_token_id;
                    src_addr_r <= issue_src_addr;
                    dst_addr_r <= issue_dst_addr;
                    req_id_r <= issue_req_id;
                    result_data_r <= {`SRAM_WDATA_W{1'b0}};
                    result_status_r <= RESULT_STATUS_OK;
                    chain_start_pending_r <= 1'b0;
                    state_r <= ST_WAIT_REQ;
                end
            end

            ST_WAIT_REQ: begin
                if (op_req_fire_w) begin
                    state_r <= ST_WAIT_RESP;
                end
            end

            ST_WAIT_RESP: begin
                if (op_resp_fire_w) begin
                    if (ENABLE_DECODER_CHAIN) begin
                        if (legacy_compact_payload_w) begin
                            chain_token_vector_r <= legacy_token_vector_w;
                            chain_kv_vector_r <= legacy_kv_vector_w;
                        end else begin
                            chain_token_vector_r <=
                                op_resp_rdata[(4*DECODER_DATA_WIDTH)-1:0];
                            chain_kv_vector_r <=
                                op_resp_rdata[(8*DECODER_DATA_WIDTH)-1:(4*DECODER_DATA_WIDTH)];
                        end
                        chain_start_pending_r <= 1'b1;
                        state_r <= ST_WAIT_CHAIN;
                    end else begin
                        result_data_r <= op_resp_rdata;
                        result_status_r <= RESULT_STATUS_OK;
                        state_r <= ST_HOLD_RESULT;
                    end
                end
            end

            ST_WAIT_CHAIN: begin
                if (decoder_chain_start_valid_w && decoder_chain_start_ready_w) begin
                    chain_start_pending_r <= 1'b0;
                end

                if (decoder_chain_result_valid_w) begin
                    result_data_r <= decoder_chain_result_packed_w;
                    result_status_r <= RESULT_STATUS_OK;
                    state_r <= ST_HOLD_RESULT;
                end
            end

            ST_HOLD_RESULT: begin
                if (result_fire_w) begin
                    state_r <= ST_IDLE;
                end
            end

            default: begin
                state_r <= ST_IDLE;
            end
        endcase
    end
end

endmodule
