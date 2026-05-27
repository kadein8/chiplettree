`timescale 1ns/1ps

`include "config/prediction_params.vh"
`include "config/interface_params.vh"
`include "config/memory_params.vh"

module tb_control_chip_stage2_single_chiplet_platform_driver;

localparam integer DRAFT_PORTS = 4;
localparam integer CONF_W = 8;
localparam integer CFG_W = 32;
localparam integer RESULT_STATUS_W = 2;
localparam integer WINDOW_SLOTS = `TREE_FRONTIER_SLOTS;
localparam integer SOURCE_ID_W =
    ((DRAFT_PORTS + 1) <= 2) ? 1 : $clog2(DRAFT_PORTS + 1);
localparam integer STIMULUS_BITS = 2525;
localparam integer STIMULUS_FRONTIER_LEVELS = 6;
localparam integer STIMULUS_VISIBLE_MASK_W = 8;
localparam integer STIMULUS_DEPTH = 256;
localparam integer DRAIN_CYCLES = 64;
localparam [`POSITION_ID_W-1:0] CURRENT_POSITION = 12'h040;
localparam [`POSITION_ID_W-1:0] RECENCY_TH = 12'h010;

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

reg native_tree_req_valid;
wire native_tree_req_ready;
reg [`REQ_ID_W-1:0] native_tree_req_id;
reg [`TREE_MAX_PREFIX_NODES-1:0] native_tree_src_prefix_slot_valid;
reg [`TREE_MAX_PREFIX_NODES*`NODE_ID_W-1:0] native_tree_src_prefix_node_id;
reg [`TREE_MAX_PREFIX_NODES*`TOKEN_ID_W-1:0] native_tree_src_prefix_token_id;
reg [`TREE_MAX_PREFIX_NODES*`POSITION_ID_W-1:0] native_tree_src_prefix_position_id;
reg [`POSITION_ID_W-1:0] native_tree_src_committed_len;
reg [`TREE_MAX_FRONTIER_LEVELS-1:0] native_tree_src_frontier_level_valid;
reg [`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS-1:0]
    native_tree_src_frontier_slot_valid;
reg [`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0]
    native_tree_src_frontier_node_id;
reg [`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0]
    native_tree_src_frontier_parent_node_id;
reg [`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`TOKEN_ID_W-1:0]
    native_tree_src_frontier_token_id;
reg [`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`TOKEN_ID_W-1:0]
    native_tree_src_frontier_referenced_token_id;
reg [`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`POSITION_ID_W-1:0]
    native_tree_src_frontier_position_id;
reg [`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`POSITION_ID_W-1:0]
    native_tree_src_frontier_referenced_position_id;
reg [`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`BRANCH_ID_W-1:0]
    native_tree_src_frontier_branch_id;
reg [`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`TREE_LEVEL_ID_W-1:0]
    native_tree_src_frontier_level_id;
reg [`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS-1:0]
    native_tree_src_frontier_tree_mask_en;

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

reg [STIMULUS_BITS-1:0] stimulus_mem [0:STIMULUS_DEPTH-1];
reg [4095:0] stimulus_memh_path;
reg [4095:0] events_jsonl_path;
integer event_fd;
integer stimulus_cycles;
integer cycle_count_r;
integer drive_index_r;
integer drain_count_r;
reg cfg_start_seen_r;

control_chip_stage2_single_chiplet #(
    .CFG_W(CFG_W),
    .DRAFT_PORTS(DRAFT_PORTS),
    .CONF_W(CONF_W),
    .RESULT_STATUS_W(RESULT_STATUS_W),
    .ENABLE_TREE_WINDOW_CONSUMER(1),
    .ENABLE_NATIVE_TREE_SIDECAR(1),
    .ENABLE_TOP_HBM_WRITEBACK_SHIM(1),
    .ENABLE_ONCHIP_HHT_CONTEXT(1),
    .CURRENT_POSITION(CURRENT_POSITION),
    .RECENCY_TH(RECENCY_TH)
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
    .native_tree_req_valid(native_tree_req_valid),
    .native_tree_req_ready(native_tree_req_ready),
    .native_tree_req_id(native_tree_req_id),
    .native_tree_src_prefix_slot_valid(native_tree_src_prefix_slot_valid),
    .native_tree_src_prefix_node_id(native_tree_src_prefix_node_id),
    .native_tree_src_prefix_token_id(native_tree_src_prefix_token_id),
    .native_tree_src_prefix_position_id(native_tree_src_prefix_position_id),
    .native_tree_src_committed_len(native_tree_src_committed_len),
    .native_tree_src_frontier_level_valid(native_tree_src_frontier_level_valid),
    .native_tree_src_frontier_slot_valid(native_tree_src_frontier_slot_valid),
    .native_tree_src_frontier_node_id(native_tree_src_frontier_node_id),
    .native_tree_src_frontier_parent_node_id(
        native_tree_src_frontier_parent_node_id),
    .native_tree_src_frontier_token_id(native_tree_src_frontier_token_id),
    .native_tree_src_frontier_referenced_token_id(
        native_tree_src_frontier_referenced_token_id),
    .native_tree_src_frontier_position_id(native_tree_src_frontier_position_id),
    .native_tree_src_frontier_referenced_position_id(
        native_tree_src_frontier_referenced_position_id),
    .native_tree_src_frontier_branch_id(
        native_tree_src_frontier_branch_id),
    .native_tree_src_frontier_level_id(
        native_tree_src_frontier_level_id),
    .native_tree_src_frontier_tree_mask_en(
        native_tree_src_frontier_tree_mask_en),
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

task clear_driven_inputs;
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
    native_tree_req_valid = 1'b0;
    native_tree_req_id = {`REQ_ID_W{1'b0}};
    native_tree_src_prefix_slot_valid = {`TREE_MAX_PREFIX_NODES{1'b0}};
    native_tree_src_prefix_node_id =
        {(`TREE_MAX_PREFIX_NODES*`NODE_ID_W){1'b0}};
    native_tree_src_prefix_token_id =
        {(`TREE_MAX_PREFIX_NODES*`TOKEN_ID_W){1'b0}};
    native_tree_src_prefix_position_id =
        {(`TREE_MAX_PREFIX_NODES*`POSITION_ID_W){1'b0}};
    native_tree_src_committed_len = {`POSITION_ID_W{1'b0}};
    native_tree_src_frontier_level_valid =
        {`TREE_MAX_FRONTIER_LEVELS{1'b0}};
    native_tree_src_frontier_slot_valid =
        {(`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS){1'b0}};
    native_tree_src_frontier_node_id =
        {(`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`NODE_ID_W){1'b0}};
    native_tree_src_frontier_parent_node_id =
        {(`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`NODE_ID_W){1'b0}};
    native_tree_src_frontier_token_id =
        {(`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`TOKEN_ID_W){1'b0}};
    native_tree_src_frontier_referenced_token_id =
        {(`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`TOKEN_ID_W){1'b0}};
    native_tree_src_frontier_position_id =
        {(`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`POSITION_ID_W){1'b0}};
    native_tree_src_frontier_referenced_position_id =
        {(`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`POSITION_ID_W){1'b0}};
    native_tree_src_frontier_branch_id =
        {(`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`BRANCH_ID_W){1'b0}};
    native_tree_src_frontier_level_id =
        {(`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`TREE_LEVEL_ID_W){1'b0}};
    native_tree_src_frontier_tree_mask_en =
        {(`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS){1'b0}};
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

task automatic apply_stimulus_word(input [STIMULUS_BITS-1:0] word);
    integer offset;
    integer port_idx;
    integer level_idx;
begin
    clear_driven_inputs();
    offset = 0;

    cfg_valid = word[offset +: 1];
    offset = offset + 1;
    cfg_data = word[offset +: CFG_W];
    offset = offset + CFG_W;
    start = word[offset +: 1];
    offset = offset + 1;
    tree_window_ready = word[offset +: 1];
    offset = offset + 1;
    recompute_req_ready = word[offset +: 1];
    offset = offset + 1;
    wb_ready = word[offset +: 1];
    offset = offset + 1;

    for (port_idx = 0; port_idx < DRAFT_PORTS; port_idx = port_idx + 1) begin
        draft_cand_valid[port_idx] = word[offset +: 1];
        offset = offset + 1;
    end
    for (port_idx = 0; port_idx < DRAFT_PORTS; port_idx = port_idx + 1) begin
        draft_parent_node_id[(port_idx*`NODE_ID_W) +: `NODE_ID_W] =
            word[offset +: `NODE_ID_W];
        offset = offset + `NODE_ID_W;
    end
    for (port_idx = 0; port_idx < DRAFT_PORTS; port_idx = port_idx + 1) begin
        draft_token_id[(port_idx*`TOKEN_ID_W) +: `TOKEN_ID_W] =
            word[offset +: `TOKEN_ID_W];
        offset = offset + `TOKEN_ID_W;
    end
    for (port_idx = 0; port_idx < DRAFT_PORTS; port_idx = port_idx + 1) begin
        draft_referenced_token_id[(port_idx*`TOKEN_ID_W) +: `TOKEN_ID_W] =
            word[offset +: `TOKEN_ID_W];
        offset = offset + `TOKEN_ID_W;
    end
    for (port_idx = 0; port_idx < DRAFT_PORTS; port_idx = port_idx + 1) begin
        draft_referenced_position[(port_idx*`POSITION_ID_W) +:
                                  `POSITION_ID_W] =
            word[offset +: `POSITION_ID_W];
        offset = offset + `POSITION_ID_W;
    end
    for (port_idx = 0; port_idx < DRAFT_PORTS; port_idx = port_idx + 1) begin
        draft_confidence[(port_idx*CONF_W) +: CONF_W] =
            word[offset +: CONF_W];
        offset = offset + CONF_W;
    end

    recompute_resp_valid = word[offset +: 1];
    offset = offset + 1;
    recompute_resp_partial = word[offset +: 1];
    offset = offset + 1;
    recompute_resp_full = word[offset +: 1];
    offset = offset + 1;
    recompute_resp_req_id = word[offset +: `REQ_ID_W];
    offset = offset + `REQ_ID_W;
    recompute_resp_kv_data = word[offset +: `SRAM_WDATA_W];
    offset = offset + `SRAM_WDATA_W;
    recompute_resp_last = word[offset +: 1];
    offset = offset + 1;

    hbm_resp_valid = word[offset +: 1];
    offset = offset + 1;
    hbm_resp_id = word[offset +: `REQ_ID_W];
    offset = offset + `REQ_ID_W;
    hbm_resp_rdata = word[offset +: `HBM_DATA_W];
    offset = offset + `HBM_DATA_W;

    native_tree_req_valid = word[offset +: 1];
    offset = offset + 1;
    native_tree_req_id = word[offset +: `REQ_ID_W];
    offset = offset + `REQ_ID_W;
    native_tree_src_prefix_slot_valid =
        word[offset +: `TREE_MAX_PREFIX_NODES];
    offset = offset + `TREE_MAX_PREFIX_NODES;
    native_tree_src_committed_len = word[offset +: `POSITION_ID_W];
    offset = offset + `POSITION_ID_W;
    offset = offset + 5;
    offset = offset + (`BRANCH_ID_W + 1);
    for (port_idx = 0; port_idx < `TREE_MAX_PREFIX_NODES;
         port_idx = port_idx + 1) begin
        native_tree_src_prefix_node_id[(port_idx*`NODE_ID_W) +: `NODE_ID_W] =
            word[offset +: `NODE_ID_W];
        offset = offset + `NODE_ID_W;
    end
    for (port_idx = 0; port_idx < `TREE_MAX_PREFIX_NODES;
         port_idx = port_idx + 1) begin
        native_tree_src_prefix_token_id[(port_idx*`TOKEN_ID_W) +: `TOKEN_ID_W] =
            word[offset +: `TOKEN_ID_W];
        offset = offset + `TOKEN_ID_W;
    end
    for (port_idx = 0; port_idx < `TREE_MAX_PREFIX_NODES;
         port_idx = port_idx + 1) begin
        native_tree_src_prefix_position_id[
            (port_idx*`POSITION_ID_W) +: `POSITION_ID_W] =
            word[offset +: `POSITION_ID_W];
        offset = offset + `POSITION_ID_W;
    end
    native_tree_src_frontier_level_valid =
        word[offset +: `TREE_MAX_FRONTIER_LEVELS];
    offset = offset + STIMULUS_FRONTIER_LEVELS;
    for (level_idx = 0; level_idx < `TREE_MAX_FRONTIER_LEVELS;
         level_idx = level_idx + 1) begin
        native_tree_src_frontier_slot_valid[
            (level_idx*`TREE_FRONTIER_SLOTS) +: `TREE_FRONTIER_SLOTS] =
            word[offset +: `TREE_FRONTIER_SLOTS];
        offset = offset + `TREE_FRONTIER_SLOTS;
    end
    if (STIMULUS_FRONTIER_LEVELS > `TREE_MAX_FRONTIER_LEVELS)
        offset = offset +
                 ((STIMULUS_FRONTIER_LEVELS - `TREE_MAX_FRONTIER_LEVELS) *
                  `TREE_FRONTIER_SLOTS);
    for (level_idx = 0; level_idx < `TREE_MAX_FRONTIER_LEVELS;
         level_idx = level_idx + 1) begin
        native_tree_src_frontier_tree_mask_en[
            (level_idx*`TREE_FRONTIER_SLOTS) +: `TREE_FRONTIER_SLOTS] =
            word[offset +: `TREE_FRONTIER_SLOTS];
        offset = offset + `TREE_FRONTIER_SLOTS;
    end
    if (STIMULUS_FRONTIER_LEVELS > `TREE_MAX_FRONTIER_LEVELS)
        offset = offset +
                 ((STIMULUS_FRONTIER_LEVELS - `TREE_MAX_FRONTIER_LEVELS) *
                  `TREE_FRONTIER_SLOTS);
    for (level_idx = 0; level_idx < `TREE_MAX_FRONTIER_LEVELS;
         level_idx = level_idx + 1) begin
        for (port_idx = 0; port_idx < `TREE_FRONTIER_SLOTS;
             port_idx = port_idx + 1) begin
            native_tree_src_frontier_node_id[
                (((level_idx*`TREE_FRONTIER_SLOTS) + port_idx)*`NODE_ID_W) +:
                `NODE_ID_W] = word[offset +: `NODE_ID_W];
            offset = offset + `NODE_ID_W;
        end
    end
    if (STIMULUS_FRONTIER_LEVELS > `TREE_MAX_FRONTIER_LEVELS)
        offset = offset +
                 ((STIMULUS_FRONTIER_LEVELS - `TREE_MAX_FRONTIER_LEVELS) *
                  `TREE_FRONTIER_SLOTS * `NODE_ID_W);
    for (level_idx = 0; level_idx < `TREE_MAX_FRONTIER_LEVELS;
         level_idx = level_idx + 1) begin
        for (port_idx = 0; port_idx < `TREE_FRONTIER_SLOTS;
             port_idx = port_idx + 1) begin
            native_tree_src_frontier_parent_node_id[
                (((level_idx*`TREE_FRONTIER_SLOTS) + port_idx)*`NODE_ID_W) +:
                `NODE_ID_W] = word[offset +: `NODE_ID_W];
            offset = offset + `NODE_ID_W;
        end
    end
    if (STIMULUS_FRONTIER_LEVELS > `TREE_MAX_FRONTIER_LEVELS)
        offset = offset +
                 ((STIMULUS_FRONTIER_LEVELS - `TREE_MAX_FRONTIER_LEVELS) *
                  `TREE_FRONTIER_SLOTS * `NODE_ID_W);
    for (level_idx = 0; level_idx < `TREE_MAX_FRONTIER_LEVELS;
         level_idx = level_idx + 1) begin
        for (port_idx = 0; port_idx < `TREE_FRONTIER_SLOTS;
             port_idx = port_idx + 1) begin
            native_tree_src_frontier_token_id[
                (((level_idx*`TREE_FRONTIER_SLOTS) + port_idx)*`TOKEN_ID_W) +:
                `TOKEN_ID_W] = word[offset +: `TOKEN_ID_W];
            offset = offset + `TOKEN_ID_W;
        end
    end
    if (STIMULUS_FRONTIER_LEVELS > `TREE_MAX_FRONTIER_LEVELS)
        offset = offset +
                 ((STIMULUS_FRONTIER_LEVELS - `TREE_MAX_FRONTIER_LEVELS) *
                  `TREE_FRONTIER_SLOTS * `TOKEN_ID_W);
    for (level_idx = 0; level_idx < `TREE_MAX_FRONTIER_LEVELS;
         level_idx = level_idx + 1) begin
        for (port_idx = 0; port_idx < `TREE_FRONTIER_SLOTS;
             port_idx = port_idx + 1) begin
            native_tree_src_frontier_referenced_token_id[
                (((level_idx*`TREE_FRONTIER_SLOTS) + port_idx)*`TOKEN_ID_W) +:
                `TOKEN_ID_W] = word[offset +: `TOKEN_ID_W];
            offset = offset + `TOKEN_ID_W;
        end
    end
    if (STIMULUS_FRONTIER_LEVELS > `TREE_MAX_FRONTIER_LEVELS)
        offset = offset +
                 ((STIMULUS_FRONTIER_LEVELS - `TREE_MAX_FRONTIER_LEVELS) *
                  `TREE_FRONTIER_SLOTS * `TOKEN_ID_W);
    for (level_idx = 0; level_idx < `TREE_MAX_FRONTIER_LEVELS;
         level_idx = level_idx + 1) begin
        for (port_idx = 0; port_idx < `TREE_FRONTIER_SLOTS;
             port_idx = port_idx + 1) begin
            native_tree_src_frontier_position_id[
                (((level_idx*`TREE_FRONTIER_SLOTS) + port_idx)*`POSITION_ID_W) +:
                `POSITION_ID_W] = word[offset +: `POSITION_ID_W];
            offset = offset + `POSITION_ID_W;
        end
    end
    if (STIMULUS_FRONTIER_LEVELS > `TREE_MAX_FRONTIER_LEVELS)
        offset = offset +
                 ((STIMULUS_FRONTIER_LEVELS - `TREE_MAX_FRONTIER_LEVELS) *
                  `TREE_FRONTIER_SLOTS * `POSITION_ID_W);
    for (level_idx = 0; level_idx < `TREE_MAX_FRONTIER_LEVELS;
         level_idx = level_idx + 1) begin
        for (port_idx = 0; port_idx < `TREE_FRONTIER_SLOTS;
             port_idx = port_idx + 1) begin
            native_tree_src_frontier_referenced_position_id[
                (((level_idx*`TREE_FRONTIER_SLOTS) + port_idx)*`POSITION_ID_W) +:
                `POSITION_ID_W] = word[offset +: `POSITION_ID_W];
            offset = offset + `POSITION_ID_W;
        end
    end
    for (level_idx = 0; level_idx < `TREE_MAX_FRONTIER_LEVELS;
         level_idx = level_idx + 1) begin
        for (port_idx = 0; port_idx < `TREE_FRONTIER_SLOTS;
             port_idx = port_idx + 1) begin
            native_tree_src_frontier_branch_id[
                (((level_idx*`TREE_FRONTIER_SLOTS) + port_idx)*`BRANCH_ID_W) +:
                `BRANCH_ID_W] = word[offset +: `BRANCH_ID_W];
            offset = offset + `BRANCH_ID_W;
        end
    end
    for (level_idx = 0; level_idx < `TREE_MAX_FRONTIER_LEVELS;
         level_idx = level_idx + 1) begin
        for (port_idx = 0; port_idx < `TREE_FRONTIER_SLOTS;
             port_idx = port_idx + 1) begin
            native_tree_src_frontier_level_id[
                (((level_idx*`TREE_FRONTIER_SLOTS) + port_idx)*`TREE_LEVEL_ID_W) +:
                `TREE_LEVEL_ID_W] = word[offset +: `TREE_LEVEL_ID_W];
            offset = offset + `TREE_LEVEL_ID_W;
        end
    end
    offset = offset + STIMULUS_VISIBLE_MASK_W;

    if (offset != STIMULUS_BITS) begin
        $fatal(1, "27 stimulus unpack width mismatch: %0d", offset);
    end
end
endtask

initial begin
    if (`TREE_MAX_FRONTIER_LEVELS > STIMULUS_FRONTIER_LEVELS) begin
        $fatal(
            1,
            "27 stimulus format supports at most %0d frontier levels, RTL expects %0d",
            STIMULUS_FRONTIER_LEVELS,
            `TREE_MAX_FRONTIER_LEVELS
        );
    end
end

task write_finish_event;
begin
    $fwrite(
        event_fd,
        "{\"cycle\":%0d,\"event\":\"finish\",\"source\":\"rtl\",\"busy_final\":%0d,\"error_flag\":%0d}\n",
        cycle_count_r,
        busy,
        error_flag
    );
end
endtask

// Native tree event labels: "native_tree_req", "native_tree_prefix_norm",
// "native_tree_frontier_norm", "native_tree_token_wr",
// "native_tree_lookup_hit", "native_tree_pe_req", "native_tree_pe_resp".
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        cycle_count_r <= 0;
        cfg_start_seen_r <= 1'b0;
    end else begin
        cycle_count_r <= cycle_count_r + 1;

        if (cfg_valid && start) begin
            cfg_start_seen_r <= 1'b1;
            $fwrite(
                event_fd,
                "{\"cycle\":%0d,\"event\":\"cfg_start\",\"source\":\"rtl\",\"cfg_data_hex\":\"0x%08x\"}\n",
                cycle_count_r,
                cfg_data
            );
        end

        if (|(draft_cand_valid & draft_cand_ready)) begin
            $fwrite(
                event_fd,
                "{\"cycle\":%0d,\"event\":\"draft_fire\",\"source\":\"rtl\",\"valid_mask_hex\":\"0x%0h\",\"ready_mask_hex\":\"0x%0h\",\"token_bus_hex\":\"0x%0h\"}\n",
                cycle_count_r,
                draft_cand_valid,
                draft_cand_ready,
                draft_token_id
            );
        end

        if (native_tree_req_valid && native_tree_req_ready) begin
            $fwrite(
                event_fd,
                "{\"cycle\":%0d,\"event\":\"native_tree_req\",\"source\":\"rtl\",\"req_id_hex\":\"0x%0h\",\"prefix_slot_valid_hex\":\"0x%0h\",\"frontier_level_valid_hex\":\"0x%0h\"}\n",
                cycle_count_r,
                native_tree_req_id,
                native_tree_src_prefix_slot_valid,
                native_tree_src_frontier_level_valid
            );
        end

        if (u_control_chip_stage2_single_chiplet.native_tree_sidecar_prefix_norm_fire_w) begin
            $fwrite(
                event_fd,
                "{\"cycle\":%0d,\"event\":\"native_tree_prefix_norm\",\"source\":\"rtl\"}\n",
                cycle_count_r
            );
        end

        if (u_control_chip_stage2_single_chiplet.native_tree_sidecar_frontier_norm_fire_w) begin
            $fwrite(
                event_fd,
                "{\"cycle\":%0d,\"event\":\"native_tree_frontier_norm\",\"source\":\"rtl\"}\n",
                cycle_count_r
            );
        end

        if (u_control_chip_stage2_single_chiplet.native_tree_sidecar_token_wr_fire_w) begin
            $fwrite(
                event_fd,
                "{\"cycle\":%0d,\"event\":\"native_tree_token_wr\",\"source\":\"rtl\"}\n",
                cycle_count_r
            );
        end

        if (u_control_chip_stage2_single_chiplet.native_tree_sidecar_lookup_hit_w) begin
            $fwrite(
                event_fd,
                "{\"cycle\":%0d,\"event\":\"native_tree_lookup_hit\",\"source\":\"rtl\"}\n",
                cycle_count_r
            );
        end

        if (u_control_chip_stage2_single_chiplet.native_tree_sidecar_pe_req_fire_w) begin
            $fwrite(
                event_fd,
                "{\"cycle\":%0d,\"event\":\"native_tree_pe_req\",\"source\":\"rtl\"}\n",
                cycle_count_r
            );
        end

        if (u_control_chip_stage2_single_chiplet.native_tree_sidecar_pe_resp_fire_w) begin
            $fwrite(
                event_fd,
                "{\"cycle\":%0d,\"event\":\"native_tree_pe_resp\",\"source\":\"rtl\"}\n",
                cycle_count_r
            );
        end

        if (tree_window_valid && tree_window_ready) begin
            $fwrite(
                event_fd,
                "{\"cycle\":%0d,\"event\":\"tree_window\",\"source\":\"rtl\",\"parent_node_id_hex\":\"0x%0h\",\"slot_valid_hex\":\"0x%0h\",\"token_bus_hex\":\"0x%0h\"}\n",
                cycle_count_r,
                tree_window_parent_node_id,
                tree_window_slot_valid,
                tree_window_token_id
            );
        end

        if (recompute_req_valid && recompute_req_ready) begin
            $fwrite(
                event_fd,
                "{\"cycle\":%0d,\"event\":\"recompute_req\",\"source\":\"rtl\",\"token_id_hex\":\"0x%0h\",\"current_position_hex\":\"0x%0h\",\"referenced_position_hex\":\"0x%0h\",\"branch_id_hex\":\"0x%0h\",\"reason_stale\":%0d}\n",
                cycle_count_r,
                recompute_req_token_id,
                recompute_req_current_position,
                recompute_req_referenced_position,
                recompute_req_branch_id,
                recompute_req_reason_stale
            );
        end

        if (wb_valid && wb_ready) begin
            $fwrite(
                event_fd,
                "{\"cycle\":%0d,\"event\":\"wb\",\"source\":\"rtl\",\"token_id_hex\":\"0x%0h\",\"addr_hex\":\"0x%0h\",\"data_hex\":\"%0h\",\"status_hex\":\"0x%0h\"}\n",
                cycle_count_r,
                wb_token_id,
                wb_addr,
                wb_data,
                wb_status
            );
        end

        if (wb_done) begin
            $fwrite(
                event_fd,
                "{\"cycle\":%0d,\"event\":\"wb_done\",\"source\":\"rtl\",\"token_id_hex\":\"0x%0h\",\"wb_error\":%0d}\n",
                cycle_count_r,
                wb_token_id,
                wb_error
            );
        end

        if (hbm_req_valid && hbm_req_write) begin
            $fwrite(
                event_fd,
                "{\"cycle\":%0d,\"event\":\"hbm_write\",\"source\":\"rtl\",\"addr_hex\":\"0x%0h\",\"data_hex\":\"%0h\",\"req_id\":%0d}\n",
                cycle_count_r,
                hbm_req_addr,
                hbm_req_wdata,
                hbm_req_id
            );
        end

        if (error_flag) begin
            $fatal(1, "25 platform driver observed error_flag");
        end
    end
end

initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    event_fd = 0;
    stimulus_cycles = 0;
    drive_index_r = 0;
    drain_count_r = 0;
    cycle_count_r = 0;
    cfg_start_seen_r = 1'b0;
    clear_driven_inputs();

    if (!$value$plusargs("stimulus_memh=%s", stimulus_memh_path)) begin
        $fatal(1, "25 missing +stimulus_memh=<path>");
    end
    if (!$value$plusargs("stimulus_cycles=%d", stimulus_cycles)) begin
        $fatal(1, "25 missing +stimulus_cycles=<n>");
    end
    if (!$value$plusargs("events_jsonl=%s", events_jsonl_path)) begin
        $fatal(1, "25 missing +events_jsonl=<path>");
    end
    if (stimulus_cycles <= 0 || stimulus_cycles > STIMULUS_DEPTH) begin
        $fatal(1, "25 invalid stimulus_cycles=%0d", stimulus_cycles);
    end

    event_fd = $fopen(events_jsonl_path, "w");
    if (event_fd == 0) begin
        $fatal(1, "25 failed to open events_jsonl_path=%0s", events_jsonl_path);
    end

    $readmemh(stimulus_memh_path, stimulus_mem);

    repeat (4) @(posedge clk);
    rst_n = 1'b1;

    for (drive_index_r = 0; drive_index_r < stimulus_cycles; drive_index_r = drive_index_r + 1) begin
        @(negedge clk);
        apply_stimulus_word(stimulus_mem[drive_index_r]);
    end

    for (drain_count_r = 0; drain_count_r < DRAIN_CYCLES; drain_count_r = drain_count_r + 1) begin
        @(negedge clk);
        clear_driven_inputs();
    end

    if (!cfg_start_seen_r) begin
        $fatal(1, "25 platform driver never observed cfg_start");
    end

    write_finish_event();
    $fclose(event_fd);
    $display("tb_control_chip_stage2_single_chiplet_platform_driver PASS");
    $finish;
end

endmodule
