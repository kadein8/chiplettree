`timescale 1ns/1ps

`include "config/interface_params.vh"
`include "config/memory_params.vh"
`include "config/model_params.vh"

module tb_integration_operator_part_fp16_gemm_min;

localparam integer MODEL_ID_W = 8;
localparam integer OP_CLASS_W = 8;
localparam integer TOKEN_LEN_W = 16;
localparam integer RESULT_STATUS_W = 2;
localparam integer DATA_WIDTH = 16;
localparam integer LANES = `FP16_TILE_LANES;
localparam integer COLS = `FP16_TILE_COLS;
localparam integer ELEMS_PER_BEAT = `SRAM_WDATA_W / DATA_WIDTH;
localparam integer WEIGHT_WORDS = LANES * COLS;
localparam integer WEIGHT_BEATS = WEIGHT_WORDS / ELEMS_PER_BEAT;
localparam integer VECTOR_BEATS = COLS / ELEMS_PER_BEAT;
localparam integer RESULT_BEATS = LANES / ELEMS_PER_BEAT;
localparam [DATA_WIDTH-1:0] FP_ZERO = 16'h0000;
localparam [DATA_WIDTH-1:0] FP_HALF = 16'h3800;
localparam [DATA_WIDTH-1:0] FP_ONE = 16'h3c00;
localparam [DATA_WIDTH-1:0] FP_128 = 16'h5800;
localparam [DATA_WIDTH-1:0] FP_TWO = 16'h4000;
localparam [DATA_WIDTH-1:0] FP_FOUR = 16'h4400;
localparam [DATA_WIDTH-1:0] FP_EIGHT = 16'h4800;
localparam [DATA_WIDTH-1:0] FP_16 = 16'h4c00;
localparam [DATA_WIDTH-1:0] FP_32 = 16'h5000;
localparam [DATA_WIDTH-1:0] FP_64 = 16'h5400;
localparam [DATA_WIDTH-1:0] FP_256 = 16'h5c00;
localparam [DATA_WIDTH-1:0] FP_512 = 16'h6000;
localparam [DATA_WIDTH-1:0] FP_1024 = 16'h6400;
localparam [`SRAM_WDATA_W-1:0] EVEN_WEIGHT_BEAT = {
    FP_EIGHT, FP_FOUR, FP_TWO, FP_ONE, FP_HALF, FP_FOUR, FP_TWO, FP_ZERO
};
localparam [`SRAM_WDATA_W-1:0] ODD_WEIGHT_BEAT = {
    FP_EIGHT, FP_FOUR, FP_TWO, FP_ONE, FP_HALF, FP_EIGHT, FP_FOUR, FP_TWO
};
localparam [`SRAM_WDATA_W-1:0] EXP_RESULT_BEAT0 = {
    FP_1024, FP_512, FP_256, FP_128, FP_64, FP_512, FP_256, FP_ZERO
};
localparam [`SRAM_WDATA_W-1:0] EXP_RESULT_BEAT1 = {
    FP_1024, FP_512, FP_256, FP_128, FP_64, FP_1024, FP_512, FP_256
};
localparam [`SRAM_WDATA_W-1:0] EXP_RESULT_SUMMARY = EXP_RESULT_BEAT0;

reg clk;
reg rst_n;

reg issue_valid;
wire issue_ready;
reg [`TOKEN_ID_W-1:0] issue_token_id;
reg [`BRANCH_ID_W-1:0] issue_branch_id;
reg [1:0] issue_epoch;
reg [MODEL_ID_W-1:0] issue_model_id;
reg [OP_CLASS_W-1:0] issue_op_class;
reg [`SRAM_ADDR_W-1:0] issue_src_addr;
reg [`SRAM_ADDR_W-1:0] issue_dst_addr;
reg [TOKEN_LEN_W-1:0] issue_token_len;
reg [`REQ_ID_W-1:0] issue_req_id;
reg [1:0] issue_flush_epoch;

wire op_req_valid;
reg op_req_ready;
wire op_req_write;
wire [`SRAM_ADDR_W-1:0] op_req_addr;
wire [`SRAM_WDATA_W-1:0] op_req_wdata;
wire [`REQ_ID_W-1:0] op_req_id;
wire op_req_last;
wire [`TOKEN_ID_W-1:0] op_req_tag;

reg op_resp_valid;
wire op_resp_ready;
reg [`SRAM_RDATA_W-1:0] op_resp_rdata;
reg [`REQ_ID_W-1:0] op_resp_id;
reg op_resp_last;
reg hbm_resp_valid;
reg [`HBM_DATA_W-1:0] hbm_resp_rdata;
reg [`REQ_ID_W-1:0] hbm_resp_id;

wire result_valid;
reg result_ready;
wire [`TOKEN_ID_W-1:0] result_token_id;
wire [`SRAM_ADDR_W-1:0] result_addr;
wire [`SRAM_WDATA_W-1:0] result_data;
wire [RESULT_STATUS_W-1:0] result_status;
wire hbm_req_valid;
wire hbm_req_write;
wire [`HBM_ADDR_W-1:0] hbm_req_addr;
wire [`HBM_DATA_W-1:0] hbm_req_wdata;
wire [`REQ_ID_W-1:0] hbm_req_id;
wire debug_decoder_qkv_valid;
wire debug_decoder_score_valid;
wire debug_decoder_softmax_valid;
wire debug_decoder_value_valid;
wire debug_decoder_ffn_valid;

reg [`SRAM_RDATA_W-1:0] backing_mem [0:(WEIGHT_BEATS + VECTOR_BEATS - 1)];
integer beat_idx_i;
integer elem_idx_i;
integer req_addr_offset_i;
integer read_req_count_r;
integer read_resp_count_r;
integer write_req_count_r;
integer cycle_count_r;
reg pending_resp_valid_r;
reg [`SRAM_RDATA_W-1:0] pending_resp_data_r;
reg [`REQ_ID_W-1:0] pending_resp_id_r;

IntegrationOperatorPart #(
    .MODEL_ID_W(MODEL_ID_W),
    .OP_CLASS_W(OP_CLASS_W),
    .TOKEN_LEN_W(TOKEN_LEN_W),
    .RESULT_STATUS_W(RESULT_STATUS_W),
    .USE_FP16_GEMM(1)
) u_integration_operator_part (
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
    .issue_tree_mask_en(1'b0),
    .issue_tree_mask_branch_id({`BRANCH_ID_W{1'b0}}),
    .issue_prefix_len(16'd0),
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
    .hbm_resp_valid(hbm_resp_valid),
    .hbm_resp_rdata(hbm_resp_rdata),
    .hbm_resp_id(hbm_resp_id),
    .hbm_req_valid(hbm_req_valid),
    .hbm_req_write(hbm_req_write),
    .hbm_req_addr(hbm_req_addr),
    .hbm_req_wdata(hbm_req_wdata),
    .hbm_req_id(hbm_req_id),
    .result_valid(result_valid),
    .result_ready(result_ready),
    .result_token_id(result_token_id),
    .result_addr(result_addr),
    .result_data(result_data),
    .result_status(result_status),
    .debug_decoder_qkv_valid(debug_decoder_qkv_valid),
    .debug_decoder_score_valid(debug_decoder_score_valid),
    .debug_decoder_softmax_valid(debug_decoder_softmax_valid),
    .debug_decoder_value_valid(debug_decoder_value_valid),
    .debug_decoder_ffn_valid(debug_decoder_ffn_valid)
);

always #5 clk = ~clk;

task init_backing_mem;
    begin
        for (beat_idx_i = 0; beat_idx_i < WEIGHT_BEATS; beat_idx_i = beat_idx_i + 1) begin
            if ((beat_idx_i % 2) == 0) begin
                backing_mem[beat_idx_i] = EVEN_WEIGHT_BEAT;
            end else begin
                backing_mem[beat_idx_i] = ODD_WEIGHT_BEAT;
            end
        end
        for (beat_idx_i = WEIGHT_BEATS; beat_idx_i < (WEIGHT_BEATS + VECTOR_BEATS); beat_idx_i = beat_idx_i + 1) begin
            backing_mem[beat_idx_i] = {`SRAM_RDATA_W{1'b0}};
            for (elem_idx_i = 0; elem_idx_i < ELEMS_PER_BEAT; elem_idx_i = elem_idx_i + 1) begin
                backing_mem[beat_idx_i][(elem_idx_i*DATA_WIDTH) +: DATA_WIDTH] = FP_ONE;
            end
        end
    end
endtask

initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    issue_valid = 1'b0;
    issue_token_id = 16'h3311;
    issue_branch_id = 2'd0;
    issue_epoch = 2'd0;
    issue_model_id = 8'h01;
    issue_op_class = 8'h02;
    issue_src_addr = {`SRAM_ADDR_W{1'b0}};
    issue_dst_addr = {{(`SRAM_ADDR_W-4){1'b0}}, 4'h8};
    issue_token_len = COLS;
    issue_req_id = 4'h5;
    issue_flush_epoch = 2'd0;
    op_req_ready = 1'b1;
    op_resp_valid = 1'b0;
    op_resp_rdata = {`SRAM_RDATA_W{1'b0}};
    op_resp_id = {`REQ_ID_W{1'b0}};
    op_resp_last = 1'b1;
    hbm_resp_valid = 1'b0;
    hbm_resp_rdata = {`HBM_DATA_W{1'b0}};
    hbm_resp_id = {`REQ_ID_W{1'b0}};
    result_ready = 1'b0;
    pending_resp_valid_r = 1'b0;
    pending_resp_data_r = {`SRAM_RDATA_W{1'b0}};
    pending_resp_id_r = {`REQ_ID_W{1'b0}};
    read_req_count_r = 0;
    read_resp_count_r = 0;
    write_req_count_r = 0;
    init_backing_mem();

    repeat (2) @(posedge clk);
    rst_n = 1'b1;

    @(posedge clk);
    if (!issue_ready) begin
        $fatal(1, "fp16 gemm operator should be ready after reset");
    end

    issue_valid = 1'b1;
    @(posedge clk);
    issue_valid = 1'b0;

    cycle_count_r = 0;
    while (!result_valid && (cycle_count_r < 2048)) begin
        @(posedge clk);
        cycle_count_r = cycle_count_r + 1;
    end

    if (!result_valid) begin
        $fatal(1, "fp16 gemm operator did not produce result");
    end
    #1;
    if (result_token_id !== issue_token_id) begin
        $fatal(1, "fp16 gemm result token mismatch");
    end
    if (result_addr !== issue_dst_addr) begin
        $fatal(1, "fp16 gemm result addr mismatch");
    end
    if (result_status !== 2'b00) begin
        $fatal(1, "fp16 gemm result status mismatch");
    end
    if (result_data !== EXP_RESULT_SUMMARY) begin
        $fatal(1, "fp16 gemm result data mismatch actual=%h", result_data);
    end
    if (write_req_count_r != RESULT_BEATS) begin
        $fatal(1, "fp16 gemm write beat count mismatch actual=%0d expected=%0d",
               write_req_count_r, RESULT_BEATS);
    end
    if (read_req_count_r != (WEIGHT_BEATS + VECTOR_BEATS)) begin
        $fatal(1, "fp16 gemm read request count mismatch actual=%0d expected=%0d",
               read_req_count_r, WEIGHT_BEATS + VECTOR_BEATS);
    end
    if (read_resp_count_r != (WEIGHT_BEATS + VECTOR_BEATS)) begin
        $fatal(1, "fp16 gemm read response count mismatch actual=%0d expected=%0d",
               read_resp_count_r, WEIGHT_BEATS + VECTOR_BEATS);
    end

    result_ready = 1'b1;
    @(posedge clk);
    result_ready = 1'b0;

    $display("tb_integration_operator_part_fp16_gemm_min PASS");
    $finish;
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        op_resp_valid <= 1'b0;
        op_resp_rdata <= {`SRAM_RDATA_W{1'b0}};
        op_resp_id <= {`REQ_ID_W{1'b0}};
        op_resp_last <= 1'b0;
        pending_resp_valid_r <= 1'b0;
        pending_resp_data_r <= {`SRAM_RDATA_W{1'b0}};
        pending_resp_id_r <= {`REQ_ID_W{1'b0}};
    end else begin
        op_resp_valid <= pending_resp_valid_r;
        op_resp_rdata <= pending_resp_data_r;
        op_resp_id <= pending_resp_id_r;
        op_resp_last <= pending_resp_valid_r;
        pending_resp_valid_r <= 1'b0;

        if (op_req_valid && op_req_ready) begin
            if (op_req_id !== issue_req_id) begin
                $fatal(1, "fp16 gemm op_req_id mismatch actual=%h expected=%h",
                       op_req_id, issue_req_id);
            end
            if (!op_req_last) begin
                $fatal(1, "fp16 gemm op_req_last should stay high per beat");
            end
            if (op_req_tag !== issue_token_id) begin
                $fatal(1, "fp16 gemm op_req_tag mismatch actual=%h expected=%h",
                       op_req_tag, issue_token_id);
            end

            req_addr_offset_i = op_req_addr - issue_src_addr;
            if (!op_req_write) begin
                if (req_addr_offset_i !== read_req_count_r) begin
                    $fatal(1, "fp16 gemm read addr mismatch actual_offset=%0d expected_offset=%0d",
                           req_addr_offset_i, read_req_count_r);
                end
                if (read_req_count_r >= (WEIGHT_BEATS + VECTOR_BEATS)) begin
                    $fatal(1, "fp16 gemm unexpected extra read request");
                end
                pending_resp_valid_r <= 1'b1;
                pending_resp_data_r <= backing_mem[read_req_count_r];
                pending_resp_id_r <= op_req_id;
                read_req_count_r = read_req_count_r + 1;
            end else begin
                if (op_req_addr !== (issue_dst_addr + write_req_count_r)) begin
                    $fatal(1, "fp16 gemm write addr mismatch actual=%h expected=%h",
                           op_req_addr, issue_dst_addr + write_req_count_r);
                end
                if ((write_req_count_r == 0) && (op_req_wdata !== EXP_RESULT_BEAT0)) begin
                    $fatal(1, "unexpected fp16 gemm write beat0 data %h", op_req_wdata);
                end
                if ((write_req_count_r == 1) && (op_req_wdata !== EXP_RESULT_BEAT1)) begin
                    $fatal(1, "unexpected fp16 gemm write beat1 data %h", op_req_wdata);
                end
                if (write_req_count_r > 1) begin
                    $fatal(1, "unexpected fp16 gemm write data %h", op_req_wdata);
                end
                write_req_count_r = write_req_count_r + 1;
            end
        end

        if (op_resp_valid && op_resp_ready) begin
            read_resp_count_r = read_resp_count_r + 1;
        end
    end
end

endmodule
