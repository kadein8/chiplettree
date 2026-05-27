`timescale 1ns/1ps

`include "config/interface_params.vh"
`include "config/memory_params.vh"

module tb_control_chip_stage2_recompute_partialkv_min;

localparam integer DRAFT_PORTS = 4;
localparam integer CONF_W = 8;
localparam integer SOURCE_ID_W =
    ((DRAFT_PORTS + 1) <= 2) ? 1 : $clog2(DRAFT_PORTS + 1);
localparam integer CFG_W = 32;
localparam integer MODEL_ID_W = 8;
localparam integer OP_CLASS_W = 8;
localparam integer TOKEN_LEN_W = 16;
localparam integer RESULT_STATUS_W = 2;
localparam [RESULT_STATUS_W-1:0] STATUS_OK = 2'b00;

localparam [`POSITION_ID_W-1:0] CURRENT_POSITION = 12'h040;
localparam [`POSITION_ID_W-1:0] RECENCY_TH = 12'h010;
localparam [SOURCE_ID_W-1:0] SEL_SOURCE_ID = 3'd2;
localparam [`NODE_ID_W-1:0] SEL_PARENT_NODE_ID = 4'd5;
localparam [`TOKEN_ID_W-1:0] SEL_TOKEN_ID = 16'h5505;
localparam [`TOKEN_ID_W-1:0] SEL_REF_TOKEN_ID = 16'h8558;
localparam [`POSITION_ID_W-1:0] SEL_REF_POS = 12'h020;
localparam [CONF_W-1:0] SEL_CONF = 8'd208;

localparam [`SRAM_ADDR_W-1:0] EXP_SRC_ADDR = {2'd0, 4'd2, 5'd6, 8'h00, 4'h0};
localparam [`REQ_ID_W-1:0] EXP_REQ_ID = 4'h6;
localparam [`SRAM_WDATA_W-1:0] EXP_PARTIAL_WDATA =
    128'h1111_2222_3333_4444_5555_6666_7777_8888;
localparam [`SRAM_WDATA_W-1:0] EXP_FULL_WDATA =
    128'haaaa_bbbb_cccc_dddd_eeee_ffff_1234_5678;
localparam [`SRAM_ID_W-1:0] EXP_SRAM_ID =
    EXP_SRC_ADDR[(`OFFSET_W + `ROW_ADDR_W + `SUBBANK_ID_W + `BANK_ID_W) +: `SRAM_ID_W];
localparam [`BANK_ID_W-1:0] EXP_BANK_ID =
    EXP_SRC_ADDR[(`OFFSET_W + `ROW_ADDR_W + `SUBBANK_ID_W) +: `BANK_ID_W];
localparam [`SUBBANK_ID_W-1:0] EXP_SUBBANK_START =
    EXP_SRC_ADDR[(`OFFSET_W + `ROW_ADDR_W) +: `SUBBANK_ID_W];
localparam [`KV_GROUP_LEN_W-1:0] EXP_GROUP_LEN = `KV_GROUP_SIZE_SUBBANK;

reg clk;
reg rst_n;

reg cfg_valid;
reg [CFG_W-1:0] cfg_data;
reg start;

reg hht_cand_valid;
wire hht_cand_ready;
reg [`NODE_ID_W-1:0] hht_parent_node_id;
reg [`TOKEN_ID_W-1:0] hht_token_id;
reg [`TOKEN_ID_W-1:0] hht_referenced_token_id;
reg [`POSITION_ID_W-1:0] hht_referenced_position;
reg [CONF_W-1:0] hht_confidence;

reg [DRAFT_PORTS-1:0] draft_cand_valid;
wire [DRAFT_PORTS-1:0] draft_cand_ready;
reg [DRAFT_PORTS*`NODE_ID_W-1:0] draft_parent_node_id;
reg [DRAFT_PORTS*`TOKEN_ID_W-1:0] draft_token_id;
reg [DRAFT_PORTS*`TOKEN_ID_W-1:0] draft_referenced_token_id;
reg [DRAFT_PORTS*`POSITION_ID_W-1:0] draft_referenced_position;
reg [DRAFT_PORTS*CONF_W-1:0] draft_confidence;

wire pred_valid;
wire pred_ready;
wire [SOURCE_ID_W-1:0] pred_source_id;
wire [`NODE_ID_W-1:0] pred_parent_node_id;
wire [`TOKEN_ID_W-1:0] pred_token_id;
wire [`TOKEN_ID_W-1:0] pred_referenced_token_id;
wire [`POSITION_ID_W-1:0] pred_referenced_position;
wire [CONF_W-1:0] pred_confidence;
wire pred_is_last_in_window;

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
wire [`NODE_ID_W-1:0] issue_parent_node_id;
wire [CONF_W-1:0] issue_confidence;

wire prep_req_valid;
wire prep_req_ready;
wire prep_req_write;
wire [`SRAM_ADDR_W-1:0] prep_req_addr;
wire [`SRAM_WDATA_W-1:0] prep_req_wdata;
wire [`REQ_ID_W-1:0] prep_req_id;

wire recompute_req_valid;
reg recompute_req_ready;
wire [`TOKEN_ID_W-1:0] recompute_req_token_id;
wire [`POSITION_ID_W-1:0] recompute_req_current_position;
wire [`POSITION_ID_W-1:0] recompute_req_referenced_position;
wire [`BRANCH_ID_W-1:0] recompute_req_branch_id;
wire recompute_req_reason_stale;

reg recompute_resp_valid;
wire recompute_resp_ready;
reg recompute_resp_partial;
reg recompute_resp_full;
reg [`REQ_ID_W-1:0] recompute_resp_req_id;
reg [`SRAM_WDATA_W-1:0] recompute_resp_kv_data;
reg recompute_resp_last;

reg kv_lookup_valid;
reg [`TOKEN_ID_W-1:0] kv_lookup_token_id;
reg [`POSITION_ID_W-1:0] kv_lookup_position_id;
wire kv_lookup_ready;
wire kv_lookup_hit;
wire kv_lookup_partial_ready;
wire kv_lookup_full_ready;
wire [`SRAM_ID_W-1:0] kv_lookup_sram_id;
wire [`BANK_ID_W-1:0] kv_lookup_bank_id;
wire [`SUBBANK_ID_W-1:0] kv_lookup_subbank_start;
wire [`KV_GROUP_LEN_W-1:0] kv_lookup_group_len;
wire debug_stale_hit;
wire debug_recompute_busy;
wire debug_recompute_done;

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

wire use_prep_req;
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

reg pred_selected_seen_r;
reg stale_seen_r;
reg recompute_req_seen_r;
reg partial_write_seen_r;
reg full_write_seen_r;
reg full_done_seen_r;
reg issue_seen_r;
reg transform_read_seen_r;
reg wb_partial_payload_seen_r;
reg partial_lookup_seen_r;
reg full_lookup_seen_r;
wire partial_write_fire_w;
wire full_write_fire_w;

assign use_prep_req = prep_req_valid;
assign rc_req_valid = use_prep_req ? prep_req_valid : op_req_valid;
assign rc_req_write = use_prep_req ? prep_req_write : op_req_write;
assign rc_req_addr = use_prep_req ? prep_req_addr : op_req_addr;
assign rc_req_wdata = use_prep_req ? prep_req_wdata : op_req_wdata;
assign rc_req_id = use_prep_req ? prep_req_id : op_req_id;
assign rc_req_pe_mask = 16'h0001;
assign rc_req_priority = {`REQ_PRIORITY_W{1'b0}};
assign rc_req_bank_id =
    rc_req_addr[(`OFFSET_W + `ROW_ADDR_W + `SUBBANK_ID_W) +: `BANK_ID_W];
assign rc_req_subbank_id =
    rc_req_addr[(`OFFSET_W + `ROW_ADDR_W) +: `SUBBANK_ID_W];
assign prep_req_ready = use_prep_req ? rc_req_ready : 1'b0;
assign op_req_ready = use_prep_req ? 1'b0 : rc_req_ready;

assign op_resp_valid = pe_resp_valid[0];
assign op_resp_rdata = pe_resp_rdata[0 +: `SRAM_RDATA_W];
assign op_resp_id = pe_resp_req_id[0 +: `REQ_ID_W];
assign op_resp_last = pe_resp_last[0];
assign pe_resp_ready = {{(`MEM_REQ_LANES-1){1'b0}}, op_resp_ready};
assign partial_write_fire_w =
    mem_req_valid[0] && mem_req_ready[0] &&
    mem_req_write[0] &&
    (mem_req_addr[0 +: `SRAM_ADDR_W] == EXP_SRC_ADDR) &&
    (mem_req_wdata[0 +: `SRAM_WDATA_W] == EXP_PARTIAL_WDATA);
assign full_write_fire_w =
    mem_req_valid[0] && mem_req_ready[0] &&
    mem_req_write[0] &&
    (mem_req_addr[0 +: `SRAM_ADDR_W] == EXP_SRC_ADDR) &&
    (mem_req_wdata[0 +: `SRAM_WDATA_W] == EXP_FULL_WDATA);

always #5 clk = ~clk;

IntegrationPredictionPart #(
    .DRAFT_PORTS(DRAFT_PORTS),
    .CONF_W(CONF_W)
) u_integration_prediction_part (
    .clk(clk),
    .rst_n(rst_n),
    .hht_cand_valid(hht_cand_valid),
    .hht_cand_ready(hht_cand_ready),
    .hht_parent_node_id(hht_parent_node_id),
    .hht_token_id(hht_token_id),
    .hht_referenced_token_id(hht_referenced_token_id),
    .hht_referenced_position(hht_referenced_position),
    .hht_confidence(hht_confidence),
    .draft_cand_valid(draft_cand_valid),
    .draft_cand_ready(draft_cand_ready),
    .draft_parent_node_id(draft_parent_node_id),
    .draft_token_id(draft_token_id),
    .draft_referenced_token_id(draft_referenced_token_id),
    .draft_referenced_position(draft_referenced_position),
    .draft_confidence(draft_confidence),
    .pred_valid(pred_valid),
    .pred_ready(pred_ready),
    .pred_source_id(pred_source_id),
    .pred_parent_node_id(pred_parent_node_id),
    .pred_token_id(pred_token_id),
    .pred_referenced_token_id(pred_referenced_token_id),
    .pred_referenced_position(pred_referenced_position),
    .pred_confidence(pred_confidence),
    .pred_is_last_in_window(pred_is_last_in_window)
);

IntegrationTreeControlPart #(
    .CFG_W(CFG_W),
    .MODEL_ID_W(MODEL_ID_W),
    .OP_CLASS_W(OP_CLASS_W),
    .TOKEN_LEN_W(TOKEN_LEN_W),
    .CONF_W(CONF_W),
    .PRED_SOURCE_ID_W(SOURCE_ID_W),
    .ENABLE_PREDICTION_INPUT(1),
    .ENABLE_RECOMPUTE_PATH(1),
    .CURRENT_POSITION(CURRENT_POSITION),
    .RECENCY_TH(RECENCY_TH),
    .ISSUE_TOKEN_ID(SEL_TOKEN_ID),
    .ISSUE_SRC_ADDR(EXP_SRC_ADDR),
    .ISSUE_REQ_ID(EXP_REQ_ID)
) u_integration_tree_control_part (
    .clk(clk),
    .rst_n(rst_n),
    .cfg_valid(cfg_valid),
    .cfg_data(cfg_data),
    .start(start),
    .busy(tree_busy),
    .error_flag(tree_error_flag),
    .pred_valid(pred_valid),
    .pred_ready(pred_ready),
    .pred_source_id(pred_source_id),
    .pred_parent_node_id(pred_parent_node_id),
    .pred_token_id(pred_token_id),
    .pred_referenced_token_id(pred_referenced_token_id),
    .pred_referenced_position(pred_referenced_position),
    .pred_confidence(pred_confidence),
    .pred_is_last_in_window(pred_is_last_in_window),
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
    .issue_parent_node_id(issue_parent_node_id),
    .issue_confidence(issue_confidence),
    .prep_req_valid(prep_req_valid),
    .prep_req_ready(prep_req_ready),
    .prep_req_write(prep_req_write),
    .prep_req_addr(prep_req_addr),
    .prep_req_wdata(prep_req_wdata),
    .prep_req_id(prep_req_id),
    .recompute_req_valid(recompute_req_valid),
    .recompute_req_ready(recompute_req_ready),
    .recompute_req_token_id(recompute_req_token_id),
    .recompute_req_current_position(recompute_req_current_position),
    .recompute_req_referenced_position(recompute_req_referenced_position),
    .recompute_req_branch_id(recompute_req_branch_id),
    .recompute_req_reason_stale(recompute_req_reason_stale),
    .recompute_resp_valid(recompute_resp_valid),
    .recompute_resp_ready(recompute_resp_ready),
    .recompute_resp_partial(recompute_resp_partial),
    .recompute_resp_full(recompute_resp_full),
    .recompute_resp_req_id(recompute_resp_req_id),
    .recompute_resp_kv_data(recompute_resp_kv_data),
    .recompute_resp_last(recompute_resp_last),
    .kv_lookup_valid(kv_lookup_valid),
    .kv_lookup_token_id(kv_lookup_token_id),
    .kv_lookup_position_id(kv_lookup_position_id),
    .kv_lookup_ready(kv_lookup_ready),
    .kv_lookup_hit(kv_lookup_hit),
    .kv_lookup_partial_ready(kv_lookup_partial_ready),
    .kv_lookup_full_ready(kv_lookup_full_ready),
    .kv_lookup_sram_id(kv_lookup_sram_id),
    .kv_lookup_bank_id(kv_lookup_bank_id),
    .kv_lookup_subbank_start(kv_lookup_subbank_start),
    .kv_lookup_group_len(kv_lookup_group_len),
    .debug_stale_hit(debug_stale_hit),
    .debug_recompute_busy(debug_recompute_busy),
    .debug_recompute_done(debug_recompute_done),
    .wb_done(wb_done),
    .wb_error(wb_error),
    .wb_token_id(wb_token_id)
);

IntegrationTransformPart #(
    .MODEL_ID_W(MODEL_ID_W),
    .OP_CLASS_W(OP_CLASS_W),
    .TOKEN_LEN_W(TOKEN_LEN_W),
    .CONF_W(CONF_W),
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
    .issue_parent_node_id(issue_parent_node_id),
    .issue_confidence(issue_confidence),
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
        recompute_req_ready = 1'b0;
        recompute_resp_valid = 1'b0;
        recompute_resp_partial = 1'b0;
        recompute_resp_full = 1'b0;
        recompute_resp_req_id = {`REQ_ID_W{1'b0}};
        recompute_resp_kv_data = {`SRAM_WDATA_W{1'b0}};
        recompute_resp_last = 1'b0;
        kv_lookup_valid = 1'b0;
        kv_lookup_token_id = {`TOKEN_ID_W{1'b0}};
        kv_lookup_position_id = {`POSITION_ID_W{1'b0}};

        hht_cand_valid = 1'b0;
        hht_parent_node_id = {`NODE_ID_W{1'b0}};
        hht_token_id = {`TOKEN_ID_W{1'b0}};
        hht_referenced_token_id = {`TOKEN_ID_W{1'b0}};
        hht_referenced_position = {`POSITION_ID_W{1'b0}};
        hht_confidence = {CONF_W{1'b0}};

        draft_cand_valid = {DRAFT_PORTS{1'b0}};
        draft_parent_node_id = {(DRAFT_PORTS*`NODE_ID_W){1'b0}};
        draft_token_id = {(DRAFT_PORTS*`TOKEN_ID_W){1'b0}};
        draft_referenced_token_id = {(DRAFT_PORTS*`TOKEN_ID_W){1'b0}};
        draft_referenced_position = {(DRAFT_PORTS*`POSITION_ID_W){1'b0}};
        draft_confidence = {(DRAFT_PORTS*CONF_W){1'b0}};
    end
endtask

task expect_ready_mask;
    input expected_hht_ready;
    input [DRAFT_PORTS-1:0] expected_draft_ready;
    begin
        #1;
        if ((hht_cand_ready !== expected_hht_ready) ||
            (draft_cand_ready !== expected_draft_ready)) begin
            $fatal(1, "prediction ready mask mismatch");
        end
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

task drive_candidate_window_once;
    begin
        hht_cand_valid = 1'b1;
        hht_parent_node_id = 4'd3;
        hht_token_id = 16'h0101;
        hht_referenced_token_id = 16'h8101;
        hht_referenced_position = 12'h03a;
        hht_confidence = 8'd120;

        draft_cand_valid = 4'b0011;
        draft_parent_node_id[(0*`NODE_ID_W) +: `NODE_ID_W] = 4'd4;
        draft_token_id[(0*`TOKEN_ID_W) +: `TOKEN_ID_W] = 16'h0202;
        draft_referenced_token_id[(0*`TOKEN_ID_W) +: `TOKEN_ID_W] = 16'h8202;
        draft_referenced_position[(0*`POSITION_ID_W) +: `POSITION_ID_W] = 12'h03c;
        draft_confidence[(0*CONF_W) +: CONF_W] = 8'd90;

        draft_parent_node_id[(1*`NODE_ID_W) +: `NODE_ID_W] = SEL_PARENT_NODE_ID;
        draft_token_id[(1*`TOKEN_ID_W) +: `TOKEN_ID_W] = SEL_TOKEN_ID;
        draft_referenced_token_id[(1*`TOKEN_ID_W) +: `TOKEN_ID_W] = SEL_REF_TOKEN_ID;
        draft_referenced_position[(1*`POSITION_ID_W) +: `POSITION_ID_W] = SEL_REF_POS;
        draft_confidence[(1*CONF_W) +: CONF_W] = SEL_CONF;

        expect_ready_mask(1'b0, 4'b0010);
        @(posedge clk);
        #1;
        hht_cand_valid = 1'b0;
        draft_cand_valid = {DRAFT_PORTS{1'b0}};
    end
endtask

task send_partial_kv_response_once;
    begin
        recompute_resp_valid = 1'b1;
        recompute_resp_partial = 1'b1;
        recompute_resp_full = 1'b0;
        recompute_resp_req_id = 4'h9;
        recompute_resp_kv_data = EXP_PARTIAL_WDATA;
        recompute_resp_last = 1'b1;
        @(posedge clk);
        #1;
        recompute_resp_valid = 1'b0;
        recompute_resp_partial = 1'b0;
        recompute_resp_last = 1'b0;
    end
endtask

task send_full_kv_response_once;
    begin
        recompute_resp_valid = 1'b1;
        recompute_resp_partial = 1'b0;
        recompute_resp_full = 1'b1;
        recompute_resp_req_id = 4'h9;
        recompute_resp_kv_data = EXP_FULL_WDATA;
        recompute_resp_last = 1'b1;
        @(posedge clk);
        #1;
        recompute_resp_valid = 1'b0;
        recompute_resp_full = 1'b0;
        recompute_resp_last = 1'b0;
    end
endtask

task query_kv_tables_once;
    begin
        kv_lookup_valid = 1'b1;
        kv_lookup_token_id = SEL_REF_TOKEN_ID;
        kv_lookup_position_id = SEL_REF_POS;
        @(posedge clk);
        #1;
        kv_lookup_valid = 1'b0;
    end
endtask

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        pred_selected_seen_r <= 1'b0;
        stale_seen_r <= 1'b0;
        recompute_req_seen_r <= 1'b0;
        partial_write_seen_r <= 1'b0;
        full_write_seen_r <= 1'b0;
        full_done_seen_r <= 1'b0;
        issue_seen_r <= 1'b0;
        transform_read_seen_r <= 1'b0;
        wb_partial_payload_seen_r <= 1'b0;
        partial_lookup_seen_r <= 1'b0;
        full_lookup_seen_r <= 1'b0;
    end else begin
        if (pred_valid && pred_ready &&
            (pred_source_id == SEL_SOURCE_ID) &&
            (pred_parent_node_id == SEL_PARENT_NODE_ID) &&
            (pred_token_id == SEL_TOKEN_ID) &&
            (pred_referenced_token_id == SEL_REF_TOKEN_ID) &&
            (pred_referenced_position == SEL_REF_POS) &&
            (pred_confidence == SEL_CONF) &&
            pred_is_last_in_window) begin
            pred_selected_seen_r <= 1'b1;
        end

        if (debug_stale_hit) begin
            stale_seen_r <= 1'b1;
        end

        if (recompute_req_valid && recompute_req_ready &&
            (recompute_req_token_id == SEL_TOKEN_ID) &&
            (recompute_req_current_position == CURRENT_POSITION) &&
            (recompute_req_referenced_position == SEL_REF_POS) &&
            recompute_req_reason_stale) begin
            recompute_req_seen_r <= 1'b1;
        end

        if (partial_write_fire_w) begin
            partial_write_seen_r <= 1'b1;
        end

        if (full_write_fire_w) begin
            full_write_seen_r <= 1'b1;
        end

        if (debug_recompute_done) begin
            full_done_seen_r <= 1'b1;
        end

        if (issue_valid && issue_ready &&
            (issue_token_id == SEL_TOKEN_ID) &&
            (issue_parent_node_id == SEL_PARENT_NODE_ID) &&
            (issue_confidence == SEL_CONF) &&
            (issue_src_addr == EXP_SRC_ADDR) &&
            (issue_req_id == EXP_REQ_ID)) begin
            if (!(partial_write_seen_r || partial_write_fire_w)) begin
                $fatal(1, "issue fired before partial KV write");
            end
            issue_seen_r <= 1'b1;
        end

        if (mem_req_valid[0] && mem_req_ready[0] &&
            !mem_req_write[0] &&
            (mem_req_addr[0 +: `SRAM_ADDR_W] == EXP_SRC_ADDR)) begin
            transform_read_seen_r <= 1'b1;
        end

        if (wb_valid &&
            (wb_token_id == SEL_TOKEN_ID) &&
            (wb_data == EXP_PARTIAL_WDATA) &&
            (wb_status == STATUS_OK)) begin
            wb_partial_payload_seen_r <= 1'b1;
        end

        if (kv_lookup_valid && kv_lookup_ready &&
            kv_lookup_hit &&
            kv_lookup_partial_ready &&
            !kv_lookup_full_ready &&
            (kv_lookup_sram_id == EXP_SRAM_ID) &&
            (kv_lookup_bank_id == EXP_BANK_ID) &&
            (kv_lookup_subbank_start == EXP_SUBBANK_START) &&
            (kv_lookup_group_len == EXP_GROUP_LEN)) begin
            partial_lookup_seen_r <= 1'b1;
        end

        if (kv_lookup_valid && kv_lookup_ready &&
            kv_lookup_hit &&
            kv_lookup_partial_ready &&
            kv_lookup_full_ready &&
            (kv_lookup_sram_id == EXP_SRAM_ID) &&
            (kv_lookup_bank_id == EXP_BANK_ID) &&
            (kv_lookup_subbank_start == EXP_SUBBANK_START) &&
            (kv_lookup_group_len == EXP_GROUP_LEN)) begin
            full_lookup_seen_r <= 1'b1;
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

    wb_ready = 1'b1;
    recompute_req_ready = 1'b1;
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

    drive_candidate_window_once();

    cycle_count = 0;
    while (!pred_selected_seen_r && (cycle_count < 8)) begin
        @(posedge clk);
        #1;
        cycle_count = cycle_count + 1;
    end
    if (!pred_selected_seen_r) begin
        $fatal(1, "prediction-to-tree handshake was not observed");
    end

    cycle_count = 0;
    while (!recompute_req_seen_r && (cycle_count < 12)) begin
        @(posedge clk);
        #1;
        cycle_count = cycle_count + 1;
    end
    if (!recompute_req_seen_r) begin
        $fatal(1, "recompute request handshake was not observed");
    end
    if (!stale_seen_r) begin
        $fatal(1, "stale hit was not observed");
    end
    if (!debug_recompute_busy) begin
        $fatal(1, "recompute control did not enter busy");
    end

    cycle_count = 0;
    while (!recompute_resp_ready && (cycle_count < 8)) begin
        @(posedge clk);
        #1;
        cycle_count = cycle_count + 1;
    end
    if (!recompute_resp_ready) begin
        $fatal(1, "recompute response channel was not ready for partial");
    end

    send_partial_kv_response_once();

    cycle_count = 0;
    while (!partial_write_seen_r && (cycle_count < 16)) begin
        @(posedge clk);
        #1;
        cycle_count = cycle_count + 1;
    end
    if (!partial_write_seen_r) begin
        $fatal(1, "partial KV SRAM write was not observed");
    end

    query_kv_tables_once();
    if (!partial_lookup_seen_r) begin
        $fatal(1, "KV table lookup did not return partial-ready state");
    end

    cycle_count = 0;
    while (!issue_seen_r && (cycle_count < 12)) begin
        @(posedge clk);
        #1;
        cycle_count = cycle_count + 1;
    end
    if (!issue_seen_r) begin
        $fatal(1, "tree issue metadata did not match partial-ready token");
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
    if (!transform_read_seen_r) begin
        $fatal(1, "transform read request was not observed");
    end
    if (!wb_partial_payload_seen_r) begin
        $fatal(1, "writeback payload did not reflect partial KV data");
    end
    if (tree_busy !== 1'b1) begin
        $fatal(1, "tree control should still wait for full KV after writeback");
    end
    if (full_done_seen_r) begin
        $fatal(1, "full recompute completion should not happen before full response");
    end

    cycle_count = 0;
    while (!recompute_resp_ready && (cycle_count < 8)) begin
        @(posedge clk);
        #1;
        cycle_count = cycle_count + 1;
    end
    if (!recompute_resp_ready) begin
        $fatal(1, "recompute response channel was not ready for full");
    end

    send_full_kv_response_once();

    cycle_count = 0;
    while ((!full_done_seen_r || !full_write_seen_r) &&
           (cycle_count < 16)) begin
        @(posedge clk);
        #1;
        cycle_count = cycle_count + 1;
    end
    if (!full_done_seen_r) begin
        $fatal(1, "full recompute completion was not observed");
    end
    if (!full_write_seen_r) begin
        $fatal(1, "full KV SRAM write was not observed");
    end

    query_kv_tables_once();
    if (!full_lookup_seen_r) begin
        $fatal(1, "KV table lookup did not return full-ready state");
    end

    @(posedge clk);
    #1;

    if (tree_busy !== 1'b0) begin
        $fatal(1, "tree control did not return to idle after full KV");
    end
    if (tree_error_flag !== 1'b0) begin
        $fatal(1, "tree control error flag should stay low");
    end

    $display("tb_control_chip_stage2_recompute_partialkv_min PASS");
    $finish;
end

endmodule
