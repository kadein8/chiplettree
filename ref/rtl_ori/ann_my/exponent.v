// -----------------------------------------------------------------------------
// Copyright (c) 2014-2023 All rights reserved
// -----------------------------------------------------------------------------
// File   : exponent.v
// Create : 2023-12-04 22:08:54
// Revise : 2026-04-28
// Description : exponent
// -----------------------------------------------------------------------------
module exponent (x,clk,enable,output_exp,ack);
parameter DATA_WIDTH=32;
localparam taylor_iter=7;
input [DATA_WIDTH-1:0] x;
input clk;
input enable;
output reg ack;
output reg [DATA_WIDTH-1:0] output_exp;

reg [DATA_WIDTH*taylor_iter-1:0] divisors; // 1/6 1/5 1/4 1/3 1/2 1 1
reg [DATA_WIDTH-1:0] mult1; // is 1 in the first cycle and then the output of the second multiplication in the rest
reg [DATA_WIDTH-1:0] one_or_x; // one in the first cycle and then x for the rest
wire [DATA_WIDTH-1:0] out_m1; // output of the first multiplication which is either with 1 or x
wire [DATA_WIDTH-1:0] out_m2; // the output of the second multiplication and the input of the first
wire [DATA_WIDTH-1:0] output_add1;
reg [DATA_WIDTH-1:0] out_reg; // the output of the addition each cycle

localparam [DATA_WIDTH-1:0] FLOAT_ONE = (DATA_WIDTH == 32) ? 32'h3F800000 : 16'h3C00;
localparam [DATA_WIDTH-1:0] FLOAT_ZERO = {DATA_WIDTH{1'b0}};

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
        if(divisors=={(DATA_WIDTH*taylor_iter){1'b0}})
        begin
            output_exp=output_add1;
            ack=1'b1;
        end
    end
end

endmodule
