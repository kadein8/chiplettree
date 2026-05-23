`timescale 1ns/1ps

`include "config/prediction_params.vh"
`include "config/interface_params.vh"
`include "config/memory_params.vh"

/*
 * 文件作用：
 * 1. 本文件实现论文 TreeControl 串行前端里的“预取排队队列”。
 * 2. 它承接 AGU 已经规范化好的 prefix/frontier 节点，把“准备申请 KV 位置/
 *    触发后续存储资源动作”的工作项先排进一个 FIFO，避免 AGU 与后端资源分配
 *    逻辑直接硬耦合。
 * 3. 在论文完整主路径里，它位于：
 *    native_tree_req
 *      -> tree_analyze / NativeTreeMainFrontend
 *      -> AGU
 *      -> prefetch_queue
 *      -> free_list / bank_state_table / token_register
 * 4. 当前 frozen strict tree-mask shortcut 主路径会绕过这条串行 TreeControl
 *    前端；但如果按论文完整语义阅读资源管理链路，本模块就是 Stage B/Stage C
 *    之间的缓冲器。
 * 5. 这个模块不做真正的 SRAM 读写，它只维护“哪些节点还在等待后续资源处理”。
 */
module prefetch_queue (
    // 时钟与复位。
    input                       clk,
    input                       rst_n,

    // 入队侧：来自 AGU 的“待预取/待资源分配工作项”。
    input                       enq_valid,
    output                      enq_ready,
    input  [`REQ_ID_W-1:0]      enq_req_id,
    input  [`BRANCH_ID_W-1:0]   enq_branch_id,
    input  [`NODE_ID_W-1:0]     enq_node_id,
    input  [`LAYER_ID_W-1:0]    enq_layer_id,
    input  [`KV_GROUP_LEN_W-1:0] enq_size_subbank,
    input                       enq_shared,

    // flush 控制：当比较器/控制器判定某些 branch/node 需要被丢弃时，
    // 队列里对应的尚未处理工作项也必须同步清掉，避免旧工作继续向后传播。
    input                       flush_valid,
    input  [`REQ_ID_W-1:0]      flush_req_id,
    input  [`BRANCH_MASK_W-1:0] flush_branch_mask,
    input  [`NODE_MASK_W-1:0]   flush_node_mask,

    // 出队侧：把队首工作项送给后续 free_list / bank_state_table。
    output                      deq_valid,
    input                       deq_ready,
    output [`REQ_ID_W-1:0]      deq_req_id,
    output [`BRANCH_ID_W-1:0]   deq_branch_id,
    output [`NODE_ID_W-1:0]     deq_node_id,
    output [`LAYER_ID_W-1:0]    deq_layer_id,
    output [`KV_GROUP_LEN_W-1:0] deq_size_subbank,
    output                      deq_shared
);

// 计数器位宽：覆盖 0..PREFETCH_Q_DEPTH 的所有可能占用数。
localparam integer PREFETCH_Q_COUNT_W =
    ((`PREFETCH_Q_DEPTH <= 1) ? 1 : $clog2(`PREFETCH_Q_DEPTH + 1));

// 当前队列寄存器阵列。
// 每个 slot 记录一个待处理工作项。
reg                          entry_valid_r [0:`PREFETCH_Q_DEPTH-1];
reg [`REQ_ID_W-1:0]          entry_req_id_r [0:`PREFETCH_Q_DEPTH-1];
reg [`BRANCH_ID_W-1:0]       entry_branch_id_r [0:`PREFETCH_Q_DEPTH-1];
reg [`NODE_ID_W-1:0]         entry_node_id_r [0:`PREFETCH_Q_DEPTH-1];
reg [`LAYER_ID_W-1:0]        entry_layer_id_r [0:`PREFETCH_Q_DEPTH-1];
reg [`KV_GROUP_LEN_W-1:0]    entry_size_subbank_r [0:`PREFETCH_Q_DEPTH-1];
reg                          entry_shared_r [0:`PREFETCH_Q_DEPTH-1];
reg [PREFETCH_Q_COUNT_W-1:0] entry_count_r;

// 下一拍队列状态。
// 采用“组合重排 + 时序写回”的写法，便于同时处理：
// 1. 正常出队
// 2. flush 删除
// 3. 同拍新入队
reg                          entry_valid_n [0:`PREFETCH_Q_DEPTH-1];
reg [`REQ_ID_W-1:0]          entry_req_id_n [0:`PREFETCH_Q_DEPTH-1];
reg [`BRANCH_ID_W-1:0]       entry_branch_id_n [0:`PREFETCH_Q_DEPTH-1];
reg [`NODE_ID_W-1:0]         entry_node_id_n [0:`PREFETCH_Q_DEPTH-1];
reg [`LAYER_ID_W-1:0]        entry_layer_id_n [0:`PREFETCH_Q_DEPTH-1];
reg [`KV_GROUP_LEN_W-1:0]    entry_size_subbank_n [0:`PREFETCH_Q_DEPTH-1];
reg                          entry_shared_n [0:`PREFETCH_Q_DEPTH-1];
reg [PREFETCH_Q_COUNT_W-1:0] entry_count_n;

// 队首组合输出。
reg deq_valid_comb;
reg [`REQ_ID_W-1:0] deq_req_id_comb;
reg [`BRANCH_ID_W-1:0] deq_branch_id_comb;
reg [`NODE_ID_W-1:0] deq_node_id_comb;
reg [`LAYER_ID_W-1:0] deq_layer_id_comb;
reg [`KV_GROUP_LEN_W-1:0] deq_size_subbank_comb;
reg deq_shared_comb;

// 循环变量与 flush 匹配辅助变量。
integer slot_i;
integer pack_idx_i;
integer node_mask_index_i;
reg branch_hit_comb;
reg node_hit_comb;

// ready 条件：只要队列没满，AGU 就可以继续塞入新工作项。
assign enq_ready = (entry_count_r < `PREFETCH_Q_DEPTH);

// 把组合态的队首直接暴露给后级。
assign deq_valid = deq_valid_comb;
assign deq_req_id = deq_req_id_comb;
assign deq_branch_id = deq_branch_id_comb;
assign deq_node_id = deq_node_id_comb;
assign deq_layer_id = deq_layer_id_comb;
assign deq_size_subbank = deq_size_subbank_comb;
assign deq_shared = deq_shared_comb;

// 队首选择逻辑：
// 1. 默认输出空值。
// 2. 如果队列非空，则总是把索引 0 的条目视为队首。
always @* begin
    deq_valid_comb = (entry_count_r != {PREFETCH_Q_COUNT_W{1'b0}});
    deq_req_id_comb = {`REQ_ID_W{1'b0}};
    deq_branch_id_comb = {`BRANCH_ID_W{1'b0}};
    deq_node_id_comb = {`NODE_ID_W{1'b0}};
    deq_layer_id_comb = {`LAYER_ID_W{1'b0}};
    deq_size_subbank_comb = {`KV_GROUP_LEN_W{1'b0}};
    deq_shared_comb = 1'b0;

    if (entry_count_r != {PREFETCH_Q_COUNT_W{1'b0}}) begin
        // 队首条目就是当前下一拍可能被 free_list 消费的工作项。
        deq_req_id_comb = entry_req_id_r[0];
        deq_branch_id_comb = entry_branch_id_r[0];
        deq_node_id_comb = entry_node_id_r[0];
        deq_layer_id_comb = entry_layer_id_r[0];
        deq_size_subbank_comb = entry_size_subbank_r[0];
        deq_shared_comb = entry_shared_r[0];
    end
end

// 队列重排逻辑：
// 1. 先把 next-state 清空。
// 2. 遍历旧队列，把“不被 flush 丢弃、也不是本拍正常出队”的条目重新紧凑打包。
// 3. 如果本拍有新入队，再把新条目追加在尾部。
always @* begin
    for (slot_i = 0; slot_i < `PREFETCH_Q_DEPTH; slot_i = slot_i + 1) begin
        entry_valid_n[slot_i] = 1'b0;
        entry_req_id_n[slot_i] = {`REQ_ID_W{1'b0}};
        entry_branch_id_n[slot_i] = {`BRANCH_ID_W{1'b0}};
        entry_node_id_n[slot_i] = {`NODE_ID_W{1'b0}};
        entry_layer_id_n[slot_i] = {`LAYER_ID_W{1'b0}};
        entry_size_subbank_n[slot_i] = {`KV_GROUP_LEN_W{1'b0}};
        entry_shared_n[slot_i] = 1'b0;
    end

    // pack_idx_i 表示 next-state 当前已经填到哪个位置。
    pack_idx_i = 0;
    for (slot_i = 0; slot_i < `PREFETCH_Q_DEPTH; slot_i = slot_i + 1) begin
        if (entry_valid_r[slot_i]) begin
            // branch_hit_comb：flush 的 branch 维度是否命中该条目。
            branch_hit_comb = 1'b0;

            // node_hit_comb：在 branch 已命中的前提下，node 维度是否也命中。
            node_hit_comb = 1'b0;

            // node_mask 是按“branch * 每分支最大节点数 + node_id”线性展开的。
            node_mask_index_i =
                (entry_branch_id_r[slot_i] * `MAX_VERIFY_NODES_PER_BRANCH) +
                entry_node_id_r[slot_i];

            // 只有 req_id、branch 都对上，才说明 flush 想删的是这个分支里的节点。
            if (flush_valid &&
                (entry_req_id_r[slot_i] == flush_req_id) &&
                (entry_branch_id_r[slot_i] < `BRANCH_NUM) &&
                flush_branch_mask[entry_branch_id_r[slot_i]]) begin
                branch_hit_comb = 1'b1;
            end

            // branch 命中之后，再进一步判断 node mask 是否命中具体节点。
            if (branch_hit_comb &&
                (node_mask_index_i >= 0) &&
                (node_mask_index_i < `NODE_MASK_W) &&
                flush_node_mask[node_mask_index_i]) begin
                node_hit_comb = 1'b1;
            end

            // 只有“没被 flush 删除”的条目才会保留下来。
            if (!(flush_valid && branch_hit_comb && node_hit_comb)) begin
                // 正常出队时，只删除队首且仅当本拍没有 flush。
                // 这样可以避免 flush 与正常出队同拍时出现二义性。
                if (!(deq_ready && deq_valid_comb && (slot_i == 0) && !flush_valid)) begin
                    entry_valid_n[pack_idx_i] = 1'b1;
                    entry_req_id_n[pack_idx_i] = entry_req_id_r[slot_i];
                    entry_branch_id_n[pack_idx_i] = entry_branch_id_r[slot_i];
                    entry_node_id_n[pack_idx_i] = entry_node_id_r[slot_i];
                    entry_layer_id_n[pack_idx_i] = entry_layer_id_r[slot_i];
                    entry_size_subbank_n[pack_idx_i] =
                        entry_size_subbank_r[slot_i];
                    entry_shared_n[pack_idx_i] = entry_shared_r[slot_i];
                    pack_idx_i = pack_idx_i + 1;
                end
            end
        end
    end

    // 在保留旧条目之后，再把新的入队条目追加到末尾。
    if (enq_valid && enq_ready) begin
        entry_valid_n[pack_idx_i] = 1'b1;
        entry_req_id_n[pack_idx_i] = enq_req_id;
        entry_branch_id_n[pack_idx_i] = enq_branch_id;
        entry_node_id_n[pack_idx_i] = enq_node_id;
        entry_layer_id_n[pack_idx_i] = enq_layer_id;
        entry_size_subbank_n[pack_idx_i] = enq_size_subbank;
        entry_shared_n[pack_idx_i] = enq_shared;
        pack_idx_i = pack_idx_i + 1;
    end

    // 最终 next-state 占用数就是打包后的条目数。
    entry_count_n = pack_idx_i[PREFETCH_Q_COUNT_W-1:0];
end

// 时序寄存器更新：
// 1. 复位时清空整个队列。
// 2. 正常时把组合算好的 next-state 写回。
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        entry_count_r <= {PREFETCH_Q_COUNT_W{1'b0}};
        for (slot_i = 0; slot_i < `PREFETCH_Q_DEPTH; slot_i = slot_i + 1) begin
            entry_valid_r[slot_i] <= 1'b0;
            entry_req_id_r[slot_i] <= {`REQ_ID_W{1'b0}};
            entry_branch_id_r[slot_i] <= {`BRANCH_ID_W{1'b0}};
            entry_node_id_r[slot_i] <= {`NODE_ID_W{1'b0}};
            entry_layer_id_r[slot_i] <= {`LAYER_ID_W{1'b0}};
            entry_size_subbank_r[slot_i] <= {`KV_GROUP_LEN_W{1'b0}};
            entry_shared_r[slot_i] <= 1'b0;
        end
    end else begin
        entry_count_r <= entry_count_n;
        for (slot_i = 0; slot_i < `PREFETCH_Q_DEPTH; slot_i = slot_i + 1) begin
            entry_valid_r[slot_i] <= entry_valid_n[slot_i];
            entry_req_id_r[slot_i] <= entry_req_id_n[slot_i];
            entry_branch_id_r[slot_i] <= entry_branch_id_n[slot_i];
            entry_node_id_r[slot_i] <= entry_node_id_n[slot_i];
            entry_layer_id_r[slot_i] <= entry_layer_id_n[slot_i];
            entry_size_subbank_r[slot_i] <= entry_size_subbank_n[slot_i];
            entry_shared_r[slot_i] <= entry_shared_n[slot_i];
        end
    end
end

endmodule
