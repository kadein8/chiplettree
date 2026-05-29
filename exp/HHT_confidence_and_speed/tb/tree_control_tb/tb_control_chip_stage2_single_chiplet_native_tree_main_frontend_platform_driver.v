`timescale 1ns/1ps

`include "config/prediction_params.vh"
`include "config/interface_params.vh"
`include "config/memory_params.vh"

module tb_control_chip_stage2_single_chiplet_native_tree_main_frontend_platform_driver;

// Strict tree-mask artifacts/events required by host strict collect:
// rtl_step2_branch0_level0_final_hidden.memh
// rtl_step2_branch3_level3_token.txt
// rtl_capture_local0_final_hidden.memh
// rtl_capture_local0_token.txt
// "verify_group_capture"
// "verify_group_issue"
// "verify_group_done"
// "accepted_token"
// "accepted_prefix"
// "bonus_token"
// "lifecycle_commit"
// "lifecycle_flush"
// "token_flush"
// "flush_reclaim"

localparam integer DRAFT_PORTS = 4;
localparam integer CONF_W = 8;
localparam integer CFG_W = 32;
localparam integer RESULT_STATUS_W = 2;
localparam integer WINDOW_SLOTS = `TREE_FRONTIER_SLOTS;
localparam integer SOURCE_ID_W =
    ((DRAFT_PORTS + 1) <= 2) ? 1 : $clog2(DRAFT_PORTS + 1);
localparam integer STIMULUS_FRONTIER_LEVELS = 6;
localparam integer STIMULUS_VISIBLE_MASK_W = 8;
localparam integer STIMULUS_BITS =
    1 + CFG_W + 1 + 1 + 1 + 1 +
    DRAFT_PORTS * (1 + `NODE_ID_W + `TOKEN_ID_W + `TOKEN_ID_W +
                   `POSITION_ID_W + CONF_W) +
    (1 + 1 + 1 + `REQ_ID_W + `SRAM_WDATA_W + 1) +
    (1 + `REQ_ID_W + `HBM_DATA_W) +
    (1 + `REQ_ID_W + `TREE_MAX_PREFIX_NODES + `POSITION_ID_W + 5 +
     (`BRANCH_ID_W + 1) +
     (`TREE_MAX_PREFIX_NODES * `NODE_ID_W) +
     (`TREE_MAX_PREFIX_NODES * `TOKEN_ID_W) +
     (`TREE_MAX_PREFIX_NODES * `POSITION_ID_W) +
     STIMULUS_FRONTIER_LEVELS +
     (STIMULUS_FRONTIER_LEVELS * `TREE_FRONTIER_SLOTS) +
     (STIMULUS_FRONTIER_LEVELS * `TREE_FRONTIER_SLOTS) +
     (STIMULUS_FRONTIER_LEVELS * `TREE_FRONTIER_SLOTS * `NODE_ID_W) +
     (STIMULUS_FRONTIER_LEVELS * `TREE_FRONTIER_SLOTS * `NODE_ID_W) +
     (STIMULUS_FRONTIER_LEVELS * `TREE_FRONTIER_SLOTS * `TOKEN_ID_W) +
     (STIMULUS_FRONTIER_LEVELS * `TREE_FRONTIER_SLOTS * `TOKEN_ID_W) +
     (STIMULUS_FRONTIER_LEVELS * `TREE_FRONTIER_SLOTS * `POSITION_ID_W) +
     (STIMULUS_FRONTIER_LEVELS * `TREE_FRONTIER_SLOTS * `POSITION_ID_W) +
     (STIMULUS_FRONTIER_LEVELS * `TREE_FRONTIER_SLOTS * `BRANCH_ID_W) +
     (STIMULUS_FRONTIER_LEVELS * `TREE_FRONTIER_SLOTS * `TREE_LEVEL_ID_W)) +
    STIMULUS_VISIBLE_MASK_W;
localparam integer STIMULUS_DEPTH = 256;
localparam integer DEFAULT_MAX_POST_STIMULUS_CYCLES = 2000000;
localparam [`POSITION_ID_W-1:0] CURRENT_POSITION = 12'h040;
localparam [`POSITION_ID_W-1:0] RECENCY_TH = 12'h010;
localparam integer TOY_MODEL_SRAM_PRELOAD_DEPTH = 65536;
localparam integer TOY_MODEL_HBM_MEM_DEPTH = 65536;
localparam integer FP16_ELEMS_PER_SRAM_BEAT = (`SRAM_WDATA_W / `FP16_TILE_DATA_W);
localparam integer FP16_HBM_TO_SRAM_RATIO = (`HBM_DATA_W / `SRAM_WDATA_W);
localparam integer FP16_HIDDEN_BEATS =
    (`TOY_DMODEL / FP16_ELEMS_PER_SRAM_BEAT);
localparam integer FP16_WEIGHT_BEATS_PER_TILE =
    (`FP16_TILE_LANES * `FP16_TILE_COLS) / FP16_ELEMS_PER_SRAM_BEAT;
localparam integer PRELOAD_PROGRESS_STRIDE = 256;
localparam integer TREE_PARALLEL_BATCH_WAIT_HEARTBEAT_CYCLES = 4096;
localparam integer FP16_PROJ_MATRIX_BEATS =
    ((`TOY_DMODEL + `FP16_TILE_LANES - 1) / `FP16_TILE_LANES) *
    ((`TOY_DMODEL + `FP16_TILE_COLS - 1) / `FP16_TILE_COLS) *
    FP16_WEIGHT_BEATS_PER_TILE;
localparam integer FP16_FFN_EXPAND_MATRIX_BEATS =
    ((`TOY_INTERMEDIATE_DIM + `FP16_TILE_LANES - 1) / `FP16_TILE_LANES) *
    ((`TOY_DMODEL + `FP16_TILE_COLS - 1) / `FP16_TILE_COLS) *
    FP16_WEIGHT_BEATS_PER_TILE;
localparam integer FP16_FFN_DOWN_MATRIX_BEATS =
    ((`TOY_DMODEL + `FP16_TILE_LANES - 1) / `FP16_TILE_LANES) *
    ((`TOY_INTERMEDIATE_DIM + `FP16_TILE_COLS - 1) / `FP16_TILE_COLS) *
    FP16_WEIGHT_BEATS_PER_TILE;
localparam integer FP16_REQUIRED_WEIGHT_SLOT_BEATS =
    (FP16_PROJ_MATRIX_BEATS > FP16_FFN_EXPAND_MATRIX_BEATS) ?
        ((FP16_PROJ_MATRIX_BEATS > FP16_FFN_DOWN_MATRIX_BEATS) ?
            FP16_PROJ_MATRIX_BEATS : FP16_FFN_DOWN_MATRIX_BEATS) :
        ((FP16_FFN_EXPAND_MATRIX_BEATS > FP16_FFN_DOWN_MATRIX_BEATS) ?
            FP16_FFN_EXPAND_MATRIX_BEATS : FP16_FFN_DOWN_MATRIX_BEATS);
localparam integer FP16_WEIGHT_WINDOW_BEATS =
    FP16_REQUIRED_WEIGHT_SLOT_BEATS * 8;
localparam integer FP16_LAYER_WEIGHT_STRIDE =
    ((2 * FP16_HIDDEN_BEATS) + FP16_WEIGHT_WINDOW_BEATS) /
    FP16_HBM_TO_SRAM_RATIO;
localparam [`SRAM_ADDR_W-1:0] TOY_MODEL_EMB_BASE = 23'd256;
localparam [`HBM_ADDR_W-1:0] FP16_HBM_WEIGHT_BASE = 32'd1024;
localparam [`SRAM_ADDR_W-1:0] FP16_HBM_MAPPED_SRAM_BASE = 23'd131072;
localparam [`SRAM_ADDR_W-1:0] FP16_WORK_FINAL_BASE = 23'd8192;
localparam integer STRICT_CAPTURE_MAX = 8;
localparam integer TREE_PARALLEL_CAPTURE_SLOTS = `VERIFY_WINDOW_SIZE;

reg clk;
reg rst_n;

reg cfg_valid;
reg [CFG_W-1:0] cfg_data;
reg start;
wire busy;
wire error_flag;

reg hht_cand_valid;
wire hht_cand_ready;
reg [`NODE_ID_W-1:0] hht_parent_node_id;
reg [`TOKEN_ID_W-1:0] hht_token_id;
reg [`TOKEN_ID_W-1:0] hht_referenced_token_id;
reg [`POSITION_ID_W-1:0] hht_referenced_position;
reg [CONF_W-1:0] hht_confidence;

reg [DRAFT_PORTS-1:0] draft_cand_valid;
wire [DRAFT_PORTS-1:0] draft_cand_ready;
reg [DRAFT_PORTS*`NODE_ID_W-1:0] draft_parent_node_id;
reg [DRAFT_PORTS*`TOKEN_ID_W-1:0] draft_token_id;
reg [DRAFT_PORTS*`TOKEN_ID_W-1:0] draft_referenced_token_id;
reg [DRAFT_PORTS*`POSITION_ID_W-1:0] draft_referenced_position;
reg [DRAFT_PORTS*CONF_W-1:0] draft_confidence;

wire tree_window_valid;
reg tree_window_ready;
wire [`NODE_ID_W-1:0] tree_window_parent_node_id;
wire [WINDOW_SLOTS-1:0] tree_window_slot_valid;
wire [WINDOW_SLOTS*SOURCE_ID_W-1:0] tree_window_source_id;
wire [WINDOW_SLOTS*`TOKEN_ID_W-1:0] tree_window_token_id;
wire [WINDOW_SLOTS*`TOKEN_ID_W-1:0] tree_window_referenced_token_id;
wire [WINDOW_SLOTS*`POSITION_ID_W-1:0] tree_window_referenced_position;
wire [WINDOW_SLOTS*CONF_W-1:0] tree_window_confidence;

reg native_tree_req_valid;
wire native_tree_req_ready;
reg [`REQ_ID_W-1:0] native_tree_req_id;
reg [`TREE_MAX_PREFIX_NODES-1:0] native_tree_src_prefix_slot_valid;
reg [`TREE_MAX_PREFIX_NODES*`NODE_ID_W-1:0] native_tree_src_prefix_node_id;
reg [`TREE_MAX_PREFIX_NODES*`TOKEN_ID_W-1:0] native_tree_src_prefix_token_id;
reg [`TREE_MAX_PREFIX_NODES*`POSITION_ID_W-1:0] native_tree_src_prefix_position_id;
reg [`POSITION_ID_W-1:0] native_tree_src_committed_len;
reg [`TREE_MAX_FRONTIER_LEVELS-1:0] native_tree_src_frontier_level_valid;
reg [`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS-1:0]
    native_tree_src_frontier_slot_valid;
reg [`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0]
    native_tree_src_frontier_node_id;
reg [`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0]
    native_tree_src_frontier_parent_node_id;
reg [`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`TOKEN_ID_W-1:0]
    native_tree_src_frontier_token_id;
reg [`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`TOKEN_ID_W-1:0]
    native_tree_src_frontier_referenced_token_id;
reg [`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`POSITION_ID_W-1:0]
    native_tree_src_frontier_position_id;
reg [`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`POSITION_ID_W-1:0]
    native_tree_src_frontier_referenced_position_id;
reg [`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`BRANCH_ID_W-1:0]
    native_tree_src_frontier_branch_id;
reg [`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`TREE_LEVEL_ID_W-1:0]
    native_tree_src_frontier_level_id;
reg [`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS-1:0]
    native_tree_src_frontier_tree_mask_en;

wire recompute_req_valid;
reg recompute_req_ready;
wire [`TOKEN_ID_W-1:0] recompute_req_token_id;
wire [`POSITION_ID_W-1:0] recompute_req_current_position;
wire [`POSITION_ID_W-1:0] recompute_req_referenced_position;
wire [`BRANCH_ID_W-1:0] recompute_req_branch_id;
wire recompute_req_reason_stale;

reg recompute_resp_valid;
wire recompute_resp_ready;
reg recompute_resp_partial;
reg recompute_resp_full;
reg [`REQ_ID_W-1:0] recompute_resp_req_id;
reg [`SRAM_WDATA_W-1:0] recompute_resp_kv_data;
reg recompute_resp_last;

reg kv_lookup_valid;
reg [`TOKEN_ID_W-1:0] kv_lookup_token_id;
reg [`POSITION_ID_W-1:0] kv_lookup_position_id;
wire kv_lookup_ready;
wire kv_lookup_hit;
wire kv_lookup_partial_ready;
wire kv_lookup_full_ready;
wire [`SRAM_ID_W-1:0] kv_lookup_sram_id;
wire [`BANK_ID_W-1:0] kv_lookup_bank_id;
wire [`SUBBANK_ID_W-1:0] kv_lookup_subbank_start;
wire [`KV_GROUP_LEN_W-1:0] kv_lookup_group_len;

wire wb_valid;
reg wb_ready;
wire [`TOKEN_ID_W-1:0] wb_token_id;
wire [`SRAM_ADDR_W-1:0] wb_addr;
wire [`SRAM_WDATA_W-1:0] wb_data;
wire [RESULT_STATUS_W-1:0] wb_status;
wire wb_done;
wire wb_error;

wire debug_stale_hit;
wire debug_recompute_busy;
wire debug_recompute_done;
wire debug_decoder_qkv_valid;
wire debug_decoder_score_valid;
wire debug_decoder_softmax_valid;
wire debug_decoder_value_valid;
wire debug_decoder_ffn_valid;

reg hbm_resp_valid;
reg [`HBM_DATA_W-1:0] hbm_resp_rdata;
reg [`REQ_ID_W-1:0] hbm_resp_id;
wire hbm_req_valid;
wire hbm_req_write;
wire [`HBM_ADDR_W-1:0] hbm_req_addr;
wire [`HBM_DATA_W-1:0] hbm_req_wdata;
wire [`REQ_ID_W-1:0] hbm_req_id;
reg hbm_auto_resp_pending_r;
reg [`HBM_DATA_W-1:0] hbm_auto_resp_rdata_r;
reg [`REQ_ID_W-1:0] hbm_auto_resp_id_r;

reg [STIMULUS_BITS-1:0] stimulus_mem [0:STIMULUS_DEPTH-1];
reg [4095:0] stimulus_memh_path;
reg [4095:0] events_jsonl_path;
reg [4095:0] toy_model_memh_dir_path;
reg [4095:0] preload_memh_path_r;
reg [4095:0] hbm_memh_path_r;
reg [4095:0] token_path_r;
reg [`SRAM_WDATA_W-1:0]
    toy_model_sram_preload_mem [0:TOY_MODEL_SRAM_PRELOAD_DEPTH-1];
reg [`HBM_DATA_W-1:0]
    toy_model_hbm_mem [0:TOY_MODEL_HBM_MEM_DEPTH-1];
integer event_fd;
integer stimulus_cycles;
integer max_post_stimulus_cycles;
integer cycle_count_r;
integer drive_index_r;
integer drain_count_r;
integer preload_sram_idx_i;
integer preload_hbm_idx_i;
integer toy_model_fd_i;
reg cfg_start_seen_r;
reg wb_done_seen_r;
reg hbm_write_seen_r;
integer strict_capture_index_base_r;
integer strict_capture_index_r;
integer strict_branch_slot_r;
integer strict_hidden_fd_i;
integer strict_token_fd_i;
reg [2:0] tree_parallel_dispatcher_state_prev_r;
reg [4:0] tree_parallel_batch_top_state_prev_r;
reg [4:0] tree_parallel_tree_attn_state_prev_r;
reg [4:0] tree_parallel_seed_mha_state_prev_r;
reg [4:0] tree_parallel_draft0_state_prev_r;
reg [4:0] tree_parallel_draft15_state_prev_r;
integer tree_parallel_batch_wait_heartbeat_cycle_r;
reg strict_capture_active_r;
reg [`TOKEN_ID_W-1:0] strict_capture_query_token_r;
reg [`BRANCH_ID_W-1:0] strict_capture_branch_id_r;
reg strict_capture_tree_mask_en_r;
reg tree_parallel_strict_capture_valid_r;
reg [`SRAM_WDATA_W-1:0] strict_final_hidden_shadow [0:FP16_HIDDEN_BEATS-1];
reg [`SRAM_WDATA_W-1:0] strict_final_hidden_sram_shadow [0:FP16_HIDDEN_BEATS-1];
reg [`SRAM_WDATA_W-1:0]
    tree_parallel_final_hidden_shadow
        [0:TREE_PARALLEL_CAPTURE_SLOTS-1][0:FP16_HIDDEN_BEATS-1];
reg [`SRAM_WDATA_W-1:0]
    tree_parallel_final_hidden_sram_shadow
        [0:TREE_PARALLEL_CAPTURE_SLOTS-1][0:FP16_HIDDEN_BEATS-1];
reg [`SRAM_ADDR_W-1:0] forced_mem_req_addr_shadow_r;
reg [`SRAM_WDATA_W-1:0] forced_mem_req_wdata_shadow_r;
reg [511:0] strict_hidden_path_r;
reg [511:0] strict_token_path_r;
integer strict_dump_idx_i;
integer tree_parallel_shadow_slot_i;
integer tree_parallel_shadow_beat_i;
integer mem_shadow_lane_i;
integer tree_parallel_lane_i;
integer mem_final_slot_idx_i;
integer mem_final_hidden_idx_i;
reg [`SRAM_ADDR_W-1:0] mem_shadow_addr_i;
reg [`SRAM_WDATA_W-1:0] mem_shadow_data_i;
reg fp16_embedding_resp_logged_r;
reg fp16_pre_norm_write_logged_r;
reg fp16_mha_out_write_logged_r;
reg fp16_res1_write_logged_r;
reg fp16_post_norm_write_logged_r;
reg fp16_ffn_out_write_logged_r;
reg fp16_res2_write_logged_r;
reg fp16_layer_result_write_logged_r;
reg fp16_final_norm_x_read_logged_r;
reg fp16_final_norm_gamma_read_logged_r;
reg fp16_final_hidden_write_logged_r;
reg fp16_lm_hidden_read_logged_r;
reg fp16_lm_weight_read_logged_r;

control_chip_stage2_single_chiplet #(
    .CFG_W(CFG_W),
    .DRAFT_PORTS(DRAFT_PORTS),
    .CONF_W(CONF_W),
    .RESULT_STATUS_W(RESULT_STATUS_W),
    .ENABLE_TREE_WINDOW_CONSUMER(0),
    .ENABLE_NATIVE_TREE_MAIN_FRONTEND(1),
    .ENABLE_NATIVE_TREE_SIDECAR(0),
    .ENABLE_TOP_HBM_WRITEBACK_SHIM(1),
    .ENABLE_ONCHIP_HHT_CONTEXT(1),
    .USE_FP16_INFERENCE_TOP(1),
    .CURRENT_POSITION(CURRENT_POSITION),
    .RECENCY_TH(RECENCY_TH),
    .ISSUE_SRC_ADDR(TOY_MODEL_EMB_BASE)
) u_control_chip_stage2_single_chiplet (
    .clk(clk),
    .rst_n(rst_n),
    .cfg_valid(cfg_valid),
    .cfg_data(cfg_data),
    .start(start),
    .busy(busy),
    .error_flag(error_flag),
    .hht_cand_valid(hht_cand_valid),
    .hht_cand_ready(hht_cand_ready),
    .hht_parent_node_id(hht_parent_node_id),
    .hht_token_id(hht_token_id),
    .hht_referenced_token_id(hht_referenced_token_id),
    .hht_referenced_position(hht_referenced_position),
    .hht_confidence(hht_confidence),
    .draft_cand_valid(draft_cand_valid),
    .draft_cand_ready(draft_cand_ready),
    .draft_parent_node_id(draft_parent_node_id),
    .draft_token_id(draft_token_id),
    .draft_referenced_token_id(draft_referenced_token_id),
    .draft_referenced_position(draft_referenced_position),
    .draft_confidence(draft_confidence),
    .tree_window_valid(tree_window_valid),
    .tree_window_ready(tree_window_ready),
    .tree_window_parent_node_id(tree_window_parent_node_id),
    .tree_window_slot_valid(tree_window_slot_valid),
    .tree_window_source_id(tree_window_source_id),
    .tree_window_token_id(tree_window_token_id),
    .tree_window_referenced_token_id(tree_window_referenced_token_id),
    .tree_window_referenced_position(tree_window_referenced_position),
    .tree_window_confidence(tree_window_confidence),
    .native_tree_req_valid(native_tree_req_valid),
    .native_tree_req_ready(native_tree_req_ready),
    .native_tree_req_id(native_tree_req_id),
    .native_tree_src_prefix_slot_valid(native_tree_src_prefix_slot_valid),
    .native_tree_src_prefix_node_id(native_tree_src_prefix_node_id),
    .native_tree_src_prefix_token_id(native_tree_src_prefix_token_id),
    .native_tree_src_prefix_position_id(native_tree_src_prefix_position_id),
    .native_tree_src_committed_len(native_tree_src_committed_len),
    .native_tree_src_frontier_level_valid(native_tree_src_frontier_level_valid),
    .native_tree_src_frontier_slot_valid(native_tree_src_frontier_slot_valid),
    .native_tree_src_frontier_node_id(native_tree_src_frontier_node_id),
    .native_tree_src_frontier_parent_node_id(
        native_tree_src_frontier_parent_node_id),
    .native_tree_src_frontier_token_id(native_tree_src_frontier_token_id),
    .native_tree_src_frontier_referenced_token_id(
        native_tree_src_frontier_referenced_token_id),
    .native_tree_src_frontier_position_id(native_tree_src_frontier_position_id),
    .native_tree_src_frontier_referenced_position_id(
        native_tree_src_frontier_referenced_position_id),
    .native_tree_src_frontier_branch_id(
        native_tree_src_frontier_branch_id),
    .native_tree_src_frontier_level_id(
        native_tree_src_frontier_level_id),
    .native_tree_src_frontier_tree_mask_en(
        native_tree_src_frontier_tree_mask_en),
    .recompute_req_valid(recompute_req_valid),
    .recompute_req_ready(recompute_req_ready),
    .recompute_req_token_id(recompute_req_token_id),
    .recompute_req_current_position(recompute_req_current_position),
    .recompute_req_referenced_position(recompute_req_referenced_position),
    .recompute_req_branch_id(recompute_req_branch_id),
    .recompute_req_reason_stale(recompute_req_reason_stale),
    .recompute_resp_valid(recompute_resp_valid),
    .recompute_resp_ready(recompute_resp_ready),
    .recompute_resp_partial(recompute_resp_partial),
    .recompute_resp_full(recompute_resp_full),
    .recompute_resp_req_id(recompute_resp_req_id),
    .recompute_resp_kv_data(recompute_resp_kv_data),
    .recompute_resp_last(recompute_resp_last),
    .kv_lookup_valid(kv_lookup_valid),
    .kv_lookup_token_id(kv_lookup_token_id),
    .kv_lookup_position_id(kv_lookup_position_id),
    .kv_lookup_ready(kv_lookup_ready),
    .kv_lookup_hit(kv_lookup_hit),
    .kv_lookup_partial_ready(kv_lookup_partial_ready),
    .kv_lookup_full_ready(kv_lookup_full_ready),
    .kv_lookup_sram_id(kv_lookup_sram_id),
    .kv_lookup_bank_id(kv_lookup_bank_id),
    .kv_lookup_subbank_start(kv_lookup_subbank_start),
    .kv_lookup_group_len(kv_lookup_group_len),
    .wb_valid(wb_valid),
    .wb_ready(wb_ready),
    .wb_token_id(wb_token_id),
    .wb_addr(wb_addr),
    .wb_data(wb_data),
    .wb_status(wb_status),
    .wb_done(wb_done),
    .wb_error(wb_error),
    .debug_stale_hit(debug_stale_hit),
    .debug_recompute_busy(debug_recompute_busy),
    .debug_recompute_done(debug_recompute_done),
    .debug_decoder_qkv_valid(debug_decoder_qkv_valid),
    .debug_decoder_score_valid(debug_decoder_score_valid),
    .debug_decoder_softmax_valid(debug_decoder_softmax_valid),
    .debug_decoder_value_valid(debug_decoder_value_valid),
    .debug_decoder_ffn_valid(debug_decoder_ffn_valid),
    .hbm_resp_valid(hbm_resp_valid),
    .hbm_resp_rdata(hbm_resp_rdata),
    .hbm_resp_id(hbm_resp_id),
    .hbm_req_valid(hbm_req_valid),
    .hbm_req_write(hbm_req_write),
    .hbm_req_addr(hbm_req_addr),
    .hbm_req_wdata(hbm_req_wdata),
    .hbm_req_id(hbm_req_id)
);

always #5 clk = ~clk;

task clear_driven_inputs;
begin
    cfg_valid = 1'b0;
    cfg_data = {CFG_W{1'b0}};
    start = 1'b0;
    hht_cand_valid = 1'b0;
    hht_parent_node_id = {`NODE_ID_W{1'b0}};
    hht_token_id = {`TOKEN_ID_W{1'b0}};
    hht_referenced_token_id = {`TOKEN_ID_W{1'b0}};
    hht_referenced_position = {`POSITION_ID_W{1'b0}};
    hht_confidence = {CONF_W{1'b0}};
    draft_cand_valid = {DRAFT_PORTS{1'b0}};
    draft_parent_node_id = {(DRAFT_PORTS*`NODE_ID_W){1'b0}};
    draft_token_id = {(DRAFT_PORTS*`TOKEN_ID_W){1'b0}};
    draft_referenced_token_id = {(DRAFT_PORTS*`TOKEN_ID_W){1'b0}};
    draft_referenced_position = {(DRAFT_PORTS*`POSITION_ID_W){1'b0}};
    draft_confidence = {(DRAFT_PORTS*CONF_W){1'b0}};
    native_tree_req_valid = 1'b0;
    native_tree_req_id = {`REQ_ID_W{1'b0}};
    native_tree_src_prefix_slot_valid = {`TREE_MAX_PREFIX_NODES{1'b0}};
    native_tree_src_prefix_node_id =
        {(`TREE_MAX_PREFIX_NODES*`NODE_ID_W){1'b0}};
    native_tree_src_prefix_token_id =
        {(`TREE_MAX_PREFIX_NODES*`TOKEN_ID_W){1'b0}};
    native_tree_src_prefix_position_id =
        {(`TREE_MAX_PREFIX_NODES*`POSITION_ID_W){1'b0}};
    native_tree_src_committed_len = {`POSITION_ID_W{1'b0}};
    native_tree_src_frontier_level_valid =
        {`TREE_MAX_FRONTIER_LEVELS{1'b0}};
    native_tree_src_frontier_slot_valid =
        {(`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS){1'b0}};
    native_tree_src_frontier_node_id =
        {(`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`NODE_ID_W){1'b0}};
    native_tree_src_frontier_parent_node_id =
        {(`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`NODE_ID_W){1'b0}};
    native_tree_src_frontier_token_id =
        {(`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`TOKEN_ID_W){1'b0}};
    native_tree_src_frontier_referenced_token_id =
        {(`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`TOKEN_ID_W){1'b0}};
    native_tree_src_frontier_position_id =
        {(`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`POSITION_ID_W){1'b0}};
    native_tree_src_frontier_referenced_position_id =
        {(`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`POSITION_ID_W){1'b0}};
    native_tree_src_frontier_branch_id =
        {(`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`BRANCH_ID_W){1'b0}};
    native_tree_src_frontier_level_id =
        {(`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`TREE_LEVEL_ID_W){1'b0}};
    native_tree_src_frontier_tree_mask_en =
        {(`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS){1'b0}};
    tree_window_ready = 1'b0;
    recompute_req_ready = 1'b0;
    recompute_resp_valid = 1'b0;
    recompute_resp_partial = 1'b0;
    recompute_resp_full = 1'b0;
    recompute_resp_req_id = {`REQ_ID_W{1'b0}};
    recompute_resp_kv_data = {`SRAM_WDATA_W{1'b0}};
    recompute_resp_last = 1'b0;
    kv_lookup_valid = 1'b0;
    kv_lookup_token_id = {`TOKEN_ID_W{1'b0}};
    kv_lookup_position_id = {`POSITION_ID_W{1'b0}};
    wb_ready = 1'b0;
    hbm_resp_valid = 1'b0;
    hbm_resp_rdata = {`HBM_DATA_W{1'b0}};
    hbm_resp_id = {`REQ_ID_W{1'b0}};
end
endtask

task automatic drive_auto_hbm_response;
begin
    if (hbm_resp_valid) begin
        hbm_auto_resp_pending_r = 1'b0;
    end else if (hbm_auto_resp_pending_r) begin
        hbm_resp_valid = 1'b1;
        hbm_resp_rdata = hbm_auto_resp_rdata_r;
        hbm_resp_id = hbm_auto_resp_id_r;
        hbm_auto_resp_pending_r = 1'b0;
    end

    if (!hbm_resp_valid && hbm_req_valid && !hbm_req_write) begin
        hbm_auto_resp_pending_r = 1'b1;
        hbm_auto_resp_id_r = hbm_req_id;
        if (hbm_req_addr < TOY_MODEL_HBM_MEM_DEPTH)
            hbm_auto_resp_rdata_r = toy_model_hbm_mem[hbm_req_addr];
        else
            hbm_auto_resp_rdata_r = {`HBM_DATA_W{1'b0}};
    end
end
endtask

task automatic apply_stimulus_word(input [STIMULUS_BITS-1:0] word);
    integer offset;
    integer port_idx;
    integer level_idx;
begin
    clear_driven_inputs();
    offset = 0;

    cfg_valid = word[offset +: 1];
    offset = offset + 1;
    cfg_data = word[offset +: CFG_W];
    offset = offset + CFG_W;
    start = word[offset +: 1];
    offset = offset + 1;
    tree_window_ready = word[offset +: 1];
    offset = offset + 1;
    recompute_req_ready = word[offset +: 1];
    offset = offset + 1;
    wb_ready = word[offset +: 1];
    offset = offset + 1;

    for (port_idx = 0; port_idx < DRAFT_PORTS; port_idx = port_idx + 1) begin
        draft_cand_valid[port_idx] = word[offset +: 1];
        offset = offset + 1;
    end
    for (port_idx = 0; port_idx < DRAFT_PORTS; port_idx = port_idx + 1) begin
        draft_parent_node_id[(port_idx*`NODE_ID_W) +: `NODE_ID_W] =
            word[offset +: `NODE_ID_W];
        offset = offset + `NODE_ID_W;
    end
    for (port_idx = 0; port_idx < DRAFT_PORTS; port_idx = port_idx + 1) begin
        draft_token_id[(port_idx*`TOKEN_ID_W) +: `TOKEN_ID_W] =
            word[offset +: `TOKEN_ID_W];
        offset = offset + `TOKEN_ID_W;
    end
    for (port_idx = 0; port_idx < DRAFT_PORTS; port_idx = port_idx + 1) begin
        draft_referenced_token_id[(port_idx*`TOKEN_ID_W) +: `TOKEN_ID_W] =
            word[offset +: `TOKEN_ID_W];
        offset = offset + `TOKEN_ID_W;
    end
    for (port_idx = 0; port_idx < DRAFT_PORTS; port_idx = port_idx + 1) begin
        draft_referenced_position[(port_idx*`POSITION_ID_W) +:
                                  `POSITION_ID_W] =
            word[offset +: `POSITION_ID_W];
        offset = offset + `POSITION_ID_W;
    end
    for (port_idx = 0; port_idx < DRAFT_PORTS; port_idx = port_idx + 1) begin
        draft_confidence[(port_idx*CONF_W) +: CONF_W] =
            word[offset +: CONF_W];
        offset = offset + CONF_W;
    end

    recompute_resp_valid = word[offset +: 1];
    offset = offset + 1;
    recompute_resp_partial = word[offset +: 1];
    offset = offset + 1;
    recompute_resp_full = word[offset +: 1];
    offset = offset + 1;
    recompute_resp_req_id = word[offset +: `REQ_ID_W];
    offset = offset + `REQ_ID_W;
    recompute_resp_kv_data = word[offset +: `SRAM_WDATA_W];
    offset = offset + `SRAM_WDATA_W;
    recompute_resp_last = word[offset +: 1];
    offset = offset + 1;

    hbm_resp_valid = word[offset +: 1];
    offset = offset + 1;
    hbm_resp_id = word[offset +: `REQ_ID_W];
    offset = offset + `REQ_ID_W;
    hbm_resp_rdata = word[offset +: `HBM_DATA_W];
    offset = offset + `HBM_DATA_W;

    native_tree_req_valid = word[offset +: 1];
    offset = offset + 1;
    native_tree_req_id = word[offset +: `REQ_ID_W];
    offset = offset + `REQ_ID_W;
    native_tree_src_prefix_slot_valid =
        word[offset +: `TREE_MAX_PREFIX_NODES];
    offset = offset + `TREE_MAX_PREFIX_NODES;
    native_tree_src_committed_len = word[offset +: `POSITION_ID_W];
    offset = offset + `POSITION_ID_W;
    offset = offset + 5;
    offset = offset + (`BRANCH_ID_W + 1);
    for (port_idx = 0; port_idx < `TREE_MAX_PREFIX_NODES;
         port_idx = port_idx + 1) begin
        native_tree_src_prefix_node_id[(port_idx*`NODE_ID_W) +: `NODE_ID_W] =
            word[offset +: `NODE_ID_W];
        offset = offset + `NODE_ID_W;
    end
    for (port_idx = 0; port_idx < `TREE_MAX_PREFIX_NODES;
         port_idx = port_idx + 1) begin
        native_tree_src_prefix_token_id[(port_idx*`TOKEN_ID_W) +: `TOKEN_ID_W] =
            word[offset +: `TOKEN_ID_W];
        offset = offset + `TOKEN_ID_W;
    end
    for (port_idx = 0; port_idx < `TREE_MAX_PREFIX_NODES;
         port_idx = port_idx + 1) begin
        native_tree_src_prefix_position_id[
            (port_idx*`POSITION_ID_W) +: `POSITION_ID_W] =
            word[offset +: `POSITION_ID_W];
        offset = offset + `POSITION_ID_W;
    end
    native_tree_src_frontier_level_valid =
        word[offset +: `TREE_MAX_FRONTIER_LEVELS];
    offset = offset + STIMULUS_FRONTIER_LEVELS;
    for (level_idx = 0; level_idx < `TREE_MAX_FRONTIER_LEVELS;
         level_idx = level_idx + 1) begin
        native_tree_src_frontier_slot_valid[
            (level_idx*`TREE_FRONTIER_SLOTS) +: `TREE_FRONTIER_SLOTS] =
            word[offset +: `TREE_FRONTIER_SLOTS];
        offset = offset + `TREE_FRONTIER_SLOTS;
    end
    if (STIMULUS_FRONTIER_LEVELS > `TREE_MAX_FRONTIER_LEVELS)
        offset = offset +
                 ((STIMULUS_FRONTIER_LEVELS - `TREE_MAX_FRONTIER_LEVELS) *
                  `TREE_FRONTIER_SLOTS);
    for (level_idx = 0; level_idx < `TREE_MAX_FRONTIER_LEVELS;
         level_idx = level_idx + 1) begin
        native_tree_src_frontier_tree_mask_en[
            (level_idx*`TREE_FRONTIER_SLOTS) +: `TREE_FRONTIER_SLOTS] =
            word[offset +: `TREE_FRONTIER_SLOTS];
        offset = offset + `TREE_FRONTIER_SLOTS;
    end
    if (STIMULUS_FRONTIER_LEVELS > `TREE_MAX_FRONTIER_LEVELS)
        offset = offset +
                 ((STIMULUS_FRONTIER_LEVELS - `TREE_MAX_FRONTIER_LEVELS) *
                  `TREE_FRONTIER_SLOTS);
    for (level_idx = 0; level_idx < `TREE_MAX_FRONTIER_LEVELS;
         level_idx = level_idx + 1) begin
        for (port_idx = 0; port_idx < `TREE_FRONTIER_SLOTS;
             port_idx = port_idx + 1) begin
            native_tree_src_frontier_node_id[
                (((level_idx*`TREE_FRONTIER_SLOTS) + port_idx)*`NODE_ID_W) +:
                `NODE_ID_W] = word[offset +: `NODE_ID_W];
            offset = offset + `NODE_ID_W;
        end
    end
    if (STIMULUS_FRONTIER_LEVELS > `TREE_MAX_FRONTIER_LEVELS)
        offset = offset +
                 ((STIMULUS_FRONTIER_LEVELS - `TREE_MAX_FRONTIER_LEVELS) *
                  `TREE_FRONTIER_SLOTS * `NODE_ID_W);
    for (level_idx = 0; level_idx < `TREE_MAX_FRONTIER_LEVELS;
         level_idx = level_idx + 1) begin
        for (port_idx = 0; port_idx < `TREE_FRONTIER_SLOTS;
             port_idx = port_idx + 1) begin
            native_tree_src_frontier_parent_node_id[
                (((level_idx*`TREE_FRONTIER_SLOTS) + port_idx)*`NODE_ID_W) +:
                `NODE_ID_W] = word[offset +: `NODE_ID_W];
            offset = offset + `NODE_ID_W;
        end
    end
    if (STIMULUS_FRONTIER_LEVELS > `TREE_MAX_FRONTIER_LEVELS)
        offset = offset +
                 ((STIMULUS_FRONTIER_LEVELS - `TREE_MAX_FRONTIER_LEVELS) *
                  `TREE_FRONTIER_SLOTS * `NODE_ID_W);
    for (level_idx = 0; level_idx < `TREE_MAX_FRONTIER_LEVELS;
         level_idx = level_idx + 1) begin
        for (port_idx = 0; port_idx < `TREE_FRONTIER_SLOTS;
             port_idx = port_idx + 1) begin
            native_tree_src_frontier_token_id[
                (((level_idx*`TREE_FRONTIER_SLOTS) + port_idx)*`TOKEN_ID_W) +:
                `TOKEN_ID_W] = word[offset +: `TOKEN_ID_W];
            offset = offset + `TOKEN_ID_W;
        end
    end
    if (STIMULUS_FRONTIER_LEVELS > `TREE_MAX_FRONTIER_LEVELS)
        offset = offset +
                 ((STIMULUS_FRONTIER_LEVELS - `TREE_MAX_FRONTIER_LEVELS) *
                  `TREE_FRONTIER_SLOTS * `TOKEN_ID_W);
    for (level_idx = 0; level_idx < `TREE_MAX_FRONTIER_LEVELS;
         level_idx = level_idx + 1) begin
        for (port_idx = 0; port_idx < `TREE_FRONTIER_SLOTS;
             port_idx = port_idx + 1) begin
            native_tree_src_frontier_referenced_token_id[
                (((level_idx*`TREE_FRONTIER_SLOTS) + port_idx)*`TOKEN_ID_W) +:
                `TOKEN_ID_W] = word[offset +: `TOKEN_ID_W];
            offset = offset + `TOKEN_ID_W;
        end
    end
    if (STIMULUS_FRONTIER_LEVELS > `TREE_MAX_FRONTIER_LEVELS)
        offset = offset +
                 ((STIMULUS_FRONTIER_LEVELS - `TREE_MAX_FRONTIER_LEVELS) *
                  `TREE_FRONTIER_SLOTS * `TOKEN_ID_W);
    for (level_idx = 0; level_idx < `TREE_MAX_FRONTIER_LEVELS;
         level_idx = level_idx + 1) begin
        for (port_idx = 0; port_idx < `TREE_FRONTIER_SLOTS;
             port_idx = port_idx + 1) begin
            native_tree_src_frontier_position_id[
                (((level_idx*`TREE_FRONTIER_SLOTS) + port_idx)*`POSITION_ID_W) +:
                `POSITION_ID_W] = word[offset +: `POSITION_ID_W];
            offset = offset + `POSITION_ID_W;
        end
    end
    if (STIMULUS_FRONTIER_LEVELS > `TREE_MAX_FRONTIER_LEVELS)
        offset = offset +
                 ((STIMULUS_FRONTIER_LEVELS - `TREE_MAX_FRONTIER_LEVELS) *
                  `TREE_FRONTIER_SLOTS * `POSITION_ID_W);
    for (level_idx = 0; level_idx < `TREE_MAX_FRONTIER_LEVELS;
         level_idx = level_idx + 1) begin
        for (port_idx = 0; port_idx < `TREE_FRONTIER_SLOTS;
             port_idx = port_idx + 1) begin
            native_tree_src_frontier_referenced_position_id[
                (((level_idx*`TREE_FRONTIER_SLOTS) + port_idx)*`POSITION_ID_W) +:
                `POSITION_ID_W] = word[offset +: `POSITION_ID_W];
            offset = offset + `POSITION_ID_W;
        end
    end
    for (level_idx = 0; level_idx < `TREE_MAX_FRONTIER_LEVELS;
         level_idx = level_idx + 1) begin
        for (port_idx = 0; port_idx < `TREE_FRONTIER_SLOTS;
             port_idx = port_idx + 1) begin
            native_tree_src_frontier_branch_id[
                (((level_idx*`TREE_FRONTIER_SLOTS) + port_idx)*`BRANCH_ID_W) +:
                `BRANCH_ID_W] = word[offset +: `BRANCH_ID_W];
            offset = offset + `BRANCH_ID_W;
        end
    end
    for (level_idx = 0; level_idx < `TREE_MAX_FRONTIER_LEVELS;
         level_idx = level_idx + 1) begin
        for (port_idx = 0; port_idx < `TREE_FRONTIER_SLOTS;
             port_idx = port_idx + 1) begin
            native_tree_src_frontier_level_id[
                (((level_idx*`TREE_FRONTIER_SLOTS) + port_idx)*`TREE_LEVEL_ID_W) +:
                `TREE_LEVEL_ID_W] = word[offset +: `TREE_LEVEL_ID_W];
            offset = offset + `TREE_LEVEL_ID_W;
        end
    end
    offset = offset + STIMULUS_VISIBLE_MASK_W;

    if (offset != STIMULUS_BITS) begin
        $fatal(1, "29 stimulus unpack width mismatch: %0d", offset);
    end

    drive_auto_hbm_response();
end
endtask

initial begin
    if (`TREE_MAX_FRONTIER_LEVELS > STIMULUS_FRONTIER_LEVELS) begin
        $fatal(
            1,
            "29 stimulus format supports at most %0d frontier levels, RTL expects %0d",
            STIMULUS_FRONTIER_LEVELS,
            `TREE_MAX_FRONTIER_LEVELS
        );
    end
end

task write_finish_event;
begin
    $fwrite(
        event_fd,
        "{\"cycle\":%0d,\"event\":\"finish\",\"source\":\"rtl\",\"busy_final\":%0d,\"error_flag\":%0d}\n",
        cycle_count_r,
        busy,
        error_flag
    );
end
endtask

task automatic strict_capture_paths_from_index;
    input integer capture_index_i;
    input integer branch_slot_i;
    output [511:0] hidden_path_o;
    output [511:0] token_path_o;
    integer level_slot_i;
begin
    hidden_path_o = "";
    token_path_o = "";
    case (capture_index_i)
        0: begin
            hidden_path_o = "rtl_step0_final_hidden.memh";
            token_path_o = "rtl_step0_token.txt";
        end
        1: begin
            hidden_path_o = "rtl_step1_final_hidden.memh";
            token_path_o = "rtl_step1_token.txt";
        end
        2: begin
            level_slot_i = strict_capture_index_r - strict_capture_index_base_r;
            $sformat(hidden_path_o,
                     "rtl_step2_branch%0d_level%0d_final_hidden.memh",
                     branch_slot_i, level_slot_i);
            $sformat(token_path_o,
                     "rtl_step2_branch%0d_level%0d_token.txt",
                     branch_slot_i, level_slot_i);
        end
        3: begin
            hidden_path_o = "rtl_step3_final_hidden.memh";
            token_path_o = "rtl_step3_token.txt";
        end
        4: begin
            hidden_path_o = "rtl_step4_final_hidden.memh";
            token_path_o = "rtl_step4_token.txt";
        end
        default: begin
            hidden_path_o = "";
            token_path_o = "";
        end
    endcase
end
endtask

task automatic strict_capture_local_paths_from_index;
    input integer capture_index_i;
    output [511:0] hidden_path_o;
    output [511:0] token_path_o;
    integer local_capture_i;
begin
    hidden_path_o = "";
    token_path_o = "";
    local_capture_i = capture_index_i - strict_capture_index_base_r;
    if (local_capture_i >= 0) begin
        $sformat(hidden_path_o,
                 "rtl_capture_local%0d_final_hidden.memh",
                 local_capture_i);
        $sformat(token_path_o,
                 "rtl_capture_local%0d_token.txt",
                 local_capture_i);
    end
end
endtask

task automatic read_sram_storage_beat;
    input [`SRAM_ADDR_W-1:0] sram_addr_i;
    output [`SRAM_WDATA_W-1:0] sram_data_o;
    reg [`OFFSET_W-1:0] offset_v;
    reg [`ROW_ADDR_W-1:0] row_addr_v;
    reg [`SUBBANK_ID_W-1:0] subbank_id_v;
    reg [`BANK_ID_W-1:0] bank_id_v;
    reg [`SRAM_ID_W-1:0] sram_id_v;
    integer total_bank_idx_v;
    integer base_addr_v;
    integer byte_idx_v;
begin
    sram_data_o = {`SRAM_WDATA_W{1'b0}};
    offset_v = sram_addr_i[`OFFSET_W-1:0];
    row_addr_v = sram_addr_i[`OFFSET_W +: `ROW_ADDR_W];
    subbank_id_v =
        sram_addr_i[(`OFFSET_W + `ROW_ADDR_W) +: `SUBBANK_ID_W];
    bank_id_v =
        sram_addr_i[
            (`OFFSET_W + `ROW_ADDR_W + `SUBBANK_ID_W) +: `BANK_ID_W];
    sram_id_v =
        sram_addr_i[
            (`OFFSET_W + `ROW_ADDR_W + `SUBBANK_ID_W + `BANK_ID_W) +:
            `SRAM_ID_W];
    total_bank_idx_v = (sram_id_v * `SRAM_BANK_NUM) + bank_id_v;
    base_addr_v = {row_addr_v, offset_v};
    sram_data_o =
        u_control_chip_stage2_single_chiplet
            .u_sram_subsystem
            .storage_beats_debug[total_bank_idx_v][subbank_id_v]
                               [base_addr_v];
end
endtask

task automatic dump_strict_hidden_and_token;
    input integer capture_index_i;
    input integer branch_slot_i;
    input [`TOKEN_ID_W-1:0] generated_token_i;
    reg [511:0] hidden_path_v;
    reg [511:0] token_path_v;
    reg [511:0] local_hidden_path_v;
    reg [511:0] local_token_path_v;
    reg [`SRAM_WDATA_W-1:0] hidden_beat_v;
begin
    strict_capture_paths_from_index(
        capture_index_i,
        branch_slot_i,
        hidden_path_v,
        token_path_v
    );
    strict_capture_local_paths_from_index(
        capture_index_i,
        local_hidden_path_v,
        local_token_path_v
    );
    if (hidden_path_v != "") begin
        strict_hidden_fd_i = $fopen(hidden_path_v, "w");
        if (strict_hidden_fd_i == 0)
            $fatal(1, "29 failed to open %0s", hidden_path_v);
        for (strict_dump_idx_i = 0;
             strict_dump_idx_i < FP16_HIDDEN_BEATS;
             strict_dump_idx_i = strict_dump_idx_i + 1) begin
            hidden_beat_v =
                strict_final_hidden_shadow[strict_dump_idx_i];
            $fdisplay(strict_hidden_fd_i, "%032h",
                      hidden_beat_v);
        end
        $fclose(strict_hidden_fd_i);
    end
    if ((local_hidden_path_v != "") &&
        (local_hidden_path_v != hidden_path_v)) begin
        strict_hidden_fd_i = $fopen(local_hidden_path_v, "w");
        if (strict_hidden_fd_i == 0)
            $fatal(1, "29 failed to open %0s", local_hidden_path_v);
        for (strict_dump_idx_i = 0;
             strict_dump_idx_i < FP16_HIDDEN_BEATS;
             strict_dump_idx_i = strict_dump_idx_i + 1) begin
            hidden_beat_v =
                strict_final_hidden_shadow[strict_dump_idx_i];
            $fdisplay(strict_hidden_fd_i, "%032h",
                      hidden_beat_v);
        end
        $fclose(strict_hidden_fd_i);
    end
    if (token_path_v != "") begin
        strict_token_fd_i = $fopen(token_path_v, "w");
        if (strict_token_fd_i == 0)
            $fatal(1, "29 failed to open %0s", token_path_v);
        $fdisplay(strict_token_fd_i, "%0d", generated_token_i);
        $fclose(strict_token_fd_i);
    end
    if ((local_token_path_v != "") &&
        (local_token_path_v != token_path_v)) begin
        strict_token_fd_i = $fopen(local_token_path_v, "w");
        if (strict_token_fd_i == 0)
            $fatal(1, "29 failed to open %0s", local_token_path_v);
        $fdisplay(strict_token_fd_i, "%0d", generated_token_i);
        $fclose(strict_token_fd_i);
    end
end
endtask

task automatic dump_tree_parallel_hidden_and_token;
    input integer branch_slot_i;
    input integer level_slot_i;
    input integer slot_idx_i;
    input [`TOKEN_ID_W-1:0] query_token_i;
    reg [511:0] hidden_path_v;
    reg [511:0] token_path_v;
    integer beat_i;
    reg [`SRAM_WDATA_W-1:0] hidden_beat_v;
begin
    $sformat(hidden_path_v,
             "rtl_step2_branch%0d_level%0d_final_hidden.memh",
             branch_slot_i, level_slot_i);
    $sformat(token_path_v,
             "rtl_step2_branch%0d_level%0d_token.txt",
             branch_slot_i, level_slot_i);
    strict_hidden_fd_i = $fopen(hidden_path_v, "w");
    if (strict_hidden_fd_i == 0)
        $fatal(1, "29 failed to open %0s", hidden_path_v);
    for (beat_i = 0; beat_i < FP16_HIDDEN_BEATS; beat_i = beat_i + 1) begin
        read_sram_storage_beat(
            FP16_WORK_FINAL_BASE + (slot_idx_i * FP16_HIDDEN_BEATS) + beat_i,
            hidden_beat_v
        );
        $fdisplay(strict_hidden_fd_i, "%032h",
                  hidden_beat_v);
    end
    $fclose(strict_hidden_fd_i);

    strict_token_fd_i = $fopen(token_path_v, "w");
    if (strict_token_fd_i == 0)
        $fatal(1, "29 failed to open %0s", token_path_v);
    $fdisplay(strict_token_fd_i, "%0d", query_token_i);
    $fclose(strict_token_fd_i);
end
endtask

task automatic dump_tree_parallel_strict_capture;
    integer level_i;
    integer branch_i;
    integer flat_idx_i;
    integer slot_idx_i;
    reg [`TOKEN_ID_W-1:0] query_token_v;
begin
    for (level_i = 0;
         level_i < `MAX_PRIVATE_NODES_PER_BRANCH;
         level_i = level_i + 1) begin
        for (branch_i = 0; branch_i < `BRANCH_NUM; branch_i = branch_i + 1) begin
            flat_idx_i = (branch_i * `MAX_PRIVATE_NODES_PER_BRANCH) + level_i;
            if (u_control_chip_stage2_single_chiplet
                    .u_tree_verify_dispatcher
                    .lat_branch_valid[branch_i] &&
                u_control_chip_stage2_single_chiplet
                    .u_tree_verify_dispatcher
                    .lat_branch_levels_valid[flat_idx_i]) begin
                slot_idx_i =
                    u_control_chip_stage2_single_chiplet
                        .u_tree_verify_dispatcher
                        .lat_branch_slot_map[
                            flat_idx_i*`SLOT_ID_W +: `SLOT_ID_W];
                query_token_v =
                    u_control_chip_stage2_single_chiplet
                        .u_tree_verify_dispatcher
                        .lat_slot_token_id[
                            slot_idx_i*`TOKEN_ID_W +: `TOKEN_ID_W];
                dump_tree_parallel_hidden_and_token(
                    branch_i,
                    level_i,
                    slot_idx_i,
                    query_token_v
                );
            end
        end
        $fwrite(
            event_fd,
            "{\"cycle\":%0d,\"event\":\"verify_group_done\",\"source\":\"rtl\",\"level_index\":%0d}\n",
            cycle_count_r,
            level_i
        );
    end
end
endtask

task automatic dump_tree_parallel_batch_debug_state;
    integer lane_i;
begin
    $display(
        "[tree-parallel-debug] busy=%0d tree_busy=%0d tree_parallel_mode=%0d tree_parallel_busy=%0d native_tree_main_busy=%0d closure_sidecar_busy=%0d native_tree_sidecar_busy=%0d native_tree_lifecycle_busy=%0d",
        busy,
        u_control_chip_stage2_single_chiplet.tree_busy,
        u_control_chip_stage2_single_chiplet.tree_parallel_mode_w,
        u_control_chip_stage2_single_chiplet.tree_parallel_busy_w,
        u_control_chip_stage2_single_chiplet.native_tree_main_busy_w,
        u_control_chip_stage2_single_chiplet.closure_sidecar_busy_w,
        u_control_chip_stage2_single_chiplet.native_tree_sidecar_busy_w,
        u_control_chip_stage2_single_chiplet.native_tree_lifecycle_busy_w
    );
    $display(
        "[tree-parallel-debug] lifecycle_window_active=%0d tree_parallel_session_active=%0d active_issue_valid=%0d lifecycle_cmp_fire=%0d tree_parallel_commit_pending=%0d tree_parallel_commit_replay_active=%0d tree_parallel_kv_commit_busy=%0d tree_parallel_wb_pending_state=%0d token_wr_valid=%0d free_list_flush_drain_busy=%0d",
        u_control_chip_stage2_single_chiplet.lifecycle_window_active_r,
        u_control_chip_stage2_single_chiplet.tree_parallel_session_active_r,
        u_control_chip_stage2_single_chiplet.active_issue_valid_r,
        u_control_chip_stage2_single_chiplet.lifecycle_cmp_fire_r,
        u_control_chip_stage2_single_chiplet.tree_parallel_commit_pending_r,
        u_control_chip_stage2_single_chiplet.tree_parallel_commit_replay_active_r,
        u_control_chip_stage2_single_chiplet.tree_parallel_kv_commit_busy_w,
        u_control_chip_stage2_single_chiplet.tree_parallel_wb_pending_state_r,
        u_control_chip_stage2_single_chiplet.token_wr_valid,
        u_control_chip_stage2_single_chiplet.free_list_flush_drain_busy
    );
    $display(
        "[tree-parallel-debug] agu_state=%0d treeq_count=%0d pending_req=%0d pending_branch=%0d pending_node=%0d pending_shared=%0d pending_live=%0d prefetch_enq_valid=%0d prefetch_enq_ready=%0d cand_resp_valid=%0d cand_resp_grant=%0d alloc_resp_valid=%0d alloc_resp_grant=%0d",
        u_control_chip_stage2_single_chiplet.u_agu.agu_state_r,
        u_control_chip_stage2_single_chiplet.u_agu.treeq_count_r,
        u_control_chip_stage2_single_chiplet.u_agu.pending_req_id_r,
        u_control_chip_stage2_single_chiplet.u_agu.pending_branch_id_r,
        u_control_chip_stage2_single_chiplet.u_agu.pending_node_id_r,
        u_control_chip_stage2_single_chiplet.u_agu.pending_shared_r,
        u_control_chip_stage2_single_chiplet.u_agu.pending_live_comb,
        u_control_chip_stage2_single_chiplet.prefetch_enq_valid,
        u_control_chip_stage2_single_chiplet.prefetch_enq_ready,
        u_control_chip_stage2_single_chiplet.cand_resp_valid,
        u_control_chip_stage2_single_chiplet.cand_resp_grant,
        u_control_chip_stage2_single_chiplet.alloc_resp_valid,
        u_control_chip_stage2_single_chiplet.alloc_resp_grant
    );
    $display(
        "[tree-parallel-debug] commit_replay_cursor=%0d commit_replay_depth=%0d commit_replay_branch=%0d commit_meta_ready=%0d commit_issue_valid=%0d commit_issue_index=%0d meta_valid_bitmap=0x%0h pending_node_ids=0x%0h replay_node_ids=0x%0h",
        u_control_chip_stage2_single_chiplet.tree_parallel_commit_replay_cursor_r,
        u_control_chip_stage2_single_chiplet.tree_parallel_commit_replay_depth_r,
        u_control_chip_stage2_single_chiplet.tree_parallel_commit_replay_branch_r,
        u_control_chip_stage2_single_chiplet.tree_parallel_commit_meta_ready_comb,
        u_control_chip_stage2_single_chiplet.tree_parallel_commit_issue_valid_comb,
        u_control_chip_stage2_single_chiplet.tree_parallel_commit_issue_index_comb,
        u_control_chip_stage2_single_chiplet.lifecycle_commit_meta_valid_by_node_r,
        u_control_chip_stage2_single_chiplet.tree_parallel_commit_pending_node_id_r,
        u_control_chip_stage2_single_chiplet.tree_parallel_commit_replay_node_id_r
    );
    $display(
        "[tree-parallel-debug] dispatcher_state=%0d batch_valid=%0d batch_ready=%0d fwd_valid=%0d fwd_ready=%0d wb_pending=%0d kv_commit_busy=%0d",
        u_control_chip_stage2_single_chiplet.u_tree_verify_dispatcher.state,
        u_control_chip_stage2_single_chiplet.tree_parallel_batch_valid_w,
        u_control_chip_stage2_single_chiplet.tree_parallel_batch_ready_w,
        u_control_chip_stage2_single_chiplet.tree_parallel_fwd_result_valid_w,
        u_control_chip_stage2_single_chiplet.tree_parallel_fwd_result_ready_w,
        u_control_chip_stage2_single_chiplet.tree_parallel_wb_pending_r,
        u_control_chip_stage2_single_chiplet.tree_parallel_kv_commit_busy_w
    );
    $display(
        "[tree-parallel-debug] seed_token=0x%0h seed_position=%0d prefix_len=%0d batch_count=%0d",
        u_control_chip_stage2_single_chiplet.tree_parallel_seed_token_id_w,
        u_control_chip_stage2_single_chiplet.tree_parallel_seed_position_w,
        u_control_chip_stage2_single_chiplet.tree_parallel_batch_prefix_len_w,
        u_control_chip_stage2_single_chiplet.tree_parallel_batch_count_w
    );
    $display(
        "[tree-parallel-debug] batch_top_state=%0d tree_attn_state=%0d seed_mha_state=%0d draft0_state=%0d draft15_state=%0d req_ctrl_state=%0d",
        u_control_chip_stage2_single_chiplet.u_tree_parallel_batch_inference_top.state_r,
        u_control_chip_stage2_single_chiplet
            .u_tree_parallel_batch_inference_top
            .u_fp16_mha_tree_attention.state_r,
        u_control_chip_stage2_single_chiplet
            .u_tree_parallel_batch_inference_top
            .u_fp16_mha_tree_attention
            .u_fp16_mha_seed_controller.state_r,
        u_control_chip_stage2_single_chiplet
            .u_tree_parallel_batch_inference_top
            .u_fp16_mha_tree_attention
            .gen_mha_slot_block[0]
            .u_fp16_mha_draft_controller.state_r,
        u_control_chip_stage2_single_chiplet
            .u_tree_parallel_batch_inference_top
            .u_fp16_mha_tree_attention
            .gen_mha_slot_block[15]
            .u_fp16_mha_draft_controller.state_r,
        u_control_chip_stage2_single_chiplet.u_request_controller.state_r
    );
    $display(
        "[tree-parallel-debug] scalar_adapter_state=%0d scalar_map_state=%0d scalar_fp16_busy=%0d scalar_layer=%0d scalar_top_state=%0d scalar_sched_state=%0d scalar_layer_state=%0d",
        u_control_chip_stage2_single_chiplet
            .u_integration_operator_part
            .gen_fp16_inference
            .u_fp16_inference_adapter.state_r,
        u_control_chip_stage2_single_chiplet
            .u_integration_operator_part
            .gen_fp16_inference
            .u_fp16_inference_adapter.map_state_r,
        u_control_chip_stage2_single_chiplet
            .u_integration_operator_part
            .gen_fp16_inference
            .u_fp16_inference_adapter.fp16_busy_w,
        u_control_chip_stage2_single_chiplet
            .u_integration_operator_part
            .gen_fp16_inference
            .u_fp16_inference_adapter.fp16_current_layer_debug_w,
        u_control_chip_stage2_single_chiplet
            .u_integration_operator_part
            .gen_fp16_inference
            .u_fp16_inference_adapter
            .u_fp16_inference_top.state_r,
        u_control_chip_stage2_single_chiplet
            .u_integration_operator_part
            .gen_fp16_inference
            .u_fp16_inference_adapter
            .u_fp16_inference_top
            .u_fp16_layer_scheduler.state_r,
        u_control_chip_stage2_single_chiplet
            .u_integration_operator_part
            .gen_fp16_inference
            .u_fp16_inference_adapter
            .u_fp16_inference_top
            .u_fp16_layer_scheduler
            .u_fp16_transformer_layer.state_r
    );
    $display(
        "[tree-parallel-debug] scalar_issue_valid=%0d scalar_issue_ready=%0d op_req_valid=%0d op_req_ready=%0d op_req_write=%0d op_req_id=%0d op_req_addr=0x%0h op_resp_valid=%0d op_resp_ready=%0d op_resp_id=%0d",
        u_control_chip_stage2_single_chiplet.issue_valid,
        u_control_chip_stage2_single_chiplet.issue_ready,
        u_control_chip_stage2_single_chiplet.op_req_valid,
        u_control_chip_stage2_single_chiplet.op_req_ready,
        u_control_chip_stage2_single_chiplet.op_req_write,
        u_control_chip_stage2_single_chiplet.op_req_id,
        u_control_chip_stage2_single_chiplet.op_req_addr,
        u_control_chip_stage2_single_chiplet.op_resp_valid,
        u_control_chip_stage2_single_chiplet.op_resp_ready,
        u_control_chip_stage2_single_chiplet.op_resp_id
    );
    $display(
        "[tree-parallel-debug] mem_req_valid=0x%0h mem_req_ready=0x%0h mem_resp_valid=0x%0h pe_resp_valid=0x%0h pe_resp_ready=0x%0h lane0_mem_req_id=%0d lane0_mem_resp_id=%0d",
        u_control_chip_stage2_single_chiplet.mem_req_valid,
        u_control_chip_stage2_single_chiplet.mem_req_ready,
        u_control_chip_stage2_single_chiplet.mem_resp_valid,
        u_control_chip_stage2_single_chiplet.pe_resp_valid,
        u_control_chip_stage2_single_chiplet.pe_resp_ready,
        u_control_chip_stage2_single_chiplet.mem_req_id[0 +: `REQ_ID_W],
        u_control_chip_stage2_single_chiplet.mem_resp_id[0 +: `REQ_ID_W]
    );
    $display(
        "[tree-parallel-debug] vec_req_valid=0x%0h vec_req_ready=0x%0h vec_resp_valid=0x%0h vec_resp_ready=0x%0h",
        u_control_chip_stage2_single_chiplet.tree_parallel_vec_req_valid_w,
        u_control_chip_stage2_single_chiplet.tree_parallel_vec_req_ready_w,
        u_control_chip_stage2_single_chiplet.tree_parallel_vec_resp_valid_w,
        u_control_chip_stage2_single_chiplet.tree_parallel_vec_resp_ready_w
    );
    $display(
        "[tree-parallel-debug] scalar_sel=%0d vec_sel=%0d lane0_resp_valid=%0d lane0_resp_req_id=%0d lane0_resp_pe_mask=0x%0h scalar_resp_valid=%0d scalar_resp_ready=%0d",
        u_control_chip_stage2_single_chiplet.tree_parallel_scalar_resp_select_w,
        u_control_chip_stage2_single_chiplet.tree_parallel_resp_select_w,
        u_control_chip_stage2_single_chiplet.lane0_resp_valid_w,
        u_control_chip_stage2_single_chiplet.lane0_resp_req_id_w,
        u_control_chip_stage2_single_chiplet.lane0_resp_pe_mask_w,
        u_control_chip_stage2_single_chiplet.tree_parallel_sram_resp_valid_w,
        u_control_chip_stage2_single_chiplet.tree_parallel_sram_resp_ready_w
    );
    $display(
        "[tree-parallel-debug] seed_rd_valid=%0d seed_rd_ready=%0d seed_resp_valid=%0d seed_resp_ready=%0d seed_req_id=%0d head=%0d pos=%0d beat=%0d",
        u_control_chip_stage2_single_chiplet.tree_parallel_sram_rd_valid_w,
        u_control_chip_stage2_single_chiplet.tree_parallel_sram_rd_ready_w,
        u_control_chip_stage2_single_chiplet.tree_parallel_sram_resp_valid_w,
        u_control_chip_stage2_single_chiplet.tree_parallel_sram_resp_ready_w,
        u_control_chip_stage2_single_chiplet.tree_parallel_sram_rd_id_w,
        u_control_chip_stage2_single_chiplet
            .u_tree_parallel_batch_inference_top
            .u_fp16_mha_tree_attention
            .u_fp16_mha_seed_controller.head_idx_r,
        u_control_chip_stage2_single_chiplet
            .u_tree_parallel_batch_inference_top
            .u_fp16_mha_tree_attention
            .u_fp16_mha_seed_controller.pos_idx_r,
        u_control_chip_stage2_single_chiplet
            .u_tree_parallel_batch_inference_top
            .u_fp16_mha_tree_attention
            .u_fp16_mha_seed_controller.beat_idx_r
    );
    $display(
        "[tree-parallel-debug] draft_barrier_waiting=0x%0h barrier_release=%0d draft_done=0x%0h draft_stage_done=0x%0h",
        u_control_chip_stage2_single_chiplet
            .u_tree_parallel_batch_inference_top
            .u_fp16_mha_tree_attention.draft_mha_barrier_waiting_w,
        u_control_chip_stage2_single_chiplet
            .u_tree_parallel_batch_inference_top
            .u_fp16_mha_tree_attention.draft_mha_barrier_release_w,
        u_control_chip_stage2_single_chiplet
            .u_tree_parallel_batch_inference_top
            .u_fp16_mha_tree_attention.draft_mha_done_r,
        u_control_chip_stage2_single_chiplet
            .u_tree_parallel_batch_inference_top
            .u_fp16_mha_tree_attention.draft_stage_done_r
    );
    $display(
        "[tree-parallel-debug] draft0_matvec_state=%0d draft0_matvec_resp_ready=%0d draft0_matvec_result_valid=%0d draft0_matvec_req_id=%0d",
        u_control_chip_stage2_single_chiplet
            .u_tree_parallel_batch_inference_top
            .u_fp16_mha_tree_attention
            .gen_mha_slot_block[0]
            .u_fp16_mha_draft_controller
            .u_fp16_tiled_matvec.state_r,
        u_control_chip_stage2_single_chiplet
            .u_tree_parallel_batch_inference_top
            .u_fp16_mha_tree_attention
            .gen_mha_slot_block[0]
            .u_fp16_mha_draft_controller
            .u_fp16_tiled_matvec.sram_resp_ready,
        u_control_chip_stage2_single_chiplet
            .u_tree_parallel_batch_inference_top
            .u_fp16_mha_tree_attention
            .gen_mha_slot_block[0]
            .u_fp16_mha_draft_controller
            .u_fp16_tiled_matvec.result_valid,
        u_control_chip_stage2_single_chiplet
            .u_tree_parallel_batch_inference_top
            .u_fp16_mha_tree_attention
            .gen_mha_slot_block[0]
            .u_fp16_mha_draft_controller
            .u_fp16_tiled_matvec.req_id_r
    );
    $display(
        "[tree-parallel-debug] draft15_matvec_state=%0d draft15_matvec_resp_ready=%0d draft15_matvec_result_valid=%0d draft15_matvec_req_id=%0d",
        u_control_chip_stage2_single_chiplet
            .u_tree_parallel_batch_inference_top
            .u_fp16_mha_tree_attention
            .gen_mha_slot_block[15]
            .u_fp16_mha_draft_controller
            .u_fp16_tiled_matvec.state_r,
        u_control_chip_stage2_single_chiplet
            .u_tree_parallel_batch_inference_top
            .u_fp16_mha_tree_attention
            .gen_mha_slot_block[15]
            .u_fp16_mha_draft_controller
            .u_fp16_tiled_matvec.sram_resp_ready,
        u_control_chip_stage2_single_chiplet
            .u_tree_parallel_batch_inference_top
            .u_fp16_mha_tree_attention
            .gen_mha_slot_block[15]
            .u_fp16_mha_draft_controller
            .u_fp16_tiled_matvec.result_valid,
        u_control_chip_stage2_single_chiplet
            .u_tree_parallel_batch_inference_top
            .u_fp16_mha_tree_attention
            .gen_mha_slot_block[15]
            .u_fp16_mha_draft_controller
            .u_fp16_tiled_matvec.req_id_r
    );
    $display(
        "[tree-parallel-debug] res1draft0_state=%0d res1draft0_x_req_accepted=%0d res1draft0_r_req_accepted=%0d res1draft0_resp_ready=%0d",
        u_control_chip_stage2_single_chiplet
            .u_tree_parallel_batch_inference_top
            .u_fp16_mha_tree_attention
            .gen_post_slot_block[0]
            .u_residual_add1_draft.state_r,
        u_control_chip_stage2_single_chiplet
            .u_tree_parallel_batch_inference_top
            .u_fp16_mha_tree_attention
            .gen_post_slot_block[0]
            .u_residual_add1_draft.x_req_accepted_r,
        u_control_chip_stage2_single_chiplet
            .u_tree_parallel_batch_inference_top
            .u_fp16_mha_tree_attention
            .gen_post_slot_block[0]
            .u_residual_add1_draft.r_req_accepted_r,
        u_control_chip_stage2_single_chiplet
            .u_tree_parallel_batch_inference_top
            .u_fp16_mha_tree_attention
            .gen_post_slot_block[0]
            .u_residual_add1_draft.sram_resp_ready
    );
    $display(
        "[tree-parallel-debug] res1draft15_state=%0d res1draft15_x_req_accepted=%0d res1draft15_r_req_accepted=%0d res1draft15_resp_ready=%0d",
        u_control_chip_stage2_single_chiplet
            .u_tree_parallel_batch_inference_top
            .u_fp16_mha_tree_attention
            .gen_post_slot_block[15]
            .u_residual_add1_draft.state_r,
        u_control_chip_stage2_single_chiplet
            .u_tree_parallel_batch_inference_top
            .u_fp16_mha_tree_attention
            .gen_post_slot_block[15]
            .u_residual_add1_draft.x_req_accepted_r,
        u_control_chip_stage2_single_chiplet
            .u_tree_parallel_batch_inference_top
            .u_fp16_mha_tree_attention
            .gen_post_slot_block[15]
            .u_residual_add1_draft.r_req_accepted_r,
        u_control_chip_stage2_single_chiplet
            .u_tree_parallel_batch_inference_top
            .u_fp16_mha_tree_attention
            .gen_post_slot_block[15]
            .u_residual_add1_draft.sram_resp_ready
    );
    $display(
        "[tree-parallel-debug] postdraft0_state=%0d postdraft0_x_req_accepted=%0d postdraft0_g_req_accepted=%0d postdraft0_resp_ready=%0d",
        u_control_chip_stage2_single_chiplet
            .u_tree_parallel_batch_inference_top
            .u_fp16_mha_tree_attention
            .gen_post_slot_block[0]
            .u_post_rmsnorm_draft.state_r,
        u_control_chip_stage2_single_chiplet
            .u_tree_parallel_batch_inference_top
            .u_fp16_mha_tree_attention
            .gen_post_slot_block[0]
            .u_post_rmsnorm_draft.x_req_accepted_r,
        u_control_chip_stage2_single_chiplet
            .u_tree_parallel_batch_inference_top
            .u_fp16_mha_tree_attention
            .gen_post_slot_block[0]
            .u_post_rmsnorm_draft.g_req_accepted_r,
        u_control_chip_stage2_single_chiplet
            .u_tree_parallel_batch_inference_top
            .u_fp16_mha_tree_attention
            .gen_post_slot_block[0]
            .u_post_rmsnorm_draft.sram_resp_ready
    );
    $display(
        "[tree-parallel-debug] postdraft15_state=%0d postdraft15_x_req_accepted=%0d postdraft15_g_req_accepted=%0d postdraft15_resp_ready=%0d",
        u_control_chip_stage2_single_chiplet
            .u_tree_parallel_batch_inference_top
            .u_fp16_mha_tree_attention
            .gen_post_slot_block[15]
            .u_post_rmsnorm_draft.state_r,
        u_control_chip_stage2_single_chiplet
            .u_tree_parallel_batch_inference_top
            .u_fp16_mha_tree_attention
            .gen_post_slot_block[15]
            .u_post_rmsnorm_draft.x_req_accepted_r,
        u_control_chip_stage2_single_chiplet
            .u_tree_parallel_batch_inference_top
            .u_fp16_mha_tree_attention
            .gen_post_slot_block[15]
            .u_post_rmsnorm_draft.g_req_accepted_r,
        u_control_chip_stage2_single_chiplet
            .u_tree_parallel_batch_inference_top
            .u_fp16_mha_tree_attention
            .gen_post_slot_block[15]
            .u_post_rmsnorm_draft.sram_resp_ready
    );
    $display(
        "[tree-parallel-debug] ffndraft0_state=%0d ffndraft0_gate_req_accepted=%0d ffndraft0_up_req_accepted=%0d ffndraft0_resp_ready=%0d",
        u_control_chip_stage2_single_chiplet
            .u_tree_parallel_batch_inference_top
            .u_fp16_mha_tree_attention
            .gen_post_slot_block[0]
            .u_fp16_ffn_swiglu_draft.state_r,
        u_control_chip_stage2_single_chiplet
            .u_tree_parallel_batch_inference_top
            .u_fp16_mha_tree_attention
            .gen_post_slot_block[0]
            .u_fp16_ffn_swiglu_draft.gate_req_accepted_r,
        u_control_chip_stage2_single_chiplet
            .u_tree_parallel_batch_inference_top
            .u_fp16_mha_tree_attention
            .gen_post_slot_block[0]
            .u_fp16_ffn_swiglu_draft.up_req_accepted_r,
        u_control_chip_stage2_single_chiplet
            .u_tree_parallel_batch_inference_top
            .u_fp16_mha_tree_attention
            .gen_post_slot_block[0]
            .u_fp16_ffn_swiglu_draft.sram_resp_ready
    );
    $display(
        "[tree-parallel-debug] ffndraft15_state=%0d ffndraft15_gate_req_accepted=%0d ffndraft15_up_req_accepted=%0d ffndraft15_resp_ready=%0d",
        u_control_chip_stage2_single_chiplet
            .u_tree_parallel_batch_inference_top
            .u_fp16_mha_tree_attention
            .gen_post_slot_block[15]
            .u_fp16_ffn_swiglu_draft.state_r,
        u_control_chip_stage2_single_chiplet
            .u_tree_parallel_batch_inference_top
            .u_fp16_mha_tree_attention
            .gen_post_slot_block[15]
            .u_fp16_ffn_swiglu_draft.gate_req_accepted_r,
        u_control_chip_stage2_single_chiplet
            .u_tree_parallel_batch_inference_top
            .u_fp16_mha_tree_attention
            .gen_post_slot_block[15]
            .u_fp16_ffn_swiglu_draft.up_req_accepted_r,
        u_control_chip_stage2_single_chiplet
            .u_tree_parallel_batch_inference_top
            .u_fp16_mha_tree_attention
            .gen_post_slot_block[15]
            .u_fp16_ffn_swiglu_draft.sram_resp_ready
    );
    for (lane_i = 0; lane_i < `MEM_REQ_LANES; lane_i = lane_i + 1) begin
        $display(
            "[tree-parallel-debug] lane=%0d lane_valid=%0d lane_write=%0d resp_valid=%0d resp_ready=%0d req_id=%0d addr=0x%0h mem_req_ready=%0d mem_resp_valid=%0d mem_resp_id=%0d sram_lane_busy=%0d pe_mask=0x%0h merge=%0d merge_src=%0d bypass=%0d issued=%0d",
            lane_i,
            u_control_chip_stage2_single_chiplet.u_request_controller.lane_valid_r[lane_i],
            u_control_chip_stage2_single_chiplet.u_request_controller.lane_write_r[lane_i],
            u_control_chip_stage2_single_chiplet.u_request_controller.resp_valid_r[lane_i],
            u_control_chip_stage2_single_chiplet.pe_resp_ready[lane_i],
            u_control_chip_stage2_single_chiplet.u_request_controller.lane_req_id_r[
                lane_i*`REQ_ID_W +: `REQ_ID_W],
            u_control_chip_stage2_single_chiplet.u_request_controller.lane_addr_r[
                lane_i*`SRAM_ADDR_W +: `SRAM_ADDR_W],
            u_control_chip_stage2_single_chiplet.mem_req_ready[lane_i],
            u_control_chip_stage2_single_chiplet.mem_resp_valid[lane_i],
            u_control_chip_stage2_single_chiplet.mem_resp_id[
                lane_i*`REQ_ID_W +: `REQ_ID_W],
            u_control_chip_stage2_single_chiplet.u_sram_subsystem.lane_busy_r[lane_i],
            u_control_chip_stage2_single_chiplet.u_request_controller.resp_pe_mask_r[
                lane_i*`PE_MASK_W +: `PE_MASK_W],
            u_control_chip_stage2_single_chiplet.u_request_controller.lane_merge_r[lane_i],
            u_control_chip_stage2_single_chiplet.u_request_controller.lane_merge_src_r[lane_i],
            u_control_chip_stage2_single_chiplet.u_request_controller.lane_bypass_r[lane_i],
            u_control_chip_stage2_single_chiplet.u_request_controller.lane_issued_r[lane_i]
        );
    end
end
endtask

task automatic force_mem_write_beat;
    input [`SRAM_ADDR_W-1:0] sram_addr_i;
    input [`SRAM_WDATA_W-1:0] sram_data_i;
begin
    forced_mem_req_addr_shadow_r = sram_addr_i;
    forced_mem_req_wdata_shadow_r = sram_data_i;
    force u_control_chip_stage2_single_chiplet.mem_req_valid =
        {{(`MEM_REQ_LANES-1){1'b0}}, 1'b1};
    force u_control_chip_stage2_single_chiplet.mem_req_write =
        {{(`MEM_REQ_LANES-1){1'b0}}, 1'b1};
    force u_control_chip_stage2_single_chiplet.mem_req_addr =
        {{((`MEM_REQ_LANES-1)*`SRAM_ADDR_W){1'b0}},
         forced_mem_req_addr_shadow_r};
    force u_control_chip_stage2_single_chiplet.mem_req_wdata =
        {{((`MEM_REQ_LANES-1)*`SRAM_WDATA_W){1'b0}},
         forced_mem_req_wdata_shadow_r};
    force u_control_chip_stage2_single_chiplet.mem_req_id =
        {(`MEM_REQ_LANES*`REQ_ID_W){1'b0}};
    @(posedge clk);
    #1;
    if (u_control_chip_stage2_single_chiplet.mem_req_ready[0] !== 1'b1) begin
        $fatal(1, "29 toy-model preload mem write was not accepted addr=0x%0h",
               sram_addr_i);
    end
    release u_control_chip_stage2_single_chiplet.mem_req_valid;
    release u_control_chip_stage2_single_chiplet.mem_req_write;
    release u_control_chip_stage2_single_chiplet.mem_req_addr;
    release u_control_chip_stage2_single_chiplet.mem_req_wdata;
    release u_control_chip_stage2_single_chiplet.mem_req_id;
end
endtask

task automatic emit_preload_start;
begin
    $fwrite(
        event_fd,
        "{\"cycle\":%0d,\"event\":\"preload_start\",\"source\":\"rtl\",\"sram_total\":%0d,\"hbm_total\":%0d}\n",
        cycle_count_r,
        TOY_MODEL_SRAM_PRELOAD_DEPTH,
        (TOY_MODEL_HBM_MEM_DEPTH - FP16_HBM_WEIGHT_BASE)
    );
    $fflush(event_fd);
end
endtask

task automatic emit_preload_progress;
    input [7:0] phase_id_i;
    input integer index_i;
    input integer total_i;
    input integer write_count_i;
begin
    if (phase_id_i == 8'd0) begin
        $fwrite(
            event_fd,
            "{\"cycle\":%0d,\"event\":\"preload_progress\",\"source\":\"rtl\",\"phase\":\"sram\",\"index\":%0d,\"total\":%0d,\"writes\":%0d}\n",
            cycle_count_r,
            index_i,
            total_i,
            write_count_i
        );
    end else begin
        $fwrite(
            event_fd,
            "{\"cycle\":%0d,\"event\":\"preload_progress\",\"source\":\"rtl\",\"phase\":\"hbm\",\"index\":%0d,\"total\":%0d,\"writes\":%0d}\n",
            cycle_count_r,
            index_i,
            total_i,
            write_count_i
        );
    end
    $fflush(event_fd);
end
endtask

task automatic emit_preload_done;
    input integer sram_write_count_i;
    input integer hbm_write_count_i;
begin
    $fwrite(
        event_fd,
        "{\"cycle\":%0d,\"event\":\"preload_done\",\"source\":\"rtl\",\"sram_writes\":%0d,\"hbm_writes\":%0d}\n",
        cycle_count_r,
        sram_write_count_i,
        hbm_write_count_i
    );
    $fflush(event_fd);
end
endtask

task automatic emit_tree_parallel_dispatcher_state;
    input [2:0] state_i;
begin
    $fwrite(
        event_fd,
        "{\"cycle\":%0d,\"event\":\"tree_parallel_dispatcher_state\",\"source\":\"rtl\",\"state\":%0d}\n",
        cycle_count_r,
        state_i
    );
    $fflush(event_fd);
end
endtask

task automatic emit_tree_parallel_batch_top_state;
    input [4:0] state_i;
begin
    $fwrite(
        event_fd,
        "{\"cycle\":%0d,\"event\":\"tree_parallel_batch_top_state\",\"source\":\"rtl\",\"state\":%0d}\n",
        cycle_count_r,
        state_i
    );
    $fflush(event_fd);
end
endtask

task automatic emit_tree_parallel_batch_inner_state;
    input [8*16-1:0] reason_i;
begin
    $fwrite(
        event_fd,
        "{\"cycle\":%0d,\"event\":\"tree_parallel_batch_inner_state\",\"source\":\"rtl\",\"reason\":\"%0s\",\"batch_top_state\":%0d,\"tree_attn_state\":%0d,\"seed_mha_state\":%0d,\"draft0_state\":%0d,\"draft15_state\":%0d,\"ffn_draft0_state\":%0d,\"ffn_draft7_state\":%0d,\"ffn_draft7_gate_req_accepted\":%0d,\"ffn_draft7_up_req_accepted\":%0d,\"ffn_draft15_state\":%0d,\"ffn_draft15_matvec_state\":%0d,\"ffn_draft15_matvec_beat_idx\":%0d,\"ffn_draft15_matvec_tile_row\":%0d,\"ffn_draft15_matvec_tile_col\":%0d,\"ffn_draft15_gate_req_accepted\":%0d,\"ffn_draft15_up_req_accepted\":%0d,\"draft_active_mask_hex\":\"0x%0h\",\"draft_done_mask_hex\":\"0x%0h\",\"vec_resp_valid_mask_hex\":\"0x%0h\",\"vec_resp_ready_mask_hex\":\"0x%0h\",\"vec_resp_blocked_mask_hex\":\"0x%0h\",\"rc_lane_valid_mask_hex\":\"0x%0h\",\"rc_lane_issued_mask_hex\":\"0x%0h\",\"sram_lane_busy_mask_hex\":\"0x%0h\",\"req_ctrl_state\":%0d}\n",
        cycle_count_r,
        reason_i,
        u_control_chip_stage2_single_chiplet.u_tree_parallel_batch_inference_top.state_r,
        u_control_chip_stage2_single_chiplet
            .u_tree_parallel_batch_inference_top
            .u_fp16_mha_tree_attention.state_r,
        u_control_chip_stage2_single_chiplet
            .u_tree_parallel_batch_inference_top
            .u_fp16_mha_tree_attention
            .u_fp16_mha_seed_controller.state_r,
        u_control_chip_stage2_single_chiplet
            .u_tree_parallel_batch_inference_top
            .u_fp16_mha_tree_attention
            .gen_mha_slot_block[0]
            .u_fp16_mha_draft_controller.state_r,
        u_control_chip_stage2_single_chiplet
            .u_tree_parallel_batch_inference_top
            .u_fp16_mha_tree_attention
            .gen_mha_slot_block[15]
            .u_fp16_mha_draft_controller.state_r,
        u_control_chip_stage2_single_chiplet
            .u_tree_parallel_batch_inference_top
            .u_fp16_mha_tree_attention
            .gen_post_slot_block[0]
            .u_fp16_ffn_swiglu_draft.state_r,
        u_control_chip_stage2_single_chiplet
            .u_tree_parallel_batch_inference_top
            .u_fp16_mha_tree_attention
            .gen_post_slot_block[7]
            .u_fp16_ffn_swiglu_draft.state_r,
        u_control_chip_stage2_single_chiplet
            .u_tree_parallel_batch_inference_top
            .u_fp16_mha_tree_attention
            .gen_post_slot_block[7]
            .u_fp16_ffn_swiglu_draft.gate_req_accepted_r,
        u_control_chip_stage2_single_chiplet
            .u_tree_parallel_batch_inference_top
            .u_fp16_mha_tree_attention
            .gen_post_slot_block[7]
            .u_fp16_ffn_swiglu_draft.up_req_accepted_r,
        u_control_chip_stage2_single_chiplet
            .u_tree_parallel_batch_inference_top
            .u_fp16_mha_tree_attention
            .gen_post_slot_block[15]
            .u_fp16_ffn_swiglu_draft.state_r,
        u_control_chip_stage2_single_chiplet
            .u_tree_parallel_batch_inference_top
            .u_fp16_mha_tree_attention
            .gen_post_slot_block[15]
            .u_fp16_ffn_swiglu_draft
            .u_fp16_tiled_matvec.state_r,
        u_control_chip_stage2_single_chiplet
            .u_tree_parallel_batch_inference_top
            .u_fp16_mha_tree_attention
            .gen_post_slot_block[15]
            .u_fp16_ffn_swiglu_draft
            .u_fp16_tiled_matvec.beat_idx_r,
        u_control_chip_stage2_single_chiplet
            .u_tree_parallel_batch_inference_top
            .u_fp16_mha_tree_attention
            .gen_post_slot_block[15]
            .u_fp16_ffn_swiglu_draft
            .u_fp16_tiled_matvec.tile_row_r,
        u_control_chip_stage2_single_chiplet
            .u_tree_parallel_batch_inference_top
            .u_fp16_mha_tree_attention
            .gen_post_slot_block[15]
            .u_fp16_ffn_swiglu_draft
            .u_fp16_tiled_matvec.tile_col_r,
        u_control_chip_stage2_single_chiplet
            .u_tree_parallel_batch_inference_top
            .u_fp16_mha_tree_attention
            .gen_post_slot_block[15]
            .u_fp16_ffn_swiglu_draft.gate_req_accepted_r,
        u_control_chip_stage2_single_chiplet
            .u_tree_parallel_batch_inference_top
            .u_fp16_mha_tree_attention
            .gen_post_slot_block[15]
            .u_fp16_ffn_swiglu_draft.up_req_accepted_r,
        u_control_chip_stage2_single_chiplet
            .u_tree_parallel_batch_inference_top
            .u_fp16_mha_tree_attention
            .draft_mha_active_w,
        u_control_chip_stage2_single_chiplet
            .u_tree_parallel_batch_inference_top
            .u_fp16_mha_tree_attention
            .draft_stage_done_r,
        u_control_chip_stage2_single_chiplet.tree_parallel_vec_resp_valid_w,
        u_control_chip_stage2_single_chiplet.tree_parallel_vec_resp_ready_w,
        u_control_chip_stage2_single_chiplet.tree_parallel_vec_resp_valid_w &
            ~u_control_chip_stage2_single_chiplet.tree_parallel_vec_resp_ready_w,
        u_control_chip_stage2_single_chiplet.u_request_controller.lane_valid_r,
        u_control_chip_stage2_single_chiplet.u_request_controller.lane_issued_r,
        {
            u_control_chip_stage2_single_chiplet.u_sram_subsystem.lane_busy_r[15],
            u_control_chip_stage2_single_chiplet.u_sram_subsystem.lane_busy_r[14],
            u_control_chip_stage2_single_chiplet.u_sram_subsystem.lane_busy_r[13],
            u_control_chip_stage2_single_chiplet.u_sram_subsystem.lane_busy_r[12],
            u_control_chip_stage2_single_chiplet.u_sram_subsystem.lane_busy_r[11],
            u_control_chip_stage2_single_chiplet.u_sram_subsystem.lane_busy_r[10],
            u_control_chip_stage2_single_chiplet.u_sram_subsystem.lane_busy_r[9],
            u_control_chip_stage2_single_chiplet.u_sram_subsystem.lane_busy_r[8],
            u_control_chip_stage2_single_chiplet.u_sram_subsystem.lane_busy_r[7],
            u_control_chip_stage2_single_chiplet.u_sram_subsystem.lane_busy_r[6],
            u_control_chip_stage2_single_chiplet.u_sram_subsystem.lane_busy_r[5],
            u_control_chip_stage2_single_chiplet.u_sram_subsystem.lane_busy_r[4],
            u_control_chip_stage2_single_chiplet.u_sram_subsystem.lane_busy_r[3],
            u_control_chip_stage2_single_chiplet.u_sram_subsystem.lane_busy_r[2],
            u_control_chip_stage2_single_chiplet.u_sram_subsystem.lane_busy_r[1],
            u_control_chip_stage2_single_chiplet.u_sram_subsystem.lane_busy_r[0]
        },
        u_control_chip_stage2_single_chiplet.u_request_controller.state_r
    );
    $fflush(event_fd);
end
endtask

task automatic emit_tree_parallel_req_fire;
begin
    $fwrite(
        event_fd,
        "{\"cycle\":%0d,\"event\":\"tree_parallel_req_fire\",\"source\":\"rtl\",\"req_id_hex\":\"0x%0h\",\"branch_valid_hex\":\"0x%0h\",\"levels_valid_hex\":\"0x%0h\"}\n",
        cycle_count_r,
        native_tree_req_id,
        u_control_chip_stage2_single_chiplet.tree_parallel_branch_valid_w,
        u_control_chip_stage2_single_chiplet.tree_parallel_branch_levels_valid_w
    );
    $fflush(event_fd);
end
endtask

task automatic preload_toy_model_memh_once;
    integer preload_sram_write_count_i;
    integer preload_hbm_write_count_i;
begin
    // Preload the underlying storage_bytes-backed SRAM through the mem_req path.
    preload_sram_write_count_i = 0;
    preload_hbm_write_count_i = 0;
    $readmemh(preload_memh_path_r, toy_model_sram_preload_mem);
    $readmemh(hbm_memh_path_r, toy_model_hbm_mem);
    emit_preload_start();

    for (preload_sram_idx_i = 0;
         preload_sram_idx_i < TOY_MODEL_SRAM_PRELOAD_DEPTH;
         preload_sram_idx_i = preload_sram_idx_i + 1) begin
        if (toy_model_sram_preload_mem[preload_sram_idx_i] !=
            {`SRAM_WDATA_W{1'b0}}) begin
            force_mem_write_beat(
                preload_sram_idx_i[`SRAM_ADDR_W-1:0],
                toy_model_sram_preload_mem[preload_sram_idx_i]
            );
            preload_sram_write_count_i = preload_sram_write_count_i + 1;
        end
        if ((preload_sram_idx_i == 0) ||
            ((preload_sram_idx_i % PRELOAD_PROGRESS_STRIDE) == 0)) begin
            emit_preload_progress(
                8'd0,
                preload_sram_idx_i,
                TOY_MODEL_SRAM_PRELOAD_DEPTH,
                preload_sram_write_count_i
            );
        end
    end

    for (preload_hbm_idx_i = FP16_HBM_WEIGHT_BASE;
         preload_hbm_idx_i < TOY_MODEL_HBM_MEM_DEPTH;
         preload_hbm_idx_i = preload_hbm_idx_i + 1) begin
        if (toy_model_hbm_mem[preload_hbm_idx_i] != {`HBM_DATA_W{1'b0}}) begin
            force_mem_write_beat(
                FP16_HBM_MAPPED_SRAM_BASE +
                    ((preload_hbm_idx_i - FP16_HBM_WEIGHT_BASE) *
                     FP16_HBM_TO_SRAM_RATIO),
                toy_model_hbm_mem[preload_hbm_idx_i][0 +: `SRAM_WDATA_W]
            );
            force_mem_write_beat(
                FP16_HBM_MAPPED_SRAM_BASE +
                    ((preload_hbm_idx_i - FP16_HBM_WEIGHT_BASE) *
                     FP16_HBM_TO_SRAM_RATIO) + 1'b1,
                toy_model_hbm_mem[preload_hbm_idx_i][`SRAM_WDATA_W +:
                                                     `SRAM_WDATA_W]
            );
            preload_hbm_write_count_i = preload_hbm_write_count_i + 2;
        end
        if ((preload_hbm_idx_i == FP16_HBM_WEIGHT_BASE) ||
            (((preload_hbm_idx_i - FP16_HBM_WEIGHT_BASE) %
              PRELOAD_PROGRESS_STRIDE) == 0)) begin
            emit_preload_progress(
                8'd1,
                preload_hbm_idx_i - FP16_HBM_WEIGHT_BASE,
                (TOY_MODEL_HBM_MEM_DEPTH - FP16_HBM_WEIGHT_BASE),
                preload_hbm_write_count_i
            );
        end
    end

    emit_preload_done(
        preload_sram_write_count_i,
        preload_hbm_write_count_i
    );
end
endtask

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        cycle_count_r <= 0;
        cfg_start_seen_r <= 1'b0;
        wb_done_seen_r <= 1'b0;
        hbm_write_seen_r <= 1'b0;
        tree_parallel_dispatcher_state_prev_r <= 3'h7;
        tree_parallel_batch_top_state_prev_r <= 5'h1f;
        tree_parallel_tree_attn_state_prev_r <= 5'h1f;
        tree_parallel_seed_mha_state_prev_r <= 5'h1f;
        tree_parallel_draft0_state_prev_r <= 5'h1f;
        tree_parallel_draft15_state_prev_r <= 5'h1f;
        tree_parallel_batch_wait_heartbeat_cycle_r <= 0;
        strict_capture_index_r <= strict_capture_index_base_r;
        strict_branch_slot_r <= 0;
        strict_capture_active_r <= 1'b0;
        strict_capture_query_token_r <= {`TOKEN_ID_W{1'b0}};
        strict_capture_branch_id_r <= {`BRANCH_ID_W{1'b0}};
        strict_capture_tree_mask_en_r <= 1'b0;
        tree_parallel_strict_capture_valid_r <= 1'b0;
        fp16_embedding_resp_logged_r <= 1'b0;
        fp16_pre_norm_write_logged_r <= 1'b0;
        fp16_mha_out_write_logged_r <= 1'b0;
        fp16_res1_write_logged_r <= 1'b0;
        fp16_post_norm_write_logged_r <= 1'b0;
        fp16_ffn_out_write_logged_r <= 1'b0;
        fp16_res2_write_logged_r <= 1'b0;
        fp16_layer_result_write_logged_r <= 1'b0;
        fp16_final_norm_x_read_logged_r <= 1'b0;
        fp16_final_norm_gamma_read_logged_r <= 1'b0;
        fp16_final_hidden_write_logged_r <= 1'b0;
        fp16_lm_hidden_read_logged_r <= 1'b0;
        fp16_lm_weight_read_logged_r <= 1'b0;
        for (strict_dump_idx_i = 0;
             strict_dump_idx_i < FP16_HIDDEN_BEATS;
             strict_dump_idx_i = strict_dump_idx_i + 1) begin
            strict_final_hidden_shadow[strict_dump_idx_i] <=
                {`SRAM_WDATA_W{1'b0}};
            strict_final_hidden_sram_shadow[strict_dump_idx_i] <=
                {`SRAM_WDATA_W{1'b0}};
        end
        for (tree_parallel_shadow_slot_i = 0;
             tree_parallel_shadow_slot_i < TREE_PARALLEL_CAPTURE_SLOTS;
             tree_parallel_shadow_slot_i = tree_parallel_shadow_slot_i + 1) begin
            for (tree_parallel_shadow_beat_i = 0;
                 tree_parallel_shadow_beat_i < FP16_HIDDEN_BEATS;
                 tree_parallel_shadow_beat_i = tree_parallel_shadow_beat_i + 1) begin
                tree_parallel_final_hidden_shadow[
                    tree_parallel_shadow_slot_i][tree_parallel_shadow_beat_i] <=
                    {`SRAM_WDATA_W{1'b0}};
                tree_parallel_final_hidden_sram_shadow[
                    tree_parallel_shadow_slot_i][tree_parallel_shadow_beat_i] <=
                    {`SRAM_WDATA_W{1'b0}};
            end
        end
    end else begin
        cycle_count_r <= cycle_count_r + 1;

        if ((u_control_chip_stage2_single_chiplet.u_tree_verify_dispatcher.state !==
             tree_parallel_dispatcher_state_prev_r)) begin
            emit_tree_parallel_dispatcher_state(
                u_control_chip_stage2_single_chiplet.u_tree_verify_dispatcher.state
            );
            tree_parallel_dispatcher_state_prev_r <=
                u_control_chip_stage2_single_chiplet.u_tree_verify_dispatcher.state;
        end

        if ((u_control_chip_stage2_single_chiplet
                 .u_tree_parallel_batch_inference_top
                 .state_r !== tree_parallel_batch_top_state_prev_r)) begin
            emit_tree_parallel_batch_top_state(
                u_control_chip_stage2_single_chiplet
                    .u_tree_parallel_batch_inference_top
                    .state_r
            );
            tree_parallel_batch_top_state_prev_r <=
                u_control_chip_stage2_single_chiplet
                    .u_tree_parallel_batch_inference_top
                    .state_r;
            tree_parallel_batch_wait_heartbeat_cycle_r <= cycle_count_r;
        end

        if ((u_control_chip_stage2_single_chiplet
                 .u_tree_parallel_batch_inference_top
                 .u_fp16_mha_tree_attention
                 .state_r !== tree_parallel_tree_attn_state_prev_r) ||
            (u_control_chip_stage2_single_chiplet
                 .u_tree_parallel_batch_inference_top
                 .u_fp16_mha_tree_attention
                 .u_fp16_mha_seed_controller.state_r !==
             tree_parallel_seed_mha_state_prev_r) ||
            (u_control_chip_stage2_single_chiplet
                 .u_tree_parallel_batch_inference_top
                 .u_fp16_mha_tree_attention
                 .gen_mha_slot_block[0]
                 .u_fp16_mha_draft_controller.state_r !==
             tree_parallel_draft0_state_prev_r) ||
            (u_control_chip_stage2_single_chiplet
                 .u_tree_parallel_batch_inference_top
                 .u_fp16_mha_tree_attention
                 .gen_mha_slot_block[15]
                 .u_fp16_mha_draft_controller.state_r !==
             tree_parallel_draft15_state_prev_r)) begin
            emit_tree_parallel_batch_inner_state("state_change");
            tree_parallel_tree_attn_state_prev_r <=
                u_control_chip_stage2_single_chiplet
                    .u_tree_parallel_batch_inference_top
                    .u_fp16_mha_tree_attention
                    .state_r;
            tree_parallel_seed_mha_state_prev_r <=
                u_control_chip_stage2_single_chiplet
                    .u_tree_parallel_batch_inference_top
                    .u_fp16_mha_tree_attention
                    .u_fp16_mha_seed_controller.state_r;
            tree_parallel_draft0_state_prev_r <=
                u_control_chip_stage2_single_chiplet
                    .u_tree_parallel_batch_inference_top
                    .u_fp16_mha_tree_attention
                    .gen_mha_slot_block[0]
                    .u_fp16_mha_draft_controller.state_r;
            tree_parallel_draft15_state_prev_r <=
                u_control_chip_stage2_single_chiplet
                    .u_tree_parallel_batch_inference_top
                    .u_fp16_mha_tree_attention
                    .gen_mha_slot_block[15]
                    .u_fp16_mha_draft_controller.state_r;
            tree_parallel_batch_wait_heartbeat_cycle_r <= cycle_count_r;
        end

        if ((u_control_chip_stage2_single_chiplet
                 .u_tree_parallel_batch_inference_top
                 .state_r == 5'd13) &&
            ((cycle_count_r - tree_parallel_batch_wait_heartbeat_cycle_r) >=
             TREE_PARALLEL_BATCH_WAIT_HEARTBEAT_CYCLES)) begin
            emit_tree_parallel_batch_inner_state("heartbeat");
            tree_parallel_batch_wait_heartbeat_cycle_r <= cycle_count_r;
        end

        if (cfg_valid && start) begin
            cfg_start_seen_r <= 1'b1;
            $fwrite(
                event_fd,
                "{\"cycle\":%0d,\"event\":\"cfg_start\",\"source\":\"rtl\",\"cfg_data_hex\":\"0x%08x\"}\n",
                cycle_count_r,
                cfg_data
            );
            $fflush(event_fd);
        end

        if (|(draft_cand_valid & draft_cand_ready)) begin
            $fwrite(
                event_fd,
                "{\"cycle\":%0d,\"event\":\"draft_fire\",\"source\":\"rtl\",\"valid_mask_hex\":\"0x%0h\",\"ready_mask_hex\":\"0x%0h\",\"token_bus_hex\":\"0x%0h\"}\n",
                cycle_count_r,
                draft_cand_valid,
                draft_cand_ready,
                draft_token_id
            );
        end

        if (native_tree_req_valid && native_tree_req_ready) begin
            $fwrite(
                event_fd,
                "{\"cycle\":%0d,\"event\":\"native_tree_req\",\"source\":\"rtl\",\"req_id_hex\":\"0x%0h\",\"prefix_slot_valid_hex\":\"0x%0h\",\"frontier_level_valid_hex\":\"0x%0h\"}\n",
                cycle_count_r,
                native_tree_req_id,
                native_tree_src_prefix_slot_valid,
                native_tree_src_frontier_level_valid
            );
            $fflush(event_fd);
        end

        if (u_control_chip_stage2_single_chiplet.tree_parallel_req_valid_w &&
            u_control_chip_stage2_single_chiplet.tree_parallel_req_ready_w) begin
            emit_tree_parallel_req_fire();
        end

        if (u_control_chip_stage2_single_chiplet.native_tree_main_req_fire_w) begin
            $fwrite(
                event_fd,
                "{\"cycle\":%0d,\"event\":\"native_tree_main_req\",\"source\":\"rtl\"}\n",
                cycle_count_r
            );
            $fflush(event_fd);
        end

        if (u_control_chip_stage2_single_chiplet.native_tree_main_frontier_capture_fire_w) begin
            $fwrite(
                event_fd,
                "{\"cycle\":%0d,\"event\":\"verify_group_capture\",\"source\":\"rtl\"}\n",
                cycle_count_r
            );
            $fflush(event_fd);
            if (u_control_chip_stage2_single_chiplet.tree_parallel_mode_w) begin
                tree_parallel_strict_capture_valid_r <= 1'b1;
                for (tree_parallel_shadow_slot_i = 0;
                     tree_parallel_shadow_slot_i < TREE_PARALLEL_CAPTURE_SLOTS;
                     tree_parallel_shadow_slot_i = tree_parallel_shadow_slot_i + 1) begin
                    for (tree_parallel_shadow_beat_i = 0;
                         tree_parallel_shadow_beat_i < FP16_HIDDEN_BEATS;
                         tree_parallel_shadow_beat_i = tree_parallel_shadow_beat_i + 1) begin
                        tree_parallel_final_hidden_shadow[
                            tree_parallel_shadow_slot_i][tree_parallel_shadow_beat_i] <=
                            {`SRAM_WDATA_W{1'b0}};
                        tree_parallel_final_hidden_sram_shadow[
                            tree_parallel_shadow_slot_i][tree_parallel_shadow_beat_i] <=
                            {`SRAM_WDATA_W{1'b0}};
                    end
                end
            end
        end

        if (u_control_chip_stage2_single_chiplet.native_tree_main_pred_fire_w ||
            (u_control_chip_stage2_single_chiplet.tree_parallel_batch_valid_w &&
             u_control_chip_stage2_single_chiplet.tree_parallel_batch_ready_w)) begin
            if (!u_control_chip_stage2_single_chiplet.tree_parallel_mode_w) begin
                strict_capture_active_r <= 1'b1;
                strict_capture_query_token_r <=
                    u_control_chip_stage2_single_chiplet.issue_token_id;
                strict_capture_tree_mask_en_r <=
                    u_control_chip_stage2_single_chiplet.issue_tree_mask_en;
                strict_capture_branch_id_r <=
                    u_control_chip_stage2_single_chiplet.issue_tree_mask_branch_id;
                strict_branch_slot_r <=
                    u_control_chip_stage2_single_chiplet.issue_tree_mask_branch_id;
                for (strict_dump_idx_i = 0;
                     strict_dump_idx_i < FP16_HIDDEN_BEATS;
                     strict_dump_idx_i = strict_dump_idx_i + 1) begin
                    strict_final_hidden_shadow[strict_dump_idx_i] <=
                        {`SRAM_WDATA_W{1'b0}};
                    strict_final_hidden_sram_shadow[strict_dump_idx_i] <=
                        {`SRAM_WDATA_W{1'b0}};
                end
            end
            $fwrite(
                event_fd,
                "{\"cycle\":%0d,\"event\":\"verify_group_issue\",\"source\":\"rtl\",\"tree_mask_en\":%0d,\"branch_id\":%0d,\"token_id_hex\":\"0x%0h\",\"referenced_position_hex\":\"0x%0h\"}\n",
                cycle_count_r,
                u_control_chip_stage2_single_chiplet.tree_parallel_mode_w ? 1'b1 :
                    u_control_chip_stage2_single_chiplet.issue_tree_mask_en,
                u_control_chip_stage2_single_chiplet.tree_parallel_mode_w ? 0 :
                    u_control_chip_stage2_single_chiplet.issue_tree_mask_branch_id,
                u_control_chip_stage2_single_chiplet.tree_parallel_mode_w ?
                    u_control_chip_stage2_single_chiplet.tree_parallel_batch_token_ids_w[0 +: `TOKEN_ID_W] :
                    u_control_chip_stage2_single_chiplet.issue_token_id,
                u_control_chip_stage2_single_chiplet.tree_parallel_mode_w ?
                    u_control_chip_stage2_single_chiplet.tree_parallel_batch_positions_w[0 +: `POSITION_ID_W] :
                    u_control_chip_stage2_single_chiplet.pred_referenced_position
            );
            $fflush(event_fd);
        end

        for (mem_shadow_lane_i = 0;
             mem_shadow_lane_i < `MEM_REQ_LANES;
             mem_shadow_lane_i = mem_shadow_lane_i + 1) begin
            if (u_control_chip_stage2_single_chiplet.mem_req_valid[mem_shadow_lane_i] &&
                u_control_chip_stage2_single_chiplet.mem_req_ready[mem_shadow_lane_i] &&
                u_control_chip_stage2_single_chiplet.mem_req_write[mem_shadow_lane_i]) begin
                mem_shadow_addr_i =
                    u_control_chip_stage2_single_chiplet.mem_req_addr[
                        mem_shadow_lane_i*`SRAM_ADDR_W +: `SRAM_ADDR_W];
                mem_shadow_data_i =
                    u_control_chip_stage2_single_chiplet.mem_req_wdata[
                        mem_shadow_lane_i*`SRAM_WDATA_W +: `SRAM_WDATA_W];
                if (strict_capture_active_r &&
                    (mem_shadow_addr_i >= FP16_WORK_FINAL_BASE)) begin
                    mem_final_hidden_idx_i =
                        mem_shadow_addr_i - FP16_WORK_FINAL_BASE;
                    if ((mem_final_hidden_idx_i >= 0) &&
                        (mem_final_hidden_idx_i < FP16_HIDDEN_BEATS)) begin
                        strict_final_hidden_shadow[mem_final_hidden_idx_i] <=
                            mem_shadow_data_i;
                        strict_final_hidden_sram_shadow[mem_final_hidden_idx_i] <=
                            mem_shadow_data_i;
                    end
                end
                if (tree_parallel_strict_capture_valid_r &&
                    (mem_shadow_addr_i >= FP16_WORK_FINAL_BASE)) begin
                    mem_final_slot_idx_i =
                        (mem_shadow_addr_i - FP16_WORK_FINAL_BASE) /
                        FP16_HIDDEN_BEATS;
                    mem_final_hidden_idx_i =
                        (mem_shadow_addr_i - FP16_WORK_FINAL_BASE) %
                        FP16_HIDDEN_BEATS;
                    if ((mem_final_slot_idx_i >= 0) &&
                        (mem_final_slot_idx_i < TREE_PARALLEL_CAPTURE_SLOTS) &&
                        (mem_final_hidden_idx_i >= 0) &&
                        (mem_final_hidden_idx_i < FP16_HIDDEN_BEATS)) begin
                        tree_parallel_final_hidden_shadow[
                            mem_final_slot_idx_i][mem_final_hidden_idx_i] <=
                            mem_shadow_data_i;
                        tree_parallel_final_hidden_sram_shadow[
                            mem_final_slot_idx_i][mem_final_hidden_idx_i] <=
                            mem_shadow_data_i;
                    end
                end
            end
        end

        if (u_control_chip_stage2_single_chiplet.issue_valid &&
            u_control_chip_stage2_single_chiplet.issue_ready) begin
            fp16_embedding_resp_logged_r <= 1'b0;
            fp16_pre_norm_write_logged_r <= 1'b0;
            fp16_mha_out_write_logged_r <= 1'b0;
            fp16_res1_write_logged_r <= 1'b0;
            fp16_post_norm_write_logged_r <= 1'b0;
            fp16_ffn_out_write_logged_r <= 1'b0;
            fp16_res2_write_logged_r <= 1'b0;
            fp16_layer_result_write_logged_r <= 1'b0;
            fp16_final_norm_x_read_logged_r <= 1'b0;
            fp16_final_norm_gamma_read_logged_r <= 1'b0;
            fp16_final_hidden_write_logged_r <= 1'b0;
            fp16_lm_hidden_read_logged_r <= 1'b0;
            fp16_lm_weight_read_logged_r <= 1'b0;
            $fwrite(
                event_fd,
                "{\"cycle\":%0d,\"event\":\"issue_accept\",\"source\":\"rtl\",\"token_id_hex\":\"0x%0h\",\"position_hex\":\"0x%0h\",\"tree_mask_en\":%0d,\"prefix_len\":%0d,\"src_addr_hex\":\"0x%0h\",\"dst_addr_hex\":\"0x%0h\"}\n",
                cycle_count_r,
                u_control_chip_stage2_single_chiplet.issue_token_id,
                u_control_chip_stage2_single_chiplet.issue_position,
                u_control_chip_stage2_single_chiplet.issue_tree_mask_en,
                u_control_chip_stage2_single_chiplet.issue_prefix_len,
                u_control_chip_stage2_single_chiplet.issue_src_addr,
                u_control_chip_stage2_single_chiplet.issue_dst_addr
            );
            $fflush(event_fd);
        end

        if ((u_control_chip_stage2_single_chiplet
                 .u_integration_operator_part
                 .gen_fp16_inference
                 .u_fp16_inference_adapter
                 .u_fp16_inference_top
                 .u_fp16_layer_scheduler
                 .u_fp16_transformer_layer
                 .state_r == 4'd2) &&
            u_control_chip_stage2_single_chiplet
                .u_integration_operator_part
                .gen_fp16_inference
                .u_fp16_inference_adapter
                .u_fp16_inference_top
                .u_fp16_layer_scheduler
                .u_fp16_transformer_layer
                .sram_wr_valid &&
            u_control_chip_stage2_single_chiplet
                .u_integration_operator_part
                .gen_fp16_inference
                .u_fp16_inference_adapter
                .u_fp16_inference_top
                .sram_wr_ready &&
            !fp16_pre_norm_write_logged_r &&
            (u_control_chip_stage2_single_chiplet
                 .u_integration_operator_part
                 .gen_fp16_inference
                 .u_fp16_inference_adapter
                 .u_fp16_inference_top
                 .u_fp16_layer_scheduler
                 .u_fp16_transformer_layer
                 .sram_wr_addr >=
             u_control_chip_stage2_single_chiplet
                 .u_integration_operator_part
                 .gen_fp16_inference
                 .u_fp16_inference_adapter
                 .u_fp16_inference_top
                 .u_fp16_layer_scheduler
                 .u_fp16_transformer_layer
                 .pre_norm_out_base_w) &&
            (u_control_chip_stage2_single_chiplet
                 .u_integration_operator_part
                 .gen_fp16_inference
                 .u_fp16_inference_adapter
                 .u_fp16_inference_top
                 .u_fp16_layer_scheduler
                 .u_fp16_transformer_layer
                 .sram_wr_addr <
             (u_control_chip_stage2_single_chiplet
                  .u_integration_operator_part
                  .gen_fp16_inference
                  .u_fp16_inference_adapter
                  .u_fp16_inference_top
                  .u_fp16_layer_scheduler
                  .u_fp16_transformer_layer
                  .pre_norm_out_base_w + FP16_HIDDEN_BEATS))) begin
            fp16_pre_norm_write_logged_r <= 1'b1;
            $fwrite(
                event_fd,
                "{\"cycle\":%0d,\"event\":\"fp16_pre_norm_write\",\"source\":\"rtl\",\"layer_index\":%0d,\"beat_index\":%0d,\"addr_hex\":\"0x%0h\",\"data_hex\":\"%0h\"}\n",
                cycle_count_r,
                u_control_chip_stage2_single_chiplet
                    .u_integration_operator_part
                    .gen_fp16_inference
                    .u_fp16_inference_adapter
                    .u_fp16_inference_top
                    .u_fp16_layer_scheduler
                    .layer_idx_r,
                u_control_chip_stage2_single_chiplet
                    .u_integration_operator_part
                    .gen_fp16_inference
                    .u_fp16_inference_adapter
                    .u_fp16_inference_top
                    .u_fp16_layer_scheduler
                    .u_fp16_transformer_layer
                    .sram_wr_addr -
                u_control_chip_stage2_single_chiplet
                    .u_integration_operator_part
                    .gen_fp16_inference
                    .u_fp16_inference_adapter
                    .u_fp16_inference_top
                    .u_fp16_layer_scheduler
                    .u_fp16_transformer_layer
                    .pre_norm_out_base_w,
                u_control_chip_stage2_single_chiplet
                    .u_integration_operator_part
                    .gen_fp16_inference
                    .u_fp16_inference_adapter
                    .u_fp16_inference_top
                    .u_fp16_layer_scheduler
                    .u_fp16_transformer_layer
                    .sram_wr_addr,
                u_control_chip_stage2_single_chiplet
                    .u_integration_operator_part
                    .gen_fp16_inference
                    .u_fp16_inference_adapter
                    .u_fp16_inference_top
                    .u_fp16_layer_scheduler
                    .u_fp16_transformer_layer
                    .sram_wr_data
            );
            $fflush(event_fd);
        end

        if ((u_control_chip_stage2_single_chiplet
                 .u_integration_operator_part
                 .gen_fp16_inference
                 .u_fp16_inference_adapter
                 .u_fp16_inference_top
                 .u_fp16_layer_scheduler
                 .u_fp16_transformer_layer
                 .state_r == 4'd4) &&
            u_control_chip_stage2_single_chiplet
                .u_integration_operator_part
                .gen_fp16_inference
                .u_fp16_inference_adapter
                .u_fp16_inference_top
                .u_fp16_layer_scheduler
                .u_fp16_transformer_layer
                .sram_wr_valid &&
            u_control_chip_stage2_single_chiplet
                .u_integration_operator_part
                .gen_fp16_inference
                .u_fp16_inference_adapter
                .u_fp16_inference_top
                .sram_wr_ready &&
            !fp16_mha_out_write_logged_r &&
            (u_control_chip_stage2_single_chiplet
                 .u_integration_operator_part
                 .gen_fp16_inference
                 .u_fp16_inference_adapter
                 .u_fp16_inference_top
                 .u_fp16_layer_scheduler
                 .u_fp16_transformer_layer
                 .sram_wr_addr >=
             u_control_chip_stage2_single_chiplet
                 .u_integration_operator_part
                 .gen_fp16_inference
                 .u_fp16_inference_adapter
                 .u_fp16_inference_top
                 .u_fp16_layer_scheduler
                 .u_fp16_transformer_layer
                 .mha_out_base_w) &&
            (u_control_chip_stage2_single_chiplet
                 .u_integration_operator_part
                 .gen_fp16_inference
                 .u_fp16_inference_adapter
                 .u_fp16_inference_top
                 .u_fp16_layer_scheduler
                 .u_fp16_transformer_layer
                 .sram_wr_addr <
             (u_control_chip_stage2_single_chiplet
                  .u_integration_operator_part
                  .gen_fp16_inference
                  .u_fp16_inference_adapter
                  .u_fp16_inference_top
                  .u_fp16_layer_scheduler
                  .u_fp16_transformer_layer
                  .mha_out_base_w + FP16_HIDDEN_BEATS))) begin
            fp16_mha_out_write_logged_r <= 1'b1;
            $fwrite(
                event_fd,
                "{\"cycle\":%0d,\"event\":\"fp16_mha_out_write\",\"source\":\"rtl\",\"layer_index\":%0d,\"beat_index\":%0d,\"addr_hex\":\"0x%0h\",\"data_hex\":\"%0h\"}\n",
                cycle_count_r,
                u_control_chip_stage2_single_chiplet
                    .u_integration_operator_part
                    .gen_fp16_inference
                    .u_fp16_inference_adapter
                    .u_fp16_inference_top
                    .u_fp16_layer_scheduler
                    .layer_idx_r,
                u_control_chip_stage2_single_chiplet
                    .u_integration_operator_part
                    .gen_fp16_inference
                    .u_fp16_inference_adapter
                    .u_fp16_inference_top
                    .u_fp16_layer_scheduler
                    .u_fp16_transformer_layer
                    .sram_wr_addr -
                u_control_chip_stage2_single_chiplet
                    .u_integration_operator_part
                    .gen_fp16_inference
                    .u_fp16_inference_adapter
                    .u_fp16_inference_top
                    .u_fp16_layer_scheduler
                    .u_fp16_transformer_layer
                    .mha_out_base_w,
                u_control_chip_stage2_single_chiplet
                    .u_integration_operator_part
                    .gen_fp16_inference
                    .u_fp16_inference_adapter
                    .u_fp16_inference_top
                    .u_fp16_layer_scheduler
                    .u_fp16_transformer_layer
                    .sram_wr_addr,
                u_control_chip_stage2_single_chiplet
                    .u_integration_operator_part
                    .gen_fp16_inference
                    .u_fp16_inference_adapter
                    .u_fp16_inference_top
                    .u_fp16_layer_scheduler
                    .u_fp16_transformer_layer
                    .sram_wr_data
            );
            $fflush(event_fd);
        end

        if ((u_control_chip_stage2_single_chiplet
                 .u_integration_operator_part
                 .gen_fp16_inference
                 .u_fp16_inference_adapter
                 .u_fp16_inference_top
                 .u_fp16_layer_scheduler
                 .u_fp16_transformer_layer
                 .state_r == 4'd6) &&
            u_control_chip_stage2_single_chiplet
                .u_integration_operator_part
                .gen_fp16_inference
                .u_fp16_inference_adapter
                .u_fp16_inference_top
                .u_fp16_layer_scheduler
                .u_fp16_transformer_layer
                .sram_wr_valid &&
            u_control_chip_stage2_single_chiplet
                .u_integration_operator_part
                .gen_fp16_inference
                .u_fp16_inference_adapter
                .u_fp16_inference_top
                .sram_wr_ready &&
            !fp16_res1_write_logged_r &&
            (u_control_chip_stage2_single_chiplet
                 .u_integration_operator_part
                 .gen_fp16_inference
                 .u_fp16_inference_adapter
                 .u_fp16_inference_top
                 .u_fp16_layer_scheduler
                 .u_fp16_transformer_layer
                 .sram_wr_addr >=
             u_control_chip_stage2_single_chiplet
                 .u_integration_operator_part
                 .gen_fp16_inference
                 .u_fp16_inference_adapter
                 .u_fp16_inference_top
                 .u_fp16_layer_scheduler
                 .u_fp16_transformer_layer
                 .result_addr_r) &&
            (u_control_chip_stage2_single_chiplet
                 .u_integration_operator_part
                 .gen_fp16_inference
                 .u_fp16_inference_adapter
                 .u_fp16_inference_top
                 .u_fp16_layer_scheduler
                 .u_fp16_transformer_layer
                 .sram_wr_addr <
             (u_control_chip_stage2_single_chiplet
                  .u_integration_operator_part
                  .gen_fp16_inference
                  .u_fp16_inference_adapter
                  .u_fp16_inference_top
                  .u_fp16_layer_scheduler
                  .u_fp16_transformer_layer
                  .result_addr_r + FP16_HIDDEN_BEATS))) begin
            fp16_res1_write_logged_r <= 1'b1;
            $fwrite(
                event_fd,
                "{\"cycle\":%0d,\"event\":\"fp16_res1_write\",\"source\":\"rtl\",\"layer_index\":%0d,\"beat_index\":%0d,\"addr_hex\":\"0x%0h\",\"data_hex\":\"%0h\"}\n",
                cycle_count_r,
                u_control_chip_stage2_single_chiplet
                    .u_integration_operator_part
                    .gen_fp16_inference
                    .u_fp16_inference_adapter
                    .u_fp16_inference_top
                    .u_fp16_layer_scheduler
                    .layer_idx_r,
                u_control_chip_stage2_single_chiplet
                    .u_integration_operator_part
                    .gen_fp16_inference
                    .u_fp16_inference_adapter
                    .u_fp16_inference_top
                    .u_fp16_layer_scheduler
                    .u_fp16_transformer_layer
                    .sram_wr_addr -
                u_control_chip_stage2_single_chiplet
                    .u_integration_operator_part
                    .gen_fp16_inference
                    .u_fp16_inference_adapter
                    .u_fp16_inference_top
                    .u_fp16_layer_scheduler
                    .u_fp16_transformer_layer
                    .result_addr_r,
                u_control_chip_stage2_single_chiplet
                    .u_integration_operator_part
                    .gen_fp16_inference
                    .u_fp16_inference_adapter
                    .u_fp16_inference_top
                    .u_fp16_layer_scheduler
                    .u_fp16_transformer_layer
                    .sram_wr_addr,
                u_control_chip_stage2_single_chiplet
                    .u_integration_operator_part
                    .gen_fp16_inference
                    .u_fp16_inference_adapter
                    .u_fp16_inference_top
                    .u_fp16_layer_scheduler
                    .u_fp16_transformer_layer
                    .sram_wr_data
            );
            $fflush(event_fd);
        end

        if ((u_control_chip_stage2_single_chiplet
                 .u_integration_operator_part
                 .gen_fp16_inference
                 .u_fp16_inference_adapter
                 .u_fp16_inference_top
                 .u_fp16_layer_scheduler
                 .u_fp16_transformer_layer
                 .state_r == 4'd8) &&
            u_control_chip_stage2_single_chiplet
                .u_integration_operator_part
                .gen_fp16_inference
                .u_fp16_inference_adapter
                .u_fp16_inference_top
                .u_fp16_layer_scheduler
                .u_fp16_transformer_layer
                .sram_wr_valid &&
            u_control_chip_stage2_single_chiplet
                .u_integration_operator_part
                .gen_fp16_inference
                .u_fp16_inference_adapter
                .u_fp16_inference_top
                .sram_wr_ready &&
            !fp16_post_norm_write_logged_r &&
            (u_control_chip_stage2_single_chiplet
                 .u_integration_operator_part
                 .gen_fp16_inference
                 .u_fp16_inference_adapter
                 .u_fp16_inference_top
                 .u_fp16_layer_scheduler
                 .u_fp16_transformer_layer
                 .sram_wr_addr >=
             u_control_chip_stage2_single_chiplet
                 .u_integration_operator_part
                 .gen_fp16_inference
                 .u_fp16_inference_adapter
                 .u_fp16_inference_top
                 .u_fp16_layer_scheduler
                 .u_fp16_transformer_layer
                 .post_norm_out_base_w) &&
            (u_control_chip_stage2_single_chiplet
                 .u_integration_operator_part
                 .gen_fp16_inference
                 .u_fp16_inference_adapter
                 .u_fp16_inference_top
                 .u_fp16_layer_scheduler
                 .u_fp16_transformer_layer
                 .sram_wr_addr <
             (u_control_chip_stage2_single_chiplet
                  .u_integration_operator_part
                  .gen_fp16_inference
                  .u_fp16_inference_adapter
                  .u_fp16_inference_top
                  .u_fp16_layer_scheduler
                  .u_fp16_transformer_layer
                  .post_norm_out_base_w + FP16_HIDDEN_BEATS))) begin
            fp16_post_norm_write_logged_r <= 1'b1;
            $fwrite(
                event_fd,
                "{\"cycle\":%0d,\"event\":\"fp16_post_norm_write\",\"source\":\"rtl\",\"layer_index\":%0d,\"beat_index\":%0d,\"addr_hex\":\"0x%0h\",\"data_hex\":\"%0h\"}\n",
                cycle_count_r,
                u_control_chip_stage2_single_chiplet
                    .u_integration_operator_part
                    .gen_fp16_inference
                    .u_fp16_inference_adapter
                    .u_fp16_inference_top
                    .u_fp16_layer_scheduler
                    .layer_idx_r,
                u_control_chip_stage2_single_chiplet
                    .u_integration_operator_part
                    .gen_fp16_inference
                    .u_fp16_inference_adapter
                    .u_fp16_inference_top
                    .u_fp16_layer_scheduler
                    .u_fp16_transformer_layer
                    .sram_wr_addr -
                u_control_chip_stage2_single_chiplet
                    .u_integration_operator_part
                    .gen_fp16_inference
                    .u_fp16_inference_adapter
                    .u_fp16_inference_top
                    .u_fp16_layer_scheduler
                    .u_fp16_transformer_layer
                    .post_norm_out_base_w,
                u_control_chip_stage2_single_chiplet
                    .u_integration_operator_part
                    .gen_fp16_inference
                    .u_fp16_inference_adapter
                    .u_fp16_inference_top
                    .u_fp16_layer_scheduler
                    .u_fp16_transformer_layer
                    .sram_wr_addr,
                u_control_chip_stage2_single_chiplet
                    .u_integration_operator_part
                    .gen_fp16_inference
                    .u_fp16_inference_adapter
                    .u_fp16_inference_top
                    .u_fp16_layer_scheduler
                    .u_fp16_transformer_layer
                    .sram_wr_data
            );
            $fflush(event_fd);
        end

        if ((u_control_chip_stage2_single_chiplet
                 .u_integration_operator_part
                 .gen_fp16_inference
                 .u_fp16_inference_adapter
                 .u_fp16_inference_top
                 .u_fp16_layer_scheduler
                 .u_fp16_transformer_layer
                 .state_r == 4'd10) &&
            u_control_chip_stage2_single_chiplet
                .u_integration_operator_part
                .gen_fp16_inference
                .u_fp16_inference_adapter
                .u_fp16_inference_top
                .u_fp16_layer_scheduler
                .u_fp16_transformer_layer
                .sram_wr_valid &&
            u_control_chip_stage2_single_chiplet
                .u_integration_operator_part
                .gen_fp16_inference
                .u_fp16_inference_adapter
                .u_fp16_inference_top
                .sram_wr_ready &&
            !fp16_ffn_out_write_logged_r &&
            (u_control_chip_stage2_single_chiplet
                 .u_integration_operator_part
                 .gen_fp16_inference
                 .u_fp16_inference_adapter
                 .u_fp16_inference_top
                 .u_fp16_layer_scheduler
                 .u_fp16_transformer_layer
                 .sram_wr_addr >=
             u_control_chip_stage2_single_chiplet
                 .u_integration_operator_part
                 .gen_fp16_inference
                 .u_fp16_inference_adapter
                 .u_fp16_inference_top
                 .u_fp16_layer_scheduler
                 .u_fp16_transformer_layer
                 .ffn_out_base_w) &&
            (u_control_chip_stage2_single_chiplet
                 .u_integration_operator_part
                 .gen_fp16_inference
                 .u_fp16_inference_adapter
                 .u_fp16_inference_top
                 .u_fp16_layer_scheduler
                 .u_fp16_transformer_layer
                 .sram_wr_addr <
             (u_control_chip_stage2_single_chiplet
                  .u_integration_operator_part
                  .gen_fp16_inference
                  .u_fp16_inference_adapter
                  .u_fp16_inference_top
                  .u_fp16_layer_scheduler
                  .u_fp16_transformer_layer
                  .ffn_out_base_w + FP16_HIDDEN_BEATS))) begin
            fp16_ffn_out_write_logged_r <= 1'b1;
            $fwrite(
                event_fd,
                "{\"cycle\":%0d,\"event\":\"fp16_ffn_out_write\",\"source\":\"rtl\",\"layer_index\":%0d,\"beat_index\":%0d,\"addr_hex\":\"0x%0h\",\"data_hex\":\"%0h\"}\n",
                cycle_count_r,
                u_control_chip_stage2_single_chiplet
                    .u_integration_operator_part
                    .gen_fp16_inference
                    .u_fp16_inference_adapter
                    .u_fp16_inference_top
                    .u_fp16_layer_scheduler
                    .layer_idx_r,
                u_control_chip_stage2_single_chiplet
                    .u_integration_operator_part
                    .gen_fp16_inference
                    .u_fp16_inference_adapter
                    .u_fp16_inference_top
                    .u_fp16_layer_scheduler
                    .u_fp16_transformer_layer
                    .sram_wr_addr -
                u_control_chip_stage2_single_chiplet
                    .u_integration_operator_part
                    .gen_fp16_inference
                    .u_fp16_inference_adapter
                    .u_fp16_inference_top
                    .u_fp16_layer_scheduler
                    .u_fp16_transformer_layer
                    .ffn_out_base_w,
                u_control_chip_stage2_single_chiplet
                    .u_integration_operator_part
                    .gen_fp16_inference
                    .u_fp16_inference_adapter
                    .u_fp16_inference_top
                    .u_fp16_layer_scheduler
                    .u_fp16_transformer_layer
                    .sram_wr_addr,
                u_control_chip_stage2_single_chiplet
                    .u_integration_operator_part
                    .gen_fp16_inference
                    .u_fp16_inference_adapter
                    .u_fp16_inference_top
                    .u_fp16_layer_scheduler
                    .u_fp16_transformer_layer
                    .sram_wr_data
            );
            $fflush(event_fd);
        end

        if ((u_control_chip_stage2_single_chiplet
                 .u_integration_operator_part
                 .gen_fp16_inference
                 .u_fp16_inference_adapter
                 .u_fp16_inference_top
                 .u_fp16_layer_scheduler
                 .u_fp16_transformer_layer
                 .state_r == 4'd12) &&
            u_control_chip_stage2_single_chiplet
                .u_integration_operator_part
                .gen_fp16_inference
                .u_fp16_inference_adapter
                .u_fp16_inference_top
                .u_fp16_layer_scheduler
                .u_fp16_transformer_layer
                .sram_wr_valid &&
            u_control_chip_stage2_single_chiplet
                .u_integration_operator_part
                .gen_fp16_inference
                .u_fp16_inference_adapter
                .u_fp16_inference_top
                .sram_wr_ready &&
            !fp16_res2_write_logged_r &&
            (u_control_chip_stage2_single_chiplet
                 .u_integration_operator_part
                 .gen_fp16_inference
                 .u_fp16_inference_adapter
                 .u_fp16_inference_top
                 .u_fp16_layer_scheduler
                 .u_fp16_transformer_layer
                 .sram_wr_addr >=
             u_control_chip_stage2_single_chiplet
                 .u_integration_operator_part
                 .gen_fp16_inference
                 .u_fp16_inference_adapter
                 .u_fp16_inference_top
                 .u_fp16_layer_scheduler
                 .u_fp16_transformer_layer
                 .result_addr_r) &&
            (u_control_chip_stage2_single_chiplet
                 .u_integration_operator_part
                 .gen_fp16_inference
                 .u_fp16_inference_adapter
                 .u_fp16_inference_top
                 .u_fp16_layer_scheduler
                 .u_fp16_transformer_layer
                 .sram_wr_addr <
             (u_control_chip_stage2_single_chiplet
                  .u_integration_operator_part
                  .gen_fp16_inference
                  .u_fp16_inference_adapter
                  .u_fp16_inference_top
                  .u_fp16_layer_scheduler
                  .u_fp16_transformer_layer
                  .result_addr_r + FP16_HIDDEN_BEATS))) begin
            fp16_res2_write_logged_r <= 1'b1;
            $fwrite(
                event_fd,
                "{\"cycle\":%0d,\"event\":\"fp16_res2_write\",\"source\":\"rtl\",\"layer_index\":%0d,\"beat_index\":%0d,\"addr_hex\":\"0x%0h\",\"data_hex\":\"%0h\"}\n",
                cycle_count_r,
                u_control_chip_stage2_single_chiplet
                    .u_integration_operator_part
                    .gen_fp16_inference
                    .u_fp16_inference_adapter
                    .u_fp16_inference_top
                    .u_fp16_layer_scheduler
                    .layer_idx_r,
                u_control_chip_stage2_single_chiplet
                    .u_integration_operator_part
                    .gen_fp16_inference
                    .u_fp16_inference_adapter
                    .u_fp16_inference_top
                    .u_fp16_layer_scheduler
                    .u_fp16_transformer_layer
                    .sram_wr_addr -
                u_control_chip_stage2_single_chiplet
                    .u_integration_operator_part
                    .gen_fp16_inference
                    .u_fp16_inference_adapter
                    .u_fp16_inference_top
                    .u_fp16_layer_scheduler
                    .u_fp16_transformer_layer
                    .result_addr_r,
                u_control_chip_stage2_single_chiplet
                    .u_integration_operator_part
                    .gen_fp16_inference
                    .u_fp16_inference_adapter
                    .u_fp16_inference_top
                    .u_fp16_layer_scheduler
                    .u_fp16_transformer_layer
                    .sram_wr_addr,
                u_control_chip_stage2_single_chiplet
                    .u_integration_operator_part
                    .gen_fp16_inference
                    .u_fp16_inference_adapter
                    .u_fp16_inference_top
                    .u_fp16_layer_scheduler
                    .u_fp16_transformer_layer
                    .sram_wr_data
            );
            $fflush(event_fd);
        end

        if (u_control_chip_stage2_single_chiplet
                .u_integration_operator_part
                .gen_fp16_inference
                .u_fp16_inference_adapter
                .u_fp16_inference_top
                .u_fp16_embedding
                .issue_valid &&
            u_control_chip_stage2_single_chiplet
                .u_integration_operator_part
                .gen_fp16_inference
                .u_fp16_inference_adapter
                .u_fp16_inference_top
                .u_fp16_embedding
                .issue_ready) begin
            $fwrite(
                event_fd,
                "{\"cycle\":%0d,\"event\":\"fp16_embedding_issue\",\"source\":\"rtl\",\"token_id_hex\":\"0x%0h\",\"embedding_base_hex\":\"0x%0h\",\"result_addr_hex\":\"0x%0h\"}\n",
                cycle_count_r,
                u_control_chip_stage2_single_chiplet
                    .u_integration_operator_part
                    .gen_fp16_inference
                    .u_fp16_inference_adapter
                    .u_fp16_inference_top
                    .u_fp16_embedding
                    .issue_token_id,
                u_control_chip_stage2_single_chiplet
                    .u_integration_operator_part
                    .gen_fp16_inference
                    .u_fp16_inference_adapter
                    .u_fp16_inference_top
                    .u_fp16_embedding
                    .issue_embedding_base,
                u_control_chip_stage2_single_chiplet
                    .u_integration_operator_part
                    .gen_fp16_inference
                    .u_fp16_inference_adapter
                    .u_fp16_inference_top
                    .u_fp16_embedding
                    .issue_result_addr
            );
            $fflush(event_fd);
        end

        if (u_control_chip_stage2_single_chiplet
                .u_integration_operator_part
                .gen_fp16_inference
                .u_fp16_inference_adapter
                .u_fp16_inference_top
                .u_fp16_embedding
                .sram_rd_valid &&
            u_control_chip_stage2_single_chiplet
                .u_integration_operator_part
                .gen_fp16_inference
                .u_fp16_inference_adapter
                .u_fp16_inference_top
                .u_fp16_embedding
                .sram_rd_ready &&
            (u_control_chip_stage2_single_chiplet
                 .u_integration_operator_part
                 .gen_fp16_inference
                 .u_fp16_inference_adapter
                 .u_fp16_inference_top
                 .u_fp16_embedding
                 .beat_idx_r == 16'd0)) begin
            $fwrite(
                event_fd,
                "{\"cycle\":%0d,\"event\":\"fp16_embedding_read\",\"source\":\"rtl\",\"read_addr_hex\":\"0x%0h\"}\n",
                cycle_count_r,
                u_control_chip_stage2_single_chiplet
                    .u_integration_operator_part
                    .gen_fp16_inference
                    .u_fp16_inference_adapter
                    .u_fp16_inference_top
                    .u_fp16_embedding
                    .sram_rd_addr
            );
            $fflush(event_fd);
        end

        if (u_control_chip_stage2_single_chiplet
                .u_integration_operator_part
                .gen_fp16_inference
                .u_fp16_inference_adapter
                .u_fp16_inference_top
                .u_fp16_embedding
                .sram_resp_valid &&
            u_control_chip_stage2_single_chiplet
                .u_integration_operator_part
                .gen_fp16_inference
                .u_fp16_inference_adapter
                .u_fp16_inference_top
                .u_fp16_embedding
                .sram_resp_ready &&
            !fp16_embedding_resp_logged_r &&
            (u_control_chip_stage2_single_chiplet
                 .u_integration_operator_part
                 .gen_fp16_inference
                 .u_fp16_inference_adapter
                 .u_fp16_inference_top
                 .u_fp16_embedding
                 .beat_idx_r == 16'd0)) begin
            fp16_embedding_resp_logged_r <= 1'b1;
            $fwrite(
                event_fd,
                "{\"cycle\":%0d,\"event\":\"fp16_embedding_resp\",\"source\":\"rtl\",\"beat_index\":%0d,\"data_hex\":\"%0h\"}\n",
                cycle_count_r,
                u_control_chip_stage2_single_chiplet
                    .u_integration_operator_part
                    .gen_fp16_inference
                    .u_fp16_inference_adapter
                    .u_fp16_inference_top
                    .u_fp16_embedding
                    .beat_idx_r,
                u_control_chip_stage2_single_chiplet
                    .u_integration_operator_part
                    .gen_fp16_inference
                    .u_fp16_inference_adapter
                    .u_fp16_inference_top
                    .u_fp16_embedding
                    .sram_resp_data
            );
            $fflush(event_fd);
        end

        if (u_control_chip_stage2_single_chiplet
                .u_integration_operator_part
                .gen_fp16_inference
                .u_fp16_inference_adapter
                .u_fp16_inference_top
                .scheduler_wr_valid_w &&
            u_control_chip_stage2_single_chiplet
                .u_integration_operator_part
                .gen_fp16_inference
                .u_fp16_inference_adapter
                .u_fp16_inference_top
                .sram_wr_ready &&
            !fp16_layer_result_write_logged_r &&
            (u_control_chip_stage2_single_chiplet
                 .u_integration_operator_part
                 .gen_fp16_inference
                 .u_fp16_inference_adapter
                 .u_fp16_inference_top
                 .u_fp16_layer_scheduler
                 .state_r == 4'd6)) begin
            fp16_layer_result_write_logged_r <= 1'b1;
            $fwrite(
                event_fd,
                "{\"cycle\":%0d,\"event\":\"fp16_layer_result_write\",\"source\":\"rtl\",\"layer_index\":%0d,\"addr_hex\":\"0x%0h\",\"data_hex\":\"%0h\"}\n",
                cycle_count_r,
                u_control_chip_stage2_single_chiplet
                    .u_integration_operator_part
                    .gen_fp16_inference
                    .u_fp16_inference_adapter
                    .u_fp16_inference_top
                    .u_fp16_layer_scheduler
                    .layer_idx_r,
                u_control_chip_stage2_single_chiplet
                    .u_integration_operator_part
                    .gen_fp16_inference
                    .u_fp16_inference_adapter
                    .u_fp16_inference_top
                    .scheduler_wr_addr_w,
                u_control_chip_stage2_single_chiplet
                    .u_integration_operator_part
                    .gen_fp16_inference
                    .u_fp16_inference_adapter
                    .u_fp16_inference_top
                    .scheduler_wr_data_w
            );
            $fflush(event_fd);
        end

        if (u_control_chip_stage2_single_chiplet
                .u_integration_operator_part
                .gen_fp16_inference
                .u_fp16_inference_adapter
                .u_fp16_inference_top
                .u_fp16_final_rmsnorm
                .sram_resp_valid &&
            u_control_chip_stage2_single_chiplet
                .u_integration_operator_part
                .gen_fp16_inference
                .u_fp16_inference_adapter
                .u_fp16_inference_top
                .u_fp16_final_rmsnorm
                .sram_resp_ready &&
            !fp16_final_norm_x_read_logged_r &&
            ((u_control_chip_stage2_single_chiplet
                  .u_integration_operator_part
                  .gen_fp16_inference
                  .u_fp16_inference_adapter
                  .u_fp16_inference_top
                  .u_fp16_final_rmsnorm
                  .state_r == 4'd1) ||
             (u_control_chip_stage2_single_chiplet
                  .u_integration_operator_part
                  .gen_fp16_inference
                  .u_fp16_inference_adapter
                  .u_fp16_inference_top
                  .u_fp16_final_rmsnorm
                  .state_r == 4'd2)) &&
            (u_control_chip_stage2_single_chiplet
                 .u_integration_operator_part
                 .gen_fp16_inference
                 .u_fp16_inference_adapter
                 .u_fp16_inference_top
                 .u_fp16_final_rmsnorm
                 .beat_idx_r == 16'd0)) begin
            fp16_final_norm_x_read_logged_r <= 1'b1;
            $fwrite(
                event_fd,
                "{\"cycle\":%0d,\"event\":\"fp16_final_norm_x_read\",\"source\":\"rtl\",\"beat_index\":%0d,\"addr_hex\":\"0x%0h\",\"data_hex\":\"%0h\"}\n",
                cycle_count_r,
                u_control_chip_stage2_single_chiplet
                    .u_integration_operator_part
                    .gen_fp16_inference
                    .u_fp16_inference_adapter
                    .u_fp16_inference_top
                    .u_fp16_final_rmsnorm
                    .beat_idx_r,
                u_control_chip_stage2_single_chiplet
                    .u_integration_operator_part
                    .gen_fp16_inference
                    .u_fp16_inference_adapter
                    .u_fp16_inference_top
                    .u_fp16_final_rmsnorm
                    .x_addr_r,
                u_control_chip_stage2_single_chiplet
                    .u_integration_operator_part
                    .gen_fp16_inference
                    .u_fp16_inference_adapter
                    .u_fp16_inference_top
                    .u_fp16_final_rmsnorm
                    .sram_resp_data
            );
            $fflush(event_fd);
        end

        if (u_control_chip_stage2_single_chiplet
                .u_integration_operator_part
                .gen_fp16_inference
                .u_fp16_inference_adapter
                .u_fp16_inference_top
                .u_fp16_final_rmsnorm
                .sram_resp_valid &&
            u_control_chip_stage2_single_chiplet
                .u_integration_operator_part
                .gen_fp16_inference
                .u_fp16_inference_adapter
                .u_fp16_inference_top
                .u_fp16_final_rmsnorm
                .sram_resp_ready &&
            !fp16_final_norm_gamma_read_logged_r &&
            ((u_control_chip_stage2_single_chiplet
                  .u_integration_operator_part
                  .gen_fp16_inference
                  .u_fp16_inference_adapter
                  .u_fp16_inference_top
                  .u_fp16_final_rmsnorm
                  .state_r == 4'd6) ||
             (u_control_chip_stage2_single_chiplet
                  .u_integration_operator_part
                  .gen_fp16_inference
                  .u_fp16_inference_adapter
                  .u_fp16_inference_top
                  .u_fp16_final_rmsnorm
                  .state_r == 4'd7)) &&
            (u_control_chip_stage2_single_chiplet
                 .u_integration_operator_part
                 .gen_fp16_inference
                 .u_fp16_inference_adapter
                 .u_fp16_inference_top
                 .u_fp16_final_rmsnorm
                 .beat_idx_r == 16'd0)) begin
            fp16_final_norm_gamma_read_logged_r <= 1'b1;
            $fwrite(
                event_fd,
                "{\"cycle\":%0d,\"event\":\"fp16_final_norm_gamma_read\",\"source\":\"rtl\",\"beat_index\":%0d,\"addr_hex\":\"0x%0h\",\"data_hex\":\"%0h\"}\n",
                cycle_count_r,
                u_control_chip_stage2_single_chiplet
                    .u_integration_operator_part
                    .gen_fp16_inference
                    .u_fp16_inference_adapter
                    .u_fp16_inference_top
                    .u_fp16_final_rmsnorm
                    .beat_idx_r,
                u_control_chip_stage2_single_chiplet
                    .u_integration_operator_part
                    .gen_fp16_inference
                    .u_fp16_inference_adapter
                    .u_fp16_inference_top
                    .u_fp16_final_rmsnorm
                    .gamma_addr_r,
                u_control_chip_stage2_single_chiplet
                    .u_integration_operator_part
                    .gen_fp16_inference
                    .u_fp16_inference_adapter
                    .u_fp16_inference_top
                    .u_fp16_final_rmsnorm
                    .sram_resp_data
            );
            $fflush(event_fd);
        end

        if (u_control_chip_stage2_single_chiplet
                .u_integration_operator_part
                .gen_fp16_inference
                .u_fp16_inference_adapter
                .u_fp16_inference_top
                .norm_wr_valid_w &&
            u_control_chip_stage2_single_chiplet
                .u_integration_operator_part
                .gen_fp16_inference
                .u_fp16_inference_adapter
                .u_fp16_inference_top
                .sram_wr_ready &&
            !fp16_final_hidden_write_logged_r &&
            (u_control_chip_stage2_single_chiplet
                 .u_integration_operator_part
                 .gen_fp16_inference
                 .u_fp16_inference_adapter
                 .u_fp16_inference_top
                 .norm_wr_addr_w >= FP16_WORK_FINAL_BASE)) begin
            fp16_final_hidden_write_logged_r <= 1'b1;
            $fwrite(
                event_fd,
                "{\"cycle\":%0d,\"event\":\"fp16_final_hidden_write\",\"source\":\"rtl\",\"beat_index\":%0d,\"addr_hex\":\"0x%0h\",\"data_hex\":\"%0h\"}\n",
                cycle_count_r,
                u_control_chip_stage2_single_chiplet
                    .u_integration_operator_part
                    .gen_fp16_inference
                    .u_fp16_inference_adapter
                    .u_fp16_inference_top
                    .norm_wr_addr_w - FP16_WORK_FINAL_BASE,
                u_control_chip_stage2_single_chiplet
                    .u_integration_operator_part
                    .gen_fp16_inference
                    .u_fp16_inference_adapter
                    .u_fp16_inference_top
                    .norm_wr_addr_w,
                u_control_chip_stage2_single_chiplet
                    .u_integration_operator_part
                    .gen_fp16_inference
                    .u_fp16_inference_adapter
                    .u_fp16_inference_top
                    .norm_wr_data_w
            );
            $fflush(event_fd);
        end

        if (u_control_chip_stage2_single_chiplet
                .u_integration_operator_part
                .gen_fp16_inference
                .u_fp16_inference_adapter
                .u_fp16_inference_top
                .u_fp16_lm_head
                .issue_valid &&
            u_control_chip_stage2_single_chiplet
                .u_integration_operator_part
                .gen_fp16_inference
                .u_fp16_inference_adapter
                .u_fp16_inference_top
                .u_fp16_lm_head
                .issue_ready) begin
            $fwrite(
                event_fd,
                "{\"cycle\":%0d,\"event\":\"fp16_lm_issue\",\"source\":\"rtl\",\"hidden_addr_hex\":\"0x%0h\",\"weight_addr_hex\":\"0x%0h\"}\n",
                cycle_count_r,
                u_control_chip_stage2_single_chiplet
                    .u_integration_operator_part
                    .gen_fp16_inference
                    .u_fp16_inference_adapter
                    .u_fp16_inference_top
                    .u_fp16_lm_head
                    .issue_hidden_addr,
                u_control_chip_stage2_single_chiplet
                    .u_integration_operator_part
                    .gen_fp16_inference
                    .u_fp16_inference_adapter
                    .u_fp16_inference_top
                    .u_fp16_lm_head
                    .issue_emb_weight_addr
            );
            $fflush(event_fd);
        end

        if (u_control_chip_stage2_single_chiplet
                .u_integration_operator_part
                .gen_fp16_inference
                .u_fp16_inference_adapter
                .u_fp16_inference_top
                .u_fp16_lm_head
                .sram_resp_valid &&
            u_control_chip_stage2_single_chiplet
                .u_integration_operator_part
                .gen_fp16_inference
                .u_fp16_inference_adapter
                .u_fp16_inference_top
                .u_fp16_lm_head
                .sram_resp_ready &&
            !fp16_lm_hidden_read_logged_r &&
            ((u_control_chip_stage2_single_chiplet
                  .u_integration_operator_part
                  .gen_fp16_inference
                  .u_fp16_inference_adapter
                  .u_fp16_inference_top
                  .u_fp16_lm_head
                  .state_r == 4'd1) ||
             (u_control_chip_stage2_single_chiplet
                  .u_integration_operator_part
                  .gen_fp16_inference
                  .u_fp16_inference_adapter
                  .u_fp16_inference_top
                  .u_fp16_lm_head
                  .state_r == 4'd2)) &&
            (u_control_chip_stage2_single_chiplet
                 .u_integration_operator_part
                 .gen_fp16_inference
                 .u_fp16_inference_adapter
                 .u_fp16_inference_top
                 .u_fp16_lm_head
                 .hidden_beat_idx_r == 16'd0)) begin
            fp16_lm_hidden_read_logged_r <= 1'b1;
            $fwrite(
                event_fd,
                "{\"cycle\":%0d,\"event\":\"fp16_lm_hidden_read\",\"source\":\"rtl\",\"beat_index\":%0d,\"data_hex\":\"%0h\"}\n",
                cycle_count_r,
                u_control_chip_stage2_single_chiplet
                    .u_integration_operator_part
                    .gen_fp16_inference
                    .u_fp16_inference_adapter
                    .u_fp16_inference_top
                    .u_fp16_lm_head
                    .hidden_beat_idx_r,
                u_control_chip_stage2_single_chiplet
                    .u_integration_operator_part
                    .gen_fp16_inference
                    .u_fp16_inference_adapter
                    .u_fp16_inference_top
                    .u_fp16_lm_head
                    .sram_resp_data
            );
            $fflush(event_fd);
        end

        if (u_control_chip_stage2_single_chiplet
                .u_integration_operator_part
                .gen_fp16_inference
                .u_fp16_inference_adapter
                .u_fp16_inference_top
                .u_fp16_lm_head
                .sram_resp_valid &&
            u_control_chip_stage2_single_chiplet
                .u_integration_operator_part
                .gen_fp16_inference
                .u_fp16_inference_adapter
                .u_fp16_inference_top
                .u_fp16_lm_head
                .sram_resp_ready &&
            !fp16_lm_weight_read_logged_r &&
            ((u_control_chip_stage2_single_chiplet
                  .u_integration_operator_part
                  .gen_fp16_inference
                  .u_fp16_inference_adapter
                  .u_fp16_inference_top
                  .u_fp16_lm_head
                  .state_r == 4'd4) ||
             (u_control_chip_stage2_single_chiplet
                  .u_integration_operator_part
                  .gen_fp16_inference
                  .u_fp16_inference_adapter
                  .u_fp16_inference_top
                  .u_fp16_lm_head
                  .state_r == 4'd5)) &&
            (u_control_chip_stage2_single_chiplet
                 .u_integration_operator_part
                 .gen_fp16_inference
                 .u_fp16_inference_adapter
                 .u_fp16_inference_top
                 .u_fp16_lm_head
                 .weight_beat_idx_r == 16'd0)) begin
            fp16_lm_weight_read_logged_r <= 1'b1;
            $fwrite(
                event_fd,
                "{\"cycle\":%0d,\"event\":\"fp16_lm_weight_read\",\"source\":\"rtl\",\"beat_index\":%0d,\"data_hex\":\"%0h\"}\n",
                cycle_count_r,
                u_control_chip_stage2_single_chiplet
                    .u_integration_operator_part
                    .gen_fp16_inference
                    .u_fp16_inference_adapter
                    .u_fp16_inference_top
                    .u_fp16_lm_head
                    .weight_beat_idx_r,
                u_control_chip_stage2_single_chiplet
                    .u_integration_operator_part
                    .gen_fp16_inference
                    .u_fp16_inference_adapter
                    .u_fp16_inference_top
                    .u_fp16_lm_head
                    .sram_resp_data
            );
            $fflush(event_fd);
        end

        if (u_control_chip_stage2_single_chiplet
                .u_tree_parallel_batch_inference_top
                .u_fp16_lm_head
                .issue_valid &&
            u_control_chip_stage2_single_chiplet
                .u_tree_parallel_batch_inference_top
                .u_fp16_lm_head
                .issue_ready) begin
            $fwrite(
                event_fd,
                "{\"cycle\":%0d,\"event\":\"tree_parallel_seed_lm_issue\",\"source\":\"rtl\",\"hidden_addr_hex\":\"0x%0h\",\"weight_addr_hex\":\"0x%0h\"}\n",
                cycle_count_r,
                u_control_chip_stage2_single_chiplet
                    .u_tree_parallel_batch_inference_top
                    .u_fp16_lm_head
                    .issue_hidden_addr,
                u_control_chip_stage2_single_chiplet
                    .u_tree_parallel_batch_inference_top
                    .u_fp16_lm_head
                    .issue_emb_weight_addr
            );
            $fflush(event_fd);
        end

        if (u_control_chip_stage2_single_chiplet
                .u_integration_operator_part
                .gen_fp16_inference
                .u_fp16_inference_adapter
                .fp16_token_out_valid_w &&
            u_control_chip_stage2_single_chiplet
                .u_integration_operator_part
                .gen_fp16_inference
                .u_fp16_inference_adapter
                .fp16_token_out_ready_w) begin
            $fwrite(
                event_fd,
                "{\"cycle\":%0d,\"event\":\"fp16_token_out\",\"source\":\"rtl\",\"token_out_hex\":\"0x%0h\"}\n",
                cycle_count_r,
                u_control_chip_stage2_single_chiplet
                    .u_integration_operator_part
                    .gen_fp16_inference
                    .u_fp16_inference_adapter
                    .fp16_token_out_id_w
            );
        end

        if (u_control_chip_stage2_single_chiplet
                .u_tree_parallel_batch_inference_top
                .lm_result_valid_w &&
            u_control_chip_stage2_single_chiplet
                .u_tree_parallel_batch_inference_top
                .lm_result_ready_w) begin
            $fwrite(
                event_fd,
                "{\"cycle\":%0d,\"event\":\"tree_parallel_logits_seed\",\"source\":\"rtl\",\"token_hex\":\"0x%0h\",\"logit_hex\":\"0x%0h\"}\n",
                cycle_count_r,
                u_control_chip_stage2_single_chiplet
                    .u_tree_parallel_batch_inference_top
                    .lm_result_token_id_w,
                u_control_chip_stage2_single_chiplet
                    .u_tree_parallel_batch_inference_top
                    .lm_result_logit_w
            );
            $fflush(event_fd);
        end

        for (tree_parallel_lane_i = 0;
             tree_parallel_lane_i < `MEM_REQ_LANES;
             tree_parallel_lane_i = tree_parallel_lane_i + 1) begin
            if (u_control_chip_stage2_single_chiplet
                    .u_tree_parallel_batch_inference_top
                    .batch_lm_draft_result_valid_w[tree_parallel_lane_i] &&
                u_control_chip_stage2_single_chiplet
                    .u_tree_parallel_batch_inference_top
                    .batch_lm_draft_result_ready_w[tree_parallel_lane_i]) begin
                $fwrite(
                    event_fd,
                    "{\"cycle\":%0d,\"event\":\"tree_parallel_logits_draft\",\"source\":\"rtl\",\"lane\":%0d,\"token_hex\":\"0x%0h\",\"logit_hex\":\"0x%0h\"}\n",
                    cycle_count_r,
                    tree_parallel_lane_i,
                    u_control_chip_stage2_single_chiplet
                        .u_tree_parallel_batch_inference_top
                        .batch_lm_draft_result_token_id_w[
                            tree_parallel_lane_i*32 +: 32],
                    u_control_chip_stage2_single_chiplet
                        .u_tree_parallel_batch_inference_top
                        .batch_lm_draft_result_logit_w[
                            tree_parallel_lane_i*16 +: 16]
                );
                $fflush(event_fd);
            end
        end

        if (u_control_chip_stage2_single_chiplet.operator_result_valid_w &&
            u_control_chip_stage2_single_chiplet.operator_result_ready_w) begin
            $fwrite(
                event_fd,
                "{\"cycle\":%0d,\"event\":\"operator_result\",\"source\":\"rtl\",\"token_id_hex\":\"0x%0h\",\"addr_hex\":\"0x%0h\"}\n",
                cycle_count_r,
                u_control_chip_stage2_single_chiplet.operator_result_token_id_w,
                u_control_chip_stage2_single_chiplet.operator_result_addr_w
            );
        end

        if (u_control_chip_stage2_single_chiplet.commit_valid) begin
            $fwrite(
                event_fd,
                "{\"cycle\":%0d,\"event\":\"lifecycle_commit\",\"source\":\"rtl\",\"branch_id\":%0d,\"branch_mask_hex\":\"0x%0h\",\"accepted_prefix_depth\":%0d}\n",
                cycle_count_r,
                u_control_chip_stage2_single_chiplet.lifecycle_commit_select_branch_comb,
                u_control_chip_stage2_single_chiplet.commit_branch_mask,
                u_control_chip_stage2_single_chiplet.accepted_prefix_depth
            );
            if (u_control_chip_stage2_single_chiplet.tree_parallel_mode_w) begin
                $fwrite(
                    event_fd,
                    "{\"cycle\":%0d,\"event\":\"bonus_token\",\"source\":\"rtl\",\"token_id_hex\":\"0x%0h\"}\n",
                    cycle_count_r,
                    u_control_chip_stage2_single_chiplet.tree_parallel_commit_bonus_token_id_w
                );
            end
        end

        if (u_control_chip_stage2_single_chiplet.flush_valid) begin
            integer flush_branch_i;
            for (flush_branch_i = 0;
                 flush_branch_i < `BRANCH_NUM;
                 flush_branch_i = flush_branch_i + 1) begin
                if (u_control_chip_stage2_single_chiplet.flush_branch_mask[flush_branch_i]) begin
                    $fwrite(
                        event_fd,
                        "{\"cycle\":%0d,\"event\":\"lifecycle_flush\",\"source\":\"rtl\",\"branch_id\":%0d,\"branch_mask_hex\":\"0x%0h\"}\n",
                        cycle_count_r,
                        flush_branch_i,
                        u_control_chip_stage2_single_chiplet.flush_branch_mask
                    );
                end
            end
        end

        if (u_control_chip_stage2_single_chiplet.accepted_prefix_valid) begin
            $fwrite(
                event_fd,
                "{\"cycle\":%0d,\"event\":\"accepted_prefix\",\"source\":\"rtl\",\"accepted_prefix_depth\":%0d}\n",
                cycle_count_r,
                u_control_chip_stage2_single_chiplet.accepted_prefix_depth
            );
            if (u_control_chip_stage2_single_chiplet.tree_parallel_mode_w) begin
                integer accepted_prefix_idx_i;
                for (accepted_prefix_idx_i = 0;
                     accepted_prefix_idx_i <
                        u_control_chip_stage2_single_chiplet.accepted_prefix_depth;
                     accepted_prefix_idx_i = accepted_prefix_idx_i + 1) begin
                    $fwrite(
                        event_fd,
                        "{\"cycle\":%0d,\"event\":\"accepted_token\",\"source\":\"rtl\",\"token_id_hex\":\"0x%0h\",\"level_index\":%0d}\n",
                        cycle_count_r,
                        u_control_chip_stage2_single_chiplet
                            .u_tree_verify_dispatcher
                            .lat_slot_token_id[
                                u_control_chip_stage2_single_chiplet
                                    .tree_parallel_commit_slots_w[
                                        (accepted_prefix_idx_i*`SLOT_ID_W) +:
                                        `SLOT_ID_W
                                    ] * `TOKEN_ID_W +:
                                `TOKEN_ID_W
                            ],
                        accepted_prefix_idx_i
                    );
                end
            end
        end

        if (u_control_chip_stage2_single_chiplet.accepted_token_fire_w) begin
            $fwrite(
                event_fd,
                "{\"cycle\":%0d,\"event\":\"accepted_token\",\"source\":\"rtl\",\"token_id_hex\":\"0x%0h\",\"position_hex\":\"0x%0h\"}\n",
                cycle_count_r,
                u_control_chip_stage2_single_chiplet.hht_active_token_id_r,
                u_control_chip_stage2_single_chiplet.accepted_position_w
            );
            $fwrite(
                event_fd,
                "{\"cycle\":%0d,\"event\":\"bonus_token\",\"source\":\"rtl\",\"token_id_hex\":\"0x%0h\"}\n",
                cycle_count_r,
                u_control_chip_stage2_single_chiplet.wb_generated_token_id_w
            );
        end

        if (u_control_chip_stage2_single_chiplet.token_flush_valid) begin
            integer token_flush_branch_i;
            integer token_flush_count_i;
            token_flush_count_i = 0;
            for (token_flush_branch_i = 0;
                 token_flush_branch_i < `BRANCH_NUM;
                 token_flush_branch_i = token_flush_branch_i + 1) begin
                if (u_control_chip_stage2_single_chiplet.token_flush_branch_mask[token_flush_branch_i])
                    token_flush_count_i = token_flush_count_i + 1;
            end
            $fwrite(
                event_fd,
                "{\"cycle\":%0d,\"event\":\"token_flush\",\"source\":\"rtl\",\"count\":%0d,\"branch_mask_hex\":\"0x%0h\"}\n",
                cycle_count_r,
                token_flush_count_i,
                u_control_chip_stage2_single_chiplet.token_flush_branch_mask
            );
        end

        if (u_control_chip_stage2_single_chiplet.flush_reclaim_valid) begin
            $fwrite(
                event_fd,
                "{\"cycle\":%0d,\"event\":\"flush_reclaim\",\"source\":\"rtl\",\"group_len\":%0d,\"count\":%0d}\n",
                cycle_count_r,
                u_control_chip_stage2_single_chiplet.flush_reclaim_group_len,
                u_control_chip_stage2_single_chiplet.flush_reclaim_group_len
            );
        end

        if (tree_window_valid && tree_window_ready) begin
            $fwrite(
                event_fd,
                "{\"cycle\":%0d,\"event\":\"tree_window\",\"source\":\"rtl\",\"parent_node_id_hex\":\"0x%0h\",\"slot_valid_hex\":\"0x%0h\",\"token_bus_hex\":\"0x%0h\"}\n",
                cycle_count_r,
                tree_window_parent_node_id,
                tree_window_slot_valid,
                tree_window_token_id
            );
        end

        if (recompute_req_valid && recompute_req_ready) begin
            $fwrite(
                event_fd,
                "{\"cycle\":%0d,\"event\":\"recompute_req\",\"source\":\"rtl\",\"token_id_hex\":\"0x%0h\",\"current_position_hex\":\"0x%0h\",\"referenced_position_hex\":\"0x%0h\",\"branch_id_hex\":\"0x%0h\",\"reason_stale\":%0d}\n",
                cycle_count_r,
                recompute_req_token_id,
                recompute_req_current_position,
                recompute_req_referenced_position,
                recompute_req_branch_id,
                recompute_req_reason_stale
            );
        end

        if (tree_parallel_strict_capture_valid_r &&
            u_control_chip_stage2_single_chiplet.tree_parallel_fwd_result_valid_w &&
            u_control_chip_stage2_single_chiplet.tree_parallel_fwd_result_ready_w) begin
            $fwrite(
                event_fd,
                "{\"cycle\":%0d,\"event\":\"tree_parallel_fwd_result\",\"source\":\"rtl\",\"count\":%0d,\"token0_hex\":\"0x%0h\",\"token1_hex\":\"0x%0h\",\"token2_hex\":\"0x%0h\",\"token3_hex\":\"0x%0h\"}\n",
                cycle_count_r,
                u_control_chip_stage2_single_chiplet.tree_parallel_fwd_result_count_w,
                u_control_chip_stage2_single_chiplet
                    .tree_parallel_fwd_result_token_ids_w[0 +: `TOKEN_ID_W],
                u_control_chip_stage2_single_chiplet
                    .tree_parallel_fwd_result_token_ids_w[32 +: `TOKEN_ID_W],
                u_control_chip_stage2_single_chiplet
                    .tree_parallel_fwd_result_token_ids_w[64 +: `TOKEN_ID_W],
                u_control_chip_stage2_single_chiplet
                    .tree_parallel_fwd_result_token_ids_w[96 +: `TOKEN_ID_W]
            );
            $fflush(event_fd);
            $fwrite(
                event_fd,
                "{\"cycle\":%0d,\"event\":\"verify_group_done\",\"source\":\"rtl\",\"level_index\":%0d}\n",
                cycle_count_r,
                strict_capture_index_r - strict_capture_index_base_r
            );
            $fflush(event_fd);
            dump_tree_parallel_strict_capture();
            tree_parallel_strict_capture_valid_r <= 1'b0;
        end

        if (wb_valid && wb_ready) begin
            $fwrite(
                event_fd,
                "{\"cycle\":%0d,\"event\":\"wb\",\"source\":\"rtl\",\"token_id_hex\":\"0x%0h\",\"addr_hex\":\"0x%0h\",\"data_hex\":\"%0h\",\"status_hex\":\"0x%0h\"}\n",
                cycle_count_r,
                wb_token_id,
                wb_addr,
                wb_data,
                wb_status
            );
        end

        if (wb_done) begin
            wb_done_seen_r <= 1'b1;
            if (strict_capture_active_r) begin
                dump_strict_hidden_and_token(
                    strict_capture_index_r,
                    strict_branch_slot_r,
                    strict_capture_query_token_r
                );
                strict_capture_active_r <= 1'b0;
                if (!strict_capture_tree_mask_en_r) begin
                    strict_capture_index_r <= strict_capture_index_r + 1;
                end else if (strict_branch_slot_r == (`BRANCH_NUM - 1)) begin
                    $fwrite(
                        event_fd,
                        "{\"cycle\":%0d,\"event\":\"verify_group_done\",\"source\":\"rtl\",\"level_index\":%0d}\n",
                        cycle_count_r,
                        strict_capture_index_r - strict_capture_index_base_r
                    );
                    $fflush(event_fd);
                    strict_capture_index_r <= strict_capture_index_r + 1;
                end
            end
            $fwrite(
                event_fd,
                "{\"cycle\":%0d,\"event\":\"wb_done\",\"source\":\"rtl\",\"token_id_hex\":\"0x%0h\",\"wb_error\":%0d}\n",
                cycle_count_r,
                u_control_chip_stage2_single_chiplet.wb_generated_token_id_w,
                wb_error
            );
            $fflush(event_fd);
        end

        if (hbm_req_valid && hbm_req_write) begin
            hbm_write_seen_r <= 1'b1;
            $fwrite(
                event_fd,
                "{\"cycle\":%0d,\"event\":\"hbm_write\",\"source\":\"rtl\",\"addr_hex\":\"0x%0h\",\"data_hex\":\"%0h\",\"req_id\":%0d}\n",
                cycle_count_r,
                hbm_req_addr,
                hbm_req_wdata,
                hbm_req_id
            );
        end

        if (error_flag) begin
            $fatal(1, "29 native tree main frontend platform driver observed error_flag");
        end
    end
end

initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    event_fd = 0;
    stimulus_cycles = 0;
    max_post_stimulus_cycles = DEFAULT_MAX_POST_STIMULUS_CYCLES;
    drive_index_r = 0;
    drain_count_r = 0;
    cycle_count_r = 0;
    strict_capture_index_base_r = 0;
    cfg_start_seen_r = 1'b0;
    wb_done_seen_r = 1'b0;
    hbm_write_seen_r = 1'b0;
    hbm_auto_resp_pending_r = 1'b0;
    hbm_auto_resp_rdata_r = {`HBM_DATA_W{1'b0}};
    hbm_auto_resp_id_r = {`REQ_ID_W{1'b0}};
    strict_capture_index_r = 0;
    strict_branch_slot_r = 0;
    strict_capture_active_r = 1'b0;
    strict_capture_query_token_r = {`TOKEN_ID_W{1'b0}};
    strict_capture_branch_id_r = {`BRANCH_ID_W{1'b0}};
    strict_capture_tree_mask_en_r = 1'b0;
    tree_parallel_strict_capture_valid_r = 1'b0;
    for (tree_parallel_shadow_slot_i = 0;
         tree_parallel_shadow_slot_i < TREE_PARALLEL_CAPTURE_SLOTS;
         tree_parallel_shadow_slot_i = tree_parallel_shadow_slot_i + 1) begin
        for (tree_parallel_shadow_beat_i = 0;
             tree_parallel_shadow_beat_i < FP16_HIDDEN_BEATS;
             tree_parallel_shadow_beat_i = tree_parallel_shadow_beat_i + 1) begin
            tree_parallel_final_hidden_shadow[
                tree_parallel_shadow_slot_i][tree_parallel_shadow_beat_i] =
                {`SRAM_WDATA_W{1'b0}};
            tree_parallel_final_hidden_sram_shadow[
                tree_parallel_shadow_slot_i][tree_parallel_shadow_beat_i] =
                {`SRAM_WDATA_W{1'b0}};
        end
    end
    for (strict_dump_idx_i = 0;
         strict_dump_idx_i < FP16_HIDDEN_BEATS;
         strict_dump_idx_i = strict_dump_idx_i + 1) begin
        strict_final_hidden_sram_shadow[strict_dump_idx_i] =
            {`SRAM_WDATA_W{1'b0}};
    end
    clear_driven_inputs();

    if (!$value$plusargs("stimulus_memh=%s", stimulus_memh_path)) begin
        $fatal(1, "29 missing +stimulus_memh=<path>");
    end
    if (!$value$plusargs("stimulus_cycles=%d", stimulus_cycles)) begin
        $fatal(1, "29 missing +stimulus_cycles=<n>");
    end
    if (!$value$plusargs("events_jsonl=%s", events_jsonl_path)) begin
        $fatal(1, "29 missing +events_jsonl=<path>");
    end
    if (!$value$plusargs("toy_model_memh_dir=%s", toy_model_memh_dir_path)) begin
        $fatal(1, "29 missing +toy_model_memh_dir=<path>");
    end
    if (!$value$plusargs("strict_capture_index_base=%d",
                         strict_capture_index_base_r)) begin
        strict_capture_index_base_r = 0;
    end
    if (!$value$plusargs("max_post_stimulus_cycles=%d",
                         max_post_stimulus_cycles)) begin
        max_post_stimulus_cycles = DEFAULT_MAX_POST_STIMULUS_CYCLES;
    end
    if (stimulus_cycles <= 0 || stimulus_cycles > STIMULUS_DEPTH) begin
        $fatal(1, "29 invalid stimulus_cycles=%0d", stimulus_cycles);
    end
    if (max_post_stimulus_cycles <= 0) begin
        $fatal(1, "29 invalid max_post_stimulus_cycles=%0d",
               max_post_stimulus_cycles);
    end

    preload_memh_path_r = {toy_model_memh_dir_path, "/sram_preload.memh"};
    hbm_memh_path_r = {toy_model_memh_dir_path, "/hbm_weights.memh"};
    token_path_r = {toy_model_memh_dir_path, "/ref_token_id.txt"};
    toy_model_fd_i = $fopen(preload_memh_path_r, "r");
    if (toy_model_fd_i == 0) begin
        $fatal(1, "29 failed to locate sram_preload.memh under %0s",
               toy_model_memh_dir_path);
    end
    $fclose(toy_model_fd_i);
    toy_model_fd_i = $fopen(hbm_memh_path_r, "r");
    if (toy_model_fd_i == 0) begin
        $fatal(1, "29 failed to locate hbm_weights.memh under %0s",
               toy_model_memh_dir_path);
    end
    $fclose(toy_model_fd_i);
    toy_model_fd_i = $fopen(token_path_r, "r");
    if (toy_model_fd_i == 0) begin
        $fatal(1, "29 failed to locate ref_token_id.txt under %0s",
               toy_model_memh_dir_path);
    end
    $fclose(toy_model_fd_i);

    event_fd = $fopen(events_jsonl_path, "w");
    if (event_fd == 0) begin
        $fatal(1, "29 failed to open events_jsonl_path=%0s", events_jsonl_path);
    end

    $readmemh(stimulus_memh_path, stimulus_mem);

    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    strict_capture_index_r = strict_capture_index_base_r;
    preload_toy_model_memh_once();

    for (drive_index_r = 0; drive_index_r < stimulus_cycles; drive_index_r = drive_index_r + 1) begin
        @(negedge clk);
        apply_stimulus_word(stimulus_mem[drive_index_r]);
    end

    for (drain_count_r = 0;
         drain_count_r < max_post_stimulus_cycles;
         drain_count_r = drain_count_r + 1) begin
        @(negedge clk);
        clear_driven_inputs();
        recompute_req_ready = 1'b1;
        wb_ready = 1'b1;
        drive_auto_hbm_response();
        if (cfg_start_seen_r &&
            wb_done_seen_r &&
            hbm_write_seen_r &&
            (busy === 1'b0)) begin
            drain_count_r = max_post_stimulus_cycles;
        end
    end

    if (!cfg_start_seen_r) begin
        $fatal(1, "29 platform driver never observed cfg_start");
    end
    if (!wb_done_seen_r || !hbm_write_seen_r || (busy !== 1'b0)) begin
        dump_tree_parallel_batch_debug_state();
    end
    if (!wb_done_seen_r) begin
        $fatal(1, "29 platform driver never observed wb_done");
    end
    if (!hbm_write_seen_r) begin
        $fatal(1, "29 platform driver never observed hbm_write");
    end
    if (busy !== 1'b0) begin
        $fatal(1, "29 platform driver did not return to idle before timeout");
    end

    write_finish_event();
    $fclose(event_fd);
    $display("tb_control_chip_stage2_single_chiplet_native_tree_main_frontend_platform_driver PASS");
    $finish;
end

endmodule
