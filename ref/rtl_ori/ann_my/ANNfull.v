// -----------------------------------------------------------------------------
// Copyright (c) 2014-2023 All rights reserved
// -----------------------------------------------------------------------------
// File   : ANNfull.v
// Create : 2023-12-04 21:07:05
// Revise : 2023-12-04 21:07:05
// Editor : ANN 
// -----------------------------------------------------------------------------
module ANNfull(clk,reset,input_ANN,output_ANN);

parameter DATA_WIDTH = 32;
parameter INPUT_NODES_L1 = 100; 
parameter INPUT_NODES_L2 = 32;
parameter INPUT_NODES_L3 = 10;
parameter OUTPUT_NODES = 4;

input clk, reset;
input [0:DATA_WIDTH*INPUT_NODES_L1-1] input_ANN;
output [0:DATA_WIDTH*OUTPUT_NODES-1] output_ANN;

reg rstLayer;
reg rstRelu;
reg enRelu;

reg [7:0] address;

wire [0:DATA_WIDTH*INPUT_NODES_L2-1] output_L1;
wire [0:DATA_WIDTH*INPUT_NODES_L2-1] output_L1_relu;

wire [0:DATA_WIDTH*INPUT_NODES_L3-1] output_L2;
wire [0:DATA_WIDTH*INPUT_NODES_L3-1] output_L2_relu;

wire [0:DATA_WIDTH*OUTPUT_NODES-1] output_L3;

wire [0:DATA_WIDTH*INPUT_NODES_L2-1] WL1;
wire [0:DATA_WIDTH*INPUT_NODES_L3-1] WL2;
wire [0:DATA_WIDTH*OUTPUT_NODES-1] WL3;

weightMemory 
#(.INPUT_NODES(INPUT_NODES_L1),
  .OUTPUT_NODES(INPUT_NODES_L2),
  .file("/home/Devane/CNN_IC2024/weight/weights1_IEEE.txt"))       //need change
  W1(
    .clk(clk),
    .address(address),
    .weights(WL1)
    );

weightMemory 
#(.INPUT_NODES(INPUT_NODES_L2),
  .OUTPUT_NODES(INPUT_NODES_L3),
  .file("/home/Devane/CNN_IC2024/weight/weights2_IEEE.txt"))       //need change
  W2(
    .clk(clk),
    .address(address),
    .weights(WL2)
    );

weightMemory 
#(.INPUT_NODES(INPUT_NODES_L3),
  .OUTPUT_NODES(OUTPUT_NODES),
  .file("/home/Devane/CNN_IC2024/weight/weights3_IEEE.txt"))       //need change
  W3(
    .clk(clk),
    .address(address),
    .weights(WL3)
    );

layer
#(.INPUT_NODES(INPUT_NODES_L1),
  .OUTPUT_NODES(INPUT_NODES_L2))
 L1(
    .clk(clk),
    .reset(rstLayer),
    .input_fc(input_ANN),
    .weights(WL1),
    .output_fc(output_L1)
    );

layer
#(.INPUT_NODES(INPUT_NODES_L2),
  .OUTPUT_NODES(INPUT_NODES_L3))
 L2(
    .clk(clk),
    .reset(rstLayer),
    .input_fc(output_L1_relu),
    .weights(WL2),
    .output_fc(output_L2)
    );

layer
#(.INPUT_NODES(INPUT_NODES_L3),
  .OUTPUT_NODES(OUTPUT_NODES))
 L3(
    .clk(clk),
    .reset(rstLayer),
    .input_fc(output_L2_relu),
    .weights(WL3),
    .output_fc(output_L3)
    );

activationFunction #(.OUTPUT_NODES(INPUT_NODES_L2)) relu_1
(
  .clk(clk),
  .reset(rstRelu),
  .en(enRelu),
  .input_fc(output_L1),
  .output_fc(output_L1_relu)
);

activationFunction #(.OUTPUT_NODES(INPUT_NODES_L3)) relu_2
(
  .clk(clk),
  .reset(rstRelu),
  .en(enRelu),
  .input_fc(output_L2),
  .output_fc(output_L2_relu)
);

activationFunction #(.OUTPUT_NODES(OUTPUT_NODES)) relu_3
(
  .clk(clk),
  .reset(rstRelu),
  .en(enRelu),
  .input_fc(output_L3),
  .output_fc(output_ANN)
);

always @(posedge clk or posedge reset) begin
  if (reset == 1'b1) begin
    rstRelu = 1'b1;
    rstLayer = 1'b1;
    address = -1;
    enRelu = 1'b0;
  end
  else begin
      rstRelu = 1'b0;
      rstLayer = 1'b0;
    if (address == INPUT_NODES_L1+1) begin
      address = address + 1;
      enRelu = 1'b1;
    end
    else if (address == INPUT_NODES_L1+2) begin
      address = -1;
      enRelu = 1'b0;
      rstLayer = 1'b1;
    end
    else begin
      address = address + 1;
    end
  end
end
 
endmodule     
