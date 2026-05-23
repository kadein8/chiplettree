`ifndef FP16_MHA_TREE_ATTENTION_SV
`define FP16_MHA_TREE_ATTENTION_SV
`include "config/interface_params.vh"
`include "config/memory_params.vh"
`include "config/model_params.vh"
`include "transformer/fp16_rmsnorm.sv"
`include "transformer/fp16_mha_controller.sv"
`include "transformer/fp16_residual_add.sv"
`include "transformer/fp16_ffn_swiglu.sv"
`timescale 1ns/1ps

module fp16_mha_tree_attention #(
    parameter integer ADDR_W                 = `SRAM_ADDR_W,
    parameter integer DATA_WIDTH             = `FP16_TILE_DATA_W,
    parameter integer DATA_BUS_W             = `SRAM_WDATA_W,
    parameter integer REQ_ID_W               = `REQ_ID_W,
    parameter integer HIDDEN_DIM             = `TOY_DMODEL,
    parameter integer INTERMEDIATE_DIM       = `TOY_INTERMEDIATE_DIM,
    parameter integer NUM_HEADS              = `TOY_NUM_Q_HEADS,
    parameter integer HEAD_DIM               = `TOY_HEAD_DIM,
    parameter integer MAX_ATTN_TOKENS        = `TOY_MAX_POS_EMB,
    parameter integer WINDOW_SIZE            = `VERIFY_WINDOW_SIZE,
    parameter integer SLOT_ID_W              = `SLOT_ID_W,
    parameter integer KV_LAYER_STRIDE        = 4096,
    parameter integer ELEMS_PER_BEAT         = DATA_BUS_W / DATA_WIDTH,
    parameter integer HIDDEN_BEATS           = HIDDEN_DIM / ELEMS_PER_BEAT,
    parameter integer INTERMEDIATE_BEATS     = INTERMEDIATE_DIM / ELEMS_PER_BEAT,
    parameter integer SLOT_SCRATCH_STRIDE    = (HIDDEN_BEATS * 9) + (INTERMEDIATE_BEATS * 3),
    parameter [ADDR_W-1:0] KV_COMMITTED_BASE = `KV_COMMITTED_BASE,
    parameter [ADDR_W-1:0] KV_DRAFT_BASE     = `KV_DRAFT_BASE_MIN
) (
    input  logic                               clk,
    input  logic                               rst_n,
    input  logic                               issue_valid,
    output logic                               issue_ready,
    input  logic [4:0]                         issue_slot_count,
    input  logic [15:0]                        issue_prefix_len,
    input  logic [WINDOW_SIZE*32-1:0]          issue_token_ids,
    input  logic [WINDOW_SIZE*16-1:0]          issue_positions,
    input  logic [WINDOW_SIZE*WINDOW_SIZE-1:0] issue_tree_mask,
    input  logic [WINDOW_SIZE-1:0]             issue_slot_is_seed,
    input  logic                               issue_seed_kv_valid,
    input  logic [4:0]                         issue_layer_id,
    input  logic [ADDR_W-1:0]                  issue_input_base_addr,
    input  logic [ADDR_W-1:0]                  issue_result_base_addr,
    input  logic [ADDR_W-1:0]                  issue_pre_norm_gamma_addr,
    input  logic [ADDR_W-1:0]                  issue_post_norm_gamma_addr,
    input  logic [ADDR_W-1:0]                  issue_wq_addr,
    input  logic [ADDR_W-1:0]                  issue_wk_addr,
    input  logic [ADDR_W-1:0]                  issue_wv_addr,
    input  logic [ADDR_W-1:0]                  issue_wo_addr,
    input  logic [ADDR_W-1:0]                  issue_gate_w_addr,
    input  logic [ADDR_W-1:0]                  issue_up_w_addr,
    input  logic [ADDR_W-1:0]                  issue_down_w_addr,
    input  logic [ADDR_W-1:0]                  issue_scratch_base_addr,
    output logic                               sram_rd_valid,
    input  logic                               sram_rd_ready,
    output logic [ADDR_W-1:0]                  sram_rd_addr,
    output logic [REQ_ID_W-1:0]                sram_rd_id,
    input  logic                               sram_resp_valid,
    output logic                               sram_resp_ready,
    input  logic [DATA_BUS_W-1:0]              sram_resp_data,
    input  logic [REQ_ID_W-1:0]                sram_resp_id,
    output logic                               sram_wr_valid,
    input  logic                               sram_wr_ready,
    output logic [ADDR_W-1:0]                  sram_wr_addr,
    output logic [DATA_BUS_W-1:0]              sram_wr_data,
    output logic [`MEM_REQ_LANES-1:0]          vec_sram_rd_valid,
    input  logic [`MEM_REQ_LANES-1:0]          vec_sram_rd_ready,
    output logic [`MEM_REQ_LANES*ADDR_W-1:0]   vec_sram_rd_addr,
    output logic [`MEM_REQ_LANES*REQ_ID_W-1:0] vec_sram_rd_id,
    output logic [`MEM_REQ_LANES*`PE_MASK_W-1:0] vec_sram_rd_pe_mask,
    input  logic [`MEM_REQ_LANES-1:0]          vec_sram_resp_valid,
    output logic [`MEM_REQ_LANES-1:0]          vec_sram_resp_ready,
    input  logic [`MEM_REQ_LANES*DATA_BUS_W-1:0] vec_sram_resp_data,
    input  logic [`MEM_REQ_LANES*REQ_ID_W-1:0] vec_sram_resp_id,
    output logic [`MEM_REQ_LANES-1:0]          vec_sram_wr_valid,
    input  logic [`MEM_REQ_LANES-1:0]          vec_sram_wr_ready,
    output logic [`MEM_REQ_LANES*ADDR_W-1:0]   vec_sram_wr_addr,
    output logic [`MEM_REQ_LANES*DATA_BUS_W-1:0] vec_sram_wr_data,
    output logic [`MEM_REQ_LANES*REQ_ID_W-1:0] vec_sram_wr_id,
    output logic [`MEM_REQ_LANES*`PE_MASK_W-1:0] vec_sram_wr_pe_mask,
    output logic                               result_valid,
    input  logic                               result_ready,
    output logic [ADDR_W-1:0]                  result_base_addr,
    output logic [4:0]                         result_slot_count,
    output logic [WINDOW_SIZE*32-1:0]          result_token_ids
);

localparam logic [4:0]
    ST_IDLE             = 5'd0,
    ST_PRE_ISSUE        = 5'd1,
    ST_PRE_WAIT         = 5'd2,
    ST_PRE_NEXT         = 5'd3,
    ST_MHA_SEED_ISSUE   = 5'd4,
    ST_MHA_SEED_WAIT    = 5'd5,
    ST_MHA_DRAFT_ISSUE  = 5'd6,
    ST_MHA_DRAFT_WAIT   = 5'd7,
    ST_RES1_SEED_ISSUE  = 5'd8,
    ST_RES1_SEED_WAIT   = 5'd9,
    ST_RES1_DRAFT_ISSUE = 5'd10,
    ST_RES1_DRAFT_WAIT  = 5'd11,
    ST_POST_SEED_ISSUE  = 5'd12,
    ST_POST_SEED_WAIT   = 5'd13,
    ST_POST_DRAFT_ISSUE = 5'd14,
    ST_POST_DRAFT_WAIT  = 5'd15,
    ST_FFN_SEED_ISSUE   = 5'd16,
    ST_FFN_SEED_WAIT    = 5'd17,
    ST_FFN_DRAFT_ISSUE  = 5'd18,
    ST_FFN_DRAFT_WAIT   = 5'd19,
    ST_RES2_SEED_ISSUE  = 5'd20,
    ST_RES2_SEED_WAIT   = 5'd21,
    ST_RES2_DRAFT_ISSUE = 5'd22,
    ST_RES2_DRAFT_WAIT  = 5'd23,
    ST_HOLD             = 5'd24;

localparam logic [4:0] ST_ISSUE = ST_PRE_ISSUE;
localparam logic [4:0] ST_MHA_ISSUE = ST_MHA_SEED_ISSUE;
localparam logic [4:0] ST_MHA_WAIT = ST_MHA_SEED_WAIT;

function automatic [ADDR_W-1:0] addr_from_u32;
    input [31:0] value;
    begin
        addr_from_u32 = value[ADDR_W-1:0];
    end
endfunction

logic [4:0] state_r;
logic [4:0] slot_count_r;
logic [4:0] pre_slot_idx_r;
logic [15:0] prefix_len_r;
logic [WINDOW_SIZE*32-1:0] token_ids_r;
logic [WINDOW_SIZE*16-1:0] positions_r;
logic [WINDOW_SIZE*WINDOW_SIZE-1:0] tree_mask_r;
logic [WINDOW_SIZE-1:0] slot_is_seed_r;
logic seed_kv_valid_r;
logic [4:0] layer_id_r;
logic [ADDR_W-1:0] input_base_addr_r;
logic [ADDR_W-1:0] result_base_addr_r;
logic [ADDR_W-1:0] pre_norm_gamma_addr_r;
logic [ADDR_W-1:0] post_norm_gamma_addr_r;
logic [ADDR_W-1:0] wq_addr_r;
logic [ADDR_W-1:0] wk_addr_r;
logic [ADDR_W-1:0] wv_addr_r;
logic [ADDR_W-1:0] wo_addr_r;
logic [ADDR_W-1:0] gate_w_addr_r;
logic [ADDR_W-1:0] up_w_addr_r;
logic [ADDR_W-1:0] down_w_addr_r;
logic [ADDR_W-1:0] scratch_base_addr_r;
logic [WINDOW_SIZE*32-1:0] result_token_ids_r;
logic [`MEM_REQ_LANES-1:0] draft_mha_done_r;
logic [`MEM_REQ_LANES-1:0] draft_mha_result_arm_r;
logic [`MEM_REQ_LANES-1:0] draft_mha_resp_quiet_r;
logic [`MEM_REQ_LANES-1:0] draft_stage_done_r;

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
logic [1:0] pre_result_status_w;

logic mha_seed_issue_ready_w;
logic mha_seed_rd_valid_w;
logic [ADDR_W-1:0] mha_seed_rd_addr_w;
logic [REQ_ID_W-1:0] mha_seed_rd_id_w;
logic mha_seed_resp_ready_w;
logic mha_seed_wr_valid_w;
logic [ADDR_W-1:0] mha_seed_wr_addr_w;
logic [DATA_BUS_W-1:0] mha_seed_wr_data_w;
logic mha_seed_result_valid_w;
logic mha_seed_result_ready_w;
logic [ADDR_W-1:0] mha_seed_result_addr_w;
logic [DATA_BUS_W-1:0] mha_seed_result_data_w;
logic [1:0] mha_seed_result_status_w;

logic [`MEM_REQ_LANES-1:0] draft_mha_active_w;
logic [`MEM_REQ_LANES-1:0] draft_mha_issue_ready_w;
logic [`MEM_REQ_LANES-1:0] draft_mha_rd_valid_w;
logic [`MEM_REQ_LANES*ADDR_W-1:0] draft_mha_rd_addr_w;
logic [`MEM_REQ_LANES*REQ_ID_W-1:0] draft_mha_rd_id_w;
logic [`MEM_REQ_LANES*`PE_MASK_W-1:0] draft_mha_rd_pe_mask_w;
logic [`MEM_REQ_LANES-1:0] draft_mha_resp_ready_w;
logic [`MEM_REQ_LANES-1:0] draft_mha_wr_valid_w;
logic [`MEM_REQ_LANES*ADDR_W-1:0] draft_mha_wr_addr_w;
logic [`MEM_REQ_LANES*DATA_BUS_W-1:0] draft_mha_wr_data_w;
logic [`MEM_REQ_LANES*REQ_ID_W-1:0] draft_mha_wr_id_w;
logic [`MEM_REQ_LANES*`PE_MASK_W-1:0] draft_mha_wr_pe_mask_w;
logic [`MEM_REQ_LANES-1:0] draft_mha_result_valid_w;
logic [`MEM_REQ_LANES-1:0] draft_mha_result_ready_w;
logic [`MEM_REQ_LANES*ADDR_W-1:0] draft_mha_result_addr_w;
logic [`MEM_REQ_LANES*DATA_BUS_W-1:0] draft_mha_result_data_w;
logic [`MEM_REQ_LANES*2-1:0] draft_mha_result_status_w;
logic [`MEM_REQ_LANES-1:0] draft_mha_barrier_waiting_w;
logic draft_mha_any_active_w;
logic draft_mha_all_issue_ready_w;
logic draft_mha_all_barrier_waiting_w;
logic draft_mha_all_done_w;
logic draft_mha_barrier_release_w;

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
logic [1:0] res1_result_status_w;
logic [`MEM_REQ_LANES-1:0] res1_draft_issue_ready_w;
logic [`MEM_REQ_LANES-1:0] res1_draft_rd_valid_w;
logic [`MEM_REQ_LANES*ADDR_W-1:0] res1_draft_rd_addr_w;
logic [`MEM_REQ_LANES*REQ_ID_W-1:0] res1_draft_rd_id_w;
logic [`MEM_REQ_LANES*`PE_MASK_W-1:0] res1_draft_rd_pe_mask_w;
logic [`MEM_REQ_LANES-1:0] res1_draft_resp_ready_w;
logic [`MEM_REQ_LANES-1:0] res1_draft_wr_valid_w;
logic [`MEM_REQ_LANES*ADDR_W-1:0] res1_draft_wr_addr_w;
logic [`MEM_REQ_LANES*DATA_BUS_W-1:0] res1_draft_wr_data_w;
logic [`MEM_REQ_LANES*REQ_ID_W-1:0] res1_draft_wr_id_w;
logic [`MEM_REQ_LANES*`PE_MASK_W-1:0] res1_draft_wr_pe_mask_w;
logic [`MEM_REQ_LANES-1:0] res1_draft_result_valid_w;
logic [`MEM_REQ_LANES-1:0] res1_draft_result_ready_w;
logic [`MEM_REQ_LANES*ADDR_W-1:0] res1_draft_result_addr_w;
logic [`MEM_REQ_LANES*DATA_BUS_W-1:0] res1_draft_result_data_w;
logic [`MEM_REQ_LANES*2-1:0] res1_draft_result_status_w;
logic res1_draft_all_issue_ready_w;
logic res1_draft_all_done_w;

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
logic [1:0] post_result_status_w;
logic [`MEM_REQ_LANES-1:0] post_draft_issue_ready_w;
logic [`MEM_REQ_LANES-1:0] post_draft_rd_valid_w;
logic [`MEM_REQ_LANES*ADDR_W-1:0] post_draft_rd_addr_w;
logic [`MEM_REQ_LANES*REQ_ID_W-1:0] post_draft_rd_id_w;
logic [`MEM_REQ_LANES*`PE_MASK_W-1:0] post_draft_rd_pe_mask_w;
logic [`MEM_REQ_LANES-1:0] post_draft_resp_ready_w;
logic [`MEM_REQ_LANES-1:0] post_draft_wr_valid_w;
logic [`MEM_REQ_LANES*ADDR_W-1:0] post_draft_wr_addr_w;
logic [`MEM_REQ_LANES*DATA_BUS_W-1:0] post_draft_wr_data_w;
logic [`MEM_REQ_LANES*REQ_ID_W-1:0] post_draft_wr_id_w;
logic [`MEM_REQ_LANES*`PE_MASK_W-1:0] post_draft_wr_pe_mask_w;
logic [`MEM_REQ_LANES-1:0] post_draft_result_valid_w;
logic [`MEM_REQ_LANES-1:0] post_draft_result_ready_w;
logic [`MEM_REQ_LANES*ADDR_W-1:0] post_draft_result_addr_w;
logic [`MEM_REQ_LANES*DATA_BUS_W-1:0] post_draft_result_data_w;
logic [`MEM_REQ_LANES*2-1:0] post_draft_result_status_w;
logic post_draft_all_issue_ready_w;
logic post_draft_all_done_w;

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
logic [1:0] ffn_result_status_w;
logic [`MEM_REQ_LANES-1:0] ffn_draft_issue_ready_w;
logic [`MEM_REQ_LANES-1:0] ffn_draft_rd_valid_w;
logic [`MEM_REQ_LANES*ADDR_W-1:0] ffn_draft_rd_addr_w;
logic [`MEM_REQ_LANES*REQ_ID_W-1:0] ffn_draft_rd_id_w;
logic [`MEM_REQ_LANES*`PE_MASK_W-1:0] ffn_draft_rd_pe_mask_w;
logic [`MEM_REQ_LANES-1:0] ffn_draft_resp_ready_w;
logic [`MEM_REQ_LANES-1:0] ffn_draft_wr_valid_w;
logic [`MEM_REQ_LANES*ADDR_W-1:0] ffn_draft_wr_addr_w;
logic [`MEM_REQ_LANES*DATA_BUS_W-1:0] ffn_draft_wr_data_w;
logic [`MEM_REQ_LANES*REQ_ID_W-1:0] ffn_draft_wr_id_w;
logic [`MEM_REQ_LANES*`PE_MASK_W-1:0] ffn_draft_wr_pe_mask_w;
logic [`MEM_REQ_LANES-1:0] ffn_draft_result_valid_w;
logic [`MEM_REQ_LANES-1:0] ffn_draft_result_ready_w;
logic [`MEM_REQ_LANES*ADDR_W-1:0] ffn_draft_result_addr_w;
logic [`MEM_REQ_LANES*DATA_BUS_W-1:0] ffn_draft_result_data_w;
logic [`MEM_REQ_LANES*2-1:0] ffn_draft_result_status_w;
logic ffn_draft_all_issue_ready_w;
logic ffn_draft_all_done_w;

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
logic [1:0] res2_result_status_w;
logic [`MEM_REQ_LANES-1:0] res2_draft_issue_ready_w;
logic [`MEM_REQ_LANES-1:0] res2_draft_rd_valid_w;
logic [`MEM_REQ_LANES*ADDR_W-1:0] res2_draft_rd_addr_w;
logic [`MEM_REQ_LANES*REQ_ID_W-1:0] res2_draft_rd_id_w;
logic [`MEM_REQ_LANES*`PE_MASK_W-1:0] res2_draft_rd_pe_mask_w;
logic [`MEM_REQ_LANES-1:0] res2_draft_resp_ready_w;
logic [`MEM_REQ_LANES-1:0] res2_draft_wr_valid_w;
logic [`MEM_REQ_LANES*ADDR_W-1:0] res2_draft_wr_addr_w;
logic [`MEM_REQ_LANES*DATA_BUS_W-1:0] res2_draft_wr_data_w;
logic [`MEM_REQ_LANES*REQ_ID_W-1:0] res2_draft_wr_id_w;
logic [`MEM_REQ_LANES*`PE_MASK_W-1:0] res2_draft_wr_pe_mask_w;
logic [`MEM_REQ_LANES-1:0] res2_draft_result_valid_w;
logic [`MEM_REQ_LANES-1:0] res2_draft_result_ready_w;
logic [`MEM_REQ_LANES*ADDR_W-1:0] res2_draft_result_addr_w;
logic [`MEM_REQ_LANES*DATA_BUS_W-1:0] res2_draft_result_data_w;
logic [`MEM_REQ_LANES*2-1:0] res2_draft_result_status_w;
logic res2_draft_all_issue_ready_w;
logic res2_draft_all_done_w;

logic layer_rd_valid_w;
logic [ADDR_W-1:0] layer_rd_addr_w;
logic [REQ_ID_W-1:0] layer_rd_id_w;
logic layer_resp_ready_w;
logic layer_wr_valid_w;
logic [ADDR_W-1:0] layer_wr_addr_w;
logic [DATA_BUS_W-1:0] layer_wr_data_w;

wire [ADDR_W-1:0] pre_slot_input_addr_w =
    input_base_addr_r + addr_from_u32(pre_slot_idx_r * HIDDEN_BEATS);
wire [ADDR_W-1:0] pre_slot_scratch_base_w =
    scratch_base_addr_r + addr_from_u32(pre_slot_idx_r * SLOT_SCRATCH_STRIDE);
wire [ADDR_W-1:0] layer_kv_committed_base_w =
    KV_COMMITTED_BASE + addr_from_u32(layer_id_r * KV_LAYER_STRIDE);
wire [ADDR_W-1:0] layer_kv_draft_base_w =
    KV_DRAFT_BASE + addr_from_u32(layer_id_r * KV_LAYER_STRIDE);
wire [WINDOW_SIZE-1:0] seed_visible_row_w =
    tree_mask_r[0 +: WINDOW_SIZE];
wire [15:0] seed_position_w =
    positions_r[0 +: 16];
wire [ADDR_W-1:0] seed_slot_scratch_base_w = scratch_base_addr_r;
wire [ADDR_W-1:0] seed_pre_norm_out_base_w = seed_slot_scratch_base_w;
wire [ADDR_W-1:0] seed_mha_scratch_base_w =
    seed_slot_scratch_base_w + HIDDEN_BEATS;
wire [ADDR_W-1:0] seed_mha_out_base_w =
    seed_slot_scratch_base_w + (HIDDEN_BEATS * 6);
wire [ADDR_W-1:0] seed_post_norm_out_base_w =
    seed_slot_scratch_base_w + (HIDDEN_BEATS * 7);
wire [ADDR_W-1:0] seed_ffn_scratch_base_w =
    seed_slot_scratch_base_w + (HIDDEN_BEATS * 8);
wire [ADDR_W-1:0] seed_ffn_out_base_w =
    seed_slot_scratch_base_w + (HIDDEN_BEATS * 8) + (INTERMEDIATE_BEATS * 3);
wire [ADDR_W-1:0] seed_input_addr_w = seed_pre_norm_out_base_w;
wire [ADDR_W-1:0] seed_result_addr_w = seed_mha_out_base_w;

wire pre_stage_active_w =
    (state_r == ST_PRE_ISSUE) || (state_r == ST_PRE_WAIT);
wire res1_seed_stage_active_w =
    (state_r == ST_RES1_SEED_ISSUE) || (state_r == ST_RES1_SEED_WAIT);
wire post_seed_stage_active_w =
    (state_r == ST_POST_SEED_ISSUE) || (state_r == ST_POST_SEED_WAIT);
wire ffn_seed_stage_active_w =
    (state_r == ST_FFN_SEED_ISSUE) || (state_r == ST_FFN_SEED_WAIT);
wire res2_seed_stage_active_w =
    (state_r == ST_RES2_SEED_ISSUE) || (state_r == ST_RES2_SEED_WAIT);
wire res1_draft_stage_active_w =
    (state_r == ST_RES1_DRAFT_ISSUE) || (state_r == ST_RES1_DRAFT_WAIT);
wire post_draft_stage_active_w =
    (state_r == ST_POST_DRAFT_ISSUE) || (state_r == ST_POST_DRAFT_WAIT);
wire ffn_draft_stage_active_w =
    (state_r == ST_FFN_DRAFT_ISSUE) || (state_r == ST_FFN_DRAFT_WAIT);
wire res2_draft_stage_active_w =
    (state_r == ST_RES2_DRAFT_ISSUE) || (state_r == ST_RES2_DRAFT_WAIT);

assign draft_mha_active_w =
    (slot_count_r > 5'd1) ?
        (({`MEM_REQ_LANES{1'b1}}) >> (`MEM_REQ_LANES - (slot_count_r - 5'd1))) :
        {`MEM_REQ_LANES{1'b0}};
assign draft_mha_any_active_w = |draft_mha_active_w;
assign draft_mha_all_issue_ready_w =
    ((draft_mha_issue_ready_w | ~draft_mha_active_w) == {`MEM_REQ_LANES{1'b1}});
assign draft_mha_all_barrier_waiting_w =
    ((draft_mha_barrier_waiting_w | ~draft_mha_active_w) == {`MEM_REQ_LANES{1'b1}});
assign draft_mha_all_done_w =
    ((draft_mha_done_r | ~draft_mha_active_w) == {`MEM_REQ_LANES{1'b1}});
assign draft_mha_barrier_release_w =
    (state_r == ST_MHA_DRAFT_WAIT) && draft_mha_all_barrier_waiting_w;
assign draft_mha_result_ready_w =
    draft_mha_result_arm_r & draft_mha_resp_quiet_r &
    ~vec_sram_resp_valid & draft_mha_active_w;
assign res1_draft_result_ready_w = {`MEM_REQ_LANES{1'b1}};
assign post_draft_result_ready_w = {`MEM_REQ_LANES{1'b1}};
assign ffn_draft_result_ready_w = {`MEM_REQ_LANES{1'b1}};
assign res2_draft_result_ready_w = {`MEM_REQ_LANES{1'b1}};
assign res1_draft_all_issue_ready_w =
    ((res1_draft_issue_ready_w | ~draft_mha_active_w) == {`MEM_REQ_LANES{1'b1}});
assign post_draft_all_issue_ready_w =
    ((post_draft_issue_ready_w | ~draft_mha_active_w) == {`MEM_REQ_LANES{1'b1}});
assign ffn_draft_all_issue_ready_w =
    ((ffn_draft_issue_ready_w | ~draft_mha_active_w) == {`MEM_REQ_LANES{1'b1}});
assign res2_draft_all_issue_ready_w =
    ((res2_draft_issue_ready_w | ~draft_mha_active_w) == {`MEM_REQ_LANES{1'b1}});
assign res1_draft_all_done_w =
    ((draft_stage_done_r | ~draft_mha_active_w) == {`MEM_REQ_LANES{1'b1}});
assign post_draft_all_done_w =
    ((draft_stage_done_r | ~draft_mha_active_w) == {`MEM_REQ_LANES{1'b1}});
assign ffn_draft_all_done_w =
    ((draft_stage_done_r | ~draft_mha_active_w) == {`MEM_REQ_LANES{1'b1}});
assign res2_draft_all_done_w =
    ((draft_stage_done_r | ~draft_mha_active_w) == {`MEM_REQ_LANES{1'b1}});

fp16_rmsnorm #(
    .DATA_WIDTH(DATA_WIDTH),
    .ADDR_W(ADDR_W),
    .DATA_BUS_W(DATA_BUS_W),
    .REQ_ID_W(REQ_ID_W),
    .VECTOR_LEN(HIDDEN_DIM),
    .RESULT_STATUS_W(2),
    .RESULT_STATUS_OK(2'b00)
) u_pre_rmsnorm (
    .clk(clk),
    .rst_n(rst_n),
    .issue_valid(state_r == ST_PRE_ISSUE),
    .issue_ready(pre_issue_ready_w),
    .issue_x_addr(pre_slot_input_addr_w),
    .issue_gamma_addr(pre_norm_gamma_addr_r),
    .issue_result_addr(pre_slot_scratch_base_w),
    .issue_req_id({REQ_ID_W{1'b0}}),
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
    .RESULT_STATUS_W(2),
    .HIDDEN_DIM(HIDDEN_DIM),
    .NUM_HEADS(NUM_HEADS),
    .HEAD_DIM(HEAD_DIM),
    .MAX_ATTN_TOKENS(MAX_ATTN_TOKENS),
    .WINDOW_SIZE(WINDOW_SIZE),
    .SLOT_ID_W(SLOT_ID_W),
    .RESULT_STATUS_OK(2'b00)
) u_fp16_mha_seed_controller (
    .clk(clk),
    .rst_n(rst_n),
    .issue_valid((state_r == ST_MHA_SEED_ISSUE) && slot_count_r != 5'd0),
    .issue_ready(mha_seed_issue_ready_w),
    .issue_input_addr(seed_input_addr_w),
    .issue_wq_addr(wq_addr_r),
    .issue_wk_addr(wk_addr_r),
    .issue_wv_addr(wv_addr_r),
    .issue_wo_addr(wo_addr_r),
    .issue_kv_cache_addr(layer_kv_committed_base_w),
    .issue_result_addr(seed_result_addr_w),
    .issue_scratch_base_addr(seed_mha_scratch_base_w),
    .issue_position(seed_position_w),
    .issue_layer_id(layer_id_r),
    .issue_req_id({REQ_ID_W{1'b0}}),
    .issue_tree_mask_en(1'b0),
    .issue_branch_id({`BRANCH_ID_W{1'b0}}),
    .issue_prefix_len(prefix_len_r),
    .issue_visible_mask({MAX_ATTN_TOKENS{1'b0}}),
    .issue_tree_batch_en(1'b1),
    .issue_tree_draft_kv_base(layer_kv_draft_base_w),
    .issue_tree_query_slot({SLOT_ID_W{1'b0}}),
    .issue_tree_slot_count(slot_count_r),
    .issue_tree_visible_slots(seed_visible_row_w),
    .issue_tree_slot_is_seed(slot_is_seed_r),
    .issue_tree_seed_kv_valid(seed_kv_valid_r),
    .issue_tree_kv_barrier_release(1'b1),
    .tree_kv_barrier_waiting(),
    .sram_rd_valid(mha_seed_rd_valid_w),
    .sram_rd_ready(sram_rd_ready),
    .sram_rd_addr(mha_seed_rd_addr_w),
    .sram_rd_id(mha_seed_rd_id_w),
    .sram_resp_valid(sram_resp_valid),
    .sram_resp_ready(mha_seed_resp_ready_w),
    .sram_resp_data(sram_resp_data),
    .sram_resp_id(sram_resp_id),
    .sram_wr_valid(mha_seed_wr_valid_w),
    .sram_wr_ready(sram_wr_ready),
    .sram_wr_addr(mha_seed_wr_addr_w),
    .sram_wr_data(mha_seed_wr_data_w),
    .result_valid(mha_seed_result_valid_w),
    .result_ready(mha_seed_result_ready_w),
    .result_addr(mha_seed_result_addr_w),
    .result_data(mha_seed_result_data_w),
    .result_status(mha_seed_result_status_w)
);

genvar gen_mha_slot;
generate
    for (gen_mha_slot = 0;
         gen_mha_slot < `MEM_REQ_LANES;
         gen_mha_slot = gen_mha_slot + 1) begin : gen_mha_slot_block
        localparam integer SLOT_WIRE_IDX = gen_mha_slot + 1;
        localparam [REQ_ID_W-1:0] SLOT_REQ_ID_W =
            SLOT_WIRE_IDX[REQ_ID_W-1:0];
        localparam [SLOT_ID_W-1:0] SLOT_QUERY_ID_W = SLOT_WIRE_IDX[SLOT_ID_W-1:0];
        wire [ADDR_W-1:0] draft_scratch_base_w =
            scratch_base_addr_r + addr_from_u32(SLOT_WIRE_IDX * SLOT_SCRATCH_STRIDE);
        wire [ADDR_W-1:0] draft_input_addr_w = draft_scratch_base_w;
        wire [ADDR_W-1:0] draft_result_addr_w =
            draft_scratch_base_w + (HIDDEN_BEATS * 6);
        wire [ADDR_W-1:0] draft_mha_scratch_base_w =
            draft_scratch_base_w + HIDDEN_BEATS;
        wire [WINDOW_SIZE-1:0] draft_visible_slots_lane_w =
            tree_mask_r[(SLOT_WIRE_IDX*WINDOW_SIZE) +: WINDOW_SIZE];
        wire [15:0] draft_position_lane_w =
            positions_r[(SLOT_WIRE_IDX*16) +: 16];
        wire draft_slot_issue_valid_w =
            (state_r == ST_MHA_DRAFT_ISSUE) &&
            draft_mha_active_w[gen_mha_slot];

        fp16_mha_controller #(
            .ADDR_W(ADDR_W),
            .DATA_WIDTH(DATA_WIDTH),
            .DATA_BUS_W(DATA_BUS_W),
            .REQ_ID_W(REQ_ID_W),
            .RESULT_STATUS_W(2),
            .HIDDEN_DIM(HIDDEN_DIM),
            .NUM_HEADS(NUM_HEADS),
            .HEAD_DIM(HEAD_DIM),
            .MAX_ATTN_TOKENS(MAX_ATTN_TOKENS),
            .WINDOW_SIZE(WINDOW_SIZE),
            .SLOT_ID_W(SLOT_ID_W),
            .RESULT_STATUS_OK(2'b00)
        ) u_fp16_mha_draft_controller (
            .clk(clk),
            .rst_n(rst_n),
            .issue_valid(draft_slot_issue_valid_w),
            .issue_ready(draft_mha_issue_ready_w[gen_mha_slot]),
            .issue_input_addr(draft_input_addr_w),
            .issue_wq_addr(wq_addr_r),
            .issue_wk_addr(wk_addr_r),
            .issue_wv_addr(wv_addr_r),
            .issue_wo_addr(wo_addr_r),
            .issue_kv_cache_addr(layer_kv_committed_base_w),
            .issue_result_addr(draft_result_addr_w),
            .issue_scratch_base_addr(draft_mha_scratch_base_w),
            .issue_position(draft_position_lane_w),
            .issue_layer_id(layer_id_r),
            .issue_req_id(SLOT_REQ_ID_W),
            .issue_tree_mask_en(1'b0),
            .issue_branch_id({`BRANCH_ID_W{1'b0}}),
            .issue_prefix_len(prefix_len_r),
            .issue_visible_mask({MAX_ATTN_TOKENS{1'b0}}),
            .issue_tree_batch_en(1'b1),
            .issue_tree_draft_kv_base(layer_kv_draft_base_w),
            .issue_tree_query_slot(SLOT_QUERY_ID_W),
            .issue_tree_slot_count(slot_count_r),
            .issue_tree_visible_slots(draft_visible_slots_lane_w),
            .issue_tree_slot_is_seed(slot_is_seed_r),
            .issue_tree_seed_kv_valid(seed_kv_valid_r),
            .issue_tree_kv_barrier_release(draft_mha_barrier_release_w),
            .tree_kv_barrier_waiting(draft_mha_barrier_waiting_w[gen_mha_slot]),
            .sram_rd_valid(draft_mha_rd_valid_w[gen_mha_slot]),
            .sram_rd_ready(vec_sram_rd_ready[gen_mha_slot]),
            .sram_rd_addr(draft_mha_rd_addr_w[gen_mha_slot*ADDR_W +: ADDR_W]),
            .sram_rd_id(draft_mha_rd_id_w[gen_mha_slot*REQ_ID_W +: REQ_ID_W]),
            .sram_resp_valid(vec_sram_resp_valid[gen_mha_slot]),
            .sram_resp_ready(draft_mha_resp_ready_w[gen_mha_slot]),
            .sram_resp_data(vec_sram_resp_data[gen_mha_slot*DATA_BUS_W +: DATA_BUS_W]),
            .sram_resp_id(vec_sram_resp_id[gen_mha_slot*REQ_ID_W +: REQ_ID_W]),
            .sram_wr_valid(draft_mha_wr_valid_w[gen_mha_slot]),
            .sram_wr_ready(vec_sram_wr_ready[gen_mha_slot]),
            .sram_wr_addr(draft_mha_wr_addr_w[gen_mha_slot*ADDR_W +: ADDR_W]),
            .sram_wr_data(draft_mha_wr_data_w[gen_mha_slot*DATA_BUS_W +: DATA_BUS_W]),
            .result_valid(draft_mha_result_valid_w[gen_mha_slot]),
            .result_ready(draft_mha_result_ready_w[gen_mha_slot]),
            .result_addr(draft_mha_result_addr_w[gen_mha_slot*ADDR_W +: ADDR_W]),
            .result_data(draft_mha_result_data_w[gen_mha_slot*DATA_BUS_W +: DATA_BUS_W]),
            .result_status(draft_mha_result_status_w[gen_mha_slot*2 +: 2])
        );

        assign draft_mha_rd_pe_mask_w[
            gen_mha_slot*`PE_MASK_W +: `PE_MASK_W] =
            draft_mha_active_w[gen_mha_slot] ?
                ({{(`PE_MASK_W-1){1'b0}}, 1'b1} << gen_mha_slot) :
                {`PE_MASK_W{1'b0}};
        assign draft_mha_wr_id_w[
            gen_mha_slot*REQ_ID_W +: REQ_ID_W] =
            SLOT_REQ_ID_W;
        assign draft_mha_wr_pe_mask_w[
            gen_mha_slot*`PE_MASK_W +: `PE_MASK_W] =
            draft_mha_active_w[gen_mha_slot] ?
                ({{(`PE_MASK_W-1){1'b0}}, 1'b1} << gen_mha_slot) :
                {`PE_MASK_W{1'b0}};
    end
endgenerate

fp16_residual_add #(
    .DATA_WIDTH(DATA_WIDTH),
    .ADDR_W(ADDR_W),
    .DATA_BUS_W(DATA_BUS_W),
    .REQ_ID_W(REQ_ID_W),
    .VECTOR_LEN(HIDDEN_DIM),
    .RESULT_STATUS_W(2),
    .RESULT_STATUS_OK(2'b00)
) u_residual_add1 (
    .clk(clk),
    .rst_n(rst_n),
    .issue_valid(state_r == ST_RES1_SEED_ISSUE),
    .issue_ready(res1_issue_ready_w),
    .issue_x_addr(seed_mha_out_base_w),
    .issue_residual_addr(input_base_addr_r),
    .issue_result_addr(result_base_addr_r),
    .issue_req_id({REQ_ID_W{1'b0}}),
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
    .RESULT_STATUS_W(2),
    .RESULT_STATUS_OK(2'b00)
) u_post_rmsnorm (
    .clk(clk),
    .rst_n(rst_n),
    .issue_valid(state_r == ST_POST_SEED_ISSUE),
    .issue_ready(post_issue_ready_w),
    .issue_x_addr(result_base_addr_r),
    .issue_gamma_addr(post_norm_gamma_addr_r),
    .issue_result_addr(seed_post_norm_out_base_w),
    .issue_req_id({REQ_ID_W{1'b0}}),
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
    .RESULT_STATUS_W(2),
    .HIDDEN_DIM(HIDDEN_DIM),
    .INTERMEDIATE_DIM(INTERMEDIATE_DIM),
    .RESULT_STATUS_OK(2'b00)
) u_fp16_ffn_swiglu (
    .clk(clk),
    .rst_n(rst_n),
    .issue_valid(state_r == ST_FFN_SEED_ISSUE),
    .issue_ready(ffn_issue_ready_w),
    .issue_input_addr(seed_post_norm_out_base_w),
    .issue_gate_w_addr(gate_w_addr_r),
    .issue_up_w_addr(up_w_addr_r),
    .issue_down_w_addr(down_w_addr_r),
    .issue_result_addr(seed_ffn_out_base_w),
    .issue_scratch_base_addr(seed_ffn_scratch_base_w),
    .issue_req_id({REQ_ID_W{1'b0}}),
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
    .RESULT_STATUS_W(2),
    .RESULT_STATUS_OK(2'b00)
) u_residual_add2 (
    .clk(clk),
    .rst_n(rst_n),
    .issue_valid(state_r == ST_RES2_SEED_ISSUE),
    .issue_ready(res2_issue_ready_w),
    .issue_x_addr(seed_ffn_out_base_w),
    .issue_residual_addr(result_base_addr_r),
    .issue_result_addr(result_base_addr_r),
    .issue_req_id({REQ_ID_W{1'b0}}),
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

genvar gen_post_slot;
generate
    for (gen_post_slot = 0;
         gen_post_slot < `MEM_REQ_LANES;
         gen_post_slot = gen_post_slot + 1) begin : gen_post_slot_block
        localparam integer SLOT_WIRE_IDX = gen_post_slot + 1;
        localparam [REQ_ID_W-1:0] SLOT_REQ_ID_W =
            SLOT_WIRE_IDX[REQ_ID_W-1:0];
        wire draft_lane_active_w = draft_mha_active_w[gen_post_slot];
        wire [ADDR_W-1:0] draft_slot_input_addr_w =
            input_base_addr_r + addr_from_u32(SLOT_WIRE_IDX * HIDDEN_BEATS);
        wire [ADDR_W-1:0] draft_slot_result_addr_w =
            result_base_addr_r + addr_from_u32(SLOT_WIRE_IDX * HIDDEN_BEATS);
        wire [ADDR_W-1:0] draft_slot_scratch_base_w =
            scratch_base_addr_r + addr_from_u32(SLOT_WIRE_IDX * SLOT_SCRATCH_STRIDE);
        wire [ADDR_W-1:0] draft_slot_mha_out_base_w =
            draft_slot_scratch_base_w + (HIDDEN_BEATS * 6);
        wire [ADDR_W-1:0] draft_slot_post_norm_out_base_w =
            draft_slot_scratch_base_w + (HIDDEN_BEATS * 7);
        wire [ADDR_W-1:0] draft_slot_ffn_scratch_base_w =
            draft_slot_scratch_base_w + (HIDDEN_BEATS * 8);
        wire [ADDR_W-1:0] draft_slot_ffn_out_base_w =
            draft_slot_scratch_base_w + (HIDDEN_BEATS * 8) + (INTERMEDIATE_BEATS * 3);

        fp16_residual_add #(
            .DATA_WIDTH(DATA_WIDTH),
            .ADDR_W(ADDR_W),
            .DATA_BUS_W(DATA_BUS_W),
            .REQ_ID_W(REQ_ID_W),
            .VECTOR_LEN(HIDDEN_DIM),
            .RESULT_STATUS_W(2),
            .RESULT_STATUS_OK(2'b00)
        ) u_residual_add1_draft (
            .clk(clk),
            .rst_n(rst_n),
            .issue_valid((state_r == ST_RES1_DRAFT_ISSUE) && draft_lane_active_w),
            .issue_ready(res1_draft_issue_ready_w[gen_post_slot]),
            .issue_x_addr(draft_slot_mha_out_base_w),
            .issue_residual_addr(draft_slot_input_addr_w),
            .issue_result_addr(draft_slot_result_addr_w),
            .issue_req_id(SLOT_REQ_ID_W),
            .sram_rd_valid(res1_draft_rd_valid_w[gen_post_slot]),
            .sram_rd_ready(vec_sram_rd_ready[gen_post_slot]),
            .sram_rd_addr(res1_draft_rd_addr_w[gen_post_slot*ADDR_W +: ADDR_W]),
            .sram_rd_id(res1_draft_rd_id_w[gen_post_slot*REQ_ID_W +: REQ_ID_W]),
            .sram_resp_valid(vec_sram_resp_valid[gen_post_slot]),
            .sram_resp_ready(res1_draft_resp_ready_w[gen_post_slot]),
            .sram_resp_data(vec_sram_resp_data[gen_post_slot*DATA_BUS_W +: DATA_BUS_W]),
            .sram_resp_id(vec_sram_resp_id[gen_post_slot*REQ_ID_W +: REQ_ID_W]),
            .sram_wr_valid(res1_draft_wr_valid_w[gen_post_slot]),
            .sram_wr_ready(vec_sram_wr_ready[gen_post_slot]),
            .sram_wr_addr(res1_draft_wr_addr_w[gen_post_slot*ADDR_W +: ADDR_W]),
            .sram_wr_data(res1_draft_wr_data_w[gen_post_slot*DATA_BUS_W +: DATA_BUS_W]),
            .result_valid(res1_draft_result_valid_w[gen_post_slot]),
            .result_ready(res1_draft_result_ready_w[gen_post_slot]),
            .result_addr(res1_draft_result_addr_w[gen_post_slot*ADDR_W +: ADDR_W]),
            .result_data(res1_draft_result_data_w[gen_post_slot*DATA_BUS_W +: DATA_BUS_W]),
            .result_status(res1_draft_result_status_w[gen_post_slot*2 +: 2])
        );
        assign res1_draft_rd_pe_mask_w[gen_post_slot*`PE_MASK_W +: `PE_MASK_W] =
            draft_lane_active_w ? ({{(`PE_MASK_W-1){1'b0}}, 1'b1} << gen_post_slot) : {`PE_MASK_W{1'b0}};
        assign res1_draft_wr_id_w[gen_post_slot*REQ_ID_W +: REQ_ID_W] = SLOT_REQ_ID_W;
        assign res1_draft_wr_pe_mask_w[gen_post_slot*`PE_MASK_W +: `PE_MASK_W] =
            draft_lane_active_w ? ({{(`PE_MASK_W-1){1'b0}}, 1'b1} << gen_post_slot) : {`PE_MASK_W{1'b0}};

        fp16_rmsnorm #(
            .DATA_WIDTH(DATA_WIDTH),
            .ADDR_W(ADDR_W),
            .DATA_BUS_W(DATA_BUS_W),
            .REQ_ID_W(REQ_ID_W),
            .VECTOR_LEN(HIDDEN_DIM),
            .RESULT_STATUS_W(2),
            .RESULT_STATUS_OK(2'b00)
        ) u_post_rmsnorm_draft (
            .clk(clk),
            .rst_n(rst_n),
            .issue_valid((state_r == ST_POST_DRAFT_ISSUE) && draft_lane_active_w),
            .issue_ready(post_draft_issue_ready_w[gen_post_slot]),
            .issue_x_addr(draft_slot_result_addr_w),
            .issue_gamma_addr(post_norm_gamma_addr_r),
            .issue_result_addr(draft_slot_post_norm_out_base_w),
            .issue_req_id(SLOT_REQ_ID_W),
            .sram_rd_valid(post_draft_rd_valid_w[gen_post_slot]),
            .sram_rd_ready(vec_sram_rd_ready[gen_post_slot]),
            .sram_rd_addr(post_draft_rd_addr_w[gen_post_slot*ADDR_W +: ADDR_W]),
            .sram_rd_id(post_draft_rd_id_w[gen_post_slot*REQ_ID_W +: REQ_ID_W]),
            .sram_resp_valid(vec_sram_resp_valid[gen_post_slot]),
            .sram_resp_ready(post_draft_resp_ready_w[gen_post_slot]),
            .sram_resp_data(vec_sram_resp_data[gen_post_slot*DATA_BUS_W +: DATA_BUS_W]),
            .sram_resp_id(vec_sram_resp_id[gen_post_slot*REQ_ID_W +: REQ_ID_W]),
            .sram_wr_valid(post_draft_wr_valid_w[gen_post_slot]),
            .sram_wr_ready(vec_sram_wr_ready[gen_post_slot]),
            .sram_wr_addr(post_draft_wr_addr_w[gen_post_slot*ADDR_W +: ADDR_W]),
            .sram_wr_data(post_draft_wr_data_w[gen_post_slot*DATA_BUS_W +: DATA_BUS_W]),
            .result_valid(post_draft_result_valid_w[gen_post_slot]),
            .result_ready(post_draft_result_ready_w[gen_post_slot]),
            .result_addr(post_draft_result_addr_w[gen_post_slot*ADDR_W +: ADDR_W]),
            .result_data(post_draft_result_data_w[gen_post_slot*DATA_BUS_W +: DATA_BUS_W]),
            .result_status(post_draft_result_status_w[gen_post_slot*2 +: 2])
        );
        assign post_draft_rd_pe_mask_w[gen_post_slot*`PE_MASK_W +: `PE_MASK_W] =
            draft_lane_active_w ? ({{(`PE_MASK_W-1){1'b0}}, 1'b1} << gen_post_slot) : {`PE_MASK_W{1'b0}};
        assign post_draft_wr_id_w[gen_post_slot*REQ_ID_W +: REQ_ID_W] = SLOT_REQ_ID_W;
        assign post_draft_wr_pe_mask_w[gen_post_slot*`PE_MASK_W +: `PE_MASK_W] =
            draft_lane_active_w ? ({{(`PE_MASK_W-1){1'b0}}, 1'b1} << gen_post_slot) : {`PE_MASK_W{1'b0}};

        fp16_ffn_swiglu #(
            .ADDR_W(ADDR_W),
            .DATA_WIDTH(DATA_WIDTH),
            .DATA_BUS_W(DATA_BUS_W),
            .REQ_ID_W(REQ_ID_W),
            .RESULT_STATUS_W(2),
            .HIDDEN_DIM(HIDDEN_DIM),
            .INTERMEDIATE_DIM(INTERMEDIATE_DIM),
            .RESULT_STATUS_OK(2'b00)
        ) u_fp16_ffn_swiglu_draft (
            .clk(clk),
            .rst_n(rst_n),
            .issue_valid((state_r == ST_FFN_DRAFT_ISSUE) && draft_lane_active_w),
            .issue_ready(ffn_draft_issue_ready_w[gen_post_slot]),
            .issue_input_addr(draft_slot_post_norm_out_base_w),
            .issue_gate_w_addr(gate_w_addr_r),
            .issue_up_w_addr(up_w_addr_r),
            .issue_down_w_addr(down_w_addr_r),
            .issue_result_addr(draft_slot_ffn_out_base_w),
            .issue_scratch_base_addr(draft_slot_ffn_scratch_base_w),
            .issue_req_id(SLOT_REQ_ID_W),
            .sram_rd_valid(ffn_draft_rd_valid_w[gen_post_slot]),
            .sram_rd_ready(vec_sram_rd_ready[gen_post_slot]),
            .sram_rd_addr(ffn_draft_rd_addr_w[gen_post_slot*ADDR_W +: ADDR_W]),
            .sram_rd_id(ffn_draft_rd_id_w[gen_post_slot*REQ_ID_W +: REQ_ID_W]),
            .sram_resp_valid(vec_sram_resp_valid[gen_post_slot]),
            .sram_resp_ready(ffn_draft_resp_ready_w[gen_post_slot]),
            .sram_resp_data(vec_sram_resp_data[gen_post_slot*DATA_BUS_W +: DATA_BUS_W]),
            .sram_resp_id(vec_sram_resp_id[gen_post_slot*REQ_ID_W +: REQ_ID_W]),
            .sram_wr_valid(ffn_draft_wr_valid_w[gen_post_slot]),
            .sram_wr_ready(vec_sram_wr_ready[gen_post_slot]),
            .sram_wr_addr(ffn_draft_wr_addr_w[gen_post_slot*ADDR_W +: ADDR_W]),
            .sram_wr_data(ffn_draft_wr_data_w[gen_post_slot*DATA_BUS_W +: DATA_BUS_W]),
            .result_valid(ffn_draft_result_valid_w[gen_post_slot]),
            .result_ready(ffn_draft_result_ready_w[gen_post_slot]),
            .result_addr(ffn_draft_result_addr_w[gen_post_slot*ADDR_W +: ADDR_W]),
            .result_data(ffn_draft_result_data_w[gen_post_slot*DATA_BUS_W +: DATA_BUS_W]),
            .result_status(ffn_draft_result_status_w[gen_post_slot*2 +: 2])
        );
        assign ffn_draft_rd_pe_mask_w[gen_post_slot*`PE_MASK_W +: `PE_MASK_W] =
            draft_lane_active_w ? ({{(`PE_MASK_W-1){1'b0}}, 1'b1} << gen_post_slot) : {`PE_MASK_W{1'b0}};
        assign ffn_draft_wr_id_w[gen_post_slot*REQ_ID_W +: REQ_ID_W] = SLOT_REQ_ID_W;
        assign ffn_draft_wr_pe_mask_w[gen_post_slot*`PE_MASK_W +: `PE_MASK_W] =
            draft_lane_active_w ? ({{(`PE_MASK_W-1){1'b0}}, 1'b1} << gen_post_slot) : {`PE_MASK_W{1'b0}};

        fp16_residual_add #(
            .DATA_WIDTH(DATA_WIDTH),
            .ADDR_W(ADDR_W),
            .DATA_BUS_W(DATA_BUS_W),
            .REQ_ID_W(REQ_ID_W),
            .VECTOR_LEN(HIDDEN_DIM),
            .RESULT_STATUS_W(2),
            .RESULT_STATUS_OK(2'b00)
        ) u_residual_add2_draft (
            .clk(clk),
            .rst_n(rst_n),
            .issue_valid((state_r == ST_RES2_DRAFT_ISSUE) && draft_lane_active_w),
            .issue_ready(res2_draft_issue_ready_w[gen_post_slot]),
            .issue_x_addr(draft_slot_ffn_out_base_w),
            .issue_residual_addr(draft_slot_result_addr_w),
            .issue_result_addr(draft_slot_result_addr_w),
            .issue_req_id(SLOT_REQ_ID_W),
            .sram_rd_valid(res2_draft_rd_valid_w[gen_post_slot]),
            .sram_rd_ready(vec_sram_rd_ready[gen_post_slot]),
            .sram_rd_addr(res2_draft_rd_addr_w[gen_post_slot*ADDR_W +: ADDR_W]),
            .sram_rd_id(res2_draft_rd_id_w[gen_post_slot*REQ_ID_W +: REQ_ID_W]),
            .sram_resp_valid(vec_sram_resp_valid[gen_post_slot]),
            .sram_resp_ready(res2_draft_resp_ready_w[gen_post_slot]),
            .sram_resp_data(vec_sram_resp_data[gen_post_slot*DATA_BUS_W +: DATA_BUS_W]),
            .sram_resp_id(vec_sram_resp_id[gen_post_slot*REQ_ID_W +: REQ_ID_W]),
            .sram_wr_valid(res2_draft_wr_valid_w[gen_post_slot]),
            .sram_wr_ready(vec_sram_wr_ready[gen_post_slot]),
            .sram_wr_addr(res2_draft_wr_addr_w[gen_post_slot*ADDR_W +: ADDR_W]),
            .sram_wr_data(res2_draft_wr_data_w[gen_post_slot*DATA_BUS_W +: DATA_BUS_W]),
            .result_valid(res2_draft_result_valid_w[gen_post_slot]),
            .result_ready(res2_draft_result_ready_w[gen_post_slot]),
            .result_addr(res2_draft_result_addr_w[gen_post_slot*ADDR_W +: ADDR_W]),
            .result_data(res2_draft_result_data_w[gen_post_slot*DATA_BUS_W +: DATA_BUS_W]),
            .result_status(res2_draft_result_status_w[gen_post_slot*2 +: 2])
        );
        assign res2_draft_rd_pe_mask_w[gen_post_slot*`PE_MASK_W +: `PE_MASK_W] =
            draft_lane_active_w ? ({{(`PE_MASK_W-1){1'b0}}, 1'b1} << gen_post_slot) : {`PE_MASK_W{1'b0}};
        assign res2_draft_wr_id_w[gen_post_slot*REQ_ID_W +: REQ_ID_W] = SLOT_REQ_ID_W;
        assign res2_draft_wr_pe_mask_w[gen_post_slot*`PE_MASK_W +: `PE_MASK_W] =
            draft_lane_active_w ? ({{(`PE_MASK_W-1){1'b0}}, 1'b1} << gen_post_slot) : {`PE_MASK_W{1'b0}};
    end
endgenerate

assign issue_ready = (state_r == ST_IDLE);
assign pre_result_ready_w = (state_r == ST_PRE_WAIT);
assign mha_seed_result_ready_w = (state_r == ST_MHA_SEED_WAIT);
assign res1_result_ready_w = (state_r == ST_RES1_SEED_WAIT);
assign post_result_ready_w = (state_r == ST_POST_SEED_WAIT);
assign ffn_result_ready_w = (state_r == ST_FFN_SEED_WAIT);
assign res2_result_ready_w = (state_r == ST_RES2_SEED_WAIT);
assign result_valid = (state_r == ST_HOLD);
assign result_base_addr = result_base_addr_r;
assign result_slot_count = slot_count_r;
assign result_token_ids = result_token_ids_r;

always_comb begin
    layer_rd_valid_w = 1'b0;
    layer_rd_addr_w = {ADDR_W{1'b0}};
    layer_rd_id_w = {REQ_ID_W{1'b0}};
    layer_resp_ready_w = 1'b0;
    layer_wr_valid_w = 1'b0;
    layer_wr_addr_w = {ADDR_W{1'b0}};
    layer_wr_data_w = {DATA_BUS_W{1'b0}};

    if (pre_stage_active_w) begin
        layer_rd_valid_w = pre_rd_valid_w;
        layer_rd_addr_w = pre_rd_addr_w;
        layer_rd_id_w = pre_rd_id_w;
        layer_resp_ready_w = pre_resp_ready_w;
        layer_wr_valid_w = pre_wr_valid_w;
        layer_wr_addr_w = pre_wr_addr_w;
        layer_wr_data_w = pre_wr_data_w;
    end else if (res1_seed_stage_active_w) begin
        layer_rd_valid_w = res1_rd_valid_w;
        layer_rd_addr_w = res1_rd_addr_w;
        layer_rd_id_w = res1_rd_id_w;
        layer_resp_ready_w = res1_resp_ready_w;
        layer_wr_valid_w = res1_wr_valid_w;
        layer_wr_addr_w = res1_wr_addr_w;
        layer_wr_data_w = res1_wr_data_w;
    end else if (post_seed_stage_active_w) begin
        layer_rd_valid_w = post_rd_valid_w;
        layer_rd_addr_w = post_rd_addr_w;
        layer_rd_id_w = post_rd_id_w;
        layer_resp_ready_w = post_resp_ready_w;
        layer_wr_valid_w = post_wr_valid_w;
        layer_wr_addr_w = post_wr_addr_w;
        layer_wr_data_w = post_wr_data_w;
    end else if (ffn_seed_stage_active_w) begin
        layer_rd_valid_w = ffn_rd_valid_w;
        layer_rd_addr_w = ffn_rd_addr_w;
        layer_rd_id_w = ffn_rd_id_w;
        layer_resp_ready_w = ffn_resp_ready_w;
        layer_wr_valid_w = ffn_wr_valid_w;
        layer_wr_addr_w = ffn_wr_addr_w;
        layer_wr_data_w = ffn_wr_data_w;
    end else if (res2_seed_stage_active_w) begin
        layer_rd_valid_w = res2_rd_valid_w;
        layer_rd_addr_w = res2_rd_addr_w;
        layer_rd_id_w = res2_rd_id_w;
        layer_resp_ready_w = res2_resp_ready_w;
        layer_wr_valid_w = res2_wr_valid_w;
        layer_wr_addr_w = res2_wr_addr_w;
        layer_wr_data_w = res2_wr_data_w;
    end

    sram_rd_valid = 1'b0;
    sram_rd_addr = {ADDR_W{1'b0}};
    sram_rd_id = {REQ_ID_W{1'b0}};
    sram_resp_ready = 1'b0;
    sram_wr_valid = 1'b0;
    sram_wr_addr = {ADDR_W{1'b0}};
    sram_wr_data = {DATA_BUS_W{1'b0}};
    vec_sram_rd_valid = {`MEM_REQ_LANES{1'b0}};
    vec_sram_rd_addr = {(`MEM_REQ_LANES*ADDR_W){1'b0}};
    vec_sram_rd_id = {(`MEM_REQ_LANES*REQ_ID_W){1'b0}};
    vec_sram_rd_pe_mask = {(`MEM_REQ_LANES*`PE_MASK_W){1'b0}};
    vec_sram_resp_ready = {`MEM_REQ_LANES{1'b0}};
    vec_sram_wr_valid = {`MEM_REQ_LANES{1'b0}};
    vec_sram_wr_addr = {(`MEM_REQ_LANES*ADDR_W){1'b0}};
    vec_sram_wr_data = {(`MEM_REQ_LANES*DATA_BUS_W){1'b0}};
    vec_sram_wr_id = {(`MEM_REQ_LANES*REQ_ID_W){1'b0}};
    vec_sram_wr_pe_mask = {(`MEM_REQ_LANES*`PE_MASK_W){1'b0}};

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

        ST_MHA_SEED_ISSUE,
        ST_MHA_SEED_WAIT: begin
            sram_rd_valid = mha_seed_rd_valid_w;
            sram_rd_addr = mha_seed_rd_addr_w;
            sram_rd_id = mha_seed_rd_id_w;
            sram_resp_ready = mha_seed_resp_ready_w;
            sram_wr_valid = mha_seed_wr_valid_w;
            sram_wr_addr = mha_seed_wr_addr_w;
            sram_wr_data = mha_seed_wr_data_w;
        end

        ST_MHA_DRAFT_ISSUE,
        ST_MHA_DRAFT_WAIT: begin
            vec_sram_rd_valid = draft_mha_rd_valid_w;
            vec_sram_rd_addr = draft_mha_rd_addr_w;
            vec_sram_rd_id = draft_mha_rd_id_w;
            vec_sram_rd_pe_mask = draft_mha_rd_pe_mask_w;
            vec_sram_resp_ready = draft_mha_resp_ready_w;
            vec_sram_wr_valid = draft_mha_wr_valid_w;
            vec_sram_wr_addr = draft_mha_wr_addr_w;
            vec_sram_wr_data = draft_mha_wr_data_w;
            vec_sram_wr_id = draft_mha_wr_id_w;
            vec_sram_wr_pe_mask = draft_mha_wr_pe_mask_w;
        end

        ST_RES1_SEED_ISSUE,
        ST_RES1_SEED_WAIT: begin
            sram_rd_valid = res1_rd_valid_w;
            sram_rd_addr = res1_rd_addr_w;
            sram_rd_id = res1_rd_id_w;
            sram_resp_ready = res1_resp_ready_w;
            sram_wr_valid = res1_wr_valid_w;
            sram_wr_addr = res1_wr_addr_w;
            sram_wr_data = res1_wr_data_w;
        end

        ST_POST_SEED_ISSUE,
        ST_POST_SEED_WAIT: begin
            sram_rd_valid = post_rd_valid_w;
            sram_rd_addr = post_rd_addr_w;
            sram_rd_id = post_rd_id_w;
            sram_resp_ready = post_resp_ready_w;
            sram_wr_valid = post_wr_valid_w;
            sram_wr_addr = post_wr_addr_w;
            sram_wr_data = post_wr_data_w;
        end

        ST_FFN_SEED_ISSUE,
        ST_FFN_SEED_WAIT: begin
            sram_rd_valid = ffn_rd_valid_w;
            sram_rd_addr = ffn_rd_addr_w;
            sram_rd_id = ffn_rd_id_w;
            sram_resp_ready = ffn_resp_ready_w;
            sram_wr_valid = ffn_wr_valid_w;
            sram_wr_addr = ffn_wr_addr_w;
            sram_wr_data = ffn_wr_data_w;
        end

        ST_RES2_SEED_ISSUE,
        ST_RES2_SEED_WAIT: begin
            sram_rd_valid = layer_rd_valid_w;
            sram_rd_addr = layer_rd_addr_w;
            sram_rd_id = layer_rd_id_w;
            sram_resp_ready = layer_resp_ready_w;
            sram_wr_valid = layer_wr_valid_w;
            sram_wr_addr = layer_wr_addr_w;
            sram_wr_data = layer_wr_data_w;
        end

        ST_RES1_DRAFT_ISSUE,
        ST_RES1_DRAFT_WAIT: begin
            vec_sram_rd_valid = res1_draft_rd_valid_w;
            vec_sram_rd_addr = res1_draft_rd_addr_w;
            vec_sram_rd_id = res1_draft_rd_id_w;
            vec_sram_rd_pe_mask = res1_draft_rd_pe_mask_w;
            vec_sram_resp_ready = res1_draft_resp_ready_w;
            vec_sram_wr_valid = res1_draft_wr_valid_w;
            vec_sram_wr_addr = res1_draft_wr_addr_w;
            vec_sram_wr_data = res1_draft_wr_data_w;
            vec_sram_wr_id = res1_draft_wr_id_w;
            vec_sram_wr_pe_mask = res1_draft_wr_pe_mask_w;
        end

        ST_POST_DRAFT_ISSUE,
        ST_POST_DRAFT_WAIT: begin
            vec_sram_rd_valid = post_draft_rd_valid_w;
            vec_sram_rd_addr = post_draft_rd_addr_w;
            vec_sram_rd_id = post_draft_rd_id_w;
            vec_sram_rd_pe_mask = post_draft_rd_pe_mask_w;
            vec_sram_resp_ready = post_draft_resp_ready_w;
            vec_sram_wr_valid = post_draft_wr_valid_w;
            vec_sram_wr_addr = post_draft_wr_addr_w;
            vec_sram_wr_data = post_draft_wr_data_w;
            vec_sram_wr_id = post_draft_wr_id_w;
            vec_sram_wr_pe_mask = post_draft_wr_pe_mask_w;
        end

        ST_FFN_DRAFT_ISSUE,
        ST_FFN_DRAFT_WAIT: begin
            vec_sram_rd_valid = ffn_draft_rd_valid_w;
            vec_sram_rd_addr = ffn_draft_rd_addr_w;
            vec_sram_rd_id = ffn_draft_rd_id_w;
            vec_sram_rd_pe_mask = ffn_draft_rd_pe_mask_w;
            vec_sram_resp_ready = ffn_draft_resp_ready_w;
            vec_sram_wr_valid = ffn_draft_wr_valid_w;
            vec_sram_wr_addr = ffn_draft_wr_addr_w;
            vec_sram_wr_data = ffn_draft_wr_data_w;
            vec_sram_wr_id = ffn_draft_wr_id_w;
            vec_sram_wr_pe_mask = ffn_draft_wr_pe_mask_w;
        end

        ST_RES2_DRAFT_ISSUE,
        ST_RES2_DRAFT_WAIT: begin
            vec_sram_rd_valid = res2_draft_rd_valid_w;
            vec_sram_rd_addr = res2_draft_rd_addr_w;
            vec_sram_rd_id = res2_draft_rd_id_w;
            vec_sram_rd_pe_mask = res2_draft_rd_pe_mask_w;
            vec_sram_resp_ready = res2_draft_resp_ready_w;
            vec_sram_wr_valid = res2_draft_wr_valid_w;
            vec_sram_wr_addr = res2_draft_wr_addr_w;
            vec_sram_wr_data = res2_draft_wr_data_w;
            vec_sram_wr_id = res2_draft_wr_id_w;
            vec_sram_wr_pe_mask = res2_draft_wr_pe_mask_w;
        end

        default: begin
        end
    endcase
end

always_ff @(posedge clk or negedge rst_n) begin
    integer lane_i;
    if (!rst_n) begin
        state_r <= ST_IDLE;
        slot_count_r <= 5'd0;
        pre_slot_idx_r <= 5'd0;
        prefix_len_r <= 16'd0;
        token_ids_r <= {WINDOW_SIZE*32{1'b0}};
        positions_r <= {WINDOW_SIZE*16{1'b0}};
        tree_mask_r <= {WINDOW_SIZE*WINDOW_SIZE{1'b0}};
        slot_is_seed_r <= {WINDOW_SIZE{1'b0}};
        seed_kv_valid_r <= 1'b0;
        layer_id_r <= 5'd0;
        input_base_addr_r <= {ADDR_W{1'b0}};
        result_base_addr_r <= {ADDR_W{1'b0}};
        pre_norm_gamma_addr_r <= {ADDR_W{1'b0}};
        post_norm_gamma_addr_r <= {ADDR_W{1'b0}};
        wq_addr_r <= {ADDR_W{1'b0}};
        wk_addr_r <= {ADDR_W{1'b0}};
        wv_addr_r <= {ADDR_W{1'b0}};
        wo_addr_r <= {ADDR_W{1'b0}};
        gate_w_addr_r <= {ADDR_W{1'b0}};
        up_w_addr_r <= {ADDR_W{1'b0}};
        down_w_addr_r <= {ADDR_W{1'b0}};
        scratch_base_addr_r <= {ADDR_W{1'b0}};
        result_token_ids_r <= {WINDOW_SIZE*32{1'b0}};
        draft_mha_done_r <= {`MEM_REQ_LANES{1'b0}};
        draft_mha_result_arm_r <= {`MEM_REQ_LANES{1'b0}};
        draft_mha_resp_quiet_r <= {`MEM_REQ_LANES{1'b0}};
        draft_stage_done_r <= {`MEM_REQ_LANES{1'b0}};
    end else begin
        case (state_r)
            ST_IDLE: begin
                draft_mha_done_r <= {`MEM_REQ_LANES{1'b0}};
                draft_mha_result_arm_r <= {`MEM_REQ_LANES{1'b0}};
                draft_mha_resp_quiet_r <= {`MEM_REQ_LANES{1'b0}};
                draft_stage_done_r <= {`MEM_REQ_LANES{1'b0}};
                if (issue_valid) begin
                    slot_count_r <= issue_slot_count;
                    pre_slot_idx_r <= 5'd0;
                    prefix_len_r <= issue_prefix_len;
                    token_ids_r <= issue_token_ids;
                    positions_r <= issue_positions;
                    tree_mask_r <= issue_tree_mask;
                    slot_is_seed_r <= issue_slot_is_seed;
                    seed_kv_valid_r <= issue_seed_kv_valid;
                    layer_id_r <= issue_layer_id;
                    input_base_addr_r <= issue_input_base_addr;
                    result_base_addr_r <= issue_result_base_addr;
                    pre_norm_gamma_addr_r <= issue_pre_norm_gamma_addr;
                    post_norm_gamma_addr_r <= issue_post_norm_gamma_addr;
                    wq_addr_r <= issue_wq_addr;
                    wk_addr_r <= issue_wk_addr;
                    wv_addr_r <= issue_wv_addr;
                    wo_addr_r <= issue_wo_addr;
                    gate_w_addr_r <= issue_gate_w_addr;
                    up_w_addr_r <= issue_up_w_addr;
                    down_w_addr_r <= issue_down_w_addr;
                    scratch_base_addr_r <= issue_scratch_base_addr;
                    result_token_ids_r <= {WINDOW_SIZE*32{1'b0}};
                    state_r <= ST_PRE_ISSUE;
                end
            end

            ST_PRE_ISSUE: if (pre_issue_ready_w) state_r <= ST_PRE_WAIT;
            ST_PRE_WAIT: if (pre_result_valid_w && pre_result_ready_w) state_r <= ST_PRE_NEXT;

            ST_PRE_NEXT: begin
                if (pre_slot_idx_r + 5'd1 >= slot_count_r) begin
                    pre_slot_idx_r <= 5'd0;
                    state_r <= ST_MHA_SEED_ISSUE;
                end else begin
                    pre_slot_idx_r <= pre_slot_idx_r + 5'd1;
                    state_r <= ST_PRE_ISSUE;
                end
            end

            ST_MHA_SEED_ISSUE: begin
                if ((slot_count_r == 5'd0) ||
                    (mha_seed_issue_ready_w && (slot_count_r != 5'd0)))
                    state_r <= ST_MHA_SEED_WAIT;
            end

            ST_MHA_SEED_WAIT: begin
                if ((slot_count_r == 5'd0) ||
                    (mha_seed_result_valid_w && mha_seed_result_ready_w)) begin
                    if (draft_mha_any_active_w)
                        state_r <= ST_MHA_DRAFT_ISSUE;
                    else
                        state_r <= ST_RES1_SEED_ISSUE;
                end
            end

            ST_MHA_DRAFT_ISSUE: begin
                draft_mha_resp_quiet_r <= {`MEM_REQ_LANES{1'b0}};
                if (draft_mha_all_issue_ready_w)
                    state_r <= ST_MHA_DRAFT_WAIT;
            end

            ST_MHA_DRAFT_WAIT: begin
                draft_mha_resp_quiet_r <=
                    ~vec_sram_resp_valid & draft_mha_active_w;
                for (lane_i = 0; lane_i < `MEM_REQ_LANES; lane_i = lane_i + 1) begin
                    if (draft_mha_result_valid_w[lane_i] &&
                        !draft_mha_done_r[lane_i]) begin
                        draft_mha_result_arm_r[lane_i] <= 1'b1;
                    end
                    if (draft_mha_result_valid_w[lane_i] &&
                        draft_mha_result_ready_w[lane_i]) begin
                        draft_mha_done_r[lane_i] <= 1'b1;
                        draft_mha_result_arm_r[lane_i] <= 1'b0;
                    end
                end
                if (draft_mha_all_done_w) begin
                    draft_mha_done_r <= {`MEM_REQ_LANES{1'b0}};
                    draft_mha_result_arm_r <= {`MEM_REQ_LANES{1'b0}};
                    draft_mha_resp_quiet_r <= {`MEM_REQ_LANES{1'b0}};
                    state_r <= ST_RES1_SEED_ISSUE;
                end
            end

            ST_RES1_SEED_ISSUE: if (res1_issue_ready_w) state_r <= ST_RES1_SEED_WAIT;
            ST_RES1_SEED_WAIT: begin
                if (res1_result_valid_w && res1_result_ready_w) begin
                    draft_stage_done_r <= {`MEM_REQ_LANES{1'b0}};
                    if (draft_mha_any_active_w)
                        state_r <= ST_RES1_DRAFT_ISSUE;
                    else
                        state_r <= ST_POST_SEED_ISSUE;
                end
            end

            ST_RES1_DRAFT_ISSUE: begin
                if (res1_draft_all_issue_ready_w)
                    state_r <= ST_RES1_DRAFT_WAIT;
            end

            ST_RES1_DRAFT_WAIT: begin
                for (lane_i = 0; lane_i < `MEM_REQ_LANES; lane_i = lane_i + 1) begin
                    if (res1_draft_result_valid_w[lane_i] &&
                        res1_draft_result_ready_w[lane_i]) begin
                        draft_stage_done_r[lane_i] <= 1'b1;
                    end
                end
                if (res1_draft_all_done_w) begin
                    draft_stage_done_r <= {`MEM_REQ_LANES{1'b0}};
                    state_r <= ST_POST_SEED_ISSUE;
                end
            end

            ST_POST_SEED_ISSUE: if (post_issue_ready_w) state_r <= ST_POST_SEED_WAIT;
            ST_POST_SEED_WAIT: begin
                if (post_result_valid_w && post_result_ready_w) begin
                    draft_stage_done_r <= {`MEM_REQ_LANES{1'b0}};
                    if (draft_mha_any_active_w)
                        state_r <= ST_POST_DRAFT_ISSUE;
                    else
                        state_r <= ST_FFN_SEED_ISSUE;
                end
            end

            ST_POST_DRAFT_ISSUE: begin
                if (post_draft_all_issue_ready_w)
                    state_r <= ST_POST_DRAFT_WAIT;
            end

            ST_POST_DRAFT_WAIT: begin
                for (lane_i = 0; lane_i < `MEM_REQ_LANES; lane_i = lane_i + 1) begin
                    if (post_draft_result_valid_w[lane_i] &&
                        post_draft_result_ready_w[lane_i]) begin
                        draft_stage_done_r[lane_i] <= 1'b1;
                    end
                end
                if (post_draft_all_done_w) begin
                    draft_stage_done_r <= {`MEM_REQ_LANES{1'b0}};
                    state_r <= ST_FFN_SEED_ISSUE;
                end
            end

            ST_FFN_SEED_ISSUE: if (ffn_issue_ready_w) state_r <= ST_FFN_SEED_WAIT;
            ST_FFN_SEED_WAIT: begin
                if (ffn_result_valid_w && ffn_result_ready_w) begin
                    draft_stage_done_r <= {`MEM_REQ_LANES{1'b0}};
                    if (draft_mha_any_active_w)
                        state_r <= ST_FFN_DRAFT_ISSUE;
                    else
                        state_r <= ST_RES2_SEED_ISSUE;
                end
            end

            ST_FFN_DRAFT_ISSUE: begin
                if (ffn_draft_all_issue_ready_w)
                    state_r <= ST_FFN_DRAFT_WAIT;
            end

            ST_FFN_DRAFT_WAIT: begin
                for (lane_i = 0; lane_i < `MEM_REQ_LANES; lane_i = lane_i + 1) begin
                    if (ffn_draft_result_valid_w[lane_i] &&
                        ffn_draft_result_ready_w[lane_i]) begin
                        draft_stage_done_r[lane_i] <= 1'b1;
                    end
                end
                if (ffn_draft_all_done_w) begin
                    draft_stage_done_r <= {`MEM_REQ_LANES{1'b0}};
                    state_r <= ST_RES2_SEED_ISSUE;
                end
            end

            ST_RES2_SEED_ISSUE: if (res2_issue_ready_w) state_r <= ST_RES2_SEED_WAIT;
            ST_RES2_SEED_WAIT: begin
                if (res2_result_valid_w && res2_result_ready_w) begin
                    result_token_ids_r[0 +: 32] <= token_ids_r[0 +: 32];
                    draft_stage_done_r <= {`MEM_REQ_LANES{1'b0}};
                    if (draft_mha_any_active_w)
                        state_r <= ST_RES2_DRAFT_ISSUE;
                    else
                        state_r <= ST_HOLD;
                end
            end

            ST_RES2_DRAFT_ISSUE: begin
                if (res2_draft_all_issue_ready_w)
                    state_r <= ST_RES2_DRAFT_WAIT;
            end

            ST_RES2_DRAFT_WAIT: begin
                for (lane_i = 0; lane_i < `MEM_REQ_LANES; lane_i = lane_i + 1) begin
                    if (res2_draft_result_valid_w[lane_i] &&
                        res2_draft_result_ready_w[lane_i]) begin
                        draft_stage_done_r[lane_i] <= 1'b1;
                        result_token_ids_r[(lane_i+1)*32 +: 32] <=
                            token_ids_r[(lane_i+1)*32 +: 32];
                    end
                end
                if (res2_draft_all_done_w) begin
                    draft_stage_done_r <= {`MEM_REQ_LANES{1'b0}};
                    state_r <= ST_HOLD;
                end
            end

            ST_HOLD: if (result_valid && result_ready) state_r <= ST_IDLE;

            default: state_r <= ST_IDLE;
        endcase
    end
end

endmodule
`endif
