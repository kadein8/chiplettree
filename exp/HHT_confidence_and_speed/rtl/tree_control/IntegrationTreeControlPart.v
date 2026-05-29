`include "config/interface_params.vh"
`include "config/memory_params.vh"
`include "config/model_params.vh"
`timescale 1ns/1ps

/*
 * 文件作用：
 * 1. 本文件实现论文 TreeControl 主控里的“发射整合器”。
 * 2. 它把前端送来的预测/节点信息整理成统一的 issue 请求，并在需要时挂接
 *    stale KV 的重算补救路径。
 * 3. 在论文完整路径里，它位于：
 *    NativeTreeMainFrontend
 *      -> IntegrationTreeControlPart
 *      -> issue / prep_req / recompute_req
 *      -> 下游算子、KV 状态表、重算控制
 * 4. 从职责上看，它不是做树解析的模块，而是把“一个待发节点”翻译成：
 *    - 是否可以直接发射给后端算子；
 *    - 是否要先走 recompute；
 *    - KVLocationTable / KVStateTable 是否已有可复用位置。
 * 5. 当前 frozen strict tree-mask 主路径会绕过这条论文式串行前端，但本文件依旧
 *    代表论文 TreeControl 在“逐节点 issue 与 stale 修复衔接处”的标准语义。
 */
module IntegrationTreeControlPart #(
    parameter CFG_W = 32,
    parameter MODEL_ID_W = 8,
    parameter OP_CLASS_W = 8,
    parameter TOKEN_LEN_W = 16,
    parameter CONF_W = 8,
    parameter PRED_SOURCE_ID_W = 3,
    parameter ENABLE_PREDICTION_INPUT = 0,
    parameter ENABLE_RECOMPUTE_PATH = 0,
    parameter [`POSITION_ID_W-1:0] CURRENT_POSITION = {`POSITION_ID_W{1'b0}},
    parameter [`POSITION_ID_W-1:0] RECENCY_TH = 12'd16,
    parameter [`KV_GROUP_LEN_W-1:0] RECOMPUTE_KV_GROUP_LEN = `KV_GROUP_SIZE_SUBBANK,
    parameter [`REQ_ID_W-1:0] RECOMPUTE_KV_WRITE_REQ_ID = 4'h9,
    parameter [`TOKEN_ID_W-1:0] ISSUE_TOKEN_ID = 16'h2401,
    parameter [`BRANCH_ID_W-1:0] ISSUE_BRANCH_ID = {`BRANCH_ID_W{1'b0}},
    parameter [1:0] ISSUE_EPOCH = 2'b01,
    parameter [MODEL_ID_W-1:0] ISSUE_MODEL_ID = 8'h21,
    parameter [OP_CLASS_W-1:0] ISSUE_OP_CLASS = 8'h31,
    parameter [`SRAM_ADDR_W-1:0] ISSUE_SRC_ADDR = {2'd0, 4'd1, 5'd3, 8'h02, 4'h0},
    parameter [`SRAM_ADDR_W-1:0] ISSUE_DST_ADDR = {2'd0, 4'd1, 5'd4, 8'h03, 4'h0},
    parameter [TOKEN_LEN_W-1:0] ISSUE_TOKEN_LEN = 16'd1,
    parameter [`REQ_ID_W-1:0] ISSUE_REQ_ID = 4'h6,
    parameter [1:0] ISSUE_FLUSH_EPOCH = 2'b00,
    parameter ISSUE_TREE_MASK_EN = 0,
    parameter [15:0] ISSUE_PREFIX_LEN = 16'd0
) (
    // 时钟、复位与会话启动控制。
    input                         clk,
    input                         rst_n,
    input  [CFG_W-1:0]            cfg_data,
    input                         cfg_valid,
    input                         start,

    // 对上游暴露的忙闲与错误状态。
    output                        busy,
    output                        error_flag,

    // 预测输入：
    // 来自 NativeTreeMainFrontend 的逐 slot 节点描述。
    input                         pred_valid,
    output                        pred_ready,
    input  [PRED_SOURCE_ID_W-1:0] pred_source_id,
    input  [`NODE_ID_W-1:0]       pred_parent_node_id,
    input  [`TOKEN_ID_W-1:0]      pred_token_id,
    input  [`TOKEN_ID_W-1:0]      pred_referenced_token_id,
    input  [`POSITION_ID_W-1:0]   pred_referenced_position,
    input  [`POSITION_ID_W-1:0]   pred_issue_position,
    input  [CONF_W-1:0]           pred_confidence,
    input                         pred_is_last_in_window,
    input  [`BRANCH_ID_W-1:0]     pred_branch_id,
    input                         pred_tree_mask_en,
    input  [15:0]                 pred_prefix_len,
    input  [`TOY_MAX_POS_EMB-1:0] pred_visible_mask,

    // issue 输出：
    // 向后端算子/控制器发射一个规范化后的节点执行请求。
    output                        issue_valid,
    input                         issue_ready,
    output [`TOKEN_ID_W-1:0]      issue_token_id,
    output [`BRANCH_ID_W-1:0]     issue_branch_id,
    output [1:0]                  issue_epoch,
    output [MODEL_ID_W-1:0]       issue_model_id,
    output [OP_CLASS_W-1:0]       issue_op_class,
    output [`SRAM_ADDR_W-1:0]     issue_src_addr,
    output [`SRAM_ADDR_W-1:0]     issue_dst_addr,
    output [TOKEN_LEN_W-1:0]      issue_token_len,
    output [`REQ_ID_W-1:0]        issue_req_id,
    output [1:0]                  issue_flush_epoch,
    output [`NODE_ID_W-1:0]       issue_parent_node_id,
    output [CONF_W-1:0]           issue_confidence,
    output                        issue_tree_mask_en,
    output [`BRANCH_ID_W-1:0]     issue_tree_mask_branch_id,
    output [15:0]                 issue_prefix_len,
    output [`TOY_MAX_POS_EMB-1:0] issue_visible_mask,
    output [`POSITION_ID_W-1:0]   issue_position,
    output                        issue_position_ovr,

    // prep 写口：
    // stale 重算时可能需要把补算得到的 KV 结果预写回 committed 区。
    output                        prep_req_valid,
    input                         prep_req_ready,
    output                        prep_req_write,
    output [`SRAM_ADDR_W-1:0]     prep_req_addr,
    output [`SRAM_WDATA_W-1:0]    prep_req_wdata,
    output [`REQ_ID_W-1:0]        prep_req_id,

    // 发给重算控制器的请求。
    output                        recompute_req_valid,
    input                         recompute_req_ready,
    output [`TOKEN_ID_W-1:0]      recompute_req_token_id,
    output [`POSITION_ID_W-1:0]   recompute_req_current_position,
    output [`POSITION_ID_W-1:0]   recompute_req_referenced_position,
    output [`BRANCH_ID_W-1:0]     recompute_req_branch_id,
    output                        recompute_req_reason_stale,

    // 重算响应返回：
    // 表示补算流水线是否已经产出部分/完整 KV。
    input                         recompute_resp_valid,
    output                        recompute_resp_ready,
    input                         recompute_resp_partial,
    input  [`REQ_ID_W-1:0]        recompute_resp_req_id,
    input                         recompute_resp_full,
    input  [`SRAM_WDATA_W-1:0]    recompute_resp_kv_data,
    input                         recompute_resp_last,

    // 外部对 KV 状态表的查表接口。
    input                         kv_lookup_valid,
    input  [`TOKEN_ID_W-1:0]      kv_lookup_token_id,
    input  [`POSITION_ID_W-1:0]   kv_lookup_position_id,
    output                        kv_lookup_ready,
    output                        kv_lookup_hit,
    output                        kv_lookup_partial_ready,
    output                        kv_lookup_full_ready,
    output [`SRAM_ID_W-1:0]       kv_lookup_sram_id,
    output [`BANK_ID_W-1:0]       kv_lookup_bank_id,
    output [`SUBBANK_ID_W-1:0]    kv_lookup_subbank_start,
    output [`KV_GROUP_LEN_W-1:0]  kv_lookup_group_len,
    output                        debug_stale_hit,
    output                        debug_recompute_busy,
    output                        debug_recompute_done,

    // 下游 writeback 完成反馈。
    input                         wb_done,
    input                         wb_error,
    input  [`TOKEN_ID_W-1:0]      wb_token_id
);

// 状态机语义：
// ST_IDLE                : 等待 cfg/start 启动一次发射流程。
// ST_WAIT_PRED           : 等待前端真正送来一个 pred 节点。
// ST_START_RECOMP        : 判定 stale 后，向 RecomputeControl 发起 start。
// ST_WAIT_RECOMP_RELEASE : 等待重算控制器允许当前节点继续 issue。
// ST_ISSUE               : 把当前节点通过 issue_* 总线送给下游。
// ST_WAIT_WB             : 等待对应 token 的 writeback 完成。
// ST_WAIT_RECOMP_FULL    : issue 已结束，但后台重算仍未完全落表，继续等补算收尾。
localparam [2:0]
    ST_IDLE = 3'd0,
    ST_WAIT_PRED = 3'd1,
    ST_START_RECOMP = 3'd2,
    ST_WAIT_RECOMP_RELEASE = 3'd3,
    ST_ISSUE = 3'd4,
    ST_WAIT_WB = 3'd5,
    ST_WAIT_RECOMP_FULL = 3'd6;

// 主状态与本次节点执行上下文锁存。
reg [2:0] state_r;
reg error_flag_r;
reg pred_stale_r;
reg pred_recompute_pending_r;
reg recompute_full_done_r;

// 锁存当前节点的预测元数据。
reg [PRED_SOURCE_ID_W-1:0] pred_source_id_r;
reg [`NODE_ID_W-1:0] pred_parent_node_id_r;
reg [`TOKEN_ID_W-1:0] pred_token_id_r;
reg [`TOKEN_ID_W-1:0] pred_referenced_token_id_r;
reg [`POSITION_ID_W-1:0] pred_referenced_position_r;
reg pred_issue_position_valid_r;
reg [`POSITION_ID_W-1:0] pred_issue_position_r;
reg [CONF_W-1:0] pred_confidence_r;
reg pred_is_last_in_window_r;
reg [`BRANCH_ID_W-1:0] pred_branch_id_r;
reg pred_tree_mask_en_r;
reg [15:0] pred_prefix_len_r;
reg [`TOY_MAX_POS_EMB-1:0] pred_visible_mask_r;

// 一拍级握手与当前活动 token。
wire start_fire_w;
wire pred_fire_w;
wire issue_fire_w;
wire wb_done_match_w;
wire [`TOKEN_ID_W-1:0] active_token_id_w;

// stale 判定相关中间量。
wire [`POSITION_ID_W-1:0] pred_age_w;
wire pred_stale_now_w;

// recompute 路径相关中间量。
wire recompute_start_valid_w;
wire recompute_start_ready_w;
wire recompute_start_fire_w;
wire recompute_prep_req_valid_w;
wire recompute_prep_req_write_w;
wire [`SRAM_ADDR_W-1:0] recompute_prep_req_addr_w;
wire [`SRAM_WDATA_W-1:0] recompute_prep_req_wdata_w;
wire [`REQ_ID_W-1:0] recompute_prep_req_id_w;
wire recompute_req_valid_w;
wire [`TOKEN_ID_W-1:0] recompute_req_token_id_w;
wire [`POSITION_ID_W-1:0] recompute_req_current_position_w;
wire [`POSITION_ID_W-1:0] recompute_req_referenced_position_w;
wire [`BRANCH_ID_W-1:0] recompute_req_branch_id_w;
wire recompute_req_reason_stale_w;
wire recompute_resp_ready_w;
wire kv_loc_wr_valid_w;
wire kv_state_wr_valid_w;
wire [`TOKEN_ID_W-1:0] kv_wr_token_id_w;
wire [`POSITION_ID_W-1:0] kv_wr_position_id_w;
wire [`SRAM_ID_W-1:0] kv_wr_sram_id_w;
wire [`BANK_ID_W-1:0] kv_wr_bank_id_w;
wire [`SUBBANK_ID_W-1:0] kv_wr_subbank_start_w;
wire [`KV_GROUP_LEN_W-1:0] kv_wr_group_len_w;
wire kv_wr_partial_ready_w;
wire kv_wr_full_ready_w;
wire recompute_issue_release_w;
wire recompute_busy_w;
wire recompute_done_w;

// KV 查表相关中间量：
// 普通 lookup 给外部使用，tree_lookup 给“当前 pred 是否 stale 且是否已有完整
// committed KV”这一路快速判定使用。
wire kv_loc_lookup_ready_w;
wire kv_loc_lookup_hit_w;
wire [`SRAM_ID_W-1:0] kv_loc_lookup_sram_id_w;
wire [`BANK_ID_W-1:0] kv_loc_lookup_bank_id_w;
wire [`SUBBANK_ID_W-1:0] kv_loc_lookup_subbank_start_w;
wire [`KV_GROUP_LEN_W-1:0] kv_loc_lookup_group_len_w;
wire kv_state_lookup_ready_w;
wire kv_state_lookup_hit_w;
wire kv_state_lookup_partial_ready_w;
wire kv_state_lookup_full_ready_w;
wire tree_kv_lookup_valid_w;
wire tree_kv_loc_lookup_ready_w;
wire tree_kv_loc_lookup_hit_w;
wire [`SRAM_ID_W-1:0] tree_kv_loc_lookup_sram_id_w;
wire [`BANK_ID_W-1:0] tree_kv_loc_lookup_bank_id_w;
wire [`SUBBANK_ID_W-1:0] tree_kv_loc_lookup_subbank_start_w;
wire [`KV_GROUP_LEN_W-1:0] tree_kv_loc_lookup_group_len_w;
wire tree_kv_state_lookup_ready_w;
wire tree_kv_state_lookup_hit_w;
wire tree_kv_state_lookup_partial_ready_w;
wire tree_kv_state_lookup_full_ready_w;
wire tree_kv_full_ready_hit_w;
wire [`BRANCH_ID_W-1:0] effective_pred_branch_id_w;
wire effective_pred_tree_mask_en_w;
wire [15:0] effective_pred_prefix_len_w;
wire [`TOY_MAX_POS_EMB-1:0] effective_pred_visible_mask_w;
wire [`POSITION_ID_W-1:0] effective_pred_issue_position_w;
wire effective_pred_issue_position_valid_w;
wire [`POSITION_ID_W-1:0] effective_pred_current_position_w;

// 根据当前位置生成因果可见掩码。
// 当 tree-mask 节点没有显式 visible_mask 时，用这个函数补出“看到自己及之前位置”
// 的最基本 causal mask。
function automatic [`TOY_MAX_POS_EMB-1:0] causal_visible_mask_of;
    input [`POSITION_ID_W-1:0] position_in;
    integer mask_idx_i;
    begin
        causal_visible_mask_of = {`TOY_MAX_POS_EMB{1'b0}};
        for (mask_idx_i = 0;
             mask_idx_i < `TOY_MAX_POS_EMB;
             mask_idx_i = mask_idx_i + 1) begin
            // 小于等于当前 position 的历史位置均可见。
            if (mask_idx_i <= position_in)
                causal_visible_mask_of[mask_idx_i] = 1'b1;
        end
    end
endfunction

// 基础握手定义。
assign start_fire_w = cfg_valid && start && (state_r == ST_IDLE);
assign pred_ready = ENABLE_PREDICTION_INPUT && (state_r == ST_WAIT_PRED);
assign pred_fire_w = pred_valid && pred_ready;
assign issue_valid = (state_r == ST_ISSUE);
assign issue_fire_w = issue_valid && issue_ready;

// active_token_id_w 表示这一轮最终等待 wb_done 的 token。
// 预测模式下来自 pred，固定模式下来自参数 ISSUE_TOKEN_ID。
assign active_token_id_w =
    ENABLE_PREDICTION_INPUT ? pred_token_id_r : ISSUE_TOKEN_ID;

// wb_done 必须和当前活动 token 对上，才能结束当前节点事务。
assign wb_done_match_w = wb_done && (wb_token_id == active_token_id_w);

// 顶层状态输出。
assign busy = (state_r != ST_IDLE);
assign error_flag = error_flag_r;

// 以下是“预测输入清洗”逻辑：
// pred_* 里某些字段在测试/占位场景下可能是 x/z，这里统一折算成可执行值。

// branch_id 缺省时回退到 pred_source_id 的低位，保证每个节点仍能落到一个分支槽。
assign effective_pred_branch_id_w =
    ((pred_branch_id === {`BRANCH_ID_W{1'bx}}) ||
     (pred_branch_id === {`BRANCH_ID_W{1'bz}})) ?
        pred_source_id[`BRANCH_ID_W-1:0] :
        pred_branch_id;

// tree_mask_en 缺省时，退化为“最后一个窗口节点启用 mask”的保守策略。
assign effective_pred_tree_mask_en_w =
    ((pred_tree_mask_en === 1'b0) || (pred_tree_mask_en === 1'b1)) ?
        pred_tree_mask_en :
        pred_is_last_in_window;

// prefix_len 缺省时退回静态参数。
assign effective_pred_prefix_len_w =
    ((pred_prefix_len === 16'hxxxx) || (pred_prefix_len === 16'hzzzz)) ?
        ISSUE_PREFIX_LEN :
        pred_prefix_len;

// issue_position 若未知，说明该节点没有显式覆盖位置。
assign effective_pred_issue_position_valid_w =
    ((pred_issue_position === 16'hxxxx) || (pred_issue_position === 16'hzzzz)) ?
        1'b0 :
        1'b1;

// 没有显式 issue_position 时，退回 referenced_position。
assign effective_pred_issue_position_w =
    effective_pred_issue_position_valid_w ?
        pred_issue_position :
        pred_referenced_position;

// stale 年龄计算使用“当前真正执行位置”，若无覆盖就回退到 CURRENT_POSITION。
assign effective_pred_current_position_w =
    effective_pred_issue_position_valid_w ?
        effective_pred_issue_position_w :
        CURRENT_POSITION;

// 可见性掩码处理：
// 1. 非 tree-mask 节点直接输出 0，表示沿用普通串行语义。
// 2. tree-mask 节点若没给显式 mask，则用因果 mask 自动生成。
assign effective_pred_visible_mask_w =
    effective_pred_tree_mask_en_w ?
        ((pred_visible_mask == {`TOY_MAX_POS_EMB{1'b0}}) ?
            causal_visible_mask_of(effective_pred_issue_position_w) :
            pred_visible_mask) :
        {`TOY_MAX_POS_EMB{1'b0}};

// 节点引用位置距离当前位置的“年龄”。
assign pred_age_w =
    (effective_pred_current_position_w >= pred_referenced_position) ?
        (effective_pred_current_position_w - pred_referenced_position) :
        {`POSITION_ID_W{1'b0}};

// stale 判定：
// 只有启用 prediction + recompute 时，且年龄超过阈值，才认为它需要补算。
assign pred_stale_now_w =
    ENABLE_PREDICTION_INPUT &&
    ENABLE_RECOMPUTE_PATH &&
    (pred_age_w >= RECENCY_TH);

// 对“当前待接收的 pred”做一拍前视查表，看看它引用的 token/position 是否已有完整 KV。
assign tree_kv_lookup_valid_w =
    ENABLE_PREDICTION_INPUT &&
    ENABLE_RECOMPUTE_PATH &&
    (state_r == ST_WAIT_PRED) &&
    pred_valid &&
    pred_stale_now_w;

// location 表命中 + state 表 full_ready 命中，才算“现成 committed KV 可以直接复用”。
assign tree_kv_full_ready_hit_w =
    tree_kv_loc_lookup_hit_w &&
    tree_kv_state_lookup_hit_w &&
    tree_kv_state_lookup_full_ready_w;

// issue_* 输出整理：
// 预测模式使用锁存的 pred 元数据；固定模式使用 module parameter 构造一个静态 issue。
assign issue_token_id = active_token_id_w;
assign issue_branch_id =
    ENABLE_PREDICTION_INPUT ? pred_branch_id_r : ISSUE_BRANCH_ID;
assign issue_epoch = ISSUE_EPOCH;
assign issue_model_id = ISSUE_MODEL_ID;
assign issue_op_class = ISSUE_OP_CLASS;
assign issue_src_addr = ISSUE_SRC_ADDR;
assign issue_dst_addr = ISSUE_DST_ADDR;
assign issue_token_len = ISSUE_TOKEN_LEN;
assign issue_req_id = ISSUE_REQ_ID;
assign issue_flush_epoch = ISSUE_FLUSH_EPOCH;
assign issue_parent_node_id =
    ENABLE_PREDICTION_INPUT ? pred_parent_node_id_r : {`NODE_ID_W{1'b0}};
assign issue_confidence =
    ENABLE_PREDICTION_INPUT ? pred_confidence_r : {CONF_W{1'b0}};
assign issue_tree_mask_en =
    ENABLE_PREDICTION_INPUT ? pred_tree_mask_en_r : ISSUE_TREE_MASK_EN;
assign issue_tree_mask_branch_id =
    ENABLE_PREDICTION_INPUT ?
        pred_branch_id_r :
        ISSUE_BRANCH_ID;
assign issue_prefix_len =
    ENABLE_PREDICTION_INPUT ? pred_prefix_len_r : ISSUE_PREFIX_LEN;
assign issue_visible_mask =
    ENABLE_PREDICTION_INPUT ?
        pred_visible_mask_r :
        causal_visible_mask_of(CURRENT_POSITION);
assign issue_position =
    ENABLE_PREDICTION_INPUT ? pred_issue_position_r : CURRENT_POSITION;
assign issue_position_ovr =
    ENABLE_PREDICTION_INPUT ?
        pred_issue_position_valid_r :
        1'b0;

// recompute start 仅在状态机进入 ST_START_RECOMP 时拉高。
assign recompute_start_valid_w =
    ENABLE_RECOMPUTE_PATH && (state_r == ST_START_RECOMP);
assign recompute_start_fire_w =
    recompute_start_valid_w && recompute_start_ready_w;

// prep_req / recompute_req / recompute_resp_ready 都受 ENABLE_RECOMPUTE_PATH 总开关控制，
// 未启用时统一返回 0，避免未使用路径带来 X 传播。
assign prep_req_valid =
    ENABLE_RECOMPUTE_PATH ? recompute_prep_req_valid_w : 1'b0;
assign prep_req_write =
    ENABLE_RECOMPUTE_PATH ? recompute_prep_req_write_w : 1'b0;
assign prep_req_addr =
    ENABLE_RECOMPUTE_PATH ? recompute_prep_req_addr_w : {`SRAM_ADDR_W{1'b0}};
assign prep_req_wdata =
    ENABLE_RECOMPUTE_PATH ? recompute_prep_req_wdata_w : {`SRAM_WDATA_W{1'b0}};
assign prep_req_id =
    ENABLE_RECOMPUTE_PATH ? recompute_prep_req_id_w : {`REQ_ID_W{1'b0}};

assign recompute_req_valid =
    ENABLE_RECOMPUTE_PATH ? recompute_req_valid_w : 1'b0;
assign recompute_req_token_id =
    ENABLE_RECOMPUTE_PATH ? recompute_req_token_id_w : {`TOKEN_ID_W{1'b0}};
assign recompute_req_current_position =
    ENABLE_RECOMPUTE_PATH ? recompute_req_current_position_w : {`POSITION_ID_W{1'b0}};
assign recompute_req_referenced_position =
    ENABLE_RECOMPUTE_PATH ? recompute_req_referenced_position_w : {`POSITION_ID_W{1'b0}};
assign recompute_req_branch_id =
    ENABLE_RECOMPUTE_PATH ? recompute_req_branch_id_w : {`BRANCH_ID_W{1'b0}};
assign recompute_req_reason_stale =
    ENABLE_RECOMPUTE_PATH ? recompute_req_reason_stale_w : 1'b0;
assign recompute_resp_ready =
    ENABLE_RECOMPUTE_PATH ? recompute_resp_ready_w : 1'b0;

// 外部 KV lookup 结果需要 location/state 两张表同时认可才算命中。
assign kv_lookup_ready = kv_loc_lookup_ready_w && kv_state_lookup_ready_w;
assign kv_lookup_hit = kv_loc_lookup_hit_w && kv_state_lookup_hit_w;
assign kv_lookup_partial_ready =
    (kv_loc_lookup_hit_w && kv_state_lookup_hit_w) ?
        kv_state_lookup_partial_ready_w : 1'b0;
assign kv_lookup_full_ready =
    (kv_loc_lookup_hit_w && kv_state_lookup_hit_w) ?
        kv_state_lookup_full_ready_w : 1'b0;
assign kv_lookup_sram_id = kv_loc_lookup_sram_id_w;
assign kv_lookup_bank_id = kv_loc_lookup_bank_id_w;
assign kv_lookup_subbank_start = kv_loc_lookup_subbank_start_w;
assign kv_lookup_group_len = kv_loc_lookup_group_len_w;

// 调试输出：用于观察当前节点是否 stale，以及补算控制器是否忙/是否完成。
assign debug_stale_hit = pred_stale_r;
assign debug_recompute_busy =
    ENABLE_RECOMPUTE_PATH ? recompute_busy_w : 1'b0;
assign debug_recompute_done =
    ENABLE_RECOMPUTE_PATH ? recompute_done_w : 1'b0;

// KVLocationTable：
// 负责 token/position -> SRAM physical location 的映射。
KVLocationTable u_kv_location_table (
    .clk(clk),
    .rst_n(rst_n),
    .wr_valid(kv_loc_wr_valid_w),
    .wr_token_id(kv_wr_token_id_w),
    .wr_position_id(kv_wr_position_id_w),
    .wr_sram_id(kv_wr_sram_id_w),
    .wr_bank_id(kv_wr_bank_id_w),
    .wr_subbank_start(kv_wr_subbank_start_w),
    .wr_group_len(kv_wr_group_len_w),
    .lookup_valid(kv_lookup_valid),
    .lookup_token_id(kv_lookup_token_id),
    .lookup_position_id(kv_lookup_position_id),
    .lookup_ready(kv_loc_lookup_ready_w),
    .lookup_hit(kv_loc_lookup_hit_w),
    .lookup_sram_id(kv_loc_lookup_sram_id_w),
    .lookup_bank_id(kv_loc_lookup_bank_id_w),
    .lookup_subbank_start(kv_loc_lookup_subbank_start_w),
    .lookup_group_len(kv_loc_lookup_group_len_w),
    .tree_lookup_valid(tree_kv_lookup_valid_w),
    .tree_lookup_token_id(pred_referenced_token_id),
    .tree_lookup_position_id(pred_referenced_position),
    .tree_lookup_ready(tree_kv_loc_lookup_ready_w),
    .tree_lookup_hit(tree_kv_loc_lookup_hit_w),
    .tree_lookup_sram_id(tree_kv_loc_lookup_sram_id_w),
    .tree_lookup_bank_id(tree_kv_loc_lookup_bank_id_w),
    .tree_lookup_subbank_start(tree_kv_loc_lookup_subbank_start_w),
    .tree_lookup_group_len(tree_kv_loc_lookup_group_len_w)
);

// KVStateTable：
// 负责记录某个 token/position 的 KV 是否 partial/full ready。
KVStateTable u_kv_state_table (
    .clk(clk),
    .rst_n(rst_n),
    .wr_valid(kv_state_wr_valid_w),
    .wr_token_id(kv_wr_token_id_w),
    .wr_position_id(kv_wr_position_id_w),
    .wr_partial_ready(kv_wr_partial_ready_w),
    .wr_full_ready(kv_wr_full_ready_w),
    .lookup_valid(kv_lookup_valid),
    .lookup_token_id(kv_lookup_token_id),
    .lookup_position_id(kv_lookup_position_id),
    .lookup_ready(kv_state_lookup_ready_w),
    .lookup_hit(kv_state_lookup_hit_w),
    .lookup_partial_ready(kv_state_lookup_partial_ready_w),
    .lookup_full_ready(kv_state_lookup_full_ready_w),
    .tree_lookup_valid(tree_kv_lookup_valid_w),
    .tree_lookup_token_id(pred_referenced_token_id),
    .tree_lookup_position_id(pred_referenced_position),
    .tree_lookup_ready(tree_kv_state_lookup_ready_w),
    .tree_lookup_hit(tree_kv_state_lookup_hit_w),
    .tree_lookup_partial_ready(tree_kv_state_lookup_partial_ready_w),
    .tree_lookup_full_ready(tree_kv_state_lookup_full_ready_w)
);

// RecomputeControl：
// 当 pred 判定 stale 且现成 KV 不够时，由它去驱动重算并把补算结果写回 committed 区。
RecomputeControl #(
    .COMMIT_ADDR(`KV_COMMITTED_BASE),
    .COMMIT_GROUP_LEN(RECOMPUTE_KV_GROUP_LEN),
    .COMMIT_REQ_ID(RECOMPUTE_KV_WRITE_REQ_ID)
) u_recompute_control (
    .clk(clk),
    .rst_n(rst_n),
    .start_valid(recompute_start_valid_w),
    .start_ready(recompute_start_ready_w),
    .start_token_id(active_token_id_w),
    .start_referenced_token_id(pred_referenced_token_id_r),
    .start_branch_id(
        ENABLE_PREDICTION_INPUT ? pred_branch_id_r : ISSUE_BRANCH_ID),
    .start_current_position(
        pred_issue_position_valid_r ? pred_issue_position_r : CURRENT_POSITION),
    .start_referenced_position(pred_referenced_position_r),
    .recompute_req_valid(recompute_req_valid_w),
    .recompute_req_ready(recompute_req_ready),
    .recompute_req_token_id(recompute_req_token_id_w),
    .recompute_req_current_position(recompute_req_current_position_w),
    .recompute_req_referenced_position(recompute_req_referenced_position_w),
    .recompute_req_branch_id(recompute_req_branch_id_w),
    .recompute_req_reason_stale(recompute_req_reason_stale_w),
    .recompute_resp_valid(recompute_resp_valid),
    .recompute_resp_ready(recompute_resp_ready_w),
    .recompute_resp_partial(recompute_resp_partial),
    .recompute_resp_full(recompute_resp_full),
    .recompute_resp_req_id(recompute_resp_req_id),
    .recompute_resp_kv_data(recompute_resp_kv_data),
    .recompute_resp_last(recompute_resp_last),
    .prep_req_valid(recompute_prep_req_valid_w),
    .prep_req_ready(prep_req_ready),
    .prep_req_write(recompute_prep_req_write_w),
    .prep_req_addr(recompute_prep_req_addr_w),
    .prep_req_wdata(recompute_prep_req_wdata_w),
    .prep_req_id(recompute_prep_req_id_w),
    .kv_loc_wr_valid(kv_loc_wr_valid_w),
    .kv_state_wr_valid(kv_state_wr_valid_w),
    .kv_wr_token_id(kv_wr_token_id_w),
    .kv_wr_position_id(kv_wr_position_id_w),
    .kv_wr_sram_id(kv_wr_sram_id_w),
    .kv_wr_bank_id(kv_wr_bank_id_w),
    .kv_wr_subbank_start(kv_wr_subbank_start_w),
    .kv_wr_group_len(kv_wr_group_len_w),
    .kv_wr_partial_ready(kv_wr_partial_ready_w),
    .kv_wr_full_ready(kv_wr_full_ready_w),
    .issue_release(recompute_issue_release_w),
    .busy(recompute_busy_w),
    .recompute_done(recompute_done_w)
);

// 主时序状态机：
// 负责串起“启动 -> 等预测 -> stale 决策 -> issue -> 等 wb -> 等重算收尾”。
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        // 复位时清空状态机和锁存的节点上下文。
        state_r <= ST_IDLE;
        error_flag_r <= 1'b0;
        pred_stale_r <= 1'b0;
        pred_recompute_pending_r <= 1'b0;
        recompute_full_done_r <= 1'b0;
        pred_source_id_r <= {PRED_SOURCE_ID_W{1'b0}};
        pred_parent_node_id_r <= {`NODE_ID_W{1'b0}};
        pred_token_id_r <= {`TOKEN_ID_W{1'b0}};
        pred_referenced_token_id_r <= {`TOKEN_ID_W{1'b0}};
        pred_referenced_position_r <= {`POSITION_ID_W{1'b0}};
        pred_issue_position_valid_r <= 1'b0;
        pred_issue_position_r <= {`POSITION_ID_W{1'b0}};
        pred_confidence_r <= {CONF_W{1'b0}};
        pred_is_last_in_window_r <= 1'b0;
        pred_branch_id_r <= {`BRANCH_ID_W{1'b0}};
        pred_tree_mask_en_r <= 1'b0;
        pred_prefix_len_r <= ISSUE_PREFIX_LEN;
        pred_visible_mask_r <= {`TOY_MAX_POS_EMB{1'b0}};
    end else begin
        case (state_r)
            ST_IDLE: begin
                // 等待上游真正发起一次 start。
                if (start_fire_w) begin
                    // 预测模式要先等 pred，固定模式可直接进入 issue。
                    state_r <= ENABLE_PREDICTION_INPUT ? ST_WAIT_PRED : ST_ISSUE;
                    error_flag_r <= 1'b0;
                    pred_stale_r <= 1'b0;
                    pred_recompute_pending_r <= 1'b0;
                    recompute_full_done_r <= 1'b0;
                end
            end

            ST_WAIT_PRED: begin
                // 接住一个完整 pred 节点，并在这里完成所有输入清洗和 stale 判定。
                if (pred_fire_w) begin
                    pred_source_id_r <= pred_source_id;
                    pred_parent_node_id_r <= pred_parent_node_id;
                    pred_token_id_r <= pred_token_id;
                    pred_referenced_token_id_r <= pred_referenced_token_id;
                    pred_referenced_position_r <= pred_referenced_position;
                    pred_issue_position_valid_r <=
                        effective_pred_issue_position_valid_w;
                    pred_issue_position_r <= effective_pred_issue_position_w;
                    pred_confidence_r <= pred_confidence;
                    pred_is_last_in_window_r <= pred_is_last_in_window;
                    pred_branch_id_r <= effective_pred_branch_id_w;
                    pred_tree_mask_en_r <= effective_pred_tree_mask_en_w;
                    pred_prefix_len_r <= effective_pred_prefix_len_w;
                    pred_visible_mask_r <= effective_pred_visible_mask_w;
                    pred_stale_r <= pred_stale_now_w;
                    recompute_full_done_r <= 1'b0;
                    if (pred_stale_now_w) begin
                        // stale 但 committed 表里已经有完整 KV，可直接 issue。
                        if (tree_kv_full_ready_hit_w) begin
                            pred_recompute_pending_r <= 1'b0;
                            state_r <= ST_ISSUE;
                        end else begin
                            // stale 且没有现成完整 KV，先启动补算。
                            pred_recompute_pending_r <= 1'b1;
                            state_r <= ST_START_RECOMP;
                        end
                    end else begin
                        // 非 stale，直接进入正常发射。
                        pred_recompute_pending_r <= 1'b0;
                        state_r <= ST_ISSUE;
                    end
                end
            end

            ST_START_RECOMP: begin
                // 向 RecomputeControl 发出 start，等它接收。
                if (recompute_start_fire_w) begin
                    state_r <= ST_WAIT_RECOMP_RELEASE;
                end
            end

            ST_WAIT_RECOMP_RELEASE: begin
                // 重算可能比 issue release 更早完成，因此先记录 full_done。
                if (recompute_done_w) begin
                    recompute_full_done_r <= 1'b1;
                end
                // 一旦补算控制器认为当前节点已可继续 issue，就进入发射阶段。
                if (recompute_issue_release_w) begin
                    state_r <= ST_ISSUE;
                end
            end

            ST_ISSUE: begin
                // 等待下游真正接受 issue。
                if (issue_fire_w) begin
                    state_r <= ST_WAIT_WB;
                end
            end

            ST_WAIT_WB: begin
                // issue 后台期间，recompute 也可能在继续收尾，因此持续监控 done。
                if (recompute_done_w) begin
                    recompute_full_done_r <= 1'b1;
                end
                // 只有匹配当前 token 的 wb_done 才能结束本次事务。
                if (wb_done_match_w) begin
                    error_flag_r <= wb_error;
                    if (pred_recompute_pending_r &&
                        ENABLE_RECOMPUTE_PATH &&
                        !(recompute_full_done_r || recompute_done_w)) begin
                        // 算子执行完成了，但补算写表还没完全落完，需要额外等待。
                        state_r <= ST_WAIT_RECOMP_FULL;
                    end else begin
                        // issue 与补算都已完成，可以回到空闲态。
                        state_r <= ST_IDLE;
                        pred_stale_r <= 1'b0;
                        pred_recompute_pending_r <= 1'b0;
                    end
                end
            end

            ST_WAIT_RECOMP_FULL: begin
                // 这里是“前台 issue 已结束、后台补算善后未结束”的尾态。
                if (recompute_done_w) begin
                    recompute_full_done_r <= 1'b1;
                    state_r <= ST_IDLE;
                    pred_stale_r <= 1'b0;
                    pred_recompute_pending_r <= 1'b0;
                end
            end

            default: begin
                // 防御式回退到空闲态。
                state_r <= ST_IDLE;
            end
        endcase
    end
end

endmodule
