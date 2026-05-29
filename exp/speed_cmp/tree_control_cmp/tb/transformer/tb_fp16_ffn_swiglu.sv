`include "config/interface_params.vh"
`include "config/memory_params.vh"
`include "config/model_params.vh"
`timescale 1ns/1ps

module tb_fp16_ffn_swiglu;

localparam integer ADDR_W = `SRAM_ADDR_W;
localparam integer DATA_WIDTH = `FP16_TILE_DATA_W;
localparam integer DATA_BUS_W = `SRAM_WDATA_W;
localparam integer HIDDEN_DIM = 128;
localparam integer INTERMEDIATE_DIM = 128;
localparam integer ELEMS_PER_BEAT = DATA_BUS_W / DATA_WIDTH;
localparam integer HIDDEN_BEATS = HIDDEN_DIM / ELEMS_PER_BEAT;
localparam integer MATVEC_BEATS = (HIDDEN_DIM * INTERMEDIATE_DIM) / ELEMS_PER_BEAT;
localparam integer MEM_DEPTH = 131072;
localparam integer MAX_WAIT_CYCLES = 120000;

localparam [15:0] FP_ONE = 16'h3c00;
localparam [15:0] FP_ONE_OVER_128 = 16'h2000;

localparam [ADDR_W-1:0] INPUT_BASE   = 23'd0;
localparam [ADDR_W-1:0] GATE_W_BASE  = 23'd2048;
localparam [ADDR_W-1:0] UP_W_BASE    = 23'd8192;
localparam [ADDR_W-1:0] DOWN_W_BASE  = 23'd14336;
localparam [ADDR_W-1:0] RESULT_BASE  = 23'd20480;
localparam [ADDR_W-1:0] SCRATCH_BASE = 23'd24576;

logic clk;
logic rst_n;
logic issue_valid;
logic issue_ready;
logic sram_rd_valid;
logic sram_rd_ready;
logic [ADDR_W-1:0] sram_rd_addr;
logic [`REQ_ID_W-1:0] sram_rd_id;
logic sram_resp_valid;
logic sram_resp_ready;
logic [DATA_BUS_W-1:0] sram_resp_data;
logic [`REQ_ID_W-1:0] sram_resp_id;
logic sram_wr_valid;
logic sram_wr_ready;
logic [ADDR_W-1:0] sram_wr_addr;
logic [DATA_BUS_W-1:0] sram_wr_data;
logic result_valid;
logic result_ready;
logic [ADDR_W-1:0] result_addr;
logic [DATA_BUS_W-1:0] result_data;
logic [1:0] result_status;

logic [DATA_BUS_W-1:0] mem [0:MEM_DEPTH-1];
logic rd_pending_r;
logic [ADDR_W-1:0] rd_addr_pending_r;
logic [`REQ_ID_W-1:0] rd_id_pending_r;

integer beat_idx_i;
integer elem_idx_i;
integer wait_cycles_i;
integer nonzero_count_i;

fp16_ffn_swiglu #(
    .ADDR_W(ADDR_W),
    .DATA_WIDTH(DATA_WIDTH),
    .DATA_BUS_W(DATA_BUS_W),
    .REQ_ID_W(`REQ_ID_W),
    .RESULT_STATUS_W(2),
    .HIDDEN_DIM(HIDDEN_DIM),
    .INTERMEDIATE_DIM(INTERMEDIATE_DIM),
    .RESULT_STATUS_OK(2'b00)
) u_dut (
    .clk(clk),
    .rst_n(rst_n),
    .issue_valid(issue_valid),
    .issue_ready(issue_ready),
    .issue_input_addr(INPUT_BASE),
    .issue_gate_w_addr(GATE_W_BASE),
    .issue_up_w_addr(UP_W_BASE),
    .issue_down_w_addr(DOWN_W_BASE),
    .issue_result_addr(RESULT_BASE),
    .issue_scratch_base_addr(SCRATCH_BASE),
    .issue_req_id(4'h4),
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
        rd_addr_pending_r <= {ADDR_W{1'b0}};
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

function automatic bit is_fp16_nan;
    input [15:0] value;
    begin
        is_fp16_nan = (&value[14:10]) && (value[9:0] != 10'd0);
    end
endfunction

task automatic clear_memory;
    begin
        for (beat_idx_i = 0; beat_idx_i < MEM_DEPTH; beat_idx_i = beat_idx_i + 1)
            mem[beat_idx_i] = {DATA_BUS_W{1'b0}};
    end
endtask

task automatic fill_region;
    input integer base_addr;
    input integer beats;
    input [15:0] fill_value;
    begin
        for (beat_idx_i = 0; beat_idx_i < beats; beat_idx_i = beat_idx_i + 1) begin
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
            $fatal(1, "ffn_swiglu timeout");
    end
endtask

task automatic check_result_region;
    begin
        nonzero_count_i = 0;
        for (beat_idx_i = 0; beat_idx_i < HIDDEN_BEATS; beat_idx_i = beat_idx_i + 1) begin
            for (elem_idx_i = 0; elem_idx_i < ELEMS_PER_BEAT; elem_idx_i = elem_idx_i + 1) begin
                if (is_fp16_nan(mem[RESULT_BASE + beat_idx_i][(elem_idx_i*DATA_WIDTH) +: DATA_WIDTH])) begin
                    $fatal(1, "ffn_swiglu result has NaN beat=%0d elem=%0d value=%h",
                           beat_idx_i,
                           elem_idx_i,
                           mem[RESULT_BASE + beat_idx_i][(elem_idx_i*DATA_WIDTH) +: DATA_WIDTH]);
                end
                if (mem[RESULT_BASE + beat_idx_i][(elem_idx_i*DATA_WIDTH) +: DATA_WIDTH] != 16'h0000)
                    nonzero_count_i = nonzero_count_i + 1;
            end
        end

        if (nonzero_count_i == 0)
            $fatal(1, "ffn_swiglu result region is all zero");
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
    fill_region(INPUT_BASE, HIDDEN_BEATS, FP_ONE);
    fill_region(GATE_W_BASE, MATVEC_BEATS, FP_ONE_OVER_128);
    fill_region(UP_W_BASE, MATVEC_BEATS, FP_ONE_OVER_128);
    fill_region(DOWN_W_BASE, MATVEC_BEATS, FP_ONE_OVER_128);

    repeat (3) @(posedge clk);
    rst_n = 1'b1;

    issue_once();

    if (result_status !== 2'b00)
        $fatal(1, "ffn_swiglu result_status mismatch actual=%b", result_status);
    if (result_addr !== RESULT_BASE)
        $fatal(1, "ffn_swiglu result_addr mismatch actual=%0d expected=%0d", result_addr, RESULT_BASE);

    check_result_region();

    $display("tb_fp16_ffn_swiglu PASS");
    $finish;
end

endmodule
