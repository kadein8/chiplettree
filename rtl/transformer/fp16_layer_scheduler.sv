`include "config/interface_params.vh"
`include "config/memory_params.vh"
`include "config/model_params.vh"
`timescale 1ns/1ps

module fp16_layer_scheduler #(
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
    parameter integer MAX_ATTN_TOKENS = `TOY_MAX_POS_EMB,
    parameter integer TILE_LANES = `FP16_TILE_LANES,
    parameter integer TILE_COLS = `FP16_TILE_COLS,
    parameter integer ELEMS_PER_SRAM_BEAT_P = DATA_BUS_W / DATA_WIDTH,
    parameter integer WEIGHT_BEATS_PER_TILE_P = (TILE_LANES * TILE_COLS) / ELEMS_PER_SRAM_BEAT_P,
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
            ((PROJ_MATRIX_BEATS_P > FFN_DOWN_MATRIX_BEATS_P) ? PROJ_MATRIX_BEATS_P : FFN_DOWN_MATRIX_BEATS_P) :
            ((FFN_EXPAND_MATRIX_BEATS_P > FFN_DOWN_MATRIX_BEATS_P) ? FFN_EXPAND_MATRIX_BEATS_P : FFN_DOWN_MATRIX_BEATS_P),
    parameter integer WEIGHT_WINDOW_BEATS = REQUIRED_WEIGHT_SLOT_BEATS_P * 8,
    parameter integer LAYER_WEIGHT_STRIDE =
        (((2 * (HIDDEN_DIM / ELEMS_PER_SRAM_BEAT_P)) + WEIGHT_WINDOW_BEATS) / (HBM_DATA_W / DATA_BUS_W))
) (
    input  logic                  clk,
    input  logic                  rst_n,
    input  logic                  issue_valid,
    output logic                  issue_ready,
    input  logic [31:0]           issue_token_position,
    input  logic [ADDR_W-1:0]     issue_input_addr,
    input  logic [ADDR_W-1:0]     issue_result_addr,
    input  logic [ADDR_W-1:0]     issue_weight_sram_base,
    input  logic [ADDR_W-1:0]     issue_kv_cache_base,
    input  logic [HBM_ADDR_W-1:0] issue_hbm_weight_base,
    input  logic [REQ_ID_W-1:0]   issue_req_id,
    input  logic                  issue_tree_mask_en,
    input  logic [`BRANCH_ID_W-1:0] issue_branch_id,
    input  logic [15:0]           issue_prefix_len,
    input  logic [MAX_ATTN_TOKENS-1:0] issue_visible_mask,

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

    output logic                  result_valid,
    input  logic                  result_ready,
    output logic [ADDR_W-1:0]     result_addr,
    output logic [4:0]            current_layer_debug
);

localparam integer ELEMS_PER_HBM_BEAT = HBM_DATA_W / DATA_WIDTH;
localparam integer ELEMS_PER_SRAM_BEAT = DATA_BUS_W / DATA_WIDTH;
localparam integer HBM_TO_SRAM_RATIO = HBM_DATA_W / DATA_BUS_W;
localparam integer HIDDEN_BEATS = HIDDEN_DIM / ELEMS_PER_SRAM_BEAT;
localparam integer INTERMEDIATE_BEATS = INTERMEDIATE_DIM / ELEMS_PER_SRAM_BEAT;
localparam integer WEIGHT_BEATS_PER_TILE = (TILE_LANES * TILE_COLS) / ELEMS_PER_SRAM_BEAT;
localparam integer TOTAL_LAYER_PRELOAD_BEATS = (2 * HIDDEN_BEATS) + WEIGHT_WINDOW_BEATS;
localparam logic [3:0]
    ST_IDLE        = 4'd0,
    ST_HBM_REQ     = 4'd1,
    ST_HBM_RESP    = 4'd2,
    ST_HBM_WRITE0  = 4'd3,
    ST_HBM_WRITE1  = 4'd4,
    ST_LAYER_ISSUE = 4'd5,
    ST_LAYER_WAIT  = 4'd6,
    ST_HOLD        = 4'd7;

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


logic [3:0] state_r;
logic [31:0] token_position_r;
logic [ADDR_W-1:0] input_addr_r;
logic [ADDR_W-1:0] result_addr_r;
logic [ADDR_W-1:0] weight_sram_base_r;
logic [ADDR_W-1:0] kv_cache_base_r;
logic [HBM_ADDR_W-1:0] hbm_weight_base_r;
logic [REQ_ID_W-1:0] req_id_r;
logic tree_mask_en_r;
logic [`BRANCH_ID_W-1:0] branch_id_r;
logic [15:0] prefix_len_r;
logic [MAX_ATTN_TOKENS-1:0] visible_mask_r;
logic [5:0] layer_idx_r;
logic [15:0] preload_idx_r;
logic [HBM_DATA_W-1:0] hbm_beat_r;
logic [DATA_BUS_W-1:0] result_data_hold_r;

logic layer_issue_ready_w;
logic layer_rd_valid_w;
logic [ADDR_W-1:0] layer_rd_addr_w;
logic [REQ_ID_W-1:0] layer_rd_id_w;
logic layer_resp_ready_w;
logic layer_wr_valid_w;
logic [ADDR_W-1:0] layer_wr_addr_w;
logic [DATA_BUS_W-1:0] layer_wr_data_w;
logic layer_result_valid_w;
logic layer_result_ready_w;
logic [ADDR_W-1:0] layer_result_addr_w;
logic [DATA_BUS_W-1:0] layer_result_data_w;
logic [1:0] layer_result_status_w;

wire [ADDR_W-1:0] layer_weight_base_w = weight_sram_base_r;
wire [ADDR_W-1:0] layer_kv_base_w = kv_cache_base_r + addr_from_u32(layer_idx_r * 4096);
wire [ADDR_W-1:0] active_input_addr_w = (layer_idx_r[0] == 1'b0) ? input_addr_r : result_addr_r;
wire [ADDR_W-1:0] active_output_addr_w = (layer_idx_r == (N_LAYERS - 1)) ? result_addr_r : ((layer_idx_r[0] == 1'b0) ? result_addr_r : input_addr_r);
wire [ADDR_W-1:0] scratch_base_w = weight_sram_base_r + addr_from_u32(TOTAL_LAYER_PRELOAD_BEATS + (layer_idx_r * ((HIDDEN_BEATS * 8) + (INTERMEDIATE_BEATS * 3))));

fp16_transformer_layer #(
    .ADDR_W(ADDR_W),
    .DATA_WIDTH(DATA_WIDTH),
    .DATA_BUS_W(DATA_BUS_W),
    .REQ_ID_W(REQ_ID_W),
    .RESULT_STATUS_W(2),
    .HIDDEN_DIM(HIDDEN_DIM),
    .INTERMEDIATE_DIM(INTERMEDIATE_DIM),
    .NUM_HEADS(NUM_HEADS),
    .HEAD_DIM(HEAD_DIM),
    .MAX_ATTN_TOKENS(MAX_ATTN_TOKENS),
    .RESULT_STATUS_OK(2'b00)
) u_fp16_transformer_layer (
    .clk(clk),
    .rst_n(rst_n),
    .issue_valid(state_r == ST_LAYER_ISSUE),
    .issue_ready(layer_issue_ready_w),
    .issue_input_addr(active_input_addr_w),
    .issue_pre_norm_gamma_addr(layer_weight_base_w),
    .issue_post_norm_gamma_addr(layer_weight_base_w + addr_from_u32(HIDDEN_BEATS)),
    .issue_wq_addr(layer_weight_base_w + addr_from_u32(HIDDEN_BEATS * 2)),
    .issue_wk_addr(layer_weight_base_w + addr_from_u32(HIDDEN_BEATS * 2 + WEIGHT_WINDOW_BEATS / 8)),
    .issue_wv_addr(layer_weight_base_w + addr_from_u32(HIDDEN_BEATS * 2 + WEIGHT_WINDOW_BEATS / 4)),
    .issue_wo_addr(layer_weight_base_w + addr_from_u32(HIDDEN_BEATS * 2 + (WEIGHT_WINDOW_BEATS * 3 / 8))),
    .issue_gate_w_addr(layer_weight_base_w + addr_from_u32(HIDDEN_BEATS * 2 + (WEIGHT_WINDOW_BEATS / 2))),
    .issue_up_w_addr(layer_weight_base_w + addr_from_u32(HIDDEN_BEATS * 2 + (WEIGHT_WINDOW_BEATS * 5 / 8))),
    .issue_down_w_addr(layer_weight_base_w + addr_from_u32(HIDDEN_BEATS * 2 + (WEIGHT_WINDOW_BEATS * 3 / 4))),
    .issue_kv_cache_addr(layer_kv_base_w),
    .issue_result_addr(active_output_addr_w),
    .issue_scratch_base_addr(scratch_base_w),
    .issue_position(token_position_r[15:0]),
    .issue_layer_id(layer_idx_r[4:0]),
    .issue_req_id(req_id_r),
    .issue_tree_mask_en(tree_mask_en_r),
    .issue_branch_id(branch_id_r),
    .issue_prefix_len(prefix_len_r),
    .issue_visible_mask(visible_mask_r),
    .issue_tree_batch_en(1'b0),
    .issue_tree_draft_kv_base({ADDR_W{1'b0}}),
    .issue_tree_query_slot({`SLOT_ID_W{1'b0}}),
    .issue_tree_slot_count(5'd0),
    .issue_tree_visible_slots({`VERIFY_WINDOW_SIZE{1'b0}}),
    .issue_tree_slot_is_seed({`VERIFY_WINDOW_SIZE{1'b0}}),
    .issue_tree_seed_kv_valid(1'b0),
    .sram_rd_valid(layer_rd_valid_w),
    .sram_rd_ready(sram_rd_ready),
    .sram_rd_addr(layer_rd_addr_w),
    .sram_rd_id(layer_rd_id_w),
    .sram_resp_valid(sram_resp_valid),
    .sram_resp_ready(layer_resp_ready_w),
    .sram_resp_data(sram_resp_data),
    .sram_resp_id(sram_resp_id),
    .sram_wr_valid(layer_wr_valid_w),
    .sram_wr_ready(sram_wr_ready),
    .sram_wr_addr(layer_wr_addr_w),
    .sram_wr_data(layer_wr_data_w),
    .result_valid(layer_result_valid_w),
    .result_ready(layer_result_ready_w),
    .result_addr(layer_result_addr_w),
    .result_data(layer_result_data_w),
    .result_status(layer_result_status_w)
);

assign issue_ready = (state_r == ST_IDLE);
assign hbm_rd_valid = (state_r == ST_HBM_REQ);
assign hbm_rd_addr = hbm_weight_base_r + (layer_idx_r * LAYER_WEIGHT_STRIDE) + preload_idx_r;
assign hbm_resp_ready = (state_r == ST_HBM_RESP);
assign result_valid = (state_r == ST_HOLD);
assign result_addr = result_addr_r;
assign current_layer_debug = layer_idx_r[4:0];
assign layer_result_ready_w = (state_r == ST_LAYER_WAIT);

always_comb begin
    sram_rd_valid = 1'b0;
    sram_rd_addr = {ADDR_W{1'b0}};
    sram_rd_id = {REQ_ID_W{1'b0}};
    sram_resp_ready = 1'b0;
    sram_wr_valid = 1'b0;
    sram_wr_addr = {ADDR_W{1'b0}};
    sram_wr_data = {DATA_BUS_W{1'b0}};

    case (state_r)
        ST_HBM_WRITE0: begin
            sram_wr_valid = 1'b1;
            sram_wr_addr = weight_sram_base_r + addr_from_u16(preload_idx_r * HBM_TO_SRAM_RATIO);
            sram_wr_data = hbm_beat_r[0 +: DATA_BUS_W];
        end

        ST_HBM_WRITE1: begin
            sram_wr_valid = 1'b1;
            sram_wr_addr = weight_sram_base_r + addr_from_u16(preload_idx_r * HBM_TO_SRAM_RATIO + 16'd1);
            sram_wr_data = hbm_beat_r[DATA_BUS_W +: DATA_BUS_W];
        end

        ST_LAYER_ISSUE,
        ST_LAYER_WAIT: begin
            sram_rd_valid = layer_rd_valid_w;
            sram_rd_addr = layer_rd_addr_w;
            sram_rd_id = layer_rd_id_w;
            sram_resp_ready = layer_resp_ready_w;
            sram_wr_valid = layer_wr_valid_w;
            sram_wr_addr = layer_wr_addr_w;
            sram_wr_data = layer_wr_data_w;
        end

        default: begin
        end
    endcase
end

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state_r <= ST_IDLE;
        token_position_r <= 32'd0;
        input_addr_r <= {ADDR_W{1'b0}};
        result_addr_r <= {ADDR_W{1'b0}};
        weight_sram_base_r <= {ADDR_W{1'b0}};
        kv_cache_base_r <= {ADDR_W{1'b0}};
        hbm_weight_base_r <= {HBM_ADDR_W{1'b0}};
        req_id_r <= {REQ_ID_W{1'b0}};
        tree_mask_en_r <= 1'b0;
        branch_id_r <= {`BRANCH_ID_W{1'b0}};
        prefix_len_r <= 16'd0;
        visible_mask_r <= {MAX_ATTN_TOKENS{1'b0}};
        layer_idx_r <= 6'd0;
        preload_idx_r <= 16'd0;
        hbm_beat_r <= {HBM_DATA_W{1'b0}};
        result_data_hold_r <= {DATA_BUS_W{1'b0}};
    end else begin
        case (state_r)
            ST_IDLE: begin
                if (issue_valid) begin
                    token_position_r <= issue_token_position;
                    input_addr_r <= issue_input_addr;
                    result_addr_r <= issue_result_addr;
                    weight_sram_base_r <= issue_weight_sram_base;
                    kv_cache_base_r <= issue_kv_cache_base;
                    hbm_weight_base_r <= issue_hbm_weight_base;
                    req_id_r <= issue_req_id;
                    tree_mask_en_r <= issue_tree_mask_en;
                    branch_id_r <= issue_branch_id;
                    prefix_len_r <= issue_prefix_len;
                    visible_mask_r <= issue_visible_mask;
                    layer_idx_r <= 6'd0;
                    preload_idx_r <= 16'd0;
                    state_r <= ST_HBM_REQ;
                end
            end

            ST_HBM_REQ: begin
                if (hbm_rd_valid && hbm_rd_ready)
                    state_r <= ST_HBM_RESP;
            end

            ST_HBM_RESP: begin
                if (hbm_resp_valid && hbm_resp_ready) begin
                    hbm_beat_r <= hbm_resp_data;
                    state_r <= ST_HBM_WRITE0;
                end
            end

            ST_HBM_WRITE0: begin
                if (sram_wr_valid && sram_wr_ready)
                    state_r <= ST_HBM_WRITE1;
            end

            ST_HBM_WRITE1: begin
                if (sram_wr_valid && sram_wr_ready) begin
                    if (preload_idx_r == ((TOTAL_LAYER_PRELOAD_BEATS / HBM_TO_SRAM_RATIO) - 1)) begin
                        state_r <= ST_LAYER_ISSUE;
                    end else begin
                        preload_idx_r <= preload_idx_r + 16'd1;
                        state_r <= ST_HBM_REQ;
                    end
                end
            end

            ST_LAYER_ISSUE: begin
                if (layer_issue_ready_w)
                    state_r <= ST_LAYER_WAIT;
            end

            ST_LAYER_WAIT: begin
                if (layer_result_valid_w && layer_result_ready_w) begin
                    result_data_hold_r <= layer_result_data_w;
                    if (layer_idx_r == (N_LAYERS - 1)) begin
                        state_r <= ST_HOLD;
                    end else begin
                        layer_idx_r <= layer_idx_r + 6'd1;
                        preload_idx_r <= 16'd0;
                        state_r <= ST_HBM_REQ;
                    end
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
