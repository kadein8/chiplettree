`timescale 1ns/1ps

`include "config/interface_params.vh"
`include "config/memory_params.vh"

module sram_subbank (
    input                       clk,
    input                       rst_n,
    input                       req_valid,
    output                      req_ready,
    input                       req_write,
    input  [`ROW_ADDR_W-1:0]    req_row_addr,
    input  [`OFFSET_W-1:0]      req_offset,
    input  [`SRAM_WDATA_W-1:0]  req_wdata,
    input  [`REQ_ID_W-1:0]      req_id,
    output                      resp_valid,
    input                       resp_ready,
    output [`SRAM_RDATA_W-1:0]  resp_rdata,
    output [`REQ_ID_W-1:0]      resp_id,
    output                      resp_last
);

localparam integer SUBBANK_BYTE_DEPTH = `SUBBANK_SIZE_BYTES;
localparam integer SRAM_BEAT_BYTES = (`SRAM_RDATA_W / 8);

reg [7:0] storage_bytes [0:SUBBANK_BYTE_DEPTH-1];

reg read_pending_valid_r;
reg [`ROW_ADDR_W-1:0] read_pending_row_addr_r;
reg [`OFFSET_W-1:0] read_pending_offset_r;
reg [`REQ_ID_W-1:0] read_pending_id_r;

reg resp_valid_r;
reg [`SRAM_RDATA_W-1:0] resp_rdata_r;
reg [`REQ_ID_W-1:0] resp_id_r;
reg resp_last_r;

integer init_i;
integer byte_i;
integer req_base_addr_i;
integer resp_base_addr_i;

assign req_ready =
    !read_pending_valid_r &&
    !(resp_valid_r && !resp_ready);

assign resp_valid = resp_valid_r;
assign resp_rdata = resp_rdata_r;
assign resp_id = resp_id_r;
assign resp_last = resp_last_r;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        for (init_i = 0; init_i < SUBBANK_BYTE_DEPTH; init_i = init_i + 1) begin
            storage_bytes[init_i] <= 8'h00;
        end

        read_pending_valid_r <= 1'b0;
        read_pending_row_addr_r <= {`ROW_ADDR_W{1'b0}};
        read_pending_offset_r <= {`OFFSET_W{1'b0}};
        read_pending_id_r <= {`REQ_ID_W{1'b0}};

        resp_valid_r <= 1'b0;
        resp_rdata_r <= {`SRAM_RDATA_W{1'b0}};
        resp_id_r <= {`REQ_ID_W{1'b0}};
        resp_last_r <= 1'b0;
    end else begin
        if (resp_valid_r && resp_ready) begin
            resp_valid_r <= 1'b0;
            resp_last_r <= 1'b0;
        end

        if (read_pending_valid_r) begin
            resp_valid_r <= 1'b1;
            resp_id_r <= read_pending_id_r;
            resp_last_r <= 1'b1;
            resp_base_addr_i =
                (read_pending_row_addr_r << `OFFSET_W) + read_pending_offset_r;
            for (byte_i = 0; byte_i < SRAM_BEAT_BYTES; byte_i = byte_i + 1) begin
                if ((resp_base_addr_i + byte_i) < SUBBANK_BYTE_DEPTH) begin
                    resp_rdata_r[(byte_i*8) +: 8] <=
                        storage_bytes[resp_base_addr_i + byte_i];
                end else begin
                    resp_rdata_r[(byte_i*8) +: 8] <= 8'h00;
                end
            end
            read_pending_valid_r <= 1'b0;
        end

        if (req_valid && req_ready) begin
            req_base_addr_i = (req_row_addr << `OFFSET_W) + req_offset;
            if (req_write) begin
                for (byte_i = 0; byte_i < SRAM_BEAT_BYTES; byte_i = byte_i + 1) begin
                    if ((req_base_addr_i + byte_i) < SUBBANK_BYTE_DEPTH) begin
                        storage_bytes[req_base_addr_i + byte_i] <=
                            req_wdata[(byte_i*8) +: 8];
                    end
                end
            end else begin
                read_pending_valid_r <= 1'b1;
                read_pending_row_addr_r <= req_row_addr;
                read_pending_offset_r <= req_offset;
                read_pending_id_r <= req_id;
            end
        end
    end
end

endmodule
