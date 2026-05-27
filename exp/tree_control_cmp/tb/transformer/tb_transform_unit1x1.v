`timescale 1ns/1ps

module tb_transform_unit1x1;

localparam DATA_WIDTH = 16;
localparam CHANNELS = 1;

reg clk;
reg reset;
reg enable;
reg [0:(CHANNELS*DATA_WIDTH)-1] input_vector;
reg [0:(CHANNELS*DATA_WIDTH)-1] weight_vector;

wire [DATA_WIDTH-1:0] result;
wire valid;

transformUnit1x1 #(
    .DATA_WIDTH(DATA_WIDTH),
    .CHANNELS(CHANNELS)
) u_transform_unit1x1 (
    .clk(clk),
    .reset(reset),
    .enable(enable),
    .input_vector(input_vector),
    .weight_vector(weight_vector),
    .result(result),
    .valid(valid)
);

always #5 clk = ~clk;

initial begin
    clk = 1'b0;
    reset = 1'b1;
    enable = 1'b0;
    input_vector = {(CHANNELS*DATA_WIDTH){1'b0}};
    weight_vector = {(CHANNELS*DATA_WIDTH){1'b0}};

    repeat (2) @(posedge clk);
    reset = 1'b0;

    input_vector[0 +: DATA_WIDTH] = 16'h3c00;
    weight_vector[0 +: DATA_WIDTH] = 16'h3c00;
    enable = 1'b1;

    repeat (CHANNELS + 2) @(posedge clk);
    #1;
    if (valid !== 1'b1) begin
        $fatal(1, "transformUnit1x1 valid should assert after accumulation");
    end
    if (result !== 16'h3c00) begin
        $fatal(1, "transformUnit1x1 result mismatch");
    end

    $display("tb_transform_unit1x1 PASS");
    $finish;
end

endmodule
