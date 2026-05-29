`timescale 1ns/1ps

`include "config/prediction_params.vh"
`include "config/interface_params.vh"
`include "config/memory_params.vh"

module tb_control_chip_stage2_single_chiplet_partial_full_fullready_reuse_top_min;

localparam integer DRAFT_PORTS = 4;
localparam integer CONF_W = 8;
localparam integer CFG_W = 32;
localparam integer RESULT_STATUS_W = 2;
localparam integer WINDOW_SLOTS = `TREE_FRONTIER_SLOTS;
localparam integer SOURCE_ID_W =
    ((DRAFT_PORTS + 1) <= 2) ? 1 : $clog2(DRAFT_PORTS + 1);
localparam [WINDOW_SLOTS-1:0] EXP_WINDOW_SLOT_MASK =
    {{(WINDOW_SLOTS-1){1'b0}}, 1'b1};
localparam [`POSITION_ID_W-1:0] CURRENT_POSITION = 12'h040;
localparam [`POSITION_ID_W-1:0] RECENCY_TH = 12'h010;
localparam [RESULT_STATUS_W-1:0] STATUS_OK = 2'b00;

localparam [SOURCE_ID_W-1:0] SEL_SOURCE_ID = 3'd2;
localparam [`NODE_ID_W-1:0] T1_PARENT_NODE_ID = 4'd5;
localparam [`TOKEN_ID_W-1:0] T1_TOKEN_ID = 16'hd101;
localparam [`NODE_ID_W-1:0] T2_PARENT_NODE_ID = 4'd6;
localparam [`TOKEN_ID_W-1:0] T2_TOKEN_ID = 16'hd202;
localparam [`TOKEN_ID_W-1:0] REF_TOKEN_ID = 16'h8d10;
localparam [`POSITION_ID_W-1:0] REF_POS = 12'h020;
localparam [CONF_W-1:0] T1_CONF = 8'd210;
localparam [CONF_W-1:0] T2_CONF = 8'd208;

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
localparam [`SRAM_WDATA_W-1:0] EXP_T1_WB_DATA = {
    {(`SRAM_WDATA_W-16){1'b0}},
    16'h3c00
};
localparam [`SRAM_WDATA_W-1:0] EXP_T2_WB_DATA = {
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

reg tree_window_t1_seen_r;
reg tree_window_t2_seen_r;
integer recompute_req_count_t1_r;
integer recompute_req_count_t2_r;
reg kv_partial_seen_r;
reg kv_full_seen_r;
reg wb_t1_seen_r;
reg wb_t2_seen_r;
integer decoder_qkv_count_r;
integer decoder_score_count_r;
integer decoder_softmax_count_r;
integer decoder_value_count_r;
integer decoder_ffn_count_r;
integer recompute_done_count_r;

control_chip_stage2_single_chiplet #(
    .CFG_W(CFG_W),
    .DRAFT_PORTS(DRAFT_PORTS),
    .CONF_W(CONF_W),
    .RESULT_STATUS_W(RESULT_STATUS_W),
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
        tree_window_ready = 1'b1;
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
            $fatal(1, "single-chiplet partial/full reuse top ready mask mismatch");
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

task drive_rank0_candidate_once;
    input [`NODE_ID_W-1:0] selected_parent_node_id;
    input [`TOKEN_ID_W-1:0] selected_token_id;
    input [`TOKEN_ID_W-1:0] selected_referenced_token_id;
    input [`POSITION_ID_W-1:0] selected_referenced_position;
    input [CONF_W-1:0] selected_confidence;
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
            selected_parent_node_id;
        draft_token_id[(1*`TOKEN_ID_W) +: `TOKEN_ID_W] = selected_token_id;
        draft_referenced_token_id[(1*`TOKEN_ID_W) +: `TOKEN_ID_W] =
            selected_referenced_token_id;
        draft_referenced_position[(1*`POSITION_ID_W) +: `POSITION_ID_W] =
            selected_referenced_position;
        draft_confidence[(1*CONF_W) +: CONF_W] = selected_confidence;

        expect_ready_mask(1'b0, 4'b0010);
        @(posedge clk);
        #1;
        draft_cand_valid = {DRAFT_PORTS{1'b0}};
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

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        tree_window_t1_seen_r <= 1'b0;
        tree_window_t2_seen_r <= 1'b0;
        recompute_req_count_t1_r <= 0;
        recompute_req_count_t2_r <= 0;
        kv_partial_seen_r <= 1'b0;
        kv_full_seen_r <= 1'b0;
        wb_t1_seen_r <= 1'b0;
        wb_t2_seen_r <= 1'b0;
        decoder_qkv_count_r <= 0;
        decoder_score_count_r <= 0;
        decoder_softmax_count_r <= 0;
        decoder_value_count_r <= 0;
        decoder_ffn_count_r <= 0;
        recompute_done_count_r <= 0;
    end else begin
        if (tree_window_valid &&
            (tree_window_slot_valid == EXP_WINDOW_SLOT_MASK)) begin
            if ((tree_window_parent_node_id == T1_PARENT_NODE_ID) &&
                (tree_window_source_id[0 +: SOURCE_ID_W] == SEL_SOURCE_ID) &&
                (tree_window_token_id[0 +: `TOKEN_ID_W] == T1_TOKEN_ID) &&
                (tree_window_referenced_token_id[0 +: `TOKEN_ID_W] == REF_TOKEN_ID) &&
                (tree_window_referenced_position[0 +: `POSITION_ID_W] == REF_POS) &&
                (tree_window_confidence[0 +: CONF_W] == T1_CONF)) begin
                tree_window_t1_seen_r <= 1'b1;
            end
            if ((tree_window_parent_node_id == T2_PARENT_NODE_ID) &&
                (tree_window_source_id[0 +: SOURCE_ID_W] == SEL_SOURCE_ID) &&
                (tree_window_token_id[0 +: `TOKEN_ID_W] == T2_TOKEN_ID) &&
                (tree_window_referenced_token_id[0 +: `TOKEN_ID_W] == REF_TOKEN_ID) &&
                (tree_window_referenced_position[0 +: `POSITION_ID_W] == REF_POS) &&
                (tree_window_confidence[0 +: CONF_W] == T2_CONF)) begin
                tree_window_t2_seen_r <= 1'b1;
            end
        end

        if (recompute_req_valid && recompute_req_ready &&
            (recompute_req_current_position == CURRENT_POSITION) &&
            (recompute_req_referenced_position == REF_POS) &&
            recompute_req_reason_stale) begin
            if (recompute_req_token_id == T1_TOKEN_ID) begin
                recompute_req_count_t1_r <= recompute_req_count_t1_r + 1;
            end
            if (recompute_req_token_id == T2_TOKEN_ID) begin
                recompute_req_count_t2_r <= recompute_req_count_t2_r + 1;
            end
        end

        if (kv_lookup_valid && kv_lookup_ready &&
            kv_lookup_hit &&
            (kv_lookup_token_id == REF_TOKEN_ID) &&
            (kv_lookup_position_id == REF_POS) &&
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
            if ((wb_token_id == T1_TOKEN_ID) &&
                (wb_data == EXP_T1_WB_DATA)) begin
                wb_t1_seen_r <= 1'b1;
            end
            if ((wb_token_id == T2_TOKEN_ID) &&
                (wb_data == EXP_T2_WB_DATA)) begin
                wb_t2_seen_r <= 1'b1;
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
        if (debug_recompute_done) begin
            recompute_done_count_r <= recompute_done_count_r + 1;
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
    while ((busy !== 1'b1) && (cycle_count < 8)) begin
        @(posedge clk);
        #1;
        cycle_count = cycle_count + 1;
    end
    if (busy !== 1'b1) begin
        $fatal(1, "T1 top did not enter busy");
    end

    drive_rank0_candidate_once(T1_PARENT_NODE_ID, T1_TOKEN_ID, REF_TOKEN_ID,
                               REF_POS, T1_CONF);

    cycle_count = 0;
    while (!tree_window_t1_seen_r && (cycle_count < 8)) begin
        @(posedge clk);
        #1;
        cycle_count = cycle_count + 1;
    end
    if (!tree_window_t1_seen_r) begin
        $fatal(1, "T1 tree window/rank0 selection was not observed");
    end

    cycle_count = 0;
    while ((recompute_req_count_t1_r != 1) && (cycle_count < 12)) begin
        @(posedge clk);
        #1;
        cycle_count = cycle_count + 1;
    end
    if (recompute_req_count_t1_r != 1) begin
        $fatal(1, "T1 recompute request handshake was not observed");
    end
    if (!debug_stale_hit) begin
        $fatal(1, "T1 stale hit was not observed");
    end
    if (!debug_recompute_busy) begin
        $fatal(1, "T1 recompute control did not enter busy");
    end

    cycle_count = 0;
    while (!recompute_resp_ready && (cycle_count < 8)) begin
        @(posedge clk);
        #1;
        cycle_count = cycle_count + 1;
    end
    if (!recompute_resp_ready) begin
        $fatal(1, "T1 recompute response channel was not ready for partial");
    end

    send_partial_kv_response_once();

    cycle_count = 0;
    while (!kv_partial_seen_r && (cycle_count < 20)) begin
        query_kv_tables_once(REF_TOKEN_ID, REF_POS);
        cycle_count = cycle_count + 1;
    end
    if (!kv_partial_seen_r) begin
        $fatal(1, "T1 KV lookup did not return partial-ready state");
    end

    cycle_count = 0;
    while (!wb_t1_seen_r && (cycle_count < 64)) begin
        @(posedge clk);
        #1;
        cycle_count = cycle_count + 1;
    end
    if (!wb_t1_seen_r) begin
        $fatal(1, "T1 partial writeback payload was not observed");
    end
    if (busy !== 1'b1) begin
        $fatal(1, "T1 top should still wait for full KV after partial writeback");
    end

    cycle_count = 0;
    while (!recompute_resp_ready && (cycle_count < 8)) begin
        @(posedge clk);
        #1;
        cycle_count = cycle_count + 1;
    end
    if (!recompute_resp_ready) begin
        $fatal(1, "T1 recompute response channel was not ready for full");
    end

    send_full_kv_response_once();

    cycle_count = 0;
    while ((!kv_full_seen_r || (recompute_done_count_r != 1)) &&
           (cycle_count < 20)) begin
        if (!kv_full_seen_r) begin
            query_kv_tables_once(REF_TOKEN_ID, REF_POS);
        end else begin
            @(posedge clk);
            #1;
        end
        cycle_count = cycle_count + 1;
    end
    if (!kv_full_seen_r) begin
        $fatal(1, "T1 KV lookup did not return full-ready state");
    end
    if (recompute_done_count_r != 1) begin
        $fatal(1, "T1 recompute full completion pulse was not observed");
    end

    cycle_count = 0;
    while ((busy !== 1'b0) && (cycle_count < 16)) begin
        @(posedge clk);
        #1;
        cycle_count = cycle_count + 1;
    end
    if (busy !== 1'b0) begin
        $fatal(1, "T1 top did not return to idle after full KV");
    end

    start_tree_once();
    cycle_count = 0;
    while ((busy !== 1'b1) && (cycle_count < 8)) begin
        @(posedge clk);
        #1;
        cycle_count = cycle_count + 1;
    end
    if (busy !== 1'b1) begin
        $fatal(1, "T2 top did not enter busy");
    end

    drive_rank0_candidate_once(T2_PARENT_NODE_ID, T2_TOKEN_ID, REF_TOKEN_ID,
                               REF_POS, T2_CONF);

    cycle_count = 0;
    while (!tree_window_t2_seen_r && (cycle_count < 8)) begin
        @(posedge clk);
        #1;
        cycle_count = cycle_count + 1;
    end
    if (!tree_window_t2_seen_r) begin
        $fatal(1, "T2 tree window/rank0 selection was not observed");
    end

    cycle_count = 0;
    while (!wb_t2_seen_r && (cycle_count < 64)) begin
        @(posedge clk);
        #1;
        cycle_count = cycle_count + 1;
    end
    if (!wb_t2_seen_r) begin
        $fatal(1, "T2 full-ready reuse writeback payload was not observed");
    end

    cycle_count = 0;
    while ((busy !== 1'b0) && (cycle_count < 16)) begin
        @(posedge clk);
        #1;
        cycle_count = cycle_count + 1;
    end
    if (busy !== 1'b0) begin
        $fatal(1, "T2 top did not return to idle");
    end

    if (recompute_req_count_t2_r != 0) begin
        $fatal(1, "T2 should not emit recompute request on full-ready reuse");
    end
    if (decoder_qkv_count_r < 2) begin
        $fatal(1, "decoder qkv stage should be observed for both T1/T2");
    end
    if (decoder_score_count_r < 2) begin
        $fatal(1, "decoder score stage should be observed for both T1/T2");
    end
    if (decoder_softmax_count_r < 2) begin
        $fatal(1, "decoder softmax stage should be observed for both T1/T2");
    end
    if (decoder_value_count_r < 2) begin
        $fatal(1, "decoder value stage should be observed for both T1/T2");
    end
    if (decoder_ffn_count_r < 2) begin
        $fatal(1, "decoder ffn stage should be observed for both T1/T2");
    end
    if (error_flag !== 1'b0) begin
        $fatal(1, "top error flag should stay low");
    end
    if (wb_error !== 1'b0) begin
        $fatal(1, "writeback error should stay low");
    end
    if (hbm_req_valid !== 1'b0) begin
        $fatal(1, "13 minimal path should not issue HBM request");
    end
    if (hbm_req_write !== 1'b0) begin
        $fatal(1, "13 minimal path HBM write flag should stay low");
    end
    if (hbm_req_addr != {`HBM_ADDR_W{1'b0}}) begin
        $fatal(1, "13 minimal path HBM address should stay zero");
    end
    if (hbm_req_wdata != {`HBM_DATA_W{1'b0}}) begin
        $fatal(1, "13 minimal path HBM data should stay zero");
    end
    if (hbm_req_id != {`REQ_ID_W{1'b0}}) begin
        $fatal(1, "13 minimal path HBM id should stay zero");
    end

    $display("tb_control_chip_stage2_single_chiplet_partial_full_fullready_reuse_top_min PASS");
    $finish;
end

endmodule
