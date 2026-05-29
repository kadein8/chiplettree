`include "config/interface_params.vh"
`include "config/memory_params.vh"
`timescale 1ns/1ps

/*
 * 文件作用：
 * 1. 本文件实现论文整合路径末端的 writeback 小缓冲。
 * 2. 它把上游已经形成好的 result 结果暂存一拍，再通过 `wb_*` 接口送给更外层
 *    的 writeback / HBM shim。
 * 3. 在完整路径里，它位于：
 *    comparator / operator result / bonus token result
 *      -> IntegrationWritebackPart
 *      -> Stage2TopWritebackHbmShim / 外部 writeback 通道
 * 4. 这个模块不负责做比较或地址计算，只负责：
 *    - 接住一条结果；
 *    - 等下游 `wb_ready`；
 *    - 在真正送出时打一拍 `wb_done`，并把 `wb_error` 由 status 汇总出来。
 */
module IntegrationWritebackPart #(
    parameter RESULT_STATUS_W = 2
) (
    // 时钟与复位。
    input                        clk,
    input                        rst_n,

    // 上游结果入口。
    input                        result_valid,
    output                       result_ready,
    input  [`TOKEN_ID_W-1:0]     result_token_id,
    input  [`SRAM_ADDR_W-1:0]    result_addr,
    input  [`SRAM_WDATA_W-1:0]   result_data,
    input  [RESULT_STATUS_W-1:0] result_status,

    // 下游 writeback 输出。
    output                       wb_valid,
    input                        wb_ready,
    output [`TOKEN_ID_W-1:0]     wb_token_id,
    output [`SRAM_ADDR_W-1:0]    wb_addr,
    output [`SRAM_WDATA_W-1:0]   wb_data,
    output [RESULT_STATUS_W-1:0] wb_status,
    output                       wb_done,
    output                       wb_error
);

// 单条结果缓冲寄存器。
reg                        entry_valid_r;
reg [`TOKEN_ID_W-1:0]      entry_token_id_r;
reg [`SRAM_ADDR_W-1:0]     entry_addr_r;
reg [`SRAM_WDATA_W-1:0]    entry_data_r;
reg [RESULT_STATUS_W-1:0]  entry_status_r;
reg                        wb_done_r;
reg                        wb_error_r;

// 基础握手。
wire result_fire_w;
wire wb_fire_w;

// 只有缓冲空时才接收新结果。
assign result_ready = !entry_valid_r;
assign result_fire_w = result_valid && result_ready;

// 当前缓冲中的结果直接暴露给下游 writeback 接口。
assign wb_valid = entry_valid_r;
assign wb_token_id = entry_token_id_r;
assign wb_addr = entry_addr_r;
assign wb_data = entry_data_r;
assign wb_status = entry_status_r;
assign wb_fire_w = wb_valid && wb_ready;

assign wb_done = wb_done_r;
assign wb_error = wb_error_r;

// 主时序块：
// 1. 复位时清空缓冲；
// 2. 平时默认把 `wb_done/wb_error` 作为单拍脉冲清零；
// 3. 收到新 result 时写入缓冲；
// 4. 下游真正消费该条结果时，清空缓冲并产生完成/错误脉冲。
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        // 复位时缓冲为空。
        entry_valid_r <= 1'b0;
        entry_token_id_r <= {`TOKEN_ID_W{1'b0}};
        entry_addr_r <= {`SRAM_ADDR_W{1'b0}};
        entry_data_r <= {`SRAM_WDATA_W{1'b0}};
        entry_status_r <= {RESULT_STATUS_W{1'b0}};
        wb_done_r <= 1'b0;
        wb_error_r <= 1'b0;
    end else begin
        // `wb_done` 与 `wb_error` 只打一拍。
        wb_done_r <= 1'b0;
        wb_error_r <= 1'b0;

        if (result_fire_w) begin
            // 接住一条新结果。
            entry_valid_r <= 1'b1;
            entry_token_id_r <= result_token_id;
            entry_addr_r <= result_addr;
            entry_data_r <= result_data;
            entry_status_r <= result_status;
        end else if (wb_fire_w) begin
            // 下游消耗后，清空条目，并把状态位归并成错误标志。
            entry_valid_r <= 1'b0;
            wb_done_r <= 1'b1;
            wb_error_r <= |entry_status_r;
        end
    end
end

endmodule
