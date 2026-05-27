// -----------------------------------------------------------------------------
// Copyright (c) 2014-2023 All rights reserved
// -----------------------------------------------------------------------------
// File   : AvgPoolSingle.v
// Create : 2023-12-04 21:15:44
// Revise : 2023-12-04 21:15:44
// Editor : av pool single
// -----------------------------------------------------------------------------
`timescale 1 ns / 10 ps

module avgPoolSingle(aPoolIn,aPoolOut);
  
parameter DATA_WIDTH = 16;
parameter InputH = 28;
parameter InputW = 28;
parameter Depth = 1;
localparam INPUT_TOTAL_WIDTH = InputH*InputW*Depth*DATA_WIDTH;
localparam OUTPUT_TOTAL_WIDTH = (InputH/2)*(InputW/2)*Depth*DATA_WIDTH;

input [0:InputH*InputW*Depth*DATA_WIDTH-1] aPoolIn;
output [0:(InputH/2)*(InputW/2)*Depth*DATA_WIDTH-1] aPoolOut;

genvar i,j;

generate 
  for (i=0; i<(InputH); i=i+2) begin
    for (j=0; j<(InputW); j=j+2) begin
    AvgUnit
    #(
     .DATA_WIDTH(DATA_WIDTH)
     )
     AU
    (
      .numA(aPoolIn[(i*InputH+j)*DATA_WIDTH+:DATA_WIDTH]),
      .numB(aPoolIn[(i*InputH+j+1)*DATA_WIDTH+:DATA_WIDTH]),
      .numC(aPoolIn[((i+1)*InputH+j)*DATA_WIDTH+:DATA_WIDTH]),
      .numD(aPoolIn[((i+1)*InputH+j+1)*DATA_WIDTH+:DATA_WIDTH]),
      .AvgOut(aPoolOut[(i/2*InputH/2+j/2)*DATA_WIDTH+:DATA_WIDTH])
      );
    end
  end
endgenerate

endmodule
