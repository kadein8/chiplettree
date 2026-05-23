// -----------------------------------------------------------------------------
// Copyright (c) 2014-2023 All rights reserved
// -----------------------------------------------------------------------------
// File   : processingElement.v
// Create : 2023-12-10 16:36:54
// Revise : 2023-12-10 16:36:54
// Description : PE Part 
// -----------------------------------------------------------------------------
module processingElement(clk,reset,floatA,floatB,result);

parameter DATA_WIDTH = 32;

input clk, reset;
input [DATA_WIDTH-1:0] floatA, floatB;
output reg [DATA_WIDTH-1:0] result;

wire [DATA_WIDTH-1:0] multResult;
wire [DATA_WIDTH-1:0] addResult;

floatMult FM (floatA,floatB,multResult);
floatAdd FADD (multResult,result,addResult);

always @ (posedge clk or posedge reset) begin
	if (reset == 1'b1) begin
		result = 0;
	end else begin
		result = addResult;
	end
end

endmodule
