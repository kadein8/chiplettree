`timescale 1ns/1ps

`include "config/interface_params.vh"
`include "config/memory_params.vh"

/*
 * 文件作用：
 * 1. 本文件实现论文 TreeControl / transformer 共享存储基础设施里的 sram_subsystem。
 * 2. 它位于 request_controller 下方，负责把多 lane SRAM 请求按地址拆到不同 bank/subbank，
 *    并把读响应再准确送回发起该读请求的 lane。
 * 3. 在完整路径里，它位于：
 *    request_controller
 *      -> sram_subsystem
 *      -> sram_bank
 *      -> sram_subbank
 * 4. 这个模块承担的关键职责是：
 *    - 多 lane 请求到多 bank/subbank 的地址解码；
 *    - 同拍冲突避免：同一个 subbank 同拍只允许一个 lane 占用；
 *    - 读事务 owner 跟踪：知道哪条读响应该回给哪个 lane；
 *    - 简单轮询公平：lane_issue_rr_start_r 决定每拍从哪个 lane 开始扫描。
 * 5. 这里是整个共享 SRAM 系统的“交叉开关 + owner 台账”，不是实际存储阵列本体。
 */
module sram_subsystem (
    // 时钟与复位。
    input                                               clk,
    input                                               rst_n,

    // 多 lane 请求接口：
    // 每条 lane 以统一的扁平 SRAM_ADDR 发请求，上层不需要关心 bank/subbank 切分细节。
    input  [`MEM_REQ_LANES-1:0]                         mem_req_valid,
    output [`MEM_REQ_LANES-1:0]                         mem_req_ready,
    input  [`MEM_REQ_LANES-1:0]                         mem_req_write,
    input  [`MEM_REQ_LANES*`SRAM_ADDR_W-1:0]            mem_req_addr,
    input  [`MEM_REQ_LANES*`SRAM_WDATA_W-1:0]           mem_req_wdata,
    input  [`MEM_REQ_LANES*`REQ_ID_W-1:0]               mem_req_id,

    // 多 lane 响应接口：
    // 读响应会按原始 owner lane 回送。
    output [`MEM_REQ_LANES-1:0]                         mem_resp_valid,
    output [`MEM_REQ_LANES*`SRAM_RDATA_W-1:0]           mem_resp_rdata,
    output [`MEM_REQ_LANES*`REQ_ID_W-1:0]               mem_resp_id,
    output [`MEM_REQ_LANES-1:0]                         mem_resp_last
);

// 派生常量：
// TOTAL_BANKS   : 总 bank 数。
// TOTAL_BANKS_W : 扁平 bank 索引位宽。
// LANE_IDX_W    : lane 索引位宽。
localparam integer TOTAL_BANKS = `SRAM_NUM * `SRAM_BANK_NUM;
localparam integer TOTAL_BANKS_W =
    ((TOTAL_BANKS <= 1) ? 1 : $clog2(TOTAL_BANKS));
localparam integer LANE_IDX_W =
    ((`MEM_REQ_LANES <= 1) ? 1 : $clog2(`MEM_REQ_LANES));

// 发往每个 bank 的拆分后请求总线。
reg [`SUBBANK_NUM_PER_BANK-1:0] bank_req_valid_r [0:TOTAL_BANKS-1];
reg [`SUBBANK_NUM_PER_BANK-1:0] bank_req_write_r [0:TOTAL_BANKS-1];
reg [`SUBBANK_NUM_PER_BANK*`ROW_ADDR_W-1:0] bank_req_row_addr_r [0:TOTAL_BANKS-1];
reg [`SUBBANK_NUM_PER_BANK*`OFFSET_W-1:0] bank_req_offset_r [0:TOTAL_BANKS-1];
reg [`SUBBANK_NUM_PER_BANK*`SRAM_WDATA_W-1:0] bank_req_wdata_r [0:TOTAL_BANKS-1];
reg [`SUBBANK_NUM_PER_BANK*`REQ_ID_W-1:0] bank_req_id_r [0:TOTAL_BANKS-1];
wire [`SUBBANK_NUM_PER_BANK-1:0] bank_req_ready_w [0:TOTAL_BANKS-1];
wire [`SUBBANK_NUM_PER_BANK-1:0] bank_resp_valid_w [0:TOTAL_BANKS-1];
wire [`SUBBANK_NUM_PER_BANK*`SRAM_RDATA_W-1:0] bank_resp_rdata_w [0:TOTAL_BANKS-1];
wire [`SUBBANK_NUM_PER_BANK*`REQ_ID_W-1:0] bank_resp_id_w [0:TOTAL_BANKS-1];
wire [`SUBBANK_NUM_PER_BANK-1:0] bank_resp_last_w [0:TOTAL_BANKS-1];

// 对外的 lane 级 ready/resp 输出寄存器。
reg [`MEM_REQ_LANES-1:0] mem_req_ready_r;
reg [`MEM_REQ_LANES-1:0] mem_resp_valid_r;
reg [`MEM_REQ_LANES*`SRAM_RDATA_W-1:0] mem_resp_rdata_r;
reg [`MEM_REQ_LANES*`REQ_ID_W-1:0] mem_resp_id_r;
reg [`MEM_REQ_LANES-1:0] mem_resp_last_r;
reg [`MEM_REQ_LANES-1:0] lane_release_now_r;

// 组合阶段的“本拍 claim 信息”：
// claimed_subbank_r 用来避免同拍两个 lane 抢同一个 subbank。
reg [`SUBBANK_NUM_PER_BANK-1:0] claimed_subbank_r [0:TOTAL_BANKS-1];

// 本拍哪些 lane 成功被接受，以及它们是读还是写、目标 bank/subbank 是什么。
reg [`MEM_REQ_LANES-1:0] lane_accept_valid_r;
reg [`MEM_REQ_LANES-1:0] lane_accept_read_r;
reg [TOTAL_BANKS_W-1:0] lane_target_bank_r [0:`MEM_REQ_LANES-1];
reg [`SUBBANK_ID_W-1:0] lane_target_subbank_r [0:`MEM_REQ_LANES-1];

// 轮询起点：
// 每次成功接受过至少一个请求后，下一拍从下一个 lane 开始扫描，降低固定优先级偏置。
reg [LANE_IDX_W-1:0] lane_issue_rr_start_r;

// storage_beats_debug：
// DISABLED — too large for simulation (64*32*4096 entries), causes VCS issues.
// Uncomment for targeted debug only.
// reg [`SRAM_WDATA_W-1:0] storage_beats_debug [0:TOTAL_BANKS-1]
//     [0:`SUBBANK_NUM_PER_BANK-1][0:`SUBBANK_SIZE_BYTES-1];

// lane_busy_r：
// 某条 lane 发出读请求后，在读响应回来之前被标记为 busy，不再接受新的读。
reg lane_busy_r [0:`MEM_REQ_LANES-1];

// owner_valid_r / owner_lane_r：
// 记录某个 bank/subbank 当前挂起的读事务属于哪条 lane。
reg owner_valid_r [0:TOTAL_BANKS-1][0:`SUBBANK_NUM_PER_BANK-1];
reg [LANE_IDX_W-1:0] owner_lane_r [0:TOTAL_BANKS-1][0:`SUBBANK_NUM_PER_BANK-1];

genvar bank_gi;
integer bank_i;
integer subbank_i;
integer lane_i;
integer owner_lane_i;
integer target_bank_i;
integer debug_base_addr_i;
integer issue_scan_step_i;
integer issue_lane_i;
reg [`SRAM_ADDR_W-1:0] lane_addr_value;
reg [`SRAM_ID_W-1:0] lane_sram_id_value;
reg [`BANK_ID_W-1:0] lane_bank_id_value;
reg [`SUBBANK_ID_W-1:0] lane_subbank_id_value;
reg [`ROW_ADDR_W-1:0] lane_row_addr_value;
reg [`OFFSET_W-1:0] lane_offset_value;
reg [`SRAM_ADDR_W-1:0] debug_addr_value;
reg [`ROW_ADDR_W-1:0] debug_row_addr_value;
reg [`OFFSET_W-1:0] debug_offset_value;

// 对外直接导出 lane 级 ready/resp。
assign mem_req_ready = mem_req_ready_r;
assign mem_resp_valid = mem_resp_valid_r;
assign mem_resp_rdata = mem_resp_rdata_r;
assign mem_resp_id = mem_resp_id_r;
assign mem_resp_last = mem_resp_last_r;

// 为每个 flat bank 实例化一个 sram_bank。
// 注意这里把 resp_ready 固定拉高，说明 bank 侧响应由 subsystem 立即接住，
// 不再向下层反压。
generate
    for (bank_gi = 0; bank_gi < TOTAL_BANKS; bank_gi = bank_gi + 1) begin : gen_banks
        sram_bank u_sram_bank (
            .clk(clk),
            .rst_n(rst_n),
            .req_valid(bank_req_valid_r[bank_gi]),
            .req_ready(bank_req_ready_w[bank_gi]),
            .req_write(bank_req_write_r[bank_gi]),
            .req_row_addr(bank_req_row_addr_r[bank_gi]),
            .req_offset(bank_req_offset_r[bank_gi]),
            .req_wdata(bank_req_wdata_r[bank_gi]),
            .req_id(bank_req_id_r[bank_gi]),
            .resp_valid(bank_resp_valid_w[bank_gi]),
            .resp_ready({`SUBBANK_NUM_PER_BANK{1'b1}}),
            .resp_rdata(bank_resp_rdata_w[bank_gi]),
            .resp_id(bank_resp_id_w[bank_gi]),
            .resp_last(bank_resp_last_w[bank_gi])
        );
    end
endgenerate

// 组合仲裁/路由逻辑：
// 1. 清空所有输出和临时状态；
// 2. 把 bank 返回的响应按 owner_lane 回灌到对应 lane；
// 3. 按 round-robin 起点扫描各 lane，请求地址解码成 bank/subbank/row/offset；
// 4. 同拍若目标 subbank 尚未被 claim，则把请求打到对应 bank；
// 5. 如果该 subbank ready，则本拍接受这条 lane。
always @* begin
    mem_req_ready_r = {`MEM_REQ_LANES{1'b0}};
    mem_resp_valid_r = {`MEM_REQ_LANES{1'b0}};
    mem_resp_rdata_r = {(`MEM_REQ_LANES*`SRAM_RDATA_W){1'b0}};
    mem_resp_id_r = {(`MEM_REQ_LANES*`REQ_ID_W){1'b0}};
    mem_resp_last_r = {`MEM_REQ_LANES{1'b0}};
    lane_release_now_r = {`MEM_REQ_LANES{1'b0}};
    lane_accept_valid_r = {`MEM_REQ_LANES{1'b0}};
    lane_accept_read_r = {`MEM_REQ_LANES{1'b0}};

    for (lane_i = 0; lane_i < `MEM_REQ_LANES; lane_i = lane_i + 1) begin
        // 默认清空本拍每条 lane 的目标 bank/subbank 记录。
        lane_target_bank_r[lane_i] = {TOTAL_BANKS_W{1'b0}};
        lane_target_subbank_r[lane_i] = {`SUBBANK_ID_W{1'b0}};
    end

    for (bank_i = 0; bank_i < TOTAL_BANKS; bank_i = bank_i + 1) begin
        // 默认情况下，不向任何 bank/subbank 发请求。
        bank_req_valid_r[bank_i] = {`SUBBANK_NUM_PER_BANK{1'b0}};
        bank_req_write_r[bank_i] = {`SUBBANK_NUM_PER_BANK{1'b0}};
        bank_req_row_addr_r[bank_i] =
            {(`SUBBANK_NUM_PER_BANK*`ROW_ADDR_W){1'b0}};
        bank_req_offset_r[bank_i] =
            {(`SUBBANK_NUM_PER_BANK*`OFFSET_W){1'b0}};
        bank_req_wdata_r[bank_i] =
            {(`SUBBANK_NUM_PER_BANK*`SRAM_WDATA_W){1'b0}};
        bank_req_id_r[bank_i] =
            {(`SUBBANK_NUM_PER_BANK*`REQ_ID_W){1'b0}};
        claimed_subbank_r[bank_i] = {`SUBBANK_NUM_PER_BANK{1'b0}};
    end

    for (bank_i = 0; bank_i < TOTAL_BANKS; bank_i = bank_i + 1) begin
        for (subbank_i = 0;
             subbank_i < `SUBBANK_NUM_PER_BANK;
             subbank_i = subbank_i + 1) begin
            if (bank_resp_valid_w[bank_i][subbank_i] &&
                owner_valid_r[bank_i][subbank_i]) begin
                // 找到读响应后，根据 owner 表把它送回原始 lane。
                owner_lane_i = owner_lane_r[bank_i][subbank_i];
                lane_release_now_r[owner_lane_i] = 1'b1;
                mem_resp_valid_r[owner_lane_i] = 1'b1;
                mem_resp_rdata_r[(owner_lane_i*`SRAM_RDATA_W) +: `SRAM_RDATA_W] =
                    bank_resp_rdata_w[bank_i][(subbank_i*`SRAM_RDATA_W) +: `SRAM_RDATA_W];
                mem_resp_id_r[(owner_lane_i*`REQ_ID_W) +: `REQ_ID_W] =
                    bank_resp_id_w[bank_i][(subbank_i*`REQ_ID_W) +: `REQ_ID_W];
                mem_resp_last_r[owner_lane_i] = bank_resp_last_w[bank_i][subbank_i];
            end
        end
    end

    for (issue_scan_step_i = 0;
         issue_scan_step_i < `MEM_REQ_LANES;
         issue_scan_step_i = issue_scan_step_i + 1) begin
        // 从轮询起点开始扫描所有 lane，实现简单 RR 仲裁。
        issue_lane_i = (lane_issue_rr_start_r + issue_scan_step_i);
        if (issue_lane_i >= `MEM_REQ_LANES) begin
            issue_lane_i = issue_lane_i - `MEM_REQ_LANES;
        end

        // 对扁平地址做字段拆解：
        // offset / row_addr / subbank / bank / sram_id。
        lane_addr_value =
            mem_req_addr[(issue_lane_i*`SRAM_ADDR_W) +: `SRAM_ADDR_W];
        lane_offset_value = lane_addr_value[`OFFSET_W-1:0];
        lane_row_addr_value =
            lane_addr_value[`OFFSET_W +: `ROW_ADDR_W];
        lane_subbank_id_value =
            lane_addr_value[(`OFFSET_W + `ROW_ADDR_W) +: `SUBBANK_ID_W];
        lane_bank_id_value =
            lane_addr_value[(`OFFSET_W + `ROW_ADDR_W + `SUBBANK_ID_W) +: `BANK_ID_W];
        lane_sram_id_value =
            lane_addr_value[(`OFFSET_W + `ROW_ADDR_W + `SUBBANK_ID_W + `BANK_ID_W) +: `SRAM_ID_W];
        target_bank_i = (lane_sram_id_value * `SRAM_BANK_NUM) + lane_bank_id_value;

        if (mem_req_valid[issue_lane_i] &&
            (!lane_busy_r[issue_lane_i] || lane_release_now_r[issue_lane_i])) begin
            // 同一个 flat bank 的同一个 subbank 一拍内只允许一个 lane claim。
            if (!claimed_subbank_r[target_bank_i][lane_subbank_id_value]) begin
                bank_req_valid_r[target_bank_i][lane_subbank_id_value] = 1'b1;
                bank_req_write_r[target_bank_i][lane_subbank_id_value] =
                    mem_req_write[issue_lane_i];
                bank_req_row_addr_r[target_bank_i]
                    [(lane_subbank_id_value*`ROW_ADDR_W) +: `ROW_ADDR_W] =
                    lane_row_addr_value;
                bank_req_offset_r[target_bank_i]
                    [(lane_subbank_id_value*`OFFSET_W) +: `OFFSET_W] =
                    lane_offset_value;
                bank_req_wdata_r[target_bank_i]
                    [(lane_subbank_id_value*`SRAM_WDATA_W) +: `SRAM_WDATA_W] =
                    mem_req_wdata[(issue_lane_i*`SRAM_WDATA_W) +: `SRAM_WDATA_W];
                bank_req_id_r[target_bank_i]
                    [(lane_subbank_id_value*`REQ_ID_W) +: `REQ_ID_W] =
                    mem_req_id[(issue_lane_i*`REQ_ID_W) +: `REQ_ID_W];
                claimed_subbank_r[target_bank_i][lane_subbank_id_value] = 1'b1;

                if (bank_req_ready_w[target_bank_i][lane_subbank_id_value]) begin
                    // 下层 ready 时，这条 lane 本拍真正被接受。
                    mem_req_ready_r[issue_lane_i] = 1'b1;
                    lane_accept_valid_r[issue_lane_i] = 1'b1;
                    lane_accept_read_r[issue_lane_i] = !mem_req_write[issue_lane_i];
                    lane_target_bank_r[issue_lane_i] = target_bank_i[TOTAL_BANKS_W-1:0];
                    lane_target_subbank_r[issue_lane_i] = lane_subbank_id_value;
                end
            end
        end
    end
end

// 主时序块：
// 1. 复位时清空 busy/owner/debug 镜像；
// 2. 若本拍接受了请求，则推进 RR 起点；
// 3. 读响应回来时清掉 owner 与 lane_busy；
// 4. 对新接受的读请求登记 owner；
// 5. 对新接受的写请求更新 debug 镜像。
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        // 复位时所有 lane 都不忙。
        for (lane_i = 0; lane_i < `MEM_REQ_LANES; lane_i = lane_i + 1) begin
            lane_busy_r[lane_i] <= 1'b0;
        end
        lane_issue_rr_start_r <= {LANE_IDX_W{1'b0}};
        for (bank_i = 0; bank_i < TOTAL_BANKS; bank_i = bank_i + 1) begin
            for (subbank_i = 0;
                 subbank_i < `SUBBANK_NUM_PER_BANK;
                 subbank_i = subbank_i + 1) begin
                owner_valid_r[bank_i][subbank_i] <= 1'b0;
                owner_lane_r[bank_i][subbank_i] <= {LANE_IDX_W{1'b0}};
            end
        end
    end else begin
        // 只要本拍至少接受过一个请求，就把 RR 起点加一。
        if (|lane_accept_valid_r) begin
            lane_issue_rr_start_r <= lane_issue_rr_start_r + 1'b1;
        end

        for (bank_i = 0; bank_i < TOTAL_BANKS; bank_i = bank_i + 1) begin
            for (subbank_i = 0;
                 subbank_i < `SUBBANK_NUM_PER_BANK;
                 subbank_i = subbank_i + 1) begin
                if (bank_resp_valid_w[bank_i][subbank_i] &&
                    owner_valid_r[bank_i][subbank_i]) begin
                    // 某个挂起读事务完成后，释放对应 lane 和 owner 槽位。
                    lane_busy_r[owner_lane_r[bank_i][subbank_i]] <= 1'b0;
                    owner_valid_r[bank_i][subbank_i] <= 1'b0;
                end
            end
        end

        for (lane_i = 0; lane_i < `MEM_REQ_LANES; lane_i = lane_i + 1) begin
            if (lane_accept_valid_r[lane_i] && lane_accept_read_r[lane_i]) begin
                // 读请求被接受：标记该 lane busy，并把 owner 绑到目标 bank/subbank。
                lane_busy_r[lane_i] <= 1'b1;
                owner_valid_r[lane_target_bank_r[lane_i]][lane_target_subbank_r[lane_i]] <=
                    1'b1;
                owner_lane_r[lane_target_bank_r[lane_i]][lane_target_subbank_r[lane_i]] <=
                    lane_i[LANE_IDX_W-1:0];
            end else if (lane_accept_valid_r[lane_i] && !lane_accept_read_r[lane_i]) begin
                // 写请求被接受：no-op (debug mirror disabled)
            end
        end
    end
end

endmodule
