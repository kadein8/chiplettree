`timescale 1ns/1ps

`include "config/prediction_params.vh"
`include "config/interface_params.vh"
`include "config/memory_params.vh"

/*
 * 文件作用：
 * 1. 本文件实现论文 TreeControl 前端资源路径里的 prefetch_queue。
 * 2. 它位于 `tree_analyze / AGU` 之后、`free_list / bank_state_table / token_register` 之前，
 *    负责把“等待后续资源处理”的树工作项缓冲起来。
 * 3. 按论文语义，这里保存的是“整层/多 branch bundle”，而不是旧实现里那种
 *    “单个 slot 条目 + 事后再包一层 slot0 bundle”的兼容结构。
 * 4. 旧标量 `enq_* / deq_*` 端口仍然保留，用于兼容旧调试链路；
 *    但正式 strict paper path 走的是 `bundle_enq_* / bundle_deq_*`。
 * 5. flush 到来时，队列会逐 bundle、逐 slot 清掉命中的 victim；
 *    只有还有幸存 slot 的 bundle 才会继续留在队列里。
 */
module prefetch_queue (
    // 时钟与复位。
    input                       clk,
    input                       rst_n,

    // 标量入队兼容口。
    input                       enq_valid,
    output                      enq_ready,
    input  [`REQ_ID_W-1:0]      enq_req_id,
    input  [`BRANCH_ID_W-1:0]   enq_branch_id,
    input  [`NODE_ID_W-1:0]     enq_node_id,
    input  [`LAYER_ID_W-1:0]    enq_layer_id,
    input  [`KV_GROUP_LEN_W-1:0] enq_size_subbank,
    input                       enq_shared,

    // 正式 bundle 入队口。
    input                       bundle_enq_valid,
    output                      bundle_enq_ready,
    input  [`REQ_ID_W-1:0]      bundle_enq_req_id,
    input  [`LAYER_ID_W-1:0]    bundle_enq_layer_id,
    input  [`TREE_FRONTIER_SLOTS-1:0] bundle_enq_slot_valid,
    input  [`TREE_FRONTIER_SLOTS*`BRANCH_ID_W-1:0] bundle_enq_branch_id,
    input  [`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0] bundle_enq_node_id,
    input  [`TREE_FRONTIER_SLOTS*`KV_GROUP_LEN_W-1:0] bundle_enq_size_subbank,
    input  [`TREE_FRONTIER_SLOTS-1:0] bundle_enq_shared,

    // flush 控制。
    input                       flush_valid,
    input  [`REQ_ID_W-1:0]      flush_req_id,
    input  [`BRANCH_MASK_W-1:0] flush_branch_mask,
    input  [`NODE_MASK_W-1:0]   flush_node_mask,

    // 正式 bundle 出队口。
    output                      bundle_deq_valid,
    input                       bundle_deq_ready,
    output [`REQ_ID_W-1:0]      bundle_deq_req_id,
    output [`LAYER_ID_W-1:0]    bundle_deq_layer_id,
    output [`TREE_FRONTIER_SLOTS-1:0] bundle_deq_slot_valid,
    output [`TREE_FRONTIER_SLOTS*`BRANCH_ID_W-1:0] bundle_deq_branch_id,
    output [`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0] bundle_deq_node_id,
    output [`TREE_FRONTIER_SLOTS*`KV_GROUP_LEN_W-1:0] bundle_deq_size_subbank,
    output [`TREE_FRONTIER_SLOTS-1:0] bundle_deq_shared,

    // 标量出队兼容口。
    output                      deq_valid,
    input                       deq_ready,
    output [`REQ_ID_W-1:0]      deq_req_id,
    output [`BRANCH_ID_W-1:0]   deq_branch_id,
    output [`NODE_ID_W-1:0]     deq_node_id,
    output [`LAYER_ID_W-1:0]    deq_layer_id,
    output [`KV_GROUP_LEN_W-1:0] deq_size_subbank,
    output                      deq_shared
);

// 计数器位宽：覆盖 0..PREFETCH_Q_DEPTH。
localparam integer PREFETCH_Q_COUNT_W =
    ((`PREFETCH_Q_DEPTH <= 1) ? 1 : $clog2(`PREFETCH_Q_DEPTH + 1));

// 当前队列寄存器：
// 每个 entry 保存一个完整 bundle。
reg entry_valid_r [0:`PREFETCH_Q_DEPTH-1];
reg [`REQ_ID_W-1:0] entry_req_id_r [0:`PREFETCH_Q_DEPTH-1];
reg [`LAYER_ID_W-1:0] entry_layer_id_r [0:`PREFETCH_Q_DEPTH-1];
reg [`TREE_FRONTIER_SLOTS-1:0] entry_slot_valid_r [0:`PREFETCH_Q_DEPTH-1];
reg [`TREE_FRONTIER_SLOTS*`BRANCH_ID_W-1:0]
    entry_branch_id_r [0:`PREFETCH_Q_DEPTH-1];
reg [`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0]
    entry_node_id_r [0:`PREFETCH_Q_DEPTH-1];
reg [`TREE_FRONTIER_SLOTS*`KV_GROUP_LEN_W-1:0]
    entry_size_subbank_r [0:`PREFETCH_Q_DEPTH-1];
reg [`TREE_FRONTIER_SLOTS-1:0] entry_shared_r [0:`PREFETCH_Q_DEPTH-1];
reg [PREFETCH_Q_COUNT_W-1:0] entry_count_r;

// 下一拍状态。
reg entry_valid_n [0:`PREFETCH_Q_DEPTH-1];
reg [`REQ_ID_W-1:0] entry_req_id_n [0:`PREFETCH_Q_DEPTH-1];
reg [`LAYER_ID_W-1:0] entry_layer_id_n [0:`PREFETCH_Q_DEPTH-1];
reg [`TREE_FRONTIER_SLOTS-1:0] entry_slot_valid_n [0:`PREFETCH_Q_DEPTH-1];
reg [`TREE_FRONTIER_SLOTS*`BRANCH_ID_W-1:0]
    entry_branch_id_n [0:`PREFETCH_Q_DEPTH-1];
reg [`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0]
    entry_node_id_n [0:`PREFETCH_Q_DEPTH-1];
reg [`TREE_FRONTIER_SLOTS*`KV_GROUP_LEN_W-1:0]
    entry_size_subbank_n [0:`PREFETCH_Q_DEPTH-1];
reg [`TREE_FRONTIER_SLOTS-1:0] entry_shared_n [0:`PREFETCH_Q_DEPTH-1];
reg [PREFETCH_Q_COUNT_W-1:0] entry_count_n;

// 队首 bundle 组合输出。
reg deq_valid_comb;
reg [`REQ_ID_W-1:0] deq_req_id_comb;
reg [`LAYER_ID_W-1:0] deq_layer_id_comb;
reg [`TREE_FRONTIER_SLOTS-1:0] deq_slot_valid_comb;
reg [`TREE_FRONTIER_SLOTS*`BRANCH_ID_W-1:0] deq_branch_id_comb;
reg [`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0] deq_node_id_comb;
reg [`TREE_FRONTIER_SLOTS*`KV_GROUP_LEN_W-1:0] deq_size_subbank_comb;
reg [`TREE_FRONTIER_SLOTS-1:0] deq_shared_comb;

// 旧标量兼容口的“队首第一个有效 slot”视图。
reg [`BRANCH_ID_W-1:0] deq_branch_id_scalar_comb;
reg [`NODE_ID_W-1:0] deq_node_id_scalar_comb;
reg [`KV_GROUP_LEN_W-1:0] deq_size_subbank_scalar_comb;
reg deq_shared_scalar_comb;
reg deq_scalar_slot_found_comb;

// 本拍是否消费了队首 entry。
reg active_deq_ready_comb;

// 本拍新入队 entry 的组合表示。
reg new_entry_valid_comb;
reg [`REQ_ID_W-1:0] new_entry_req_id_comb;
reg [`LAYER_ID_W-1:0] new_entry_layer_id_comb;
reg [`TREE_FRONTIER_SLOTS-1:0] new_entry_slot_valid_comb;
reg [`TREE_FRONTIER_SLOTS*`BRANCH_ID_W-1:0] new_entry_branch_id_comb;
reg [`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0] new_entry_node_id_comb;
reg [`TREE_FRONTIER_SLOTS*`KV_GROUP_LEN_W-1:0] new_entry_size_subbank_comb;
reg [`TREE_FRONTIER_SLOTS-1:0] new_entry_shared_comb;

// flush/重排辅助量。
integer slot_i;
integer queue_i;
integer pack_idx_i;
integer deq_pick_slot_i;
integer node_mask_index_i;
integer flush_branch_idx_i;
integer flush_node_id_i;
reg entry_any_slot_comb;
reg slot_flush_hit_comb;

// ready：只要还有空位，就允许新 bundle 进入。
assign enq_ready = (entry_count_r < `PREFETCH_Q_DEPTH);
assign bundle_enq_ready = (entry_count_r < `PREFETCH_Q_DEPTH);

// bundle 出队正式边界。
assign deq_valid = deq_valid_comb;
assign bundle_deq_valid = deq_valid_comb;
assign bundle_deq_req_id = deq_req_id_comb;
assign bundle_deq_layer_id = deq_layer_id_comb;
assign bundle_deq_slot_valid = deq_slot_valid_comb;
assign bundle_deq_branch_id = deq_branch_id_comb;
assign bundle_deq_node_id = deq_node_id_comb;
assign bundle_deq_size_subbank = deq_size_subbank_comb;
assign bundle_deq_shared = deq_shared_comb;

// 标量兼容口：仅暴露队首 bundle 里的第一个有效 slot。
assign deq_req_id = deq_req_id_comb;
assign deq_branch_id = deq_branch_id_scalar_comb;
assign deq_node_id = deq_node_id_scalar_comb;
assign deq_layer_id = deq_layer_id_comb;
assign deq_size_subbank = deq_size_subbank_scalar_comb;
assign deq_shared = deq_shared_scalar_comb;

// 本拍入队语义：
// 1. bundle_enq_* 优先于标量 enq_*；
// 2. bundle 会原样作为一个队列 entry 保存；
// 3. 标量兼容口只在没有 bundle 时才包成单 slot entry。
always @* begin
    new_entry_valid_comb = 1'b0;
    new_entry_req_id_comb = {`REQ_ID_W{1'b0}};
    new_entry_layer_id_comb = {`LAYER_ID_W{1'b0}};
    new_entry_slot_valid_comb = {`TREE_FRONTIER_SLOTS{1'b0}};
    new_entry_branch_id_comb =
        {(`TREE_FRONTIER_SLOTS*`BRANCH_ID_W){1'b0}};
    new_entry_node_id_comb =
        {(`TREE_FRONTIER_SLOTS*`NODE_ID_W){1'b0}};
    new_entry_size_subbank_comb =
        {(`TREE_FRONTIER_SLOTS*`KV_GROUP_LEN_W){1'b0}};
    new_entry_shared_comb = {`TREE_FRONTIER_SLOTS{1'b0}};

    if (bundle_enq_valid) begin
        new_entry_valid_comb = (bundle_enq_slot_valid != {`TREE_FRONTIER_SLOTS{1'b0}});
        new_entry_req_id_comb = bundle_enq_req_id;
        new_entry_layer_id_comb = bundle_enq_layer_id;
        new_entry_slot_valid_comb = bundle_enq_slot_valid;
        new_entry_branch_id_comb = bundle_enq_branch_id;
        new_entry_node_id_comb = bundle_enq_node_id;
        new_entry_size_subbank_comb = bundle_enq_size_subbank;
        new_entry_shared_comb = bundle_enq_shared;
    end else if (enq_valid) begin
        new_entry_valid_comb = 1'b1;
        new_entry_req_id_comb = enq_req_id;
        new_entry_layer_id_comb = enq_layer_id;
        new_entry_slot_valid_comb = {{(`TREE_FRONTIER_SLOTS-1){1'b0}}, 1'b1};
        new_entry_branch_id_comb =
            {{((`TREE_FRONTIER_SLOTS-1)*`BRANCH_ID_W){1'b0}}, enq_branch_id};
        new_entry_node_id_comb =
            {{((`TREE_FRONTIER_SLOTS-1)*`NODE_ID_W){1'b0}}, enq_node_id};
        new_entry_size_subbank_comb =
            {{((`TREE_FRONTIER_SLOTS-1)*`KV_GROUP_LEN_W){1'b0}},
             enq_size_subbank};
        new_entry_shared_comb =
            {{(`TREE_FRONTIER_SLOTS-1){1'b0}}, enq_shared};
    end
end

// 队首输出：
// 1. bundle 端口直接给出整个 head entry；
// 2. 标量兼容口扫描 head entry，取第一个有效 slot。
always @* begin
    active_deq_ready_comb = deq_ready || bundle_deq_ready;

    deq_valid_comb = (entry_count_r != {PREFETCH_Q_COUNT_W{1'b0}});
    deq_req_id_comb = {`REQ_ID_W{1'b0}};
    deq_layer_id_comb = {`LAYER_ID_W{1'b0}};
    deq_slot_valid_comb = {`TREE_FRONTIER_SLOTS{1'b0}};
    deq_branch_id_comb = {(`TREE_FRONTIER_SLOTS*`BRANCH_ID_W){1'b0}};
    deq_node_id_comb = {(`TREE_FRONTIER_SLOTS*`NODE_ID_W){1'b0}};
    deq_size_subbank_comb = {(`TREE_FRONTIER_SLOTS*`KV_GROUP_LEN_W){1'b0}};
    deq_shared_comb = {`TREE_FRONTIER_SLOTS{1'b0}};

    deq_branch_id_scalar_comb = {`BRANCH_ID_W{1'b0}};
    deq_node_id_scalar_comb = {`NODE_ID_W{1'b0}};
    deq_size_subbank_scalar_comb = {`KV_GROUP_LEN_W{1'b0}};
    deq_shared_scalar_comb = 1'b0;
    deq_scalar_slot_found_comb = 1'b0;

    if (deq_valid_comb) begin
        deq_req_id_comb = entry_req_id_r[0];
        deq_layer_id_comb = entry_layer_id_r[0];
        deq_slot_valid_comb = entry_slot_valid_r[0];
        deq_branch_id_comb = entry_branch_id_r[0];
        deq_node_id_comb = entry_node_id_r[0];
        deq_size_subbank_comb = entry_size_subbank_r[0];
        deq_shared_comb = entry_shared_r[0];

        for (deq_pick_slot_i = 0;
             deq_pick_slot_i < `TREE_FRONTIER_SLOTS;
             deq_pick_slot_i = deq_pick_slot_i + 1) begin
            if (!deq_scalar_slot_found_comb &&
                entry_slot_valid_r[0][deq_pick_slot_i]) begin
                deq_scalar_slot_found_comb = 1'b1;
                deq_branch_id_scalar_comb =
                    entry_branch_id_r[0][
                        (deq_pick_slot_i*`BRANCH_ID_W) +: `BRANCH_ID_W];
                deq_node_id_scalar_comb =
                    entry_node_id_r[0][
                        (deq_pick_slot_i*`NODE_ID_W) +: `NODE_ID_W];
                deq_size_subbank_scalar_comb =
                    entry_size_subbank_r[0][
                        (deq_pick_slot_i*`KV_GROUP_LEN_W) +:
                        `KV_GROUP_LEN_W];
                deq_shared_scalar_comb =
                    entry_shared_r[0][deq_pick_slot_i];
            end
        end
    end
end

// 队列 next-state：
// 1. 先保留未被 pop/flush 清掉的旧 bundle；
// 2. flush 在 bundle 内逐 slot 裁剪；
// 3. 整个 bundle 全空时丢弃；
// 4. 最后把本拍新 bundle 追加到队尾。
always @* begin
    for (queue_i = 0; queue_i < `PREFETCH_Q_DEPTH; queue_i = queue_i + 1) begin
        entry_valid_n[queue_i] = 1'b0;
        entry_req_id_n[queue_i] = {`REQ_ID_W{1'b0}};
        entry_layer_id_n[queue_i] = {`LAYER_ID_W{1'b0}};
        entry_slot_valid_n[queue_i] = {`TREE_FRONTIER_SLOTS{1'b0}};
        entry_branch_id_n[queue_i] = {(`TREE_FRONTIER_SLOTS*`BRANCH_ID_W){1'b0}};
        entry_node_id_n[queue_i] = {(`TREE_FRONTIER_SLOTS*`NODE_ID_W){1'b0}};
        entry_size_subbank_n[queue_i] =
            {(`TREE_FRONTIER_SLOTS*`KV_GROUP_LEN_W){1'b0}};
        entry_shared_n[queue_i] = {`TREE_FRONTIER_SLOTS{1'b0}};
    end

    pack_idx_i = 0;
    for (queue_i = 0; queue_i < `PREFETCH_Q_DEPTH; queue_i = queue_i + 1) begin
        if (entry_valid_r[queue_i]) begin
            // pop 优先于正常保留；若同拍有 flush，则先按 flush 语义裁剪，不直接 pop。
            if (!(active_deq_ready_comb &&
                  deq_valid_comb &&
                  (queue_i == 0) &&
                  !flush_valid)) begin
                entry_req_id_n[pack_idx_i] = entry_req_id_r[queue_i];
                entry_layer_id_n[pack_idx_i] = entry_layer_id_r[queue_i];
                entry_slot_valid_n[pack_idx_i] = entry_slot_valid_r[queue_i];
                entry_branch_id_n[pack_idx_i] = entry_branch_id_r[queue_i];
                entry_node_id_n[pack_idx_i] = entry_node_id_r[queue_i];
                entry_size_subbank_n[pack_idx_i] = entry_size_subbank_r[queue_i];
                entry_shared_n[pack_idx_i] = entry_shared_r[queue_i];

                entry_any_slot_comb = 1'b0;
                for (slot_i = 0;
                     slot_i < `TREE_FRONTIER_SLOTS;
                     slot_i = slot_i + 1) begin
                    slot_flush_hit_comb = 1'b0;
                    if (flush_valid &&
                        entry_slot_valid_r[queue_i][slot_i] &&
                        (entry_req_id_r[queue_i] == flush_req_id)) begin
                        flush_branch_idx_i =
                            {{(32-`BRANCH_ID_W){1'b0}},
                             entry_branch_id_r[queue_i][
                                 (slot_i*`BRANCH_ID_W) +: `BRANCH_ID_W]};
                        flush_node_id_i =
                            {{(32-`NODE_ID_W){1'b0}},
                             entry_node_id_r[queue_i][
                                 (slot_i*`NODE_ID_W) +: `NODE_ID_W]};
                        node_mask_index_i =
                            (flush_branch_idx_i *
                             `MAX_VERIFY_NODES_PER_BRANCH) +
                            flush_node_id_i;
                        if ((flush_branch_idx_i < `BRANCH_NUM) &&
                            flush_branch_mask[flush_branch_idx_i] &&
                            (node_mask_index_i < `NODE_MASK_W) &&
                            flush_node_mask[node_mask_index_i]) begin
                            slot_flush_hit_comb = 1'b1;
                        end
                    end

                    if (slot_flush_hit_comb) begin
                        entry_slot_valid_n[pack_idx_i][slot_i] = 1'b0;
                    end

                    if (entry_slot_valid_n[pack_idx_i][slot_i]) begin
                        entry_any_slot_comb = 1'b1;
                    end
                end

                if (entry_any_slot_comb) begin
                    entry_valid_n[pack_idx_i] = 1'b1;
                    pack_idx_i = pack_idx_i + 1;
                end
            end
        end
    end

    if (new_entry_valid_comb && enq_ready) begin
        entry_valid_n[pack_idx_i] = 1'b1;
        entry_req_id_n[pack_idx_i] = new_entry_req_id_comb;
        entry_layer_id_n[pack_idx_i] = new_entry_layer_id_comb;
        entry_slot_valid_n[pack_idx_i] = new_entry_slot_valid_comb;
        entry_branch_id_n[pack_idx_i] = new_entry_branch_id_comb;
        entry_node_id_n[pack_idx_i] = new_entry_node_id_comb;
        entry_size_subbank_n[pack_idx_i] = new_entry_size_subbank_comb;
        entry_shared_n[pack_idx_i] = new_entry_shared_comb;
        pack_idx_i = pack_idx_i + 1;
    end

    entry_count_n = pack_idx_i[PREFETCH_Q_COUNT_W-1:0];
end

// 时序寄存器更新。
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        entry_count_r <= {PREFETCH_Q_COUNT_W{1'b0}};
        for (queue_i = 0; queue_i < `PREFETCH_Q_DEPTH; queue_i = queue_i + 1) begin
            entry_valid_r[queue_i] <= 1'b0;
            entry_req_id_r[queue_i] <= {`REQ_ID_W{1'b0}};
            entry_layer_id_r[queue_i] <= {`LAYER_ID_W{1'b0}};
            entry_slot_valid_r[queue_i] <= {`TREE_FRONTIER_SLOTS{1'b0}};
            entry_branch_id_r[queue_i] <= {(`TREE_FRONTIER_SLOTS*`BRANCH_ID_W){1'b0}};
            entry_node_id_r[queue_i] <= {(`TREE_FRONTIER_SLOTS*`NODE_ID_W){1'b0}};
            entry_size_subbank_r[queue_i] <=
                {(`TREE_FRONTIER_SLOTS*`KV_GROUP_LEN_W){1'b0}};
            entry_shared_r[queue_i] <= {`TREE_FRONTIER_SLOTS{1'b0}};
        end
    end else begin
        entry_count_r <= entry_count_n;
        for (queue_i = 0; queue_i < `PREFETCH_Q_DEPTH; queue_i = queue_i + 1) begin
            entry_valid_r[queue_i] <= entry_valid_n[queue_i];
            entry_req_id_r[queue_i] <= entry_req_id_n[queue_i];
            entry_layer_id_r[queue_i] <= entry_layer_id_n[queue_i];
            entry_slot_valid_r[queue_i] <= entry_slot_valid_n[queue_i];
            entry_branch_id_r[queue_i] <= entry_branch_id_n[queue_i];
            entry_node_id_r[queue_i] <= entry_node_id_n[queue_i];
            entry_size_subbank_r[queue_i] <= entry_size_subbank_n[queue_i];
            entry_shared_r[queue_i] <= entry_shared_n[queue_i];
        end
    end
end

endmodule
