`include "config/interface_params.vh"
`include "config/memory_params.vh"
`include "config/model_params.vh"
`timescale 1ns/1ps

module tb_fp16_inference_top_toy_real;

localparam integer HIDDEN_DIM = 128;
localparam integer INTERMEDIATE_DIM = 256;
localparam integer NUM_HEADS = 2;
localparam integer HEAD_DIM = 64;
localparam integer N_LAYERS = 2;
localparam integer VOCAB_SIZE = 16;
localparam integer DATA_WIDTH = 16;
localparam integer DATA_BUS_W = `SRAM_WDATA_W;
localparam integer HBM_DATA_W = `HBM_DATA_W;
localparam integer ELEMS_PER_BEAT = DATA_BUS_W / DATA_WIDTH;
localparam integer HIDDEN_BEATS = HIDDEN_DIM / ELEMS_PER_BEAT;
localparam integer MEM_DEPTH = 262144;
localparam integer HBM_DEPTH = 131072;
localparam integer WEIGHT_WINDOW_BEATS = 32768;
localparam integer LAYER_WEIGHT_STRIDE = 16400;
localparam integer MAX_WAIT_CYCLES = 800000;
localparam integer NUM_AUTOREGRESSIVE_TOKENS = 4;

localparam [`SRAM_ADDR_W-1:0] EMB_BASE = 23'd256;
localparam [`SRAM_ADDR_W-1:0] FINAL_GAMMA_BASE = 23'd2048;
localparam [`SRAM_ADDR_W-1:0] LM_HEAD_BASE = 23'd49664;
localparam [`SRAM_ADDR_W-1:0] WORK_HIDDEN0_BASE = 23'd4096;
localparam [`SRAM_ADDR_W-1:0] WORK_HIDDEN1_BASE = 23'd6144;
localparam [`SRAM_ADDR_W-1:0] WORK_FINAL_BASE = 23'd8192;
localparam [`SRAM_ADDR_W-1:0] WEIGHT_SRAM_BASE = 23'd16384;
localparam [`SRAM_ADDR_W-1:0] KV_CACHE_SRAM_BASE = 23'd57344;
localparam [`HBM_ADDR_W-1:0] HBM_WEIGHT_BASE = 32'd1024;

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
logic [HBM_DATA_W-1:0] hbm_resp_data;

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

logic [`SRAM_WDATA_W-1:0] sram_mem [0:MEM_DEPTH-1];
logic [HBM_DATA_W-1:0] hbm_mem [0:HBM_DEPTH-1];
logic sram_rd_pending_r;
logic [`SRAM_ADDR_W-1:0] sram_rd_addr_pending_r;
logic [`REQ_ID_W-1:0] sram_rd_id_pending_r;
logic hbm_rd_pending_r;
logic [`HBM_ADDR_W-1:0] hbm_rd_addr_pending_r;

integer idx_i;
integer fd_i;
integer wait_cycles_i;
integer step_idx_i;
string preload_path_r;
string hbm_path_r;
string generated_dir_r;

fp16_inference_top #(
    .ADDR_W(`SRAM_ADDR_W),
    .HBM_ADDR_W(`HBM_ADDR_W),
    .HBM_DATA_W(HBM_DATA_W),
    .DATA_BUS_W(`SRAM_WDATA_W),
    .REQ_ID_W(`REQ_ID_W),
    .HIDDEN_DIM(HIDDEN_DIM),
    .INTERMEDIATE_DIM(INTERMEDIATE_DIM),
    .NUM_HEADS(NUM_HEADS),
    .HEAD_DIM(HEAD_DIM),
    .N_LAYERS(N_LAYERS),
    .VOCAB_SIZE(VOCAB_SIZE),
    .WEIGHT_WINDOW_BEATS(WEIGHT_WINDOW_BEATS),
    .LAYER_WEIGHT_STRIDE(LAYER_WEIGHT_STRIDE),
    .WORK_HIDDEN0_BASE(WORK_HIDDEN0_BASE),
    .WORK_HIDDEN1_BASE(WORK_HIDDEN1_BASE),
    .WORK_FINAL_BASE(WORK_FINAL_BASE),
    .WEIGHT_SRAM_BASE(WEIGHT_SRAM_BASE),
    .KV_CACHE_SRAM_BASE(KV_CACHE_SRAM_BASE),
    .HBM_WEIGHT_BASE(HBM_WEIGHT_BASE),
    .LM_HEAD_WEIGHT_BASE(LM_HEAD_BASE)
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
        hbm_resp_data <= {HBM_DATA_W{1'b0}};
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
            sram_resp_data <= sram_mem[sram_rd_addr_pending_r];
            sram_resp_id <= sram_rd_id_pending_r;
            sram_rd_pending_r <= 1'b0;
        end

        if (sram_wr_valid && sram_wr_ready)
            sram_mem[sram_wr_addr] <= sram_wr_data;

        if (hbm_rd_valid && hbm_rd_ready) begin
            hbm_rd_pending_r <= 1'b1;
            hbm_rd_addr_pending_r <= hbm_rd_addr;
        end

        if (hbm_rd_pending_r) begin
            hbm_resp_valid <= 1'b1;
            hbm_resp_data <= hbm_mem[hbm_rd_addr_pending_r];
            hbm_rd_pending_r <= 1'b0;
        end
    end
end

task automatic dump_hidden_after_layer1;
    input integer base_addr;
    input integer beats;
    begin
        fd_i = $fopen("rtl_hidden_after_layer1.memh", "w");
        if (fd_i == 0)
            $fatal(1, "failed to open rtl_hidden_after_layer1.memh");
        for (idx_i = 0; idx_i < beats; idx_i = idx_i + 1)
            $fdisplay(fd_i, "%032h", sram_mem[base_addr + idx_i]);
        $fclose(fd_i);
    end
endtask

task automatic dump_final_hidden;
    input integer base_addr;
    input integer beats;
    begin
        fd_i = $fopen("rtl_final_hidden.memh", "w");
        if (fd_i == 0)
            $fatal(1, "failed to open rtl_final_hidden.memh");
        for (idx_i = 0; idx_i < beats; idx_i = idx_i + 1)
            $fdisplay(fd_i, "%032h", sram_mem[base_addr + idx_i]);
        $fclose(fd_i);
    end
endtask

task automatic dump_token;
    begin
        fd_i = $fopen("rtl_token.txt", "w");
        if (fd_i == 0)
            $fatal(1, "failed to open rtl_token.txt");
        $fdisplay(fd_i, "%0d", token_out_id);
        $fclose(fd_i);
    end
endtask

task automatic dump_step_hidden;
    input integer step;
    input integer base_addr;
    input integer beats;
    begin
        fd_i = $fopen($sformatf("rtl_step%0d_final_hidden.memh", step), "w");
        if (fd_i == 0)
            $fatal(1, "failed to open rtl_step%0d_final_hidden.memh", step);
        for (idx_i = 0; idx_i < beats; idx_i = idx_i + 1)
            $fdisplay(fd_i, "%032h", sram_mem[base_addr + idx_i]);
        $fclose(fd_i);
    end
endtask

task automatic dump_step_token;
    input integer step;
    input [31:0] tok_id;
    begin
        fd_i = $fopen($sformatf("rtl_step%0d_token.txt", step), "w");
        if (fd_i == 0)
            $fatal(1, "failed to open rtl_step%0d_token.txt", step);
        $fdisplay(fd_i, "%0d", tok_id);
        $fclose(fd_i);
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
    hbm_resp_data = {HBM_DATA_W{1'b0}};

    for (idx_i = 0; idx_i < MEM_DEPTH; idx_i = idx_i + 1)
        sram_mem[idx_i] = {`SRAM_WDATA_W{1'b0}};
    for (idx_i = 0; idx_i < HBM_DEPTH; idx_i = idx_i + 1)
        hbm_mem[idx_i] = {HBM_DATA_W{1'b0}};

    generated_dir_r = "";
    if (!$value$plusargs("toy_model_generated_dir=%s", generated_dir_r))
        generated_dir_r = "code/script/toy_model/generated";

    preload_path_r = {generated_dir_r, "/sram_preload.memh"};
    hbm_path_r = {generated_dir_r, "/hbm_weights.memh"};
    fd_i = $fopen(preload_path_r, "r");
    if (fd_i == 0) begin
        generated_dir_r = "../../../../code/script/toy_model/generated";
        preload_path_r = {generated_dir_r, "/sram_preload.memh"};
        hbm_path_r = {generated_dir_r, "/hbm_weights.memh"};
        fd_i = $fopen(preload_path_r, "r");
    end
    if (fd_i == 0)
        $fatal(1, "failed to locate sram_preload.memh");
    $fclose(fd_i);

    fd_i = $fopen(hbm_path_r, "r");
    if (fd_i == 0) begin
        hbm_path_r = "../../../../code/script/toy_model/generated/hbm_weights.memh";
        fd_i = $fopen(hbm_path_r, "r");
    end
    if (fd_i == 0)
        $fatal(1, "failed to locate hbm_weights.memh");
    $fclose(fd_i);

    $readmemh(preload_path_r, sram_mem);
    $readmemh(hbm_path_r, hbm_mem);

    repeat (4) @(posedge clk);
    rst_n = 1'b1;

    for (step_idx_i = 0; step_idx_i < NUM_AUTOREGRESSIVE_TOKENS; step_idx_i = step_idx_i + 1) begin
        wait (token_in_ready);
        @(negedge clk);
        token_in_valid = 1'b1;
        token_in_id = (step_idx_i == 0) ? 32'd0 : token_out_id;
        token_in_is_bos = (step_idx_i == 0) ? 1'b1 : 1'b0;
        @(negedge clk);
        token_in_valid = 1'b0;

        wait_cycles_i = 0;
        while (!token_out_valid && (wait_cycles_i < MAX_WAIT_CYCLES)) begin
            @(posedge clk);
            wait_cycles_i = wait_cycles_i + 1;
        end

        if (!token_out_valid)
            $fatal(1, "toy_real top timeout waiting for token_out_valid at step %0d", step_idx_i);

        @(posedge clk);
        wait (!busy);
        @(negedge clk);

        if (busy)
            $fatal(1, "busy should be low after completion step=%0d", step_idx_i);
        if (current_position !== (step_idx_i + 1))
            $fatal(1, "current_position mismatch step=%0d actual=%0d expected=%0d", step_idx_i, current_position, step_idx_i + 1);
        if (current_layer_debug !== (N_LAYERS - 1))
            $fatal(1, "current_layer_debug mismatch actual=%0d expected=%0d", current_layer_debug, N_LAYERS - 1);
        if (token_out_id >= VOCAB_SIZE)
            $fatal(1, "token_out_id out of range step=%0d tok=%0d", step_idx_i, token_out_id);

        if (step_idx_i == 0) begin
            dump_hidden_after_layer1(WORK_HIDDEN1_BASE, HIDDEN_BEATS);
            dump_final_hidden(WORK_FINAL_BASE, HIDDEN_BEATS);
            dump_token();
        end
        dump_step_hidden(step_idx_i, WORK_FINAL_BASE, HIDDEN_BEATS);
        dump_step_token(step_idx_i, token_out_id);
        $display("Step %0d: token=%0d position=%0d", step_idx_i, token_out_id, current_position);
    end

    $display("RTL token_out_id = %0d", token_out_id);
    $display("tb_fp16_inference_top_toy_real MULTI_TOKEN PASS");
    $display("tb_fp16_inference_top_toy_real PASS");
    $finish;
end

endmodule
