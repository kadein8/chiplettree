// -----------------------------------------------------------------------------
// Copyright (c) 2014-2023 All rights reserved
// -----------------------------------------------------------------------------
// File   : floatAdd_tb.v
// Create : 2023-11-26 13:35:31
// Revise : 2023-11-26 13:35:31
// Editor : fp adder tb, same as MAC unit
// -----------------------------------------------------------------------------
`timescale 100 ns / 10 ps

module floatAdd_tb ();

reg [15:0] floatA;
reg [15:0] floatB;
wire [15:0] sum;

initial begin
	
	// 0.3 + 0.2
	#0
	floatA = 16'h34CD;
	floatB = 16'h3266;

	// 0.3 + 0
	#10
	floatA = 16'h34CD;
	floatB = 16'h0000;
    
    // -0.3 + 0.2
	#10
	floatA = 16'hB4CD;
	floatB = 16'h3266;

	// -0.3 + -0.2
	#10
	floatA = 16'hB4CD;
	floatB = 16'hB266;

	#10
	$stop;
end

floatAdd FADD
(
	.floatA(floatA),
	.floatB(floatB),
	.sum(sum)
);

endmodule
