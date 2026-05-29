// -----------------------------------------------------------------------------
// Copyright (c) 2014-2023 All rights reserved
// -----------------------------------------------------------------------------
// File   : HyperbolicTangent_tb.v
// Create : 2023-11-26 13:40:09
// Revise : 2023-11-26 13:40:09
// Editor : tanh convergence region check tb(fp16 style)
// -----------------------------------------------------------------------------
module HyperBolicTangent_tb ();

reg clk, reset;
reg [15:0]x;
wire [15:0]OutputFinal;
wire Finished;

localparam PERIOD = 100;

always
	#(PERIOD/2) clk = ~clk;

initial begin
	#0 //starting the tanh 
	clk = 1'b1;
	reset = 1'b1;
	// trying a random input(0.600000023842)     where tanh(0.600000023842)=0.53704958
	x=16'b0011_1000_1100_1101;

	#(PERIOD/2)
	reset = 0;	
	
	#400
	// waiting for 4 clock cycles then checking the output with approx.(0.53710)
	if(OutputFinal==16'b0011_1000_0100_1100 && Finished==1'b1)begin 
	 $display("Result is Right [Not in convergence region]");	  
	end
	else begin 
	 $display("Result is Wrong");	 
	end	 
	//trying another input which will be in the convergence region(3)  the output will be converged to 1    and reseting the function again
	x=16'b0100_0010_0000_0000;
	    
	reset = 1'b1;
	#(PERIOD/2)
	reset=1'b0;
	#200
	// checking if the output is 1
	if(OutputFinal==16'b0011_1100_0000_0000)begin 
	        $display("Result is Right [ convergence region]");	  
	end
	else begin 
	        $display("Result is Wrong ");	 
	end	
	$stop;
end

HyperBolicTangent UUT
(
  .x(x),
	.clk(clk),
	.reset(reset),
	.OutputFinal(OutputFinal),
	.Finished(Finished)	
);

endmodule

