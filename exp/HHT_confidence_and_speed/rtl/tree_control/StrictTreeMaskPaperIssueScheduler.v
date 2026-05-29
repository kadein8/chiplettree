`timescale 1ns/1ps

`include "config/prediction_params.vh"
`include "config/interface_params.vh"
`include "config/memory_params.vh"
`include "config/model_params.vh"

/*
 * 文件作用：
 * 1. 这个模块实现论文 strict tree-mask 主路径里
 *    token_register -> issue bundle
 *    这段专用调度边界。
 * 2. 上游给它的是“本层 bundle 刚写入 token_register 的节点元数据”；
 *    这里先把 AGU 顺序吐出的单 slot 写回重新收齐成整层 bundle，
 *    再并行查询 token_register，最后拼成正式 compute descriptor。
 * 3. 下游后续将接到论文正式后端：
 *    pe arrays issue
 *      -> request_controller
 *      -> sram_subsystem
 *      -> request_controller(resp regroup)
 *      -> multicast_network
 *      -> pe arrays
 *    的正式并行计算后端。
 * 4. 当前阶段它先把论文要求的 descriptor 边界冻结下来，
 *    不在这里决定 PE arrays 的数值实现细节。
 */
module StrictTreeMaskPaperIssueScheduler #(
    parameter integer PRIVATE_DEPTH_W =
        (((`MAX_VERIFY_NODES_PER_BRANCH + 1) <= 2) ? 1 :
         $clog2(`MAX_VERIFY_NODES_PER_BRANCH + 1))
) (
    input                             clk,
    input                             rst_n,

    // src_bundle_*：
    // 来自 AGU/token_register 写入完成后的本层 bundle 元数据。
    input                             src_bundle_valid,
    output                            src_bundle_ready,
    input      [`REQ_ID_W-1:0]        src_bundle_req_id,
    input      [`TREE_FRONTIER_SLOTS-1:0] src_bundle_slot_valid,
    input      [`TREE_FRONTIER_SLOTS*`TOKEN_ID_W-1:0]
               src_bundle_token_id,
    input      [`TREE_FRONTIER_SLOTS*`POSITION_ID_W-1:0]
               src_bundle_position_id,
    input      [`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0]
               src_bundle_node_id,
    input      [`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0]
               src_bundle_parent_node_id,
    input      [`TREE_FRONTIER_SLOTS*`BRANCH_ID_W-1:0]
               src_bundle_branch_id,
    input      [`TREE_LEVEL_ID_W-1:0]  src_bundle_level_id,
    input      [4:0]                  src_bundle_slot_count,
    input      [15:0]                 src_bundle_prefix_len,
    input      [`TREE_FRONTIER_SLOTS-1:0] src_bundle_slot_tree_mask_en,
    input      [`TREE_FRONTIER_SLOTS*`MODEL_MAX_POS_EMB-1:0]
               src_bundle_slot_visible_mask,
    input      [`TREE_FRONTIER_SLOTS*PRIVATE_DEPTH_W-1:0]
               src_bundle_private_depth,

    // token_register lookup bundle 边界。
    output                            lookup_bundle_valid,
    input                             lookup_bundle_ready,
    output     [`REQ_ID_W-1:0]        lookup_bundle_req_id,
    output     [`TREE_FRONTIER_SLOTS-1:0] lookup_bundle_slot_valid,
    output     [`TREE_FRONTIER_SLOTS*`TOKEN_ID_W-1:0]
               lookup_bundle_token_id,
    output     [`TREE_FRONTIER_SLOTS*`POSITION_ID_W-1:0]
               lookup_bundle_position_id,
    input                             lookup_bundle_resp_valid,
    input      [`REQ_ID_W-1:0]        lookup_bundle_resp_req_id,
    input      [`TREE_FRONTIER_SLOTS-1:0] lookup_bundle_resp_hit,
    input      [`TREE_FRONTIER_SLOTS*`SRAM_ID_W-1:0]
               lookup_bundle_resp_sram_id,
    input      [`TREE_FRONTIER_SLOTS*`BANK_ID_W-1:0]
               lookup_bundle_resp_bank_id,
    input      [`TREE_FRONTIER_SLOTS*`SUBBANK_ID_W-1:0]
               lookup_bundle_resp_subbank_start,
    input      [`TREE_FRONTIER_SLOTS*`KV_GROUP_LEN_W-1:0]
               lookup_bundle_resp_group_len,
    input      [`TREE_FRONTIER_SLOTS*`BRANCH_MASK_W-1:0]
               lookup_bundle_resp_branch_mask,
    input      [`TREE_FRONTIER_SLOTS-1:0] lookup_bundle_resp_is_shared,
    input      [`TREE_FRONTIER_SLOTS*`TOKEN_STATE_W-1:0]
               lookup_bundle_resp_state,
    input      [`TREE_FRONTIER_SLOTS*`TOKEN_ENTRY_TYPE_W-1:0]
               lookup_bundle_resp_entry_type,

    // issue_bundle_*：
    // 这是论文后半段 compute path 的正式输入 bundle。
    output                            issue_bundle_valid,
    input                             issue_bundle_ready,
    output     [`REQ_ID_W-1:0]        issue_bundle_req_id,
    output     [`TREE_FRONTIER_SLOTS-1:0] issue_bundle_slot_valid,
    output     [`TREE_FRONTIER_SLOTS-1:0] issue_bundle_slot_lookup_hit,
    output     [`TREE_FRONTIER_SLOTS*`TOKEN_ID_W-1:0]
               issue_bundle_token_id,
    output     [`TREE_FRONTIER_SLOTS*`POSITION_ID_W-1:0]
               issue_bundle_position_id,
    output     [`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0]
               issue_bundle_node_id,
    output     [`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0]
               issue_bundle_parent_node_id,
    output     [`TREE_FRONTIER_SLOTS*`BRANCH_ID_W-1:0]
               issue_bundle_branch_id,
    output     [`TREE_LEVEL_ID_W-1:0]  issue_bundle_level_id,
    output     [4:0]                  issue_bundle_slot_count,
    output     [15:0]                 issue_bundle_prefix_len,
    output     [`TREE_FRONTIER_SLOTS-1:0] issue_bundle_slot_tree_mask_en,
    output     [`TREE_FRONTIER_SLOTS*`MODEL_MAX_POS_EMB-1:0]
               issue_bundle_slot_visible_mask,
    output     [`TREE_FRONTIER_SLOTS*PRIVATE_DEPTH_W-1:0]
               issue_bundle_private_depth,
    output     [`TREE_FRONTIER_SLOTS*`SRAM_ID_W-1:0]
               issue_bundle_sram_id,
    output     [`TREE_FRONTIER_SLOTS*`BANK_ID_W-1:0]
               issue_bundle_bank_id,
    output     [`TREE_FRONTIER_SLOTS*`SUBBANK_ID_W-1:0]
               issue_bundle_subbank_start,
    output     [`TREE_FRONTIER_SLOTS*`KV_GROUP_LEN_W-1:0]
               issue_bundle_group_len,
    output     [`TREE_FRONTIER_SLOTS*`BRANCH_MASK_W-1:0]
               issue_bundle_branch_mask,
    output     [`TREE_FRONTIER_SLOTS-1:0] issue_bundle_is_shared,
    output     [`TREE_FRONTIER_SLOTS*`TOKEN_STATE_W-1:0]
               issue_bundle_entry_state,
    output     [`TREE_FRONTIER_SLOTS*`TOKEN_ENTRY_TYPE_W-1:0]
               issue_bundle_entry_type,
    output     [`SRAM_ADDR_W-1:0]      issue_bundle_embedding_base_addr,
    output     [`SRAM_ADDR_W-1:0]      issue_bundle_hidden0_base_addr,
    output     [`SRAM_ADDR_W-1:0]      issue_bundle_hidden1_base_addr,
    output     [`SRAM_ADDR_W-1:0]      issue_bundle_final_base_addr,
    output     [`SRAM_ADDR_W-1:0]      issue_bundle_weight_sram_base_addr,
    output     [`SRAM_ADDR_W-1:0]      issue_bundle_kv_cache_base_addr,
    output     [`SRAM_ADDR_W-1:0]      issue_bundle_draft_kv_base_addr,
    output     [`HBM_ADDR_W-1:0]       issue_bundle_hbm_weight_base_addr,
    output     [`SRAM_ADDR_W-1:0]      issue_bundle_final_norm_gamma_addr,
    output     [`SRAM_ADDR_W-1:0]      issue_bundle_lm_head_weight_base_addr
);

// strict paper path 的 base/layout 口径不再允许使用低位占位常量。
// 这里统一改成“模型无关参数名 + 默认 profile 赋值”的方式：
// 1. scheduler 只负责把这些通用 layout 字段挂到 descriptor；
// 2. 真正的 profile 默认值收在 `model_params.vh`；
// 3. 后续切模型时只改基础参数，不在这里重写逻辑。

function [4:0] slot_popcount;
    input [`TREE_FRONTIER_SLOTS-1:0] slot_valid_in;
    integer slot_count_i;
    begin
        slot_popcount = 5'd0;
        for (slot_count_i = 0;
             slot_count_i < `TREE_FRONTIER_SLOTS;
             slot_count_i = slot_count_i + 1) begin
            if (slot_valid_in[slot_count_i]) begin
                slot_popcount = slot_popcount + 1'b1;
            end
        end
    end
endfunction

wire src_bundle_accept_w;
wire [`TREE_FRONTIER_SLOTS-1:0] merged_collect_slot_valid_w;
wire [`TREE_FRONTIER_SLOTS*`TOKEN_ID_W-1:0] merged_collect_token_id_w;
wire [`TREE_FRONTIER_SLOTS*`POSITION_ID_W-1:0] merged_collect_position_id_w;
wire [`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0] merged_collect_node_id_w;
wire [`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0] merged_collect_parent_node_id_w;
wire [`TREE_FRONTIER_SLOTS*`BRANCH_ID_W-1:0] merged_collect_branch_id_w;
wire [`TREE_FRONTIER_SLOTS*PRIVATE_DEPTH_W-1:0]
    merged_collect_private_depth_w;
wire [4:0] merged_collect_seen_count_w;

reg collect_pending_r;
reg [`REQ_ID_W-1:0] collect_req_id_r;
reg [`TREE_FRONTIER_SLOTS-1:0] collect_slot_valid_r;
reg [`TREE_FRONTIER_SLOTS*`TOKEN_ID_W-1:0] collect_token_id_r;
reg [`TREE_FRONTIER_SLOTS*`POSITION_ID_W-1:0] collect_position_id_r;
reg [`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0] collect_node_id_r;
reg [`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0] collect_parent_node_id_r;
reg [`TREE_FRONTIER_SLOTS*`BRANCH_ID_W-1:0] collect_branch_id_r;
reg [`TREE_LEVEL_ID_W-1:0] collect_level_id_r;
reg [4:0] collect_slot_count_r;
reg [15:0] collect_prefix_len_r;
reg [`TREE_FRONTIER_SLOTS-1:0] collect_slot_tree_mask_en_r;
reg [`TREE_FRONTIER_SLOTS*`MODEL_MAX_POS_EMB-1:0]
    collect_slot_visible_mask_r;
reg [`TREE_FRONTIER_SLOTS*PRIVATE_DEPTH_W-1:0] collect_private_depth_r;

reg lookup_pending_r;
reg lookup_launch_r;
reg issue_pending_r;
reg [`REQ_ID_W-1:0] pending_req_id_r;
reg [`TREE_FRONTIER_SLOTS-1:0] pending_slot_valid_r;
reg [`TREE_FRONTIER_SLOTS*`TOKEN_ID_W-1:0] pending_token_id_r;
reg [`TREE_FRONTIER_SLOTS*`POSITION_ID_W-1:0] pending_position_id_r;
reg [`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0] pending_node_id_r;
reg [`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0] pending_parent_node_id_r;
reg [`TREE_FRONTIER_SLOTS*`BRANCH_ID_W-1:0] pending_branch_id_r;
reg [`TREE_FRONTIER_SLOTS*PRIVATE_DEPTH_W-1:0] pending_private_depth_r;

reg [`REQ_ID_W-1:0] issue_bundle_req_id_r;
reg [`TREE_FRONTIER_SLOTS-1:0] issue_bundle_slot_valid_r;
reg [`TREE_FRONTIER_SLOTS-1:0] issue_bundle_slot_lookup_hit_r;
reg [`TREE_FRONTIER_SLOTS*`TOKEN_ID_W-1:0] issue_bundle_token_id_r;
reg [`TREE_FRONTIER_SLOTS*`POSITION_ID_W-1:0] issue_bundle_position_id_r;
reg [`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0] issue_bundle_node_id_r;
reg [`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0] issue_bundle_parent_node_id_r;
reg [`TREE_FRONTIER_SLOTS*`BRANCH_ID_W-1:0] issue_bundle_branch_id_r;
reg [`TREE_LEVEL_ID_W-1:0] issue_bundle_level_id_r;
reg [4:0] issue_bundle_slot_count_r;
reg [15:0] issue_bundle_prefix_len_r;
reg [`TREE_FRONTIER_SLOTS-1:0] issue_bundle_slot_tree_mask_en_r;
reg [`TREE_FRONTIER_SLOTS*`MODEL_MAX_POS_EMB-1:0]
    issue_bundle_slot_visible_mask_r;
reg [`TREE_FRONTIER_SLOTS*PRIVATE_DEPTH_W-1:0] issue_bundle_private_depth_r;
reg [`TREE_FRONTIER_SLOTS*`SRAM_ID_W-1:0] issue_bundle_sram_id_r;
reg [`TREE_FRONTIER_SLOTS*`BANK_ID_W-1:0] issue_bundle_bank_id_r;
reg [`TREE_FRONTIER_SLOTS*`SUBBANK_ID_W-1:0]
    issue_bundle_subbank_start_r;
reg [`TREE_FRONTIER_SLOTS*`KV_GROUP_LEN_W-1:0] issue_bundle_group_len_r;
reg [`TREE_FRONTIER_SLOTS*`BRANCH_MASK_W-1:0] issue_bundle_branch_mask_r;
reg [`TREE_FRONTIER_SLOTS-1:0] issue_bundle_is_shared_r;
reg [`TREE_FRONTIER_SLOTS*`TOKEN_STATE_W-1:0] issue_bundle_entry_state_r;
reg [`TREE_FRONTIER_SLOTS*`TOKEN_ENTRY_TYPE_W-1:0]
    issue_bundle_entry_type_r;

assign src_bundle_ready =
    !lookup_pending_r &&
    !lookup_launch_r &&
    !issue_pending_r &&
    (!collect_pending_r || (src_bundle_req_id == collect_req_id_r));
assign src_bundle_accept_w = src_bundle_valid && src_bundle_ready;

assign merged_collect_slot_valid_w =
    collect_pending_r ?
        (collect_slot_valid_r | src_bundle_slot_valid) :
        src_bundle_slot_valid;
assign merged_collect_token_id_w =
    collect_pending_r ?
        (collect_token_id_r | src_bundle_token_id) :
        src_bundle_token_id;
assign merged_collect_position_id_w =
    collect_pending_r ?
        (collect_position_id_r | src_bundle_position_id) :
        src_bundle_position_id;
assign merged_collect_node_id_w =
    collect_pending_r ?
        (collect_node_id_r | src_bundle_node_id) :
        src_bundle_node_id;
assign merged_collect_parent_node_id_w =
    collect_pending_r ?
        (collect_parent_node_id_r | src_bundle_parent_node_id) :
        src_bundle_parent_node_id;
assign merged_collect_branch_id_w =
    collect_pending_r ?
        (collect_branch_id_r | src_bundle_branch_id) :
        src_bundle_branch_id;
assign merged_collect_private_depth_w =
    collect_pending_r ?
        (collect_private_depth_r | src_bundle_private_depth) :
        src_bundle_private_depth;
assign merged_collect_seen_count_w =
    slot_popcount(merged_collect_slot_valid_w);

assign lookup_bundle_valid = lookup_launch_r;
assign lookup_bundle_req_id = pending_req_id_r;
assign lookup_bundle_slot_valid = pending_slot_valid_r;
assign lookup_bundle_token_id = pending_token_id_r;
assign lookup_bundle_position_id = pending_position_id_r;

assign issue_bundle_valid = issue_pending_r;
assign issue_bundle_req_id = issue_bundle_req_id_r;
assign issue_bundle_slot_valid = issue_bundle_slot_valid_r;
assign issue_bundle_slot_lookup_hit = issue_bundle_slot_lookup_hit_r;
assign issue_bundle_token_id = issue_bundle_token_id_r;
assign issue_bundle_position_id = issue_bundle_position_id_r;
assign issue_bundle_node_id = issue_bundle_node_id_r;
assign issue_bundle_parent_node_id = issue_bundle_parent_node_id_r;
assign issue_bundle_branch_id = issue_bundle_branch_id_r;
assign issue_bundle_level_id = issue_bundle_level_id_r;
assign issue_bundle_slot_count = issue_bundle_slot_count_r;
assign issue_bundle_prefix_len = issue_bundle_prefix_len_r;
assign issue_bundle_slot_tree_mask_en = issue_bundle_slot_tree_mask_en_r;
assign issue_bundle_slot_visible_mask = issue_bundle_slot_visible_mask_r;
assign issue_bundle_private_depth = issue_bundle_private_depth_r;
assign issue_bundle_sram_id = issue_bundle_sram_id_r;
assign issue_bundle_bank_id = issue_bundle_bank_id_r;
assign issue_bundle_subbank_start = issue_bundle_subbank_start_r;
assign issue_bundle_group_len = issue_bundle_group_len_r;
assign issue_bundle_branch_mask = issue_bundle_branch_mask_r;
assign issue_bundle_is_shared = issue_bundle_is_shared_r;
assign issue_bundle_entry_state = issue_bundle_entry_state_r;
assign issue_bundle_entry_type = issue_bundle_entry_type_r;
assign issue_bundle_embedding_base_addr = `MODEL_EMB_BASE;
assign issue_bundle_hidden0_base_addr = `MODEL_WORK_HIDDEN0_BASE;
assign issue_bundle_hidden1_base_addr = `MODEL_WORK_HIDDEN1_BASE;
assign issue_bundle_final_base_addr = `MODEL_WORK_FINAL_BASE;
assign issue_bundle_weight_sram_base_addr = `MODEL_WEIGHT_SRAM_BASE;
assign issue_bundle_kv_cache_base_addr = `KV_COMMITTED_BASE;
assign issue_bundle_draft_kv_base_addr = `KV_DRAFT_BASE_MIN;
assign issue_bundle_hbm_weight_base_addr = `MODEL_HBM_WEIGHT_BASE;
assign issue_bundle_final_norm_gamma_addr = `MODEL_FINAL_NORM_GAMMA_ADDR;
assign issue_bundle_lm_head_weight_base_addr = `MODEL_LM_HEAD_WEIGHT_BASE;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        collect_pending_r <= 1'b0;
        collect_req_id_r <= {`REQ_ID_W{1'b0}};
        collect_slot_valid_r <= {`TREE_FRONTIER_SLOTS{1'b0}};
        collect_token_id_r <= {(`TREE_FRONTIER_SLOTS*`TOKEN_ID_W){1'b0}};
        collect_position_id_r <=
            {(`TREE_FRONTIER_SLOTS*`POSITION_ID_W){1'b0}};
        collect_node_id_r <= {(`TREE_FRONTIER_SLOTS*`NODE_ID_W){1'b0}};
        collect_parent_node_id_r <=
            {(`TREE_FRONTIER_SLOTS*`NODE_ID_W){1'b0}};
        collect_branch_id_r <= {(`TREE_FRONTIER_SLOTS*`BRANCH_ID_W){1'b0}};
        collect_level_id_r <= {`TREE_LEVEL_ID_W{1'b0}};
        collect_slot_count_r <= 5'd0;
        collect_prefix_len_r <= 16'd0;
        collect_slot_tree_mask_en_r <= {`TREE_FRONTIER_SLOTS{1'b0}};
        collect_slot_visible_mask_r <=
            {(`TREE_FRONTIER_SLOTS*`MODEL_MAX_POS_EMB){1'b0}};
        collect_private_depth_r <=
            {(`TREE_FRONTIER_SLOTS*PRIVATE_DEPTH_W){1'b0}};
        lookup_pending_r <= 1'b0;
        lookup_launch_r <= 1'b0;
        issue_pending_r <= 1'b0;
        pending_req_id_r <= {`REQ_ID_W{1'b0}};
        pending_slot_valid_r <= {`TREE_FRONTIER_SLOTS{1'b0}};
        pending_token_id_r <= {(`TREE_FRONTIER_SLOTS*`TOKEN_ID_W){1'b0}};
        pending_position_id_r <=
            {(`TREE_FRONTIER_SLOTS*`POSITION_ID_W){1'b0}};
        pending_node_id_r <= {(`TREE_FRONTIER_SLOTS*`NODE_ID_W){1'b0}};
        pending_parent_node_id_r <=
            {(`TREE_FRONTIER_SLOTS*`NODE_ID_W){1'b0}};
        pending_branch_id_r <= {(`TREE_FRONTIER_SLOTS*`BRANCH_ID_W){1'b0}};
        pending_private_depth_r <=
            {(`TREE_FRONTIER_SLOTS*PRIVATE_DEPTH_W){1'b0}};
        issue_bundle_req_id_r <= {`REQ_ID_W{1'b0}};
        issue_bundle_slot_valid_r <= {`TREE_FRONTIER_SLOTS{1'b0}};
        issue_bundle_slot_lookup_hit_r <= {`TREE_FRONTIER_SLOTS{1'b0}};
        issue_bundle_token_id_r <= {(`TREE_FRONTIER_SLOTS*`TOKEN_ID_W){1'b0}};
        issue_bundle_position_id_r <=
            {(`TREE_FRONTIER_SLOTS*`POSITION_ID_W){1'b0}};
        issue_bundle_node_id_r <= {(`TREE_FRONTIER_SLOTS*`NODE_ID_W){1'b0}};
        issue_bundle_parent_node_id_r <=
            {(`TREE_FRONTIER_SLOTS*`NODE_ID_W){1'b0}};
        issue_bundle_branch_id_r <=
            {(`TREE_FRONTIER_SLOTS*`BRANCH_ID_W){1'b0}};
        issue_bundle_level_id_r <= {`TREE_LEVEL_ID_W{1'b0}};
        issue_bundle_slot_count_r <= 5'd0;
        issue_bundle_prefix_len_r <= 16'd0;
        issue_bundle_slot_tree_mask_en_r <= {`TREE_FRONTIER_SLOTS{1'b0}};
        issue_bundle_slot_visible_mask_r <=
            {(`TREE_FRONTIER_SLOTS*`MODEL_MAX_POS_EMB){1'b0}};
        issue_bundle_private_depth_r <=
            {(`TREE_FRONTIER_SLOTS*PRIVATE_DEPTH_W){1'b0}};
        issue_bundle_sram_id_r <= {(`TREE_FRONTIER_SLOTS*`SRAM_ID_W){1'b0}};
        issue_bundle_bank_id_r <= {(`TREE_FRONTIER_SLOTS*`BANK_ID_W){1'b0}};
        issue_bundle_subbank_start_r <=
            {(`TREE_FRONTIER_SLOTS*`SUBBANK_ID_W){1'b0}};
        issue_bundle_group_len_r <=
            {(`TREE_FRONTIER_SLOTS*`KV_GROUP_LEN_W){1'b0}};
        issue_bundle_branch_mask_r <=
            {(`TREE_FRONTIER_SLOTS*`BRANCH_MASK_W){1'b0}};
        issue_bundle_is_shared_r <= {`TREE_FRONTIER_SLOTS{1'b0}};
        issue_bundle_entry_state_r <=
            {(`TREE_FRONTIER_SLOTS*`TOKEN_STATE_W){1'b0}};
        issue_bundle_entry_type_r <=
            {(`TREE_FRONTIER_SLOTS*`TOKEN_ENTRY_TYPE_W){1'b0}};
    end else begin
        lookup_launch_r <= 1'b0;

        if (issue_pending_r && issue_bundle_ready) begin
            issue_pending_r <= 1'b0;
        end

        if (src_bundle_accept_w) begin
            collect_req_id_r <= src_bundle_req_id;
            collect_slot_valid_r <= merged_collect_slot_valid_w;
            collect_token_id_r <= merged_collect_token_id_w;
            collect_position_id_r <= merged_collect_position_id_w;
            collect_node_id_r <= merged_collect_node_id_w;
            collect_parent_node_id_r <= merged_collect_parent_node_id_w;
            collect_branch_id_r <= merged_collect_branch_id_w;
            collect_level_id_r <=
                collect_pending_r ? collect_level_id_r : src_bundle_level_id;
            collect_slot_count_r <=
                collect_pending_r ? collect_slot_count_r : src_bundle_slot_count;
            collect_prefix_len_r <=
                collect_pending_r ? collect_prefix_len_r : src_bundle_prefix_len;
            collect_slot_tree_mask_en_r <=
                collect_pending_r ?
                    (collect_slot_tree_mask_en_r |
                     src_bundle_slot_tree_mask_en) :
                    src_bundle_slot_tree_mask_en;
            collect_slot_visible_mask_r <=
                collect_pending_r ?
                    (collect_slot_visible_mask_r |
                     src_bundle_slot_visible_mask) :
                    src_bundle_slot_visible_mask;
            collect_private_depth_r <= merged_collect_private_depth_w;
            collect_pending_r <= 1'b1;

            if (merged_collect_seen_count_w ==
                (collect_pending_r ? collect_slot_count_r : src_bundle_slot_count)) begin
                lookup_pending_r <= 1'b1;
                lookup_launch_r <= lookup_bundle_ready;
                collect_pending_r <= 1'b0;
                pending_req_id_r <= src_bundle_req_id;
                pending_slot_valid_r <= merged_collect_slot_valid_w;
                pending_token_id_r <= merged_collect_token_id_w;
                pending_position_id_r <= merged_collect_position_id_w;
                pending_node_id_r <= merged_collect_node_id_w;
                pending_branch_id_r <= merged_collect_branch_id_w;
                if (collect_pending_r) begin
                    pending_parent_node_id_r <= merged_collect_parent_node_id_w;
                    pending_private_depth_r <= merged_collect_private_depth_w;
                end else begin
                    pending_parent_node_id_r <= src_bundle_parent_node_id;
                    pending_private_depth_r <= src_bundle_private_depth;
                end
            end
        end

        if (lookup_pending_r &&
            lookup_bundle_resp_valid &&
            (lookup_bundle_resp_req_id == pending_req_id_r)) begin
            lookup_pending_r <= 1'b0;
            issue_pending_r <= 1'b1;
            issue_bundle_req_id_r <= pending_req_id_r;
            issue_bundle_slot_valid_r <= pending_slot_valid_r;
            issue_bundle_slot_lookup_hit_r <= lookup_bundle_resp_hit;
            issue_bundle_token_id_r <= pending_token_id_r;
            issue_bundle_position_id_r <= pending_position_id_r;
            issue_bundle_node_id_r <= pending_node_id_r;
            issue_bundle_parent_node_id_r <= pending_parent_node_id_r;
            issue_bundle_branch_id_r <= pending_branch_id_r;
            issue_bundle_level_id_r <= collect_level_id_r;
            issue_bundle_slot_count_r <= collect_slot_count_r;
            issue_bundle_prefix_len_r <= collect_prefix_len_r;
            issue_bundle_slot_tree_mask_en_r <= collect_slot_tree_mask_en_r;
            issue_bundle_slot_visible_mask_r <= collect_slot_visible_mask_r;
            issue_bundle_private_depth_r <= pending_private_depth_r;
            issue_bundle_sram_id_r <= lookup_bundle_resp_sram_id;
            issue_bundle_bank_id_r <= lookup_bundle_resp_bank_id;
            issue_bundle_subbank_start_r <= lookup_bundle_resp_subbank_start;
            issue_bundle_group_len_r <= lookup_bundle_resp_group_len;
            issue_bundle_branch_mask_r <= lookup_bundle_resp_branch_mask;
            issue_bundle_is_shared_r <= lookup_bundle_resp_is_shared;
            issue_bundle_entry_state_r <= lookup_bundle_resp_state;
            issue_bundle_entry_type_r <= lookup_bundle_resp_entry_type;
        end
    end
end

endmodule
