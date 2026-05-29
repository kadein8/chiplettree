`timescale 1ns/1ps

`include "config/prediction_params.vh"
`include "config/interface_params.vh"

module tb_control_chip_stage2_prediction_parallel_multibranch_input_tree_min;

localparam integer DRAFT_PORTS = 4;
localparam integer CONF_W = 8;
localparam integer SOURCE_ID_W =
    ((DRAFT_PORTS + 1) <= 2) ? 1 : $clog2(DRAFT_PORTS + 1);
localparam integer WINDOW_SLOTS = `TREE_FRONTIER_SLOTS;
localparam [CONF_W-1:0] HHT_CONF_TH = 8'd100;
localparam [CONF_W-1:0] DRAFT_CONF_TH = 8'd100;

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
wire [WINDOW_SLOTS-1:0] tree_window_slot_valid;
wire [WINDOW_SLOTS*SOURCE_ID_W-1:0] tree_window_source_id;
wire [WINDOW_SLOTS*`TOKEN_ID_W-1:0] tree_window_token_id;
wire [WINDOW_SLOTS*`TOKEN_ID_W-1:0] tree_window_referenced_token_id;
wire [WINDOW_SLOTS*`POSITION_ID_W-1:0] tree_window_referenced_position;
wire [WINDOW_SLOTS*CONF_W-1:0] tree_window_confidence;

IntegrationPredictionPart #(
    .DRAFT_PORTS(DRAFT_PORTS),
    .CONF_W(CONF_W),
    .HHT_CONF_TH(HHT_CONF_TH),
    .DRAFT_CONF_TH(DRAFT_CONF_TH),
    .ENABLE_MULTI_BRANCH_WINDOW(1),
    .WINDOW_BRANCH_SLOTS(WINDOW_SLOTS)
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

task clear_inputs;
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

task expect_ready_mask;
    input expected_hht_ready;
    input [DRAFT_PORTS-1:0] expected_draft_ready;
    begin
        #1;
        if ((hht_cand_ready !== expected_hht_ready) ||
            (draft_cand_ready !== expected_draft_ready)) begin
            $fatal(1, "parallel multibranch admission ready mask mismatch");
        end
    end
endtask

task expect_idle;
    begin
        #1;
        if ((pred_valid !== 1'b0) || (tree_window_valid !== 1'b0)) begin
            $fatal(1, "prediction multibranch window should be idle");
        end
    end
endtask

task expect_rank0;
    input [SOURCE_ID_W-1:0] expected_source_id;
    input [`NODE_ID_W-1:0] expected_parent_node_id;
    input [`TOKEN_ID_W-1:0] expected_token_id;
    input [`TOKEN_ID_W-1:0] expected_referenced_token_id;
    input [`POSITION_ID_W-1:0] expected_referenced_position;
    input [CONF_W-1:0] expected_confidence;
    begin
        #1;
        if ((pred_valid !== 1'b1) ||
            (pred_source_id != expected_source_id) ||
            (pred_parent_node_id != expected_parent_node_id) ||
            (pred_token_id != expected_token_id) ||
            (pred_referenced_token_id != expected_referenced_token_id) ||
            (pred_referenced_position != expected_referenced_position) ||
            (pred_confidence != expected_confidence) ||
            (pred_is_last_in_window !== 1'b1)) begin
            $fatal(1, "parallel multibranch rank0 mismatch");
        end
    end
endtask

task expect_window_slot;
    input integer slot_idx;
    input expected_valid;
    input [SOURCE_ID_W-1:0] expected_source_id;
    input [`TOKEN_ID_W-1:0] expected_token_id;
    input [`TOKEN_ID_W-1:0] expected_referenced_token_id;
    input [`POSITION_ID_W-1:0] expected_referenced_position;
    input [CONF_W-1:0] expected_confidence;
    begin
        #1;
        if (tree_window_slot_valid[slot_idx] !== expected_valid) begin
            $fatal(1, "parallel multibranch slot valid mismatch");
        end
        if (expected_valid) begin
            if ((tree_window_source_id[(slot_idx*SOURCE_ID_W) +: SOURCE_ID_W] != expected_source_id) ||
                (tree_window_token_id[(slot_idx*`TOKEN_ID_W) +: `TOKEN_ID_W] != expected_token_id) ||
                (tree_window_referenced_token_id[(slot_idx*`TOKEN_ID_W) +: `TOKEN_ID_W] != expected_referenced_token_id) ||
                (tree_window_referenced_position[(slot_idx*`POSITION_ID_W) +: `POSITION_ID_W] != expected_referenced_position) ||
                (tree_window_confidence[(slot_idx*CONF_W) +: CONF_W] != expected_confidence)) begin
                $fatal(1, "parallel multibranch slot payload mismatch");
            end
        end
    end
endtask

task consume_outputs_once;
    begin
        pred_ready = 1'b1;
        tree_window_ready = 1'b1;
        @(posedge clk);
        #1;
        pred_ready = 1'b0;
        tree_window_ready = 1'b0;
    end
endtask

initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    pred_ready = 1'b0;
    tree_window_ready = 1'b0;
    clear_inputs();

    repeat (3) @(posedge clk);
    rst_n = 1'b1;

    clear_inputs();
    expect_idle();
    expect_ready_mask(1'b0, {DRAFT_PORTS{1'b0}});

    // Case 1:
    // - same-parent concurrent accept
    // - low-confidence draft[2] dropped
    // - window keeps 4 admitted entries in descending confidence order
    hht_cand_valid = 1'b1;
    hht_parent_node_id = 4'd6;
    hht_token_id = 16'h1101;
    hht_referenced_token_id = 16'h7101;
    hht_referenced_position = 12'h031;
    hht_confidence = 8'd210;

    draft_cand_valid = 4'b1111;

    draft_parent_node_id[(0*`NODE_ID_W) +: `NODE_ID_W] = 4'd6;
    draft_token_id[(0*`TOKEN_ID_W) +: `TOKEN_ID_W] = 16'h1201;
    draft_referenced_token_id[(0*`TOKEN_ID_W) +: `TOKEN_ID_W] = 16'h7201;
    draft_referenced_position[(0*`POSITION_ID_W) +: `POSITION_ID_W] = 12'h032;
    draft_confidence[(0*CONF_W) +: CONF_W] = 8'd180;

    draft_parent_node_id[(1*`NODE_ID_W) +: `NODE_ID_W] = 4'd6;
    draft_token_id[(1*`TOKEN_ID_W) +: `TOKEN_ID_W] = 16'h1301;
    draft_referenced_token_id[(1*`TOKEN_ID_W) +: `TOKEN_ID_W] = 16'h7301;
    draft_referenced_position[(1*`POSITION_ID_W) +: `POSITION_ID_W] = 12'h033;
    draft_confidence[(1*CONF_W) +: CONF_W] = 8'd250;

    draft_parent_node_id[(2*`NODE_ID_W) +: `NODE_ID_W] = 4'd6;
    draft_token_id[(2*`TOKEN_ID_W) +: `TOKEN_ID_W] = 16'h1401;
    draft_referenced_token_id[(2*`TOKEN_ID_W) +: `TOKEN_ID_W] = 16'h7401;
    draft_referenced_position[(2*`POSITION_ID_W) +: `POSITION_ID_W] = 12'h034;
    draft_confidence[(2*CONF_W) +: CONF_W] = 8'd90;

    draft_parent_node_id[(3*`NODE_ID_W) +: `NODE_ID_W] = 4'd6;
    draft_token_id[(3*`TOKEN_ID_W) +: `TOKEN_ID_W] = 16'h1501;
    draft_referenced_token_id[(3*`TOKEN_ID_W) +: `TOKEN_ID_W] = 16'h7501;
    draft_referenced_position[(3*`POSITION_ID_W) +: `POSITION_ID_W] = 12'h035;
    draft_confidence[(3*CONF_W) +: CONF_W] = 8'd200;

    expect_ready_mask(1'b1, 4'b1011);
    @(posedge clk);
    #1;
    clear_inputs();

    if ((tree_window_valid !== 1'b1) ||
        (tree_window_parent_node_id != 4'd6) ||
        (tree_window_slot_valid != 4'b1111)) begin
        $fatal(1, "parallel multibranch window header mismatch");
    end

    expect_rank0(3'd2, 4'd6, 16'h1301, 16'h7301, 12'h033, 8'd250);
    expect_window_slot(0, 1'b1, 3'd2, 16'h1301, 16'h7301, 12'h033, 8'd250);
    expect_window_slot(1, 1'b1, 3'd0, 16'h1101, 16'h7101, 12'h031, 8'd210);
    expect_window_slot(2, 1'b1, 3'd4, 16'h1501, 16'h7501, 12'h035, 8'd200);
    expect_window_slot(3, 1'b1, 3'd1, 16'h1201, 16'h7201, 12'h032, 8'd180);

    consume_outputs_once();
    expect_idle();

    // Case 2:
    // - 5 candidates above threshold, truncate to top-4
    // - HHT wins tie against draft
    // - lower draft port wins tie among drafts
    hht_cand_valid = 1'b1;
    hht_parent_node_id = 4'd9;
    hht_token_id = 16'h2101;
    hht_referenced_token_id = 16'h8101;
    hht_referenced_position = 12'h041;
    hht_confidence = 8'd180;

    draft_cand_valid = 4'b1111;

    draft_parent_node_id[(0*`NODE_ID_W) +: `NODE_ID_W] = 4'd9;
    draft_token_id[(0*`TOKEN_ID_W) +: `TOKEN_ID_W] = 16'h2201;
    draft_referenced_token_id[(0*`TOKEN_ID_W) +: `TOKEN_ID_W] = 16'h8201;
    draft_referenced_position[(0*`POSITION_ID_W) +: `POSITION_ID_W] = 12'h042;
    draft_confidence[(0*CONF_W) +: CONF_W] = 8'd180;

    draft_parent_node_id[(1*`NODE_ID_W) +: `NODE_ID_W] = 4'd9;
    draft_token_id[(1*`TOKEN_ID_W) +: `TOKEN_ID_W] = 16'h2301;
    draft_referenced_token_id[(1*`TOKEN_ID_W) +: `TOKEN_ID_W] = 16'h8301;
    draft_referenced_position[(1*`POSITION_ID_W) +: `POSITION_ID_W] = 12'h043;
    draft_confidence[(1*CONF_W) +: CONF_W] = 8'd180;

    draft_parent_node_id[(2*`NODE_ID_W) +: `NODE_ID_W] = 4'd9;
    draft_token_id[(2*`TOKEN_ID_W) +: `TOKEN_ID_W] = 16'h2401;
    draft_referenced_token_id[(2*`TOKEN_ID_W) +: `TOKEN_ID_W] = 16'h8401;
    draft_referenced_position[(2*`POSITION_ID_W) +: `POSITION_ID_W] = 12'h044;
    draft_confidence[(2*CONF_W) +: CONF_W] = 8'd170;

    draft_parent_node_id[(3*`NODE_ID_W) +: `NODE_ID_W] = 4'd9;
    draft_token_id[(3*`TOKEN_ID_W) +: `TOKEN_ID_W] = 16'h2501;
    draft_referenced_token_id[(3*`TOKEN_ID_W) +: `TOKEN_ID_W] = 16'h8501;
    draft_referenced_position[(3*`POSITION_ID_W) +: `POSITION_ID_W] = 12'h045;
    draft_confidence[(3*CONF_W) +: CONF_W] = 8'd160;

    expect_ready_mask(1'b1, 4'b0111);
    @(posedge clk);
    #1;
    clear_inputs();

    if ((tree_window_valid !== 1'b1) ||
        (tree_window_parent_node_id != 4'd9) ||
        (tree_window_slot_valid != 4'b1111)) begin
        $fatal(1, "parallel multibranch truncated window header mismatch");
    end

    expect_rank0(3'd0, 4'd9, 16'h2101, 16'h8101, 12'h041, 8'd180);
    expect_window_slot(0, 1'b1, 3'd0, 16'h2101, 16'h8101, 12'h041, 8'd180);
    expect_window_slot(1, 1'b1, 3'd1, 16'h2201, 16'h8201, 12'h042, 8'd180);
    expect_window_slot(2, 1'b1, 3'd2, 16'h2301, 16'h8301, 12'h043, 8'd180);
    expect_window_slot(3, 1'b1, 3'd3, 16'h2401, 16'h8401, 12'h044, 8'd170);

    consume_outputs_once();
    expect_idle();

    // Case 3:
    // - all below threshold
    hht_cand_valid = 1'b1;
    hht_parent_node_id = 4'd2;
    hht_token_id = 16'h3101;
    hht_referenced_token_id = 16'h9101;
    hht_referenced_position = 12'h051;
    hht_confidence = 8'd99;

    draft_cand_valid = 4'b0010;
    draft_parent_node_id[(1*`NODE_ID_W) +: `NODE_ID_W] = 4'd2;
    draft_token_id[(1*`TOKEN_ID_W) +: `TOKEN_ID_W] = 16'h3201;
    draft_referenced_token_id[(1*`TOKEN_ID_W) +: `TOKEN_ID_W] = 16'h9201;
    draft_referenced_position[(1*`POSITION_ID_W) +: `POSITION_ID_W] = 12'h052;
    draft_confidence[(1*CONF_W) +: CONF_W] = 8'd80;

    expect_ready_mask(1'b0, 4'b0000);
    @(posedge clk);
    clear_inputs();
    expect_idle();

    $display("tb_control_chip_stage2_prediction_parallel_multibranch_input_tree_min PASS");
    $finish;
end

endmodule
