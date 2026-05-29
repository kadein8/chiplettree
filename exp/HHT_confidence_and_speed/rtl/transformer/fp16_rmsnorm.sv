`include "config/interface_params.vh"
`include "config/memory_params.vh"
`include "config/model_params.vh"
`timescale 1ns/1ps

module fp16_rmsnorm #(
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
    input  logic [ADDR_W-1:0]          issue_gamma_addr,
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
    ST_IDLE      = 4'd0,
    ST_X_REQ     = 4'd1,
    ST_X_RESP    = 4'd2,
    ST_X_DRAIN   = 4'd3,
    ST_INV_START = 4'd4,
    ST_INV_WAIT  = 4'd5,
    ST_G_REQ     = 4'd6,
    ST_G_RESP    = 4'd7,
    ST_G_DRAIN   = 4'd8,
    ST_G_WRITE   = 4'd9,
    ST_HOLD      = 4'd10;

function automatic [DATA_WIDTH-1:0] fp16_neg;
    input [DATA_WIDTH-1:0] value;
    begin
        if (value == {DATA_WIDTH{1'b0}})
            fp16_neg = value;
        else
            fp16_neg = {~value[DATA_WIDTH-1], value[DATA_WIDTH-2:0]};
    end
endfunction

function automatic [DATA_WIDTH-1:0] fp16_div_pow2;
    input [DATA_WIDTH-1:0] value;
    input integer shift_by;
    reg [4:0] exponent_v;
    begin
        exponent_v = value[14:10];
        if ((value == 16'h0000) || (exponent_v <= shift_by[4:0]))
            fp16_div_pow2 = 16'h0000;
        else
            fp16_div_pow2 = {value[15], exponent_v - shift_by[4:0], value[9:0]};
    end
endfunction

function automatic [ADDR_W-1:0] addr_from_u16;
    input [15:0] value;
    begin
        addr_from_u16 = {{(ADDR_W-16){1'b0}}, value};
    end
endfunction

logic [3:0] state_r;
logic [ADDR_W-1:0] x_addr_r;
logic [ADDR_W-1:0] gamma_addr_r;
logic [ADDR_W-1:0] result_addr_r;
logic [REQ_ID_W-1:0] req_id_r;
logic [15:0] beat_idx_r;
logic [(VECTOR_LEN*DATA_WIDTH)-1:0] x_mem_r;
logic [DATA_BUS_W-1:0] gamma_beat_r;
logic [DATA_BUS_W-1:0] write_beat_r;
logic [DATA_WIDTH-1:0] sumsq_r;
logic [DATA_WIDTH-1:0] mean_sq_w;
logic [DATA_WIDTH-1:0] mean_sq_eps_w;
logic [DATA_WIDTH-1:0] inv_rms_r;
logic inv_start_r;
logic inv_busy_w;
logic inv_done_w;
logic [DATA_WIDTH-1:0] inv_result_w;
logic [RESULT_STATUS_W-1:0] result_status_r;
logic x_req_accepted_r;
logic g_req_accepted_r;

logic [DATA_WIDTH-1:0] x_square_w   [0:ELEMS_PER_BEAT-1];
logic [DATA_WIDTH-1:0] beat_sum_w   [0:ELEMS_PER_BEAT];
logic [DATA_WIDTH-1:0] scale_mul0_w [0:ELEMS_PER_BEAT-1];
logic [DATA_WIDTH-1:0] gamma_mul_w  [0:ELEMS_PER_BEAT-1];
logic [DATA_WIDTH-1:0] scale_mul1_w [0:ELEMS_PER_BEAT-1];
logic [DATA_WIDTH-1:0] sumsq_next_w;
integer elem_idx_i;
genvar elem_g;

assign issue_ready = (state_r == ST_IDLE);
assign sram_rd_id = req_id_r;
assign sram_resp_ready =
    ((((state_r == ST_X_REQ) &&
       (x_req_accepted_r || (sram_rd_valid && sram_rd_ready))) ||
      (state_r == ST_X_RESP) ||
      (state_r == ST_X_DRAIN) ||
      ((state_r == ST_G_REQ) &&
       (g_req_accepted_r || (sram_rd_valid && sram_rd_ready))) ||
      (state_r == ST_G_RESP) ||
      (state_r == ST_G_DRAIN)) &&
    (sram_resp_id == req_id_r));
assign result_valid = (state_r == ST_HOLD);
assign result_addr = result_addr_r;
assign result_data = write_beat_r;
assign result_status = result_status_r;

assign mean_sq_w = fp16_div_pow2(sumsq_r, 10);

floatAdd16 u_add_eps (
    .floatA(mean_sq_w),
    .floatB(16'h0011),
    .sum(mean_sq_eps_w)
);

fp16_inv_sqrt_nr u_fp16_inv_sqrt_nr (
    .clk(clk),
    .rst_n(rst_n),
    .start(inv_start_r),
    .value(mean_sq_eps_w),
    .busy(inv_busy_w),
    .done(inv_done_w),
    .result(inv_result_w)
);

generate
    for (elem_g = 0; elem_g < ELEMS_PER_BEAT; elem_g = elem_g + 1) begin : gen_rms_beat
        floatMult16 u_square (
            .floatA(sram_resp_data[(elem_g*DATA_WIDTH) +: DATA_WIDTH]),
            .floatB(sram_resp_data[(elem_g*DATA_WIDTH) +: DATA_WIDTH]),
            .product(x_square_w[elem_g])
        );

        floatMult16 u_scale_mul0 (
            .floatA(x_mem_r[((beat_idx_r*ELEMS_PER_BEAT + elem_g)*DATA_WIDTH) +: DATA_WIDTH]),
            .floatB(inv_rms_r),
            .product(scale_mul0_w[elem_g])
        );

        assign gamma_mul_w[elem_g] =
            (((state_r == ST_G_REQ) || (state_r == ST_G_RESP)) &&
             sram_resp_valid && sram_resp_ready) ?
            sram_resp_data[(elem_g*DATA_WIDTH) +: DATA_WIDTH] :
            gamma_beat_r[(elem_g*DATA_WIDTH) +: DATA_WIDTH];

        floatMult16 u_scale_mul1 (
            .floatA(scale_mul0_w[elem_g]),
            .floatB(gamma_mul_w[elem_g]),
            .product(scale_mul1_w[elem_g])
        );
    end
endgenerate

assign beat_sum_w[0] = 16'h0000;

generate
    for (elem_g = 0; elem_g < ELEMS_PER_BEAT; elem_g = elem_g + 1) begin : gen_rms_sum
        floatAdd16 u_beat_add (
            .floatA(beat_sum_w[elem_g]),
            .floatB(x_square_w[elem_g]),
            .sum(beat_sum_w[elem_g + 1])
        );
    end
endgenerate

floatAdd16 u_add_sumsq (
    .floatA(sumsq_r),
    .floatB(beat_sum_w[ELEMS_PER_BEAT]),
    .sum(sumsq_next_w)
);

always_comb begin
    sram_rd_valid = 1'b0;
    sram_rd_addr = {ADDR_W{1'b0}};
    sram_wr_valid = 1'b0;
    sram_wr_addr = {ADDR_W{1'b0}};
    sram_wr_data = write_beat_r;

    case (state_r)
        ST_X_REQ: begin
            sram_rd_valid = 1'b1;
            sram_rd_addr = x_addr_r + addr_from_u16(beat_idx_r);
        end
        ST_G_REQ: begin
            sram_rd_valid = 1'b1;
            sram_rd_addr = gamma_addr_r + addr_from_u16(beat_idx_r);
        end
        ST_G_WRITE: begin
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
        gamma_addr_r <= {ADDR_W{1'b0}};
        result_addr_r <= {ADDR_W{1'b0}};
        req_id_r <= {REQ_ID_W{1'b0}};
        beat_idx_r <= 16'd0;
        x_mem_r <= {(VECTOR_LEN*DATA_WIDTH){1'b0}};
        gamma_beat_r <= {DATA_BUS_W{1'b0}};
        write_beat_r <= {DATA_BUS_W{1'b0}};
        sumsq_r <= 16'h0000;
        inv_rms_r <= 16'h3c00;
        inv_start_r <= 1'b0;
        x_req_accepted_r <= 1'b0;
        g_req_accepted_r <= 1'b0;
        result_status_r <= {RESULT_STATUS_W{1'b0}};
    end else begin
        inv_start_r <= 1'b0;

        case (state_r)
            ST_IDLE: begin
                if (issue_valid) begin
                    x_addr_r <= issue_x_addr;
                    gamma_addr_r <= issue_gamma_addr;
                    result_addr_r <= issue_result_addr;
                    req_id_r <= issue_req_id;
                    beat_idx_r <= 16'd0;
                    sumsq_r <= 16'h0000;
                    inv_rms_r <= 16'h3c00;
                    write_beat_r <= {DATA_BUS_W{1'b0}};
                    result_status_r <= RESULT_STATUS_OK;
                    x_req_accepted_r <= 1'b0;
                    g_req_accepted_r <= 1'b0;
                    state_r <= ST_X_REQ;
                end
            end

            ST_X_REQ: begin
                if ((x_req_accepted_r || (sram_rd_valid && sram_rd_ready)) &&
                    sram_resp_valid && sram_resp_ready) begin
                    x_mem_r[(beat_idx_r*DATA_BUS_W) +: DATA_BUS_W] <= sram_resp_data;
                    sumsq_r <= sumsq_next_w;
                    x_req_accepted_r <= 1'b0;
                    if (beat_idx_r == (VECTOR_BEATS - 1)) begin
                        state_r <= ST_X_DRAIN;
                    end else begin
                        beat_idx_r <= beat_idx_r + 16'd1;
                        state_r <= ST_X_DRAIN;
                    end
                end else if (sram_rd_valid && sram_rd_ready) begin
                    x_req_accepted_r <= 1'b1;
                    state_r <= ST_X_RESP;
                end
            end

            ST_X_RESP: begin
                if (sram_resp_valid && sram_resp_ready) begin
                    x_mem_r[(beat_idx_r*DATA_BUS_W) +: DATA_BUS_W] <= sram_resp_data;
                    sumsq_r <= sumsq_next_w;
                    x_req_accepted_r <= 1'b0;
                    if (beat_idx_r == (VECTOR_BEATS - 1)) begin
                        state_r <= ST_X_DRAIN;
                    end else begin
                        beat_idx_r <= beat_idx_r + 16'd1;
                        state_r <= ST_X_DRAIN;
                    end
                end
            end

            ST_X_DRAIN: begin
                if (!(sram_resp_valid && sram_resp_ready)) begin
                    if (beat_idx_r == (VECTOR_BEATS - 1))
                        state_r <= ST_INV_START;
                    else
                        state_r <= ST_X_REQ;
                end
            end

            ST_INV_START: begin
                inv_start_r <= 1'b1;
                x_req_accepted_r <= 1'b0;
                g_req_accepted_r <= 1'b0;
                state_r <= ST_INV_WAIT;
            end

            ST_INV_WAIT: begin
                if (inv_done_w) begin
                    inv_rms_r <= inv_result_w;
                    beat_idx_r <= 16'd0;
                    g_req_accepted_r <= 1'b0;
                    state_r <= ST_G_REQ;
                end
            end

            ST_G_REQ: begin
                if ((g_req_accepted_r || (sram_rd_valid && sram_rd_ready)) &&
                    sram_resp_valid && sram_resp_ready) begin
                    gamma_beat_r <= sram_resp_data;
                    for (elem_idx_i = 0; elem_idx_i < ELEMS_PER_BEAT; elem_idx_i = elem_idx_i + 1) begin
                        write_beat_r[(elem_idx_i*DATA_WIDTH) +: DATA_WIDTH] <= scale_mul1_w[elem_idx_i];
                    end
                    g_req_accepted_r <= 1'b0;
                    state_r <= ST_G_DRAIN;
                end else if (sram_rd_valid && sram_rd_ready) begin
                    g_req_accepted_r <= 1'b1;
                    state_r <= ST_G_RESP;
                end
            end

            ST_G_RESP: begin
                if (sram_resp_valid && sram_resp_ready) begin
                    gamma_beat_r <= sram_resp_data;
                    for (elem_idx_i = 0; elem_idx_i < ELEMS_PER_BEAT; elem_idx_i = elem_idx_i + 1) begin
                        write_beat_r[(elem_idx_i*DATA_WIDTH) +: DATA_WIDTH] <= scale_mul1_w[elem_idx_i];
                    end
                    g_req_accepted_r <= 1'b0;
                    state_r <= ST_G_DRAIN;
                end
            end

            ST_G_DRAIN: begin
                if (!(sram_resp_valid && sram_resp_ready)) begin
                    state_r <= ST_G_WRITE;
                end
            end

            ST_G_WRITE: begin
                if (sram_wr_valid && sram_wr_ready) begin
                    if (beat_idx_r == (VECTOR_BEATS - 1)) begin
                        g_req_accepted_r <= 1'b0;
                        state_r <= ST_HOLD;
                    end else begin
                        beat_idx_r <= beat_idx_r + 16'd1;
                        g_req_accepted_r <= 1'b0;
                        state_r <= ST_G_REQ;
                    end
                end
            end

            ST_HOLD: begin
                if (result_valid && result_ready) begin
                    x_req_accepted_r <= 1'b0;
                    g_req_accepted_r <= 1'b0;
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
