`timescale 1ns/1ps

module fp16_matvec_tile_acc_tb;

localparam integer LANES = 16;
localparam integer COLS = 128;
localparam integer DATA_WIDTH = 16;
localparam [DATA_WIDTH-1:0] FP_ZERO = 16'h0000;
localparam [DATA_WIDTH-1:0] FP_ONE  = 16'h3c00;
localparam [DATA_WIDTH-1:0] FP_TWO  = 16'h4000;
localparam [DATA_WIDTH-1:0] FP_128  = 16'h5800;
localparam [DATA_WIDTH-1:0] FP_256  = 16'h5c00;

reg clk;
reg rst_n;
reg start;
reg [DATA_WIDTH-1:0] vector_val;
reg [(LANES*DATA_WIDTH)-1:0] weights;
reg [(LANES*DATA_WIDTH)-1:0] init_accum;
reg accum_en;
wire busy;
wire done;
wire [(LANES*DATA_WIDTH)-1:0] result;
wire [6:0] col_idx;

integer lane_idx_i;
integer cycle_count;

fp16_matvec_tile_acc #(
    .LANES(LANES),
    .COLS(COLS),
    .DATA_WIDTH(DATA_WIDTH)
) u_dut (
    .clk(clk),
    .rst_n(rst_n),
    .start(start),
    .vector_val(vector_val),
    .weights(weights),
    .init_accum(init_accum),
    .accum_en(accum_en),
    .busy(busy),
    .done(done),
    .result(result),
    .col_idx(col_idx)
);

always #5 clk = ~clk;

task load_all_weights;
    input [DATA_WIDTH-1:0] value;
    begin
        for (lane_idx_i = 0; lane_idx_i < LANES; lane_idx_i = lane_idx_i + 1)
            weights[(lane_idx_i*DATA_WIDTH) +: DATA_WIDTH] = value;
    end
endtask

task load_all_init;
    input [DATA_WIDTH-1:0] value;
    begin
        for (lane_idx_i = 0; lane_idx_i < LANES; lane_idx_i = lane_idx_i + 1)
            init_accum[(lane_idx_i*DATA_WIDTH) +: DATA_WIDTH] = value;
    end
endtask

task pulse_start;
    begin
        @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;
    end
endtask

task wait_done;
    begin
        cycle_count = 0;
        while (!done && cycle_count < (COLS + 8)) begin
            @(posedge clk);
            cycle_count = cycle_count + 1;
        end
        if (!done)
            $fatal(1, "timeout waiting for done");
    end
endtask

task expect_all;
    input [DATA_WIDTH-1:0] value;
    begin
        for (lane_idx_i = 0; lane_idx_i < LANES; lane_idx_i = lane_idx_i + 1) begin
            if (result[(lane_idx_i*DATA_WIDTH) +: DATA_WIDTH] !== value) begin
                $fatal(1, "lane %0d mismatch actual=%h expected=%h",
                       lane_idx_i, result[(lane_idx_i*DATA_WIDTH) +: DATA_WIDTH], value);
            end
        end
    end
endtask

initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    start = 1'b0;
    vector_val = FP_ZERO;
    weights = {(LANES*DATA_WIDTH){1'b0}};
    init_accum = {(LANES*DATA_WIDTH){1'b0}};
    accum_en = 1'b0;

    repeat (2) @(posedge clk);
    rst_n = 1'b1;

    vector_val = FP_ONE;
    load_all_weights(FP_ONE);
    load_all_init(FP_ZERO);
    accum_en = 1'b0;
    pulse_start();
    wait_done();
    expect_all(FP_128);

    vector_val = FP_ONE;
    load_all_weights(FP_ONE);
    load_all_init(FP_128);
    accum_en = 1'b1;
    pulse_start();
    wait_done();
    expect_all(FP_256);

    vector_val = FP_ONE;
    load_all_weights(FP_TWO);
    load_all_init(FP_ZERO);
    accum_en = 1'b0;
    pulse_start();
    wait_done();
    expect_all(FP_256);

    $display("fp16_matvec_tile_acc_tb PASS");
    $finish;
end

endmodule
