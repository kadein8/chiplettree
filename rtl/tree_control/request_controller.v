`include "config/prediction_params.vh"
`timescale 1ns/1ps

`include "config/interface_params.vh"
`include "config/memory_params.vh"

/*
 * 文件作用：
 * 1. 本文件实现论文 TreeControl / transformer 共享访存基础设施中的 request_controller。
 * 2. 它位于上层算子/树控制逻辑与下层 sram_subsystem 之间，负责把：
 *    - 单路标量请求 `req_in_*`
 *    - 多路向量请求 `vec_req_*`
 *    统一整理成 `mem_req_*` 多 lane 请求，并把 `mem_resp_*` 再转换成统一响应。
 * 3. 在完整路径里，它位于：
 *    fp16_inference_top / TreeControl / kv_commit / prep
 *      -> request_controller
 *      -> sram_subsystem
 *      -> multicast_network
 * 4. 这个模块最重要的行为有四类：
 *    - 收集多个标量读请求，尽量在进入 SRAM 前做成一组 lane 请求；
 *    - 对同地址读做 merge，只发一次真实 SRAM 读；
 *    - 对“读命中前面同地址写”做 bypass，直接用写数据返回；
 *    - 维护响应阶段，把 bypass / merge / 真 SRAM 读返回统一整理给下游。
 * 5. 因此它既是“请求收集器”，也是“同地址去重/旁路器”，还是“响应重组器”。
 */
module request_controller (
    // 时钟与复位。
    input                                               clk,
    input                                               rst_n,

    // 标量请求入口：
    // 用于 tree path、prep、kv_commit 等按单条请求推进的上游。
    input                                               req_in_valid,
    output                                              req_in_ready,
    input                                               req_in_write,
    input  [`SRAM_ADDR_W-1:0]                           req_in_addr,
    input  [`SRAM_WDATA_W-1:0]                          req_in_wdata,
    input  [`REQ_ID_W-1:0]                              req_in_req_id,
    input  [`PE_MASK_W-1:0]                             req_in_pe_mask,
    input  [`REQ_PRIORITY_W-1:0]                        req_in_priority,
    input  [`BANK_ID_W-1:0]                             req_in_bank_id,
    input  [`SUBBANK_ID_W-1:0]                          req_in_subbank_id,

    // 向量请求入口：
    // 用于多 lane 直接并发的算子请求。
    input  [`MEM_REQ_LANES-1:0]                         vec_req_valid,
    output [`MEM_REQ_LANES-1:0]                         vec_req_ready,
    input  [`MEM_REQ_LANES-1:0]                         vec_req_write,
    input  [`MEM_REQ_LANES*`SRAM_ADDR_W-1:0]            vec_req_addr,
    input  [`MEM_REQ_LANES*`SRAM_WDATA_W-1:0]           vec_req_wdata,
    input  [`MEM_REQ_LANES*`REQ_ID_W-1:0]               vec_req_req_id,
    input  [`MEM_REQ_LANES*`PE_MASK_W-1:0]              vec_req_pe_mask,
    input  [`MEM_REQ_LANES*`REQ_PRIORITY_W-1:0]         vec_req_priority,
    input  [`MEM_REQ_LANES*`BANK_ID_W-1:0]              vec_req_bank_id,
    input  [`MEM_REQ_LANES*`SUBBANK_ID_W-1:0]           vec_req_subbank_id,

    // 发往底层 sram_subsystem 的多 lane 请求接口。
    output [`MEM_REQ_LANES-1:0]                         mem_req_valid,
    input  [`MEM_REQ_LANES-1:0]                         mem_req_ready,
    output [`MEM_REQ_LANES-1:0]                         mem_req_write,
    output [`MEM_REQ_LANES*`SRAM_ADDR_W-1:0]            mem_req_addr,
    output [`MEM_REQ_LANES*`SRAM_WDATA_W-1:0]           mem_req_wdata,
    output [`MEM_REQ_LANES*`REQ_ID_W-1:0]               mem_req_id,
    input  [`MEM_REQ_LANES-1:0]                         mem_resp_valid,
    input  [`MEM_REQ_LANES*`SRAM_RDATA_W-1:0]           mem_resp_rdata,
    input  [`MEM_REQ_LANES*`REQ_ID_W-1:0]               mem_resp_id,
    input  [`MEM_REQ_LANES-1:0]                         mem_resp_last,

    // 对外统一响应接口：
    // 后续通常会接 multicast_network，把每 lane 响应再分发到具体消费者。
    output [`MEM_REQ_LANES-1:0]                         resp_out_valid,
    input  [`MEM_REQ_LANES-1:0]                         resp_out_ready,
    output [`MEM_REQ_LANES*`SRAM_RDATA_W-1:0]           resp_out_rdata,
    output [`MEM_REQ_LANES*`REQ_ID_W-1:0]               resp_out_req_id,
    output [`MEM_REQ_LANES*`PE_MASK_W-1:0]              resp_out_pe_mask,
    output [`MEM_REQ_LANES-1:0]                         resp_out_last
);

// 状态机语义：
// STATE_IDLE      : 等待一组新请求进入控制器。
// STATE_COLLECT   : 已收下第一条标量读，继续尝试收集更多可并行/可 merge 的标量请求。
// STATE_ISSUE     : 把本组请求发往 sram_subsystem，并在同拍捕获可能立即可得的响应。
// STATE_WAIT_RESP : 已完成请求发射，但仍在等待真实 SRAM 读响应回来。
// STATE_RESP      : 把已经整理好的响应对外送出，等待下游 ready 消费。
localparam [2:0] STATE_IDLE      = 3'd0;
localparam [2:0] STATE_COLLECT   = 3'd1;
localparam [2:0] STATE_ISSUE     = 3'd2;
localparam [2:0] STATE_WAIT_RESP = 3'd3;
localparam [2:0] STATE_RESP      = 3'd4;

localparam integer LANE_IDX_W =
    ((`MEM_REQ_LANES <= 1) ? 1 : $clog2(`MEM_REQ_LANES));
localparam integer SRAM_ID_LSB =
    (`OFFSET_W + `ROW_ADDR_W + `SUBBANK_ID_W + `BANK_ID_W);

// 主状态。
reg [2:0] state_r;

// collect_wait_r：
// 在 COLLECT 态里用于实现“再等一拍看看是否还有新标量请求”的小等待窗。
reg collect_wait_r;

// 当前请求组的 lane 台账：
// lane_valid_r      : 此 lane 是否已有有效条目。
// lane_merge_r      : 此 lane 是否并不真正发 SRAM，而是复用别的 lane 的读结果。
// lane_write_r      : 此 lane 是否写请求。
// lane_bypass_r     : 此 lane 是否用旁路数据直接完成，不走真实 SRAM 读。
// lane_issued_r     : 此 lane 对应的真实请求是否已经被底层接受。
reg [`MEM_REQ_LANES-1:0] lane_valid_r;
reg [`MEM_REQ_LANES-1:0] lane_merge_r;
reg [`MEM_REQ_LANES-1:0] lane_write_r;
reg [`MEM_REQ_LANES-1:0] lane_bypass_r;
reg [`MEM_REQ_LANES-1:0] lane_issued_r;
reg [`MEM_REQ_LANES*`SRAM_ADDR_W-1:0] lane_addr_r;
reg [`MEM_REQ_LANES*`SRAM_WDATA_W-1:0] lane_wdata_r;
reg [`MEM_REQ_LANES*`SRAM_RDATA_W-1:0] lane_bypass_data_r;
reg [`MEM_REQ_LANES*`REQ_ID_W-1:0] lane_req_id_r;
reg [`MEM_REQ_LANES*`PE_MASK_W-1:0] lane_pe_mask_r;
reg [`MEM_REQ_LANES*`REQ_PRIORITY_W-1:0] lane_priority_r;
reg [`MEM_REQ_LANES*`BANK_ID_W-1:0] lane_bank_id_r;
reg [`MEM_REQ_LANES*`SUBBANK_ID_W-1:0] lane_subbank_id_r;

// 对 merge lane，记住它真正依附的“根读 lane”是谁。
reg [LANE_IDX_W-1:0] lane_merge_src_r [0:`MEM_REQ_LANES-1];

// 发往 sram_subsystem 的组合请求。
reg [`MEM_REQ_LANES-1:0] mem_req_valid_c;
reg [`MEM_REQ_LANES-1:0] mem_req_write_c;
reg [`MEM_REQ_LANES*`SRAM_ADDR_W-1:0] mem_req_addr_c;
reg [`MEM_REQ_LANES*`SRAM_WDATA_W-1:0] mem_req_wdata_c;
reg [`MEM_REQ_LANES*`REQ_ID_W-1:0] mem_req_id_c;

// 已锁存的响应，与“本拍新得到的响应”组合量。
reg [`MEM_REQ_LANES-1:0] resp_valid_r;
reg [`MEM_REQ_LANES*`SRAM_RDATA_W-1:0] resp_rdata_r;
reg [`MEM_REQ_LANES*`REQ_ID_W-1:0] resp_req_id_r;
reg [`MEM_REQ_LANES*`PE_MASK_W-1:0] resp_pe_mask_r;
reg [`MEM_REQ_LANES-1:0] resp_last_r;
reg [`MEM_REQ_LANES-1:0] resp_now_valid_c;
reg [`MEM_REQ_LANES*`SRAM_RDATA_W-1:0] resp_now_rdata_c;
reg [`MEM_REQ_LANES*`REQ_ID_W-1:0] resp_now_req_id_c;
reg [`MEM_REQ_LANES*`PE_MASK_W-1:0] resp_now_pe_mask_c;
reg [`MEM_REQ_LANES-1:0] resp_now_last_c;
reg [`MEM_REQ_LANES*`SRAM_RDATA_W-1:0] resp_out_rdata_c;
reg [`MEM_REQ_LANES*`REQ_ID_W-1:0] resp_out_req_id_c;
reg [`MEM_REQ_LANES*`PE_MASK_W-1:0] resp_out_pe_mask_c;
reg [`MEM_REQ_LANES-1:0] resp_out_last_c;

// collect / accept / issue / resp 组合判定标志。
reg collect_ready_c;
reg accept_same_addr_merge_c;
reg accept_same_addr_bypass_c;
reg accept_read_after_write_bypass_c;
reg accept_independent_c;
reg accept_has_free_c;
reg merge_group_only_c;
reg merge_lane_present_c;
reg write_lane_present_c;
reg resource_conflict_c;
reg [LANE_IDX_W-1:0] accept_lane_idx_c;
reg [LANE_IDX_W-1:0] accept_store_idx_c;
reg [LANE_IDX_W-1:0] accept_merge_root_idx_c;
reg [LANE_IDX_W-1:0] accept_bypass_source_idx_c;
reg issue_ready_c;
reg issue_has_response_c;
reg issue_has_sram_read_c;
reg issue_all_reqs_accepted_c;
reg resp_complete_c;
reg vec_group_supported_c;
reg vec_any_valid_c;
reg [`MEM_REQ_LANES-1:0] vec_req_valid_mask_c;
reg [`MEM_REQ_LANES-1:0] vec_lane_valid_c;
reg [`MEM_REQ_LANES-1:0] vec_lane_write_c;
reg [`MEM_REQ_LANES-1:0] vec_lane_bypass_c;
reg [`MEM_REQ_LANES-1:0] vec_lane_merge_c;
reg [`MEM_REQ_LANES*`SRAM_ADDR_W-1:0] vec_lane_addr_c;
reg [`MEM_REQ_LANES*`SRAM_WDATA_W-1:0] vec_lane_wdata_c;
reg [`MEM_REQ_LANES*`SRAM_RDATA_W-1:0] vec_lane_bypass_data_c;
reg [`MEM_REQ_LANES*`REQ_ID_W-1:0] vec_lane_req_id_c;
reg [`MEM_REQ_LANES*`PE_MASK_W-1:0] vec_lane_pe_mask_c;
reg [`MEM_REQ_LANES*`REQ_PRIORITY_W-1:0] vec_lane_priority_c;
reg [`MEM_REQ_LANES*`BANK_ID_W-1:0] vec_lane_bank_id_c;
reg [`MEM_REQ_LANES*`SUBBANK_ID_W-1:0] vec_lane_subbank_id_c;
reg [LANE_IDX_W-1:0] vec_lane_merge_src_c [0:`MEM_REQ_LANES-1];
reg vec_accept_same_addr_merge_c;
reg [LANE_IDX_W-1:0] vec_accept_merge_root_idx_c;
reg [LANE_IDX_W-1:0] vec_root_idx_c;

// 循环变量。
integer lane_i;
integer reset_i;
integer resp_i;
integer shift_i;
integer root_lane_i;
integer update_i;
integer update_root_i;
integer vec_i;
integer vec_j;

// ready 语义：
// 1. IDLE 且没有向量组抢占时，标量入口可直接接收第一条请求。
// 2. COLLECT 态里，只有当前请求满足 collect_ready_c 的收集规则时才接收。
assign req_in_ready =
    (((state_r == STATE_IDLE) && !vec_any_valid_c) ||
     ((state_r == STATE_COLLECT) && req_in_valid && collect_ready_c));
assign vec_req_ready =
    ({`MEM_REQ_LANES{
        (state_r == STATE_IDLE) &&
        !req_in_valid &&
        vec_group_supported_c
    }} & vec_req_valid_mask_c);

// 组合请求直连到底层 SRAM 子系统。
assign mem_req_valid = mem_req_valid_c;
assign mem_req_write = mem_req_write_c;
assign mem_req_addr = mem_req_addr_c;
assign mem_req_wdata = mem_req_wdata_c;
assign mem_req_id = mem_req_id_c;

// 对外响应来自当前已经锁存好的 resp_valid_r / resp_out_*_c。
assign resp_out_valid = resp_valid_r;
assign resp_out_rdata = resp_out_rdata_c;
assign resp_out_req_id = resp_out_req_id_c;
assign resp_out_pe_mask = resp_out_pe_mask_c;
assign resp_out_last = resp_out_last_c;

// 向量入口预处理：
// 1. 把 `vec_req_valid` 规整成纯 0/1 掩码；
// 2. 直接把向量请求的各字段拷到内部临时阵列；
// 3. 对同地址读做组内 merge，避免一个向量组自己内部重复发同地址读。
always @* begin
    vec_req_valid_mask_c = {`MEM_REQ_LANES{1'b0}};
    for (vec_i = 0; vec_i < `MEM_REQ_LANES; vec_i = vec_i + 1) begin
        // 只把严格等于 1'b1 的位视为有效，屏蔽 x/z。
        vec_req_valid_mask_c[vec_i] = (vec_req_valid[vec_i] === 1'b1);
    end

    // 缺省情况下，向量组整体是支持的，并且先原样透传所有字段。
    vec_any_valid_c = |vec_req_valid_mask_c;
    vec_group_supported_c = 1'b1;
    vec_lane_valid_c = vec_req_valid_mask_c;
    vec_lane_write_c = vec_req_write;
    vec_lane_bypass_c = {`MEM_REQ_LANES{1'b0}};
    vec_lane_merge_c = {`MEM_REQ_LANES{1'b0}};
    vec_lane_addr_c = vec_req_addr;
    vec_lane_wdata_c = vec_req_wdata;
    vec_lane_bypass_data_c = {(`MEM_REQ_LANES*`SRAM_RDATA_W){1'b0}};
    vec_lane_req_id_c = vec_req_req_id;
    vec_lane_pe_mask_c = vec_req_pe_mask;
    vec_lane_priority_c = vec_req_priority;
    vec_lane_bank_id_c = vec_req_bank_id;
    vec_lane_subbank_id_c = vec_req_subbank_id;
    for (vec_i = 0; vec_i < `MEM_REQ_LANES; vec_i = vec_i + 1) begin
        vec_lane_merge_src_c[vec_i] = {LANE_IDX_W{1'b0}};
    end
    vec_accept_same_addr_merge_c = 1'b0;
    vec_accept_merge_root_idx_c = {LANE_IDX_W{1'b0}};
    vec_root_idx_c = {LANE_IDX_W{1'b0}};

    for (vec_i = 0; vec_i < `MEM_REQ_LANES; vec_i = vec_i + 1) begin
        if (vec_req_valid_mask_c[vec_i] && vec_group_supported_c) begin
            vec_accept_same_addr_merge_c = 1'b0;
            vec_accept_merge_root_idx_c = {LANE_IDX_W{1'b0}};

            for (vec_j = 0; vec_j < vec_i; vec_j = vec_j + 1) begin
                if (vec_req_valid_mask_c[vec_j]) begin
                    // vec_root_idx_c 表示 vec_j 所归属的根 lane。
                    vec_root_idx_c = vec_j[LANE_IDX_W-1:0];
                    if (vec_lane_merge_c[vec_j]) begin
                        vec_root_idx_c = vec_lane_merge_src_c[vec_j];
                    end

                    // 只有“当前是读、根 lane 也是读、地址完全相同”时才允许 merge。
                    if (!vec_req_write[vec_i] &&
                        !vec_lane_write_c[vec_root_idx_c] &&
                        (vec_req_addr[(vec_i*`SRAM_ADDR_W) +: `SRAM_ADDR_W] ==
                         vec_lane_addr_c[(vec_root_idx_c*`SRAM_ADDR_W) +: `SRAM_ADDR_W])) begin
                        vec_accept_same_addr_merge_c = 1'b1;
                        vec_accept_merge_root_idx_c = vec_root_idx_c;
                    end
                end
            end

            if (vec_accept_same_addr_merge_c) begin
                // 把当前 vec_i 标记成 merge lane，并指向它的根 lane。
                vec_lane_merge_c[vec_i] = 1'b1;
                vec_lane_merge_src_c[vec_i] = vec_accept_merge_root_idx_c;
            end
        end
    end
end

// 主组合分析块：
// 1. 分析 COLLECT 态下当前标量请求是否能被吸收入组；
// 2. 分析 ISSUE/WAIT_RESP 阶段真实该往 SRAM 发什么；
// 3. 把 bypass / merge / SRAM 返回统一整理成响应。
always @* begin
    collect_ready_c = 1'b0;
    accept_same_addr_merge_c = 1'b0;
    accept_same_addr_bypass_c = 1'b0;
    accept_read_after_write_bypass_c = 1'b0;
    accept_independent_c = 1'b0;
    accept_has_free_c = 1'b0;
    merge_group_only_c = 1'b1;
    merge_lane_present_c = 1'b0;
    write_lane_present_c = 1'b0;
    resource_conflict_c = 1'b0;
    accept_lane_idx_c = {LANE_IDX_W{1'b0}};
    accept_store_idx_c = {LANE_IDX_W{1'b0}};
    accept_merge_root_idx_c = {LANE_IDX_W{1'b0}};
    accept_bypass_source_idx_c = {LANE_IDX_W{1'b0}};
    issue_ready_c = 1'b0;
    issue_has_response_c = 1'b0;
    issue_has_sram_read_c = 1'b0;
    issue_all_reqs_accepted_c = 1'b0;
    resp_complete_c = 1'b0;

    mem_req_valid_c = {`MEM_REQ_LANES{1'b0}};
    mem_req_write_c = {`MEM_REQ_LANES{1'b0}};
    mem_req_addr_c = {(`MEM_REQ_LANES*`SRAM_ADDR_W){1'b0}};
    mem_req_wdata_c = {(`MEM_REQ_LANES*`SRAM_WDATA_W){1'b0}};
    mem_req_id_c = {(`MEM_REQ_LANES*`REQ_ID_W){1'b0}};
    resp_now_valid_c = {`MEM_REQ_LANES{1'b0}};
    resp_now_rdata_c = {(`MEM_REQ_LANES*`SRAM_RDATA_W){1'b0}};
    resp_now_req_id_c = {(`MEM_REQ_LANES*`REQ_ID_W){1'b0}};
    resp_now_pe_mask_c = {(`MEM_REQ_LANES*`PE_MASK_W){1'b0}};
    resp_now_last_c = {`MEM_REQ_LANES{1'b0}};
    resp_out_rdata_c = {(`MEM_REQ_LANES*`SRAM_RDATA_W){1'b0}};
    resp_out_req_id_c = {(`MEM_REQ_LANES*`REQ_ID_W){1'b0}};
    resp_out_pe_mask_c = {(`MEM_REQ_LANES*`PE_MASK_W){1'b0}};
    resp_out_last_c = {`MEM_REQ_LANES{1'b0}};

    // 在已有 lane 中找第一个空位，用于 COLLECT 态装新条目。
    for (lane_i = 1; lane_i < `MEM_REQ_LANES; lane_i = lane_i + 1) begin
        if (!lane_valid_r[lane_i] && !accept_has_free_c) begin
            accept_has_free_c = 1'b1;
            accept_lane_idx_c = lane_i[LANE_IDX_W-1:0];
        end
    end

    // 先扫描已有 lane，提取几类全局信息：
    // 1. 是否已有 merge lane；
    // 2. 是否已有写 lane；
    // 3. 新请求若与已有真实 SRAM 访问落在同一物理资源上，是否会形成 resource conflict。
    for (lane_i = 0; lane_i < `MEM_REQ_LANES; lane_i = lane_i + 1) begin
        if (lane_valid_r[lane_i] && lane_merge_r[lane_i]) begin
            merge_lane_present_c = 1'b1;
        end

        if (lane_valid_r[lane_i] && lane_write_r[lane_i]) begin
            write_lane_present_c = 1'b1;
        end

        if (lane_valid_r[lane_i] && !lane_merge_r[lane_i] &&
            !lane_bypass_r[lane_i]) begin
            // resource_conflict 只看真正要进 SRAM 的那些 lane。
            if (req_in_addr[SRAM_ID_LSB +: `SRAM_ID_W] ==
                    lane_addr_r[(lane_i*`SRAM_ADDR_W + SRAM_ID_LSB) +: `SRAM_ID_W] &&
                req_in_bank_id ==
                    lane_bank_id_r[(lane_i*`BANK_ID_W) +: `BANK_ID_W] &&
                req_in_subbank_id ==
                    lane_subbank_id_r[(lane_i*`SUBBANK_ID_W) +: `SUBBANK_ID_W]) begin
                resource_conflict_c = 1'b1;
            end
        end

        if ((lane_i != 0) && lane_valid_r[lane_i] && !lane_merge_r[lane_i]) begin
            merge_group_only_c = 1'b0;
        end
    end

    // accept_store_idx_c：
    // 标量收集时最终要把新请求放到哪个槽位，默认就是第一个空位。
    accept_store_idx_c = accept_lane_idx_c;
    if ((state_r == STATE_COLLECT) && accept_has_free_c) begin
        for (lane_i = 0; lane_i < `MEM_REQ_LANES; lane_i = lane_i + 1) begin
            if (lane_valid_r[lane_i]) begin
                // root_lane_i：
                // 如果 lane_i 自己就是 merge lane，则它真正依附的根 lane 才是比较对象。
                root_lane_i = lane_i;
                if (lane_merge_r[lane_i]) begin
                    root_lane_i = lane_merge_src_r[lane_i];
                end

                // 情况 1：新请求是读，且与已有读根 lane 同地址。
                // 这种情况下允许把新请求作为 merge lane 吸收进来。
                if (!req_in_write &&
                    !lane_write_r[root_lane_i] &&
                    !lane_bypass_r[root_lane_i] &&
                    (req_in_addr ==
                        lane_addr_r[(root_lane_i*`SRAM_ADDR_W) +: `SRAM_ADDR_W]) &&
                    !accept_same_addr_merge_c &&
                    !accept_read_after_write_bypass_c &&
                    !lane_bypass_r[lane_i]) begin
                    accept_same_addr_merge_c = 1'b1;
                    accept_merge_root_idx_c = root_lane_i[LANE_IDX_W-1:0];
                end

                // 情况 2：新请求是读，但前面已有同地址写。
                // 则无需再发 SRAM 读，直接从该写数据做 bypass。
                if (!req_in_write &&
                    lane_write_r[lane_i] &&
                    (req_in_addr ==
                        lane_addr_r[(lane_i*`SRAM_ADDR_W) +: `SRAM_ADDR_W]) &&
                    !accept_read_after_write_bypass_c) begin
                    accept_read_after_write_bypass_c = 1'b1;
                    accept_bypass_source_idx_c = lane_i[LANE_IDX_W-1:0];
                    accept_same_addr_merge_c = 1'b0;
                end

                // 情况 3：新请求是写，且命中已有同地址读根 lane。
                // 后续需要把这些已有读转成 bypass，直接吃这次写数据。
                if (req_in_write &&
                    !lane_write_r[root_lane_i] &&
                    !lane_bypass_r[root_lane_i] &&
                    (req_in_addr ==
                        lane_addr_r[(root_lane_i*`SRAM_ADDR_W) +: `SRAM_ADDR_W]) &&
                    !accept_same_addr_bypass_c &&
                    !lane_bypass_r[lane_i]) begin
                    accept_same_addr_bypass_c = 1'b1;
                    accept_merge_root_idx_c = root_lane_i[LANE_IDX_W-1:0];
                end
            end
        end

        // 情况 4：没有 merge、没有 bypass、没有资源冲突、也没有写阻塞时，
        // 新请求可以作为 independent lane 直接并入这一组。
        if (!accept_same_addr_merge_c &&
            !accept_same_addr_bypass_c &&
            !accept_read_after_write_bypass_c &&
            !resource_conflict_c &&
            !write_lane_present_c) begin
            accept_independent_c = 1'b1;
        end
    end

    // collect_ready_c 表示这条标量请求是否满足任一种可接受场景。
    collect_ready_c = accept_same_addr_merge_c ||
                      accept_same_addr_bypass_c ||
                      accept_read_after_write_bypass_c ||
                      accept_independent_c;

    // 对纯读组做一个简单“按 priority 插槽前插”的处理：
    // 若当前请求优先级更高，可把它插到前面某个更靠前的空档位置。
    if (accept_independent_c && !merge_lane_present_c &&
        !write_lane_present_c && !req_in_write) begin
        for (lane_i = 0; lane_i < `MEM_REQ_LANES; lane_i = lane_i + 1) begin
            if (lane_i < accept_lane_idx_c && lane_valid_r[lane_i] &&
                !lane_merge_r[lane_i] &&
                (req_in_priority >
                    lane_priority_r[(lane_i*`REQ_PRIORITY_W) +: `REQ_PRIORITY_W]) &&
                (accept_store_idx_c == accept_lane_idx_c)) begin
                accept_store_idx_c = lane_i[LANE_IDX_W-1:0];
            end
        end
    end

    // ISSUE 态：
    // 把“还没 issued 且需要真实进 SRAM 的 lane”送到底层 mem_req_*。
    if (state_r == STATE_ISSUE) begin
        issue_ready_c = 1'b1;
        issue_all_reqs_accepted_c = 1'b1;
        for (lane_i = 0; lane_i < `MEM_REQ_LANES; lane_i = lane_i + 1) begin
            // 只要组里存在读，就说明最终需要有响应阶段。
            if (lane_valid_r[lane_i] && !lane_write_r[lane_i]) begin
                issue_has_response_c = 1'b1;
            end

            // 只有真实 SRAM 读才会让控制器进入 WAIT_RESP。
            if (lane_valid_r[lane_i] && !lane_write_r[lane_i] &&
                !lane_merge_r[lane_i] && !lane_bypass_r[lane_i]) begin
                issue_has_sram_read_c = 1'b1;
            end

            if (lane_valid_r[lane_i] && !lane_merge_r[lane_i] &&
                !lane_bypass_r[lane_i] && !lane_issued_r[lane_i]) begin
                // merge / bypass lane 不向 SRAM 发真实请求，其余 lane 按原字段发射。
                mem_req_valid_c[lane_i] = 1'b1;
                mem_req_addr_c[(lane_i*`SRAM_ADDR_W) +: `SRAM_ADDR_W] =
                    lane_addr_r[(lane_i*`SRAM_ADDR_W) +: `SRAM_ADDR_W];
                mem_req_wdata_c[(lane_i*`SRAM_WDATA_W) +: `SRAM_WDATA_W] =
                    lane_wdata_r[(lane_i*`SRAM_WDATA_W) +: `SRAM_WDATA_W];
                mem_req_id_c[(lane_i*`REQ_ID_W) +: `REQ_ID_W] =
                    lane_req_id_r[(lane_i*`REQ_ID_W) +: `REQ_ID_W];
                mem_req_write_c[lane_i] = lane_write_r[lane_i];
                if (!mem_req_ready[lane_i]) begin
                    // 任何一个真实请求没被底层接受，都说明本拍 issue 未完成。
                    issue_all_reqs_accepted_c = 1'b0;
                end
            end
        end
    end

    // ISSUE/WAIT_RESP 两个阶段都可能形成“本拍新响应”：
    // 1. bypass lane 直接本拍出响应；
    // 2. merge lane 跟随其根 lane 的真实读响应；
    // 3. 非 merge/bypass 读 lane 直接使用对应的 mem_resp。
    if ((state_r == STATE_ISSUE) || (state_r == STATE_WAIT_RESP)) begin
        resp_complete_c = 1'b1;
        for (lane_i = 0; lane_i < `MEM_REQ_LANES; lane_i = lane_i + 1) begin
            if (lane_valid_r[lane_i] && lane_bypass_r[lane_i] &&
                !lane_write_r[lane_i] && !resp_valid_r[lane_i]) begin
                // bypass：直接把预存的 bypass_data 作为响应数据。
                resp_now_valid_c[lane_i] = 1'b1;
                resp_now_rdata_c[(lane_i*`SRAM_RDATA_W) +: `SRAM_RDATA_W] =
                    lane_bypass_data_r[(lane_i*`SRAM_RDATA_W) +: `SRAM_RDATA_W];
                resp_now_req_id_c[(lane_i*`REQ_ID_W) +: `REQ_ID_W] =
                    lane_req_id_r[(lane_i*`REQ_ID_W) +: `REQ_ID_W];
                resp_now_pe_mask_c[(lane_i*`PE_MASK_W) +: `PE_MASK_W] =
                    lane_pe_mask_r[(lane_i*`PE_MASK_W) +: `PE_MASK_W];
                resp_now_last_c[lane_i] = 1'b1;
            end else if (lane_valid_r[lane_i] && !lane_write_r[lane_i] &&
                         lane_merge_r[lane_i] && !resp_valid_r[lane_i] &&
                         mem_resp_valid[lane_merge_src_r[lane_i]]) begin
                // merge：复用根 lane 的真实 SRAM 响应，但 req_id/pe_mask 用自己的。
                resp_now_valid_c[lane_i] = 1'b1;
                resp_now_rdata_c[(lane_i*`SRAM_RDATA_W) +: `SRAM_RDATA_W] =
                    mem_resp_rdata[(lane_merge_src_r[lane_i]*`SRAM_RDATA_W) +:
                                   `SRAM_RDATA_W];
                resp_now_req_id_c[(lane_i*`REQ_ID_W) +: `REQ_ID_W] =
                    lane_req_id_r[(lane_i*`REQ_ID_W) +: `REQ_ID_W];
                resp_now_pe_mask_c[(lane_i*`PE_MASK_W) +: `PE_MASK_W] =
                    lane_pe_mask_r[(lane_i*`PE_MASK_W) +: `PE_MASK_W];
                resp_now_last_c[lane_i] = mem_resp_last[lane_merge_src_r[lane_i]];
            end else if (lane_valid_r[lane_i] && !lane_write_r[lane_i] &&
                         !lane_merge_r[lane_i] && !lane_bypass_r[lane_i] &&
                         !resp_valid_r[lane_i] && mem_resp_valid[lane_i]) begin
                // 真实读：直接接对应 lane 的 mem_resp。
                resp_now_valid_c[lane_i] = 1'b1;
                resp_now_rdata_c[(lane_i*`SRAM_RDATA_W) +: `SRAM_RDATA_W] =
                    mem_resp_rdata[(lane_i*`SRAM_RDATA_W) +: `SRAM_RDATA_W];
                resp_now_req_id_c[(lane_i*`REQ_ID_W) +: `REQ_ID_W] =
                    lane_req_id_r[(lane_i*`REQ_ID_W) +: `REQ_ID_W];
                resp_now_pe_mask_c[(lane_i*`PE_MASK_W) +: `PE_MASK_W] =
                    lane_pe_mask_r[(lane_i*`PE_MASK_W) +: `PE_MASK_W];
                resp_now_last_c[lane_i] = mem_resp_last[lane_i];
            end

            // resp_complete_c 用于判断这一组读请求是否已经全部拿到结果。
            if (lane_valid_r[lane_i] && !lane_write_r[lane_i]) begin
                if (lane_merge_r[lane_i]) begin
                    if (!resp_valid_r[lane_i] &&
                        !mem_resp_valid[lane_merge_src_r[lane_i]]) begin
                        resp_complete_c = 1'b0;
                    end
                end else if (lane_bypass_r[lane_i]) begin
                    if (!resp_valid_r[lane_i]) begin
                        resp_complete_c = 1'b0;
                    end
                end else if (!resp_valid_r[lane_i] && !mem_resp_valid[lane_i]) begin
                    resp_complete_c = 1'b0;
                end
            end
        end
    end

    // 对外响应总线默认只反映当前已经锁存进 resp_*_r 的稳定响应。
    for (lane_i = 0; lane_i < `MEM_REQ_LANES; lane_i = lane_i + 1) begin
        if (resp_valid_r[lane_i]) begin
            resp_out_rdata_c[(lane_i*`SRAM_RDATA_W) +: `SRAM_RDATA_W] =
                resp_rdata_r[(lane_i*`SRAM_RDATA_W) +: `SRAM_RDATA_W];
            resp_out_req_id_c[(lane_i*`REQ_ID_W) +: `REQ_ID_W] =
                resp_req_id_r[(lane_i*`REQ_ID_W) +: `REQ_ID_W];
            resp_out_pe_mask_c[(lane_i*`PE_MASK_W) +: `PE_MASK_W] =
                resp_pe_mask_r[(lane_i*`PE_MASK_W) +: `PE_MASK_W];
            resp_out_last_c[lane_i] = resp_last_r[lane_i];
        end
    end
end

// 主时序状态机：
// 1. 维护当前请求组的 lane 台账；
// 2. 在不同阶段吸收新请求、发射真实 SRAM 访问、锁存响应；
// 3. 响应全部被下游接收后清空上下文并回到 IDLE。
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        // 复位时清空状态机、请求组台账、merge 源索引与响应寄存器。
        state_r <= STATE_IDLE;
        collect_wait_r <= 1'b0;
        lane_valid_r <= {`MEM_REQ_LANES{1'b0}};
        lane_merge_r <= {`MEM_REQ_LANES{1'b0}};
        lane_write_r <= {`MEM_REQ_LANES{1'b0}};
        lane_bypass_r <= {`MEM_REQ_LANES{1'b0}};
        lane_issued_r <= {`MEM_REQ_LANES{1'b0}};
        lane_addr_r <= {(`MEM_REQ_LANES*`SRAM_ADDR_W){1'b0}};
        lane_wdata_r <= {(`MEM_REQ_LANES*`SRAM_WDATA_W){1'b0}};
        lane_bypass_data_r <= {(`MEM_REQ_LANES*`SRAM_RDATA_W){1'b0}};
        lane_req_id_r <= {(`MEM_REQ_LANES*`REQ_ID_W){1'b0}};
        lane_pe_mask_r <= {(`MEM_REQ_LANES*`PE_MASK_W){1'b0}};
        lane_priority_r <= {(`MEM_REQ_LANES*`REQ_PRIORITY_W){1'b0}};
        lane_bank_id_r <= {(`MEM_REQ_LANES*`BANK_ID_W){1'b0}};
        lane_subbank_id_r <= {(`MEM_REQ_LANES*`SUBBANK_ID_W){1'b0}};
        for (reset_i = 0; reset_i < `MEM_REQ_LANES; reset_i = reset_i + 1) begin
            lane_merge_src_r[reset_i] <= {LANE_IDX_W{1'b0}};
        end
        resp_valid_r <= {`MEM_REQ_LANES{1'b0}};
        resp_rdata_r <= {(`MEM_REQ_LANES*`SRAM_RDATA_W){1'b0}};
        resp_req_id_r <= {(`MEM_REQ_LANES*`REQ_ID_W){1'b0}};
        resp_pe_mask_r <= {(`MEM_REQ_LANES*`PE_MASK_W){1'b0}};
        resp_last_r <= {`MEM_REQ_LANES{1'b0}};
    end else begin
        case (state_r)
            STATE_IDLE: begin
                // IDLE 优先看向量组；
                // 只有没有向量组抢占时，才接标量入口。
                if (vec_any_valid_c && vec_group_supported_c &&
                    ((vec_req_valid & vec_req_ready) != {`MEM_REQ_LANES{1'b0}})) begin
                    collect_wait_r <= 1'b0;

                    // 把整个向量组直接装入 lane 台账。
                    lane_valid_r <= vec_lane_valid_c;
                    lane_merge_r <= vec_lane_merge_c;
                    lane_write_r <= vec_lane_write_c;
                    lane_bypass_r <= vec_lane_bypass_c;

                    // merge / bypass lane 不需要真实 SRAM issue，因此初始就记为 issued。
                    lane_issued_r <= vec_lane_merge_c | vec_lane_bypass_c;
                    lane_addr_r <= vec_lane_addr_c;
                    lane_wdata_r <= vec_lane_wdata_c;
                    lane_bypass_data_r <= vec_lane_bypass_data_c;
                    lane_req_id_r <= vec_lane_req_id_c;
                    lane_pe_mask_r <= vec_lane_pe_mask_c;
                    lane_priority_r <= vec_lane_priority_c;
                    lane_bank_id_r <= vec_lane_bank_id_c;
                    lane_subbank_id_r <= vec_lane_subbank_id_c;
                    for (reset_i = 0; reset_i < `MEM_REQ_LANES; reset_i = reset_i + 1) begin
                        lane_merge_src_r[reset_i] <= vec_lane_merge_src_c[reset_i];
                    end
                    resp_valid_r <= {`MEM_REQ_LANES{1'b0}};

                    // 向量组不再继续 collect，直接进入 issue。
                    state_r <= STATE_ISSUE;
                end else if (req_in_valid && req_in_ready) begin
                    collect_wait_r <= 1'b0;

                    // 标量入口只先占用 lane0。
                    lane_valid_r <= {{(`MEM_REQ_LANES-1){1'b0}}, 1'b1};
                    lane_merge_r <= {`MEM_REQ_LANES{1'b0}};
                    lane_write_r <= {{(`MEM_REQ_LANES-1){1'b0}}, req_in_write};
                    lane_bypass_r <= {`MEM_REQ_LANES{1'b0}};
                    lane_issued_r <= {`MEM_REQ_LANES{1'b0}};
                    lane_addr_r[0 +: `SRAM_ADDR_W] <= req_in_addr;
                    lane_wdata_r[0 +: `SRAM_WDATA_W] <= req_in_wdata;
                    lane_bypass_data_r <= {(`MEM_REQ_LANES*`SRAM_RDATA_W){1'b0}};
                    lane_req_id_r[0 +: `REQ_ID_W] <= req_in_req_id;
                    lane_pe_mask_r[0 +: `PE_MASK_W] <= req_in_pe_mask;
                    lane_priority_r[0 +: `REQ_PRIORITY_W] <= req_in_priority;
                    lane_bank_id_r[0 +: `BANK_ID_W] <= req_in_bank_id;
                    lane_subbank_id_r[0 +: `SUBBANK_ID_W] <= req_in_subbank_id;
                    lane_merge_src_r[0] <= {LANE_IDX_W{1'b0}};
                    resp_valid_r <= {`MEM_REQ_LANES{1'b0}};
                    if (req_in_write) begin
                        // 单条写不需要等更多读合并，直接去 ISSUE。
                        state_r <= STATE_ISSUE;
                    end else begin
                        // 单条读先进入 COLLECT，看还能不能多收几条一起处理。
                        state_r <= STATE_COLLECT;
                    end
                end
            end

            STATE_COLLECT: begin
                // COLLECT 态尝试把新的标量请求吸收到现有请求组中。
                if (req_in_valid && collect_ready_c) begin
                    for (shift_i = `MEM_REQ_LANES-1; shift_i > 0; shift_i = shift_i - 1) begin
                        if (accept_independent_c && !merge_lane_present_c &&
                            (shift_i <= accept_lane_idx_c) &&
                            (shift_i > accept_store_idx_c)) begin
                            // 若发生“按优先级前插”，则把后面的条目整体右移，为新条目腾槽位。
                            lane_valid_r[shift_i] <= lane_valid_r[shift_i-1];
                            lane_merge_r[shift_i] <= lane_merge_r[shift_i-1];
                            lane_write_r[shift_i] <= lane_write_r[shift_i-1];
                            lane_bypass_r[shift_i] <= lane_bypass_r[shift_i-1];
                            lane_issued_r[shift_i] <= lane_issued_r[shift_i-1];
                            lane_addr_r[(shift_i*`SRAM_ADDR_W) +: `SRAM_ADDR_W] <=
                                lane_addr_r[((shift_i-1)*`SRAM_ADDR_W) +: `SRAM_ADDR_W];
                            lane_wdata_r[(shift_i*`SRAM_WDATA_W) +: `SRAM_WDATA_W] <=
                                lane_wdata_r[((shift_i-1)*`SRAM_WDATA_W) +: `SRAM_WDATA_W];
                            lane_bypass_data_r[(shift_i*`SRAM_RDATA_W) +: `SRAM_RDATA_W] <=
                                lane_bypass_data_r[((shift_i-1)*`SRAM_RDATA_W) +: `SRAM_RDATA_W];
                            lane_req_id_r[(shift_i*`REQ_ID_W) +: `REQ_ID_W] <=
                                lane_req_id_r[((shift_i-1)*`REQ_ID_W) +: `REQ_ID_W];
                            lane_pe_mask_r[(shift_i*`PE_MASK_W) +: `PE_MASK_W] <=
                                lane_pe_mask_r[((shift_i-1)*`PE_MASK_W) +: `PE_MASK_W];
                            lane_priority_r[(shift_i*`REQ_PRIORITY_W) +: `REQ_PRIORITY_W] <=
                                lane_priority_r[((shift_i-1)*`REQ_PRIORITY_W) +: `REQ_PRIORITY_W];
                            lane_bank_id_r[(shift_i*`BANK_ID_W) +: `BANK_ID_W] <=
                                lane_bank_id_r[((shift_i-1)*`BANK_ID_W) +: `BANK_ID_W];
                            lane_subbank_id_r[(shift_i*`SUBBANK_ID_W) +: `SUBBANK_ID_W] <=
                                lane_subbank_id_r[((shift_i-1)*`SUBBANK_ID_W) +: `SUBBANK_ID_W];
                            lane_merge_src_r[shift_i] <= lane_merge_src_r[shift_i-1];
                        end
                    end

                    // 把新请求写入选定槽位，并根据 merge/bypass 结果设置元数据。
                    lane_valid_r[accept_store_idx_c] <= 1'b1;
                    lane_merge_r[accept_store_idx_c] <= accept_same_addr_merge_c;
                    lane_merge_src_r[accept_store_idx_c] <=
                        accept_same_addr_merge_c ?
                            accept_merge_root_idx_c : {LANE_IDX_W{1'b0}};
                    lane_write_r[accept_store_idx_c] <= req_in_write;
                    lane_bypass_r[accept_store_idx_c] <=
                        accept_read_after_write_bypass_c;
                    lane_issued_r[accept_store_idx_c] <=
                        accept_same_addr_merge_c ||
                        accept_read_after_write_bypass_c;
                    lane_addr_r[(accept_store_idx_c*`SRAM_ADDR_W) +: `SRAM_ADDR_W] <=
                        req_in_addr;
                    lane_wdata_r[(accept_store_idx_c*`SRAM_WDATA_W) +: `SRAM_WDATA_W] <=
                        req_in_wdata;
                    if (accept_read_after_write_bypass_c) begin
                        lane_bypass_data_r[(accept_store_idx_c*`SRAM_RDATA_W) +: `SRAM_RDATA_W] <=
                            lane_wdata_r[(accept_bypass_source_idx_c*`SRAM_WDATA_W) +: `SRAM_WDATA_W];
                    end else begin
                        lane_bypass_data_r[(accept_store_idx_c*`SRAM_RDATA_W) +: `SRAM_RDATA_W] <=
                            {`SRAM_RDATA_W{1'b0}};
                    end
                    lane_req_id_r[(accept_store_idx_c*`REQ_ID_W) +: `REQ_ID_W] <=
                        req_in_req_id;
                    lane_pe_mask_r[(accept_store_idx_c*`PE_MASK_W) +: `PE_MASK_W] <=
                        req_in_pe_mask;
                    lane_priority_r[(accept_store_idx_c*`REQ_PRIORITY_W) +: `REQ_PRIORITY_W] <=
                        req_in_priority;
                    lane_bank_id_r[(accept_store_idx_c*`BANK_ID_W) +: `BANK_ID_W] <=
                        req_in_bank_id;
                    lane_subbank_id_r[(accept_store_idx_c*`SUBBANK_ID_W) +: `SUBBANK_ID_W] <=
                        req_in_subbank_id;

                    if (accept_same_addr_bypass_c && req_in_write) begin
                        // 写命中已有读时，把所有命中同地址的旧读条目改造成 bypass。
                        for (update_i = 0; update_i < `MEM_REQ_LANES; update_i = update_i + 1) begin
                            if (lane_valid_r[update_i]) begin
                                update_root_i = update_i;
                                if (lane_merge_r[update_i]) begin
                                    update_root_i = lane_merge_src_r[update_i];
                                end
                                if (!lane_write_r[update_root_i] &&
                                    !lane_bypass_r[update_root_i] &&
                                    (req_in_addr ==
                                        lane_addr_r[(update_root_i*`SRAM_ADDR_W) +: `SRAM_ADDR_W])) begin
                                    lane_merge_r[update_i] <= 1'b0;
                                    lane_merge_src_r[update_i] <= {LANE_IDX_W{1'b0}};
                                    lane_bypass_r[update_i] <= 1'b1;
                                    lane_issued_r[update_i] <= 1'b1;
                                    lane_bypass_data_r[(update_i*`SRAM_RDATA_W) +: `SRAM_RDATA_W] <=
                                        req_in_wdata;
                                end
                            end
                        end
                    end
                    collect_wait_r <= 1'b0;

                    if (accept_lane_idx_c == (`MEM_REQ_LANES-1)) begin
                        // 已经填满可用 lane，停止继续收集。
                        state_r <= STATE_ISSUE;
                    end
                end else if (collect_wait_r) begin
                    // 连续两拍都没有新的可接受请求，则结束 collect，转入 ISSUE。
                    state_r <= STATE_ISSUE;
                end else begin
                    // 第一次没等到新请求时，先把 wait 标志拉起，再多等一拍。
                    collect_wait_r <= 1'b1;
                end
            end

            STATE_ISSUE: begin
                if (issue_ready_c) begin
                    collect_wait_r <= 1'b0;
                    for (resp_i = 0; resp_i < `MEM_REQ_LANES; resp_i = resp_i + 1) begin
                        if (lane_valid_r[resp_i] && lane_bypass_r[resp_i] &&
                            !lane_write_r[resp_i]) begin
                            if (resp_now_valid_c[resp_i]) begin
                                // bypass 响应可在 ISSUE 态直接锁存。
                                resp_valid_r[resp_i] <= 1'b1;
                                resp_rdata_r[(resp_i*`SRAM_RDATA_W) +: `SRAM_RDATA_W] <=
                                    lane_bypass_data_r[(resp_i*`SRAM_RDATA_W) +: `SRAM_RDATA_W];
                                resp_req_id_r[(resp_i*`REQ_ID_W) +: `REQ_ID_W] <=
                                    lane_req_id_r[(resp_i*`REQ_ID_W) +: `REQ_ID_W];
                                resp_pe_mask_r[(resp_i*`PE_MASK_W) +: `PE_MASK_W] <=
                                    lane_pe_mask_r[(resp_i*`PE_MASK_W) +: `PE_MASK_W];
                                resp_last_r[resp_i] <= 1'b1;
                            end
                        end

                        if (lane_valid_r[resp_i] && !lane_write_r[resp_i] &&
                            !lane_merge_r[resp_i] && !lane_bypass_r[resp_i] &&
                            mem_resp_valid[resp_i]) begin
                            if (resp_now_valid_c[resp_i]) begin
                                // 有些真实 SRAM 读响应可能在 ISSUE 态同拍就回来了。
                                resp_valid_r[resp_i] <= 1'b1;
                                resp_rdata_r[(resp_i*`SRAM_RDATA_W) +: `SRAM_RDATA_W] <=
                                    mem_resp_rdata[(resp_i*`SRAM_RDATA_W) +: `SRAM_RDATA_W];
                                resp_req_id_r[(resp_i*`REQ_ID_W) +: `REQ_ID_W] <=
                                    lane_req_id_r[(resp_i*`REQ_ID_W) +: `REQ_ID_W];
                                resp_pe_mask_r[(resp_i*`PE_MASK_W) +: `PE_MASK_W] <=
                                    lane_pe_mask_r[(resp_i*`PE_MASK_W) +: `PE_MASK_W];
                                resp_last_r[resp_i] <= mem_resp_last[resp_i];
                            end
                        end

                        if (lane_valid_r[resp_i] && !lane_write_r[resp_i] &&
                            lane_merge_r[resp_i] &&
                            mem_resp_valid[lane_merge_src_r[resp_i]]) begin
                            if (resp_now_valid_c[resp_i]) begin
                                // merge lane 也可能在 ISSUE 态同步得到根 lane 的返回。
                                resp_valid_r[resp_i] <= 1'b1;
                                resp_rdata_r[(resp_i*`SRAM_RDATA_W) +: `SRAM_RDATA_W] <=
                                    mem_resp_rdata[(lane_merge_src_r[resp_i]*`SRAM_RDATA_W) +:
                                                   `SRAM_RDATA_W];
                                resp_req_id_r[(resp_i*`REQ_ID_W) +: `REQ_ID_W] <=
                                    lane_req_id_r[(resp_i*`REQ_ID_W) +: `REQ_ID_W];
                                resp_pe_mask_r[(resp_i*`PE_MASK_W) +: `PE_MASK_W] <=
                                    lane_pe_mask_r[(resp_i*`PE_MASK_W) +: `PE_MASK_W];
                                resp_last_r[resp_i] <= mem_resp_last[lane_merge_src_r[resp_i]];
                            end
                        end

                        if (mem_req_valid_c[resp_i] && mem_req_ready[resp_i]) begin
                            // 真实发往 SRAM 的 lane 一旦被接受，标记为已 issue。
                            lane_issued_r[resp_i] <= 1'b1;
                        end
                    end

                    if (!issue_all_reqs_accepted_c) begin
                        // 底层还没全部接走，继续停在 ISSUE 再试。
                        state_r <= STATE_ISSUE;
                    end else if (!issue_has_response_c) begin
                        // 整组全是写请求，没有响应阶段，直接回空闲。
                        lane_valid_r <= {`MEM_REQ_LANES{1'b0}};
                        lane_merge_r <= {`MEM_REQ_LANES{1'b0}};
                        lane_write_r <= {`MEM_REQ_LANES{1'b0}};
                        lane_bypass_r <= {`MEM_REQ_LANES{1'b0}};
                        lane_issued_r <= {`MEM_REQ_LANES{1'b0}};
                        lane_priority_r <= {(`MEM_REQ_LANES*`REQ_PRIORITY_W){1'b0}};
                        for (reset_i = 0; reset_i < `MEM_REQ_LANES; reset_i = reset_i + 1) begin
                            lane_merge_src_r[reset_i] <= {LANE_IDX_W{1'b0}};
                        end
                        state_r <= STATE_IDLE;
                    end else if (resp_complete_c) begin
                        // 所有需要的读响应已经齐了，进入 RESP 对外发送。
                        state_r <= STATE_RESP;
                    end else if (issue_has_sram_read_c) begin
                        // 仍有真实 SRAM 读未回来，进入 WAIT_RESP。
                        state_r <= STATE_WAIT_RESP;
                    end else begin
                        // 理论上不会走到太多这里；保守进入 RESP。
                        state_r <= STATE_RESP;
                    end
                end
            end

            STATE_WAIT_RESP: begin
                // WAIT_RESP 只负责继续接收尚未到齐的真实读/merge 响应。
                for (resp_i = 0; resp_i < `MEM_REQ_LANES; resp_i = resp_i + 1) begin
                    if (lane_valid_r[resp_i] && !lane_write_r[resp_i] &&
                        !lane_merge_r[resp_i] && !lane_bypass_r[resp_i] &&
                        mem_resp_valid[resp_i]) begin
                        if (resp_now_valid_c[resp_i]) begin
                            resp_valid_r[resp_i] <= 1'b1;
                            resp_rdata_r[(resp_i*`SRAM_RDATA_W) +: `SRAM_RDATA_W] <=
                                mem_resp_rdata[(resp_i*`SRAM_RDATA_W) +: `SRAM_RDATA_W];
                            resp_req_id_r[(resp_i*`REQ_ID_W) +: `REQ_ID_W] <=
                                lane_req_id_r[(resp_i*`REQ_ID_W) +: `REQ_ID_W];
                            resp_pe_mask_r[(resp_i*`PE_MASK_W) +: `PE_MASK_W] <=
                                lane_pe_mask_r[(resp_i*`PE_MASK_W) +: `PE_MASK_W];
                            resp_last_r[resp_i] <= mem_resp_last[resp_i];
                        end
                    end

                    if (lane_valid_r[resp_i] && !lane_write_r[resp_i] &&
                        lane_merge_r[resp_i] &&
                        mem_resp_valid[lane_merge_src_r[resp_i]]) begin
                        if (resp_now_valid_c[resp_i]) begin
                            resp_valid_r[resp_i] <= 1'b1;
                            resp_rdata_r[(resp_i*`SRAM_RDATA_W) +: `SRAM_RDATA_W] <=
                                mem_resp_rdata[(lane_merge_src_r[resp_i]*`SRAM_RDATA_W) +:
                                               `SRAM_RDATA_W];
                            resp_req_id_r[(resp_i*`REQ_ID_W) +: `REQ_ID_W] <=
                                lane_req_id_r[(resp_i*`REQ_ID_W) +: `REQ_ID_W];
                            resp_pe_mask_r[(resp_i*`PE_MASK_W) +: `PE_MASK_W] <=
                                lane_pe_mask_r[(resp_i*`PE_MASK_W) +: `PE_MASK_W];
                            resp_last_r[resp_i] <= mem_resp_last[lane_merge_src_r[resp_i]];
                        end
                    end
                end

                if (resp_complete_c) begin
                    // 全部读响应到齐后进入最终 RESP。
                    state_r <= STATE_RESP;
                end
            end

            STATE_RESP: begin
                // RESP 态只做一件事：把已经锁存好的响应等待下游逐 lane 接走。
                for (resp_i = 0; resp_i < `MEM_REQ_LANES; resp_i = resp_i + 1) begin
                    if (resp_valid_r[resp_i] && resp_out_ready[resp_i]) begin
                        resp_valid_r[resp_i] <= 1'b0;
                    end
                end

                if ((resp_valid_r & ~resp_out_ready) == {`MEM_REQ_LANES{1'b0}}) begin
                    // 所有有效响应都已经被消费，清掉本组上下文，回到 IDLE。
                    lane_valid_r <= {`MEM_REQ_LANES{1'b0}};
                    lane_merge_r <= {`MEM_REQ_LANES{1'b0}};
                    lane_write_r <= {`MEM_REQ_LANES{1'b0}};
                    lane_bypass_r <= {`MEM_REQ_LANES{1'b0}};
                    lane_issued_r <= {`MEM_REQ_LANES{1'b0}};
                    lane_priority_r <= {(`MEM_REQ_LANES*`REQ_PRIORITY_W){1'b0}};
                    for (reset_i = 0; reset_i < `MEM_REQ_LANES; reset_i = reset_i + 1) begin
                        lane_merge_src_r[reset_i] <= {LANE_IDX_W{1'b0}};
                    end
                    state_r <= STATE_IDLE;
                end
            end

            default: begin
                // 防御式回到 IDLE。
                state_r <= STATE_IDLE;
            end
        endcase
    end
end

endmodule
