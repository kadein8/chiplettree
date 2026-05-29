`include "config/interface_params.vh"
`include "config/memory_params.vh"
`include "config/model_params.vh"
`timescale 1ns/1ps

module tb_fp16_silu;

localparam integer DATA_WIDTH = `FP16_TILE_DATA_W;
localparam integer DATA_BUS_W = `SRAM_WDATA_W;
localparam integer ELEMS_PER_BEAT = DATA_BUS_W / DATA_WIDTH;
localparam integer MAX_WAIT_CYCLES = 2048;
localparam [15:0] FP_ZERO = 16'h0000;
localparam [15:0] FP_HALF = 16'h3800;
localparam [15:0] FP_ONE  = 16'h3c00;
localparam [15:0] FP_NEG_ONE = 16'hbc00;
localparam [15:0] FP_FIVE = 16'h4500;
localparam [15:0] FP_NEG_FIVE = 16'hc500;
localparam [15:0] FP_TEN = 16'h4900;

logic clk;
logic rst_n;
logic start_valid;
logic start_ready;
logic [DATA_BUS_W-1:0] x_beat;
logic result_valid;
logic [DATA_BUS_W-1:0] result_beat;

integer elem_idx_i;
integer wait_cycles_i;

fp16_silu u_dut (
    .clk(clk),
    .rst_n(rst_n),
    .start_valid(start_valid),
    .start_ready(start_ready),
    .x_beat(x_beat),
    .result_valid(result_valid),
    .result_beat(result_beat)
);

always #5 clk = ~clk;

function automatic [DATA_BUS_W-1:0] fill_beat;
    input [15:0] value_fp16;
    integer idx_i;
    begin
        fill_beat = {DATA_BUS_W{1'b0}};
        for (idx_i = 0; idx_i < ELEMS_PER_BEAT; idx_i = idx_i + 1)
            fill_beat[(idx_i*DATA_WIDTH) +: DATA_WIDTH] = value_fp16;
    end
endfunction

function automatic bit fp16_close;
    input [15:0] actual;
    input [15:0] expected;
    input integer ulp_tol;
    integer diff_v;
    begin
        if (actual == expected) begin
            fp16_close = 1'b1;
        end else if (actual[15] != expected[15]) begin
            fp16_close = 1'b0;
        end else begin
            diff_v = (actual[14:0] > expected[14:0]) ?
                     (actual[14:0] - expected[14:0]) :
                     (expected[14:0] - actual[14:0]);
            fp16_close = (diff_v <= ulp_tol);
        end
    end
endfunction

task automatic run_case;
    input [15:0] input_value;
    input [15:0] expected_value;
    input [255:0] case_name;
    begin
        wait (start_ready);
        @(negedge clk);
        x_beat = fill_beat(input_value);
        start_valid = 1'b1;
        @(negedge clk);
        start_valid = 1'b0;

        wait_cycles_i = 0;
        while (!result_valid && (wait_cycles_i < MAX_WAIT_CYCLES)) begin
            @(posedge clk);
            wait_cycles_i = wait_cycles_i + 1;
        end

        if (!result_valid)
            $fatal(1, "SiLU timeout case=%0s", case_name);

        @(posedge clk);

        for (elem_idx_i = 0; elem_idx_i < ELEMS_PER_BEAT; elem_idx_i = elem_idx_i + 1) begin
            if (!fp16_close(result_beat[(elem_idx_i*DATA_WIDTH) +: DATA_WIDTH], expected_value, 4)) begin
                $fatal(1, "SiLU mismatch case=%0s elem=%0d actual=%h expected=%h",
                       case_name,
                       elem_idx_i,
                       result_beat[(elem_idx_i*DATA_WIDTH) +: DATA_WIDTH],
                       expected_value);
            end
        end
    end
endtask

initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    start_valid = 1'b0;
    x_beat = {DATA_BUS_W{1'b0}};

    repeat (3) @(posedge clk);
    rst_n = 1'b1;

    run_case(FP_ZERO, 16'h0000, "silu(0.0)");
    run_case(FP_ONE, 16'h39d9, "silu(1.0)");
    run_case(FP_HALF, 16'h34fb, "silu(0.5)");
    run_case(FP_NEG_ONE, 16'hb44e, "silu(-1.0)");
    run_case(FP_FIVE, 16'h44f7, "silu(5.0)");
    run_case(FP_NEG_FIVE, 16'ha849, "silu(-5.0)");
    run_case(FP_TEN, 16'h4900, "silu(10.0)");

    $display("tb_fp16_silu PASS");
    $finish;
end

endmodule
