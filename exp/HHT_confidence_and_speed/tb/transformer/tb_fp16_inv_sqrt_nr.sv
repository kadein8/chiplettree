`include "config/interface_params.vh"
`include "config/memory_params.vh"
`include "config/model_params.vh"
`timescale 1ns/1ps

module tb_fp16_inv_sqrt_nr;

localparam [15:0] FP_ZERO    = 16'h0000;
localparam [15:0] FP_QUARTER = 16'h3400;
localparam [15:0] FP_ONE     = 16'h3c00;
localparam [15:0] FP_TWO     = 16'h4000;
localparam [15:0] FP_FOUR    = 16'h4400;
localparam [15:0] FP_EIGHT   = 16'h4800;
localparam [15:0] FP_7P9766  = 16'h47fa;
localparam integer MAX_WAIT_CYCLES = 64;

logic clk;
logic rst_n;
logic start;
logic [15:0] value;
logic busy;
logic done;
logic [15:0] result;

integer wait_cycles_i;

fp16_inv_sqrt_nr u_dut (
    .clk(clk),
    .rst_n(rst_n),
    .start(start),
    .value(value),
    .busy(busy),
    .done(done),
    .result(result)
);

always #5 clk = ~clk;

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
    input [15:0] case_value;
    input [15:0] expected_value;
    input [255:0] case_name;
    begin
        wait (!busy);
        @(negedge clk);
        value = case_value;
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        wait_cycles_i = 0;
        while (!done && (wait_cycles_i < MAX_WAIT_CYCLES)) begin
            @(posedge clk);
            wait_cycles_i = wait_cycles_i + 1;
        end

        if (!done)
            $fatal(1, "inv_sqrt timeout case=%0s", case_name);
        if (!fp16_close(result, expected_value, 4))
            $fatal(1, "inv_sqrt mismatch case=%0s actual=%h expected=%h",
                   case_name, result, expected_value);
    end
endtask

initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    start = 1'b0;
    value = FP_ZERO;

    repeat (3) @(posedge clk);
    rst_n = 1'b1;

    run_case(FP_ONE, FP_ONE, "inv_sqrt(1.0)");
    run_case(FP_TWO, 16'h39a8, "inv_sqrt(2.0)");
    run_case(FP_FOUR, 16'h3800, "inv_sqrt(4.0)");
    run_case(FP_QUARTER, FP_TWO, "inv_sqrt(0.25)");
    run_case(FP_EIGHT, 16'h35a8, "inv_sqrt(8.0)");
    run_case(FP_7P9766, 16'h35aa, "inv_sqrt(7.9765625)");

    $display("tb_fp16_inv_sqrt_nr PASS");
    $finish;
end

endmodule
