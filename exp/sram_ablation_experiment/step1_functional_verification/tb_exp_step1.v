`timescale 1ns/1ps

`include "config/prediction_params.vh"
`include "config/interface_params.vh"
`include "config/memory_params.vh"

module tb_exp_step1;

localparam integer DRAFT_PORTS = 4;
localparam integer CONF_W = 8;
localparam integer CFG_W = 32;
localparam integer RESULT_STATUS_W = 2;
localparam integer WINDOW_SLOTS = `TREE_FRONTIER_SLOTS;
localparam integer SOURCE_ID_W =
    ((DRAFT_PORTS + 1) <= 2) ? 1 : $clog2(DRAFT_PORTS + 1);
localparam [`POSITION_ID_W-1:0] CURRENT_POSITION = 12'h040;
localparam [`POSITION_ID_W-1:0] RECENCY_TH = 12'h010;
localparam [RESULT_STATUS_W-1:0] STATUS_OK = 2'b00;

localparam integer ROUND_NUM = 2;

localparam [`NODE_ID_W-1:0] ROUND_PARENT_NODE_ID [0:ROUND_NUM-1] = '{4'd5, 4'd6};
localparam [SOURCE_ID_W-1:0] ROUND_SOURCE_ID [0:ROUND_NUM-1] = '{3'd2, 3'd1};
localparam [`TOKEN_ID_W-1:0] ROUND_TOKEN_ID [0:ROUND_NUM-1] = '{16'hca21, 16'hda31};
localparam [`TOKEN_ID_W-1:0] ROUND_REF_TOKEN_ID [0:ROUND_NUM-1] = '{16'h8c21, 16'h9d31};
localparam [`POSITION_ID_W-1:0] ROUND_REF_POS [0:ROUND_NUM-1] = '{12'h020, 12'h022};
localparam [CONF_W-1:0] ROUND_CONF [0:ROUND_NUM-1] = '{8'd208, 8'd212};
localparam [`REQ_ID_W-1:0] ROUND_RECOMP_RESP_ID [0:ROUND_NUM-1] = '{4'h9, 4'ha};

localparam [`SRAM_ADDR_W-1:0] EXP_SRC_ADDR =
    {2'd0, 4'd2, 5'd6, 8'h00, 4'h0};
localparam [`SRAM_ADDR_W-1:0] EXP_DST_ADDR =
    {2'd0, 4'd1, 5'd4, 8'h03, 4'h0};
localparam [`SRAM_WDATA_W-1:0] EXP_FULL_KV_DATA = {
    {(`SRAM_WDATA_W-32){1'b0}},
    16'h4000,
    16'h3c00
};
localparam [`SRAM_WDATA_W-1:0] EXP_WB_DATA = {
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

reg tree_window_seen_r;
reg recompute_req_seen_r;
reg recompute_done_seen_r;
reg kv_full_seen_r;
reg wb_seen_r;
reg wb_done_seen_r;
reg decoder_qkv_seen_r;
reg decoder_score_seen_r;
reg decoder_softmax_seen_r;
reg decoder_value_seen_r;
reg decoder_ffn_seen_r;
reg [31:0] wb_pulse_count_r;
integer round_idx;
integer cycle_count;

control_chip_stage2_single_chiplet #(
    .CFG_W(CFG_W),
    .DRAFT_PORTS(DRAFT_PORTS),
    .CONF_W(CONF_W),
    .RESULT_STATUS_W(RESULT_STATUS_W),
    .ENABLE_MULTI_BRANCH_WINDOW(1),
    .ENABLE_DECODER_CHAIN(1),
    .DECODER_DATA_WIDTH(16),
    .CURRENT_POSITION(CURRENT_POSITION),
    .RECENCY_TH(RECENCY_TH),
    .ISSUE_SRC_ADDR(EXP_SRC_ADDR),
    .ISSUE_DST_ADDR(EXP_DST_ADDR)
) u_dut (
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
    .native_tree_req_valid(1'b0),
    .native_tree_req_ready(),
    .native_tree_req_id({`REQ_ID_W{1'b0}}),
    .native_tree_src_prefix_slot_valid({`TREE_MAX_PREFIX_NODES{1'b0}}),
    .native_tree_src_prefix_node_id({(`TREE_MAX_PREFIX_NODES*`NODE_ID_W){1'b0}}),
    .native_tree_src_frontier_level_valid({`TREE_MAX_FRONTIER_LEVELS{1'b0}}),
    .native_tree_src_frontier_slot_valid({(`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS){1'b0}}),
    .native_tree_src_frontier_node_id({(`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`NODE_ID_W){1'b0}}),
    .native_tree_src_frontier_parent_node_id({(`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`NODE_ID_W){1'b0}}),
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

task reset_round_observers;
    begin
        tree_window_seen_r = 1'b0;
        recompute_req_seen_r = 1'b0;
        recompute_done_seen_r = 1'b0;
        kv_full_seen_r = 1'b0;
        wb_seen_r = 1'b0;
        wb_done_seen_r = 1'b0;
        decoder_qkv_seen_r = 1'b0;
        decoder_score_seen_r = 1'b0;
        decoder_softmax_seen_r = 1'b0;
        decoder_value_seen_r = 1'b0;
        decoder_ffn_seen_r = 1'b0;
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

task drive_round_candidate_once;
    input integer idx;
    begin
        hht_cand_valid = 1'b1;
        hht_parent_node_id = 4'd1;
        hht_token_id = 16'h0100 + idx;
        hht_referenced_token_id = 16'h8100 + idx;
        hht_referenced_position = 12'h03a + idx;
        hht_confidence = 8'd120;

        draft_cand_valid = {DRAFT_PORTS{1'b0}};
        draft_parent_node_id = {(DRAFT_PORTS*`NODE_ID_W){1'b0}};
        draft_token_id = {(DRAFT_PORTS*`TOKEN_ID_W){1'b0}};
        draft_referenced_token_id = {(DRAFT_PORTS*`TOKEN_ID_W){1'b0}};
        draft_referenced_position = {(DRAFT_PORTS*`POSITION_ID_W){1'b0}};
        draft_confidence = {(DRAFT_PORTS*CONF_W){1'b0}};

        draft_cand_valid[ROUND_SOURCE_ID[idx]-1] = 1'b1;
        draft_parent_node_id[((ROUND_SOURCE_ID[idx]-1)*`NODE_ID_W) +: `NODE_ID_W] =
            ROUND_PARENT_NODE_ID[idx];
        draft_token_id[((ROUND_SOURCE_ID[idx]-1)*`TOKEN_ID_W) +: `TOKEN_ID_W] =
            ROUND_TOKEN_ID[idx];
        draft_referenced_token_id[((ROUND_SOURCE_ID[idx]-1)*`TOKEN_ID_W) +: `TOKEN_ID_W] =
            ROUND_REF_TOKEN_ID[idx];
        draft_referenced_position[((ROUND_SOURCE_ID[idx]-1)*`POSITION_ID_W) +: `POSITION_ID_W] =
            ROUND_REF_POS[idx];
        draft_confidence[((ROUND_SOURCE_ID[idx]-1)*CONF_W) +: CONF_W] =
            ROUND_CONF[idx];

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

task send_full_kv_response_once;
    input integer idx;
    begin
        recompute_resp_valid = 1'b1;
        recompute_resp_partial = 1'b0;
        recompute_resp_full = 1'b1;
        recompute_resp_req_id = ROUND_RECOMP_RESP_ID[idx];
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
    input integer idx;
    begin
        kv_lookup_valid = 1'b1;
        kv_lookup_token_id = ROUND_REF_TOKEN_ID[idx];
        kv_lookup_position_id = ROUND_REF_POS[idx];
        @(posedge clk);
        #1;
        kv_lookup_valid = 1'b0;
    end
endtask

task run_single_round;
    input integer idx;
    reg [31:0] wb_start_count;
    begin
        reset_round_observers();
        wb_start_count = wb_pulse_count_r;

        start_tree_once();
        cycle_count = 0;
        while ((busy !== 1'b1) && (cycle_count < 8)) begin
            @(posedge clk);
            #1;
            cycle_count = cycle_count + 1;
        end
        if (busy !== 1'b1) begin
            $fatal(1, "step1 round %0d: busy did not assert", idx);
        end

        drive_round_candidate_once(idx);

        cycle_count = 0;
        while (!tree_window_seen_r && (cycle_count < 8)) begin
            @(posedge clk);
            #1;
            cycle_count = cycle_count + 1;
        end
        if (!tree_window_seen_r) begin
            $fatal(1, "step1 round %0d: tree_window was not observed", idx);
        end
        consume_tree_window_once();

        cycle_count = 0;
        while (!recompute_req_seen_r && (cycle_count < 12)) begin
            @(posedge clk);
            #1;
            cycle_count = cycle_count + 1;
        end
        if (!recompute_req_seen_r) begin
            $fatal(1, "step1 round %0d: recompute request was not observed", idx);
        end
        if (!debug_stale_hit) begin
            $fatal(1, "step1 round %0d: stale hit was not observed", idx);
        end

        cycle_count = 0;
        while (!recompute_resp_ready && (cycle_count < 8)) begin
            @(posedge clk);
            #1;
            cycle_count = cycle_count + 1;
        end
        if (!recompute_resp_ready) begin
            $fatal(1, "step1 round %0d: recompute response channel not ready", idx);
        end
        send_full_kv_response_once(idx);

        cycle_count = 0;
        while (!recompute_done_seen_r && (cycle_count < 16)) begin
            @(posedge clk);
            #1;
            cycle_count = cycle_count + 1;
        end
        if (!recompute_done_seen_r) begin
            $fatal(1, "step1 round %0d: recompute completion was not observed", idx);
        end

        query_kv_tables_once(idx);
        if (!kv_full_seen_r) begin
            $fatal(1, "step1 round %0d: KV full-ready lookup was not observed", idx);
        end

        cycle_count = 0;
        while ((!decoder_qkv_seen_r || !decoder_score_seen_r ||
                !decoder_softmax_seen_r || !decoder_value_seen_r ||
                !decoder_ffn_seen_r || !wb_done_seen_r) &&
               (cycle_count < 64)) begin
            @(posedge clk);
            #1;
            cycle_count = cycle_count + 1;
        end

        if (!decoder_qkv_seen_r || !decoder_score_seen_r ||
            !decoder_softmax_seen_r || !decoder_value_seen_r ||
            !decoder_ffn_seen_r) begin
            $fatal(1, "step1 round %0d: decoder chain debug pulse missing", idx);
        end
        if (!wb_seen_r || !wb_done_seen_r) begin
            $fatal(1, "step1 round %0d: writeback handshake was not observed", idx);
        end
        if ((wb_pulse_count_r - wb_start_count) != 1) begin
            $fatal(1, "step1 round %0d: wb_done pulse count mismatch", idx);
        end

        @(posedge clk);
        #1;
        if (busy !== 1'b0) begin
            $fatal(1, "step1 round %0d: top did not return to idle", idx);
        end
        if (error_flag !== 1'b0) begin
            $fatal(1, "step1 round %0d: error_flag should stay low", idx);
        end
        if (wb_error !== 1'b0) begin
            $fatal(1, "step1 round %0d: wb_error should stay low", idx);
        end
    end
endtask

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        tree_window_seen_r <= 1'b0;
        recompute_req_seen_r <= 1'b0;
        recompute_done_seen_r <= 1'b0;
        kv_full_seen_r <= 1'b0;
        wb_seen_r <= 1'b0;
        wb_done_seen_r <= 1'b0;
        decoder_qkv_seen_r <= 1'b0;
        decoder_score_seen_r <= 1'b0;
        decoder_softmax_seen_r <= 1'b0;
        decoder_value_seen_r <= 1'b0;
        decoder_ffn_seen_r <= 1'b0;
        wb_pulse_count_r <= 32'd0;
    end else begin
        if (tree_window_valid &&
            (tree_window_parent_node_id == ROUND_PARENT_NODE_ID[round_idx]) &&
            tree_window_slot_valid[0] &&
            (tree_window_source_id[0 +: SOURCE_ID_W] == ROUND_SOURCE_ID[round_idx]) &&
            (tree_window_token_id[0 +: `TOKEN_ID_W] == ROUND_TOKEN_ID[round_idx]) &&
            (tree_window_referenced_token_id[0 +: `TOKEN_ID_W] == ROUND_REF_TOKEN_ID[round_idx]) &&
            (tree_window_referenced_position[0 +: `POSITION_ID_W] == ROUND_REF_POS[round_idx]) &&
            (tree_window_confidence[0 +: CONF_W] == ROUND_CONF[round_idx])) begin
            tree_window_seen_r <= 1'b1;
        end

        if (recompute_req_valid && recompute_req_ready &&
            (recompute_req_token_id == ROUND_TOKEN_ID[round_idx]) &&
            (recompute_req_current_position == CURRENT_POSITION) &&
            (recompute_req_referenced_position == ROUND_REF_POS[round_idx]) &&
            recompute_req_reason_stale) begin
            recompute_req_seen_r <= 1'b1;
        end

        if (debug_recompute_done) begin
            recompute_done_seen_r <= 1'b1;
        end

        if (kv_lookup_valid && kv_lookup_ready &&
            kv_lookup_hit &&
            !kv_lookup_partial_ready &&
            kv_lookup_full_ready &&
            (kv_lookup_sram_id == EXP_SRAM_ID) &&
            (kv_lookup_bank_id == EXP_BANK_ID) &&
            (kv_lookup_subbank_start == EXP_SUBBANK_START) &&
            (kv_lookup_group_len == EXP_GROUP_LEN)) begin
            kv_full_seen_r <= 1'b1;
        end

        if (wb_valid &&
            (wb_token_id == ROUND_TOKEN_ID[round_idx]) &&
            (wb_addr == EXP_DST_ADDR) &&
            (wb_data == EXP_WB_DATA) &&
            (wb_status == STATUS_OK)) begin
            wb_seen_r <= 1'b1;
        end

        if (wb_done) begin
            wb_done_seen_r <= 1'b1;
            wb_pulse_count_r <= wb_pulse_count_r + 1'b1;
        end
        if (debug_decoder_qkv_valid) begin
            decoder_qkv_seen_r <= 1'b1;
        end
        if (debug_decoder_score_valid) begin
            decoder_score_seen_r <= 1'b1;
        end
        if (debug_decoder_softmax_valid) begin
            decoder_softmax_seen_r <= 1'b1;
        end
        if (debug_decoder_value_valid) begin
            decoder_value_seen_r <= 1'b1;
        end
        if (debug_decoder_ffn_valid) begin
            decoder_ffn_seen_r <= 1'b1;
        end
    end
end

initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    round_idx = 0;
    clear_inputs();

    repeat (3) @(posedge clk);
    rst_n = 1'b1;
    wb_ready = 1'b1;
    recompute_req_ready = 1'b1;

    for (round_idx = 0; round_idx < ROUND_NUM; round_idx = round_idx + 1) begin
        run_single_round(round_idx);
    end

    if (wb_pulse_count_r != ROUND_NUM) begin
        $fatal(1, "step1 total wb_done pulse count mismatch");
    end
    if (hbm_req_valid !== 1'b0 || hbm_req_write !== 1'b0 ||
        hbm_req_addr != {`HBM_ADDR_W{1'b0}} ||
        hbm_req_wdata != {`HBM_DATA_W{1'b0}} ||
        hbm_req_id != {`REQ_ID_W{1'b0}}) begin
        $fatal(1, "step1 minimal path should not issue HBM traffic");
    end

    $display("tb_exp_step1 PASS");
    $finish;
end

endmodule
