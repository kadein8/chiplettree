`include "config/interface_params.vh"
`include "config/memory_params.vh"
`include "config/model_params.vh"
`timescale 1ns/1ps

module fp16_residual_add #(
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
    input  logic [ADDR_W-1:0]          issue_x_addr,
    input  logic [ADDR_W-1:0]          issue_residual_addr,
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

localparam integer ELEMS_PER_BEAT = DATA_BUS_W / DATA_WIDTH;
localparam integer VECTOR_BEATS = VECTOR_LEN / ELEMS_PER_BEAT;
localparam logic [3:0]
    ST_IDLE    = 4'd0,
    ST_X_REQ   = 4'd1,
    ST_X_RESP  = 4'd2,
    ST_X_DRAIN = 4'd3,
    ST_R_REQ   = 4'd4,
    ST_R_RESP  = 4'd5,
    ST_R_DRAIN = 4'd6,
    ST_WRITE   = 4'd7,
    ST_HOLD    = 4'd8;

function automatic [ADDR_W-1:0] addr_from_u16;
    input [15:0] value;
    begin
        addr_from_u16 = {{(ADDR_W-16){1'b0}}, value};
    end
endfunction

logic [3:0] state_r;
logic [ADDR_W-1:0] x_addr_r;
logic [ADDR_W-1:0] residual_addr_r;
logic [ADDR_W-1:0] result_addr_r;
logic [REQ_ID_W-1:0] req_id_r;
logic [15:0] beat_idx_r;
logic x_req_accepted_r;
logic r_req_accepted_r;
logic [DATA_BUS_W-1:0] x_beat_r;
logic [DATA_BUS_W-1:0] result_beat_r;
logic [RESULT_STATUS_W-1:0] result_status_r;
logic [DATA_WIDTH-1:0] add_w [0:ELEMS_PER_BEAT-1];
integer elem_idx_i;
genvar elem_g;

assign issue_ready = (state_r == ST_IDLE);
assign sram_rd_id = req_id_r;
assign sram_resp_ready =
    (((state_r == ST_X_REQ) && x_req_accepted_r) ||
     (state_r == ST_X_RESP) ||
     (state_r == ST_X_DRAIN) ||
     ((state_r == ST_R_REQ) && r_req_accepted_r) ||
     (state_r == ST_R_RESP) ||
     (state_r == ST_R_DRAIN)) &&
    (sram_resp_id == req_id_r);
assign result_valid = (state_r == ST_HOLD);
assign result_addr = result_addr_r;
assign result_data = result_beat_r;
assign result_status = result_status_r;

generate
    for (elem_g = 0; elem_g < ELEMS_PER_BEAT; elem_g = elem_g + 1) begin : gen_add
        floatAdd16 u_float_add16 (
            .floatA(x_beat_r[(elem_g*DATA_WIDTH) +: DATA_WIDTH]),
            .floatB(sram_resp_data[(elem_g*DATA_WIDTH) +: DATA_WIDTH]),
            .sum(add_w[elem_g])
        );
    end
endgenerate

always_comb begin
    sram_rd_valid = 1'b0;
    sram_rd_addr = {ADDR_W{1'b0}};
    sram_wr_valid = 1'b0;
    sram_wr_addr = {ADDR_W{1'b0}};
    sram_wr_data = result_beat_r;

    case (state_r)
        ST_X_REQ: begin
            sram_rd_valid = 1'b1;
            sram_rd_addr = x_addr_r + addr_from_u16(beat_idx_r);
        end
        ST_R_REQ: begin
            sram_rd_valid = 1'b1;
            sram_rd_addr = residual_addr_r + addr_from_u16(beat_idx_r);
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
        x_addr_r <= {ADDR_W{1'b0}};
        residual_addr_r <= {ADDR_W{1'b0}};
        result_addr_r <= {ADDR_W{1'b0}};
        req_id_r <= {REQ_ID_W{1'b0}};
        beat_idx_r <= 16'd0;
        x_req_accepted_r <= 1'b0;
        r_req_accepted_r <= 1'b0;
        x_beat_r <= {DATA_BUS_W{1'b0}};
        result_beat_r <= {DATA_BUS_W{1'b0}};
        result_status_r <= {RESULT_STATUS_W{1'b0}};
    end else begin
        case (state_r)
            ST_IDLE: begin
                if (issue_valid) begin
                    x_addr_r <= issue_x_addr;
                    residual_addr_r <= issue_residual_addr;
                    result_addr_r <= issue_result_addr;
                    req_id_r <= issue_req_id;
                    beat_idx_r <= 16'd0;
                    x_req_accepted_r <= 1'b0;
                    r_req_accepted_r <= 1'b0;
                    result_status_r <= RESULT_STATUS_OK;
                    state_r <= ST_X_REQ;
                end
            end

            ST_X_REQ: begin
                if (x_req_accepted_r && sram_resp_valid && sram_resp_ready) begin
                    x_beat_r <= sram_resp_data;
                    x_req_accepted_r <= 1'b0;
                    r_req_accepted_r <= 1'b0;
                    state_r <= ST_X_DRAIN;
                end else if (sram_rd_valid && sram_rd_ready) begin
                    x_req_accepted_r <= 1'b1;
                    state_r <= ST_X_RESP;
                end
            end

            ST_X_RESP: begin
                if (sram_resp_valid && sram_resp_ready) begin
                    x_beat_r <= sram_resp_data;
                    x_req_accepted_r <= 1'b0;
                    r_req_accepted_r <= 1'b0;
                    state_r <= ST_X_DRAIN;
                end
            end

            ST_X_DRAIN: begin
                if (!(sram_resp_valid && sram_resp_ready)) begin
                    state_r <= ST_R_REQ;
                end
            end

            ST_R_REQ: begin
                if (r_req_accepted_r && sram_resp_valid && sram_resp_ready) begin
                    for (elem_idx_i = 0; elem_idx_i < ELEMS_PER_BEAT; elem_idx_i = elem_idx_i + 1) begin
                        result_beat_r[(elem_idx_i*DATA_WIDTH) +: DATA_WIDTH] <= add_w[elem_idx_i];
                    end
                    r_req_accepted_r <= 1'b0;
                    state_r <= ST_R_DRAIN;
                end else if (sram_rd_valid && sram_rd_ready) begin
                    r_req_accepted_r <= 1'b1;
                    state_r <= ST_R_RESP;
                end
            end

            ST_R_RESP: begin
                if (sram_resp_valid && sram_resp_ready) begin
                    for (elem_idx_i = 0; elem_idx_i < ELEMS_PER_BEAT; elem_idx_i = elem_idx_i + 1) begin
                        result_beat_r[(elem_idx_i*DATA_WIDTH) +: DATA_WIDTH] <= add_w[elem_idx_i];
                    end
                    r_req_accepted_r <= 1'b0;
                    state_r <= ST_R_DRAIN;
                end
            end

            ST_R_DRAIN: begin
                if (!(sram_resp_valid && sram_resp_ready)) begin
                    state_r <= ST_WRITE;
                end
            end

            ST_WRITE: begin
                if (sram_wr_valid && sram_wr_ready) begin
                    if (beat_idx_r == (VECTOR_BEATS - 1)) begin
                        x_req_accepted_r <= 1'b0;
                        r_req_accepted_r <= 1'b0;
                        state_r <= ST_HOLD;
                    end else begin
                        beat_idx_r <= beat_idx_r + 16'd1;
                        x_req_accepted_r <= 1'b0;
                        r_req_accepted_r <= 1'b0;
                        state_r <= ST_X_REQ;
                    end
                end
            end

            ST_HOLD: begin
                if (result_valid && result_ready) begin
                    x_req_accepted_r <= 1'b0;
                    r_req_accepted_r <= 1'b0;
                    state_r <= ST_IDLE;
                end
            end

            default: state_r <= ST_IDLE;
        endcase
    end
end

endmodule
