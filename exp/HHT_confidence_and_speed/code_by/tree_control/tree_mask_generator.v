`include "config/interface_params.vh"
`include "config/model_params.vh"
`timescale 1ns/1ps

/*
 * 文件作用：
 * 1. 本文件实现论文 TreeControl 前端里的“可见性掩码生成器”。
 * 2. 输入是一棵以 prefix + layered frontier 表达的树，请求中显式给出
 *    node_id / parent_node_id / position_id。
 * 3. 输出是每个 frontier level、每个 slot 对应的 visible mask，用来表达：
 *    - 所有 committed / prefix 位置可见；
 *    - 自己分支上的祖先位置可见；
 *    - 非祖先 sibling/cousin 不可见。
 * 4. 在论文语义里，它位于：
 *    native_tree_req -> tree_mask_generator -> NativeTreeMainFrontend
 * 5. 在当前仓库里，它主要服务串行 TreeControl 路径；
 *    frozen strict tree-mask shortcut 主路径则在 tree_verify_dispatcher 内部
 *    重新生成 batch 级 tree mask。
 */
module tree_mask_generator #(
    parameter integer VISIBLE_MASK_W = `TOY_MAX_POS_EMB,
    parameter integer SLOT_COUNT = `TREE_FRONTIER_SLOTS,
    parameter integer LEVEL_COUNT = `TREE_MAX_FRONTIER_LEVELS
) (
    // prefix 输入：提供显式前缀节点的 node_id 与 position。
    input  [`TREE_MAX_PREFIX_NODES-1:0] src_prefix_slot_valid,
    input  [`TREE_MAX_PREFIX_NODES*`NODE_ID_W-1:0] src_prefix_node_id,
    input  [`TREE_MAX_PREFIX_NODES*`POSITION_ID_W-1:0] src_prefix_position_id,

    // committed 历史总长度。当前实现里主要作为上下文存在性信号保留。
    input  [`POSITION_ID_W-1:0] src_committed_len,

    // frontier 输入：按 (level, slot) 描述的树形 frontier。
    input  [LEVEL_COUNT-1:0] src_frontier_level_valid,
    input  [LEVEL_COUNT*SLOT_COUNT-1:0] src_frontier_slot_valid,
    input  [LEVEL_COUNT*SLOT_COUNT*`NODE_ID_W-1:0] src_frontier_node_id,
    input  [LEVEL_COUNT*SLOT_COUNT*`NODE_ID_W-1:0]
           src_frontier_parent_node_id,
    input  [LEVEL_COUNT*SLOT_COUNT*`POSITION_ID_W-1:0]
           src_frontier_position_id,
    input  [LEVEL_COUNT*SLOT_COUNT*`BRANCH_ID_W-1:0]
           src_frontier_branch_id,
    input  [LEVEL_COUNT*SLOT_COUNT*`TREE_LEVEL_ID_W-1:0]
           src_frontier_level_id,

    // 输出：每个 flat slot 对应一个长度为 VISIBLE_MASK_W 的位置可见向量。
    output reg [LEVEL_COUNT*SLOT_COUNT*VISIBLE_MASK_W-1:0]
               visible_mask_by_level
);

// 以 node_id 为索引建立查找表时，表项数量就是所有可能 node_id 的总数。
localparam integer NODE_LUT_SIZE = (1 << `NODE_ID_W);

// 遍历 prefix/frontier/position 时的循环变量。
integer prefix_idx_i;
integer level_idx_i;
integer slot_idx_i;
integer flat_slot_idx_i;
integer step_idx_i;
integer position_idx_i;

// 下面三组组合数组一起构成“节点查找表”：
// 1. node_valid_comb       : 某个 node_id 当前是否已知。
// 2. node_parent_bus_comb  : 某个 node_id 的父节点是谁。
// 3. node_position_bus_comb: 某个 node_id 对应哪个 position。
reg [NODE_LUT_SIZE-1:0] node_valid_comb;
reg [(NODE_LUT_SIZE*`NODE_ID_W)-1:0] node_parent_bus_comb;
reg [(NODE_LUT_SIZE*`POSITION_ID_W)-1:0] node_position_bus_comb;

// slot_mask_comb：当前正在计算的某个 slot 的可见位置位图。
reg [VISIBLE_MASK_W-1:0] slot_mask_comb;

// 沿祖先链回溯时使用的游标。
reg [`NODE_ID_W-1:0] cursor_node_comb;
reg [`NODE_ID_W-1:0] next_parent_node_comb;
reg [`POSITION_ID_W-1:0] cursor_position_comb;

// 当前正在处理的节点元数据。
reg [`NODE_ID_W-1:0] node_id_comb;
reg [`NODE_ID_W-1:0] parent_node_id_comb;
reg [`POSITION_ID_W-1:0] position_id_comb;
reg [`BRANCH_ID_W-1:0] branch_id_comb;
reg [`TREE_LEVEL_ID_W-1:0] level_id_comb;

/*
 * 组合生成过程分三步：
 * 1. 先用 prefix 建立一份 node_id -> {parent, position} 的查找表。
 * 2. 再把所有 frontier 节点补进这份查找表。
 * 3. 最后对每个 frontier slot：
 *    - 先把所有 prefix 位置标成可见；
 *    - 再沿“自己 -> 父亲 -> 祖先”链一路回溯，把祖先位置标成可见；
 *    - 结果写回 visible_mask_by_level。
 */
always @* begin
    // 每次重算都从空查找表和全零 mask 开始，确保没有上拍残留。
    node_valid_comb = {NODE_LUT_SIZE{1'b0}};
    node_parent_bus_comb = {(NODE_LUT_SIZE*`NODE_ID_W){1'b0}};
    node_position_bus_comb = {(NODE_LUT_SIZE*`POSITION_ID_W){1'b0}};
    visible_mask_by_level = {(LEVEL_COUNT*SLOT_COUNT*VISIBLE_MASK_W){1'b0}};

    // 第一步：把 prefix 节点写入 node 查找表。
    for (prefix_idx_i = 0;
         prefix_idx_i < `TREE_MAX_PREFIX_NODES;
         prefix_idx_i = prefix_idx_i + 1) begin
        if (src_prefix_slot_valid[prefix_idx_i]) begin
            node_id_comb =
                src_prefix_node_id[(prefix_idx_i*`NODE_ID_W) +: `NODE_ID_W];

            // 标记这个 node_id 已知。
            node_valid_comb[node_id_comb] = 1'b1;

            // prefix 节点在这里统一视为“根侧可见节点”，其父亲记为 NONE。
            node_parent_bus_comb[(node_id_comb*`NODE_ID_W) +: `NODE_ID_W] =
                `TREE_PARENT_NONE_NODE_ID;

            // 记录 prefix 节点对应的绝对 position。
            node_position_bus_comb[
                (node_id_comb*`POSITION_ID_W) +: `POSITION_ID_W] =
                src_prefix_position_id[
                    (prefix_idx_i*`POSITION_ID_W) +: `POSITION_ID_W];
        end
    end

    // 第二步：把 frontier 节点补进 node 查找表。
    for (level_idx_i = 0;
         level_idx_i < LEVEL_COUNT;
         level_idx_i = level_idx_i + 1) begin
        for (slot_idx_i = 0;
             slot_idx_i < SLOT_COUNT;
             slot_idx_i = slot_idx_i + 1) begin
            flat_slot_idx_i = (level_idx_i * SLOT_COUNT) + slot_idx_i;
            if (src_frontier_level_valid[level_idx_i] &&
                src_frontier_slot_valid[flat_slot_idx_i]) begin
                node_id_comb =
                    src_frontier_node_id[
                        (flat_slot_idx_i*`NODE_ID_W) +: `NODE_ID_W];
                parent_node_id_comb =
                    src_frontier_parent_node_id[
                        (flat_slot_idx_i*`NODE_ID_W) +: `NODE_ID_W];
                position_id_comb =
                    src_frontier_position_id[
                        (flat_slot_idx_i*`POSITION_ID_W) +: `POSITION_ID_W];
                branch_id_comb =
                    src_frontier_branch_id[
                        (flat_slot_idx_i*`BRANCH_ID_W) +: `BRANCH_ID_W];
                level_id_comb =
                    src_frontier_level_id[
                        (flat_slot_idx_i*`TREE_LEVEL_ID_W) +:
                        `TREE_LEVEL_ID_W];

                // 记录该节点本身是已知节点。
                node_valid_comb[node_id_comb] = 1'b1;

                // 记录它的父节点关系，供后面祖先链回溯。
                node_parent_bus_comb[
                    (node_id_comb*`NODE_ID_W) +: `NODE_ID_W] =
                    parent_node_id_comb;

                // 记录它的绝对 position。
                node_position_bus_comb[
                    (node_id_comb*`POSITION_ID_W) +: `POSITION_ID_W] =
                    position_id_comb;

                // 下面这个条件块在逻辑上不改变功能：
                // 1. branch_id_comb == branch_id_comb 和 level_id_comb == level_id_comb
                //    是恒真自比较，当前更多是保留“这里确实已经读过 branch/level 元数据”。
                // 2. src_committed_len != 0 只是在存在 committed context 时再次确认
                //    node_valid_comb[node_id_comb] 为 1。
                if (src_committed_len != {`POSITION_ID_W{1'b0}} &&
                    branch_id_comb == branch_id_comb &&
                    level_id_comb == level_id_comb) begin
                    node_valid_comb[node_id_comb] = 1'b1;
                end
            end
        end
    end

    // 第三步：为每个 frontier slot 生成一个 visible mask。
    for (level_idx_i = 0;
         level_idx_i < LEVEL_COUNT;
         level_idx_i = level_idx_i + 1) begin
        for (slot_idx_i = 0;
             slot_idx_i < SLOT_COUNT;
             slot_idx_i = slot_idx_i + 1) begin
            flat_slot_idx_i = (level_idx_i * SLOT_COUNT) + slot_idx_i;

            // 每个 slot 都从全零 mask 开始。
            slot_mask_comb = {VISIBLE_MASK_W{1'b0}};
            cursor_node_comb = {`NODE_ID_W{1'b0}};

            if (src_frontier_level_valid[level_idx_i] &&
                src_frontier_slot_valid[flat_slot_idx_i]) begin
                // 3.1 先把显式 prefix 的 position 全部置为可见。
                for (prefix_idx_i = 0;
                     prefix_idx_i < `TREE_MAX_PREFIX_NODES;
                     prefix_idx_i = prefix_idx_i + 1) begin
                    if (src_prefix_slot_valid[prefix_idx_i]) begin
                        position_id_comb =
                            src_prefix_position_id[
                                (prefix_idx_i*`POSITION_ID_W) +:
                                 `POSITION_ID_W];
                        if (position_id_comb < VISIBLE_MASK_W)
                            slot_mask_comb[position_id_comb] = 1'b1;
                    end
                end

                // 3.2 从当前 slot 自己的 node_id 出发，沿父链一路回溯。
                cursor_node_comb =
                    src_frontier_node_id[
                        (flat_slot_idx_i*`NODE_ID_W) +: `NODE_ID_W];
                for (step_idx_i = 0;
                     step_idx_i < NODE_LUT_SIZE;
                     step_idx_i = step_idx_i + 1) begin
                    if ((cursor_node_comb != {`NODE_ID_W{1'b0}}) &&
                        (cursor_node_comb != `TREE_PARENT_NONE_NODE_ID) &&
                        node_valid_comb[cursor_node_comb]) begin
                        // 当前祖先节点对应的 position 可见。
                        cursor_position_comb =
                            node_position_bus_comb[
                                (cursor_node_comb*`POSITION_ID_W) +:
                                 `POSITION_ID_W];
                        if (cursor_position_comb < VISIBLE_MASK_W)
                            slot_mask_comb[cursor_position_comb] = 1'b1;

                        // 指针跳到父节点，继续下一轮祖先回溯。
                        next_parent_node_comb =
                            node_parent_bus_comb[
                                (cursor_node_comb*`NODE_ID_W) +:
                                 `NODE_ID_W];
                        cursor_node_comb = next_parent_node_comb;
                    end else begin
                        // 回溯终止条件：
                        // 1. 到了 0；
                        // 2. 到了 NONE；
                        // 3. 当前 node_id 在查找表中无效。
                        cursor_node_comb = {`NODE_ID_W{1'b0}};
                    end
                end
            end

            // 3.3 把当前 slot 的临时 mask 写回输出总线。
            for (position_idx_i = 0;
                 position_idx_i < VISIBLE_MASK_W;
                 position_idx_i = position_idx_i + 1) begin
                visible_mask_by_level[
                    (flat_slot_idx_i*VISIBLE_MASK_W) + position_idx_i] =
                    slot_mask_comb[position_idx_i];
            end
        end
    end
end

endmodule
