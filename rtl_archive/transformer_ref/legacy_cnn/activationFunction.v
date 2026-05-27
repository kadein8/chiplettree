// -----------------------------------------------------------------------------
// Copyright (c) 2014-2023 All rights reserved
// -----------------------------------------------------------------------------
// File   : activationFunction.v
// Create : 2023-12-04 21:03:22
// Revise : 2023-12-04 21:03:22
// Editor : relu act func
// -----------------------------------------------------------------------------
module activationFunction(clk,reset,en,input_fc,output_fc);

parameter DATA_WIDTH = 32;
parameter OUTPUT_NODES = 32;
localparam TOTAL_WIDTH = DATA_WIDTH*OUTPUT_NODES;

input clk, reset, en;
input [0:DATA_WIDTH*OUTPUT_NODES-1] input_fc;
output reg [0:DATA_WIDTH*OUTPUT_NODES-1] output_fc;

integer i;

always @ (negedge clk or posedge reset) begin
	if (reset == 1'b1) begin
		output_fc = 0;
	end else begin
		if (en == 1'b1) begin
			for (i = 0; i < OUTPUT_NODES; i = i + 1) begin
				if (input_fc[DATA_WIDTH*i-1+DATA_WIDTH] == 1'b1) begin
					output_fc[DATA_WIDTH*i+:DATA_WIDTH] = 0;
				end else begin
					output_fc[DATA_WIDTH*i+:DATA_WIDTH] = input_fc[DATA_WIDTH*i+:DATA_WIDTH];
				end
			end
		end
	end
end

endmodule
