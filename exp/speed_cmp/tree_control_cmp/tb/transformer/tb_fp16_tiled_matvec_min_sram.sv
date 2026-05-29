`include "config/interface_params.vh"
`include "config/memory_params.vh"
`include "config/model_params.vh"
`timescale 1ns/1ps

module tb_fp16_tiled_matvec_min_sram;

localparam integer DATA_WIDTH = `FP16_TILE_DATA_W;
localparam integer DATA_BUS_W = `SRAM_WDATA_W;
localparam integer ELEMS_PER_BEAT = DATA_BUS_W / DATA_WIDTH;
localparam integer LANES = `FP16_TILE_LANES;
localparam integer COLS = `FP16_TILE_COLS;
localparam integer MEM_DEPTH = 4096;
localparam [`SRAM_ADDR_W-1:0] WEIGHT_BASE = 23'd128;
localparam [`SRAM_ADDR_W-1:0] VECTOR_BASE = 23'd512;
localparam [`SRAM_ADDR_W-1:0] RESULT_BASE = 23'd1024;
localparam [15:0] FP_ZERO = 16'h0000;
localparam [15:0] FP_ONE = 16'h3c00;
localparam [15:0] FP_128 = 16'h5800;

logic clk;
logic rst_n;
logic issue_valid;
logic issue_ready;
logic [`SRAM_ADDR_W-1:0] issue_weight_base_addr;
logic [`SRAM_ADDR_W-1:0] issue_vector_addr;
logic [`SRAM_ADDR_W-1:0] issue_result_addr;
logic [`REQ_ID_W-1:0] issue_req_id;
logic [15:0] issue_matrix_rows;
logic [15:0] issue_matrix_cols;

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

fp16_tiled_matvec #(
    .LANES(LANES),
    .COLS(COLS),
    .DATA_WIDTH(DATA_WIDTH)
) u_dut (
    .clk(clk),
    .rst_n(rst_n),
    .issue_valid(issue_valid),
    .issue_ready(issue_ready),
    .issue_weight_base_addr(issue_weight_base_addr),
    .issue_vector_addr(issue_vector_addr),
    .issue_result_addr(issue_result_addr),
    .issue_req_id(issue_req_id),
    .issue_matrix_rows(issue_matrix_rows),
    .issue_matrix_cols(issue_matrix_cols),
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

        if (sram_wr_valid && sram_wr_ready) begin
            mem[sram_wr_addr] <= sram_wr_data;
        end
    end
end

task preload_vector_and_weights;
    begin
        for (beat_idx_i = 0; beat_idx_i < MEM_DEPTH; beat_idx_i = beat_idx_i + 1)
            mem[beat_idx_i] = {DATA_BUS_W{1'b0}};

        for (beat_idx_i = 0; beat_idx_i < (COLS / ELEMS_PER_BEAT); beat_idx_i = beat_idx_i + 1) begin
            for (elem_idx_i = 0; elem_idx_i < ELEMS_PER_BEAT; elem_idx_i = elem_idx_i + 1)
                mem[VECTOR_BASE + beat_idx_i][(elem_idx_i*DATA_WIDTH) +: DATA_WIDTH] = FP_ONE;
        end

        for (beat_idx_i = 0; beat_idx_i < ((LANES * COLS) / ELEMS_PER_BEAT); beat_idx_i = beat_idx_i + 1) begin
            for (elem_idx_i = 0; elem_idx_i < ELEMS_PER_BEAT; elem_idx_i = elem_idx_i + 1)
                mem[WEIGHT_BASE + beat_idx_i][(elem_idx_i*DATA_WIDTH) +: DATA_WIDTH] = FP_ONE;
        end
    end
endtask

task expect_result_region;
    begin
        for (beat_idx_i = 0; beat_idx_i < (LANES / ELEMS_PER_BEAT); beat_idx_i = beat_idx_i + 1) begin
            for (elem_idx_i = 0; elem_idx_i < ELEMS_PER_BEAT; elem_idx_i = elem_idx_i + 1) begin
                if (mem[RESULT_BASE + beat_idx_i][(elem_idx_i*DATA_WIDTH) +: DATA_WIDTH] !== FP_128) begin
                    $fatal(1, "matvec result mismatch beat=%0d elem=%0d actual=%h expected=%h",
                           beat_idx_i,
                           elem_idx_i,
                           mem[RESULT_BASE + beat_idx_i][(elem_idx_i*DATA_WIDTH) +: DATA_WIDTH],
                           FP_128);
                end
            end
        end
    end
endtask

initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    issue_valid = 1'b0;
    issue_weight_base_addr = WEIGHT_BASE;
    issue_vector_addr = VECTOR_BASE;
    issue_result_addr = RESULT_BASE;
    issue_req_id = 4'h3;
    issue_matrix_rows = LANES;
    issue_matrix_cols = COLS;
    sram_rd_ready = 1'b1;
    sram_wr_ready = 1'b1;
    result_ready = 1'b1;
    sram_resp_valid = 1'b0;
    sram_resp_data = {DATA_BUS_W{1'b0}};
    sram_resp_id = {`REQ_ID_W{1'b0}};

    preload_vector_and_weights();

    repeat (3) @(posedge clk);
    rst_n = 1'b1;

    wait (issue_ready);
    @(negedge clk);
    issue_valid = 1'b1;
    @(negedge clk);
    issue_valid = 1'b0;

    wait (result_valid);
    @(posedge clk);

    if (result_addr !== RESULT_BASE)
        $fatal(1, "result_addr mismatch actual=%0d expected=%0d", result_addr, RESULT_BASE);
    if (result_status !== 2'b00)
        $fatal(1, "result_status mismatch actual=%b", result_status);
    if (result_data[15:0] !== FP_128)
        $fatal(1, "result_data first lane mismatch actual=%h expected=%h", result_data[15:0], FP_128);

    expect_result_region();

    $display("tb_fp16_tiled_matvec_min_sram PASS");
    $finish;
end

endmodule
