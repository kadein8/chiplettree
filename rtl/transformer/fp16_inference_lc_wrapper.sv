`timescale 1ns/1ps
`include "config/interface_params.vh"
`include "config/prediction_params.vh"
`include "config/model_params.vh"
`include "config/memory_params.vh"

// fp16_inference_lc_wrapper
//
// Drop-in replacement for PeArrayLayerController using fp16_inference_top
// (real systolic array + HBM weight streaming + tree attention).

module fp16_inference_lc_wrapper #(
    parameter integer HIDDEN_DIM   = `MODEL_DMODEL,
    parameter integer INTERMEDIATE = `MODEL_INTERMEDIATE_DIM,
    parameter integer NUM_HEADS    = `MODEL_HEAD_NUM,
    parameter integer HEAD_DIM     = `MODEL_HEAD_DIM,
    parameter integer N_LAYERS     = `MODEL_N_LAYERS,
    parameter integer VOCAB_SIZE   = `MODEL_VOCAB_SIZE,
    parameter integer MAX_POS      = `MODEL_MAX_POS_EMB,
    parameter integer NUM_SLOTS    = `TREE_FRONTIER_SLOTS,
    parameter [22:0]  WORK_H0_BASE = `MODEL_WORK_HIDDEN0_BASE,
    parameter [22:0]  WORK_H1_BASE = `MODEL_WORK_HIDDEN1_BASE,
    parameter [22:0]  WORK_F_BASE  = `MODEL_WORK_FINAL_BASE,
    parameter [22:0]  KV_BASE      = `KV_DRAFT_BASE_MIN,
    parameter [22:0]  W_SRAM_BASE  = `MODEL_WEIGHT_SRAM_BASE,
    parameter [31:0]  HBM_W_BASE   = `MODEL_HBM_WEIGHT_BASE
) (
    input  logic clk,
    input  logic rst_n,
    input  logic                              start,
    output logic                              done,
    output logic                              busy,
    input  logic [NUM_SLOTS-1:0]              slot_valid,
    input  logic [NUM_SLOTS*`TOKEN_ID_W-1:0]  slot_token_id,
    input  logic [NUM_SLOTS*`POSITION_ID_W-1:0] slot_position_id,
    input  logic [NUM_SLOTS*NUM_SLOTS-1:0]    tree_mask,
    input  logic [`SRAM_ADDR_W-1:0]           embedding_base_addr,
    input  logic [`SRAM_ADDR_W-1:0]           hidden0_base_addr,
    input  logic [`SRAM_ADDR_W-1:0]           hidden1_base_addr,
    input  logic [`SRAM_ADDR_W-1:0]           final_base_addr,
    input  logic [`SRAM_ADDR_W-1:0]           weight_sram_base_addr,
    input  logic [`SRAM_ADDR_W-1:0]           kv_cache_base_addr,
    input  logic [`SRAM_ADDR_W-1:0]           final_norm_gamma_addr,
    input  logic [`SRAM_ADDR_W-1:0]           lm_head_weight_base_addr,
    input  logic [`HBM_ADDR_W-1:0]            hbm_weight_base_addr,
    input  logic [15:0]                       committed_prefix_len,
    output logic [`MEM_REQ_LANES-1:0]         vec_req_valid,
    input  logic [`MEM_REQ_LANES-1:0]         vec_req_ready,
    output logic [`MEM_REQ_LANES-1:0]         vec_req_write,
    output logic [`MEM_REQ_LANES*`SRAM_ADDR_W-1:0] vec_req_addr,
    output logic [`MEM_REQ_LANES*`SRAM_WDATA_W-1:0] vec_req_wdata,
    output logic [`MEM_REQ_LANES*`REQ_ID_W-1:0] vec_req_req_id,
    output logic [`MEM_REQ_LANES*`PE_MASK_W-1:0] vec_req_pe_mask,
    output logic [`MEM_REQ_LANES*`REQ_PRIORITY_W-1:0] vec_req_priority,
    output logic [`MEM_REQ_LANES*`BANK_ID_W-1:0] vec_req_bank_id,
    output logic [`MEM_REQ_LANES*`SUBBANK_ID_W-1:0] vec_req_subbank_id,
    input  logic [`PE_MASK_W-1:0]             mc_resp_valid,
    output logic [`PE_MASK_W-1:0]             mc_resp_ready,
    input  logic [`PE_MASK_W*`SRAM_RDATA_W-1:0] mc_resp_rdata,
    input  logic [`PE_MASK_W*`REQ_ID_W-1:0]   mc_resp_req_id,
    input  logic [`PE_MASK_W-1:0]             mc_resp_last,
    output logic                              sram_wr_valid,
    input  logic                              sram_wr_ready,
    output logic [`SRAM_ADDR_W-1:0]           sram_wr_addr,
    output logic [`SRAM_WDATA_W-1:0]          sram_wr_data,
    output logic                              hbm_rd_valid,
    input  logic                              hbm_rd_ready,
    output logic [`HBM_ADDR_W-1:0]            hbm_rd_addr,
    input  logic                              hbm_resp_valid,
    input  logic [`HBM_DATA_W-1:0]            hbm_resp_data,
    output logic [NUM_SLOTS-1:0]              out_token_valid,
    output logic [NUM_SLOTS*`TOKEN_ID_W-1:0]  out_token_id
);
// PLACEHOLDER_BODY

localparam integer WINDOW_SIZE = `VERIFY_WINDOW_SIZE;

function automatic [4:0] popcount(input [NUM_SLOTS-1:0] v);
    integer i;
    begin
        popcount = 0;
        for (i = 0; i < NUM_SLOTS; i = i + 1)
            popcount = popcount + {4'd0, v[i]};
    end
endfunction

localparam [1:0] W_IDLE = 2'd0, W_RUN = 2'd1, W_DONE = 2'd2;
reg [1:0] wstate_r;
reg [NUM_SLOTS-1:0] slot_valid_r;
reg [4:0] batch_count_r;
reg batch_in_valid_r;
wire batch_in_ready_w;
wire batch_out_valid_w;
wire [4:0] batch_out_count_w;
wire [WINDOW_SIZE*32-1:0] batch_out_token_ids_w;
reg [WINDOW_SIZE*32-1:0] batch_token_ids_r;
reg [WINDOW_SIZE*16-1:0] batch_positions_r;
reg [WINDOW_SIZE*WINDOW_SIZE-1:0] batch_tree_mask_r;

integer si;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        wstate_r <= W_IDLE;
        done <= 1'b0;
        busy <= 1'b0;
        batch_in_valid_r <= 1'b0;
    end else begin
        done <= 1'b0;
        case (wstate_r)
        W_IDLE: begin
            if (start) begin
                wstate_r <= W_RUN;
                busy <= 1'b1;
                slot_valid_r <= slot_valid;
                batch_count_r <= popcount(slot_valid);
                batch_in_valid_r <= 1'b1;
                for (si = 0; si < WINDOW_SIZE; si = si + 1) begin
                    if (si < NUM_SLOTS) begin
                        batch_token_ids_r[si*32 +: 32] <= {16'd0, slot_token_id[si*`TOKEN_ID_W +: `TOKEN_ID_W]};
                        batch_positions_r[si*16 +: 16] <= {4'd0, slot_position_id[si*`POSITION_ID_W +: `POSITION_ID_W]};
                    end else begin
                        batch_token_ids_r[si*32 +: 32] <= 32'd0;
                        batch_positions_r[si*16 +: 16] <= 16'd0;
                    end
                end
                batch_tree_mask_r <= tree_mask;
            end
        end
// PLACEHOLDER_FSM_CONT
        W_RUN: begin
            if (batch_in_valid_r && batch_in_ready_w)
                batch_in_valid_r <= 1'b0;
            if (batch_out_valid_w)
                wstate_r <= W_DONE;
        end
        W_DONE: begin
            done <= 1'b1;
            busy <= 1'b0;
            wstate_r <= W_IDLE;
        end
        default: wstate_r <= W_IDLE;
        endcase
    end
end

genvar oi;
generate for (oi = 0; oi < NUM_SLOTS; oi = oi + 1) begin : gen_out
    assign out_token_valid[oi] = (wstate_r == W_DONE) && slot_valid_r[oi];
    assign out_token_id[oi*`TOKEN_ID_W +: `TOKEN_ID_W] =
        batch_out_token_ids_w[oi*32 +: `TOKEN_ID_W];
end endgenerate

logic fp16_sram_rd_valid, fp16_sram_rd_ready;
logic [`SRAM_ADDR_W-1:0] fp16_sram_rd_addr;
logic [`REQ_ID_W-1:0] fp16_sram_rd_id;
logic fp16_sram_resp_valid;
logic [`SRAM_RDATA_W-1:0] fp16_sram_resp_data;
logic [`REQ_ID_W-1:0] fp16_sram_resp_id;

logic [`MEM_REQ_LANES-1:0] fp16_vec_rd_valid, fp16_vec_rd_ready;
logic [`MEM_REQ_LANES*`SRAM_ADDR_W-1:0] fp16_vec_rd_addr;
logic [`MEM_REQ_LANES*`REQ_ID_W-1:0] fp16_vec_rd_id;
logic [`MEM_REQ_LANES*`PE_MASK_W-1:0] fp16_vec_rd_pe_mask;
logic [`MEM_REQ_LANES-1:0] fp16_vec_wr_valid;
logic [`MEM_REQ_LANES*`SRAM_ADDR_W-1:0] fp16_vec_wr_addr;
logic [`MEM_REQ_LANES*`SRAM_WDATA_W-1:0] fp16_vec_wr_data;
// PLACEHOLDER_MUX

// Mux: vec reads, vec writes, and scalar reads onto vec_req port
// Priority: vec_wr > vec_rd > scalar_rd (fp16_inference_top sequences these)
assign vec_req_valid = fp16_vec_wr_valid | fp16_vec_rd_valid | {(`MEM_REQ_LANES-1)'(0), fp16_sram_rd_valid & ~|fp16_vec_rd_valid & ~|fp16_vec_wr_valid};
assign vec_req_write = fp16_vec_wr_valid;

// Lane 0 address mux
assign vec_req_addr[0 +: `SRAM_ADDR_W] =
    fp16_vec_wr_valid[0] ? fp16_vec_wr_addr[0 +: `SRAM_ADDR_W] :
    fp16_vec_rd_valid[0] ? fp16_vec_rd_addr[0 +: `SRAM_ADDR_W] :
    fp16_sram_rd_addr;
assign vec_req_req_id[0 +: `REQ_ID_W] =
    fp16_vec_wr_valid[0] ? {`REQ_ID_W{1'b0}} :
    fp16_vec_rd_valid[0] ? fp16_vec_rd_id[0 +: `REQ_ID_W] :
    fp16_sram_rd_id;

genvar li;
generate for (li = 1; li < `MEM_REQ_LANES; li = li + 1) begin : gen_vec_mux
    assign vec_req_addr[li*`SRAM_ADDR_W +: `SRAM_ADDR_W] =
        fp16_vec_wr_valid[li] ? fp16_vec_wr_addr[li*`SRAM_ADDR_W +: `SRAM_ADDR_W] :
        fp16_vec_rd_addr[li*`SRAM_ADDR_W +: `SRAM_ADDR_W];
    assign vec_req_req_id[li*`REQ_ID_W +: `REQ_ID_W] =
        fp16_vec_wr_valid[li] ? {`REQ_ID_W{1'b0}} :
        fp16_vec_rd_id[li*`REQ_ID_W +: `REQ_ID_W];
end endgenerate

assign vec_req_pe_mask = fp16_vec_rd_pe_mask;
assign vec_req_wdata = fp16_vec_wr_data;
assign vec_req_priority = '0;
assign vec_req_bank_id = '0;
assign vec_req_subbank_id = '0;
assign fp16_vec_rd_ready = vec_req_ready & ~fp16_vec_wr_valid;
assign fp16_sram_rd_ready = vec_req_ready[0] & ~fp16_vec_rd_valid[0] & ~fp16_vec_wr_valid[0];

reg scalar_rd_pending_r;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) scalar_rd_pending_r <= 1'b0;
    else if (fp16_sram_rd_valid && fp16_sram_rd_ready) scalar_rd_pending_r <= 1'b1;
    else if (mc_resp_valid[0] && scalar_rd_pending_r) scalar_rd_pending_r <= 1'b0;
end
assign fp16_sram_resp_valid = mc_resp_valid[0] && scalar_rd_pending_r;
assign fp16_sram_resp_data = mc_resp_rdata[0 +: `SRAM_RDATA_W];
assign fp16_sram_resp_id = mc_resp_req_id[0 +: `REQ_ID_W];
assign mc_resp_ready = {`PE_MASK_W{1'b1}};
// PLACEHOLDER_INSTANCE

fp16_inference_top #(
    .HIDDEN_DIM(HIDDEN_DIM), .INTERMEDIATE_DIM(INTERMEDIATE),
    .NUM_HEADS(NUM_HEADS), .HEAD_DIM(HEAD_DIM),
    .N_LAYERS(N_LAYERS), .VOCAB_SIZE(VOCAB_SIZE),
    .MAX_ATTN_TOKENS(MAX_POS), .WINDOW_SIZE(WINDOW_SIZE),
    .WORK_HIDDEN0_BASE(WORK_H0_BASE), .WORK_HIDDEN1_BASE(WORK_H1_BASE),
    .WORK_FINAL_BASE(WORK_F_BASE),
    .WEIGHT_SRAM_BASE(W_SRAM_BASE),
    .KV_CACHE_SRAM_BASE(`KV_COMMITTED_BASE),
    .KV_DRAFT_SRAM_BASE(KV_BASE),
    .HBM_WEIGHT_BASE(HBM_W_BASE),
    .LM_HEAD_WEIGHT_BASE(`MODEL_LM_HEAD_WEIGHT_BASE)
) u_infer (
    .clk(clk), .rst_n(rst_n),
    .token_in_valid(1'b0), .token_in_ready(),
    .token_in_id(32'd0), .token_in_is_bos(1'b0),
    .token_out_valid(), .token_out_ready(1'b1), .token_out_id(),
    .cfg_embedding_base(embedding_base_addr),
    .cfg_final_norm_gamma_addr(final_norm_gamma_addr),
    .cfg_do_sample(1'b0), .cfg_top_k(7'd1), .cfg_top_p(16'd0),
    .cfg_tree_mask_en(1'b0), .cfg_branch_id(2'd0),
    .cfg_prefix_len(16'd0), .cfg_visible_mask({MAX_POS{1'b1}}),
    .cfg_position(16'd0), .cfg_position_ovr(1'b0),
    .batch_in_valid(batch_in_valid_r), .batch_in_ready(batch_in_ready_w),
    .batch_in_count(batch_count_r),
    .batch_in_token_ids(batch_token_ids_r),
    .batch_in_positions(batch_positions_r),
    .batch_in_tree_mask(batch_tree_mask_r),
    .batch_in_prefix_len(committed_prefix_len),
    .batch_in_seed_kv_valid(1'b0),
    .batch_in_slot_is_seed({{(WINDOW_SIZE-1){1'b0}}, 1'b1}),
    .batch_out_valid(batch_out_valid_w), .batch_out_ready(1'b1),
    .batch_out_count(batch_out_count_w),
    .batch_out_token_ids(batch_out_token_ids_w),
    .hbm_rd_valid(hbm_rd_valid), .hbm_rd_ready(hbm_rd_ready),
    .hbm_rd_addr(hbm_rd_addr),
    .hbm_resp_valid(hbm_resp_valid), .hbm_resp_ready(),
    .hbm_resp_data(hbm_resp_data),
    .sram_rd_valid(fp16_sram_rd_valid), .sram_rd_ready(fp16_sram_rd_ready),
    .sram_rd_addr(fp16_sram_rd_addr), .sram_rd_id(fp16_sram_rd_id),
    .sram_resp_valid(fp16_sram_resp_valid), .sram_resp_ready(),
    .sram_resp_data(fp16_sram_resp_data), .sram_resp_id(fp16_sram_resp_id),
    .sram_wr_valid(sram_wr_valid), .sram_wr_ready(sram_wr_ready),
    .sram_wr_addr(sram_wr_addr), .sram_wr_data(sram_wr_data),
    .vec_sram_rd_valid(fp16_vec_rd_valid), .vec_sram_rd_ready(fp16_vec_rd_ready),
    .vec_sram_rd_addr(fp16_vec_rd_addr), .vec_sram_rd_id(fp16_vec_rd_id),
    .vec_sram_rd_pe_mask(fp16_vec_rd_pe_mask),
    .vec_sram_resp_valid(mc_resp_valid & ~{(`MEM_REQ_LANES-1)'(0), scalar_rd_pending_r}),
    .vec_sram_resp_ready(), .vec_sram_resp_data(mc_resp_rdata),
    .vec_sram_resp_id(mc_resp_req_id),
    .vec_sram_wr_valid(fp16_vec_wr_valid),
    .vec_sram_wr_ready({`MEM_REQ_LANES{1'b1}}),
    .vec_sram_wr_addr(fp16_vec_wr_addr),
    .vec_sram_wr_data(fp16_vec_wr_data),
    .vec_sram_wr_id(), .vec_sram_wr_pe_mask(),
    .busy(), .current_position(), .current_layer_debug()
);

endmodule
