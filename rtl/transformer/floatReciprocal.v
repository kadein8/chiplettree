`ifndef TRANSFORMER_FLOAT_RECIPROCAL_V
`define TRANSFORMER_FLOAT_RECIPROCAL_V
// -----------------------------------------------------------------------------
// Copyright (c) 2014-2023 All rights reserved
// -----------------------------------------------------------------------------
// File   : floatReciprocal.v
// Create : 2023-12-10 16:28:35
// Revise : 2026-05-10
// Description : 1/X divider
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
module floatReciprocal(number,enable,clk,output_rec,ack);

parameter DATA_WIDTH=32;
localparam integer ITER_MAX=12;
localparam integer EXP_WIDTH=(DATA_WIDTH==32) ? 8 : 5;
localparam integer MAN_WIDTH=(DATA_WIDTH==32) ? 23 : 10;
localparam [DATA_WIDTH-1:0] P1=(DATA_WIDTH==32) ? 32'h4034B4B5 : 16'h410F; // 43/17
localparam [DATA_WIDTH-1:0] P2=(DATA_WIDTH==32) ? 32'hBFF0F0F1 : 16'hBF88; // -32/17
localparam [DATA_WIDTH-1:0] FLOAT_ONE=(DATA_WIDTH==32) ? 32'h3F800000 : 16'h3C00;
localparam [EXP_WIDTH-1:0] DDASH_EXP=(DATA_WIDTH==32) ? 8'd126 : 5'd14;
localparam [EXP_WIDTH-1:0] RECIP_EXP_CONST=(DATA_WIDTH==32) ? 8'hFD : 5'h1D;
localparam [EXP_WIDTH-1:0] EXP_INF=(DATA_WIDTH==32) ? 8'hFF : 5'h1F;
localparam integer SIM_LATENCY=3;

input [DATA_WIDTH-1:0] number; // the number that we need to get the 1/number of
input clk,enable;
output reg [DATA_WIDTH-1:0] output_rec; // = 1/number
output reg ack;

`ifdef SYNTHESIS
wire [DATA_WIDTH-1:0] Ddash; // D' = mantissa of D and exponent of -1
wire [DATA_WIDTH-1:0] P2Ddash; // (-32/17) * D'
wire [DATA_WIDTH-1:0] Xi; // X[i]= 43/17 - (32/17)D'
wire [DATA_WIDTH-1:0] Xip1; // X[i+1]
wire [DATA_WIDTH-1:0] out0; // Xi*D
wire [DATA_WIDTH-1:0] out1; // 1-Xi*D
wire [DATA_WIDTH-1:0] out2; // X*(1-Xi*D)
reg [DATA_WIDTH-1:0] mux;

assign Ddash={1'b0,DDASH_EXP,number[MAN_WIDTH-1:0]};

generate
    if (DATA_WIDTH == 32) begin : reciprocal_fp32
        floatMult FM1 (P2,Ddash,P2Ddash); // -(32/17)*D'
        floatAdd FADD1 (P2Ddash,P1,Xi); // 43/17 + (-(32/17)D')
        floatMult FM2 (mux,Ddash,out0); // Xi*D'
        floatAdd FSUB1 (FLOAT_ONE,{1'b1,out0[DATA_WIDTH-2:0]},out1); // 1-Xi*D
        floatMult FM3 (mux,out1,out2); // X*(1-Xi*D)
        floatAdd FADD2 (mux,out2,Xip1); // Xi+Xi*(1-D*Xi)
    end
    else begin : reciprocal_fp16
        floatMult16 FM1 (P2,Ddash,P2Ddash);
        floatAdd16 FADD1 (P2Ddash,P1,Xi);
        floatMult16 FM2 (mux,Ddash,out0);
        floatAdd16 FSUB1 (FLOAT_ONE,{1'b1,out0[DATA_WIDTH-2:0]},out1);
        floatMult16 FM3 (mux,out1,out2);
        floatAdd16 FADD2 (mux,out2,Xip1);
    end
endgenerate

always @ (negedge clk) begin
    if (enable==1'b0) begin
        mux=Xi;
        ack=1'b0;
    end
    else begin
        if(mux==Xip1) begin
            ack=1'b1; // set ack bit to show that the division is done
            output_rec={number[DATA_WIDTH-1],RECIP_EXP_CONST-number[MAN_WIDTH+EXP_WIDTH-1:MAN_WIDTH],Xip1[MAN_WIDTH-1:0]};
        end
        else begin
            mux=Xip1; // continue until ack is 1
        end
    end
end
`else
reg [DATA_WIDTH-1:0] number_r;
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
        end else if (exp_v == EXP_INF) begin
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
    real man_real;
    integer man_floor;
    real frac_part;
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
                    real_to_fp16 = 16'h0000;
                end else begin
                    // Round to nearest even
                    man_real = (norm_v - 1.0) * (2.0 ** MAN_WIDTH);
                    man_floor = $rtoi(man_real);
                    if (man_floor > man_real) man_floor = man_floor - 1; // floor
                    frac_part = man_real - man_floor;
                    if (frac_part > 0.5)
                        man_floor = man_floor + 1;
                    else if (frac_part == 0.5) begin
                        if (man_floor[0] == 1'b1) // odd -> round up to even
                            man_floor = man_floor + 1;
                    end
                    if (man_floor == (1 << MAN_WIDTH)) begin
                        man_floor = 0;
                        exp_v = exp_v + 1;
                    end
                    biased_exp_v = exp_v + 15;
                    if (biased_exp_v >= 31)
                        real_to_fp16 = {sign_v[0], EXP_INF, {MAN_WIDTH{1'b0}}};
                    else
                        real_to_fp16 = {sign_v[0], biased_exp_v[EXP_WIDTH-1:0], man_floor[MAN_WIDTH-1:0]};
                end
            end
        end
    end
endfunction

function [DATA_WIDTH-1:0] compute_recip_bits;
    input [DATA_WIDTH-1:0] in_bits;
    real in_real;
    real out_real;
    begin
        if (DATA_WIDTH == 32) begin
            in_real = bits_to_real32(in_bits);
            if (in_real == 0.0)
                compute_recip_bits = {in_bits[31], EXP_INF, {MAN_WIDTH{1'b0}}};
            else begin
                out_real = 1.0 / in_real;
                compute_recip_bits = real_to_bits32(out_real);
            end
        end else begin
            in_real = fp16_to_real(in_bits[15:0]);
            if (in_real == 0.0)
                compute_recip_bits = {in_bits[15], EXP_INF, {MAN_WIDTH{1'b0}}};
            else begin
                out_real = 1.0 / in_real;
                compute_recip_bits = real_to_fp16(out_real);
            end
        end
    end
endfunction

always @ (negedge clk) begin
    if (enable == 1'b0) begin
        number_r <= {DATA_WIDTH{1'b0}};
        cycle_count_r <= {$clog2(SIM_LATENCY+1){1'b0}};
        busy_r <= 1'b0;
        output_rec <= {DATA_WIDTH{1'b0}};
        ack <= 1'b0;
    end else begin
        ack <= 1'b0;
        if (!busy_r) begin
            busy_r <= 1'b1;
            number_r <= number;
            cycle_count_r <= 1;
        end else if (cycle_count_r == SIM_LATENCY) begin
            output_rec <= compute_recip_bits(number_r);
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
