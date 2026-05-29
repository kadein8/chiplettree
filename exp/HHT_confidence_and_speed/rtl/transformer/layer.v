// -----------------------------------------------------------------------------
// Copyright (c) 2014-2023 All rights reserved
// -----------------------------------------------------------------------------
// File   : layer.v
// Create : 2023-12-10 16:35:18
// Revise : 2023-12-10 16:35:18
// Description : layer basic build
// -----------------------------------------------------------------------------
module layer(clk,reset,enable,input_fc,weights,output_fc);

parameter DATA_WIDTH = 32;
parameter INPUT_NODES = 100;
parameter OUTPUT_NODES = 32;
localparam INPUT_WIDTH = DATA_WIDTH*INPUT_NODES;
localparam OUTPUT_WIDTH = DATA_WIDTH*OUTPUT_NODES;

input clk, reset, enable;
input [0:DATA_WIDTH*INPUT_NODES-1] input_fc;
input [0:DATA_WIDTH*OUTPUT_NODES-1] weights;
output [0:DATA_WIDTH*OUTPUT_NODES-1] output_fc;

reg [DATA_WIDTH-1:0] selectedInput;
integer j;

genvar i;

generate
	for (i = 0; i < OUTPUT_NODES; i = i + 1) begin
		processingElement16
		#(
			.DATA_WIDTH(DATA_WIDTH)
		) PE
		(
			.clk(clk),
			.reset(reset),
			.enable(enable),
			.floatA(selectedInput),
			.floatB(weights[DATA_WIDTH*i+:DATA_WIDTH]),
			.result(output_fc[DATA_WIDTH*i+:DATA_WIDTH])
		);
	end
endgenerate

always @ (posedge clk or posedge reset) begin
	if (reset == 1'b1) begin
		selectedInput = 0;
		j = INPUT_NODES - 1;
	end else if (enable == 1'b1 && j < 0) begin
		selectedInput = 0;
	end else if (enable == 1'b1) begin
		selectedInput = input_fc[DATA_WIDTH*j+:DATA_WIDTH];
		j = j - 1;
	end
end

endmodule
