`include "config/interface_params.vh"
`include "config/memory_params.vh"
`include "config/model_params.vh"
`timescale 1ns/1ps

module tb_fp16_rope;

localparam integer DATA_WIDTH = `FP16_TILE_DATA_W;
localparam integer HEAD_DIM = 64;
localparam [15:0] FP_ZERO = 16'h0000;
localparam [15:0] FP_ONE = 16'h3c00;
// The current fp16_rope implementation uses a 1024-entry phase LUT, so the
// expected values for non-zero positions are LUT-quantized rather than exact
// math-library cos/sin outputs.
localparam [15:0] FP_COS_PAIR1_POS1 = 16'h3a65;
localparam [15:0] FP_SIN_PAIR1_POS1 = 16'h38ce;

logic clk;
logic rst_n;
logic start_valid;
logic start_ready;
logic [15:0] position;
logic [(HEAD_DIM*DATA_WIDTH)-1:0] head_vector;
logic rotated_valid;
logic [(HEAD_DIM*DATA_WIDTH)-1:0] rotated_vector;

integer elem_idx_i;

fp16_rope #(
    .DATA_WIDTH(DATA_WIDTH),
    .HEAD_DIM(HEAD_DIM),
    .PARALLEL_PAIRS(8)
) u_dut (
    .clk(clk),
    .rst_n(rst_n),
    .start_valid(start_valid),
    .start_ready(start_ready),
    .position(position),
    .head_vector(head_vector),
    .rotated_valid(rotated_valid),
    .rotated_vector(rotated_vector)
);

always #5 clk = ~clk;

task automatic drive_once;
    input [15:0] test_position;
    begin
        wait (start_ready);
        @(negedge clk);
        position = test_position;
        start_valid = 1'b1;
        @(negedge clk);
        start_valid = 1'b0;
        wait (rotated_valid);
        @(posedge clk);
    end
endtask

initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    start_valid = 1'b0;
    position = 16'd0;
    head_vector = {(HEAD_DIM*DATA_WIDTH){1'b0}};

    repeat (3) @(posedge clk);
    rst_n = 1'b1;

    for (elem_idx_i = 0; elem_idx_i < HEAD_DIM; elem_idx_i = elem_idx_i + 1)
        head_vector[(elem_idx_i*DATA_WIDTH) +: DATA_WIDTH] = FP_ONE;
    drive_once(16'd0);
    if (rotated_vector !== head_vector)
        $fatal(1, "RoPE position 0 all-one should be identity");

    for (elem_idx_i = 0; elem_idx_i < HEAD_DIM; elem_idx_i = elem_idx_i + 1) begin
        head_vector[(elem_idx_i*DATA_WIDTH) +: DATA_WIDTH] =
            elem_idx_i[0] ? FP_ZERO : FP_ONE;
    end
    drive_once(16'd0);
    if (rotated_vector !== head_vector)
        $fatal(1, "RoPE position 0 alternating input should be identity");

    for (elem_idx_i = 0; elem_idx_i < HEAD_DIM; elem_idx_i = elem_idx_i + 1)
        head_vector[(elem_idx_i*DATA_WIDTH) +: DATA_WIDTH] = FP_ONE;
    drive_once(16'd1);
    if (rotated_vector === head_vector)
        $fatal(1, "RoPE position 1 should not remain identical");

    head_vector = {(HEAD_DIM*DATA_WIDTH){1'b0}};
    head_vector[(2*DATA_WIDTH) +: DATA_WIDTH] = FP_ONE;
    drive_once(16'd1);
    if (rotated_vector[(2*DATA_WIDTH) +: DATA_WIDTH] !== FP_COS_PAIR1_POS1)
        $fatal(1, "RoPE pair1 cos mismatch got=%h exp=%h",
               rotated_vector[(2*DATA_WIDTH) +: DATA_WIDTH], FP_COS_PAIR1_POS1);
    if (rotated_vector[(3*DATA_WIDTH) +: DATA_WIDTH] !== FP_SIN_PAIR1_POS1)
        $fatal(1, "RoPE pair1 sin mismatch got=%h exp=%h",
               rotated_vector[(3*DATA_WIDTH) +: DATA_WIDTH], FP_SIN_PAIR1_POS1);

    $display("tb_fp16_rope PASS");
    $finish;
end

endmodule
