`timescale 1ns/1ps

`include "config/prediction_params.vh"
`include "config/interface_params.vh"
`include "config/memory_params.vh"

module tb_control_chip_stage2_single_chiplet_strongest_bounded_window_hht_feedback_top_min #(
    parameter integer ENABLE_FINAL_FINISH = 1
) ();

localparam integer DRAFT_PORTS = 4;
localparam integer CONF_W = 8;
localparam integer CFG_W = 32;
localparam integer RESULT_STATUS_W = 2;
localparam integer WINDOW_SLOTS = `TREE_FRONTIER_SLOTS;
localparam integer SOURCE_ID_W =
    ((DRAFT_PORTS + 1) <= 2) ? 1 : $clog2(DRAFT_PORTS + 1);
localparam integer HHT_ENTRY_NUM = 4;
localparam integer HHT_HIT_COUNT_W = 8;
localparam integer HHT_LRU_W = 16;
localparam [RESULT_STATUS_W-1:0] STATUS_OK = 2'b00;
localparam [`POSITION_ID_W-1:0] CURRENT_POSITION = 12'h040;
localparam [`POSITION_ID_W-1:0] RECENCY_TH = 12'h010;

localparam [`NODE_ID_W-1:0] WINDOW_PARENT_NODE_ID = 4'd5;

localparam [SOURCE_ID_W-1:0] PHASE0_SOURCE_ID = 3'd2;
localparam [`TOKEN_ID_W-1:0] PHASE0_TOKEN_ID = 16'hea11;
localparam [`TOKEN_ID_W-1:0] PHASE0_REF_TOKEN_ID = 16'h8a10;
localparam [`POSITION_ID_W-1:0] PHASE0_REF_POS = 12'h03d;
localparam [CONF_W-1:0] PHASE0_CONF = 8'd200;

localparam [SOURCE_ID_W-1:0] PHASE1_SLOT0_SOURCE_ID = 3'd4;
localparam [`TOKEN_ID_W-1:0] PHASE1_SLOT0_TOKEN_ID = 16'hdb31;
localparam [`TOKEN_ID_W-1:0] PHASE1_SLOT0_REF_TOKEN_ID = 16'h9b30;
localparam [`POSITION_ID_W-1:0] PHASE1_SLOT0_REF_POS = 12'h03f;
localparam [CONF_W-1:0] PHASE1_SLOT0_CONF = 8'd250;

localparam [SOURCE_ID_W-1:0] PHASE1_SLOT1_SOURCE_ID = {SOURCE_ID_W{1'b0}};
localparam [`TOKEN_ID_W-1:0] PHASE1_SLOT1_TOKEN_ID = PHASE0_TOKEN_ID;
localparam [`TOKEN_ID_W-1:0] PHASE1_SLOT1_REF_TOKEN_ID = PHASE0_REF_TOKEN_ID;
localparam [`POSITION_ID_W-1:0] PHASE1_SLOT1_REF_POS = PHASE0_REF_POS;
localparam [CONF_W-1:0] PHASE1_SLOT1_CONF = 8'd230;

localparam [SOURCE_ID_W-1:0] PHASE1_SLOT2_SOURCE_ID = 3'd1;
localparam [`TOKEN_ID_W-1:0] PHASE1_SLOT2_TOKEN_ID = 16'hdc11;
localparam [`TOKEN_ID_W-1:0] PHASE1_SLOT2_REF_TOKEN_ID = 16'h6c10;
localparam [`POSITION_ID_W-1:0] PHASE1_SLOT2_REF_POS = 12'h020;
localparam [CONF_W-1:0] PHASE1_SLOT2_CONF = 8'd220;

localparam [SOURCE_ID_W-1:0] PHASE1_SLOT3_SOURCE_ID = 3'd3;
localparam [`TOKEN_ID_W-1:0] PHASE1_SLOT3_TOKEN_ID = 16'hdd21;
localparam [`TOKEN_ID_W-1:0] PHASE1_SLOT3_REF_TOKEN_ID =
    PHASE1_SLOT2_REF_TOKEN_ID;
localparam [`POSITION_ID_W-1:0] PHASE1_SLOT3_REF_POS =
    PHASE1_SLOT2_REF_POS;
localparam [CONF_W-1:0] PHASE1_SLOT3_CONF = 8'd210;

localparam [`SRAM_ADDR_W-1:0] EXP_SRC_ADDR =
    {2'd0, 4'd2, 5'd6, 8'h00, 4'h0};
localparam [`SRAM_ADDR_W-1:0] EXP_DST_ADDR =
    {2'd0, 4'd1, 5'd4, 8'h03, 4'h0};
localparam [`REQ_ID_W-1:0] EXP_RECOMPUTE_RESP_ID = 4'h9;
localparam [`SRAM_WDATA_W-1:0] EXP_PARTIAL_KV_DATA = {
    {(`SRAM_WDATA_W-32){1'b0}},
    16'h3c00,
    16'h3c00
};
localparam [`SRAM_WDATA_W-1:0] EXP_FULL_KV_DATA = {
    {(`SRAM_WDATA_W-32){1'b0}},
    16'h4000,
    16'h3c00
};
localparam [`SRAM_WDATA_W-1:0] EXP_PARTIAL_WB_DATA = {
    {(`SRAM_WDATA_W-16){1'b0}},
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
localparam [`SUBBANK_ID_W-1:0] EXP_SUBBANK_START =
    EXP_SRC_ADDR[(`OFFSET_W + `ROW_ADDR_W) +: `SUBBANK_ID_W];
localparam [`KV_GROUP_LEN_W-1:0] EXP_GROUP_LEN = `KV_GROUP_SIZE_SUBBANK;
localparam integer SRAM_BEAT_BYTES = (`SRAM_WDATA_W / 8);
localparam integer EXP_SRC_BANK_IDX =
    (EXP_SRAM_ID * `SRAM_BANK_NUM) + EXP_BANK_ID;
localparam integer EXP_SRC_SUBBANK_IDX = EXP_SUBBANK_START;
localparam integer EXP_SRC_BASE_ADDR =
    ((EXP_SRC_ADDR[`OFFSET_W +: `ROW_ADDR_W]) << `OFFSET_W) +
    EXP_SRC_ADDR[`OFFSET_W-1:0];

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

reg tree_window_phase0_seen_r;
reg tree_window_phase1_seen_r;
integer recompute_req_count_phase0_r;
integer recompute_req_count_slot0_r;
integer recompute_req_count_slot2_r;
integer recompute_req_count_slot3_r;
integer recompute_done_count_r;
reg kv_partial_seen_r;
reg kv_full_seen_r;
integer wb_phase0_hht_payload_count_r;
integer wb_slot0_payload_count_r;
integer wb_slot2_payload_count_r;
integer wb_slot3_payload_count_r;
integer wb_phase0_hht_done_count_r;
integer wb_slot0_done_count_r;
integer wb_slot2_done_count_r;
integer wb_slot3_done_count_r;
integer wb_done_total_count_r;
integer decoder_qkv_count_r;
integer decoder_score_count_r;
integer decoder_softmax_count_r;
integer decoder_value_count_r;
integer decoder_ffn_count_r;

control_chip_stage2_single_chiplet #(
    .CFG_W(CFG_W),
    .DRAFT_PORTS(DRAFT_PORTS),
    .CONF_W(CONF_W),
    .RESULT_STATUS_W(RESULT_STATUS_W),
    .ENABLE_TREE_WINDOW_CONSUMER(1),
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

task expect_ready_mask;
    input expected_hht_ready;
    input [DRAFT_PORTS-1:0] expected_draft_ready;
    begin
        #1;
        if ((hht_cand_ready !== expected_hht_ready) ||
            (draft_cand_ready !== expected_draft_ready)) begin
            $fatal(1, "19 top ready mask mismatch");
        end
    end
endtask

task expect_window_slot;
    input integer slot_idx;
    input expected_valid;
    input [SOURCE_ID_W-1:0] expected_source_id;
    input [`TOKEN_ID_W-1:0] expected_token_id;
    input [`TOKEN_ID_W-1:0] expected_ref_token_id;
    input [`POSITION_ID_W-1:0] expected_ref_pos;
    input [CONF_W-1:0] expected_confidence;
    begin
        #1;
        if (tree_window_slot_valid[slot_idx] !== expected_valid) begin
            $fatal(1, "19 tree window slot valid mismatch");
        end
        if (expected_valid) begin
            if ((tree_window_source_id[(slot_idx*SOURCE_ID_W) +: SOURCE_ID_W] !=
                 expected_source_id) ||
                (tree_window_token_id[(slot_idx*`TOKEN_ID_W) +: `TOKEN_ID_W] !=
                 expected_token_id) ||
                (tree_window_referenced_token_id[
                    (slot_idx*`TOKEN_ID_W) +: `TOKEN_ID_W] !=
                 expected_ref_token_id) ||
                (tree_window_referenced_position[
                    (slot_idx*`POSITION_ID_W) +: `POSITION_ID_W] !=
                 expected_ref_pos) ||
                (tree_window_confidence[(slot_idx*CONF_W) +: CONF_W] !=
                 expected_confidence)) begin
                $fatal(1, "19 tree window slot payload mismatch");
            end
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

task drive_phase0_seed_once;
    begin
        hht_cand_valid = 1'b0;
        hht_parent_node_id = {`NODE_ID_W{1'b0}};
        hht_token_id = {`TOKEN_ID_W{1'b0}};
        hht_referenced_token_id = {`TOKEN_ID_W{1'b0}};
        hht_referenced_position = {`POSITION_ID_W{1'b0}};
        hht_confidence = {CONF_W{1'b0}};

        draft_cand_valid = 4'b0010;
        draft_parent_node_id = {(DRAFT_PORTS*`NODE_ID_W){1'b0}};
        draft_token_id = {(DRAFT_PORTS*`TOKEN_ID_W){1'b0}};
        draft_referenced_token_id = {(DRAFT_PORTS*`TOKEN_ID_W){1'b0}};
        draft_referenced_position = {(DRAFT_PORTS*`POSITION_ID_W){1'b0}};
        draft_confidence = {(DRAFT_PORTS*CONF_W){1'b0}};

        draft_parent_node_id[(1*`NODE_ID_W) +: `NODE_ID_W] =
            WINDOW_PARENT_NODE_ID;
        draft_token_id[(1*`TOKEN_ID_W) +: `TOKEN_ID_W] = PHASE0_TOKEN_ID;
        draft_referenced_token_id[(1*`TOKEN_ID_W) +: `TOKEN_ID_W] =
            PHASE0_REF_TOKEN_ID;
        draft_referenced_position[(1*`POSITION_ID_W) +: `POSITION_ID_W] =
            PHASE0_REF_POS;
        draft_confidence[(1*CONF_W) +: CONF_W] = PHASE0_CONF;

        expect_ready_mask(1'b0, 4'b0010);
        @(posedge clk);
        #1;
        draft_cand_valid = {DRAFT_PORTS{1'b0}};
    end
endtask

task drive_phase1_window_once;
    begin
        hht_cand_valid = 1'b1;
        hht_parent_node_id = WINDOW_PARENT_NODE_ID;
        hht_token_id = PHASE1_SLOT1_TOKEN_ID;
        hht_referenced_token_id = PHASE1_SLOT1_REF_TOKEN_ID;
        hht_referenced_position = PHASE1_SLOT1_REF_POS;
        hht_confidence = PHASE1_SLOT1_CONF;

        draft_cand_valid = 4'b1101;
        draft_parent_node_id = {(DRAFT_PORTS*`NODE_ID_W){1'b0}};
        draft_token_id = {(DRAFT_PORTS*`TOKEN_ID_W){1'b0}};
        draft_referenced_token_id = {(DRAFT_PORTS*`TOKEN_ID_W){1'b0}};
        draft_referenced_position = {(DRAFT_PORTS*`POSITION_ID_W){1'b0}};
        draft_confidence = {(DRAFT_PORTS*CONF_W){1'b0}};

        draft_parent_node_id[(0*`NODE_ID_W) +: `NODE_ID_W] =
            WINDOW_PARENT_NODE_ID;
        draft_token_id[(0*`TOKEN_ID_W) +: `TOKEN_ID_W] = PHASE1_SLOT2_TOKEN_ID;
        draft_referenced_token_id[(0*`TOKEN_ID_W) +: `TOKEN_ID_W] =
            PHASE1_SLOT2_REF_TOKEN_ID;
        draft_referenced_position[(0*`POSITION_ID_W) +: `POSITION_ID_W] =
            PHASE1_SLOT2_REF_POS;
        draft_confidence[(0*CONF_W) +: CONF_W] = PHASE1_SLOT2_CONF;

        draft_parent_node_id[(2*`NODE_ID_W) +: `NODE_ID_W] =
            WINDOW_PARENT_NODE_ID;
        draft_token_id[(2*`TOKEN_ID_W) +: `TOKEN_ID_W] = PHASE1_SLOT3_TOKEN_ID;
        draft_referenced_token_id[(2*`TOKEN_ID_W) +: `TOKEN_ID_W] =
            PHASE1_SLOT3_REF_TOKEN_ID;
        draft_referenced_position[(2*`POSITION_ID_W) +: `POSITION_ID_W] =
            PHASE1_SLOT3_REF_POS;
        draft_confidence[(2*CONF_W) +: CONF_W] = PHASE1_SLOT3_CONF;

        draft_parent_node_id[(3*`NODE_ID_W) +: `NODE_ID_W] =
            WINDOW_PARENT_NODE_ID;
        draft_token_id[(3*`TOKEN_ID_W) +: `TOKEN_ID_W] = PHASE1_SLOT0_TOKEN_ID;
        draft_referenced_token_id[(3*`TOKEN_ID_W) +: `TOKEN_ID_W] =
            PHASE1_SLOT0_REF_TOKEN_ID;
        draft_referenced_position[(3*`POSITION_ID_W) +: `POSITION_ID_W] =
            PHASE1_SLOT0_REF_POS;
        draft_confidence[(3*CONF_W) +: CONF_W] = PHASE1_SLOT0_CONF;

        expect_ready_mask(1'b1, 4'b1101);
        @(posedge clk);
        #1;
        hht_cand_valid = 1'b0;
        draft_cand_valid = {DRAFT_PORTS{1'b0}};
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

task send_partial_kv_response_once;
    begin
        recompute_resp_valid = 1'b1;
        recompute_resp_partial = 1'b1;
        recompute_resp_full = 1'b0;
        recompute_resp_req_id = EXP_RECOMPUTE_RESP_ID;
        recompute_resp_kv_data = EXP_PARTIAL_KV_DATA;
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
        recompute_resp_req_id = EXP_RECOMPUTE_RESP_ID;
        recompute_resp_kv_data = EXP_FULL_KV_DATA;
        recompute_resp_last = 1'b1;
        @(posedge clk);
        #1;
        recompute_resp_valid = 1'b0;
        recompute_resp_full = 1'b0;
        recompute_resp_last = 1'b0;
    end
endtask

task preload_src_full_kv_once;
    integer preload_byte_idx;
    begin
        // phase0/slot0/slot1 are non-recompute consume paths and must read
        // an already-present full-KV from ISSUE_SRC_ADDR instead of reset-zero.
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
                $fatal(1, "19 source SRAM preload mismatch");
            end
        end
    end
endtask

task query_kv_tables_once;
    input [`TOKEN_ID_W-1:0] query_token_id;
    input [`POSITION_ID_W-1:0] query_position_id;
    begin
        kv_lookup_valid = 1'b1;
        kv_lookup_token_id = query_token_id;
        kv_lookup_position_id = query_position_id;
        @(posedge clk);
        #1;
        kv_lookup_valid = 1'b0;
    end
endtask

task sample_hht_entry;
    input [`NODE_ID_W-1:0] parent_node_id_i;
    input [`TOKEN_ID_W-1:0] token_id_i;
    input [`TOKEN_ID_W-1:0] referenced_token_id_i;
    input [`POSITION_ID_W-1:0] referenced_position_i;
    output found_o;
    output [CONF_W-1:0] confidence_o;
    output [HHT_HIT_COUNT_W-1:0] hit_count_o;
    output [HHT_LRU_W-1:0] lru_o;
    integer idx;
    begin
        found_o = 1'b0;
        confidence_o = {CONF_W{1'b0}};
        hit_count_o = {HHT_HIT_COUNT_W{1'b0}};
        lru_o = {HHT_LRU_W{1'b0}};
        for (idx = 0; idx < HHT_ENTRY_NUM; idx = idx + 1) begin
            if (u_control_chip_stage2_single_chiplet
                    .u_integration_prediction_part
                    .u_hht_state_table.entry_valid_r[idx] &&
                (u_control_chip_stage2_single_chiplet
                    .u_integration_prediction_part
                    .u_hht_state_table.entry_parent_node_id_r[idx] ==
                 parent_node_id_i) &&
                (u_control_chip_stage2_single_chiplet
                    .u_integration_prediction_part
                    .u_hht_state_table.entry_token_id_r[idx] ==
                 token_id_i) &&
                (u_control_chip_stage2_single_chiplet
                    .u_integration_prediction_part
                    .u_hht_state_table.entry_referenced_token_id_r[idx] ==
                 referenced_token_id_i) &&
                (u_control_chip_stage2_single_chiplet
                    .u_integration_prediction_part
                    .u_hht_state_table.entry_referenced_position_r[idx] ==
                 referenced_position_i)) begin
                found_o = 1'b1;
                confidence_o =
                    u_control_chip_stage2_single_chiplet
                        .u_integration_prediction_part
                        .u_hht_state_table.entry_confidence_r[idx];
                hit_count_o =
                    u_control_chip_stage2_single_chiplet
                        .u_integration_prediction_part
                        .u_hht_state_table.entry_hit_count_r[idx];
                lru_o =
                    u_control_chip_stage2_single_chiplet
                        .u_integration_prediction_part
                        .u_hht_state_table.entry_last_use_r[idx];
            end
        end
    end
endtask

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        tree_window_phase0_seen_r <= 1'b0;
        tree_window_phase1_seen_r <= 1'b0;
        recompute_req_count_phase0_r <= 0;
        recompute_req_count_slot0_r <= 0;
        recompute_req_count_slot2_r <= 0;
        recompute_req_count_slot3_r <= 0;
        recompute_done_count_r <= 0;
        kv_partial_seen_r <= 1'b0;
        kv_full_seen_r <= 1'b0;
        wb_phase0_hht_payload_count_r <= 0;
        wb_slot0_payload_count_r <= 0;
        wb_slot2_payload_count_r <= 0;
        wb_slot3_payload_count_r <= 0;
        wb_phase0_hht_done_count_r <= 0;
        wb_slot0_done_count_r <= 0;
        wb_slot2_done_count_r <= 0;
        wb_slot3_done_count_r <= 0;
        wb_done_total_count_r <= 0;
        decoder_qkv_count_r <= 0;
        decoder_score_count_r <= 0;
        decoder_softmax_count_r <= 0;
        decoder_value_count_r <= 0;
        decoder_ffn_count_r <= 0;
    end else begin
        if (tree_window_valid &&
            (tree_window_parent_node_id == WINDOW_PARENT_NODE_ID) &&
            (tree_window_slot_valid == 4'b0001) &&
            (tree_window_source_id[0 +: SOURCE_ID_W] == PHASE0_SOURCE_ID) &&
            (tree_window_token_id[0 +: `TOKEN_ID_W] == PHASE0_TOKEN_ID) &&
            (tree_window_referenced_token_id[0 +: `TOKEN_ID_W] ==
             PHASE0_REF_TOKEN_ID) &&
            (tree_window_referenced_position[0 +: `POSITION_ID_W] ==
             PHASE0_REF_POS) &&
            (tree_window_confidence[0 +: CONF_W] == PHASE0_CONF) &&
            !tree_window_slot_valid[1] &&
            !tree_window_slot_valid[2] &&
            !tree_window_slot_valid[3]) begin
            tree_window_phase0_seen_r <= 1'b1;
        end

        if (tree_window_valid &&
            (tree_window_parent_node_id == WINDOW_PARENT_NODE_ID) &&
            (tree_window_slot_valid == 4'b1111) &&
            (tree_window_source_id[0 +: SOURCE_ID_W] ==
             PHASE1_SLOT0_SOURCE_ID) &&
            (tree_window_token_id[0 +: `TOKEN_ID_W] == PHASE1_SLOT0_TOKEN_ID) &&
            (tree_window_referenced_token_id[0 +: `TOKEN_ID_W] ==
             PHASE1_SLOT0_REF_TOKEN_ID) &&
            (tree_window_referenced_position[0 +: `POSITION_ID_W] ==
             PHASE1_SLOT0_REF_POS) &&
            (tree_window_confidence[0 +: CONF_W] == PHASE1_SLOT0_CONF) &&
            (tree_window_source_id[(1*SOURCE_ID_W) +: SOURCE_ID_W] ==
             PHASE1_SLOT1_SOURCE_ID) &&
            (tree_window_token_id[(1*`TOKEN_ID_W) +: `TOKEN_ID_W] ==
             PHASE1_SLOT1_TOKEN_ID) &&
            (tree_window_referenced_token_id[(1*`TOKEN_ID_W) +: `TOKEN_ID_W] ==
             PHASE1_SLOT1_REF_TOKEN_ID) &&
            (tree_window_referenced_position[(1*`POSITION_ID_W) +:
                                             `POSITION_ID_W] ==
             PHASE1_SLOT1_REF_POS) &&
            (tree_window_confidence[(1*CONF_W) +: CONF_W] ==
             PHASE1_SLOT1_CONF) &&
            (tree_window_source_id[(2*SOURCE_ID_W) +: SOURCE_ID_W] ==
             PHASE1_SLOT2_SOURCE_ID) &&
            (tree_window_token_id[(2*`TOKEN_ID_W) +: `TOKEN_ID_W] ==
             PHASE1_SLOT2_TOKEN_ID) &&
            (tree_window_referenced_token_id[(2*`TOKEN_ID_W) +: `TOKEN_ID_W] ==
             PHASE1_SLOT2_REF_TOKEN_ID) &&
            (tree_window_referenced_position[(2*`POSITION_ID_W) +:
                                             `POSITION_ID_W] ==
             PHASE1_SLOT2_REF_POS) &&
            (tree_window_confidence[(2*CONF_W) +: CONF_W] ==
             PHASE1_SLOT2_CONF) &&
            (tree_window_source_id[(3*SOURCE_ID_W) +: SOURCE_ID_W] ==
             PHASE1_SLOT3_SOURCE_ID) &&
            (tree_window_token_id[(3*`TOKEN_ID_W) +: `TOKEN_ID_W] ==
             PHASE1_SLOT3_TOKEN_ID) &&
            (tree_window_referenced_token_id[(3*`TOKEN_ID_W) +: `TOKEN_ID_W] ==
             PHASE1_SLOT3_REF_TOKEN_ID) &&
            (tree_window_referenced_position[(3*`POSITION_ID_W) +:
                                             `POSITION_ID_W] ==
             PHASE1_SLOT3_REF_POS) &&
            (tree_window_confidence[(3*CONF_W) +: CONF_W] ==
             PHASE1_SLOT3_CONF)) begin
            tree_window_phase1_seen_r <= 1'b1;
        end

        if (recompute_req_valid && recompute_req_ready &&
            (recompute_req_current_position == CURRENT_POSITION) &&
            recompute_req_reason_stale) begin
            if ((recompute_req_token_id == PHASE0_TOKEN_ID) &&
                (recompute_req_referenced_position == PHASE0_REF_POS)) begin
                recompute_req_count_phase0_r <=
                    recompute_req_count_phase0_r + 1;
            end
            if ((recompute_req_token_id == PHASE1_SLOT0_TOKEN_ID) &&
                (recompute_req_referenced_position == PHASE1_SLOT0_REF_POS)) begin
                recompute_req_count_slot0_r <= recompute_req_count_slot0_r + 1;
            end
            if ((recompute_req_token_id == PHASE1_SLOT2_TOKEN_ID) &&
                (recompute_req_referenced_position == PHASE1_SLOT2_REF_POS)) begin
                recompute_req_count_slot2_r <= recompute_req_count_slot2_r + 1;
            end
            if ((recompute_req_token_id == PHASE1_SLOT3_TOKEN_ID) &&
                (recompute_req_referenced_position == PHASE1_SLOT3_REF_POS)) begin
                recompute_req_count_slot3_r <= recompute_req_count_slot3_r + 1;
            end
        end

        if (debug_recompute_done) begin
            recompute_done_count_r <= recompute_done_count_r + 1;
        end

        if (kv_lookup_valid && kv_lookup_ready &&
            kv_lookup_hit &&
            (kv_lookup_token_id == PHASE1_SLOT2_REF_TOKEN_ID) &&
            (kv_lookup_position_id == PHASE1_SLOT2_REF_POS) &&
            (kv_lookup_sram_id == EXP_SRAM_ID) &&
            (kv_lookup_bank_id == EXP_BANK_ID) &&
            (kv_lookup_subbank_start == EXP_SUBBANK_START) &&
            (kv_lookup_group_len == EXP_GROUP_LEN)) begin
            if (kv_lookup_partial_ready && !kv_lookup_full_ready) begin
                kv_partial_seen_r <= 1'b1;
            end
            if (kv_lookup_partial_ready && kv_lookup_full_ready) begin
                kv_full_seen_r <= 1'b1;
            end
        end

        if (wb_valid &&
            (wb_addr == EXP_DST_ADDR) &&
            (wb_status == STATUS_OK)) begin
            if ((wb_token_id == PHASE0_TOKEN_ID) &&
                (wb_data == EXP_FULL_WB_DATA)) begin
                wb_phase0_hht_payload_count_r <=
                    wb_phase0_hht_payload_count_r + 1;
            end
            if ((wb_token_id == PHASE1_SLOT0_TOKEN_ID) &&
                (wb_data == EXP_FULL_WB_DATA)) begin
                wb_slot0_payload_count_r <= wb_slot0_payload_count_r + 1;
            end
            if ((wb_token_id == PHASE1_SLOT2_TOKEN_ID) &&
                (wb_data == EXP_PARTIAL_WB_DATA)) begin
                wb_slot2_payload_count_r <= wb_slot2_payload_count_r + 1;
            end
            if ((wb_token_id == PHASE1_SLOT3_TOKEN_ID) &&
                (wb_data == EXP_FULL_WB_DATA)) begin
                wb_slot3_payload_count_r <= wb_slot3_payload_count_r + 1;
            end
        end

        if (wb_done) begin
            wb_done_total_count_r <= wb_done_total_count_r + 1;
            if (wb_token_id == PHASE0_TOKEN_ID) begin
                wb_phase0_hht_done_count_r <= wb_phase0_hht_done_count_r + 1;
            end
            if (wb_token_id == PHASE1_SLOT0_TOKEN_ID) begin
                wb_slot0_done_count_r <= wb_slot0_done_count_r + 1;
            end
            if (wb_token_id == PHASE1_SLOT2_TOKEN_ID) begin
                wb_slot2_done_count_r <= wb_slot2_done_count_r + 1;
            end
            if (wb_token_id == PHASE1_SLOT3_TOKEN_ID) begin
                wb_slot3_done_count_r <= wb_slot3_done_count_r + 1;
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

integer cycle_count;
reg hht_found_r;
reg [CONF_W-1:0] hht_confidence_sample_r;
reg [HHT_HIT_COUNT_W-1:0] hht_hit_count_sample_r;
reg [HHT_LRU_W-1:0] hht_lru_after_phase0_write_r;
reg [HHT_LRU_W-1:0] hht_lru_after_phase1_accept_r;
reg [HHT_LRU_W-1:0] hht_lru_after_phase1_write_r;
reg scenario_complete_r;

initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    hht_found_r = 1'b0;
    hht_confidence_sample_r = {CONF_W{1'b0}};
    hht_hit_count_sample_r = {HHT_HIT_COUNT_W{1'b0}};
    hht_lru_after_phase0_write_r = {HHT_LRU_W{1'b0}};
    hht_lru_after_phase1_accept_r = {HHT_LRU_W{1'b0}};
    hht_lru_after_phase1_write_r = {HHT_LRU_W{1'b0}};
    scenario_complete_r = 1'b0;
    clear_inputs();

    repeat (3) @(posedge clk);
    rst_n = 1'b1;
    @(posedge clk);
    #1;
    preload_src_full_kv_once();
    wb_ready = 1'b1;
    recompute_req_ready = 1'b1;

    start_tree_once();
    cycle_count = 0;
    while ((busy !== 1'b1) && (cycle_count < 8)) begin
        @(posedge clk);
        #1;
        cycle_count = cycle_count + 1;
    end
    if (busy !== 1'b1) begin
        $fatal(1, "19 phase0 top did not enter busy");
    end

    drive_phase0_seed_once();

    cycle_count = 0;
    while (!tree_window_phase0_seen_r && (cycle_count < 8)) begin
        @(posedge clk);
        #1;
        cycle_count = cycle_count + 1;
    end
    if (!tree_window_phase0_seen_r) begin
        $fatal(1, "19 phase0 tree window was not observed");
    end
    if ((tree_window_parent_node_id != WINDOW_PARENT_NODE_ID) ||
        (tree_window_slot_valid != 4'b0001)) begin
        $fatal(1, "19 phase0 tree window header mismatch");
    end
    expect_window_slot(0, 1'b1, PHASE0_SOURCE_ID, PHASE0_TOKEN_ID,
                       PHASE0_REF_TOKEN_ID, PHASE0_REF_POS, PHASE0_CONF);
    expect_window_slot(1, 1'b0, {SOURCE_ID_W{1'b0}}, {`TOKEN_ID_W{1'b0}},
                       {`TOKEN_ID_W{1'b0}}, {`POSITION_ID_W{1'b0}},
                       {CONF_W{1'b0}});
    expect_window_slot(2, 1'b0, {SOURCE_ID_W{1'b0}}, {`TOKEN_ID_W{1'b0}},
                       {`TOKEN_ID_W{1'b0}}, {`POSITION_ID_W{1'b0}},
                       {CONF_W{1'b0}});
    expect_window_slot(3, 1'b0, {SOURCE_ID_W{1'b0}}, {`TOKEN_ID_W{1'b0}},
                       {`TOKEN_ID_W{1'b0}}, {`POSITION_ID_W{1'b0}},
                       {CONF_W{1'b0}});
    consume_tree_window_once();

    cycle_count = 0;
    while ((wb_phase0_hht_payload_count_r != 1) && (cycle_count < 64)) begin
        @(posedge clk);
        #1;
        cycle_count = cycle_count + 1;
    end
    if (wb_phase0_hht_payload_count_r != 1) begin
        $fatal(1, "19 phase0 seed writeback payload was not observed");
    end

    cycle_count = 0;
    while ((wb_phase0_hht_done_count_r != 1) && (cycle_count < 8)) begin
        @(posedge clk);
        #1;
        cycle_count = cycle_count + 1;
    end
    if (wb_phase0_hht_done_count_r != 1) begin
        $fatal(1, "19 phase0 seed wb_done was not observed");
    end
    if (recompute_req_count_phase0_r != 0) begin
        $fatal(1, "19 phase0 non-stale seed should not emit recompute request");
    end

    repeat (2) begin
        @(posedge clk);
        #1;
    end
    sample_hht_entry(WINDOW_PARENT_NODE_ID, PHASE0_TOKEN_ID,
                     PHASE0_REF_TOKEN_ID, PHASE0_REF_POS,
                     hht_found_r, hht_confidence_sample_r,
                     hht_hit_count_sample_r, hht_lru_after_phase0_write_r);
    if (!hht_found_r) begin
        $fatal(1, "19 phase0 writeback did not create HHT entry");
    end
    if (hht_confidence_sample_r != PHASE0_CONF) begin
        $fatal(1, "19 phase0 HHT confidence mismatch after writeback");
    end
    if (hht_hit_count_sample_r != 8'd0) begin
        $fatal(1, "19 phase0 HHT hit_count should remain zero after writeback");
    end

    cycle_count = 0;
    while ((busy !== 1'b0) && (cycle_count < 16)) begin
        @(posedge clk);
        #1;
        cycle_count = cycle_count + 1;
    end
    if (busy !== 1'b0) begin
        $fatal(1, "19 phase0 top did not return to idle");
    end

    start_tree_once();
    cycle_count = 0;
    while ((busy !== 1'b1) && (cycle_count < 8)) begin
        @(posedge clk);
        #1;
        cycle_count = cycle_count + 1;
    end
    if (busy !== 1'b1) begin
        $fatal(1, "19 phase1 top did not enter busy");
    end

    drive_phase1_window_once();

    repeat (2) begin
        @(posedge clk);
        #1;
    end
    sample_hht_entry(WINDOW_PARENT_NODE_ID, PHASE1_SLOT1_TOKEN_ID,
                     PHASE1_SLOT1_REF_TOKEN_ID, PHASE1_SLOT1_REF_POS,
                     hht_found_r, hht_confidence_sample_r,
                     hht_hit_count_sample_r, hht_lru_after_phase1_accept_r);
    if (!hht_found_r) begin
        $fatal(1, "19 phase1 accepted HHT entry was not found");
    end
    if (hht_confidence_sample_r != PHASE0_CONF) begin
        $fatal(1, "19 phase1 accept should not refresh HHT confidence yet");
    end
    if (hht_hit_count_sample_r != 8'd1) begin
        $fatal(1, "19 phase1 accepted HHT hit did not increment hit_count");
    end
    if (!(hht_lru_after_phase1_accept_r > hht_lru_after_phase0_write_r)) begin
        $fatal(1, "19 phase1 accepted HHT hit did not advance LRU");
    end

    cycle_count = 0;
    while (!tree_window_phase1_seen_r && (cycle_count < 8)) begin
        @(posedge clk);
        #1;
        cycle_count = cycle_count + 1;
    end
    if (!tree_window_phase1_seen_r) begin
        $fatal(1, "19 phase1 tree window was not observed");
    end
    if ((tree_window_parent_node_id != WINDOW_PARENT_NODE_ID) ||
        (tree_window_slot_valid != 4'b1111)) begin
        $fatal(1, "19 phase1 tree window header mismatch");
    end
    expect_window_slot(0, 1'b1, PHASE1_SLOT0_SOURCE_ID, PHASE1_SLOT0_TOKEN_ID,
                       PHASE1_SLOT0_REF_TOKEN_ID, PHASE1_SLOT0_REF_POS,
                       PHASE1_SLOT0_CONF);
    expect_window_slot(1, 1'b1, PHASE1_SLOT1_SOURCE_ID, PHASE1_SLOT1_TOKEN_ID,
                       PHASE1_SLOT1_REF_TOKEN_ID, PHASE1_SLOT1_REF_POS,
                       PHASE1_SLOT1_CONF);
    expect_window_slot(2, 1'b1, PHASE1_SLOT2_SOURCE_ID, PHASE1_SLOT2_TOKEN_ID,
                       PHASE1_SLOT2_REF_TOKEN_ID, PHASE1_SLOT2_REF_POS,
                       PHASE1_SLOT2_CONF);
    expect_window_slot(3, 1'b1, PHASE1_SLOT3_SOURCE_ID, PHASE1_SLOT3_TOKEN_ID,
                       PHASE1_SLOT3_REF_TOKEN_ID, PHASE1_SLOT3_REF_POS,
                       PHASE1_SLOT3_CONF);
    consume_tree_window_once();

    cycle_count = 0;
    while ((wb_slot0_payload_count_r != 1) && (cycle_count < 64)) begin
        @(posedge clk);
        #1;
        cycle_count = cycle_count + 1;
    end
    if (wb_slot0_payload_count_r != 1) begin
        $fatal(1, "19 phase1 slot0 writeback payload was not observed");
    end

    cycle_count = 0;
    while ((wb_slot0_done_count_r != 1) && (cycle_count < 8)) begin
        @(posedge clk);
        #1;
        cycle_count = cycle_count + 1;
    end
    if (wb_slot0_done_count_r != 1) begin
        $fatal(1, "19 phase1 slot0 wb_done was not observed");
    end
    if (recompute_req_count_phase0_r != 0) begin
        $fatal(1, "19 phase1 slot1 should not emit recompute request");
    end
    if (recompute_req_count_slot0_r != 0) begin
        $fatal(1, "19 phase1 slot0 non-stale path should not recompute");
    end
    if (busy !== 1'b1) begin
        $fatal(1, "19 top should remain busy after phase1 slot0");
    end

    cycle_count = 0;
    while ((wb_phase0_hht_payload_count_r != 2) && (cycle_count < 64)) begin
        @(posedge clk);
        #1;
        cycle_count = cycle_count + 1;
    end
    if (wb_phase0_hht_payload_count_r != 2) begin
        $fatal(1, "19 phase1 slot1 HHT writeback payload was not observed");
    end

    cycle_count = 0;
    while ((wb_phase0_hht_done_count_r != 2) && (cycle_count < 8)) begin
        @(posedge clk);
        #1;
        cycle_count = cycle_count + 1;
    end
    if (wb_phase0_hht_done_count_r != 2) begin
        $fatal(1, "19 phase1 slot1 HHT wb_done was not observed");
    end
    if (recompute_req_count_phase0_r != 0) begin
        $fatal(1, "19 HHT hit should not emit recompute request");
    end
    if (busy !== 1'b1) begin
        $fatal(1, "19 top should remain busy while stale slot is still pending");
    end

    cycle_count = 0;
    while ((recompute_req_count_slot2_r != 1) && (cycle_count < 12)) begin
        @(posedge clk);
        #1;
        cycle_count = cycle_count + 1;
    end
    if (recompute_req_count_slot2_r != 1) begin
        $fatal(1, "19 phase1 slot2 recompute request was not observed");
    end
    if (!debug_stale_hit) begin
        $fatal(1, "19 phase1 slot2 stale hit was not observed");
    end
    if (!debug_recompute_busy) begin
        $fatal(1, "19 recompute control did not enter busy on slot2");
    end

    cycle_count = 0;
    while (!recompute_resp_ready && (cycle_count < 8)) begin
        @(posedge clk);
        #1;
        cycle_count = cycle_count + 1;
    end
    if (!recompute_resp_ready) begin
        $fatal(1, "19 recompute response channel was not ready for partial");
    end
    send_partial_kv_response_once();

    cycle_count = 0;
    while (!kv_partial_seen_r && (cycle_count < 20)) begin
        query_kv_tables_once(PHASE1_SLOT2_REF_TOKEN_ID, PHASE1_SLOT2_REF_POS);
        cycle_count = cycle_count + 1;
    end
    if (!kv_partial_seen_r) begin
        $fatal(1, "19 phase1 slot2 partial-ready KV state was not observed");
    end

    cycle_count = 0;
    while ((wb_slot2_payload_count_r != 1) && (cycle_count < 64)) begin
        @(posedge clk);
        #1;
        cycle_count = cycle_count + 1;
    end
    if (wb_slot2_payload_count_r != 1) begin
        $fatal(1, "19 phase1 slot2 partial writeback payload was not observed");
    end

    cycle_count = 0;
    while ((wb_slot2_done_count_r != 1) && (cycle_count < 8)) begin
        @(posedge clk);
        #1;
        cycle_count = cycle_count + 1;
    end
    if (wb_slot2_done_count_r != 1) begin
        $fatal(1, "19 phase1 slot2 wb_done was not observed");
    end
    if (recompute_done_count_r != 0) begin
        $fatal(1, "19 phase1 slot2 partial stage should not finish full recompute");
    end
    if (busy !== 1'b1) begin
        $fatal(1, "19 top should remain busy after slot2 partial writeback");
    end

    cycle_count = 0;
    while (!recompute_resp_ready && (cycle_count < 8)) begin
        @(posedge clk);
        #1;
        cycle_count = cycle_count + 1;
    end
    if (!recompute_resp_ready) begin
        $fatal(1, "19 recompute response channel was not ready for full");
    end
    send_full_kv_response_once();

    cycle_count = 0;
    while ((!kv_full_seen_r || (recompute_done_count_r != 1)) &&
           (cycle_count < 20)) begin
        if (!kv_full_seen_r) begin
            query_kv_tables_once(PHASE1_SLOT2_REF_TOKEN_ID,
                                 PHASE1_SLOT2_REF_POS);
        end else begin
            @(posedge clk);
            #1;
        end
        cycle_count = cycle_count + 1;
    end
    if (!kv_full_seen_r) begin
        $fatal(1, "19 phase1 slot2 full-ready KV state was not observed");
    end
    if (recompute_done_count_r != 1) begin
        $fatal(1, "19 phase1 slot2 full recompute completion pulse was not observed");
    end

    cycle_count = 0;
    while ((wb_slot3_payload_count_r != 1) && (cycle_count < 64)) begin
        @(posedge clk);
        #1;
        cycle_count = cycle_count + 1;
    end
    if (wb_slot3_payload_count_r != 1) begin
        $fatal(1, "19 phase1 slot3 reuse writeback payload was not observed");
    end

    cycle_count = 0;
    while ((wb_slot3_done_count_r != 1) && (cycle_count < 8)) begin
        @(posedge clk);
        #1;
        cycle_count = cycle_count + 1;
    end
    if (wb_slot3_done_count_r != 1) begin
        $fatal(1, "19 phase1 slot3 wb_done was not observed");
    end

    cycle_count = 0;
    while ((wb_done_total_count_r != 5) && (cycle_count < 8)) begin
        @(posedge clk);
        #1;
        cycle_count = cycle_count + 1;
    end
    if (wb_done_total_count_r != 5) begin
        $fatal(1, "19 combined run should complete exactly five writebacks");
    end
    if (recompute_req_count_phase0_r != 0) begin
        $fatal(1, "19 phase0/slot1 same-key path incorrectly emitted recompute");
    end
    if (recompute_req_count_slot0_r != 0) begin
        $fatal(1, "19 phase1 slot0 non-stale path incorrectly emitted recompute");
    end
    if (recompute_req_count_slot2_r != 1) begin
        $fatal(1, "19 phase1 slot2 should emit exactly one recompute request");
    end
    if (recompute_req_count_slot3_r != 0) begin
        $fatal(1, "19 phase1 slot3 reuse path incorrectly emitted recompute");
    end

    cycle_count = 0;
    while ((busy !== 1'b0) && (cycle_count < 16)) begin
        @(posedge clk);
        #1;
        cycle_count = cycle_count + 1;
    end
    if (busy !== 1'b0) begin
        $fatal(1, "19 top did not return to idle after all phase1 slots completed");
    end

    repeat (2) begin
        @(posedge clk);
        #1;
    end
    sample_hht_entry(WINDOW_PARENT_NODE_ID, PHASE1_SLOT1_TOKEN_ID,
                     PHASE1_SLOT1_REF_TOKEN_ID, PHASE1_SLOT1_REF_POS,
                     hht_found_r, hht_confidence_sample_r,
                     hht_hit_count_sample_r, hht_lru_after_phase1_write_r);
    if (!hht_found_r) begin
        $fatal(1, "19 final HHT entry was not found");
    end
    if (hht_confidence_sample_r != PHASE1_SLOT1_CONF) begin
        $fatal(1, "19 final HHT confidence was not refreshed by slot1 writeback");
    end
    if (hht_hit_count_sample_r != 8'd1) begin
        $fatal(1, "19 final HHT hit_count should remain one");
    end
    if (!(hht_lru_after_phase1_write_r > hht_lru_after_phase1_accept_r)) begin
        $fatal(1, "19 final HHT writeback did not advance LRU again");
    end

    if (decoder_qkv_count_r < 5) begin
        $fatal(1, "19 decoder qkv stage should be observed at least five times");
    end
    if (decoder_score_count_r < 5) begin
        $fatal(1, "19 decoder score stage should be observed at least five times");
    end
    if (decoder_softmax_count_r < 5) begin
        $fatal(1, "19 decoder softmax stage should be observed at least five times");
    end
    if (decoder_value_count_r < 5) begin
        $fatal(1, "19 decoder value stage should be observed at least five times");
    end
    if (decoder_ffn_count_r < 5) begin
        $fatal(1, "19 decoder ffn stage should be observed at least five times");
    end
    if (error_flag !== 1'b0) begin
        $fatal(1, "19 top error flag should stay low");
    end
    if (wb_error !== 1'b0) begin
        $fatal(1, "19 writeback error should stay low");
    end
    if (hbm_req_valid !== 1'b0) begin
        $fatal(1, "19 minimal path should not issue HBM request");
    end
    if (hbm_req_write !== 1'b0) begin
        $fatal(1, "19 minimal path HBM write flag should stay low");
    end
    if (hbm_req_addr != {`HBM_ADDR_W{1'b0}}) begin
        $fatal(1, "19 minimal path HBM address should stay zero");
    end
    if (hbm_req_wdata != {`HBM_DATA_W{1'b0}}) begin
        $fatal(1, "19 minimal path HBM data should stay zero");
    end
    if (hbm_req_id != {`REQ_ID_W{1'b0}}) begin
        $fatal(1, "19 minimal path HBM id should stay zero");
    end

    $display("tb_control_chip_stage2_single_chiplet_strongest_bounded_window_hht_feedback_top_min PASS");
    scenario_complete_r = 1'b1;
    if (ENABLE_FINAL_FINISH) begin
        $finish;
    end
end

endmodule
