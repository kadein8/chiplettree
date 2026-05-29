`timescale 1ns/1ps

`include "config/interface_params.vh"
`include "config/memory_params.vh"

module tb_request_controller_wide_concurrency ();

localparam [`SRAM_RDATA_W-1:0] DATA0 =
    128'h61000000_11111111_22222222_33333333;
localparam [`SRAM_RDATA_W-1:0] DATA1 =
    128'h62000000_44444444_55555555_66666666;
localparam [`SRAM_RDATA_W-1:0] DATA2 =
    128'h63000000_77777777_88888888_99999999;
localparam [`SRAM_RDATA_W-1:0] DATA3 =
    128'h64000000_aaaaaaaa_bbbbbbbb_cccccccc;
localparam [`SRAM_RDATA_W-1:0] UPDATED0 =
    128'h65000000_dddddddd_eeeeeeee_ffffffff;
localparam [`SRAM_RDATA_W-1:0] UPDATED3 =
    128'h66000000_12345678_90abcdef_0fedcba9;

localparam [`REQ_ID_W-1:0] INIT0_REQ_ID = 4'h1;
localparam [`REQ_ID_W-1:0] INIT1_REQ_ID = 4'h2;
localparam [`REQ_ID_W-1:0] INIT2_REQ_ID = 4'h3;
localparam [`REQ_ID_W-1:0] INIT3_REQ_ID = 4'h4;

localparam [`REQ_ID_W-1:0] W1_READ0_REQ_ID = 4'h5;
localparam [`REQ_ID_W-1:0] W1_READ1_REQ_ID = 4'h6;
localparam [`REQ_ID_W-1:0] W1_READ2_REQ_ID = 4'h7;
localparam [`REQ_ID_W-1:0] W1_READ3_REQ_ID = 4'h8;
localparam [`REQ_ID_W-1:0] W1_BLOCKED_REQ_ID = 4'h9;

localparam [`REQ_ID_W-1:0] W2_BYPASS_READ_REQ_ID = 4'ha;
localparam [`REQ_ID_W-1:0] W2_SIDE_READ_REQ_ID = 4'hb;
localparam [`REQ_ID_W-1:0] W2_BYPASS_WRITE_REQ_ID = 4'hc;

localparam [`REQ_ID_W-1:0] W3_READ_REQ_ID = 4'hd;
localparam [`REQ_ID_W-1:0] W3_WRITE_REQ_ID = 4'he;
localparam [`REQ_ID_W-1:0] W4_READBACK0_REQ_ID = 4'hf;
localparam [`REQ_ID_W-1:0] W4_READBACK3_REQ_ID = 4'h0;

localparam [`PE_MASK_W-1:0] W1_READ0_PE_MASK = 16'h0001;
localparam [`PE_MASK_W-1:0] W1_READ1_PE_MASK = 16'h0002;
localparam [`PE_MASK_W-1:0] W1_READ2_PE_MASK = 16'h0004;
localparam [`PE_MASK_W-1:0] W1_READ3_PE_MASK = 16'h0008;
localparam [`PE_MASK_W-1:0] W2_BYPASS_READ_PE_MASK = 16'h0010;
localparam [`PE_MASK_W-1:0] W2_SIDE_READ_PE_MASK = 16'h0020;
localparam [`PE_MASK_W-1:0] W3_READ_PE_MASK = 16'h0040;
localparam [`PE_MASK_W-1:0] W4_READBACK0_PE_MASK = 16'h0080;
localparam [`PE_MASK_W-1:0] W4_READBACK3_PE_MASK = 16'h0100;

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
reg [`SRAM_ADDR_W-1:0] addr2;
reg [`SRAM_ADDR_W-1:0] addr3;
reg [`SRAM_ADDR_W-1:0] blocked_addr;

integer mon_i;
integer wait_i;
reg saw_wave1_four_lane_issue;
reg saw_wave2_probe_backpressure;
reg saw_wave3_mixed_issue;
reg measure_wave2_issues;
integer wave2_issue_total_count;
integer wave2_addr0_read_issue_count;
integer wave2_addr0_write_issue_count;
integer wave2_addr1_read_issue_count;

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

    if (rst_n &&
        mem_req_valid == 4'b1111 &&
        mem_req_ready == 4'b1111 &&
        mem_req_write == 4'b0000 &&
        mem_req_addr[(0*`SRAM_ADDR_W) +: `SRAM_ADDR_W] == addr1 &&
        mem_req_addr[(1*`SRAM_ADDR_W) +: `SRAM_ADDR_W] == addr3 &&
        mem_req_addr[(2*`SRAM_ADDR_W) +: `SRAM_ADDR_W] == addr2 &&
        mem_req_addr[(3*`SRAM_ADDR_W) +: `SRAM_ADDR_W] == addr0 &&
        mem_req_id[(0*`REQ_ID_W) +: `REQ_ID_W] == W1_READ1_REQ_ID &&
        mem_req_id[(1*`REQ_ID_W) +: `REQ_ID_W] == W1_READ3_REQ_ID &&
        mem_req_id[(2*`REQ_ID_W) +: `REQ_ID_W] == W1_READ2_REQ_ID &&
        mem_req_id[(3*`REQ_ID_W) +: `REQ_ID_W] == W1_READ0_REQ_ID) begin
        saw_wave1_four_lane_issue = 1'b1;
    end

    if (rst_n && measure_wave2_issues) begin
        for (mon_i = 0; mon_i < `MEM_REQ_LANES; mon_i = mon_i + 1) begin
            if (mem_req_valid[mon_i] && mem_req_ready[mon_i]) begin
                wave2_issue_total_count = wave2_issue_total_count + 1;
                if (mem_req_addr[(mon_i*`SRAM_ADDR_W) +: `SRAM_ADDR_W] == addr0) begin
                    if (mem_req_write[mon_i]) begin
                        wave2_addr0_write_issue_count =
                            wave2_addr0_write_issue_count + 1;
                    end else begin
                        wave2_addr0_read_issue_count =
                            wave2_addr0_read_issue_count + 1;
                    end
                end
                if (!mem_req_write[mon_i] &&
                    mem_req_addr[(mon_i*`SRAM_ADDR_W) +: `SRAM_ADDR_W] == addr1) begin
                    wave2_addr1_read_issue_count =
                        wave2_addr1_read_issue_count + 1;
                end
            end
        end
    end

    if (rst_n &&
        mem_req_valid[1:0] == 2'b11 &&
        mem_req_ready[1:0] == 2'b11 &&
        mem_req_write[1:0] == 2'b10 &&
        mem_req_addr[(0*`SRAM_ADDR_W) +: `SRAM_ADDR_W] == addr2 &&
        mem_req_addr[(1*`SRAM_ADDR_W) +: `SRAM_ADDR_W] == addr3 &&
        mem_req_id[(0*`REQ_ID_W) +: `REQ_ID_W] == W3_READ_REQ_ID &&
        mem_req_id[(1*`REQ_ID_W) +: `REQ_ID_W] == W3_WRITE_REQ_ID) begin
        saw_wave3_mixed_issue = 1'b1;
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
    input [`REQ_PRIORITY_W-1:0] priority_i;
    begin
        @(posedge clk);
        #1;
        req_in_valid = 1'b1;
        req_in_write = do_write;
        req_in_addr = addr_i;
        req_in_wdata = wdata_i;
        req_in_req_id = req_id_i;
        req_in_pe_mask = pe_mask_i;
        req_in_priority = priority_i;
        req_in_bank_id =
            addr_i[`OFFSET_W + `ROW_ADDR_W + `SUBBANK_ID_W +: `BANK_ID_W];
        req_in_subbank_id =
            addr_i[`OFFSET_W + `ROW_ADDR_W +: `SUBBANK_ID_W];
        #1;
        if (!req_in_ready) begin
            $fatal(1, "request_controller did not accept expected request");
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
    input [`REQ_PRIORITY_W-1:0] priority_i;
    begin
        @(posedge clk);
        #1;
        req_in_valid = 1'b1;
        req_in_write = do_write;
        req_in_addr = addr_i;
        req_in_wdata = wdata_i;
        req_in_req_id = req_id_i;
        req_in_pe_mask = pe_mask_i;
        req_in_priority = priority_i;
        req_in_bank_id =
            addr_i[`OFFSET_W + `ROW_ADDR_W + `SUBBANK_ID_W +: `BANK_ID_W];
        req_in_subbank_id =
            addr_i[`OFFSET_W + `ROW_ADDR_W +: `SUBBANK_ID_W];
        #1;
        if (req_in_ready) begin
            $fatal(1, "request_controller should backpressure while busy");
        end
        saw_wave2_probe_backpressure = 1'b1;
        @(posedge clk);
        #1;
        clear_req();
    end
endtask

task expect_response_stable;
    input [`MEM_REQ_LANES-1:0] expected_valid;
    input integer hold_cycles;
    reg [`MEM_REQ_LANES*`SRAM_RDATA_W-1:0] snapshot_rdata;
    reg [`MEM_REQ_LANES*`REQ_ID_W-1:0] snapshot_req_id;
    reg [`MEM_REQ_LANES*`PE_MASK_W-1:0] snapshot_pe_mask;
    reg [`MEM_REQ_LANES-1:0] snapshot_last;
    integer hold_i;
    begin
        snapshot_rdata = resp_out_rdata;
        snapshot_req_id = resp_out_req_id;
        snapshot_pe_mask = resp_out_pe_mask;
        snapshot_last = resp_out_last;
        for (hold_i = 0; hold_i < hold_cycles; hold_i = hold_i + 1) begin
            @(posedge clk);
            #1;
            if (resp_out_valid != expected_valid ||
                resp_out_rdata != snapshot_rdata ||
                resp_out_req_id != snapshot_req_id ||
                resp_out_pe_mask != snapshot_pe_mask ||
                resp_out_last != snapshot_last) begin
                $fatal(1, "response payload changed while PE was not ready");
            end
            if (req_in_ready) begin
                $fatal(1, "request_controller reopened upstream while response held");
            end
        end
    end
endtask

task release_response_mask;
    input [`MEM_REQ_LANES-1:0] ready_mask;
    begin
        resp_out_ready = ready_mask;
        @(posedge clk);
        #1;
        resp_out_ready = {`MEM_REQ_LANES{1'b0}};
        if (|resp_out_valid) begin
            $fatal(1, "response valid should clear after ready handshake");
        end
    end
endtask

task wait_wave1_response_hold_and_release;
    reg seen;
    begin
        seen = 1'b0;
        for (wait_i = 0; wait_i < 18; wait_i = wait_i + 1) begin
            @(posedge clk);
            #1;
            if (resp_out_valid == 4'b1111) begin
                seen = 1'b1;
                if (resp_out_rdata[(0*`SRAM_RDATA_W) +: `SRAM_RDATA_W] != DATA1 ||
                    resp_out_rdata[(1*`SRAM_RDATA_W) +: `SRAM_RDATA_W] != DATA3 ||
                    resp_out_rdata[(2*`SRAM_RDATA_W) +: `SRAM_RDATA_W] != DATA2 ||
                    resp_out_rdata[(3*`SRAM_RDATA_W) +: `SRAM_RDATA_W] != DATA0 ||
                    resp_out_req_id[(0*`REQ_ID_W) +: `REQ_ID_W] != W1_READ1_REQ_ID ||
                    resp_out_req_id[(1*`REQ_ID_W) +: `REQ_ID_W] != W1_READ3_REQ_ID ||
                    resp_out_req_id[(2*`REQ_ID_W) +: `REQ_ID_W] != W1_READ2_REQ_ID ||
                    resp_out_req_id[(3*`REQ_ID_W) +: `REQ_ID_W] != W1_READ0_REQ_ID ||
                    resp_out_pe_mask[(0*`PE_MASK_W) +: `PE_MASK_W] != W1_READ1_PE_MASK ||
                    resp_out_pe_mask[(1*`PE_MASK_W) +: `PE_MASK_W] != W1_READ3_PE_MASK ||
                    resp_out_pe_mask[(2*`PE_MASK_W) +: `PE_MASK_W] != W1_READ2_PE_MASK ||
                    resp_out_pe_mask[(3*`PE_MASK_W) +: `PE_MASK_W] != W1_READ0_PE_MASK ||
                    resp_out_last != 4'b1111) begin
                    $fatal(1, "wave1 response data or metadata mismatch");
                end
                drive_probe_expect_backpressure(
                    1'b0,
                    blocked_addr,
                    {`SRAM_WDATA_W{1'b0}},
                    W1_BLOCKED_REQ_ID,
                    16'h0200,
                    2'd0
                );
                expect_response_stable(4'b1111, 2);
                release_response_mask(4'b1111);
                disable wait_wave1_response_hold_and_release;
            end
        end
        if (!seen) begin
            $fatal(1, "wave1 four-lane response did not arrive");
        end
    end
endtask

task wait_wave2_response_hold_and_release;
    reg seen;
    begin
        seen = 1'b0;
        for (wait_i = 0; wait_i < 18; wait_i = wait_i + 1) begin
            @(posedge clk);
            #1;
            if (resp_out_valid == 4'b0011) begin
                seen = 1'b1;
                if (resp_out_rdata[(0*`SRAM_RDATA_W) +: `SRAM_RDATA_W] != UPDATED0 ||
                    resp_out_rdata[(1*`SRAM_RDATA_W) +: `SRAM_RDATA_W] != DATA1 ||
                    resp_out_req_id[(0*`REQ_ID_W) +: `REQ_ID_W] != W2_BYPASS_READ_REQ_ID ||
                    resp_out_req_id[(1*`REQ_ID_W) +: `REQ_ID_W] != W2_SIDE_READ_REQ_ID ||
                    resp_out_pe_mask[(0*`PE_MASK_W) +: `PE_MASK_W] != W2_BYPASS_READ_PE_MASK ||
                    resp_out_pe_mask[(1*`PE_MASK_W) +: `PE_MASK_W] != W2_SIDE_READ_PE_MASK ||
                    resp_out_last[1:0] != 2'b11) begin
                    $fatal(1, "wave2 response data or metadata mismatch");
                end
                expect_response_stable(4'b0011, 2);
                release_response_mask(4'b0011);
                disable wait_wave2_response_hold_and_release;
            end
        end
        if (!seen) begin
            $fatal(1, "wave2 response did not arrive");
        end
    end
endtask

task wait_wave3_response_hold_and_release;
    reg seen;
    begin
        seen = 1'b0;
        for (wait_i = 0; wait_i < 18; wait_i = wait_i + 1) begin
            @(posedge clk);
            #1;
            if (resp_out_valid == 4'b0001) begin
                seen = 1'b1;
                if (resp_out_rdata[(0*`SRAM_RDATA_W) +: `SRAM_RDATA_W] != DATA2 ||
                    resp_out_req_id[(0*`REQ_ID_W) +: `REQ_ID_W] != W3_READ_REQ_ID ||
                    resp_out_pe_mask[(0*`PE_MASK_W) +: `PE_MASK_W] != W3_READ_PE_MASK ||
                    !resp_out_last[0]) begin
                    $fatal(1, "wave3 response data or metadata mismatch");
                end
                expect_response_stable(4'b0001, 1);
                release_response_mask(4'b0001);
                disable wait_wave3_response_hold_and_release;
            end
        end
        if (!seen) begin
            $fatal(1, "wave3 response did not arrive");
        end
    end
endtask

task wait_wave4_response_hold_and_release;
    reg seen;
    begin
        seen = 1'b0;
        for (wait_i = 0; wait_i < 18; wait_i = wait_i + 1) begin
            @(posedge clk);
            #1;
            if (resp_out_valid == 4'b0011) begin
                seen = 1'b1;
                if (resp_out_rdata[(0*`SRAM_RDATA_W) +: `SRAM_RDATA_W] != UPDATED0 ||
                    resp_out_rdata[(1*`SRAM_RDATA_W) +: `SRAM_RDATA_W] != UPDATED3 ||
                    resp_out_req_id[(0*`REQ_ID_W) +: `REQ_ID_W] != W4_READBACK0_REQ_ID ||
                    resp_out_req_id[(1*`REQ_ID_W) +: `REQ_ID_W] != W4_READBACK3_REQ_ID ||
                    resp_out_pe_mask[(0*`PE_MASK_W) +: `PE_MASK_W] != W4_READBACK0_PE_MASK ||
                    resp_out_pe_mask[(1*`PE_MASK_W) +: `PE_MASK_W] != W4_READBACK3_PE_MASK ||
                    resp_out_last[1:0] != 2'b11) begin
                    $fatal(1, "wave4 readback response mismatch");
                end
                expect_response_stable(4'b0011, 1);
                release_response_mask(4'b0011);
                disable wait_wave4_response_hold_and_release;
            end
        end
        if (!seen) begin
            $fatal(1, "wave4 readback response did not arrive");
        end
    end
endtask

initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    clear_req();
    resp_out_ready = {`MEM_REQ_LANES{1'b0}};
    saw_wave1_four_lane_issue = 1'b0;
    saw_wave2_probe_backpressure = 1'b0;
    saw_wave3_mixed_issue = 1'b0;
    measure_wave2_issues = 1'b0;
    wave2_issue_total_count = 0;
    wave2_addr0_read_issue_count = 0;
    wave2_addr0_write_issue_count = 0;
    wave2_addr1_read_issue_count = 0;

    addr0 = pack_addr(2'h0, 4'h0, 5'h03, 8'h31, 4'h0);
    addr1 = pack_addr(2'h0, 4'h1, 5'h04, 8'h32, 4'h0);
    addr2 = pack_addr(2'h0, 4'h2, 5'h05, 8'h33, 4'h0);
    addr3 = pack_addr(2'h0, 4'h3, 5'h06, 8'h34, 4'h0);
    blocked_addr = pack_addr(2'h0, 4'h4, 5'h07, 8'h35, 4'h0);

    repeat (3) @(posedge clk);
    rst_n = 1'b1;

    drive_accepted_request(1'b1, addr0, DATA0, INIT0_REQ_ID, 16'h0000, 2'd0);
    drive_accepted_request(1'b1, addr1, DATA1, INIT1_REQ_ID, 16'h0000, 2'd0);
    drive_accepted_request(1'b1, addr2, DATA2, INIT2_REQ_ID, 16'h0000, 2'd0);
    drive_accepted_request(1'b1, addr3, DATA3, INIT3_REQ_ID, 16'h0000, 2'd0);

    drive_accepted_request(1'b0, addr0, {`SRAM_WDATA_W{1'b0}},
                           W1_READ0_REQ_ID, W1_READ0_PE_MASK, 2'd0);
    drive_accepted_request(1'b0, addr1, {`SRAM_WDATA_W{1'b0}},
                           W1_READ1_REQ_ID, W1_READ1_PE_MASK, 2'd3);
    drive_accepted_request(1'b0, addr2, {`SRAM_WDATA_W{1'b0}},
                           W1_READ2_REQ_ID, W1_READ2_PE_MASK, 2'd1);
    drive_accepted_request(1'b0, addr3, {`SRAM_WDATA_W{1'b0}},
                           W1_READ3_REQ_ID, W1_READ3_PE_MASK, 2'd2);

    wait_wave1_response_hold_and_release();

    if (!saw_wave1_four_lane_issue) begin
        $fatal(1, "wave1 did not issue four priority-sorted reads together");
    end
    if (!saw_wave2_probe_backpressure) begin
        $fatal(1, "wave1 did not backpressure a new request while responses held");
    end

    wave2_issue_total_count = 0;
    wave2_addr0_read_issue_count = 0;
    wave2_addr0_write_issue_count = 0;
    wave2_addr1_read_issue_count = 0;
    measure_wave2_issues = 1'b1;

    drive_accepted_request(1'b0, addr0, {`SRAM_WDATA_W{1'b0}},
                           W2_BYPASS_READ_REQ_ID, W2_BYPASS_READ_PE_MASK, 2'd2);
    drive_accepted_request(1'b0, addr1, {`SRAM_WDATA_W{1'b0}},
                           W2_SIDE_READ_REQ_ID, W2_SIDE_READ_PE_MASK, 2'd1);
    drive_accepted_request(1'b1, addr0, UPDATED0,
                           W2_BYPASS_WRITE_REQ_ID, 16'h0000, 2'd0);

    wait_wave2_response_hold_and_release();
    measure_wave2_issues = 1'b0;

    if (wave2_issue_total_count != 2 ||
        wave2_addr0_read_issue_count != 0 ||
        wave2_addr0_write_issue_count != 1 ||
        wave2_addr1_read_issue_count != 1) begin
        $fatal(1, "wave2 physical issue pattern mismatch");
    end

    drive_accepted_request(1'b0, addr2, {`SRAM_WDATA_W{1'b0}},
                           W3_READ_REQ_ID, W3_READ_PE_MASK, 2'd1);
    drive_accepted_request(1'b1, addr3, UPDATED3,
                           W3_WRITE_REQ_ID, 16'h0000, 2'd0);

    wait_wave3_response_hold_and_release();

    if (!saw_wave3_mixed_issue) begin
        $fatal(1, "wave3 independent read/write pair did not issue together");
    end

    drive_accepted_request(1'b0, addr0, {`SRAM_WDATA_W{1'b0}},
                           W4_READBACK0_REQ_ID, W4_READBACK0_PE_MASK, 2'd2);
    drive_accepted_request(1'b0, addr3, {`SRAM_WDATA_W{1'b0}},
                           W4_READBACK3_REQ_ID, W4_READBACK3_PE_MASK, 2'd1);

    wait_wave4_response_hold_and_release();

    @(posedge clk);
    #1;
    if (!req_in_ready) begin
        $fatal(1, "request_controller should return to ready after wide rounds");
    end

    $display("tb_request_controller_wide_concurrency PASS");
    $finish;
end

endmodule
