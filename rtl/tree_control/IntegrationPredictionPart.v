`include "config/interface_params.vh"
`timescale 1ns/1ps

/*
 * 文件作用：
 * 1. 本文件实现论文预测整合路径中的 IntegrationPredictionPart。
 * 2. 它把 HHT 候选和多个 draft 候选收进同一个候选池，按置信度和来源优先级选出：
 *    - 单条最佳 prediction；
 *    - 可选的 multi-branch prediction window。
 * 3. 在完整路径里，它位于：
 *    HHTContextPredictor / draft generators
 *      -> IntegrationPredictionPart
 *      -> NativeTreeMainFrontend / IntegrationTreeControlPart
 * 4. 这个模块不做 transformer 计算，它做的是“候选过滤、排序、成窗、握手输出”。
 */
module IntegrationPredictionPart #(
    parameter integer DRAFT_PORTS = 4,
    parameter integer CONF_W = 8,
    parameter integer ENABLE_MULTI_BRANCH_WINDOW = 0,
    parameter integer WINDOW_BRANCH_SLOTS = `TREE_FRONTIER_SLOTS,
    parameter integer ENABLE_HHT_LIFECYCLE = 0,
    parameter integer HHT_ENTRY_NUM = 4,
    parameter integer HHT_HIT_COUNT_W = 8,
    parameter integer HHT_LRU_W = 16,
    parameter integer SOURCE_ID_W =
        ((DRAFT_PORTS + 1) <= 2) ? 1 : $clog2(DRAFT_PORTS + 1),
    parameter [CONF_W-1:0] HHT_CONF_TH = 8'd100,
    parameter [CONF_W-1:0] DRAFT_CONF_TH = 8'd100
) (
    // 时钟与复位。
    input clk,
    input rst_n,

    // HHT 候选输入。
    input hht_cand_valid,
    output hht_cand_ready,
    input [`NODE_ID_W-1:0] hht_parent_node_id,
    input [`TOKEN_ID_W-1:0] hht_token_id,
    input [`TOKEN_ID_W-1:0] hht_referenced_token_id,
    input [`POSITION_ID_W-1:0] hht_referenced_position,
    input [CONF_W-1:0] hht_confidence,

    // 多个 draft 候选输入。
    input [DRAFT_PORTS-1:0] draft_cand_valid,
    output [DRAFT_PORTS-1:0] draft_cand_ready,
    input [DRAFT_PORTS*`NODE_ID_W-1:0] draft_parent_node_id,
    input [DRAFT_PORTS*`TOKEN_ID_W-1:0] draft_token_id,
    input [DRAFT_PORTS*`TOKEN_ID_W-1:0] draft_referenced_token_id,
    input [DRAFT_PORTS*`POSITION_ID_W-1:0] draft_referenced_position,
    input [DRAFT_PORTS*CONF_W-1:0] draft_confidence,

    // HHT 生命周期更新输入。
    input hht_update_valid,
    output hht_update_ready,
    input [`NODE_ID_W-1:0] hht_update_parent_node_id,
    input [`TOKEN_ID_W-1:0] hht_update_token_id,
    input [`TOKEN_ID_W-1:0] hht_update_referenced_token_id,
    input [`POSITION_ID_W-1:0] hht_update_referenced_position,
    input [CONF_W-1:0] hht_update_confidence,

    // 单条 prediction 输出。
    output pred_valid,
    input pred_ready,
    output [SOURCE_ID_W-1:0] pred_source_id,
    output [`NODE_ID_W-1:0] pred_parent_node_id,
    output [`TOKEN_ID_W-1:0] pred_token_id,
    output [`TOKEN_ID_W-1:0] pred_referenced_token_id,
    output [`POSITION_ID_W-1:0] pred_referenced_position,
    output [CONF_W-1:0] pred_confidence,
    output pred_is_last_in_window,

    // 多分支 window 输出：
    // 只有 ENABLE_MULTI_BRANCH_WINDOW 打开时才有意义。
    output tree_window_valid,
    input tree_window_ready,
    output [`NODE_ID_W-1:0] tree_window_parent_node_id,
    output [WINDOW_BRANCH_SLOTS-1:0] tree_window_slot_valid,
    output [WINDOW_BRANCH_SLOTS*SOURCE_ID_W-1:0] tree_window_source_id,
    output [WINDOW_BRANCH_SLOTS*`TOKEN_ID_W-1:0] tree_window_token_id,
    output [WINDOW_BRANCH_SLOTS*`TOKEN_ID_W-1:0] tree_window_referenced_token_id,
    output [WINDOW_BRANCH_SLOTS*`POSITION_ID_W-1:0] tree_window_referenced_position,
    output [WINDOW_BRANCH_SLOTS*CONF_W-1:0] tree_window_confidence
);

// 候选总数 = 1 个 HHT 候选 + DRAFT_PORTS 个 draft 候选。
localparam integer TOTAL_CANDS = DRAFT_PORTS + 1;
localparam integer HHT_ENTRY_INDEX_W =
    (HHT_ENTRY_NUM <= 2) ? 1 : $clog2(HHT_ENTRY_NUM);

// 单条最佳 prediction 的输出寄存器。
reg entry_valid_r;
reg [SOURCE_ID_W-1:0] entry_source_id_r;
reg [`NODE_ID_W-1:0] entry_parent_node_id_r;
reg [`TOKEN_ID_W-1:0] entry_token_id_r;
reg [`TOKEN_ID_W-1:0] entry_referenced_token_id_r;
reg [`POSITION_ID_W-1:0] entry_referenced_position_r;
reg [CONF_W-1:0] entry_confidence_r;
reg entry_is_last_in_window_r;

// multi-branch window 输出寄存器。
reg tree_window_valid_r;
reg [`NODE_ID_W-1:0] tree_window_parent_node_id_r;
reg [WINDOW_BRANCH_SLOTS-1:0] tree_window_slot_valid_r;
reg [WINDOW_BRANCH_SLOTS*SOURCE_ID_W-1:0] tree_window_source_id_r;
reg [WINDOW_BRANCH_SLOTS*`TOKEN_ID_W-1:0] tree_window_token_id_r;
reg [WINDOW_BRANCH_SLOTS*`TOKEN_ID_W-1:0] tree_window_referenced_token_id_r;
reg [WINDOW_BRANCH_SLOTS*`POSITION_ID_W-1:0] tree_window_referenced_position_r;
reg [WINDOW_BRANCH_SLOTS*CONF_W-1:0] tree_window_confidence_r;

// 统一候选池：
// 下标 0 固定给 HHT，1..DRAFT_PORTS 给各个 draft port。
reg cand_valid_arr [0:TOTAL_CANDS-1];
reg [SOURCE_ID_W-1:0] cand_source_id_arr [0:TOTAL_CANDS-1];
reg [`NODE_ID_W-1:0] cand_parent_node_id_arr [0:TOTAL_CANDS-1];
reg [`TOKEN_ID_W-1:0] cand_token_id_arr [0:TOTAL_CANDS-1];
reg [`TOKEN_ID_W-1:0] cand_referenced_token_id_arr [0:TOTAL_CANDS-1];
reg [`POSITION_ID_W-1:0] cand_referenced_position_arr [0:TOTAL_CANDS-1];
reg [CONF_W-1:0] cand_confidence_arr [0:TOTAL_CANDS-1];
reg remaining_valid_arr [0:TOTAL_CANDS-1];

// 本拍选中的整窗候选。
reg [WINDOW_BRANCH_SLOTS-1:0] selected_slot_valid_w;
reg [WINDOW_BRANCH_SLOTS*SOURCE_ID_W-1:0] selected_source_id_w;
reg [WINDOW_BRANCH_SLOTS*`NODE_ID_W-1:0] selected_parent_node_id_w;
reg [WINDOW_BRANCH_SLOTS*`TOKEN_ID_W-1:0] selected_token_id_w;
reg [WINDOW_BRANCH_SLOTS*`TOKEN_ID_W-1:0] selected_referenced_token_id_w;
reg [WINDOW_BRANCH_SLOTS*`POSITION_ID_W-1:0] selected_referenced_position_w;
reg [WINDOW_BRANCH_SLOTS*CONF_W-1:0] selected_confidence_w;

// 第 0 个 slot 也是单条 pred 的来源。
reg best_valid_w;
reg [SOURCE_ID_W-1:0] best_source_id_w;
reg [`NODE_ID_W-1:0] best_parent_node_id_w;
reg [`TOKEN_ID_W-1:0] best_token_id_w;
reg [`TOKEN_ID_W-1:0] best_referenced_token_id_w;
reg [`POSITION_ID_W-1:0] best_referenced_position_w;
reg [CONF_W-1:0] best_confidence_w;
reg legacy_hht_ready_w;
reg [DRAFT_PORTS-1:0] legacy_draft_ready_w;
reg selected_hht_ready_w;
reg [DRAFT_PORTS-1:0] selected_draft_ready_w;
reg capture_available_w;

// 每个 slot 做局部选优时使用的临时变量。
reg loop_best_valid_w;
reg [SOURCE_ID_W-1:0] loop_best_source_id_w;
reg [`NODE_ID_W-1:0] loop_best_parent_node_id_w;
reg [`TOKEN_ID_W-1:0] loop_best_token_id_w;
reg [`TOKEN_ID_W-1:0] loop_best_referenced_token_id_w;
reg [`POSITION_ID_W-1:0] loop_best_referenced_position_w;
reg [CONF_W-1:0] loop_best_confidence_w;
integer loop_best_idx_w;

integer cand_idx;
integer draft_idx;
integer slot_idx;

// HHT probe 结果与 accept 事件。
wire hht_table_probe_hit_w;
wire [HHT_ENTRY_INDEX_W-1:0] hht_table_probe_hit_index_w;
wire hht_accept_fire_w;

// candidate_better_than：
// 比较两个候选优先级：
// 1. valid 胜过 invalid；
// 2. 置信度更高者更优；
// 3. 置信度相同时，source_id 更小者更优。
function candidate_better_than;
    input cand_valid_i;
    input [CONF_W-1:0] cand_confidence_i;
    input [SOURCE_ID_W-1:0] cand_source_id_i;
    input best_valid_i;
    input [CONF_W-1:0] best_confidence_i;
    input [SOURCE_ID_W-1:0] best_source_id_i;
    begin
        candidate_better_than = 1'b0;
        if (cand_valid_i) begin
            if (!best_valid_i) begin
                candidate_better_than = 1'b1;
            end else if (cand_confidence_i > best_confidence_i) begin
                candidate_better_than = 1'b1;
            end else if ((cand_confidence_i == best_confidence_i) &&
                         (cand_source_id_i < best_source_id_i)) begin
                candidate_better_than = 1'b1;
            end
        end
    end
endfunction

// HHT 更新口在生命周期功能打开时始终 ready。
assign hht_update_ready = ENABLE_HHT_LIFECYCLE ? 1'b1 : 1'b0;

// 只有 HHT 候选真的被 ready/accept 且 probe 命中时，才给 HHTStateTable 一个 accept_hit。
assign hht_accept_fire_w =
    ENABLE_HHT_LIFECYCLE &&
    hht_cand_valid &&
    hht_cand_ready &&
    hht_table_probe_hit_w;

// HHT 状态表：
// 负责 probe、accept_hit 和记账式 update。
HHTStateTable #(
    .CONF_W(CONF_W),
    .ENTRY_NUM(HHT_ENTRY_NUM),
    .HIT_COUNT_W(HHT_HIT_COUNT_W),
    .LRU_W(HHT_LRU_W),
    .ENTRY_INDEX_W(HHT_ENTRY_INDEX_W)
) u_hht_state_table (
    .clk(clk),
    .rst_n(rst_n),
    .probe_valid(ENABLE_HHT_LIFECYCLE ? hht_cand_valid : 1'b0),
    .probe_parent_node_id(hht_parent_node_id),
    .probe_token_id(hht_token_id),
    .probe_referenced_token_id(hht_referenced_token_id),
    .probe_referenced_position(hht_referenced_position),
    .probe_hit(hht_table_probe_hit_w),
    .probe_hit_index(hht_table_probe_hit_index_w),
    .accept_hit_valid(hht_accept_fire_w),
    .accept_hit_index(hht_table_probe_hit_index_w),
    .update_valid(ENABLE_HHT_LIFECYCLE ? hht_update_valid : 1'b0),
    .update_parent_node_id(hht_update_parent_node_id),
    .update_token_id(hht_update_token_id),
    .update_referenced_token_id(hht_update_referenced_token_id),
    .update_referenced_position(hht_update_referenced_position),
    .update_confidence(hht_update_confidence)
);

// 候选过滤、选优、成窗逻辑：
// 1. 先按阈值收集 HHT/draft 候选；
// 2. 在 remaining_valid_arr 上逐 slot 贪心选出最优候选；
// 3. slot0 作为单条 pred；
// 4. 根据单条模式或 window 模式产生 ready。
always @* begin
    // 只有 entry 缓冲和可选的 tree_window 缓冲都空时，才允许抓新一轮候选。
    capture_available_w =
        !entry_valid_r &&
        (!ENABLE_MULTI_BRANCH_WINDOW || !tree_window_valid_r);

    for (cand_idx = 0; cand_idx < TOTAL_CANDS; cand_idx = cand_idx + 1) begin
        // 默认清空统一候选池。
        cand_valid_arr[cand_idx] = 1'b0;
        cand_source_id_arr[cand_idx] = {SOURCE_ID_W{1'b0}};
        cand_parent_node_id_arr[cand_idx] = {`NODE_ID_W{1'b0}};
        cand_token_id_arr[cand_idx] = {`TOKEN_ID_W{1'b0}};
        cand_referenced_token_id_arr[cand_idx] = {`TOKEN_ID_W{1'b0}};
        cand_referenced_position_arr[cand_idx] = {`POSITION_ID_W{1'b0}};
        cand_confidence_arr[cand_idx] = {CONF_W{1'b0}};
        remaining_valid_arr[cand_idx] = 1'b0;
    end

    // HHT 候选需要过 HHT_CONF_TH 才进入候选池。
    if (hht_cand_valid && (hht_confidence >= HHT_CONF_TH)) begin
        cand_valid_arr[0] = 1'b1;
        cand_source_id_arr[0] = {SOURCE_ID_W{1'b0}};
        cand_parent_node_id_arr[0] = hht_parent_node_id;
        cand_token_id_arr[0] = hht_token_id;
        cand_referenced_token_id_arr[0] = hht_referenced_token_id;
        cand_referenced_position_arr[0] = hht_referenced_position;
        cand_confidence_arr[0] = hht_confidence;
    end

    for (draft_idx = 0; draft_idx < DRAFT_PORTS; draft_idx = draft_idx + 1) begin
        // 每个 draft 端口的候选也需要过 DRAFT_CONF_TH 才进入候选池。
        if (draft_cand_valid[draft_idx] &&
            (draft_confidence[(draft_idx*CONF_W) +: CONF_W] >= DRAFT_CONF_TH)) begin
            cand_valid_arr[draft_idx + 1] = 1'b1;
            cand_source_id_arr[draft_idx + 1] = draft_idx + 1;
            cand_parent_node_id_arr[draft_idx + 1] =
                draft_parent_node_id[(draft_idx*`NODE_ID_W) +: `NODE_ID_W];
            cand_token_id_arr[draft_idx + 1] =
                draft_token_id[(draft_idx*`TOKEN_ID_W) +: `TOKEN_ID_W];
            cand_referenced_token_id_arr[draft_idx + 1] =
                draft_referenced_token_id[(draft_idx*`TOKEN_ID_W) +: `TOKEN_ID_W];
            cand_referenced_position_arr[draft_idx + 1] =
                draft_referenced_position[(draft_idx*`POSITION_ID_W) +:
                                          `POSITION_ID_W];
            cand_confidence_arr[draft_idx + 1] =
                draft_confidence[(draft_idx*CONF_W) +: CONF_W];
        end
    end

    // 先把本拍选中的窗口内容全部清零。
    selected_slot_valid_w = {WINDOW_BRANCH_SLOTS{1'b0}};
    selected_source_id_w = {(WINDOW_BRANCH_SLOTS*SOURCE_ID_W){1'b0}};
    selected_parent_node_id_w =
        {(WINDOW_BRANCH_SLOTS*`NODE_ID_W){1'b0}};
    selected_token_id_w = {(WINDOW_BRANCH_SLOTS*`TOKEN_ID_W){1'b0}};
    selected_referenced_token_id_w =
        {(WINDOW_BRANCH_SLOTS*`TOKEN_ID_W){1'b0}};
    selected_referenced_position_w =
        {(WINDOW_BRANCH_SLOTS*`POSITION_ID_W){1'b0}};
    selected_confidence_w = {(WINDOW_BRANCH_SLOTS*CONF_W){1'b0}};

    for (cand_idx = 0; cand_idx < TOTAL_CANDS; cand_idx = cand_idx + 1) begin
        // remaining_valid_arr 是“尚未被前面 slot 拿走”的候选集合。
        remaining_valid_arr[cand_idx] = cand_valid_arr[cand_idx];
    end

    for (slot_idx = 0; slot_idx < WINDOW_BRANCH_SLOTS; slot_idx = slot_idx + 1) begin
        // 对每一个 slot，都重新从 remaining_valid_arr 中挑一个当前最优候选。
        loop_best_valid_w = 1'b0;
        loop_best_source_id_w = {SOURCE_ID_W{1'b0}};
        loop_best_parent_node_id_w = {`NODE_ID_W{1'b0}};
        loop_best_token_id_w = {`TOKEN_ID_W{1'b0}};
        loop_best_referenced_token_id_w = {`TOKEN_ID_W{1'b0}};
        loop_best_referenced_position_w = {`POSITION_ID_W{1'b0}};
        loop_best_confidence_w = {CONF_W{1'b0}};
        loop_best_idx_w = 0;

        for (cand_idx = 0; cand_idx < TOTAL_CANDS; cand_idx = cand_idx + 1) begin
            // slot0 不受 parent 约束；
            // 后续 slot 必须与 slot0 共用同一个 parent_node_id，形成同一父节点展开的窗口。
            if (remaining_valid_arr[cand_idx] &&
                ((slot_idx == 0) ||
                 !selected_slot_valid_w[0] ||
                 (cand_parent_node_id_arr[cand_idx] ==
                  selected_parent_node_id_w[0 +: `NODE_ID_W])) &&
                candidate_better_than(
                    remaining_valid_arr[cand_idx],
                    cand_confidence_arr[cand_idx],
                    cand_source_id_arr[cand_idx],
                    loop_best_valid_w,
                    loop_best_confidence_w,
                    loop_best_source_id_w)) begin
                // 命中更优候选时，更新当前 slot 的最佳记录。
                loop_best_valid_w = 1'b1;
                loop_best_source_id_w = cand_source_id_arr[cand_idx];
                loop_best_parent_node_id_w = cand_parent_node_id_arr[cand_idx];
                loop_best_token_id_w = cand_token_id_arr[cand_idx];
                loop_best_referenced_token_id_w =
                    cand_referenced_token_id_arr[cand_idx];
                loop_best_referenced_position_w =
                    cand_referenced_position_arr[cand_idx];
                loop_best_confidence_w = cand_confidence_arr[cand_idx];
                loop_best_idx_w = cand_idx;
            end
        end

        if (loop_best_valid_w) begin
            // 把当前 slot 的最佳候选写入 selected_*_w，并从 remaining 集合中移除。
            selected_slot_valid_w[slot_idx] = 1'b1;
            selected_source_id_w[(slot_idx*SOURCE_ID_W) +: SOURCE_ID_W] =
                loop_best_source_id_w;
            selected_parent_node_id_w[(slot_idx*`NODE_ID_W) +: `NODE_ID_W] =
                loop_best_parent_node_id_w;
            selected_token_id_w[(slot_idx*`TOKEN_ID_W) +: `TOKEN_ID_W] =
                loop_best_token_id_w;
            selected_referenced_token_id_w[(slot_idx*`TOKEN_ID_W) +:
                                           `TOKEN_ID_W] =
                loop_best_referenced_token_id_w;
            selected_referenced_position_w[(slot_idx*`POSITION_ID_W) +:
                                           `POSITION_ID_W] =
                loop_best_referenced_position_w;
            selected_confidence_w[(slot_idx*CONF_W) +: CONF_W] =
                loop_best_confidence_w;
            remaining_valid_arr[loop_best_idx_w] = 1'b0;
        end
    end

    // 单条 pred 直接取 window 第 0 槽。
    best_valid_w = selected_slot_valid_w[0];
    best_source_id_w = selected_source_id_w[0 +: SOURCE_ID_W];
    best_parent_node_id_w = selected_parent_node_id_w[0 +: `NODE_ID_W];
    best_token_id_w = selected_token_id_w[0 +: `TOKEN_ID_W];
    best_referenced_token_id_w =
        selected_referenced_token_id_w[0 +: `TOKEN_ID_W];
    best_referenced_position_w =
        selected_referenced_position_w[0 +: `POSITION_ID_W];
    best_confidence_w = selected_confidence_w[0 +: CONF_W];

    // legacy ready：
    // 单条模式下，只对最佳候选来源拉 ready。
    legacy_hht_ready_w = 1'b0;
    legacy_draft_ready_w = {DRAFT_PORTS{1'b0}};
    if (best_valid_w) begin
        if (best_source_id_w == {SOURCE_ID_W{1'b0}}) begin
            legacy_hht_ready_w = 1'b1;
        end else begin
            for (draft_idx = 0; draft_idx < DRAFT_PORTS; draft_idx = draft_idx + 1) begin
                if (best_source_id_w == (draft_idx + 1)) begin
                    legacy_draft_ready_w[draft_idx] = 1'b1;
                end
            end
        end
    end

    // window ready：
    // 多分支窗口模式下，对整个已选 window 中涉及到的所有来源都拉 ready。
    selected_hht_ready_w = 1'b0;
    selected_draft_ready_w = {DRAFT_PORTS{1'b0}};
    for (slot_idx = 0; slot_idx < WINDOW_BRANCH_SLOTS; slot_idx = slot_idx + 1) begin
        if (selected_slot_valid_w[slot_idx]) begin
            if (selected_source_id_w[(slot_idx*SOURCE_ID_W) +: SOURCE_ID_W] ==
                {SOURCE_ID_W{1'b0}}) begin
                selected_hht_ready_w = 1'b1;
            end else begin
                for (draft_idx = 0; draft_idx < DRAFT_PORTS; draft_idx = draft_idx + 1) begin
                    if (selected_source_id_w[(slot_idx*SOURCE_ID_W) +:
                                             SOURCE_ID_W] == (draft_idx + 1)) begin
                        selected_draft_ready_w[draft_idx] = 1'b1;
                    end
                end
            end
        end
    end
end

// 候选 ready 由 capture_available 和单条/窗口模式共同决定。
assign hht_cand_ready =
    capture_available_w &&
    (ENABLE_MULTI_BRANCH_WINDOW ? selected_hht_ready_w : legacy_hht_ready_w);
assign draft_cand_ready =
    capture_available_w ?
        (ENABLE_MULTI_BRANCH_WINDOW ? selected_draft_ready_w :
                                      legacy_draft_ready_w) :
        {DRAFT_PORTS{1'b0}};

// 单条 pred 输出直接由 entry_*_r 导出。
assign pred_valid = entry_valid_r;
assign pred_source_id = entry_source_id_r;
assign pred_parent_node_id = entry_parent_node_id_r;
assign pred_token_id = entry_token_id_r;
assign pred_referenced_token_id = entry_referenced_token_id_r;
assign pred_referenced_position = entry_referenced_position_r;
assign pred_confidence = entry_confidence_r;
assign pred_is_last_in_window = entry_is_last_in_window_r;

// 多分支 window 仅在功能打开时才对外有效，否则全部输出 0。
assign tree_window_valid =
    ENABLE_MULTI_BRANCH_WINDOW ? tree_window_valid_r : 1'b0;
assign tree_window_parent_node_id =
    ENABLE_MULTI_BRANCH_WINDOW ? tree_window_parent_node_id_r :
                                 {`NODE_ID_W{1'b0}};
assign tree_window_slot_valid =
    ENABLE_MULTI_BRANCH_WINDOW ? tree_window_slot_valid_r :
                                 {WINDOW_BRANCH_SLOTS{1'b0}};
assign tree_window_source_id =
    ENABLE_MULTI_BRANCH_WINDOW ? tree_window_source_id_r :
                                 {(WINDOW_BRANCH_SLOTS*SOURCE_ID_W){1'b0}};
assign tree_window_token_id =
    ENABLE_MULTI_BRANCH_WINDOW ? tree_window_token_id_r :
                                 {(WINDOW_BRANCH_SLOTS*`TOKEN_ID_W){1'b0}};
assign tree_window_referenced_token_id =
    ENABLE_MULTI_BRANCH_WINDOW ? tree_window_referenced_token_id_r :
                                 {(WINDOW_BRANCH_SLOTS*`TOKEN_ID_W){1'b0}};
assign tree_window_referenced_position =
    ENABLE_MULTI_BRANCH_WINDOW ? tree_window_referenced_position_r :
                                 {(WINDOW_BRANCH_SLOTS*`POSITION_ID_W){1'b0}};
assign tree_window_confidence =
    ENABLE_MULTI_BRANCH_WINDOW ? tree_window_confidence_r :
                                 {(WINDOW_BRANCH_SLOTS*CONF_W){1'b0}};

// 主时序块：
// 1. 复位时清空单条输出和窗口输出；
// 2. 若单条 pred 有效，等待 pred_ready 清空；
// 3. 若窗口有效，等待 tree_window_ready 清空；
// 4. 当 best_valid_w 成立时，抓取一轮新的单条/整窗输出。
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        // 复位时缓冲为空。
        entry_valid_r <= 1'b0;
        entry_source_id_r <= {SOURCE_ID_W{1'b0}};
        entry_parent_node_id_r <= {`NODE_ID_W{1'b0}};
        entry_token_id_r <= {`TOKEN_ID_W{1'b0}};
        entry_referenced_token_id_r <= {`TOKEN_ID_W{1'b0}};
        entry_referenced_position_r <= {`POSITION_ID_W{1'b0}};
        entry_confidence_r <= {CONF_W{1'b0}};
        entry_is_last_in_window_r <= 1'b0;
        tree_window_valid_r <= 1'b0;
        tree_window_parent_node_id_r <= {`NODE_ID_W{1'b0}};
        tree_window_slot_valid_r <= {WINDOW_BRANCH_SLOTS{1'b0}};
        tree_window_source_id_r <= {(WINDOW_BRANCH_SLOTS*SOURCE_ID_W){1'b0}};
        tree_window_token_id_r <= {(WINDOW_BRANCH_SLOTS*`TOKEN_ID_W){1'b0}};
        tree_window_referenced_token_id_r <=
            {(WINDOW_BRANCH_SLOTS*`TOKEN_ID_W){1'b0}};
        tree_window_referenced_position_r <=
            {(WINDOW_BRANCH_SLOTS*`POSITION_ID_W){1'b0}};
        tree_window_confidence_r <= {(WINDOW_BRANCH_SLOTS*CONF_W){1'b0}};
    end else if (entry_valid_r) begin
        // 单条 pred 被消费后清空。
        if (pred_ready) begin
            entry_valid_r <= 1'b0;
        end
        if (ENABLE_MULTI_BRANCH_WINDOW &&
            tree_window_valid_r &&
            tree_window_ready) begin
            // 若窗口也被消费，则同步清除窗口 valid。
            tree_window_valid_r <= 1'b0;
        end
    end else if (ENABLE_MULTI_BRANCH_WINDOW && tree_window_valid_r) begin
        // 单条 pred 已空、但窗口还在等待时，只处理窗口握手。
        if (tree_window_ready) begin
            tree_window_valid_r <= 1'b0;
        end
    end else if (best_valid_w) begin
        // 抓取本轮最佳候选到单条 pred 缓冲。
        entry_valid_r <= 1'b1;
        entry_source_id_r <= best_source_id_w;
        entry_parent_node_id_r <= best_parent_node_id_w;
        entry_token_id_r <= best_token_id_w;
        entry_referenced_token_id_r <= best_referenced_token_id_w;
        entry_referenced_position_r <= best_referenced_position_w;
        entry_confidence_r <= best_confidence_w;
        entry_is_last_in_window_r <= 1'b1;
        if (ENABLE_MULTI_BRANCH_WINDOW) begin
            // 若开启窗口模式，则把整个 selected window 一并锁存出来。
            tree_window_valid_r <= 1'b1;
            tree_window_parent_node_id_r <=
                selected_parent_node_id_w[0 +: `NODE_ID_W];
            tree_window_slot_valid_r <= selected_slot_valid_w;
            tree_window_source_id_r <= selected_source_id_w;
            tree_window_token_id_r <= selected_token_id_w;
            tree_window_referenced_token_id_r <=
                selected_referenced_token_id_w;
            tree_window_referenced_position_r <=
                selected_referenced_position_w;
            tree_window_confidence_r <= selected_confidence_w;
        end
    end
end

endmodule
