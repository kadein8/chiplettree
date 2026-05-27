`timescale 1ns/1ps

`include "config/interface_params.vh"
`include "config/memory_params.vh"
`include "config/model_params.vh"

module tb_fp16_inference_adapter;

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
localparam integer HBM_TO_SRAM_RATIO = HBM_DATA_W / DATA_BUS_W;
localparam integer HBM_DEPTH = 131072;
localparam integer WEIGHT_WINDOW_BEATS = 32768;
localparam integer TOTAL_LAYER_PRELOAD_BEATS = (2 * HIDDEN_BEATS) + WEIGHT_WINDOW_BEATS;
localparam integer LAYER_WEIGHT_STRIDE = TOTAL_LAYER_PRELOAD_BEATS / HBM_TO_SRAM_RATIO;
localparam integer MAX_WAIT_CYCLES = 1000000;

localparam [`SRAM_ADDR_W-1:0] EMB_BASE = 23'd256;
localparam [`SRAM_ADDR_W-1:0] FINAL_GAMMA_BASE = 23'd2048;
localparam [`SRAM_ADDR_W-1:0] WORK_HIDDEN0_BASE = 23'd4096;
localparam [`SRAM_ADDR_W-1:0] WORK_HIDDEN1_BASE = 23'd6144;
localparam [`SRAM_ADDR_W-1:0] WORK_FINAL_BASE = 23'd8192;
localparam [`SRAM_ADDR_W-1:0] WEIGHT_SRAM_BASE = 23'd16384;
localparam [`SRAM_ADDR_W-1:0] HBM_MAPPED_SRAM_BASE = 23'd131072;
localparam [`SRAM_ADDR_W-1:0] KV_CACHE_SRAM_BASE = 23'd57344;
localparam [`SRAM_ADDR_W-1:0] LM_HEAD_BASE = 23'd49664;
localparam [`HBM_ADDR_W-1:0] HBM_WEIGHT_BASE = 32'd1024;

logic clk;
logic rst_n;

logic issue_valid;
logic issue_ready;
logic [`TOKEN_ID_W-1:0] issue_token_id;
logic [`BRANCH_ID_W-1:0] issue_branch_id;
logic [1:0] issue_epoch;
logic [7:0] issue_model_id;
logic [7:0] issue_op_class;
logic [`SRAM_ADDR_W-1:0] issue_src_addr;
logic [`SRAM_ADDR_W-1:0] issue_dst_addr;
logic [15:0] issue_token_len;
logic [`REQ_ID_W-1:0] issue_req_id;
logic [1:0] issue_flush_epoch;
logic issue_tree_mask_en;
logic [`BRANCH_ID_W-1:0] issue_tree_mask_branch_id;
logic [15:0] issue_prefix_len;

logic op_req_valid;
logic op_req_ready;
logic op_req_write;
logic [`SRAM_ADDR_W-1:0] op_req_addr;
logic [`SRAM_WDATA_W-1:0] op_req_wdata;
logic [`REQ_ID_W-1:0] op_req_id;
logic op_req_last;
logic [`TOKEN_ID_W-1:0] op_req_tag;

logic op_resp_valid;
logic op_resp_ready;
logic [`SRAM_RDATA_W-1:0] op_resp_rdata;
logic [`REQ_ID_W-1:0] op_resp_id;
logic op_resp_last;

logic result_valid;
logic result_ready;
logic [`TOKEN_ID_W-1:0] result_token_id;
logic [`SRAM_ADDR_W-1:0] result_addr;
logic [`SRAM_WDATA_W-1:0] result_data;
logic [1:0] result_status;

logic [`SRAM_WDATA_W-1:0] mem [0:MEM_DEPTH-1];
logic [HBM_DATA_W-1:0] hbm_mem [0:HBM_DEPTH-1];
logic pending_resp_valid_r;
logic [`SRAM_RDATA_W-1:0] pending_resp_data_r;
logic [`REQ_ID_W-1:0] pending_resp_id_r;
logic saw_weight_window_read_r;
integer fd_i;
integer ref_token_i;
integer hbm_mapped_read_count_r;
integer hbm_mapped_hi_read_count_r;
integer preload_hbm_idx_i;
integer beat_idx_i;
integer elem_idx_i;
integer cycle_count_i;
string generated_dir_r;
string preload_path_r;
string hbm_path_r;
string token_path_r;

fp16_inference_adapter #(
    .ADDR_W(`SRAM_ADDR_W),
    .DATA_BUS_W(`SRAM_WDATA_W),
    .REQ_ID_W(`REQ_ID_W),
    .HBM_ADDR_W(`HBM_ADDR_W),
    .HBM_DATA_W(`HBM_DATA_W),
    .TOKEN_ID_W(`TOKEN_ID_W),
    .RESULT_STATUS_W(2),
    .FINAL_NORM_GAMMA_ADDR(FINAL_GAMMA_BASE),
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
    .HBM_MAPPED_SRAM_BASE(HBM_MAPPED_SRAM_BASE),
    .KV_CACHE_SRAM_BASE(KV_CACHE_SRAM_BASE),
    .HBM_WEIGHT_BASE(HBM_WEIGHT_BASE),
    .LM_HEAD_WEIGHT_BASE(LM_HEAD_BASE)
) u_dut (
    .clk(clk),
    .rst_n(rst_n),
    .issue_valid(issue_valid),
    .issue_ready(issue_ready),
    .issue_token_id(issue_token_id),
    .issue_branch_id(issue_branch_id),
    .issue_epoch(issue_epoch),
    .issue_model_id(issue_model_id),
    .issue_op_class(issue_op_class),
    .issue_src_addr(issue_src_addr),
    .issue_dst_addr(issue_dst_addr),
    .issue_token_len(issue_token_len),
    .issue_req_id(issue_req_id),
    .issue_flush_epoch(issue_flush_epoch),
    .issue_tree_mask_en(issue_tree_mask_en),
    .issue_tree_mask_branch_id(issue_tree_mask_branch_id),
    .issue_prefix_len(issue_prefix_len),
    .op_req_valid(op_req_valid),
    .op_req_ready(op_req_ready),
    .op_req_write(op_req_write),
    .op_req_addr(op_req_addr),
    .op_req_wdata(op_req_wdata),
    .op_req_id(op_req_id),
    .op_req_last(op_req_last),
    .op_req_tag(op_req_tag),
    .op_resp_valid(op_resp_valid),
    .op_resp_ready(op_resp_ready),
    .op_resp_rdata(op_resp_rdata),
    .op_resp_id(op_resp_id),
    .op_resp_last(op_resp_last),
    .result_valid(result_valid),
    .result_ready(result_ready),
    .result_token_id(result_token_id),
    .result_addr(result_addr),
    .result_data(result_data),
    .result_status(result_status)
);

always #5 clk = ~clk;

initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    issue_valid = 1'b0;
    issue_token_id = 16'd0;
    issue_branch_id = '0;
    issue_epoch = 2'd0;
    issue_model_id = 8'h01;
    issue_op_class = 8'h02;
    issue_src_addr = EMB_BASE;
    issue_dst_addr = 23'd96;
    issue_token_len = 16'd1;
    issue_req_id = 4'h5;
    issue_flush_epoch = 2'd0;
    issue_tree_mask_en = 1'b1;
    issue_tree_mask_branch_id = 2'd2;
    issue_prefix_len = 16'd2;
    op_req_ready = 1'b1;
    op_resp_valid = 1'b0;
    op_resp_rdata = '0;
    op_resp_id = '0;
    op_resp_last = 1'b0;
    result_ready = 1'b0;
    pending_resp_valid_r = 1'b0;
    pending_resp_data_r = '0;
    pending_resp_id_r = '0;
    saw_weight_window_read_r = 1'b0;
    hbm_mapped_read_count_r = 0;
    hbm_mapped_hi_read_count_r = 0;
    ref_token_i = -1;

    for (beat_idx_i = 0; beat_idx_i < MEM_DEPTH; beat_idx_i = beat_idx_i + 1)
        mem[beat_idx_i] = {`SRAM_WDATA_W{1'b0}};
    for (beat_idx_i = 0; beat_idx_i < HBM_DEPTH; beat_idx_i = beat_idx_i + 1)
        hbm_mem[beat_idx_i] = {HBM_DATA_W{1'b0}};

    generated_dir_r = "";
    if (!$value$plusargs("toy_model_generated_dir=%s", generated_dir_r))
        generated_dir_r = "code/script/toy_model/generated";

    preload_path_r = {generated_dir_r, "/sram_preload.memh"};
    hbm_path_r = {generated_dir_r, "/hbm_weights.memh"};
    token_path_r = {generated_dir_r, "/ref_token_id.txt"};
    fd_i = $fopen(preload_path_r, "r");
    if (fd_i == 0) begin
        generated_dir_r = "../../../../code/script/toy_model/generated";
        preload_path_r = {generated_dir_r, "/sram_preload.memh"};
        hbm_path_r = {generated_dir_r, "/hbm_weights.memh"};
        token_path_r = {generated_dir_r, "/ref_token_id.txt"};
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

    fd_i = $fopen(token_path_r, "r");
    if (fd_i == 0) begin
        token_path_r = "../../../../code/script/toy_model/generated/ref_token_id.txt";
        fd_i = $fopen(token_path_r, "r");
    end
    if (fd_i == 0)
        $fatal(1, "failed to locate ref_token_id.txt");
    if ($fscanf(fd_i, "%d", ref_token_i) != 1)
        $fatal(1, "failed to parse ref_token_id.txt");
    $fclose(fd_i);

    $readmemh(preload_path_r, mem);
    $readmemh(hbm_path_r, hbm_mem);
    for (preload_hbm_idx_i = 0;
         preload_hbm_idx_i < (N_LAYERS * LAYER_WEIGHT_STRIDE);
         preload_hbm_idx_i = preload_hbm_idx_i + 1) begin
        mem[HBM_MAPPED_SRAM_BASE + (preload_hbm_idx_i * HBM_TO_SRAM_RATIO)] =
            hbm_mem[HBM_WEIGHT_BASE + preload_hbm_idx_i][0 +: DATA_BUS_W];
        mem[HBM_MAPPED_SRAM_BASE + (preload_hbm_idx_i * HBM_TO_SRAM_RATIO) + 1] =
            hbm_mem[HBM_WEIGHT_BASE + preload_hbm_idx_i][DATA_BUS_W +: DATA_BUS_W];
    end

    repeat (4) @(posedge clk);
    rst_n = 1'b1;

    @(posedge clk);
    if (!issue_ready)
        $fatal(1, "adapter should be ready after reset");

    issue_valid = 1'b1;
    @(posedge clk);
    issue_valid = 1'b0;

    cycle_count_i = 0;
    while (!result_valid && (cycle_count_i < MAX_WAIT_CYCLES)) begin
        @(posedge clk);
        cycle_count_i = cycle_count_i + 1;
    end

    if (!result_valid)
        $fatal(1,
               "adapter did not produce result within %0d cycles waited=%0d state=%0d map_state=%0d pos=%0d layer=%0d lo_reads=%0d hi_reads=%0d",
               MAX_WAIT_CYCLES,
               cycle_count_i,
               u_dut.state_r,
               u_dut.map_state_r,
               u_dut.fp16_current_position_w,
               u_dut.fp16_current_layer_debug_w,
               hbm_mapped_read_count_r,
               hbm_mapped_hi_read_count_r);
    #1;
    if (result_token_id !== issue_token_id)
        $fatal(1, "result_token_id must return original issue token");
    if (result_addr !== issue_dst_addr)
        $fatal(1, "result_addr mismatch");
    if (result_status !== 2'b00)
        $fatal(1, "result_status must stay OK");
    if (result_data[`SRAM_WDATA_W-1:16] !== '0)
        $fatal(1, "result_data upper bits should stay zero packed actual=%h", result_data);
    if (result_data[15:0] !== ref_token_i[15:0])
        $fatal(1, "generated token mismatch actual=%0d expected=%0d",
               result_data[15:0], ref_token_i);
    if (!saw_weight_window_read_r)
        $fatal(1, "adapter never translated layer HBM fetches into SRAM reads");
    if ((hbm_mapped_read_count_r == 0) || (hbm_mapped_hi_read_count_r == 0))
        $fatal(1, "adapter did not issue both halves of mapped HBM reads");

    result_ready = 1'b1;
    @(posedge clk);
    result_ready = 1'b0;

    $display("tb_fp16_inference_adapter PASS");
    $finish;
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        op_resp_valid <= 1'b0;
        op_resp_rdata <= '0;
        op_resp_id <= '0;
        op_resp_last <= 1'b0;
        pending_resp_valid_r <= 1'b0;
        pending_resp_data_r <= '0;
        pending_resp_id_r <= '0;
    end else begin
        op_resp_valid <= pending_resp_valid_r;
        op_resp_rdata <= pending_resp_data_r;
        op_resp_id <= pending_resp_id_r;
        op_resp_last <= pending_resp_valid_r;
        pending_resp_valid_r <= 1'b0;

        if (op_req_valid && op_req_ready) begin
            if (!op_req_last)
                $fatal(1, "adapter op_req_last should stay high");
            if (op_req_tag !== issue_token_id)
                $fatal(1, "adapter op_req_tag mismatch actual=%h expected=%h",
                       op_req_tag, issue_token_id);

            if (op_req_write) begin
                mem[op_req_addr] <= op_req_wdata;
                if (op_req_id !== issue_req_id)
                    $fatal(1, "adapter write req id mismatch actual=%h expected=%h",
                           op_req_id, issue_req_id);
            end else begin
                if ((op_req_addr >= HBM_MAPPED_SRAM_BASE) &&
                    (op_req_addr < (HBM_MAPPED_SRAM_BASE +
                                    (N_LAYERS * TOTAL_LAYER_PRELOAD_BEATS)))) begin
                    saw_weight_window_read_r <= 1'b1;
                    if (((op_req_addr - HBM_MAPPED_SRAM_BASE) % HBM_TO_SRAM_RATIO) == 0)
                        hbm_mapped_read_count_r = hbm_mapped_read_count_r + 1;
                    else
                        hbm_mapped_hi_read_count_r = hbm_mapped_hi_read_count_r + 1;
                end
                pending_resp_valid_r <= 1'b1;
                pending_resp_data_r <= mem[op_req_addr];
                pending_resp_id_r <= op_req_id;
            end
        end
    end
end

endmodule
