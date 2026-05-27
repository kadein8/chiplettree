// -----------------------------------------------------------------------------
// Copyright (c) 2014-2023 All rights reserved
// -----------------------------------------------------------------------------
// File   : InegrationFCpart.v
// Create : 2023-12-10 16:32:08
// Revise : 2023-12-10 16:32:08
// Description : FC layer
// -----------------------------------------------------------------------------

module integrationFC (clk,reset,FCstart,iFCinput,CNNoutput);

parameter DATA_WIDTH = 16;
parameter IntIn = 120;
parameter FC_1_out = 84;
parameter FC_2_out = 10;

input clk, reset;
input FCstart;
input [0:IntIn*DATA_WIDTH-1] iFCinput;
output [0:FC_2_out*DATA_WIDTH-1] CNNoutput;

wire [0:FC_1_out*DATA_WIDTH-1] fc1Out;
wire [0:FC_1_out*DATA_WIDTH-1] fc1OutTanh;

wire [0:FC_2_out*DATA_WIDTH-1] fc2Out;
wire [0:FC_2_out*DATA_WIDTH-1] fc2OutSMax;

wire [0:DATA_WIDTH*FC_1_out-1] wFC1;
wire [0:DATA_WIDTH*FC_2_out-1] wFC2;

reg FC1reset;
reg FC2reset;
reg TanhReset;
wire TanhFlag;
reg SMaxEnable;
wire DoneFlag;

integer counter;
reg FCrun;
reg [7:0] address1;
reg [7:0] address2;
wire FC1enable;
wire FC2enable;
wire TanhStart;

assign FC1enable = FCrun && (counter > 0) &&
                   (counter < IntIn + 10);
assign FC2enable = FCrun &&
                   (counter > IntIn + 12 + FC_1_out*6) &&
                   (counter < IntIn + 12 + FC_1_out*6 + FC_1_out + 10);
assign TanhStart = FCrun &&
                   (counter > IntIn + 10) &&
                   (counter < IntIn + 12 + FC_1_out*6);

weightMemory 
#(.DATA_WIDTH(DATA_WIDTH),
  .INPUT_NODES(IntIn),
  .OUTPUT_NODES(FC_1_out),
  .file("/home/ICer/CNN_IC2024/weight/weightsdense_1_IEEE_fp16.txt"))
  W1(
    .clk(clk),
    .address(address1),
    .weights(wFC1)
    );
    
weightMemory 
#(.DATA_WIDTH(DATA_WIDTH),
  .INPUT_NODES(FC_1_out),
  .OUTPUT_NODES(FC_2_out),
  .file("/home/ICer/CNN_IC2024/weight/weightsdense_2_IEEE_fp16.txt"))
  W2(
    .clk(clk),
    .address(address2),
    .weights(wFC2)
    );  
    
layer
#(.DATA_WIDTH(DATA_WIDTH),
  .INPUT_NODES(IntIn),
  .OUTPUT_NODES(FC_1_out))
 FC1(
    .clk(clk),
    .reset(FC1reset || reset),
    .enable(FC1enable),
    .input_fc(iFCinput),
    .weights(wFC1),
    .output_fc(fc1Out)
    );

UsingTheTanh16
#(
  .DATA_WIDTH(DATA_WIDTH),
  .nofinputs(FC_1_out)
)
Tanh1(
      .x(fc1Out),
      .clk(clk),
      .start(TanhStart),
      .Output(fc1OutTanh),
      .resetExternal(TanhReset || reset),
      .FinishedTanh(TanhFlag)
      );

layer
#(.DATA_WIDTH(DATA_WIDTH),
  .INPUT_NODES(FC_1_out),
  .OUTPUT_NODES(FC_2_out))
 FC2(
    .clk(clk),
    .reset(FC2reset || reset),
    .enable(FC2enable),
    .input_fc(fc1OutTanh),
    .weights(wFC2),
    .output_fc(fc2Out)
    );
    
softmax
#(.DATA_WIDTH(DATA_WIDTH)) 
  SMax(
      .inputs(fc2Out),
      .clk(clk),
      .enable(SMaxEnable),
      .outputs(CNNoutput),
      .ackSoft(DoneFlag)
      );

always @(posedge clk or posedge reset) begin
  if (reset == 1'b1) begin
    FC1reset = 1'b1;
    FC2reset = 1'b1;
    TanhReset = 1'b1;
    SMaxEnable = 1'b0;
    counter = 0;
    FCrun = 1'b0;
    address1 = -1;
    address2 = -1;
  end
  else begin
    if (FCstart == 1'b1) begin
      FCrun = 1'b1;
    end
    if (FCrun == 1'b1) begin
      counter = counter + 1;
      if (counter > 0 && counter < IntIn + 10) begin
         FC1reset = 1'b0;
      end
      else if (counter > IntIn + 10 && counter < IntIn + 12 + FC_1_out*6) begin
         TanhReset = 1'b0;
         address2 = -3;
      end
      else if (counter > IntIn + 12 + FC_1_out*6 && counter < IntIn + 12 + FC_1_out*6 + FC_1_out + 10) begin
         FC2reset = 1'b0;
      end
      else if (counter > IntIn + 12 + FC_1_out*6 + FC_1_out + 10) begin
         SMaxEnable = 1'b1;
      end
      if (address1 != 8'hfe) begin
        address1 = address1 + 1;
      end
      else
        address1 = 8'hfe;
      address2 = address2 + 1;
    end
  end
end

endmodule  
