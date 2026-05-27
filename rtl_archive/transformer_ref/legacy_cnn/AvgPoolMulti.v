// -----------------------------------------------------------------------------
// Copyright (c) 2014-2023 All rights reserved
// -----------------------------------------------------------------------------
// File   : AvgPoolMulti.v
// Create : 2023-12-04 21:07:57
// Revise : 2023-12-04 21:07:57
// Editor : avpool multi
// -----------------------------------------------------------------------------
`timescale 1 ns / 10 ps

module AvgPoolMulti(clk, reset, start,apInput, apOutput,done);

parameter DATA_WIDTH = 16;
parameter D = 6;
parameter H = 28;
parameter W = 28;
localparam INPUT_SLICE_WIDTH = H*W*DATA_WIDTH;
localparam OUTPUT_SLICE_WIDTH = (H/2)*(W/2)*DATA_WIDTH;
localparam INPUT_TOTAL_WIDTH = H*W*D*DATA_WIDTH;
localparam OUTPUT_TOTAL_WIDTH = (H/2)*(W/2)*D*DATA_WIDTH;

input reset,clk,start;
input [0:H*W*D*DATA_WIDTH-1] apInput;
output reg [0:(H/2)*(W/2)*D*DATA_WIDTH-1] apOutput;
output reg done;

reg [0:H*W*DATA_WIDTH-1] apInput_s;
wire [0:(H/2)*(W/2)*DATA_WIDTH-1] apOutput_s;
integer counter;
reg started;


avgPoolSingle
  #(
      .DATA_WIDTH(DATA_WIDTH),
      .InputH(H),
      .InputW(W)
  ) avgPool
  (
      .aPoolIn(apInput_s),
      .aPoolOut(apOutput_s)
  );


always @ (posedge clk or posedge reset) begin
  if (reset == 1'b1) begin
    counter = 0;
    done = 0;
    started = 1'b0;
  end
  else begin
    if (start == 1'b1) begin
      started = 1'b1;
    end
    if (((start != 0) || (started != 0)) && (done == 1'b0)) begin
      if (counter < D-1) begin
        counter = counter+1;
      end
      else begin
        done = 1;
      end
    end
  end
end

always @ (*) begin
  apInput_s = apInput[counter*H*W*DATA_WIDTH+:H*W*DATA_WIDTH];
  apOutput[counter*(H/2)*(W/2)*DATA_WIDTH+:(H/2)*(W/2)*DATA_WIDTH] = apOutput_s;
end

endmodule
