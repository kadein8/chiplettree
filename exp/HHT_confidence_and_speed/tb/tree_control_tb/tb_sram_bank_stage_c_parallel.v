`timescale 1ns/1ps

`include "config/interface_params.vh"
`include "config/memory_params.vh"

module tb_sram_bank_stage_c_parallel;

reg clk;
reg rst_n;

reg [`SUBBANK_NUM_PER_BANK-1:0] req_valid;
wire [`SUBBANK_NUM_PER_BANK-1:0] req_ready;
reg [`SUBBANK_NUM_PER_BANK-1:0] req_write;
reg [`SUBBANK_NUM_PER_BANK*`ROW_ADDR_W-1:0] req_row_addr;
reg [`SUBBANK_NUM_PER_BANK*`OFFSET_W-1:0] req_offset;
reg [`SUBBANK_NUM_PER_BANK*`SRAM_WDATA_W-1:0] req_wdata;
reg [`SUBBANK_NUM_PER_BANK*`REQ_ID_W-1:0] req_id;
wire [`SUBBANK_NUM_PER_BANK-1:0] resp_valid;
reg [`SUBBANK_NUM_PER_BANK-1:0] resp_ready;
wire [`SUBBANK_NUM_PER_BANK*`SRAM_RDATA_W-1:0] resp_rdata;
wire [`SUBBANK_NUM_PER_BANK*`REQ_ID_W-1:0] resp_id;
wire [`SUBBANK_NUM_PER_BANK-1:0] resp_last;

localparam integer SB0 = 0;
localparam integer SB1 = 1;

sram_bank u_sram_bank (
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

task clear_req_vectors;
    begin
        req_valid = {`SUBBANK_NUM_PER_BANK{1'b0}};
        req_write = {`SUBBANK_NUM_PER_BANK{1'b0}};
        req_row_addr = {(`SUBBANK_NUM_PER_BANK*`ROW_ADDR_W){1'b0}};
        req_offset = {(`SUBBANK_NUM_PER_BANK*`OFFSET_W){1'b0}};
        req_wdata = {(`SUBBANK_NUM_PER_BANK*`SRAM_WDATA_W){1'b0}};
        req_id = {(`SUBBANK_NUM_PER_BANK*`REQ_ID_W){1'b0}};
    end
endtask

task drive_two_lane_req;
    input write0_i;
    input [`ROW_ADDR_W-1:0] row0_i;
    input [`OFFSET_W-1:0] offset0_i;
    input [`SRAM_WDATA_W-1:0] wdata0_i;
    input [`REQ_ID_W-1:0] id0_i;
    input write1_i;
    input [`ROW_ADDR_W-1:0] row1_i;
    input [`OFFSET_W-1:0] offset1_i;
    input [`SRAM_WDATA_W-1:0] wdata1_i;
    input [`REQ_ID_W-1:0] id1_i;
    begin
        clear_req_vectors();
        req_valid[SB0] = 1'b1;
        req_write[SB0] = write0_i;
        req_row_addr[(SB0*`ROW_ADDR_W) +: `ROW_ADDR_W] = row0_i;
        req_offset[(SB0*`OFFSET_W) +: `OFFSET_W] = offset0_i;
        req_wdata[(SB0*`SRAM_WDATA_W) +: `SRAM_WDATA_W] = wdata0_i;
        req_id[(SB0*`REQ_ID_W) +: `REQ_ID_W] = id0_i;

        req_valid[SB1] = 1'b1;
        req_write[SB1] = write1_i;
        req_row_addr[(SB1*`ROW_ADDR_W) +: `ROW_ADDR_W] = row1_i;
        req_offset[(SB1*`OFFSET_W) +: `OFFSET_W] = offset1_i;
        req_wdata[(SB1*`SRAM_WDATA_W) +: `SRAM_WDATA_W] = wdata1_i;
        req_id[(SB1*`REQ_ID_W) +: `REQ_ID_W] = id1_i;

        @(posedge clk);
        #1;
        clear_req_vectors();
    end
endtask

initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    clear_req_vectors();
    resp_ready = {`SUBBANK_NUM_PER_BANK{1'b1}};

    repeat (3) @(posedge clk);
    rst_n = 1'b1;

    #1;
    if (!req_ready[SB0] || !req_ready[SB1]) begin
        $fatal(1, "two different subbanks should be ready after reset");
    end

    drive_two_lane_req(
        1'b1, 8'h04, 4'h0, 128'h01020304_05060708_11121314_15161718, 4'h1,
        1'b1, 8'h05, 4'h1, 128'h21222324_25262728_31323334_35363738, 4'h2
    );

    @(posedge clk);
    #1;
    if (resp_valid[SB0] || resp_valid[SB1]) begin
        $fatal(1, "write-only cycle should not emit read responses");
    end

    drive_two_lane_req(
        1'b0, 8'h04, 4'h0, 128'h0, 4'h3,
        1'b0, 8'h05, 4'h1, 128'h0, 4'h4
    );

    @(posedge clk);
    #1;
    if (!resp_valid[SB0] || !resp_valid[SB1]) begin
        $fatal(1, "different subbanks in one bank should return independently");
    end

    if (resp_id[(SB0*`REQ_ID_W) +: `REQ_ID_W] != 4'h3 ||
        resp_id[(SB1*`REQ_ID_W) +: `REQ_ID_W] != 4'h4) begin
        $fatal(1, "lane-local response ids mismatch");
    end

    if (!resp_last[SB0] || !resp_last[SB1]) begin
        $fatal(1, "each local response should be single-beat");
    end

    if (resp_rdata[(SB0*`SRAM_RDATA_W) +: `SRAM_RDATA_W] !=
            128'h01020304_05060708_11121314_15161718 ||
        resp_rdata[(SB1*`SRAM_RDATA_W) +: `SRAM_RDATA_W] !=
            128'h21222324_25262728_31323334_35363738) begin
        $fatal(1, "bank wrapper did not preserve lane-local data");
    end

    resp_ready[SB0] = 1'b0;
    @(posedge clk);
    #1;
    if (!resp_valid[SB0]) begin
        $fatal(1, "held response on one lane should stay valid");
    end
    if (!req_ready[SB1]) begin
        $fatal(1, "other subbank lane should remain independently ready");
    end

    clear_req_vectors();
    req_valid[SB1] = 1'b1;
    req_write[SB1] = 1'b1;
    req_row_addr[(SB1*`ROW_ADDR_W) +: `ROW_ADDR_W] = 8'h06;
    req_offset[(SB1*`OFFSET_W) +: `OFFSET_W] = 4'h2;
    req_wdata[(SB1*`SRAM_WDATA_W) +: `SRAM_WDATA_W] =
        128'h41424344_45464748_51525354_55565758;
    req_id[(SB1*`REQ_ID_W) +: `REQ_ID_W] = 4'h5;

    #1;
    if (!req_ready[SB1]) begin
        $fatal(1, "held response on lane 0 should not block lane 1 traffic");
    end

    @(posedge clk);
    #1;
    clear_req_vectors();
    resp_ready[SB0] = 1'b1;

    $display("tb_sram_bank_stage_c_parallel PASS");
    $finish;
end

endmodule
