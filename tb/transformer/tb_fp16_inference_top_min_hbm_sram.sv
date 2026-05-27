`include "config/interface_params.vh"
`include "config/memory_params.vh"
`include "config/model_params.vh"
`timescale 1ns/1ps

module tb_fp16_inference_top_min_hbm_sram;

localparam integer HIDDEN_DIM = 128;
localparam integer INTERMEDIATE_DIM = 128;
localparam integer NUM_HEADS = 1;
localparam integer HEAD_DIM = 128;
localparam integer N_LAYERS = 2;
localparam integer VOCAB_SIZE = 16;
localparam integer DATA_WIDTH = 16;
localparam integer DATA_BUS_W = `SRAM_WDATA_W;
localparam integer ELEMS_PER_BEAT = DATA_BUS_W / DATA_WIDTH;
localparam integer HIDDEN_BEATS = HIDDEN_DIM / ELEMS_PER_BEAT;
localparam integer MATVEC_BEATS = (HIDDEN_DIM * HIDDEN_DIM) / ELEMS_PER_BEAT;
localparam integer MEM_DEPTH = 131072;

localparam [`SRAM_ADDR_W-1:0] EMB_BASE = 23'd256;
localparam [`SRAM_ADDR_W-1:0] FINAL_GAMMA_BASE = 23'd2048;
localparam [`SRAM_ADDR_W-1:0] WORK_HIDDEN0_BASE = 23'd4096;
localparam [`SRAM_ADDR_W-1:0] WORK_HIDDEN1_BASE = 23'd6144;
localparam [`SRAM_ADDR_W-1:0] WORK_FINAL_BASE = 23'd8192;
localparam [`SRAM_ADDR_W-1:0] WEIGHT_SRAM_BASE = 23'd16384;
localparam [`SRAM_ADDR_W-1:0] KV_CACHE_SRAM_BASE = 23'd49152;
localparam [`HBM_ADDR_W-1:0] HBM_WEIGHT_BASE = 32'd1024;

localparam [15:0] FP_ZERO = 16'h0000;
localparam [15:0] FP_ONE = 16'h3c00;

logic clk;
logic rst_n;
logic token_in_valid;
logic token_in_ready;
logic [31:0] token_in_id;
logic token_in_is_bos;
logic token_out_valid;
logic token_out_ready;
logic [31:0] token_out_id;
logic [`SRAM_ADDR_W-1:0] cfg_embedding_base;
logic [`SRAM_ADDR_W-1:0] cfg_final_norm_gamma_addr;
logic cfg_do_sample;
logic [6:0] cfg_top_k;
logic [15:0] cfg_top_p;

logic hbm_rd_valid;
logic hbm_rd_ready;
logic [`HBM_ADDR_W-1:0] hbm_rd_addr;
logic hbm_resp_valid;
logic hbm_resp_ready;
logic [`HBM_DATA_W-1:0] hbm_resp_data;

logic sram_rd_valid;
logic sram_rd_ready;
logic [`SRAM_ADDR_W-1:0] sram_rd_addr;
logic [`REQ_ID_W-1:0] sram_rd_id;
logic sram_resp_valid;
logic sram_resp_ready;
logic [`SRAM_RDATA_W-1:0] sram_resp_data;
logic [`REQ_ID_W-1:0] sram_resp_id;
logic sram_wr_valid;
logic sram_wr_ready;
logic [`SRAM_ADDR_W-1:0] sram_wr_addr;
logic [`SRAM_WDATA_W-1:0] sram_wr_data;

logic busy;
logic [15:0] current_position;
logic [4:0] current_layer_debug;

logic [`SRAM_WDATA_W-1:0] mem [0:MEM_DEPTH-1];
logic sram_rd_pending_r;
logic [`SRAM_ADDR_W-1:0] sram_rd_addr_pending_r;
logic [`REQ_ID_W-1:0] sram_rd_id_pending_r;
logic hbm_rd_pending_r;
logic [`HBM_ADDR_W-1:0] hbm_rd_addr_pending_r;

integer beat_idx_i;
integer elem_idx_i;
integer layer_idx_i;
integer layer_base_i;

fp16_inference_top #(
    .ADDR_W(`SRAM_ADDR_W),
    .HBM_ADDR_W(`HBM_ADDR_W),
    .HBM_DATA_W(`HBM_DATA_W),
    .DATA_BUS_W(`SRAM_WDATA_W),
    .REQ_ID_W(`REQ_ID_W),
    .HIDDEN_DIM(HIDDEN_DIM),
    .INTERMEDIATE_DIM(INTERMEDIATE_DIM),
    .NUM_HEADS(NUM_HEADS),
    .HEAD_DIM(HEAD_DIM),
    .N_LAYERS(N_LAYERS),
    .VOCAB_SIZE(VOCAB_SIZE),
    .WORK_HIDDEN0_BASE(WORK_HIDDEN0_BASE),
    .WORK_HIDDEN1_BASE(WORK_HIDDEN1_BASE),
    .WORK_FINAL_BASE(WORK_FINAL_BASE),
    .WEIGHT_SRAM_BASE(WEIGHT_SRAM_BASE),
    .KV_CACHE_SRAM_BASE(KV_CACHE_SRAM_BASE),
    .HBM_WEIGHT_BASE(HBM_WEIGHT_BASE)
) u_dut (
    .clk(clk),
    .rst_n(rst_n),
    .token_in_valid(token_in_valid),
    .token_in_ready(token_in_ready),
    .token_in_id(token_in_id),
    .token_in_is_bos(token_in_is_bos),
    .token_out_valid(token_out_valid),
    .token_out_ready(token_out_ready),
    .token_out_id(token_out_id),
    .cfg_embedding_base(cfg_embedding_base),
    .cfg_final_norm_gamma_addr(cfg_final_norm_gamma_addr),
    .cfg_do_sample(cfg_do_sample),
    .cfg_top_k(cfg_top_k),
    .cfg_top_p(cfg_top_p),
    .cfg_tree_mask_en(1'b0),
    .cfg_branch_id({`BRANCH_ID_W{1'b0}}),
    .cfg_prefix_len(16'd0),
    .cfg_position(16'd0),
    .cfg_position_ovr(1'b0),
    .hbm_rd_valid(hbm_rd_valid),
    .hbm_rd_ready(hbm_rd_ready),
    .hbm_rd_addr(hbm_rd_addr),
    .hbm_resp_valid(hbm_resp_valid),
    .hbm_resp_ready(hbm_resp_ready),
    .hbm_resp_data(hbm_resp_data),
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
    .vec_sram_rd_valid(),
    .vec_sram_rd_ready({`MEM_REQ_LANES{1'b0}}),
    .vec_sram_rd_addr(),
    .vec_sram_rd_id(),
    .vec_sram_rd_pe_mask(),
    .vec_sram_resp_valid({`MEM_REQ_LANES{1'b0}}),
    .vec_sram_resp_ready(),
    .vec_sram_resp_data({(`MEM_REQ_LANES*`SRAM_RDATA_W){1'b0}}),
    .vec_sram_resp_id({(`MEM_REQ_LANES*`REQ_ID_W){1'b0}}),
    .vec_sram_wr_valid(),
    .vec_sram_wr_ready({`MEM_REQ_LANES{1'b0}}),
    .vec_sram_wr_addr(),
    .vec_sram_wr_data(),
    .vec_sram_wr_id(),
    .vec_sram_wr_pe_mask(),
    .busy(busy),
    .current_position(current_position),
    .current_layer_debug(current_layer_debug)
);

always #5 clk = ~clk;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        sram_rd_pending_r <= 1'b0;
        sram_rd_addr_pending_r <= {`SRAM_ADDR_W{1'b0}};
        sram_rd_id_pending_r <= {`REQ_ID_W{1'b0}};
        sram_resp_valid <= 1'b0;
        sram_resp_data <= {`SRAM_RDATA_W{1'b0}};
        sram_resp_id <= {`REQ_ID_W{1'b0}};
        hbm_rd_pending_r <= 1'b0;
        hbm_rd_addr_pending_r <= {`HBM_ADDR_W{1'b0}};
        hbm_resp_valid <= 1'b0;
        hbm_resp_data <= {`HBM_DATA_W{1'b0}};
    end else begin
        sram_resp_valid <= 1'b0;
        hbm_resp_valid <= 1'b0;

        if (sram_rd_valid && sram_rd_ready) begin
            sram_rd_pending_r <= 1'b1;
            sram_rd_addr_pending_r <= sram_rd_addr;
            sram_rd_id_pending_r <= sram_rd_id;
        end

        if (sram_rd_pending_r) begin
            sram_resp_valid <= 1'b1;
            sram_resp_data <= mem[sram_rd_addr_pending_r];
            sram_resp_id <= sram_rd_id_pending_r;
            sram_rd_pending_r <= 1'b0;
        end

        if (sram_wr_valid && sram_wr_ready)
            mem[sram_wr_addr] <= sram_wr_data;

        if (hbm_rd_valid && hbm_rd_ready) begin
            hbm_rd_pending_r <= 1'b1;
            hbm_rd_addr_pending_r <= hbm_rd_addr;
        end

        if (hbm_rd_pending_r) begin
            hbm_resp_valid <= 1'b1;
            hbm_resp_data <= {4{hbm_rd_addr_pending_r, hbm_rd_addr_pending_r}};
            hbm_rd_pending_r <= 1'b0;
        end
    end
end

task preload_embedding;
    begin
        for (beat_idx_i = 0; beat_idx_i < HIDDEN_BEATS; beat_idx_i = beat_idx_i + 1) begin
            for (elem_idx_i = 0; elem_idx_i < ELEMS_PER_BEAT; elem_idx_i = elem_idx_i + 1)
                mem[EMB_BASE + beat_idx_i][(elem_idx_i*DATA_WIDTH) +: DATA_WIDTH] = FP_ONE;
        end
    end
endtask

task preload_gamma;
    input [`SRAM_ADDR_W-1:0] gamma_base;
    begin
        for (beat_idx_i = 0; beat_idx_i < HIDDEN_BEATS; beat_idx_i = beat_idx_i + 1) begin
            for (elem_idx_i = 0; elem_idx_i < ELEMS_PER_BEAT; elem_idx_i = elem_idx_i + 1)
                mem[gamma_base + beat_idx_i][(elem_idx_i*DATA_WIDTH) +: DATA_WIDTH] = FP_ONE;
        end
    end
endtask

task preload_matvec_weights;
    input integer base_addr;
    begin
        for (beat_idx_i = 0; beat_idx_i < MATVEC_BEATS; beat_idx_i = beat_idx_i + 1) begin
            for (elem_idx_i = 0; elem_idx_i < ELEMS_PER_BEAT; elem_idx_i = elem_idx_i + 1)
                mem[base_addr + beat_idx_i][(elem_idx_i*DATA_WIDTH) +: DATA_WIDTH] = FP_ONE;
        end
    end
endtask

task preload_layer_weights;
    input integer layer_idx;
    integer base_addr;
    begin
        base_addr = WEIGHT_SRAM_BASE + (layer_idx * 16384);
        preload_gamma(base_addr);
        preload_gamma(base_addr + HIDDEN_BEATS);
        preload_gamma(base_addr + (2 * HIDDEN_BEATS));
        preload_gamma(base_addr + (3 * HIDDEN_BEATS));
        preload_matvec_weights(base_addr + (4 * HIDDEN_BEATS));
        preload_matvec_weights(base_addr + (4 * HIDDEN_BEATS) + MATVEC_BEATS);
        preload_matvec_weights(base_addr + (4 * HIDDEN_BEATS) + (2 * MATVEC_BEATS));
        preload_matvec_weights(base_addr + (4 * HIDDEN_BEATS) + (3 * MATVEC_BEATS));
        preload_matvec_weights(base_addr + (4 * HIDDEN_BEATS) + (4 * MATVEC_BEATS));
        preload_matvec_weights(base_addr + (4 * HIDDEN_BEATS) + (5 * MATVEC_BEATS));
        preload_matvec_weights(base_addr + (4 * HIDDEN_BEATS) + (6 * MATVEC_BEATS));
    end
endtask

initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    token_in_valid = 1'b0;
    token_in_id = 32'd0;
    token_in_is_bos = 1'b1;
    token_out_ready = 1'b1;
    cfg_embedding_base = EMB_BASE;
    cfg_final_norm_gamma_addr = FINAL_GAMMA_BASE;
    cfg_do_sample = 1'b0;
    cfg_top_k = 7'd1;
    cfg_top_p = 16'h3c00;
    hbm_rd_ready = 1'b1;
    sram_rd_ready = 1'b1;
    sram_wr_ready = 1'b1;
    sram_resp_valid = 1'b0;
    sram_resp_data = {`SRAM_RDATA_W{1'b0}};
    sram_resp_id = {`REQ_ID_W{1'b0}};
    hbm_resp_valid = 1'b0;
    hbm_resp_data = {`HBM_DATA_W{1'b0}};

    for (beat_idx_i = 0; beat_idx_i < MEM_DEPTH; beat_idx_i = beat_idx_i + 1)
        mem[beat_idx_i] = {`SRAM_WDATA_W{1'b0}};

    preload_embedding();
    preload_gamma(FINAL_GAMMA_BASE);
    for (layer_idx_i = 0; layer_idx_i < N_LAYERS; layer_idx_i = layer_idx_i + 1)
        preload_layer_weights(layer_idx_i);

    repeat (4) @(posedge clk);
    rst_n = 1'b1;

    wait (token_in_ready);
    @(negedge clk);
    token_in_valid = 1'b1;
    token_in_id = 32'd0;
    @(negedge clk);
    token_in_valid = 1'b0;

    wait (token_out_valid);
    @(posedge clk);
    wait (!busy);
    @(negedge clk);

    if (busy)
        $fatal(1, "busy should be low after token output handshake");
    if (current_position !== 16'd1)
        $fatal(1, "current_position mismatch after one token: %0d", current_position);
    if (token_out_id >= VOCAB_SIZE)
        $fatal(1, "token_out_id out of range: %0d", token_out_id);

    $display("tb_fp16_inference_top_min_hbm_sram PASS");
    $finish;
end

endmodule
