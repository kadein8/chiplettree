// -----------------------------------------------------------------------------
// Copyright (c) 2014-2023 All rights reserved
// -----------------------------------------------------------------------------
// Author : IC_Brother
// File   : processingElement16.v
// Create : 2023-12-10 16:38:13
// Revise : 2023-12-10 16:38:13
// Description : sublime text4, tab size (4)
// -----------------------------------------------------------------------------
`timescale 100 ns / 10 ps

module processingElement16(clk,reset,enable,floatA,floatB,result);

parameter DATA_WIDTH = 16;

input clk, reset, enable;
input [DATA_WIDTH-1:0] floatA, floatB;
output reg [DATA_WIDTH-1:0] result;

wire [DATA_WIDTH-1:0] multResult;
wire [DATA_WIDTH-1:0] addResult;

floatMult16 FM (floatA,floatB,multResult);
floatAdd16 FADD (multResult,result,addResult);

always @ (posedge clk or posedge reset) begin
	if (reset == 1'b1) begin
		result = 0;
	end else if (enable == 1'b1) begin
		result = addResult;
	end
end

endmodule
