`timescale 1ns/1ps

`include "config/interface_params.vh"
`include "config/memory_params.vh"

/*
 * 文件作用：
 * 1. 本文件实现论文共享存储基础设施中的单个 sram_bank。
 * 2. 它本身不做仲裁和复杂状态管理，只负责把一个 bank 再切成多个 subbank，
 *    然后把每一路请求/响应直连到对应的 sram_subbank。
 * 3. 在完整路径里，它位于：
 *    sram_subsystem
 *      -> sram_bank
 *      -> sram_subbank
 * 4. 因此这个模块是一个纯层级封装器，帮助把 bank 级接口按 subbank 粒度展开。
 */
module sram_bank (
    // 时钟与复位。
    input                                               clk,
    input                                               rst_n,

    // 每个 subbank 一路请求：
    // req_row_addr/req_offset 共同决定访问地址。
    input  [`SUBBANK_NUM_PER_BANK-1:0]                  req_valid,
    output [`SUBBANK_NUM_PER_BANK-1:0]                  req_ready,
    input  [`SUBBANK_NUM_PER_BANK-1:0]                  req_write,
    input  [`SUBBANK_NUM_PER_BANK*`ROW_ADDR_W-1:0]      req_row_addr,
    input  [`SUBBANK_NUM_PER_BANK*`OFFSET_W-1:0]        req_offset,
    input  [`SUBBANK_NUM_PER_BANK*`SRAM_WDATA_W-1:0]    req_wdata,
    input  [`SUBBANK_NUM_PER_BANK*`REQ_ID_W-1:0]        req_id,

    // 每个 subbank 一路响应。
    output [`SUBBANK_NUM_PER_BANK-1:0]                  resp_valid,
    input  [`SUBBANK_NUM_PER_BANK-1:0]                  resp_ready,
    output [`SUBBANK_NUM_PER_BANK*`SRAM_RDATA_W-1:0]    resp_rdata,
    output [`SUBBANK_NUM_PER_BANK*`REQ_ID_W-1:0]        resp_id,
    output [`SUBBANK_NUM_PER_BANK-1:0]                  resp_last
);

// generate 循环变量。
genvar subbank_gi;

// 对 bank 内每个 subbank 实例化一个独立的 sram_subbank。
// 各路总线通过位切片映射到对应实例。
generate
    for (subbank_gi = 0;
         subbank_gi < `SUBBANK_NUM_PER_BANK;
         subbank_gi = subbank_gi + 1) begin : gen_subbanks
        sram_subbank u_sram_subbank (
            .clk(clk),
            .rst_n(rst_n),
            .req_valid(req_valid[subbank_gi]),
            .req_ready(req_ready[subbank_gi]),
            .req_write(req_write[subbank_gi]),
            .req_row_addr(
                req_row_addr[(subbank_gi*`ROW_ADDR_W) +: `ROW_ADDR_W]
            ),
            .req_offset(
                req_offset[(subbank_gi*`OFFSET_W) +: `OFFSET_W]
            ),
            .req_wdata(
                req_wdata[(subbank_gi*`SRAM_WDATA_W) +: `SRAM_WDATA_W]
            ),
            .req_id(
                req_id[(subbank_gi*`REQ_ID_W) +: `REQ_ID_W]
            ),
            .resp_valid(resp_valid[subbank_gi]),
            .resp_ready(resp_ready[subbank_gi]),
            .resp_rdata(
                resp_rdata[(subbank_gi*`SRAM_RDATA_W) +: `SRAM_RDATA_W]
            ),
            .resp_id(
                resp_id[(subbank_gi*`REQ_ID_W) +: `REQ_ID_W]
            ),
            .resp_last(resp_last[subbank_gi])
        );
    end
endgenerate

endmodule
