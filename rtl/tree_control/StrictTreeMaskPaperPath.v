`timescale 1ns/1ps

`include "config/prediction_params.vh"
`include "config/interface_params.vh"
`include "config/memory_params.vh"
`include "config/model_params.vh"
`include "tree_control/tree_analyze.v"
`include "tree_control/agu.v"
`include "tree_control/prefetch_queue.v"
`include "tree_control/free_list.v"
`include "tree_control/bank_state_table.v"
`include "tree_control/token_register.v"
`include "tree_control/comparator.v"
`include "tree_control/StrictTreeMaskPaperIssueScheduler.v"

/*
 * 文件作用：
 * 1. 这个文件是 strict tree-mask 论文主路径的顶层容器边界。
 * 2. 当前阶段它已经把论文前半段里：
 *      tree_analyze -> prefix/frontier bundle 打包 -> AGU
 *      -> prefetch_queue -> free_list
 *    这一整段 ownership 收进容器内部。
 * 3. 容器对外只继续暴露：
 *    - free_list -> bank_state_table 的 alloc candidate bundle
 *    - free_list -> bank_state_table 的 flush reclaim 事件
 *    - AGU -> token_register 的 token write / token flush 边界
 *    - comparator -> AGU 的 flush/liveness 控制边界
 * 4. 这样 stage2 顶层已经不再拥有 AGU / prefetch_queue / free_list，只保留更后段
 *    的 bank_state_table / token_register / comparator 等模块。
 */
module StrictTreeMaskPaperPath #(
    parameter integer PRIVATE_DEPTH_W =
        (((`MAX_VERIFY_NODES_PER_BRANCH + 1) <= 2) ? 1 :
         $clog2(`MAX_VERIFY_NODES_PER_BRANCH + 1))
) (
    input                             clk,
    input                             rst_n,

    // native_tree_req 原始树输入。
    input                             req_valid,
    output                            req_ready,
    input      [`REQ_ID_W-1:0]        req_id,
    input      [`TREE_MAX_PREFIX_NODES-1:0] src_prefix_slot_valid,
    input      [`TREE_MAX_PREFIX_NODES*`NODE_ID_W-1:0]
               src_prefix_node_id,
    input      [`TREE_MAX_PREFIX_NODES*`TOKEN_ID_W-1:0]
               src_prefix_token_id,
    input      [`TREE_MAX_PREFIX_NODES*`POSITION_ID_W-1:0]
               src_prefix_position_id,
    input      [`POSITION_ID_W-1:0]   src_committed_len,
    input      [`TREE_MAX_FRONTIER_LEVELS-1:0]
               src_frontier_level_valid,
    input      [`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS-1:0]
               src_frontier_slot_valid,
    input      [`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0]
               src_frontier_node_id,
    input      [`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0]
               src_frontier_parent_node_id,
    input      [`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`TOKEN_ID_W-1:0]
               src_frontier_token_id,
    input      [`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`TOKEN_ID_W-1:0]
               src_frontier_referenced_token_id,
    input      [`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`POSITION_ID_W-1:0]
               src_frontier_position_id,
    input      [`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`POSITION_ID_W-1:0]
               src_frontier_referenced_position_id,
    input      [`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`BRANCH_ID_W-1:0]
               src_frontier_branch_id,
    input      [`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`TREE_LEVEL_ID_W-1:0]
               src_frontier_level_id,
    input      [`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS-1:0]
               src_frontier_tree_mask_en,
    input      [`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`MODEL_MAX_POS_EMB-1:0]
               visible_mask_by_level,

    // comparator -> AGU 的控制边界。
    input                             flush_freeze,
    input                             flush_ctrl_valid,
    input      [`REQ_ID_W-1:0]        flush_ctrl_req_id,
    input      [`BRANCH_MASK_W-1:0]   flush_ctrl_branch_mask,
    input      [`NODE_MASK_W-1:0]     flush_ctrl_node_mask,
    input                             branch_liveness_valid,
    input      [`REQ_ID_W-1:0]        branch_liveness_req_id,
    input      [`BRANCH_MASK_W-1:0]   branch_liveness_live_mask,
    input      [`BRANCH_MASK_W-1:0]   branch_liveness_prune_mask,
    input                             reduce_start_valid,
    input      [`REQ_ID_W-1:0]        cmp_req_id,
    input      [`BRANCH_NUM-1:0]      cmp_slot_valid,
    input      [`BRANCH_NUM*`TOKEN_ID_W-1:0] cmp_slot_real_token_id,
    input      [`BRANCH_NUM*`TOKEN_ID_W-1:0] cmp_slot_candidate_token_id,
    input      [`BRANCH_NUM*`NODE_ID_W-1:0] cmp_slot_node_id,
    input      [`BRANCH_NUM*`NODE_ID_W-1:0] cmp_slot_parent_node_id,
    input      [`BRANCH_NUM*`BRANCH_ID_W-1:0] cmp_slot_branch_id,
    input      [`REQ_ID_W-1:0]        reduce_req_id,
    input      [(`BRANCH_NUM*2)-1:0]  active_branch_epoch,
    input      [`BRANCH_NUM-1:0]      active_branch_valid,
    input      [`BRANCH_NUM*(((`MAX_VERIFY_NODES_PER_BRANCH + 1) <= 2) ? 1 :
                               $clog2(`MAX_VERIFY_NODES_PER_BRANCH + 1))-1:0]
               active_branch_depth,
    input      [(`BRANCH_NUM*`MAX_VERIFY_NODES_PER_BRANCH*`NODE_ID_W)-1:0]
               active_branch_node_id,
    input      [(`BRANCH_NUM*`MAX_VERIFY_NODES_PER_BRANCH*`NODE_ID_W)-1:0]
               active_branch_parent_node_id,
    input      [`BRANCH_NUM-1:0]      result_slot_valid,
    input      [`REQ_ID_W-1:0]        result_req_id,
    input      [`BRANCH_NUM*`BRANCH_ID_W-1:0] result_branch_id,
    input      [(`BRANCH_NUM*2)-1:0]  result_branch_epoch,
    input      [`BRANCH_NUM*(((`MAX_VERIFY_NODES_PER_BRANCH + 1) <= 2) ? 1 :
                               $clog2(`MAX_VERIFY_NODES_PER_BRANCH + 1))-1:0]
               result_private_depth,
    input      [`BRANCH_NUM*`NODE_ID_W-1:0] result_node_id,
    input      [`BRANCH_NUM*`NODE_ID_W-1:0] result_parent_node_id,
    input      [`BRANCH_NUM-1:0]      result_accept,
    output                            cmp_commit_valid,
    output     [`BRANCH_MASK_W-1:0]   cmp_commit_branch_mask,
    output     [`NODE_MASK_W-1:0]     cmp_commit_node_mask,
    output                            cmp_flush_valid,
    output     [`BRANCH_MASK_W-1:0]   cmp_flush_branch_mask,
    output     [`NODE_MASK_W-1:0]     cmp_flush_node_mask,
    output                            cmp_accepted_prefix_valid,
    output     [`REQ_ID_W-1:0]        cmp_accepted_prefix_req_id,
    output     [`BRANCH_ID_W-1:0]     cmp_accepted_prefix_branch_id,
    output     [(((`MAX_VERIFY_NODES_PER_BRANCH + 1) <= 2) ? 1 :
                 $clog2(`MAX_VERIFY_NODES_PER_BRANCH + 1))-1:0]
               cmp_accepted_prefix_depth,
    output     [(`MAX_VERIFY_NODES_PER_BRANCH*`NODE_ID_W)-1:0]
               cmp_accepted_prefix_node_id,
    output     [`BRANCH_NUM-1:0]      cmp_live_branch_mask,
    output     [`BRANCH_NUM-1:0]      cmp_prune_branch_mask,
    // comparator/commit -> bank_state_table 的提交边界。
    input                             bank_commit_valid,
    input      [`REQ_ID_W-1:0]        bank_commit_req_id,
    input      [`SRAM_ID_W-1:0]       bank_commit_sram_id,
    input      [`BANK_ID_W-1:0]       bank_commit_bank_id,
    input      [`SUBBANK_ID_W-1:0]    bank_commit_subbank_start,
    input      [`KV_GROUP_LEN_W-1:0]  bank_commit_group_len,
    input      [`BRANCH_MASK_W-1:0]   bank_commit_branch_mask,
    input      [`NODE_MASK_W-1:0]     bank_commit_node_mask,

    // free_list -> bank_state_table。
    output                            alloc_cand_bundle_valid,
    output     [`REQ_ID_W-1:0]        alloc_cand_bundle_req_id,
    output     [`TREE_FRONTIER_SLOTS-1:0] alloc_cand_bundle_slot_valid,
    output     [`TREE_FRONTIER_SLOTS*`BRANCH_ID_W-1:0]
               alloc_cand_bundle_branch_id,
    output     [`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0]
               alloc_cand_bundle_node_id,
    output     [`TREE_FRONTIER_SLOTS*`KV_GROUP_LEN_W-1:0]
               alloc_cand_bundle_size_subbank,
    output     [`TREE_FRONTIER_SLOTS-1:0] alloc_cand_bundle_shared,
    output     [`TREE_FRONTIER_SLOTS*`SRAM_ID_W-1:0]
               alloc_cand_bundle_sram_id,
    output     [`TREE_FRONTIER_SLOTS*`BANK_ID_W-1:0]
               alloc_cand_bundle_bank_id,
    output     [`TREE_FRONTIER_SLOTS*`SUBBANK_ID_W-1:0]
               alloc_cand_bundle_subbank_start,
    output     [`TREE_FRONTIER_SLOTS*`KV_GROUP_LEN_W-1:0]
               alloc_cand_bundle_group_len,

    // free_list -> bank_state_table reclaim 事件。
    output                            flush_reclaim_valid,
    output     [`SRAM_ID_W-1:0]       flush_reclaim_sram_id,
    output     [`BANK_ID_W-1:0]       flush_reclaim_bank_id,
    output     [`SUBBANK_ID_W-1:0]    flush_reclaim_subbank_start,
    output     [`KV_GROUP_LEN_W-1:0]  flush_reclaim_group_len,
    output                            flush_drain_busy,

    // AGU -> token_register。
    output                            token_wr_valid,
    output     [`REQ_ID_W-1:0]        token_wr_req_id,
    output     [`TOKEN_ID_W-1:0]      token_wr_token_id,
    output     [`POSITION_ID_W-1:0]   token_wr_position_id,
    output     [`NODE_ID_W-1:0]       token_wr_node_id,
    output     [`BRANCH_ID_W-1:0]     token_wr_branch_id,
    output     [`BRANCH_MASK_W-1:0]   token_wr_branch_mask,
    output                            token_wr_is_shared,
    output     [`SRAM_ID_W-1:0]       token_wr_sram_id,
    output     [`BANK_ID_W-1:0]       token_wr_bank_id,
    output     [`SUBBANK_ID_W-1:0]    token_wr_subbank_start,
    output     [`KV_GROUP_LEN_W-1:0]  token_wr_group_len,
    output     [`TOKEN_REG_INDEX_W-1:0] token_wr_index,
    input                             token_lookup_valid,
    input      [`TOKEN_ID_W-1:0]      token_lookup_token_id,
    input      [`POSITION_ID_W-1:0]   token_lookup_position_id,
    output                            token_lookup_ready,
    output                            token_lookup_hit,
    output     [`SRAM_ID_W-1:0]       token_lookup_sram_id,
    output     [`BANK_ID_W-1:0]       token_lookup_bank_id,
    output     [`SUBBANK_ID_W-1:0]    token_lookup_subbank_start,
    output     [`KV_GROUP_LEN_W-1:0]  token_lookup_group_len,
    output     [`BRANCH_MASK_W-1:0]   token_lookup_branch_mask,
    output                            token_lookup_is_shared,
    output     [`TOKEN_ENTRY_TYPE_W-1:0] token_lookup_entry_type,
    output     [`TOKEN_STATE_W-1:0]   token_lookup_entry_state,
    // token_register -> issue bundle：
    // 这是论文 strict 主路径里 metadata/compute 后半段的正式输入边界。
    input                             paper_issue_bundle_ready,
    output                            paper_issue_bundle_valid,
    output     [`REQ_ID_W-1:0]        paper_issue_bundle_req_id,
    output     [`TREE_FRONTIER_SLOTS-1:0] paper_issue_bundle_slot_valid,
    output     [`TREE_FRONTIER_SLOTS-1:0] paper_issue_bundle_slot_lookup_hit,
    output     [`TREE_FRONTIER_SLOTS*`TOKEN_ID_W-1:0]
               paper_issue_bundle_token_id,
    output     [`TREE_FRONTIER_SLOTS*`POSITION_ID_W-1:0]
               paper_issue_bundle_position_id,
    output     [`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0]
               paper_issue_bundle_node_id,
    output     [`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0]
               paper_issue_bundle_parent_node_id,
    output     [`TREE_FRONTIER_SLOTS*`BRANCH_ID_W-1:0]
               paper_issue_bundle_branch_id,
    output     [`TREE_LEVEL_ID_W-1:0] paper_issue_bundle_level_id,
    output     [4:0]                 paper_issue_bundle_slot_count,
    output     [15:0]                paper_issue_bundle_prefix_len,
    output     [`TREE_FRONTIER_SLOTS-1:0] paper_issue_bundle_slot_tree_mask_en,
    output     [`TREE_FRONTIER_SLOTS*`MODEL_MAX_POS_EMB-1:0]
               paper_issue_bundle_slot_visible_mask,
    output     [`TREE_FRONTIER_SLOTS*PRIVATE_DEPTH_W-1:0]
               paper_issue_bundle_private_depth,
    output     [`TREE_FRONTIER_SLOTS*`SRAM_ID_W-1:0]
               paper_issue_bundle_sram_id,
    output     [`TREE_FRONTIER_SLOTS*`BANK_ID_W-1:0]
               paper_issue_bundle_bank_id,
    output     [`TREE_FRONTIER_SLOTS*`SUBBANK_ID_W-1:0]
               paper_issue_bundle_subbank_start,
    output     [`TREE_FRONTIER_SLOTS*`KV_GROUP_LEN_W-1:0]
               paper_issue_bundle_group_len,
    output     [`TREE_FRONTIER_SLOTS*`BRANCH_MASK_W-1:0]
               paper_issue_bundle_branch_mask,
    output     [`TREE_FRONTIER_SLOTS-1:0] paper_issue_bundle_is_shared,
    output     [`TREE_FRONTIER_SLOTS*`TOKEN_STATE_W-1:0]
               paper_issue_bundle_entry_state,
    output     [`TREE_FRONTIER_SLOTS*`TOKEN_ENTRY_TYPE_W-1:0]
               paper_issue_bundle_entry_type,
    output     [`SRAM_ADDR_W-1:0]     paper_issue_bundle_embedding_base_addr,
    output     [`SRAM_ADDR_W-1:0]     paper_issue_bundle_hidden0_base_addr,
    output     [`SRAM_ADDR_W-1:0]     paper_issue_bundle_hidden1_base_addr,
    output     [`SRAM_ADDR_W-1:0]     paper_issue_bundle_final_base_addr,
    output     [`SRAM_ADDR_W-1:0]     paper_issue_bundle_weight_sram_base_addr,
    output     [`SRAM_ADDR_W-1:0]     paper_issue_bundle_kv_cache_base_addr,
    output     [`SRAM_ADDR_W-1:0]     paper_issue_bundle_draft_kv_base_addr,
    output     [`HBM_ADDR_W-1:0]      paper_issue_bundle_hbm_weight_base_addr,
    output     [`SRAM_ADDR_W-1:0]     paper_issue_bundle_final_norm_gamma_addr,
    output     [`SRAM_ADDR_W-1:0]     paper_issue_bundle_lm_head_weight_base_addr,
    input                             token_commit_valid,
    input      [`TOKEN_REG_INDEX_W-1:0] token_commit_index,
    input      [`REQ_ID_W-1:0]        token_commit_req_id,
    input      [`BRANCH_MASK_W-1:0]   token_commit_branch_mask,
    input      [`NODE_MASK_W-1:0]     token_commit_node_mask,
    output     [`TOKEN_REG_INDEX_W:0] token_entry_count,
    output                            token_error_flag
);

localparam integer BRANCH_EPOCH_W = 2;
localparam integer PATH_PACK_W =
    (`BRANCH_NUM * `MAX_VERIFY_NODES_PER_BRANCH * `NODE_ID_W);
localparam integer DEPTH_PACK_W =
    (`BRANCH_NUM * PRIVATE_DEPTH_W);
localparam integer EPOCH_PACK_W =
    (`BRANCH_NUM * BRANCH_EPOCH_W);

integer visible_slot_i;
integer token_wr_bundle_slot_i;

// tree_analyze 输出的前端论文语义流。
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
wire [15:0] prefix_count;
wire frontier_valid;
wire frontier_ready;
wire [`REQ_ID_W-1:0] frontier_req_id;
wire [`TREE_LEVEL_ID_W-1:0] frontier_level_id;
wire [`TREE_FRONTIER_SLOTS-1:0] frontier_slot_valid;
wire [`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0] frontier_node_id;
wire [`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0] frontier_parent_node_id;
wire [`TREE_FRONTIER_SLOTS*`TOKEN_ID_W-1:0] frontier_token_id;
wire [`TREE_FRONTIER_SLOTS*`TOKEN_ID_W-1:0] frontier_referenced_token_id;
wire [`TREE_FRONTIER_SLOTS*`POSITION_ID_W-1:0] frontier_position_id;
wire [`TREE_FRONTIER_SLOTS*`POSITION_ID_W-1:0]
     frontier_referenced_position_id;
wire [`TREE_FRONTIER_SLOTS*`BRANCH_ID_W-1:0] frontier_branch_id;
wire [15:0] frontier_level_slot_count;
wire [`TREE_FRONTIER_SLOTS-1:0] frontier_tree_mask_en;

// prefix/frontier -> AGU 的统一 bundle 边界。
wire agu_bundle_valid_w;
wire agu_bundle_ready_w;
wire [`REQ_ID_W-1:0] agu_bundle_req_id_w;
wire [`TREE_LEVEL_ID_W-1:0] agu_bundle_level_id_w;
wire [`TREE_FRONTIER_SLOTS-1:0] agu_bundle_slot_valid_w;
wire [`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0] agu_bundle_node_id_w;
wire [`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0] agu_bundle_parent_node_id_w;
wire [`TREE_FRONTIER_SLOTS*`TOKEN_ID_W-1:0] agu_bundle_token_id_w;
wire [`TREE_FRONTIER_SLOTS*`POSITION_ID_W-1:0] agu_bundle_position_id_w;
wire [`TREE_FRONTIER_SLOTS*`BRANCH_ID_W-1:0] agu_bundle_branch_id_w;
wire [`TREE_FRONTIER_SLOTS-1:0] agu_bundle_slot_shared_w;
wire [4:0] agu_bundle_slot_count_w;
wire [15:0] agu_bundle_prefix_len_w;
wire [`TREE_FRONTIER_SLOTS-1:0] agu_bundle_slot_tree_mask_en_w;
wire [`TREE_FRONTIER_SLOTS*`MODEL_MAX_POS_EMB-1:0]
     agu_bundle_slot_visible_mask_w;
reg agu_bundle_valid_comb;
reg [`REQ_ID_W-1:0] agu_bundle_req_id_comb;
reg [`TREE_LEVEL_ID_W-1:0] agu_bundle_level_id_comb;
reg [`TREE_FRONTIER_SLOTS-1:0] agu_bundle_slot_valid_comb;
reg [`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0] agu_bundle_node_id_comb;
reg [`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0] agu_bundle_parent_node_id_comb;
reg [`TREE_FRONTIER_SLOTS*`TOKEN_ID_W-1:0] agu_bundle_token_id_comb;
reg [`TREE_FRONTIER_SLOTS*`POSITION_ID_W-1:0] agu_bundle_position_id_comb;
reg [`TREE_FRONTIER_SLOTS*`BRANCH_ID_W-1:0] agu_bundle_branch_id_comb;
reg [`TREE_FRONTIER_SLOTS-1:0] agu_bundle_slot_shared_comb;
reg [4:0] agu_bundle_slot_count_comb;
reg [15:0] agu_bundle_prefix_len_comb;
reg [`TREE_FRONTIER_SLOTS-1:0] agu_bundle_slot_tree_mask_en_comb;
reg [`TREE_FRONTIER_SLOTS*`MODEL_MAX_POS_EMB-1:0]
    agu_bundle_slot_visible_mask_comb;

// AGU -> prefetch_queue 内部边界。
wire prefetch_bundle_valid;
wire [`REQ_ID_W-1:0] prefetch_bundle_req_id;
wire [`LAYER_ID_W-1:0] prefetch_bundle_layer_id;
wire [`TREE_FRONTIER_SLOTS-1:0] prefetch_bundle_slot_valid;
wire [`TREE_FRONTIER_SLOTS*`BRANCH_ID_W-1:0] prefetch_bundle_branch_id;
wire [`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0] prefetch_bundle_node_id;
wire [`TREE_FRONTIER_SLOTS*`KV_GROUP_LEN_W-1:0] prefetch_bundle_size_subbank;
wire [`TREE_FRONTIER_SLOTS-1:0] prefetch_bundle_shared;
wire prefetch_bundle_ready_w;
wire prefetch_flush_valid_w;
wire [`REQ_ID_W-1:0] prefetch_flush_req_id_w;
wire [`BRANCH_MASK_W-1:0] prefetch_flush_branch_mask_w;
wire [`NODE_MASK_W-1:0] prefetch_flush_node_mask_w;

// prefetch_queue -> free_list 的 bundle 出队边界。
wire queue_bundle_deq_valid_w;
wire queue_bundle_deq_ready_w;
wire [`REQ_ID_W-1:0] queue_bundle_deq_req_id_w;
wire [`LAYER_ID_W-1:0] queue_bundle_deq_layer_id_w;
wire [`TREE_FRONTIER_SLOTS-1:0] queue_bundle_deq_slot_valid_w;
wire [`TREE_FRONTIER_SLOTS*`BRANCH_ID_W-1:0] queue_bundle_deq_branch_id_w;
wire [`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0] queue_bundle_deq_node_id_w;
wire [`TREE_FRONTIER_SLOTS*`KV_GROUP_LEN_W-1:0]
     queue_bundle_deq_size_subbank_w;
wire [`TREE_FRONTIER_SLOTS-1:0] queue_bundle_deq_shared_w;

// queue_bundle_deq -> free_list 的 bundle 包装边界。
wire free_list_bundle_valid_w;
wire [`TREE_FRONTIER_SLOTS-1:0] free_list_bundle_slot_valid_w;
wire [`TREE_FRONTIER_SLOTS*`BRANCH_ID_W-1:0] free_list_bundle_branch_id_w;
wire [`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0] free_list_bundle_node_id_w;
wire [`TREE_FRONTIER_SLOTS*`KV_GROUP_LEN_W-1:0]
     free_list_bundle_size_subbank_w;
wire [`TREE_FRONTIER_SLOTS-1:0] free_list_bundle_shared_w;

// free_list -> AGU 的 candidate response 内部边界。
wire cand_resp_valid_w;
wire cand_resp_grant_w;
wire [`REQ_ID_W-1:0] cand_resp_req_id_w;
wire [`SRAM_ID_W-1:0] cand_resp_sram_id_w;
wire [`BANK_ID_W-1:0] cand_resp_bank_id_w;
wire [`SUBBANK_ID_W-1:0] cand_resp_subbank_start_w;
wire [`KV_GROUP_LEN_W-1:0] cand_resp_group_len_w;
wire cand_resp_bundle_valid_w;
wire [`REQ_ID_W-1:0] cand_resp_bundle_req_id_w;
wire [`TREE_FRONTIER_SLOTS-1:0] cand_resp_bundle_slot_valid_w;
wire [`TREE_FRONTIER_SLOTS-1:0] cand_resp_bundle_grant_w;
wire [`TREE_FRONTIER_SLOTS*`SRAM_ID_W-1:0] cand_resp_bundle_sram_id_w;
wire [`TREE_FRONTIER_SLOTS*`BANK_ID_W-1:0] cand_resp_bundle_bank_id_w;
wire [`TREE_FRONTIER_SLOTS*`SUBBANK_ID_W-1:0]
     cand_resp_bundle_subbank_start_w;
wire [`TREE_FRONTIER_SLOTS*`KV_GROUP_LEN_W-1:0]
     cand_resp_bundle_group_len_w;

// AGU -> free_list 的 flush 扇出内部边界。
wire free_list_flush_valid_w;
wire [`REQ_ID_W-1:0] free_list_flush_req_id_w;
wire [`BRANCH_MASK_W-1:0] free_list_flush_branch_mask_w;
wire [`NODE_MASK_W-1:0] free_list_flush_node_mask_w;
wire free_list_flush_drain_busy_w;
wire token_wr_bundle_valid_w;
wire [`REQ_ID_W-1:0] token_wr_bundle_req_id_w;
wire [`TREE_FRONTIER_SLOTS-1:0] token_wr_bundle_slot_valid_w;
wire [`TREE_FRONTIER_SLOTS*`TOKEN_ID_W-1:0] token_wr_bundle_token_id_w;
wire [`TREE_FRONTIER_SLOTS*`POSITION_ID_W-1:0]
     token_wr_bundle_position_id_w;
wire [`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0] token_wr_bundle_node_id_w;
wire [`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0] token_wr_bundle_parent_node_id_w;
wire [`TREE_FRONTIER_SLOTS*`BRANCH_ID_W-1:0] token_wr_bundle_branch_id_w;
wire [`TREE_LEVEL_ID_W-1:0] token_wr_bundle_level_id_w;
wire [4:0] token_wr_bundle_slot_count_w;
wire [15:0] token_wr_bundle_prefix_len_w;
wire [`TREE_FRONTIER_SLOTS-1:0] token_wr_bundle_slot_tree_mask_en_w;
wire [`TREE_FRONTIER_SLOTS*`MODEL_MAX_POS_EMB-1:0]
     token_wr_bundle_slot_visible_mask_w;
wire [`TREE_FRONTIER_SLOTS*PRIVATE_DEPTH_W-1:0] token_wr_bundle_private_depth_w;
wire [`TREE_FRONTIER_SLOTS*`SRAM_ID_W-1:0] token_wr_bundle_sram_id_w;
wire [`TREE_FRONTIER_SLOTS*`BANK_ID_W-1:0] token_wr_bundle_bank_id_w;
wire [`TREE_FRONTIER_SLOTS*`SUBBANK_ID_W-1:0]
     token_wr_bundle_subbank_start_w;
wire [`TREE_FRONTIER_SLOTS*`KV_GROUP_LEN_W-1:0]
     token_wr_bundle_group_len_w;
wire [`TREE_FRONTIER_SLOTS*`BRANCH_MASK_W-1:0]
     token_wr_bundle_branch_mask_w;
wire [`TREE_FRONTIER_SLOTS-1:0] token_wr_bundle_is_shared_w;
wire [(`TREE_FRONTIER_SLOTS*`TOKEN_REG_INDEX_W)-1:0]
     token_wr_bundle_index_w;
wire token_lookup_bundle_valid_w;
wire token_lookup_bundle_ready_w;
wire [`REQ_ID_W-1:0] token_lookup_bundle_req_id_w;
wire [`TREE_FRONTIER_SLOTS-1:0] token_lookup_bundle_slot_valid_w;
wire [`TREE_FRONTIER_SLOTS*`TOKEN_ID_W-1:0] token_lookup_bundle_token_id_w;
wire [`TREE_FRONTIER_SLOTS*`POSITION_ID_W-1:0]
     token_lookup_bundle_position_id_w;
wire token_lookup_bundle_resp_valid_w;
wire [`REQ_ID_W-1:0] token_lookup_bundle_resp_req_id_w;
wire [`TREE_FRONTIER_SLOTS-1:0] token_lookup_bundle_resp_hit_w;
wire [`TREE_FRONTIER_SLOTS*`SRAM_ID_W-1:0]
     token_lookup_bundle_resp_sram_id_w;
wire [`TREE_FRONTIER_SLOTS*`BANK_ID_W-1:0]
     token_lookup_bundle_resp_bank_id_w;
wire [`TREE_FRONTIER_SLOTS*`SUBBANK_ID_W-1:0]
     token_lookup_bundle_resp_subbank_start_w;
wire [`TREE_FRONTIER_SLOTS*`KV_GROUP_LEN_W-1:0]
     token_lookup_bundle_resp_group_len_w;
wire [`TREE_FRONTIER_SLOTS*`BRANCH_MASK_W-1:0]
     token_lookup_bundle_resp_branch_mask_w;
wire [`TREE_FRONTIER_SLOTS-1:0] token_lookup_bundle_resp_is_shared_w;
wire [`TREE_FRONTIER_SLOTS*`TOKEN_STATE_W-1:0]
     token_lookup_bundle_resp_state_w;
wire [`TREE_FRONTIER_SLOTS*`TOKEN_ENTRY_TYPE_W-1:0]
     token_lookup_bundle_resp_entry_type_w;
wire token_flush_valid_w;
wire [`REQ_ID_W-1:0] token_flush_req_id_w;
wire [`BRANCH_MASK_W-1:0] token_flush_branch_mask_w;
wire [`NODE_MASK_W-1:0] token_flush_node_mask_w;
wire req_accept_fire_w;
reg [`TOKEN_REG_INDEX_W-1:0] token_wr_index_r;
reg [(`TREE_FRONTIER_SLOTS*`TOKEN_REG_INDEX_W)-1:0]
    token_wr_bundle_index_comb;

// 为了让结构测试和顶层接线都能直接看到论文边界，这里保留一组 _w alias。
wire alloc_cand_bundle_valid_w;
wire [`REQ_ID_W-1:0] alloc_cand_bundle_req_id_w;
wire [`TREE_FRONTIER_SLOTS-1:0] alloc_cand_bundle_slot_valid_w;
wire [`TREE_FRONTIER_SLOTS*`BRANCH_ID_W-1:0] alloc_cand_bundle_branch_id_w;
wire [`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0] alloc_cand_bundle_node_id_w;
wire [`TREE_FRONTIER_SLOTS*`KV_GROUP_LEN_W-1:0]
     alloc_cand_bundle_size_subbank_w;
wire [`TREE_FRONTIER_SLOTS-1:0] alloc_cand_bundle_shared_w;
wire [`TREE_FRONTIER_SLOTS*`SRAM_ID_W-1:0] alloc_cand_bundle_sram_id_w;
wire [`TREE_FRONTIER_SLOTS*`BANK_ID_W-1:0] alloc_cand_bundle_bank_id_w;
wire [`TREE_FRONTIER_SLOTS*`SUBBANK_ID_W-1:0]
     alloc_cand_bundle_subbank_start_w;
wire [`TREE_FRONTIER_SLOTS*`KV_GROUP_LEN_W-1:0]
     alloc_cand_bundle_group_len_w;

assign alloc_cand_bundle_valid_w = alloc_cand_bundle_valid;
assign alloc_cand_bundle_req_id_w = alloc_cand_bundle_req_id;
assign alloc_cand_bundle_slot_valid_w = alloc_cand_bundle_slot_valid;
assign alloc_cand_bundle_branch_id_w = alloc_cand_bundle_branch_id;
assign alloc_cand_bundle_node_id_w = alloc_cand_bundle_node_id;
assign alloc_cand_bundle_size_subbank_w = alloc_cand_bundle_size_subbank;
assign alloc_cand_bundle_shared_w = alloc_cand_bundle_shared;
assign alloc_cand_bundle_sram_id_w = alloc_cand_bundle_sram_id;
assign alloc_cand_bundle_bank_id_w = alloc_cand_bundle_bank_id;
assign alloc_cand_bundle_subbank_start_w = alloc_cand_bundle_subbank_start;
assign alloc_cand_bundle_group_len_w = alloc_cand_bundle_group_len;
assign flush_drain_busy = free_list_flush_drain_busy_w;
assign token_wr_index = token_wr_index_r;
assign req_accept_fire_w = req_valid && req_ready;
assign token_wr_bundle_index_w =
    token_wr_bundle_index_comb;

assign agu_bundle_valid_w = agu_bundle_valid_comb;
assign agu_bundle_req_id_w = agu_bundle_req_id_comb;
assign agu_bundle_level_id_w = agu_bundle_level_id_comb;
assign agu_bundle_slot_valid_w = agu_bundle_slot_valid_comb;
assign agu_bundle_node_id_w = agu_bundle_node_id_comb;
assign agu_bundle_parent_node_id_w = agu_bundle_parent_node_id_comb;
assign agu_bundle_token_id_w = agu_bundle_token_id_comb;
assign agu_bundle_position_id_w = agu_bundle_position_id_comb;
assign agu_bundle_branch_id_w = agu_bundle_branch_id_comb;
assign agu_bundle_slot_shared_w = agu_bundle_slot_shared_comb;
assign agu_bundle_slot_count_w = agu_bundle_slot_count_comb;
assign agu_bundle_prefix_len_w = agu_bundle_prefix_len_comb;
assign agu_bundle_slot_tree_mask_en_w = agu_bundle_slot_tree_mask_en_comb;
assign agu_bundle_slot_visible_mask_w = agu_bundle_slot_visible_mask_comb;

always @* begin
    token_wr_bundle_index_comb =
        {(`TREE_FRONTIER_SLOTS*`TOKEN_REG_INDEX_W){1'b0}};
    for (token_wr_bundle_slot_i = 0;
         token_wr_bundle_slot_i < `TREE_FRONTIER_SLOTS;
         token_wr_bundle_slot_i = token_wr_bundle_slot_i + 1) begin
        if (token_wr_bundle_slot_valid_w[token_wr_bundle_slot_i]) begin
            token_wr_bundle_index_comb[
                (token_wr_bundle_slot_i*`TOKEN_REG_INDEX_W) +:
                `TOKEN_REG_INDEX_W] = token_wr_index_r;
        end
    end
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        token_wr_index_r <= {`TOKEN_REG_INDEX_W{1'b0}};
    end else begin
        if (token_wr_valid) begin
            token_wr_index_r <= token_wr_index_r + 1'b1;
        end
        if (req_accept_fire_w) begin
            token_wr_index_r <= {`TOKEN_REG_INDEX_W{1'b0}};
        end
    end
end

// AGU 已经进容器，因此 tree_analyze 的 ready 直接由 AGU bundle 消费能力决定。
assign prefix_ready = agu_bundle_ready_w;
assign frontier_ready = agu_bundle_ready_w;

// 当前容器已经把 prefix/frontier -> bundle 的 ownership 收进来。
always @* begin
    agu_bundle_valid_comb = 1'b0;
    agu_bundle_req_id_comb = {`REQ_ID_W{1'b0}};
    agu_bundle_level_id_comb = {`TREE_LEVEL_ID_W{1'b0}};
    agu_bundle_slot_valid_comb = {`TREE_FRONTIER_SLOTS{1'b0}};
    agu_bundle_node_id_comb = {(`TREE_FRONTIER_SLOTS*`NODE_ID_W){1'b0}};
    agu_bundle_parent_node_id_comb =
        {(`TREE_FRONTIER_SLOTS*`NODE_ID_W){1'b0}};
    agu_bundle_token_id_comb = {(`TREE_FRONTIER_SLOTS*`TOKEN_ID_W){1'b0}};
    agu_bundle_position_id_comb =
        {(`TREE_FRONTIER_SLOTS*`POSITION_ID_W){1'b0}};
    agu_bundle_branch_id_comb =
        {(`TREE_FRONTIER_SLOTS*`BRANCH_ID_W){1'b0}};
    agu_bundle_slot_shared_comb = {`TREE_FRONTIER_SLOTS{1'b0}};
    agu_bundle_slot_count_comb = 5'd0;
    agu_bundle_prefix_len_comb = 16'd0;
    agu_bundle_slot_tree_mask_en_comb = {`TREE_FRONTIER_SLOTS{1'b0}};
    agu_bundle_slot_visible_mask_comb =
        {(`TREE_FRONTIER_SLOTS*`MODEL_MAX_POS_EMB){1'b0}};

    if (prefix_valid) begin
        agu_bundle_valid_comb = prefix_node_valid;
        agu_bundle_req_id_comb = prefix_req_id;
        agu_bundle_level_id_comb = prefix_layer_id[`TREE_LEVEL_ID_W-1:0];
        agu_bundle_slot_valid_comb =
            {{(`TREE_FRONTIER_SLOTS-1){1'b0}}, 1'b1};
        agu_bundle_node_id_comb[`NODE_ID_W-1:0] = prefix_node_id;
        agu_bundle_parent_node_id_comb[`NODE_ID_W-1:0] =
            prefix_parent_node_id;
        agu_bundle_token_id_comb[`TOKEN_ID_W-1:0] = prefix_token_id;
        agu_bundle_position_id_comb[`POSITION_ID_W-1:0] = prefix_position_id;
        agu_bundle_slot_shared_comb[0] = 1'b1;
        agu_bundle_slot_count_comb = 5'd1;
        agu_bundle_prefix_len_comb = prefix_count;
    end else if (frontier_valid) begin
        agu_bundle_valid_comb = 1'b1;
        agu_bundle_req_id_comb = frontier_req_id;
        agu_bundle_level_id_comb = frontier_level_id;
        agu_bundle_slot_valid_comb = frontier_slot_valid;
        agu_bundle_node_id_comb = frontier_node_id;
        agu_bundle_parent_node_id_comb = frontier_parent_node_id;
        agu_bundle_token_id_comb = frontier_token_id;
        agu_bundle_position_id_comb = frontier_position_id;
        agu_bundle_branch_id_comb = frontier_branch_id;
        agu_bundle_slot_count_comb = frontier_level_slot_count[4:0];
        agu_bundle_prefix_len_comb = prefix_count;
        agu_bundle_slot_tree_mask_en_comb = frontier_tree_mask_en;
        for (visible_slot_i = 0;
             visible_slot_i < `TREE_FRONTIER_SLOTS;
             visible_slot_i = visible_slot_i + 1) begin
            agu_bundle_slot_visible_mask_comb[
                (visible_slot_i*`MODEL_MAX_POS_EMB) +: `MODEL_MAX_POS_EMB] =
                visible_mask_by_level[
                    (((frontier_level_id*`TREE_FRONTIER_SLOTS) +
                      visible_slot_i) * `MODEL_MAX_POS_EMB) +:
                     `MODEL_MAX_POS_EMB];
        end
    end
end

tree_analyze u_tree_analyze (
    .clk(clk),
    .rst_n(rst_n),
    .req_valid(req_valid),
    .req_ready(req_ready),
    .req_id(req_id),
    .src_prefix_slot_valid(src_prefix_slot_valid),
    .src_prefix_node_id(src_prefix_node_id),
    .src_prefix_token_id(src_prefix_token_id),
    .src_prefix_position_id(src_prefix_position_id),
    .src_committed_len(src_committed_len),
    .src_frontier_level_valid(src_frontier_level_valid),
    .src_frontier_slot_valid(src_frontier_slot_valid),
    .src_frontier_node_id(src_frontier_node_id),
    .src_frontier_parent_node_id(src_frontier_parent_node_id),
    .src_frontier_token_id(src_frontier_token_id),
    .src_frontier_referenced_token_id(src_frontier_referenced_token_id),
    .src_frontier_position_id(src_frontier_position_id),
    .src_frontier_referenced_position_id(
        src_frontier_referenced_position_id),
    .src_frontier_branch_id(src_frontier_branch_id),
    .src_frontier_level_id(src_frontier_level_id),
    .src_frontier_tree_mask_en(src_frontier_tree_mask_en),
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
    .prefix_count(prefix_count),
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

agu u_agu (
    .clk(clk),
    .rst_n(rst_n),
    .tree_in_valid(1'b0),
    .tree_in_ready(),
    .tree_in_req_id({`REQ_ID_W{1'b0}}),
    .tree_in_branch_id({`BRANCH_ID_W{1'b0}}),
    .tree_in_node_id({`NODE_ID_W{1'b0}}),
    .bundle_in_valid(agu_bundle_valid_w),
    .bundle_in_ready(agu_bundle_ready_w),
    .bundle_in_req_id(agu_bundle_req_id_w),
    .bundle_in_level_id(agu_bundle_level_id_w),
    .bundle_in_slot_valid(agu_bundle_slot_valid_w),
    .bundle_in_node_id(agu_bundle_node_id_w),
    .bundle_in_parent_node_id(agu_bundle_parent_node_id_w),
    .bundle_in_token_id(agu_bundle_token_id_w),
    .bundle_in_position_id(agu_bundle_position_id_w),
    .bundle_in_branch_id(agu_bundle_branch_id_w),
    .bundle_in_slot_shared(agu_bundle_slot_shared_w),
    .bundle_in_slot_count(agu_bundle_slot_count_w),
    .bundle_in_prefix_len(agu_bundle_prefix_len_w),
    .bundle_in_slot_tree_mask_en(agu_bundle_slot_tree_mask_en_w),
    .bundle_in_slot_visible_mask(agu_bundle_slot_visible_mask_w),
    .prefix_valid(1'b0),
    .prefix_ready(),
    .prefix_req_id({`REQ_ID_W{1'b0}}),
    .prefix_node_valid(1'b0),
    .prefix_node_id({`NODE_ID_W{1'b0}}),
    .prefix_parent_node_id({`NODE_ID_W{1'b0}}),
    .prefix_token_id({`TOKEN_ID_W{1'b0}}),
    .prefix_position_id({`POSITION_ID_W{1'b0}}),
    .prefix_layer_id({`LAYER_ID_W{1'b0}}),
    .prefix_is_last(1'b0),
    .frontier_valid(1'b0),
    .frontier_ready(),
    .frontier_req_id({`REQ_ID_W{1'b0}}),
    .frontier_level_id({`TREE_LEVEL_ID_W{1'b0}}),
    .frontier_slot_valid({`TREE_FRONTIER_SLOTS{1'b0}}),
    .frontier_node_id({(`TREE_FRONTIER_SLOTS*`NODE_ID_W){1'b0}}),
    .frontier_parent_node_id({(`TREE_FRONTIER_SLOTS*`NODE_ID_W){1'b0}}),
    .frontier_token_id({(`TREE_FRONTIER_SLOTS*`TOKEN_ID_W){1'b0}}),
    .frontier_position_id({(`TREE_FRONTIER_SLOTS*`POSITION_ID_W){1'b0}}),
    .prefetch_enq_ready(1'b0),
    .cand_resp_valid(cand_resp_valid_w),
    .prefetch_bundle_ready(prefetch_bundle_ready_w),
    .cand_resp_grant(cand_resp_grant_w),
    .cand_resp_req_id(cand_resp_req_id_w),
    .cand_resp_sram_id(cand_resp_sram_id_w),
    .cand_resp_bank_id(cand_resp_bank_id_w),
    .cand_resp_subbank_start(cand_resp_subbank_start_w),
    .cand_resp_group_len(cand_resp_group_len_w),
    .cand_resp_bundle_valid(cand_resp_bundle_valid_w),
    .cand_resp_bundle_req_id(cand_resp_bundle_req_id_w),
    .cand_resp_bundle_slot_valid(cand_resp_bundle_slot_valid_w),
    .cand_resp_bundle_grant(cand_resp_bundle_grant_w),
    .cand_resp_bundle_sram_id(cand_resp_bundle_sram_id_w),
    .cand_resp_bundle_bank_id(cand_resp_bundle_bank_id_w),
    .cand_resp_bundle_subbank_start(cand_resp_bundle_subbank_start_w),
    .cand_resp_bundle_group_len(cand_resp_bundle_group_len_w),
    .alloc_resp_valid(1'b0),
    .alloc_resp_grant(1'b0),
    .alloc_resp_req_id({`REQ_ID_W{1'b0}}),
    .alloc_resp_sram_id({`SRAM_ID_W{1'b0}}),
    .alloc_resp_bank_id({`BANK_ID_W{1'b0}}),
    .alloc_resp_subbank_start({`SUBBANK_ID_W{1'b0}}),
    .alloc_resp_group_len({`KV_GROUP_LEN_W{1'b0}}),
    .flush_freeze(cmp_flush_valid),
    .flush_drain_busy(free_list_flush_drain_busy_w),
    .flush_ctrl_valid(cmp_flush_valid),
    .flush_ctrl_req_id(cmp_accepted_prefix_req_id),
    .flush_ctrl_branch_mask(cmp_flush_branch_mask),
    .flush_ctrl_node_mask(cmp_flush_node_mask),
    .branch_liveness_valid(cmp_accepted_prefix_valid),
    .branch_liveness_req_id(cmp_accepted_prefix_req_id),
    .branch_liveness_live_mask(cmp_live_branch_mask),
    .branch_liveness_prune_mask(cmp_prune_branch_mask),
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
    .alloc_cand_valid(),
    .alloc_cand_req_id(),
    .alloc_cand_branch_id(),
    .alloc_cand_node_id(),
    .alloc_cand_size_subbank(),
    .alloc_cand_shared(),
    .alloc_cand_sram_id(),
    .alloc_cand_bank_id(),
    .alloc_cand_subbank_start(),
    .alloc_cand_group_len(),
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
    .token_wr_bundle_valid(token_wr_bundle_valid_w),
    .token_wr_bundle_req_id(token_wr_bundle_req_id_w),
    .token_wr_bundle_slot_valid(token_wr_bundle_slot_valid_w),
    .token_wr_bundle_token_id(token_wr_bundle_token_id_w),
    .token_wr_bundle_position_id(token_wr_bundle_position_id_w),
    .token_wr_bundle_node_id(token_wr_bundle_node_id_w),
    .token_wr_bundle_parent_node_id(token_wr_bundle_parent_node_id_w),
    .token_wr_bundle_branch_id(token_wr_bundle_branch_id_w),
    .token_wr_bundle_level_id(token_wr_bundle_level_id_w),
    .token_wr_bundle_slot_count(token_wr_bundle_slot_count_w),
    .token_wr_bundle_prefix_len(token_wr_bundle_prefix_len_w),
    .token_wr_bundle_slot_tree_mask_en(token_wr_bundle_slot_tree_mask_en_w),
    .token_wr_bundle_slot_visible_mask(token_wr_bundle_slot_visible_mask_w),
    .token_wr_bundle_private_depth(token_wr_bundle_private_depth_w),
    .token_wr_bundle_sram_id(token_wr_bundle_sram_id_w),
    .token_wr_bundle_bank_id(token_wr_bundle_bank_id_w),
    .token_wr_bundle_subbank_start(token_wr_bundle_subbank_start_w),
    .token_wr_bundle_group_len(token_wr_bundle_group_len_w),
    .token_wr_bundle_branch_mask(token_wr_bundle_branch_mask_w),
    .token_wr_bundle_is_shared(token_wr_bundle_is_shared_w),
    .prefetch_enq_valid(),
    .prefetch_enq_req_id(),
    .prefetch_enq_branch_id(),
    .prefetch_enq_node_id(),
    .prefetch_enq_layer_id(),
    .prefetch_enq_size_subbank(),
    .prefetch_enq_shared(),
    .prefetch_bundle_valid(prefetch_bundle_valid),
    .prefetch_bundle_req_id(prefetch_bundle_req_id),
    .prefetch_bundle_layer_id(prefetch_bundle_layer_id),
    .prefetch_bundle_slot_valid(prefetch_bundle_slot_valid),
    .prefetch_bundle_branch_id(prefetch_bundle_branch_id),
    .prefetch_bundle_node_id(prefetch_bundle_node_id),
    .prefetch_bundle_size_subbank(prefetch_bundle_size_subbank),
    .prefetch_bundle_shared(prefetch_bundle_shared),
    .prefetch_flush_valid(prefetch_flush_valid_w),
    .prefetch_flush_req_id(prefetch_flush_req_id_w),
    .prefetch_flush_branch_mask(prefetch_flush_branch_mask_w),
    .prefetch_flush_node_mask(prefetch_flush_node_mask_w),
    .free_list_flush_valid(free_list_flush_valid_w),
    .free_list_flush_req_id(free_list_flush_req_id_w),
    .free_list_flush_branch_mask(free_list_flush_branch_mask_w),
    .free_list_flush_node_mask(free_list_flush_node_mask_w),
    .token_flush_valid(token_flush_valid_w),
    .token_flush_req_id(token_flush_req_id_w),
    .token_flush_branch_mask(token_flush_branch_mask_w),
    .token_flush_node_mask(token_flush_node_mask_w)
);

prefetch_queue u_prefetch_queue (
    .clk(clk),
    .rst_n(rst_n),
    .enq_valid(1'b0),
    .enq_ready(),
    .enq_req_id({`REQ_ID_W{1'b0}}),
    .enq_branch_id({`BRANCH_ID_W{1'b0}}),
    .enq_node_id({`NODE_ID_W{1'b0}}),
    .enq_layer_id({`LAYER_ID_W{1'b0}}),
    .enq_size_subbank({`KV_GROUP_LEN_W{1'b0}}),
    .enq_shared(1'b0),
    .bundle_enq_valid(prefetch_bundle_valid),
    .bundle_enq_ready(prefetch_bundle_ready_w),
    .bundle_enq_req_id(prefetch_bundle_req_id),
    .bundle_enq_layer_id(prefetch_bundle_layer_id),
    .bundle_enq_slot_valid(prefetch_bundle_slot_valid),
    .bundle_enq_branch_id(prefetch_bundle_branch_id),
    .bundle_enq_node_id(prefetch_bundle_node_id),
    .bundle_enq_size_subbank(prefetch_bundle_size_subbank),
    .bundle_enq_shared(prefetch_bundle_shared),
    .flush_valid(prefetch_flush_valid_w),
    .flush_req_id(prefetch_flush_req_id_w),
    .flush_branch_mask(prefetch_flush_branch_mask_w),
    .flush_node_mask(prefetch_flush_node_mask_w),
    .bundle_deq_valid(queue_bundle_deq_valid_w),
    .bundle_deq_ready(queue_bundle_deq_ready_w),
    .bundle_deq_req_id(queue_bundle_deq_req_id_w),
    .bundle_deq_layer_id(queue_bundle_deq_layer_id_w),
    .bundle_deq_slot_valid(queue_bundle_deq_slot_valid_w),
    .bundle_deq_branch_id(queue_bundle_deq_branch_id_w),
    .bundle_deq_node_id(queue_bundle_deq_node_id_w),
    .bundle_deq_size_subbank(queue_bundle_deq_size_subbank_w),
    .bundle_deq_shared(queue_bundle_deq_shared_w),
    .deq_valid(),
    .deq_ready(1'b0),
    .deq_req_id(),
    .deq_branch_id(),
    .deq_node_id(),
    .deq_layer_id(),
    .deq_size_subbank(),
    .deq_shared()
);

// 论文 strict 主路径在容器内部仍显式保留 queue -> free_list 的 bundle 边界。
assign free_list_bundle_valid_w = queue_bundle_deq_valid_w;
assign free_list_bundle_slot_valid_w = queue_bundle_deq_slot_valid_w;
assign free_list_bundle_branch_id_w = queue_bundle_deq_branch_id_w;
assign free_list_bundle_node_id_w = queue_bundle_deq_node_id_w;
assign free_list_bundle_size_subbank_w = queue_bundle_deq_size_subbank_w;
assign free_list_bundle_shared_w = queue_bundle_deq_shared_w;

free_list u_free_list (
    .clk(clk),
    .rst_n(rst_n),
    .cand_req_valid(1'b0),
    .cand_req_ready(),
    .cand_req_req_id({`REQ_ID_W{1'b0}}),
    .cand_req_branch_id({`BRANCH_ID_W{1'b0}}),
    .cand_req_node_id({`NODE_ID_W{1'b0}}),
    .cand_req_size_subbank({`KV_GROUP_LEN_W{1'b0}}),
    .cand_req_shared(1'b0),
    .bundle_req_valid(free_list_bundle_valid_w),
    .bundle_req_ready(queue_bundle_deq_ready_w),
    .bundle_req_req_id(queue_bundle_deq_req_id_w),
    .bundle_req_slot_valid(free_list_bundle_slot_valid_w),
    .bundle_req_branch_id(free_list_bundle_branch_id_w),
    .bundle_req_node_id(free_list_bundle_node_id_w),
    .bundle_req_size_subbank(free_list_bundle_size_subbank_w),
    .bundle_req_shared(free_list_bundle_shared_w),
    .cand_resp_valid(cand_resp_valid_w),
    .cand_resp_grant(cand_resp_grant_w),
    .cand_resp_req_id(cand_resp_req_id_w),
    .cand_resp_sram_id(cand_resp_sram_id_w),
    .cand_resp_bank_id(cand_resp_bank_id_w),
    .cand_resp_subbank_start(cand_resp_subbank_start_w),
    .cand_resp_group_len(cand_resp_group_len_w),
    .cand_resp_bundle_valid(cand_resp_bundle_valid_w),
    .cand_resp_bundle_req_id(cand_resp_bundle_req_id_w),
    .cand_resp_bundle_slot_valid(cand_resp_bundle_slot_valid_w),
    .cand_resp_bundle_grant(cand_resp_bundle_grant_w),
    .cand_resp_bundle_sram_id(cand_resp_bundle_sram_id_w),
    .cand_resp_bundle_bank_id(cand_resp_bundle_bank_id_w),
    .cand_resp_bundle_subbank_start(cand_resp_bundle_subbank_start_w),
    .cand_resp_bundle_group_len(cand_resp_bundle_group_len_w),
    .alloc_cand_valid(),
    .alloc_cand_req_id(),
    .alloc_cand_branch_id(),
    .alloc_cand_node_id(),
    .alloc_cand_size_subbank(),
    .alloc_cand_shared(),
    .alloc_cand_sram_id(),
    .alloc_cand_bank_id(),
    .alloc_cand_subbank_start(),
    .alloc_cand_group_len(),
    .alloc_cand_bundle_valid(alloc_cand_bundle_valid),
    .alloc_cand_bundle_req_id(alloc_cand_bundle_req_id),
    .alloc_cand_bundle_slot_valid(alloc_cand_bundle_slot_valid),
    .alloc_cand_bundle_branch_id(alloc_cand_bundle_branch_id),
    .alloc_cand_bundle_node_id(alloc_cand_bundle_node_id),
    .alloc_cand_bundle_size_subbank(alloc_cand_bundle_size_subbank),
    .alloc_cand_bundle_shared(alloc_cand_bundle_shared),
    .alloc_cand_bundle_sram_id(alloc_cand_bundle_sram_id),
    .alloc_cand_bundle_bank_id(alloc_cand_bundle_bank_id),
    .alloc_cand_bundle_subbank_start(alloc_cand_bundle_subbank_start),
    .alloc_cand_bundle_group_len(alloc_cand_bundle_group_len),
    .flush_valid(free_list_flush_valid_w),
    .flush_req_id(free_list_flush_req_id_w),
    .flush_branch_mask(free_list_flush_branch_mask_w),
    .flush_node_mask(free_list_flush_node_mask_w),
    .flush_drain_busy(free_list_flush_drain_busy_w),
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

comparator u_comparator (
    .clk(clk),
    .rst_n(rst_n),
    .cmp_req_id(cmp_req_id),
    .cmp_slot_valid(cmp_slot_valid),
    .cmp_slot_real_token_id(cmp_slot_real_token_id),
    .cmp_slot_candidate_token_id(cmp_slot_candidate_token_id),
    .cmp_slot_node_id(cmp_slot_node_id),
    .cmp_slot_parent_node_id(cmp_slot_parent_node_id),
    .cmp_slot_branch_id(cmp_slot_branch_id),
    .reduce_start_valid(reduce_start_valid),
    .reduce_req_id(reduce_req_id),
    .active_branch_valid(active_branch_valid),
    .active_branch_epoch(active_branch_epoch),
    .active_branch_depth(active_branch_depth),
    .active_branch_node_id(active_branch_node_id),
    .active_branch_parent_node_id(active_branch_parent_node_id),
    .result_slot_valid(result_slot_valid),
    .result_req_id(result_req_id),
    .result_branch_id(result_branch_id),
    .result_branch_epoch(result_branch_epoch),
    .result_private_depth(result_private_depth),
    .result_node_id(result_node_id),
    .result_parent_node_id(result_parent_node_id),
    .result_accept(result_accept),
    .commit_valid(cmp_commit_valid),
    .commit_branch_mask(cmp_commit_branch_mask),
    .commit_node_mask(cmp_commit_node_mask),
    .flush_valid(cmp_flush_valid),
    .flush_branch_mask(cmp_flush_branch_mask),
    .flush_node_mask(cmp_flush_node_mask),
    .accepted_prefix_valid(cmp_accepted_prefix_valid),
    .accepted_prefix_req_id(cmp_accepted_prefix_req_id),
    .accepted_prefix_branch_id(cmp_accepted_prefix_branch_id),
    .accepted_prefix_depth(cmp_accepted_prefix_depth),
    .accepted_prefix_node_id(cmp_accepted_prefix_node_id),
    .live_branch_mask(cmp_live_branch_mask),
    .prune_branch_mask(cmp_prune_branch_mask)
);

StrictTreeMaskPaperIssueScheduler u_strict_tree_mask_paper_issue_scheduler (
    .clk(clk),
    .rst_n(rst_n),
    .src_bundle_valid(token_wr_bundle_valid_w),
    .src_bundle_ready(),
    .src_bundle_req_id(token_wr_bundle_req_id_w),
    .src_bundle_slot_valid(token_wr_bundle_slot_valid_w),
    .src_bundle_token_id(token_wr_bundle_token_id_w),
    .src_bundle_position_id(token_wr_bundle_position_id_w),
    .src_bundle_node_id(token_wr_bundle_node_id_w),
    .src_bundle_parent_node_id(token_wr_bundle_parent_node_id_w),
    .src_bundle_branch_id(token_wr_bundle_branch_id_w),
    .src_bundle_level_id(token_wr_bundle_level_id_w),
    .src_bundle_slot_count(token_wr_bundle_slot_count_w),
    .src_bundle_prefix_len(token_wr_bundle_prefix_len_w),
    .src_bundle_slot_tree_mask_en(token_wr_bundle_slot_tree_mask_en_w),
    .src_bundle_slot_visible_mask(token_wr_bundle_slot_visible_mask_w),
    .src_bundle_private_depth(token_wr_bundle_private_depth_w),
    .lookup_bundle_valid(token_lookup_bundle_valid_w),
    .lookup_bundle_ready(token_lookup_bundle_ready_w),
    .lookup_bundle_req_id(token_lookup_bundle_req_id_w),
    .lookup_bundle_slot_valid(token_lookup_bundle_slot_valid_w),
    .lookup_bundle_token_id(token_lookup_bundle_token_id_w),
    .lookup_bundle_position_id(token_lookup_bundle_position_id_w),
    .lookup_bundle_resp_valid(token_lookup_bundle_resp_valid_w),
    .lookup_bundle_resp_req_id(token_lookup_bundle_resp_req_id_w),
    .lookup_bundle_resp_hit(token_lookup_bundle_resp_hit_w),
    .lookup_bundle_resp_sram_id(token_lookup_bundle_resp_sram_id_w),
    .lookup_bundle_resp_bank_id(token_lookup_bundle_resp_bank_id_w),
    .lookup_bundle_resp_subbank_start(
        token_lookup_bundle_resp_subbank_start_w),
    .lookup_bundle_resp_group_len(token_lookup_bundle_resp_group_len_w),
    .lookup_bundle_resp_branch_mask(token_lookup_bundle_resp_branch_mask_w),
    .lookup_bundle_resp_is_shared(token_lookup_bundle_resp_is_shared_w),
    .lookup_bundle_resp_state(token_lookup_bundle_resp_state_w),
    .lookup_bundle_resp_entry_type(token_lookup_bundle_resp_entry_type_w),
    .issue_bundle_valid(paper_issue_bundle_valid),
    .issue_bundle_ready(paper_issue_bundle_ready),
    .issue_bundle_req_id(paper_issue_bundle_req_id),
    .issue_bundle_slot_valid(paper_issue_bundle_slot_valid),
    .issue_bundle_slot_lookup_hit(paper_issue_bundle_slot_lookup_hit),
    .issue_bundle_token_id(paper_issue_bundle_token_id),
    .issue_bundle_position_id(paper_issue_bundle_position_id),
    .issue_bundle_node_id(paper_issue_bundle_node_id),
    .issue_bundle_parent_node_id(paper_issue_bundle_parent_node_id),
    .issue_bundle_branch_id(paper_issue_bundle_branch_id),
    .issue_bundle_level_id(paper_issue_bundle_level_id),
    .issue_bundle_slot_count(paper_issue_bundle_slot_count),
    .issue_bundle_prefix_len(paper_issue_bundle_prefix_len),
    .issue_bundle_slot_tree_mask_en(paper_issue_bundle_slot_tree_mask_en),
    .issue_bundle_slot_visible_mask(paper_issue_bundle_slot_visible_mask),
    .issue_bundle_private_depth(paper_issue_bundle_private_depth),
    .issue_bundle_sram_id(paper_issue_bundle_sram_id),
    .issue_bundle_bank_id(paper_issue_bundle_bank_id),
    .issue_bundle_subbank_start(paper_issue_bundle_subbank_start),
    .issue_bundle_group_len(paper_issue_bundle_group_len),
    .issue_bundle_branch_mask(paper_issue_bundle_branch_mask),
    .issue_bundle_is_shared(paper_issue_bundle_is_shared),
    .issue_bundle_entry_state(paper_issue_bundle_entry_state),
    .issue_bundle_entry_type(paper_issue_bundle_entry_type),
    .issue_bundle_embedding_base_addr(paper_issue_bundle_embedding_base_addr),
    .issue_bundle_hidden0_base_addr(paper_issue_bundle_hidden0_base_addr),
    .issue_bundle_hidden1_base_addr(paper_issue_bundle_hidden1_base_addr),
    .issue_bundle_final_base_addr(paper_issue_bundle_final_base_addr),
    .issue_bundle_weight_sram_base_addr(paper_issue_bundle_weight_sram_base_addr),
    .issue_bundle_kv_cache_base_addr(paper_issue_bundle_kv_cache_base_addr),
    .issue_bundle_draft_kv_base_addr(paper_issue_bundle_draft_kv_base_addr),
    .issue_bundle_hbm_weight_base_addr(paper_issue_bundle_hbm_weight_base_addr),
    .issue_bundle_final_norm_gamma_addr(paper_issue_bundle_final_norm_gamma_addr),
    .issue_bundle_lm_head_weight_base_addr(paper_issue_bundle_lm_head_weight_base_addr)
);

bank_state_table u_bank_state_table (
    .clk(clk),
    .rst_n(rst_n),
    .cand_valid(1'b0),
    .cand_ready(),
    .cand_req_id({`REQ_ID_W{1'b0}}),
    .cand_branch_id({`BRANCH_ID_W{1'b0}}),
    .cand_node_id({`NODE_ID_W{1'b0}}),
    .cand_size_subbank({`KV_GROUP_LEN_W{1'b0}}),
    .cand_shared(1'b0),
    .cand_sram_id({`SRAM_ID_W{1'b0}}),
    .cand_bank_id({`BANK_ID_W{1'b0}}),
    .cand_subbank_start({`SUBBANK_ID_W{1'b0}}),
    .cand_group_len({`KV_GROUP_LEN_W{1'b0}}),
    .cand_bundle_valid(alloc_cand_bundle_valid_w),
    .cand_bundle_ready(),
    .cand_bundle_req_id(alloc_cand_bundle_req_id_w),
    .cand_bundle_slot_valid(alloc_cand_bundle_slot_valid_w),
    .cand_bundle_branch_id(alloc_cand_bundle_branch_id_w),
    .cand_bundle_node_id(alloc_cand_bundle_node_id_w),
    .cand_bundle_size_subbank(alloc_cand_bundle_size_subbank_w),
    .cand_bundle_shared(alloc_cand_bundle_shared_w),
    .cand_bundle_sram_id(alloc_cand_bundle_sram_id_w),
    .cand_bundle_bank_id(alloc_cand_bundle_bank_id_w),
    .cand_bundle_subbank_start(alloc_cand_bundle_subbank_start_w),
    .cand_bundle_group_len(alloc_cand_bundle_group_len_w),
    .alloc_resp_valid(),
    .alloc_resp_grant(),
    .alloc_resp_req_id(),
    .alloc_resp_sram_id(),
    .alloc_resp_bank_id(),
    .alloc_resp_subbank_start(),
    .alloc_resp_group_len(),
    .alloc_resp_occ_bitmap(),
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
    .wr_valid(1'b0),
    .wr_ready(),
    .wr_index({`TOKEN_REG_INDEX_W{1'b0}}),
    .wr_req_id({`REQ_ID_W{1'b0}}),
    .wr_token_id({`TOKEN_ID_W{1'b0}}),
    .wr_position_id({`POSITION_ID_W{1'b0}}),
    .wr_node_id({`NODE_ID_W{1'b0}}),
    .wr_branch_id({`BRANCH_ID_W{1'b0}}),
    .wr_sram_id({`SRAM_ID_W{1'b0}}),
    .wr_bank_id({`BANK_ID_W{1'b0}}),
    .wr_subbank_start({`SUBBANK_ID_W{1'b0}}),
    .wr_group_len({`KV_GROUP_LEN_W{1'b0}}),
    .wr_branch_mask({`BRANCH_MASK_W{1'b0}}),
    .wr_is_shared(1'b0),
    .wr_bundle_valid(token_wr_bundle_valid_w),
    .wr_bundle_ready(),
    .wr_bundle_slot_valid(token_wr_bundle_slot_valid_w),
    .wr_bundle_index(token_wr_bundle_index_w),
    .wr_bundle_req_id(token_wr_bundle_req_id_w),
    .wr_bundle_token_id(token_wr_bundle_token_id_w),
    .wr_bundle_position_id(token_wr_bundle_position_id_w),
    .wr_bundle_node_id(token_wr_bundle_node_id_w),
    .wr_bundle_branch_id(token_wr_bundle_branch_id_w),
    .wr_bundle_sram_id(token_wr_bundle_sram_id_w),
    .wr_bundle_bank_id(token_wr_bundle_bank_id_w),
    .wr_bundle_subbank_start(token_wr_bundle_subbank_start_w),
    .wr_bundle_group_len(token_wr_bundle_group_len_w),
    .wr_bundle_branch_mask(token_wr_bundle_branch_mask_w),
    .wr_bundle_is_shared(token_wr_bundle_is_shared_w),
    .lookup_valid(token_lookup_valid),
    .lookup_ready(token_lookup_ready),
    .lookup_req_id({`REQ_ID_W{1'b0}}),
    .lookup_token_id(token_lookup_token_id),
    .lookup_position_id(token_lookup_position_id),
    .lookup_resp_valid(),
    .lookup_resp_hit(token_lookup_hit),
    .lookup_resp_req_id(),
    .lookup_resp_sram_id(token_lookup_sram_id),
    .lookup_resp_bank_id(token_lookup_bank_id),
    .lookup_resp_subbank_start(token_lookup_subbank_start),
    .lookup_resp_group_len(token_lookup_group_len),
    .lookup_resp_branch_mask(token_lookup_branch_mask),
    .lookup_resp_is_shared(token_lookup_is_shared),
    .lookup_resp_entry_type(token_lookup_entry_type),
    .lookup_resp_state(token_lookup_entry_state),
    .lookup_bundle_valid(token_lookup_bundle_valid_w),
    .lookup_bundle_ready(token_lookup_bundle_ready_w),
    .lookup_bundle_req_id(token_lookup_bundle_req_id_w),
    .lookup_bundle_slot_valid(token_lookup_bundle_slot_valid_w),
    .lookup_bundle_token_id(token_lookup_bundle_token_id_w),
    .lookup_bundle_position_id(token_lookup_bundle_position_id_w),
    .lookup_bundle_resp_valid(token_lookup_bundle_resp_valid_w),
    .lookup_bundle_resp_req_id(token_lookup_bundle_resp_req_id_w),
    .lookup_bundle_resp_hit(token_lookup_bundle_resp_hit_w),
    .lookup_bundle_resp_sram_id(token_lookup_bundle_resp_sram_id_w),
    .lookup_bundle_resp_bank_id(token_lookup_bundle_resp_bank_id_w),
    .lookup_bundle_resp_subbank_start(
        token_lookup_bundle_resp_subbank_start_w),
    .lookup_bundle_resp_group_len(token_lookup_bundle_resp_group_len_w),
    .lookup_bundle_resp_branch_mask(token_lookup_bundle_resp_branch_mask_w),
    .lookup_bundle_resp_is_shared(token_lookup_bundle_resp_is_shared_w),
    .lookup_bundle_resp_state(token_lookup_bundle_resp_state_w),
    .lookup_bundle_resp_entry_type(token_lookup_bundle_resp_entry_type_w),
    .commit_valid(token_commit_valid),
    .commit_index(token_commit_index),
    .commit_req_id(token_commit_req_id),
    .commit_branch_mask(token_commit_branch_mask),
    .commit_node_mask(token_commit_node_mask),
    .flush_valid(token_flush_valid_w),
    .flush_req_id(token_flush_req_id_w),
    .flush_branch_mask(token_flush_branch_mask_w),
    .flush_node_mask(token_flush_node_mask_w),
    .entry_count(token_entry_count),
    .error_flag(token_error_flag)
);

endmodule
