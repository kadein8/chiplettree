// -----------------------------------------------------------------------------
// Copyright (c) 2014-2023 All rights reserved
// -----------------------------------------------------------------------------
// File   : convLayerMulti.v
// Create : 2023-12-04 21:30:58
// Revise : 2023-12-04 21:30:58
// Description : conv multi layer
// -----------------------------------------------------------------------------

`timescale 100 ns / 10 ps

module convLayerMulti(clk,reset,start,image,filters,outputConv,done);

parameter DATA_WIDTH = 16;
parameter D = 1; //Depth of image and filter
parameter H = 32; //Height of image
parameter W = 32; //Width of image
parameter F = 5; //Size of filter
parameter K = 6; //Number of filters applied
localparam FILTER_WIDTH = D*F*F*DATA_WIDTH;
localparam FILTER_PAIR_WIDTH = 2*FILTER_WIDTH;
localparam FILTERS_TOTAL_WIDTH = K*D*F*F*DATA_WIDTH;
localparam SINGLE_LAYER_WIDTH = (H-F+1)*(W-F+1)*DATA_WIDTH;
localparam OUTPUT_SINGLES_WIDTH = 2*SINGLE_LAYER_WIDTH;
localparam OUTPUT_TOTAL_WIDTH = K*(H-F+1)*(W-F+1)*DATA_WIDTH;

input clk, reset,start;
input [0:D*H*W*DATA_WIDTH-1] image;
input [0:K*D*F*F*DATA_WIDTH-1] filters;
output reg [0:K*(H-F+1)*(W-F+1)*DATA_WIDTH-1] outputConv;
output reg done;

reg [0:2*D*F*F*DATA_WIDTH-1] inputFilters;
wire [0:2*(H-F+1)*(W-F+1)*DATA_WIDTH-1] outputSingleLayers;
wire layerEnable;
reg internalReset;
reg started;

integer filterSet, counter, outputCounter;

assign layerEnable = (start || started) && (done == 1'b0) && (filterSet < K/2);

genvar i;

generate
    for (i = 0; i < 2; i = i + 1) begin
        convLayerSingle #(
          .DATA_WIDTH(DATA_WIDTH),
          .D(D),
          .H(H),
          .W(W),
          .F(F)
        ) UUT
        (
            .clk(clk),
            .reset(internalReset),
            .enable(layerEnable),
            .image(image),
            .filter(inputFilters[i*D*F*F*DATA_WIDTH+:D*F*F*DATA_WIDTH]),
            .outputConv(outputSingleLayers[i*(H-F+1)*(W-F+1)*DATA_WIDTH+:(H-F+1)*(W-F+1)*DATA_WIDTH])
        );
    end
endgenerate

always @ (posedge clk or posedge reset) begin
    if (reset == 1'b1) begin
        internalReset = 1'b1;
        filterSet = 0;
        counter = 0;
        outputCounter = 0;
        done = 0;
        started = 1'b0;
    end
    else begin
        if (start == 1'b1) begin
            started = 1'b1;
        end
        if (((start != 0) || (started != 0)) && (filterSet < K/2)) begin
            if (counter == ((((H-F+1)*(W-F+1))/((H-F+1)/2))*(D*F*F+3)+1)) begin
                outputCounter = outputCounter + 1;
                counter = 0;
                internalReset = 1'b1;
                filterSet = filterSet + 1;
            end else begin
                internalReset = 0;
                counter = counter + 1;
            end
        end
        else if (((start != 0) || (started != 0)) && (done == 1'b0)) begin
            done = 1'b1;
            internalReset = 1'b0;
        end
    end
end

always @ (*) begin
    inputFilters = filters[filterSet*2*D*F*F*DATA_WIDTH+:2*D*F*F*DATA_WIDTH];
    outputConv[outputCounter*2*(H-F+1)*(W-F+1)*DATA_WIDTH+:2*(H-F+1)*(W-F+1)*DATA_WIDTH] = outputSingleLayers;
end

endmodule
