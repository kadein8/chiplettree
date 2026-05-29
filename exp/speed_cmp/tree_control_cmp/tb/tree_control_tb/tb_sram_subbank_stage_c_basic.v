`timescale 1ns/1ps

`include "config/interface_params.vh"
`include "config/memory_params.vh"

module tb_sram_subbank_stage_c_basic;

reg clk;
reg rst_n;

reg req_valid;
wire req_ready;
reg req_write;
reg [`ROW_ADDR_W-1:0] req_row_addr;
reg [`OFFSET_W-1:0] req_offset;
reg [`SRAM_WDATA_W-1:0] req_wdata;
reg [`REQ_ID_W-1:0] req_id;

wire resp_valid;
reg resp_ready;
wire [`SRAM_RDATA_W-1:0] resp_rdata;
wire [`REQ_ID_W-1:0] resp_id;
wire resp_last;

sram_subbank u_sram_subbank (
    .clk(clk),
    .rst_n(rst_n),
    .req_valid(req_valid),
    .req_ready(req_ready),
    .req_write(req_write),
    .req_row_addr(req_row_addr),
    .req_offset(req_offset),
    .req_wdata(req_wdata),
    .req_id(req_id),
    .resp_valid(resp_valid),
    .resp_ready(resp_ready),
    .resp_rdata(resp_rdata),
    .resp_id(resp_id),
    .resp_last(resp_last)
);

always #5 clk = ~clk;

task drive_req;
    input write_i;
    input [`ROW_ADDR_W-1:0] row_i;
    input [`OFFSET_W-1:0] offset_i;
    input [`SRAM_WDATA_W-1:0] wdata_i;
    input [`REQ_ID_W-1:0] id_i;
    begin
        req_valid = 1'b1;
        req_write = write_i;
        req_row_addr = row_i;
        req_offset = offset_i;
        req_wdata = wdata_i;
        req_id = id_i;
        @(posedge clk);
        #1;
        req_valid = 1'b0;
    end
endtask

initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    req_valid = 1'b0;
    req_write = 1'b0;
    req_row_addr = {`ROW_ADDR_W{1'b0}};
    req_offset = {`OFFSET_W{1'b0}};
    req_wdata = {`SRAM_WDATA_W{1'b0}};
    req_id = {`REQ_ID_W{1'b0}};
    resp_ready = 1'b1;

    repeat (3) @(posedge clk);
    rst_n = 1'b1;

    #1;
    if (!req_ready) begin
        $fatal(1, "sram_subbank should be ready after reset");
    end

    drive_req(1'b0, 8'h00, 4'h0, 128'h0, 4'h1);

    #1;
    if (resp_valid) begin
        $fatal(1, "read response should not return in the accept cycle");
    end

    @(posedge clk);
    #1;
    if (!resp_valid || resp_id != 4'h1 || resp_last != 1'b1) begin
        $fatal(1, "read response did not return at N+1");
    end

    if (resp_rdata != 128'h0) begin
        $fatal(1, "unwritten location should read back as zero");
    end

    resp_ready = 1'b0;
    #1;
    if (req_ready) begin
        $fatal(1, "held response should backpressure new traffic");
    end

    @(posedge clk);
    #1;
    if (!resp_valid || resp_id != 4'h1) begin
        $fatal(1, "held response should remain stable until resp_ready");
    end

    resp_ready = 1'b1;
    @(posedge clk);
    #1;
    if (resp_valid) begin
        $fatal(1, "response should clear after acceptance");
    end

    if (!req_ready) begin
        $fatal(1, "subbank should return to ready after response drain");
    end

    drive_req(
        1'b1,
        8'h01,
        4'h2,
        128'h11223344_55667788_99aabbcc_ddeeff00,
        4'h2
    );

    @(posedge clk);
    #1;
    if (resp_valid) begin
        $fatal(1, "write request should not emit a read response");
    end

    drive_req(1'b0, 8'h01, 4'h2, 128'h0, 4'h3);

    @(posedge clk);
    #1;
    if (!resp_valid || resp_id != 4'h3 || resp_last != 1'b1) begin
        $fatal(1, "write-followed-by-read did not return a response");
    end

    if (resp_rdata != 128'h11223344_55667788_99aabbcc_ddeeff00) begin
        $fatal(1, "read did not observe the newest written value");
    end

    $display("tb_sram_subbank_stage_c_basic PASS");
    $finish;
end

endmodule
