module CNN_top(clk, reset, image, Conv1F, Conv2F, Conv3F, CNNoutput);

parameter DATA_WIDTH = 16;
parameter ImgInW     = 32;
parameter ImgInH     = 32;
parameter Kernel     = 5;
parameter DepthC1    = 6;
parameter DepthC2    = 16;
parameter DepthC3    = 120;
parameter FC_2_out   = 10;

localparam IMAGE_WIDTH   = ImgInW*ImgInH*DATA_WIDTH;
localparam CONV1F_WIDTH  = Kernel*Kernel*DepthC1*DATA_WIDTH;
localparam CONV2F_WIDTH  = DepthC2*Kernel*Kernel*DepthC1*DATA_WIDTH;
localparam CONV3F_WIDTH  = DepthC3*Kernel*Kernel*DepthC2*DATA_WIDTH;
localparam CONVOUT_WIDTH = DepthC3*DATA_WIDTH;
localparam FCOUT_WIDTH   = FC_2_out*DATA_WIDTH;

input clk;
input reset;
input  [0:IMAGE_WIDTH-1]  image;
input  [0:CONV1F_WIDTH-1] Conv1F;
input  [0:CONV2F_WIDTH-1] Conv2F;
input  [0:CONV3F_WIDTH-1] Conv3F;
output [0:FCOUT_WIDTH-1]  CNNoutput;

wire [0:CONVOUT_WIDTH-1] ConvOutput;
wire convflag;

IntegrationConvPart #(
    .DATA_WIDTH(DATA_WIDTH),
    .ImgInW(ImgInW),
    .ImgInH(ImgInH),
    .Kernel(Kernel),
    .DepthC1(DepthC1),
    .DepthC2(DepthC2),
    .DepthC3(DepthC3)
) ConvPart (
    .clk(clk),
    .reset(reset),
    .CNNinput(image),
    .Conv1F(Conv1F),
    .Conv2F(Conv2F),
    .Conv3F(Conv3F),
    .iConvOutput(ConvOutput),
    .convflag(convflag) // You can connect this to an LED or a testbench signal to monitor when convolution is done
);

integrationFC #(
    .DATA_WIDTH(DATA_WIDTH),
    .IntIn(DepthC3),
    .FC_2_out(FC_2_out)
) FCPart (
    .clk(clk),
    .reset(reset),
    .FCstart(convflag), // Start FC part when convolution is done
    .iFCinput(ConvOutput),
    .CNNoutput(CNNoutput)
);

endmodule
