`include "config/interface_params.vh"
`include "config/model_params.vh"
`timescale 1ns/1ps

module fp16_silu #(
    parameter integer DATA_WIDTH = `FP16_TILE_DATA_W,
    parameter integer DATA_BUS_W = `SRAM_WDATA_W
) (
    input  logic                  clk,
    input  logic                  rst_n,
    input  logic                  start_valid,
    output logic                  start_ready,
    input  logic [DATA_BUS_W-1:0] x_beat,
    output logic                  result_valid,
    output logic [DATA_BUS_W-1:0] result_beat
);

localparam integer ELEMS_PER_BEAT = DATA_BUS_W / DATA_WIDTH;
localparam logic [2:0]
    ST_IDLE  = 3'd0,
    ST_NEG   = 3'd1,
    ST_EXP   = 3'd2,
    ST_ADD   = 3'd3,
    ST_RECIP = 3'd4,
    ST_MUL   = 3'd5,
    ST_HOLD  = 3'd6;
localparam logic [DATA_WIDTH-1:0] FP_ZERO = 16'h0000;
localparam logic [DATA_WIDTH-1:0] FP_ONE = 16'h3c00;

function automatic [DATA_WIDTH-1:0] fp16_neg;
    input [DATA_WIDTH-1:0] value;
    begin
        if (value == FP_ZERO)
            fp16_neg = FP_ZERO;
        else
            fp16_neg = {~value[DATA_WIDTH-1], value[DATA_WIDTH-2:0]};
    end
endfunction

logic [2:0] state_r;
logic [2:0] elem_idx_r;
logic [DATA_BUS_W-1:0] x_beat_r;
logic [DATA_BUS_W-1:0] result_beat_r;
logic [DATA_WIDTH-1:0] x_elem_r;
logic [DATA_WIDTH-1:0] neg_x_r;
logic [DATA_WIDTH-1:0] exp_result_r;
logic [DATA_WIDTH-1:0] one_plus_exp_r;
logic [DATA_WIDTH-1:0] sigmoid_r;
logic [DATA_WIDTH-1:0] one_plus_exp_w;
logic [DATA_WIDTH-1:0] silu_elem_w;
logic [DATA_WIDTH-1:0] exp_result_w;
logic [DATA_WIDTH-1:0] recip_result_w;
logic exp_ack_w;
logic recip_ack_w;

assign start_ready = (state_r == ST_IDLE);
assign result_valid = (state_r == ST_HOLD);
assign result_beat = result_beat_r;

exponent #(
    .DATA_WIDTH(DATA_WIDTH)
) u_exp (
    .x(neg_x_r),
    .clk(clk),
    .enable(state_r == ST_EXP),
    .output_exp(exp_result_w),
    .ack(exp_ack_w)
);

floatAdd16 u_add_one (
    .floatA(exp_result_r),
    .floatB(FP_ONE),
    .sum(one_plus_exp_w)
);

floatReciprocal #(
    .DATA_WIDTH(DATA_WIDTH)
) u_recip (
    .number(one_plus_exp_r),
    .enable(state_r == ST_RECIP),
    .clk(clk),
    .output_rec(recip_result_w),
    .ack(recip_ack_w)
);

floatMult16 u_mul_silu (
    .floatA(x_elem_r),
    .floatB(sigmoid_r),
    .product(silu_elem_w)
);

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state_r <= ST_IDLE;
        elem_idx_r <= 3'd0;
        x_beat_r <= {DATA_BUS_W{1'b0}};
        result_beat_r <= {DATA_BUS_W{1'b0}};
        x_elem_r <= FP_ZERO;
        neg_x_r <= FP_ZERO;
        exp_result_r <= FP_ZERO;
        one_plus_exp_r <= FP_ZERO;
        sigmoid_r <= FP_ZERO;
    end else begin
        case (state_r)
            ST_IDLE: begin
                if (start_valid) begin
                    x_beat_r <= x_beat;
                    result_beat_r <= {DATA_BUS_W{1'b0}};
                    elem_idx_r <= 3'd0;
                    state_r <= ST_NEG;
                end
            end

            ST_NEG: begin
                x_elem_r <= x_beat_r[(elem_idx_r*DATA_WIDTH) +: DATA_WIDTH];
                neg_x_r <= fp16_neg(x_beat_r[(elem_idx_r*DATA_WIDTH) +: DATA_WIDTH]);
                state_r <= ST_EXP;
            end

            ST_EXP: begin
                if (exp_ack_w) begin
                    exp_result_r <= exp_result_w;
                    state_r <= ST_ADD;
                end
            end

            ST_ADD: begin
                one_plus_exp_r <= one_plus_exp_w;
                state_r <= ST_RECIP;
            end

            ST_RECIP: begin
                if (recip_ack_w) begin
                    sigmoid_r <= recip_result_w;
                    state_r <= ST_MUL;
                end
            end

            ST_MUL: begin
                result_beat_r[(elem_idx_r*DATA_WIDTH) +: DATA_WIDTH] <= silu_elem_w;
                if (elem_idx_r == (ELEMS_PER_BEAT - 1)) begin
                    state_r <= ST_HOLD;
                end else begin
                    elem_idx_r <= elem_idx_r + 3'd1;
                    state_r <= ST_NEG;
                end
            end

            ST_HOLD: begin
                state_r <= ST_IDLE;
            end

            default: state_r <= ST_IDLE;
        endcase
    end
end

endmodule
