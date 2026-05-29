`timescale 1ns/1ps

`include "config/interface_params.vh"
`include "config/memory_params.vh"

module tb_integration_tree_control_tree_mask_metadata_min;

localparam integer CFG_W = 32;
localparam integer CONF_W = 8;
localparam integer PRED_SOURCE_ID_W = 3;
localparam [`TOKEN_ID_W-1:0] EXP_TOKEN_ID = 16'h4455;
localparam [`TOKEN_ID_W-1:0] EXP_REF_TOKEN_ID = 16'h1122;
localparam [`POSITION_ID_W-1:0] EXP_REF_POS = 12'h01a;
localparam [`NODE_ID_W-1:0] EXP_PARENT = 4'd7;
localparam [`BRANCH_ID_W-1:0] EXP_BRANCH_ID = 2'd2;
localparam [15:0] EXP_PREFIX_LEN = 16'd2;
localparam [CONF_W-1:0] EXP_CONF = 8'd180;

reg clk;
reg rst_n;
reg [CFG_W-1:0] cfg_data;
reg cfg_valid;
reg start;

reg pred_valid;
wire pred_ready;
reg [PRED_SOURCE_ID_W-1:0] pred_source_id;
reg [`NODE_ID_W-1:0] pred_parent_node_id;
reg [`TOKEN_ID_W-1:0] pred_token_id;
reg [`TOKEN_ID_W-1:0] pred_referenced_token_id;
reg [`POSITION_ID_W-1:0] pred_referenced_position;
reg [CONF_W-1:0] pred_confidence;
reg pred_is_last_in_window;
reg [`BRANCH_ID_W-1:0] pred_branch_id;
reg pred_tree_mask_en;
reg [15:0] pred_prefix_len;

wire busy;
wire error_flag;
wire issue_valid;
reg issue_ready;
wire [`TOKEN_ID_W-1:0] issue_token_id;
wire [`BRANCH_ID_W-1:0] issue_branch_id;
wire [`NODE_ID_W-1:0] issue_parent_node_id;
wire [CONF_W-1:0] issue_confidence;
wire issue_tree_mask_en;
wire [`BRANCH_ID_W-1:0] issue_tree_mask_branch_id;
wire [15:0] issue_prefix_len;

wire prep_req_valid;
wire prep_req_write;
wire [`SRAM_ADDR_W-1:0] prep_req_addr;
wire [`SRAM_WDATA_W-1:0] prep_req_wdata;
wire [`REQ_ID_W-1:0] prep_req_id;

wire recompute_req_valid;
wire [`TOKEN_ID_W-1:0] recompute_req_token_id;
wire [`POSITION_ID_W-1:0] recompute_req_current_position;
wire [`POSITION_ID_W-1:0] recompute_req_referenced_position;
wire [`BRANCH_ID_W-1:0] recompute_req_branch_id;
wire recompute_req_reason_stale;

reg wb_done;
reg wb_error;
reg [`TOKEN_ID_W-1:0] wb_token_id;

always #5 clk = ~clk;

IntegrationTreeControlPart #(
    .CFG_W(CFG_W),
    .CONF_W(CONF_W),
    .PRED_SOURCE_ID_W(PRED_SOURCE_ID_W),
    .ENABLE_PREDICTION_INPUT(1),
    .ENABLE_RECOMPUTE_PATH(0),
    .ISSUE_PREFIX_LEN(16'd0)
) u_dut (
    .clk(clk),
    .rst_n(rst_n),
    .cfg_data(cfg_data),
    .cfg_valid(cfg_valid),
    .start(start),
    .busy(busy),
    .error_flag(error_flag),
    .pred_valid(pred_valid),
    .pred_ready(pred_ready),
    .pred_source_id(pred_source_id),
    .pred_parent_node_id(pred_parent_node_id),
    .pred_token_id(pred_token_id),
    .pred_referenced_token_id(pred_referenced_token_id),
    .pred_referenced_position(pred_referenced_position),
    .pred_confidence(pred_confidence),
    .pred_is_last_in_window(pred_is_last_in_window),
    .pred_branch_id(pred_branch_id),
    .pred_tree_mask_en(pred_tree_mask_en),
    .pred_prefix_len(pred_prefix_len),
    .issue_valid(issue_valid),
    .issue_ready(issue_ready),
    .issue_token_id(issue_token_id),
    .issue_branch_id(issue_branch_id),
    .issue_epoch(),
    .issue_model_id(),
    .issue_op_class(),
    .issue_src_addr(),
    .issue_dst_addr(),
    .issue_token_len(),
    .issue_req_id(),
    .issue_flush_epoch(),
    .issue_parent_node_id(issue_parent_node_id),
    .issue_confidence(issue_confidence),
    .issue_tree_mask_en(issue_tree_mask_en),
    .issue_tree_mask_branch_id(issue_tree_mask_branch_id),
    .issue_prefix_len(issue_prefix_len),
    .prep_req_valid(prep_req_valid),
    .prep_req_ready(1'b1),
    .prep_req_write(prep_req_write),
    .prep_req_addr(prep_req_addr),
    .prep_req_wdata(prep_req_wdata),
    .prep_req_id(prep_req_id),
    .recompute_req_valid(recompute_req_valid),
    .recompute_req_ready(1'b1),
    .recompute_req_token_id(recompute_req_token_id),
    .recompute_req_current_position(recompute_req_current_position),
    .recompute_req_referenced_position(recompute_req_referenced_position),
    .recompute_req_branch_id(recompute_req_branch_id),
    .recompute_req_reason_stale(recompute_req_reason_stale),
    .recompute_resp_valid(1'b0),
    .recompute_resp_ready(),
    .recompute_resp_partial(1'b0),
    .recompute_resp_req_id({`REQ_ID_W{1'b0}}),
    .recompute_resp_full(1'b0),
    .recompute_resp_kv_data({`SRAM_WDATA_W{1'b0}}),
    .recompute_resp_last(1'b0),
    .kv_lookup_valid(1'b0),
    .kv_lookup_token_id({`TOKEN_ID_W{1'b0}}),
    .kv_lookup_position_id({`POSITION_ID_W{1'b0}}),
    .kv_lookup_ready(),
    .kv_lookup_hit(),
    .kv_lookup_partial_ready(),
    .kv_lookup_full_ready(),
    .kv_lookup_sram_id(),
    .kv_lookup_bank_id(),
    .kv_lookup_subbank_start(),
    .kv_lookup_group_len(),
    .debug_stale_hit(),
    .debug_recompute_busy(),
    .debug_recompute_done(),
    .wb_done(wb_done),
    .wb_error(wb_error),
    .wb_token_id(wb_token_id)
);

task automatic clear_inputs;
    begin
        cfg_data = {CFG_W{1'b0}};
        cfg_valid = 1'b0;
        start = 1'b0;
        pred_valid = 1'b0;
        pred_source_id = {PRED_SOURCE_ID_W{1'b0}};
        pred_parent_node_id = {`NODE_ID_W{1'b0}};
        pred_token_id = {`TOKEN_ID_W{1'b0}};
        pred_referenced_token_id = {`TOKEN_ID_W{1'b0}};
        pred_referenced_position = {`POSITION_ID_W{1'b0}};
        pred_confidence = {CONF_W{1'b0}};
        pred_is_last_in_window = 1'b0;
        pred_branch_id = {`BRANCH_ID_W{1'b0}};
        pred_tree_mask_en = 1'b0;
        pred_prefix_len = 16'd0;
        issue_ready = 1'b1;
        wb_done = 1'b0;
        wb_error = 1'b0;
        wb_token_id = {`TOKEN_ID_W{1'b0}};
    end
endtask

task automatic start_once;
    begin
        @(negedge clk);
        cfg_valid = 1'b1;
        start = 1'b1;
        cfg_data = 32'h1;
        @(negedge clk);
        cfg_valid = 1'b0;
        start = 1'b0;
    end
endtask

task automatic drive_prediction_once;
    begin
        wait (pred_ready);
        @(negedge clk);
        pred_valid = 1'b1;
        pred_source_id = 3'd5;
        pred_parent_node_id = EXP_PARENT;
        pred_token_id = EXP_TOKEN_ID;
        pred_referenced_token_id = EXP_REF_TOKEN_ID;
        pred_referenced_position = EXP_REF_POS;
        pred_confidence = EXP_CONF;
        pred_is_last_in_window = 1'b1;
        pred_branch_id = EXP_BRANCH_ID;
        pred_tree_mask_en = 1'b1;
        pred_prefix_len = EXP_PREFIX_LEN;
        @(negedge clk);
        pred_valid = 1'b0;
    end
endtask

task automatic wait_for_issue_valid;
    integer wait_cycles;
    begin
        wait_cycles = 0;
        while ((issue_valid !== 1'b1) && (wait_cycles < 20)) begin
            @(posedge clk);
            #1;
            wait_cycles = wait_cycles + 1;
        end
        if (issue_valid !== 1'b1) begin
            $fatal(1, "issue_valid was not asserted within timeout");
        end
    end
endtask

task automatic send_wb_done_once;
    begin
        // Allow the issue handshake to retire into ST_WAIT_WB first.
        @(posedge clk);
        #1;
        wb_token_id = EXP_TOKEN_ID;
        wb_done = 1'b1;
        @(posedge clk);
        #1;
        wb_done = 1'b0;
        wb_token_id = {`TOKEN_ID_W{1'b0}};
    end
endtask

task automatic wait_for_busy_drop;
    integer wait_cycles;
    begin
        wait_cycles = 0;
        while ((busy !== 1'b0) && (wait_cycles < 20)) begin
            @(posedge clk);
            #1;
            wait_cycles = wait_cycles + 1;
        end
        if (busy !== 1'b0) begin
            $fatal(1, "busy should drop after wb_done");
        end
    end
endtask

initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    clear_inputs();

    repeat (3) @(posedge clk);
    rst_n = 1'b1;

    start_once();
    drive_prediction_once();
    wait_for_issue_valid();

    if (issue_token_id !== EXP_TOKEN_ID) begin
        $fatal(1, "issue_token_id mismatch");
    end
    if (issue_parent_node_id !== EXP_PARENT) begin
        $fatal(1, "issue_parent_node_id mismatch");
    end
    if (issue_confidence !== EXP_CONF) begin
        $fatal(1, "issue_confidence mismatch");
    end
    if (issue_branch_id !== EXP_BRANCH_ID) begin
        $fatal(1, "issue_branch_id mismatch actual=%0d expected=%0d",
               issue_branch_id, EXP_BRANCH_ID);
    end
    if (issue_tree_mask_branch_id !== EXP_BRANCH_ID) begin
        $fatal(1, "issue_tree_mask_branch_id mismatch actual=%0d expected=%0d",
               issue_tree_mask_branch_id, EXP_BRANCH_ID);
    end
    if (issue_tree_mask_en !== 1'b1) begin
        $fatal(1, "issue_tree_mask_en should be 1");
    end
    if (issue_prefix_len !== EXP_PREFIX_LEN) begin
        $fatal(1, "issue_prefix_len mismatch actual=%0d expected=%0d",
               issue_prefix_len, EXP_PREFIX_LEN);
    end
    if (prep_req_valid !== 1'b0) begin
        $fatal(1, "prep_req_valid should remain low");
    end
    if (recompute_req_valid !== 1'b0) begin
        $fatal(1, "recompute_req_valid should remain low");
    end
    if (error_flag !== 1'b0) begin
        $fatal(1, "error_flag should remain low");
    end

    send_wb_done_once();
    wait_for_busy_drop();

    $display("tb_integration_tree_control_tree_mask_metadata_min PASS");
    $finish;
end

endmodule
