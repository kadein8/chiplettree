`timescale 1ns/1ps

module fp16_matvec_tile_tb;

localparam integer LANES = 16;
localparam integer COLS = 128;
localparam integer DATA_WIDTH = 16;
localparam [DATA_WIDTH-1:0] FP_ZERO = 16'h0000;
localparam [DATA_WIDTH-1:0] FP_HALF = 16'h3800;
localparam [DATA_WIDTH-1:0] FP_ONE = 16'h3c00;
localparam [DATA_WIDTH-1:0] FP_TWO = 16'h4000;
localparam [DATA_WIDTH-1:0] FP_FOUR = 16'h4400;
localparam [DATA_WIDTH-1:0] FP_128 = 16'h5800;
localparam [DATA_WIDTH-1:0] FP_256 = 16'h5c00;
localparam [DATA_WIDTH-1:0] FP_512 = 16'h6000;
localparam [DATA_WIDTH-1:0] FP_64 = 16'h5400;

reg clk;
reg rst_n;
reg start;
reg [DATA_WIDTH-1:0] vector_val;
reg [(LANES*DATA_WIDTH)-1:0] weights;
wire busy;
wire done;
wire [(LANES*DATA_WIDTH)-1:0] result;
wire [6:0] col_idx;

integer cycle_count;
integer lane_idx_i;
reg done_seen_r;

fp16_matvec_tile #(
    .LANES(LANES),
    .COLS(COLS),
    .DATA_WIDTH(DATA_WIDTH)
) u_fp16_matvec_tile (
    .clk(clk),
    .rst_n(rst_n),
    .start(start),
    .vector_val(vector_val),
    .weights(weights),
    .busy(busy),
    .done(done),
    .result(result),
    .col_idx(col_idx)
);

always #5 clk = ~clk;

task load_all_weights;
    input [DATA_WIDTH-1:0] value;
    begin
        for (lane_idx_i = 0; lane_idx_i < LANES; lane_idx_i = lane_idx_i + 1) begin
            weights[(lane_idx_i*DATA_WIDTH) +: DATA_WIDTH] = value;
        end
    end
endtask

task expect_lane_value_all;
    input [DATA_WIDTH-1:0] value;
    begin
        for (lane_idx_i = 0; lane_idx_i < LANES; lane_idx_i = lane_idx_i + 1) begin
            if (result[(lane_idx_i*DATA_WIDTH) +: DATA_WIDTH] !== value) begin
                $fatal(1, "lane %0d result mismatch, actual=%h expected=%h",
                       lane_idx_i,
                       result[(lane_idx_i*DATA_WIDTH) +: DATA_WIDTH],
                       value);
            end
        end
    end
endtask

task pulse_start;
    begin
        @(negedge clk);
        start = 1'b1;
        @(posedge clk);
        #1;
        start = 1'b0;
        if (!busy) begin
            $fatal(1, "matvec tile did not accept start pulse");
        end
    end
endtask

task wait_for_done_or_timeout;
    begin
        done_seen_r = 1'b0;
        cycle_count = 0;

        fork : wait_done_group
            begin : wait_done_block
                while (done !== 1'b1) begin
                    @(posedge clk);
                    #1;
                    cycle_count = cycle_count + 1;
                end
                done_seen_r = 1'b1;
            end

            begin : timeout_block
                repeat (COLS + 8) @(posedge clk);
                #1;
            end
        join_any

        disable wait_done_group;
    end
endtask

task run_case_lane_pattern;
    begin
        vector_val = FP_ONE;
        weights = {
            FP_FOUR, FP_TWO, FP_ONE, FP_HALF,
            FP_FOUR, FP_TWO, FP_ONE, FP_HALF,
            FP_FOUR, FP_TWO, FP_ONE, FP_HALF,
            FP_FOUR, FP_TWO, FP_ONE, FP_ZERO
        };
        pulse_start();
        wait_for_done_or_timeout();

        if (!done_seen_r) begin
            $fatal(1, "matvec tile lane-pattern case did not finish");
        end
        #1;
        if (result[(0*DATA_WIDTH) +: DATA_WIDTH] !== FP_ZERO) begin
            $fatal(1, "lane 0 mismatch actual=%h expected=%h",
                   result[(0*DATA_WIDTH) +: DATA_WIDTH], FP_ZERO);
        end
        if (result[(1*DATA_WIDTH) +: DATA_WIDTH] !== FP_128) begin
            $fatal(1, "lane 1 mismatch actual=%h expected=%h",
                   result[(1*DATA_WIDTH) +: DATA_WIDTH], FP_128);
        end
        if (result[(2*DATA_WIDTH) +: DATA_WIDTH] !== FP_256) begin
            $fatal(1, "lane 2 mismatch actual=%h expected=%h",
                   result[(2*DATA_WIDTH) +: DATA_WIDTH], FP_256);
        end
        if (result[(3*DATA_WIDTH) +: DATA_WIDTH] !== FP_512) begin
            $fatal(1, "lane 3 mismatch actual=%h expected=%h",
                   result[(3*DATA_WIDTH) +: DATA_WIDTH], FP_512);
        end
        if (result[(4*DATA_WIDTH) +: DATA_WIDTH] !== FP_64) begin
            $fatal(1, "lane 4 mismatch actual=%h expected=%h",
                   result[(4*DATA_WIDTH) +: DATA_WIDTH], FP_64);
        end
        if (result[(5*DATA_WIDTH) +: DATA_WIDTH] !== FP_128) begin
            $fatal(1, "lane 5 mismatch actual=%h expected=%h",
                   result[(5*DATA_WIDTH) +: DATA_WIDTH], FP_128);
        end
        if (result[(6*DATA_WIDTH) +: DATA_WIDTH] !== FP_256) begin
            $fatal(1, "lane 6 mismatch actual=%h expected=%h",
                   result[(6*DATA_WIDTH) +: DATA_WIDTH], FP_256);
        end
        if (result[(7*DATA_WIDTH) +: DATA_WIDTH] !== FP_512) begin
            $fatal(1, "lane 7 mismatch actual=%h expected=%h",
                   result[(7*DATA_WIDTH) +: DATA_WIDTH], FP_512);
        end
    end
endtask

task run_case_all_constant;
    input [DATA_WIDTH-1:0] vector_value_i;
    input [DATA_WIDTH-1:0] weight_value_i;
    input [DATA_WIDTH-1:0] expected_value_i;
    begin
        vector_val = vector_value_i;
        load_all_weights(weight_value_i);
        pulse_start();
        wait_for_done_or_timeout();

        if (!done_seen_r) begin
            $fatal(1, "matvec tile did not finish");
        end
        if (busy) begin
            $fatal(1, "busy should drop in done cycle");
        end
        if (col_idx !== (COLS-1)) begin
            $fatal(1, "col_idx mismatch in done cycle actual=%0d expected=%0d",
                   col_idx, COLS-1);
        end
        #1;
        expect_lane_value_all(expected_value_i);

        @(posedge clk);
        #1;
        if (done) begin
            $fatal(1, "done should be a single-cycle pulse");
        end
    end
endtask

initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    start = 1'b0;
    vector_val = FP_ZERO;
    weights = {(LANES*DATA_WIDTH){1'b0}};
    done_seen_r = 1'b0;

    repeat (2) @(posedge clk);
    rst_n = 1'b1;

    run_case_all_constant(FP_ZERO, FP_ONE, FP_ZERO);
    run_case_all_constant(FP_ONE, FP_ONE, FP_128);
    run_case_all_constant(FP_ONE, FP_TWO, FP_256);
    run_case_lane_pattern();

    $display("fp16_matvec_tile_tb PASS");
    $finish;
end

endmodule
