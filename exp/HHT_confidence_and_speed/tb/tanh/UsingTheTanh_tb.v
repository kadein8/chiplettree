// -----------------------------------------------------------------------------
// Copyright (c) 2014-2023 All rights reserved
// -----------------------------------------------------------------------------
// File   : UsingTheTanh_tb.v
// Create : 2023-11-26 13:39:46
// Revise : 2023-11-26 13:39:46
// Editor : tanh ACT tb 
// -----------------------------------------------------------------------------
module UsingTheTanh_tb ();

reg clk, resetExternal;
reg [31:0]x;
wire [31:0]Output;
wire FinishedTanh;

localparam PERIOD = 100;

always
	#(PERIOD/2) clk = ~clk;

initial begin
	#0 //starting the tanh 
	clk = 1'b1;
	resetExternal = 1'b1;
	// trying a random input(0.6,3)     where tanh(0.600000023842)=0.53704958, tanh(3)~=1
	x=32'b0011_1000_1100_1101_0100_0010_0000_0000;  //38CD 4200

	#(PERIOD/2)
	resetExternal = 1'b0;	
	
	#800
	// waiting for The final output which will be (0.57,1)
	if(Output==32'b0011_1000_0100_1100_0011_1100_0000_0000 && FinishedTanh==1'b1)begin //384C 3C00
	 $display("Result is right (for the full array of inputs)");	  
	  end
	  else begin 
	 $display("Result is Wrong");	 
	    end	 
	$stop;
end

UsingTheTanh #(.nofinputs(2))
UUT(
    .x(x),
	.clk(clk),
	.Output(Output),
	.resetExternal(resetExternal),	
	.FinishedTanh(FinishedTanh)	
);

endmodule



