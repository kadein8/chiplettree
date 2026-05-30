`ifndef FP16_MHA_CONTROLLER_SV
`define FP16_MHA_CONTROLLER_SV
`include "config/interface_params.vh"
`include "config/memory_params.vh"
`include "config/model_params.vh"
`timescale 1ns/1ps

module fp16_mha_controller #(
    parameter integer ADDR_W = `SRAM_ADDR_W,
    parameter integer DATA_WIDTH = `FP16_TILE_DATA_W,
    parameter integer DATA_BUS_W = `SRAM_WDATA_W,
    parameter integer REQ_ID_W = `REQ_ID_W,
    parameter integer RESULT_STATUS_W = 2,
    parameter integer HIDDEN_DIM = `QWEN3_DMODEL,
    parameter integer NUM_HEADS = `QWEN3_NUM_Q_HEADS,
    parameter integer HEAD_DIM = `QWEN3_HEAD_DIM,
    parameter integer MAX_ATTN_TOKENS = `QWEN3_MAX_POS_EMB,
    parameter integer WINDOW_SIZE = `VERIFY_WINDOW_SIZE,
    parameter integer SLOT_ID_W = `SLOT_ID_W,
    parameter [RESULT_STATUS_W-1:0] RESULT_STATUS_OK = 2'b00
) (
    input  logic                       clk,
    input  logic                       rst_n,
    input  logic                       issue_valid,
    output logic                       issue_ready,
    input  logic [ADDR_W-1:0]          issue_input_addr,
    input  logic [ADDR_W-1:0]          issue_wq_addr,
    input  logic [ADDR_W-1:0]          issue_wk_addr,
    input  logic [ADDR_W-1:0]          issue_wv_addr,
    input  logic [ADDR_W-1:0]          issue_wo_addr,
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
    input  logic [SLOT_ID_W-1:0]       issue_tree_query_slot,
    input  logic [4:0]                 issue_tree_slot_count,
    input  logic [WINDOW_SIZE-1:0]     issue_tree_visible_slots,
    input  logic [WINDOW_SIZE-1:0]     issue_tree_slot_is_seed,
    input  logic                       issue_tree_seed_kv_valid,
    input  logic                       issue_tree_kv_barrier_release,
    output logic                       tree_kv_barrier_waiting,

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
localparam integer HEAD_BEATS = HEAD_DIM / ELEMS_PER_BEAT;
localparam [DATA_WIDTH-1:0] FP16_ZERO = 16'h0000;
localparam [DATA_WIDTH-1:0] FP16_NEG_INF = 16'hfc00;
localparam [15:0] MAX_ATTN_POS_W = MAX_ATTN_TOKENS - 1;
localparam logic [5:0]
    ST_IDLE            = 6'd0,
    ST_Q_ISSUE         = 6'd1,
    ST_Q_WAIT          = 6'd2,
    ST_K_ISSUE         = 6'd3,
    ST_K_WAIT          = 6'd4,
    ST_V_ISSUE         = 6'd5,
    ST_V_WAIT          = 6'd6,
    ST_LOAD_Q_REQ      = 6'd7,
    ST_LOAD_Q_RESP     = 6'd8,
    ST_ROPE_Q_START    = 6'd9,
    ST_ROPE_Q_WAIT     = 6'd10,
    ST_LOAD_K_REQ      = 6'd11,
    ST_LOAD_K_RESP     = 6'd12,
    ST_ROPE_K_START    = 6'd13,
    ST_ROPE_K_WAIT     = 6'd14,
    ST_CACHE_K_WRITE   = 6'd15,
    ST_LOAD_V_REQ      = 6'd16,
    ST_LOAD_V_RESP     = 6'd17,
    ST_CACHE_V_WRITE   = 6'd18,
    ST_DOT_REQ         = 6'd19,
    ST_DOT_RESP        = 6'd20,
    ST_DOT_NEXT        = 6'd21,
    ST_SOFT_EXP_PREP   = 6'd22,
    ST_SOFT_EXP_WAIT   = 6'd23,
    ST_SOFT_RECIP_PREP = 6'd24,
    ST_SOFT_RECIP_WAIT = 6'd25,
    ST_WV_REQ          = 6'd26,
    ST_WV_RESP         = 6'd27,
    ST_WV_NEXT         = 6'd28,
    ST_ATTN_WRITE      = 6'd29,
    ST_O_ISSUE         = 6'd30,
    ST_O_WAIT          = 6'd31,
    ST_LOAD_Q_DRAIN    = 6'd32,
    ST_LOAD_K_DRAIN    = 6'd33,
    ST_LOAD_V_DRAIN    = 6'd34,
    ST_DOT_DRAIN       = 6'd35,
    ST_WV_DRAIN        = 6'd36;

function automatic [ADDR_W-1:0] addr_from_u16;
    input [15:0] value;
    begin
        addr_from_u16 = {{(ADDR_W-16){1'b0}}, value};
    end
endfunction

function automatic [ADDR_W-1:0] addr_from_u32;
    input [31:0] value;
    begin
        addr_from_u32 = value[ADDR_W-1:0];
    end
endfunction

function automatic [DATA_WIDTH-1:0] fp16_neg;
    input [DATA_WIDTH-1:0] value;
    begin
        if (value == FP16_ZERO)
            fp16_neg = FP16_ZERO;
        else
            fp16_neg = {~value[DATA_WIDTH-1], value[DATA_WIDTH-2:0]};
    end
endfunction

function automatic fp16_gt;
    input [DATA_WIDTH-1:0] lhs;
    input [DATA_WIDTH-1:0] rhs;
    begin
        if (rhs == FP16_NEG_INF) begin
            fp16_gt = (lhs != FP16_NEG_INF);
        end else if (lhs[DATA_WIDTH-1] != rhs[DATA_WIDTH-1]) begin
            fp16_gt = (!lhs[DATA_WIDTH-1]) && rhs[DATA_WIDTH-1];
        end else if (!lhs[DATA_WIDTH-1]) begin
            fp16_gt = (lhs[DATA_WIDTH-2:0] > rhs[DATA_WIDTH-2:0]);
        end else begin
            fp16_gt = (lhs[DATA_WIDTH-2:0] < rhs[DATA_WIDTH-2:0]);
        end
    end
endfunction

function automatic [DATA_WIDTH-1:0] fp16_inv_sqrt_head_dim_const;
    input integer head_dim_value;
    begin
        case (head_dim_value)
            16: fp16_inv_sqrt_head_dim_const = 16'h3400;   // 1 / sqrt(16)
            32: fp16_inv_sqrt_head_dim_const = 16'h31a8;   // 1 / sqrt(32)
            64: fp16_inv_sqrt_head_dim_const = 16'h3000;   // 1 / sqrt(64)
            128: fp16_inv_sqrt_head_dim_const = 16'h2da8;  // 1 / sqrt(128)
            256: fp16_inv_sqrt_head_dim_const = 16'h2c00;  // 1 / sqrt(256)
            512: fp16_inv_sqrt_head_dim_const = 16'h29a8;  // 1 / sqrt(512)
            1024: fp16_inv_sqrt_head_dim_const = 16'h2800; // 1 / sqrt(1024)
            default: fp16_inv_sqrt_head_dim_const = 16'h3000;
        endcase
    end
endfunction

localparam [DATA_WIDTH-1:0] FP16_INV_SQRT_HEAD_DIM = fp16_inv_sqrt_head_dim_const(HEAD_DIM);

logic [5:0] state_r;
logic [ADDR_W-1:0] input_addr_r;
logic [ADDR_W-1:0] wq_addr_r;
logic [ADDR_W-1:0] wk_addr_r;
logic [ADDR_W-1:0] wv_addr_r;
logic [ADDR_W-1:0] wo_addr_r;
logic [ADDR_W-1:0] kv_cache_addr_r;
logic [ADDR_W-1:0] result_addr_r;
logic [ADDR_W-1:0] scratch_base_addr_r;
logic [15:0] position_r;
logic [4:0] layer_id_r;
logic [REQ_ID_W-1:0] req_id_r;
logic [15:0] head_idx_r;
logic [15:0] beat_idx_r;
logic [15:0] pos_idx_r;
logic [15:0] effective_position_r;
logic tree_mask_en_r;
logic [`BRANCH_ID_W-1:0] branch_id_r;
logic [15:0] prefix_len_r;
logic [MAX_ATTN_TOKENS-1:0] visible_mask_r;
logic tree_batch_en_r;
logic [ADDR_W-1:0] tree_draft_kv_base_r;
logic [SLOT_ID_W-1:0] tree_query_slot_r;
logic [4:0] tree_slot_count_r;
logic [WINDOW_SIZE-1:0] tree_visible_slots_r;
logic [WINDOW_SIZE-1:0] tree_slot_is_seed_r;
logic tree_seed_kv_valid_r;
logic tree_kv_write_done_r;
logic [DATA_WIDTH-1:0] dot_acc_r;
logic [DATA_WIDTH-1:0] score_value_r;
logic [DATA_WIDTH-1:0] score_max_r;
logic [DATA_WIDTH-1:0] exp_sum_r;
logic [DATA_WIDTH-1:0] inv_sum_r;
logic exp_enable_r;
logic recip_enable_r;
logic [DATA_WIDTH-1:0] exp_input_r;
logic [DATA_WIDTH-1:0] recip_input_r;
logic rd_req_accepted_r;

logic [(HEAD_DIM*DATA_WIDTH)-1:0] q_head_vector_r;
logic [(HEAD_DIM*DATA_WIDTH)-1:0] k_head_vector_r;
logic [(HEAD_DIM*DATA_WIDTH)-1:0] v_head_vector_r;
logic [(HEAD_DIM*DATA_WIDTH)-1:0] rotated_q_head_r;
logic [(HEAD_DIM*DATA_WIDTH)-1:0] rotated_k_head_r;
logic [(HEAD_DIM*DATA_WIDTH)-1:0] attn_out_r;
logic [DATA_WIDTH-1:0] score_mem_r [0:MAX_ATTN_TOKENS-1];
logic [DATA_WIDTH-1:0] weight_mem_r [0:MAX_ATTN_TOKENS-1];

logic matvec_issue_valid_w;
logic matvec_issue_ready_w;
logic [ADDR_W-1:0] matvec_weight_addr_w;
logic [ADDR_W-1:0] matvec_vector_addr_w;
logic [ADDR_W-1:0] matvec_result_addr_cfg_w;
logic matvec_rd_valid_w;
logic [ADDR_W-1:0] matvec_rd_addr_w;
logic [REQ_ID_W-1:0] matvec_rd_id_w;
logic matvec_resp_ready_w;
logic matvec_wr_valid_w;
logic [ADDR_W-1:0] matvec_wr_addr_w;
logic [DATA_BUS_W-1:0] matvec_wr_data_w;
logic matvec_result_valid_w;
logic matvec_result_ready_w;
logic [ADDR_W-1:0] matvec_result_addr_w;
logic [DATA_BUS_W-1:0] matvec_result_data_w;
logic [RESULT_STATUS_W-1:0] matvec_result_status_w;

logic rope_start_ready_w;
logic rope_rotated_valid_w;
logic [(HEAD_DIM*DATA_WIDTH)-1:0] rope_rotated_vector_w;
logic [(HEAD_DIM*DATA_WIDTH)-1:0] rope_input_vector_w;

wire [ADDR_W-1:0] q_buf_base_w = scratch_base_addr_r;
wire [ADDR_W-1:0] k_buf_base_w = scratch_base_addr_r + HIDDEN_BEATS;
wire [ADDR_W-1:0] v_buf_base_w = scratch_base_addr_r + (2 * HIDDEN_BEATS);
wire [ADDR_W-1:0] attn_buf_base_w = scratch_base_addr_r + (3 * HIDDEN_BEATS);
wire [ADDR_W-1:0] q_head_base_w = q_buf_base_w + addr_from_u32(head_idx_r * HEAD_BEATS);
wire [ADDR_W-1:0] k_head_base_w = k_buf_base_w + addr_from_u32(head_idx_r * HEAD_BEATS);
wire [ADDR_W-1:0] v_head_base_w = v_buf_base_w + addr_from_u32(head_idx_r * HEAD_BEATS);
wire [ADDR_W-1:0] attn_head_base_w = attn_buf_base_w + addr_from_u32(head_idx_r * HEAD_BEATS);
wire [31:0] kv_current_position_offset_w = position_r * NUM_HEADS * HEAD_BEATS * 2;
wire [31:0] kv_tree_query_slot_offset_w =
    tree_query_slot_r * NUM_HEADS * HEAD_BEATS * 2;
wire [ADDR_W-1:0] kv_tree_k_head_base_w =
    tree_draft_kv_base_r +
    addr_from_u32(kv_tree_query_slot_offset_w + (head_idx_r * HEAD_BEATS));
wire [ADDR_W-1:0] kv_tree_v_head_base_w =
    tree_draft_kv_base_r +
    addr_from_u32(
        kv_tree_query_slot_offset_w +
        (NUM_HEADS * HEAD_BEATS) +
        (head_idx_r * HEAD_BEATS));
wire [ADDR_W-1:0] kv_k_head_base_w =
    tree_batch_en_r ? kv_tree_k_head_base_w :
    (kv_cache_addr_r +
     addr_from_u32(kv_current_position_offset_w + (head_idx_r * HEAD_BEATS)));
wire [ADDR_W-1:0] kv_v_head_base_w =
    tree_batch_en_r ? kv_tree_v_head_base_w :
    (kv_cache_addr_r +
     addr_from_u32(
         kv_current_position_offset_w +
         (NUM_HEADS * HEAD_BEATS) +
         (head_idx_r * HEAD_BEATS)));
wire [31:0] kv_hist_position_offset_w = pos_idx_r * NUM_HEADS * HEAD_BEATS * 2;
wire tree_ctx_is_committed_w = tree_batch_en_r && (pos_idx_r < prefix_len_r);
wire [15:0] tree_ctx_slot_idx_u16_w = pos_idx_r - prefix_len_r;
wire [SLOT_ID_W-1:0] tree_ctx_slot_idx_w =
    tree_ctx_slot_idx_u16_w[SLOT_ID_W-1:0];
wire tree_query_is_seed_w = tree_slot_is_seed_r[tree_query_slot_r];
wire tree_query_needs_kv_w =
    !(tree_query_is_seed_w && tree_seed_kv_valid_r);
wire tree_ctx_slot_in_range_w =
    tree_ctx_slot_idx_u16_w < {{11{1'b0}}, tree_slot_count_r};
wire tree_ctx_is_seed_slot_w =
    tree_slot_is_seed_r[tree_ctx_slot_idx_w];
wire tree_ctx_skip_seed_duplicate_w =
    tree_ctx_is_seed_slot_w && tree_seed_kv_valid_r;
logic pos_visible_w;
wire [31:0] kv_tree_ctx_slot_offset_w =
    tree_ctx_slot_idx_w * NUM_HEADS * HEAD_BEATS * 2;
wire [ADDR_W-1:0] kv_tree_hist_draft_k_base_w =
    tree_draft_kv_base_r +
    addr_from_u32(kv_tree_ctx_slot_offset_w + (head_idx_r * HEAD_BEATS));
wire [ADDR_W-1:0] kv_tree_hist_draft_v_base_w =
    tree_draft_kv_base_r +
    addr_from_u32(
        kv_tree_ctx_slot_offset_w +
        (NUM_HEADS * HEAD_BEATS) +
        (head_idx_r * HEAD_BEATS));
wire [ADDR_W-1:0] kv_tree_hist_committed_k_base_w =
    kv_cache_addr_r +
    addr_from_u32(kv_hist_position_offset_w + (head_idx_r * HEAD_BEATS));
wire [ADDR_W-1:0] kv_tree_hist_committed_v_base_w =
    kv_cache_addr_r +
    addr_from_u32(
        kv_hist_position_offset_w +
        (NUM_HEADS * HEAD_BEATS) +
        (head_idx_r * HEAD_BEATS));
wire [ADDR_W-1:0] kv_hist_k_base_w =
    tree_batch_en_r ?
        (tree_ctx_is_committed_w ?
            kv_tree_hist_committed_k_base_w :
            kv_tree_hist_draft_k_base_w) :
        (kv_cache_addr_r +
         addr_from_u32(
             kv_hist_position_offset_w + (head_idx_r * HEAD_BEATS)));
wire [ADDR_W-1:0] kv_hist_v_base_w =
    tree_batch_en_r ?
        (tree_ctx_is_committed_w ?
            kv_tree_hist_committed_v_base_w :
            kv_tree_hist_draft_v_base_w) :
        (kv_cache_addr_r +
         addr_from_u32(
             kv_hist_position_offset_w +
             (NUM_HEADS * HEAD_BEATS) +
             (head_idx_r * HEAD_BEATS)));
wire tree_dot_needs_read_w =
    !tree_batch_en_r || tree_ctx_is_committed_w || pos_visible_w;
wire tree_softmax_skip_w =
    tree_batch_en_r && !tree_ctx_is_committed_w && !pos_visible_w;
wire tree_wv_needs_read_w =
    !tree_batch_en_r || tree_ctx_is_committed_w || pos_visible_w;
wire softmax_pos_active_w =
    !tree_batch_en_r || !tree_softmax_skip_w;

logic [DATA_WIDTH-1:0] q_dot_elem_w [0:ELEMS_PER_BEAT-1];
logic [DATA_WIDTH-1:0] k_dot_elem_w [0:ELEMS_PER_BEAT-1];
logic [DATA_WIDTH-1:0] dot_mul_w [0:ELEMS_PER_BEAT-1];
logic [DATA_WIDTH-1:0] dot_l1_w [0:(ELEMS_PER_BEAT/2)-1];
logic [DATA_WIDTH-1:0] dot_l2_w [0:(ELEMS_PER_BEAT/4)-1];
logic [DATA_WIDTH-1:0] dot_beat_sum_w;
logic [DATA_WIDTH-1:0] dot_acc_next_w;
logic [DATA_WIDTH-1:0] dot_scaled_w;

logic [DATA_WIDTH-1:0] resp_v_elem_w [0:ELEMS_PER_BEAT-1];
logic [DATA_WIDTH-1:0] attn_prev_elem_w [0:ELEMS_PER_BEAT-1];
logic [DATA_WIDTH-1:0] weighted_v_mul_w [0:ELEMS_PER_BEAT-1];
logic [DATA_WIDTH-1:0] attn_accum_next_w [0:ELEMS_PER_BEAT-1];
logic [DATA_WIDTH-1:0] normalized_weight_w;

logic [DATA_WIDTH-1:0] exp_delta_w;
logic [DATA_WIDTH-1:0] exp_out_w;
logic exp_ack_w;
logic [DATA_WIDTH-1:0] exp_sum_next_w;
logic [DATA_WIDTH-1:0] recip_out_w;
logic recip_ack_w;

genvar elem_g;
genvar dot_l1_g;
genvar dot_l2_g;

assign rope_input_vector_w =
    (state_r == ST_ROPE_Q_START || state_r == ST_ROPE_Q_WAIT) ? q_head_vector_r : k_head_vector_r;

assign pos_visible_w =
    tree_batch_en_r ?
        (tree_ctx_is_committed_w ?
            1'b1 :
            (tree_ctx_slot_in_range_w &&
             tree_visible_slots_r[tree_ctx_slot_idx_w] &&
             !tree_ctx_skip_seed_duplicate_w)) :
        (tree_mask_en_r ? visible_mask_r[pos_idx_r] : 1'b1);

assign matvec_issue_valid_w =
    (state_r == ST_Q_ISSUE) ||
    (state_r == ST_K_ISSUE) ||
    (state_r == ST_V_ISSUE) ||
    (state_r == ST_O_ISSUE);

assign matvec_weight_addr_w =
    (state_r == ST_Q_ISSUE) ? wq_addr_r :
    (state_r == ST_K_ISSUE) ? wk_addr_r :
    (state_r == ST_V_ISSUE) ? wv_addr_r :
    wo_addr_r;

assign matvec_vector_addr_w =
    (state_r == ST_O_ISSUE) ? attn_buf_base_w : input_addr_r;

assign matvec_result_addr_cfg_w =
    (state_r == ST_Q_ISSUE) ? q_buf_base_w :
    (state_r == ST_K_ISSUE) ? k_buf_base_w :
    (state_r == ST_V_ISSUE) ? v_buf_base_w :
    result_addr_r;

wire matvec_resp_quiet_w =
    !(sram_resp_valid && (sram_resp_id == req_id_r));
assign matvec_result_ready_w =
    ((state_r == ST_Q_WAIT) ||
     (state_r == ST_K_WAIT) ||
     (state_r == ST_V_WAIT)) ? matvec_resp_quiet_w :
    ((state_r == ST_O_WAIT) ? (result_ready && matvec_resp_quiet_w) : 1'b0);
assign issue_ready = (state_r == ST_IDLE);
assign result_valid =
    (state_r == ST_O_WAIT) &&
    matvec_result_valid_w &&
    matvec_resp_quiet_w;
assign result_addr = result_addr_r;
assign result_data = matvec_result_data_w;
assign result_status = matvec_result_status_w;
assign tree_kv_barrier_waiting =
    tree_batch_en_r &&
    (state_r == ST_CACHE_V_WRITE) &&
    tree_kv_write_done_r;

fp16_tiled_matvec #(
    .LANES(`FP16_TILE_LANES),
    .COLS(`FP16_TILE_COLS),
    .DATA_WIDTH(DATA_WIDTH),
    .ADDR_W(ADDR_W),
    .DATA_BUS_W(DATA_BUS_W),
    .REQ_ID_W(REQ_ID_W),
    .RESULT_STATUS_W(RESULT_STATUS_W),
    .MAX_MATRIX_ROWS(HIDDEN_DIM),
    .MAX_MATRIX_COLS(HIDDEN_DIM),
    .RESULT_STATUS_OK(RESULT_STATUS_OK)
) u_fp16_tiled_matvec (
    .clk(clk),
    .rst_n(rst_n),
    .issue_valid(matvec_issue_valid_w),
    .issue_ready(matvec_issue_ready_w),
    .issue_weight_base_addr(matvec_weight_addr_w),
    .issue_vector_addr(matvec_vector_addr_w),
    .issue_result_addr(matvec_result_addr_cfg_w),
    .issue_req_id(req_id_r),
    .issue_matrix_rows(HIDDEN_DIM[15:0]),
    .issue_matrix_cols(HIDDEN_DIM[15:0]),
    .sram_rd_valid(matvec_rd_valid_w),
    .sram_rd_ready(sram_rd_ready),
    .sram_rd_addr(matvec_rd_addr_w),
    .sram_rd_id(matvec_rd_id_w),
    .sram_resp_valid(sram_resp_valid),
    .sram_resp_ready(matvec_resp_ready_w),
    .sram_resp_data(sram_resp_data),
    .sram_resp_id(sram_resp_id),
    .sram_wr_valid(matvec_wr_valid_w),
    .sram_wr_ready(sram_wr_ready),
    .sram_wr_addr(matvec_wr_addr_w),
    .sram_wr_data(matvec_wr_data_w),
    .result_valid(matvec_result_valid_w),
    .result_ready(matvec_result_ready_w),
    .result_addr(matvec_result_addr_w),
    .result_data(matvec_result_data_w),
    .result_status(matvec_result_status_w)
);

fp16_rope #(
    .DATA_WIDTH(DATA_WIDTH),
    .HEAD_DIM(HEAD_DIM),
    .PARALLEL_PAIRS(8)
) u_fp16_rope (
    .clk(clk),
    .rst_n(rst_n),
    .start_valid((state_r == ST_ROPE_Q_START) || (state_r == ST_ROPE_K_START)),
    .start_ready(rope_start_ready_w),
    .position(position_r),
    .head_vector(rope_input_vector_w),
    .rotated_valid(rope_rotated_valid_w),
    .rotated_vector(rope_rotated_vector_w)
);

generate
    for (elem_g = 0; elem_g < ELEMS_PER_BEAT; elem_g = elem_g + 1) begin : gen_attn_lanes
        assign q_dot_elem_w[elem_g] =
            rotated_q_head_r[((beat_idx_r * ELEMS_PER_BEAT + elem_g) * DATA_WIDTH) +: DATA_WIDTH];
        assign k_dot_elem_w[elem_g] =
            sram_resp_data[(elem_g * DATA_WIDTH) +: DATA_WIDTH];
        assign resp_v_elem_w[elem_g] =
            sram_resp_data[(elem_g * DATA_WIDTH) +: DATA_WIDTH];
        assign attn_prev_elem_w[elem_g] =
            attn_out_r[((beat_idx_r * ELEMS_PER_BEAT + elem_g) * DATA_WIDTH) +: DATA_WIDTH];

        floatMult16 u_dot_mul (
            .floatA(q_dot_elem_w[elem_g]),
            .floatB(k_dot_elem_w[elem_g]),
            .product(dot_mul_w[elem_g])
        );

        floatMult16 u_weighted_v_mul (
            .floatA(resp_v_elem_w[elem_g]),
            .floatB(normalized_weight_w),
            .product(weighted_v_mul_w[elem_g])
        );

        floatAdd16 u_attn_accum (
            .floatA(attn_prev_elem_w[elem_g]),
            .floatB(weighted_v_mul_w[elem_g]),
            .sum(attn_accum_next_w[elem_g])
        );
    end
endgenerate

generate
    for (dot_l1_g = 0; dot_l1_g < (ELEMS_PER_BEAT / 2); dot_l1_g = dot_l1_g + 1) begin : gen_dot_l1
        floatAdd16 u_dot_l1_add (
            .floatA(dot_mul_w[dot_l1_g * 2]),
            .floatB(dot_mul_w[dot_l1_g * 2 + 1]),
            .sum(dot_l1_w[dot_l1_g])
        );
    end
endgenerate

generate
    for (dot_l2_g = 0; dot_l2_g < (ELEMS_PER_BEAT / 4); dot_l2_g = dot_l2_g + 1) begin : gen_dot_l2
        floatAdd16 u_dot_l2_add (
            .floatA(dot_l1_w[dot_l2_g * 2]),
            .floatB(dot_l1_w[dot_l2_g * 2 + 1]),
            .sum(dot_l2_w[dot_l2_g])
        );
    end
endgenerate

floatAdd16 u_dot_l3_add (
    .floatA(dot_l2_w[0]),
    .floatB(dot_l2_w[1]),
    .sum(dot_beat_sum_w)
);

floatAdd16 u_dot_acc_add (
    .floatA(dot_acc_r),
    .floatB(dot_beat_sum_w),
    .sum(dot_acc_next_w)
);

floatMult16 u_dot_scale (
    .floatA(dot_acc_next_w),
    .floatB(FP16_INV_SQRT_HEAD_DIM),
    .product(dot_scaled_w)
);

floatAdd16 u_exp_delta_add (
    .floatA(score_mem_r[pos_idx_r]),
    .floatB(fp16_neg(score_max_r)),
    .sum(exp_delta_w)
);

exponent #(
    .DATA_WIDTH(DATA_WIDTH)
) u_exponent (
    .x(exp_input_r),
    .clk(clk),
    .enable(exp_enable_r),
    .output_exp(exp_out_w),
    .ack(exp_ack_w)
);

floatAdd16 u_exp_sum_add (
    .floatA(exp_sum_r),
    .floatB(exp_out_w),
    .sum(exp_sum_next_w)
);

floatReciprocal #(
    .DATA_WIDTH(DATA_WIDTH)
) u_recip (
    .number(recip_input_r),
    .enable(recip_enable_r),
    .clk(clk),
    .output_rec(recip_out_w),
    .ack(recip_ack_w)
);

floatMult16 u_norm_weight (
    .floatA(weight_mem_r[pos_idx_r]),
    .floatB(inv_sum_r),
    .product(normalized_weight_w)
);

always_comb begin
    sram_rd_valid = 1'b0;
    sram_rd_addr = {ADDR_W{1'b0}};
    sram_rd_id = req_id_r;
    sram_resp_ready = 1'b0;
    sram_wr_valid = 1'b0;
    sram_wr_addr = {ADDR_W{1'b0}};
    sram_wr_data = {DATA_BUS_W{1'b0}};

    case (state_r)
        ST_Q_ISSUE,
        ST_Q_WAIT,
        ST_K_ISSUE,
        ST_K_WAIT,
        ST_V_ISSUE,
        ST_V_WAIT,
        ST_O_ISSUE,
        ST_O_WAIT: begin
            sram_rd_valid = matvec_rd_valid_w;
            sram_rd_addr = matvec_rd_addr_w;
            sram_rd_id = matvec_rd_id_w;
            sram_resp_ready = matvec_resp_ready_w;
            sram_wr_valid = matvec_wr_valid_w;
            sram_wr_addr = matvec_wr_addr_w;
            sram_wr_data = matvec_wr_data_w;
        end

        ST_LOAD_Q_REQ: begin
            sram_rd_valid = !rd_req_accepted_r;
            sram_rd_addr = q_head_base_w + addr_from_u16(beat_idx_r);
            sram_resp_ready =
                (sram_resp_id == req_id_r) &&
                (rd_req_accepted_r || (sram_rd_valid && sram_rd_ready));
        end

        ST_LOAD_K_REQ: begin
            sram_rd_valid = !rd_req_accepted_r;
            sram_rd_addr = k_head_base_w + addr_from_u16(beat_idx_r);
            sram_resp_ready =
                (sram_resp_id == req_id_r) &&
                (rd_req_accepted_r || (sram_rd_valid && sram_rd_ready));
        end

        ST_LOAD_V_REQ: begin
            sram_rd_valid = !rd_req_accepted_r;
            sram_rd_addr = v_head_base_w + addr_from_u16(beat_idx_r);
            sram_resp_ready =
                (sram_resp_id == req_id_r) &&
                (rd_req_accepted_r || (sram_rd_valid && sram_rd_ready));
        end

        ST_DOT_REQ: begin
            sram_rd_valid = !rd_req_accepted_r;
            sram_rd_addr = kv_hist_k_base_w + addr_from_u16(beat_idx_r);
            sram_resp_ready =
                (sram_resp_id == req_id_r) &&
                (rd_req_accepted_r || (sram_rd_valid && sram_rd_ready));
        end

        ST_WV_REQ: begin
            sram_rd_valid = !rd_req_accepted_r;
            sram_rd_addr = kv_hist_v_base_w + addr_from_u16(beat_idx_r);
            sram_resp_ready =
                (sram_resp_id == req_id_r) &&
                (rd_req_accepted_r || (sram_rd_valid && sram_rd_ready));
        end

        ST_LOAD_Q_RESP,
        ST_LOAD_Q_DRAIN,
        ST_LOAD_K_RESP,
        ST_LOAD_K_DRAIN,
        ST_LOAD_V_RESP,
        ST_LOAD_V_DRAIN,
        ST_DOT_RESP,
        ST_DOT_DRAIN,
        ST_WV_RESP,
        ST_WV_DRAIN: begin
            sram_resp_ready = (sram_resp_id == req_id_r);
        end

        ST_ROPE_Q_START,
        ST_ROPE_Q_WAIT,
        ST_ROPE_K_START,
        ST_ROPE_K_WAIT: begin
            sram_resp_ready = (sram_resp_id == req_id_r);
        end

        ST_CACHE_K_WRITE: begin
            sram_resp_ready = (sram_resp_id == req_id_r);
            sram_wr_valid = 1'b1;
            sram_wr_addr = kv_k_head_base_w + addr_from_u16(beat_idx_r);
            sram_wr_data = rotated_k_head_r[(beat_idx_r * DATA_BUS_W) +: DATA_BUS_W];
        end

        ST_CACHE_V_WRITE: begin
            sram_resp_ready = (sram_resp_id == req_id_r);
            if (!tree_kv_write_done_r) begin
                sram_wr_valid = 1'b1;
                sram_wr_addr = kv_v_head_base_w + addr_from_u16(beat_idx_r);
                sram_wr_data = v_head_vector_r[(beat_idx_r * DATA_BUS_W) +: DATA_BUS_W];
            end
        end

            ST_ATTN_WRITE: begin
                sram_wr_valid = 1'b1;
                sram_wr_addr = attn_head_base_w + addr_from_u16(beat_idx_r);
                sram_wr_data = attn_out_r[(beat_idx_r * DATA_BUS_W) +: DATA_BUS_W];
                sram_resp_ready = (sram_resp_id == req_id_r);
            end

        default: begin
        end
    endcase
end

always_ff @(posedge clk or negedge rst_n) begin
    integer elem_idx_i;
    if (!rst_n) begin
        state_r <= ST_IDLE;
        input_addr_r <= {ADDR_W{1'b0}};
        wq_addr_r <= {ADDR_W{1'b0}};
        wk_addr_r <= {ADDR_W{1'b0}};
        wv_addr_r <= {ADDR_W{1'b0}};
        wo_addr_r <= {ADDR_W{1'b0}};
        kv_cache_addr_r <= {ADDR_W{1'b0}};
        result_addr_r <= {ADDR_W{1'b0}};
        scratch_base_addr_r <= {ADDR_W{1'b0}};
        position_r <= 16'd0;
        layer_id_r <= 5'd0;
        req_id_r <= {REQ_ID_W{1'b0}};
        head_idx_r <= 16'd0;
        beat_idx_r <= 16'd0;
        pos_idx_r <= 16'd0;
        effective_position_r <= 16'd0;
        tree_mask_en_r <= 1'b0;
        branch_id_r <= {`BRANCH_ID_W{1'b0}};
        prefix_len_r <= 16'd0;
        visible_mask_r <= {MAX_ATTN_TOKENS{1'b0}};
        tree_batch_en_r <= 1'b0;
        tree_draft_kv_base_r <= {ADDR_W{1'b0}};
        tree_query_slot_r <= {SLOT_ID_W{1'b0}};
        tree_slot_count_r <= 5'd0;
        tree_visible_slots_r <= {WINDOW_SIZE{1'b0}};
        tree_slot_is_seed_r <= {WINDOW_SIZE{1'b0}};
        tree_seed_kv_valid_r <= 1'b0;
        tree_kv_write_done_r <= 1'b0;
        rd_req_accepted_r <= 1'b0;
        dot_acc_r <= FP16_ZERO;
        score_value_r <= FP16_ZERO;
        score_max_r <= FP16_NEG_INF;
        exp_sum_r <= FP16_ZERO;
        inv_sum_r <= FP16_ZERO;
        exp_enable_r <= 1'b0;
        recip_enable_r <= 1'b0;
        exp_input_r <= FP16_ZERO;
        recip_input_r <= FP16_ZERO;
        q_head_vector_r <= {(HEAD_DIM*DATA_WIDTH){1'b0}};
        k_head_vector_r <= {(HEAD_DIM*DATA_WIDTH){1'b0}};
        v_head_vector_r <= {(HEAD_DIM*DATA_WIDTH){1'b0}};
        rotated_q_head_r <= {(HEAD_DIM*DATA_WIDTH){1'b0}};
        rotated_k_head_r <= {(HEAD_DIM*DATA_WIDTH){1'b0}};
        attn_out_r <= {(HEAD_DIM*DATA_WIDTH){1'b0}};
    end else begin
        case (state_r)
            ST_IDLE: begin
                exp_enable_r <= 1'b0;
                recip_enable_r <= 1'b0;
                if (issue_valid) begin
                    input_addr_r <= issue_input_addr;
                    wq_addr_r <= issue_wq_addr;
                    wk_addr_r <= issue_wk_addr;
                    wv_addr_r <= issue_wv_addr;
                    wo_addr_r <= issue_wo_addr;
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
                    tree_kv_write_done_r <= 1'b0;
                    rd_req_accepted_r <= 1'b0;
                    head_idx_r <= 16'd0;
                    beat_idx_r <= 16'd0;
                    pos_idx_r <= 16'd0;
                    effective_position_r <=
                        issue_tree_batch_en ?
                            ((issue_prefix_len + issue_tree_slot_count > MAX_ATTN_POS_W) ?
                                MAX_ATTN_POS_W :
                                (issue_prefix_len + issue_tree_slot_count - 16'd1)) :
                            ((issue_position > MAX_ATTN_POS_W) ?
                                MAX_ATTN_POS_W :
                                issue_position);
                    dot_acc_r <= FP16_ZERO;
                    score_max_r <= FP16_NEG_INF;
                    exp_sum_r <= FP16_ZERO;
                    inv_sum_r <= FP16_ZERO;
                    state_r <= ST_Q_ISSUE;
                end
            end

            ST_Q_ISSUE: begin
                if (matvec_issue_valid_w && matvec_issue_ready_w)
                    state_r <= ST_Q_WAIT;
            end

            ST_Q_WAIT: begin
                if (matvec_result_valid_w && matvec_result_ready_w)
                    state_r <= ST_K_ISSUE;
            end

            ST_K_ISSUE: begin
                if (matvec_issue_valid_w && matvec_issue_ready_w)
                    state_r <= ST_K_WAIT;
            end

            ST_K_WAIT: begin
                if (matvec_result_valid_w && matvec_result_ready_w)
                    state_r <= ST_V_ISSUE;
            end

            ST_V_ISSUE: begin
                if (matvec_issue_valid_w && matvec_issue_ready_w)
                    state_r <= ST_V_WAIT;
            end

            ST_V_WAIT: begin
                if (matvec_result_valid_w && matvec_result_ready_w) begin
                    rd_req_accepted_r <= 1'b0;
                    head_idx_r <= 16'd0;
                    beat_idx_r <= 16'd0;
                    state_r <= ST_LOAD_Q_REQ;
                end
            end

            ST_LOAD_Q_REQ: begin
                if ((rd_req_accepted_r || (sram_rd_valid && sram_rd_ready)) &&
                    sram_resp_valid && sram_resp_ready) begin
                    q_head_vector_r[(beat_idx_r * DATA_BUS_W) +: DATA_BUS_W] <= sram_resp_data;
                    rd_req_accepted_r <= 1'b0;
                    if (beat_idx_r == (HEAD_BEATS - 1)) begin
                        beat_idx_r <= 16'd0;
                        state_r <= ST_LOAD_Q_DRAIN;
                    end else begin
                        beat_idx_r <= beat_idx_r + 16'd1;
                        state_r <= ST_LOAD_Q_DRAIN;
                    end
                end else if (sram_rd_valid && sram_rd_ready) begin
                    rd_req_accepted_r <= 1'b1;
                    state_r <= ST_LOAD_Q_RESP;
                end
            end

            ST_LOAD_Q_RESP: begin
                if (sram_resp_valid && sram_resp_ready) begin
                    q_head_vector_r[(beat_idx_r * DATA_BUS_W) +: DATA_BUS_W] <= sram_resp_data;
                    rd_req_accepted_r <= 1'b0;
                    if (beat_idx_r == (HEAD_BEATS - 1)) begin
                        beat_idx_r <= 16'd0;
                        state_r <= ST_LOAD_Q_DRAIN;
                    end else begin
                        beat_idx_r <= beat_idx_r + 16'd1;
                        state_r <= ST_LOAD_Q_DRAIN;
                    end
                end
            end

            ST_LOAD_Q_DRAIN: begin
                if (!(sram_resp_valid && sram_resp_ready)) begin
                    if (beat_idx_r == 16'd0)
                        state_r <= ST_ROPE_Q_START;
                    else
                        state_r <= ST_LOAD_Q_REQ;
                end
            end

            ST_ROPE_Q_START: begin
                if (rope_start_ready_w)
                    state_r <= ST_ROPE_Q_WAIT;
            end

            ST_ROPE_Q_WAIT: begin
                if (rope_rotated_valid_w) begin
                    rotated_q_head_r <= rope_rotated_vector_w;
                    rd_req_accepted_r <= 1'b0;
                    beat_idx_r <= 16'd0;
                    state_r <= ST_LOAD_K_REQ;
                end
            end

            ST_LOAD_K_REQ: begin
                if ((rd_req_accepted_r || (sram_rd_valid && sram_rd_ready)) &&
                    sram_resp_valid && sram_resp_ready) begin
                    k_head_vector_r[(beat_idx_r * DATA_BUS_W) +: DATA_BUS_W] <= sram_resp_data;
                    rd_req_accepted_r <= 1'b0;
                    if (beat_idx_r == (HEAD_BEATS - 1)) begin
                        beat_idx_r <= 16'd0;
                        state_r <= ST_LOAD_K_DRAIN;
                    end else begin
                        beat_idx_r <= beat_idx_r + 16'd1;
                        state_r <= ST_LOAD_K_DRAIN;
                    end
                end else if (sram_rd_valid && sram_rd_ready) begin
                    rd_req_accepted_r <= 1'b1;
                    state_r <= ST_LOAD_K_RESP;
                end
            end

            ST_LOAD_K_RESP: begin
                if (sram_resp_valid && sram_resp_ready) begin
                    k_head_vector_r[(beat_idx_r * DATA_BUS_W) +: DATA_BUS_W] <= sram_resp_data;
                    rd_req_accepted_r <= 1'b0;
                    if (beat_idx_r == (HEAD_BEATS - 1)) begin
                        beat_idx_r <= 16'd0;
                        state_r <= ST_LOAD_K_DRAIN;
                    end else begin
                        beat_idx_r <= beat_idx_r + 16'd1;
                        state_r <= ST_LOAD_K_DRAIN;
                    end
                end
            end

            ST_LOAD_K_DRAIN: begin
                if (!(sram_resp_valid && sram_resp_ready)) begin
                    if (beat_idx_r == 16'd0)
                        state_r <= ST_ROPE_K_START;
                    else
                        state_r <= ST_LOAD_K_REQ;
                end
            end

            ST_ROPE_K_START: begin
                if (rope_start_ready_w)
                    state_r <= ST_ROPE_K_WAIT;
            end

            ST_ROPE_K_WAIT: begin
                if (rope_rotated_valid_w) begin
                    rotated_k_head_r <= rope_rotated_vector_w;
                    rd_req_accepted_r <= 1'b0;
                    beat_idx_r <= 16'd0;
                    if (tree_batch_en_r && !tree_query_needs_kv_w)
                        state_r <= ST_LOAD_V_REQ;
                    else
                        state_r <= ST_CACHE_K_WRITE;
                end
            end

            ST_CACHE_K_WRITE: begin
                if (sram_wr_valid && sram_wr_ready) begin
                    // synthesis translate_on
                    if (beat_idx_r == (HEAD_BEATS - 1)) begin
                        rd_req_accepted_r <= 1'b0;
                        beat_idx_r <= 16'd0;
                        state_r <= ST_LOAD_V_REQ;
                    end else begin
                        beat_idx_r <= beat_idx_r + 16'd1;
                    end
                end
            end

            ST_LOAD_V_REQ: begin
                if ((rd_req_accepted_r || (sram_rd_valid && sram_rd_ready)) &&
                    sram_resp_valid && sram_resp_ready) begin
                    v_head_vector_r[(beat_idx_r * DATA_BUS_W) +: DATA_BUS_W] <= sram_resp_data;
                    rd_req_accepted_r <= 1'b0;
                    if (beat_idx_r == (HEAD_BEATS - 1)) begin
                        beat_idx_r <= 16'd0;
                        state_r <= ST_LOAD_V_DRAIN;
                    end else begin
                        beat_idx_r <= beat_idx_r + 16'd1;
                        state_r <= ST_LOAD_V_DRAIN;
                    end
                end else if (sram_rd_valid && sram_rd_ready) begin
                    rd_req_accepted_r <= 1'b1;
                    state_r <= ST_LOAD_V_RESP;
                end
            end

            ST_LOAD_V_RESP: begin
                if (sram_resp_valid && sram_resp_ready) begin
                    v_head_vector_r[(beat_idx_r * DATA_BUS_W) +: DATA_BUS_W] <= sram_resp_data;
                    rd_req_accepted_r <= 1'b0;
                    if (beat_idx_r == (HEAD_BEATS - 1)) begin
                        beat_idx_r <= 16'd0;
                        state_r <= ST_LOAD_V_DRAIN;
                    end else begin
                        beat_idx_r <= beat_idx_r + 16'd1;
                        state_r <= ST_LOAD_V_DRAIN;
                    end
                end
            end

            ST_LOAD_V_DRAIN: begin
                if (!(sram_resp_valid && sram_resp_ready)) begin
                    if (beat_idx_r == 16'd0)
                        state_r <= ST_CACHE_V_WRITE;
                    else
                        state_r <= ST_LOAD_V_REQ;
                end
            end

            ST_CACHE_V_WRITE: begin
                if (tree_batch_en_r && !tree_query_needs_kv_w && !tree_kv_write_done_r) begin
                    tree_kv_write_done_r <= 1'b1;
                end else if (!tree_kv_write_done_r) begin
                    if (sram_wr_valid && sram_wr_ready) begin
                        if (beat_idx_r == (HEAD_BEATS - 1)) begin
                            beat_idx_r <= 16'd0;
                            if (tree_batch_en_r) begin
                                tree_kv_write_done_r <= 1'b1;
                            end else begin
                                rd_req_accepted_r <= 1'b0;
                                pos_idx_r <= 16'd0;
                                dot_acc_r <= FP16_ZERO;
                                score_max_r <= FP16_NEG_INF;
                                state_r <= ST_DOT_REQ;
                            end
                        end else begin
                            beat_idx_r <= beat_idx_r + 16'd1;
                        end
                    end
                end else if (!tree_batch_en_r || issue_tree_kv_barrier_release) begin
                    tree_kv_write_done_r <= 1'b0;
                    rd_req_accepted_r <= 1'b0;
                    pos_idx_r <= 16'd0;
                    dot_acc_r <= FP16_ZERO;
                    score_max_r <= FP16_NEG_INF;
                    state_r <= ST_DOT_REQ;
                end
            end

            ST_DOT_REQ: begin
                tree_kv_write_done_r <= 1'b0;
                if (tree_batch_en_r && !tree_dot_needs_read_w) begin
                    rd_req_accepted_r <= 1'b0;
                    dot_acc_r <= FP16_ZERO;
                    score_value_r <= FP16_NEG_INF;
                    state_r <= ST_DOT_NEXT;
                end else if ((rd_req_accepted_r || (sram_rd_valid && sram_rd_ready)) &&
                             sram_resp_valid && sram_resp_ready) begin
                    rd_req_accepted_r <= 1'b0;
                    if (beat_idx_r == (HEAD_BEATS - 1)) begin
                        dot_acc_r <= FP16_ZERO;
                        beat_idx_r <= 16'd0;
                        score_value_r <= dot_scaled_w;
                        state_r <= ST_DOT_DRAIN;
                    end else begin
                        dot_acc_r <= dot_acc_next_w;
                        beat_idx_r <= beat_idx_r + 16'd1;
                        state_r <= ST_DOT_DRAIN;
                    end
                end else if (sram_rd_valid && sram_rd_ready) begin
                    rd_req_accepted_r <= 1'b1;
                    state_r <= ST_DOT_RESP;
                end
            end

            ST_DOT_RESP: begin
                if (sram_resp_valid && sram_resp_ready) begin
                    // synthesis translate_on
                    rd_req_accepted_r <= 1'b0;
                    if (beat_idx_r == (HEAD_BEATS - 1)) begin
                        dot_acc_r <= FP16_ZERO;
                        beat_idx_r <= 16'd0;
                        score_value_r <= dot_scaled_w;
                        state_r <= ST_DOT_DRAIN;
                    end else begin
                        dot_acc_r <= dot_acc_next_w;
                        beat_idx_r <= beat_idx_r + 16'd1;
                        state_r <= ST_DOT_DRAIN;
                    end
                end
            end

            ST_DOT_DRAIN: begin
                if (!(sram_resp_valid && sram_resp_ready)) begin
                    if (beat_idx_r == 16'd0)
                        state_r <= ST_DOT_NEXT;
                    else
                        state_r <= ST_DOT_REQ;
                end
            end

            ST_DOT_NEXT: begin
                if (tree_batch_en_r && tree_softmax_skip_w) begin
                    score_mem_r[pos_idx_r] <= FP16_NEG_INF;
                end else if (tree_mask_en_r && !pos_visible_w) begin
                    score_mem_r[pos_idx_r] <= FP16_NEG_INF;
                end else begin
                    score_mem_r[pos_idx_r] <= score_value_r;
                    if (fp16_gt(score_value_r, score_max_r))
                        score_max_r <= score_value_r;
                end

                // synthesis translate_off
                // synthesis translate_on

                if (pos_idx_r == effective_position_r) begin
                    pos_idx_r <= 16'd0;
                    exp_sum_r <= FP16_ZERO;
                    exp_enable_r <= 1'b0;
                    state_r <= ST_SOFT_EXP_PREP;
                end else begin
                    pos_idx_r <= pos_idx_r + 16'd1;
                    beat_idx_r <= 16'd0;
                    dot_acc_r <= FP16_ZERO;
                    state_r <= ST_DOT_REQ;
                end
            end

            ST_SOFT_EXP_PREP: begin
                exp_enable_r <= 1'b0;
                exp_input_r <= exp_delta_w;
                state_r <= ST_SOFT_EXP_WAIT;
            end

            ST_SOFT_EXP_WAIT: begin
                exp_enable_r <= 1'b1;
                if (exp_ack_w) begin
                    exp_enable_r <= 1'b0;
                    if (softmax_pos_active_w) begin
                        weight_mem_r[pos_idx_r] <= exp_out_w;
                        exp_sum_r <= exp_sum_next_w;
                    end else begin
                        weight_mem_r[pos_idx_r] <= FP16_ZERO;
                        exp_sum_r <= exp_sum_r;
                    end
                    if (pos_idx_r == effective_position_r) begin
                        pos_idx_r <= 16'd0;
                        if (softmax_pos_active_w)
                            recip_input_r <= exp_sum_next_w;
                        else
                            recip_input_r <= exp_sum_r;
                        recip_enable_r <= 1'b0;
                        state_r <= ST_SOFT_RECIP_PREP;
                    end else begin
                        pos_idx_r <= pos_idx_r + 16'd1;
                        state_r <= ST_SOFT_EXP_PREP;
                    end
                end
            end

            ST_SOFT_RECIP_PREP: begin
                recip_enable_r <= 1'b0;
                state_r <= ST_SOFT_RECIP_WAIT;
            end

            ST_SOFT_RECIP_WAIT: begin
                recip_enable_r <= 1'b1;
                if (recip_ack_w) begin
                    recip_enable_r <= 1'b0;
                    inv_sum_r <= recip_out_w;
                    rd_req_accepted_r <= 1'b0;
                    pos_idx_r <= 16'd0;
                    beat_idx_r <= 16'd0;
                    attn_out_r <= {(HEAD_DIM*DATA_WIDTH){1'b0}};
                    state_r <= ST_WV_REQ;
                end
            end

            ST_WV_REQ: begin
                if (tree_batch_en_r && !tree_wv_needs_read_w) begin
                    rd_req_accepted_r <= 1'b0;
                    for (elem_idx_i = 0; elem_idx_i < ELEMS_PER_BEAT; elem_idx_i = elem_idx_i + 1) begin
                        attn_out_r[((beat_idx_r * ELEMS_PER_BEAT + elem_idx_i) * DATA_WIDTH) +: DATA_WIDTH] <=
                            attn_prev_elem_w[elem_idx_i];
                    end
                    if (beat_idx_r == (HEAD_BEATS - 1))
                        state_r <= ST_WV_NEXT;
                    else begin
                        beat_idx_r <= beat_idx_r + 16'd1;
                        state_r <= ST_WV_REQ;
                    end
                end else if ((rd_req_accepted_r || (sram_rd_valid && sram_rd_ready)) &&
                             sram_resp_valid && sram_resp_ready) begin
                    rd_req_accepted_r <= 1'b0;
                    for (elem_idx_i = 0; elem_idx_i < ELEMS_PER_BEAT; elem_idx_i = elem_idx_i + 1) begin
                        attn_out_r[((beat_idx_r * ELEMS_PER_BEAT + elem_idx_i) * DATA_WIDTH) +: DATA_WIDTH] <=
                            attn_accum_next_w[elem_idx_i];
                    end
                    if (beat_idx_r == (HEAD_BEATS - 1)) begin
                        beat_idx_r <= 16'd0;
                        state_r <= ST_WV_DRAIN;
                    end else begin
                        beat_idx_r <= beat_idx_r + 16'd1;
                        state_r <= ST_WV_DRAIN;
                    end
                end else if (sram_rd_valid && sram_rd_ready) begin
                    rd_req_accepted_r <= 1'b1;
                    state_r <= ST_WV_RESP;
                end
            end

            ST_WV_RESP: begin
                if (sram_resp_valid && sram_resp_ready) begin
                    rd_req_accepted_r <= 1'b0;
                    for (elem_idx_i = 0; elem_idx_i < ELEMS_PER_BEAT; elem_idx_i = elem_idx_i + 1) begin
                        attn_out_r[((beat_idx_r * ELEMS_PER_BEAT + elem_idx_i) * DATA_WIDTH) +: DATA_WIDTH] <=
                            attn_accum_next_w[elem_idx_i];
                    end
                    if (beat_idx_r == (HEAD_BEATS - 1)) begin
                        beat_idx_r <= 16'd0;
                        state_r <= ST_WV_DRAIN;
                    end else begin
                        beat_idx_r <= beat_idx_r + 16'd1;
                        state_r <= ST_WV_DRAIN;
                    end
                end
            end

            ST_WV_DRAIN: begin
                if (!(sram_resp_valid && sram_resp_ready)) begin
                    if (beat_idx_r == 16'd0)
                        state_r <= ST_WV_NEXT;
                    else
                        state_r <= ST_WV_REQ;
                end
            end

            ST_WV_NEXT: begin
                if (pos_idx_r == effective_position_r) begin
                    beat_idx_r <= 16'd0;
                    state_r <= ST_ATTN_WRITE;
                end else begin
                    pos_idx_r <= pos_idx_r + 16'd1;
                    beat_idx_r <= 16'd0;
                    state_r <= ST_WV_REQ;
                end
            end

            ST_ATTN_WRITE: begin
                if (sram_wr_valid && sram_wr_ready) begin
                    if (beat_idx_r == (HEAD_BEATS - 1)) begin
                        if (head_idx_r == (NUM_HEADS - 1)) begin
                            state_r <= ST_O_ISSUE;
                        end else begin
                            rd_req_accepted_r <= 1'b0;
                            head_idx_r <= head_idx_r + 16'd1;
                            beat_idx_r <= 16'd0;
                            pos_idx_r <= 16'd0;
                            state_r <= ST_LOAD_Q_REQ;
                        end
                    end else begin
                        beat_idx_r <= beat_idx_r + 16'd1;
                    end
                end
            end

            ST_O_ISSUE: begin
                if (matvec_issue_valid_w && matvec_issue_ready_w)
                    state_r <= ST_O_WAIT;
            end

            ST_O_WAIT: begin
                if (matvec_result_valid_w && matvec_result_ready_w) begin
                    state_r <= ST_IDLE;
                end
            end

            default: begin
                state_r <= ST_IDLE;
            end
        endcase
    end
end

endmodule
`endif
