`timescale 1ns/1ps

`include "config/prediction_params.vh"
`include "config/interface_params.vh"
`include "config/memory_params.vh"
`include "config/model_params.vh"

// PeArrayLayerController — FULL TRANSFORMER FORWARD PASS
//
// Complete implementation: embed → N×(norm+QKV+attn+Wo+res+norm+FFN+res) → norm → lm_head → argmax
// Position-0 simplification: single-token attention → attn_out = V (softmax=1.0)
// All matvec operations use pe_mac_unit (8 lanes, 128 depth, FP16)
// 4 slots processed in parallel

module PeArrayLayerController #(
    parameter integer HIDDEN_DIM     = `MODEL_DMODEL,
    parameter integer INTERMEDIATE   = `MODEL_INTERMEDIATE_DIM,
    parameter integer NUM_HEADS      = `MODEL_HEAD_NUM,
    parameter integer HEAD_DIM       = `MODEL_HEAD_DIM,
    parameter integer N_LAYERS       = `MODEL_N_LAYERS,
    parameter integer VOCAB_SIZE     = `MODEL_VOCAB_SIZE,
    parameter integer MAX_POS        = `MODEL_MAX_POS_EMB,
    parameter integer DATA_W         = `FP16_TILE_DATA_W,
    parameter integer BEAT_ELEMS     = (`SRAM_RDATA_W / `FP16_TILE_DATA_W),
    parameter integer HIDDEN_BEATS   = ((HIDDEN_DIM + BEAT_ELEMS - 1) / BEAT_ELEMS),
    parameter integer INTER_BEATS    = ((INTERMEDIATE + BEAT_ELEMS - 1) / BEAT_ELEMS),
    parameter integer NUM_SLOTS      = `TREE_FRONTIER_SLOTS,
    parameter integer PE_ROWS        = `STRICT_PAPER_PE_ROWS,
    parameter integer PE_COLS        = `STRICT_PAPER_PE_COLS
) (
    input                              clk,
    input                              rst_n,
    input                              start,
    output reg                         done,
    output reg                         busy,
    input  [NUM_SLOTS-1:0]             slot_valid,
    input  [NUM_SLOTS*`TOKEN_ID_W-1:0] slot_token_id,
    input  [NUM_SLOTS*`POSITION_ID_W-1:0] slot_position_id,
    input  [`SRAM_ADDR_W-1:0]          embedding_base_addr,
    input  [`SRAM_ADDR_W-1:0]          hidden0_base_addr,
    input  [`SRAM_ADDR_W-1:0]          hidden1_base_addr,
    input  [`SRAM_ADDR_W-1:0]          final_base_addr,
    input  [`SRAM_ADDR_W-1:0]          weight_sram_base_addr,
    input  [`SRAM_ADDR_W-1:0]          kv_cache_base_addr,
    input  [`SRAM_ADDR_W-1:0]          final_norm_gamma_addr,
    input  [`SRAM_ADDR_W-1:0]          lm_head_weight_base_addr,
    input  [`HBM_ADDR_W-1:0]           hbm_weight_base_addr,
    output reg                         sram_rd_valid,
    input                              sram_rd_ready,
    output reg [`SRAM_ADDR_W-1:0]      sram_rd_addr,
    input                              sram_resp_valid,
    input  [`SRAM_RDATA_W-1:0]         sram_resp_data,
    output reg                         sram_wr_valid,
    input                              sram_wr_ready,
    output reg [`SRAM_ADDR_W-1:0]      sram_wr_addr,
    output reg [`SRAM_WDATA_W-1:0]     sram_wr_data,
    output reg                         hbm_rd_valid,
    input                              hbm_rd_ready,
    output reg [`HBM_ADDR_W-1:0]       hbm_rd_addr,
    input                              hbm_resp_valid,
    input  [`HBM_DATA_W-1:0]           hbm_resp_data,
    output reg [NUM_SLOTS-1:0]         out_token_valid,
    output reg [NUM_SLOTS*`TOKEN_ID_W-1:0] out_token_id
);

// Weight tile sizes in SRAM beats (elements / BEAT_ELEMS):
// 128×128 matrix = 16384 elements = 2048 beats
localparam integer TILE_BEATS = (HIDDEN_DIM * HIDDEN_DIM) / BEAT_ELEMS;  // 2048
// 256×128 (FFN expand) = 32768 elements = 4096 beats
localparam integer FFN_EXP_TILE_BEATS = (INTERMEDIATE * HIDDEN_DIM) / BEAT_ELEMS;  // 4096
// 128×256 (FFN down) = 32768 elements = 4096 beats
localparam integer FFN_DOWN_TILE_BEATS = (HIDDEN_DIM * INTERMEDIATE) / BEAT_ELEMS;  // 4096

// HBM layout per layer (in SRAM beats after preload):
// Python pads each matrix slot to WEIGHT_SLOT_BEATS = max(TILE, FFN_EXP, FFN_DOWN) = 4096
// Layout: pre_gamma(16) + post_gamma(16) + Wq(4096) + Wk(4096) + Wv(4096) + Wo(4096)
//         + gate(4096) + up(4096) + down(4096)
localparam integer WEIGHT_SLOT_BEATS = FFN_EXP_TILE_BEATS;  // 4096 (padded slot size)
localparam integer LAYER_PRE_GAMMA_OFF  = 0;
localparam integer LAYER_POST_GAMMA_OFF = HIDDEN_BEATS;
localparam integer LAYER_WQ_OFF  = 2 * HIDDEN_BEATS;
localparam integer LAYER_WK_OFF  = LAYER_WQ_OFF + WEIGHT_SLOT_BEATS;
localparam integer LAYER_WV_OFF  = LAYER_WK_OFF + WEIGHT_SLOT_BEATS;
localparam integer LAYER_WO_OFF  = LAYER_WV_OFF + WEIGHT_SLOT_BEATS;
localparam integer LAYER_GATE_OFF = LAYER_WO_OFF + WEIGHT_SLOT_BEATS;
localparam integer LAYER_UP_OFF  = LAYER_GATE_OFF + WEIGHT_SLOT_BEATS;
localparam integer LAYER_DOWN_OFF = LAYER_UP_OFF + WEIGHT_SLOT_BEATS;
localparam integer LAYER_TOTAL_BEATS = 2 * HIDDEN_BEATS + 7 * WEIGHT_SLOT_BEATS + WEIGHT_SLOT_BEATS; // 32800 (matches Python)

// =========================================================================
// States
// =========================================================================
localparam [4:0]
    ST_IDLE       = 5'd0,
    ST_EMBED_RD   = 5'd1,
    ST_HBM_PRE    = 5'd2,
    ST_HBM_WR     = 5'd3,
    ST_NORM_RD    = 5'd4,  // read gamma + compute norm
    ST_NORM_COMP  = 5'd5,
    ST_MATVEC_RD  = 5'd6,  // pipelined matvec (read weights + MAC)
    ST_MATVEC_DN  = 5'd7,  // matvec done, store result
    ST_RESIDUAL   = 5'd8,  // element-wise add
    ST_SILU_MUL   = 5'd9,  // silu(gate)*up
    ST_ARGMAX     = 5'd10,
    ST_DONE       = 5'd11,
    ST_MATVEC_LATCH = 5'd12, // 1-cycle latch for slot_mac_out_r before copy
    ST_ATTN_COMP  = 5'd13;  // full multi-head attention (RoPE + KV cache + softmax)

// Operation sequence (indexes into op table)
localparam [4:0]
    OP_EMBED      = 5'd0,
    OP_PRE_NORM   = 5'd1,
    OP_WQ         = 5'd2,
    OP_WK         = 5'd3,
    OP_WV         = 5'd4,
    OP_WO         = 5'd5,
    OP_RES1       = 5'd6,
    OP_POST_NORM  = 5'd7,
    OP_GATE       = 5'd8,
    OP_UP         = 5'd9,
    OP_SILU_MUL   = 5'd10,
    OP_DOWN       = 5'd11,
    OP_RES2       = 5'd12,
    OP_NEXT_LAYER = 5'd13,
    OP_FINAL_NORM = 5'd14,
    OP_LM_HEAD    = 5'd15,
    OP_ARGMAX     = 5'd16;

reg [4:0] state_r;
reg [4:0] op_r;
reg [5:0] layer_idx_r;
reg [11:0] beat_cnt_r;   // up to 3072 for FFN down input
reg [11:0] resp_cnt_r;
reg [8:0] out_group_r;   // output group index (max 384 = 3072/8)
reg [1:0] load_slot_r;
reg [15:0] hbm_cnt_r;

// Per-slot vectors (128 × 16-bit = 2048 bits each)
reg [HIDDEN_DIM*DATA_W-1:0] slot_hidden_r [0:NUM_SLOTS-1];
reg [HIDDEN_DIM*DATA_W-1:0] slot_residual_r [0:NUM_SLOTS-1];
reg [HIDDEN_DIM*DATA_W-1:0] slot_norm_r [0:NUM_SLOTS-1];
reg [HIDDEN_DIM*DATA_W-1:0] slot_q_r [0:NUM_SLOTS-1];   // Q projection result (for attention)
reg [HIDDEN_DIM*DATA_W-1:0] slot_k_r [0:NUM_SLOTS-1];   // K projection result (for attention)
reg [INTERMEDIATE*DATA_W-1:0] slot_gate_r [0:NUM_SLOTS-1];
reg [INTERMEDIATE*DATA_W-1:0] slot_up_r [0:NUM_SLOTS-1];
// MAC output buffer (max INTERMEDIATE=256 elements)
reg [INTERMEDIATE*DATA_W-1:0] slot_mac_out_r [0:NUM_SLOTS-1];
// Gamma register
reg [HIDDEN_DIM*DATA_W-1:0] gamma_r;
// Visible mask for tree attention (per slot, MAX_POS bits)
reg [NUM_SLOTS*MAX_POS-1:0] slot_visible_mask_r;

reg [NUM_SLOTS-1:0] active_slots_r;
reg [NUM_SLOTS*`TOKEN_ID_W-1:0] lat_token_id_r;

// Current matvec config
reg [`SRAM_ADDR_W-1:0] mv_weight_base_r;
reg [11:0] mv_input_dim_r;   // up to 3072 for FFN down
reg [8:0] mv_output_groups_r; // up to 384 = 3072/8

// MAC units
reg  [NUM_SLOTS-1:0]              mac_clear;
reg  [NUM_SLOTS-1:0]              mac_valid;
reg  [BEAT_ELEMS*DATA_W-1:0]      mac_weight_col;
reg  [8:0]                        mac_depth_cfg_r;
wire [NUM_SLOTS*BEAT_ELEMS*DATA_W-1:0] mac_result;
wire [NUM_SLOTS-1:0]              mac_done;
reg  [NUM_SLOTS-1:0]              mac_done_latch_r;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) mac_done_latch_r <= {NUM_SLOTS{1'b0}};
    else begin
        mac_done_latch_r <= mac_done_latch_r | mac_done;
        if (|mac_clear) mac_done_latch_r <= {NUM_SLOTS{1'b0}};
    end
end
wire all_mac_done_w = &(mac_done_latch_r | mac_done | ~active_slots_r);

// MAC input vector selection: depends on operation
// For hidden-dim ops: use slot_norm_r (normalized input)
// For FFN down: use slot_gate_r (after silu*up, stored there)
// mac_elem_idx_r tracks which vector element to feed the MAC.
// Cleared by mac_clear, incremented each cycle mac_valid is active.
reg [DATA_W-1:0] mac_vec_sel [0:NUM_SLOTS-1];
reg [11:0] mac_elem_idx_r;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        mac_elem_idx_r <= 9'd0;
    else if (|mac_clear)
        mac_elem_idx_r <= 9'd0;
    else if (|mac_valid)
        mac_elem_idx_r <= mac_elem_idx_r + 9'd1;
end

always @(*) begin : mac_vec_select
    integer sv;
    for (sv = 0; sv < NUM_SLOTS; sv = sv + 1) begin
        if (op_r == OP_DOWN)
            mac_vec_sel[sv] = slot_gate_r[sv][mac_elem_idx_r*DATA_W +: DATA_W];
        else if (op_r == OP_WO)
            // For Wo: read V directly from slot_mac_out_r (avoids LATCH copy issue)
            mac_vec_sel[sv] = slot_mac_out_r[sv][mac_elem_idx_r*DATA_W +: DATA_W];
        else
            mac_vec_sel[sv] = slot_norm_r[sv][mac_elem_idx_r*DATA_W +: DATA_W];
    end
end

genvar si;
generate
    for (si = 0; si < NUM_SLOTS; si = si + 1) begin : gen_slot_mac
        pe_mac_unit #(.LANES(BEAT_ELEMS), .DEPTH(INTERMEDIATE), .DATA_W(DATA_W))
        u_mac (
            .clk(clk), .rst_n(rst_n),
            .clear(mac_clear[si]),
            .mac_valid(mac_valid[si]),
            .vector_val(mac_vec_sel[si]),
            .weight_col(mac_weight_col),
            .depth_cfg(mv_input_dim_r[$clog2(INTERMEDIATE)-1:0]),
            .result(mac_result[si*BEAT_ELEMS*DATA_W +: BEAT_ELEMS*DATA_W]),
            .done(mac_done[si])
        );
    end
endgenerate

// Shared FP16 arithmetic (retained for argmax compare)
wire [15:0] fp_mult_a, fp_mult_b, fp_mult_out;
wire [15:0] fp_add_a, fp_add_b, fp_add_out;
floatMult16 u_fp_mult (.floatA(fp_mult_a), .floatB(fp_mult_b), .product(fp_mult_out));
floatAdd16 u_fp_add (.floatA(fp_add_a), .floatB(fp_add_b), .sum(fp_add_out));

// =========================================================================
// Nonlinear operator module instances
// =========================================================================
reg sub_started_r;  // tracks whether start pulse has been sent in current state

// --- Flat bus wiring for module interfaces ---
wire [NUM_SLOTS*HIDDEN_DIM*DATA_W-1:0] norm_vec_in_w;
wire [NUM_SLOTS*HIDDEN_DIM*DATA_W-1:0] norm_vec_out_w;
wire norm_start_w = (state_r == ST_NORM_COMP && !sub_started_r);
wire norm_done_w;

wire [NUM_SLOTS*HIDDEN_DIM*DATA_W-1:0] res_vec_a_w;
wire [NUM_SLOTS*HIDDEN_DIM*DATA_W-1:0] res_vec_b_w;
wire [NUM_SLOTS*HIDDEN_DIM*DATA_W-1:0] res_vec_out_w;
wire res_start_w = (state_r == ST_RESIDUAL && !sub_started_r);
wire res_done_w;

wire [NUM_SLOTS*INTERMEDIATE*DATA_W-1:0] silu_gate_w;
wire [NUM_SLOTS*INTERMEDIATE*DATA_W-1:0] silu_up_w;
wire [NUM_SLOTS*INTERMEDIATE*DATA_W-1:0] silu_out_w;
wire silu_start_w = (state_r == ST_SILU_MUL && !sub_started_r);
wire silu_done_w;

// Pack array registers into flat buses
genvar gi;
generate
    for (gi = 0; gi < NUM_SLOTS; gi = gi + 1) begin : gen_flat_bus
        assign norm_vec_in_w[gi*HIDDEN_DIM*DATA_W +: HIDDEN_DIM*DATA_W] = slot_hidden_r[gi];
        assign res_vec_a_w[gi*HIDDEN_DIM*DATA_W +: HIDDEN_DIM*DATA_W] = slot_residual_r[gi];
        assign res_vec_b_w[gi*HIDDEN_DIM*DATA_W +: HIDDEN_DIM*DATA_W] =
            slot_mac_out_r[gi][HIDDEN_DIM*DATA_W-1:0];
        assign silu_gate_w[gi*INTERMEDIATE*DATA_W +: INTERMEDIATE*DATA_W] = slot_gate_r[gi];
        assign silu_up_w[gi*INTERMEDIATE*DATA_W +: INTERMEDIATE*DATA_W] = slot_up_r[gi];
    end
endgenerate

// RMSNorm compute module
pe_rmsnorm_compute #(
    .DIM(HIDDEN_DIM), .DATA_W(DATA_W), .NUM_SLOTS(NUM_SLOTS)
) u_rmsnorm (
    .clk(clk), .rst_n(rst_n),
    .start(norm_start_w),
    .done(norm_done_w),
    .active_slots(active_slots_r),
    .vec_in(norm_vec_in_w),
    .gamma(gamma_r),
    .vec_out(norm_vec_out_w)
);

// Residual add compute module
pe_residual_add_compute #(
    .DIM(HIDDEN_DIM), .DATA_W(DATA_W), .NUM_SLOTS(NUM_SLOTS)
) u_residual (
    .clk(clk), .rst_n(rst_n),
    .start(res_start_w),
    .done(res_done_w),
    .active_slots(active_slots_r),
    .vec_a(res_vec_a_w),
    .vec_b(res_vec_b_w),
    .vec_out(res_vec_out_w)
);

// SiLU×gate compute module
pe_silu_mul_compute #(
    .DIM(INTERMEDIATE), .DATA_W(DATA_W), .NUM_SLOTS(NUM_SLOTS)
) u_silu_mul (
    .clk(clk), .rst_n(rst_n),
    .start(silu_start_w),
    .done(silu_done_w),
    .active_slots(active_slots_r),
    .vec_gate(silu_gate_w),
    .vec_up(silu_up_w),
    .vec_out(silu_out_w)
);

// Full multi-head attention compute module (RoPE + KV cache + tree mask + softmax)
wire attn_start_w = (state_r == ST_ATTN_COMP && !sub_started_r);
wire attn_done_w;
wire [NUM_SLOTS*HIDDEN_DIM*DATA_W-1:0] attn_vec_q_w;
wire [NUM_SLOTS*HIDDEN_DIM*DATA_W-1:0] attn_vec_k_w;
wire [NUM_SLOTS*HIDDEN_DIM*DATA_W-1:0] attn_vec_v_w;
wire [NUM_SLOTS*HIDDEN_DIM*DATA_W-1:0] attn_vec_out_w;

// Pack Q/K/V from array registers into flat buses for attention module
genvar ai;
generate
    for (ai = 0; ai < NUM_SLOTS; ai = ai + 1) begin : gen_attn_bus
        assign attn_vec_q_w[ai*HIDDEN_DIM*DATA_W +: HIDDEN_DIM*DATA_W] = slot_q_r[ai];
        assign attn_vec_k_w[ai*HIDDEN_DIM*DATA_W +: HIDDEN_DIM*DATA_W] = slot_k_r[ai];
        assign attn_vec_v_w[ai*HIDDEN_DIM*DATA_W +: HIDDEN_DIM*DATA_W] =
            slot_mac_out_r[ai][HIDDEN_DIM*DATA_W-1:0];
    end
endgenerate

pe_attn_compute #(
    .HIDDEN_DIM(HIDDEN_DIM), .HEAD_DIM(HEAD_DIM), .NUM_HEADS(NUM_HEADS),
    .MAX_POS(MAX_POS), .N_LAYERS(N_LAYERS), .DATA_W(DATA_W), .NUM_SLOTS(NUM_SLOTS)
) u_attn (
    .clk(clk), .rst_n(rst_n),
    .start(attn_start_w),
    .done(attn_done_w),
    .active_slots(active_slots_r),
    .layer_idx(layer_idx_r),
    .position(slot_position_id[NUM_SLOTS*`POSITION_ID_W-1:0]),
    .visible_mask(slot_visible_mask_r),
    .vec_q(attn_vec_q_w),
    .vec_k(attn_vec_k_w),
    .vec_v(attn_vec_v_w),
    .vec_out(attn_vec_out_w)
);

// Argmax
reg [DATA_W-1:0] slot_max_val_r [0:NUM_SLOTS-1];
reg [`TOKEN_ID_W-1:0] slot_max_idx_r [0:NUM_SLOTS-1];
reg [15:0] argmax_elem_r;

integer i;

// =========================================================================
// Main state machine
// =========================================================================
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state_r <= ST_IDLE;
        op_r <= 5'd0;
        layer_idx_r <= 6'd0;
        beat_cnt_r <= 9'd0;
        resp_cnt_r <= 9'd0;
        out_group_r <= 5'd0;
        load_slot_r <= 2'd0;
        hbm_cnt_r <= 16'd0;
        active_slots_r <= {NUM_SLOTS{1'b0}};
        lat_token_id_r <= {(NUM_SLOTS*`TOKEN_ID_W){1'b0}};
        mv_weight_base_r <= {`SRAM_ADDR_W{1'b0}};
        mv_input_dim_r <= 9'd0;
        mv_output_groups_r <= 5'd0;
        busy <= 1'b0;
        done <= 1'b0;
        sram_rd_valid <= 1'b0;
        sram_wr_valid <= 1'b0;
        hbm_rd_valid <= 1'b0;
        out_token_valid <= {NUM_SLOTS{1'b0}};
        out_token_id <= {(NUM_SLOTS*`TOKEN_ID_W){1'b0}};
        mac_clear <= {NUM_SLOTS{1'b0}};
        mac_valid <= {NUM_SLOTS{1'b0}};
        mac_weight_col <= {(BEAT_ELEMS*DATA_W){1'b0}};
        mac_depth_cfg_r <= 9'd128;
        gamma_r <= {(HIDDEN_DIM*DATA_W){1'b0}};
        sub_started_r <= 1'b0;
        argmax_elem_r <= 16'd0;
        slot_visible_mask_r <= {(NUM_SLOTS*MAX_POS){1'b0}};
        for (i = 0; i < NUM_SLOTS; i = i + 1) begin
            slot_hidden_r[i] <= {(HIDDEN_DIM*DATA_W){1'b0}};
            slot_residual_r[i] <= {(HIDDEN_DIM*DATA_W){1'b0}};
            slot_norm_r[i] <= {(HIDDEN_DIM*DATA_W){1'b0}};
            slot_q_r[i] <= {(HIDDEN_DIM*DATA_W){1'b0}};
            slot_k_r[i] <= {(HIDDEN_DIM*DATA_W){1'b0}};
            slot_gate_r[i] <= {(INTERMEDIATE*DATA_W){1'b0}};
            slot_up_r[i] <= {(INTERMEDIATE*DATA_W){1'b0}};
            slot_mac_out_r[i] <= {(INTERMEDIATE*DATA_W){1'b0}};
            slot_max_val_r[i] <= 16'h0000;
            slot_max_idx_r[i] <= {`TOKEN_ID_W{1'b0}};
        end
    end else begin
        done <= 1'b0;
        sram_rd_valid <= 1'b0;
        sram_wr_valid <= 1'b0;
        hbm_rd_valid <= 1'b0;
        out_token_valid <= {NUM_SLOTS{1'b0}};
        mac_clear <= {NUM_SLOTS{1'b0}};
        mac_valid <= {NUM_SLOTS{1'b0}};

        case (state_r)
        // =================================================================
        ST_IDLE: begin
            if (start) begin
                busy <= 1'b1;
                active_slots_r <= slot_valid;
                lat_token_id_r <= slot_token_id;
                layer_idx_r <= 6'd0;
                op_r <= OP_EMBED;
                load_slot_r <= 2'd0;
                beat_cnt_r <= 9'd0;
                resp_cnt_r <= 9'd0;
                state_r <= ST_EMBED_RD;
                // Generate causal visible mask from position for each slot
                // mask[pos] = 1 for pos <= current_position (causal attention)
                for (i = 0; i < NUM_SLOTS; i = i + 1) begin : gen_mask_blk
                    integer mi;
                    for (mi = 0; mi < MAX_POS; mi = mi + 1) begin
                        if (mi <= slot_position_id[i*`POSITION_ID_W +: `POSITION_ID_W])
                            slot_visible_mask_r[i*MAX_POS + mi] <= 1'b1;
                        else
                            slot_visible_mask_r[i*MAX_POS + mi] <= 1'b0;
                    end
                end
            end
        end

        // =================================================================
        // EMBEDDING READ (pipelined)
        ST_EMBED_RD: begin
            if (beat_cnt_r < HIDDEN_BEATS) begin
                sram_rd_valid <= 1'b1;
                sram_rd_addr <= embedding_base_addr +
                    (lat_token_id_r[load_slot_r*`TOKEN_ID_W +: `TOKEN_ID_W] * HIDDEN_BEATS) +
                    beat_cnt_r;
                if (sram_rd_ready) beat_cnt_r <= beat_cnt_r + 9'd1;
            end
            if (sram_resp_valid) begin
                slot_hidden_r[load_slot_r][resp_cnt_r*BEAT_ELEMS*DATA_W +: BEAT_ELEMS*DATA_W]
                    <= sram_resp_data[BEAT_ELEMS*DATA_W-1:0];
                resp_cnt_r <= resp_cnt_r + 9'd1;
                if (resp_cnt_r == HIDDEN_BEATS - 1) begin
                    if (load_slot_r < NUM_SLOTS-1 && active_slots_r[load_slot_r+1]) begin
                        load_slot_r <= load_slot_r + 2'd1;
                        beat_cnt_r <= 9'd0; resp_cnt_r <= 9'd0;
                    end else begin
                        // All embeddings loaded → start layer 0
                        op_r <= OP_PRE_NORM;
                        layer_idx_r <= 6'd0;
                        state_r <= ST_NORM_RD;
                        beat_cnt_r <= 9'd0; resp_cnt_r <= 9'd0;
                    end
                end
            end
        end

        // =================================================================
        // HBM PRELOAD (currently skipped - weights pre-loaded by testbench)
        ST_HBM_PRE: begin
            state_r <= ST_NORM_RD;
        end
        ST_HBM_WR: begin
            state_r <= ST_NORM_RD;
        end

        // =================================================================
        // NORM READ: read gamma vector, then compute norm behaviorally
        ST_NORM_RD: begin
            if (beat_cnt_r < HIDDEN_BEATS) begin
                sram_rd_valid <= 1'b1;
                if (op_r == OP_FINAL_NORM)
                    sram_rd_addr <= final_norm_gamma_addr + beat_cnt_r;
                else if (op_r == OP_PRE_NORM)
                    sram_rd_addr <= weight_sram_base_addr +
                        (layer_idx_r * LAYER_TOTAL_BEATS) + LAYER_PRE_GAMMA_OFF + beat_cnt_r;
                else // POST_NORM
                    sram_rd_addr <= weight_sram_base_addr +
                        (layer_idx_r * LAYER_TOTAL_BEATS) + LAYER_POST_GAMMA_OFF + beat_cnt_r;
                if (sram_rd_ready) beat_cnt_r <= beat_cnt_r + 9'd1;
            end
            if (sram_resp_valid) begin
                gamma_r[resp_cnt_r*BEAT_ELEMS*DATA_W +: BEAT_ELEMS*DATA_W]
                    <= sram_resp_data[BEAT_ELEMS*DATA_W-1:0];
                resp_cnt_r <= resp_cnt_r + 9'd1;
                if (resp_cnt_r == HIDDEN_BEATS - 1) begin
                    state_r <= ST_NORM_COMP;
                    sub_started_r <= 1'b0;
                end
            end
        end

        // NORM COMPUTE: delegated to pe_rmsnorm_compute module
        // Module fires on norm_start_w = (state==ST_NORM_COMP && !sub_started_r)
        ST_NORM_COMP: begin
            sub_started_r <= 1'b1;
            if (norm_done_w) begin
                // Latch results from module output
                for (i = 0; i < NUM_SLOTS; i = i + 1) begin
                    if (active_slots_r[i]) begin
                        slot_norm_r[i] <= norm_vec_out_w[i*HIDDEN_DIM*DATA_W +: HIDDEN_DIM*DATA_W];
                        slot_residual_r[i] <= slot_hidden_r[i];
                    end
                end
                sub_started_r <= 1'b0;
                // Advance to next operation after norm
                beat_cnt_r <= 9'd0; resp_cnt_r <= 9'd0; out_group_r <= 5'd0;
                case (op_r)
                OP_PRE_NORM: begin
                    op_r <= OP_WQ;
                    mv_weight_base_r <= weight_sram_base_addr +
                        (layer_idx_r * LAYER_TOTAL_BEATS) + LAYER_WQ_OFF;
                    mv_input_dim_r <= HIDDEN_DIM;
                    mv_output_groups_r <= HIDDEN_DIM / BEAT_ELEMS;
                    mac_clear <= active_slots_r;
                    state_r <= ST_MATVEC_RD;
                end
                OP_POST_NORM: begin
                    op_r <= OP_GATE;
                    mv_weight_base_r <= weight_sram_base_addr +
                        (layer_idx_r * LAYER_TOTAL_BEATS) + LAYER_GATE_OFF;
                    mv_input_dim_r <= HIDDEN_DIM;
                    mv_output_groups_r <= INTERMEDIATE / BEAT_ELEMS;
                    mac_clear <= active_slots_r;
                    state_r <= ST_MATVEC_RD;
                end
                OP_FINAL_NORM: begin
                    op_r <= OP_LM_HEAD;
                    mv_weight_base_r <= lm_head_weight_base_addr;
                    mv_input_dim_r <= HIDDEN_DIM;
                    mv_output_groups_r <= VOCAB_SIZE / BEAT_ELEMS;
                    mac_clear <= active_slots_r;
                    state_r <= ST_MATVEC_RD;
                end
                default: state_r <= ST_DONE;
                endcase
            end
        end

        // =================================================================
        // MATVEC: pipelined weight read + MAC
        // Weight tile address calculation:
        //   For single tile-col matrices (128 input cols):
        //     addr = base + (out_group/2)*256 + beat_cnt*2 + (out_group%2)
        //   For multi tile-col matrices (256 input cols, e.g. FFN down):
        //     tile_col = beat_cnt / 128
        //     col_in_tile = beat_cnt % 128
        //     addr = base + (out_group/2)*(num_tile_cols*256) + tile_col*256 + col_in_tile*2 + out_group%2
        ST_MATVEC_RD: begin
            if (beat_cnt_r < mv_input_dim_r) begin
                sram_rd_valid <= 1'b1;
                if (mv_input_dim_r <= 12'd128) begin
                    // Single tile-col
                    sram_rd_addr <= mv_weight_base_r +
                        ((out_group_r >> 1) * 256) +
                        (beat_cnt_r * 2) +
                        {{(`SRAM_ADDR_W-1){1'b0}}, out_group_r[0]};
                end else begin
                    // Multi tile-col
                    sram_rd_addr <= mv_weight_base_r +
                        ((out_group_r >> 1) * ((mv_input_dim_r >> 7) * 256)) +
                        ((beat_cnt_r >> 7) * 256) +
                        ((beat_cnt_r & 12'h7F) * 2) +
                        {{(`SRAM_ADDR_W-1){1'b0}}, out_group_r[0]};
                end
                if (sram_rd_ready) beat_cnt_r <= beat_cnt_r + 12'd1;
            end
            if (sram_resp_valid) begin
                mac_weight_col <= sram_resp_data[BEAT_ELEMS*DATA_W-1:0];
                mac_valid <= active_slots_r;
                resp_cnt_r <= resp_cnt_r + 9'd1;
                // Transition when all responses received (= mv_input_dim_r)
                if (resp_cnt_r == mv_input_dim_r - 1)
                    state_r <= ST_MATVEC_DN;
            end
        end

        // MATVEC DONE: store result, advance output group or next op
        ST_MATVEC_DN: begin
            for (i = 0; i < NUM_SLOTS; i = i + 1) begin
                if (active_slots_r[i])
                    slot_mac_out_r[i][out_group_r*BEAT_ELEMS*DATA_W +: BEAT_ELEMS*DATA_W]
                        <= mac_result[i*BEAT_ELEMS*DATA_W +: BEAT_ELEMS*DATA_W];
            end
            if (out_group_r == mv_output_groups_r - 1) begin
                // Matvec complete — route based on current op
                case (op_r)
                OP_WQ: begin
                    // Q computed — save to slot_q_r, proceed to Wk
                    // (uses LATCH state to let slot_mac_out_r settle)
                    state_r <= ST_MATVEC_LATCH;
                end
                OP_WK: begin
                    // K computed — save to slot_k_r, proceed to Wv
                    // (uses LATCH state to let slot_mac_out_r settle)
                    state_r <= ST_MATVEC_LATCH;
                end
                OP_WV: begin
                    // V computed — go to full attention (V in slot_mac_out_r)
                    state_r <= ST_MATVEC_LATCH;
                end
                OP_WO: begin
                    // Wo @ V done → residual add
                    op_r <= OP_RES1;
                    sub_started_r <= 1'b0;
                    state_r <= ST_RESIDUAL;
                end
                OP_GATE: begin
                    // Gate computed — need 1 cycle for slot_mac_out_r to settle
                    state_r <= ST_MATVEC_LATCH;
                end
                OP_UP: begin
                    // Up computed — need 1 cycle for slot_mac_out_r to settle
                    state_r <= ST_MATVEC_LATCH;
                end
                OP_DOWN: begin
                    // Down computed → residual add
                    op_r <= OP_RES2;
                    sub_started_r <= 1'b0;
                    state_r <= ST_RESIDUAL;
                end
                OP_LM_HEAD: begin
                    // Logits computed → argmax
                    for (i = 0; i < NUM_SLOTS; i = i + 1)
                        slot_mac_out_r[i] <= slot_mac_out_r[i]; // already there
                    op_r <= OP_ARGMAX;
                    argmax_elem_r <= 16'd0;
                    for (i = 0; i < NUM_SLOTS; i = i + 1) begin
                        slot_max_val_r[i] <= 16'h0000;
                        slot_max_idx_r[i] <= {`TOKEN_ID_W{1'b0}};
                    end
                    state_r <= ST_ARGMAX;
                end
                default: state_r <= ST_DONE;
                endcase
            end else begin
                out_group_r <= out_group_r + 5'd1;
                mac_clear <= active_slots_r;
                beat_cnt_r <= 9'd0; resp_cnt_r <= 9'd0;
                state_r <= ST_MATVEC_RD;
            end
        end

        // =================================================================
        // MATVEC LATCH: 1-cycle delay so slot_mac_out_r NBA settles before copy
        ST_MATVEC_LATCH: begin
            case (op_r)
            OP_WQ: begin
                // Save Q result from slot_mac_out_r, proceed to Wk
                for (i = 0; i < NUM_SLOTS; i = i + 1)
                    slot_q_r[i] <= slot_mac_out_r[i][HIDDEN_DIM*DATA_W-1:0];
                op_r <= OP_WK;
                mv_weight_base_r <= weight_sram_base_addr +
                    (layer_idx_r * LAYER_TOTAL_BEATS) + LAYER_WK_OFF;
                mv_output_groups_r <= HIDDEN_DIM / BEAT_ELEMS;
                out_group_r <= 5'd0; beat_cnt_r <= 9'd0; resp_cnt_r <= 9'd0;
                mac_clear <= active_slots_r;
                state_r <= ST_MATVEC_RD;
            end
            OP_WK: begin
                // Save K result from slot_mac_out_r, proceed to Wv
                for (i = 0; i < NUM_SLOTS; i = i + 1)
                    slot_k_r[i] <= slot_mac_out_r[i][HIDDEN_DIM*DATA_W-1:0];
                op_r <= OP_WV;
                mv_weight_base_r <= weight_sram_base_addr +
                    (layer_idx_r * LAYER_TOTAL_BEATS) + LAYER_WV_OFF;
                mv_output_groups_r <= HIDDEN_DIM / BEAT_ELEMS;
                out_group_r <= 5'd0; beat_cnt_r <= 9'd0; resp_cnt_r <= 9'd0;
                mac_clear <= active_slots_r;
                state_r <= ST_MATVEC_RD;
            end
            OP_WV: begin
                // V in slot_mac_out_r — go to full attention computation
                sub_started_r <= 1'b0;
                state_r <= ST_ATTN_COMP;
            end
            OP_GATE: begin
                // Copy gate result from slot_mac_out_r
                for (i = 0; i < NUM_SLOTS; i = i + 1)
                    slot_gate_r[i] <= slot_mac_out_r[i];
                op_r <= OP_UP;
                mv_weight_base_r <= weight_sram_base_addr +
                    (layer_idx_r * LAYER_TOTAL_BEATS) + LAYER_UP_OFF;
                mv_input_dim_r <= HIDDEN_DIM;
                mv_output_groups_r <= INTERMEDIATE / BEAT_ELEMS;
                out_group_r <= 5'd0; beat_cnt_r <= 9'd0; resp_cnt_r <= 9'd0;
                mac_clear <= active_slots_r;
                state_r <= ST_MATVEC_RD;
            end
            OP_UP: begin
                // Copy up result from slot_mac_out_r
                for (i = 0; i < NUM_SLOTS; i = i + 1)
                    slot_up_r[i] <= slot_mac_out_r[i];
                op_r <= OP_SILU_MUL;
                sub_started_r <= 1'b0;
                state_r <= ST_SILU_MUL;
            end
            default: state_r <= ST_DONE;
            endcase
        end

        // =================================================================
        // ATTENTION COMPUTE: full MHA (RoPE + KV cache + tree mask + softmax)
        // Delegated to pe_attn_compute module
        ST_ATTN_COMP: begin
            sub_started_r <= 1'b1;
            if (attn_done_w) begin
                // Latch attention output to slot_mac_out_r (for Wo matvec input)
                for (i = 0; i < NUM_SLOTS; i = i + 1) begin
                    if (active_slots_r[i])
                        slot_mac_out_r[i][HIDDEN_DIM*DATA_W-1:0]
                            <= attn_vec_out_w[i*HIDDEN_DIM*DATA_W +: HIDDEN_DIM*DATA_W];
                end
                sub_started_r <= 1'b0;
                // Proceed to Wo projection
                op_r <= OP_WO;
                mv_weight_base_r <= weight_sram_base_addr +
                    (layer_idx_r * LAYER_TOTAL_BEATS) + LAYER_WO_OFF;
                mv_input_dim_r <= HIDDEN_DIM;
                mv_output_groups_r <= HIDDEN_DIM / BEAT_ELEMS;
                out_group_r <= 5'd0; beat_cnt_r <= 9'd0; resp_cnt_r <= 9'd0;
                mac_clear <= active_slots_r;
                state_r <= ST_MATVEC_RD;
            end
        end

        // =================================================================
        // RESIDUAL ADD: delegated to pe_residual_add_compute module
        ST_RESIDUAL: begin
            sub_started_r <= 1'b1;
            if (res_done_w) begin
                for (i = 0; i < NUM_SLOTS; i = i + 1) begin
                    if (active_slots_r[i])
                        slot_hidden_r[i] <= res_vec_out_w[i*HIDDEN_DIM*DATA_W +: HIDDEN_DIM*DATA_W];
                end
                sub_started_r <= 1'b0;
                beat_cnt_r <= 9'd0; resp_cnt_r <= 9'd0;
                case (op_r)
                OP_RES1: begin
                    op_r <= OP_POST_NORM;
                    state_r <= ST_NORM_RD;
                end
                OP_RES2: begin
                    if (layer_idx_r == N_LAYERS - 1) begin
                        op_r <= OP_FINAL_NORM;
                        state_r <= ST_NORM_RD;
                    end else begin
                        layer_idx_r <= layer_idx_r + 6'd1;
                        op_r <= OP_PRE_NORM;
                        state_r <= ST_NORM_RD;
                    end
                end
                default: state_r <= ST_DONE;
                endcase
            end
        end

        // =================================================================
        // SILU_MUL: delegated to pe_silu_mul_compute module
        ST_SILU_MUL: begin
            sub_started_r <= 1'b1;
            if (silu_done_w) begin
                for (i = 0; i < NUM_SLOTS; i = i + 1) begin
                    if (active_slots_r[i])
                        slot_gate_r[i] <= silu_out_w[i*INTERMEDIATE*DATA_W +: INTERMEDIATE*DATA_W];
                end
                sub_started_r <= 1'b0;
                // Now do W_down @ silu_result
                op_r <= OP_DOWN;
                mv_weight_base_r <= weight_sram_base_addr +
                    (layer_idx_r * LAYER_TOTAL_BEATS) + LAYER_DOWN_OFF;
                mv_input_dim_r <= INTERMEDIATE;
                mv_output_groups_r <= HIDDEN_DIM / BEAT_ELEMS;
                out_group_r <= 5'd0; beat_cnt_r <= 9'd0; resp_cnt_r <= 9'd0;
                mac_clear <= active_slots_r;
                state_r <= ST_MATVEC_RD;
            end
        end

        // =================================================================
        // ARGMAX
        ST_ARGMAX: begin
            if (argmax_elem_r < VOCAB_SIZE) begin
                for (i = 0; i < NUM_SLOTS; i = i + 1) begin
                    if (active_slots_r[i]) begin
                        if (argmax_elem_r == 16'd0) begin
                            slot_max_val_r[i] <= slot_mac_out_r[i][0 +: DATA_W];
                            slot_max_idx_r[i] <= {`TOKEN_ID_W{1'b0}};
                        end else begin
                            // FP16 sortable compare
                            if ((slot_mac_out_r[i][argmax_elem_r*DATA_W + DATA_W - 1] ?
                                    ~slot_mac_out_r[i][argmax_elem_r*DATA_W +: DATA_W] :
                                    {1'b1, slot_mac_out_r[i][argmax_elem_r*DATA_W +: DATA_W-1]})
                                >
                                (slot_max_val_r[i][DATA_W-1] ?
                                    ~slot_max_val_r[i] :
                                    {1'b1, slot_max_val_r[i][DATA_W-2:0]}))
                            begin
                                slot_max_val_r[i] <= slot_mac_out_r[i][argmax_elem_r*DATA_W +: DATA_W];
                                slot_max_idx_r[i] <= argmax_elem_r[`TOKEN_ID_W-1:0];
                            end
                        end
                    end
                end
                argmax_elem_r <= argmax_elem_r + 16'd1;
            end else begin
                for (i = 0; i < NUM_SLOTS; i = i + 1) begin
                    out_token_valid[i] <= active_slots_r[i];
                    out_token_id[i*`TOKEN_ID_W +: `TOKEN_ID_W] <= slot_max_idx_r[i];
                end
                state_r <= ST_DONE;
            end
        end

        // =================================================================
        ST_DONE: begin
            done <= 1'b1;
            busy <= 1'b0;
            state_r <= ST_IDLE;
        end

        default: state_r <= ST_IDLE;
        endcase
    end
end

endmodule
