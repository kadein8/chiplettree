`include "config/interface_params.vh"
`include "config/memory_params.vh"
`include "config/model_params.vh"
`timescale 1ns/1ps

module fp16_transformer_layer #(
    parameter integer ADDR_W = `SRAM_ADDR_W,
    parameter integer DATA_WIDTH = `FP16_TILE_DATA_W,
    parameter integer DATA_BUS_W = `SRAM_WDATA_W,
    parameter integer REQ_ID_W = `REQ_ID_W,
    parameter integer RESULT_STATUS_W = 2,
    parameter integer HIDDEN_DIM = `TOY_DMODEL,
    parameter integer INTERMEDIATE_DIM = `TOY_INTERMEDIATE_DIM,
    parameter integer NUM_HEADS = `TOY_NUM_Q_HEADS,
    parameter integer HEAD_DIM = `TOY_HEAD_DIM,
    parameter integer MAX_ATTN_TOKENS = `TOY_MAX_POS_EMB,
    parameter [RESULT_STATUS_W-1:0] RESULT_STATUS_OK = 2'b00
) (
    input  logic                       clk,
    input  logic                       rst_n,
    input  logic                       issue_valid,
    output logic                       issue_ready,
    input  logic [ADDR_W-1:0]          issue_input_addr,
    input  logic [ADDR_W-1:0]          issue_pre_norm_gamma_addr,
    input  logic [ADDR_W-1:0]          issue_post_norm_gamma_addr,
    input  logic [ADDR_W-1:0]          issue_wq_addr,
    input  logic [ADDR_W-1:0]          issue_wk_addr,
    input  logic [ADDR_W-1:0]          issue_wv_addr,
    input  logic [ADDR_W-1:0]          issue_wo_addr,
    input  logic [ADDR_W-1:0]          issue_gate_w_addr,
    input  logic [ADDR_W-1:0]          issue_up_w_addr,
    input  logic [ADDR_W-1:0]          issue_down_w_addr,
    input  logic [ADDR_W-1:0]          issue_kv_cache_addr,
    input  logic [ADDR_W-1:0]          issue_result_addr,
    input  logic [ADDR_W-1:0]          issue_scratch_base_addr,
    input  logic [15:0]                issue_position,
    input  logic [4:0]                 issue_layer_id,
    input  logic [REQ_ID_W-1:0]        issue_req_id,
    input  logic                       issue_tree_mask_en,
    input  logic [`BRANCH_ID_W-1:0]    issue_branch_id,
    input  logic [15:0]                issue_prefix_len,
    input  logic [MAX_ATTN_TOKENS-1:0] issue_visible_mask,
    input  logic                       issue_tree_batch_en,
    input  logic [ADDR_W-1:0]          issue_tree_draft_kv_base,
    input  logic [`SLOT_ID_W-1:0]      issue_tree_query_slot,
    input  logic [4:0]                 issue_tree_slot_count,
    input  logic [`VERIFY_WINDOW_SIZE-1:0] issue_tree_visible_slots,
    input  logic [`VERIFY_WINDOW_SIZE-1:0] issue_tree_slot_is_seed,
    input  logic                       issue_tree_seed_kv_valid,

    output logic                       sram_rd_valid,
    input  logic                       sram_rd_ready,
    output logic [ADDR_W-1:0]          sram_rd_addr,
    output logic [REQ_ID_W-1:0]        sram_rd_id,
    input  logic                       sram_resp_valid,
    output logic                       sram_resp_ready,
    input  logic [DATA_BUS_W-1:0]      sram_resp_data,
    input  logic [REQ_ID_W-1:0]        sram_resp_id,
    output logic                       sram_wr_valid,
    input  logic                       sram_wr_ready,
    output logic [ADDR_W-1:0]          sram_wr_addr,
    output logic [DATA_BUS_W-1:0]      sram_wr_data,

    output logic                       result_valid,
    input  logic                       result_ready,
    output logic [ADDR_W-1:0]          result_addr,
    output logic [DATA_BUS_W-1:0]      result_data,
    output logic [RESULT_STATUS_W-1:0] result_status
);

localparam integer ELEMS_PER_BEAT = DATA_BUS_W / DATA_WIDTH;
localparam integer HIDDEN_BEATS = HIDDEN_DIM / ELEMS_PER_BEAT;
localparam integer INTERMEDIATE_BEATS = INTERMEDIATE_DIM / ELEMS_PER_BEAT;
localparam logic [3:0]
    ST_IDLE       = 4'd0,
    ST_PRE_ISSUE  = 4'd1,
    ST_PRE_WAIT   = 4'd2,
    ST_MHA_ISSUE  = 4'd3,
    ST_MHA_WAIT   = 4'd4,
    ST_RES1_ISSUE = 4'd5,
    ST_RES1_WAIT  = 4'd6,
    ST_POST_ISSUE = 4'd7,
    ST_POST_WAIT  = 4'd8,
    ST_FFN_ISSUE  = 4'd9,
    ST_FFN_WAIT   = 4'd10,
    ST_RES2_ISSUE = 4'd11,
    ST_RES2_WAIT  = 4'd12,
    ST_HOLD       = 4'd13;
localparam [REQ_ID_W-1:0] PRE_NORM_REQ_ID = 5'h13;
localparam [REQ_ID_W-1:0] MHA_REQ_ID = 5'h14;
localparam [REQ_ID_W-1:0] RES1_REQ_ID = 5'h15;
localparam [REQ_ID_W-1:0] POST_NORM_REQ_ID = 5'h16;
localparam [REQ_ID_W-1:0] FFN_REQ_ID = 5'h17;
localparam [REQ_ID_W-1:0] RES2_REQ_ID = 5'h18;

function automatic [ADDR_W-1:0] addr_from_u32;
    input [31:0] value;
    begin
        addr_from_u32 = value[ADDR_W-1:0];
    end
endfunction

logic [3:0] state_r;
logic [ADDR_W-1:0] input_addr_r;
logic [ADDR_W-1:0] pre_norm_gamma_addr_r;
logic [ADDR_W-1:0] post_norm_gamma_addr_r;
logic [ADDR_W-1:0] wq_addr_r;
logic [ADDR_W-1:0] wk_addr_r;
logic [ADDR_W-1:0] wv_addr_r;
logic [ADDR_W-1:0] wo_addr_r;
logic [ADDR_W-1:0] gate_w_addr_r;
logic [ADDR_W-1:0] up_w_addr_r;
logic [ADDR_W-1:0] down_w_addr_r;
logic [ADDR_W-1:0] kv_cache_addr_r;
logic [ADDR_W-1:0] result_addr_r;
logic [ADDR_W-1:0] scratch_base_addr_r;
logic [15:0] position_r;
logic [4:0] layer_id_r;
logic [REQ_ID_W-1:0] req_id_r;
logic tree_mask_en_r;
logic [`BRANCH_ID_W-1:0] branch_id_r;
logic [15:0] prefix_len_r;
logic [MAX_ATTN_TOKENS-1:0] visible_mask_r;
logic tree_batch_en_r;
logic [ADDR_W-1:0] tree_draft_kv_base_r;
logic [`SLOT_ID_W-1:0] tree_query_slot_r;
logic [4:0] tree_slot_count_r;
logic [`VERIFY_WINDOW_SIZE-1:0] tree_visible_slots_r;
logic [`VERIFY_WINDOW_SIZE-1:0] tree_slot_is_seed_r;
logic tree_seed_kv_valid_r;
logic [DATA_BUS_W-1:0] result_data_r;
logic [RESULT_STATUS_W-1:0] result_status_r;

wire [ADDR_W-1:0] pre_norm_out_base_w = scratch_base_addr_r;
wire [ADDR_W-1:0] mha_scratch_base_w = scratch_base_addr_r + HIDDEN_BEATS;
wire [ADDR_W-1:0] mha_out_base_w = scratch_base_addr_r + (HIDDEN_BEATS * 6);
wire [ADDR_W-1:0] post_norm_out_base_w = scratch_base_addr_r + (HIDDEN_BEATS * 7);
wire [ADDR_W-1:0] ffn_scratch_base_w = scratch_base_addr_r + (HIDDEN_BEATS * 8);
wire [ADDR_W-1:0] ffn_out_base_w = scratch_base_addr_r + (HIDDEN_BEATS * 8) + (INTERMEDIATE_BEATS * 3);

logic pre_issue_ready_w;
logic pre_rd_valid_w;
logic [ADDR_W-1:0] pre_rd_addr_w;
logic [REQ_ID_W-1:0] pre_rd_id_w;
logic pre_resp_ready_w;
logic pre_wr_valid_w;
logic [ADDR_W-1:0] pre_wr_addr_w;
logic [DATA_BUS_W-1:0] pre_wr_data_w;
logic pre_result_valid_w;
logic pre_result_ready_w;
logic [ADDR_W-1:0] pre_result_addr_w;
logic [DATA_BUS_W-1:0] pre_result_data_w;
logic [RESULT_STATUS_W-1:0] pre_result_status_w;

logic mha_issue_ready_w;
logic mha_rd_valid_w;
logic [ADDR_W-1:0] mha_rd_addr_w;
logic [REQ_ID_W-1:0] mha_rd_id_w;
logic mha_resp_ready_w;
logic mha_wr_valid_w;
logic [ADDR_W-1:0] mha_wr_addr_w;
logic [DATA_BUS_W-1:0] mha_wr_data_w;
logic mha_result_valid_w;
logic mha_result_ready_w;
logic [ADDR_W-1:0] mha_result_addr_w;
logic [DATA_BUS_W-1:0] mha_result_data_w;
logic [RESULT_STATUS_W-1:0] mha_result_status_w;

logic res1_issue_ready_w;
logic res1_rd_valid_w;
logic [ADDR_W-1:0] res1_rd_addr_w;
logic [REQ_ID_W-1:0] res1_rd_id_w;
logic res1_resp_ready_w;
logic res1_wr_valid_w;
logic [ADDR_W-1:0] res1_wr_addr_w;
logic [DATA_BUS_W-1:0] res1_wr_data_w;
logic res1_result_valid_w;
logic res1_result_ready_w;
logic [ADDR_W-1:0] res1_result_addr_w;
logic [DATA_BUS_W-1:0] res1_result_data_w;
logic [RESULT_STATUS_W-1:0] res1_result_status_w;

logic post_issue_ready_w;
logic post_rd_valid_w;
logic [ADDR_W-1:0] post_rd_addr_w;
logic [REQ_ID_W-1:0] post_rd_id_w;
logic post_resp_ready_w;
logic post_wr_valid_w;
logic [ADDR_W-1:0] post_wr_addr_w;
logic [DATA_BUS_W-1:0] post_wr_data_w;
logic post_result_valid_w;
logic post_result_ready_w;
logic [ADDR_W-1:0] post_result_addr_w;
logic [DATA_BUS_W-1:0] post_result_data_w;
logic [RESULT_STATUS_W-1:0] post_result_status_w;

logic ffn_issue_ready_w;
logic ffn_rd_valid_w;
logic [ADDR_W-1:0] ffn_rd_addr_w;
logic [REQ_ID_W-1:0] ffn_rd_id_w;
logic ffn_resp_ready_w;
logic ffn_wr_valid_w;
logic [ADDR_W-1:0] ffn_wr_addr_w;
logic [DATA_BUS_W-1:0] ffn_wr_data_w;
logic ffn_result_valid_w;
logic ffn_result_ready_w;
logic [ADDR_W-1:0] ffn_result_addr_w;
logic [DATA_BUS_W-1:0] ffn_result_data_w;
logic [RESULT_STATUS_W-1:0] ffn_result_status_w;

logic res2_issue_ready_w;
logic res2_rd_valid_w;
logic [ADDR_W-1:0] res2_rd_addr_w;
logic [REQ_ID_W-1:0] res2_rd_id_w;
logic res2_resp_ready_w;
logic res2_wr_valid_w;
logic [ADDR_W-1:0] res2_wr_addr_w;
logic [DATA_BUS_W-1:0] res2_wr_data_w;
logic res2_result_valid_w;
logic res2_result_ready_w;
logic [ADDR_W-1:0] res2_result_addr_w;
logic [DATA_BUS_W-1:0] res2_result_data_w;
logic [RESULT_STATUS_W-1:0] res2_result_status_w;

fp16_rmsnorm #(
    .DATA_WIDTH(DATA_WIDTH),
    .ADDR_W(ADDR_W),
    .DATA_BUS_W(DATA_BUS_W),
    .REQ_ID_W(REQ_ID_W),
    .VECTOR_LEN(HIDDEN_DIM),
    .RESULT_STATUS_W(RESULT_STATUS_W),
    .RESULT_STATUS_OK(RESULT_STATUS_OK)
) u_pre_rmsnorm (
    .clk(clk),
    .rst_n(rst_n),
    .issue_valid(state_r == ST_PRE_ISSUE),
    .issue_ready(pre_issue_ready_w),
    .issue_x_addr(input_addr_r),
    .issue_gamma_addr(pre_norm_gamma_addr_r),
    .issue_result_addr(pre_norm_out_base_w),
    .issue_req_id(PRE_NORM_REQ_ID),
    .sram_rd_valid(pre_rd_valid_w),
    .sram_rd_ready(sram_rd_ready),
    .sram_rd_addr(pre_rd_addr_w),
    .sram_rd_id(pre_rd_id_w),
    .sram_resp_valid(sram_resp_valid),
    .sram_resp_ready(pre_resp_ready_w),
    .sram_resp_data(sram_resp_data),
    .sram_resp_id(sram_resp_id),
    .sram_wr_valid(pre_wr_valid_w),
    .sram_wr_ready(sram_wr_ready),
    .sram_wr_addr(pre_wr_addr_w),
    .sram_wr_data(pre_wr_data_w),
    .result_valid(pre_result_valid_w),
    .result_ready(pre_result_ready_w),
    .result_addr(pre_result_addr_w),
    .result_data(pre_result_data_w),
    .result_status(pre_result_status_w)
);

fp16_mha_controller #(
    .ADDR_W(ADDR_W),
    .DATA_WIDTH(DATA_WIDTH),
    .DATA_BUS_W(DATA_BUS_W),
    .REQ_ID_W(REQ_ID_W),
    .RESULT_STATUS_W(RESULT_STATUS_W),
    .HIDDEN_DIM(HIDDEN_DIM),
    .NUM_HEADS(NUM_HEADS),
    .HEAD_DIM(HEAD_DIM),
    .MAX_ATTN_TOKENS(MAX_ATTN_TOKENS),
    .RESULT_STATUS_OK(RESULT_STATUS_OK)
) u_fp16_mha_controller (
    .clk(clk),
    .rst_n(rst_n),
    .issue_valid(state_r == ST_MHA_ISSUE),
    .issue_ready(mha_issue_ready_w),
    .issue_input_addr(pre_norm_out_base_w),
    .issue_wq_addr(wq_addr_r),
    .issue_wk_addr(wk_addr_r),
    .issue_wv_addr(wv_addr_r),
    .issue_wo_addr(wo_addr_r),
    .issue_kv_cache_addr(kv_cache_addr_r),
    .issue_result_addr(mha_out_base_w),
    .issue_scratch_base_addr(mha_scratch_base_w),
    .issue_position(position_r),
    .issue_layer_id(layer_id_r),
    .issue_req_id(MHA_REQ_ID),
    .issue_tree_mask_en(tree_mask_en_r),
    .issue_branch_id(branch_id_r),
    .issue_prefix_len(prefix_len_r),
    .issue_visible_mask(visible_mask_r),
    .issue_tree_batch_en(tree_batch_en_r),
    .issue_tree_draft_kv_base(tree_draft_kv_base_r),
    .issue_tree_query_slot(tree_query_slot_r),
    .issue_tree_slot_count(tree_slot_count_r),
    .issue_tree_visible_slots(tree_visible_slots_r),
    .issue_tree_slot_is_seed(tree_slot_is_seed_r),
    .issue_tree_seed_kv_valid(tree_seed_kv_valid_r),
    .issue_tree_kv_barrier_release(1'b1),
    .tree_kv_barrier_waiting(),
    .sram_rd_valid(mha_rd_valid_w),
    .sram_rd_ready(sram_rd_ready),
    .sram_rd_addr(mha_rd_addr_w),
    .sram_rd_id(mha_rd_id_w),
    .sram_resp_valid(sram_resp_valid),
    .sram_resp_ready(mha_resp_ready_w),
    .sram_resp_data(sram_resp_data),
    .sram_resp_id(sram_resp_id),
    .sram_wr_valid(mha_wr_valid_w),
    .sram_wr_ready(sram_wr_ready),
    .sram_wr_addr(mha_wr_addr_w),
    .sram_wr_data(mha_wr_data_w),
    .result_valid(mha_result_valid_w),
    .result_ready(mha_result_ready_w),
    .result_addr(mha_result_addr_w),
    .result_data(mha_result_data_w),
    .result_status(mha_result_status_w)
);

fp16_residual_add #(
    .DATA_WIDTH(DATA_WIDTH),
    .ADDR_W(ADDR_W),
    .DATA_BUS_W(DATA_BUS_W),
    .REQ_ID_W(REQ_ID_W),
    .VECTOR_LEN(HIDDEN_DIM),
    .RESULT_STATUS_W(RESULT_STATUS_W),
    .RESULT_STATUS_OK(RESULT_STATUS_OK)
) u_residual_add1 (
    .clk(clk),
    .rst_n(rst_n),
    .issue_valid(state_r == ST_RES1_ISSUE),
    .issue_ready(res1_issue_ready_w),
    .issue_x_addr(mha_out_base_w),
    .issue_residual_addr(input_addr_r),
    .issue_result_addr(result_addr_r),
    .issue_req_id(RES1_REQ_ID),
    .sram_rd_valid(res1_rd_valid_w),
    .sram_rd_ready(sram_rd_ready),
    .sram_rd_addr(res1_rd_addr_w),
    .sram_rd_id(res1_rd_id_w),
    .sram_resp_valid(sram_resp_valid),
    .sram_resp_ready(res1_resp_ready_w),
    .sram_resp_data(sram_resp_data),
    .sram_resp_id(sram_resp_id),
    .sram_wr_valid(res1_wr_valid_w),
    .sram_wr_ready(sram_wr_ready),
    .sram_wr_addr(res1_wr_addr_w),
    .sram_wr_data(res1_wr_data_w),
    .result_valid(res1_result_valid_w),
    .result_ready(res1_result_ready_w),
    .result_addr(res1_result_addr_w),
    .result_data(res1_result_data_w),
    .result_status(res1_result_status_w)
);

fp16_rmsnorm #(
    .DATA_WIDTH(DATA_WIDTH),
    .ADDR_W(ADDR_W),
    .DATA_BUS_W(DATA_BUS_W),
    .REQ_ID_W(REQ_ID_W),
    .VECTOR_LEN(HIDDEN_DIM),
    .RESULT_STATUS_W(RESULT_STATUS_W),
    .RESULT_STATUS_OK(RESULT_STATUS_OK)
) u_post_rmsnorm (
    .clk(clk),
    .rst_n(rst_n),
    .issue_valid(state_r == ST_POST_ISSUE),
    .issue_ready(post_issue_ready_w),
    .issue_x_addr(result_addr_r),
    .issue_gamma_addr(post_norm_gamma_addr_r),
    .issue_result_addr(post_norm_out_base_w),
    .issue_req_id(POST_NORM_REQ_ID),
    .sram_rd_valid(post_rd_valid_w),
    .sram_rd_ready(sram_rd_ready),
    .sram_rd_addr(post_rd_addr_w),
    .sram_rd_id(post_rd_id_w),
    .sram_resp_valid(sram_resp_valid),
    .sram_resp_ready(post_resp_ready_w),
    .sram_resp_data(sram_resp_data),
    .sram_resp_id(sram_resp_id),
    .sram_wr_valid(post_wr_valid_w),
    .sram_wr_ready(sram_wr_ready),
    .sram_wr_addr(post_wr_addr_w),
    .sram_wr_data(post_wr_data_w),
    .result_valid(post_result_valid_w),
    .result_ready(post_result_ready_w),
    .result_addr(post_result_addr_w),
    .result_data(post_result_data_w),
    .result_status(post_result_status_w)
);

fp16_ffn_swiglu #(
    .ADDR_W(ADDR_W),
    .DATA_WIDTH(DATA_WIDTH),
    .DATA_BUS_W(DATA_BUS_W),
    .REQ_ID_W(REQ_ID_W),
    .RESULT_STATUS_W(RESULT_STATUS_W),
    .HIDDEN_DIM(HIDDEN_DIM),
    .INTERMEDIATE_DIM(INTERMEDIATE_DIM),
    .RESULT_STATUS_OK(RESULT_STATUS_OK)
) u_fp16_ffn_swiglu (
    .clk(clk),
    .rst_n(rst_n),
    .issue_valid(state_r == ST_FFN_ISSUE),
    .issue_ready(ffn_issue_ready_w),
    .issue_input_addr(post_norm_out_base_w),
    .issue_gate_w_addr(gate_w_addr_r),
    .issue_up_w_addr(up_w_addr_r),
    .issue_down_w_addr(down_w_addr_r),
    .issue_result_addr(ffn_out_base_w),
    .issue_scratch_base_addr(ffn_scratch_base_w),
    .issue_req_id(FFN_REQ_ID),
    .sram_rd_valid(ffn_rd_valid_w),
    .sram_rd_ready(sram_rd_ready),
    .sram_rd_addr(ffn_rd_addr_w),
    .sram_rd_id(ffn_rd_id_w),
    .sram_resp_valid(sram_resp_valid),
    .sram_resp_ready(ffn_resp_ready_w),
    .sram_resp_data(sram_resp_data),
    .sram_resp_id(sram_resp_id),
    .sram_wr_valid(ffn_wr_valid_w),
    .sram_wr_ready(sram_wr_ready),
    .sram_wr_addr(ffn_wr_addr_w),
    .sram_wr_data(ffn_wr_data_w),
    .result_valid(ffn_result_valid_w),
    .result_ready(ffn_result_ready_w),
    .result_addr(ffn_result_addr_w),
    .result_data(ffn_result_data_w),
    .result_status(ffn_result_status_w)
);

fp16_residual_add #(
    .DATA_WIDTH(DATA_WIDTH),
    .ADDR_W(ADDR_W),
    .DATA_BUS_W(DATA_BUS_W),
    .REQ_ID_W(REQ_ID_W),
    .VECTOR_LEN(HIDDEN_DIM),
    .RESULT_STATUS_W(RESULT_STATUS_W),
    .RESULT_STATUS_OK(RESULT_STATUS_OK)
) u_residual_add2 (
    .clk(clk),
    .rst_n(rst_n),
    .issue_valid(state_r == ST_RES2_ISSUE),
    .issue_ready(res2_issue_ready_w),
    .issue_x_addr(ffn_out_base_w),
    .issue_residual_addr(result_addr_r),
    .issue_result_addr(result_addr_r),
    .issue_req_id(RES2_REQ_ID),
    .sram_rd_valid(res2_rd_valid_w),
    .sram_rd_ready(sram_rd_ready),
    .sram_rd_addr(res2_rd_addr_w),
    .sram_rd_id(res2_rd_id_w),
    .sram_resp_valid(sram_resp_valid),
    .sram_resp_ready(res2_resp_ready_w),
    .sram_resp_data(sram_resp_data),
    .sram_resp_id(sram_resp_id),
    .sram_wr_valid(res2_wr_valid_w),
    .sram_wr_ready(sram_wr_ready),
    .sram_wr_addr(res2_wr_addr_w),
    .sram_wr_data(res2_wr_data_w),
    .result_valid(res2_result_valid_w),
    .result_ready(res2_result_ready_w),
    .result_addr(res2_result_addr_w),
    .result_data(res2_result_data_w),
    .result_status(res2_result_status_w)
);

assign pre_result_ready_w = (state_r == ST_PRE_WAIT);
assign mha_result_ready_w = (state_r == ST_MHA_WAIT);
assign res1_result_ready_w = (state_r == ST_RES1_WAIT);
assign post_result_ready_w = (state_r == ST_POST_WAIT);
assign ffn_result_ready_w = (state_r == ST_FFN_WAIT);
assign res2_result_ready_w = (state_r == ST_RES2_WAIT);

assign issue_ready = (state_r == ST_IDLE);
assign result_valid = (state_r == ST_HOLD);
assign result_addr = result_addr_r;
assign result_data = result_data_r;
assign result_status = result_status_r;

always_comb begin
    sram_rd_valid = 1'b0;
    sram_rd_addr = {ADDR_W{1'b0}};
    sram_rd_id = {REQ_ID_W{1'b0}};
    sram_resp_ready = 1'b0;
    sram_wr_valid = 1'b0;
    sram_wr_addr = {ADDR_W{1'b0}};
    sram_wr_data = {DATA_BUS_W{1'b0}};

    case (state_r)
        ST_PRE_ISSUE,
        ST_PRE_WAIT: begin
            sram_rd_valid = pre_rd_valid_w;
            sram_rd_addr = pre_rd_addr_w;
            sram_rd_id = pre_rd_id_w;
            sram_resp_ready = pre_resp_ready_w;
            sram_wr_valid = pre_wr_valid_w;
            sram_wr_addr = pre_wr_addr_w;
            sram_wr_data = pre_wr_data_w;
        end

        ST_MHA_ISSUE,
        ST_MHA_WAIT: begin
            sram_rd_valid = mha_rd_valid_w;
            sram_rd_addr = mha_rd_addr_w;
            sram_rd_id = mha_rd_id_w;
            sram_resp_ready = mha_resp_ready_w;
            sram_wr_valid = mha_wr_valid_w;
            sram_wr_addr = mha_wr_addr_w;
            sram_wr_data = mha_wr_data_w;
        end

        ST_RES1_ISSUE,
        ST_RES1_WAIT: begin
            sram_rd_valid = res1_rd_valid_w;
            sram_rd_addr = res1_rd_addr_w;
            sram_rd_id = res1_rd_id_w;
            sram_resp_ready = res1_resp_ready_w;
            sram_wr_valid = res1_wr_valid_w;
            sram_wr_addr = res1_wr_addr_w;
            sram_wr_data = res1_wr_data_w;
        end

        ST_POST_ISSUE,
        ST_POST_WAIT: begin
            sram_rd_valid = post_rd_valid_w;
            sram_rd_addr = post_rd_addr_w;
            sram_rd_id = post_rd_id_w;
            sram_resp_ready = post_resp_ready_w;
            sram_wr_valid = post_wr_valid_w;
            sram_wr_addr = post_wr_addr_w;
            sram_wr_data = post_wr_data_w;
        end

        ST_FFN_ISSUE,
        ST_FFN_WAIT: begin
            sram_rd_valid = ffn_rd_valid_w;
            sram_rd_addr = ffn_rd_addr_w;
            sram_rd_id = ffn_rd_id_w;
            sram_resp_ready = ffn_resp_ready_w;
            sram_wr_valid = ffn_wr_valid_w;
            sram_wr_addr = ffn_wr_addr_w;
            sram_wr_data = ffn_wr_data_w;
        end

        ST_RES2_ISSUE,
        ST_RES2_WAIT: begin
            sram_rd_valid = res2_rd_valid_w;
            sram_rd_addr = res2_rd_addr_w;
            sram_rd_id = res2_rd_id_w;
            sram_resp_ready = res2_resp_ready_w;
            sram_wr_valid = res2_wr_valid_w;
            sram_wr_addr = res2_wr_addr_w;
            sram_wr_data = res2_wr_data_w;
        end

        default: begin
        end
    endcase
end

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state_r <= ST_IDLE;
        input_addr_r <= {ADDR_W{1'b0}};
        pre_norm_gamma_addr_r <= {ADDR_W{1'b0}};
        post_norm_gamma_addr_r <= {ADDR_W{1'b0}};
        wq_addr_r <= {ADDR_W{1'b0}};
        wk_addr_r <= {ADDR_W{1'b0}};
        wv_addr_r <= {ADDR_W{1'b0}};
        wo_addr_r <= {ADDR_W{1'b0}};
        gate_w_addr_r <= {ADDR_W{1'b0}};
        up_w_addr_r <= {ADDR_W{1'b0}};
        down_w_addr_r <= {ADDR_W{1'b0}};
        kv_cache_addr_r <= {ADDR_W{1'b0}};
        result_addr_r <= {ADDR_W{1'b0}};
        scratch_base_addr_r <= {ADDR_W{1'b0}};
        position_r <= 16'd0;
        layer_id_r <= 5'd0;
        req_id_r <= {REQ_ID_W{1'b0}};
        tree_mask_en_r <= 1'b0;
        branch_id_r <= {`BRANCH_ID_W{1'b0}};
        prefix_len_r <= 16'd0;
        visible_mask_r <= {MAX_ATTN_TOKENS{1'b0}};
        tree_batch_en_r <= 1'b0;
        tree_draft_kv_base_r <= {ADDR_W{1'b0}};
        tree_query_slot_r <= {`SLOT_ID_W{1'b0}};
        tree_slot_count_r <= 5'd0;
        tree_visible_slots_r <= {`VERIFY_WINDOW_SIZE{1'b0}};
        tree_slot_is_seed_r <= {`VERIFY_WINDOW_SIZE{1'b0}};
        tree_seed_kv_valid_r <= 1'b0;
        result_data_r <= {DATA_BUS_W{1'b0}};
        result_status_r <= {RESULT_STATUS_W{1'b0}};
    end else begin
        case (state_r)
            ST_IDLE: begin
                if (issue_valid) begin
                    input_addr_r <= issue_input_addr;
                    pre_norm_gamma_addr_r <= issue_pre_norm_gamma_addr;
                    post_norm_gamma_addr_r <= issue_post_norm_gamma_addr;
                    wq_addr_r <= issue_wq_addr;
                    wk_addr_r <= issue_wk_addr;
                    wv_addr_r <= issue_wv_addr;
                    wo_addr_r <= issue_wo_addr;
                    gate_w_addr_r <= issue_gate_w_addr;
                    up_w_addr_r <= issue_up_w_addr;
                    down_w_addr_r <= issue_down_w_addr;
                    kv_cache_addr_r <= issue_kv_cache_addr;
                    result_addr_r <= issue_result_addr;
                    scratch_base_addr_r <= issue_scratch_base_addr;
                    position_r <= issue_position;
                    layer_id_r <= issue_layer_id;
                    req_id_r <= issue_req_id;
                    tree_mask_en_r <= issue_tree_mask_en;
                    branch_id_r <= issue_branch_id;
                    prefix_len_r <= issue_prefix_len;
                    visible_mask_r <= issue_visible_mask;
                    tree_batch_en_r <= issue_tree_batch_en;
                    tree_draft_kv_base_r <= issue_tree_draft_kv_base;
                    tree_query_slot_r <= issue_tree_query_slot;
                    tree_slot_count_r <= issue_tree_slot_count;
                    tree_visible_slots_r <= issue_tree_visible_slots;
                    tree_slot_is_seed_r <= issue_tree_slot_is_seed;
                    tree_seed_kv_valid_r <= issue_tree_seed_kv_valid;
                    result_data_r <= {DATA_BUS_W{1'b0}};
                    result_status_r <= RESULT_STATUS_OK;
                    state_r <= ST_PRE_ISSUE;
                end
            end

            ST_PRE_ISSUE: begin
                if (pre_issue_ready_w)
                    state_r <= ST_PRE_WAIT;
            end

            ST_PRE_WAIT: begin
                if (pre_result_valid_w && pre_result_ready_w)
                    state_r <= ST_MHA_ISSUE;
            end

            ST_MHA_ISSUE: begin
                if (mha_issue_ready_w)
                    state_r <= ST_MHA_WAIT;
            end

            ST_MHA_WAIT: begin
                if (mha_result_valid_w && mha_result_ready_w)
                    state_r <= ST_RES1_ISSUE;
            end

            ST_RES1_ISSUE: begin
                if (res1_issue_ready_w)
                    state_r <= ST_RES1_WAIT;
            end

            ST_RES1_WAIT: begin
                if (res1_result_valid_w && res1_result_ready_w)
                    state_r <= ST_POST_ISSUE;
            end

            ST_POST_ISSUE: begin
                if (post_issue_ready_w)
                    state_r <= ST_POST_WAIT;
            end

            ST_POST_WAIT: begin
                if (post_result_valid_w && post_result_ready_w)
                    state_r <= ST_FFN_ISSUE;
            end

            ST_FFN_ISSUE: begin
                if (ffn_issue_ready_w)
                    state_r <= ST_FFN_WAIT;
            end

            ST_FFN_WAIT: begin
                if (ffn_result_valid_w && ffn_result_ready_w)
                    state_r <= ST_RES2_ISSUE;
            end

            ST_RES2_ISSUE: begin
                if (res2_issue_ready_w)
                    state_r <= ST_RES2_WAIT;
            end

            ST_RES2_WAIT: begin
                if (res2_result_valid_w && res2_result_ready_w) begin
                    result_data_r <= res2_result_data_w;
                    result_status_r <= res2_result_status_w;
                    state_r <= ST_HOLD;
                end
            end

            ST_HOLD: begin
                if (result_valid && result_ready)
                    state_r <= ST_IDLE;
            end

            default: begin
                state_r <= ST_IDLE;
            end
        endcase
    end
end

endmodule
