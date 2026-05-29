`timescale 1ns/1ps

`include "config/interface_params.vh"
`include "config/memory_params.vh"

module tb_request_controller_multilane_issue ();

localparam [`SRAM_RDATA_W-1:0] DATA0 =
    128'h11112222_33334444_55556666_77778888;
localparam [`SRAM_RDATA_W-1:0] DATA1 =
    128'h9999aaaa_bbbbcccc_ddddeeee_ffff0001;
localparam [`REQ_ID_W-1:0] WRITE0_REQ_ID = 4'h1;
localparam [`REQ_ID_W-1:0] WRITE1_REQ_ID = 4'h2;
localparam [`REQ_ID_W-1:0] READ0_REQ_ID = 4'h3;
localparam [`REQ_ID_W-1:0] READ1_REQ_ID = 4'h4;
localparam [`PE_MASK_W-1:0] READ0_PE_MASK = 16'h0001;
localparam [`PE_MASK_W-1:0] READ1_PE_MASK = 16'h0002;

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

reg [`SRAM_ADDR_W-1:0] addr0;
reg [`SRAM_ADDR_W-1:0] addr1;
integer issue_wait_i;
integer resp_wait_i;
reg saw_parallel_issue;
reg saw_parallel_resp;

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

always @(posedge clk) begin
    #1;
    if (rst_n && mem_req_valid[1:0] == 2'b11 && mem_req_ready[1:0] == 2'b11) begin
        saw_parallel_issue = 1'b1;
        if (mem_req_write[1:0] != 2'b00) begin
            $fatal(1, "parallel issue should be read-read");
        end
        if (mem_req_addr[0 +: `SRAM_ADDR_W] != addr0 ||
            mem_req_addr[`SRAM_ADDR_W +: `SRAM_ADDR_W] != addr1 ||
            mem_req_id[0 +: `REQ_ID_W] != READ0_REQ_ID ||
            mem_req_id[`REQ_ID_W +: `REQ_ID_W] != READ1_REQ_ID) begin
            $fatal(1, "parallel issue lane address or id mismatch");
        end
    end
end

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

task drive_accepted_request;
    input do_write;
    input [`SRAM_ADDR_W-1:0] addr_i;
    input [`SRAM_WDATA_W-1:0] wdata_i;
    input [`REQ_ID_W-1:0] req_id_i;
    input [`PE_MASK_W-1:0] pe_mask_i;
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
        req_in_bank_id = addr_i[`OFFSET_W + `ROW_ADDR_W + `SUBBANK_ID_W +: `BANK_ID_W];
        req_in_subbank_id = addr_i[`OFFSET_W + `ROW_ADDR_W +: `SUBBANK_ID_W];
        #1;
        if (!req_in_ready) begin
            $fatal(1, "request_controller did not accept expected request");
        end
        @(posedge clk);
        #1;
        clear_req();
    end
endtask

task drive_second_parallel_read;
    input [`SRAM_ADDR_W-1:0] addr_i;
    input [`REQ_ID_W-1:0] req_id_i;
    input [`PE_MASK_W-1:0] pe_mask_i;
    begin
        @(posedge clk);
        #1;
        req_in_valid = 1'b1;
        req_in_write = 1'b0;
        req_in_addr = addr_i;
        req_in_wdata = {`SRAM_WDATA_W{1'b0}};
        req_in_req_id = req_id_i;
        req_in_pe_mask = pe_mask_i;
        req_in_priority = {`REQ_PRIORITY_W{1'b0}};
        req_in_bank_id = addr_i[`OFFSET_W + `ROW_ADDR_W + `SUBBANK_ID_W +: `BANK_ID_W];
        req_in_subbank_id = addr_i[`OFFSET_W + `ROW_ADDR_W +: `SUBBANK_ID_W];
        #1;
        if (!req_in_ready) begin
            $fatal(1, "independent second read should be buffered for multi-lane issue");
        end
        @(posedge clk);
        #1;
        clear_req();
    end
endtask

initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    clear_req();
    resp_out_ready = {`MEM_REQ_LANES{1'b0}};
    saw_parallel_issue = 1'b0;
    saw_parallel_resp = 1'b0;
    addr0 = pack_addr(2'h0, 4'h0, 5'h04, 8'h21, 4'h0);
    addr1 = pack_addr(2'h0, 4'h1, 5'h05, 8'h22, 4'h0);

    repeat (3) @(posedge clk);
    rst_n = 1'b1;

    drive_accepted_request(1'b1, addr0, DATA0, WRITE0_REQ_ID, 16'h0000);
    drive_accepted_request(1'b1, addr1, DATA1, WRITE1_REQ_ID, 16'h0000);

    drive_accepted_request(1'b0, addr0, {`SRAM_WDATA_W{1'b0}},
                           READ0_REQ_ID, READ0_PE_MASK);
    drive_second_parallel_read(addr1, READ1_REQ_ID, READ1_PE_MASK);

    for (issue_wait_i = 0; issue_wait_i < 8; issue_wait_i = issue_wait_i + 1) begin
        @(posedge clk);
        #1;
    end
    if (!saw_parallel_issue) begin
        $fatal(1, "request_controller did not issue two independent reads on lane0/lane1 together");
    end

    for (resp_wait_i = 0; resp_wait_i < 12; resp_wait_i = resp_wait_i + 1) begin
        @(posedge clk);
        #1;
        if (resp_out_valid[1:0] == 2'b11) begin
            saw_parallel_resp = 1'b1;
            if (resp_out_rdata[0 +: `SRAM_RDATA_W] != DATA0 ||
                resp_out_rdata[`SRAM_RDATA_W +: `SRAM_RDATA_W] != DATA1 ||
                resp_out_req_id[0 +: `REQ_ID_W] != READ0_REQ_ID ||
                resp_out_req_id[`REQ_ID_W +: `REQ_ID_W] != READ1_REQ_ID ||
                resp_out_pe_mask[0 +: `PE_MASK_W] != READ0_PE_MASK ||
                resp_out_pe_mask[`PE_MASK_W +: `PE_MASK_W] != READ1_PE_MASK ||
                resp_out_last[1:0] != 2'b11) begin
                $fatal(1, "parallel response lane data or metadata mismatch");
            end
            resp_out_ready[1:0] = 2'b11;
            @(posedge clk);
            #1;
            resp_out_ready = {`MEM_REQ_LANES{1'b0}};
        end
    end
    if (!saw_parallel_resp) begin
        $fatal(1, "request_controller did not return two PE response lanes together");
    end

    @(posedge clk);
    #1;
    if (|resp_out_valid) begin
        $fatal(1, "parallel responses should clear after ready handshake");
    end
    if (!req_in_ready) begin
        $fatal(1, "request_controller should return to ready after parallel responses retire");
    end

    $display("tb_request_controller_multilane_issue PASS");
    $finish;
end

endmodule
