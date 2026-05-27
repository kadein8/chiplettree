`timescale 1ns/1ps

module transformUnit1x1 (
    clk,
    reset,
    enable,
    input_vector,
    weight_vector,
    result,
    valid
);

parameter DATA_WIDTH = 16;
parameter CHANNELS = 16;

input clk;
input reset;
input enable;
input [0:(CHANNELS*DATA_WIDTH)-1] input_vector;
input [0:(CHANNELS*DATA_WIDTH)-1] weight_vector;
output [DATA_WIDTH-1:0] result;
output reg valid;

reg [DATA_WIDTH-1:0] selected_input_r;
reg [DATA_WIDTH-1:0] selected_weight_r;
integer channel_idx_r;

processingElement16 #(
    .DATA_WIDTH(DATA_WIDTH)
) u_processing_element16 (
    .clk(clk),
    .reset(reset),
    .enable(enable),
    .floatA(selected_input_r),
    .floatB(selected_weight_r),
    .result(result)
);

always @(posedge clk or posedge reset) begin
    if (reset == 1'b1) begin
        channel_idx_r = 0;
        selected_input_r = {DATA_WIDTH{1'b0}};
        selected_weight_r = {DATA_WIDTH{1'b0}};
        valid = 1'b0;
    end else if (enable == 1'b1) begin
        if (channel_idx_r < CHANNELS) begin
            selected_input_r =
                input_vector[(channel_idx_r*DATA_WIDTH) +: DATA_WIDTH];
            selected_weight_r =
                weight_vector[(channel_idx_r*DATA_WIDTH) +: DATA_WIDTH];
            valid = 1'b0;
            channel_idx_r = channel_idx_r + 1;
        end else if (channel_idx_r == CHANNELS) begin
            selected_input_r = {DATA_WIDTH{1'b0}};
            selected_weight_r = {DATA_WIDTH{1'b0}};
            valid = 1'b0;
            channel_idx_r = channel_idx_r + 1;
        end else begin
            selected_input_r = {DATA_WIDTH{1'b0}};
            selected_weight_r = {DATA_WIDTH{1'b0}};
            valid = 1'b1;
        end
    end
end

endmodule
