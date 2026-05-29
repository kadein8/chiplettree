`include "config/interface_params.vh"
`include "config/memory_params.vh"
`include "config/model_params.vh"
`timescale 1ns/1ps

module fp16_inference_adapter #(
    parameter integer ADDR_W = `SRAM_ADDR_W,
    parameter integer DATA_BUS_W = `SRAM_WDATA_W,
    parameter integer REQ_ID_W = `REQ_ID_W,
    parameter integer HBM_ADDR_W = `HBM_ADDR_W,
    parameter integer HBM_DATA_W = `HBM_DATA_W,
    parameter integer TOKEN_ID_W = `TOKEN_ID_W,
    parameter integer RESULT_STATUS_W = 2,
    parameter integer HIDDEN_DIM = `TOY_DMODEL,
    parameter integer INTERMEDIATE_DIM = `TOY_INTERMEDIATE_DIM,
    parameter integer NUM_HEADS = `TOY_NUM_Q_HEADS,
    parameter integer HEAD_DIM = `TOY_HEAD_DIM,
    parameter integer N_LAYERS = `TOY_N_LAYERS,
    parameter integer VOCAB_SIZE = `TOY_VOCAB_SIZE,
    parameter integer MAX_ATTN_TOKENS = `TOY_MAX_POS_EMB,
    parameter integer TILE_LANES = `FP16_TILE_LANES,
    parameter integer TILE_COLS = `FP16_TILE_COLS,
    parameter integer DATA_WIDTH = `FP16_TILE_DATA_W,
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
    parameter [ADDR_W-1:0] FINAL_NORM_GAMMA_ADDR = 23'd2048,
    parameter integer DEFAULT_DO_SAMPLE = 0,
    parameter [6:0] DEFAULT_TOP_K = 7'd1,
    parameter [15:0] DEFAULT_TOP_P = 16'h3c00,
    parameter [RESULT_STATUS_W-1:0] RESULT_STATUS_OK = 2'b00,
    parameter [ADDR_W-1:0] WORK_HIDDEN0_BASE = 23'd4096,
    parameter [ADDR_W-1:0] WORK_HIDDEN1_BASE = 23'd6144,
    parameter [ADDR_W-1:0] WORK_FINAL_BASE = 23'd8192,
    parameter [ADDR_W-1:0] WEIGHT_SRAM_BASE = 23'd16384,
    parameter [ADDR_W-1:0] HBM_MAPPED_SRAM_BASE = 23'd131072,
    parameter [ADDR_W-1:0] KV_CACHE_SRAM_BASE = `KV_COMMITTED_BASE,
    parameter [HBM_ADDR_W-1:0] HBM_WEIGHT_BASE = 32'd1024,
    parameter [ADDR_W-1:0] LM_HEAD_WEIGHT_BASE = 23'd49664,
    parameter [REQ_ID_W-1:0] HBM_MAPPED_REQ_ID =
        {{(REQ_ID_W-1){1'b1}}, 1'b0}
) (
    input  logic                       clk,
    input  logic                       rst_n,

    input  logic                       issue_valid,
    output logic                       issue_ready,
    input  logic [TOKEN_ID_W-1:0]      issue_token_id,
    input  logic [`BRANCH_ID_W-1:0]    issue_branch_id,
    input  logic [1:0]                 issue_epoch,
    input  logic [7:0]                 issue_model_id,
    input  logic [7:0]                 issue_op_class,
    input  logic [ADDR_W-1:0]          issue_src_addr,
    input  logic [ADDR_W-1:0]          issue_dst_addr,
    input  logic [15:0]                issue_token_len,
    input  logic [REQ_ID_W-1:0]        issue_req_id,
    input  logic [1:0]                 issue_flush_epoch,
    input  logic                       issue_tree_mask_en,
    input  logic [`BRANCH_ID_W-1:0]    issue_tree_mask_branch_id,
    input  logic [15:0]                issue_prefix_len,
    input  logic [MAX_ATTN_TOKENS-1:0] issue_visible_mask,
    input  logic [15:0]                issue_position,
    input  logic                       issue_position_ovr,

    output logic                       op_req_valid,
    input  logic                       op_req_ready,
    output logic                       op_req_write,
    output logic [ADDR_W-1:0]          op_req_addr,
    output logic [DATA_BUS_W-1:0]      op_req_wdata,
    output logic [REQ_ID_W-1:0]        op_req_id,
    output logic                       op_req_last,
    output logic [TOKEN_ID_W-1:0]      op_req_tag,

    input  logic                       op_resp_valid,
    output logic                       op_resp_ready,
    input  logic [DATA_BUS_W-1:0]      op_resp_rdata,
    input  logic [REQ_ID_W-1:0]        op_resp_id,
    input  logic                       op_resp_last,

    output logic                       result_valid,
    input  logic                       result_ready,
    output logic [TOKEN_ID_W-1:0]      result_token_id,
    output logic [ADDR_W-1:0]          result_addr,
    output logic [DATA_BUS_W-1:0]      result_data,
    output logic [RESULT_STATUS_W-1:0] result_status
);

localparam logic [1:0]
    ST_IDLE   = 2'd0,
    ST_BUSY   = 2'd1,
    ST_RESULT = 2'd2;

localparam logic [2:0]
    MAP_IDLE    = 3'd0,
    MAP_SEND_LO = 3'd1,
    MAP_WAIT_LO = 3'd2,
    MAP_SEND_HI = 3'd3,
    MAP_WAIT_HI = 3'd4,
    MAP_RESP    = 3'd5;

localparam integer HBM_TO_SRAM_RATIO = HBM_DATA_W / DATA_BUS_W;

logic [1:0] state_r;
logic [2:0] map_state_r;
logic [TOKEN_ID_W-1:0] token_id_r;
logic [ADDR_W-1:0] src_addr_r;
logic [ADDR_W-1:0] dst_addr_r;
logic [REQ_ID_W-1:0] req_id_r;
logic tree_mask_en_r;
logic [`BRANCH_ID_W-1:0] tree_mask_branch_id_r;
logic [15:0] prefix_len_r;
logic [MAX_ATTN_TOKENS-1:0] visible_mask_r;
logic [15:0] position_ovr_val_r;
logic position_ovr_en_r;
logic [31:0] generated_token_r;
logic [HBM_ADDR_W-1:0] map_hbm_addr_r;
logic [DATA_BUS_W-1:0] map_low_data_r;
logic [HBM_DATA_W-1:0] map_resp_data_r;

logic fp16_token_in_ready_w;
logic fp16_token_out_valid_w;
logic fp16_token_out_ready_w;
logic [31:0] fp16_token_out_id_w;
logic fp16_hbm_rd_valid_w;
logic fp16_hbm_rd_ready_w;
logic [HBM_ADDR_W-1:0] fp16_hbm_rd_addr_w;
logic fp16_hbm_resp_valid_w;
logic fp16_hbm_resp_ready_w;
logic [HBM_DATA_W-1:0] fp16_hbm_resp_data_w;
logic fp16_sram_rd_valid_w;
logic fp16_sram_rd_ready_w;
logic [ADDR_W-1:0] fp16_sram_rd_addr_w;
logic [REQ_ID_W-1:0] fp16_sram_rd_id_w;
logic fp16_sram_resp_valid_w;
logic fp16_sram_resp_ready_w;
logic [DATA_BUS_W-1:0] fp16_sram_resp_data_w;
logic [REQ_ID_W-1:0] fp16_sram_resp_id_w;
logic fp16_sram_wr_valid_w;
logic fp16_sram_wr_ready_w;
logic [ADDR_W-1:0] fp16_sram_wr_addr_w;
logic [DATA_BUS_W-1:0] fp16_sram_wr_data_w;
logic fp16_busy_w;
logic [15:0] fp16_current_position_w;
logic [4:0] fp16_current_layer_debug_w;

wire issue_fire_w;
wire fp16_token_out_fire_w;
wire map_req_active_w;
wire direct_rd_active_w;
wire [ADDR_W-1:0] map_sram_addr_low_w;
wire [ADDR_W-1:0] map_sram_addr_high_w;
wire active_tree_mask_en_w;
wire [`BRANCH_ID_W-1:0] active_branch_id_w;
wire [15:0] active_prefix_len_w;
wire [MAX_ATTN_TOKENS-1:0] active_visible_mask_w;
wire [15:0] active_position_ovr_val_w;
wire active_position_ovr_en_w;
wire [ADDR_W-1:0] active_src_addr_w;

assign issue_fire_w = issue_valid && issue_ready;
assign fp16_token_out_fire_w = fp16_token_out_valid_w && fp16_token_out_ready_w;
assign map_req_active_w =
    (map_state_r == MAP_SEND_LO) || (map_state_r == MAP_SEND_HI);
assign direct_rd_active_w = fp16_sram_rd_valid_w && !map_req_active_w;
assign active_tree_mask_en_w =
    (state_r == ST_IDLE) ? issue_tree_mask_en : tree_mask_en_r;
assign active_branch_id_w =
    (state_r == ST_IDLE) ? issue_tree_mask_branch_id : tree_mask_branch_id_r;
assign active_prefix_len_w =
    (state_r == ST_IDLE) ? issue_prefix_len : prefix_len_r;
assign active_visible_mask_w =
    (state_r == ST_IDLE) ? issue_visible_mask : visible_mask_r;
assign active_position_ovr_val_w =
    (state_r == ST_IDLE) ? issue_position : position_ovr_val_r;
assign active_position_ovr_en_w =
    (state_r == ST_IDLE) ? issue_position_ovr : position_ovr_en_r;
assign active_src_addr_w =
    (state_r == ST_IDLE) ? issue_src_addr : src_addr_r;

assign map_sram_addr_low_w =
    HBM_MAPPED_SRAM_BASE +
    (map_hbm_addr_r - HBM_WEIGHT_BASE) * HBM_TO_SRAM_RATIO;
assign map_sram_addr_high_w = map_sram_addr_low_w + 1'b1;

assign issue_ready =
    (state_r == ST_IDLE) &&
    (map_state_r == MAP_IDLE) &&
    fp16_token_in_ready_w;
assign fp16_token_out_ready_w = (state_r == ST_BUSY);

assign op_req_valid =
    fp16_sram_wr_valid_w || map_req_active_w || direct_rd_active_w;
assign op_req_write = fp16_sram_wr_valid_w;
assign op_req_addr =
    fp16_sram_wr_valid_w ? fp16_sram_wr_addr_w :
    ((map_state_r == MAP_SEND_HI) ? map_sram_addr_high_w :
     (map_req_active_w ? map_sram_addr_low_w : fp16_sram_rd_addr_w));
assign op_req_wdata =
    fp16_sram_wr_valid_w ? fp16_sram_wr_data_w : {DATA_BUS_W{1'b0}};
assign op_req_id =
    fp16_sram_wr_valid_w ? req_id_r :
    (map_req_active_w ? HBM_MAPPED_REQ_ID : fp16_sram_rd_id_w);
assign op_req_last = 1'b1;
assign op_req_tag = token_id_r;

assign fp16_sram_wr_ready_w = op_req_ready && fp16_sram_wr_valid_w;
assign fp16_sram_rd_ready_w =
    op_req_ready &&
    !fp16_sram_wr_valid_w &&
    !map_req_active_w &&
    fp16_sram_rd_valid_w;
assign fp16_hbm_rd_ready_w = (map_state_r == MAP_IDLE);

assign fp16_sram_resp_valid_w =
    op_resp_valid && (op_resp_id != HBM_MAPPED_REQ_ID);
assign fp16_sram_resp_data_w = op_resp_rdata;
assign fp16_sram_resp_id_w = op_resp_id;
assign fp16_hbm_resp_valid_w = (map_state_r == MAP_RESP);
assign fp16_hbm_resp_data_w = map_resp_data_r;

assign op_resp_ready =
    (op_resp_id == HBM_MAPPED_REQ_ID) ?
        ((map_state_r == MAP_WAIT_LO) || (map_state_r == MAP_WAIT_HI)) :
        fp16_sram_resp_ready_w;

assign result_valid = (state_r == ST_RESULT);
assign result_token_id = token_id_r;
assign result_addr = dst_addr_r;
assign result_data = {{(DATA_BUS_W-16){1'b0}}, generated_token_r[15:0]};
assign result_status = RESULT_STATUS_OK;

fp16_inference_top #(
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
    .VOCAB_SIZE(VOCAB_SIZE),
    .MAX_ATTN_TOKENS(MAX_ATTN_TOKENS),
    .WEIGHT_WINDOW_BEATS(WEIGHT_WINDOW_BEATS),
    .LAYER_WEIGHT_STRIDE(LAYER_WEIGHT_STRIDE),
    .WORK_HIDDEN0_BASE(WORK_HIDDEN0_BASE),
    .WORK_HIDDEN1_BASE(WORK_HIDDEN1_BASE),
    .WORK_FINAL_BASE(WORK_FINAL_BASE),
    .WEIGHT_SRAM_BASE(WEIGHT_SRAM_BASE),
    .KV_CACHE_SRAM_BASE(KV_CACHE_SRAM_BASE),
    .HBM_WEIGHT_BASE(HBM_WEIGHT_BASE),
    .LM_HEAD_WEIGHT_BASE(LM_HEAD_WEIGHT_BASE)
) u_fp16_inference_top (
    .clk(clk),
    .rst_n(rst_n),
    .token_in_valid(issue_fire_w),
    .token_in_ready(fp16_token_in_ready_w),
    .token_in_id({16'd0, issue_token_id}),
    .token_in_is_bos(1'b0),
    .token_out_valid(fp16_token_out_valid_w),
    .token_out_ready(fp16_token_out_ready_w),
    .token_out_id(fp16_token_out_id_w),
    .cfg_embedding_base(active_src_addr_w),
    .cfg_final_norm_gamma_addr(FINAL_NORM_GAMMA_ADDR),
    .cfg_do_sample(DEFAULT_DO_SAMPLE[0]),
    .cfg_top_k(DEFAULT_TOP_K),
    .cfg_top_p(DEFAULT_TOP_P),
    .cfg_tree_mask_en(active_tree_mask_en_w),
    .cfg_branch_id(active_branch_id_w),
    .cfg_prefix_len(active_prefix_len_w),
    .cfg_visible_mask(active_visible_mask_w),
    .cfg_position(active_position_ovr_val_w),
    .cfg_position_ovr(active_position_ovr_en_w),
    .batch_in_valid(1'b0),
    .batch_in_ready(),
    .batch_in_count(5'd0),
    .batch_in_token_ids({(`VERIFY_WINDOW_SIZE*32){1'b0}}),
    .batch_in_positions({(`VERIFY_WINDOW_SIZE*16){1'b0}}),
    .batch_in_tree_mask({(`VERIFY_WINDOW_SIZE*`VERIFY_WINDOW_SIZE){1'b0}}),
    .batch_in_prefix_len(16'd0),
    .batch_in_seed_kv_valid(1'b0),
    .batch_in_slot_is_seed({`VERIFY_WINDOW_SIZE{1'b0}}),
    .batch_out_valid(),
    .batch_out_ready(1'b0),
    .batch_out_count(),
    .batch_out_token_ids(),
    .hbm_rd_valid(fp16_hbm_rd_valid_w),
    .hbm_rd_ready(fp16_hbm_rd_ready_w),
    .hbm_rd_addr(fp16_hbm_rd_addr_w),
    .hbm_resp_valid(fp16_hbm_resp_valid_w),
    .hbm_resp_ready(fp16_hbm_resp_ready_w),
    .hbm_resp_data(fp16_hbm_resp_data_w),
    .sram_rd_valid(fp16_sram_rd_valid_w),
    .sram_rd_ready(fp16_sram_rd_ready_w),
    .sram_rd_addr(fp16_sram_rd_addr_w),
    .sram_rd_id(fp16_sram_rd_id_w),
    .sram_resp_valid(fp16_sram_resp_valid_w),
    .sram_resp_ready(fp16_sram_resp_ready_w),
    .sram_resp_data(fp16_sram_resp_data_w),
    .sram_resp_id(fp16_sram_resp_id_w),
    .sram_wr_valid(fp16_sram_wr_valid_w),
    .sram_wr_ready(fp16_sram_wr_ready_w),
    .sram_wr_addr(fp16_sram_wr_addr_w),
    .sram_wr_data(fp16_sram_wr_data_w),
    .vec_sram_rd_valid(),
    .vec_sram_rd_ready({`MEM_REQ_LANES{1'b0}}),
    .vec_sram_rd_addr(),
    .vec_sram_rd_id(),
    .vec_sram_rd_pe_mask(),
    .vec_sram_resp_valid({`MEM_REQ_LANES{1'b0}}),
    .vec_sram_resp_ready(),
    .vec_sram_resp_data({(`MEM_REQ_LANES*`SRAM_WDATA_W){1'b0}}),
    .vec_sram_resp_id({(`MEM_REQ_LANES*`REQ_ID_W){1'b0}}),
    .vec_sram_wr_valid(),
    .vec_sram_wr_ready({`MEM_REQ_LANES{1'b0}}),
    .vec_sram_wr_addr(),
    .vec_sram_wr_data(),
    .vec_sram_wr_id(),
    .vec_sram_wr_pe_mask(),
    .busy(fp16_busy_w),
    .current_position(fp16_current_position_w),
    .current_layer_debug(fp16_current_layer_debug_w)
);

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state_r <= ST_IDLE;
        map_state_r <= MAP_IDLE;
        token_id_r <= {TOKEN_ID_W{1'b0}};
        src_addr_r <= {ADDR_W{1'b0}};
        dst_addr_r <= {ADDR_W{1'b0}};
        req_id_r <= {REQ_ID_W{1'b0}};
        tree_mask_en_r <= 1'b0;
        tree_mask_branch_id_r <= {`BRANCH_ID_W{1'b0}};
        prefix_len_r <= 16'd0;
        visible_mask_r <= {MAX_ATTN_TOKENS{1'b0}};
        position_ovr_val_r <= 16'd0;
        position_ovr_en_r <= 1'b0;
        generated_token_r <= 32'd0;
        map_hbm_addr_r <= {HBM_ADDR_W{1'b0}};
        map_low_data_r <= {DATA_BUS_W{1'b0}};
        map_resp_data_r <= {HBM_DATA_W{1'b0}};
    end else begin
        case (map_state_r)
            MAP_IDLE: begin
                if (fp16_hbm_rd_valid_w && fp16_hbm_rd_ready_w) begin
                    map_hbm_addr_r <= fp16_hbm_rd_addr_w;
                    map_state_r <= MAP_SEND_LO;
                end
            end

            MAP_SEND_LO: begin
                if (!fp16_sram_wr_valid_w && op_req_ready)
                    map_state_r <= MAP_WAIT_LO;
            end

            MAP_WAIT_LO: begin
                if (op_resp_valid && op_resp_ready &&
                    (op_resp_id == HBM_MAPPED_REQ_ID)) begin
                    map_low_data_r <= op_resp_rdata;
                    map_state_r <= MAP_SEND_HI;
                end
            end

            MAP_SEND_HI: begin
                if (!fp16_sram_wr_valid_w && op_req_ready)
                    map_state_r <= MAP_WAIT_HI;
            end

            MAP_WAIT_HI: begin
                if (op_resp_valid && op_resp_ready &&
                    (op_resp_id == HBM_MAPPED_REQ_ID)) begin
                    map_resp_data_r <= {op_resp_rdata, map_low_data_r};
                    map_state_r <= MAP_RESP;
                end
            end

            MAP_RESP: begin
                if (fp16_hbm_resp_valid_w && fp16_hbm_resp_ready_w)
                    map_state_r <= MAP_IDLE;
            end

            default: begin
                map_state_r <= MAP_IDLE;
            end
        endcase

        case (state_r)
            ST_IDLE: begin
                if (issue_fire_w) begin
                    token_id_r <= issue_token_id;
                    src_addr_r <= issue_src_addr;
                    dst_addr_r <= issue_dst_addr;
                    req_id_r <= issue_req_id;
                    tree_mask_en_r <= issue_tree_mask_en;
                    tree_mask_branch_id_r <= issue_tree_mask_branch_id;
                    prefix_len_r <= issue_prefix_len;
                    visible_mask_r <= issue_visible_mask;
                    position_ovr_val_r <= issue_position;
                    position_ovr_en_r <= issue_position_ovr;
                    generated_token_r <= 32'd0;
                    state_r <= ST_BUSY;
                end
            end

            ST_BUSY: begin
                if (fp16_token_out_fire_w) begin
                    generated_token_r <= fp16_token_out_id_w;
                    state_r <= ST_RESULT;
                end
            end

            ST_RESULT: begin
                if (result_valid && result_ready) begin
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
