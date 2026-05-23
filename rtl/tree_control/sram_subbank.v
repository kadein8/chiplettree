`timescale 1ns/1ps

`include "config/interface_params.vh"
`include "config/memory_params.vh"

/*
 * 文件作用：
 * 1. 本文件实现共享 SRAM 基础设施里的最小存储单元 sram_subbank。
 * 2. 它维护一个本地 storage_beats 数组，支持：
 *    - 同拍写入；
 *    - 一拍后返回的同步读出。
 * 3. 在完整路径里，它位于：
 *    request_controller / sram_subsystem
 *      -> sram_bank
 *      -> sram_subbank
 * 4. 这个模块是整个 TreeControl / transformer 共享存储系统的最底层存储模型，
 *    上层的 bank、subsystem、request_controller 都只是在组织和路由这些读写请求。
 */
module sram_subbank (
    // 时钟与复位。
    input                       clk,
    input                       rst_n,

    // 单路请求接口。
    input                       req_valid,
    output                      req_ready,
    input                       req_write,
    input  [`ROW_ADDR_W-1:0]    req_row_addr,
    input  [`OFFSET_W-1:0]      req_offset,
    input  [`SRAM_WDATA_W-1:0]  req_wdata,
    input  [`REQ_ID_W-1:0]      req_id,

    // 单路响应接口。
    output                      resp_valid,
    input                       resp_ready,
    output [`SRAM_RDATA_W-1:0]  resp_rdata,
    output [`REQ_ID_W-1:0]      resp_id,
    output                      resp_last
);

// 该 subbank 内可寻址的 beat 数。
localparam integer SUBBANK_DEPTH = `SUBBANK_SIZE_BYTES;

// 实际存储阵列。
reg [`SRAM_RDATA_W-1:0] storage_beats [0:SUBBANK_DEPTH-1];

// 读请求采用“挂起一拍后返回”的模型，这些寄存器用于缓存待读事务。
reg read_pending_valid_r;
reg [`ROW_ADDR_W-1:0] read_pending_row_addr_r;
reg [`OFFSET_W-1:0] read_pending_offset_r;
reg [`REQ_ID_W-1:0] read_pending_id_r;

// 响应寄存器。
reg resp_valid_r;
reg [`SRAM_RDATA_W-1:0] resp_rdata_r;
reg [`REQ_ID_W-1:0] resp_id_r;
reg resp_last_r;

// 循环变量与线性地址拼接临时变量。
integer init_i;
integer req_base_addr_i;
integer resp_base_addr_i;

// 只有在“没有挂起读请求，且没有旧响应阻塞”时，才能接新的请求。
assign req_ready =
    !read_pending_valid_r &&
    !(resp_valid_r && !resp_ready);

// 导出响应寄存器。
assign resp_valid = resp_valid_r;
assign resp_rdata = resp_rdata_r;
assign resp_id = resp_id_r;
assign resp_last = resp_last_r;

// 主时序逻辑：
// 1. 复位时清空存储和所有状态；
// 2. 清理已经被下游接走的旧响应；
// 3. 若有挂起读请求，则本拍返回数据；
// 4. 若本拍收到新请求，则写请求直接写入，读请求进入 pending。
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        // 复位时把整个 subbank 内容清零。
        for (init_i = 0; init_i < SUBBANK_DEPTH; init_i = init_i + 1) begin
            storage_beats[init_i] <= {`SRAM_RDATA_W{1'b0}};
        end

        // 清空待读事务和响应寄存器。
        read_pending_valid_r <= 1'b0;
        read_pending_row_addr_r <= {`ROW_ADDR_W{1'b0}};
        read_pending_offset_r <= {`OFFSET_W{1'b0}};
        read_pending_id_r <= {`REQ_ID_W{1'b0}};

        resp_valid_r <= 1'b0;
        resp_rdata_r <= {`SRAM_RDATA_W{1'b0}};
        resp_id_r <= {`REQ_ID_W{1'b0}};
        resp_last_r <= 1'b0;
    end else begin
        // 旧响应被消费后，清掉 valid/last。
        if (resp_valid_r && resp_ready) begin
            resp_valid_r <= 1'b0;
            resp_last_r <= 1'b0;
        end

        if (read_pending_valid_r) begin
            // 把上一拍挂起的读请求在这一拍真正返回出来。
            resp_valid_r <= 1'b1;
            resp_id_r <= read_pending_id_r;
            resp_last_r <= 1'b1;
            resp_base_addr_i =
                {read_pending_row_addr_r, read_pending_offset_r};
            if (resp_base_addr_i < SUBBANK_DEPTH) begin
                // 合法地址返回真实存储内容。
                resp_rdata_r <= storage_beats[resp_base_addr_i];
            end else begin
                // 越界地址返回 0，避免把非法地址扩散成 X。
                resp_rdata_r <= {`SRAM_RDATA_W{1'b0}};
            end
            read_pending_valid_r <= 1'b0;
        end

        if (req_valid && req_ready) begin
            // row_addr 与 offset 拼成线性地址索引。
            req_base_addr_i = {req_row_addr, req_offset};
            if (req_write) begin
                // 写请求：同拍写入数组。
                if (req_base_addr_i < SUBBANK_DEPTH) begin
                    storage_beats[req_base_addr_i] <= req_wdata;
                end
            end else begin
                // 读请求：只记下参数，数据下一拍返回。
                read_pending_valid_r <= 1'b1;
                read_pending_row_addr_r <= req_row_addr;
                read_pending_offset_r <= req_offset;
                read_pending_id_r <= req_id;
            end
        end
    end
end

endmodule
