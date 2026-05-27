`timescale 1ns/1ps

`include "config/interface_params.vh"
`include "config/memory_params.vh"

module sram_bank (
    input                                               clk,
    input                                               rst_n,
    input  [`SUBBANK_NUM_PER_BANK-1:0]                  req_valid,
    output [`SUBBANK_NUM_PER_BANK-1:0]                  req_ready,
    input  [`SUBBANK_NUM_PER_BANK-1:0]                  req_write,
    input  [`SUBBANK_NUM_PER_BANK*`ROW_ADDR_W-1:0]      req_row_addr,
    input  [`SUBBANK_NUM_PER_BANK*`OFFSET_W-1:0]        req_offset,
    input  [`SUBBANK_NUM_PER_BANK*`SRAM_WDATA_W-1:0]    req_wdata,
    input  [`SUBBANK_NUM_PER_BANK*`REQ_ID_W-1:0]        req_id,
    output [`SUBBANK_NUM_PER_BANK-1:0]                  resp_valid,
    input  [`SUBBANK_NUM_PER_BANK-1:0]                  resp_ready,
    output [`SUBBANK_NUM_PER_BANK*`SRAM_RDATA_W-1:0]    resp_rdata,
    output [`SUBBANK_NUM_PER_BANK*`REQ_ID_W-1:0]        resp_id,
    output [`SUBBANK_NUM_PER_BANK-1:0]                  resp_last
);

genvar subbank_gi;
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
