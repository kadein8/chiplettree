`timescale 1ns/1ps
`include "config/interface_params.vh"
`include "config/prediction_params.vh"
`include "config/model_params.vh"
`include "config/memory_params.vh"

module speculative_decode_final_top (
    input                              clk,
    input                              rst_n,
    input                              start,
    input  [`TOKEN_ID_W-1:0]           prompt_token_id,
    input  [7:0]                       max_gen_tokens,
    output logic                       done,
    output logic                       busy,
    output logic                       token_out_valid,
    output logic [`TOKEN_ID_W-1:0]     token_out_id,
    output logic                       hbm_rd_valid,
    input  logic                       hbm_rd_ready,
    output logic [`HBM_ADDR_W-1:0]     hbm_rd_addr,
    input  logic                       hbm_resp_valid,
    input  logic [`HBM_DATA_W-1:0]     hbm_resp_data,
    input  logic                       sram_preload_valid,
    input  logic [`SRAM_ADDR_W-1:0]    sram_preload_addr,
    input  logic [`SRAM_WDATA_W-1:0]   sram_preload_data,
    input  logic                       warmup_accept_valid,
    input  logic [`NODE_ID_W-1:0]      warmup_accept_parent_node_id,
    input  logic [`TOKEN_ID_W-1:0]     warmup_accept_token_id,
    input  logic [`POSITION_ID_W-1:0]  warmup_accept_position
);

localparam integer BRANCH_NUM = `BRANCH_NUM;
localparam integer MAX_LEVELS = `MAX_PRIVATE_NODES_PER_BRANCH;
localparam integer LC_SLOTS   = `TREE_FRONTIER_SLOTS;

localparam [3:0]
    ST_IDLE = 4'd0, ST_PREDICT = 4'd1, ST_BUILD = 4'd2, ST_VERIFY = 4'd3,
    ST_COMPARE = 4'd4, ST_EMIT = 4'd5, ST_KV_COMMIT = 4'd6, ST_CHECK = 4'd7, ST_DONE = 4'd8,
    ST_FALLBACK = 4'd9, ST_FB_WAIT = 4'd10;

logic [3:0] state_r;
logic [7:0] gen_count_r, max_gen_r;
logic [`NODE_ID_W-1:0] seed_node_id_r;
logic [`TOKEN_ID_W-1:0] seed_token_id_r;
logic [`POSITION_ID_W-1:0] seed_position_r;
logic [15:0] committed_prefix_len_r;
logic [3:0] kv_commit_count_r;  // tokens to commit in ST_KV_COMMIT
logic [15:0] kv_commit_old_prefix_r;  // prefix_len before commit

// Forward declarations for emitter/fallback (used by draft feedback & KV sync)
logic emit_token_valid, emit_done;
logic [`TOKEN_ID_W-1:0] emit_token_id;
logic [3:0] emit_tokens_emitted;
logic fallback_token_valid_r;
logic [`TOKEN_ID_W-1:0] fallback_token_id_r;

// =========================================================================
// HHT Context Predictor
// =========================================================================
logic hht_accept_valid;
logic [`NODE_ID_W-1:0] hht_accept_parent_node_id;
logic [`TOKEN_ID_W-1:0] hht_accept_token_id;
logic [`POSITION_ID_W-1:0] hht_accept_position;
logic hht_cand_valid;
logic [`NODE_ID_W-1:0] hht_cand_parent_node_id;
logic [`TOKEN_ID_W-1:0] hht_cand_token_id;
logic [`TOKEN_ID_W-1:0] hht_cand_referenced_token_id;
logic [`POSITION_ID_W-1:0] hht_cand_referenced_position;
logic [7:0] hht_cand_confidence;
logic [`TOKEN_ID_W-1:0] tb_spec_token_0, tb_spec_token_1;
logic tb_spec_query_valid, tb_spec_hit;
logic [`TOKEN_ID_W-1:0] tb_spec_prediction;

HHTContextPredictor #(.CONF_W(8), .HISTORY_LEN(2), .SET_NUM(8), .WAY_NUM(4)) u_hht (
    .clk(clk), .rst_n(rst_n), .admission_enable(1'b1),
    .accept_valid(hht_accept_valid), .accept_parent_node_id(hht_accept_parent_node_id),
    .accept_token_id(hht_accept_token_id), .accept_position(hht_accept_position),
    .cand_valid(hht_cand_valid), .cand_parent_node_id(hht_cand_parent_node_id),
    .cand_token_id(hht_cand_token_id), .cand_referenced_token_id(hht_cand_referenced_token_id),
    .cand_referenced_position(hht_cand_referenced_position), .cand_confidence(hht_cand_confidence),
    .spec_token_0(tb_spec_token_0), .spec_token_1(tb_spec_token_1),
    .spec_query_valid(tb_spec_query_valid), .spec_hit(tb_spec_hit), .spec_prediction(tb_spec_prediction)
);

// =========================================================================
// Tree Builder
// =========================================================================
logic tb_start, tb_done, tb_busy;
logic tb_tree_req_valid, tb_tree_req_ready;
logic [`NODE_ID_W-1:0] tb_seed_node_id;
logic [`TOKEN_ID_W-1:0] tb_seed_token_id;
logic [`POSITION_ID_W-1:0] tb_seed_position;
logic [BRANCH_NUM-1:0] tb_branch_valid;
logic [BRANCH_NUM*MAX_LEVELS*`NODE_ID_W-1:0] tb_branch_node_ids;
logic [BRANCH_NUM*MAX_LEVELS*`NODE_ID_W-1:0] tb_branch_parent_node_ids;
logic [BRANCH_NUM*MAX_LEVELS*`TOKEN_ID_W-1:0] tb_branch_draft_tokens;
logic [BRANCH_NUM*MAX_LEVELS*`POSITION_ID_W-1:0] tb_branch_draft_positions;
logic [BRANCH_NUM*MAX_LEVELS-1:0] tb_branch_levels_valid;
logic [15:0] tb_committed_prefix_len;
logic tb_hht_done;

// Forward declarations for draft injection
logic draft_valid;
logic [`TOKEN_ID_W-1:0] draft_token_id;
logic [`NODE_ID_W-1:0] draft_parent_node_id;
logic [`POSITION_ID_W-1:0] draft_position;

// Mux HHT + draft into tree_builder
logic tb_cand_valid;
logic [`NODE_ID_W-1:0] tb_cand_parent_node_id;
logic [`TOKEN_ID_W-1:0] tb_cand_token_id;
logic [`POSITION_ID_W-1:0] tb_cand_referenced_position;
assign tb_cand_valid = draft_valid || hht_cand_valid;
assign tb_cand_parent_node_id = draft_valid ? draft_parent_node_id : hht_cand_parent_node_id;
assign tb_cand_token_id = draft_valid ? draft_token_id : hht_cand_token_id;
assign tb_cand_referenced_position = draft_valid ? draft_position : hht_cand_referenced_position;

tree_builder #(.BRANCH_NUM(BRANCH_NUM), .MAX_LEVELS(MAX_LEVELS), .TIMEOUT_CYCLES(64)) u_tree_builder (
    .clk(clk), .rst_n(rst_n), .start(tb_start), .done(tb_done), .busy(tb_busy),
    .seed_node_id(seed_node_id_r), .seed_token_id(seed_token_id_r), .seed_position(seed_position_r),
    .committed_prefix_len_in(committed_prefix_len_r),
    .cand_valid(tb_cand_valid), .cand_parent_node_id(tb_cand_parent_node_id),
    .cand_token_id(tb_cand_token_id), .cand_referenced_position(tb_cand_referenced_position),
    .hht_done(tb_hht_done),
    .spec_token_0(tb_spec_token_0), .spec_token_1(tb_spec_token_1),
    .spec_query_valid(tb_spec_query_valid), .spec_hit(tb_spec_hit), .spec_prediction(tb_spec_prediction),
    .tree_req_valid(tb_tree_req_valid), .tree_req_ready(tb_tree_req_ready),
    .out_seed_node_id(tb_seed_node_id), .out_seed_token_id(tb_seed_token_id), .out_seed_position(tb_seed_position),
    .out_branch_valid(tb_branch_valid), .out_branch_node_ids(tb_branch_node_ids),
    .out_branch_parent_node_ids(tb_branch_parent_node_ids),
    .out_branch_draft_tokens(tb_branch_draft_tokens), .out_branch_draft_positions(tb_branch_draft_positions),
    .out_branch_levels_valid(tb_branch_levels_valid), .out_committed_prefix_len(tb_committed_prefix_len)
);
assign tb_tree_req_ready = (state_r == ST_BUILD) && tb_tree_req_valid;

// =========================================================================
// Draft Injection Interface
// =========================================================================
logic draft_inject_start, draft_done_w;
logic [1:0] draft_branch_id;
logic [2:0] draft_depth;
logic [BRANCH_NUM-1:0] draft_branch_active;
logic [BRANCH_NUM*MAX_LEVELS*`TOKEN_ID_W-1:0] draft_branch_injected_tokens;
logic [BRANCH_NUM*3-1:0] draft_branch_depth_out;

draft_injection_interface #(.BRANCH_NUM(BRANCH_NUM), .MAX_DEPTH(MAX_LEVELS)) u_draft_inject (
    .clk(clk), .rst_n(rst_n), .inject_start(draft_inject_start),
    .seed_token_id(seed_token_id_r), .seed_position(seed_position_r), .seed_node_id(seed_node_id_r),
    .commit_feedback_valid(emit_token_valid || fallback_token_valid_r || (start && state_r == ST_IDLE)),
    .commit_feedback_token(emit_token_valid ? emit_token_id : fallback_token_valid_r ? fallback_token_id_r : prompt_token_id),
    .draft_valid(draft_valid), .draft_token_id(draft_token_id),
    .draft_parent_node_id(draft_parent_node_id), .draft_position(draft_position),
    .draft_branch_id(draft_branch_id), .draft_depth(draft_depth), .draft_done(draft_done_w),
    .branch_active(draft_branch_active), .branch_injected_tokens(draft_branch_injected_tokens),
    .branch_depth_out(draft_branch_depth_out)
);
assign draft_inject_start = (state_r == ST_BUILD) && !tb_busy && !tb_done;

// =========================================================================
// Branch Parallel Scheduler
// =========================================================================
logic sched_start, sched_all_done;
logic [BRANCH_NUM-1:0] sched_lc_start, sched_lc_done, sched_lc_busy;
logic [BRANCH_NUM*LC_SLOTS-1:0] sched_lc_slot_valid;
logic [BRANCH_NUM*LC_SLOTS*`TOKEN_ID_W-1:0] sched_lc_slot_token_id;
logic [BRANCH_NUM*LC_SLOTS*`POSITION_ID_W-1:0] sched_lc_slot_position_id;
logic [BRANCH_NUM*LC_SLOTS*LC_SLOTS-1:0] sched_lc_tree_mask;
logic [BRANCH_NUM*LC_SLOTS*`TOKEN_ID_W-1:0] sched_lc_out_token_id;
logic [BRANCH_NUM-1:0] sched_branch_result_valid;
logic [BRANCH_NUM*`TOKEN_ID_W-1:0] sched_branch_generated_token;
logic [BRANCH_NUM*MAX_LEVELS*`TOKEN_ID_W-1:0] sched_branch_draft_tokens_out;

branch_parallel_scheduler #(.BRANCH_NUM(BRANCH_NUM), .MAX_DEPTH(MAX_LEVELS)) u_scheduler (
    .clk(clk), .rst_n(rst_n), .start(sched_start), .all_done(sched_all_done),
    .branch_valid(tb_branch_valid), .branch_draft_tokens(tb_branch_draft_tokens),
    .branch_draft_positions(tb_branch_draft_positions), .branch_levels_valid(tb_branch_levels_valid),
    .seed_token_id(seed_token_id_r), .seed_position(seed_position_r),
    .committed_prefix_len(committed_prefix_len_r),
    .lc_start(sched_lc_start), .lc_done(sched_lc_done), .lc_busy(sched_lc_busy),
    .lc_slot_valid(sched_lc_slot_valid), .lc_slot_token_id(sched_lc_slot_token_id),
    .lc_slot_position_id(sched_lc_slot_position_id), .lc_tree_mask(sched_lc_tree_mask),
    .lc_out_token_id(sched_lc_out_token_id),
    .branch_result_valid(sched_branch_result_valid),
    .branch_generated_token(sched_branch_generated_token),
    .branch_draft_tokens_out(sched_branch_draft_tokens_out)
);

// =========================================================================
// 4x LC instances + shared SRAM
// =========================================================================
localparam BEHAV_SRAM_DEPTH = 270336;
reg [`SRAM_RDATA_W-1:0] behav_sram [0:BEHAV_SRAM_DEPTH-1];

logic [BRANCH_NUM-1:0] lc_start_w, lc_done_w, lc_busy_w;
logic [BRANCH_NUM*LC_SLOTS-1:0] lc_out_token_valid_w;
logic [BRANCH_NUM*LC_SLOTS*`TOKEN_ID_W-1:0] lc_out_token_id_w;

logic [BRANCH_NUM-1:0] lc_hbm_rd_valid;
logic [BRANCH_NUM*`HBM_ADDR_W-1:0] lc_hbm_rd_addr;
logic [BRANCH_NUM-1:0] lc_hbm_resp_valid;
logic [BRANCH_NUM*`HBM_DATA_W-1:0] lc_hbm_resp_data;

localparam integer HBM_LOCAL_DEPTH = 32768;
reg [`HBM_DATA_W-1:0] hbm_local_mem [0:HBM_LOCAL_DEPTH-1];

assign hbm_rd_valid = 1'b0;
assign hbm_rd_addr = '0;

// Fallback mux
logic fallback_lc_start;
wire use_fallback = (state_r == ST_FALLBACK || state_r == ST_FB_WAIT);
assign fallback_lc_start = (state_r == ST_FALLBACK);

logic [BRANCH_NUM*LC_SLOTS-1:0] mux_lc_slot_valid;
logic [BRANCH_NUM*LC_SLOTS*`TOKEN_ID_W-1:0] mux_lc_slot_token_id;
logic [BRANCH_NUM*LC_SLOTS*`POSITION_ID_W-1:0] mux_lc_slot_position_id;
logic [BRANCH_NUM*LC_SLOTS*LC_SLOTS-1:0] mux_lc_tree_mask;

always_comb begin
    mux_lc_slot_valid = sched_lc_slot_valid;
    mux_lc_slot_token_id = sched_lc_slot_token_id;
    mux_lc_slot_position_id = sched_lc_slot_position_id;
    mux_lc_tree_mask = sched_lc_tree_mask;
    if (use_fallback) begin
        mux_lc_slot_valid[0*LC_SLOTS +: LC_SLOTS] = '0;
        mux_lc_slot_valid[0*LC_SLOTS + 0] = 1'b1;
        mux_lc_slot_token_id[0*LC_SLOTS*`TOKEN_ID_W +: LC_SLOTS*`TOKEN_ID_W] = '0;
        mux_lc_slot_token_id[0*LC_SLOTS*`TOKEN_ID_W +: `TOKEN_ID_W] = seed_token_id_r;
        mux_lc_slot_position_id[0*LC_SLOTS*`POSITION_ID_W +: LC_SLOTS*`POSITION_ID_W] = '0;
        mux_lc_slot_position_id[0*LC_SLOTS*`POSITION_ID_W +: `POSITION_ID_W] = seed_position_r;
        mux_lc_tree_mask[0*LC_SLOTS*LC_SLOTS +: LC_SLOTS*LC_SLOTS] = '0;
        mux_lc_tree_mask[0*LC_SLOTS*LC_SLOTS + 0] = 1'b1;
    end
end

assign lc_start_w = use_fallback ? {3'b0, fallback_lc_start} : sched_lc_start;
assign sched_lc_done = lc_done_w;
assign sched_lc_busy = lc_busy_w;
assign sched_lc_out_token_id = lc_out_token_id_w;

genvar gi;
generate
for (gi = 0; gi < BRANCH_NUM; gi = gi + 1) begin : gen_lc
    logic lc_sram_wr_valid, lc_sram_wr_ready;
    logic [`SRAM_ADDR_W-1:0] lc_sram_wr_addr;
    logic [`SRAM_WDATA_W-1:0] lc_sram_wr_data;
    logic [`MEM_REQ_LANES-1:0] lc_vec_req_valid, lc_vec_req_ready, lc_vec_req_write;
    logic [`MEM_REQ_LANES*`SRAM_ADDR_W-1:0] lc_vec_req_addr;
    logic [`MEM_REQ_LANES*`SRAM_WDATA_W-1:0] lc_vec_req_wdata;
    logic [`MEM_REQ_LANES*`REQ_ID_W-1:0] lc_vec_req_req_id;
    logic [`MEM_REQ_LANES*`PE_MASK_W-1:0] lc_vec_req_pe_mask;
    logic [`MEM_REQ_LANES*`REQ_PRIORITY_W-1:0] lc_vec_req_priority;
    logic [`MEM_REQ_LANES*`BANK_ID_W-1:0] lc_vec_req_bank_id;
    logic [`MEM_REQ_LANES*`SUBBANK_ID_W-1:0] lc_vec_req_subbank_id;
    logic [`PE_MASK_W-1:0] lc_mc_resp_valid, lc_mc_resp_ready, lc_mc_resp_last;
    logic [`PE_MASK_W*`SRAM_RDATA_W-1:0] lc_mc_resp_rdata;
    logic [`PE_MASK_W*`REQ_ID_W-1:0] lc_mc_resp_req_id;

    fp16_inference_lc_wrapper #(
        .WORK_H0_BASE(`MODEL_WORK_HIDDEN0_BASE + gi * 512),
        .WORK_H1_BASE(`MODEL_WORK_HIDDEN1_BASE + gi * 512),
        .WORK_F_BASE(`MODEL_WORK_FINAL_BASE + gi * 512),
        .KV_BASE(`KV_DRAFT_BASE_MIN + gi * 16384),
        .W_SRAM_BASE(`MODEL_WEIGHT_SRAM_BASE + gi * 33792),
        .HBM_W_BASE(`MODEL_HBM_WEIGHT_BASE)
    ) u_lc (
        .clk(clk), .rst_n(rst_n),
        .start(lc_start_w[gi]), .done(lc_done_w[gi]), .busy(lc_busy_w[gi]),
        .slot_valid(mux_lc_slot_valid[gi*LC_SLOTS +: LC_SLOTS]),
        .slot_token_id(mux_lc_slot_token_id[gi*LC_SLOTS*`TOKEN_ID_W +: LC_SLOTS*`TOKEN_ID_W]),
        .slot_position_id(mux_lc_slot_position_id[gi*LC_SLOTS*`POSITION_ID_W +: LC_SLOTS*`POSITION_ID_W]),
        .tree_mask(mux_lc_tree_mask[gi*LC_SLOTS*LC_SLOTS +: LC_SLOTS*LC_SLOTS]),
        .embedding_base_addr(`MODEL_EMB_BASE),
        .hidden0_base_addr(`MODEL_WORK_HIDDEN0_BASE + gi * 512),
        .hidden1_base_addr(`MODEL_WORK_HIDDEN1_BASE + gi * 512),
        .final_base_addr(`MODEL_WORK_FINAL_BASE + gi * 512),
        .weight_sram_base_addr(`MODEL_WEIGHT_SRAM_BASE),
        .kv_cache_base_addr(`KV_DRAFT_BASE_MIN + gi * 16384),
        .final_norm_gamma_addr(`MODEL_FINAL_NORM_GAMMA_ADDR),
        .lm_head_weight_base_addr(`MODEL_LM_HEAD_WEIGHT_BASE),
        .hbm_weight_base_addr(`MODEL_HBM_WEIGHT_BASE),
        .committed_prefix_len(committed_prefix_len_r),
        .vec_req_valid(lc_vec_req_valid), .vec_req_ready(lc_vec_req_ready),
        .vec_req_write(lc_vec_req_write), .vec_req_addr(lc_vec_req_addr),
        .vec_req_wdata(lc_vec_req_wdata), .vec_req_req_id(lc_vec_req_req_id),
        .vec_req_pe_mask(lc_vec_req_pe_mask), .vec_req_priority(lc_vec_req_priority),
        .vec_req_bank_id(lc_vec_req_bank_id), .vec_req_subbank_id(lc_vec_req_subbank_id),
        .mc_resp_valid(lc_mc_resp_valid), .mc_resp_ready(lc_mc_resp_ready),
        .mc_resp_rdata(lc_mc_resp_rdata), .mc_resp_req_id(lc_mc_resp_req_id),
        .mc_resp_last(lc_mc_resp_last),
        .sram_wr_valid(lc_sram_wr_valid), .sram_wr_ready(lc_sram_wr_ready),
        .sram_wr_addr(lc_sram_wr_addr), .sram_wr_data(lc_sram_wr_data),
        .hbm_rd_valid(lc_hbm_rd_valid[gi]), .hbm_rd_ready(1'b1),
        .hbm_rd_addr(lc_hbm_rd_addr[gi*`HBM_ADDR_W +: `HBM_ADDR_W]),
        .hbm_resp_valid(lc_hbm_resp_valid[gi]),
        .hbm_resp_data(lc_hbm_resp_data[gi*`HBM_DATA_W +: `HBM_DATA_W]),
        .out_token_valid(lc_out_token_valid_w[gi*LC_SLOTS +: LC_SLOTS]),
        .out_token_id(lc_out_token_id_w[gi*LC_SLOTS*`TOKEN_ID_W +: LC_SLOTS*`TOKEN_ID_W])
    );

    // Shared SRAM behavioral model
    assign lc_vec_req_ready = {`MEM_REQ_LANES{1'b1}};
    assign lc_sram_wr_ready = 1'b1;
    reg [`MEM_REQ_LANES-1:0] resp_valid_r;
    reg [`MEM_REQ_LANES*`SRAM_RDATA_W-1:0] resp_rdata_r;
    reg [`MEM_REQ_LANES*`REQ_ID_W-1:0] resp_id_r;
    reg [`MEM_REQ_LANES-1:0] resp_last_r;
    integer mi;
    always @(posedge clk) begin
        for (mi = 0; mi < `MEM_REQ_LANES; mi = mi + 1) begin
            resp_valid_r[mi] <= lc_vec_req_valid[mi] && !lc_vec_req_write[mi];
            if (lc_vec_req_valid[mi]) begin
                if (lc_vec_req_write[mi]) begin
                    if (lc_vec_req_addr[mi*`SRAM_ADDR_W +: `SRAM_ADDR_W] < BEHAV_SRAM_DEPTH)
                        behav_sram[lc_vec_req_addr[mi*`SRAM_ADDR_W +: `SRAM_ADDR_W]] <= lc_vec_req_wdata[mi*`SRAM_WDATA_W +: `SRAM_WDATA_W];
                end else begin
                    if (lc_vec_req_addr[mi*`SRAM_ADDR_W +: `SRAM_ADDR_W] < BEHAV_SRAM_DEPTH)
                        resp_rdata_r[mi*`SRAM_RDATA_W +: `SRAM_RDATA_W] <= behav_sram[lc_vec_req_addr[mi*`SRAM_ADDR_W +: `SRAM_ADDR_W]];
                    else
                        resp_rdata_r[mi*`SRAM_RDATA_W +: `SRAM_RDATA_W] <= '0;
                end
                resp_id_r[mi*`REQ_ID_W +: `REQ_ID_W] <= lc_vec_req_req_id[mi*`REQ_ID_W +: `REQ_ID_W];
            end
            resp_last_r[mi] <= lc_vec_req_valid[mi] && !lc_vec_req_write[mi];
        end
        if (lc_sram_wr_valid && lc_sram_wr_addr < BEHAV_SRAM_DEPTH)
            behav_sram[lc_sram_wr_addr] <= lc_sram_wr_data;
        // KV commit: copy draft KV to committed region (only in gi==0 instance)
        // synthesis translate_off
        if (gi == 0 && state_r == ST_KV_COMMIT) begin : kv_commit_copy
            integer kv_layer, kv_beat, kv_tok;
            integer kv_src_base, kv_dst_base;
            localparam integer KV_POS_STRIDE_L = `MODEL_HEAD_NUM * (`MODEL_HEAD_DIM / (`SRAM_RDATA_W / `FP16_TILE_DATA_W)) * 2;
            for (kv_tok = 0; kv_tok < kv_commit_count_r; kv_tok = kv_tok + 1) begin
                for (kv_layer = 0; kv_layer < `MODEL_N_LAYERS; kv_layer = kv_layer + 1) begin
                    kv_src_base = (`KV_DRAFT_BASE_MIN + kv_tok * 16384) + kv_layer * 4096;
                    kv_dst_base = `KV_COMMITTED_BASE + kv_layer * 4096 + (kv_commit_old_prefix_r + kv_tok) * KV_POS_STRIDE_L;
                    for (kv_beat = 0; kv_beat < KV_POS_STRIDE_L; kv_beat = kv_beat + 1) begin
                        behav_sram[kv_dst_base + kv_beat] <= behav_sram[kv_src_base + kv_beat];
                    end
                end
            end
        end
        // synthesis translate_on
    end
    assign lc_mc_resp_valid = resp_valid_r;
    assign lc_mc_resp_rdata = resp_rdata_r;
    assign lc_mc_resp_req_id = resp_id_r;
    assign lc_mc_resp_last = resp_last_r;

    // Per-LC HBM pipeline
    reg hbm_pipe1_valid_r;
    reg [`HBM_ADDR_W-1:0] hbm_pipe1_addr_r;
    reg hbm_pipe2_valid_r;
    reg [`HBM_DATA_W-1:0] hbm_pipe2_data_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hbm_pipe1_valid_r <= 0;
            hbm_pipe2_valid_r <= 0;
        end else begin
            hbm_pipe1_valid_r <= lc_hbm_rd_valid[gi];
            hbm_pipe1_addr_r <= lc_hbm_rd_addr[gi*`HBM_ADDR_W +: `HBM_ADDR_W];
            hbm_pipe2_valid_r <= hbm_pipe1_valid_r;
            if (hbm_pipe1_valid_r && hbm_pipe1_addr_r < HBM_LOCAL_DEPTH)
                hbm_pipe2_data_r <= hbm_local_mem[hbm_pipe1_addr_r];
            else
                hbm_pipe2_data_r <= '0;
        end
    end
    assign lc_hbm_resp_valid[gi] = hbm_pipe2_valid_r;
    assign lc_hbm_resp_data[gi*`HBM_DATA_W +: `HBM_DATA_W] = hbm_pipe2_data_r;
end
endgenerate

// =========================================================================
// KV Cache Sync — NOT NEEDED with fp16_inference_top
// =========================================================================
// fp16_inference_top manages KV cache in shared SRAM. All 4 instances
// access the same behav_sram, so committed prefix KV is naturally visible.
// No cross-module KV copy required.

// =========================================================================
// Longest Path Comparator
// =========================================================================
logic cmp_start, cmp_result_valid;
logic [3:0] cmp_accepted_count;
logic [(MAX_LEVELS+1)*`TOKEN_ID_W-1:0] cmp_accepted_tokens;
logic [BRANCH_NUM-1:0] cmp_flush_mask;
logic cmp_all_correct;

longest_path_comparator #(.BRANCH_NUM(BRANCH_NUM), .MAX_DEPTH(MAX_LEVELS)) u_comparator (
    .clk(clk), .rst_n(rst_n), .compare_start(cmp_start),
    .branch_generated_token(sched_branch_generated_token),
    .branch_valid(sched_branch_result_valid),
    .branch_injected_tokens(draft_branch_injected_tokens),
    .branch_depth(draft_branch_depth_out),
    .result_valid(cmp_result_valid), .accepted_count(cmp_accepted_count),
    .accepted_tokens(cmp_accepted_tokens), .flush_mask(cmp_flush_mask),
    .all_correct(cmp_all_correct)
);

// =========================================================================
// Multi-Token Emitter
// =========================================================================
logic emit_start;
logic [`TOKEN_ID_W-1:0] emit_new_seed;
logic [`POSITION_ID_W-1:0] emit_new_position;
logic [15:0] emit_new_prefix_len;

multi_token_emitter #(.MAX_DEPTH(MAX_LEVELS)) u_emitter (
    .clk(clk), .rst_n(rst_n), .emit_start(emit_start),
    .accepted_count(cmp_accepted_count), .accepted_tokens(cmp_accepted_tokens),
    .current_position(seed_position_r), .current_prefix_len(committed_prefix_len_r),
    .token_out_valid(emit_token_valid), .token_out_id(emit_token_id),
    .emit_done(emit_done), .new_seed_token(emit_new_seed),
    .new_position(emit_new_position), .new_prefix_len(emit_new_prefix_len),
    .tokens_emitted(emit_tokens_emitted)
);

assign token_out_valid = emit_token_valid || fallback_token_valid_r;
assign token_out_id = fallback_token_valid_r ? fallback_token_id_r : emit_token_id;

// =========================================================================
// Main State Machine
// =========================================================================
assign tb_start = (state_r == ST_BUILD) && !tb_busy && !tb_done;
assign tb_hht_done = (state_r != ST_BUILD);

logic hht_feedback_valid;
assign hht_feedback_valid = emit_token_valid;
assign hht_accept_valid = warmup_accept_valid || hht_feedback_valid;
assign hht_accept_parent_node_id = warmup_accept_valid ? warmup_accept_parent_node_id : '0;
assign hht_accept_token_id = warmup_accept_valid ? warmup_accept_token_id : emit_token_id;
assign hht_accept_position = warmup_accept_valid ? warmup_accept_position : seed_position_r;

reg verify_started_r;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state_r <= ST_IDLE;
        gen_count_r <= 8'd0;
        max_gen_r <= 8'd0;
        seed_node_id_r <= '0;
        seed_token_id_r <= '0;
        seed_position_r <= '0;
        committed_prefix_len_r <= 16'd0;
        done <= 1'b0;
        busy <= 1'b0;
        cmp_start <= 1'b0;
        emit_start <= 1'b0;
        verify_started_r <= 1'b0;
        fallback_token_valid_r <= 1'b0;
        fallback_token_id_r <= '0;
    end else begin
        done <= 1'b0;
        cmp_start <= 1'b0;
        emit_start <= 1'b0;
        fallback_token_valid_r <= 1'b0;

        case (state_r)
        ST_IDLE: begin
            if (start) begin
                state_r <= ST_PREDICT;
                busy <= 1'b1;
                max_gen_r <= max_gen_tokens;
                gen_count_r <= 8'd0;
                seed_token_id_r <= prompt_token_id;
                seed_node_id_r <= '0;
                seed_position_r <= '0;
                committed_prefix_len_r <= 16'd0;
            end
        end
        ST_PREDICT: begin
            state_r <= ST_BUILD;
            verify_started_r <= 1'b0;
        end
        ST_BUILD: begin
            if (tb_done) begin
                if (|tb_branch_valid) state_r <= ST_VERIFY;
                else state_r <= ST_FALLBACK;
            end
        end
        ST_FALLBACK: state_r <= ST_FB_WAIT;
        ST_FB_WAIT: begin
            if (lc_done_w[0]) begin
                fallback_token_valid_r <= 1'b1;
                fallback_token_id_r <= lc_out_token_id_w[0 +: `TOKEN_ID_W];
                gen_count_r <= gen_count_r + 8'd1;
                seed_token_id_r <= lc_out_token_id_w[0 +: `TOKEN_ID_W];
                seed_position_r <= seed_position_r + {{(`POSITION_ID_W-1){1'b0}}, 1'b1};
                kv_commit_old_prefix_r <= committed_prefix_len_r;
                kv_commit_count_r <= 4'd1;
                committed_prefix_len_r <= committed_prefix_len_r + 16'd1;
                state_r <= ST_KV_COMMIT;
                // synthesis translate_off
                $display("[FINAL_TOP] FALLBACK: token=%0d", lc_out_token_id_w[0 +: `TOKEN_ID_W]);
                // synthesis translate_on
            end
        end
        ST_VERIFY: begin
            if (!verify_started_r) verify_started_r <= 1'b1;
            if (sched_all_done) begin
                cmp_start <= 1'b1;
                state_r <= ST_COMPARE;
            end
        end
        ST_COMPARE: begin
            if (cmp_result_valid) begin
                emit_start <= 1'b1;
                state_r <= ST_EMIT;
            end
        end
        ST_EMIT: begin
            if (emit_done) begin
                seed_token_id_r <= emit_new_seed;
                seed_position_r <= emit_new_position;
                kv_commit_old_prefix_r <= committed_prefix_len_r;
                kv_commit_count_r <= emit_tokens_emitted;
                committed_prefix_len_r <= emit_new_prefix_len;
                gen_count_r <= gen_count_r + {4'd0, emit_tokens_emitted};
                state_r <= ST_KV_COMMIT;
                // synthesis translate_off
                $display("[FINAL_TOP] round done: emitted %0d tokens, new_seed=%0d pos=%0d",
                    emit_tokens_emitted, emit_new_seed, emit_new_position);
                // synthesis translate_on
            end
        end
        ST_KV_COMMIT: begin
            // KV copy is done in a separate always block (see below)
            state_r <= ST_CHECK;
        end
        ST_CHECK: begin
            if (gen_count_r >= max_gen_r) state_r <= ST_DONE;
            else state_r <= ST_PREDICT;
        end
        ST_DONE: begin
            done <= 1'b1;
            busy <= 1'b0;
            state_r <= ST_IDLE;
        end
        default: state_r <= ST_IDLE;
        endcase
    end
end

assign sched_start = (state_r == ST_VERIFY) && !verify_started_r;

endmodule
