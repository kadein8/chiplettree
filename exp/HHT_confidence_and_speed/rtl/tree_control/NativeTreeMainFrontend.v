`timescale 1ns/1ps

`include "config/prediction_params.vh"
`include "config/interface_params.vh"
`include "config/model_params.vh"

/*
 * 文件作用：
 * 1. 本文件实现论文语义中的 Native Tree 主前端控制器。
 * 2. 它接收 native_tree_req，先借助 tree_analyze 把树拆成 prefix 流和
 *    frontier 流，再把这些结构化数据整理成“逐 slot 发射”的 tc_pred_* 接口。
 * 3. 在论文完整主路径里，它位于：
 *    native_tree_req -> tree_analyze -> NativeTreeMainFrontend
 *      -> IntegrationTreeControlPart -> AGU / issue
 * 4. 其中：
 *    - prefix 节点按顺序一拍一个发射；
 *    - frontier 节点按 level 捕获，再在同一 level 内按 slot 顺序逐个发射。
 * 5. 当前 frozen strict tree-mask shortcut 主路径会绕过本模块，
 *    直接进入 tree_verify_dispatcher；因此本文件代表的是“论文完整 TreeControl
 *    串行主前端”的语义，而不是当前 strict tree-mask shortcut 的主计算入口。
 */
module NativeTreeMainFrontend #(
    parameter integer CFG_W = 32,
    parameter integer SOURCE_ID_W = 3,
    parameter integer CONF_W = 8,
    parameter integer WINDOW_BRANCH_SLOTS = `TREE_FRONTIER_SLOTS,
    parameter integer VISIBLE_MASK_W = `TOY_MAX_POS_EMB,
    parameter integer SLOT_IDX_W =
        (WINDOW_BRANCH_SLOTS <= 2) ? 1 : $clog2(WINDOW_BRANCH_SLOTS)
) (
    // 时钟与复位。
    input                             clk,
    input                             rst_n,

    // 会话配置输入：
    // session_start 表示开始一个新的前端会话，session_cfg_data 是这轮前端带着的配置。
    input                             session_cfg_valid,
    input      [CFG_W-1:0]            session_cfg_data,
    input                             session_start,
    output                            busy,

    // 原始 native tree request 输入。
    input                             src_req_valid,
    output                            src_req_ready,
    input      [`REQ_ID_W-1:0]        src_req_id,
    input      [`TREE_MAX_PREFIX_NODES-1:0] src_prefix_slot_valid,
    input      [`TREE_MAX_PREFIX_NODES*`NODE_ID_W-1:0] src_prefix_node_id,
    input      [`TREE_MAX_PREFIX_NODES*`TOKEN_ID_W-1:0] src_prefix_token_id,
    input      [`TREE_MAX_PREFIX_NODES*`POSITION_ID_W-1:0] src_prefix_position_id,
    input      [`POSITION_ID_W-1:0]   src_committed_len,
    input      [`TREE_MAX_FRONTIER_LEVELS-1:0] src_frontier_level_valid,
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
    input      [`TREE_MAX_FRONTIER_LEVELS*WINDOW_BRANCH_SLOTS*VISIBLE_MASK_W-1:0]
               src_visible_mask_by_level,

    // 对 TreeControl 主控的配置启动接口。
    output                            tc_cfg_valid,
    output     [CFG_W-1:0]            tc_cfg_data,
    output                            tc_start,
    input                             tc_busy,

    // 对 TreeControl 主控的逐 slot 预测发射接口。
    output                            tc_pred_valid,
    input                             tc_pred_ready,
    output     [SOURCE_ID_W-1:0]      tc_pred_source_id,
    output     [`BRANCH_ID_W-1:0]     tc_pred_branch_id,
    output     [`TREE_LEVEL_ID_W-1:0] tc_pred_level_id,
    output     [`NODE_ID_W-1:0]       tc_pred_node_id,
    output     [`NODE_ID_W-1:0]       tc_pred_parent_node_id,
    output     [`TOKEN_ID_W-1:0]      tc_pred_token_id,
    output     [`TOKEN_ID_W-1:0]      tc_pred_referenced_token_id,
    output     [`POSITION_ID_W-1:0]   tc_pred_referenced_position,
    output     [`POSITION_ID_W-1:0]   tc_pred_issue_position,
    output     [CONF_W-1:0]           tc_pred_confidence,
    output                            tc_pred_is_last_in_window,
    output                            tc_pred_tree_mask_en,
    output     [15:0]                 tc_pred_prefix_len,
    output     [VISIBLE_MASK_W-1:0]   tc_pred_visible_mask,

    // 调试事件输出。
    output                            debug_req_fire,
    output                            debug_frontier_capture_fire,
    output                            debug_pred_fire
);

// 状态机说明：
// ST_IDLE             : 等待 session_start。
// ST_WAIT_REQ         : 会话已开始，等待接收一棵 tree request。
// ST_WAIT_FRONTIER    : 等待 tree_analyze 输出 prefix 或 frontier。
// ST_LAUNCH_START     : 向 TreeControl 主控打一拍 cfg/start。
// ST_WAIT_PRED_ACCEPT : 等待当前 slot 被主控接受。
// ST_WAIT_SLOT_DONE   : 当前 slot 被接受后，等待主控把这一 slot 处理完。
localparam [2:0]
    ST_IDLE             = 3'd0,
    ST_WAIT_REQ         = 3'd1,
    ST_WAIT_FRONTIER    = 3'd2,
    ST_LAUNCH_START     = 3'd3,
    ST_WAIT_PRED_ACCEPT = 3'd4,
    ST_WAIT_SLOT_DONE   = 3'd5;

// 当前状态。
reg [2:0] state_r;

// 会话级配置数据锁存。一次 session_start 之后，后续整个请求都沿用这份配置。
reg [CFG_W-1:0] session_cfg_data_r;

// 记录这棵树里“最后一个有效 frontier level”的 level_id，
// 用于判断某个 slot 是否已经是整个窗口的最后一个待发节点。
reg [`TREE_LEVEL_ID_W-1:0] last_frontier_level_id_r;

// 当前已经捕获进 slot 寄存器的 frontier level id。
reg [`TREE_LEVEL_ID_W-1:0] captured_frontier_level_id_r;

// 当前被装入“逐 slot 发射寄存器组”的元数据。
reg [WINDOW_BRANCH_SLOTS-1:0] slot_valid_r;
reg [WINDOW_BRANCH_SLOTS*`NODE_ID_W-1:0] slot_node_id_r;
reg [WINDOW_BRANCH_SLOTS*`NODE_ID_W-1:0] slot_parent_node_id_r;
reg [WINDOW_BRANCH_SLOTS*`TOKEN_ID_W-1:0] slot_token_id_r;
reg [WINDOW_BRANCH_SLOTS*`TOKEN_ID_W-1:0] slot_referenced_token_id_r;
reg [WINDOW_BRANCH_SLOTS*`POSITION_ID_W-1:0] slot_referenced_position_r;
reg [WINDOW_BRANCH_SLOTS*`POSITION_ID_W-1:0] slot_issue_position_r;
reg [WINDOW_BRANCH_SLOTS*`BRANCH_ID_W-1:0] slot_branch_id_r;
reg [WINDOW_BRANCH_SLOTS*`TREE_LEVEL_ID_W-1:0] slot_level_id_r;
reg [WINDOW_BRANCH_SLOTS-1:0] slot_tree_mask_en_r;

// 当前正在发射哪个 slot。
reg [SLOT_IDX_W-1:0] current_slot_idx_r;

// 这一轮 request 是否仍处于活跃期。
reg request_active_r;

// 当前窗口应当看到的 prefix 长度。
reg [15:0] captured_prefix_count_r;

// 每个 slot 对应的 visible mask。
reg [WINDOW_BRANCH_SLOTS*VISIBLE_MASK_W-1:0] slot_visible_mask_r;

// 标记当前发射的是 prefix 伪装成的单 slot，还是 frontier level 中的真实 slot。
reg slot_prefix_phase_r;

// 下面两组寄存器用于 prefix 串发时构造“引用上一个 prefix token”的语义。
reg have_last_prefix_r;
reg [`TOKEN_ID_W-1:0] last_prefix_token_r;
reg [`POSITION_ID_W-1:0] last_prefix_position_r;

// tree_analyze 子模块输出的拆解流。
wire tree_req_ready_w;
wire tree_req_fire_w;
wire prefix_valid_w;
wire [`REQ_ID_W-1:0] prefix_req_id_w;
wire prefix_node_valid_w;
wire [`NODE_ID_W-1:0] prefix_node_id_w;
wire [`NODE_ID_W-1:0] prefix_parent_node_id_w;
wire [`TOKEN_ID_W-1:0] prefix_token_id_w;
wire [`POSITION_ID_W-1:0] prefix_position_id_w;
wire [`LAYER_ID_W-1:0] prefix_layer_id_w;
wire prefix_is_last_w;
wire [15:0] ta_prefix_count_w;
wire frontier_valid_w;
wire frontier_ready_w;
wire [`REQ_ID_W-1:0] frontier_req_id_w;
wire [`TREE_LEVEL_ID_W-1:0] frontier_level_id_w;
wire [`TREE_FRONTIER_SLOTS-1:0] frontier_slot_valid_w;
wire [`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0] frontier_node_id_w;
wire [`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0] frontier_parent_node_id_w;
wire [`TREE_FRONTIER_SLOTS*`TOKEN_ID_W-1:0] frontier_token_id_w;
wire [`TREE_FRONTIER_SLOTS*`TOKEN_ID_W-1:0] frontier_referenced_token_id_w;
wire [`TREE_FRONTIER_SLOTS*`POSITION_ID_W-1:0] frontier_position_id_w;
wire [`TREE_FRONTIER_SLOTS*`POSITION_ID_W-1:0] frontier_referenced_position_id_w;
wire [`TREE_FRONTIER_SLOTS*`BRANCH_ID_W-1:0] frontier_branch_id_w;
wire [15:0] frontier_level_slot_count_w;
wire [`TREE_FRONTIER_SLOTS-1:0] frontier_tree_mask_en_w;

// 组合分析结果：
// 1. 当前层里第一个有效 slot 是谁。
// 2. 当前层里当前 slot 之后还有没有下一个有效 slot。
reg [SLOT_IDX_W-1:0] first_slot_idx_comb;
reg has_valid_slot_comb;
reg [SLOT_IDX_W-1:0] next_slot_idx_w;
reg next_slot_valid_w;

// 整棵请求里最后一个有效 frontier level id。
reg [`TREE_LEVEL_ID_W-1:0] request_last_frontier_level_id_comb;

// 组合循环变量。
integer level_idx_i;
integer slot_idx_i;

// 握手事件。
wire session_start_fire_w;
wire frontier_capture_fire_w;
wire pred_accept_fire_w;
wire pred_fire_w;

// 只有空闲态才接受一次新的会话启动。
assign session_start_fire_w =
    session_cfg_valid &&
    session_start &&
    (state_r == ST_IDLE);

// 只有在等待请求态，才允许 tree_analyze 接受新 tree request。
assign src_req_ready = (state_r == ST_WAIT_REQ) ? tree_req_ready_w : 1'b0;
assign tree_req_fire_w = (state_r == ST_WAIT_REQ) && src_req_valid && tree_req_ready_w;

// 只有当前端正在等待下一段 frontier/prefix，且下游主控不忙时，才允许接收 frontier level。
assign frontier_ready_w = (state_r == ST_WAIT_FRONTIER) && !tc_busy;
assign frontier_capture_fire_w =
    frontier_valid_w && frontier_ready_w && has_valid_slot_comb;

// 本模块非空闲即 busy。
assign busy = (state_r != ST_IDLE);

// ST_LAUNCH_START 只打一拍，用来给 TreeControl 主控送配置和 start。
assign tc_cfg_valid = (state_r == ST_LAUNCH_START);
assign tc_cfg_data = session_cfg_data_r;
assign tc_start = (state_r == ST_LAUNCH_START);

// ST_WAIT_PRED_ACCEPT 期间，当前 slot 元数据稳定暴露在 tc_pred_* 上。
assign tc_pred_valid = (state_r == ST_WAIT_PRED_ACCEPT);
assign pred_accept_fire_w = tc_pred_valid && tc_pred_ready;
assign pred_fire_w = tc_pred_valid && tc_pred_ready;

// tc_pred_source_id 这里直接复用当前 slot 下标，表示“这一拍发的是哪一个 slot”。
assign tc_pred_source_id = current_slot_idx_r;

// 当前 slot 对外发射的分支 id、level id、节点 id、父节点 id。
assign tc_pred_branch_id =
    slot_branch_id_r[(current_slot_idx_r*`BRANCH_ID_W) +: `BRANCH_ID_W];
assign tc_pred_level_id =
    slot_level_id_r[(current_slot_idx_r*`TREE_LEVEL_ID_W) +: `TREE_LEVEL_ID_W];
assign tc_pred_node_id =
    slot_node_id_r[(current_slot_idx_r*`NODE_ID_W) +: `NODE_ID_W];
assign tc_pred_parent_node_id =
    slot_parent_node_id_r[(current_slot_idx_r*`NODE_ID_W) +: `NODE_ID_W];

// 当前 slot 的 token 与引用上下文。
assign tc_pred_token_id =
    slot_token_id_r[(current_slot_idx_r*`TOKEN_ID_W) +: `TOKEN_ID_W];
assign tc_pred_referenced_token_id =
    slot_referenced_token_id_r[
        (current_slot_idx_r*`TOKEN_ID_W) +: `TOKEN_ID_W];
assign tc_pred_referenced_position =
    slot_referenced_position_r[
        (current_slot_idx_r*`POSITION_ID_W) +: `POSITION_ID_W];
assign tc_pred_issue_position =
    slot_issue_position_r[
        (current_slot_idx_r*`POSITION_ID_W) +: `POSITION_ID_W];

// 当前实现里置信度先给固定值，重点是结构和路由语义。
assign tc_pred_confidence = 8'd200;

// 判断当前 slot 是否是整个窗口的最后一个待发节点：
// 1. 不能处于 prefix phase；
// 2. 当前 level 内不能再有后续有效 slot；
// 3. 当前捕获的 level 必须已经是整棵树的最后一个 frontier level。
assign tc_pred_is_last_in_window =
    !slot_prefix_phase_r &&
    !next_slot_valid_w &&
    (captured_frontier_level_id_r == last_frontier_level_id_r);

// 当前 slot 的 tree-mask 元数据、prefix 长度和 visible mask。
assign tc_pred_tree_mask_en = slot_tree_mask_en_r[current_slot_idx_r];
assign tc_pred_prefix_len = captured_prefix_count_r;
assign tc_pred_visible_mask =
    slot_visible_mask_r[(current_slot_idx_r*VISIBLE_MASK_W) +: VISIBLE_MASK_W];

// 调试事件导出。
assign debug_req_fire = tree_req_fire_w;
assign debug_frontier_capture_fire = frontier_capture_fire_w;
assign debug_pred_fire = pred_fire_w;

/*
 * 组合分析块：
 * 1. 扫整棵请求，找出最后一个有效 frontier level id。
 * 2. 扫当前捕获的 level，找出第一个有效 slot。
 * 3. 在当前 slot 之后继续扫描，找出下一个有效 slot。
 */
always @* begin
    // 默认认为最后一个 frontier level 为 0。
    request_last_frontier_level_id_comb = {`TREE_LEVEL_ID_W{1'b0}};
    for (level_idx_i = 0;
         level_idx_i < `TREE_MAX_FRONTIER_LEVELS;
         level_idx_i = level_idx_i + 1) begin
        if (src_frontier_level_valid[level_idx_i] &&
            (src_frontier_slot_valid[
                (level_idx_i*`TREE_FRONTIER_SLOTS) +: `TREE_FRONTIER_SLOTS] !=
             {`TREE_FRONTIER_SLOTS{1'b0}})) begin
            request_last_frontier_level_id_comb =
                src_frontier_level_id[
                    (level_idx_i*`TREE_FRONTIER_SLOTS*`TREE_LEVEL_ID_W) +:
                    `TREE_LEVEL_ID_W];
        end
    end

    // 在当前 level 中找第一个有效 slot，用作这一层第一次发射的起点。
    first_slot_idx_comb = {SLOT_IDX_W{1'b0}};
    has_valid_slot_comb = 1'b0;
    for (slot_idx_i = 0;
         slot_idx_i < WINDOW_BRANCH_SLOTS;
         slot_idx_i = slot_idx_i + 1) begin
        if (frontier_slot_valid_w[slot_idx_i] && !has_valid_slot_comb) begin
            has_valid_slot_comb = 1'b1;
            first_slot_idx_comb = slot_idx_i[SLOT_IDX_W-1:0];
        end
    end

    // 从 current_slot_idx 之后继续找，定位下一个有效 slot。
    next_slot_idx_w = {SLOT_IDX_W{1'b0}};
    next_slot_valid_w = 1'b0;
    for (slot_idx_i = 0;
         slot_idx_i < WINDOW_BRANCH_SLOTS;
         slot_idx_i = slot_idx_i + 1) begin
        if ((slot_idx_i > current_slot_idx_r) &&
            slot_valid_r[slot_idx_i] &&
            !next_slot_valid_w) begin
            next_slot_valid_w = 1'b1;
            next_slot_idx_w = slot_idx_i[SLOT_IDX_W-1:0];
        end
    end

end

// tree_analyze 是本文件的直接上游：负责把整棵树拆成 prefix 流与 frontier 流。
tree_analyze u_tree_analyze (
    .clk(clk),
    .rst_n(rst_n),
    .req_valid((state_r == ST_WAIT_REQ) ? src_req_valid : 1'b0),
    .req_ready(tree_req_ready_w),
    .req_id(src_req_id),
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
    .src_frontier_referenced_position_id(src_frontier_referenced_position_id),
    .src_frontier_branch_id(src_frontier_branch_id),
    .src_frontier_level_id(src_frontier_level_id),
    .src_frontier_tree_mask_en(src_frontier_tree_mask_en),
    .prefix_valid(prefix_valid_w),
    .prefix_ready((state_r == ST_WAIT_FRONTIER) && !tc_busy),
    .prefix_req_id(prefix_req_id_w),
    .prefix_node_valid(prefix_node_valid_w),
    .prefix_node_id(prefix_node_id_w),
    .prefix_parent_node_id(prefix_parent_node_id_w),
    .prefix_token_id(prefix_token_id_w),
    .prefix_position_id(prefix_position_id_w),
    .prefix_layer_id(prefix_layer_id_w),
    .prefix_is_last(prefix_is_last_w),
    .prefix_count(ta_prefix_count_w),
    .frontier_valid(frontier_valid_w),
    .frontier_ready(frontier_ready_w),
    .frontier_req_id(frontier_req_id_w),
    .frontier_level_id(frontier_level_id_w),
    .frontier_slot_valid(frontier_slot_valid_w),
    .frontier_node_id(frontier_node_id_w),
    .frontier_parent_node_id(frontier_parent_node_id_w),
    .frontier_token_id(frontier_token_id_w),
    .frontier_referenced_token_id(frontier_referenced_token_id_w),
    .frontier_position_id(frontier_position_id_w),
    .frontier_referenced_position_id(frontier_referenced_position_id_w),
    .frontier_branch_id(frontier_branch_id_w),
    .frontier_level_slot_count(frontier_level_slot_count_w),
    .frontier_tree_mask_en(frontier_tree_mask_en_w)
);

/*
 * 主时序状态机：
 * 1. 先等会话启动。
 * 2. 再等树请求进入。
 * 3. tree_analyze 吐 prefix 就构造成单 slot 发射；
 *    tree_analyze 吐 frontier level 就整层捕获，再逐 slot 发射。
 * 4. 每发一个 slot，都要等待下游主控 accept，再等待它处理结束。
 */
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        // 复位时清空全部状态与缓存，避免上一轮请求残留影响下一轮。
        state_r <= ST_IDLE;
        session_cfg_data_r <= {CFG_W{1'b0}};
        last_frontier_level_id_r <= {`TREE_LEVEL_ID_W{1'b0}};
        captured_frontier_level_id_r <= {`TREE_LEVEL_ID_W{1'b0}};
        slot_valid_r <= {WINDOW_BRANCH_SLOTS{1'b0}};
        slot_node_id_r <= {(WINDOW_BRANCH_SLOTS*`NODE_ID_W){1'b0}};
        slot_parent_node_id_r <= {(WINDOW_BRANCH_SLOTS*`NODE_ID_W){1'b0}};
        slot_token_id_r <= {(WINDOW_BRANCH_SLOTS*`TOKEN_ID_W){1'b0}};
        slot_referenced_token_id_r <= {(WINDOW_BRANCH_SLOTS*`TOKEN_ID_W){1'b0}};
        slot_referenced_position_r <=
            {(WINDOW_BRANCH_SLOTS*`POSITION_ID_W){1'b0}};
        slot_issue_position_r <=
            {(WINDOW_BRANCH_SLOTS*`POSITION_ID_W){1'b0}};
        slot_branch_id_r <= {(WINDOW_BRANCH_SLOTS*`BRANCH_ID_W){1'b0}};
        slot_level_id_r <= {(WINDOW_BRANCH_SLOTS*`TREE_LEVEL_ID_W){1'b0}};
        slot_tree_mask_en_r <= {WINDOW_BRANCH_SLOTS{1'b0}};
        current_slot_idx_r <= {SLOT_IDX_W{1'b0}};
        request_active_r <= 1'b0;
        captured_prefix_count_r <= 16'd0;
        slot_visible_mask_r <= {(WINDOW_BRANCH_SLOTS*VISIBLE_MASK_W){1'b0}};
        slot_prefix_phase_r <= 1'b0;
        have_last_prefix_r <= 1'b0;
        last_prefix_token_r <= {`TOKEN_ID_W{1'b0}};
        last_prefix_position_r <= {`POSITION_ID_W{1'b0}};
    end else begin
        case (state_r)
            ST_IDLE: begin
                // 会话启动后，锁存配置并进入等待请求态。
                if (session_start_fire_w) begin
                    session_cfg_data_r <= session_cfg_data;
                    request_active_r <= 1'b0;
                    state_r <= ST_WAIT_REQ;
                end
            end

            ST_WAIT_REQ: begin
                // 接收到完整 tree request 后，记录最后一个 frontier level，
                // 并初始化本轮 prefix 语义相关状态。
                if (tree_req_fire_w) begin
                    last_frontier_level_id_r <=
                        request_last_frontier_level_id_comb;
                    request_active_r <= 1'b1;
                    captured_prefix_count_r <=
                        {{(16-`POSITION_ID_W){1'b0}}, src_committed_len};
                    slot_prefix_phase_r <= 1'b0;
                    have_last_prefix_r <= 1'b0;
                    last_prefix_token_r <= {`TOKEN_ID_W{1'b0}};
                    last_prefix_position_r <= {`POSITION_ID_W{1'b0}};
                    state_r <= ST_WAIT_FRONTIER;
                end
            end

            ST_WAIT_FRONTIER: begin
                // 如果 tree_analyze 此时给出的是 prefix 节点：
                // 1. 把它包装成一个“只有 slot0 有效”的单 slot 发射包；
                // 2. 构造它的 referenced_token/position；
                // 3. 进入一次新的 launch/start。
                if (prefix_valid_w) begin
                    slot_prefix_phase_r <= 1'b1;
                    slot_valid_r <= {{(WINDOW_BRANCH_SLOTS-1){1'b0}}, 1'b1};
                    slot_node_id_r <= {(WINDOW_BRANCH_SLOTS*`NODE_ID_W){1'b0}};
                    slot_parent_node_id_r <=
                        {(WINDOW_BRANCH_SLOTS*`NODE_ID_W){1'b0}};
                    slot_token_id_r <= {(WINDOW_BRANCH_SLOTS*`TOKEN_ID_W){1'b0}};
                    slot_referenced_token_id_r <=
                        {(WINDOW_BRANCH_SLOTS*`TOKEN_ID_W){1'b0}};
                    slot_referenced_position_r <=
                        {(WINDOW_BRANCH_SLOTS*`POSITION_ID_W){1'b0}};
                    slot_issue_position_r <=
                        {(WINDOW_BRANCH_SLOTS*`POSITION_ID_W){1'b0}};
                    slot_branch_id_r <= {(WINDOW_BRANCH_SLOTS*`BRANCH_ID_W){1'b0}};
                    slot_level_id_r <=
                        {(WINDOW_BRANCH_SLOTS*`TREE_LEVEL_ID_W){1'b0}};
                    slot_tree_mask_en_r <= {WINDOW_BRANCH_SLOTS{1'b0}};
                    slot_visible_mask_r <=
                        {(WINDOW_BRANCH_SLOTS*VISIBLE_MASK_W){1'b0}};

                    // prefix 只占 slot 0。
                    slot_node_id_r[0 +: `NODE_ID_W] <= prefix_node_id_w;
                    slot_parent_node_id_r[0 +: `NODE_ID_W] <=
                        prefix_parent_node_id_w;
                    slot_token_id_r[0 +: `TOKEN_ID_W] <= prefix_token_id_w;

                    // prefix 的引用语义：
                    // 1. 如果这是第一个 prefix，就引用自己；
                    // 2. 否则引用上一个 prefix。
                    if (!have_last_prefix_r) begin
                        slot_referenced_token_id_r[0 +: `TOKEN_ID_W] <=
                            prefix_token_id_w;
                        slot_referenced_position_r[0 +: `POSITION_ID_W] <=
                            prefix_position_id_w;
                    end else begin
                        slot_referenced_token_id_r[0 +: `TOKEN_ID_W] <=
                            last_prefix_token_r;
                        slot_referenced_position_r[0 +: `POSITION_ID_W] <=
                            last_prefix_position_r;
                    end

                    // prefix 当前节点的 issue position 就是自己的绝对位置。
                    slot_issue_position_r[0 +: `POSITION_ID_W] <= prefix_position_id_w;

                    // 更新 prefix 长度与“上一个 prefix 节点”缓存。
                    captured_prefix_count_r <= ta_prefix_count_w;
                    have_last_prefix_r <= 1'b1;
                    last_prefix_token_r <= prefix_token_id_w;
                    last_prefix_position_r <= prefix_position_id_w;

                    current_slot_idx_r <= {SLOT_IDX_W{1'b0}};
                    state_r <= ST_LAUNCH_START;

                // 如果拿到的是一整个 frontier level：
                // 1. 把这一层全部 slot 元数据装入寄存器；
                // 2. 复制对应的 visible mask；
                // 3. 从这一层第一个有效 slot 开始逐 slot 发射。
                end else if (frontier_capture_fire_w) begin
                    captured_frontier_level_id_r <= frontier_level_id_w;
                    captured_prefix_count_r <= ta_prefix_count_w;
                    slot_prefix_phase_r <= 1'b0;
                    slot_valid_r <= frontier_slot_valid_w;
                    slot_node_id_r <= frontier_node_id_w;
                    slot_parent_node_id_r <= frontier_parent_node_id_w;
                    slot_token_id_r <= frontier_token_id_w;
                    slot_referenced_token_id_r <=
                        frontier_referenced_token_id_w;
                    slot_referenced_position_r <=
                        frontier_referenced_position_id_w;
                    slot_issue_position_r <= frontier_position_id_w;
                    slot_branch_id_r <= frontier_branch_id_w;
                    slot_level_id_r <=
                        {(WINDOW_BRANCH_SLOTS){frontier_level_id_w}};
                    slot_tree_mask_en_r <= frontier_tree_mask_en_w;
                    slot_visible_mask_r <=
                        {(WINDOW_BRANCH_SLOTS*VISIBLE_MASK_W){1'b0}};
                    for (level_idx_i = 0;
                         level_idx_i < WINDOW_BRANCH_SLOTS;
                         level_idx_i = level_idx_i + 1) begin
                        slot_visible_mask_r[
                            (level_idx_i*VISIBLE_MASK_W) +: VISIBLE_MASK_W] <=
                            src_visible_mask_by_level[
                                (((frontier_level_id_w*WINDOW_BRANCH_SLOTS) +
                                  level_idx_i) * VISIBLE_MASK_W) +:
                                 VISIBLE_MASK_W];
                    end
                    current_slot_idx_r <= first_slot_idx_comb;
                    state_r <= ST_LAUNCH_START;

                // request_active_r 说明这一轮请求曾经开始过。
                // 若现在 tree_analyze 已经重新 ready，说明 prefix/frontier 都已经吐完。
                end else if (request_active_r && tree_req_ready_w) begin
                    request_active_r <= 1'b0;
                    state_r <= ST_IDLE;
                end
            end

            ST_LAUNCH_START: begin
                // 这里只打一拍 start，然后立刻进入等待 accept。
                state_r <= ST_WAIT_PRED_ACCEPT;
            end

            ST_WAIT_PRED_ACCEPT: begin
                // 当前 slot 被下游主控接收后，转入等待这一 slot 处理结束。
                if (pred_accept_fire_w) begin
                    state_r <= ST_WAIT_SLOT_DONE;
                end
            end

            ST_WAIT_SLOT_DONE: begin
                // 等到 tc_busy 拉低，表示当前 slot 的主控处理已结束。
                if (!tc_busy) begin
                    // 如果当前是 frontier phase，且这一层还有后续有效 slot，
                    // 就继续发这一层的下一个 slot。
                    if (!slot_prefix_phase_r && next_slot_valid_w) begin
                        current_slot_idx_r <= next_slot_idx_w;
                        state_r <= ST_LAUNCH_START;
                    end else begin
                        // 否则清空 slot 缓冲，回到等待下一段 prefix/frontier。
                        slot_valid_r <= {WINDOW_BRANCH_SLOTS{1'b0}};
                        slot_node_id_r <= {(WINDOW_BRANCH_SLOTS*`NODE_ID_W){1'b0}};
                        slot_parent_node_id_r <=
                            {(WINDOW_BRANCH_SLOTS*`NODE_ID_W){1'b0}};
                        slot_token_id_r <= {(WINDOW_BRANCH_SLOTS*`TOKEN_ID_W){1'b0}};
                        slot_referenced_token_id_r <=
                            {(WINDOW_BRANCH_SLOTS*`TOKEN_ID_W){1'b0}};
                        slot_referenced_position_r <=
                            {(WINDOW_BRANCH_SLOTS*`POSITION_ID_W){1'b0}};
                        slot_issue_position_r <=
                            {(WINDOW_BRANCH_SLOTS*`POSITION_ID_W){1'b0}};
                        slot_branch_id_r <= {(WINDOW_BRANCH_SLOTS*`BRANCH_ID_W){1'b0}};
                        slot_level_id_r <= {(WINDOW_BRANCH_SLOTS*`TREE_LEVEL_ID_W){1'b0}};
                        slot_tree_mask_en_r <= {WINDOW_BRANCH_SLOTS{1'b0}};
                        slot_visible_mask_r <=
                            {(WINDOW_BRANCH_SLOTS*VISIBLE_MASK_W){1'b0}};
                        slot_prefix_phase_r <= 1'b0;
                        state_r <= ST_WAIT_FRONTIER;
                    end
                end
            end

            default: begin
                // 防御性回退。
                state_r <= ST_IDLE;
            end
        endcase
    end
end

endmodule
