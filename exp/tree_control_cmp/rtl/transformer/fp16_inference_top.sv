`include "config/interface_params.vh"
`include "config/memory_params.vh"
`include "config/model_params.vh"
`include "transformer/fp16_mha_tree_attention.sv"
`timescale 1ns/1ps

module fp16_inference_top #(
    parameter integer ADDR_W = `SRAM_ADDR_W,
    parameter integer DATA_WIDTH = `FP16_TILE_DATA_W,
    parameter integer DATA_BUS_W = `SRAM_WDATA_W,
    parameter integer REQ_ID_W = `REQ_ID_W,
    parameter integer HBM_ADDR_W = `HBM_ADDR_W,
    parameter integer HBM_DATA_W = `HBM_DATA_W,
    parameter integer HIDDEN_DIM = `TOY_DMODEL,
    parameter integer INTERMEDIATE_DIM = `TOY_INTERMEDIATE_DIM,
    parameter integer NUM_HEADS = `TOY_NUM_Q_HEADS,
    parameter integer HEAD_DIM = `TOY_HEAD_DIM,
    parameter integer N_LAYERS = `TOY_N_LAYERS,
    parameter integer VOCAB_SIZE = `TOY_VOCAB_SIZE,
    parameter integer MAX_ATTN_TOKENS = `TOY_MAX_POS_EMB,
    parameter integer WINDOW_SIZE = `VERIFY_WINDOW_SIZE,
    parameter integer TILE_LANES = `FP16_TILE_LANES,
    parameter integer TILE_COLS = `FP16_TILE_COLS,
    parameter integer ELEMS_PER_SRAM_BEAT_P = DATA_BUS_W / DATA_WIDTH,
    parameter integer WEIGHT_BEATS_PER_TILE_P =
        (TILE_LANES * TILE_COLS) / ELEMS_PER_SRAM_BEAT_P,
    parameter integer PROJ_MATRIX_BEATS_P =
        ((HIDDEN_DIM + TILE_LANES - 1) / TILE_LANES) *
        ((HIDDEN_DIM + TILE_COLS - 1) / TILE_COLS) *
        WEIGHT_BEATS_PER_TILE_P,
    parameter integer FFN_EXPAND_MATRIX_BEATS_P =
        ((INTERMEDIATE_DIM + TILE_LANES - 1) / TILE_LANES) *
        ((HIDDEN_DIM + TILE_COLS - 1) / TILE_COLS) *
        WEIGHT_BEATS_PER_TILE_P,
    parameter integer FFN_DOWN_MATRIX_BEATS_P =
        ((HIDDEN_DIM + TILE_LANES - 1) / TILE_LANES) *
        ((INTERMEDIATE_DIM + TILE_COLS - 1) / TILE_COLS) *
        WEIGHT_BEATS_PER_TILE_P,
    parameter integer REQUIRED_WEIGHT_SLOT_BEATS_P =
        (PROJ_MATRIX_BEATS_P > FFN_EXPAND_MATRIX_BEATS_P) ?
            ((PROJ_MATRIX_BEATS_P > FFN_DOWN_MATRIX_BEATS_P) ?
                PROJ_MATRIX_BEATS_P : FFN_DOWN_MATRIX_BEATS_P) :
            ((FFN_EXPAND_MATRIX_BEATS_P > FFN_DOWN_MATRIX_BEATS_P) ?
                FFN_EXPAND_MATRIX_BEATS_P : FFN_DOWN_MATRIX_BEATS_P),
    parameter integer WEIGHT_WINDOW_BEATS = REQUIRED_WEIGHT_SLOT_BEATS_P * 8,
    parameter integer LAYER_WEIGHT_STRIDE =
        (((2 * (HIDDEN_DIM / ELEMS_PER_SRAM_BEAT_P)) + WEIGHT_WINDOW_BEATS) /
         (HBM_DATA_W / DATA_BUS_W)),
    parameter [ADDR_W-1:0] WORK_HIDDEN0_BASE = 23'd4096,
    parameter [ADDR_W-1:0] WORK_HIDDEN1_BASE = 23'd6144,
    parameter [ADDR_W-1:0] WORK_FINAL_BASE = 23'd8192,
    parameter [ADDR_W-1:0] WEIGHT_SRAM_BASE = 23'd16384,
    parameter [ADDR_W-1:0] KV_CACHE_SRAM_BASE = `KV_COMMITTED_BASE,
    parameter [HBM_ADDR_W-1:0] HBM_WEIGHT_BASE = 32'd1024,
    parameter [ADDR_W-1:0] LM_HEAD_WEIGHT_BASE = 23'd49664
) (
    input  logic                  clk,
    input  logic                  rst_n,

    input  logic                  token_in_valid,
    output logic                  token_in_ready,
    input  logic [31:0]           token_in_id,
    input  logic                  token_in_is_bos,
    output logic                  token_out_valid,
    input  logic                  token_out_ready,
    output logic [31:0]           token_out_id,
    input  logic [ADDR_W-1:0]     cfg_embedding_base,
    input  logic [ADDR_W-1:0]     cfg_final_norm_gamma_addr,
    input  logic                  cfg_do_sample,
    input  logic [6:0]            cfg_top_k,
    input  logic [15:0]           cfg_top_p,
    input  logic                  cfg_tree_mask_en,
    input  logic [`BRANCH_ID_W-1:0] cfg_branch_id,
    input  logic [15:0]           cfg_prefix_len,
    input  logic [MAX_ATTN_TOKENS-1:0] cfg_visible_mask,
    input  logic [15:0]           cfg_position,
    input  logic                  cfg_position_ovr,

    input  logic                  batch_in_valid,
    output logic                  batch_in_ready,
    input  logic [4:0]            batch_in_count,
    input  logic [WINDOW_SIZE*32-1:0]  batch_in_token_ids,
    input  logic [WINDOW_SIZE*16-1:0]  batch_in_positions,
    input  logic [WINDOW_SIZE*WINDOW_SIZE-1:0] batch_in_tree_mask,
    input  logic [15:0]           batch_in_prefix_len,
    input  logic                  batch_in_seed_kv_valid,
    input  logic [WINDOW_SIZE-1:0] batch_in_slot_is_seed,
    output logic                  batch_out_valid,
    input  logic                  batch_out_ready,
    output logic [4:0]            batch_out_count,
    output logic [WINDOW_SIZE*32-1:0] batch_out_token_ids,

    output logic                  hbm_rd_valid,
    input  logic                  hbm_rd_ready,
    output logic [HBM_ADDR_W-1:0] hbm_rd_addr,
    input  logic                  hbm_resp_valid,
    output logic                  hbm_resp_ready,
    input  logic [HBM_DATA_W-1:0] hbm_resp_data,

    output logic                  sram_rd_valid,
    input  logic                  sram_rd_ready,
    output logic [ADDR_W-1:0]     sram_rd_addr,
    output logic [REQ_ID_W-1:0]   sram_rd_id,
    input  logic                  sram_resp_valid,
    output logic                  sram_resp_ready,
    input  logic [DATA_BUS_W-1:0] sram_resp_data,
    input  logic [REQ_ID_W-1:0]   sram_resp_id,
    output logic                  sram_wr_valid,
    input  logic                  sram_wr_ready,
    output logic [ADDR_W-1:0]     sram_wr_addr,
    output logic [DATA_BUS_W-1:0] sram_wr_data,
    output logic [`MEM_REQ_LANES-1:0] vec_sram_rd_valid,
    input  logic [`MEM_REQ_LANES-1:0] vec_sram_rd_ready,
    output logic [`MEM_REQ_LANES*ADDR_W-1:0] vec_sram_rd_addr,
    output logic [`MEM_REQ_LANES*REQ_ID_W-1:0] vec_sram_rd_id,
    output logic [`MEM_REQ_LANES*`PE_MASK_W-1:0] vec_sram_rd_pe_mask,
    input  logic [`MEM_REQ_LANES-1:0] vec_sram_resp_valid,
    output logic [`MEM_REQ_LANES-1:0] vec_sram_resp_ready,
    input  logic [`MEM_REQ_LANES*DATA_BUS_W-1:0] vec_sram_resp_data,
    input  logic [`MEM_REQ_LANES*REQ_ID_W-1:0] vec_sram_resp_id,
    output logic [`MEM_REQ_LANES-1:0] vec_sram_wr_valid,
    input  logic [`MEM_REQ_LANES-1:0] vec_sram_wr_ready,
    output logic [`MEM_REQ_LANES*ADDR_W-1:0] vec_sram_wr_addr,
    output logic [`MEM_REQ_LANES*DATA_BUS_W-1:0] vec_sram_wr_data,
    output logic [`MEM_REQ_LANES*REQ_ID_W-1:0] vec_sram_wr_id,
    output logic [`MEM_REQ_LANES*`PE_MASK_W-1:0] vec_sram_wr_pe_mask,

    output logic                  busy,
    output logic [15:0]           current_position,
    output logic [4:0]            current_layer_debug
);

localparam logic [4:0]
    ST_IDLE                  = 5'd0,
    ST_EMBED_ISSUE           = 5'd1,
    ST_EMBED_WAIT            = 5'd2,
    ST_LAYER_ISSUE           = 5'd3,
    ST_LAYER_WAIT            = 5'd4,
    ST_NORM_ISSUE            = 5'd5,
    ST_NORM_WAIT             = 5'd6,
    ST_LM_ISSUE              = 5'd7,
    ST_LM_WAIT               = 5'd8,
    ST_HOLD                  = 5'd9,
    ST_BATCH_EMBED_ISSUE     = 5'd10,
    ST_BATCH_EMBED_WAIT      = 5'd11,
    ST_BATCH_LAYER_ISSUE     = 5'd12,
    ST_BATCH_LAYER_WAIT      = 5'd13,
    ST_BATCH_NORM_SEED_ISSUE = 5'd14,
    ST_BATCH_NORM_SEED_WAIT  = 5'd15,
    ST_BATCH_NORM_DRAFT_ISSUE = 5'd16,
    ST_BATCH_NORM_DRAFT_WAIT = 5'd17,
    ST_BATCH_LOGITS_SEED_ISSUE = 5'd18,
    ST_BATCH_LOGITS_SEED_WAIT = 5'd19,
    ST_BATCH_LOGITS_DRAFT_ISSUE = 5'd20,
    ST_BATCH_LOGITS_DRAFT_WAIT = 5'd21,
    ST_BATCH_HOLD            = 5'd22,
    ST_BATCH_HBM_REQ         = 5'd23,
    ST_BATCH_HBM_RESP        = 5'd24,
    ST_BATCH_HBM_WRITE0      = 5'd25,
    ST_BATCH_HBM_WRITE1      = 5'd26;
localparam integer HIDDEN_BEATS_P = HIDDEN_DIM / ELEMS_PER_SRAM_BEAT_P;
localparam integer INTERMEDIATE_BEATS_P = INTERMEDIATE_DIM / ELEMS_PER_SRAM_BEAT_P;
localparam integer HBM_TO_SRAM_RATIO_P = HBM_DATA_W / DATA_BUS_W;
localparam integer TOTAL_LAYER_PRELOAD_BEATS_P =
    (2 * HIDDEN_BEATS_P) + WEIGHT_WINDOW_BEATS;
localparam integer BATCH_PRELOAD_HBM_BEATS_P =
    TOTAL_LAYER_PRELOAD_BEATS_P / HBM_TO_SRAM_RATIO_P;
localparam integer TREE_BATCH_SLOT_SCRATCH_STRIDE_P =
    (HIDDEN_BEATS_P * 9) + (INTERMEDIATE_BEATS_P * 3);
localparam integer TREE_BATCH_LAYER_SCRATCH_STRIDE_P =
    WINDOW_SIZE * TREE_BATCH_SLOT_SCRATCH_STRIDE_P;
localparam integer TREE_BATCH_KV_REGION_STRIDE_P = 4096;
localparam [ADDR_W-1:0] TREE_BATCH_SCRATCH_BASE_P =
    `KV_DRAFT_BASE_MIN + (N_LAYERS * TREE_BATCH_KV_REGION_STRIDE_P);
localparam [REQ_ID_W-1:0] EMBEDDING_REQ_ID = 5'h11;
localparam [REQ_ID_W-1:0] LAYER_SCHED_REQ_ID = 5'h12;
localparam [REQ_ID_W-1:0] FINAL_NORM_REQ_ID = 5'h19;
localparam [REQ_ID_W-1:0] LM_HEAD_REQ_ID = 5'h1a;

function automatic [ADDR_W-1:0] addr_from_u32;
    input [31:0] value;
    begin
        addr_from_u32 = value[ADDR_W-1:0];
    end
endfunction

logic [4:0] state_r;
logic [31:0] token_in_id_r;
logic token_in_is_bos_r;
logic [ADDR_W-1:0] embedding_base_r;
logic [ADDR_W-1:0] final_norm_gamma_addr_r;
logic do_sample_r;
logic [6:0] top_k_r;
logic [15:0] top_p_r;
logic tree_mask_en_r;
logic [`BRANCH_ID_W-1:0] branch_id_r;
logic [15:0] prefix_len_r;
logic [MAX_ATTN_TOKENS-1:0] visible_mask_r;
logic [15:0] position_r;
logic [31:0] token_out_id_r;

logic [4:0] batch_count_r;
logic [4:0] batch_embed_slot_idx_r;
logic [4:0] batch_layer_idx_r;
logic [15:0] batch_preload_idx_r;
logic [ADDR_W-1:0] batch_last_hidden_base_r;
logic [WINDOW_SIZE*32-1:0] batch_token_ids_r;
logic [WINDOW_SIZE*16-1:0] batch_positions_r;
logic [WINDOW_SIZE*WINDOW_SIZE-1:0] batch_tree_mask_r;
logic [WINDOW_SIZE-1:0] batch_slot_is_seed_r;
logic batch_seed_kv_valid_r;
logic [WINDOW_SIZE*32-1:0] batch_out_token_ids_r;
logic [HBM_DATA_W-1:0] batch_hbm_beat_r;
logic [`MEM_REQ_LANES-1:0] batch_tail_done_r;

logic batch_mha_issue_ready_w;
logic batch_mha_result_valid_w;
logic batch_mha_result_ready_w;
logic [ADDR_W-1:0] batch_mha_result_addr_w;
logic [4:0] batch_mha_result_count_w;
logic [WINDOW_SIZE*32-1:0] batch_mha_result_token_ids_w;
logic batch_mha_rd_valid_w;
logic [ADDR_W-1:0] batch_mha_rd_addr_w;
logic [REQ_ID_W-1:0] batch_mha_rd_id_w;
logic batch_mha_resp_ready_w;
logic batch_mha_wr_valid_w;
logic [ADDR_W-1:0] batch_mha_wr_addr_w;
logic [DATA_BUS_W-1:0] batch_mha_wr_data_w;
logic [`MEM_REQ_LANES-1:0] batch_mha_vec_rd_valid_w;
logic [`MEM_REQ_LANES*ADDR_W-1:0] batch_mha_vec_rd_addr_w;
logic [`MEM_REQ_LANES*REQ_ID_W-1:0] batch_mha_vec_rd_id_w;
logic [`MEM_REQ_LANES*`PE_MASK_W-1:0] batch_mha_vec_rd_pe_mask_w;
logic [`MEM_REQ_LANES-1:0] batch_mha_vec_resp_ready_w;
logic [`MEM_REQ_LANES-1:0] batch_mha_vec_wr_valid_w;
logic [`MEM_REQ_LANES*ADDR_W-1:0] batch_mha_vec_wr_addr_w;
logic [`MEM_REQ_LANES*DATA_BUS_W-1:0] batch_mha_vec_wr_data_w;
logic [`MEM_REQ_LANES*REQ_ID_W-1:0] batch_mha_vec_wr_id_w;
logic [`MEM_REQ_LANES*`PE_MASK_W-1:0] batch_mha_vec_wr_pe_mask_w;

logic embedding_issue_ready_w;
logic embedding_rd_valid_w;
logic [ADDR_W-1:0] embedding_rd_addr_w;
logic [REQ_ID_W-1:0] embedding_rd_id_w;
logic embedding_resp_ready_w;
logic embedding_wr_valid_w;
logic [ADDR_W-1:0] embedding_wr_addr_w;
logic [DATA_BUS_W-1:0] embedding_wr_data_w;
logic embedding_result_valid_w;
logic embedding_result_ready_w;
logic [ADDR_W-1:0] embedding_result_addr_w;
logic [DATA_BUS_W-1:0] embedding_result_data_w;
logic [1:0] embedding_result_status_w;

logic scheduler_issue_ready_w;
logic scheduler_hbm_rd_valid_w;
logic [HBM_ADDR_W-1:0] scheduler_hbm_rd_addr_w;
logic scheduler_hbm_resp_ready_w;
logic scheduler_rd_valid_w;
logic [ADDR_W-1:0] scheduler_rd_addr_w;
logic [REQ_ID_W-1:0] scheduler_rd_id_w;
logic scheduler_resp_ready_w;
logic scheduler_wr_valid_w;
logic [ADDR_W-1:0] scheduler_wr_addr_w;
logic [DATA_BUS_W-1:0] scheduler_wr_data_w;
logic scheduler_result_valid_w;
logic scheduler_result_ready_w;
logic [ADDR_W-1:0] scheduler_result_addr_w;
logic [4:0] scheduler_current_layer_debug_w;

logic norm_issue_ready_w;
logic norm_rd_valid_w;
logic [ADDR_W-1:0] norm_rd_addr_w;
logic [REQ_ID_W-1:0] norm_rd_id_w;
logic norm_resp_ready_w;
logic norm_wr_valid_w;
logic [ADDR_W-1:0] norm_wr_addr_w;
logic [DATA_BUS_W-1:0] norm_wr_data_w;
logic norm_result_valid_w;
logic norm_result_ready_w;
logic [ADDR_W-1:0] norm_result_addr_w;
logic [DATA_BUS_W-1:0] norm_result_data_w;
logic [1:0] norm_result_status_w;
logic [`MEM_REQ_LANES-1:0] batch_norm_draft_issue_ready_w;
logic [`MEM_REQ_LANES-1:0] batch_norm_draft_rd_valid_w;
logic [`MEM_REQ_LANES*ADDR_W-1:0] batch_norm_draft_rd_addr_w;
logic [`MEM_REQ_LANES*REQ_ID_W-1:0] batch_norm_draft_rd_id_w;
logic [`MEM_REQ_LANES*`PE_MASK_W-1:0] batch_norm_draft_rd_pe_mask_w;
logic [`MEM_REQ_LANES-1:0] batch_norm_draft_resp_ready_w;
logic [`MEM_REQ_LANES-1:0] batch_norm_draft_wr_valid_w;
logic [`MEM_REQ_LANES*ADDR_W-1:0] batch_norm_draft_wr_addr_w;
logic [`MEM_REQ_LANES*DATA_BUS_W-1:0] batch_norm_draft_wr_data_w;
logic [`MEM_REQ_LANES*REQ_ID_W-1:0] batch_norm_draft_wr_id_w;
logic [`MEM_REQ_LANES*`PE_MASK_W-1:0] batch_norm_draft_wr_pe_mask_w;
logic [`MEM_REQ_LANES-1:0] batch_norm_draft_result_valid_w;
logic [`MEM_REQ_LANES-1:0] batch_norm_draft_result_ready_w;
logic [`MEM_REQ_LANES*ADDR_W-1:0] batch_norm_draft_result_addr_w;
logic [`MEM_REQ_LANES*DATA_BUS_W-1:0] batch_norm_draft_result_data_w;
logic [`MEM_REQ_LANES*2-1:0] batch_norm_draft_result_status_w;
logic batch_norm_draft_all_issue_ready_w;
logic batch_norm_draft_all_done_w;

logic lm_issue_ready_w;
logic lm_rd_valid_w;
logic [ADDR_W-1:0] lm_rd_addr_w;
logic [REQ_ID_W-1:0] lm_rd_id_w;
logic lm_resp_ready_w;
logic lm_result_valid_w;
logic lm_result_ready_w;
logic [31:0] lm_result_token_id_w;
logic [15:0] lm_result_logit_w;
logic [`MEM_REQ_LANES-1:0] batch_lm_draft_issue_ready_w;
logic [`MEM_REQ_LANES-1:0] batch_lm_draft_rd_valid_w;
logic [`MEM_REQ_LANES*ADDR_W-1:0] batch_lm_draft_rd_addr_w;
logic [`MEM_REQ_LANES*REQ_ID_W-1:0] batch_lm_draft_rd_id_w;
logic [`MEM_REQ_LANES*`PE_MASK_W-1:0] batch_lm_draft_rd_pe_mask_w;
logic [`MEM_REQ_LANES-1:0] batch_lm_draft_resp_ready_w;
logic [`MEM_REQ_LANES-1:0] batch_lm_draft_result_valid_w;
logic [`MEM_REQ_LANES-1:0] batch_lm_draft_result_ready_w;
logic [`MEM_REQ_LANES*32-1:0] batch_lm_draft_result_token_id_w;
logic [`MEM_REQ_LANES*16-1:0] batch_lm_draft_result_logit_w;
logic batch_lm_draft_all_issue_ready_w;
logic batch_lm_draft_all_done_w;

wire [ADDR_W-1:0] embed_result_base_w = WORK_HIDDEN0_BASE;
wire [ADDR_W-1:0] layer_result_base_w = WORK_HIDDEN1_BASE;
wire [ADDR_W-1:0] final_norm_result_base_w = WORK_FINAL_BASE;
wire [31:0] batch_embed_token_id_w =
    batch_token_ids_r[batch_embed_slot_idx_r*32 +: 32];
wire [ADDR_W-1:0] batch_embed_result_addr_w =
    WORK_HIDDEN0_BASE + addr_from_u32(batch_embed_slot_idx_r * HIDDEN_BEATS_P);
wire [ADDR_W-1:0] batch_layer_input_base_w =
    batch_layer_idx_r[0] ? WORK_HIDDEN1_BASE : WORK_HIDDEN0_BASE;
wire [ADDR_W-1:0] batch_layer_output_base_w =
    batch_layer_idx_r[0] ? WORK_HIDDEN0_BASE : WORK_HIDDEN1_BASE;
wire [ADDR_W-1:0] batch_layer_weight_base_w = WEIGHT_SRAM_BASE;
wire [31:0] batch_preload_sram_offset_w =
    batch_preload_idx_r * HBM_TO_SRAM_RATIO_P;
wire [HBM_ADDR_W-1:0] batch_hbm_rd_addr_w =
    HBM_WEIGHT_BASE + (batch_layer_idx_r * LAYER_WEIGHT_STRIDE) +
    batch_preload_idx_r;
wire [ADDR_W-1:0] batch_weight_write0_addr_w =
    batch_layer_weight_base_w + addr_from_u32(batch_preload_sram_offset_w);
wire [ADDR_W-1:0] batch_weight_write1_addr_w =
    batch_layer_weight_base_w +
    addr_from_u32(batch_preload_sram_offset_w + 32'd1);
wire [ADDR_W-1:0] batch_wq_addr_w =
    batch_layer_weight_base_w + addr_from_u32(HIDDEN_BEATS_P * 2);
wire [ADDR_W-1:0] batch_wk_addr_w =
    batch_layer_weight_base_w +
    addr_from_u32(HIDDEN_BEATS_P * 2 + WEIGHT_WINDOW_BEATS / 8);
wire [ADDR_W-1:0] batch_wv_addr_w =
    batch_layer_weight_base_w +
    addr_from_u32(HIDDEN_BEATS_P * 2 + WEIGHT_WINDOW_BEATS / 4);
wire [ADDR_W-1:0] batch_wo_addr_w =
    batch_layer_weight_base_w +
    addr_from_u32(HIDDEN_BEATS_P * 2 + (WEIGHT_WINDOW_BEATS * 3 / 8));
wire [ADDR_W-1:0] batch_gate_w_addr_w =
    batch_layer_weight_base_w +
    addr_from_u32(HIDDEN_BEATS_P * 2 + (WEIGHT_WINDOW_BEATS / 2));
wire [ADDR_W-1:0] batch_up_w_addr_w =
    batch_layer_weight_base_w +
    addr_from_u32(HIDDEN_BEATS_P * 2 + (WEIGHT_WINDOW_BEATS * 5 / 8));
wire [ADDR_W-1:0] batch_down_w_addr_w =
    batch_layer_weight_base_w +
    addr_from_u32(HIDDEN_BEATS_P * 2 + (WEIGHT_WINDOW_BEATS * 3 / 4));
wire [ADDR_W-1:0] batch_pre_norm_gamma_addr_w =
    batch_layer_weight_base_w;
wire [ADDR_W-1:0] batch_post_norm_gamma_addr_w =
    batch_layer_weight_base_w + addr_from_u32(HIDDEN_BEATS_P);
wire [ADDR_W-1:0] batch_layer_scratch_base_w =
    TREE_BATCH_SCRATCH_BASE_P +
    addr_from_u32(batch_layer_idx_r * TREE_BATCH_LAYER_SCRATCH_STRIDE_P);
wire [ADDR_W-1:0] batch_norm_seed_input_addr_w = batch_last_hidden_base_r;
wire [ADDR_W-1:0] batch_norm_seed_output_addr_w = WORK_FINAL_BASE;
wire [ADDR_W-1:0] batch_lm_seed_hidden_addr_w = WORK_FINAL_BASE;
wire [`MEM_REQ_LANES-1:0] batch_tail_active_w =
    (batch_count_r > 5'd1) ?
        (({`MEM_REQ_LANES{1'b1}}) >> (`MEM_REQ_LANES - (batch_count_r - 5'd1))) :
        {`MEM_REQ_LANES{1'b0}};
wire [ADDR_W-1:0] norm_issue_x_addr_w =
    (state_r == ST_BATCH_NORM_SEED_ISSUE) ?
        batch_norm_seed_input_addr_w : layer_result_base_w;
wire [ADDR_W-1:0] norm_issue_result_addr_w =
    (state_r == ST_BATCH_NORM_SEED_ISSUE) ?
        batch_norm_seed_output_addr_w : final_norm_result_base_w;
wire [ADDR_W-1:0] lm_issue_hidden_addr_w =
    (state_r == ST_BATCH_LOGITS_SEED_ISSUE) ?
        batch_lm_seed_hidden_addr_w : final_norm_result_base_w;

assign batch_in_ready = (state_r == ST_IDLE);
assign batch_out_valid = (state_r == ST_BATCH_HOLD);
assign batch_out_count = batch_count_r;
assign batch_out_token_ids = batch_out_token_ids_r;

fp16_embedding #(
    .DATA_WIDTH(DATA_WIDTH),
    .ADDR_W(ADDR_W),
    .DATA_BUS_W(DATA_BUS_W),
    .REQ_ID_W(REQ_ID_W),
    .VECTOR_LEN(HIDDEN_DIM),
    .RESULT_STATUS_W(2),
    .RESULT_STATUS_OK(2'b00)
) u_fp16_embedding (
    .clk(clk),
    .rst_n(rst_n),
    .issue_valid(
        (state_r == ST_EMBED_ISSUE) ||
        (state_r == ST_BATCH_EMBED_ISSUE)),
    .issue_ready(embedding_issue_ready_w),
    .issue_token_id(
        (state_r == ST_BATCH_EMBED_ISSUE) ?
            batch_embed_token_id_w : token_in_id_r),
    .issue_embedding_base(embedding_base_r),
    .issue_result_addr(
        (state_r == ST_BATCH_EMBED_ISSUE) ?
            batch_embed_result_addr_w : embed_result_base_w),
    .issue_req_id(EMBEDDING_REQ_ID),
    .sram_rd_valid(embedding_rd_valid_w),
    .sram_rd_ready(sram_rd_ready),
    .sram_rd_addr(embedding_rd_addr_w),
    .sram_rd_id(embedding_rd_id_w),
    .sram_resp_valid(sram_resp_valid),
    .sram_resp_ready(embedding_resp_ready_w),
    .sram_resp_data(sram_resp_data),
    .sram_resp_id(sram_resp_id),
    .sram_wr_valid(embedding_wr_valid_w),
    .sram_wr_ready(sram_wr_ready),
    .sram_wr_addr(embedding_wr_addr_w),
    .sram_wr_data(embedding_wr_data_w),
    .result_valid(embedding_result_valid_w),
    .result_ready(embedding_result_ready_w),
    .result_addr(embedding_result_addr_w),
    .result_data(embedding_result_data_w),
    .result_status(embedding_result_status_w)
);

fp16_layer_scheduler #(
    .ADDR_W(ADDR_W),
    .DATA_WIDTH(DATA_WIDTH),
    .DATA_BUS_W(DATA_BUS_W),
    .REQ_ID_W(REQ_ID_W),
    .HBM_ADDR_W(HBM_ADDR_W),
    .HBM_DATA_W(HBM_DATA_W),
    .HIDDEN_DIM(HIDDEN_DIM),
    .INTERMEDIATE_DIM(INTERMEDIATE_DIM),
    .NUM_HEADS(NUM_HEADS),
    .HEAD_DIM(HEAD_DIM),
    .N_LAYERS(N_LAYERS),
    .MAX_ATTN_TOKENS(MAX_ATTN_TOKENS),
    .TILE_LANES(TILE_LANES),
    .TILE_COLS(TILE_COLS),
    .WEIGHT_WINDOW_BEATS(WEIGHT_WINDOW_BEATS),
    .LAYER_WEIGHT_STRIDE(LAYER_WEIGHT_STRIDE)
) u_fp16_layer_scheduler (
    .clk(clk),
    .rst_n(rst_n),
    .issue_valid(state_r == ST_LAYER_ISSUE),
    .issue_ready(scheduler_issue_ready_w),
    .issue_token_position({16'd0, position_r}),
    .issue_input_addr(embed_result_base_w),
    .issue_result_addr(layer_result_base_w),
    .issue_weight_sram_base(WEIGHT_SRAM_BASE),
    .issue_kv_cache_base(KV_CACHE_SRAM_BASE),
    .issue_hbm_weight_base(HBM_WEIGHT_BASE),
    .issue_req_id(LAYER_SCHED_REQ_ID),
    .issue_tree_mask_en(tree_mask_en_r),
    .issue_branch_id(branch_id_r),
    .issue_prefix_len(prefix_len_r),
    .issue_visible_mask(visible_mask_r),
    .hbm_rd_valid(scheduler_hbm_rd_valid_w),
    .hbm_rd_ready(hbm_rd_ready),
    .hbm_rd_addr(scheduler_hbm_rd_addr_w),
    .hbm_resp_valid(hbm_resp_valid),
    .hbm_resp_ready(scheduler_hbm_resp_ready_w),
    .hbm_resp_data(hbm_resp_data),
    .sram_rd_valid(scheduler_rd_valid_w),
    .sram_rd_ready(sram_rd_ready),
    .sram_rd_addr(scheduler_rd_addr_w),
    .sram_rd_id(scheduler_rd_id_w),
    .sram_resp_valid(sram_resp_valid),
    .sram_resp_ready(scheduler_resp_ready_w),
    .sram_resp_data(sram_resp_data),
    .sram_resp_id(sram_resp_id),
    .sram_wr_valid(scheduler_wr_valid_w),
    .sram_wr_ready(sram_wr_ready),
    .sram_wr_addr(scheduler_wr_addr_w),
    .sram_wr_data(scheduler_wr_data_w),
    .result_valid(scheduler_result_valid_w),
    .result_ready(scheduler_result_ready_w),
    .result_addr(scheduler_result_addr_w),
    .current_layer_debug(scheduler_current_layer_debug_w)
);

fp16_rmsnorm #(
    .DATA_WIDTH(DATA_WIDTH),
    .ADDR_W(ADDR_W),
    .DATA_BUS_W(DATA_BUS_W),
    .REQ_ID_W(REQ_ID_W),
    .VECTOR_LEN(HIDDEN_DIM),
    .RESULT_STATUS_W(2),
    .RESULT_STATUS_OK(2'b00)
) u_fp16_final_rmsnorm (
    .clk(clk),
    .rst_n(rst_n),
    .issue_valid(
        (state_r == ST_NORM_ISSUE) ||
        (state_r == ST_BATCH_NORM_SEED_ISSUE)),
    .issue_ready(norm_issue_ready_w),
    .issue_x_addr(norm_issue_x_addr_w),
    .issue_gamma_addr(final_norm_gamma_addr_r),
    .issue_result_addr(norm_issue_result_addr_w),
    .issue_req_id(FINAL_NORM_REQ_ID),
    .sram_rd_valid(norm_rd_valid_w),
    .sram_rd_ready(sram_rd_ready),
    .sram_rd_addr(norm_rd_addr_w),
    .sram_rd_id(norm_rd_id_w),
    .sram_resp_valid(sram_resp_valid),
    .sram_resp_ready(norm_resp_ready_w),
    .sram_resp_data(sram_resp_data),
    .sram_resp_id(sram_resp_id),
    .sram_wr_valid(norm_wr_valid_w),
    .sram_wr_ready(sram_wr_ready),
    .sram_wr_addr(norm_wr_addr_w),
    .sram_wr_data(norm_wr_data_w),
    .result_valid(norm_result_valid_w),
    .result_ready(norm_result_ready_w),
    .result_addr(norm_result_addr_w),
    .result_data(norm_result_data_w),
    .result_status(norm_result_status_w)
);

fp16_lm_head #(
    .DATA_WIDTH(DATA_WIDTH),
    .ADDR_W(ADDR_W),
    .DATA_BUS_W(DATA_BUS_W),
    .REQ_ID_W(REQ_ID_W),
    .HIDDEN_DIM(HIDDEN_DIM),
    .VOCAB_SIZE(VOCAB_SIZE),
    .RESULT_STATUS_W(2)
) u_fp16_lm_head (
    .clk(clk),
    .rst_n(rst_n),
    .issue_valid(
        (state_r == ST_LM_ISSUE) ||
        (state_r == ST_BATCH_LOGITS_SEED_ISSUE)),
    .issue_ready(lm_issue_ready_w),
    .issue_hidden_addr(lm_issue_hidden_addr_w),
    .issue_emb_weight_addr(LM_HEAD_WEIGHT_BASE),
    .issue_do_sample(do_sample_r),
    .issue_temperature(16'h3c00),
    .issue_top_k(top_k_r),
    .issue_top_p(top_p_r),
    .issue_req_id(LM_HEAD_REQ_ID),
    .sram_rd_valid(lm_rd_valid_w),
    .sram_rd_ready(sram_rd_ready),
    .sram_rd_addr(lm_rd_addr_w),
    .sram_rd_id(lm_rd_id_w),
    .sram_resp_valid(sram_resp_valid),
    .sram_resp_ready(lm_resp_ready_w),
    .sram_resp_data(sram_resp_data),
    .sram_resp_id(sram_resp_id),
    .result_valid(lm_result_valid_w),
    .result_ready(lm_result_ready_w),
    .result_token_id(lm_result_token_id_w),
    .result_logit(lm_result_logit_w)
);

genvar gen_tail_slot;
generate
    for (gen_tail_slot = 0;
         gen_tail_slot < `MEM_REQ_LANES;
         gen_tail_slot = gen_tail_slot + 1) begin : gen_tail_slot_block
        localparam integer SLOT_WIRE_IDX = gen_tail_slot + 1;
        localparam [REQ_ID_W-1:0] SLOT_REQ_ID_W = SLOT_WIRE_IDX[REQ_ID_W-1:0];
        wire batch_tail_lane_active_w = batch_tail_active_w[gen_tail_slot];
        wire [ADDR_W-1:0] batch_norm_draft_input_addr_w =
            batch_last_hidden_base_r + addr_from_u32(SLOT_WIRE_IDX * HIDDEN_BEATS_P);
        wire [ADDR_W-1:0] batch_norm_draft_output_addr_w =
            WORK_FINAL_BASE + addr_from_u32(SLOT_WIRE_IDX * HIDDEN_BEATS_P);

        fp16_rmsnorm #(
            .DATA_WIDTH(DATA_WIDTH),
            .ADDR_W(ADDR_W),
            .DATA_BUS_W(DATA_BUS_W),
            .REQ_ID_W(REQ_ID_W),
            .VECTOR_LEN(HIDDEN_DIM),
            .RESULT_STATUS_W(2),
            .RESULT_STATUS_OK(2'b00)
        ) u_fp16_batch_final_rmsnorm_draft (
            .clk(clk),
            .rst_n(rst_n),
            .issue_valid((state_r == ST_BATCH_NORM_DRAFT_ISSUE) && batch_tail_lane_active_w),
            .issue_ready(batch_norm_draft_issue_ready_w[gen_tail_slot]),
            .issue_x_addr(batch_norm_draft_input_addr_w),
            .issue_gamma_addr(final_norm_gamma_addr_r),
            .issue_result_addr(batch_norm_draft_output_addr_w),
            .issue_req_id(SLOT_REQ_ID_W),
            .sram_rd_valid(batch_norm_draft_rd_valid_w[gen_tail_slot]),
            .sram_rd_ready(vec_sram_rd_ready[gen_tail_slot]),
            .sram_rd_addr(batch_norm_draft_rd_addr_w[gen_tail_slot*ADDR_W +: ADDR_W]),
            .sram_rd_id(batch_norm_draft_rd_id_w[gen_tail_slot*REQ_ID_W +: REQ_ID_W]),
            .sram_resp_valid(vec_sram_resp_valid[gen_tail_slot]),
            .sram_resp_ready(batch_norm_draft_resp_ready_w[gen_tail_slot]),
            .sram_resp_data(vec_sram_resp_data[gen_tail_slot*DATA_BUS_W +: DATA_BUS_W]),
            .sram_resp_id(vec_sram_resp_id[gen_tail_slot*REQ_ID_W +: REQ_ID_W]),
            .sram_wr_valid(batch_norm_draft_wr_valid_w[gen_tail_slot]),
            .sram_wr_ready(vec_sram_wr_ready[gen_tail_slot]),
            .sram_wr_addr(batch_norm_draft_wr_addr_w[gen_tail_slot*ADDR_W +: ADDR_W]),
            .sram_wr_data(batch_norm_draft_wr_data_w[gen_tail_slot*DATA_BUS_W +: DATA_BUS_W]),
            .result_valid(batch_norm_draft_result_valid_w[gen_tail_slot]),
            .result_ready(batch_norm_draft_result_ready_w[gen_tail_slot]),
            .result_addr(batch_norm_draft_result_addr_w[gen_tail_slot*ADDR_W +: ADDR_W]),
            .result_data(batch_norm_draft_result_data_w[gen_tail_slot*DATA_BUS_W +: DATA_BUS_W]),
            .result_status(batch_norm_draft_result_status_w[gen_tail_slot*2 +: 2])
        );
        assign batch_norm_draft_rd_pe_mask_w[gen_tail_slot*`PE_MASK_W +: `PE_MASK_W] =
            batch_tail_lane_active_w ? ({{(`PE_MASK_W-1){1'b0}}, 1'b1} << gen_tail_slot) : {`PE_MASK_W{1'b0}};
        assign batch_norm_draft_wr_id_w[gen_tail_slot*REQ_ID_W +: REQ_ID_W] = SLOT_REQ_ID_W;
        assign batch_norm_draft_wr_pe_mask_w[gen_tail_slot*`PE_MASK_W +: `PE_MASK_W] =
            batch_tail_lane_active_w ? ({{(`PE_MASK_W-1){1'b0}}, 1'b1} << gen_tail_slot) : {`PE_MASK_W{1'b0}};

        fp16_lm_head #(
            .DATA_WIDTH(DATA_WIDTH),
            .ADDR_W(ADDR_W),
            .DATA_BUS_W(DATA_BUS_W),
            .REQ_ID_W(REQ_ID_W),
            .HIDDEN_DIM(HIDDEN_DIM),
            .VOCAB_SIZE(VOCAB_SIZE),
            .RESULT_STATUS_W(2)
        ) u_fp16_lm_head_draft (
            .clk(clk),
            .rst_n(rst_n),
            .issue_valid((state_r == ST_BATCH_LOGITS_DRAFT_ISSUE) && batch_tail_lane_active_w),
            .issue_ready(batch_lm_draft_issue_ready_w[gen_tail_slot]),
            .issue_hidden_addr(batch_norm_draft_output_addr_w),
            .issue_emb_weight_addr(LM_HEAD_WEIGHT_BASE),
            .issue_do_sample(do_sample_r),
            .issue_temperature(16'h3c00),
            .issue_top_k(top_k_r),
            .issue_top_p(top_p_r),
            .issue_req_id(SLOT_REQ_ID_W),
            .sram_rd_valid(batch_lm_draft_rd_valid_w[gen_tail_slot]),
            .sram_rd_ready(vec_sram_rd_ready[gen_tail_slot]),
            .sram_rd_addr(batch_lm_draft_rd_addr_w[gen_tail_slot*ADDR_W +: ADDR_W]),
            .sram_rd_id(batch_lm_draft_rd_id_w[gen_tail_slot*REQ_ID_W +: REQ_ID_W]),
            .sram_resp_valid(vec_sram_resp_valid[gen_tail_slot]),
            .sram_resp_ready(batch_lm_draft_resp_ready_w[gen_tail_slot]),
            .sram_resp_data(vec_sram_resp_data[gen_tail_slot*DATA_BUS_W +: DATA_BUS_W]),
            .sram_resp_id(vec_sram_resp_id[gen_tail_slot*REQ_ID_W +: REQ_ID_W]),
            .result_valid(batch_lm_draft_result_valid_w[gen_tail_slot]),
            .result_ready(batch_lm_draft_result_ready_w[gen_tail_slot]),
            .result_token_id(batch_lm_draft_result_token_id_w[gen_tail_slot*32 +: 32]),
            .result_logit(batch_lm_draft_result_logit_w[gen_tail_slot*16 +: 16])
        );
        assign batch_lm_draft_rd_pe_mask_w[gen_tail_slot*`PE_MASK_W +: `PE_MASK_W] =
            batch_tail_lane_active_w ? ({{(`PE_MASK_W-1){1'b0}}, 1'b1} << gen_tail_slot) : {`PE_MASK_W{1'b0}};
    end
endgenerate

assign batch_norm_draft_all_issue_ready_w =
    ((batch_norm_draft_issue_ready_w | ~batch_tail_active_w) == {`MEM_REQ_LANES{1'b1}});
assign batch_lm_draft_all_issue_ready_w =
    ((batch_lm_draft_issue_ready_w | ~batch_tail_active_w) == {`MEM_REQ_LANES{1'b1}});
assign batch_norm_draft_all_done_w =
    ((batch_tail_done_r | ~batch_tail_active_w) == {`MEM_REQ_LANES{1'b1}});
assign batch_lm_draft_all_done_w =
    ((batch_tail_done_r | ~batch_tail_active_w) == {`MEM_REQ_LANES{1'b1}});

fp16_mha_tree_attention #(
    .ADDR_W(ADDR_W),
    .DATA_WIDTH(DATA_WIDTH),
    .DATA_BUS_W(DATA_BUS_W),
    .REQ_ID_W(REQ_ID_W),
    .HIDDEN_DIM(HIDDEN_DIM),
    .INTERMEDIATE_DIM(INTERMEDIATE_DIM),
    .NUM_HEADS(NUM_HEADS),
    .HEAD_DIM(HEAD_DIM),
    .MAX_ATTN_TOKENS(MAX_ATTN_TOKENS),
    .WINDOW_SIZE(WINDOW_SIZE)
) u_fp16_mha_tree_attention (
    .clk(clk),
    .rst_n(rst_n),
    .issue_valid(state_r == ST_BATCH_LAYER_ISSUE),
    .issue_ready(batch_mha_issue_ready_w),
    .issue_slot_count(batch_count_r),
    .issue_prefix_len(prefix_len_r),
    .issue_token_ids(batch_token_ids_r),
    .issue_positions(batch_positions_r),
    .issue_tree_mask(batch_tree_mask_r),
    .issue_slot_is_seed(batch_slot_is_seed_r),
    .issue_seed_kv_valid(batch_seed_kv_valid_r),
    .issue_layer_id(batch_layer_idx_r[4:0]),
    .issue_input_base_addr(batch_layer_input_base_w),
    .issue_result_base_addr(batch_layer_output_base_w),
    .issue_pre_norm_gamma_addr(batch_pre_norm_gamma_addr_w),
    .issue_post_norm_gamma_addr(batch_post_norm_gamma_addr_w),
    .issue_wq_addr(batch_wq_addr_w),
    .issue_wk_addr(batch_wk_addr_w),
    .issue_wv_addr(batch_wv_addr_w),
    .issue_wo_addr(batch_wo_addr_w),
    .issue_gate_w_addr(batch_gate_w_addr_w),
    .issue_up_w_addr(batch_up_w_addr_w),
    .issue_down_w_addr(batch_down_w_addr_w),
    .issue_scratch_base_addr(batch_layer_scratch_base_w),
    .sram_rd_valid(batch_mha_rd_valid_w),
    .sram_rd_ready(sram_rd_ready),
    .sram_rd_addr(batch_mha_rd_addr_w),
    .sram_rd_id(batch_mha_rd_id_w),
    .sram_resp_valid(sram_resp_valid),
    .sram_resp_ready(batch_mha_resp_ready_w),
    .sram_resp_data(sram_resp_data),
    .sram_resp_id(sram_resp_id),
    .sram_wr_valid(batch_mha_wr_valid_w),
    .sram_wr_ready(sram_wr_ready),
    .sram_wr_addr(batch_mha_wr_addr_w),
    .sram_wr_data(batch_mha_wr_data_w),
    .vec_sram_rd_valid(batch_mha_vec_rd_valid_w),
    .vec_sram_rd_ready(vec_sram_rd_ready),
    .vec_sram_rd_addr(batch_mha_vec_rd_addr_w),
    .vec_sram_rd_id(batch_mha_vec_rd_id_w),
    .vec_sram_rd_pe_mask(batch_mha_vec_rd_pe_mask_w),
    .vec_sram_resp_valid(vec_sram_resp_valid),
    .vec_sram_resp_ready(batch_mha_vec_resp_ready_w),
    .vec_sram_resp_data(vec_sram_resp_data),
    .vec_sram_resp_id(vec_sram_resp_id),
    .vec_sram_wr_valid(batch_mha_vec_wr_valid_w),
    .vec_sram_wr_ready(vec_sram_wr_ready),
    .vec_sram_wr_addr(batch_mha_vec_wr_addr_w),
    .vec_sram_wr_data(batch_mha_vec_wr_data_w),
    .vec_sram_wr_id(batch_mha_vec_wr_id_w),
    .vec_sram_wr_pe_mask(batch_mha_vec_wr_pe_mask_w),
    .result_valid(batch_mha_result_valid_w),
    .result_ready(batch_mha_result_ready_w),
    .result_base_addr(batch_mha_result_addr_w),
    .result_slot_count(batch_mha_result_count_w),
    .result_token_ids(batch_mha_result_token_ids_w)
);

assign token_in_ready = (state_r == ST_IDLE);
assign token_out_valid = (state_r == ST_HOLD);
assign token_out_id = token_out_id_r;
assign busy = (state_r != ST_IDLE);
assign current_position = position_r;
assign current_layer_debug =
    (state_r >= ST_BATCH_LAYER_ISSUE) ? batch_layer_idx_r[4:0] :
    scheduler_current_layer_debug_w;

assign embedding_result_ready_w =
    (state_r == ST_EMBED_WAIT) ||
    (state_r == ST_BATCH_EMBED_WAIT);
assign scheduler_result_ready_w = (state_r == ST_LAYER_WAIT);
assign norm_result_ready_w =
    (state_r == ST_NORM_WAIT) ||
    (state_r == ST_BATCH_NORM_SEED_WAIT);
assign lm_result_ready_w =
    (state_r == ST_LM_WAIT) ||
    (state_r == ST_BATCH_LOGITS_SEED_WAIT);
assign batch_mha_result_ready_w = (state_r == ST_BATCH_LAYER_WAIT);
assign batch_norm_draft_result_ready_w = {`MEM_REQ_LANES{1'b1}};
assign batch_lm_draft_result_ready_w = {`MEM_REQ_LANES{1'b1}};

always_comb begin
    hbm_rd_valid = 1'b0;
    hbm_rd_addr = {HBM_ADDR_W{1'b0}};
    hbm_resp_ready = 1'b0;
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
        ST_EMBED_ISSUE,
        ST_EMBED_WAIT,
        ST_BATCH_EMBED_ISSUE,
        ST_BATCH_EMBED_WAIT: begin
            sram_rd_valid = embedding_rd_valid_w;
            sram_rd_addr = embedding_rd_addr_w;
            sram_rd_id = embedding_rd_id_w;
            sram_resp_ready = embedding_resp_ready_w;
            sram_wr_valid = embedding_wr_valid_w;
            sram_wr_addr = embedding_wr_addr_w;
            sram_wr_data = embedding_wr_data_w;
        end

        ST_LAYER_ISSUE,
        ST_LAYER_WAIT: begin
            hbm_rd_valid = scheduler_hbm_rd_valid_w;
            hbm_rd_addr = scheduler_hbm_rd_addr_w;
            hbm_resp_ready = scheduler_hbm_resp_ready_w;
            sram_rd_valid = scheduler_rd_valid_w;
            sram_rd_addr = scheduler_rd_addr_w;
            sram_rd_id = scheduler_rd_id_w;
            sram_resp_ready = scheduler_resp_ready_w;
            sram_wr_valid = scheduler_wr_valid_w;
            sram_wr_addr = scheduler_wr_addr_w;
            sram_wr_data = scheduler_wr_data_w;
        end

        ST_BATCH_HBM_REQ,
        ST_BATCH_HBM_RESP: begin
            hbm_rd_valid = (state_r == ST_BATCH_HBM_REQ);
            hbm_rd_addr = batch_hbm_rd_addr_w;
            hbm_resp_ready = (state_r == ST_BATCH_HBM_RESP);
        end

        ST_BATCH_HBM_WRITE0: begin
            sram_wr_valid = 1'b1;
            sram_wr_addr = batch_weight_write0_addr_w;
            sram_wr_data = batch_hbm_beat_r[0 +: DATA_BUS_W];
        end

        ST_BATCH_HBM_WRITE1: begin
            sram_wr_valid = 1'b1;
            sram_wr_addr = batch_weight_write1_addr_w;
            sram_wr_data = batch_hbm_beat_r[DATA_BUS_W +: DATA_BUS_W];
        end

        ST_NORM_ISSUE,
        ST_NORM_WAIT,
        ST_BATCH_NORM_SEED_ISSUE,
        ST_BATCH_NORM_SEED_WAIT: begin
            sram_rd_valid = norm_rd_valid_w;
            sram_rd_addr = norm_rd_addr_w;
            sram_rd_id = norm_rd_id_w;
            sram_resp_ready = norm_resp_ready_w;
            sram_wr_valid = norm_wr_valid_w;
            sram_wr_addr = norm_wr_addr_w;
            sram_wr_data = norm_wr_data_w;
        end

        ST_BATCH_NORM_DRAFT_ISSUE,
        ST_BATCH_NORM_DRAFT_WAIT: begin
            vec_sram_rd_valid = batch_norm_draft_rd_valid_w;
            vec_sram_rd_addr = batch_norm_draft_rd_addr_w;
            vec_sram_rd_id = batch_norm_draft_rd_id_w;
            vec_sram_rd_pe_mask = batch_norm_draft_rd_pe_mask_w;
            vec_sram_resp_ready = batch_norm_draft_resp_ready_w;
            vec_sram_wr_valid = batch_norm_draft_wr_valid_w;
            vec_sram_wr_addr = batch_norm_draft_wr_addr_w;
            vec_sram_wr_data = batch_norm_draft_wr_data_w;
            vec_sram_wr_id = batch_norm_draft_wr_id_w;
            vec_sram_wr_pe_mask = batch_norm_draft_wr_pe_mask_w;
        end

        ST_LM_ISSUE,
        ST_LM_WAIT,
        ST_BATCH_LOGITS_SEED_ISSUE,
        ST_BATCH_LOGITS_SEED_WAIT: begin
            sram_rd_valid = lm_rd_valid_w;
            sram_rd_addr = lm_rd_addr_w;
            sram_rd_id = lm_rd_id_w;
            sram_resp_ready = lm_resp_ready_w;
        end

        ST_BATCH_LOGITS_DRAFT_ISSUE,
        ST_BATCH_LOGITS_DRAFT_WAIT: begin
            vec_sram_rd_valid = batch_lm_draft_rd_valid_w;
            vec_sram_rd_addr = batch_lm_draft_rd_addr_w;
            vec_sram_rd_id = batch_lm_draft_rd_id_w;
            vec_sram_rd_pe_mask = batch_lm_draft_rd_pe_mask_w;
            vec_sram_resp_ready = batch_lm_draft_resp_ready_w;
        end

        ST_BATCH_LAYER_ISSUE,
        ST_BATCH_LAYER_WAIT,
        ST_BATCH_HOLD: begin
            sram_rd_valid = batch_mha_rd_valid_w;
            sram_rd_addr = batch_mha_rd_addr_w;
            sram_rd_id = batch_mha_rd_id_w;
            sram_resp_ready = batch_mha_resp_ready_w;
            sram_wr_valid = batch_mha_wr_valid_w;
            sram_wr_addr = batch_mha_wr_addr_w;
            sram_wr_data = batch_mha_wr_data_w;
            vec_sram_rd_valid = batch_mha_vec_rd_valid_w;
            vec_sram_rd_addr = batch_mha_vec_rd_addr_w;
            vec_sram_rd_id = batch_mha_vec_rd_id_w;
            vec_sram_rd_pe_mask = batch_mha_vec_rd_pe_mask_w;
            vec_sram_resp_ready = batch_mha_vec_resp_ready_w;
            vec_sram_wr_valid = batch_mha_vec_wr_valid_w;
            vec_sram_wr_addr = batch_mha_vec_wr_addr_w;
            vec_sram_wr_data = batch_mha_vec_wr_data_w;
            vec_sram_wr_id = batch_mha_vec_wr_id_w;
            vec_sram_wr_pe_mask = batch_mha_vec_wr_pe_mask_w;
        end

        default: begin
        end
    endcase
end

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state_r <= ST_IDLE;
        token_in_id_r <= 32'd0;
        token_in_is_bos_r <= 1'b0;
        embedding_base_r <= {ADDR_W{1'b0}};
        final_norm_gamma_addr_r <= {ADDR_W{1'b0}};
        do_sample_r <= 1'b0;
        top_k_r <= 7'd1;
        top_p_r <= 16'h3c00;
        tree_mask_en_r <= 1'b0;
        branch_id_r <= {`BRANCH_ID_W{1'b0}};
        prefix_len_r <= 16'd0;
        visible_mask_r <= {MAX_ATTN_TOKENS{1'b0}};
        position_r <= 16'd0;
        token_out_id_r <= 32'd0;
        batch_count_r <= 5'd0;
        batch_embed_slot_idx_r <= 5'd0;
        batch_layer_idx_r <= 5'd0;
        batch_preload_idx_r <= 16'd0;
        batch_last_hidden_base_r <= {ADDR_W{1'b0}};
        batch_token_ids_r <= {WINDOW_SIZE*32{1'b0}};
        batch_positions_r <= {WINDOW_SIZE*16{1'b0}};
        batch_tree_mask_r <= {WINDOW_SIZE*WINDOW_SIZE{1'b0}};
        batch_slot_is_seed_r <= {WINDOW_SIZE{1'b0}};
        batch_seed_kv_valid_r <= 1'b0;
        batch_out_token_ids_r <= {WINDOW_SIZE*32{1'b0}};
        batch_hbm_beat_r <= {HBM_DATA_W{1'b0}};
        batch_tail_done_r <= {`MEM_REQ_LANES{1'b0}};
    end else begin
        case (state_r)
            ST_IDLE: begin
                if (batch_in_valid) begin
                    embedding_base_r <= cfg_embedding_base;
                    final_norm_gamma_addr_r <= cfg_final_norm_gamma_addr;
                    do_sample_r <= cfg_do_sample;
                    top_k_r <= cfg_top_k;
                    top_p_r <= cfg_top_p;
                    tree_mask_en_r <= 1'b1;
                    branch_id_r <= {`BRANCH_ID_W{1'b0}};
                    prefix_len_r <= batch_in_prefix_len;
                    visible_mask_r <= {MAX_ATTN_TOKENS{1'b0}};
                    batch_count_r <= batch_in_count;
                    batch_embed_slot_idx_r <= 5'd0;
                    batch_layer_idx_r <= 5'd0;
                    batch_preload_idx_r <= 16'd0;
                    batch_last_hidden_base_r <= WORK_HIDDEN0_BASE;
                    batch_token_ids_r <= batch_in_token_ids;
                    batch_positions_r <= batch_in_positions;
                    batch_tree_mask_r <= batch_in_tree_mask;
                    batch_slot_is_seed_r <= batch_in_slot_is_seed;
                    batch_seed_kv_valid_r <= batch_in_seed_kv_valid;
                    batch_out_token_ids_r <= {WINDOW_SIZE*32{1'b0}};
                    batch_hbm_beat_r <= {HBM_DATA_W{1'b0}};
                    batch_tail_done_r <= {`MEM_REQ_LANES{1'b0}};
                    state_r <= ST_BATCH_EMBED_ISSUE;
                end else if (token_in_valid) begin
                    token_in_id_r <= token_in_id;
                    token_in_is_bos_r <= token_in_is_bos;
                    embedding_base_r <= cfg_embedding_base;
                    final_norm_gamma_addr_r <= cfg_final_norm_gamma_addr;
                    do_sample_r <= cfg_do_sample;
                    top_k_r <= cfg_top_k;
                    top_p_r <= cfg_top_p;
                    tree_mask_en_r <= cfg_tree_mask_en;
                    branch_id_r <= cfg_branch_id;
                    prefix_len_r <= cfg_prefix_len;
                    visible_mask_r <= cfg_visible_mask;
                    if (token_in_is_bos)
                        position_r <= 16'd0;
                    else if (cfg_position_ovr)
                        position_r <= cfg_position;
                    state_r <= ST_EMBED_ISSUE;
                end
            end

            ST_EMBED_ISSUE: begin
                if (embedding_issue_ready_w)
                    state_r <= ST_EMBED_WAIT;
            end

            ST_EMBED_WAIT: begin
                if (embedding_result_valid_w && embedding_result_ready_w)
                    state_r <= ST_LAYER_ISSUE;
            end

            ST_BATCH_EMBED_ISSUE: begin
                if (embedding_issue_ready_w)
                    state_r <= ST_BATCH_EMBED_WAIT;
            end

            ST_BATCH_EMBED_WAIT: begin
                if (embedding_result_valid_w && embedding_result_ready_w) begin
                    if (batch_embed_slot_idx_r + 5'd1 >= batch_count_r) begin
                        batch_layer_idx_r <= 5'd0;
                        batch_preload_idx_r <= 16'd0;
                        state_r <= ST_BATCH_HBM_REQ;
                    end else begin
                        batch_embed_slot_idx_r <= batch_embed_slot_idx_r + 5'd1;
                        state_r <= ST_BATCH_EMBED_ISSUE;
                    end
                end
            end

            ST_BATCH_HBM_REQ: begin
                if (hbm_rd_ready)
                    state_r <= ST_BATCH_HBM_RESP;
            end

            ST_BATCH_HBM_RESP: begin
                if (hbm_resp_valid && hbm_resp_ready) begin
                    batch_hbm_beat_r <= hbm_resp_data;
                    state_r <= ST_BATCH_HBM_WRITE0;
                end
            end

            ST_BATCH_HBM_WRITE0: begin
                if (sram_wr_ready)
                    state_r <= ST_BATCH_HBM_WRITE1;
            end

            ST_BATCH_HBM_WRITE1: begin
                if (sram_wr_ready) begin
                    if (batch_preload_idx_r + 16'd1 >=
                        BATCH_PRELOAD_HBM_BEATS_P[15:0]) begin
                        state_r <= ST_BATCH_LAYER_ISSUE;
                    end else begin
                        batch_preload_idx_r <= batch_preload_idx_r + 16'd1;
                        state_r <= ST_BATCH_HBM_REQ;
                    end
                end
            end

            ST_LAYER_ISSUE: begin
                if (scheduler_issue_ready_w)
                    state_r <= ST_LAYER_WAIT;
            end

            ST_LAYER_WAIT: begin
                if (scheduler_result_valid_w && scheduler_result_ready_w)
                    state_r <= ST_NORM_ISSUE;
            end

            ST_NORM_ISSUE: begin
                if (norm_issue_ready_w)
                    state_r <= ST_NORM_WAIT;
            end

            ST_NORM_WAIT: begin
                if (norm_result_valid_w && norm_result_ready_w)
                    state_r <= ST_LM_ISSUE;
            end

            ST_LM_ISSUE: begin
                if (lm_issue_ready_w)
                    state_r <= ST_LM_WAIT;
            end

            ST_LM_WAIT: begin
                if (lm_result_valid_w && lm_result_ready_w) begin
                    token_out_id_r <= lm_result_token_id_w;
                    state_r <= ST_HOLD;
                end
            end

            ST_HOLD: begin
                if (token_out_valid && token_out_ready) begin
                    position_r <= position_r + 16'd1;
                    state_r <= ST_IDLE;
                end
            end

            ST_BATCH_LAYER_ISSUE: begin
                if (batch_mha_issue_ready_w)
                    state_r <= ST_BATCH_LAYER_WAIT;
            end

            ST_BATCH_LAYER_WAIT: begin
                if (batch_mha_result_valid_w && batch_mha_result_ready_w) begin
                    batch_count_r <= batch_mha_result_count_w;
                    batch_last_hidden_base_r <= batch_mha_result_addr_w;
                    if (batch_layer_idx_r + 5'd1 >= N_LAYERS[4:0]) begin
                        batch_tail_done_r <= {`MEM_REQ_LANES{1'b0}};
                        state_r <= ST_BATCH_NORM_SEED_ISSUE;
                    end else begin
                        batch_layer_idx_r <= batch_layer_idx_r + 5'd1;
                        batch_preload_idx_r <= 16'd0;
                        state_r <= ST_BATCH_HBM_REQ;
                    end
                end
            end

            ST_BATCH_NORM_SEED_ISSUE: begin
                if (norm_issue_ready_w)
                    state_r <= ST_BATCH_NORM_SEED_WAIT;
            end

            ST_BATCH_NORM_SEED_WAIT: begin
                if (norm_result_valid_w && norm_result_ready_w) begin
                    batch_tail_done_r <= {`MEM_REQ_LANES{1'b0}};
                    if (batch_count_r > 5'd1)
                        state_r <= ST_BATCH_NORM_DRAFT_ISSUE;
                    else
                        state_r <= ST_BATCH_LOGITS_SEED_ISSUE;
                end
            end

            ST_BATCH_NORM_DRAFT_ISSUE: begin
                if (batch_norm_draft_all_issue_ready_w)
                    state_r <= ST_BATCH_NORM_DRAFT_WAIT;
            end

            ST_BATCH_NORM_DRAFT_WAIT: begin
                for (int tail_i = 0; tail_i < `MEM_REQ_LANES; tail_i = tail_i + 1) begin
                    if (batch_norm_draft_result_valid_w[tail_i] &&
                        batch_norm_draft_result_ready_w[tail_i]) begin
                        batch_tail_done_r[tail_i] <= 1'b1;
                    end
                end
                if (batch_norm_draft_all_done_w)
                    state_r <= ST_BATCH_LOGITS_SEED_ISSUE;
            end

            ST_BATCH_LOGITS_SEED_ISSUE: begin
                if (lm_issue_ready_w)
                    state_r <= ST_BATCH_LOGITS_SEED_WAIT;
            end

            ST_BATCH_LOGITS_SEED_WAIT: begin
                if (lm_result_valid_w && lm_result_ready_w) begin
                    batch_out_token_ids_r[0 +: 32] <= lm_result_token_id_w;
                    batch_tail_done_r <= {`MEM_REQ_LANES{1'b0}};
                    if (batch_count_r > 5'd1)
                        state_r <= ST_BATCH_LOGITS_DRAFT_ISSUE;
                    else
                        state_r <= ST_BATCH_HOLD;
                end
            end

            ST_BATCH_LOGITS_DRAFT_ISSUE: begin
                if (batch_lm_draft_all_issue_ready_w)
                    state_r <= ST_BATCH_LOGITS_DRAFT_WAIT;
            end

            ST_BATCH_LOGITS_DRAFT_WAIT: begin
                for (int lm_i = 0; lm_i < `MEM_REQ_LANES; lm_i = lm_i + 1) begin
                    if (batch_lm_draft_result_valid_w[lm_i] &&
                        batch_lm_draft_result_ready_w[lm_i]) begin
                        batch_tail_done_r[lm_i] <= 1'b1;
                        batch_out_token_ids_r[(lm_i+1)*32 +: 32] <=
                            batch_lm_draft_result_token_id_w[lm_i*32 +: 32];
                    end
                end
                if (batch_lm_draft_all_done_w)
                    state_r <= ST_BATCH_HOLD;
            end

            ST_BATCH_HOLD: begin
                if (batch_out_valid && batch_out_ready)
                    state_r <= ST_IDLE;
            end

            default: begin
                state_r <= ST_IDLE;
            end
        endcase
    end
end

endmodule
