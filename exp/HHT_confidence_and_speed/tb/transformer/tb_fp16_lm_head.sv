`include "config/interface_params.vh"
`include "config/memory_params.vh"
`include "config/model_params.vh"
`timescale 1ns/1ps

module tb_fp16_lm_head;

localparam integer DATA_WIDTH = `FP16_TILE_DATA_W;
localparam integer DATA_BUS_W = `SRAM_WDATA_W;
localparam integer HIDDEN_DIM = 128;
localparam integer VOCAB_SIZE = 16;
localparam integer LANES = `FP16_TILE_LANES;
localparam integer ELEMS_PER_BEAT = DATA_BUS_W / DATA_WIDTH;
localparam integer HIDDEN_BEATS = HIDDEN_DIM / ELEMS_PER_BEAT;
localparam integer MEM_DEPTH = 65536;
localparam integer MAX_WAIT_CYCLES = 50000;

localparam [15:0] FP_ONE = 16'h3c00;
localparam [15:0] FP_TWO = 16'h4000;

localparam [`SRAM_ADDR_W-1:0] HIDDEN_BASE = 23'd0;
localparam [`SRAM_ADDR_W-1:0] EMB_W_BASE = 23'd2048;

logic clk;
logic rst_n;
logic issue_valid;
logic issue_ready;
logic issue_do_sample;
logic [15:0] issue_temperature;
logic [6:0] issue_top_k;
logic [15:0] issue_top_p;
logic sram_rd_valid;
logic sram_rd_ready;
logic [`SRAM_ADDR_W-1:0] sram_rd_addr;
logic [`REQ_ID_W-1:0] sram_rd_id;
logic sram_resp_valid;
logic sram_resp_ready;
logic [DATA_BUS_W-1:0] sram_resp_data;
logic [`REQ_ID_W-1:0] sram_resp_id;
logic result_valid;
logic result_ready;
logic [31:0] result_token_id;
logic [15:0] result_logit;

logic [DATA_BUS_W-1:0] mem [0:MEM_DEPTH-1];
logic rd_pending_r;
logic [`SRAM_ADDR_W-1:0] rd_addr_pending_r;
logic [`REQ_ID_W-1:0] rd_id_pending_r;

integer beat_idx_i;
integer elem_idx_i;
integer wait_cycles_i;
integer row_i;
integer col_i;
integer flat_idx_v;
integer beat_v;
integer lane_v;
reg [15:0] weight_v;

fp16_lm_head #(
    .DATA_WIDTH(DATA_WIDTH),
    .ADDR_W(`SRAM_ADDR_W),
    .DATA_BUS_W(DATA_BUS_W),
    .REQ_ID_W(`REQ_ID_W),
    .HIDDEN_DIM(HIDDEN_DIM),
    .VOCAB_SIZE(VOCAB_SIZE),
    .RESULT_STATUS_W(2),
    .TOP_K_MAX(16)
) u_dut (
    .clk(clk),
    .rst_n(rst_n),
    .issue_valid(issue_valid),
    .issue_ready(issue_ready),
    .issue_hidden_addr(HIDDEN_BASE),
    .issue_emb_weight_addr(EMB_W_BASE),
    .issue_do_sample(issue_do_sample),
    .issue_temperature(issue_temperature),
    .issue_top_k(issue_top_k),
    .issue_top_p(issue_top_p),
    .issue_req_id(4'h5),
    .sram_rd_valid(sram_rd_valid),
    .sram_rd_ready(sram_rd_ready),
    .sram_rd_addr(sram_rd_addr),
    .sram_rd_id(sram_rd_id),
    .sram_resp_valid(sram_resp_valid),
    .sram_resp_ready(sram_resp_ready),
    .sram_resp_data(sram_resp_data),
    .sram_resp_id(sram_resp_id),
    .result_valid(result_valid),
    .result_ready(result_ready),
    .result_token_id(result_token_id),
    .result_logit(result_logit)
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
    end
end

task automatic clear_memory;
    begin
        for (beat_idx_i = 0; beat_idx_i < MEM_DEPTH; beat_idx_i = beat_idx_i + 1)
            mem[beat_idx_i] = {DATA_BUS_W{1'b0}};
    end
endtask

task automatic preload_hidden;
    begin
        for (beat_idx_i = 0; beat_idx_i < HIDDEN_BEATS; beat_idx_i = beat_idx_i + 1) begin
            for (elem_idx_i = 0; elem_idx_i < ELEMS_PER_BEAT; elem_idx_i = elem_idx_i + 1)
                mem[HIDDEN_BASE + beat_idx_i][(elem_idx_i*DATA_WIDTH) +: DATA_WIDTH] = FP_ONE;
        end
    end
endtask

task automatic preload_weights;
    begin
        for (col_i = 0; col_i < HIDDEN_DIM; col_i = col_i + 1) begin
            for (row_i = 0; row_i < VOCAB_SIZE; row_i = row_i + 1) begin
                flat_idx_v = (col_i * LANES) + row_i;
                beat_v = EMB_W_BASE + (flat_idx_v / ELEMS_PER_BEAT);
                lane_v = flat_idx_v % ELEMS_PER_BEAT;
                weight_v = (row_i == 0) ? FP_TWO : FP_ONE;
                mem[beat_v][(lane_v*DATA_WIDTH) +: DATA_WIDTH] = weight_v;
            end
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
            $fatal(1, "lm_head timeout");
    end
endtask

initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    issue_valid = 1'b0;
    issue_do_sample = 1'b0;
    issue_temperature = FP_ONE;
    issue_top_k = 7'd1;
    issue_top_p = FP_ONE;
    sram_rd_ready = 1'b1;
    result_ready = 1'b1;
    sram_resp_valid = 1'b0;
    sram_resp_data = {DATA_BUS_W{1'b0}};
    sram_resp_id = {`REQ_ID_W{1'b0}};

    clear_memory();
    preload_hidden();
    preload_weights();

    repeat (3) @(posedge clk);
    rst_n = 1'b1;

    issue_do_sample = 1'b0;
    issue_top_k = 7'd1;
    issue_once();
    if (result_token_id !== 32'd0)
        $fatal(1, "lm_head greedy token mismatch actual=%0d expected=0", result_token_id);
    if (result_logit == 16'h0000)
        $fatal(1, "lm_head greedy logit should be non-zero");

    issue_do_sample = 1'b1;
    issue_top_k = 7'd4;
    issue_top_p = FP_ONE;
    issue_once();
    if (result_token_id >= VOCAB_SIZE)
        $fatal(1, "lm_head sampled token out of range actual=%0d", result_token_id);

    $display("tb_fp16_lm_head PASS");
    $finish;
end

endmodule
