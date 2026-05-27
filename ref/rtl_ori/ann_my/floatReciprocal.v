// -----------------------------------------------------------------------------
// Copyright (c) 2014-2023 All rights reserved
// -----------------------------------------------------------------------------
// File   : floatReciprocal.v
// Create : 2023-12-10 16:28:35
// Revise : 2026-04-28
// Description : 1/X divider
// -----------------------------------------------------------------------------
module floatReciprocal(number,enable,clk,output_rec,ack);

parameter DATA_WIDTH=32;
localparam EXP_WIDTH=(DATA_WIDTH==32) ? 8 : 5;
localparam MAN_WIDTH=(DATA_WIDTH==32) ? 23 : 10;
localparam [DATA_WIDTH-1:0] P1=(DATA_WIDTH==32) ? 32'h4034B4B5 : 16'h410F; // 43/17
localparam [DATA_WIDTH-1:0] P2=(DATA_WIDTH==32) ? 32'hBFF0F0F1 : 16'hBF88; // -32/17
localparam [DATA_WIDTH-1:0] FLOAT_ONE=(DATA_WIDTH==32) ? 32'h3F800000 : 16'h3C00;
localparam [EXP_WIDTH-1:0] DDASH_EXP=(DATA_WIDTH==32) ? 8'd126 : 5'd14;
localparam [EXP_WIDTH-1:0] RECIP_EXP_CONST=(DATA_WIDTH==32) ? 8'hFD : 5'h1D;

input [DATA_WIDTH-1:0] number; // the number that we need to get the 1/number of
input clk,enable;
output reg [DATA_WIDTH-1:0] output_rec; // = 1/number
output reg ack;

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

endmodule
