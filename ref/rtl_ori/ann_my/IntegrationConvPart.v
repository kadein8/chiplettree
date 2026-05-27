// -----------------------------------------------------------------------------
// Copyright (c) 2014-2023 All rights reserved
// -----------------------------------------------------------------------------
// File   : IntegrationConvPart.v
// Create : 2023-12-10 16:32:30
// Revise : 2023-12-10 16:32:30
// Description : ann conv
// -----------------------------------------------------------------------------

module IntegrationConvPart (clk,reset,CNNinput,Conv1F,Conv2F,Conv3F,iConvOutput,convflag);

parameter DATA_WIDTH = 16;
parameter ImgInW = 32;
parameter ImgInH = 32;
parameter Conv1Out = 28;
parameter AvgP1out = 14;
parameter Conv2Out = 10;
parameter Kernel = 5;
parameter AvgP2out = 5;
parameter Conv3Out = 1;
parameter DepthC1 = 6;
parameter DepthC2 = 16;
parameter DepthC3 = 120;

integer counter;

input clk, reset;
input [0:ImgInW*ImgInH*DATA_WIDTH-1] CNNinput;
input [0:Kernel*Kernel*DepthC1*DATA_WIDTH-1] Conv1F;
input [0:DepthC2*Kernel*Kernel*DepthC1*DATA_WIDTH-1] Conv2F;
input [0:DepthC3*Kernel*Kernel*DepthC2*DATA_WIDTH-1] Conv3F;
output [0:DepthC3*DATA_WIDTH-1] iConvOutput;
output reg convflag;

reg C1rst,C2rst,C3rst,AP1rst,AP2rst,Tanh1Reset,Tanh2Reset,Tanh3Reset;
wire C1start;
wire C1done,C2start,C2done,C3start,C3done,Tanh1Flag,Tanh2Flag,Tanh3Flag;
wire AP1start,AP1done,AP2start,AP2done;

wire [0:Conv1Out*Conv1Out*DepthC1*DATA_WIDTH-1] C1out;
wire [0:Conv1Out*Conv1Out*DepthC1*DATA_WIDTH-1] C1outTanH;

wire [0:AvgP1out*AvgP1out*DepthC1*DATA_WIDTH-1] AP1out;

wire [0:Conv2Out*Conv2Out*DepthC2*DATA_WIDTH-1] C2out;
wire [0:Conv2Out*Conv2Out*DepthC2*DATA_WIDTH-1] C2outTanH;

wire [0:AvgP2out*AvgP2out*DepthC2*DATA_WIDTH-1] AP2out;

wire [0:Conv3Out*Conv3Out*DepthC3*DATA_WIDTH-1] C3out;
assign C1start = 1'b1;

convLayerMulti
#(
  .DATA_WIDTH(DATA_WIDTH),
  .D(1),
  .H(ImgInH),
  .W(ImgInW),
  .F(Kernel),
  .K(DepthC1)
) C1
(
	.clk(clk),
	.reset(reset || C1rst),
  .start(C1start),
	.image(CNNinput),
	.filters(Conv1F),
	.outputConv(C1out),
  .done(C1done)
);

UsingTheTanh16
#(
  .DATA_WIDTH(DATA_WIDTH),
  .nofinputs(Conv1Out*Conv1Out*DepthC1)
)
Tanh1(
      .x(C1out),
      .clk(clk),
      .start(C1done),
      .Output(C1outTanH),
      .resetExternal(reset || Tanh1Reset),
      .FinishedTanh(Tanh1Flag)
      );

AvgPoolMulti
  #(
    .DATA_WIDTH(DATA_WIDTH),
    .D(DepthC1),
    .H(Conv1Out),
    .W(Conv1Out)
  ) AP1
  (
    .clk(clk),
    .reset(reset || AP1rst),  
    .start(Tanh1Flag),
    .apInput(C1outTanH),
    .apOutput(AP1out),
    .done(AP1done)
  );

convLayerMulti
#(
  .DATA_WIDTH(DATA_WIDTH),
  .D(DepthC1),
  .H(AvgP1out),
  .W(AvgP1out),
  .F(Kernel),
  .K(DepthC2)
) C2 
(
	.clk(clk),
	.reset(reset || C2rst),
  .start(AP1done),
	.image(AP1out),
	.filters(Conv2F),
	.outputConv(C2out),
  .done(C2done)
);

UsingTheTanh16
#(
  .DATA_WIDTH(DATA_WIDTH),
  .nofinputs(Conv2Out*Conv2Out*DepthC2)
)
Tanh2(
      .x(C2out),
      .clk(clk),
      .start(C2done),
      .Output(C2outTanH),
      .resetExternal(reset || Tanh2Reset),
      .FinishedTanh(Tanh2Flag)
      );

AvgPoolMulti 
  #(
  .DATA_WIDTH(DATA_WIDTH),
  .D(DepthC2),
  .H(Conv2Out),
  .W(Conv2Out)
  ) AP2
  (
    .clk(clk),
    .reset(reset || AP2rst),
    .start(Tanh2Flag),
    .apInput(C2outTanH),
    .apOutput(AP2out),
    .done(AP2done)
  );

convLayerMulti
#(
  .DATA_WIDTH(DATA_WIDTH),
  .D(DepthC2),
  .H(AvgP2out),
  .W(AvgP2out),
  .F(Kernel),
  .K(DepthC3)
) C3
(
	.clk(clk),
	.reset(reset || C3rst),
  .start(AP2done),
	.image(AP2out),
	.filters(Conv3F),
	.outputConv(C3out),
  .done(C3done)
);

UsingTheTanh16
#(
  .DATA_WIDTH(DATA_WIDTH),
  .nofinputs(Conv3Out*Conv3Out*DepthC3)
)
Tanh3(
      .x(C3out),
      .clk(clk),
      .start(C3done),
      .Output(iConvOutput),
      .resetExternal(reset || Tanh3Reset),
      .FinishedTanh(Tanh3Flag)
      );

always @(posedge clk or posedge reset) begin
  if (reset == 1'b1) begin
    C1rst = 1'b1;
    C2rst = 1'b1;
    C3rst = 1'b1;
    AP1rst = 1'b1;
    AP2rst = 1'b1;
    Tanh1Reset = 1'b1;
    Tanh2Reset = 1'b1;
    Tanh3Reset = 1'b1;
    convflag = 1'b0;
    counter = 0;
  end
  else begin
    counter = counter + 1;
    if (C1start == 1'b1) begin
       C1rst = 1'b0;
    end
    if (C1done == 1'b1) begin
       Tanh1Reset = 1'b0;
    end
    if (Tanh1Flag == 1'b1) begin
       AP1rst = 1'b0;
    end
    if (AP1done == 1'b1) begin
       C2rst = 1'b0;
    end 
    if (C2done == 1'b1) begin
      Tanh2Reset = 1'b0;
    end
    if (Tanh2Flag == 1'b1) begin
       AP2rst = 1'b0;
    end
    if (AP2done == 1'b1) begin
       C3rst = 1'b0;
    end   
    if (C3done == 1'b1) begin
       Tanh3Reset = 1'b0;
    end 
    if (Tanh3Flag == 1'b1) begin
       convflag = 1'b1;
    end
  end
// else begin
//   counter = counter + 1;
//   if (counter >= 0 && counter <= 7*1457) begin
//        C1rst = 1'b0;
//     end
//   else if (counter >= 7*1457 && counter <= 7*1457+6*784*6) begin
//        Tanh1Reset = 1'b0;
//     end
//   else if (counter >= 7*1457+6*784*6 && counter <= 7*1457+6*784*6+8) begin
//        AP1rst = 1'b0;
//     end
//   else if (counter >= 7*1457+6*784*6+8 && counter <= 7*1457+6*784*6+8+18*22*152) begin
//        C2rst = 1'b0;
//     end
//   else if (counter >= 7*1457+6*784*6+8+18*22*152 && counter <= 7*1457+6*784*6+8+18*22*152 + 6*1600) begin
//       Tanh2Reset = 1'b0;
//     end
//   else if (counter >= 7*1457+6*784*6+8+18*22*152 + 6*1600 && counter <= 7*1457+6*784*6+8+18*22*152 + 6*1600 + 20) begin
//        AP2rst = 1'b0;
//     end
//   else if (counter >= 7*1457+6*784*6+8+18*22*152 + 6*1600 + 20 && counter <= 7*1457+6*784*6+8+18*22*152 + 6*1600 + 20 + 30) begin
//        C3rst = 1'b0;
//     end
//   else begin
//        Tanh3Reset = 1'b0;
//        convflag = 1'b1;
//     end
//   end
end

endmodule
