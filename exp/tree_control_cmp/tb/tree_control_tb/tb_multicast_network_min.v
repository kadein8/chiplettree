`include "config/interface_params.vh"
`include "config/memory_params.vh"
`timescale 1ns/1ps

module tb_multicast_network_min;

localparam integer NUM_LANES = `MEM_REQ_LANES;
localparam integer DATA_W = `SRAM_RDATA_W;
localparam integer REQ_ID_W = `REQ_ID_W;
localparam integer PE_MASK_W = `PE_MASK_W;

logic [NUM_LANES-1:0] resp_in_valid;
logic [NUM_LANES-1:0] resp_in_ready;
logic [NUM_LANES*DATA_W-1:0] resp_in_rdata;
logic [NUM_LANES*REQ_ID_W-1:0] resp_in_req_id;
logic [NUM_LANES*PE_MASK_W-1:0] resp_in_pe_mask;
logic [NUM_LANES-1:0] resp_in_last;
logic [PE_MASK_W-1:0] pe_valid;
logic [PE_MASK_W-1:0] pe_ready;
logic [PE_MASK_W*DATA_W-1:0] pe_rdata;
logic [PE_MASK_W*REQ_ID_W-1:0] pe_req_id;
logic [PE_MASK_W*PE_MASK_W-1:0] pe_mask;
logic [PE_MASK_W-1:0] pe_last;

multicast_network u_dut (
    .resp_in_valid(resp_in_valid),
    .resp_in_ready(resp_in_ready),
    .resp_in_rdata(resp_in_rdata),
    .resp_in_req_id(resp_in_req_id),
    .resp_in_pe_mask(resp_in_pe_mask),
    .resp_in_last(resp_in_last),
    .pe_valid(pe_valid),
    .pe_ready(pe_ready),
    .pe_rdata(pe_rdata),
    .pe_req_id(pe_req_id),
    .pe_mask(pe_mask),
    .pe_last(pe_last)
);

initial begin
    resp_in_valid = '0;
    resp_in_rdata = '0;
    resp_in_req_id = '0;
    resp_in_pe_mask = '0;
    resp_in_last = '0;
    pe_ready = {PE_MASK_W{1'b1}};

    resp_in_valid[0] = 1'b1;
    resp_in_rdata[0 +: DATA_W] = 128'hdead_beef_0000_0001_dead_beef_0000_0001;
    resp_in_req_id[0 +: REQ_ID_W] = 4'h3;
    resp_in_pe_mask[0 +: PE_MASK_W] = 16'h0001;
    #1;
    if (pe_valid[0] !== 1'b1)
        $fatal(1, "single-cast PE0 should be valid");
    if (pe_valid[1] !== 1'b0)
        $fatal(1, "single-cast should not drive PE1");
    if (resp_in_ready[0] !== 1'b1)
        $fatal(1, "single-cast lane should be ready");

    resp_in_valid = '0;
    resp_in_rdata = '0;
    resp_in_req_id = '0;
    resp_in_pe_mask = '0;
    resp_in_last = '0;

    resp_in_valid[0] = 1'b1;
    resp_in_rdata[0 +: DATA_W] = 128'h0123_4567_89ab_cdef_0123_4567_89ab_cdef;
    resp_in_req_id[0 +: REQ_ID_W] = 4'h7;
    resp_in_pe_mask[0 +: PE_MASK_W] = 16'hffff;
    #1;
    if (pe_valid !== 16'hffff)
        $fatal(1, "broadcast should drive all PEs actual=%h", pe_valid);
    if (pe_req_id[0 +: REQ_ID_W] !== 4'h7)
        $fatal(1, "broadcast req_id mismatch on PE0");
    if (pe_req_id[(15*REQ_ID_W) +: REQ_ID_W] !== 4'h7)
        $fatal(1, "broadcast req_id mismatch on PE15");

    pe_ready = {PE_MASK_W{1'b1}};
    pe_ready[3] = 1'b0;
    #1;
    if (resp_in_ready[0] !== 1'b0)
        $fatal(1, "backpressure should hold lane when one target PE is not ready");

    resp_in_valid = '0;
    resp_in_rdata = '0;
    resp_in_req_id = '0;
    resp_in_pe_mask = '0;
    resp_in_last = '0;
    pe_ready = {PE_MASK_W{1'b1}};

    resp_in_valid[0] = 1'b1;
    resp_in_valid[1] = 1'b1;
    resp_in_rdata[0 +: DATA_W] = 128'h0000_0000_0000_0000_0000_0000_0000_00aa;
    resp_in_rdata[DATA_W +: DATA_W] = 128'h0000_0000_0000_0000_0000_0000_0000_00bb;
    resp_in_req_id[0 +: REQ_ID_W] = 4'h1;
    resp_in_req_id[REQ_ID_W +: REQ_ID_W] = 4'h2;
    resp_in_pe_mask[0 +: PE_MASK_W] = 16'h0003;
    resp_in_pe_mask[PE_MASK_W +: PE_MASK_W] = 16'h0004;
    #1;
    if (pe_valid[0] !== 1'b1 || pe_valid[1] !== 1'b1 || pe_valid[2] !== 1'b1)
        $fatal(1, "multi-lane no-overlap case should drive PE0/1/2");
    if (resp_in_ready[0] !== 1'b1 || resp_in_ready[1] !== 1'b1)
        $fatal(1, "multi-lane no-overlap lanes should both be ready");

    $display("tb_multicast_network_min PASS");
    $finish;
end

endmodule
