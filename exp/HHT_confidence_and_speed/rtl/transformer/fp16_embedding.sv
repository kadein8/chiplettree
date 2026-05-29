`include "config/interface_params.vh"
`include "config/memory_params.vh"
`include "config/model_params.vh"
`timescale 1ns/1ps

module fp16_embedding #(
    parameter integer DATA_WIDTH = `FP16_TILE_DATA_W,
    parameter integer ADDR_W = `SRAM_ADDR_W,
    parameter integer DATA_BUS_W = `SRAM_WDATA_W,
    parameter integer REQ_ID_W = `REQ_ID_W,
    parameter integer VECTOR_LEN = `QWEN3_DMODEL,
    parameter integer RESULT_STATUS_W = 2,
    parameter [RESULT_STATUS_W-1:0] RESULT_STATUS_OK = 2'b00
) (
    input  logic                       clk,
    input  logic                       rst_n,

    input  logic                       issue_valid,
    output logic                       issue_ready,
    input  logic [31:0]                issue_token_id,
    input  logic [ADDR_W-1:0]          issue_embedding_base,
    input  logic [ADDR_W-1:0]          issue_result_addr,
    input  logic [REQ_ID_W-1:0]        issue_req_id,

    output logic                       sram_rd_valid,
    input  logic                       sram_rd_ready,
    output logic [ADDR_W-1:0]          sram_rd_addr,
    output logic [REQ_ID_W-1:0]        sram_rd_id,

    input  logic                       sram_resp_valid,
    output logic                       sram_resp_ready,
    input  logic [DATA_BUS_W-1:0]      sram_resp_data,
    input  logic [REQ_ID_W-1:0]        sram_resp_id,

    output logic                       sram_wr_valid,
    input  logic                       sram_wr_ready,
    output logic [ADDR_W-1:0]          sram_wr_addr,
    output logic [DATA_BUS_W-1:0]      sram_wr_data,

    output logic                       result_valid,
    input  logic                       result_ready,
    output logic [ADDR_W-1:0]          result_addr,
    output logic [DATA_BUS_W-1:0]      result_data,
    output logic [RESULT_STATUS_W-1:0] result_status
);

localparam integer VECTOR_BEATS = VECTOR_LEN / (DATA_BUS_W / DATA_WIDTH);
localparam logic [2:0]
    ST_IDLE = 3'd0,
    ST_REQ  = 3'd1,
    ST_RESP = 3'd2,
    ST_WRITE = 3'd3,
    ST_HOLD = 3'd4;

logic [2:0] state_r;
logic [ADDR_W-1:0] embedding_base_r;
logic [ADDR_W-1:0] result_addr_r;
logic [REQ_ID_W-1:0] req_id_r;
logic [31:0] token_id_r;
logic [15:0] beat_idx_r;
logic [DATA_BUS_W-1:0] beat_data_r;
logic [RESULT_STATUS_W-1:0] result_status_r;
logic [ADDR_W-1:0] token_base_offset_w;

function automatic [ADDR_W-1:0] addr_from_u16;
    input [15:0] value;
    begin
        addr_from_u16 = {{(ADDR_W-16){1'b0}}, value};
    end
endfunction

function automatic [ADDR_W-1:0] addr_from_u32;
    input [31:0] value;
    begin
        addr_from_u32 = value[ADDR_W-1:0];
    end
endfunction

assign token_base_offset_w = addr_from_u32(token_id_r * VECTOR_BEATS);
assign issue_ready = (state_r == ST_IDLE);
assign sram_rd_id = req_id_r;
assign sram_resp_ready =
    ((state_r == ST_REQ) || (state_r == ST_RESP)) &&
    (sram_resp_id == req_id_r);
assign result_valid = (state_r == ST_HOLD);
assign result_addr = result_addr_r;
assign result_data = beat_data_r;
assign result_status = result_status_r;

always_comb begin
    sram_rd_valid = 1'b0;
    sram_rd_addr = {ADDR_W{1'b0}};
    sram_wr_valid = 1'b0;
    sram_wr_addr = {ADDR_W{1'b0}};
    sram_wr_data = beat_data_r;

    case (state_r)
        ST_REQ: begin
            sram_rd_valid = 1'b1;
            sram_rd_addr = embedding_base_r + token_base_offset_w + addr_from_u16(beat_idx_r);
        end
        ST_WRITE: begin
            sram_wr_valid = 1'b1;
            sram_wr_addr = result_addr_r + addr_from_u16(beat_idx_r);
        end
        default: begin
        end
    endcase
end

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state_r <= ST_IDLE;
        embedding_base_r <= {ADDR_W{1'b0}};
        result_addr_r <= {ADDR_W{1'b0}};
        req_id_r <= {REQ_ID_W{1'b0}};
        token_id_r <= 32'd0;
        beat_idx_r <= 16'd0;
        beat_data_r <= {DATA_BUS_W{1'b0}};
        result_status_r <= {RESULT_STATUS_W{1'b0}};
    end else begin
        case (state_r)
            ST_IDLE: begin
                if (issue_valid) begin
                    embedding_base_r <= issue_embedding_base;
                    result_addr_r <= issue_result_addr;
                    req_id_r <= issue_req_id;
                    token_id_r <= issue_token_id;
                    beat_idx_r <= 16'd0;
                    result_status_r <= RESULT_STATUS_OK;
                    state_r <= ST_REQ;
                end
            end

            ST_REQ: begin
                if (sram_resp_valid && sram_resp_ready) begin
                    beat_data_r <= sram_resp_data;
                    state_r <= ST_WRITE;
                end else if (sram_rd_valid && sram_rd_ready) begin
                    state_r <= ST_RESP;
                end
            end

            ST_RESP: begin
                if (sram_resp_valid && sram_resp_ready) begin
                    beat_data_r <= sram_resp_data;
                    state_r <= ST_WRITE;
                end
            end

            ST_WRITE: begin
                if (sram_wr_valid && sram_wr_ready) begin
                    if (beat_idx_r == (VECTOR_BEATS - 1)) begin
                        state_r <= ST_HOLD;
                    end else begin
                        beat_idx_r <= beat_idx_r + 16'd1;
                        state_r <= ST_REQ;
                    end
                end
            end

            ST_HOLD: begin
                if (result_valid && result_ready)
                    state_r <= ST_IDLE;
            end

            default: state_r <= ST_IDLE;
        endcase
    end
end

endmodule
