`timescale 1ns/1ps

`include "config/interface_params.vh"
`include "config/memory_params.vh"

module tb_sram_subsystem_stage_c_route;

reg clk;
reg rst_n;

reg [`MEM_REQ_LANES-1:0] mem_req_valid;
wire [`MEM_REQ_LANES-1:0] mem_req_ready;
reg [`MEM_REQ_LANES-1:0] mem_req_write;
reg [`MEM_REQ_LANES*`SRAM_ADDR_W-1:0] mem_req_addr;
reg [`MEM_REQ_LANES*`SRAM_WDATA_W-1:0] mem_req_wdata;
reg [`MEM_REQ_LANES*`REQ_ID_W-1:0] mem_req_id;
wire [`MEM_REQ_LANES-1:0] mem_resp_valid;
wire [`MEM_REQ_LANES*`SRAM_RDATA_W-1:0] mem_resp_rdata;
wire [`MEM_REQ_LANES*`REQ_ID_W-1:0] mem_resp_id;
wire [`MEM_REQ_LANES-1:0] mem_resp_last;

localparam integer L0 = 0;
localparam integer L1 = 1;

sram_subsystem u_sram_subsystem (
    .clk(clk),
    .rst_n(rst_n),
    .mem_req_valid(mem_req_valid),
    .mem_req_ready(mem_req_ready),
    .mem_req_write(mem_req_write),
    .mem_req_addr(mem_req_addr),
    .mem_req_wdata(mem_req_wdata),
    .mem_req_id(mem_req_id),
    .mem_resp_valid(mem_resp_valid),
    .mem_resp_rdata(mem_resp_rdata),
    .mem_resp_id(mem_resp_id),
    .mem_resp_last(mem_resp_last)
);

always #5 clk = ~clk;

function [`SRAM_ADDR_W-1:0] pack_addr;
    input [`SRAM_ID_W-1:0] sram_i;
    input [`BANK_ID_W-1:0] bank_i;
    input [`SUBBANK_ID_W-1:0] subbank_i;
    input [`ROW_ADDR_W-1:0] row_i;
    input [`OFFSET_W-1:0] offset_i;
    begin
        pack_addr = {
            sram_i,
            bank_i,
            subbank_i,
            row_i,
            offset_i
        };
    end
endfunction

task clear_mem_req;
    begin
        mem_req_valid = {`MEM_REQ_LANES{1'b0}};
        mem_req_write = {`MEM_REQ_LANES{1'b0}};
        mem_req_addr = {(`MEM_REQ_LANES*`SRAM_ADDR_W){1'b0}};
        mem_req_wdata = {(`MEM_REQ_LANES*`SRAM_WDATA_W){1'b0}};
        mem_req_id = {(`MEM_REQ_LANES*`REQ_ID_W){1'b0}};
    end
endtask

task drive_lane_req;
    input integer lane_i;
    input write_i;
    input [`SRAM_ADDR_W-1:0] addr_i;
    input [`SRAM_WDATA_W-1:0] wdata_i;
    input [`REQ_ID_W-1:0] id_i;
    begin
        mem_req_valid[lane_i] = 1'b1;
        mem_req_write[lane_i] = write_i;
        mem_req_addr[(lane_i*`SRAM_ADDR_W) +: `SRAM_ADDR_W] = addr_i;
        mem_req_wdata[(lane_i*`SRAM_WDATA_W) +: `SRAM_WDATA_W] = wdata_i;
        mem_req_id[(lane_i*`REQ_ID_W) +: `REQ_ID_W] = id_i;
    end
endtask

initial begin
    reg [`SRAM_ADDR_W-1:0] addr_a;
    reg [`SRAM_ADDR_W-1:0] addr_b;
    reg [`SRAM_ADDR_W-1:0] addr_conflict;

    clk = 1'b0;
    rst_n = 1'b0;
    clear_mem_req();

    addr_a = pack_addr(2'd1, 4'd2, 5'd5, 8'h03, 4'h4);
    addr_b = pack_addr(2'd1, 4'd2, 5'd6, 8'h07, 4'h1);
    addr_conflict = pack_addr(2'd0, 4'd1, 5'd2, 8'h09, 4'h0);

    repeat (3) @(posedge clk);
    rst_n = 1'b1;

    clear_mem_req();
    drive_lane_req(
        L0,
        1'b1,
        addr_a,
        128'h00112233_44556677_8899aabb_ccddeeff,
        4'h1
    );
    drive_lane_req(
        L1,
        1'b1,
        addr_b,
        128'h10213243_54657687_98a9bacb_dcedef0f,
        4'h2
    );

    #1;
    if (!mem_req_ready[L0] || !mem_req_ready[L1]) begin
        $fatal(1, "different targets should be accepted in parallel");
    end

    @(posedge clk);
    #1;
    clear_mem_req();

    @(posedge clk);
    #1;
    if (mem_resp_valid[L0] || mem_resp_valid[L1]) begin
        $fatal(1, "write-only cycle should not produce read responses");
    end

    clear_mem_req();
    drive_lane_req(L0, 1'b0, addr_a, 128'h0, 4'h3);
    drive_lane_req(L1, 1'b0, addr_b, 128'h0, 4'h4);

    #1;
    if (!mem_req_ready[L0] || !mem_req_ready[L1]) begin
        $fatal(1, "different routed targets should remain independently ready");
    end

    @(posedge clk);
    #1;
    clear_mem_req();

    @(posedge clk);
    #1;
    if (!mem_resp_valid[L0] || !mem_resp_valid[L1]) begin
        $fatal(1, "routed reads did not return on their original lanes");
    end

    if (mem_resp_id[(L0*`REQ_ID_W) +: `REQ_ID_W] != 4'h3 ||
        mem_resp_id[(L1*`REQ_ID_W) +: `REQ_ID_W] != 4'h4) begin
        $fatal(1, "response ids did not return on the correct lanes");
    end

    if (!mem_resp_last[L0] || !mem_resp_last[L1]) begin
        $fatal(1, "subsystem responses should be single-beat in Stage C");
    end

    if (mem_resp_rdata[(L0*`SRAM_RDATA_W) +: `SRAM_RDATA_W] !=
            128'h00112233_44556677_8899aabb_ccddeeff ||
        mem_resp_rdata[(L1*`SRAM_RDATA_W) +: `SRAM_RDATA_W] !=
            128'h10213243_54657687_98a9bacb_dcedef0f) begin
        $fatal(1, "subsystem routing changed read data");
    end

    clear_mem_req();
    drive_lane_req(
        L0,
        1'b1,
        addr_conflict,
        128'habcdef01_23456789_13579bdf_2468ace0,
        4'h5
    );
    drive_lane_req(
        L1,
        1'b1,
        addr_conflict,
        128'h0badc0de_feedface_c001d00d_deadbeef,
        4'h6
    );

    #1;
    if (!mem_req_ready[L0]) begin
        $fatal(1, "lower-priority lane should win same-target conflict");
    end

    if (mem_req_ready[L1]) begin
        $fatal(1, "same-target conflict should backpressure the later lane");
    end

    @(posedge clk);
    #1;
    clear_mem_req();

    @(posedge clk);
    #1;
    clear_mem_req();
    drive_lane_req(L0, 1'b0, addr_conflict, 128'h0, 4'h7);

    @(posedge clk);
    #1;
    clear_mem_req();

    @(posedge clk);
    #1;
    if (!mem_resp_valid[L0]) begin
        $fatal(1, "conflict-winner readback did not return");
    end

    if (mem_resp_rdata[(L0*`SRAM_RDATA_W) +: `SRAM_RDATA_W] !=
            128'habcdef01_23456789_13579bdf_2468ace0) begin
        $fatal(1, "same-target conflict winner did not preserve written data");
    end

    $display("tb_sram_subsystem_stage_c_route PASS");
    $finish;
end

endmodule
