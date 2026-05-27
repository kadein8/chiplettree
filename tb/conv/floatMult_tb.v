// -----------------------------------------------------------------------------
// Copyright (c) 2014-2023 All rights reserved
// -----------------------------------------------------------------------------om
// File   : floatMult_TB.v
// Create : 2023-11-09 21:14:15
// Revise : 2023-11-09 21:14:15
// Design : 16bit floating point multiplier basic tb
// -----------------------------------------------------------------------------
`timescale 100 ns / 10 ps

module floatMult_tb ();

reg [15:0] floatA;
reg [15:0] floatB;
wire [15:0] product;

initial begin
	
	// 4 * 5
	#0
	floatA = 16'b0100010000000000;
	floatB = 16'b0100010100000000;

	// 0.0004125 * 0
	#10
	floatA = 16'b0000111011000010;
	floatB = 16'b0000000000000000;

	#10
	// -0.75 * 0.75
	floatA = 16'b1011101000000000;
	floatB = 16'b0011101000000000;

	#10
	//-0.375*-0.375
	floatA = 16'b1011011000000000;
	floatB = 16'b1011011000000000;	

    #10
	$stop;
end

floatMult FM
(
	.floatA(floatA),
	.floatB(floatB),
	.product(product)
);

endmodule
