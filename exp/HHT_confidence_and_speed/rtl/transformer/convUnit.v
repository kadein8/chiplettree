// -----------------------------------------------------------------------------
// Copyright (c) 2014-2023 All rights reserved
// -----------------------------------------------------------------------------
// File   : convUnit.v
// Create : 2023-12-04 22:08:14
// Revise : 2023-12-04 22:08:14
// Description : conv unit 
// -----------------------------------------------------------------------------
`timescale 100 ns / 10 ps

module convUnit(clk,reset,enable,image,filter,result,valid);

parameter DATA_WIDTH = 16;
parameter D = 1; //depth of the filter
parameter F = 5; //size of the filter
localparam INPUT_WIDTH = D*F*F*DATA_WIDTH;

input clk, reset, enable;
input [0:D*F*F*DATA_WIDTH-1] image, filter;
output [DATA_WIDTH-1:0] result;
output reg valid;

reg [DATA_WIDTH-1:0] selectedInput1, selectedInput2;

integer i;


processingElement16
	#(
		.DATA_WIDTH(DATA_WIDTH)
	) PE
	(
		.clk(clk),
		.reset(reset),
		.enable(enable),
		.floatA(selectedInput1),
		.floatB(selectedInput2),
		.result(result)
	);

// The convolution is calculated in a sequential process to save hardware
// The result of the element wise matrix multiplication is finished after (F*F+2) cycles (2 cycles to reset the processing element and F*F cycles to accumulate the result of the F*F multiplications) 
always @ (posedge clk, posedge reset) begin
	if (reset == 1'b1) begin // reset
		i = 0;
		selectedInput1 = 0;
		selectedInput2 = 0;
		valid = 1'b0;
	end else if (enable == 1'b1) begin
		if (i < D*F*F) begin // send one element of the image part and one element of the filter to be multiplied and accumulated
			selectedInput1 = image[DATA_WIDTH*i+:DATA_WIDTH];
			selectedInput2 = filter[DATA_WIDTH*i+:DATA_WIDTH];
			valid = 1'b0;
			i = i + 1;
		end else if (i == D*F*F) begin // wait one cycle for the final accumulated result to be registered
			selectedInput1 = 0;
			selectedInput2 = 0;
			valid = 1'b0;
			i = i + 1;
		end else begin // the convolution result is valid in this cycle and remains valid until reset
			selectedInput1 = 0;
			selectedInput2 = 0;
			valid = 1'b1;
		end
	end
end

endmodule
