`timescale 1ns/1ps

`include "config/interface_params.vh"
`include "config/memory_params.vh"

module tb_request_controller_mixed_read_write ();

localparam [`SRAM_RDATA_W-1:0] OLD_DATA =
    128'ha1000000_11111111_22222222_33333333;
localparam [`SRAM_RDATA_W-1:0] NEW_DATA =
    128'ha2000000_44444444_55555555_66666666;
localparam [`SRAM_RDATA_W-1:0] READ_DATA =
    128'ha3000000_77777777_88888888_99999999;
localparam [`SRAM_RDATA_W-1:0] WRITE_DATA =
    128'ha4000000_aaaaaaaa_bbbbbbbb_cccccccc;

localparam [`REQ_ID_W-1:0] INIT0_REQ_ID = 4'h1;
localparam [`REQ_ID_W-1:0] INIT1_REQ_ID = 4'h2;
localparam [`REQ_ID_W-1:0] BYPASS_READ_REQ_ID = 4'h3;
localparam [`REQ_ID_W-1:0] BYPASS_WRITE_REQ_ID = 4'h4;
localparam [`REQ_ID_W-1:0] MIXED_READ_REQ_ID = 4'h5;
localparam [`REQ_ID_W-1:0] MIXED_WRITE_REQ_ID = 4'h6;
localparam [`REQ_ID_W-1:0] CONFLICT_READ_REQ_ID = 4'h7;
localparam [`REQ_ID_W-1:0] CONFLICT_WRITE_REQ_ID = 4'h8;

localparam [`PE_MASK_W-1:0] BYPASS_READ_PE_MASK = 16'h0100;
localparam [`PE_MASK_W-1:0] MIXED_READ_PE_MASK = 16'h0200;
localparam [`PE_MASK_W-1:0] CONFLICT_READ_PE_MASK = 16'h0400;

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

reg [`SRAM_ADDR_W-1:0] bypass_addr;
reg [`SRAM_ADDR_W-1:0] mixed_read_addr;
reg [`SRAM_ADDR_W-1:0] mixed_write_addr;
reg [`SRAM_ADDR_W-1:0] conflict_read_addr;
reg [`SRAM_ADDR_W-1:0] conflict_write_addr;

integer bypass_read_issue_count;
integer bypass_write_issue_count;
integer mon_i;
reg saw_mixed_issue;
reg saw_conflict_backpressure;

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
    for (mon_i = 0; mon_i < `MEM_REQ_LANES; mon_i = mon_i + 1) begin
        if (rst_n && mem_req_valid[mon_i] && mem_req_ready[mon_i] &&
            mem_req_addr[(mon_i*`SRAM_ADDR_W) +: `SRAM_ADDR_W] == bypass_addr) begin
            if (mem_req_write[mon_i]) begin
                bypass_write_issue_count = bypass_write_issue_count + 1;
            end else begin
                bypass_read_issue_count = bypass_read_issue_count + 1;
            end
        end
    end

    if (rst_n && mem_req_valid[1:0] == 2'b11 && mem_req_ready[1:0] == 2'b11) begin
        if (mem_req_addr[0 +: `SRAM_ADDR_W] == mixed_read_addr &&
            mem_req_addr[`SRAM_ADDR_W +: `SRAM_ADDR_W] == mixed_write_addr &&
            mem_req_write[1:0] == 2'b10 &&
            mem_req_wdata[`SRAM_WDATA_W +: `SRAM_WDATA_W] == WRITE_DATA) begin
            saw_mixed_issue = 1'b1;
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

task drive_probe_expect_ready;
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
            $fatal(1, "mixed read/write candidate should be accepted");
        end
        @(posedge clk);
        #1;
        clear_req();
    end
endtask

task drive_probe_expect_backpressure;
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
        if (req_in_ready) begin
            $fatal(1, "same-SRAM same-subbank different-address read/write should be backpressured");
        end
        saw_conflict_backpressure = 1'b1;
        @(posedge clk);
        #1;
        clear_req();
    end
endtask

task wait_single_response;
    input [`SRAM_RDATA_W-1:0] expected_data;
    input [`REQ_ID_W-1:0] expected_req_id;
    input [`PE_MASK_W-1:0] expected_pe_mask;
    integer wait_i;
    reg seen;
    begin
        seen = 1'b0;
        for (wait_i = 0; wait_i < 18; wait_i = wait_i + 1) begin
            @(posedge clk);
            #1;
            if (resp_out_valid[0]) begin
                seen = 1'b1;
                if (resp_out_rdata[0 +: `SRAM_RDATA_W] != expected_data ||
                    resp_out_req_id[0 +: `REQ_ID_W] != expected_req_id ||
                    resp_out_pe_mask[0 +: `PE_MASK_W] != expected_pe_mask ||
                    !resp_out_last[0]) begin
                    $fatal(1, "single response data or metadata mismatch");
                end
                resp_out_ready[0] = 1'b1;
                @(posedge clk);
                #1;
                resp_out_ready = {`MEM_REQ_LANES{1'b0}};
                disable wait_single_response;
            end
        end
        if (!seen) begin
            $fatal(1, "expected response did not arrive");
        end
    end
endtask

initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    clear_req();
    resp_out_ready = {`MEM_REQ_LANES{1'b0}};
    bypass_read_issue_count = 0;
    bypass_write_issue_count = 0;
    saw_mixed_issue = 1'b0;
    saw_conflict_backpressure = 1'b0;

    bypass_addr = pack_addr(2'h0, 4'h0, 5'h03, 8'h11, 4'h0);
    mixed_read_addr = pack_addr(2'h0, 4'h1, 5'h04, 8'h12, 4'h0);
    mixed_write_addr = pack_addr(2'h0, 4'h2, 5'h05, 8'h13, 4'h0);
    conflict_read_addr = pack_addr(2'h0, 4'h3, 5'h06, 8'h21, 4'h0);
    conflict_write_addr = pack_addr(2'h0, 4'h3, 5'h06, 8'h22, 4'h0);

    repeat (3) @(posedge clk);
    rst_n = 1'b1;

    drive_accepted_request(1'b1, bypass_addr, OLD_DATA, INIT0_REQ_ID, 16'h0000);
    drive_accepted_request(1'b1, mixed_read_addr, READ_DATA, INIT1_REQ_ID, 16'h0000);
    bypass_read_issue_count = 0;
    bypass_write_issue_count = 0;

    drive_accepted_request(1'b0, bypass_addr, {`SRAM_WDATA_W{1'b0}},
                           BYPASS_READ_REQ_ID, BYPASS_READ_PE_MASK);
    drive_probe_expect_ready(1'b1, bypass_addr, NEW_DATA,
                             BYPASS_WRITE_REQ_ID, 16'h0000);
    wait_single_response(NEW_DATA, BYPASS_READ_REQ_ID, BYPASS_READ_PE_MASK);

    if (bypass_read_issue_count != 0) begin
        $fatal(1, "same-address read/write bypass should not issue a physical SRAM read");
    end
    if (bypass_write_issue_count != 1) begin
        $fatal(1, "same-address read/write bypass should issue exactly one physical write");
    end

    drive_accepted_request(1'b0, mixed_read_addr, {`SRAM_WDATA_W{1'b0}},
                           MIXED_READ_REQ_ID, MIXED_READ_PE_MASK);
    drive_probe_expect_ready(1'b1, mixed_write_addr, WRITE_DATA,
                             MIXED_WRITE_REQ_ID, 16'h0000);
    wait_single_response(READ_DATA, MIXED_READ_REQ_ID, MIXED_READ_PE_MASK);

    if (!saw_mixed_issue) begin
        $fatal(1, "independent read/write should issue together on separate lanes");
    end

    drive_accepted_request(1'b0, conflict_read_addr, {`SRAM_WDATA_W{1'b0}},
                           CONFLICT_READ_REQ_ID, CONFLICT_READ_PE_MASK);
    drive_probe_expect_backpressure(1'b1, conflict_write_addr, WRITE_DATA,
                                    CONFLICT_WRITE_REQ_ID, 16'h0000);
    wait_single_response({`SRAM_RDATA_W{1'b0}}, CONFLICT_READ_REQ_ID,
                         CONFLICT_READ_PE_MASK);

    if (!saw_conflict_backpressure) begin
        $fatal(1, "read/write conflict backpressure was not observed");
    end

    @(posedge clk);
    #1;
    if (!req_in_ready) begin
        $fatal(1, "request_controller should return to ready after mixed read/write cases");
    end

    $display("tb_request_controller_mixed_read_write PASS");
    $finish;
end

endmodule
