`include "config/interface_params.vh"
`include "config/memory_params.vh"
`include "config/model_params.vh"
`timescale 1ns/1ps

module tb_fp16_rmsnorm;

localparam integer DATA_WIDTH = `FP16_TILE_DATA_W;
localparam integer DATA_BUS_W = `SRAM_WDATA_W;
localparam integer VECTOR_LEN = `QWEN3_DMODEL;
localparam integer ELEMS_PER_BEAT = DATA_BUS_W / DATA_WIDTH;
localparam integer VECTOR_BEATS = VECTOR_LEN / ELEMS_PER_BEAT;
localparam integer MEM_DEPTH = 8192;
localparam integer MAX_WAIT_CYCLES = 50000;

localparam [`SRAM_ADDR_W-1:0] X_BASE = 23'd0;
localparam [`SRAM_ADDR_W-1:0] GAMMA_BASE = 23'd128;
localparam [`SRAM_ADDR_W-1:0] RESULT_BASE = 23'd256;
localparam [15:0] FP_ZERO = 16'h0000;
localparam [15:0] FP_ONE = 16'h3c00;
localparam [15:0] FP_EIGHT = 16'h4800;
localparam [15:0] FP_2P828 = 16'h41a8;

logic clk;
logic rst_n;
logic issue_valid;
logic issue_ready;
logic sram_rd_valid;
logic sram_rd_ready;
logic [`SRAM_ADDR_W-1:0] sram_rd_addr;
logic [`REQ_ID_W-1:0] sram_rd_id;
logic sram_resp_valid;
logic sram_resp_ready;
logic [DATA_BUS_W-1:0] sram_resp_data;
logic [`REQ_ID_W-1:0] sram_resp_id;
logic sram_wr_valid;
logic sram_wr_ready;
logic [`SRAM_ADDR_W-1:0] sram_wr_addr;
logic [DATA_BUS_W-1:0] sram_wr_data;
logic result_valid;
logic result_ready;
logic [`SRAM_ADDR_W-1:0] result_addr;
logic [DATA_BUS_W-1:0] result_data;
logic [1:0] result_status;

logic [DATA_BUS_W-1:0] mem [0:MEM_DEPTH-1];
logic rd_pending_r;
logic [`SRAM_ADDR_W-1:0] rd_addr_pending_r;
logic [`REQ_ID_W-1:0] rd_id_pending_r;

integer beat_idx_i;
integer elem_idx_i;
integer wait_cycles_i;

fp16_rmsnorm u_dut (
    .clk(clk),
    .rst_n(rst_n),
    .issue_valid(issue_valid),
    .issue_ready(issue_ready),
    .issue_x_addr(X_BASE),
    .issue_gamma_addr(GAMMA_BASE),
    .issue_result_addr(RESULT_BASE),
    .issue_req_id(4'h1),
    .sram_rd_valid(sram_rd_valid),
    .sram_rd_ready(sram_rd_ready),
    .sram_rd_addr(sram_rd_addr),
    .sram_rd_id(sram_rd_id),
    .sram_resp_valid(sram_resp_valid),
    .sram_resp_ready(sram_resp_ready),
    .sram_resp_data(sram_resp_data),
    .sram_resp_id(sram_resp_id),
    .sram_wr_valid(sram_wr_valid),
    .sram_wr_ready(sram_wr_ready),
    .sram_wr_addr(sram_wr_addr),
    .sram_wr_data(sram_wr_data),
    .result_valid(result_valid),
    .result_ready(result_ready),
    .result_addr(result_addr),
    .result_data(result_data),
    .result_status(result_status)
);

always #5 clk = ~clk;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        rd_pending_r <= 1'b0;
        rd_addr_pending_r <= {`SRAM_ADDR_W{1'b0}};
        rd_id_pending_r <= {`REQ_ID_W{1'b0}};
        sram_resp_valid <= 1'b0;
        sram_resp_data <= {DATA_BUS_W{1'b0}};
        sram_resp_id <= {`REQ_ID_W{1'b0}};
    end else begin
        sram_resp_valid <= 1'b0;

        if (sram_rd_valid && sram_rd_ready) begin
            rd_pending_r <= 1'b1;
            rd_addr_pending_r <= sram_rd_addr;
            rd_id_pending_r <= sram_rd_id;
        end

        if (rd_pending_r) begin
            sram_resp_valid <= 1'b1;
            sram_resp_data <= mem[rd_addr_pending_r];
            sram_resp_id <= rd_id_pending_r;
            rd_pending_r <= 1'b0;
        end

        if (sram_wr_valid && sram_wr_ready)
            mem[sram_wr_addr] <= sram_wr_data;
    end
end

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

task automatic fill_region;
    input integer base_addr;
    input [15:0] fill_value;
    begin
        for (beat_idx_i = 0; beat_idx_i < VECTOR_BEATS; beat_idx_i = beat_idx_i + 1) begin
            for (elem_idx_i = 0; elem_idx_i < ELEMS_PER_BEAT; elem_idx_i = elem_idx_i + 1)
                mem[base_addr + beat_idx_i][(elem_idx_i*DATA_WIDTH) +: DATA_WIDTH] = fill_value;
        end
    end
endtask

task automatic fill_prefix_region;
    input integer base_addr;
    input integer active_elems;
    input [15:0] active_value;
    input [15:0] inactive_value;
    integer linear_idx_v;
    begin
        for (beat_idx_i = 0; beat_idx_i < VECTOR_BEATS; beat_idx_i = beat_idx_i + 1) begin
            for (elem_idx_i = 0; elem_idx_i < ELEMS_PER_BEAT; elem_idx_i = elem_idx_i + 1) begin
                linear_idx_v = beat_idx_i * ELEMS_PER_BEAT + elem_idx_i;
                mem[base_addr + beat_idx_i][(elem_idx_i*DATA_WIDTH) +: DATA_WIDTH] =
                    (linear_idx_v < active_elems) ? active_value : inactive_value;
            end
        end
    end
endtask

task automatic clear_memory;
    begin
        for (beat_idx_i = 0; beat_idx_i < MEM_DEPTH; beat_idx_i = beat_idx_i + 1)
            mem[beat_idx_i] = {DATA_BUS_W{1'b0}};
    end
endtask

task automatic issue_once;
    begin
        wait (issue_ready);
        @(negedge clk);
        issue_valid = 1'b1;
        @(negedge clk);
        issue_valid = 1'b0;

        wait_cycles_i = 0;
        while (!result_valid && (wait_cycles_i < MAX_WAIT_CYCLES)) begin
            @(posedge clk);
            wait_cycles_i = wait_cycles_i + 1;
        end

        if (!result_valid)
            $fatal(1, "rmsnorm timeout");
    end
endtask

task automatic expect_region_exact;
    input integer base_addr;
    input [15:0] expected_value;
    input [255:0] case_name;
    begin
        for (beat_idx_i = 0; beat_idx_i < VECTOR_BEATS; beat_idx_i = beat_idx_i + 1) begin
            for (elem_idx_i = 0; elem_idx_i < ELEMS_PER_BEAT; elem_idx_i = elem_idx_i + 1) begin
                if (mem[base_addr + beat_idx_i][(elem_idx_i*DATA_WIDTH) +: DATA_WIDTH] !== expected_value) begin
                    $fatal(1, "rmsnorm mismatch case=%0s beat=%0d elem=%0d actual=%h expected=%h",
                           case_name,
                           beat_idx_i,
                           elem_idx_i,
                           mem[base_addr + beat_idx_i][(elem_idx_i*DATA_WIDTH) +: DATA_WIDTH],
                           expected_value);
                end
            end
        end
    end
endtask

task automatic expect_region_close;
    input integer base_addr;
    input [15:0] expected_value;
    input integer ulp_tol;
    input [255:0] case_name;
    begin
        for (beat_idx_i = 0; beat_idx_i < VECTOR_BEATS; beat_idx_i = beat_idx_i + 1) begin
            for (elem_idx_i = 0; elem_idx_i < ELEMS_PER_BEAT; elem_idx_i = elem_idx_i + 1) begin
                if (!fp16_close(mem[base_addr + beat_idx_i][(elem_idx_i*DATA_WIDTH) +: DATA_WIDTH],
                                expected_value,
                                ulp_tol)) begin
                    $fatal(1, "rmsnorm mismatch case=%0s beat=%0d elem=%0d actual=%h expected=%h",
                           case_name,
                           beat_idx_i,
                           elem_idx_i,
                           mem[base_addr + beat_idx_i][(elem_idx_i*DATA_WIDTH) +: DATA_WIDTH],
                           expected_value);
                end
            end
        end
    end
endtask

task automatic expect_prefix_close;
    input integer base_addr;
    input integer active_elems;
    input [15:0] active_expected;
    input [15:0] inactive_expected;
    input integer ulp_tol;
    input [255:0] case_name;
    integer linear_idx_v;
    reg [15:0] expected_value_v;
    begin
        for (beat_idx_i = 0; beat_idx_i < VECTOR_BEATS; beat_idx_i = beat_idx_i + 1) begin
            for (elem_idx_i = 0; elem_idx_i < ELEMS_PER_BEAT; elem_idx_i = elem_idx_i + 1) begin
                linear_idx_v = beat_idx_i * ELEMS_PER_BEAT + elem_idx_i;
                expected_value_v = (linear_idx_v < active_elems) ? active_expected : inactive_expected;
                if (!fp16_close(mem[base_addr + beat_idx_i][(elem_idx_i*DATA_WIDTH) +: DATA_WIDTH],
                                expected_value_v,
                                ulp_tol)) begin
                    $fatal(1, "rmsnorm mismatch case=%0s beat=%0d elem=%0d actual=%h expected=%h",
                           case_name,
                           beat_idx_i,
                           elem_idx_i,
                           mem[base_addr + beat_idx_i][(elem_idx_i*DATA_WIDTH) +: DATA_WIDTH],
                           expected_value_v);
                end
            end
        end
    end
endtask

initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    issue_valid = 1'b0;
    sram_rd_ready = 1'b1;
    sram_wr_ready = 1'b1;
    result_ready = 1'b1;
    sram_resp_valid = 1'b0;
    sram_resp_data = {DATA_BUS_W{1'b0}};
    sram_resp_id = {`REQ_ID_W{1'b0}};

    clear_memory();

    repeat (3) @(posedge clk);
    rst_n = 1'b1;

    clear_memory();
    fill_region(X_BASE, FP_ONE);
    fill_region(GAMMA_BASE, FP_ONE);
    issue_once();
    if (result_status !== 2'b00)
        $fatal(1, "rmsnorm status mismatch actual=%b", result_status);
    if (result_addr !== RESULT_BASE)
        $fatal(1, "rmsnorm result_addr mismatch actual=%0d expected=%0d", result_addr, RESULT_BASE);
    expect_region_close(RESULT_BASE, FP_ONE, 32, "all_one");

    clear_memory();
    fill_region(X_BASE, FP_ZERO);
    fill_region(GAMMA_BASE, FP_ONE);
    issue_once();
    if (result_status !== 2'b00)
        $fatal(1, "rmsnorm zero status mismatch actual=%b", result_status);
    expect_region_exact(RESULT_BASE, FP_ZERO, "all_zero");

    clear_memory();
    fill_prefix_region(X_BASE, 128, FP_EIGHT, FP_ZERO);
    fill_region(GAMMA_BASE, FP_ONE);
    issue_once();
    if (result_status !== 2'b00)
        $fatal(1, "rmsnorm high_range status mismatch actual=%b", result_status);
    expect_prefix_close(RESULT_BASE, 128, FP_2P828, FP_ZERO, 8, "prefix_128_eight");

    $display("tb_fp16_rmsnorm PASS");
    $finish;
end

endmodule
