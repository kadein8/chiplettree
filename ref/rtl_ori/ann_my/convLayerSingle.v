`timescale 100 ns / 10 ps

module convLayerSingle(clk,reset,enable,image,filter,outputConv);

parameter DATA_WIDTH = 16;
parameter D = 1; //Depth of the filter
parameter H = 32; //Height of the image
parameter W = 32; //Width of the image
parameter F = 5; //Size of the filter
localparam OUTPUT_UNIT_WIDTH = ((W-F+1)/2)*DATA_WIDTH;
localparam RECEPTIVE_WIDTH = ((W-F+1)/2)*D*F*F*DATA_WIDTH;
localparam FILTER_WIDTH = D*F*F*DATA_WIDTH;
localparam OUTPUT_TOTAL_WIDTH = (H-F+1)*(W-F+1)*DATA_WIDTH;
localparam OUTPUT_BLOCKS = OUTPUT_TOTAL_WIDTH/OUTPUT_UNIT_WIDTH;

input clk, reset, enable;
input [0:D*H*W*DATA_WIDTH-1] image;
input [0:D*F*F*DATA_WIDTH-1] filter;
output reg [0:(H-F+1)*(W-F+1)*DATA_WIDTH-1] outputConv; // output of the module

wire [0:((W-F+1)/2)*DATA_WIDTH-1] outputConvUnits; // output of the conv units and input to the row selector
wire [0:((H-F+1)/2)-1] convUnitValid;
wire outputValid;

reg internalReset;
wire [0:(((W-F+1)/2)*D*F*F*DATA_WIDTH)-1] receptiveField; // array of the matrices to be sent to conv units
reg [0:OUTPUT_UNIT_WIDTH-1] outputBlocks [0:OUTPUT_BLOCKS-1];
wire [0:OUTPUT_TOTAL_WIDTH-1] outputConvPacked;


integer outputCounter, clearIdx;
//outputCounter: index to map the output of the conv units to the output of the module

reg [5:0] rowNumber, column; 
//rowNumber: determines the row that is calculated by the conv units
//column: determines if we are calculating the first or the second 14 pixels of the output row

RFselector
#(
	.DATA_WIDTH(DATA_WIDTH),
	.D(D),
	.H(H),
	.W(W),
	.F(F)
) RF
(
	.image(image),
	.rowNumber(rowNumber),
	.column(column),
	.receptiveField(receptiveField)
);

assign outputValid = &convUnitValid;

genvar n, outputBlockIdx;

generate //generating n convolution units where n is half the number of pixels in one row of the output image
	for (n = 0; n < (H-F+1)/2; n = n + 1) begin 
		convUnit
		#(
			.DATA_WIDTH(DATA_WIDTH),
			.D(D),
			.F(F)
		) CU
		(
			.clk(clk),
			.reset(internalReset),
			.enable(enable),
			.image(receptiveField[n*D*F*F*DATA_WIDTH+:D*F*F*DATA_WIDTH]),
			.filter(filter),
			.result(outputConvUnits[n*DATA_WIDTH+:DATA_WIDTH]),
			.valid(convUnitValid[n])
		);
	end
endgenerate

generate
	for (outputBlockIdx = 0; outputBlockIdx < OUTPUT_BLOCKS; outputBlockIdx = outputBlockIdx + 1) begin
		assign outputConvPacked[outputBlockIdx*OUTPUT_UNIT_WIDTH+:OUTPUT_UNIT_WIDTH] = outputBlocks[outputBlockIdx];
	end
endgenerate

always @ (posedge clk or posedge reset) begin
	if (reset == 1'b1) begin
		internalReset = 1'b1;
		rowNumber = 0;
		column = 0;
		outputCounter = 0;
		for (clearIdx = 0; clearIdx < OUTPUT_BLOCKS; clearIdx = clearIdx + 1) begin
			outputBlocks[clearIdx] = {OUTPUT_UNIT_WIDTH{1'b0}};
		end
	end else if (enable == 1'b1 && rowNumber < H-F+1) begin
		if (outputValid == 1'b1) begin
			if (outputCounter < OUTPUT_BLOCKS) begin
				outputBlocks[outputCounter] = outputConvUnits;
			end
			outputCounter = outputCounter + 1;
			internalReset = 1'b1;
			if (column == 0) begin
				column = (H-F+1)/2;
			end else begin
				rowNumber = rowNumber + 1;
				column = 0;
			end
		end else begin
			internalReset = 0;
		end
	end
end

always @ (*) begin
	outputConv = outputConvPacked;
end

endmodule
