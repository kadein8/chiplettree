`timescale 1ns/1ps

`include "config/prediction_params.vh"
`include "config/interface_params.vh"
`include "config/memory_params.vh"

module tb_control_chip_stage2_single_chiplet_onchip_hht_context_predictor_min;

localparam integer DRAFT_PORTS = 4;
localparam integer CONF_W = 8;
localparam integer CFG_W = 32;
localparam integer RESULT_STATUS_W = 2;
localparam integer WINDOW_SLOTS = `TREE_FRONTIER_SLOTS;
localparam integer SOURCE_ID_W =
    ((DRAFT_PORTS + 1) <= 2) ? 1 : $clog2(DRAFT_PORTS + 1);
localparam [RESULT_STATUS_W-1:0] STATUS_OK = 2'b00;
localparam [`POSITION_ID_W-1:0] CURRENT_POSITION = 12'h040;
localparam [`POSITION_ID_W-1:0] RECENCY_TH = 12'h010;

localparam [SOURCE_ID_W-1:0] HHT_SOURCE_ID = {SOURCE_ID_W{1'b0}};
localparam [SOURCE_ID_W-1:0] DRAFT_SOURCE_ID = 3'd2;
localparam [`NODE_ID_W-1:0] WINDOW_PARENT_NODE_ID = 4'd5;

localparam [`TOKEN_ID_W-1:0] BOOT_REF_TOKEN_ID = 16'h7000;
localparam [`POSITION_ID_W-1:0] BOOT_REF_POS = 12'h03b;
localparam [`TOKEN_ID_W-1:0] TOKEN_A = 16'ha001;
localparam [`TOKEN_ID_W-1:0] TOKEN_B = 16'hb002;
localparam [`TOKEN_ID_W-1:0] TOKEN_C = 16'hc003;
localparam [`TOKEN_ID_W-1:0] TOKEN_D = 16'hd004;
localparam [`POSITION_ID_W-1:0] POS_A = 12'h03c;
localparam [`POSITION_ID_W-1:0] POS_B = 12'h03d;
localparam [`POSITION_ID_W-1:0] POS_C = 12'h03e;
localparam [`POSITION_ID_W-1:0] POS_D = 12'h03e;
localparam [CONF_W-1:0] DRAFT_CONF = 8'd200;
localparam [CONF_W-1:0] STRONG_DRAFT_CONF = 8'd220;
localparam [CONF_W-1:0] HHT_CONF_PHASE1 = 8'd1;
localparam [CONF_W-1:0] HHT_CONF_PHASE2 = 8'd2;
localparam [CONF_W-1:0] HHT_CONF_PHASE3 = 8'd1;

localparam [`SRAM_ADDR_W-1:0] EXP_SRC_ADDR =
    {2'd0, 4'd2, 5'd6, 8'h00, 4'h0};
localparam [`SRAM_ADDR_W-1:0] EXP_DST_ADDR =
    {2'd0, 4'd1, 5'd4, 8'h03, 4'h0};
localparam [`SRAM_WDATA_W-1:0] EXP_FULL_KV_DATA = {
    {(`SRAM_WDATA_W-32){1'b0}},
    16'h4000,
    16'h3c00
};
localparam [`SRAM_WDATA_W-1:0] EXP_FULL_WB_DATA = {
    {(`SRAM_WDATA_W-16){1'b0}},
    16'h4000
};
localparam [`SRAM_ID_W-1:0] EXP_SRAM_ID =
    EXP_SRC_ADDR[(`OFFSET_W + `ROW_ADDR_W + `SUBBANK_ID_W + `BANK_ID_W) +:
                 `SRAM_ID_W];
localparam [`BANK_ID_W-1:0] EXP_BANK_ID =
    EXP_SRC_ADDR[(`OFFSET_W + `ROW_ADDR_W + `SUBBANK_ID_W) +: `BANK_ID_W];
localparam integer EXP_SRC_BANK_IDX =
    (EXP_SRAM_ID * `SRAM_BANK_NUM) + EXP_BANK_ID;
localparam [`SUBBANK_ID_W-1:0] EXP_SUBBANK_START =
    EXP_SRC_ADDR[(`OFFSET_W + `ROW_ADDR_W) +: `SUBBANK_ID_W];
localparam integer EXP_SRC_SUBBANK_IDX = EXP_SUBBANK_START;
localparam integer EXP_SRC_BASE_ADDR =
    ((EXP_SRC_ADDR[`OFFSET_W +: `ROW_ADDR_W]) << `OFFSET_W) +
    EXP_SRC_ADDR[`OFFSET_W-1:0];
localparam integer SRAM_BEAT_BYTES = (`SRAM_WDATA_W / 8);

reg clk;
reg rst_n;

reg cfg_valid;
reg [CFG_W-1:0] cfg_data;
reg start;
wire busy;
wire error_flag;

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

wire tree_window_valid;
reg tree_window_ready;
wire [`NODE_ID_W-1:0] tree_window_parent_node_id;
wire [WINDOW_SLOTS-1:0] tree_window_slot_valid;
wire [WINDOW_SLOTS*SOURCE_ID_W-1:0] tree_window_source_id;
wire [WINDOW_SLOTS*`TOKEN_ID_W-1:0] tree_window_token_id;
wire [WINDOW_SLOTS*`TOKEN_ID_W-1:0] tree_window_referenced_token_id;
wire [WINDOW_SLOTS*`POSITION_ID_W-1:0] tree_window_referenced_position;
wire [WINDOW_SLOTS*CONF_W-1:0] tree_window_confidence;

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

wire wb_valid;
reg wb_ready;
wire [`TOKEN_ID_W-1:0] wb_token_id;
wire [`SRAM_ADDR_W-1:0] wb_addr;
wire [`SRAM_WDATA_W-1:0] wb_data;
wire [RESULT_STATUS_W-1:0] wb_status;
wire wb_done;
wire wb_error;

wire debug_stale_hit;
wire debug_recompute_busy;
wire debug_recompute_done;
wire debug_decoder_qkv_valid;
wire debug_decoder_score_valid;
wire debug_decoder_softmax_valid;
wire debug_decoder_value_valid;
wire debug_decoder_ffn_valid;

reg hbm_resp_valid;
reg [`HBM_DATA_W-1:0] hbm_resp_rdata;
reg [`REQ_ID_W-1:0] hbm_resp_id;
wire hbm_req_valid;
wire hbm_req_write;
wire [`HBM_ADDR_W-1:0] hbm_req_addr;
wire [`HBM_DATA_W-1:0] hbm_req_wdata;
wire [`REQ_ID_W-1:0] hbm_req_id;

integer recompute_req_count_r;
integer wb_payload_count_r;
integer wb_done_total_count_r;
integer wb_token_a_done_count_r;
integer wb_token_b_done_count_r;
integer wb_token_c_done_count_r;
integer wb_token_d_done_count_r;
integer decoder_qkv_count_r;
integer decoder_score_count_r;
integer decoder_softmax_count_r;
integer decoder_value_count_r;
integer decoder_ffn_count_r;
reg [`TOKEN_ID_W-1:0] last_wb_done_token_r;
reg [`TOKEN_ID_W-1:0] last_wb_payload_token_r;

control_chip_stage2_single_chiplet #(
    .CFG_W(CFG_W),
    .DRAFT_PORTS(DRAFT_PORTS),
    .CONF_W(CONF_W),
    .RESULT_STATUS_W(RESULT_STATUS_W),
    .ENABLE_ONCHIP_HHT_CONTEXT(1),
    .CURRENT_POSITION(CURRENT_POSITION),
    .RECENCY_TH(RECENCY_TH),
    .ISSUE_SRC_ADDR(EXP_SRC_ADDR),
    .ISSUE_DST_ADDR(EXP_DST_ADDR)
) u_control_chip_stage2_single_chiplet (
    .clk(clk),
    .rst_n(rst_n),
    .cfg_valid(cfg_valid),
    .cfg_data(cfg_data),
    .start(start),
    .busy(busy),
    .error_flag(error_flag),
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
    .tree_window_valid(tree_window_valid),
    .tree_window_ready(tree_window_ready),
    .tree_window_parent_node_id(tree_window_parent_node_id),
    .tree_window_slot_valid(tree_window_slot_valid),
    .tree_window_source_id(tree_window_source_id),
    .tree_window_token_id(tree_window_token_id),
    .tree_window_referenced_token_id(tree_window_referenced_token_id),
    .tree_window_referenced_position(tree_window_referenced_position),
    .tree_window_confidence(tree_window_confidence),
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
    .wb_valid(wb_valid),
    .wb_ready(wb_ready),
    .wb_token_id(wb_token_id),
    .wb_addr(wb_addr),
    .wb_data(wb_data),
    .wb_status(wb_status),
    .wb_done(wb_done),
    .wb_error(wb_error),
    .debug_stale_hit(debug_stale_hit),
    .debug_recompute_busy(debug_recompute_busy),
    .debug_recompute_done(debug_recompute_done),
    .debug_decoder_qkv_valid(debug_decoder_qkv_valid),
    .debug_decoder_score_valid(debug_decoder_score_valid),
    .debug_decoder_softmax_valid(debug_decoder_softmax_valid),
    .debug_decoder_value_valid(debug_decoder_value_valid),
    .debug_decoder_ffn_valid(debug_decoder_ffn_valid),
    .hbm_resp_valid(hbm_resp_valid),
    .hbm_resp_rdata(hbm_resp_rdata),
    .hbm_resp_id(hbm_resp_id),
    .hbm_req_valid(hbm_req_valid),
    .hbm_req_write(hbm_req_write),
    .hbm_req_addr(hbm_req_addr),
    .hbm_req_wdata(hbm_req_wdata),
    .hbm_req_id(hbm_req_id)
);

always #5 clk = ~clk;

task clear_inputs;
    begin
        cfg_valid = 1'b0;
        cfg_data = {CFG_W{1'b0}};
        start = 1'b0;
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
        tree_window_ready = 1'b0;
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
        wb_ready = 1'b0;
        hbm_resp_valid = 1'b0;
        hbm_resp_rdata = {`HBM_DATA_W{1'b0}};
        hbm_resp_id = {`REQ_ID_W{1'b0}};
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

task wait_for_busy_high;
    integer cycle_count;
    begin
        cycle_count = 0;
        while ((busy !== 1'b1) && (cycle_count < 16)) begin
            @(posedge clk);
            #1;
            cycle_count = cycle_count + 1;
        end
        if (busy !== 1'b1) begin
            $fatal(1, "24 top did not enter busy");
        end
    end
endtask

task wait_for_idle_low;
    integer cycle_count;
    begin
        cycle_count = 0;
        while ((busy !== 1'b0) && (cycle_count < 24)) begin
            @(posedge clk);
            #1;
            cycle_count = cycle_count + 1;
        end
        if (busy !== 1'b0) begin
            $fatal(1, "24 top did not return to idle");
        end
    end
endtask

task drive_single_draft_candidate_once;
    input [`TOKEN_ID_W-1:0] token_id_i;
    input [`TOKEN_ID_W-1:0] referenced_token_id_i;
    input [`POSITION_ID_W-1:0] referenced_position_i;
    input [CONF_W-1:0] confidence_i;
    begin
        hht_cand_valid = 1'b0;
        draft_cand_valid = 4'b0010;
        draft_parent_node_id = {(DRAFT_PORTS*`NODE_ID_W){1'b0}};
        draft_token_id = {(DRAFT_PORTS*`TOKEN_ID_W){1'b0}};
        draft_referenced_token_id = {(DRAFT_PORTS*`TOKEN_ID_W){1'b0}};
        draft_referenced_position = {(DRAFT_PORTS*`POSITION_ID_W){1'b0}};
        draft_confidence = {(DRAFT_PORTS*CONF_W){1'b0}};

        draft_parent_node_id[(1*`NODE_ID_W) +: `NODE_ID_W] =
            WINDOW_PARENT_NODE_ID;
        draft_token_id[(1*`TOKEN_ID_W) +: `TOKEN_ID_W] = token_id_i;
        draft_referenced_token_id[(1*`TOKEN_ID_W) +: `TOKEN_ID_W] =
            referenced_token_id_i;
        draft_referenced_position[(1*`POSITION_ID_W) +: `POSITION_ID_W] =
            referenced_position_i;
        draft_confidence[(1*CONF_W) +: CONF_W] = confidence_i;

        @(posedge clk);
        #1;
        draft_cand_valid = {DRAFT_PORTS{1'b0}};
    end
endtask

task check_window_slot;
    input integer slot_idx;
    input expected_valid_i;
    input [SOURCE_ID_W-1:0] expected_source_id_i;
    input [`TOKEN_ID_W-1:0] expected_token_id_i;
    input [`TOKEN_ID_W-1:0] expected_referenced_token_id_i;
    input [`POSITION_ID_W-1:0] expected_referenced_position_i;
    input [CONF_W-1:0] expected_confidence_i;
    begin
        if (tree_window_slot_valid[slot_idx] !== expected_valid_i) begin
            $fatal(1, "24 tree window slot valid mismatch");
        end
        if (expected_valid_i) begin
            if ((tree_window_source_id[(slot_idx*SOURCE_ID_W) +: SOURCE_ID_W] !=
                 expected_source_id_i) ||
                (tree_window_token_id[(slot_idx*`TOKEN_ID_W) +: `TOKEN_ID_W] !=
                 expected_token_id_i) ||
                (tree_window_referenced_token_id[
                    (slot_idx*`TOKEN_ID_W) +: `TOKEN_ID_W] !=
                 expected_referenced_token_id_i) ||
                (tree_window_referenced_position[
                    (slot_idx*`POSITION_ID_W) +: `POSITION_ID_W] !=
                 expected_referenced_position_i) ||
                (tree_window_confidence[(slot_idx*CONF_W) +: CONF_W] !=
                 expected_confidence_i)) begin
                $fatal(1, "24 tree window slot payload mismatch");
            end
        end
    end
endtask

task wait_for_window_slot0;
    input [SOURCE_ID_W-1:0] expected_source_id_i;
    input [`TOKEN_ID_W-1:0] expected_token_id_i;
    input [`TOKEN_ID_W-1:0] expected_referenced_token_id_i;
    input [`POSITION_ID_W-1:0] expected_referenced_position_i;
    input [CONF_W-1:0] expected_confidence_i;
    input exact_single_i;
    integer cycle_count;
    begin
        cycle_count = 0;
        while ((tree_window_valid !== 1'b1) && (cycle_count < 24)) begin
            @(posedge clk);
            #1;
            cycle_count = cycle_count + 1;
        end
        if (tree_window_valid !== 1'b1) begin
            $fatal(1, "24 tree window was not observed");
        end
        if (tree_window_parent_node_id != WINDOW_PARENT_NODE_ID) begin
            $fatal(1, "24 tree window parent mismatch");
        end
        check_window_slot(0, 1'b1, expected_source_id_i, expected_token_id_i,
                          expected_referenced_token_id_i,
                          expected_referenced_position_i,
                          expected_confidence_i);
        if (exact_single_i) begin
            if (tree_window_slot_valid != 4'b0001) begin
                $fatal(1, "24 expected exactly one tree window slot");
            end
            check_window_slot(1, 1'b0, {SOURCE_ID_W{1'b0}},
                              {`TOKEN_ID_W{1'b0}},
                              {`TOKEN_ID_W{1'b0}},
                              {`POSITION_ID_W{1'b0}},
                              {CONF_W{1'b0}});
            check_window_slot(2, 1'b0, {SOURCE_ID_W{1'b0}},
                              {`TOKEN_ID_W{1'b0}},
                              {`TOKEN_ID_W{1'b0}},
                              {`POSITION_ID_W{1'b0}},
                              {CONF_W{1'b0}});
            check_window_slot(3, 1'b0, {SOURCE_ID_W{1'b0}},
                              {`TOKEN_ID_W{1'b0}},
                              {`TOKEN_ID_W{1'b0}},
                              {`POSITION_ID_W{1'b0}},
                              {CONF_W{1'b0}});
        end
    end
endtask

task wait_for_window_mismatch;
    integer cycle_count;
    begin
        cycle_count = 0;
        while ((tree_window_valid !== 1'b1) && (cycle_count < 24)) begin
            @(posedge clk);
            #1;
            cycle_count = cycle_count + 1;
        end
        if (tree_window_valid !== 1'b1) begin
            $fatal(1, "24 mismatch tree window was not observed");
        end
        if (tree_window_parent_node_id != WINDOW_PARENT_NODE_ID) begin
            $fatal(1, "24 mismatch tree window parent mismatch");
        end
        if (tree_window_slot_valid != 4'b0011) begin
            $fatal(1, "24 mismatch tree window slot mask mismatch");
        end
        check_window_slot(0, 1'b1, DRAFT_SOURCE_ID, TOKEN_D, TOKEN_B,
                          POS_B, STRONG_DRAFT_CONF);
        check_window_slot(1, 1'b1, HHT_SOURCE_ID, TOKEN_C, TOKEN_B,
                          POS_B, HHT_CONF_PHASE2);
        check_window_slot(2, 1'b0, {SOURCE_ID_W{1'b0}},
                          {`TOKEN_ID_W{1'b0}},
                          {`TOKEN_ID_W{1'b0}},
                          {`POSITION_ID_W{1'b0}},
                          {CONF_W{1'b0}});
        check_window_slot(3, 1'b0, {SOURCE_ID_W{1'b0}},
                          {`TOKEN_ID_W{1'b0}},
                          {`TOKEN_ID_W{1'b0}},
                          {`POSITION_ID_W{1'b0}},
                          {CONF_W{1'b0}});
    end
endtask

task consume_tree_window_once;
    begin
        tree_window_ready = 1'b1;
        @(posedge clk);
        #1;
        tree_window_ready = 1'b0;
    end
endtask

task wait_for_next_wb_done;
    input [`TOKEN_ID_W-1:0] expected_token_id_i;
    integer cycle_count;
    integer expected_total;
    begin
        expected_total = wb_done_total_count_r + 1;
        cycle_count = 0;
        while ((wb_done_total_count_r < expected_total) && (cycle_count < 96)) begin
            @(posedge clk);
            #1;
            cycle_count = cycle_count + 1;
        end
        if (wb_done_total_count_r != expected_total) begin
            $fatal(1, "24 wb_done was not observed");
        end
        if (last_wb_done_token_r != expected_token_id_i) begin
            $fatal(1, "24 wb_done token mismatch");
        end
        if (wb_payload_count_r < expected_total) begin
            $fatal(1, "24 writeback payload was not observed");
        end
        if (last_wb_payload_token_r != expected_token_id_i) begin
            $fatal(1, "24 writeback payload token mismatch");
        end
    end
endtask

task run_draft_accept_once;
    input [`TOKEN_ID_W-1:0] token_id_i;
    input [`TOKEN_ID_W-1:0] referenced_token_id_i;
    input [`POSITION_ID_W-1:0] referenced_position_i;
    input [CONF_W-1:0] confidence_i;
    input exact_single_i;
    begin
        start_tree_once();
        wait_for_busy_high();
        drive_single_draft_candidate_once(token_id_i, referenced_token_id_i,
                                          referenced_position_i, confidence_i);
        wait_for_window_slot0(DRAFT_SOURCE_ID, token_id_i,
                              referenced_token_id_i,
                              referenced_position_i,
                              confidence_i,
                              exact_single_i);
        consume_tree_window_once();
        wait_for_next_wb_done(token_id_i);
        wait_for_idle_low();
    end
endtask

task run_hht_accept_once;
    input [`TOKEN_ID_W-1:0] token_id_i;
    input [`TOKEN_ID_W-1:0] referenced_token_id_i;
    input [`POSITION_ID_W-1:0] referenced_position_i;
    input [CONF_W-1:0] confidence_i;
    begin
        start_tree_once();
        wait_for_busy_high();
        wait_for_window_slot0(HHT_SOURCE_ID, token_id_i,
                              referenced_token_id_i,
                              referenced_position_i,
                              confidence_i,
                              1'b1);
        consume_tree_window_once();
        wait_for_next_wb_done(token_id_i);
        wait_for_idle_low();
    end
endtask

task run_mismatch_accept_once;
    begin
        start_tree_once();
        wait_for_busy_high();
        drive_single_draft_candidate_once(TOKEN_D, TOKEN_B, POS_B,
                                          STRONG_DRAFT_CONF);
        wait_for_window_mismatch();
        consume_tree_window_once();
        wait_for_next_wb_done(TOKEN_D);
        wait_for_idle_low();
    end
endtask

task preload_src_full_kv_once;
    integer preload_byte_idx;
    begin
        for (preload_byte_idx = 0;
             preload_byte_idx < SRAM_BEAT_BYTES;
             preload_byte_idx = preload_byte_idx + 1) begin
            u_control_chip_stage2_single_chiplet
                .u_sram_subsystem.gen_banks[EXP_SRC_BANK_IDX]
                .u_sram_bank.gen_subbanks[EXP_SRC_SUBBANK_IDX]
                .u_sram_subbank.storage_bytes[EXP_SRC_BASE_ADDR + preload_byte_idx] =
                    EXP_FULL_KV_DATA[(preload_byte_idx*8) +: 8];
        end

        for (preload_byte_idx = 0;
             preload_byte_idx < SRAM_BEAT_BYTES;
             preload_byte_idx = preload_byte_idx + 1) begin
            if (u_control_chip_stage2_single_chiplet
                    .u_sram_subsystem.gen_banks[EXP_SRC_BANK_IDX]
                    .u_sram_bank.gen_subbanks[EXP_SRC_SUBBANK_IDX]
                    .u_sram_subbank.storage_bytes[EXP_SRC_BASE_ADDR + preload_byte_idx] !==
                EXP_FULL_KV_DATA[(preload_byte_idx*8) +: 8]) begin
                $fatal(1, "24 source SRAM preload mismatch");
            end
        end
    end
endtask

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        recompute_req_count_r <= 0;
        wb_payload_count_r <= 0;
        wb_done_total_count_r <= 0;
        wb_token_a_done_count_r <= 0;
        wb_token_b_done_count_r <= 0;
        wb_token_c_done_count_r <= 0;
        wb_token_d_done_count_r <= 0;
        decoder_qkv_count_r <= 0;
        decoder_score_count_r <= 0;
        decoder_softmax_count_r <= 0;
        decoder_value_count_r <= 0;
        decoder_ffn_count_r <= 0;
        last_wb_done_token_r <= {`TOKEN_ID_W{1'b0}};
        last_wb_payload_token_r <= {`TOKEN_ID_W{1'b0}};
    end else begin
        if (recompute_req_valid && recompute_req_ready) begin
            recompute_req_count_r <= recompute_req_count_r + 1;
        end

        if (wb_valid) begin
            if ((wb_addr != EXP_DST_ADDR) ||
                (wb_data != EXP_FULL_WB_DATA) ||
                (wb_status != STATUS_OK)) begin
                $fatal(1, "24 writeback payload mismatch");
            end
            wb_payload_count_r <= wb_payload_count_r + 1;
            last_wb_payload_token_r <= wb_token_id;
        end

        if (wb_done) begin
            wb_done_total_count_r <= wb_done_total_count_r + 1;
            last_wb_done_token_r <= wb_token_id;
            if (wb_token_id == TOKEN_A) begin
                wb_token_a_done_count_r <= wb_token_a_done_count_r + 1;
            end else if (wb_token_id == TOKEN_B) begin
                wb_token_b_done_count_r <= wb_token_b_done_count_r + 1;
            end else if (wb_token_id == TOKEN_C) begin
                wb_token_c_done_count_r <= wb_token_c_done_count_r + 1;
            end else if (wb_token_id == TOKEN_D) begin
                wb_token_d_done_count_r <= wb_token_d_done_count_r + 1;
            end else begin
                $fatal(1, "24 unexpected wb_done token");
            end
        end

        if (debug_decoder_qkv_valid) begin
            decoder_qkv_count_r <= decoder_qkv_count_r + 1;
        end
        if (debug_decoder_score_valid) begin
            decoder_score_count_r <= decoder_score_count_r + 1;
        end
        if (debug_decoder_softmax_valid) begin
            decoder_softmax_count_r <= decoder_softmax_count_r + 1;
        end
        if (debug_decoder_value_valid) begin
            decoder_value_count_r <= decoder_value_count_r + 1;
        end
        if (debug_decoder_ffn_valid) begin
            decoder_ffn_count_r <= decoder_ffn_count_r + 1;
        end
    end
end

initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    clear_inputs();

    repeat (3) @(posedge clk);
    rst_n = 1'b1;
    @(posedge clk);
    #1;
    preload_src_full_kv_once();
    wb_ready = 1'b1;
    recompute_req_ready = 1'b1;

    run_draft_accept_once(TOKEN_A, BOOT_REF_TOKEN_ID, BOOT_REF_POS,
                          DRAFT_CONF, 1'b1);
    run_draft_accept_once(TOKEN_B, TOKEN_A, POS_A, DRAFT_CONF, 1'b1);
    run_draft_accept_once(TOKEN_C, TOKEN_B, POS_B, DRAFT_CONF, 1'b1);

    run_draft_accept_once(TOKEN_A, BOOT_REF_TOKEN_ID, BOOT_REF_POS,
                          DRAFT_CONF, 1'b0);
    run_draft_accept_once(TOKEN_B, TOKEN_A, POS_A, DRAFT_CONF, 1'b0);
    run_hht_accept_once(TOKEN_C, TOKEN_B, POS_B, HHT_CONF_PHASE1);

    run_draft_accept_once(TOKEN_A, BOOT_REF_TOKEN_ID, BOOT_REF_POS,
                          DRAFT_CONF, 1'b0);
    run_draft_accept_once(TOKEN_B, TOKEN_A, POS_A, DRAFT_CONF, 1'b0);
    run_mismatch_accept_once();

    run_draft_accept_once(TOKEN_A, BOOT_REF_TOKEN_ID, BOOT_REF_POS,
                          DRAFT_CONF, 1'b0);
    run_draft_accept_once(TOKEN_B, TOKEN_A, POS_A, DRAFT_CONF, 1'b0);
    run_hht_accept_once(TOKEN_D, TOKEN_B, POS_B, HHT_CONF_PHASE3);

    if (recompute_req_count_r != 0) begin
        $fatal(1, "24 non-stale path should not emit recompute request");
    end
    if (wb_payload_count_r != 12) begin
        $fatal(1, "24 should emit exactly twelve writeback payloads");
    end
    if (wb_done_total_count_r != 12) begin
        $fatal(1, "24 should complete exactly twelve writebacks");
    end
    if (wb_token_a_done_count_r != 4) begin
        $fatal(1, "24 token A wb_done count mismatch");
    end
    if (wb_token_b_done_count_r != 4) begin
        $fatal(1, "24 token B wb_done count mismatch");
    end
    if (wb_token_c_done_count_r != 2) begin
        $fatal(1, "24 token C wb_done count mismatch");
    end
    if (wb_token_d_done_count_r != 2) begin
        $fatal(1, "24 token D wb_done count mismatch");
    end
    if (decoder_qkv_count_r < 12) begin
        $fatal(1, "24 decoder qkv stage should be observed at least twelve times");
    end
    if (decoder_score_count_r < 12) begin
        $fatal(1, "24 decoder score stage should be observed at least twelve times");
    end
    if (decoder_softmax_count_r < 12) begin
        $fatal(1, "24 decoder softmax stage should be observed at least twelve times");
    end
    if (decoder_value_count_r < 12) begin
        $fatal(1, "24 decoder value stage should be observed at least twelve times");
    end
    if (decoder_ffn_count_r < 12) begin
        $fatal(1, "24 decoder ffn stage should be observed at least twelve times");
    end
    if (error_flag !== 1'b0) begin
        $fatal(1, "24 top error flag should stay low");
    end
    if (wb_error !== 1'b0) begin
        $fatal(1, "24 writeback error should stay low");
    end
    if (debug_stale_hit !== 1'b0) begin
        $fatal(1, "24 non-stale path should not assert stale hit");
    end
    if (debug_recompute_busy !== 1'b0) begin
        $fatal(1, "24 non-stale path should not enter recompute busy");
    end
    if (debug_recompute_done !== 1'b0) begin
        $fatal(1, "24 non-stale path should not emit recompute done");
    end
    if (hbm_req_valid !== 1'b0) begin
        $fatal(1, "24 minimal path should not issue HBM request");
    end
    if (hbm_req_write !== 1'b0) begin
        $fatal(1, "24 minimal path HBM write flag should stay low");
    end
    if (hbm_req_addr != {`HBM_ADDR_W{1'b0}}) begin
        $fatal(1, "24 minimal path HBM address should stay zero");
    end
    if (hbm_req_wdata != {`HBM_DATA_W{1'b0}}) begin
        $fatal(1, "24 minimal path HBM data should stay zero");
    end
    if (hbm_req_id != {`REQ_ID_W{1'b0}}) begin
        $fatal(1, "24 minimal path HBM id should stay zero");
    end

    $display("tb_control_chip_stage2_single_chiplet_onchip_hht_context_predictor_min PASS");
    $finish;
end

endmodule
