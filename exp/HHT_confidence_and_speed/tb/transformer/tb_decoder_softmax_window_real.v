`timescale 1ns/1ps

module tb_decoder_softmax_window_real;

localparam integer DATA_WIDTH = 16;
localparam integer WINDOW_SLOTS = 2;
localparam [DATA_WIDTH-1:0] FP_ONE = 16'h3c00;

reg clk;
reg rst_n;
reg start_valid;
wire start_ready;
reg [WINDOW_SLOTS*DATA_WIDTH-1:0] score_vector;
wire weight_valid;
wire [WINDOW_SLOTS*DATA_WIDTH-1:0] weight_vector;

integer cycle_count;

decoderSoftmaxWindow #(
    .DATA_WIDTH(DATA_WIDTH),
    .WINDOW_SLOTS(WINDOW_SLOTS)
) u_decoder_softmax_window (
    .clk(clk),
    .rst_n(rst_n),
    .start_valid(start_valid),
    .start_ready(start_ready),
    .score_vector(score_vector),
    .weight_valid(weight_valid),
    .weight_vector(weight_vector)
);

always #5 clk = ~clk;

initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    start_valid = 1'b0;
    score_vector = {(WINDOW_SLOTS*DATA_WIDTH){1'b0}};

    repeat (2) @(posedge clk);
    rst_n = 1'b1;

    @(posedge clk);
    if (!start_ready) begin
        $fatal(1, "softmax window should be ready after reset");
    end

    score_vector[0 +: DATA_WIDTH] = 16'h0000;
    score_vector[DATA_WIDTH +: DATA_WIDTH] = 16'h0000;
    start_valid = 1'b1;

    @(posedge clk);
    start_valid = 1'b0;

    cycle_count = 0;
    while (!weight_valid && (cycle_count < 128)) begin
        @(posedge clk);
        cycle_count = cycle_count + 1;
    end

    if (!weight_valid) begin
        $fatal(1, "softmax window did not finish");
    end

    #1;
    if (weight_vector[0 +: DATA_WIDTH] == {DATA_WIDTH{1'b0}}) begin
        $fatal(1, "softmax slot0 should not be zero");
    end
    if (weight_vector[DATA_WIDTH +: DATA_WIDTH] == {DATA_WIDTH{1'b0}}) begin
        $fatal(1, "softmax slot1 should not be zero");
    end
    if (weight_vector[0 +: DATA_WIDTH] != weight_vector[DATA_WIDTH +: DATA_WIDTH]) begin
        $fatal(1, "equal scores should produce equal weights");
    end
    if (weight_vector[0 +: DATA_WIDTH] == FP_ONE) begin
        $fatal(1, "multi-slot softmax should not degenerate to fixed 1.0");
    end

    $display("tb_decoder_softmax_window_real PASS");
    $finish;
end

endmodule
