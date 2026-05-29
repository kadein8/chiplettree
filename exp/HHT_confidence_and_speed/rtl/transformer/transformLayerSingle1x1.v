`timescale 1ns/1ps

module transformLayerSingle1x1 (
    clk,
    reset,
    enable,
    input_vector,
    weights,
    output_vector,
    output_valid
);

parameter DATA_WIDTH = 16;
parameter INPUT_CHANNELS = 16;
parameter OUTPUT_UNITS = 4;

input clk;
input reset;
input enable;
input [0:(INPUT_CHANNELS*DATA_WIDTH)-1] input_vector;
input [0:(OUTPUT_UNITS*INPUT_CHANNELS*DATA_WIDTH)-1] weights;
output [0:(OUTPUT_UNITS*DATA_WIDTH)-1] output_vector;
output output_valid;

wire [0:(OUTPUT_UNITS*DATA_WIDTH)-1] unit_results_w;
wire [OUTPUT_UNITS-1:0] unit_valid_w;

assign output_valid = &unit_valid_w;
assign output_vector = unit_results_w;

genvar unit_idx;
generate
    for (unit_idx = 0; unit_idx < OUTPUT_UNITS; unit_idx = unit_idx + 1) begin
        transformUnit1x1 #(
            .DATA_WIDTH(DATA_WIDTH),
            .CHANNELS(INPUT_CHANNELS)
        ) u_transform_unit1x1 (
            .clk(clk),
            .reset(reset),
            .enable(enable),
            .input_vector(input_vector),
            .weight_vector(
                weights[(unit_idx*INPUT_CHANNELS*DATA_WIDTH) +:
                        (INPUT_CHANNELS*DATA_WIDTH)]
            ),
            .result(
                unit_results_w[(unit_idx*DATA_WIDTH) +: DATA_WIDTH]
            ),
            .valid(unit_valid_w[unit_idx])
        );
    end
endgenerate

endmodule
