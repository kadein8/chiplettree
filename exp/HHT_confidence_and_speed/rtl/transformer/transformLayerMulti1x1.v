`timescale 1ns/1ps

module transformLayerMulti1x1 (
    clk,
    reset,
    enable,
    input_vectors,
    weights,
    output_vectors,
    output_valid
);

parameter DATA_WIDTH = 16;
parameter INPUT_CHANNELS = 16;
parameter OUTPUT_UNITS = 4;
parameter BRANCH_SLOTS = 4;

input clk;
input reset;
input enable;
input [0:(BRANCH_SLOTS*INPUT_CHANNELS*DATA_WIDTH)-1] input_vectors;
input [0:(OUTPUT_UNITS*INPUT_CHANNELS*DATA_WIDTH)-1] weights;
output [0:(BRANCH_SLOTS*OUTPUT_UNITS*DATA_WIDTH)-1] output_vectors;
output output_valid;

wire [0:(BRANCH_SLOTS*OUTPUT_UNITS*DATA_WIDTH)-1] single_outputs_w;
wire [BRANCH_SLOTS-1:0] single_valid_w;

assign output_valid = &single_valid_w;
assign output_vectors = single_outputs_w;

genvar branch_idx;
generate
    for (branch_idx = 0; branch_idx < BRANCH_SLOTS; branch_idx = branch_idx + 1) begin
        transformLayerSingle1x1 #(
            .DATA_WIDTH(DATA_WIDTH),
            .INPUT_CHANNELS(INPUT_CHANNELS),
            .OUTPUT_UNITS(OUTPUT_UNITS)
        ) u_transform_layer_single1x1 (
            .clk(clk),
            .reset(reset),
            .enable(enable),
            .input_vector(
                input_vectors[(branch_idx*INPUT_CHANNELS*DATA_WIDTH) +:
                              (INPUT_CHANNELS*DATA_WIDTH)]
            ),
            .weights(weights),
            .output_vector(
                single_outputs_w[(branch_idx*OUTPUT_UNITS*DATA_WIDTH) +:
                                 (OUTPUT_UNITS*DATA_WIDTH)]
            ),
            .output_valid(single_valid_w[branch_idx])
        );
    end
endgenerate

endmodule
