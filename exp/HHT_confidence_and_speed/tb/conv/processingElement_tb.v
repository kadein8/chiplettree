// -----------------------------------------------------------------------------
// Copyright (c) 2014-2023 All rights reserved
// -----------------------------------------------------------------------------
// File   : processingElement_TB.v
// Create : 2023-11-12 14:08:35
// Revise : 2023-11-12 14:08:35
// Design : Mac unit tb
// -----------------------------------------------------------------------------
`timescale 100 ns / 10 ps

module processingElement_tb();

reg clk,reset;
reg [15:0] floatA, floatB;
wire [15:0] result;

localparam PERIOD = 100;

always
	#(PERIOD/2) clk = ~clk;

initial begin
	#0
	clk = 1'b0;
	reset = 1;
	// A = 2 , B = 3
	floatA = 16'h4000;
	floatB = 16'h4200;

	#PERIOD
	reset = 0;
    #PERIOD
	// A = 3 , B = 3
	floatA = 16'h4200;
	floatB = 16'h4200;




	#(2*PERIOD)
	$stop;	
end

processingElement PE 
(
	.clk(clk),
	.reset(reset),
	.floatA(floatA),
	.floatB(floatB),
	.result(result)
);

endmodule
