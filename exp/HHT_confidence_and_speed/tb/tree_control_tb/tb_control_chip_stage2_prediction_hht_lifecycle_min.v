`timescale 1ns/1ps

`include "config/prediction_params.vh"
`include "config/interface_params.vh"

module tb_control_chip_stage2_prediction_hht_lifecycle_min;

localparam integer DRAFT_PORTS = 2;
localparam integer CONF_W = 8;
localparam integer SOURCE_ID_W =
    ((DRAFT_PORTS + 1) <= 2) ? 1 : $clog2(DRAFT_PORTS + 1);
localparam integer HHT_ENTRY_NUM = 4;
localparam integer HHT_HIT_COUNT_W = 8;
localparam integer HHT_LRU_W = 16;

reg clk;
reg rst_n;

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

reg hht_update_valid;
wire hht_update_ready;
reg [`NODE_ID_W-1:0] hht_update_parent_node_id;
reg [`TOKEN_ID_W-1:0] hht_update_token_id;
reg [`TOKEN_ID_W-1:0] hht_update_referenced_token_id;
reg [`POSITION_ID_W-1:0] hht_update_referenced_position;
reg [CONF_W-1:0] hht_update_confidence;

wire pred_valid;
reg pred_ready;
wire [SOURCE_ID_W-1:0] pred_source_id;
wire [`NODE_ID_W-1:0] pred_parent_node_id;
wire [`TOKEN_ID_W-1:0] pred_token_id;
wire [`TOKEN_ID_W-1:0] pred_referenced_token_id;
wire [`POSITION_ID_W-1:0] pred_referenced_position;
wire [CONF_W-1:0] pred_confidence;
wire pred_is_last_in_window;

wire tree_window_valid;
reg tree_window_ready;
wire [`NODE_ID_W-1:0] tree_window_parent_node_id;
wire [`TREE_FRONTIER_SLOTS-1:0] tree_window_slot_valid;
wire [(`TREE_FRONTIER_SLOTS*SOURCE_ID_W)-1:0] tree_window_source_id;
wire [(`TREE_FRONTIER_SLOTS*`TOKEN_ID_W)-1:0] tree_window_token_id;
wire [(`TREE_FRONTIER_SLOTS*`TOKEN_ID_W)-1:0] tree_window_referenced_token_id;
wire [(`TREE_FRONTIER_SLOTS*`POSITION_ID_W)-1:0] tree_window_referenced_position;
wire [(`TREE_FRONTIER_SLOTS*CONF_W)-1:0] tree_window_confidence;

reg [HHT_LRU_W-1:0] a_lru_after_write;
reg [HHT_LRU_W-1:0] a_lru_after_hit1;

IntegrationPredictionPart #(
    .DRAFT_PORTS(DRAFT_PORTS),
    .CONF_W(CONF_W),
    .ENABLE_MULTI_BRANCH_WINDOW(0),
    .HHT_ENTRY_NUM(HHT_ENTRY_NUM),
    .HHT_HIT_COUNT_W(HHT_HIT_COUNT_W),
    .HHT_LRU_W(HHT_LRU_W),
    .ENABLE_HHT_LIFECYCLE(1)
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
    .hht_update_valid(hht_update_valid),
    .hht_update_ready(hht_update_ready),
    .hht_update_parent_node_id(hht_update_parent_node_id),
    .hht_update_token_id(hht_update_token_id),
    .hht_update_referenced_token_id(hht_update_referenced_token_id),
    .hht_update_referenced_position(hht_update_referenced_position),
    .hht_update_confidence(hht_update_confidence),
    .pred_valid(pred_valid),
    .pred_ready(pred_ready),
    .pred_source_id(pred_source_id),
    .pred_parent_node_id(pred_parent_node_id),
    .pred_token_id(pred_token_id),
    .pred_referenced_token_id(pred_referenced_token_id),
    .pred_referenced_position(pred_referenced_position),
    .pred_confidence(pred_confidence),
    .pred_is_last_in_window(pred_is_last_in_window),
    .tree_window_valid(tree_window_valid),
    .tree_window_ready(tree_window_ready),
    .tree_window_parent_node_id(tree_window_parent_node_id),
    .tree_window_slot_valid(tree_window_slot_valid),
    .tree_window_source_id(tree_window_source_id),
    .tree_window_token_id(tree_window_token_id),
    .tree_window_referenced_token_id(tree_window_referenced_token_id),
    .tree_window_referenced_position(tree_window_referenced_position),
    .tree_window_confidence(tree_window_confidence)
);

always #5 clk = ~clk;

task clear_candidate_inputs;
    begin
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

task clear_update_inputs;
    begin
        hht_update_valid = 1'b0;
        hht_update_parent_node_id = {`NODE_ID_W{1'b0}};
        hht_update_token_id = {`TOKEN_ID_W{1'b0}};
        hht_update_referenced_token_id = {`TOKEN_ID_W{1'b0}};
        hht_update_referenced_position = {`POSITION_ID_W{1'b0}};
        hht_update_confidence = {CONF_W{1'b0}};
    end
endtask

task expect_idle;
    begin
        #1;
        if ((pred_valid !== 1'b0) || (tree_window_valid !== 1'b0)) begin
            $fatal(1, "prediction hht lifecycle should be idle");
        end
    end
endtask

task expect_entry;
    input integer entry_idx;
    input expected_valid;
    input [`NODE_ID_W-1:0] expected_parent_node_id;
    input [`TOKEN_ID_W-1:0] expected_token_id;
    input [`TOKEN_ID_W-1:0] expected_referenced_token_id;
    input [`POSITION_ID_W-1:0] expected_referenced_position;
    input [CONF_W-1:0] expected_confidence;
    input [HHT_HIT_COUNT_W-1:0] expected_hit_count;
    begin
        #1;
        if (u_integration_prediction_part.u_hht_state_table.entry_valid_r[entry_idx] !== expected_valid) begin
            $fatal(1, "prediction hht lifecycle valid mismatch");
        end
        if (expected_valid) begin
            if ((u_integration_prediction_part.u_hht_state_table.entry_parent_node_id_r[entry_idx] != expected_parent_node_id) ||
                (u_integration_prediction_part.u_hht_state_table.entry_token_id_r[entry_idx] != expected_token_id) ||
                (u_integration_prediction_part.u_hht_state_table.entry_referenced_token_id_r[entry_idx] != expected_referenced_token_id) ||
                (u_integration_prediction_part.u_hht_state_table.entry_referenced_position_r[entry_idx] != expected_referenced_position) ||
                (u_integration_prediction_part.u_hht_state_table.entry_confidence_r[entry_idx] != expected_confidence) ||
                (u_integration_prediction_part.u_hht_state_table.entry_hit_count_r[entry_idx] != expected_hit_count)) begin
                $fatal(1, "prediction hht lifecycle payload mismatch");
            end
        end
    end
endtask

task drive_hht_update;
    input [`NODE_ID_W-1:0] parent_node_id_i;
    input [`TOKEN_ID_W-1:0] token_id_i;
    input [`TOKEN_ID_W-1:0] referenced_token_id_i;
    input [`POSITION_ID_W-1:0] referenced_position_i;
    input [CONF_W-1:0] confidence_i;
    begin
        hht_update_valid = 1'b1;
        hht_update_parent_node_id = parent_node_id_i;
        hht_update_token_id = token_id_i;
        hht_update_referenced_token_id = referenced_token_id_i;
        hht_update_referenced_position = referenced_position_i;
        hht_update_confidence = confidence_i;
        @(posedge clk);
        #1;
        clear_update_inputs();
    end
endtask

task expect_pred;
    input [SOURCE_ID_W-1:0] expected_source_id;
    input [`TOKEN_ID_W-1:0] expected_token_id;
    input [`TOKEN_ID_W-1:0] expected_referenced_token_id;
    input [`POSITION_ID_W-1:0] expected_referenced_position;
    input [CONF_W-1:0] expected_confidence;
    begin
        #1;
        if ((pred_valid !== 1'b1) ||
            (pred_source_id != expected_source_id) ||
            (pred_token_id != expected_token_id) ||
            (pred_referenced_token_id != expected_referenced_token_id) ||
            (pred_referenced_position != expected_referenced_position) ||
            (pred_confidence != expected_confidence) ||
            (pred_is_last_in_window !== 1'b1)) begin
            $fatal(1, "prediction hht lifecycle pred payload mismatch");
        end
    end
endtask

task consume_pred_once;
    begin
        pred_ready = 1'b1;
        @(posedge clk);
        #1;
        pred_ready = 1'b0;
    end
endtask

initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    pred_ready = 1'b0;
    tree_window_ready = 1'b0;
    a_lru_after_write = {HHT_LRU_W{1'b0}};
    a_lru_after_hit1 = {HHT_LRU_W{1'b0}};
    clear_candidate_inputs();
    clear_update_inputs();

    repeat (3) @(posedge clk);
    rst_n = 1'b1;

    expect_idle();
    expect_entry(0, 1'b0, {`NODE_ID_W{1'b0}}, {`TOKEN_ID_W{1'b0}},
                 {`TOKEN_ID_W{1'b0}}, {`POSITION_ID_W{1'b0}},
                 {CONF_W{1'b0}}, {HHT_HIT_COUNT_W{1'b0}});

    if (hht_update_ready !== 1'b1) begin
        $fatal(1, "prediction hht lifecycle update port should be ready");
    end

    // Case 1:
    // - write back one new HHT entry A
    // - entry0 should be allocated with hit_count=0
    drive_hht_update(4'd3, 16'h0A01, 16'h7001, 12'h031, 8'd205);
    expect_entry(0, 1'b1, 4'd3, 16'h0A01, 16'h7001, 12'h031, 8'd205, 8'd0);
    a_lru_after_write =
        u_integration_prediction_part.u_hht_state_table.entry_last_use_r[0];

    // Case 2:
    // - same HHT candidate is present
    // - higher-confidence draft wins admission
    // - hit_count must not change because HHT was not accepted
    hht_cand_valid = 1'b1;
    hht_parent_node_id = 4'd3;
    hht_token_id = 16'h0A01;
    hht_referenced_token_id = 16'h7001;
    hht_referenced_position = 12'h031;
    hht_confidence = 8'd180;

    draft_cand_valid[0] = 1'b1;
    draft_parent_node_id[(0*`NODE_ID_W) +: `NODE_ID_W] = 4'd3;
    draft_token_id[(0*`TOKEN_ID_W) +: `TOKEN_ID_W] = 16'h0D01;
    draft_referenced_token_id[(0*`TOKEN_ID_W) +: `TOKEN_ID_W] = 16'h7101;
    draft_referenced_position[(0*`POSITION_ID_W) +: `POSITION_ID_W] = 12'h032;
    draft_confidence[(0*CONF_W) +: CONF_W] = 8'd230;

    @(posedge clk);
    #1;
    clear_candidate_inputs();
    expect_pred(1, 16'h0D01, 16'h7101, 12'h032, 8'd230);
    consume_pred_once();
    expect_idle();
    expect_entry(0, 1'b1, 4'd3, 16'h0A01, 16'h7001, 12'h031, 8'd205, 8'd0);

    // Case 3:
    // - same HHT candidate now wins and is accepted
    // - hit_count increments and LRU advances
    hht_cand_valid = 1'b1;
    hht_parent_node_id = 4'd3;
    hht_token_id = 16'h0A01;
    hht_referenced_token_id = 16'h7001;
    hht_referenced_position = 12'h031;
    hht_confidence = 8'd200;

    @(posedge clk);
    #1;
    clear_candidate_inputs();
    expect_pred(0, 16'h0A01, 16'h7001, 12'h031, 8'd200);
    consume_pred_once();
    expect_idle();
    expect_entry(0, 1'b1, 4'd3, 16'h0A01, 16'h7001, 12'h031, 8'd205, 8'd1);
    if (!(u_integration_prediction_part.u_hht_state_table.entry_last_use_r[0] >
          a_lru_after_write)) begin
        $fatal(1, "prediction hht lifecycle lru should advance on accepted hit");
    end
    a_lru_after_hit1 =
        u_integration_prediction_part.u_hht_state_table.entry_last_use_r[0];

    // Case 4:
    // - write back a second new entry B
    // - a new slot should be allocated independently
    drive_hht_update(4'd3, 16'h0B01, 16'h7002, 12'h033, 8'd199);
    expect_entry(1, 1'b1, 4'd3, 16'h0B01, 16'h7002, 12'h033, 8'd199, 8'd0);

    // Case 5:
    // - accept entry A again
    // - hit_count keeps growing and LRU advances again
    hht_cand_valid = 1'b1;
    hht_parent_node_id = 4'd3;
    hht_token_id = 16'h0A01;
    hht_referenced_token_id = 16'h7001;
    hht_referenced_position = 12'h031;
    hht_confidence = 8'd201;

    @(posedge clk);
    #1;
    clear_candidate_inputs();
    expect_pred(0, 16'h0A01, 16'h7001, 12'h031, 8'd201);
    consume_pred_once();
    expect_idle();
    expect_entry(0, 1'b1, 4'd3, 16'h0A01, 16'h7001, 12'h031, 8'd205, 8'd2);
    if (!(u_integration_prediction_part.u_hht_state_table.entry_last_use_r[0] >
          a_lru_after_hit1)) begin
        $fatal(1, "prediction hht lifecycle lru should advance on second hit");
    end

    $display("tb_control_chip_stage2_prediction_hht_lifecycle_min PASS");
    $finish;
end

endmodule
