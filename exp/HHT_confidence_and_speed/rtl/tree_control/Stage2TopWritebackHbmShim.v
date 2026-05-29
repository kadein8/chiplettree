`timescale 1ns/1ps

`include "config/interface_params.vh"
`include "config/memory_params.vh"

module Stage2TopWritebackHbmShim (
    input                         enable,
    input                         wb_valid,
    input                         wb_ready,
    input  [`TOKEN_ID_W-1:0]      wb_token_id,
    input  [`SRAM_ADDR_W-1:0]     wb_addr,
    input  [`SRAM_WDATA_W-1:0]    wb_data,
    output                        hbm_req_valid,
    output                        hbm_req_write,
    output [`HBM_ADDR_W-1:0]      hbm_req_addr,
    output [`HBM_DATA_W-1:0]      hbm_req_wdata,
    output [`REQ_ID_W-1:0]        hbm_req_id
);

wire fire_w;

assign fire_w = enable && wb_valid && wb_ready;

assign hbm_req_valid = fire_w;
assign hbm_req_write = fire_w;
assign hbm_req_addr = fire_w ?
                      {{(`HBM_ADDR_W-`SRAM_ADDR_W){1'b0}}, wb_addr} :
                      {`HBM_ADDR_W{1'b0}};
assign hbm_req_wdata = fire_w ?
                       {{(`HBM_DATA_W-`SRAM_WDATA_W){1'b0}}, wb_data} :
                       {`HBM_DATA_W{1'b0}};
assign hbm_req_id = fire_w ? wb_token_id[`REQ_ID_W-1:0] :
                    {`REQ_ID_W{1'b0}};

endmodule
