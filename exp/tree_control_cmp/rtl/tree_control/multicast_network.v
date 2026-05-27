`include "config/interface_params.vh"
`include "config/memory_params.vh"
`timescale 1ns/1ps

/*
 * 文件作用：
 * 1. 本文件实现论文 TreeControl / SRAM 共享基础设施里的 multicast_network。
 * 2. 它消费的不是裸 `sram_subsystem` 返回 beat，而是 `request_controller`
 *    根据 SRAM 返回和保存的 `pe_mask/req_id` 重组后的多 lane 响应。
 * 3. 在论文完整路径和当前整合实现里，它位于：
 *    sram_subsystem
 *      -> request_controller(resp regroup)
 *      -> multicast_network
 *      -> 各个下游消费者（tree path、串行算子、KV commit 等）
 * 4. 它本质上不是计算模块，而是一个响应路由器：
 *    - 输入侧按 lane 收到若干条返回数据；
 *    - 输出侧按目标 PE 掩码把一条返回复制给多个消费者；
 *    - 同拍若两个 lane 争用同一个 PE，则后面的 lane 需要等待。
 * 5. 这个模块是树并行和串行路径共用的共享设施，不属于某条单独算法路径。
 */
module multicast_network #(
    parameter NUM_LANES = `MEM_REQ_LANES,
    parameter DATA_W = `SRAM_RDATA_W,
    parameter REQ_ID_W = `REQ_ID_W,
    parameter PE_MASK_W = `PE_MASK_W,
    parameter NUM_PES = `PE_MASK_W
) (
    // SRAM 响应输入：
    // 每个 lane 带一条返回数据、请求 id、目标 PE 掩码以及 last 标志。
    input  wire [NUM_LANES-1:0]                  resp_in_valid,
    output reg  [NUM_LANES-1:0]                  resp_in_ready,
    input  wire [NUM_LANES*DATA_W-1:0]           resp_in_rdata,
    input  wire [NUM_LANES*REQ_ID_W-1:0]         resp_in_req_id,
    input  wire [NUM_LANES*PE_MASK_W-1:0]        resp_in_pe_mask,
    input  wire [NUM_LANES-1:0]                  resp_in_last,

    // PE 输出：
    // 同一条 lane 响应可以被复制给多个 pe_i，只要 pe_mask 指向它们。
    output reg  [NUM_PES-1:0]                    pe_valid,
    input  wire [NUM_PES-1:0]                    pe_ready,
    output reg  [NUM_PES*DATA_W-1:0]             pe_rdata,
    output reg  [NUM_PES*REQ_ID_W-1:0]           pe_req_id,
    output reg  [NUM_PES*PE_MASK_W-1:0]          pe_mask,
    output reg  [NUM_PES-1:0]                    pe_last
);

// 循环变量。
integer lane_i;
integer pe_i;

// claimed_pe_mask_w：
// 当前组合拍里已经被前面 lane 占用过的 PE 集合。
reg [NUM_PES-1:0] claimed_pe_mask_w;

// lane_target_mask_w：
// 当前 lane 想发往哪些 PE。
reg [PE_MASK_W-1:0] lane_target_mask_w;

// lane_conflict_w：
// 当前 lane 是否与前面已经处理过的 lane 争抢了同一个 PE。
reg lane_conflict_w;

// lane_targets_ready_w：
// 当前 lane 指向的所有 PE 是否都 ready。
reg lane_targets_ready_w;

// 组合路由逻辑：
// 1. 先清空所有 ready/valid/数据。
// 2. 逐个 lane 扫描。
// 3. 若 lane 的目标 PE 与前面 lane 已 claim 的 PE 冲突，则当前 lane 不能被接受。
// 4. 若不冲突，则检查所有目标 PE 是否都 ready；只有全部 ready 才给该 lane ready。
// 5. 对每个被目标掩码命中的 PE，复制这条 lane 的数据/req_id/last。
always @* begin
    resp_in_ready = {NUM_LANES{1'b0}};
    pe_valid = {NUM_PES{1'b0}};
    pe_rdata = {(NUM_PES*DATA_W){1'b0}};
    pe_req_id = {(NUM_PES*REQ_ID_W){1'b0}};
    pe_mask = {(NUM_PES*PE_MASK_W){1'b0}};
    pe_last = {NUM_PES{1'b0}};
    claimed_pe_mask_w = {NUM_PES{1'b0}};

    for (lane_i = 0; lane_i < NUM_LANES; lane_i = lane_i + 1) begin
        // 取出当前 lane 的目标 PE 掩码。
        lane_target_mask_w = resp_in_pe_mask[(lane_i*PE_MASK_W) +: PE_MASK_W];
        lane_conflict_w = 1'b0;
        lane_targets_ready_w = 1'b1;

        if (resp_in_valid[lane_i]) begin
            // 如果当前 lane 想访问的任意一个 PE 已被前面 lane 占用，则本 lane 发生冲突。
            if ((lane_target_mask_w & claimed_pe_mask_w) != {PE_MASK_W{1'b0}}) begin
                lane_conflict_w = 1'b1;
                lane_targets_ready_w = 1'b0;
            end else begin
                // 不冲突时，要求所有目标 PE 都 ready，当前 lane 才能被真正接受。
                for (pe_i = 0; pe_i < NUM_PES; pe_i = pe_i + 1) begin
                    if (lane_target_mask_w[pe_i] && !pe_ready[pe_i]) begin
                        lane_targets_ready_w = 1'b0;
                    end
                end

                // 对掩码命中的每个 PE 复制同一份返回数据。
                for (pe_i = 0; pe_i < NUM_PES; pe_i = pe_i + 1) begin
                    if (lane_target_mask_w[pe_i]) begin
                        pe_valid[pe_i] = 1'b1;
                        pe_rdata[(pe_i*DATA_W) +: DATA_W] =
                            resp_in_rdata[(lane_i*DATA_W) +: DATA_W];
                        pe_req_id[(pe_i*REQ_ID_W) +: REQ_ID_W] =
                            resp_in_req_id[(lane_i*REQ_ID_W) +: REQ_ID_W];
                        pe_mask[(pe_i*PE_MASK_W) +: PE_MASK_W] = lane_target_mask_w;
                        pe_last[pe_i] = resp_in_last[lane_i];
                    end
                end

                // 记录这些 PE 已经被当前 lane 占用，后续 lane 不能再重复 claim。
                claimed_pe_mask_w = claimed_pe_mask_w | lane_target_mask_w;
            end

            if (!lane_conflict_w) begin
                // 空目标掩码的 lane 不需要等待任何 PE，直接 ready。
                if (lane_target_mask_w == {PE_MASK_W{1'b0}}) begin
                    resp_in_ready[lane_i] = 1'b1;
                end else begin
                    // 非空掩码时，必须等所有目标 PE ready。
                    resp_in_ready[lane_i] = lane_targets_ready_w;
                end
            end
        end
    end
end

endmodule
