`include "config/interface_params.vh"
`include "config/memory_params.vh"
`include "config/model_params.vh"
`timescale 1ns/1ps

module tb_fp16_residual_add;

localparam integer DATA_WIDTH = `FP16_TILE_DATA_W;
localparam integer DATA_BUS_W = `SRAM_WDATA_W;
localparam integer VECTOR_LEN = `QWEN3_DMODEL;
localparam integer ELEMS_PER_BEAT = DATA_BUS_W / DATA_WIDTH;
localparam integer VECTOR_BEATS = VECTOR_LEN / ELEMS_PER_BEAT;
localparam integer MEM_DEPTH = 8192;
localparam integer MAX_WAIT_CYCLES = 20000;

localparam [`SRAM_ADDR_W-1:0] X_BASE = 23'd0;
localparam [`SRAM_ADDR_W-1:0] RESIDUAL_BASE = 23'd128;
localparam [`SRAM_ADDR_W-1:0] RESULT_BASE = 23'd256;
localparam [15:0] FP_ZERO = 16'h0000;
localparam [15:0] FP_ONE  = 16'h3c00;
localparam [15:0] FP_TWO  = 16'h4000;

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

fp16_residual_add u_dut (
    .clk(clk),
    .rst_n(rst_n),
    .issue_valid(issue_valid),
    .issue_ready(issue_ready),
    .issue_x_addr(X_BASE),
    .issue_residual_addr(RESIDUAL_BASE),
    .issue_result_addr(RESULT_BASE),
    .issue_req_id(4'h2),
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

task automatic clear_memory;
    begin
        for (beat_idx_i = 0; beat_idx_i < MEM_DEPTH; beat_idx_i = beat_idx_i + 1)
            mem[beat_idx_i] = {DATA_BUS_W{1'b0}};
    end
endtask

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
            $fatal(1, "residual_add timeout");
    end
endtask

task automatic expect_region;
    input [15:0] expected_value;
    input [255:0] case_name;
    begin
        for (beat_idx_i = 0; beat_idx_i < VECTOR_BEATS; beat_idx_i = beat_idx_i + 1) begin
            for (elem_idx_i = 0; elem_idx_i < ELEMS_PER_BEAT; elem_idx_i = elem_idx_i + 1) begin
                if (mem[RESULT_BASE + beat_idx_i][(elem_idx_i*DATA_WIDTH) +: DATA_WIDTH] !== expected_value) begin
                    $fatal(1, "residual_add mismatch case=%0s beat=%0d elem=%0d actual=%h expected=%h",
                           case_name,
                           beat_idx_i,
                           elem_idx_i,
                           mem[RESULT_BASE + beat_idx_i][(elem_idx_i*DATA_WIDTH) +: DATA_WIDTH],
                           expected_value);
                end
            end
        end
    end
endtask

task automatic run_case;
    input [15:0] x_value;
    input [15:0] residual_value;
    input [15:0] expected_value;
    input [255:0] case_name;
    begin
        clear_memory();
        fill_region(X_BASE, x_value);
        fill_region(RESIDUAL_BASE, residual_value);
        issue_once();
        if (result_status !== 2'b00)
            $fatal(1, "residual_add status mismatch case=%0s actual=%b", case_name, result_status);
        if (result_addr !== RESULT_BASE)
            $fatal(1, "residual_add result_addr mismatch case=%0s actual=%0d expected=%0d",
                   case_name, result_addr, RESULT_BASE);
        expect_region(expected_value, case_name);
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

    run_case(FP_ONE, FP_ONE, FP_TWO, "1+1");
    run_case(FP_ONE, FP_ZERO, FP_ONE, "1+0");
    run_case(FP_ZERO, FP_ONE, FP_ONE, "0+1");

    $display("tb_fp16_residual_add PASS");
    $finish;
end

endmodule
