`include "config/prediction_params.vh"
`include "config/interface_params.vh"
`include "config/memory_params.vh"
`include "config/model_params.vh"
`include "tree_control/NativeTreeMainFrontend.v"
`include "tree_control/multicast_network.v"
`include "tree_control/PredictionWindowSerialDispatcher.v"
`include "tree_control/kv_commit_copier.v"
`include "tree_control/tree_mask_generator.v"
`include "transformer/fp16_inference_top.sv"
`include "transformer/tree_verify_dispatcher.sv"
`timescale 1ns/1ps

module control_chip_stage2_single_chiplet #(
    parameter integer CFG_W = 32,
    parameter integer DRAFT_PORTS = 4,
    parameter integer CONF_W = 8,
    parameter integer MODEL_ID_W = 8,
    parameter integer OP_CLASS_W = 8,
    parameter integer TOKEN_LEN_W = 16,
    parameter integer RESULT_STATUS_W = 2,
    parameter integer ENABLE_MULTI_BRANCH_WINDOW = 1,
    parameter integer ENABLE_TREE_WINDOW_CONSUMER = 0,
    parameter integer ENABLE_OWNERSHIP_CLOSURE_SIDECAR = 0,
    parameter integer ENABLE_NATIVE_TREE_MAIN_FRONTEND = 0,
    parameter integer ENABLE_NATIVE_TREE_SIDECAR = 0,
    parameter integer ENABLE_TOP_HBM_WRITEBACK_SHIM = 0,
    parameter integer ENABLE_ONCHIP_HHT_CONTEXT = 0,
    parameter integer WINDOW_BRANCH_SLOTS = `TREE_FRONTIER_SLOTS,
    parameter integer ENABLE_DECODER_CHAIN = 1,
    parameter integer DECODER_DATA_WIDTH = 16,
    parameter integer DECODER_VECTOR_DIM = 4,
    parameter integer USE_FP16_GEMM = 0,
    parameter integer USE_FP16_INFERENCE_TOP = 0,
    parameter integer PRED_SOURCE_ID_W =
        ((DRAFT_PORTS + 1) <= 2) ? 1 : $clog2(DRAFT_PORTS + 1),
    parameter [`POSITION_ID_W-1:0] CURRENT_POSITION = 12'h040,
    parameter [`POSITION_ID_W-1:0] RECENCY_TH = 12'h010,
    parameter [`SRAM_ADDR_W-1:0] ISSUE_SRC_ADDR =
        {2'd0, 4'd2, 5'd6, 8'h00, 4'h0},
    parameter [`SRAM_ADDR_W-1:0] ISSUE_DST_ADDR =
        {2'd0, 4'd1, 5'd4, 8'h03, 4'h0}
) (
    input                             clk,
    input                             rst_n,
    input                             cfg_valid,
    input      [CFG_W-1:0]            cfg_data,
    input                             start,
    output                            busy,
    output                            error_flag,

    input                             hht_cand_valid,
    output                            hht_cand_ready,
    input      [`NODE_ID_W-1:0]       hht_parent_node_id,
    input      [`TOKEN_ID_W-1:0]      hht_token_id,
    input      [`TOKEN_ID_W-1:0]      hht_referenced_token_id,
    input      [`POSITION_ID_W-1:0]   hht_referenced_position,
    input      [CONF_W-1:0]           hht_confidence,

    input      [DRAFT_PORTS-1:0]      draft_cand_valid,
    output     [DRAFT_PORTS-1:0]      draft_cand_ready,
    input      [DRAFT_PORTS*`NODE_ID_W-1:0] draft_parent_node_id,
    input      [DRAFT_PORTS*`TOKEN_ID_W-1:0] draft_token_id,
    input      [DRAFT_PORTS*`TOKEN_ID_W-1:0] draft_referenced_token_id,
    input      [DRAFT_PORTS*`POSITION_ID_W-1:0] draft_referenced_position,
    input      [DRAFT_PORTS*CONF_W-1:0] draft_confidence,

    output                            tree_window_valid,
    input                             tree_window_ready,
    output     [`NODE_ID_W-1:0]       tree_window_parent_node_id,
    output     [WINDOW_BRANCH_SLOTS-1:0] tree_window_slot_valid,
    output     [WINDOW_BRANCH_SLOTS*PRED_SOURCE_ID_W-1:0] tree_window_source_id,
    output     [WINDOW_BRANCH_SLOTS*`TOKEN_ID_W-1:0] tree_window_token_id,
    output     [WINDOW_BRANCH_SLOTS*`TOKEN_ID_W-1:0] tree_window_referenced_token_id,
    output     [WINDOW_BRANCH_SLOTS*`POSITION_ID_W-1:0] tree_window_referenced_position,
    output     [WINDOW_BRANCH_SLOTS*CONF_W-1:0] tree_window_confidence,

    input                             native_tree_req_valid,
    output                            native_tree_req_ready,
    input      [`REQ_ID_W-1:0]        native_tree_req_id,
    input      [`TREE_MAX_PREFIX_NODES-1:0] native_tree_src_prefix_slot_valid,
    input      [`TREE_MAX_PREFIX_NODES*`NODE_ID_W-1:0]
               native_tree_src_prefix_node_id,
    input      [`TREE_MAX_PREFIX_NODES*`TOKEN_ID_W-1:0]
               native_tree_src_prefix_token_id,
    input      [`TREE_MAX_PREFIX_NODES*`POSITION_ID_W-1:0]
               native_tree_src_prefix_position_id,
    input      [`POSITION_ID_W-1:0]   native_tree_src_committed_len,
    input      [`TREE_MAX_FRONTIER_LEVELS-1:0]
               native_tree_src_frontier_level_valid,
    input      [`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS-1:0]
               native_tree_src_frontier_slot_valid,
    input      [`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0]
               native_tree_src_frontier_node_id,
    input      [`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0]
               native_tree_src_frontier_parent_node_id,
    input      [`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`TOKEN_ID_W-1:0]
               native_tree_src_frontier_token_id,
    input      [`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`TOKEN_ID_W-1:0]
               native_tree_src_frontier_referenced_token_id,
    input      [`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`POSITION_ID_W-1:0]
               native_tree_src_frontier_position_id,
    input      [`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`POSITION_ID_W-1:0]
               native_tree_src_frontier_referenced_position_id,
    input      [`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`BRANCH_ID_W-1:0]
               native_tree_src_frontier_branch_id,
    input      [`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`TREE_LEVEL_ID_W-1:0]
               native_tree_src_frontier_level_id,
    input      [`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS-1:0]
               native_tree_src_frontier_tree_mask_en,

    output                            recompute_req_valid,
    input                             recompute_req_ready,
    output     [`TOKEN_ID_W-1:0]      recompute_req_token_id,
    output     [`POSITION_ID_W-1:0]   recompute_req_current_position,
    output     [`POSITION_ID_W-1:0]   recompute_req_referenced_position,
    output     [`BRANCH_ID_W-1:0]     recompute_req_branch_id,
    output                            recompute_req_reason_stale,

    input                             recompute_resp_valid,
    output                            recompute_resp_ready,
    input                             recompute_resp_partial,
    input                             recompute_resp_full,
    input      [`REQ_ID_W-1:0]        recompute_resp_req_id,
    input      [`SRAM_WDATA_W-1:0]    recompute_resp_kv_data,
    input                             recompute_resp_last,

    input                             kv_lookup_valid,
    input      [`TOKEN_ID_W-1:0]      kv_lookup_token_id,
    input      [`POSITION_ID_W-1:0]   kv_lookup_position_id,
    output                            kv_lookup_ready,
    output                            kv_lookup_hit,
    output                            kv_lookup_partial_ready,
    output                            kv_lookup_full_ready,
    output     [`SRAM_ID_W-1:0]       kv_lookup_sram_id,
    output     [`BANK_ID_W-1:0]       kv_lookup_bank_id,
    output     [`SUBBANK_ID_W-1:0]    kv_lookup_subbank_start,
    output     [`KV_GROUP_LEN_W-1:0]  kv_lookup_group_len,

    output                            wb_valid,
    input                             wb_ready,
    output     [`TOKEN_ID_W-1:0]      wb_token_id,
    output     [`SRAM_ADDR_W-1:0]     wb_addr,
    output     [`SRAM_WDATA_W-1:0]    wb_data,
    output     [RESULT_STATUS_W-1:0]  wb_status,
    output                            wb_done,
    output                            wb_error,

    output                            debug_stale_hit,
    output                            debug_recompute_busy,
    output                            debug_recompute_done,
    output                            debug_decoder_qkv_valid,
    output                            debug_decoder_score_valid,
    output                            debug_decoder_softmax_valid,
    output                            debug_decoder_value_valid,
    output                            debug_decoder_ffn_valid,

    input                             hbm_resp_valid,
    input      [`HBM_DATA_W-1:0]      hbm_resp_rdata,
    input      [`REQ_ID_W-1:0]        hbm_resp_id,
    output                            hbm_req_valid,
    output                            hbm_req_write,
    output     [`HBM_ADDR_W-1:0]      hbm_req_addr,
    output     [`HBM_DATA_W-1:0]      hbm_req_wdata,
    output     [`REQ_ID_W-1:0]        hbm_req_id
);

wire pred_src_valid;
wire pred_src_ready;
wire [PRED_SOURCE_ID_W-1:0] pred_src_source_id;
wire [`NODE_ID_W-1:0] pred_src_parent_node_id;
wire [`TOKEN_ID_W-1:0] pred_src_token_id;
wire [`TOKEN_ID_W-1:0] pred_src_referenced_token_id;
wire [`POSITION_ID_W-1:0] pred_src_referenced_position;
wire [CONF_W-1:0] pred_src_confidence;
wire pred_src_is_last_in_window;

wire pred_valid;
wire pred_ready;
wire [PRED_SOURCE_ID_W-1:0] pred_source_id;
wire [`NODE_ID_W-1:0] pred_parent_node_id;
wire [`TOKEN_ID_W-1:0] pred_token_id;
wire [`TOKEN_ID_W-1:0] pred_referenced_token_id;
wire [`POSITION_ID_W-1:0] pred_referenced_position;
wire [CONF_W-1:0] pred_confidence;
wire pred_is_last_in_window;
wire [`BRANCH_ID_W-1:0] pred_branch_id_w;
wire [`TREE_LEVEL_ID_W-1:0] pred_level_id_w;
wire pred_tree_mask_en_w;
wire [15:0] pred_prefix_len_w;
wire [`TOY_MAX_POS_EMB-1:0] pred_visible_mask_w;

wire tree_window_src_valid;
wire tree_window_src_ready;
wire [`NODE_ID_W-1:0] tree_window_src_parent_node_id;
wire [WINDOW_BRANCH_SLOTS-1:0] tree_window_src_slot_valid;
wire [WINDOW_BRANCH_SLOTS*PRED_SOURCE_ID_W-1:0] tree_window_src_source_id;
wire [WINDOW_BRANCH_SLOTS*`TOKEN_ID_W-1:0] tree_window_src_token_id;
wire [WINDOW_BRANCH_SLOTS*`TOKEN_ID_W-1:0]
    tree_window_src_referenced_token_id;
wire [WINDOW_BRANCH_SLOTS*`POSITION_ID_W-1:0]
    tree_window_src_referenced_position;
wire [WINDOW_BRANCH_SLOTS*CONF_W-1:0] tree_window_src_confidence;

wire dispatch_busy;
wire dispatch_cfg_valid;
wire [CFG_W-1:0] dispatch_cfg_data;
wire dispatch_start;
wire dispatch_pred_valid;
wire dispatch_pred_ready;
wire [PRED_SOURCE_ID_W-1:0] dispatch_pred_source_id;
wire [`NODE_ID_W-1:0] dispatch_pred_parent_node_id;
wire [`TOKEN_ID_W-1:0] dispatch_pred_token_id;
wire [`TOKEN_ID_W-1:0] dispatch_pred_referenced_token_id;
wire [`POSITION_ID_W-1:0] dispatch_pred_referenced_position;
wire [`POSITION_ID_W-1:0] dispatch_pred_issue_position;
wire [CONF_W-1:0] dispatch_pred_confidence;
wire dispatch_pred_is_last_in_window;
wire [((WINDOW_BRANCH_SLOTS <= 2) ? 1 : $clog2(WINDOW_BRANCH_SLOTS))-1:0]
    dispatch_pred_slot_idx;
wire dispatch_pred_tree_mask_en;
wire [15:0] dispatch_pred_prefix_len;
wire dispatch_src_pred_ready;
wire dispatch_src_tree_window_ready;
wire native_tree_main_busy_w;
wire native_tree_main_req_ready_w;
wire native_tree_main_cfg_valid_w;
wire [CFG_W-1:0] native_tree_main_cfg_data_w;
wire native_tree_main_start_w;
wire native_tree_main_pred_valid_w;
wire native_tree_main_pred_ready_w;
wire [PRED_SOURCE_ID_W-1:0] native_tree_main_pred_source_id_w;
wire [`BRANCH_ID_W-1:0] native_tree_main_pred_branch_id_w;
wire [`TREE_LEVEL_ID_W-1:0] native_tree_main_pred_level_id_w;
wire [`NODE_ID_W-1:0] native_tree_main_pred_node_id_w;
wire [`NODE_ID_W-1:0] native_tree_main_pred_parent_node_id_w;
wire [`TOKEN_ID_W-1:0] native_tree_main_pred_token_id_w;
wire [`TOKEN_ID_W-1:0] native_tree_main_pred_referenced_token_id_w;
wire [`POSITION_ID_W-1:0] native_tree_main_pred_referenced_position_w;
wire [`POSITION_ID_W-1:0] native_tree_main_pred_issue_position_w;
wire [CONF_W-1:0] native_tree_main_pred_confidence_w;
wire native_tree_main_pred_is_last_in_window_w;
wire native_tree_main_pred_tree_mask_en_w;
wire [15:0] native_tree_main_pred_prefix_len_w;
wire [`TOY_MAX_POS_EMB-1:0] native_tree_main_pred_visible_mask_w;
wire agu_tree_in_ready_w;
wire native_tree_main_req_fire_w;
wire native_tree_main_frontier_capture_fire_w;
wire native_tree_main_pred_fire_w;
wire [`TREE_MAX_FRONTIER_LEVELS*WINDOW_BRANCH_SLOTS*`TOY_MAX_POS_EMB-1:0]
    native_tree_visible_mask_by_level_w;
wire tree_parallel_mode_w;
localparam [`SRAM_ADDR_W-1:0] TREE_PARALLEL_FINAL_NORM_GAMMA_ADDR = 23'd2048;
wire tree_parallel_req_valid_w;
wire tree_parallel_req_ready_w;
reg [`NODE_ID_W-1:0] tree_parallel_seed_node_id_w;
reg [`TOKEN_ID_W-1:0] tree_parallel_seed_token_id_w;
reg [`POSITION_ID_W-1:0] tree_parallel_seed_position_w;
reg [`BRANCH_NUM-1:0] tree_parallel_branch_valid_w;
reg [`BRANCH_NUM*`MAX_PRIVATE_NODES_PER_BRANCH*`NODE_ID_W-1:0]
    tree_parallel_branch_node_ids_w;
reg [`BRANCH_NUM*`MAX_PRIVATE_NODES_PER_BRANCH*`NODE_ID_W-1:0]
    tree_parallel_branch_parent_node_ids_w;
reg [`BRANCH_NUM*`MAX_PRIVATE_NODES_PER_BRANCH*`TOKEN_ID_W-1:0]
    tree_parallel_branch_draft_tokens_w;
reg [`BRANCH_NUM*`MAX_PRIVATE_NODES_PER_BRANCH*`POSITION_ID_W-1:0]
    tree_parallel_branch_draft_positions_w;
reg [`BRANCH_NUM*`MAX_PRIVATE_NODES_PER_BRANCH-1:0]
    tree_parallel_branch_levels_valid_w;
wire [15:0] tree_parallel_committed_prefix_len_w;
wire tree_parallel_batch_valid_w;
wire tree_parallel_batch_ready_w;
wire [4:0] tree_parallel_batch_count_w;
wire [`VERIFY_WINDOW_SIZE*32-1:0] tree_parallel_batch_token_ids_w;
wire [`VERIFY_WINDOW_SIZE*16-1:0] tree_parallel_batch_positions_w;
wire [`VERIFY_WINDOW_SIZE*`VERIFY_WINDOW_SIZE-1:0]
    tree_parallel_batch_tree_mask_w;
wire [15:0] tree_parallel_batch_prefix_len_w;
wire tree_parallel_batch_seed_kv_valid_w;
wire [`VERIFY_WINDOW_SIZE-1:0] tree_parallel_batch_slot_is_seed_w;
wire tree_parallel_fwd_result_valid_w;
wire tree_parallel_fwd_result_ready_w;
wire [4:0] tree_parallel_fwd_result_count_w;
wire [`VERIFY_WINDOW_SIZE*32-1:0] tree_parallel_fwd_result_token_ids_w;
wire tree_parallel_commit_valid_w;
wire [`BRANCH_ID_W-1:0] tree_parallel_commit_branch_id_w;
wire [2:0] tree_parallel_commit_depth_w;
wire [`TOKEN_ID_W-1:0] tree_parallel_commit_bonus_token_id_w;
wire [`BRANCH_NUM-1:0] tree_parallel_commit_flush_mask_w;
wire [`MAX_PRIVATE_NODES_PER_BRANCH*`SLOT_ID_W-1:0]
    tree_parallel_commit_slots_w;
wire [`MAX_PRIVATE_NODES_PER_BRANCH*16-1:0]
    tree_parallel_commit_slot_positions_w;
wire tree_parallel_busy_w;
wire tree_parallel_hbm_rd_valid_w;
wire tree_parallel_hbm_rd_ready_w;
wire [`HBM_ADDR_W-1:0] tree_parallel_hbm_rd_addr_w;
wire tree_parallel_hbm_resp_ready_w;
wire tree_parallel_sram_rd_valid_w;
wire tree_parallel_sram_rd_ready_w;
wire [`SRAM_ADDR_W-1:0] tree_parallel_sram_rd_addr_w;
wire [`REQ_ID_W-1:0] tree_parallel_sram_rd_id_w;
wire tree_parallel_sram_resp_ready_w;
wire tree_parallel_sram_wr_valid_w;
wire tree_parallel_sram_wr_ready_w;
wire [`SRAM_ADDR_W-1:0] tree_parallel_sram_wr_addr_w;
wire [`SRAM_WDATA_W-1:0] tree_parallel_sram_wr_data_w;
wire [`MEM_REQ_LANES-1:0] tree_parallel_vec_req_valid_w;
wire [`MEM_REQ_LANES-1:0] tree_parallel_vec_req_ready_w;
wire [`MEM_REQ_LANES-1:0] tree_parallel_vec_req_write_w;
wire [`MEM_REQ_LANES*`SRAM_ADDR_W-1:0] tree_parallel_vec_req_addr_w;
wire [`MEM_REQ_LANES*`SRAM_WDATA_W-1:0] tree_parallel_vec_req_wdata_w;
wire [`MEM_REQ_LANES*`REQ_ID_W-1:0] tree_parallel_vec_req_req_id_w;
wire [`MEM_REQ_LANES*`PE_MASK_W-1:0] tree_parallel_vec_req_pe_mask_w;
wire [`MEM_REQ_LANES*`REQ_PRIORITY_W-1:0] tree_parallel_vec_req_priority_w;
wire [`MEM_REQ_LANES*`BANK_ID_W-1:0] tree_parallel_vec_req_bank_id_w;
wire [`MEM_REQ_LANES*`SUBBANK_ID_W-1:0] tree_parallel_vec_req_subbank_id_w;
wire [`MEM_REQ_LANES-1:0] tree_parallel_vec_rd_valid_raw_w;
wire [`MEM_REQ_LANES*`SRAM_ADDR_W-1:0] tree_parallel_vec_rd_addr_raw_w;
wire [`MEM_REQ_LANES*`REQ_ID_W-1:0] tree_parallel_vec_rd_id_raw_w;
wire [`MEM_REQ_LANES*`PE_MASK_W-1:0] tree_parallel_vec_rd_pe_mask_raw_w;
wire [`MEM_REQ_LANES-1:0] tree_parallel_vec_wr_valid_raw_w;
wire [`MEM_REQ_LANES*`SRAM_ADDR_W-1:0] tree_parallel_vec_wr_addr_raw_w;
wire [`MEM_REQ_LANES*`SRAM_WDATA_W-1:0] tree_parallel_vec_wr_data_raw_w;
wire [`MEM_REQ_LANES*`REQ_ID_W-1:0] tree_parallel_vec_wr_id_raw_w;
wire [`MEM_REQ_LANES*`PE_MASK_W-1:0] tree_parallel_vec_wr_pe_mask_raw_w;
wire [`MEM_REQ_LANES-1:0] tree_parallel_vec_resp_valid_raw_w;
wire [`MEM_REQ_LANES-1:0] tree_parallel_vec_resp_valid_w;
wire [`MEM_REQ_LANES-1:0] tree_parallel_vec_resp_ready_w;
wire [`MEM_REQ_LANES*`SRAM_RDATA_W-1:0] tree_parallel_vec_resp_rdata_w;
wire [`MEM_REQ_LANES*`REQ_ID_W-1:0] tree_parallel_vec_resp_req_id_w;
wire [`MEM_REQ_LANES*`PE_MASK_W-1:0] tree_parallel_vec_resp_pe_mask_w;
wire [`MEM_REQ_LANES-1:0] tree_parallel_vec_resp_last_w;
wire [`MEM_REQ_LANES-1:0] tree_parallel_vec_resp_is_draft_w;
wire [`MEM_REQ_LANES-1:0] tree_parallel_vec_resp_orphan_drain_w;
wire [`MEM_REQ_LANES-1:0] tree_parallel_vec_resp_consume_w;
wire [15:0] tree_parallel_current_position_w;
wire [4:0] tree_parallel_current_layer_debug_w;
wire tree_parallel_kv_commit_start_w;
wire tree_parallel_kv_commit_done_w;
wire tree_parallel_kv_commit_busy_w;
wire [`MAX_PRIVATE_NODES_PER_BRANCH*`SLOT_ID_W-1:0]
    tree_parallel_kv_commit_slots_w;
wire [`MAX_PRIVATE_NODES_PER_BRANCH*16-1:0]
    tree_parallel_kv_commit_positions_w;
wire tree_parallel_kv_commit_sram_rd_valid_w;
wire tree_parallel_kv_commit_sram_rd_ready_w;
wire [`SRAM_ADDR_W-1:0] tree_parallel_kv_commit_sram_rd_addr_w;
wire tree_parallel_kv_commit_resp_ready_w;
wire tree_parallel_kv_commit_sram_wr_valid_w;
wire tree_parallel_kv_commit_sram_wr_ready_w;
wire [`SRAM_ADDR_W-1:0] tree_parallel_kv_commit_sram_wr_addr_w;
wire [`SRAM_WDATA_W-1:0] tree_parallel_kv_commit_sram_wr_data_w;
wire tree_cfg_valid_w;
wire [CFG_W-1:0] tree_cfg_data_w;
wire tree_start_w;

wire tree_busy;
wire tree_error_flag;
wire tc_issue_valid;
wire tc_issue_ready;
wire [`TOKEN_ID_W-1:0] tc_issue_token_id;
wire [`BRANCH_ID_W-1:0] tc_issue_branch_id;
wire [1:0] tc_issue_epoch;
wire [MODEL_ID_W-1:0] tc_issue_model_id;
wire [OP_CLASS_W-1:0] tc_issue_op_class;
wire [`SRAM_ADDR_W-1:0] tc_issue_src_addr;
wire [`SRAM_ADDR_W-1:0] tc_issue_dst_addr;
wire [TOKEN_LEN_W-1:0] tc_issue_token_len;
wire [`REQ_ID_W-1:0] tc_issue_req_id;
wire [1:0] tc_issue_flush_epoch;
wire [`NODE_ID_W-1:0] tc_issue_parent_node_id;
wire [CONF_W-1:0] tc_issue_confidence;
wire tc_issue_tree_mask_en;
wire [`BRANCH_ID_W-1:0] tc_issue_tree_mask_branch_id;
wire [15:0] tc_issue_prefix_len;
wire [`TOY_MAX_POS_EMB-1:0] tc_issue_visible_mask;
wire [`POSITION_ID_W-1:0] tc_issue_position;
wire tc_issue_position_ovr;

wire issue_valid;
wire issue_ready;
wire [`TOKEN_ID_W-1:0] issue_token_id;
wire [`BRANCH_ID_W-1:0] issue_branch_id;
wire [1:0] issue_epoch;
wire [MODEL_ID_W-1:0] issue_model_id;
wire [OP_CLASS_W-1:0] issue_op_class;
wire [`SRAM_ADDR_W-1:0] issue_src_addr;
wire [`SRAM_ADDR_W-1:0] issue_dst_addr;
wire [TOKEN_LEN_W-1:0] issue_token_len;
wire [`REQ_ID_W-1:0] issue_req_id;
wire [1:0] issue_flush_epoch;
wire [`NODE_ID_W-1:0] issue_parent_node_id;
wire [CONF_W-1:0] issue_confidence;
wire issue_tree_mask_en;
wire [`BRANCH_ID_W-1:0] issue_tree_mask_branch_id;
wire [15:0] issue_prefix_len;
wire [`TOY_MAX_POS_EMB-1:0] issue_visible_mask;
wire [`POSITION_ID_W-1:0] issue_position;
wire issue_position_ovr;

wire prep_req_valid;
wire prep_req_ready;
wire prep_req_write;
wire [`SRAM_ADDR_W-1:0] prep_req_addr;
wire [`SRAM_WDATA_W-1:0] prep_req_wdata;
wire [`REQ_ID_W-1:0] prep_req_id;

wire op_req_valid;
wire op_req_ready;
wire op_req_write;
wire [`SRAM_ADDR_W-1:0] op_req_addr;
wire [`SRAM_WDATA_W-1:0] op_req_wdata;
wire [`REQ_ID_W-1:0] op_req_id;
wire op_req_last;
wire [`TOKEN_ID_W-1:0] op_req_tag;

wire op_resp_valid;
wire op_resp_ready;
wire [`SRAM_RDATA_W-1:0] op_resp_rdata;
wire [`REQ_ID_W-1:0] op_resp_id;
wire op_resp_last;

wire operator_result_valid_w;
wire operator_result_ready_w;
wire writeback_result_ready_w;
wire operator_raw_result_valid_w;
wire operator_raw_result_ready_w;
wire [`TOKEN_ID_W-1:0] operator_raw_result_token_id_w;
wire [`SRAM_ADDR_W-1:0] operator_raw_result_addr_w;
wire [`SRAM_WDATA_W-1:0] operator_raw_result_data_w;
wire [RESULT_STATUS_W-1:0] operator_raw_result_status_w;
wire tree_parallel_wb_result_valid_w;
wire tree_parallel_wb_result_ready_w;
wire tree_parallel_wb_pending_r;
reg tree_parallel_wb_pending_state_r;
wire [`TOKEN_ID_W-1:0] tree_parallel_wb_result_token_id_w;
wire [`SRAM_ADDR_W-1:0] tree_parallel_wb_result_addr_w;
wire [`SRAM_WDATA_W-1:0] tree_parallel_wb_result_data_w;
wire [RESULT_STATUS_W-1:0] tree_parallel_wb_result_status_w;
wire [`TOKEN_ID_W-1:0] operator_result_token_id_w;
wire [`SRAM_ADDR_W-1:0] operator_result_addr_w;
wire [`SRAM_WDATA_W-1:0] operator_result_data_w;
wire [RESULT_STATUS_W-1:0] operator_result_status_w;

wire use_prep_req;
wire rc_req_valid;
wire rc_req_ready;
wire rc_req_write;
wire [`SRAM_ADDR_W-1:0] rc_req_addr;
wire [`SRAM_WDATA_W-1:0] rc_req_wdata;
wire [`REQ_ID_W-1:0] rc_req_id;
wire [`PE_MASK_W-1:0] rc_req_pe_mask;
wire [`REQ_PRIORITY_W-1:0] rc_req_priority;
wire [`BANK_ID_W-1:0] rc_req_bank_id;
wire [`SUBBANK_ID_W-1:0] rc_req_subbank_id;

wire [`MEM_REQ_LANES-1:0] mem_req_valid;
wire [`MEM_REQ_LANES-1:0] mem_req_ready;
wire [`MEM_REQ_LANES-1:0] mem_req_write;
wire [`MEM_REQ_LANES*`SRAM_ADDR_W-1:0] mem_req_addr;
wire [`MEM_REQ_LANES*`SRAM_WDATA_W-1:0] mem_req_wdata;
wire [`MEM_REQ_LANES*`REQ_ID_W-1:0] mem_req_id;
wire [`MEM_REQ_LANES-1:0] mem_resp_valid;
wire [`MEM_REQ_LANES*`SRAM_RDATA_W-1:0] mem_resp_rdata;
wire [`MEM_REQ_LANES*`REQ_ID_W-1:0] mem_resp_id;
wire [`MEM_REQ_LANES-1:0] mem_resp_last;
wire [`MEM_REQ_LANES-1:0] pe_resp_valid;
wire [`MEM_REQ_LANES*`SRAM_RDATA_W-1:0] pe_resp_rdata;
wire [`MEM_REQ_LANES*`REQ_ID_W-1:0] pe_resp_req_id;
wire [`MEM_REQ_LANES*`PE_MASK_W-1:0] pe_resp_pe_mask;
wire [`MEM_REQ_LANES-1:0] pe_resp_last;
wire [`MEM_REQ_LANES-1:0] pe_resp_ready;
wire [`MEM_REQ_LANES-1:0] mc_resp_in_ready_w;
wire [`PE_MASK_W-1:0] mc_pe_valid_w;
wire [`PE_MASK_W*`SRAM_RDATA_W-1:0] mc_pe_rdata_w;
wire [`PE_MASK_W*`REQ_ID_W-1:0] mc_pe_req_id_w;
wire [`PE_MASK_W*`PE_MASK_W-1:0] mc_pe_mask_w;
wire [`PE_MASK_W-1:0] mc_pe_last_w;
wire [`PE_MASK_W-1:0] mc_pe_ready_w;

wire closure_sidecar_src_tree_window_ready_w;
wire closure_sidecar_busy_w;
wire closure_sidecar_pe_req_valid_w;
wire closure_sidecar_pe_req_ready_w;
wire closure_sidecar_pe_req_write_w;
wire [`SRAM_ADDR_W-1:0] closure_sidecar_pe_req_addr_w;
wire [`SRAM_WDATA_W-1:0] closure_sidecar_pe_req_wdata_w;
wire [`REQ_ID_W-1:0] closure_sidecar_pe_req_id_w;
wire [`PE_MASK_W-1:0] closure_sidecar_pe_req_pe_mask_w;
wire [`REQ_PRIORITY_W-1:0] closure_sidecar_pe_req_priority_w;
wire [`BANK_ID_W-1:0] closure_sidecar_pe_req_bank_id_w;
wire [`SUBBANK_ID_W-1:0] closure_sidecar_pe_req_subbank_id_w;
wire closure_sidecar_pe_resp_valid_w;
wire closure_sidecar_pe_resp_ready_w;
wire [`SRAM_RDATA_W-1:0] closure_sidecar_pe_resp_rdata_w;
wire [`REQ_ID_W-1:0] closure_sidecar_pe_resp_req_id_w;
wire [`PE_MASK_W-1:0] closure_sidecar_pe_resp_pe_mask_w;
wire closure_sidecar_pe_resp_last_w;
wire closure_sidecar_window_fire_w;
wire closure_sidecar_token_wr_fire_w;
wire closure_sidecar_lookup_hit_w;
wire closure_sidecar_pe_req_fire_w;
wire closure_sidecar_pe_resp_fire_w;
wire native_tree_req_ready_w;
wire native_tree_sidecar_busy_w;
wire native_tree_sidecar_pe_req_valid_w;
wire native_tree_sidecar_pe_req_ready_w;
wire native_tree_sidecar_pe_req_write_w;
wire [`SRAM_ADDR_W-1:0] native_tree_sidecar_pe_req_addr_w;
wire [`SRAM_WDATA_W-1:0] native_tree_sidecar_pe_req_wdata_w;
wire [`REQ_ID_W-1:0] native_tree_sidecar_pe_req_id_w;
wire [`PE_MASK_W-1:0] native_tree_sidecar_pe_req_pe_mask_w;
wire [`REQ_PRIORITY_W-1:0] native_tree_sidecar_pe_req_priority_w;
wire [`BANK_ID_W-1:0] native_tree_sidecar_pe_req_bank_id_w;
wire [`SUBBANK_ID_W-1:0] native_tree_sidecar_pe_req_subbank_id_w;
wire native_tree_sidecar_pe_resp_valid_w;
wire native_tree_sidecar_pe_resp_ready_w;
wire [`SRAM_RDATA_W-1:0] native_tree_sidecar_pe_resp_rdata_w;
wire [`REQ_ID_W-1:0] native_tree_sidecar_pe_resp_req_id_w;
wire [`PE_MASK_W-1:0] native_tree_sidecar_pe_resp_pe_mask_w;
wire native_tree_sidecar_pe_resp_last_w;
wire native_tree_or_sidecar_pe_resp_ready_w;
wire native_tree_sidecar_req_fire_w;
wire native_tree_sidecar_prefix_norm_fire_w;
wire native_tree_sidecar_frontier_norm_fire_w;
wire native_tree_sidecar_token_wr_fire_w;
wire native_tree_sidecar_lookup_hit_w;
wire native_tree_sidecar_pe_req_fire_w;
wire native_tree_sidecar_pe_resp_fire_w;
wire frontend_busy_w;
wire main_path_quiet_w;
wire rc_main_req_valid_w;
wire rc_main_req_ready_w;
wire rc_main_req_write_w;
wire [`SRAM_ADDR_W-1:0] rc_main_req_addr_w;
wire [`SRAM_WDATA_W-1:0] rc_main_req_wdata_w;
wire [`REQ_ID_W-1:0] rc_main_req_id_w;
wire [`PE_MASK_W-1:0] rc_main_req_pe_mask_w;
wire [`REQ_PRIORITY_W-1:0] rc_main_req_priority_w;
wire [`BANK_ID_W-1:0] rc_main_req_bank_id_w;
wire [`SUBBANK_ID_W-1:0] rc_main_req_subbank_id_w;
wire use_tree_parallel_sram_req_w;
wire tree_parallel_sram_req_valid_w;
wire tree_parallel_sram_req_write_w;
wire [`SRAM_ADDR_W-1:0] tree_parallel_sram_req_addr_w;
wire [`SRAM_WDATA_W-1:0] tree_parallel_sram_req_wdata_w;
wire [`REQ_ID_W-1:0] tree_parallel_sram_req_id_w;
wire use_tree_parallel_kv_commit_req_w;
wire tree_parallel_kv_commit_req_valid_w;
wire tree_parallel_kv_commit_req_write_w;
wire [`SRAM_ADDR_W-1:0] tree_parallel_kv_commit_req_addr_w;
wire [`SRAM_WDATA_W-1:0] tree_parallel_kv_commit_req_wdata_w;
wire [`REQ_ID_W-1:0] tree_parallel_kv_commit_req_id_w;
wire use_native_tree_req_w;
wire use_sidecar_req_w;
wire lane0_resp_valid_w;
wire [`SRAM_RDATA_W-1:0] lane0_resp_rdata_w;
wire [`REQ_ID_W-1:0] lane0_resp_req_id_w;
wire [`PE_MASK_W-1:0] lane0_resp_pe_mask_w;
wire lane0_resp_last_w;
wire sidecar_resp_select_w;
wire native_tree_resp_select_w;
wire tree_parallel_resp_select_w;
wire tree_parallel_scalar_resp_select_w;
wire tree_parallel_kv_commit_resp_select_w;
wire tree_parallel_scalar_tail_resp_ready_w;
wire tree_parallel_scalar_resp_orphan_drain_w;
wire tree_parallel_scalar_resp_consume_w;
wire tree_parallel_sram_resp_valid_w;
wire [`SRAM_RDATA_W-1:0] tree_parallel_sram_resp_data_w;
wire [`REQ_ID_W-1:0] tree_parallel_sram_resp_id_w;
wire [`TOKEN_ENTRY_TYPE_W-1:0] kv_lookup_entry_type_w;
wire [`TOKEN_STATE_W-1:0] kv_lookup_entry_state_w;
wire hbm_req_valid_w;
wire hbm_req_write_w;
wire [`HBM_ADDR_W-1:0] hbm_req_addr_w;
wire [`HBM_DATA_W-1:0] hbm_req_wdata_w;
wire [`REQ_ID_W-1:0] hbm_req_id_w;
wire operator_hbm_req_valid_w;
wire operator_hbm_req_write_w;
wire [`HBM_ADDR_W-1:0] operator_hbm_req_addr_w;
wire [`HBM_DATA_W-1:0] operator_hbm_req_wdata_w;
wire [`REQ_ID_W-1:0] operator_hbm_req_id_w;
wire wb_hbm_req_valid_w;
wire wb_hbm_req_write_w;
wire [`HBM_ADDR_W-1:0] wb_hbm_req_addr_w;
wire [`HBM_DATA_W-1:0] wb_hbm_req_wdata_w;
wire [`REQ_ID_W-1:0] wb_hbm_req_id_w;

reg hht_active_valid_r;
reg [`NODE_ID_W-1:0] hht_active_parent_node_id_r;
reg [`TOKEN_ID_W-1:0] hht_active_token_id_r;
reg [`TOKEN_ID_W-1:0] hht_active_referenced_token_id_r;
reg [`POSITION_ID_W-1:0] hht_active_referenced_position_r;
reg [CONF_W-1:0] hht_active_confidence_r;
reg hht_update_valid_r;
reg [`NODE_ID_W-1:0] hht_update_parent_node_id_r;
reg [`TOKEN_ID_W-1:0] hht_update_token_id_r;
reg [`TOKEN_ID_W-1:0] hht_update_referenced_token_id_r;
reg [`POSITION_ID_W-1:0] hht_update_referenced_position_r;
reg [CONF_W-1:0] hht_update_confidence_r;

wire pred_accept_fire_w;
wire wb_hht_match_w;
wire hht_update_ready_w;
wire accepted_token_fire_w;
wire [`POSITION_ID_W-1:0] accepted_position_w;
wire onchip_hht_cand_valid_w;
wire [`NODE_ID_W-1:0] onchip_hht_parent_node_id_w;
wire [`TOKEN_ID_W-1:0] onchip_hht_token_id_w;
wire [`TOKEN_ID_W-1:0] onchip_hht_referenced_token_id_w;
wire [`POSITION_ID_W-1:0] onchip_hht_referenced_position_w;
wire [CONF_W-1:0] onchip_hht_confidence_w;
wire onchip_hht_session_start_w;
wire onchip_hht_session_live_w;
wire onchip_hht_capture_fire_w;
reg onchip_hht_admission_open_r;
wire selected_hht_cand_valid_w;
wire selected_hht_cand_ready_w;
wire [`NODE_ID_W-1:0] selected_hht_parent_node_id_w;
wire [`TOKEN_ID_W-1:0] selected_hht_token_id_w;
wire [`TOKEN_ID_W-1:0] selected_hht_referenced_token_id_w;
wire [`POSITION_ID_W-1:0] selected_hht_referenced_position_w;
wire [CONF_W-1:0] selected_hht_confidence_w;
localparam integer PRIVATE_DEPTH_W =
    (((`MAX_VERIFY_NODES_PER_BRANCH + 1) <= 2) ? 1 :
     $clog2(`MAX_VERIFY_NODES_PER_BRANCH + 1));
localparam integer BRANCH_EPOCH_W = 2;
localparam integer PATH_PACK_W =
    (`BRANCH_NUM * `MAX_VERIFY_NODES_PER_BRANCH * `NODE_ID_W);
localparam integer DEPTH_PACK_W =
    (`BRANCH_NUM * PRIVATE_DEPTH_W);
localparam integer EPOCH_PACK_W =
    (`BRANCH_NUM * BRANCH_EPOCH_W);
wire native_tree_ownership_req_ready_w;
wire prefix_valid;
wire prefix_ready;
wire [`REQ_ID_W-1:0] prefix_req_id;
wire prefix_node_valid;
wire [`NODE_ID_W-1:0] prefix_node_id;
wire [`NODE_ID_W-1:0] prefix_parent_node_id;
wire [`TOKEN_ID_W-1:0] prefix_token_id;
wire [`POSITION_ID_W-1:0] prefix_position_id;
wire [`LAYER_ID_W-1:0] prefix_layer_id;
wire prefix_is_last;
wire [15:0] ownership_prefix_count_w;
wire frontier_valid;
wire frontier_ready;
wire [`REQ_ID_W-1:0] frontier_req_id;
wire [`TREE_LEVEL_ID_W-1:0] frontier_level_id;
wire [`TREE_FRONTIER_SLOTS-1:0] frontier_slot_valid;
wire [`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0] frontier_node_id;
wire [`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0] agu_frontier_node_id_w;
wire [`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0] frontier_parent_node_id;
wire [`TREE_FRONTIER_SLOTS*`TOKEN_ID_W-1:0] frontier_token_id;
wire [`TREE_FRONTIER_SLOTS*`TOKEN_ID_W-1:0] frontier_referenced_token_id;
wire [`TREE_FRONTIER_SLOTS*`POSITION_ID_W-1:0] frontier_position_id;
wire [`TREE_FRONTIER_SLOTS*`POSITION_ID_W-1:0]
    frontier_referenced_position_id;
wire [`TREE_FRONTIER_SLOTS*`BRANCH_ID_W-1:0] frontier_branch_id;
wire [15:0] frontier_level_slot_count;
wire [`TREE_FRONTIER_SLOTS-1:0] frontier_tree_mask_en;
wire prefetch_enq_ready;
wire prefetch_enq_valid;
wire [`REQ_ID_W-1:0] prefetch_enq_req_id;
wire [`BRANCH_ID_W-1:0] prefetch_enq_branch_id;
wire [`NODE_ID_W-1:0] prefetch_enq_node_id;
wire [`LAYER_ID_W-1:0] prefetch_enq_layer_id;
wire [`KV_GROUP_LEN_W-1:0] prefetch_enq_size_subbank;
wire prefetch_enq_shared;
wire prefetch_flush_valid;
wire [`REQ_ID_W-1:0] prefetch_flush_req_id;
wire [`BRANCH_MASK_W-1:0] prefetch_flush_branch_mask;
wire [`NODE_MASK_W-1:0] prefetch_flush_node_mask;
wire queue_deq_valid;
wire queue_deq_ready;
wire [`REQ_ID_W-1:0] queue_deq_req_id;
wire [`BRANCH_ID_W-1:0] queue_deq_branch_id;
wire [`NODE_ID_W-1:0] queue_deq_node_id;
wire [`LAYER_ID_W-1:0] queue_deq_layer_id;
wire [`KV_GROUP_LEN_W-1:0] queue_deq_size_subbank;
wire queue_deq_shared;
wire cand_resp_valid;
wire cand_resp_grant;
wire [`REQ_ID_W-1:0] cand_resp_req_id;
wire [`SRAM_ID_W-1:0] cand_resp_sram_id;
wire [`BANK_ID_W-1:0] cand_resp_bank_id;
wire [`SUBBANK_ID_W-1:0] cand_resp_subbank_start;
wire [`KV_GROUP_LEN_W-1:0] cand_resp_group_len;
wire alloc_cand_valid;
wire [`REQ_ID_W-1:0] alloc_cand_req_id;
wire [`BRANCH_ID_W-1:0] alloc_cand_branch_id;
wire [`NODE_ID_W-1:0] alloc_cand_node_id;
wire [`KV_GROUP_LEN_W-1:0] alloc_cand_size_subbank;
wire alloc_cand_shared;
wire [`SRAM_ID_W-1:0] alloc_cand_sram_id;
wire [`BANK_ID_W-1:0] alloc_cand_bank_id;
wire [`SUBBANK_ID_W-1:0] alloc_cand_subbank_start;
wire [`KV_GROUP_LEN_W-1:0] alloc_cand_group_len;
wire free_list_flush_valid;
wire [`REQ_ID_W-1:0] free_list_flush_req_id;
wire [`BRANCH_MASK_W-1:0] free_list_flush_branch_mask;
wire [`NODE_MASK_W-1:0] free_list_flush_node_mask;
wire free_list_flush_drain_busy;
wire flush_reclaim_valid;
wire [`SRAM_ID_W-1:0] flush_reclaim_sram_id;
wire [`BANK_ID_W-1:0] flush_reclaim_bank_id;
wire [`SUBBANK_ID_W-1:0] flush_reclaim_subbank_start;
wire [`KV_GROUP_LEN_W-1:0] flush_reclaim_group_len;
wire alloc_resp_valid;
wire alloc_resp_grant;
wire [`REQ_ID_W-1:0] alloc_resp_req_id;
wire [`SRAM_ID_W-1:0] alloc_resp_sram_id;
wire [`BANK_ID_W-1:0] alloc_resp_bank_id;
wire [`SUBBANK_ID_W-1:0] alloc_resp_subbank_start;
wire [`KV_GROUP_LEN_W-1:0] alloc_resp_group_len;
wire [`BANK_OCC_BITMAP_W-1:0] alloc_resp_occ_bitmap;
wire token_wr_valid;
wire [`REQ_ID_W-1:0] token_wr_req_id;
wire [`TOKEN_ID_W-1:0] token_wr_token_id;
wire [`POSITION_ID_W-1:0] token_wr_position_id;
wire [`NODE_ID_W-1:0] token_wr_node_id;
wire [`BRANCH_ID_W-1:0] token_wr_branch_id;
wire [`BRANCH_MASK_W-1:0] token_wr_branch_mask;
wire token_wr_is_shared;
wire [`SRAM_ID_W-1:0] token_wr_sram_id;
wire [`BANK_ID_W-1:0] token_wr_bank_id;
wire [`SUBBANK_ID_W-1:0] token_wr_subbank_start;
wire [`KV_GROUP_LEN_W-1:0] token_wr_group_len;
wire token_flush_valid;
wire [`REQ_ID_W-1:0] token_flush_req_id;
wire [`BRANCH_MASK_W-1:0] token_flush_branch_mask;
wire [`NODE_MASK_W-1:0] token_flush_node_mask;
wire [`TOKEN_REG_INDEX_W:0] token_entry_count;
wire token_error_flag;
wire token_commit_valid;
wire [`TOKEN_REG_INDEX_W-1:0] token_commit_index;
wire [`REQ_ID_W-1:0] token_commit_req_id;
wire [`BRANCH_MASK_W-1:0] token_commit_branch_mask;
wire [`NODE_MASK_W-1:0] token_commit_node_mask;
wire bank_commit_valid;
wire [`REQ_ID_W-1:0] bank_commit_req_id;
wire [`SRAM_ID_W-1:0] bank_commit_sram_id;
wire [`BANK_ID_W-1:0] bank_commit_bank_id;
wire [`SUBBANK_ID_W-1:0] bank_commit_subbank_start;
wire [`KV_GROUP_LEN_W-1:0] bank_commit_group_len;
wire [`BRANCH_MASK_W-1:0] bank_commit_branch_mask;
wire [`NODE_MASK_W-1:0] bank_commit_node_mask;
wire commit_valid;
wire [`BRANCH_MASK_W-1:0] commit_branch_mask;
wire [`NODE_MASK_W-1:0] commit_node_mask;
wire flush_valid;
wire [`BRANCH_MASK_W-1:0] flush_branch_mask;
wire [`NODE_MASK_W-1:0] flush_node_mask;
wire accepted_prefix_valid;
wire [`REQ_ID_W-1:0] accepted_prefix_req_id;
wire [PRIVATE_DEPTH_W-1:0] accepted_prefix_depth;
wire [(`MAX_VERIFY_NODES_PER_BRANCH*`NODE_ID_W)-1:0] accepted_prefix_node_id;
wire branch_liveness_update_valid_w;
wire [`BRANCH_NUM-1:0] live_branch_mask;
wire [`BRANCH_NUM-1:0] prune_branch_mask;
wire cmp_commit_valid_w;
wire [`BRANCH_MASK_W-1:0] cmp_commit_branch_mask_w;
wire [`NODE_MASK_W-1:0] cmp_commit_node_mask_w;
wire cmp_flush_valid_w;
wire [`BRANCH_MASK_W-1:0] cmp_flush_branch_mask_w;
wire [`NODE_MASK_W-1:0] cmp_flush_node_mask_w;
wire cmp_accepted_prefix_valid_w;
wire [`REQ_ID_W-1:0] cmp_accepted_prefix_req_id_w;
wire [PRIVATE_DEPTH_W-1:0] cmp_accepted_prefix_depth_w;
wire [(`MAX_VERIFY_NODES_PER_BRANCH*`NODE_ID_W)-1:0]
    cmp_accepted_prefix_node_id_w;
wire [`BRANCH_NUM-1:0] cmp_live_branch_mask_w;
wire [`BRANCH_NUM-1:0] cmp_prune_branch_mask_w;
wire wb_generated_token_fire_w;
wire [`TOKEN_ID_W-1:0] wb_generated_token_id_w;
wire native_tree_req_accept_fire_w;
wire native_tree_lifecycle_busy_w;
reg [`TOKEN_REG_INDEX_W-1:0] token_wr_index_r;
reg lifecycle_window_active_r;
reg [`REQ_ID_W-1:0] lifecycle_req_id_r;
reg tree_parallel_session_active_r;
reg active_issue_valid_r;
reg [`BRANCH_ID_W-1:0] active_issue_branch_id_r;
reg [`TREE_LEVEL_ID_W-1:0] active_issue_level_id_r;
reg [PRIVATE_DEPTH_W-1:0] active_issue_private_depth_r;
reg [`NODE_ID_W-1:0] active_issue_node_id_r;
reg [`NODE_ID_W-1:0] active_issue_parent_node_id_r;
reg [`TOKEN_ID_W-1:0] active_issue_candidate_token_id_r;
reg active_issue_is_last_r;
reg [`BRANCH_NUM-1:0] lifecycle_slot_meta_valid_r;
reg [`BRANCH_NUM-1:0] lifecycle_slot_result_valid_r;
reg [`BRANCH_NUM*`TOKEN_ID_W-1:0] lifecycle_cmp_candidate_token_id_r;
reg [`BRANCH_NUM*`TOKEN_ID_W-1:0] lifecycle_cmp_real_token_id_r;
reg [`BRANCH_NUM*`NODE_ID_W-1:0] lifecycle_cmp_node_id_r;
reg [`BRANCH_NUM*`NODE_ID_W-1:0] lifecycle_cmp_parent_node_id_r;
reg [`BRANCH_NUM*`BRANCH_ID_W-1:0] lifecycle_cmp_branch_id_r;
reg [DEPTH_PACK_W-1:0] lifecycle_candidate_depth_by_branch_r;
reg [PATH_PACK_W-1:0] lifecycle_candidate_node_path_by_branch_r;
reg [PATH_PACK_W-1:0] lifecycle_candidate_parent_path_by_branch_r;
reg [DEPTH_PACK_W-1:0] lifecycle_result_depth_by_branch_r;
reg [(`BRANCH_NUM*`MAX_VERIFY_NODES_PER_BRANCH)-1:0]
    lifecycle_commit_meta_valid_by_node_r;
reg [`BRANCH_NUM*`TOKEN_REG_INDEX_W-1:0] lifecycle_commit_index_by_slot_r;
reg [`BRANCH_NUM*`SRAM_ID_W-1:0] lifecycle_commit_sram_id_by_slot_r;
reg [`BRANCH_NUM*`BANK_ID_W-1:0] lifecycle_commit_bank_id_by_slot_r;
reg [`BRANCH_NUM*`SUBBANK_ID_W-1:0] lifecycle_commit_subbank_by_slot_r;
reg [`BRANCH_NUM*`KV_GROUP_LEN_W-1:0] lifecycle_commit_group_len_by_slot_r;
reg [(`BRANCH_NUM*`MAX_VERIFY_NODES_PER_BRANCH*`TOKEN_REG_INDEX_W)-1:0]
    lifecycle_commit_index_by_node_r;
reg [(`BRANCH_NUM*`MAX_VERIFY_NODES_PER_BRANCH*`SRAM_ID_W)-1:0]
    lifecycle_commit_sram_id_by_node_r;
reg [(`BRANCH_NUM*`MAX_VERIFY_NODES_PER_BRANCH*`BANK_ID_W)-1:0]
    lifecycle_commit_bank_id_by_node_r;
reg [(`BRANCH_NUM*`MAX_VERIFY_NODES_PER_BRANCH*`SUBBANK_ID_W)-1:0]
    lifecycle_commit_subbank_by_node_r;
reg [(`BRANCH_NUM*`MAX_VERIFY_NODES_PER_BRANCH*`KV_GROUP_LEN_W)-1:0]
    lifecycle_commit_group_len_by_node_r;
reg lifecycle_cmp_fire_r;
reg [`BRANCH_NUM-1:0] lifecycle_cmp_slot_valid_comb;
reg [DEPTH_PACK_W-1:0] lifecycle_active_branch_depth_comb;
reg [PATH_PACK_W-1:0] lifecycle_active_branch_node_id_comb;
reg [PATH_PACK_W-1:0] lifecycle_active_branch_parent_node_id_comb;
reg [(`BRANCH_NUM*PRIVATE_DEPTH_W)-1:0] lifecycle_result_private_depth_comb;
reg [`BRANCH_NUM-1:0] lifecycle_result_accept_comb;
reg lifecycle_commit_select_valid_comb;
reg [`BRANCH_ID_W-1:0] lifecycle_commit_select_branch_comb;
reg [`BRANCH_MASK_W-1:0] tree_parallel_commit_branch_mask_comb;
reg [`NODE_MASK_W-1:0] tree_parallel_commit_node_mask_comb;
reg tree_parallel_flush_valid_comb;
reg [`NODE_MASK_W-1:0] tree_parallel_flush_node_mask_comb;
reg [(`MAX_VERIFY_NODES_PER_BRANCH*`NODE_ID_W)-1:0]
    tree_parallel_accepted_prefix_node_id_comb;
reg [`BRANCH_MASK_W-1:0] tree_parallel_live_branch_mask_comb;
reg [`BRANCH_MASK_W-1:0] tree_parallel_prune_branch_mask_comb;
reg tree_parallel_commit_pending_r;
reg [PRIVATE_DEPTH_W-1:0] tree_parallel_commit_pending_depth_r;
reg [`BRANCH_ID_W-1:0] tree_parallel_commit_pending_branch_r;
reg [(`MAX_VERIFY_NODES_PER_BRANCH*`NODE_ID_W)-1:0]
    tree_parallel_commit_pending_node_id_r;
reg tree_parallel_commit_replay_active_r;
reg [PRIVATE_DEPTH_W-1:0] tree_parallel_commit_replay_cursor_r;
reg [PRIVATE_DEPTH_W-1:0] tree_parallel_commit_replay_depth_r;
reg [`BRANCH_ID_W-1:0] tree_parallel_commit_replay_branch_r;
reg [(`MAX_VERIFY_NODES_PER_BRANCH*`NODE_ID_W)-1:0]
    tree_parallel_commit_replay_node_id_r;
reg tree_parallel_commit_meta_ready_comb;
reg tree_parallel_commit_issue_valid_comb;
reg [`TOKEN_REG_INDEX_W-1:0] tree_parallel_commit_issue_index_comb;
reg [`REQ_ID_W-1:0] tree_parallel_commit_issue_req_id_comb;
reg [`BRANCH_MASK_W-1:0] tree_parallel_commit_issue_branch_mask_comb;
reg [`NODE_MASK_W-1:0] tree_parallel_commit_issue_node_mask_comb;
reg [`SRAM_ID_W-1:0] tree_parallel_commit_issue_sram_id_comb;
reg [`BANK_ID_W-1:0] tree_parallel_commit_issue_bank_id_comb;
reg [`SUBBANK_ID_W-1:0] tree_parallel_commit_issue_subbank_comb;
reg [`KV_GROUP_LEN_W-1:0] tree_parallel_commit_issue_group_len_comb;
integer lifecycle_slot_i;
integer tree_parallel_level_idx_i;
integer tree_parallel_branch_idx_i;
integer tree_parallel_prefix_idx_i;
integer tree_parallel_flat_slot_idx_i;
integer tree_parallel_meta_flat_idx_i;
integer tree_parallel_reduce_branch_i;
integer tree_parallel_reduce_level_i;
integer tree_parallel_reduce_bit_idx_i;
integer tree_parallel_replay_level_i;
integer tree_parallel_replay_node_id_i;
integer tree_parallel_replay_flat_idx_i;
reg tree_parallel_seed_found_comb;
reg tree_parallel_seed_ref_found_comb;
reg [`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0] agu_tree_parallel_frontier_node_id_comb;
wire tree_parallel_req_mode_w;
localparam [CONF_W-1:0] HHT_CONF_MIN_W =
    {{(CONF_W-1){1'b0}}, 1'b1};
localparam [CONF_W-1:0] LEGACY_HHT_CONF_TH_W = 8'd100;
localparam [CONF_W-1:0] SELECTED_HHT_CONF_TH_W =
    ENABLE_ONCHIP_HHT_CONTEXT ? HHT_CONF_MIN_W : LEGACY_HHT_CONF_TH_W;

assign use_prep_req = prep_req_valid;
assign tree_parallel_sram_req_valid_w =
    tree_parallel_sram_rd_valid_w || tree_parallel_sram_wr_valid_w;
assign tree_parallel_sram_req_write_w = tree_parallel_sram_wr_valid_w;
assign tree_parallel_sram_req_addr_w =
    tree_parallel_sram_wr_valid_w ?
        tree_parallel_sram_wr_addr_w :
        tree_parallel_sram_rd_addr_w;
assign tree_parallel_sram_req_wdata_w = tree_parallel_sram_wr_data_w;
assign tree_parallel_sram_req_id_w =
    tree_parallel_sram_wr_valid_w ?
        {`REQ_ID_W{1'b0}} :
        tree_parallel_sram_rd_id_w;
assign tree_parallel_kv_commit_req_valid_w =
    tree_parallel_kv_commit_sram_rd_valid_w ||
    tree_parallel_kv_commit_sram_wr_valid_w;
assign tree_parallel_kv_commit_req_write_w =
    tree_parallel_kv_commit_sram_wr_valid_w;
assign tree_parallel_kv_commit_req_addr_w =
    tree_parallel_kv_commit_sram_wr_valid_w ?
        tree_parallel_kv_commit_sram_wr_addr_w :
        tree_parallel_kv_commit_sram_rd_addr_w;
assign tree_parallel_kv_commit_req_wdata_w =
    tree_parallel_kv_commit_sram_wr_data_w;
assign tree_parallel_kv_commit_req_id_w = {`REQ_ID_W{1'b0}};
assign tree_parallel_vec_req_valid_w =
    tree_parallel_vec_rd_valid_raw_w | tree_parallel_vec_wr_valid_raw_w;
assign tree_parallel_vec_req_write_w = tree_parallel_vec_wr_valid_raw_w;

genvar tree_parallel_vec_lane_g;
generate
    for (tree_parallel_vec_lane_g = 0;
         tree_parallel_vec_lane_g < `MEM_REQ_LANES;
         tree_parallel_vec_lane_g = tree_parallel_vec_lane_g + 1) begin : gen_tree_parallel_vec_req_mux
        assign tree_parallel_vec_req_addr_w[
            tree_parallel_vec_lane_g*`SRAM_ADDR_W +: `SRAM_ADDR_W] =
            tree_parallel_vec_wr_valid_raw_w[tree_parallel_vec_lane_g] ?
                tree_parallel_vec_wr_addr_raw_w[
                    tree_parallel_vec_lane_g*`SRAM_ADDR_W +: `SRAM_ADDR_W] :
                tree_parallel_vec_rd_addr_raw_w[
                    tree_parallel_vec_lane_g*`SRAM_ADDR_W +: `SRAM_ADDR_W];
        assign tree_parallel_vec_req_wdata_w[
            tree_parallel_vec_lane_g*`SRAM_WDATA_W +: `SRAM_WDATA_W] =
            tree_parallel_vec_wr_data_raw_w[
                tree_parallel_vec_lane_g*`SRAM_WDATA_W +: `SRAM_WDATA_W];
        assign tree_parallel_vec_req_req_id_w[
            tree_parallel_vec_lane_g*`REQ_ID_W +: `REQ_ID_W] =
            tree_parallel_vec_wr_valid_raw_w[tree_parallel_vec_lane_g] ?
                tree_parallel_vec_wr_id_raw_w[
                    tree_parallel_vec_lane_g*`REQ_ID_W +: `REQ_ID_W] :
                tree_parallel_vec_rd_id_raw_w[
                    tree_parallel_vec_lane_g*`REQ_ID_W +: `REQ_ID_W];
        assign tree_parallel_vec_req_pe_mask_w[
            tree_parallel_vec_lane_g*`PE_MASK_W +: `PE_MASK_W] =
            tree_parallel_vec_wr_valid_raw_w[tree_parallel_vec_lane_g] ?
                tree_parallel_vec_wr_pe_mask_raw_w[
                    tree_parallel_vec_lane_g*`PE_MASK_W +: `PE_MASK_W] :
                tree_parallel_vec_rd_pe_mask_raw_w[
                    tree_parallel_vec_lane_g*`PE_MASK_W +: `PE_MASK_W];
        assign tree_parallel_vec_req_priority_w[
            tree_parallel_vec_lane_g*`REQ_PRIORITY_W +: `REQ_PRIORITY_W] =
            {`REQ_PRIORITY_W{1'b0}};
        assign tree_parallel_vec_req_bank_id_w[
            tree_parallel_vec_lane_g*`BANK_ID_W +: `BANK_ID_W] =
            tree_parallel_vec_req_addr_w[
                tree_parallel_vec_lane_g*`SRAM_ADDR_W +
                (`OFFSET_W + `ROW_ADDR_W + `SUBBANK_ID_W) +: `BANK_ID_W];
        assign tree_parallel_vec_req_subbank_id_w[
            tree_parallel_vec_lane_g*`SUBBANK_ID_W +: `SUBBANK_ID_W] =
            tree_parallel_vec_req_addr_w[
                tree_parallel_vec_lane_g*`SRAM_ADDR_W +
                (`OFFSET_W + `ROW_ADDR_W) +: `SUBBANK_ID_W];
    end
endgenerate

assign use_tree_parallel_sram_req_w =
    tree_parallel_mode_w && tree_parallel_sram_req_valid_w;
assign use_tree_parallel_kv_commit_req_w =
    tree_parallel_mode_w &&
    !use_tree_parallel_sram_req_w &&
    tree_parallel_kv_commit_req_valid_w;
assign rc_main_req_valid_w =
    use_tree_parallel_sram_req_w ? tree_parallel_sram_req_valid_w :
    (use_tree_parallel_kv_commit_req_w ? tree_parallel_kv_commit_req_valid_w :
    (use_prep_req ? prep_req_valid : op_req_valid));
assign rc_main_req_write_w =
    use_tree_parallel_sram_req_w ? tree_parallel_sram_req_write_w :
    (use_tree_parallel_kv_commit_req_w ? tree_parallel_kv_commit_req_write_w :
    (use_prep_req ? prep_req_write : op_req_write));
assign rc_main_req_addr_w =
    use_tree_parallel_sram_req_w ? tree_parallel_sram_req_addr_w :
    (use_tree_parallel_kv_commit_req_w ? tree_parallel_kv_commit_req_addr_w :
    (use_prep_req ? prep_req_addr : op_req_addr));
assign rc_main_req_wdata_w =
    use_tree_parallel_sram_req_w ? tree_parallel_sram_req_wdata_w :
    (use_tree_parallel_kv_commit_req_w ? tree_parallel_kv_commit_req_wdata_w :
    (use_prep_req ? prep_req_wdata : op_req_wdata));
assign rc_main_req_id_w =
    use_tree_parallel_sram_req_w ? tree_parallel_sram_req_id_w :
    (use_tree_parallel_kv_commit_req_w ? tree_parallel_kv_commit_req_id_w :
    (use_prep_req ? prep_req_id : op_req_id));
assign rc_main_req_pe_mask_w = {{(`PE_MASK_W-1){1'b0}}, 1'b1};
assign rc_main_req_priority_w = {`REQ_PRIORITY_W{1'b0}};
assign rc_main_req_bank_id_w =
    rc_main_req_addr_w[(`OFFSET_W + `ROW_ADDR_W + `SUBBANK_ID_W) +:
                       `BANK_ID_W];
assign rc_main_req_subbank_id_w =
    rc_main_req_addr_w[(`OFFSET_W + `ROW_ADDR_W) +: `SUBBANK_ID_W];
assign main_path_quiet_w =
    !tree_busy &&
    !frontend_busy_w &&
    !prep_req_valid &&
    !op_req_valid &&
    !issue_valid;
assign frontend_busy_w =
    ENABLE_NATIVE_TREE_MAIN_FRONTEND ?
        (tree_parallel_mode_w ? tree_parallel_busy_w : native_tree_main_busy_w) :
        dispatch_busy;
assign native_tree_req_ready =
    ENABLE_NATIVE_TREE_MAIN_FRONTEND ?
        (ENABLE_NATIVE_TREE_SIDECAR ?
            ((((tree_parallel_mode_w ?
                    (tree_parallel_req_ready_w &&
                     native_tree_main_req_ready_w &&
                     native_tree_ownership_req_ready_w) :
                    (native_tree_main_req_ready_w &&
                     native_tree_ownership_req_ready_w)))) &&
             native_tree_req_ready_w) :
            (tree_parallel_mode_w ?
                (tree_parallel_req_ready_w &&
                 native_tree_main_req_ready_w &&
                 native_tree_ownership_req_ready_w) :
                (native_tree_main_req_ready_w &&
                 native_tree_ownership_req_ready_w))) :
        native_tree_req_ready_w;
assign use_sidecar_req_w =
    ENABLE_OWNERSHIP_CLOSURE_SIDECAR &&
    !rc_main_req_valid_w &&
    !native_tree_sidecar_pe_req_valid_w &&
    closure_sidecar_pe_req_valid_w;
assign native_tree_resp_select_w =
    ENABLE_NATIVE_TREE_SIDECAR &&
    lane0_resp_valid_w &&
    (lane0_resp_req_id_w == native_tree_sidecar_pe_req_id_w);
assign use_native_tree_req_w =
    ENABLE_NATIVE_TREE_SIDECAR &&
    !rc_main_req_valid_w &&
    native_tree_sidecar_pe_req_valid_w;
assign rc_req_valid = use_native_tree_req_w ? native_tree_sidecar_pe_req_valid_w :
                      (use_sidecar_req_w ? closure_sidecar_pe_req_valid_w :
                                           rc_main_req_valid_w);
assign rc_req_write = use_native_tree_req_w ? native_tree_sidecar_pe_req_write_w :
                      (use_sidecar_req_w ? closure_sidecar_pe_req_write_w :
                                           rc_main_req_write_w);
assign rc_req_addr = use_native_tree_req_w ? native_tree_sidecar_pe_req_addr_w :
                     (use_sidecar_req_w ? closure_sidecar_pe_req_addr_w :
                                          rc_main_req_addr_w);
assign rc_req_wdata = use_native_tree_req_w ?
                          native_tree_sidecar_pe_req_wdata_w :
                      (use_sidecar_req_w ? closure_sidecar_pe_req_wdata_w :
                                           rc_main_req_wdata_w);
assign rc_req_id = use_native_tree_req_w ? native_tree_sidecar_pe_req_id_w :
                   (use_sidecar_req_w ? closure_sidecar_pe_req_id_w :
                                        rc_main_req_id_w);
assign rc_req_pe_mask = use_native_tree_req_w ?
                            native_tree_sidecar_pe_req_pe_mask_w :
                        (use_sidecar_req_w ? closure_sidecar_pe_req_pe_mask_w :
                                             rc_main_req_pe_mask_w);
assign rc_req_priority = use_native_tree_req_w ?
                             native_tree_sidecar_pe_req_priority_w :
                         (use_sidecar_req_w ? closure_sidecar_pe_req_priority_w :
                                              rc_main_req_priority_w);
assign rc_req_bank_id = use_native_tree_req_w ?
                            native_tree_sidecar_pe_req_bank_id_w :
                        (use_sidecar_req_w ? closure_sidecar_pe_req_bank_id_w :
                                             rc_main_req_bank_id_w);
assign rc_req_subbank_id = use_native_tree_req_w ?
                               native_tree_sidecar_pe_req_subbank_id_w :
                           (use_sidecar_req_w ?
                                closure_sidecar_pe_req_subbank_id_w :
                                rc_main_req_subbank_id_w);
assign rc_main_req_ready_w =
    (use_native_tree_req_w || use_sidecar_req_w) ? 1'b0 : rc_req_ready;
assign tree_parallel_sram_rd_ready_w =
    (use_tree_parallel_sram_req_w && !tree_parallel_sram_req_write_w) ?
        rc_main_req_ready_w : 1'b0;
assign tree_parallel_sram_wr_ready_w =
    (use_tree_parallel_sram_req_w && tree_parallel_sram_req_write_w) ?
        rc_main_req_ready_w : 1'b0;
assign tree_parallel_hbm_rd_ready_w = 1'b1;
assign tree_parallel_hbm_resp_ready_w = 1'b1;
assign tree_parallel_kv_commit_sram_rd_ready_w =
    (use_tree_parallel_kv_commit_req_w && !tree_parallel_kv_commit_req_write_w) ?
        rc_main_req_ready_w : 1'b0;
assign tree_parallel_kv_commit_sram_wr_ready_w =
    (use_tree_parallel_kv_commit_req_w && tree_parallel_kv_commit_req_write_w) ?
        rc_main_req_ready_w : 1'b0;
assign native_tree_sidecar_pe_req_ready_w =
    use_native_tree_req_w ? rc_req_ready : 1'b0;
assign closure_sidecar_pe_req_ready_w =
    use_sidecar_req_w ? rc_req_ready : 1'b0;
assign prep_req_ready = use_prep_req ? rc_main_req_ready_w : 1'b0;
assign op_req_ready = use_prep_req ? 1'b0 : rc_main_req_ready_w;

assign lane0_resp_valid_w = mc_pe_valid_w[0];
assign lane0_resp_rdata_w = mc_pe_rdata_w[0 +: `SRAM_RDATA_W];
assign lane0_resp_req_id_w = mc_pe_req_id_w[0 +: `REQ_ID_W];
assign lane0_resp_pe_mask_w = mc_pe_mask_w[0 +: `PE_MASK_W];
assign lane0_resp_last_w = mc_pe_last_w[0];
assign tree_parallel_vec_resp_valid_raw_w = mc_pe_valid_w;
assign tree_parallel_vec_resp_rdata_w = mc_pe_rdata_w;
assign tree_parallel_vec_resp_req_id_w = mc_pe_req_id_w;
assign tree_parallel_vec_resp_pe_mask_w = mc_pe_mask_w;
assign tree_parallel_vec_resp_last_w = mc_pe_last_w;
genvar tree_parallel_vec_resp_lane_g;
generate
    for (tree_parallel_vec_resp_lane_g = 0;
         tree_parallel_vec_resp_lane_g < `MEM_REQ_LANES;
         tree_parallel_vec_resp_lane_g = tree_parallel_vec_resp_lane_g + 1) begin : gen_tree_parallel_vec_resp_classify
        assign tree_parallel_vec_resp_is_draft_w[tree_parallel_vec_resp_lane_g] =
            tree_parallel_vec_resp_valid_raw_w[tree_parallel_vec_resp_lane_g] &&
            (((tree_parallel_vec_resp_req_id_w[
                tree_parallel_vec_resp_lane_g*`REQ_ID_W +: `REQ_ID_W] !=
              {`REQ_ID_W{1'b0}}) &&
              (tree_parallel_vec_resp_req_id_w[
                tree_parallel_vec_resp_lane_g*`REQ_ID_W +: `REQ_ID_W] <=
             `MEM_REQ_LANES)) ||
             ((tree_parallel_vec_resp_pe_mask_w[
                 tree_parallel_vec_resp_lane_g*`PE_MASK_W +: `PE_MASK_W] &
               ~{{(`PE_MASK_W-1){1'b0}}, 1'b1}) != {`PE_MASK_W{1'b0}}));
        // A parked draft-lane response can survive across stage boundaries
        // because per-lane req_id values are reused. If the current draft read
        // on that lane has not yet been accepted, that parked response cannot
        // belong to the new request and must be drained before it blocks the
        // shared request controller in STATE_RESP.
        assign tree_parallel_vec_resp_orphan_drain_w[
            tree_parallel_vec_resp_lane_g] =
            tree_parallel_vec_resp_is_draft_w[tree_parallel_vec_resp_lane_g] &&
            tree_parallel_vec_rd_valid_raw_w[tree_parallel_vec_resp_lane_g] &&
            !tree_parallel_vec_req_ready_w[tree_parallel_vec_resp_lane_g] &&
            !tree_parallel_vec_resp_ready_w[tree_parallel_vec_resp_lane_g];
        assign tree_parallel_vec_resp_consume_w[
            tree_parallel_vec_resp_lane_g] =
            tree_parallel_vec_resp_ready_w[tree_parallel_vec_resp_lane_g] ||
            tree_parallel_vec_resp_orphan_drain_w[
                tree_parallel_vec_resp_lane_g];
        assign tree_parallel_vec_resp_valid_w[
            tree_parallel_vec_resp_lane_g] =
            tree_parallel_vec_resp_orphan_drain_w[
                tree_parallel_vec_resp_lane_g] ? 1'b0 :
                tree_parallel_vec_resp_valid_raw_w[
                    tree_parallel_vec_resp_lane_g];
    end
endgenerate
assign sidecar_resp_select_w =
    ENABLE_OWNERSHIP_CLOSURE_SIDECAR &&
    !native_tree_resp_select_w &&
    lane0_resp_valid_w &&
    (lane0_resp_req_id_w == closure_sidecar_pe_req_id_w);
assign tree_parallel_resp_select_w =
    tree_parallel_mode_w &&
    !native_tree_resp_select_w &&
    !sidecar_resp_select_w &&
    !tree_parallel_kv_commit_resp_select_w &&
    (|tree_parallel_vec_resp_is_draft_w);
assign tree_parallel_scalar_resp_select_w =
    tree_parallel_mode_w &&
    !native_tree_resp_select_w &&
    !sidecar_resp_select_w &&
    !tree_parallel_kv_commit_resp_select_w &&
    !tree_parallel_resp_select_w &&
    lane0_resp_valid_w;
assign tree_parallel_kv_commit_resp_select_w =
    tree_parallel_mode_w &&
    !native_tree_resp_select_w &&
    !sidecar_resp_select_w &&
    tree_parallel_kv_commit_busy_w &&
    lane0_resp_valid_w &&
    !use_tree_parallel_sram_req_w;
assign native_tree_sidecar_pe_resp_valid_w =
    native_tree_resp_select_w ? lane0_resp_valid_w : 1'b0;
assign native_tree_sidecar_pe_resp_rdata_w = lane0_resp_rdata_w;
assign native_tree_sidecar_pe_resp_req_id_w = lane0_resp_req_id_w;
assign native_tree_sidecar_pe_resp_pe_mask_w = lane0_resp_pe_mask_w;
assign native_tree_sidecar_pe_resp_last_w = lane0_resp_last_w;
assign closure_sidecar_pe_resp_valid_w =
    sidecar_resp_select_w ? lane0_resp_valid_w : 1'b0;
assign closure_sidecar_pe_resp_rdata_w = lane0_resp_rdata_w;
assign closure_sidecar_pe_resp_req_id_w = lane0_resp_req_id_w;
assign closure_sidecar_pe_resp_pe_mask_w = lane0_resp_pe_mask_w;
assign closure_sidecar_pe_resp_last_w = lane0_resp_last_w;
// A parked lane0 scalar response with req_id=0 can outlive the stage that
// issued it. If the next scalar stage has not yet had its read accepted, that
// response cannot belong to the new request and must be drained to break the
// req/resp circular wait on the shared scalar lane.
assign tree_parallel_scalar_resp_orphan_drain_w =
    tree_parallel_scalar_resp_select_w &&
    lane0_resp_valid_w &&
    tree_parallel_sram_rd_valid_w &&
    !tree_parallel_sram_rd_ready_w &&
    !tree_parallel_sram_resp_ready_w;
assign tree_parallel_sram_resp_valid_w =
    (tree_parallel_scalar_resp_select_w &&
     !tree_parallel_scalar_resp_orphan_drain_w) ? lane0_resp_valid_w : 1'b0;
assign tree_parallel_sram_resp_data_w = lane0_resp_rdata_w;
assign tree_parallel_sram_resp_id_w = lane0_resp_req_id_w;
assign tree_parallel_scalar_resp_consume_w =
    tree_parallel_sram_resp_ready_w ||
    tree_parallel_scalar_resp_orphan_drain_w;

assign op_resp_valid =
    (native_tree_resp_select_w || sidecar_resp_select_w ||
     tree_parallel_kv_commit_resp_select_w ||
     tree_parallel_resp_select_w ||
     tree_parallel_scalar_resp_select_w) ?
        1'b0 : lane0_resp_valid_w;
assign op_resp_rdata = lane0_resp_rdata_w;
assign op_resp_id = lane0_resp_req_id_w;
assign op_resp_last = lane0_resp_last_w;
assign pe_resp_ready = mc_resp_in_ready_w;
assign native_tree_or_sidecar_pe_resp_ready_w =
    native_tree_resp_select_w ?
        native_tree_sidecar_pe_resp_ready_w :
        closure_sidecar_pe_resp_ready_w;
assign tree_parallel_scalar_tail_resp_ready_w =
    native_tree_resp_select_w ?
        native_tree_sidecar_pe_resp_ready_w :
    (sidecar_resp_select_w ?
        closure_sidecar_pe_resp_ready_w :
    (tree_parallel_kv_commit_resp_select_w ?
        tree_parallel_kv_commit_resp_ready_w :
        op_resp_ready));
assign mc_pe_ready_w =
    tree_parallel_resp_select_w ?
        tree_parallel_vec_resp_consume_w :
    (tree_parallel_scalar_resp_select_w ?
        {{(`PE_MASK_W-1){1'b1}}, tree_parallel_scalar_resp_consume_w} :
        {{(`PE_MASK_W-1){1'b1}}, tree_parallel_scalar_tail_resp_ready_w});

assign pred_src_ready =
    ENABLE_NATIVE_TREE_MAIN_FRONTEND ? 1'b1 :
    (ENABLE_TREE_WINDOW_CONSUMER ? dispatch_src_pred_ready : pred_ready);
assign tree_parallel_req_mode_w =
    ENABLE_NATIVE_TREE_MAIN_FRONTEND &&
    (|native_tree_src_frontier_tree_mask_en);
assign tree_parallel_mode_w =
    tree_parallel_session_active_r ||
    tree_parallel_req_mode_w ||
    tree_parallel_kv_commit_busy_w;
assign native_tree_main_pred_ready_w =
    tree_parallel_mode_w ? agu_tree_in_ready_w : pred_ready;
assign tree_parallel_req_valid_w =
    tree_parallel_req_mode_w && native_tree_req_valid;
assign tree_parallel_committed_prefix_len_w =
    {{(16-`POSITION_ID_W){1'b0}}, native_tree_src_committed_len};
assign agu_frontier_node_id_w =
    tree_parallel_mode_w ? agu_tree_parallel_frontier_node_id_comb :
                           frontier_node_id;

always @* begin
    tree_parallel_seed_node_id_w = {`NODE_ID_W{1'b0}};
    tree_parallel_seed_token_id_w = {`TOKEN_ID_W{1'b0}};
    tree_parallel_seed_position_w = {`POSITION_ID_W{1'b0}};
    tree_parallel_branch_valid_w = {`BRANCH_NUM{1'b0}};
    tree_parallel_branch_node_ids_w =
        {(`BRANCH_NUM*`MAX_PRIVATE_NODES_PER_BRANCH*`NODE_ID_W){1'b0}};
    tree_parallel_branch_parent_node_ids_w =
        {(`BRANCH_NUM*`MAX_PRIVATE_NODES_PER_BRANCH*`NODE_ID_W){1'b0}};
    tree_parallel_branch_draft_tokens_w =
        {(`BRANCH_NUM*`MAX_PRIVATE_NODES_PER_BRANCH*`TOKEN_ID_W){1'b0}};
    tree_parallel_branch_draft_positions_w =
        {(`BRANCH_NUM*`MAX_PRIVATE_NODES_PER_BRANCH*`POSITION_ID_W){1'b0}};
    tree_parallel_branch_levels_valid_w =
        {(`BRANCH_NUM*`MAX_PRIVATE_NODES_PER_BRANCH){1'b0}};
    tree_parallel_seed_found_comb = 1'b0;
    tree_parallel_seed_ref_found_comb = 1'b0;
    agu_tree_parallel_frontier_node_id_comb =
        {(`TREE_FRONTIER_SLOTS*`NODE_ID_W){1'b0}};

    for (tree_parallel_branch_idx_i = 0;
         tree_parallel_branch_idx_i < `TREE_FRONTIER_SLOTS;
         tree_parallel_branch_idx_i = tree_parallel_branch_idx_i + 1) begin
        agu_tree_parallel_frontier_node_id_comb[
            (tree_parallel_branch_idx_i*`NODE_ID_W) +: `NODE_ID_W] =
            {{(`NODE_ID_W-`TREE_LEVEL_ID_W){1'b0}}, frontier_level_id};
    end

    for (tree_parallel_prefix_idx_i = 0;
         tree_parallel_prefix_idx_i < `TREE_MAX_PREFIX_NODES;
         tree_parallel_prefix_idx_i = tree_parallel_prefix_idx_i + 1) begin
        if (native_tree_src_prefix_slot_valid[tree_parallel_prefix_idx_i]) begin
            tree_parallel_seed_node_id_w =
                native_tree_src_prefix_node_id[
                    (tree_parallel_prefix_idx_i*`NODE_ID_W) +: `NODE_ID_W];
            tree_parallel_seed_token_id_w =
                native_tree_src_prefix_token_id[
                    (tree_parallel_prefix_idx_i*`TOKEN_ID_W) +: `TOKEN_ID_W];
            tree_parallel_seed_position_w =
                native_tree_src_prefix_position_id[
                    (tree_parallel_prefix_idx_i*`POSITION_ID_W) +:
                    `POSITION_ID_W];
            tree_parallel_seed_found_comb = 1'b1;
        end
    end

    for (tree_parallel_level_idx_i = 0;
         tree_parallel_level_idx_i < `MAX_PRIVATE_NODES_PER_BRANCH;
         tree_parallel_level_idx_i = tree_parallel_level_idx_i + 1) begin
        for (tree_parallel_branch_idx_i = 0;
             tree_parallel_branch_idx_i < `BRANCH_NUM;
             tree_parallel_branch_idx_i = tree_parallel_branch_idx_i + 1) begin
            tree_parallel_flat_slot_idx_i =
                (tree_parallel_level_idx_i * `TREE_FRONTIER_SLOTS) +
                tree_parallel_branch_idx_i;
            if ((tree_parallel_level_idx_i < `TREE_MAX_FRONTIER_LEVELS) &&
                native_tree_src_frontier_level_valid[tree_parallel_level_idx_i] &&
                native_tree_src_frontier_slot_valid[tree_parallel_flat_slot_idx_i]) begin
                if (!tree_parallel_seed_ref_found_comb) begin
                    tree_parallel_seed_token_id_w =
                        native_tree_src_frontier_referenced_token_id[
                            (tree_parallel_flat_slot_idx_i*`TOKEN_ID_W) +:
                            `TOKEN_ID_W];
                    tree_parallel_seed_position_w =
                        native_tree_src_frontier_referenced_position_id[
                            (tree_parallel_flat_slot_idx_i*`POSITION_ID_W) +:
                            `POSITION_ID_W];
                    tree_parallel_seed_ref_found_comb = 1'b1;
                    if (!tree_parallel_seed_found_comb) begin
                        tree_parallel_seed_node_id_w =
                            native_tree_src_frontier_parent_node_id[
                                (tree_parallel_flat_slot_idx_i*`NODE_ID_W) +:
                                `NODE_ID_W];
                        tree_parallel_seed_found_comb = 1'b1;
                    end
                end
                tree_parallel_branch_valid_w[tree_parallel_branch_idx_i] = 1'b1;
                tree_parallel_branch_levels_valid_w[
                    (tree_parallel_branch_idx_i*`MAX_PRIVATE_NODES_PER_BRANCH) +
                    tree_parallel_level_idx_i] = 1'b1;
                tree_parallel_branch_node_ids_w[
                    ((tree_parallel_branch_idx_i*`MAX_PRIVATE_NODES_PER_BRANCH +
                      tree_parallel_level_idx_i)*`NODE_ID_W) +: `NODE_ID_W] =
                    native_tree_src_frontier_node_id[
                        (tree_parallel_flat_slot_idx_i*`NODE_ID_W) +:
                        `NODE_ID_W];
                tree_parallel_branch_parent_node_ids_w[
                    ((tree_parallel_branch_idx_i*`MAX_PRIVATE_NODES_PER_BRANCH +
                      tree_parallel_level_idx_i)*`NODE_ID_W) +: `NODE_ID_W] =
                    native_tree_src_frontier_parent_node_id[
                        (tree_parallel_flat_slot_idx_i*`NODE_ID_W) +:
                        `NODE_ID_W];
                tree_parallel_branch_draft_tokens_w[
                    ((tree_parallel_branch_idx_i*`MAX_PRIVATE_NODES_PER_BRANCH +
                      tree_parallel_level_idx_i)*`TOKEN_ID_W) +: `TOKEN_ID_W] =
                    native_tree_src_frontier_token_id[
                        (tree_parallel_flat_slot_idx_i*`TOKEN_ID_W) +:
                        `TOKEN_ID_W];
                tree_parallel_branch_draft_positions_w[
                    ((tree_parallel_branch_idx_i*`MAX_PRIVATE_NODES_PER_BRANCH +
                      tree_parallel_level_idx_i)*`POSITION_ID_W) +:
                     `POSITION_ID_W] =
                    native_tree_src_frontier_position_id[
                        (tree_parallel_flat_slot_idx_i*`POSITION_ID_W) +:
                        `POSITION_ID_W];
            end
        end
    end

    if (!tree_parallel_seed_ref_found_comb &&
        (native_tree_src_committed_len != {`POSITION_ID_W{1'b0}})) begin
        tree_parallel_seed_position_w =
            native_tree_src_committed_len - {{(`POSITION_ID_W-1){1'b0}}, 1'b1};
    end
end

assign tree_window_src_ready =
    ENABLE_NATIVE_TREE_MAIN_FRONTEND ?
        (ENABLE_OWNERSHIP_CLOSURE_SIDECAR ?
            closure_sidecar_src_tree_window_ready_w : 1'b1) :
    (ENABLE_TREE_WINDOW_CONSUMER ?
        (dispatch_src_tree_window_ready &
         (ENABLE_OWNERSHIP_CLOSURE_SIDECAR ?
             closure_sidecar_src_tree_window_ready_w : 1'b1)) :
                                  tree_window_ready);

assign pred_valid =
    ENABLE_NATIVE_TREE_MAIN_FRONTEND ?
        (tree_parallel_mode_w ? 1'b0 : native_tree_main_pred_valid_w) :
    (ENABLE_TREE_WINDOW_CONSUMER ? dispatch_pred_valid : pred_src_valid);
assign pred_source_id =
    ENABLE_NATIVE_TREE_MAIN_FRONTEND ?
        (tree_parallel_mode_w ? {PRED_SOURCE_ID_W{1'b0}} :
         native_tree_main_pred_source_id_w) :
    (ENABLE_TREE_WINDOW_CONSUMER ? dispatch_pred_source_id :
                                   pred_src_source_id);
assign pred_parent_node_id =
    ENABLE_NATIVE_TREE_MAIN_FRONTEND ?
        (tree_parallel_mode_w ? {`NODE_ID_W{1'b0}} :
         native_tree_main_pred_parent_node_id_w) :
    (ENABLE_TREE_WINDOW_CONSUMER ? dispatch_pred_parent_node_id :
                                   pred_src_parent_node_id);
assign pred_token_id =
    ENABLE_NATIVE_TREE_MAIN_FRONTEND ?
        (tree_parallel_mode_w ? {`TOKEN_ID_W{1'b0}} :
         native_tree_main_pred_token_id_w) :
    (ENABLE_TREE_WINDOW_CONSUMER ? dispatch_pred_token_id :
                                   pred_src_token_id);
assign pred_referenced_token_id =
    ENABLE_NATIVE_TREE_MAIN_FRONTEND ?
        (tree_parallel_mode_w ? {`TOKEN_ID_W{1'b0}} :
         native_tree_main_pred_referenced_token_id_w) :
    (ENABLE_TREE_WINDOW_CONSUMER ? dispatch_pred_referenced_token_id :
                                   pred_src_referenced_token_id);
assign pred_referenced_position =
    ENABLE_NATIVE_TREE_MAIN_FRONTEND ?
        (tree_parallel_mode_w ? {`POSITION_ID_W{1'b0}} :
         native_tree_main_pred_referenced_position_w) :
    (ENABLE_TREE_WINDOW_CONSUMER ? dispatch_pred_referenced_position :
                                   pred_src_referenced_position);
assign pred_confidence =
    ENABLE_NATIVE_TREE_MAIN_FRONTEND ?
        (tree_parallel_mode_w ? {CONF_W{1'b0}} :
         native_tree_main_pred_confidence_w) :
    (ENABLE_TREE_WINDOW_CONSUMER ? dispatch_pred_confidence :
                                   pred_src_confidence);
assign pred_is_last_in_window =
    ENABLE_NATIVE_TREE_MAIN_FRONTEND ?
        (tree_parallel_mode_w ? 1'b0 :
         native_tree_main_pred_is_last_in_window_w) :
    (ENABLE_TREE_WINDOW_CONSUMER ? dispatch_pred_is_last_in_window :
                                   pred_src_is_last_in_window);
assign pred_branch_id_w =
    ENABLE_NATIVE_TREE_MAIN_FRONTEND ?
        (tree_parallel_mode_w ? {`BRANCH_ID_W{1'b0}} :
         native_tree_main_pred_branch_id_w) :
    (ENABLE_TREE_WINDOW_CONSUMER ?
        dispatch_pred_slot_idx[`BRANCH_ID_W-1:0] :
        pred_src_source_id[`BRANCH_ID_W-1:0]);
assign pred_level_id_w =
    ENABLE_NATIVE_TREE_MAIN_FRONTEND ?
        (tree_parallel_mode_w ? {`TREE_LEVEL_ID_W{1'b0}} :
         native_tree_main_pred_level_id_w) :
        {`TREE_LEVEL_ID_W{1'b0}};
assign pred_tree_mask_en_w =
    ENABLE_NATIVE_TREE_MAIN_FRONTEND ?
        (tree_parallel_mode_w ? 1'b0 : native_tree_main_pred_tree_mask_en_w) :
    (ENABLE_TREE_WINDOW_CONSUMER ? dispatch_pred_tree_mask_en : 1'b0);
assign pred_prefix_len_w =
    ENABLE_NATIVE_TREE_MAIN_FRONTEND ?
        (tree_parallel_mode_w ? 16'd0 : native_tree_main_pred_prefix_len_w) :
    (ENABLE_TREE_WINDOW_CONSUMER ? dispatch_pred_prefix_len : 16'd0);
assign pred_visible_mask_w =
    ENABLE_NATIVE_TREE_MAIN_FRONTEND ?
        (tree_parallel_mode_w ? {`TOY_MAX_POS_EMB{1'b0}} :
         native_tree_main_pred_visible_mask_w) :
        {`TOY_MAX_POS_EMB{1'b0}};

assign tree_cfg_valid_w =
    ENABLE_NATIVE_TREE_MAIN_FRONTEND ?
        (tree_parallel_mode_w ? 1'b0 : native_tree_main_cfg_valid_w) :
    (ENABLE_TREE_WINDOW_CONSUMER ? dispatch_cfg_valid : cfg_valid);
assign tree_cfg_data_w =
    ENABLE_NATIVE_TREE_MAIN_FRONTEND ? native_tree_main_cfg_data_w :
    (ENABLE_TREE_WINDOW_CONSUMER ? dispatch_cfg_data : cfg_data);
assign tree_start_w =
    ENABLE_NATIVE_TREE_MAIN_FRONTEND ?
        (tree_parallel_mode_w ? 1'b0 : native_tree_main_start_w) :
    (ENABLE_TREE_WINDOW_CONSUMER ? dispatch_start : start);

assign tree_window_valid = tree_window_src_valid;
assign tree_window_parent_node_id = tree_window_src_parent_node_id;
assign tree_window_slot_valid = tree_window_src_slot_valid;
assign tree_window_source_id = tree_window_src_source_id;
assign tree_window_token_id = tree_window_src_token_id;
assign tree_window_referenced_token_id =
    tree_window_src_referenced_token_id;
assign tree_window_referenced_position =
    tree_window_src_referenced_position;
assign tree_window_confidence = tree_window_src_confidence;

assign busy =
    ENABLE_NATIVE_TREE_MAIN_FRONTEND ?
        (tree_busy ||
         (tree_parallel_mode_w ? tree_parallel_busy_w : native_tree_main_busy_w) ||
         closure_sidecar_busy_w ||
         native_tree_sidecar_busy_w || native_tree_lifecycle_busy_w) :
    (ENABLE_TREE_WINDOW_CONSUMER ?
        (tree_busy || dispatch_busy || closure_sidecar_busy_w ||
         native_tree_sidecar_busy_w) :
        (tree_busy || closure_sidecar_busy_w || native_tree_sidecar_busy_w));
assign error_flag = tree_error_flag | token_error_flag;

assign hbm_req_valid_w =
    tree_parallel_hbm_rd_valid_w ||
    operator_hbm_req_valid_w ||
    wb_hbm_req_valid_w;
assign hbm_req_write_w =
    tree_parallel_hbm_rd_valid_w ? 1'b0 :
    (operator_hbm_req_valid_w ? operator_hbm_req_write_w :
                                wb_hbm_req_write_w);
assign hbm_req_addr_w =
    tree_parallel_hbm_rd_valid_w ? tree_parallel_hbm_rd_addr_w :
    (operator_hbm_req_valid_w ? operator_hbm_req_addr_w :
                                wb_hbm_req_addr_w);
assign hbm_req_wdata_w =
    tree_parallel_hbm_rd_valid_w ? {`HBM_DATA_W{1'b0}} :
    (operator_hbm_req_valid_w ? operator_hbm_req_wdata_w :
                                wb_hbm_req_wdata_w);
assign hbm_req_id_w =
    tree_parallel_hbm_rd_valid_w ? {`REQ_ID_W{1'b0}} :
    (operator_hbm_req_valid_w ? operator_hbm_req_id_w :
                                wb_hbm_req_id_w);
assign hbm_req_valid = hbm_req_valid_w;
assign hbm_req_write = hbm_req_write_w;
assign hbm_req_addr = hbm_req_addr_w;
assign hbm_req_wdata = hbm_req_wdata_w;
assign hbm_req_id = hbm_req_id_w;
assign wb_generated_token_fire_w = wb_done && !wb_error;
assign wb_generated_token_id_w = wb_data[15:0];
assign native_tree_req_accept_fire_w =
    ENABLE_NATIVE_TREE_MAIN_FRONTEND &&
    native_tree_req_valid &&
    native_tree_req_ready;
assign token_commit_valid =
    tree_parallel_commit_replay_active_r ?
        tree_parallel_commit_issue_valid_comb :
        (commit_valid && lifecycle_commit_select_valid_comb);
assign token_commit_index =
    tree_parallel_commit_replay_active_r ?
        tree_parallel_commit_issue_index_comb :
        lifecycle_commit_index_by_slot_r[
            (lifecycle_commit_select_branch_comb*`TOKEN_REG_INDEX_W) +:
            `TOKEN_REG_INDEX_W];
assign token_commit_req_id =
    tree_parallel_commit_replay_active_r ?
        tree_parallel_commit_issue_req_id_comb :
        lifecycle_req_id_r;
assign token_commit_branch_mask =
    tree_parallel_commit_replay_active_r ?
        tree_parallel_commit_issue_branch_mask_comb :
        commit_branch_mask;
assign token_commit_node_mask =
    tree_parallel_commit_replay_active_r ?
        tree_parallel_commit_issue_node_mask_comb :
        commit_node_mask;
assign bank_commit_valid =
    tree_parallel_commit_replay_active_r ?
        tree_parallel_commit_issue_valid_comb :
        (commit_valid && lifecycle_commit_select_valid_comb);
assign bank_commit_req_id =
    tree_parallel_commit_replay_active_r ?
        tree_parallel_commit_issue_req_id_comb :
        lifecycle_req_id_r;
assign bank_commit_sram_id =
    tree_parallel_commit_replay_active_r ?
        tree_parallel_commit_issue_sram_id_comb :
        lifecycle_commit_sram_id_by_slot_r[
            (lifecycle_commit_select_branch_comb*`SRAM_ID_W) +: `SRAM_ID_W];
assign bank_commit_bank_id =
    tree_parallel_commit_replay_active_r ?
        tree_parallel_commit_issue_bank_id_comb :
        lifecycle_commit_bank_id_by_slot_r[
            (lifecycle_commit_select_branch_comb*`BANK_ID_W) +: `BANK_ID_W];
assign bank_commit_subbank_start =
    tree_parallel_commit_replay_active_r ?
        tree_parallel_commit_issue_subbank_comb :
        lifecycle_commit_subbank_by_slot_r[
            (lifecycle_commit_select_branch_comb*`SUBBANK_ID_W) +:
            `SUBBANK_ID_W];
assign bank_commit_group_len =
    tree_parallel_commit_replay_active_r ?
        tree_parallel_commit_issue_group_len_comb :
        lifecycle_commit_group_len_by_slot_r[
            (lifecycle_commit_select_branch_comb*`KV_GROUP_LEN_W) +:
            `KV_GROUP_LEN_W];
assign bank_commit_branch_mask =
    tree_parallel_commit_replay_active_r ?
        tree_parallel_commit_issue_branch_mask_comb :
        commit_branch_mask;
assign bank_commit_node_mask =
    tree_parallel_commit_replay_active_r ?
        tree_parallel_commit_issue_node_mask_comb :
        commit_node_mask;
assign commit_valid =
    tree_parallel_mode_w ? tree_parallel_commit_valid_w : cmp_commit_valid_w;
assign commit_branch_mask =
    tree_parallel_mode_w ?
        tree_parallel_commit_branch_mask_comb :
        cmp_commit_branch_mask_w;
assign commit_node_mask =
    tree_parallel_mode_w ?
        tree_parallel_commit_node_mask_comb :
        cmp_commit_node_mask_w;
assign flush_valid =
    tree_parallel_mode_w ? tree_parallel_flush_valid_comb : cmp_flush_valid_w;
assign flush_branch_mask =
    tree_parallel_mode_w ?
        tree_parallel_commit_flush_mask_w :
        cmp_flush_branch_mask_w;
assign flush_node_mask =
    tree_parallel_mode_w ?
        tree_parallel_flush_node_mask_comb :
        cmp_flush_node_mask_w;
assign accepted_prefix_valid =
    tree_parallel_mode_w ?
        (tree_parallel_commit_valid_w &&
         (tree_parallel_commit_depth_w != 3'd0)) :
        cmp_accepted_prefix_valid_w;
assign accepted_prefix_req_id =
    tree_parallel_mode_w ? lifecycle_req_id_r : cmp_accepted_prefix_req_id_w;
assign accepted_prefix_depth =
    tree_parallel_mode_w ?
        tree_parallel_commit_depth_w[PRIVATE_DEPTH_W-1:0] :
        cmp_accepted_prefix_depth_w;
assign accepted_prefix_node_id =
    tree_parallel_mode_w ?
        tree_parallel_accepted_prefix_node_id_comb :
        cmp_accepted_prefix_node_id_w;
assign live_branch_mask =
    tree_parallel_mode_w ?
        tree_parallel_live_branch_mask_comb :
        cmp_live_branch_mask_w;
assign prune_branch_mask =
    tree_parallel_mode_w ?
        tree_parallel_prune_branch_mask_comb :
        cmp_prune_branch_mask_w;
assign branch_liveness_update_valid_w =
    tree_parallel_mode_w ? tree_parallel_commit_valid_w :
    cmp_accepted_prefix_valid_w;
assign tree_parallel_wb_pending_r = tree_parallel_wb_pending_state_r;
assign tree_parallel_wb_result_valid_w =
    tree_parallel_wb_pending_r;
assign tree_parallel_wb_result_ready_w = writeback_result_ready_w;
assign tree_parallel_wb_result_token_id_w =
    {{(`TOKEN_ID_W-`REQ_ID_W){1'b0}}, lifecycle_req_id_r};
assign tree_parallel_wb_result_addr_w = {`SRAM_ADDR_W{1'b0}};
assign tree_parallel_wb_result_data_w =
    {{(`SRAM_WDATA_W-16){1'b0}}, tree_parallel_commit_bonus_token_id_w};
assign tree_parallel_wb_result_status_w = {RESULT_STATUS_W{1'b0}};
assign operator_result_valid_w =
    operator_raw_result_valid_w || tree_parallel_wb_result_valid_w;
assign operator_raw_result_ready_w =
    writeback_result_ready_w && !tree_parallel_wb_result_valid_w;
assign operator_result_ready_w = operator_raw_result_ready_w;
assign operator_result_token_id_w =
    tree_parallel_wb_result_valid_w ?
        tree_parallel_wb_result_token_id_w :
        operator_raw_result_token_id_w;
assign operator_result_addr_w =
    tree_parallel_wb_result_valid_w ?
        tree_parallel_wb_result_addr_w :
        operator_raw_result_addr_w;
assign operator_result_data_w =
    tree_parallel_wb_result_valid_w ?
        tree_parallel_wb_result_data_w :
        operator_raw_result_data_w;
assign operator_result_status_w =
    tree_parallel_wb_result_valid_w ?
        tree_parallel_wb_result_status_w :
        operator_raw_result_status_w;
assign native_tree_lifecycle_busy_w =
    lifecycle_window_active_r ||
    active_issue_valid_r ||
    lifecycle_cmp_fire_r ||
    tree_parallel_commit_pending_r ||
    tree_parallel_commit_replay_active_r ||
    tree_parallel_kv_commit_busy_w ||
    token_wr_valid ||
    free_list_flush_drain_busy;

always @* begin
    lifecycle_cmp_slot_valid_comb = {`BRANCH_NUM{1'b0}};
    lifecycle_commit_select_valid_comb = 1'b0;
    lifecycle_commit_select_branch_comb = {`BRANCH_ID_W{1'b0}};
    lifecycle_active_branch_depth_comb = lifecycle_candidate_depth_by_branch_r;
    lifecycle_active_branch_node_id_comb = lifecycle_candidate_node_path_by_branch_r;
    lifecycle_active_branch_parent_node_id_comb =
        lifecycle_candidate_parent_path_by_branch_r;
    lifecycle_result_private_depth_comb = lifecycle_result_depth_by_branch_r;

    if (lifecycle_cmp_fire_r) begin
        lifecycle_cmp_slot_valid_comb = lifecycle_slot_meta_valid_r;
    end

    for (lifecycle_slot_i = 0;
         lifecycle_slot_i < `BRANCH_NUM;
         lifecycle_slot_i = lifecycle_slot_i + 1) begin
        if (commit_branch_mask[lifecycle_slot_i] &&
            !lifecycle_commit_select_valid_comb) begin
            lifecycle_commit_select_valid_comb = 1'b1;
            lifecycle_commit_select_branch_comb =
                lifecycle_slot_i[`BRANCH_ID_W-1:0];
        end
    end
end

always @* begin
    tree_parallel_commit_branch_mask_comb = {`BRANCH_MASK_W{1'b0}};
    tree_parallel_commit_node_mask_comb = {`NODE_MASK_W{1'b0}};
    tree_parallel_flush_valid_comb = 1'b0;
    tree_parallel_flush_node_mask_comb = {`NODE_MASK_W{1'b0}};
    tree_parallel_accepted_prefix_node_id_comb =
        {(`MAX_VERIFY_NODES_PER_BRANCH*`NODE_ID_W){1'b0}};
    tree_parallel_live_branch_mask_comb = {`BRANCH_MASK_W{1'b0}};
    tree_parallel_prune_branch_mask_comb =
        tree_parallel_branch_valid_w & tree_parallel_commit_flush_mask_w;

    if (tree_parallel_commit_valid_w &&
        (tree_parallel_commit_depth_w != 3'd0) &&
        (tree_parallel_commit_branch_id_w < `BRANCH_NUM)) begin
        tree_parallel_commit_branch_mask_comb[tree_parallel_commit_branch_id_w] =
            1'b1;

        for (tree_parallel_reduce_level_i = 0;
             tree_parallel_reduce_level_i < `MAX_VERIFY_NODES_PER_BRANCH;
             tree_parallel_reduce_level_i = tree_parallel_reduce_level_i + 1) begin
            tree_parallel_reduce_bit_idx_i =
                (tree_parallel_commit_branch_id_w * `MAX_VERIFY_NODES_PER_BRANCH) +
                tree_parallel_reduce_level_i;

            if (tree_parallel_reduce_level_i < tree_parallel_commit_depth_w) begin
                tree_parallel_commit_node_mask_comb[tree_parallel_reduce_bit_idx_i] =
                    1'b1;
                tree_parallel_accepted_prefix_node_id_comb[
                    (tree_parallel_reduce_level_i*`NODE_ID_W) +: `NODE_ID_W] =
                    tree_parallel_reduce_level_i[`NODE_ID_W-1:0];
            end
        end

        tree_parallel_live_branch_mask_comb[tree_parallel_commit_branch_id_w] =
            1'b1;
    end

    tree_parallel_prune_branch_mask_comb =
        tree_parallel_branch_valid_w &
        ~tree_parallel_live_branch_mask_comb;

    for (tree_parallel_reduce_branch_i = 0;
         tree_parallel_reduce_branch_i < `BRANCH_NUM;
         tree_parallel_reduce_branch_i = tree_parallel_reduce_branch_i + 1) begin
        if (tree_parallel_commit_valid_w &&
            tree_parallel_commit_flush_mask_w[tree_parallel_reduce_branch_i]) begin
            tree_parallel_flush_valid_comb = 1'b1;
            for (tree_parallel_reduce_level_i = 0;
                 tree_parallel_reduce_level_i < `MAX_VERIFY_NODES_PER_BRANCH;
                 tree_parallel_reduce_level_i = tree_parallel_reduce_level_i + 1) begin
                if (lifecycle_slot_meta_valid_r[tree_parallel_reduce_branch_i] &&
                    (tree_parallel_reduce_level_i <
                     lifecycle_candidate_depth_by_branch_r[
                         (tree_parallel_reduce_branch_i*PRIVATE_DEPTH_W) +:
                         PRIVATE_DEPTH_W]) &&
                    ((tree_parallel_reduce_branch_i !=
                      tree_parallel_commit_branch_id_w) ||
                     (tree_parallel_reduce_level_i >=
                      tree_parallel_commit_depth_w))) begin
                    tree_parallel_reduce_bit_idx_i =
                        (tree_parallel_reduce_branch_i *
                         `MAX_VERIFY_NODES_PER_BRANCH) +
                        tree_parallel_reduce_level_i;
                    tree_parallel_flush_node_mask_comb[tree_parallel_reduce_bit_idx_i] =
                        1'b1;
                end
            end
        end
    end
end

always @* begin
    tree_parallel_commit_meta_ready_comb = 1'b0;
    tree_parallel_commit_issue_valid_comb = 1'b0;
    tree_parallel_commit_issue_index_comb = {`TOKEN_REG_INDEX_W{1'b0}};
    tree_parallel_commit_issue_req_id_comb = lifecycle_req_id_r;
    tree_parallel_commit_issue_branch_mask_comb = {`BRANCH_MASK_W{1'b0}};
    tree_parallel_commit_issue_node_mask_comb = {`NODE_MASK_W{1'b0}};
    tree_parallel_commit_issue_sram_id_comb = {`SRAM_ID_W{1'b0}};
    tree_parallel_commit_issue_bank_id_comb = {`BANK_ID_W{1'b0}};
    tree_parallel_commit_issue_subbank_comb = {`SUBBANK_ID_W{1'b0}};
    tree_parallel_commit_issue_group_len_comb = {`KV_GROUP_LEN_W{1'b0}};

    if (tree_parallel_commit_pending_r &&
        tree_parallel_commit_pending_depth_r != {PRIVATE_DEPTH_W{1'b0}}) begin
        tree_parallel_commit_meta_ready_comb = 1'b1;
        for (tree_parallel_replay_level_i = 0;
             tree_parallel_replay_level_i < `MAX_VERIFY_NODES_PER_BRANCH;
             tree_parallel_replay_level_i = tree_parallel_replay_level_i + 1) begin
            if (tree_parallel_replay_level_i ==
                tree_parallel_commit_replay_cursor_r) begin
                tree_parallel_replay_node_id_i =
                    tree_parallel_commit_pending_node_id_r[
                        (tree_parallel_replay_level_i*`NODE_ID_W) +:
                        `NODE_ID_W];
                tree_parallel_replay_flat_idx_i =
                    (tree_parallel_commit_pending_branch_r *
                     `MAX_VERIFY_NODES_PER_BRANCH) +
                    tree_parallel_replay_node_id_i;
                if (!lifecycle_commit_meta_valid_by_node_r[
                        tree_parallel_replay_flat_idx_i]) begin
                    tree_parallel_commit_meta_ready_comb = 1'b0;
                end else begin
                    tree_parallel_commit_issue_valid_comb = 1'b1;
                    tree_parallel_commit_issue_index_comb =
                        lifecycle_commit_index_by_node_r[
                            (tree_parallel_replay_flat_idx_i *
                             `TOKEN_REG_INDEX_W) +: `TOKEN_REG_INDEX_W];
                    tree_parallel_commit_issue_branch_mask_comb[
                        tree_parallel_commit_pending_branch_r] = 1'b1;
                    tree_parallel_commit_issue_node_mask_comb[
                        tree_parallel_replay_flat_idx_i] = 1'b1;
                    tree_parallel_commit_issue_sram_id_comb =
                        lifecycle_commit_sram_id_by_node_r[
                            (tree_parallel_replay_flat_idx_i *
                             `SRAM_ID_W) +: `SRAM_ID_W];
                    tree_parallel_commit_issue_bank_id_comb =
                        lifecycle_commit_bank_id_by_node_r[
                            (tree_parallel_replay_flat_idx_i *
                             `BANK_ID_W) +: `BANK_ID_W];
                    tree_parallel_commit_issue_subbank_comb =
                        lifecycle_commit_subbank_by_node_r[
                            (tree_parallel_replay_flat_idx_i *
                             `SUBBANK_ID_W) +: `SUBBANK_ID_W];
                    tree_parallel_commit_issue_group_len_comb =
                        lifecycle_commit_group_len_by_node_r[
                            (tree_parallel_replay_flat_idx_i *
                             `KV_GROUP_LEN_W) +: `KV_GROUP_LEN_W];
                end
            end
        end
    end
end

assign pred_accept_fire_w = pred_valid && pred_ready;
assign wb_hht_match_w =
    wb_done &&
    hht_active_valid_r &&
    (wb_token_id == hht_active_token_id_r);
assign accepted_token_fire_w = wb_hht_match_w && !wb_error;
assign accepted_position_w =
    hht_active_referenced_position_r +
    {{(`POSITION_ID_W-1){1'b0}}, 1'b1};
assign onchip_hht_session_start_w = cfg_valid && start;
assign onchip_hht_session_live_w = tree_busy || frontend_busy_w;
assign selected_hht_cand_valid_w =
    ENABLE_ONCHIP_HHT_CONTEXT ? onchip_hht_cand_valid_w : hht_cand_valid;
assign selected_hht_parent_node_id_w =
    ENABLE_ONCHIP_HHT_CONTEXT ? onchip_hht_parent_node_id_w :
                                hht_parent_node_id;
assign selected_hht_token_id_w =
    ENABLE_ONCHIP_HHT_CONTEXT ? onchip_hht_token_id_w : hht_token_id;
assign selected_hht_referenced_token_id_w =
    ENABLE_ONCHIP_HHT_CONTEXT ? onchip_hht_referenced_token_id_w :
                                hht_referenced_token_id;
assign selected_hht_referenced_position_w =
    ENABLE_ONCHIP_HHT_CONTEXT ? onchip_hht_referenced_position_w :
                                hht_referenced_position;
assign selected_hht_confidence_w =
    ENABLE_ONCHIP_HHT_CONTEXT ? onchip_hht_confidence_w : hht_confidence;
assign onchip_hht_capture_fire_w =
    (selected_hht_cand_valid_w && selected_hht_cand_ready_w) ||
    (|(draft_cand_valid & draft_cand_ready));
assign hht_cand_ready =
    ENABLE_ONCHIP_HHT_CONTEXT ? 1'b0 : selected_hht_cand_ready_w;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        hht_active_valid_r <= 1'b0;
        hht_active_parent_node_id_r <= {`NODE_ID_W{1'b0}};
        hht_active_token_id_r <= {`TOKEN_ID_W{1'b0}};
        hht_active_referenced_token_id_r <= {`TOKEN_ID_W{1'b0}};
        hht_active_referenced_position_r <= {`POSITION_ID_W{1'b0}};
        hht_active_confidence_r <= {CONF_W{1'b0}};
        hht_update_valid_r <= 1'b0;
        hht_update_parent_node_id_r <= {`NODE_ID_W{1'b0}};
        hht_update_token_id_r <= {`TOKEN_ID_W{1'b0}};
        hht_update_referenced_token_id_r <= {`TOKEN_ID_W{1'b0}};
        hht_update_referenced_position_r <= {`POSITION_ID_W{1'b0}};
        hht_update_confidence_r <= {CONF_W{1'b0}};
        onchip_hht_admission_open_r <= 1'b0;
        token_wr_index_r <= {`TOKEN_REG_INDEX_W{1'b0}};
        lifecycle_window_active_r <= 1'b0;
        lifecycle_req_id_r <= {`REQ_ID_W{1'b0}};
        tree_parallel_session_active_r <= 1'b0;
        active_issue_valid_r <= 1'b0;
        active_issue_branch_id_r <= {`BRANCH_ID_W{1'b0}};
        active_issue_level_id_r <= {`TREE_LEVEL_ID_W{1'b0}};
        active_issue_private_depth_r <= {PRIVATE_DEPTH_W{1'b0}};
        active_issue_node_id_r <= {`NODE_ID_W{1'b0}};
        active_issue_parent_node_id_r <= {`NODE_ID_W{1'b0}};
        active_issue_candidate_token_id_r <= {`TOKEN_ID_W{1'b0}};
        active_issue_is_last_r <= 1'b0;
        lifecycle_slot_meta_valid_r <= {`BRANCH_NUM{1'b0}};
        lifecycle_slot_result_valid_r <= {`BRANCH_NUM{1'b0}};
        lifecycle_cmp_candidate_token_id_r <=
            {(`BRANCH_NUM*`TOKEN_ID_W){1'b0}};
        lifecycle_cmp_real_token_id_r <= {(`BRANCH_NUM*`TOKEN_ID_W){1'b0}};
        lifecycle_cmp_node_id_r <= {(`BRANCH_NUM*`NODE_ID_W){1'b0}};
        lifecycle_cmp_parent_node_id_r <= {(`BRANCH_NUM*`NODE_ID_W){1'b0}};
        lifecycle_cmp_branch_id_r <= {(`BRANCH_NUM*`BRANCH_ID_W){1'b0}};
        lifecycle_candidate_depth_by_branch_r <= {DEPTH_PACK_W{1'b0}};
        lifecycle_candidate_node_path_by_branch_r <= {PATH_PACK_W{1'b0}};
        lifecycle_candidate_parent_path_by_branch_r <= {PATH_PACK_W{1'b0}};
        lifecycle_result_depth_by_branch_r <= {DEPTH_PACK_W{1'b0}};
        lifecycle_commit_meta_valid_by_node_r <=
            {(`BRANCH_NUM*`MAX_VERIFY_NODES_PER_BRANCH){1'b0}};
        lifecycle_commit_index_by_slot_r <=
            {(`BRANCH_NUM*`TOKEN_REG_INDEX_W){1'b0}};
        lifecycle_commit_sram_id_by_slot_r <=
            {(`BRANCH_NUM*`SRAM_ID_W){1'b0}};
        lifecycle_commit_bank_id_by_slot_r <=
            {(`BRANCH_NUM*`BANK_ID_W){1'b0}};
        lifecycle_commit_subbank_by_slot_r <=
            {(`BRANCH_NUM*`SUBBANK_ID_W){1'b0}};
        lifecycle_commit_group_len_by_slot_r <=
            {(`BRANCH_NUM*`KV_GROUP_LEN_W){1'b0}};
        lifecycle_commit_index_by_node_r <=
            {(`BRANCH_NUM*`MAX_VERIFY_NODES_PER_BRANCH*`TOKEN_REG_INDEX_W){1'b0}};
        lifecycle_commit_sram_id_by_node_r <=
            {(`BRANCH_NUM*`MAX_VERIFY_NODES_PER_BRANCH*`SRAM_ID_W){1'b0}};
        lifecycle_commit_bank_id_by_node_r <=
            {(`BRANCH_NUM*`MAX_VERIFY_NODES_PER_BRANCH*`BANK_ID_W){1'b0}};
        lifecycle_commit_subbank_by_node_r <=
            {(`BRANCH_NUM*`MAX_VERIFY_NODES_PER_BRANCH*`SUBBANK_ID_W){1'b0}};
        lifecycle_commit_group_len_by_node_r <=
            {(`BRANCH_NUM*`MAX_VERIFY_NODES_PER_BRANCH*`KV_GROUP_LEN_W){1'b0}};
        lifecycle_cmp_fire_r <= 1'b0;
        lifecycle_active_branch_depth_comb <= {DEPTH_PACK_W{1'b0}};
        lifecycle_active_branch_node_id_comb <= {PATH_PACK_W{1'b0}};
        lifecycle_active_branch_parent_node_id_comb <= {PATH_PACK_W{1'b0}};
        lifecycle_result_private_depth_comb <=
            {(`BRANCH_NUM*PRIVATE_DEPTH_W){1'b0}};
        lifecycle_result_accept_comb <= {`BRANCH_NUM{1'b0}};
        tree_parallel_commit_pending_r <= 1'b0;
        tree_parallel_commit_pending_depth_r <= {PRIVATE_DEPTH_W{1'b0}};
        tree_parallel_commit_pending_branch_r <= {`BRANCH_ID_W{1'b0}};
        tree_parallel_commit_pending_node_id_r <=
            {(`MAX_VERIFY_NODES_PER_BRANCH*`NODE_ID_W){1'b0}};
        tree_parallel_commit_replay_active_r <= 1'b0;
        tree_parallel_commit_replay_cursor_r <= {PRIVATE_DEPTH_W{1'b0}};
        tree_parallel_commit_replay_depth_r <= {PRIVATE_DEPTH_W{1'b0}};
        tree_parallel_commit_replay_branch_r <= {`BRANCH_ID_W{1'b0}};
        tree_parallel_commit_replay_node_id_r <=
            {(`MAX_VERIFY_NODES_PER_BRANCH*`NODE_ID_W){1'b0}};
        tree_parallel_wb_pending_state_r <= 1'b0;
    end else begin
        hht_update_valid_r <= 1'b0;
        lifecycle_cmp_fire_r <= 1'b0;

        if (tree_parallel_wb_pending_r && tree_parallel_wb_result_ready_w) begin
            tree_parallel_wb_pending_state_r <= 1'b0;
        end

        if (onchip_hht_session_start_w && !onchip_hht_capture_fire_w) begin
            onchip_hht_admission_open_r <= 1'b1;
        end else if (onchip_hht_capture_fire_w || !onchip_hht_session_live_w) begin
            onchip_hht_admission_open_r <= 1'b0;
        end

        if (token_wr_valid) begin
            token_wr_index_r <= token_wr_index_r + 1'b1;
            if ((lifecycle_window_active_r ||
                 tree_parallel_session_active_r ||
                 tree_parallel_commit_pending_r ||
                 tree_parallel_commit_replay_active_r) &&
                !token_wr_is_shared &&
                (token_wr_branch_id < `BRANCH_NUM)) begin
                lifecycle_commit_index_by_slot_r[
                    (token_wr_branch_id*`TOKEN_REG_INDEX_W) +:
                    `TOKEN_REG_INDEX_W] <= token_wr_index_r;
                lifecycle_commit_sram_id_by_slot_r[
                    (token_wr_branch_id*`SRAM_ID_W) +: `SRAM_ID_W] <=
                    token_wr_sram_id;
                lifecycle_commit_bank_id_by_slot_r[
                    (token_wr_branch_id*`BANK_ID_W) +: `BANK_ID_W] <=
                    token_wr_bank_id;
                lifecycle_commit_subbank_by_slot_r[
                    (token_wr_branch_id*`SUBBANK_ID_W) +:
                    `SUBBANK_ID_W] <= token_wr_subbank_start;
                lifecycle_commit_group_len_by_slot_r[
                    (token_wr_branch_id*`KV_GROUP_LEN_W) +:
                    `KV_GROUP_LEN_W] <= token_wr_group_len;
                if (token_wr_node_id < `MAX_VERIFY_NODES_PER_BRANCH) begin
                    tree_parallel_meta_flat_idx_i =
                        (token_wr_branch_id * `MAX_VERIFY_NODES_PER_BRANCH) +
                        token_wr_node_id;
                    lifecycle_commit_meta_valid_by_node_r[
                        tree_parallel_meta_flat_idx_i] <= 1'b1;
                    lifecycle_commit_index_by_node_r[
                        (tree_parallel_meta_flat_idx_i*`TOKEN_REG_INDEX_W) +:
                        `TOKEN_REG_INDEX_W] <= token_wr_index_r;
                    lifecycle_commit_sram_id_by_node_r[
                        (tree_parallel_meta_flat_idx_i*`SRAM_ID_W) +:
                        `SRAM_ID_W] <= token_wr_sram_id;
                    lifecycle_commit_bank_id_by_node_r[
                        (tree_parallel_meta_flat_idx_i*`BANK_ID_W) +:
                        `BANK_ID_W] <= token_wr_bank_id;
                    lifecycle_commit_subbank_by_node_r[
                        (tree_parallel_meta_flat_idx_i*`SUBBANK_ID_W) +:
                        `SUBBANK_ID_W] <= token_wr_subbank_start;
                    lifecycle_commit_group_len_by_node_r[
                        (tree_parallel_meta_flat_idx_i*`KV_GROUP_LEN_W) +:
                        `KV_GROUP_LEN_W] <= token_wr_group_len;
                end
            end
        end

        if (native_tree_req_accept_fire_w) begin
            token_wr_index_r <= {`TOKEN_REG_INDEX_W{1'b0}};
            lifecycle_req_id_r <= native_tree_req_id;
            tree_parallel_session_active_r <= tree_parallel_req_mode_w;
            lifecycle_window_active_r <=
                |native_tree_src_frontier_tree_mask_en;
            active_issue_valid_r <= 1'b0;
            active_issue_branch_id_r <= {`BRANCH_ID_W{1'b0}};
            active_issue_level_id_r <= {`TREE_LEVEL_ID_W{1'b0}};
            active_issue_private_depth_r <= {PRIVATE_DEPTH_W{1'b0}};
            active_issue_node_id_r <= {`NODE_ID_W{1'b0}};
            active_issue_parent_node_id_r <= {`NODE_ID_W{1'b0}};
            active_issue_candidate_token_id_r <= {`TOKEN_ID_W{1'b0}};
            active_issue_is_last_r <= 1'b0;
            lifecycle_slot_meta_valid_r <= {`BRANCH_NUM{1'b0}};
            lifecycle_slot_result_valid_r <= {`BRANCH_NUM{1'b0}};
            lifecycle_cmp_candidate_token_id_r <=
                {(`BRANCH_NUM*`TOKEN_ID_W){1'b0}};
            lifecycle_cmp_real_token_id_r <=
                {(`BRANCH_NUM*`TOKEN_ID_W){1'b0}};
            lifecycle_cmp_node_id_r <= {(`BRANCH_NUM*`NODE_ID_W){1'b0}};
            lifecycle_cmp_parent_node_id_r <=
                {(`BRANCH_NUM*`NODE_ID_W){1'b0}};
            lifecycle_cmp_branch_id_r <= {(`BRANCH_NUM*`BRANCH_ID_W){1'b0}};
            lifecycle_candidate_depth_by_branch_r <= {DEPTH_PACK_W{1'b0}};
            lifecycle_candidate_node_path_by_branch_r <= {PATH_PACK_W{1'b0}};
            lifecycle_candidate_parent_path_by_branch_r <= {PATH_PACK_W{1'b0}};
            lifecycle_result_depth_by_branch_r <= {DEPTH_PACK_W{1'b0}};
            lifecycle_commit_meta_valid_by_node_r <=
                {(`BRANCH_NUM*`MAX_VERIFY_NODES_PER_BRANCH){1'b0}};
            lifecycle_commit_index_by_slot_r <=
                {(`BRANCH_NUM*`TOKEN_REG_INDEX_W){1'b0}};
            lifecycle_commit_sram_id_by_slot_r <=
                {(`BRANCH_NUM*`SRAM_ID_W){1'b0}};
            lifecycle_commit_bank_id_by_slot_r <=
                {(`BRANCH_NUM*`BANK_ID_W){1'b0}};
            lifecycle_commit_subbank_by_slot_r <=
                {(`BRANCH_NUM*`SUBBANK_ID_W){1'b0}};
            lifecycle_commit_group_len_by_slot_r <=
                {(`BRANCH_NUM*`KV_GROUP_LEN_W){1'b0}};
            lifecycle_commit_index_by_node_r <=
                {(`BRANCH_NUM*`MAX_VERIFY_NODES_PER_BRANCH*`TOKEN_REG_INDEX_W){1'b0}};
            lifecycle_commit_sram_id_by_node_r <=
                {(`BRANCH_NUM*`MAX_VERIFY_NODES_PER_BRANCH*`SRAM_ID_W){1'b0}};
            lifecycle_commit_bank_id_by_node_r <=
                {(`BRANCH_NUM*`MAX_VERIFY_NODES_PER_BRANCH*`BANK_ID_W){1'b0}};
            lifecycle_commit_subbank_by_node_r <=
                {(`BRANCH_NUM*`MAX_VERIFY_NODES_PER_BRANCH*`SUBBANK_ID_W){1'b0}};
            lifecycle_commit_group_len_by_node_r <=
                {(`BRANCH_NUM*`MAX_VERIFY_NODES_PER_BRANCH*`KV_GROUP_LEN_W){1'b0}};
            lifecycle_active_branch_depth_comb <= {DEPTH_PACK_W{1'b0}};
            lifecycle_active_branch_node_id_comb <= {PATH_PACK_W{1'b0}};
            lifecycle_active_branch_parent_node_id_comb <=
                {PATH_PACK_W{1'b0}};
            lifecycle_result_private_depth_comb <=
                {(`BRANCH_NUM*PRIVATE_DEPTH_W){1'b0}};
            lifecycle_result_accept_comb <= {`BRANCH_NUM{1'b0}};
            tree_parallel_commit_pending_r <= 1'b0;
            tree_parallel_commit_pending_depth_r <= {PRIVATE_DEPTH_W{1'b0}};
            tree_parallel_commit_pending_branch_r <= {`BRANCH_ID_W{1'b0}};
            tree_parallel_commit_pending_node_id_r <=
                {(`MAX_VERIFY_NODES_PER_BRANCH*`NODE_ID_W){1'b0}};
            tree_parallel_commit_replay_active_r <= 1'b0;
            tree_parallel_commit_replay_cursor_r <= {PRIVATE_DEPTH_W{1'b0}};
            tree_parallel_commit_replay_depth_r <= {PRIVATE_DEPTH_W{1'b0}};
            tree_parallel_commit_replay_branch_r <= {`BRANCH_ID_W{1'b0}};
            tree_parallel_commit_replay_node_id_r <=
                {(`MAX_VERIFY_NODES_PER_BRANCH*`NODE_ID_W){1'b0}};
            tree_parallel_wb_pending_state_r <= 1'b0;

            if (tree_parallel_req_mode_w) begin
                for (tree_parallel_branch_idx_i = 0;
                     tree_parallel_branch_idx_i < `BRANCH_NUM;
                     tree_parallel_branch_idx_i =
                         tree_parallel_branch_idx_i + 1) begin
                    if (tree_parallel_branch_valid_w[tree_parallel_branch_idx_i]) begin
                        lifecycle_slot_meta_valid_r[tree_parallel_branch_idx_i] <= 1'b1;
                        lifecycle_cmp_branch_id_r[
                            (tree_parallel_branch_idx_i*`BRANCH_ID_W) +:
                            `BRANCH_ID_W] <=
                            tree_parallel_branch_idx_i[`BRANCH_ID_W-1:0];
                    end
                end

                for (tree_parallel_level_idx_i = 0;
                     tree_parallel_level_idx_i < `MAX_PRIVATE_NODES_PER_BRANCH;
                     tree_parallel_level_idx_i =
                         tree_parallel_level_idx_i + 1) begin
                    for (tree_parallel_branch_idx_i = 0;
                         tree_parallel_branch_idx_i < `BRANCH_NUM;
                         tree_parallel_branch_idx_i =
                             tree_parallel_branch_idx_i + 1) begin
                        if (tree_parallel_branch_levels_valid_w[
                                (tree_parallel_branch_idx_i*
                                 `MAX_PRIVATE_NODES_PER_BRANCH) +
                                tree_parallel_level_idx_i]) begin
                            lifecycle_cmp_candidate_token_id_r[
                                (tree_parallel_branch_idx_i*`TOKEN_ID_W) +:
                                `TOKEN_ID_W] <=
                                tree_parallel_branch_draft_tokens_w[
                                    ((tree_parallel_branch_idx_i*
                                      `MAX_PRIVATE_NODES_PER_BRANCH +
                                      tree_parallel_level_idx_i)*`TOKEN_ID_W) +:
                                     `TOKEN_ID_W];
                            lifecycle_cmp_node_id_r[
                                (tree_parallel_branch_idx_i*`NODE_ID_W) +:
                                `NODE_ID_W] <=
                                tree_parallel_level_idx_i[`NODE_ID_W-1:0];
                            lifecycle_cmp_parent_node_id_r[
                                (tree_parallel_branch_idx_i*`NODE_ID_W) +:
                                `NODE_ID_W] <=
                                tree_parallel_branch_parent_node_ids_w[
                                    ((tree_parallel_branch_idx_i*
                                      `MAX_PRIVATE_NODES_PER_BRANCH +
                                      tree_parallel_level_idx_i)*`NODE_ID_W) +:
                                     `NODE_ID_W];
                            lifecycle_candidate_depth_by_branch_r[
                                (tree_parallel_branch_idx_i*PRIVATE_DEPTH_W) +:
                                PRIVATE_DEPTH_W] <=
                                tree_parallel_level_idx_i[PRIVATE_DEPTH_W-1:0] + 1'b1;
                            lifecycle_candidate_node_path_by_branch_r[
                            (((tree_parallel_branch_idx_i*
                               `MAX_VERIFY_NODES_PER_BRANCH) +
                              tree_parallel_level_idx_i)*`NODE_ID_W) +:
                             `NODE_ID_W] <=
                            tree_parallel_level_idx_i[`NODE_ID_W-1:0];
                            lifecycle_candidate_parent_path_by_branch_r[
                                (((tree_parallel_branch_idx_i*
                                   `MAX_VERIFY_NODES_PER_BRANCH) +
                                  tree_parallel_level_idx_i)*`NODE_ID_W) +:
                                 `NODE_ID_W] <=
                                tree_parallel_branch_parent_node_ids_w[
                                    ((tree_parallel_branch_idx_i*
                                      `MAX_PRIVATE_NODES_PER_BRANCH +
                                      tree_parallel_level_idx_i)*`NODE_ID_W) +:
                                     `NODE_ID_W];
                        end
                    end
                end
            end
        end

        if (ENABLE_NATIVE_TREE_MAIN_FRONTEND &&
            lifecycle_window_active_r &&
            !tree_parallel_mode_w &&
            pred_accept_fire_w &&
            pred_tree_mask_en_w &&
            (pred_branch_id_w < `BRANCH_NUM)) begin
            active_issue_valid_r <= 1'b1;
            active_issue_branch_id_r <= pred_branch_id_w;
            active_issue_level_id_r <= pred_level_id_w;
            active_issue_private_depth_r <= pred_level_id_w + 1'b1;
            active_issue_node_id_r <= native_tree_main_pred_node_id_w;
            active_issue_parent_node_id_r <= pred_parent_node_id;
            active_issue_candidate_token_id_r <= pred_token_id;
            active_issue_is_last_r <= pred_is_last_in_window;
            lifecycle_slot_meta_valid_r[pred_branch_id_w] <= 1'b1;
            lifecycle_cmp_candidate_token_id_r[
                (pred_branch_id_w*`TOKEN_ID_W) +: `TOKEN_ID_W] <=
                pred_token_id;
            lifecycle_cmp_node_id_r[
                (pred_branch_id_w*`NODE_ID_W) +: `NODE_ID_W] <=
                native_tree_main_pred_node_id_w;
            lifecycle_cmp_parent_node_id_r[
                (pred_branch_id_w*`NODE_ID_W) +: `NODE_ID_W] <=
                pred_parent_node_id;
            lifecycle_cmp_branch_id_r[
                (pred_branch_id_w*`BRANCH_ID_W) +: `BRANCH_ID_W] <=
                pred_branch_id_w;
            lifecycle_candidate_depth_by_branch_r[
                (pred_branch_id_w*PRIVATE_DEPTH_W) +: PRIVATE_DEPTH_W] <=
                pred_level_id_w + 1'b1;
            lifecycle_candidate_node_path_by_branch_r[
                (((pred_branch_id_w*`MAX_VERIFY_NODES_PER_BRANCH) + pred_level_id_w)*
                 `NODE_ID_W) +: `NODE_ID_W] <=
                native_tree_main_pred_node_id_w;
            lifecycle_candidate_parent_path_by_branch_r[
                (((pred_branch_id_w*`MAX_VERIFY_NODES_PER_BRANCH) + pred_level_id_w)*
                 `NODE_ID_W) +: `NODE_ID_W] <=
                pred_parent_node_id;
        end

        if (wb_generated_token_fire_w &&
            lifecycle_window_active_r &&
            active_issue_valid_r &&
            (active_issue_branch_id_r < `BRANCH_NUM)) begin
            lifecycle_slot_result_valid_r[active_issue_branch_id_r] <= 1'b1;
            lifecycle_cmp_real_token_id_r[
                (active_issue_branch_id_r*`TOKEN_ID_W) +: `TOKEN_ID_W] <=
                wb_generated_token_id_w;
            lifecycle_result_depth_by_branch_r[
                (active_issue_branch_id_r*PRIVATE_DEPTH_W) +:
                PRIVATE_DEPTH_W] <=
                active_issue_private_depth_r;
            lifecycle_result_accept_comb[active_issue_branch_id_r] <=
                (wb_generated_token_id_w ==
                 active_issue_candidate_token_id_r);
            if (active_issue_is_last_r) begin
                lifecycle_cmp_fire_r <= 1'b1;
                lifecycle_window_active_r <= 1'b0;
            end
            active_issue_valid_r <= 1'b0;
        end

        if (tree_parallel_mode_w &&
            tree_parallel_commit_valid_w &&
            lifecycle_window_active_r) begin
            lifecycle_slot_result_valid_r <= tree_parallel_branch_valid_w;
            lifecycle_result_accept_comb <=
                tree_parallel_branch_valid_w &
                ~tree_parallel_commit_flush_mask_w;
            for (tree_parallel_branch_idx_i = 0;
                 tree_parallel_branch_idx_i < `BRANCH_NUM;
                 tree_parallel_branch_idx_i =
                     tree_parallel_branch_idx_i + 1) begin
                lifecycle_cmp_real_token_id_r[
                    (tree_parallel_branch_idx_i*`TOKEN_ID_W) +:
                    `TOKEN_ID_W] <=
                    tree_parallel_commit_bonus_token_id_w;
                if (tree_parallel_branch_idx_i ==
                    tree_parallel_commit_branch_id_w) begin
                    lifecycle_result_depth_by_branch_r[
                        (tree_parallel_branch_idx_i*PRIVATE_DEPTH_W) +:
                        PRIVATE_DEPTH_W] <=
                        tree_parallel_commit_depth_w[PRIVATE_DEPTH_W-1:0];
                end else begin
                    lifecycle_result_depth_by_branch_r[
                        (tree_parallel_branch_idx_i*PRIVATE_DEPTH_W) +:
                        PRIVATE_DEPTH_W] <=
                        {PRIVATE_DEPTH_W{1'b0}};
                end
            end
            lifecycle_cmp_fire_r <= 1'b1;
            lifecycle_window_active_r <= 1'b0;
            tree_parallel_commit_pending_r <=
                (tree_parallel_commit_depth_w[PRIVATE_DEPTH_W-1:0] !=
                 {PRIVATE_DEPTH_W{1'b0}});
            tree_parallel_commit_pending_depth_r <=
                tree_parallel_commit_depth_w[PRIVATE_DEPTH_W-1:0];
            tree_parallel_commit_pending_branch_r <=
                tree_parallel_commit_branch_id_w;
            tree_parallel_commit_pending_node_id_r <=
                tree_parallel_accepted_prefix_node_id_comb;
            tree_parallel_commit_replay_active_r <=
                (tree_parallel_commit_depth_w[PRIVATE_DEPTH_W-1:0] !=
                 {PRIVATE_DEPTH_W{1'b0}});
            tree_parallel_commit_replay_cursor_r <= {PRIVATE_DEPTH_W{1'b0}};
            tree_parallel_commit_replay_depth_r <=
                tree_parallel_commit_depth_w[PRIVATE_DEPTH_W-1:0];
            tree_parallel_commit_replay_branch_r <=
                tree_parallel_commit_branch_id_w;
            tree_parallel_commit_replay_node_id_r <=
                tree_parallel_accepted_prefix_node_id_comb;
            tree_parallel_session_active_r <=
                (tree_parallel_commit_depth_w[PRIVATE_DEPTH_W-1:0] !=
                 {PRIVATE_DEPTH_W{1'b0}});
            tree_parallel_wb_pending_state_r <= 1'b1;
        end

        if (tree_parallel_commit_replay_active_r &&
            tree_parallel_commit_issue_valid_comb) begin
            if ((tree_parallel_commit_replay_cursor_r + 1'b1) >=
                tree_parallel_commit_replay_depth_r) begin
                tree_parallel_commit_replay_active_r <= 1'b0;
                tree_parallel_commit_replay_cursor_r <= {PRIVATE_DEPTH_W{1'b0}};
            end else begin
                tree_parallel_commit_replay_cursor_r <=
                    tree_parallel_commit_replay_cursor_r + 1'b1;
            end
        end

        if (tree_parallel_commit_pending_r &&
            !tree_parallel_commit_replay_active_r &&
            !tree_parallel_kv_commit_busy_w) begin
            tree_parallel_commit_pending_r <= 1'b0;
            tree_parallel_session_active_r <= 1'b0;
        end

        if (pred_accept_fire_w) begin
            hht_active_valid_r <= 1'b1;
            hht_active_parent_node_id_r <= pred_parent_node_id;
            hht_active_token_id_r <= pred_token_id;
            hht_active_referenced_token_id_r <= pred_referenced_token_id;
            hht_active_referenced_position_r <= pred_referenced_position;
            hht_active_confidence_r <= pred_confidence;
        end

        if (wb_hht_match_w) begin
            hht_update_parent_node_id_r <= hht_active_parent_node_id_r;
            hht_update_token_id_r <= hht_active_token_id_r;
            hht_update_referenced_token_id_r <=
                hht_active_referenced_token_id_r;
            hht_update_referenced_position_r <=
                hht_active_referenced_position_r;
            hht_update_confidence_r <= hht_active_confidence_r;
            hht_update_valid_r <= !wb_error;
            hht_active_valid_r <= 1'b0;
        end
    end
end

HHTContextPredictor #(
    .CONF_W(CONF_W)
) u_hht_context_predictor (
    .clk(clk),
    .rst_n(rst_n),
    .admission_enable(
        ENABLE_ONCHIP_HHT_CONTEXT ? onchip_hht_admission_open_r : 1'b0),
    .accept_valid(
        ENABLE_ONCHIP_HHT_CONTEXT ? accepted_token_fire_w : 1'b0),
    .accept_parent_node_id(hht_active_parent_node_id_r),
    .accept_token_id(hht_active_token_id_r),
    .accept_position(accepted_position_w),
    .cand_valid(onchip_hht_cand_valid_w),
    .cand_parent_node_id(onchip_hht_parent_node_id_w),
    .cand_token_id(onchip_hht_token_id_w),
    .cand_referenced_token_id(onchip_hht_referenced_token_id_w),
    .cand_referenced_position(onchip_hht_referenced_position_w),
    .cand_confidence(onchip_hht_confidence_w)
);

IntegrationPredictionPart #(
    .DRAFT_PORTS(DRAFT_PORTS),
    .CONF_W(CONF_W),
    .ENABLE_MULTI_BRANCH_WINDOW(ENABLE_MULTI_BRANCH_WINDOW),
    .WINDOW_BRANCH_SLOTS(WINDOW_BRANCH_SLOTS),
    .ENABLE_HHT_LIFECYCLE(ENABLE_ONCHIP_HHT_CONTEXT ? 0 : 1),
    .HHT_CONF_TH(SELECTED_HHT_CONF_TH_W)
) u_integration_prediction_part (
    .clk(clk),
    .rst_n(rst_n),
    .hht_cand_valid(selected_hht_cand_valid_w),
    .hht_cand_ready(selected_hht_cand_ready_w),
    .hht_parent_node_id(selected_hht_parent_node_id_w),
    .hht_token_id(selected_hht_token_id_w),
    .hht_referenced_token_id(selected_hht_referenced_token_id_w),
    .hht_referenced_position(selected_hht_referenced_position_w),
    .hht_confidence(selected_hht_confidence_w),
    .draft_cand_valid(draft_cand_valid),
    .draft_cand_ready(draft_cand_ready),
    .draft_parent_node_id(draft_parent_node_id),
    .draft_token_id(draft_token_id),
    .draft_referenced_token_id(draft_referenced_token_id),
    .draft_referenced_position(draft_referenced_position),
    .draft_confidence(draft_confidence),
    .hht_update_valid(hht_update_valid_r),
    .hht_update_ready(hht_update_ready_w),
    .hht_update_parent_node_id(hht_update_parent_node_id_r),
    .hht_update_token_id(hht_update_token_id_r),
    .hht_update_referenced_token_id(hht_update_referenced_token_id_r),
    .hht_update_referenced_position(hht_update_referenced_position_r),
    .hht_update_confidence(hht_update_confidence_r),
    .pred_valid(pred_src_valid),
    .pred_ready(pred_src_ready),
    .pred_source_id(pred_src_source_id),
    .pred_parent_node_id(pred_src_parent_node_id),
    .pred_token_id(pred_src_token_id),
    .pred_referenced_token_id(pred_src_referenced_token_id),
    .pred_referenced_position(pred_src_referenced_position),
    .pred_confidence(pred_src_confidence),
    .pred_is_last_in_window(pred_src_is_last_in_window),
    .tree_window_valid(tree_window_src_valid),
    .tree_window_ready(tree_window_src_ready),
    .tree_window_parent_node_id(tree_window_src_parent_node_id),
    .tree_window_slot_valid(tree_window_src_slot_valid),
    .tree_window_source_id(tree_window_src_source_id),
    .tree_window_token_id(tree_window_src_token_id),
    .tree_window_referenced_token_id(tree_window_src_referenced_token_id),
    .tree_window_referenced_position(tree_window_src_referenced_position),
    .tree_window_confidence(tree_window_src_confidence)
);

PredictionWindowOwnershipClosureSidecar #(
    .SOURCE_ID_W(PRED_SOURCE_ID_W),
    .CONF_W(CONF_W),
    .WINDOW_BRANCH_SLOTS(WINDOW_BRANCH_SLOTS)
) u_prediction_window_ownership_closure_sidecar (
    .clk(clk),
    .rst_n(rst_n),
    .enable(ENABLE_OWNERSHIP_CLOSURE_SIDECAR),
    .main_path_quiet(main_path_quiet_w),
    .src_tree_window_valid(tree_window_src_valid),
    .src_tree_window_ready(closure_sidecar_src_tree_window_ready_w),
    .src_tree_window_parent_node_id(tree_window_src_parent_node_id),
    .src_tree_window_slot_valid(tree_window_src_slot_valid),
    .src_tree_window_source_id(tree_window_src_source_id),
    .src_tree_window_token_id(tree_window_src_token_id),
    .src_tree_window_referenced_token_id(
        tree_window_src_referenced_token_id),
    .src_tree_window_referenced_position(
        tree_window_src_referenced_position),
    .src_tree_window_confidence(tree_window_src_confidence),
    .pe_req_valid(closure_sidecar_pe_req_valid_w),
    .pe_req_ready(closure_sidecar_pe_req_ready_w),
    .pe_req_write(closure_sidecar_pe_req_write_w),
    .pe_req_addr(closure_sidecar_pe_req_addr_w),
    .pe_req_wdata(closure_sidecar_pe_req_wdata_w),
    .pe_req_req_id(closure_sidecar_pe_req_id_w),
    .pe_req_pe_mask(closure_sidecar_pe_req_pe_mask_w),
    .pe_req_priority(closure_sidecar_pe_req_priority_w),
    .pe_req_bank_id(closure_sidecar_pe_req_bank_id_w),
    .pe_req_subbank_id(closure_sidecar_pe_req_subbank_id_w),
    .pe_resp_valid(closure_sidecar_pe_resp_valid_w),
    .pe_resp_ready(closure_sidecar_pe_resp_ready_w),
    .pe_resp_rdata(closure_sidecar_pe_resp_rdata_w),
    .pe_resp_req_id(closure_sidecar_pe_resp_req_id_w),
    .pe_resp_pe_mask(closure_sidecar_pe_resp_pe_mask_w),
    .pe_resp_last(closure_sidecar_pe_resp_last_w),
    .busy(closure_sidecar_busy_w),
    .debug_window_fire(closure_sidecar_window_fire_w),
    .debug_token_wr_fire(closure_sidecar_token_wr_fire_w),
    .debug_lookup_hit(closure_sidecar_lookup_hit_w),
    .debug_pe_req_fire(closure_sidecar_pe_req_fire_w),
    .debug_pe_resp_fire(closure_sidecar_pe_resp_fire_w)
);

NativeTreeOwnershipClosureSidecar u_native_tree_ownership_closure_sidecar (
    .clk(clk),
    .rst_n(rst_n),
    .enable(ENABLE_NATIVE_TREE_SIDECAR),
    .main_path_quiet(main_path_quiet_w),
    .src_req_valid(native_tree_req_valid),
    .src_req_ready(native_tree_req_ready_w),
    .src_req_id(native_tree_req_id),
    .src_prefix_slot_valid(native_tree_src_prefix_slot_valid),
    .src_prefix_node_id(native_tree_src_prefix_node_id),
    .src_frontier_level_valid(native_tree_src_frontier_level_valid),
    .src_frontier_slot_valid(native_tree_src_frontier_slot_valid),
    .src_frontier_node_id(native_tree_src_frontier_node_id),
    .src_frontier_parent_node_id(native_tree_src_frontier_parent_node_id),
    .pe_req_valid(native_tree_sidecar_pe_req_valid_w),
    .pe_req_ready(native_tree_sidecar_pe_req_ready_w),
    .pe_req_write(native_tree_sidecar_pe_req_write_w),
    .pe_req_addr(native_tree_sidecar_pe_req_addr_w),
    .pe_req_wdata(native_tree_sidecar_pe_req_wdata_w),
    .pe_req_req_id(native_tree_sidecar_pe_req_id_w),
    .pe_req_pe_mask(native_tree_sidecar_pe_req_pe_mask_w),
    .pe_req_priority(native_tree_sidecar_pe_req_priority_w),
    .pe_req_bank_id(native_tree_sidecar_pe_req_bank_id_w),
    .pe_req_subbank_id(native_tree_sidecar_pe_req_subbank_id_w),
    .pe_resp_valid(native_tree_sidecar_pe_resp_valid_w),
    .pe_resp_ready(native_tree_sidecar_pe_resp_ready_w),
    .pe_resp_rdata(native_tree_sidecar_pe_resp_rdata_w),
    .pe_resp_req_id(native_tree_sidecar_pe_resp_req_id_w),
    .pe_resp_pe_mask(native_tree_sidecar_pe_resp_pe_mask_w),
    .pe_resp_last(native_tree_sidecar_pe_resp_last_w),
    .busy(native_tree_sidecar_busy_w),
    .debug_req_fire(native_tree_sidecar_req_fire_w),
    .debug_prefix_norm_fire(native_tree_sidecar_prefix_norm_fire_w),
    .debug_frontier_norm_fire(native_tree_sidecar_frontier_norm_fire_w),
    .debug_token_wr_fire(native_tree_sidecar_token_wr_fire_w),
    .debug_lookup_hit(native_tree_sidecar_lookup_hit_w),
    .debug_pe_req_fire(native_tree_sidecar_pe_req_fire_w),
    .debug_pe_resp_fire(native_tree_sidecar_pe_resp_fire_w)
);

tree_analyze u_tree_analyze (
    .clk(clk),
    .rst_n(rst_n),
    .req_valid(
        (ENABLE_NATIVE_TREE_MAIN_FRONTEND) ?
            native_tree_req_valid : 1'b0),
    .req_ready(native_tree_ownership_req_ready_w),
    .req_id(native_tree_req_id),
    .src_prefix_slot_valid(native_tree_src_prefix_slot_valid),
    .src_prefix_node_id(native_tree_src_prefix_node_id),
    .src_prefix_token_id(native_tree_src_prefix_token_id),
    .src_prefix_position_id(native_tree_src_prefix_position_id),
    .src_committed_len(native_tree_src_committed_len),
    .src_frontier_level_valid(native_tree_src_frontier_level_valid),
    .src_frontier_slot_valid(native_tree_src_frontier_slot_valid),
    .src_frontier_node_id(native_tree_src_frontier_node_id),
    .src_frontier_parent_node_id(native_tree_src_frontier_parent_node_id),
    .src_frontier_token_id(native_tree_src_frontier_token_id),
    .src_frontier_referenced_token_id(
        native_tree_src_frontier_referenced_token_id),
    .src_frontier_position_id(native_tree_src_frontier_position_id),
    .src_frontier_referenced_position_id(
        native_tree_src_frontier_referenced_position_id),
    .src_frontier_branch_id(native_tree_src_frontier_branch_id),
    .src_frontier_level_id(native_tree_src_frontier_level_id),
    .src_frontier_tree_mask_en(native_tree_src_frontier_tree_mask_en),
    .prefix_valid(prefix_valid),
    .prefix_ready(prefix_ready),
    .prefix_req_id(prefix_req_id),
    .prefix_node_valid(prefix_node_valid),
    .prefix_node_id(prefix_node_id),
    .prefix_parent_node_id(prefix_parent_node_id),
    .prefix_token_id(prefix_token_id),
    .prefix_position_id(prefix_position_id),
    .prefix_layer_id(prefix_layer_id),
    .prefix_is_last(prefix_is_last),
    .prefix_count(ownership_prefix_count_w),
    .frontier_valid(frontier_valid),
    .frontier_ready(frontier_ready),
    .frontier_req_id(frontier_req_id),
    .frontier_level_id(frontier_level_id),
    .frontier_slot_valid(frontier_slot_valid),
    .frontier_node_id(frontier_node_id),
    .frontier_parent_node_id(frontier_parent_node_id),
    .frontier_token_id(frontier_token_id),
    .frontier_referenced_token_id(frontier_referenced_token_id),
    .frontier_position_id(frontier_position_id),
    .frontier_referenced_position_id(frontier_referenced_position_id),
    .frontier_branch_id(frontier_branch_id),
    .frontier_level_slot_count(frontier_level_slot_count),
    .frontier_tree_mask_en(frontier_tree_mask_en)
);

comparator u_comparator (
    .clk(clk),
    .rst_n(rst_n),
    .cmp_req_id(lifecycle_req_id_r),
    .cmp_slot_valid(lifecycle_cmp_slot_valid_comb),
    .cmp_slot_real_token_id(lifecycle_cmp_real_token_id_r),
    .cmp_slot_candidate_token_id(lifecycle_cmp_candidate_token_id_r),
    .cmp_slot_node_id(lifecycle_cmp_node_id_r),
    .cmp_slot_parent_node_id(lifecycle_cmp_parent_node_id_r),
    .cmp_slot_branch_id(lifecycle_cmp_branch_id_r),
    .reduce_start_valid(lifecycle_cmp_fire_r),
    .reduce_req_id(lifecycle_req_id_r),
    .active_branch_valid(lifecycle_slot_meta_valid_r),
    .active_branch_epoch({EPOCH_PACK_W{1'b0}}),
    .active_branch_depth(lifecycle_active_branch_depth_comb),
    .active_branch_node_id(lifecycle_active_branch_node_id_comb),
    .active_branch_parent_node_id(lifecycle_active_branch_parent_node_id_comb),
    .result_slot_valid(lifecycle_slot_result_valid_r),
    .result_req_id(lifecycle_req_id_r),
    .result_branch_id(lifecycle_cmp_branch_id_r),
    .result_branch_epoch({EPOCH_PACK_W{1'b0}}),
    .result_private_depth(lifecycle_result_private_depth_comb),
    .result_node_id(lifecycle_cmp_node_id_r),
    .result_parent_node_id(lifecycle_cmp_parent_node_id_r),
    .result_accept(lifecycle_result_accept_comb),
    .commit_valid(cmp_commit_valid_w),
    .commit_branch_mask(cmp_commit_branch_mask_w),
    .commit_node_mask(cmp_commit_node_mask_w),
    .flush_valid(cmp_flush_valid_w),
    .flush_branch_mask(cmp_flush_branch_mask_w),
    .flush_node_mask(cmp_flush_node_mask_w),
    .accepted_prefix_valid(cmp_accepted_prefix_valid_w),
    .accepted_prefix_req_id(cmp_accepted_prefix_req_id_w),
    .accepted_prefix_depth(cmp_accepted_prefix_depth_w),
    .accepted_prefix_node_id(cmp_accepted_prefix_node_id_w),
    .live_branch_mask(cmp_live_branch_mask_w),
    .prune_branch_mask(cmp_prune_branch_mask_w)
);

agu u_agu (
    .clk(clk),
    .rst_n(rst_n),
    .tree_in_valid(
        tree_parallel_mode_w ? 1'b0 : pred_accept_fire_w),
    .tree_in_ready(agu_tree_in_ready_w),
    .tree_in_req_id(lifecycle_req_id_r),
    .tree_in_branch_id(
        tree_parallel_mode_w ?
            native_tree_main_pred_branch_id_w :
            pred_branch_id_w),
    .tree_in_node_id(
        tree_parallel_mode_w ?
            {{(`NODE_ID_W-`TREE_LEVEL_ID_W){1'b0}},
             native_tree_main_pred_level_id_w} :
            native_tree_main_pred_node_id_w),
    .prefix_valid(prefix_valid),
    .prefix_ready(prefix_ready),
    .prefix_req_id(prefix_req_id),
    .prefix_node_valid(prefix_node_valid),
    .prefix_node_id(prefix_node_id),
    .prefix_parent_node_id(prefix_parent_node_id),
    .prefix_token_id(prefix_token_id),
    .prefix_position_id(prefix_position_id),
    .prefix_layer_id(prefix_layer_id),
    .prefix_is_last(prefix_is_last),
    .frontier_valid(frontier_valid),
    .frontier_ready(frontier_ready),
    .frontier_req_id(frontier_req_id),
    .frontier_level_id(frontier_level_id),
    .frontier_slot_valid(frontier_slot_valid),
    .frontier_node_id(agu_frontier_node_id_w),
    .frontier_parent_node_id(frontier_parent_node_id),
    .frontier_token_id(frontier_token_id),
    .frontier_position_id(frontier_position_id),
    .prefetch_enq_ready(prefetch_enq_ready),
    .cand_resp_valid(cand_resp_valid),
    .cand_resp_grant(cand_resp_grant),
    .cand_resp_req_id(cand_resp_req_id),
    .cand_resp_sram_id(cand_resp_sram_id),
    .cand_resp_bank_id(cand_resp_bank_id),
    .cand_resp_subbank_start(cand_resp_subbank_start),
    .cand_resp_group_len(cand_resp_group_len),
    .alloc_resp_valid(alloc_resp_valid),
    .alloc_resp_grant(alloc_resp_grant),
    .alloc_resp_req_id(alloc_resp_req_id),
    .alloc_resp_sram_id(alloc_resp_sram_id),
    .alloc_resp_bank_id(alloc_resp_bank_id),
    .alloc_resp_subbank_start(alloc_resp_subbank_start),
    .alloc_resp_group_len(alloc_resp_group_len),
    .flush_freeze(flush_valid),
    .flush_drain_busy(free_list_flush_drain_busy),
    .flush_ctrl_valid(flush_valid),
    .flush_ctrl_req_id(lifecycle_req_id_r),
    .flush_ctrl_branch_mask(flush_branch_mask),
    .flush_ctrl_node_mask(flush_node_mask),
    .branch_liveness_valid(branch_liveness_update_valid_w),
    .branch_liveness_req_id(accepted_prefix_req_id),
    .branch_liveness_live_mask(live_branch_mask),
    .branch_liveness_prune_mask(prune_branch_mask),
    .prefix_norm_valid(),
    .prefix_norm_req_id(),
    .prefix_norm_node_valid(),
    .prefix_norm_node_id(),
    .prefix_norm_parent_node_id(),
    .prefix_norm_token_id(),
    .prefix_norm_position_id(),
    .prefix_norm_layer_id(),
    .prefix_norm_is_last(),
    .prefix_norm_is_shared(),
    .frontier_norm_valid(),
    .frontier_norm_req_id(),
    .frontier_norm_level_id(),
    .frontier_norm_slot_valid(),
    .frontier_norm_node_id(),
    .frontier_norm_parent_node_id(),
    .frontier_norm_token_id(),
    .frontier_norm_position_id(),
    .frontier_norm_size_subbank(),
    .frontier_norm_slot_shared(),
    .alloc_cand_valid(alloc_cand_valid),
    .alloc_cand_req_id(alloc_cand_req_id),
    .alloc_cand_branch_id(alloc_cand_branch_id),
    .alloc_cand_node_id(alloc_cand_node_id),
    .alloc_cand_size_subbank(alloc_cand_size_subbank),
    .alloc_cand_shared(alloc_cand_shared),
    .alloc_cand_sram_id(alloc_cand_sram_id),
    .alloc_cand_bank_id(alloc_cand_bank_id),
    .alloc_cand_subbank_start(alloc_cand_subbank_start),
    .alloc_cand_group_len(alloc_cand_group_len),
    .token_wr_valid(token_wr_valid),
    .token_wr_req_id(token_wr_req_id),
    .token_wr_token_id(token_wr_token_id),
    .token_wr_position_id(token_wr_position_id),
    .token_wr_node_id(token_wr_node_id),
    .token_wr_branch_id(token_wr_branch_id),
    .token_wr_branch_mask(token_wr_branch_mask),
    .token_wr_is_shared(token_wr_is_shared),
    .token_wr_sram_id(token_wr_sram_id),
    .token_wr_bank_id(token_wr_bank_id),
    .token_wr_subbank_start(token_wr_subbank_start),
    .token_wr_group_len(token_wr_group_len),
    .prefetch_enq_valid(prefetch_enq_valid),
    .prefetch_enq_req_id(prefetch_enq_req_id),
    .prefetch_enq_branch_id(prefetch_enq_branch_id),
    .prefetch_enq_node_id(prefetch_enq_node_id),
    .prefetch_enq_layer_id(prefetch_enq_layer_id),
    .prefetch_enq_size_subbank(prefetch_enq_size_subbank),
    .prefetch_enq_shared(prefetch_enq_shared),
    .prefetch_flush_valid(prefetch_flush_valid),
    .prefetch_flush_req_id(prefetch_flush_req_id),
    .prefetch_flush_branch_mask(prefetch_flush_branch_mask),
    .prefetch_flush_node_mask(prefetch_flush_node_mask),
    .free_list_flush_valid(free_list_flush_valid),
    .free_list_flush_req_id(free_list_flush_req_id),
    .free_list_flush_branch_mask(free_list_flush_branch_mask),
    .free_list_flush_node_mask(free_list_flush_node_mask),
    .token_flush_valid(token_flush_valid),
    .token_flush_req_id(token_flush_req_id),
    .token_flush_branch_mask(token_flush_branch_mask),
    .token_flush_node_mask(token_flush_node_mask)
);

prefetch_queue u_prefetch_queue (
    .clk(clk),
    .rst_n(rst_n),
    .enq_valid(prefetch_enq_valid),
    .enq_ready(prefetch_enq_ready),
    .enq_req_id(prefetch_enq_req_id),
    .enq_branch_id(prefetch_enq_branch_id),
    .enq_node_id(prefetch_enq_node_id),
    .enq_layer_id(prefetch_enq_layer_id),
    .enq_size_subbank(prefetch_enq_size_subbank),
    .enq_shared(prefetch_enq_shared),
    .flush_valid(prefetch_flush_valid),
    .flush_req_id(prefetch_flush_req_id),
    .flush_branch_mask(prefetch_flush_branch_mask),
    .flush_node_mask(prefetch_flush_node_mask),
    .deq_valid(queue_deq_valid),
    .deq_ready(queue_deq_ready),
    .deq_req_id(queue_deq_req_id),
    .deq_branch_id(queue_deq_branch_id),
    .deq_node_id(queue_deq_node_id),
    .deq_layer_id(queue_deq_layer_id),
    .deq_size_subbank(queue_deq_size_subbank),
    .deq_shared(queue_deq_shared)
);

free_list u_free_list (
    .clk(clk),
    .rst_n(rst_n),
    .cand_req_valid(queue_deq_valid),
    .cand_req_ready(queue_deq_ready),
    .cand_req_req_id(queue_deq_req_id),
    .cand_req_branch_id(queue_deq_branch_id),
    .cand_req_node_id(queue_deq_node_id),
    .cand_req_size_subbank(queue_deq_size_subbank),
    .cand_req_shared(queue_deq_shared),
    .cand_resp_valid(cand_resp_valid),
    .cand_resp_grant(cand_resp_grant),
    .cand_resp_req_id(cand_resp_req_id),
    .cand_resp_sram_id(cand_resp_sram_id),
    .cand_resp_bank_id(cand_resp_bank_id),
    .cand_resp_subbank_start(cand_resp_subbank_start),
    .cand_resp_group_len(cand_resp_group_len),
    .alloc_cand_valid(alloc_cand_valid),
    .alloc_cand_req_id(alloc_cand_req_id),
    .alloc_cand_branch_id(alloc_cand_branch_id),
    .alloc_cand_node_id(alloc_cand_node_id),
    .alloc_cand_size_subbank(alloc_cand_size_subbank),
    .alloc_cand_shared(alloc_cand_shared),
    .alloc_cand_sram_id(alloc_cand_sram_id),
    .alloc_cand_bank_id(alloc_cand_bank_id),
    .alloc_cand_subbank_start(alloc_cand_subbank_start),
    .alloc_cand_group_len(alloc_cand_group_len),
    .flush_valid(free_list_flush_valid),
    .flush_req_id(free_list_flush_req_id),
    .flush_branch_mask(free_list_flush_branch_mask),
    .flush_node_mask(free_list_flush_node_mask),
    .flush_drain_busy(free_list_flush_drain_busy),
    .flush_reclaim_valid(flush_reclaim_valid),
    .flush_reclaim_sram_id(flush_reclaim_sram_id),
    .flush_reclaim_bank_id(flush_reclaim_bank_id),
    .flush_reclaim_subbank_start(flush_reclaim_subbank_start),
    .flush_reclaim_group_len(flush_reclaim_group_len),
    .release_valid(1'b0),
    .release_sram_id({`SRAM_ID_W{1'b0}}),
    .release_bank_id({`BANK_ID_W{1'b0}}),
    .release_subbank_start({`SUBBANK_ID_W{1'b0}}),
    .release_group_len({`KV_GROUP_LEN_W{1'b0}})
);

bank_state_table u_bank_state_table (
    .clk(clk),
    .rst_n(rst_n),
    .cand_valid(alloc_cand_valid),
    .cand_ready(),
    .cand_req_id(alloc_cand_req_id),
    .cand_branch_id(alloc_cand_branch_id),
    .cand_node_id(alloc_cand_node_id),
    .cand_size_subbank(alloc_cand_size_subbank),
    .cand_shared(alloc_cand_shared),
    .cand_sram_id(alloc_cand_sram_id),
    .cand_bank_id(alloc_cand_bank_id),
    .cand_subbank_start(alloc_cand_subbank_start),
    .cand_group_len(alloc_cand_group_len),
    .alloc_resp_valid(alloc_resp_valid),
    .alloc_resp_grant(alloc_resp_grant),
    .alloc_resp_req_id(alloc_resp_req_id),
    .alloc_resp_sram_id(alloc_resp_sram_id),
    .alloc_resp_bank_id(alloc_resp_bank_id),
    .alloc_resp_subbank_start(alloc_resp_subbank_start),
    .alloc_resp_group_len(alloc_resp_group_len),
    .alloc_resp_occ_bitmap(alloc_resp_occ_bitmap),
    .commit_valid(bank_commit_valid),
    .commit_req_id(bank_commit_req_id),
    .commit_sram_id(bank_commit_sram_id),
    .commit_bank_id(bank_commit_bank_id),
    .commit_subbank_start(bank_commit_subbank_start),
    .commit_group_len(bank_commit_group_len),
    .commit_branch_mask(bank_commit_branch_mask),
    .commit_node_mask(bank_commit_node_mask),
    .flush_valid(1'b0),
    .flush_req_id({`REQ_ID_W{1'b0}}),
    .flush_branch_mask({`BRANCH_MASK_W{1'b0}}),
    .flush_node_mask({`NODE_MASK_W{1'b0}}),
    .reclaim_valid(flush_reclaim_valid),
    .reclaim_sram_id(flush_reclaim_sram_id),
    .reclaim_bank_id(flush_reclaim_bank_id),
    .reclaim_subbank_start(flush_reclaim_subbank_start),
    .reclaim_group_len(flush_reclaim_group_len),
    .query_valid(1'b0),
    .query_sram_id({`SRAM_ID_W{1'b0}}),
    .query_bank_id({`BANK_ID_W{1'b0}}),
    .query_resp_valid(),
    .query_resp_occ_bitmap(),
    .query_resp_state(),
    .query_resp_branch_mask(),
    .query_resp_refcnt()
);

token_register u_token_register (
    .clk(clk),
    .rst_n(rst_n),
    .wr_valid(token_wr_valid),
    .wr_ready(),
    .wr_index(token_wr_index_r),
    .wr_req_id(token_wr_req_id),
    .wr_token_id(token_wr_token_id),
    .wr_position_id(token_wr_position_id),
    .wr_node_id(token_wr_node_id),
    .wr_branch_id(token_wr_branch_id),
    .wr_sram_id(token_wr_sram_id),
    .wr_bank_id(token_wr_bank_id),
    .wr_subbank_start(token_wr_subbank_start),
    .wr_group_len(token_wr_group_len),
    .wr_branch_mask(token_wr_branch_mask),
    .wr_is_shared(token_wr_is_shared),
    .lookup_valid(kv_lookup_valid),
    .lookup_ready(),
    .lookup_req_id({`REQ_ID_W{1'b0}}),
    .lookup_token_id(kv_lookup_token_id),
    .lookup_position_id(kv_lookup_position_id),
    .lookup_resp_valid(),
    .lookup_resp_hit(),
    .lookup_resp_req_id(),
    .lookup_resp_sram_id(),
    .lookup_resp_bank_id(),
    .lookup_resp_subbank_start(),
    .lookup_resp_group_len(),
    .lookup_resp_branch_mask(),
    .lookup_resp_is_shared(),
    .lookup_resp_entry_type(kv_lookup_entry_type_w),
    .lookup_resp_state(kv_lookup_entry_state_w),
    .commit_valid(token_commit_valid),
    .commit_index(token_commit_index),
    .commit_req_id(token_commit_req_id),
    .commit_branch_mask(token_commit_branch_mask),
    .commit_node_mask(token_commit_node_mask),
    .flush_valid(token_flush_valid),
    .flush_req_id(token_flush_req_id),
    .flush_branch_mask(token_flush_branch_mask),
    .flush_node_mask(token_flush_node_mask),
    .entry_count(token_entry_count),
    .error_flag(token_error_flag)
);

tree_mask_generator #(
    .VISIBLE_MASK_W(`TOY_MAX_POS_EMB),
    .SLOT_COUNT(WINDOW_BRANCH_SLOTS),
    .LEVEL_COUNT(`TREE_MAX_FRONTIER_LEVELS)
) u_tree_mask_generator (
    .src_prefix_slot_valid(native_tree_src_prefix_slot_valid),
    .src_prefix_node_id(native_tree_src_prefix_node_id),
    .src_prefix_position_id(native_tree_src_prefix_position_id),
    .src_committed_len(native_tree_src_committed_len),
    .src_frontier_level_valid(native_tree_src_frontier_level_valid),
    .src_frontier_slot_valid(native_tree_src_frontier_slot_valid),
    .src_frontier_node_id(native_tree_src_frontier_node_id),
    .src_frontier_parent_node_id(native_tree_src_frontier_parent_node_id),
    .src_frontier_position_id(native_tree_src_frontier_position_id),
    .src_frontier_branch_id(native_tree_src_frontier_branch_id),
    .src_frontier_level_id(native_tree_src_frontier_level_id),
    .visible_mask_by_level(native_tree_visible_mask_by_level_w)
);

tree_verify_dispatcher u_tree_verify_dispatcher (
    .clk(clk),
    .rst_n(rst_n),
    .tree_req_valid(tree_parallel_req_valid_w),
    .tree_req_ready(tree_parallel_req_ready_w),
    .seed_node_id(tree_parallel_seed_node_id_w),
    .seed_token_id(tree_parallel_seed_token_id_w),
    .seed_position(tree_parallel_seed_position_w),
    .branch_valid(tree_parallel_branch_valid_w),
    .branch_node_ids(tree_parallel_branch_node_ids_w),
    .branch_parent_node_ids(tree_parallel_branch_parent_node_ids_w),
    .branch_draft_tokens(tree_parallel_branch_draft_tokens_w),
    .branch_draft_positions(tree_parallel_branch_draft_positions_w),
    .branch_levels_valid(tree_parallel_branch_levels_valid_w),
    .committed_prefix_len(tree_parallel_committed_prefix_len_w),
    .batch_out_valid(tree_parallel_batch_valid_w),
    .batch_out_ready(tree_parallel_batch_ready_w),
    .batch_out_count(tree_parallel_batch_count_w),
    .batch_out_token_ids(tree_parallel_batch_token_ids_w),
    .batch_out_positions(tree_parallel_batch_positions_w),
    .batch_out_tree_mask(tree_parallel_batch_tree_mask_w),
    .batch_out_prefix_len(tree_parallel_batch_prefix_len_w),
    .batch_out_seed_kv_valid(tree_parallel_batch_seed_kv_valid_w),
    .batch_out_slot_is_seed(tree_parallel_batch_slot_is_seed_w),
    .fwd_result_valid(tree_parallel_fwd_result_valid_w),
    .fwd_result_ready(tree_parallel_fwd_result_ready_w),
    .fwd_result_count(tree_parallel_fwd_result_count_w),
    .fwd_result_token_ids(tree_parallel_fwd_result_token_ids_w),
    .commit_valid(tree_parallel_commit_valid_w),
    .commit_branch_id(tree_parallel_commit_branch_id_w),
    .commit_depth(tree_parallel_commit_depth_w),
    .commit_bonus_token_id(tree_parallel_commit_bonus_token_id_w),
    .commit_flush_mask(tree_parallel_commit_flush_mask_w),
    .commit_slots(tree_parallel_commit_slots_w),
    .commit_slot_positions(tree_parallel_commit_slot_positions_w),
    .busy(tree_parallel_busy_w)
);

fp16_inference_top u_tree_parallel_batch_inference_top (
    .clk(clk),
    .rst_n(rst_n),
    .token_in_valid(1'b0),
    .token_in_ready(),
    .token_in_id(32'd0),
    .token_in_is_bos(1'b0),
    .token_out_valid(),
    .token_out_ready(1'b0),
    .token_out_id(),
    .cfg_embedding_base(ISSUE_SRC_ADDR),
    .cfg_final_norm_gamma_addr(TREE_PARALLEL_FINAL_NORM_GAMMA_ADDR),
    .cfg_do_sample(1'b0),
    .cfg_top_k(7'd1),
    .cfg_top_p(16'h3c00),
    .cfg_tree_mask_en(1'b1),
    .cfg_branch_id({`BRANCH_ID_W{1'b0}}),
    .cfg_prefix_len(16'd0),
    .cfg_visible_mask({`TOY_MAX_POS_EMB{1'b0}}),
    .cfg_position(16'd0),
    .cfg_position_ovr(1'b0),
    .batch_in_valid(tree_parallel_batch_valid_w),
    .batch_in_ready(tree_parallel_batch_ready_w),
    .batch_in_count(tree_parallel_batch_count_w),
    .batch_in_token_ids(tree_parallel_batch_token_ids_w),
    .batch_in_positions(tree_parallel_batch_positions_w),
    .batch_in_tree_mask(tree_parallel_batch_tree_mask_w),
    .batch_in_prefix_len(tree_parallel_batch_prefix_len_w),
    .batch_in_seed_kv_valid(tree_parallel_batch_seed_kv_valid_w),
    .batch_in_slot_is_seed(tree_parallel_batch_slot_is_seed_w),
    .batch_out_valid(tree_parallel_fwd_result_valid_w),
    .batch_out_ready(tree_parallel_fwd_result_ready_w),
    .batch_out_count(tree_parallel_fwd_result_count_w),
    .batch_out_token_ids(tree_parallel_fwd_result_token_ids_w),
    .hbm_rd_valid(tree_parallel_hbm_rd_valid_w),
    .hbm_rd_ready(tree_parallel_hbm_rd_ready_w),
    .hbm_rd_addr(tree_parallel_hbm_rd_addr_w),
    .hbm_resp_valid(hbm_resp_valid),
    .hbm_resp_ready(tree_parallel_hbm_resp_ready_w),
    .hbm_resp_data(hbm_resp_rdata),
    .sram_rd_valid(tree_parallel_sram_rd_valid_w),
    .sram_rd_ready(tree_parallel_sram_rd_ready_w),
    .sram_rd_addr(tree_parallel_sram_rd_addr_w),
    .sram_rd_id(tree_parallel_sram_rd_id_w),
    .sram_resp_valid(tree_parallel_sram_resp_valid_w),
    .sram_resp_ready(tree_parallel_sram_resp_ready_w),
    .sram_resp_data(tree_parallel_sram_resp_data_w),
    .sram_resp_id(tree_parallel_sram_resp_id_w),
    .sram_wr_valid(tree_parallel_sram_wr_valid_w),
    .sram_wr_ready(tree_parallel_sram_wr_ready_w),
    .sram_wr_addr(tree_parallel_sram_wr_addr_w),
    .sram_wr_data(tree_parallel_sram_wr_data_w),
    .vec_sram_rd_valid(tree_parallel_vec_rd_valid_raw_w),
    .vec_sram_rd_ready(tree_parallel_vec_req_ready_w),
    .vec_sram_rd_addr(tree_parallel_vec_rd_addr_raw_w),
    .vec_sram_rd_id(tree_parallel_vec_rd_id_raw_w),
    .vec_sram_rd_pe_mask(tree_parallel_vec_rd_pe_mask_raw_w),
    .vec_sram_resp_valid(tree_parallel_vec_resp_valid_w),
    .vec_sram_resp_ready(tree_parallel_vec_resp_ready_w),
    .vec_sram_resp_data(tree_parallel_vec_resp_rdata_w),
    .vec_sram_resp_id(tree_parallel_vec_resp_req_id_w),
    .vec_sram_wr_valid(tree_parallel_vec_wr_valid_raw_w),
    .vec_sram_wr_ready(tree_parallel_vec_req_ready_w),
    .vec_sram_wr_addr(tree_parallel_vec_wr_addr_raw_w),
    .vec_sram_wr_data(tree_parallel_vec_wr_data_raw_w),
    .vec_sram_wr_id(tree_parallel_vec_wr_id_raw_w),
    .vec_sram_wr_pe_mask(tree_parallel_vec_wr_pe_mask_raw_w),
    .busy(),
    .current_position(tree_parallel_current_position_w),
    .current_layer_debug(tree_parallel_current_layer_debug_w)
);

assign tree_parallel_kv_commit_start_w =
    tree_parallel_mode_w &&
    tree_parallel_commit_valid_w &&
    lifecycle_window_active_r &&
    (tree_parallel_commit_depth_w != 3'd0);
assign tree_parallel_kv_commit_slots_w = tree_parallel_commit_slots_w;
assign tree_parallel_kv_commit_positions_w = tree_parallel_commit_slot_positions_w;

kv_commit_copier u_tree_parallel_kv_commit_copier (
    .clk(clk),
    .rst_n(rst_n),
    .start(tree_parallel_kv_commit_start_w),
    .depth(tree_parallel_commit_depth_w),
    .slot_indices(tree_parallel_kv_commit_slots_w),
    .slot_positions(tree_parallel_kv_commit_positions_w),
    .sram_rd_valid(tree_parallel_kv_commit_sram_rd_valid_w),
    .sram_rd_ready(tree_parallel_kv_commit_sram_rd_ready_w),
    .sram_rd_addr(tree_parallel_kv_commit_sram_rd_addr_w),
    .sram_resp_valid(tree_parallel_kv_commit_resp_select_w ? lane0_resp_valid_w : 1'b0),
    .sram_resp_ready(tree_parallel_kv_commit_resp_ready_w),
    .sram_resp_data(lane0_resp_rdata_w),
    .sram_wr_valid(tree_parallel_kv_commit_sram_wr_valid_w),
    .sram_wr_ready(tree_parallel_kv_commit_sram_wr_ready_w),
    .sram_wr_addr(tree_parallel_kv_commit_sram_wr_addr_w),
    .sram_wr_data(tree_parallel_kv_commit_sram_wr_data_w),
    .done(tree_parallel_kv_commit_done_w),
    .busy(tree_parallel_kv_commit_busy_w)
);

NativeTreeMainFrontend #(
    .CFG_W(CFG_W),
    .SOURCE_ID_W(PRED_SOURCE_ID_W),
    .CONF_W(CONF_W),
    .WINDOW_BRANCH_SLOTS(WINDOW_BRANCH_SLOTS),
    .VISIBLE_MASK_W(`TOY_MAX_POS_EMB)
) u_native_tree_main_frontend (
    .clk(clk),
    .rst_n(rst_n),
    .session_cfg_valid(
        ENABLE_NATIVE_TREE_MAIN_FRONTEND ? cfg_valid : 1'b0),
    .session_cfg_data(cfg_data),
    .session_start(
        ENABLE_NATIVE_TREE_MAIN_FRONTEND ? start : 1'b0),
    .busy(native_tree_main_busy_w),
    .src_req_valid(
        (ENABLE_NATIVE_TREE_MAIN_FRONTEND) ?
            native_tree_req_valid : 1'b0),
    .src_req_ready(native_tree_main_req_ready_w),
    .src_req_id(native_tree_req_id),
    .src_prefix_slot_valid(native_tree_src_prefix_slot_valid),
    .src_prefix_node_id(native_tree_src_prefix_node_id),
    .src_prefix_token_id(native_tree_src_prefix_token_id),
    .src_prefix_position_id(native_tree_src_prefix_position_id),
    .src_committed_len(native_tree_src_committed_len),
    .src_frontier_level_valid(native_tree_src_frontier_level_valid),
    .src_frontier_slot_valid(native_tree_src_frontier_slot_valid),
    .src_frontier_node_id(native_tree_src_frontier_node_id),
    .src_frontier_parent_node_id(native_tree_src_frontier_parent_node_id),
    .src_frontier_token_id(native_tree_src_frontier_token_id),
    .src_frontier_referenced_token_id(
        native_tree_src_frontier_referenced_token_id),
    .src_frontier_position_id(native_tree_src_frontier_position_id),
    .src_frontier_referenced_position_id(
        native_tree_src_frontier_referenced_position_id),
    .src_frontier_branch_id(native_tree_src_frontier_branch_id),
    .src_frontier_level_id(native_tree_src_frontier_level_id),
    .src_frontier_tree_mask_en(native_tree_src_frontier_tree_mask_en),
    .src_visible_mask_by_level(native_tree_visible_mask_by_level_w),
    .tc_cfg_valid(native_tree_main_cfg_valid_w),
    .tc_cfg_data(native_tree_main_cfg_data_w),
    .tc_start(native_tree_main_start_w),
    .tc_busy(tree_parallel_mode_w ? 1'b0 : tree_busy),
    .tc_pred_valid(native_tree_main_pred_valid_w),
    .tc_pred_ready(native_tree_main_pred_ready_w),
    .tc_pred_source_id(native_tree_main_pred_source_id_w),
    .tc_pred_branch_id(native_tree_main_pred_branch_id_w),
    .tc_pred_level_id(native_tree_main_pred_level_id_w),
    .tc_pred_node_id(native_tree_main_pred_node_id_w),
    .tc_pred_parent_node_id(native_tree_main_pred_parent_node_id_w),
    .tc_pred_token_id(native_tree_main_pred_token_id_w),
    .tc_pred_referenced_token_id(
        native_tree_main_pred_referenced_token_id_w),
    .tc_pred_referenced_position(
        native_tree_main_pred_referenced_position_w),
    .tc_pred_issue_position(
        native_tree_main_pred_issue_position_w),
    .tc_pred_confidence(native_tree_main_pred_confidence_w),
    .tc_pred_is_last_in_window(
        native_tree_main_pred_is_last_in_window_w),
    .tc_pred_tree_mask_en(native_tree_main_pred_tree_mask_en_w),
    .tc_pred_prefix_len(native_tree_main_pred_prefix_len_w),
    .tc_pred_visible_mask(native_tree_main_pred_visible_mask_w),
    .debug_req_fire(native_tree_main_req_fire_w),
    .debug_frontier_capture_fire(
        native_tree_main_frontier_capture_fire_w),
    .debug_pred_fire(native_tree_main_pred_fire_w)
);

PredictionWindowSerialDispatcher #(
    .CFG_W(CFG_W),
    .WINDOW_BRANCH_SLOTS(WINDOW_BRANCH_SLOTS),
    .SOURCE_ID_W(PRED_SOURCE_ID_W),
    .CONF_W(CONF_W)
) u_prediction_window_serial_dispatcher (
    .clk(clk),
    .rst_n(rst_n),
    .session_cfg_valid(
        ENABLE_NATIVE_TREE_MAIN_FRONTEND ? 1'b0 : cfg_valid),
    .session_cfg_data(cfg_data),
    .session_start(
        ENABLE_NATIVE_TREE_MAIN_FRONTEND ? 1'b0 : start),
    .busy(dispatch_busy),
    .src_pred_valid(pred_src_valid),
    .src_pred_ready(dispatch_src_pred_ready),
    .src_pred_source_id(pred_src_source_id),
    .src_pred_parent_node_id(pred_src_parent_node_id),
    .src_pred_token_id(pred_src_token_id),
    .src_pred_referenced_token_id(pred_src_referenced_token_id),
    .src_pred_referenced_position(pred_src_referenced_position),
    .src_pred_confidence(pred_src_confidence),
    .src_pred_is_last_in_window(pred_src_is_last_in_window),
    .src_tree_window_valid(tree_window_src_valid),
    .src_tree_window_ready(dispatch_src_tree_window_ready),
    .src_tree_window_parent_node_id(tree_window_src_parent_node_id),
    .src_tree_window_slot_valid(tree_window_src_slot_valid),
    .src_tree_window_source_id(tree_window_src_source_id),
    .src_tree_window_token_id(tree_window_src_token_id),
    .src_tree_window_referenced_token_id(
        tree_window_src_referenced_token_id),
    .src_tree_window_referenced_position(
        tree_window_src_referenced_position),
    .src_tree_window_confidence(tree_window_src_confidence),
    .tc_cfg_valid(dispatch_cfg_valid),
    .tc_cfg_data(dispatch_cfg_data),
    .tc_start(dispatch_start),
    .tc_busy(tree_busy),
    .tc_pred_valid(dispatch_pred_valid),
    .tc_pred_ready(pred_ready),
    .tc_pred_source_id(dispatch_pred_source_id),
    .tc_pred_parent_node_id(dispatch_pred_parent_node_id),
    .tc_pred_token_id(dispatch_pred_token_id),
    .tc_pred_referenced_token_id(dispatch_pred_referenced_token_id),
    .tc_pred_referenced_position(dispatch_pred_referenced_position),
    .tc_pred_issue_position(dispatch_pred_issue_position),
    .tc_pred_confidence(dispatch_pred_confidence),
    .tc_pred_is_last_in_window(dispatch_pred_is_last_in_window),
    .tc_pred_slot_idx(dispatch_pred_slot_idx),
    .tc_pred_tree_mask_en(dispatch_pred_tree_mask_en),
    .tc_pred_prefix_len(dispatch_pred_prefix_len)
);

IntegrationTreeControlPart #(
    .CFG_W(CFG_W),
    .MODEL_ID_W(MODEL_ID_W),
    .OP_CLASS_W(OP_CLASS_W),
    .TOKEN_LEN_W(TOKEN_LEN_W),
    .CONF_W(CONF_W),
    .PRED_SOURCE_ID_W(PRED_SOURCE_ID_W),
    .ENABLE_PREDICTION_INPUT(1),
    .ENABLE_RECOMPUTE_PATH(1),
    .CURRENT_POSITION(CURRENT_POSITION),
    .RECENCY_TH(RECENCY_TH),
    .ISSUE_SRC_ADDR(ISSUE_SRC_ADDR),
    .ISSUE_DST_ADDR(ISSUE_DST_ADDR)
) u_integration_tree_control_part (
    .clk(clk),
    .rst_n(rst_n),
    .cfg_valid(tree_cfg_valid_w),
    .cfg_data(tree_cfg_data_w),
    .start(tree_start_w),
    .busy(tree_busy),
    .error_flag(tree_error_flag),
    .pred_valid(pred_valid),
    .pred_ready(pred_ready),
    .pred_source_id(pred_source_id),
    .pred_parent_node_id(pred_parent_node_id),
    .pred_token_id(pred_token_id),
    .pred_referenced_token_id(pred_referenced_token_id),
    .pred_referenced_position(pred_referenced_position),
    .pred_issue_position(
        ENABLE_NATIVE_TREE_MAIN_FRONTEND ?
            native_tree_main_pred_issue_position_w :
        (ENABLE_TREE_WINDOW_CONSUMER ?
            dispatch_pred_issue_position :
            pred_referenced_position)),
    .pred_confidence(pred_confidence),
    .pred_is_last_in_window(pred_is_last_in_window),
    .pred_branch_id(pred_branch_id_w),
    .pred_tree_mask_en(pred_tree_mask_en_w),
    .pred_prefix_len(pred_prefix_len_w),
    .pred_visible_mask(pred_visible_mask_w),
    .issue_valid(tc_issue_valid),
    .issue_ready(tc_issue_ready),
    .issue_token_id(tc_issue_token_id),
    .issue_branch_id(tc_issue_branch_id),
    .issue_epoch(tc_issue_epoch),
    .issue_model_id(tc_issue_model_id),
    .issue_op_class(tc_issue_op_class),
    .issue_src_addr(tc_issue_src_addr),
    .issue_dst_addr(tc_issue_dst_addr),
    .issue_token_len(tc_issue_token_len),
    .issue_req_id(tc_issue_req_id),
    .issue_flush_epoch(tc_issue_flush_epoch),
    .issue_parent_node_id(tc_issue_parent_node_id),
    .issue_confidence(tc_issue_confidence),
    .issue_tree_mask_en(tc_issue_tree_mask_en),
    .issue_tree_mask_branch_id(tc_issue_tree_mask_branch_id),
    .issue_prefix_len(tc_issue_prefix_len),
    .issue_visible_mask(tc_issue_visible_mask),
    .issue_position(tc_issue_position),
    .issue_position_ovr(tc_issue_position_ovr),
    .prep_req_valid(prep_req_valid),
    .prep_req_ready(prep_req_ready),
    .prep_req_write(prep_req_write),
    .prep_req_addr(prep_req_addr),
    .prep_req_wdata(prep_req_wdata),
    .prep_req_id(prep_req_id),
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
    .debug_stale_hit(debug_stale_hit),
    .debug_recompute_busy(debug_recompute_busy),
    .debug_recompute_done(debug_recompute_done),
    .wb_done(wb_done),
    .wb_error(wb_error),
    .wb_token_id(wb_token_id)
);

assign tc_issue_ready = issue_ready;
assign issue_valid = tc_issue_valid;
assign issue_token_id = tc_issue_token_id;
assign issue_branch_id = tc_issue_branch_id;
assign issue_epoch = tc_issue_epoch;
assign issue_model_id = tc_issue_model_id;
assign issue_op_class = tc_issue_op_class;
assign issue_src_addr = tc_issue_src_addr;
assign issue_dst_addr = tc_issue_dst_addr;
assign issue_token_len = tc_issue_token_len;
assign issue_req_id = tc_issue_req_id;
assign issue_flush_epoch = tc_issue_flush_epoch;
assign issue_parent_node_id = tc_issue_parent_node_id;
assign issue_confidence = tc_issue_confidence;
assign issue_tree_mask_en = tc_issue_tree_mask_en;
assign issue_tree_mask_branch_id = tc_issue_tree_mask_branch_id;
assign issue_prefix_len = tc_issue_prefix_len;
assign issue_visible_mask = tc_issue_visible_mask;
assign issue_position = tc_issue_position;
assign issue_position_ovr = tc_issue_position_ovr;
IntegrationOperatorPart #(
    .MODEL_ID_W(MODEL_ID_W),
    .OP_CLASS_W(OP_CLASS_W),
    .TOKEN_LEN_W(TOKEN_LEN_W),
    .RESULT_STATUS_W(RESULT_STATUS_W),
    .CONF_W(CONF_W),
    .ENABLE_DECODER_CHAIN(ENABLE_DECODER_CHAIN),
    .DECODER_DATA_WIDTH(DECODER_DATA_WIDTH),
    .DECODER_VECTOR_DIM(DECODER_VECTOR_DIM),
    .USE_FP16_GEMM(USE_FP16_GEMM),
    .USE_FP16_INFERENCE_TOP(USE_FP16_INFERENCE_TOP)
) u_integration_operator_part (
    .clk(clk),
    .rst_n(rst_n),
    .issue_valid(issue_valid),
    .issue_ready(issue_ready),
    .issue_token_id(issue_token_id),
    .issue_branch_id(issue_branch_id),
    .issue_epoch(issue_epoch),
    .issue_model_id(issue_model_id),
    .issue_op_class(issue_op_class),
    .issue_src_addr(issue_src_addr),
    .issue_dst_addr(issue_dst_addr),
    .issue_token_len(issue_token_len),
    .issue_req_id(issue_req_id),
    .issue_flush_epoch(issue_flush_epoch),
    .issue_tree_mask_en(issue_tree_mask_en),
    .issue_tree_mask_branch_id(issue_tree_mask_branch_id),
    .issue_prefix_len(issue_prefix_len),
    .issue_visible_mask(issue_visible_mask),
    .issue_position(issue_position),
    .issue_position_ovr(issue_position_ovr),
    .op_req_valid(op_req_valid),
    .op_req_ready(op_req_ready),
    .op_req_write(op_req_write),
    .op_req_addr(op_req_addr),
    .op_req_wdata(op_req_wdata),
    .op_req_id(op_req_id),
    .op_req_last(op_req_last),
    .op_req_tag(op_req_tag),
    .op_resp_valid(op_resp_valid),
    .op_resp_ready(op_resp_ready),
    .op_resp_rdata(op_resp_rdata),
    .op_resp_id(op_resp_id),
    .op_resp_last(op_resp_last),
    .hbm_resp_valid(hbm_resp_valid),
    .hbm_resp_rdata(hbm_resp_rdata),
    .hbm_resp_id(hbm_resp_id),
    .hbm_req_valid(operator_hbm_req_valid_w),
    .hbm_req_write(operator_hbm_req_write_w),
    .hbm_req_addr(operator_hbm_req_addr_w),
    .hbm_req_wdata(operator_hbm_req_wdata_w),
    .hbm_req_id(operator_hbm_req_id_w),
    .result_valid(operator_raw_result_valid_w),
    .result_ready(operator_raw_result_ready_w),
    .result_token_id(operator_raw_result_token_id_w),
    .result_addr(operator_raw_result_addr_w),
    .result_data(operator_raw_result_data_w),
    .result_status(operator_raw_result_status_w),
    .debug_decoder_qkv_valid(debug_decoder_qkv_valid),
    .debug_decoder_score_valid(debug_decoder_score_valid),
    .debug_decoder_softmax_valid(debug_decoder_softmax_valid),
    .debug_decoder_value_valid(debug_decoder_value_valid),
    .debug_decoder_ffn_valid(debug_decoder_ffn_valid)
);

IntegrationWritebackPart #(
    .RESULT_STATUS_W(RESULT_STATUS_W)
) u_integration_writeback_part (
    .clk(clk),
    .rst_n(rst_n),
    .result_valid(operator_result_valid_w),
    .result_ready(writeback_result_ready_w),
    .result_token_id(operator_result_token_id_w),
    .result_addr(operator_result_addr_w),
    .result_data(operator_result_data_w),
    .result_status(operator_result_status_w),
    .wb_valid(wb_valid),
    .wb_ready(wb_ready),
    .wb_token_id(wb_token_id),
    .wb_addr(wb_addr),
    .wb_data(wb_data),
    .wb_status(wb_status),
    .wb_done(wb_done),
    .wb_error(wb_error)
);

Stage2TopWritebackHbmShim u_stage2_top_writeback_hbm_shim (
    .enable(ENABLE_TOP_HBM_WRITEBACK_SHIM),
    .wb_valid(wb_valid),
    .wb_ready(wb_ready),
    .wb_token_id(wb_token_id),
    .wb_addr(wb_addr),
    .wb_data(wb_data),
    .hbm_req_valid(wb_hbm_req_valid_w),
    .hbm_req_write(wb_hbm_req_write_w),
    .hbm_req_addr(wb_hbm_req_addr_w),
    .hbm_req_wdata(wb_hbm_req_wdata_w),
    .hbm_req_id(wb_hbm_req_id_w)
);

request_controller u_request_controller (
    .clk(clk),
    .rst_n(rst_n),
    .req_in_valid(rc_req_valid),
    .req_in_ready(rc_req_ready),
    .req_in_write(rc_req_write),
    .req_in_addr(rc_req_addr),
    .req_in_wdata(rc_req_wdata),
    .req_in_req_id(rc_req_id),
    .req_in_pe_mask(rc_req_pe_mask),
    .req_in_priority(rc_req_priority),
    .req_in_bank_id(rc_req_bank_id),
    .req_in_subbank_id(rc_req_subbank_id),
    .vec_req_valid(tree_parallel_vec_req_valid_w),
    .vec_req_ready(tree_parallel_vec_req_ready_w),
    .vec_req_write(tree_parallel_vec_req_write_w),
    .vec_req_addr(tree_parallel_vec_req_addr_w),
    .vec_req_wdata(tree_parallel_vec_req_wdata_w),
    .vec_req_req_id(tree_parallel_vec_req_req_id_w),
    .vec_req_pe_mask(tree_parallel_vec_req_pe_mask_w),
    .vec_req_priority(tree_parallel_vec_req_priority_w),
    .vec_req_bank_id(tree_parallel_vec_req_bank_id_w),
    .vec_req_subbank_id(tree_parallel_vec_req_subbank_id_w),
    .mem_req_valid(mem_req_valid),
    .mem_req_ready(mem_req_ready),
    .mem_req_write(mem_req_write),
    .mem_req_addr(mem_req_addr),
    .mem_req_wdata(mem_req_wdata),
    .mem_req_id(mem_req_id),
    .mem_resp_valid(mem_resp_valid),
    .mem_resp_rdata(mem_resp_rdata),
    .mem_resp_id(mem_resp_id),
    .mem_resp_last(mem_resp_last),
    .resp_out_valid(pe_resp_valid),
    .resp_out_ready(pe_resp_ready),
    .resp_out_rdata(pe_resp_rdata),
    .resp_out_req_id(pe_resp_req_id),
    .resp_out_pe_mask(pe_resp_pe_mask),
    .resp_out_last(pe_resp_last)
);

multicast_network u_multicast_network (
    .resp_in_valid(pe_resp_valid),
    .resp_in_ready(mc_resp_in_ready_w),
    .resp_in_rdata(pe_resp_rdata),
    .resp_in_req_id(pe_resp_req_id),
    .resp_in_pe_mask(pe_resp_pe_mask),
    .resp_in_last(pe_resp_last),
    .pe_valid(mc_pe_valid_w),
    .pe_ready(mc_pe_ready_w),
    .pe_rdata(mc_pe_rdata_w),
    .pe_req_id(mc_pe_req_id_w),
    .pe_mask(mc_pe_mask_w),
    .pe_last(mc_pe_last_w)
);

sram_subsystem u_sram_subsystem (
    .clk(clk),
    .rst_n(rst_n),
    .mem_req_valid(mem_req_valid),
    .mem_req_ready(mem_req_ready),
    .mem_req_write(mem_req_write),
    .mem_req_addr(mem_req_addr),
    .mem_req_wdata(mem_req_wdata),
    .mem_req_id(mem_req_id),
    .mem_resp_valid(mem_resp_valid),
    .mem_resp_rdata(mem_resp_rdata),
    .mem_resp_id(mem_resp_id),
    .mem_resp_last(mem_resp_last)
);

endmodule
