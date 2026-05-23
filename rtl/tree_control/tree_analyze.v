`timescale 1ns/1ps

`include "config/prediction_params.vh"
`include "config/interface_params.vh"

/*
 * 文件作用：
 * 1. 本文件实现论文 TreeControl 前端里的“树请求拆解器”。
 * 2. 它把一个完整的 native tree request 按论文语义拆成两段顺序流：
 *    - prefix 流：已经共享/已知的前缀节点，按节点顺序逐个吐出。
 *    - frontier 流：待验证的 frontier，按 level 为单位逐层吐出。
 * 3. 在论文主前端路径里，它位于：
 *    native_tree_req -> tree_analyze -> NativeTreeMainFrontend / AGU
 * 4. 在当前仓库里，这个模块同时服务两类消费者：
 *    - NativeTreeMainFrontend：把拆出的 prefix/frontier 再整理成逐 slot 发射。
 *    - 顶层 control_chip_stage2_single_chiplet：直接把 prefix/frontier 喂给 AGU。
 * 5. 需要特别注意：当前 frozen strict tree-mask 主路径会绕过这条串行主前端，
 *    直接走 tree_verify_dispatcher；但论文完整 TreeControl 语义仍然以本模块为
 *    “树结构输入的第一站”。
 */
module tree_analyze (
    // 时钟与复位。
    input  clk,
    input  rst_n,

    // 原始树请求握手：
    // req_valid/req_ready 表示上游是否正在提交一个完整 native tree request。
    input  req_valid,
    output req_ready,
    input  [`REQ_ID_W-1:0] req_id,

    // prefix 描述：
    // prefix 部分是 committed context 在本次请求中显式携带的前缀节点。
    input  [`TREE_MAX_PREFIX_NODES-1:0] src_prefix_slot_valid,
    input  [`TREE_MAX_PREFIX_NODES*`NODE_ID_W-1:0] src_prefix_node_id,
    input  [`TREE_MAX_PREFIX_NODES*`TOKEN_ID_W-1:0] src_prefix_token_id,
    input  [`TREE_MAX_PREFIX_NODES*`POSITION_ID_W-1:0] src_prefix_position_id,

    // committed_len 不是 prefix 节点个数，而是更长 committed 历史在 KV 中的总长度。
    input  [`POSITION_ID_W-1:0] src_committed_len,

    // frontier 描述：
    // 这里把整棵待验证树按 (level, slot) 矩阵形式打包输入。
    input  [`TREE_MAX_FRONTIER_LEVELS-1:0] src_frontier_level_valid,
    input  [`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS-1:0] src_frontier_slot_valid,
    input  [`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0] src_frontier_node_id,
    input  [`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0] src_frontier_parent_node_id,
    input  [`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`TOKEN_ID_W-1:0] src_frontier_token_id,
    input  [`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`TOKEN_ID_W-1:0] src_frontier_referenced_token_id,
    input  [`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`POSITION_ID_W-1:0] src_frontier_position_id,
    input  [`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`POSITION_ID_W-1:0] src_frontier_referenced_position_id,
    input  [`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`BRANCH_ID_W-1:0] src_frontier_branch_id,
    input  [`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`TREE_LEVEL_ID_W-1:0] src_frontier_level_id,
    input  [`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS-1:0] src_frontier_tree_mask_en,

    // prefix 输出流：
    // 以“逐节点”方式输出，每个时刻最多吐出一个 prefix 节点。
    output prefix_valid,
    input  prefix_ready,
    output [`REQ_ID_W-1:0] prefix_req_id,
    output prefix_node_valid,
    output [`NODE_ID_W-1:0] prefix_node_id,
    output [`NODE_ID_W-1:0] prefix_parent_node_id,
    output [`TOKEN_ID_W-1:0] prefix_token_id,
    output [`POSITION_ID_W-1:0] prefix_position_id,
    output [`LAYER_ID_W-1:0] prefix_layer_id,
    output prefix_is_last,
    output [15:0] prefix_count,

    // frontier 输出流：
    // 以“逐层”方式输出，每个时刻最多吐出一个 frontier level 的所有 slot。
    output frontier_valid,
    input  frontier_ready,
    output [`REQ_ID_W-1:0] frontier_req_id,
    output [`TREE_LEVEL_ID_W-1:0] frontier_level_id,
    output [`TREE_FRONTIER_SLOTS-1:0] frontier_slot_valid,
    output [`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0] frontier_node_id,
    output [`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0] frontier_parent_node_id,
    output [`TREE_FRONTIER_SLOTS*`TOKEN_ID_W-1:0] frontier_token_id,
    output [`TREE_FRONTIER_SLOTS*`TOKEN_ID_W-1:0] frontier_referenced_token_id,
    output [`TREE_FRONTIER_SLOTS*`POSITION_ID_W-1:0] frontier_position_id,
    output [`TREE_FRONTIER_SLOTS*`POSITION_ID_W-1:0] frontier_referenced_position_id,
    output [`TREE_FRONTIER_SLOTS*`BRANCH_ID_W-1:0] frontier_branch_id,
    output [15:0] frontier_level_slot_count,
    output [`TREE_FRONTIER_SLOTS-1:0] frontier_tree_mask_en
);

// 三态状态机：
// IDLE      : 等待接收一个完整树请求。
// PREFIX    : 正在逐个输出 prefix 节点。
// FRONTIER  : 正在逐层输出 frontier。
localparam [1:0] TA_STATE_IDLE     = 2'd0;
localparam [1:0] TA_STATE_PREFIX   = 2'd1;
localparam [1:0] TA_STATE_FRONTIER = 2'd2;

// 当前状态。
reg [1:0] state_r;

// 锁存的请求 id。拆解期间一直沿用同一个 req_id。
reg [`REQ_ID_W-1:0] req_id_r;

// 锁存的 prefix 内容。
reg [`TREE_MAX_PREFIX_NODES-1:0] prefix_slot_valid_r;
reg [`TREE_MAX_PREFIX_NODES*`NODE_ID_W-1:0] prefix_node_id_r;
reg [`TREE_MAX_PREFIX_NODES*`TOKEN_ID_W-1:0] prefix_token_id_r;
reg [`TREE_MAX_PREFIX_NODES*`POSITION_ID_W-1:0] prefix_position_id_r;

// 锁存的 committed 历史长度。
reg [`POSITION_ID_W-1:0] committed_len_r;

// 锁存的 frontier 内容。
reg [`TREE_MAX_FRONTIER_LEVELS-1:0] frontier_level_valid_r;
reg [`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS-1:0] frontier_slot_valid_r;
reg [`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0] frontier_node_id_r;
reg [`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0] frontier_parent_node_id_r;
reg [`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`TOKEN_ID_W-1:0] frontier_token_id_r;
reg [`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`TOKEN_ID_W-1:0] frontier_referenced_token_id_r;
reg [`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`POSITION_ID_W-1:0] frontier_position_id_r;
reg [`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`POSITION_ID_W-1:0] frontier_referenced_position_id_r;
reg [`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`BRANCH_ID_W-1:0] frontier_branch_id_r;
reg [`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`TREE_LEVEL_ID_W-1:0] frontier_level_id_r;
reg [`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS-1:0] frontier_tree_mask_en_r;

// 当前正在输出哪个 prefix 节点、哪个 frontier level。
reg [`TREE_LEVEL_ID_W-1:0] prefix_idx_r;
reg [`TREE_LEVEL_ID_W-1:0] frontier_level_idx_r;

// 组合逻辑导出的“最后一个 prefix index”和“最后一个有效 frontier level”。
reg [`TREE_LEVEL_ID_W-1:0] prefix_last_idx_comb;
reg [`TREE_LEVEL_ID_W-1:0] frontier_last_level_idx_comb;

// 当前 frontier level 对外显示的 level_id，以及该层有效 slot 数量。
reg [`TREE_LEVEL_ID_W-1:0] frontier_level_id_comb;
reg [15:0] frontier_level_slot_count_comb;

// 循环变量：
// idx_i          : 扫 prefix 或 frontier level 时使用。
// slot_count_i   : 统计某一层有效 slot 数量时使用。
integer idx_i;
integer slot_count_i;

// 只有在空闲态才接受一个新的完整树请求。
assign req_ready = (state_r == TA_STATE_IDLE);

// prefix_valid 的含义是：
// 1. 当前状态确实处于 PREFIX。
// 2. 当前 index 指向的位置是有效 prefix slot。
assign prefix_valid =
    (state_r == TA_STATE_PREFIX) &&
    prefix_slot_valid_r[prefix_idx_r];

// prefix 子流沿用整棵树请求的 req_id。
assign prefix_req_id = req_id_r;

// 这里 prefix 输出已经是“逐节点”流，所以 node_valid 与 prefix_valid 同义。
assign prefix_node_valid = prefix_valid;

// 当前 prefix 节点的 node_id，直接从锁存数组按 prefix_idx 切片。
assign prefix_node_id =
    prefix_node_id_r[(prefix_idx_r*`NODE_ID_W) +: `NODE_ID_W];

// prefix 的 parent 语义：
// 1. 第 0 个 prefix 没有更早的显式父节点，所以用 NONE。
// 2. 其他 prefix 节点的父亲默认就是前一个 prefix 节点。
assign prefix_parent_node_id =
    (prefix_idx_r == {`TREE_LEVEL_ID_W{1'b0}}) ?
        `TREE_PARENT_NONE_NODE_ID :
        prefix_node_id_r[((prefix_idx_r - 1'b1)*`NODE_ID_W) +: `NODE_ID_W];

// prefix_layer_id 这里不是 transformer layer，而是 prefix 在线性流里的顺序编号。
assign prefix_layer_id =
    {{(`LAYER_ID_W-`TREE_LEVEL_ID_W){1'b0}}, prefix_idx_r};

// 当前 prefix 是否是这一轮 prefix 流的最后一个节点。
assign prefix_is_last = (prefix_idx_r == prefix_last_idx_comb);

// prefix_count 输出的是 committed 历史总长度，而不是 prefix 节点数。
assign prefix_count =
    {{(16-`POSITION_ID_W){1'b0}}, committed_len_r};

// 当前 prefix 节点的 token 和 position。
assign prefix_token_id =
    prefix_token_id_r[(prefix_idx_r*`TOKEN_ID_W) +: `TOKEN_ID_W];
assign prefix_position_id =
    prefix_position_id_r[
        (prefix_idx_r*`POSITION_ID_W) +: `POSITION_ID_W];

// frontier_valid 的含义是：
// 1. 当前状态处于 FRONTIER。
// 2. 当前 level index 对应的 level 确实有效。
assign frontier_valid =
    (state_r == TA_STATE_FRONTIER) &&
    frontier_level_valid_r[frontier_level_idx_r];

// frontier 子流同样沿用整棵树请求的 req_id。
assign frontier_req_id = req_id_r;

// 当前正在输出的 frontier level id。
assign frontier_level_id = frontier_level_id_comb;

// 以下所有 frontier 输出，都是从锁存矩阵中按当前 frontier_level_idx 切出一整层。
assign frontier_slot_valid =
    frontier_slot_valid_r[(frontier_level_idx_r*`TREE_FRONTIER_SLOTS) +: `TREE_FRONTIER_SLOTS];
assign frontier_node_id =
    frontier_node_id_r[(frontier_level_idx_r*`TREE_FRONTIER_SLOTS*`NODE_ID_W) +:
        (`TREE_FRONTIER_SLOTS*`NODE_ID_W)];
assign frontier_parent_node_id =
    frontier_parent_node_id_r[(frontier_level_idx_r*`TREE_FRONTIER_SLOTS*`NODE_ID_W) +:
        (`TREE_FRONTIER_SLOTS*`NODE_ID_W)];
assign frontier_token_id =
    frontier_token_id_r[(frontier_level_idx_r*`TREE_FRONTIER_SLOTS*`TOKEN_ID_W) +:
        (`TREE_FRONTIER_SLOTS*`TOKEN_ID_W)];
assign frontier_referenced_token_id =
    frontier_referenced_token_id_r[
        (frontier_level_idx_r*`TREE_FRONTIER_SLOTS*`TOKEN_ID_W) +:
        (`TREE_FRONTIER_SLOTS*`TOKEN_ID_W)];
assign frontier_position_id =
    frontier_position_id_r[
        (frontier_level_idx_r*`TREE_FRONTIER_SLOTS*`POSITION_ID_W) +:
        (`TREE_FRONTIER_SLOTS*`POSITION_ID_W)];
assign frontier_referenced_position_id =
    frontier_referenced_position_id_r[
        (frontier_level_idx_r*`TREE_FRONTIER_SLOTS*`POSITION_ID_W) +:
        (`TREE_FRONTIER_SLOTS*`POSITION_ID_W)];
assign frontier_branch_id =
    frontier_branch_id_r[
        (frontier_level_idx_r*`TREE_FRONTIER_SLOTS*`BRANCH_ID_W) +:
        (`TREE_FRONTIER_SLOTS*`BRANCH_ID_W)];

// 该层有效 slot 数量，供下游知道这层实际有多少个待处理节点。
assign frontier_level_slot_count = frontier_level_slot_count_comb;

// 当前层每个 slot 是否启用 tree-mask 语义。
assign frontier_tree_mask_en =
    frontier_tree_mask_en_r[
        (frontier_level_idx_r*`TREE_FRONTIER_SLOTS) +:
        `TREE_FRONTIER_SLOTS];

/*
 * 组合分析块：
 * 1. 先找出最后一个有效 prefix index。
 * 2. 再找出最后一个有效 frontier level。
 * 3. 再根据当前 frontier_level_idx 取出该层的 level_id。
 * 4. 最后统计该层一共有多少个有效 slot。
 */
always @* begin
    // 默认没有有效 prefix 时，把最后 index 维持为 0。
    prefix_last_idx_comb = {`TREE_LEVEL_ID_W{1'b0}};
    for (idx_i = 0; idx_i < `TREE_MAX_PREFIX_NODES; idx_i = idx_i + 1) begin
        // 遍历所有 prefix slot，记录最后一个有效的位置。
        if (prefix_slot_valid_r[idx_i]) begin
            prefix_last_idx_comb = idx_i[`TREE_LEVEL_ID_W-1:0];
        end
    end

    // 默认没有有效 frontier 时，把最后 level 维持为 0。
    frontier_last_level_idx_comb = {`TREE_LEVEL_ID_W{1'b0}};
    for (idx_i = 0; idx_i < `TREE_MAX_FRONTIER_LEVELS; idx_i = idx_i + 1) begin
        // 遍历所有 frontier level，记录最后一个有效 level。
        if (frontier_level_valid_r[idx_i]) begin
            frontier_last_level_idx_comb = idx_i[`TREE_LEVEL_ID_W-1:0];
        end
    end

    // 从当前 level 对应的矩阵区域里切出该层的 level_id。
    frontier_level_id_comb =
        frontier_level_id_r[
            (frontier_level_idx_r*`TREE_FRONTIER_SLOTS*`TREE_LEVEL_ID_W) +:
            `TREE_LEVEL_ID_W];

    // 对当前层做有效 slot 计数。
    frontier_level_slot_count_comb = 16'd0;
    for (slot_count_i = 0;
         slot_count_i < `TREE_FRONTIER_SLOTS;
         slot_count_i = slot_count_i + 1) begin
        if (frontier_slot_valid_r[
                (frontier_level_idx_r*`TREE_FRONTIER_SLOTS) + slot_count_i]) begin
            frontier_level_slot_count_comb =
                frontier_level_slot_count_comb + 16'd1;
        end
    end

end

/*
 * 时序状态机：
 * 1. IDLE 接收整棵树并锁存。
 * 2. 若有 prefix，则先进入 PREFIX 逐节点输出。
 * 3. prefix 结束后，若存在 frontier，则进入 FRONTIER 逐层输出。
 * 4. 全部完成后返回 IDLE，等待下一棵树。
 */
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        // 复位时清空状态与所有锁存内容，避免上一拍残留污染新请求。
        state_r <= TA_STATE_IDLE;
        req_id_r <= {`REQ_ID_W{1'b0}};
        prefix_slot_valid_r <= {`TREE_MAX_PREFIX_NODES{1'b0}};
        prefix_node_id_r <= {(`TREE_MAX_PREFIX_NODES*`NODE_ID_W){1'b0}};
        prefix_token_id_r <= {(`TREE_MAX_PREFIX_NODES*`TOKEN_ID_W){1'b0}};
        prefix_position_id_r <= {(`TREE_MAX_PREFIX_NODES*`POSITION_ID_W){1'b0}};
        committed_len_r <= {`POSITION_ID_W{1'b0}};
        frontier_level_valid_r <= {`TREE_MAX_FRONTIER_LEVELS{1'b0}};
        frontier_slot_valid_r <=
            {(`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS){1'b0}};
        frontier_node_id_r <=
            {(`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`NODE_ID_W){1'b0}};
        frontier_parent_node_id_r <=
            {(`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`NODE_ID_W){1'b0}};
        frontier_token_id_r <=
            {(`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`TOKEN_ID_W){1'b0}};
        frontier_referenced_token_id_r <=
            {(`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`TOKEN_ID_W){1'b0}};
        frontier_position_id_r <=
            {(`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`POSITION_ID_W){1'b0}};
        frontier_referenced_position_id_r <=
            {(`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`POSITION_ID_W){1'b0}};
        frontier_branch_id_r <=
            {(`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`BRANCH_ID_W){1'b0}};
        frontier_level_id_r <=
            {(`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`TREE_LEVEL_ID_W){1'b0}};
        frontier_tree_mask_en_r <=
            {(`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS){1'b0}};
        prefix_idx_r <= {`TREE_LEVEL_ID_W{1'b0}};
        frontier_level_idx_r <= {`TREE_LEVEL_ID_W{1'b0}};
    end else begin
        case (state_r)
            TA_STATE_IDLE: begin
                // 只有在空闲态且上游完成握手时，才把整棵树一次性锁进本模块。
                if (req_valid && req_ready) begin
                    req_id_r <= req_id;
                    prefix_slot_valid_r <= src_prefix_slot_valid;
                    prefix_node_id_r <= src_prefix_node_id;
                    prefix_token_id_r <= src_prefix_token_id;
                    prefix_position_id_r <= src_prefix_position_id;
                    committed_len_r <= src_committed_len;
                    frontier_level_valid_r <= src_frontier_level_valid;
                    frontier_slot_valid_r <= src_frontier_slot_valid;
                    frontier_node_id_r <= src_frontier_node_id;
                    frontier_parent_node_id_r <= src_frontier_parent_node_id;
                    frontier_token_id_r <= src_frontier_token_id;
                    frontier_referenced_token_id_r <=
                        src_frontier_referenced_token_id;
                    frontier_position_id_r <= src_frontier_position_id;
                    frontier_referenced_position_id_r <=
                        src_frontier_referenced_position_id;
                    frontier_branch_id_r <= src_frontier_branch_id;
                    frontier_level_id_r <= src_frontier_level_id;
                    frontier_tree_mask_en_r <= src_frontier_tree_mask_en;

                    // 新请求开始时，总是从第 0 个 prefix 和第 0 个 frontier level 起步。
                    prefix_idx_r <= {`TREE_LEVEL_ID_W{1'b0}};
                    frontier_level_idx_r <= {`TREE_LEVEL_ID_W{1'b0}};

                    // 优先输出 prefix；只有没有 prefix 时才直接转到 frontier。
                    if (src_prefix_slot_valid != {`TREE_MAX_PREFIX_NODES{1'b0}}) begin
                        state_r <= TA_STATE_PREFIX;
                    end else if (src_frontier_level_valid != {`TREE_MAX_FRONTIER_LEVELS{1'b0}}) begin
                        state_r <= TA_STATE_FRONTIER;
                    end
                end
            end

            TA_STATE_PREFIX: begin
                // 仅当当前 prefix 节点有效且下游接受后，才推进 prefix 指针。
                if (prefix_valid && prefix_ready) begin
                    // 若当前已经是最后一个 prefix 节点，则准备切到 frontier 或结束。
                    if (prefix_idx_r == prefix_last_idx_comb) begin
                        if (frontier_level_valid_r != {`TREE_MAX_FRONTIER_LEVELS{1'b0}}) begin
                            frontier_level_idx_r <= {`TREE_LEVEL_ID_W{1'b0}};
                            state_r <= TA_STATE_FRONTIER;
                        end else begin
                            state_r <= TA_STATE_IDLE;
                        end
                    end else begin
                        // 否则继续输出下一个 prefix 节点。
                        prefix_idx_r <= prefix_idx_r + 1'b1;
                    end
                end
            end

            TA_STATE_FRONTIER: begin
                // 仅当当前 frontier level 被下游整个接受后，才推进到下一层。
                if (frontier_valid && frontier_ready) begin
                    if (frontier_level_idx_r == frontier_last_level_idx_comb) begin
                        // 当前已经是最后一层，整个请求处理结束。
                        state_r <= TA_STATE_IDLE;
                    end else begin
                        // 还有下一层 frontier，则 level index 加一。
                        frontier_level_idx_r <= frontier_level_idx_r + 1'b1;
                    end
                end
            end

            default: begin
                // 防御性回退：遇到非法状态直接回空闲。
                state_r <= TA_STATE_IDLE;
            end
        endcase
    end
end

endmodule
