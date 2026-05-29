`timescale 1ns/1ps

`include "config/interface_params.vh"
`include "config/memory_params.vh"

module tb_request_controller_bootstrap ();

localparam integer TEST_LANE = 0;
localparam [`SRAM_RDATA_W-1:0] TEST_DATA =
    128'hdeadbeef_01234567_89abcdef_76543210;
localparam [`PE_MASK_W-1:0] TEST_PE_MASK = 16'h00f0;
localparam [`REQ_ID_W-1:0] WRITE_REQ_ID = 4'h2;
localparam [`REQ_ID_W-1:0] READ_REQ_ID = 4'h3;
localparam [`REQ_ID_W-1:0] BLOCKED_REQ_ID = 4'h4;

reg clk;
reg rst_n;

reg req_in_valid;
wire req_in_ready;
reg req_in_write;
reg [`SRAM_ADDR_W-1:0] req_in_addr;
reg [`SRAM_WDATA_W-1:0] req_in_wdata;
reg [`REQ_ID_W-1:0] req_in_req_id;
reg [`PE_MASK_W-1:0] req_in_pe_mask;
reg [`REQ_PRIORITY_W-1:0] req_in_priority;
reg [`BANK_ID_W-1:0] req_in_bank_id;
reg [`SUBBANK_ID_W-1:0] req_in_subbank_id;

wire [`MEM_REQ_LANES-1:0] mem_req_valid;
wire [`MEM_REQ_LANES-1:0] mem_req_ready;
wire [`MEM_REQ_LANES-1:0] mem_req_write;
wire [`MEM_REQ_LANES*`SRAM_ADDR_W-1:0] mem_req_addr;
wire [`MEM_REQ_LANES*`SRAM_WDATA_W-1:0] mem_req_wdata;
wire [`MEM_REQ_LANES*`REQ_ID_W-1:0] mem_req_id;
wire [`MEM_REQ_LANES-1:0] mem_resp_valid;
wire [`MEM_REQ_LANES*`SRAM_RDATA_W-1:0] mem_resp_rdata;
wire [`MEM_REQ_LANES*`REQ_ID_W-1:0] mem_resp_id;
wire [`MEM_REQ_LANES-1:0] mem_resp_last;

wire [`MEM_REQ_LANES-1:0] resp_out_valid;
reg [`MEM_REQ_LANES-1:0] resp_out_ready;
wire [`MEM_REQ_LANES*`SRAM_RDATA_W-1:0] resp_out_rdata;
wire [`MEM_REQ_LANES*`REQ_ID_W-1:0] resp_out_req_id;
wire [`MEM_REQ_LANES*`PE_MASK_W-1:0] resp_out_pe_mask;
wire [`MEM_REQ_LANES-1:0] resp_out_last;

reg [`SRAM_ADDR_W-1:0] test_addr;
reg [`SRAM_ADDR_W-1:0] blocked_addr;

request_controller u_request_controller (
    .clk(clk),
    .rst_n(rst_n),
    .req_in_valid(req_in_valid),
    .req_in_ready(req_in_ready),
    .req_in_write(req_in_write),
    .req_in_addr(req_in_addr),
    .req_in_wdata(req_in_wdata),
    .req_in_req_id(req_in_req_id),
    .req_in_pe_mask(req_in_pe_mask),
    .req_in_priority(req_in_priority),
    .req_in_bank_id(req_in_bank_id),
    .req_in_subbank_id(req_in_subbank_id),
    .vec_req_valid({`MEM_REQ_LANES{1'b0}}),
    .vec_req_ready(),
    .vec_req_write({`MEM_REQ_LANES{1'b0}}),
    .vec_req_addr({(`MEM_REQ_LANES*`SRAM_ADDR_W){1'b0}}),
    .vec_req_wdata({(`MEM_REQ_LANES*`SRAM_WDATA_W){1'b0}}),
    .vec_req_req_id({(`MEM_REQ_LANES*`REQ_ID_W){1'b0}}),
    .vec_req_pe_mask({(`MEM_REQ_LANES*`PE_MASK_W){1'b0}}),
    .vec_req_priority({(`MEM_REQ_LANES*`REQ_PRIORITY_W){1'b0}}),
    .vec_req_bank_id({(`MEM_REQ_LANES*`BANK_ID_W){1'b0}}),
    .vec_req_subbank_id({(`MEM_REQ_LANES*`SUBBANK_ID_W){1'b0}}),
    .mem_req_valid(mem_req_valid),
    .mem_req_ready(mem_req_ready),
    .mem_req_write(mem_req_write),
    .mem_req_addr(mem_req_addr),
    .mem_req_wdata(mem_req_wdata),
    .mem_req_id(mem_req_id),
    .mem_resp_valid(mem_resp_valid),
    .mem_resp_rdata(mem_resp_rdata),
    .mem_resp_id(mem_resp_id),
    .mem_resp_last(mem_resp_last),
    .resp_out_valid(resp_out_valid),
    .resp_out_ready(resp_out_ready),
    .resp_out_rdata(resp_out_rdata),
    .resp_out_req_id(resp_out_req_id),
    .resp_out_pe_mask(resp_out_pe_mask),
    .resp_out_last(resp_out_last)
);

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
        pack_addr = {sram_i, bank_i, subbank_i, row_i, offset_i};
    end
endfunction

task clear_req;
    begin
        req_in_valid = 1'b0;
        req_in_write = 1'b0;
        req_in_addr = {`SRAM_ADDR_W{1'b0}};
        req_in_wdata = {`SRAM_WDATA_W{1'b0}};
        req_in_req_id = {`REQ_ID_W{1'b0}};
        req_in_pe_mask = {`PE_MASK_W{1'b0}};
        req_in_priority = {`REQ_PRIORITY_W{1'b0}};
        req_in_bank_id = {`BANK_ID_W{1'b0}};
        req_in_subbank_id = {`SUBBANK_ID_W{1'b0}};
    end
endtask

task drive_request;
    input do_write;
    input [`SRAM_ADDR_W-1:0] addr_i;
    input [`SRAM_WDATA_W-1:0] wdata_i;
    input [`REQ_ID_W-1:0] req_id_i;
    input [`PE_MASK_W-1:0] pe_mask_i;
    input [`BANK_ID_W-1:0] bank_i;
    input [`SUBBANK_ID_W-1:0] subbank_i;
    begin
        @(posedge clk);
        #1;
        req_in_valid = 1'b1;
        req_in_write = do_write;
        req_in_addr = addr_i;
        req_in_wdata = wdata_i;
        req_in_req_id = req_id_i;
        req_in_pe_mask = pe_mask_i;
        req_in_priority = {`REQ_PRIORITY_W{1'b0}};
        req_in_bank_id = bank_i;
        req_in_subbank_id = subbank_i;
        #1;
        if (!req_in_ready) begin
            $fatal(1, "request_controller should accept a request while idle");
        end
        @(posedge clk);
        #1;
        clear_req();
    end
endtask

task wait_ready;
    integer wait_i;
    reg seen;
    begin
        seen = 1'b0;
        for (wait_i = 0; wait_i < 8; wait_i = wait_i + 1) begin
            @(posedge clk);
            #1;
            if (req_in_ready) begin
                seen = 1'b1;
                disable wait_ready;
            end
        end
        if (!seen) begin
            $fatal(1, "request_controller did not return to ready");
        end
    end
endtask

task wait_response_valid;
    integer wait_i;
    reg seen;
    begin
        seen = 1'b0;
        for (wait_i = 0; wait_i < 12; wait_i = wait_i + 1) begin
            @(posedge clk);
            #1;
            if (resp_out_valid[0]) begin
                seen = 1'b1;
                disable wait_response_valid;
            end
        end
        if (!seen) begin
            $fatal(1, "request_controller did not return a read response");
        end
    end
endtask

initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    clear_req();
    resp_out_ready = {`MEM_REQ_LANES{1'b0}};
    test_addr = pack_addr(2'h0, 4'h0, 4'h1, 8'h05, 4'h0);
    blocked_addr = pack_addr(2'h0, 4'h0, 4'h1, 8'h06, 4'h0);

    repeat (3) @(posedge clk);
    rst_n = 1'b1;

    @(posedge clk);
    #1;
    if (!req_in_ready) begin
        $fatal(1, "request_controller should be ready after reset");
    end

    drive_request(1'b1, test_addr, TEST_DATA, WRITE_REQ_ID, 16'h0001, 4'h0, 4'h1);
    wait_ready();
    if (resp_out_valid[0]) begin
        $fatal(1, "write passthrough should not fabricate a read response");
    end

    drive_request(1'b0, test_addr, {`SRAM_WDATA_W{1'b0}}, READ_REQ_ID,
                  TEST_PE_MASK, 4'h0, 4'h1);

    @(posedge clk);
    #1;
    req_in_valid = 1'b1;
    req_in_write = 1'b0;
    req_in_addr = blocked_addr;
    req_in_wdata = {`SRAM_WDATA_W{1'b0}};
    req_in_req_id = BLOCKED_REQ_ID;
    req_in_pe_mask = 16'h0002;
    req_in_bank_id = 4'h0;
    req_in_subbank_id = 4'h1;
    #1;
    if (req_in_ready) begin
        $fatal(1, "busy read should not accept a second upstream request");
    end
    clear_req();

    wait_response_valid();
    if (resp_out_rdata[0 +: `SRAM_RDATA_W] != TEST_DATA ||
        resp_out_req_id[0 +: `REQ_ID_W] != READ_REQ_ID ||
        resp_out_pe_mask[0 +: `PE_MASK_W] != TEST_PE_MASK ||
        !resp_out_last[0]) begin
        $fatal(1, "request_controller response metadata or data mismatch");
    end

    @(posedge clk);
    #1;
    if (!resp_out_valid[0]) begin
        $fatal(1, "response should hold while resp_out_ready is low");
    end

    resp_out_ready[0] = 1'b1;
    @(posedge clk);
    #1;
    resp_out_ready = {`MEM_REQ_LANES{1'b0}};
    if (resp_out_valid[0]) begin
        $fatal(1, "response should clear after resp_out_ready handshake");
    end
    if (!req_in_ready) begin
        $fatal(1, "request_controller should accept again after response retires");
    end

    if (|mem_req_valid[`MEM_REQ_LANES-1:1]) begin
        $fatal(1, "Stage D0 bootstrap should keep nonzero lanes quiescent");
    end

    $display("tb_request_controller_bootstrap PASS");
    $finish;
end

endmodule
