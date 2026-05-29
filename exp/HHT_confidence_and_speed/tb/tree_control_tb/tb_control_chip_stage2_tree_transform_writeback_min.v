`timescale 1ns/1ps

`include "config/interface_params.vh"
`include "config/memory_params.vh"

module tb_control_chip_stage2_tree_transform_writeback_min;

localparam integer CFG_W = 32;
localparam integer MODEL_ID_W = 8;
localparam integer OP_CLASS_W = 8;
localparam integer TOKEN_LEN_W = 16;
localparam integer RESULT_STATUS_W = 2;
localparam [RESULT_STATUS_W-1:0] STATUS_OK = 2'b00;

localparam [`TOKEN_ID_W-1:0] EXP_TOKEN_ID = 16'h2401;
localparam [`SRAM_ADDR_W-1:0] EXP_SRC_ADDR = {2'd0, 4'd1, 5'd3, 8'h02, 4'h0};
localparam [`SRAM_ADDR_W-1:0] EXP_DST_ADDR = {2'd0, 4'd1, 5'd4, 8'h03, 4'h0};
localparam [`REQ_ID_W-1:0] EXP_REQ_ID = 4'h6;
localparam [`SRAM_WDATA_W-1:0] EXP_WDATA =
    128'h1111_2222_3333_4444_aaaa_bbbb_cccc_dddd;

reg clk;
reg rst_n;

reg cfg_valid;
reg [CFG_W-1:0] cfg_data;
reg start;

wire tree_busy;
wire tree_error_flag;
wire issue_valid;
wire issue_ready;
wire [`TOKEN_ID_W-1:0] issue_token_id;
wire [`BRANCH_ID_W-1:0] issue_branch_id;
wire [1:0] issue_epoch;
wire [MODEL_ID_W-1:0] issue_model_id;
wire [OP_CLASS_W-1:0] issue_op_class;
wire [`SRAM_ADDR_W-1:0] issue_src_addr;
wire [`SRAM_ADDR_W-1:0] issue_dst_addr;
wire [TOKEN_LEN_W-1:0] issue_token_len;
wire [`REQ_ID_W-1:0] issue_req_id;
wire [1:0] issue_flush_epoch;

wire prep_req_valid;
wire prep_req_write;
wire [`SRAM_ADDR_W-1:0] prep_req_addr;
wire [`SRAM_WDATA_W-1:0] prep_req_wdata;
wire [`REQ_ID_W-1:0] prep_req_id;

wire op_req_valid;
wire op_req_ready;
wire op_req_write;
wire [`SRAM_ADDR_W-1:0] op_req_addr;
wire [`SRAM_WDATA_W-1:0] op_req_wdata;
wire [`REQ_ID_W-1:0] op_req_id;
wire op_req_last;
wire [`TOKEN_ID_W-1:0] op_req_tag;

wire op_resp_valid;
wire op_resp_ready;
wire [`SRAM_RDATA_W-1:0] op_resp_rdata;
wire [`REQ_ID_W-1:0] op_resp_id;
wire op_resp_last;

wire result_valid;
wire result_ready;
wire [`TOKEN_ID_W-1:0] result_token_id;
wire [`SRAM_ADDR_W-1:0] result_addr;
wire [`SRAM_WDATA_W-1:0] result_data;
wire [RESULT_STATUS_W-1:0] result_status;

wire wb_valid;
reg wb_ready;
wire [`TOKEN_ID_W-1:0] wb_token_id;
wire [`SRAM_ADDR_W-1:0] wb_addr;
wire [`SRAM_WDATA_W-1:0] wb_data;
wire [RESULT_STATUS_W-1:0] wb_status;
wire wb_done;
wire wb_error;

reg tb_req_valid;
wire tb_req_ready;
reg tb_req_write;
reg [`SRAM_ADDR_W-1:0] tb_req_addr;
reg [`SRAM_WDATA_W-1:0] tb_req_wdata;
reg [`REQ_ID_W-1:0] tb_req_id;
reg use_tb_req;

wire rc_req_valid;
wire rc_req_ready;
wire rc_req_write;
wire [`SRAM_ADDR_W-1:0] rc_req_addr;
wire [`SRAM_WDATA_W-1:0] rc_req_wdata;
wire [`REQ_ID_W-1:0] rc_req_id;
wire [`PE_MASK_W-1:0] rc_req_pe_mask;
wire [`REQ_PRIORITY_W-1:0] rc_req_priority;
wire [`BANK_ID_W-1:0] rc_req_bank_id;
wire [`SUBBANK_ID_W-1:0] rc_req_subbank_id;

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
wire [`MEM_REQ_LANES-1:0] pe_resp_valid;
wire [`MEM_REQ_LANES*`SRAM_RDATA_W-1:0] pe_resp_rdata;
wire [`MEM_REQ_LANES*`REQ_ID_W-1:0] pe_resp_req_id;
wire [`MEM_REQ_LANES*`PE_MASK_W-1:0] pe_resp_pe_mask;
wire [`MEM_REQ_LANES-1:0] pe_resp_last;
wire [`MEM_REQ_LANES-1:0] pe_resp_ready;

reg preload_write_seen_r;
reg transform_read_seen_r;
reg wb_payload_seen_r;
reg prep_req_seen_r;

assign rc_req_valid = use_tb_req ? tb_req_valid : op_req_valid;
assign rc_req_write = use_tb_req ? tb_req_write : op_req_write;
assign rc_req_addr = use_tb_req ? tb_req_addr : op_req_addr;
assign rc_req_wdata = use_tb_req ? tb_req_wdata : op_req_wdata;
assign rc_req_id = use_tb_req ? tb_req_id : op_req_id;
assign rc_req_pe_mask = use_tb_req ? 16'h0001 : 16'h0001;
assign rc_req_priority = {`REQ_PRIORITY_W{1'b0}};
assign rc_req_bank_id =
    rc_req_addr[(`OFFSET_W + `ROW_ADDR_W + `SUBBANK_ID_W) +: `BANK_ID_W];
assign rc_req_subbank_id =
    rc_req_addr[(`OFFSET_W + `ROW_ADDR_W) +: `SUBBANK_ID_W];
assign tb_req_ready = use_tb_req ? rc_req_ready : 1'b0;
assign op_req_ready = use_tb_req ? 1'b0 : rc_req_ready;

assign op_resp_valid = pe_resp_valid[0];
assign op_resp_rdata = pe_resp_rdata[0 +: `SRAM_RDATA_W];
assign op_resp_id = pe_resp_req_id[0 +: `REQ_ID_W];
assign op_resp_last = pe_resp_last[0];
assign pe_resp_ready = {{(`MEM_REQ_LANES-1){1'b0}}, op_resp_ready};

always #5 clk = ~clk;

IntegrationTreeControlPart #(
    .CFG_W(CFG_W),
    .MODEL_ID_W(MODEL_ID_W),
    .OP_CLASS_W(OP_CLASS_W),
    .TOKEN_LEN_W(TOKEN_LEN_W)
) u_integration_tree_control_part (
    .clk(clk),
    .rst_n(rst_n),
    .cfg_valid(cfg_valid),
    .cfg_data(cfg_data),
    .start(start),
    .busy(tree_busy),
    .error_flag(tree_error_flag),
    .issue_valid(issue_valid),
    .issue_ready(issue_ready),
    .issue_token_id(issue_token_id),
    .issue_branch_id(issue_branch_id),
    .issue_epoch(issue_epoch),
    .issue_model_id(issue_model_id),
    .issue_op_class(issue_op_class),
    .issue_src_addr(issue_src_addr),
    .issue_dst_addr(issue_dst_addr),
    .issue_token_len(issue_token_len),
    .issue_req_id(issue_req_id),
    .issue_flush_epoch(issue_flush_epoch),
    .prep_req_valid(prep_req_valid),
    .prep_req_ready(1'b1),
    .prep_req_write(prep_req_write),
    .prep_req_addr(prep_req_addr),
    .prep_req_wdata(prep_req_wdata),
    .prep_req_id(prep_req_id),
    .wb_done(wb_done),
    .wb_error(wb_error),
    .wb_token_id(wb_token_id)
);

IntegrationTransformPart #(
    .MODEL_ID_W(MODEL_ID_W),
    .OP_CLASS_W(OP_CLASS_W),
    .TOKEN_LEN_W(TOKEN_LEN_W),
    .RESULT_STATUS_W(RESULT_STATUS_W)
) u_integration_transform_part (
    .clk(clk),
    .rst_n(rst_n),
    .issue_valid(issue_valid),
    .issue_ready(issue_ready),
    .issue_token_id(issue_token_id),
    .issue_branch_id(issue_branch_id),
    .issue_epoch(issue_epoch),
    .issue_model_id(issue_model_id),
    .issue_op_class(issue_op_class),
    .issue_src_addr(issue_src_addr),
    .issue_dst_addr(issue_dst_addr),
    .issue_token_len(issue_token_len),
    .issue_req_id(issue_req_id),
    .issue_flush_epoch(issue_flush_epoch),
    .op_req_valid(op_req_valid),
    .op_req_ready(op_req_ready),
    .op_req_write(op_req_write),
    .op_req_addr(op_req_addr),
    .op_req_wdata(op_req_wdata),
    .op_req_id(op_req_id),
    .op_req_last(op_req_last),
    .op_req_tag(op_req_tag),
    .op_resp_valid(op_resp_valid),
    .op_resp_ready(op_resp_ready),
    .op_resp_rdata(op_resp_rdata),
    .op_resp_id(op_resp_id),
    .op_resp_last(op_resp_last),
    .result_valid(result_valid),
    .result_ready(result_ready),
    .result_token_id(result_token_id),
    .result_addr(result_addr),
    .result_data(result_data),
    .result_status(result_status)
);

IntegrationWritebackPart #(
    .RESULT_STATUS_W(RESULT_STATUS_W)
) u_integration_writeback_part (
    .clk(clk),
    .rst_n(rst_n),
    .result_valid(result_valid),
    .result_ready(result_ready),
    .result_token_id(result_token_id),
    .result_addr(result_addr),
    .result_data(result_data),
    .result_status(result_status),
    .wb_valid(wb_valid),
    .wb_ready(wb_ready),
    .wb_token_id(wb_token_id),
    .wb_addr(wb_addr),
    .wb_data(wb_data),
    .wb_status(wb_status),
    .wb_done(wb_done),
    .wb_error(wb_error)
);

request_controller u_request_controller (
    .clk(clk),
    .rst_n(rst_n),
    .req_in_valid(rc_req_valid),
    .req_in_ready(rc_req_ready),
    .req_in_write(rc_req_write),
    .req_in_addr(rc_req_addr),
    .req_in_wdata(rc_req_wdata),
    .req_in_req_id(rc_req_id),
    .req_in_pe_mask(rc_req_pe_mask),
    .req_in_priority(rc_req_priority),
    .req_in_bank_id(rc_req_bank_id),
    .req_in_subbank_id(rc_req_subbank_id),
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
    .resp_out_valid(pe_resp_valid),
    .resp_out_ready(pe_resp_ready),
    .resp_out_rdata(pe_resp_rdata),
    .resp_out_req_id(pe_resp_req_id),
    .resp_out_pe_mask(pe_resp_pe_mask),
    .resp_out_last(pe_resp_last)
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

task clear_inputs;
    begin
        cfg_valid = 1'b0;
        cfg_data = {CFG_W{1'b0}};
        start = 1'b0;
        wb_ready = 1'b0;
        tb_req_valid = 1'b0;
        tb_req_write = 1'b0;
        tb_req_addr = {`SRAM_ADDR_W{1'b0}};
        tb_req_wdata = {`SRAM_WDATA_W{1'b0}};
        tb_req_id = {`REQ_ID_W{1'b0}};
        use_tb_req = 1'b0;
    end
endtask

task preload_src_data_once;
    begin
        use_tb_req = 1'b1;
        tb_req_valid = 1'b1;
        tb_req_write = 1'b1;
        tb_req_addr = EXP_SRC_ADDR;
        tb_req_wdata = EXP_WDATA;
        tb_req_id = 4'h1;

        @(posedge clk);
        #1;
        tb_req_valid = 1'b0;
        use_tb_req = 1'b0;
    end
endtask

task start_tree_once;
    begin
        cfg_valid = 1'b1;
        cfg_data = 32'h0000_0001;
        start = 1'b1;
        @(posedge clk);
        #1;
        cfg_valid = 1'b0;
        start = 1'b0;
    end
endtask

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        preload_write_seen_r <= 1'b0;
        transform_read_seen_r <= 1'b0;
        wb_payload_seen_r <= 1'b0;
        prep_req_seen_r <= 1'b0;
    end else begin
        if (prep_req_valid) begin
            prep_req_seen_r <= 1'b1;
        end

        if (mem_req_valid[0] && mem_req_ready[0] &&
            mem_req_write[0] &&
            (mem_req_addr[0 +: `SRAM_ADDR_W] == EXP_SRC_ADDR) &&
            (mem_req_wdata[0 +: `SRAM_WDATA_W] == EXP_WDATA)) begin
            preload_write_seen_r <= 1'b1;
        end

        if (mem_req_valid[0] && mem_req_ready[0] &&
            !mem_req_write[0] &&
            (mem_req_addr[0 +: `SRAM_ADDR_W] == EXP_SRC_ADDR)) begin
            transform_read_seen_r <= 1'b1;
        end

        if (wb_valid &&
            (wb_token_id == EXP_TOKEN_ID) &&
            (wb_addr == EXP_DST_ADDR) &&
            (wb_data == EXP_WDATA) &&
            (wb_status == STATUS_OK)) begin
            wb_payload_seen_r <= 1'b1;
        end
    end
end

integer cycle_count;

initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    clear_inputs();

    repeat (3) @(posedge clk);
    rst_n = 1'b1;

    preload_src_data_once();

    cycle_count = 0;
    while (!preload_write_seen_r && (cycle_count < 8)) begin
        @(posedge clk);
        #1;
        cycle_count = cycle_count + 1;
    end
    if (!preload_write_seen_r) begin
        $fatal(1, "preload write was not observed");
    end

    wb_ready = 1'b1;
    start_tree_once();

    cycle_count = 0;
    while ((tree_busy !== 1'b1) && (cycle_count < 8)) begin
        @(posedge clk);
        #1;
        cycle_count = cycle_count + 1;
    end
    if (tree_busy !== 1'b1) begin
        $fatal(1, "tree control did not enter busy");
    end

    cycle_count = 0;
    while (!wb_done && (cycle_count < 40)) begin
        @(posedge clk);
        #1;
        cycle_count = cycle_count + 1;
    end
    if (!wb_done) begin
        $fatal(1, "writeback completion was not observed");
    end

    @(posedge clk);
    #1;

    if (tree_busy !== 1'b0) begin
        $fatal(1, "tree control did not return to idle");
    end
    if (tree_error_flag !== 1'b0) begin
        $fatal(1, "tree control error flag should stay low");
    end
    if (!transform_read_seen_r) begin
        $fatal(1, "transform read request was not observed");
    end
    if (!wb_payload_seen_r) begin
        $fatal(1, "writeback payload was not observed");
    end
    if (prep_req_seen_r) begin
        $fatal(1, "prep request path should stay idle in this slice");
    end

    $display("tb_control_chip_stage2_tree_transform_writeback_min PASS");
    $finish;
end

endmodule
