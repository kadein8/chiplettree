`timescale 1ns/1ps

`include "config/interface_params.vh"
`include "config/memory_params.vh"

module tb_request_controller_multi_merge ();

localparam [`SRAM_RDATA_W-1:0] TEST_DATA =
    128'hd1d0d1d0_11112222_33334444_55556666;

localparam [`REQ_ID_W-1:0] WRITE_REQ_ID = 4'h1;
localparam [`REQ_ID_W-1:0] READ0_REQ_ID = 4'h2;
localparam [`REQ_ID_W-1:0] READ1_REQ_ID = 4'h3;
localparam [`REQ_ID_W-1:0] READ2_REQ_ID = 4'h4;
localparam [`REQ_ID_W-1:0] READ3_REQ_ID = 4'h5;

localparam [`PE_MASK_W-1:0] READ0_PE_MASK = 16'h0001;
localparam [`PE_MASK_W-1:0] READ1_PE_MASK = 16'h0002;
localparam [`PE_MASK_W-1:0] READ2_PE_MASK = 16'h0004;
localparam [`PE_MASK_W-1:0] READ3_PE_MASK = 16'h0008;

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
integer read_issue_count;
integer resp_wait_i;
reg saw_merged_responses;

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
    if (rst_n && mem_req_valid[0] && mem_req_ready[0] && !mem_req_write[0]) begin
        read_issue_count = read_issue_count + 1;
    end
    if (rst_n && |mem_req_valid[`MEM_REQ_LANES-1:1]) begin
        $fatal(1, "same-address multi-merge should not issue extra SRAM read lanes");
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

task drive_merge_candidate;
    input [`SRAM_ADDR_W-1:0] addr_i;
    input [`REQ_ID_W-1:0] req_id_i;
    input [`PE_MASK_W-1:0] pe_mask_i;
    begin
        drive_accepted_request(1'b0, addr_i, {`SRAM_WDATA_W{1'b0}},
                               req_id_i, pe_mask_i);
    end
endtask

initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    clear_req();
    resp_out_ready = {`MEM_REQ_LANES{1'b0}};
    read_issue_count = 0;
    saw_merged_responses = 1'b0;
    test_addr = pack_addr(2'h0, 4'h0, 5'h09, 8'h51, 4'h0);

    repeat (3) @(posedge clk);
    rst_n = 1'b1;

    drive_accepted_request(1'b1, test_addr, TEST_DATA, WRITE_REQ_ID, 16'h0000);

    drive_accepted_request(1'b0, test_addr, {`SRAM_WDATA_W{1'b0}},
                           READ0_REQ_ID, READ0_PE_MASK);
    drive_merge_candidate(test_addr, READ1_REQ_ID, READ1_PE_MASK);
    drive_merge_candidate(test_addr, READ2_REQ_ID, READ2_PE_MASK);
    drive_merge_candidate(test_addr, READ3_REQ_ID, READ3_PE_MASK);

    for (resp_wait_i = 0; resp_wait_i < 16; resp_wait_i = resp_wait_i + 1) begin
        @(posedge clk);
        #1;
        if (resp_out_valid == 4'b1111) begin
            saw_merged_responses = 1'b1;
            if (resp_out_rdata[(0*`SRAM_RDATA_W) +: `SRAM_RDATA_W] != TEST_DATA ||
                resp_out_rdata[(1*`SRAM_RDATA_W) +: `SRAM_RDATA_W] != TEST_DATA ||
                resp_out_rdata[(2*`SRAM_RDATA_W) +: `SRAM_RDATA_W] != TEST_DATA ||
                resp_out_rdata[(3*`SRAM_RDATA_W) +: `SRAM_RDATA_W] != TEST_DATA ||
                resp_out_req_id[(0*`REQ_ID_W) +: `REQ_ID_W] != READ0_REQ_ID ||
                resp_out_req_id[(1*`REQ_ID_W) +: `REQ_ID_W] != READ1_REQ_ID ||
                resp_out_req_id[(2*`REQ_ID_W) +: `REQ_ID_W] != READ2_REQ_ID ||
                resp_out_req_id[(3*`REQ_ID_W) +: `REQ_ID_W] != READ3_REQ_ID ||
                resp_out_pe_mask[(0*`PE_MASK_W) +: `PE_MASK_W] != READ0_PE_MASK ||
                resp_out_pe_mask[(1*`PE_MASK_W) +: `PE_MASK_W] != READ1_PE_MASK ||
                resp_out_pe_mask[(2*`PE_MASK_W) +: `PE_MASK_W] != READ2_PE_MASK ||
                resp_out_pe_mask[(3*`PE_MASK_W) +: `PE_MASK_W] != READ3_PE_MASK ||
                resp_out_last != 4'b1111) begin
                $fatal(1, "multi-merged response data or metadata mismatch");
            end
            resp_out_ready = 4'b1111;
            @(posedge clk);
            #1;
            resp_out_ready = {`MEM_REQ_LANES{1'b0}};
        end
    end

    if (!saw_merged_responses) begin
        $fatal(1, "expected four logical same-address responses together");
    end

    if (read_issue_count != 1) begin
        $fatal(1, "same-address multi-merge should issue exactly one SRAM read, saw %0d",
               read_issue_count);
    end

    @(posedge clk);
    #1;
    if (!req_in_ready) begin
        $fatal(1, "request_controller should return to ready after multi-merged responses retire");
    end

    $display("tb_request_controller_multi_merge PASS");
    $finish;
end

endmodule
