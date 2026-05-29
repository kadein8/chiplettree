`ifndef TRANSFORMER_EXPONENT_V
`define TRANSFORMER_EXPONENT_V
// -----------------------------------------------------------------------------
// Copyright (c) 2014-2023 All rights reserved
// -----------------------------------------------------------------------------
// File   : exponent.v
// Create : 2023-12-04 22:08:54
// Revise : 2026-05-10
// Description : exponent
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
module exponent (x,clk,enable,output_exp,ack);
parameter DATA_WIDTH=32;
localparam integer TAYLOR_ITER=7;
localparam integer SIM_LATENCY=7;
localparam integer EXP_WIDTH=(DATA_WIDTH==32) ? 8 : 5;
localparam integer MAN_WIDTH=(DATA_WIDTH==32) ? 23 : 10;
localparam [DATA_WIDTH-1:0] FLOAT_ONE = (DATA_WIDTH == 32) ? 32'h3F800000 : 16'h3C00;
localparam [DATA_WIDTH-1:0] FLOAT_ZERO = {DATA_WIDTH{1'b0}};
localparam [EXP_WIDTH-1:0] EXP_INF = {EXP_WIDTH{1'b1}};

input [DATA_WIDTH-1:0] x;
input clk;
input enable;
output reg ack;
output reg [DATA_WIDTH-1:0] output_exp;

`ifdef SYNTHESIS
reg [DATA_WIDTH*TAYLOR_ITER-1:0] divisors; // 1/6 1/5 1/4 1/3 1/2 1 1
reg [DATA_WIDTH-1:0] mult1; // is 1 in the first cycle and then the output of the second multiplication in the rest
reg [DATA_WIDTH-1:0] one_or_x; // one in the first cycle and then x for the rest
wire [DATA_WIDTH-1:0] out_m1; // output of the first multiplication which is either with 1 or x
wire [DATA_WIDTH-1:0] out_m2; // the output of the second multiplication and the input of the first
wire [DATA_WIDTH-1:0] output_add1;
reg [DATA_WIDTH-1:0] out_reg; // the output of the addition each cycle

generate
    if (DATA_WIDTH == 32) begin : exponent_fp32
        floatMult FM1 (mult1,one_or_x,out_m1);
        floatMult FM2 (out_m1,divisors[DATA_WIDTH-1:0],out_m2);
        floatAdd FADD1 (out_m2,out_reg,output_add1);
    end
    else begin : exponent_fp16
        floatMult16 FM1 (mult1,one_or_x,out_m1);
        floatMult16 FM2 (out_m1,divisors[DATA_WIDTH-1:0],out_m2);
        floatAdd16 FADD1 (out_m2,out_reg,output_add1);
    end
endgenerate

always @ (posedge clk) begin
    if(enable==1'b0) begin
        one_or_x=FLOAT_ONE; // initially 1
        mult1=FLOAT_ONE; // initially 1
        out_reg=FLOAT_ZERO; // initially 0
        output_exp=FLOAT_ZERO; // output zero until ack is 1
        if (DATA_WIDTH == 32) begin
            divisors={32'h3E2AAAAB,32'h3E4CCCCD,32'h3E800000,32'h3EAAAAAB,32'h3F000000,32'h3F800000,32'h3F800000};
        end
        else begin
            divisors={16'h3155,16'h3266,16'h3400,16'h3555,16'h3800,16'h3C00,16'h3C00};
        end
        ack=1'b0; // acknowledge is 0 at the beginning
    end
    else begin
        one_or_x=x;
        mult1=out_m2; // get the output of the second multiplication to multiply with x
        divisors=divisors>>DATA_WIDTH; // shift by DATA_WIDTH to compute the next factorial term
        out_reg=output_add1;
        if(divisors=={(DATA_WIDTH*TAYLOR_ITER){1'b0}})
        begin
            output_exp=output_add1;
            ack=1'b1;
        end
    end
end
`else
reg [DATA_WIDTH-1:0] x_latched_r;
reg [$clog2(SIM_LATENCY+1)-1:0] cycle_count_r;
reg busy_r;

function real bits_to_real32;
    input [31:0] bits;
    begin
        bits_to_real32 = $bitstoshortreal(bits);
    end
endfunction

function [31:0] real_to_bits32;
    input real value;
    shortreal tmp;
    begin
        tmp = value;
        real_to_bits32 = $shortrealtobits(tmp);
    end
endfunction

function real fp16_to_real;
    input [15:0] bits;
    integer sign_v;
    integer exp_v;
    integer man_v;
    real frac_v;
    integer shift_v;
    begin
        sign_v = bits[15] ? -1 : 1;
        exp_v = bits[14:10];
        man_v = bits[9:0];
        if ((exp_v == 0) && (man_v == 0)) begin
            fp16_to_real = 0.0;
        end else if (exp_v == 0) begin
            frac_v = man_v;
            for (shift_v = 0; shift_v < MAN_WIDTH; shift_v = shift_v + 1)
                frac_v = frac_v / 2.0;
            fp16_to_real = sign_v * frac_v * (2.0 ** (-14));
        end else if (exp_v == 31) begin
            if (man_v == 0)
                fp16_to_real = sign_v * 1.0e30;
            else
                fp16_to_real = 0.0;
        end else begin
            frac_v = 1.0 + (man_v / (2.0 ** MAN_WIDTH));
            fp16_to_real = sign_v * frac_v * (2.0 ** (exp_v - 15));
        end
    end
endfunction

function [15:0] real_to_fp16;
    input real value;
    integer sign_v;
    real abs_v;
    integer exp_v;
    integer biased_exp_v;
    real norm_v;
    integer man_v;
    integer rounded_v;
    begin
        if (!(value < 0.0 || value >= 0.0)) begin
            real_to_fp16 = 16'h7e00;
        end else begin
            sign_v = (value < 0.0) ? 1 : 0;
            abs_v = sign_v ? -value : value;
            if (abs_v == 0.0) begin
                real_to_fp16 = 16'h0000;
            end else begin
                exp_v = 0;
                norm_v = abs_v;
                while (norm_v >= 2.0) begin
                    norm_v = norm_v / 2.0;
                    exp_v = exp_v + 1;
                end
                while (norm_v < 1.0) begin
                    norm_v = norm_v * 2.0;
                    exp_v = exp_v - 1;
                end

                if ((exp_v + 15) >= 31) begin
                    real_to_fp16 = {sign_v[0], EXP_INF, {MAN_WIDTH{1'b0}}};
                end else if ((exp_v + 15) <= 0) begin
                    norm_v = abs_v / (2.0 ** (-14));
                    rounded_v = $rtoi(norm_v * (2.0 ** MAN_WIDTH) + 0.5);
                    if (rounded_v <= 0)
                        real_to_fp16 = 16'h0000;
                    else if (rounded_v >= (1 << MAN_WIDTH))
                        real_to_fp16 = {sign_v[0], 5'd1, {MAN_WIDTH{1'b0}}};
                    else
                        real_to_fp16 = {sign_v[0], 5'd0, rounded_v[MAN_WIDTH-1:0]};
                end else begin
                    man_v = $rtoi((norm_v - 1.0) * (2.0 ** MAN_WIDTH) + 0.5);
                    if (man_v == (1 << MAN_WIDTH)) begin
                        man_v = 0;
                        exp_v = exp_v + 1;
                    end
                    biased_exp_v = exp_v + 15;
                    if (biased_exp_v >= 31)
                        real_to_fp16 = {sign_v[0], EXP_INF, {MAN_WIDTH{1'b0}}};
                    else
                        real_to_fp16 = {sign_v[0], biased_exp_v[EXP_WIDTH-1:0], man_v[MAN_WIDTH-1:0]};
                end
            end
        end
    end
endfunction

function [DATA_WIDTH-1:0] compute_exp_bits;
    input [DATA_WIDTH-1:0] in_bits;
    real in_real;
    real out_real;
    begin
        if (DATA_WIDTH == 32) begin
            in_real = bits_to_real32(in_bits);
            out_real = $exp(in_real);
            compute_exp_bits = real_to_bits32(out_real);
        end else begin
            in_real = fp16_to_real(in_bits[15:0]);
            out_real = $exp(in_real);
            compute_exp_bits = real_to_fp16(out_real);
        end
    end
endfunction

always @ (posedge clk) begin
    if (enable == 1'b0) begin
        x_latched_r <= {DATA_WIDTH{1'b0}};
        cycle_count_r <= {$clog2(SIM_LATENCY+1){1'b0}};
        busy_r <= 1'b0;
        output_exp <= FLOAT_ZERO;
        ack <= 1'b0;
    end else begin
        ack <= 1'b0;
        if (!busy_r) begin
            busy_r <= 1'b1;
            x_latched_r <= x;
            cycle_count_r <= 1;
        end else if (cycle_count_r == SIM_LATENCY) begin
            output_exp <= compute_exp_bits(x_latched_r);
            ack <= 1'b1;
            busy_r <= 1'b0;
            cycle_count_r <= {$clog2(SIM_LATENCY+1){1'b0}};
        end else begin
            cycle_count_r <= cycle_count_r + 1'b1;
        end
    end
end
`endif

endmodule
`endif
