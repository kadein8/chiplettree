`timescale 1ns/1ps

`include "config/prediction_params.vh"
`include "config/interface_params.vh"

module tb_control_chip_stage2_prediction_admission;

localparam integer DRAFT_PORTS = 4;
localparam integer CONF_W = 8;
localparam integer SOURCE_ID_W =
    ((DRAFT_PORTS + 1) <= 2) ? 1 : $clog2(DRAFT_PORTS + 1);
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

IntegrationPredictionPart #(
    .DRAFT_PORTS(DRAFT_PORTS),
    .CONF_W(CONF_W),
    .HHT_CONF_TH(HHT_CONF_TH),
    .DRAFT_CONF_TH(DRAFT_CONF_TH)
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
            $fatal(1, "prediction admission ready mask mismatch");
        end
    end
endtask

task expect_no_pred;
    begin
        #1;
        if (pred_valid !== 1'b0) begin
            $fatal(1, "prediction admission should be idle");
        end
    end
endtask

task expect_pred;
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
            $fatal(1, "prediction admission selected candidate mismatch");
        end
    end
endtask

task consume_pred;
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
    clear_inputs();

    repeat (3) @(posedge clk);
    rst_n = 1'b1;

    clear_inputs();
    expect_no_pred();
    expect_ready_mask(1'b0, {DRAFT_PORTS{1'b0}});

    // Case 1:
    // - drop low-confidence draft[0]
    // - accept highest-confidence draft[1]
    // - do not choose lower-confidence HHT
    hht_cand_valid = 1'b1;
    hht_parent_node_id = 4'd3;
    hht_token_id = 16'h0101;
    hht_referenced_token_id = 16'h1011;
    hht_referenced_position = 12'h021;
    hht_confidence = 8'd120;

    draft_cand_valid = 4'b0011;
    draft_parent_node_id[(0*`NODE_ID_W) +: `NODE_ID_W] = 4'd4;
    draft_token_id[(0*`TOKEN_ID_W) +: `TOKEN_ID_W] = 16'h0202;
    draft_referenced_token_id[(0*`TOKEN_ID_W) +: `TOKEN_ID_W] = 16'h2022;
    draft_referenced_position[(0*`POSITION_ID_W) +: `POSITION_ID_W] = 12'h022;
    draft_confidence[(0*CONF_W) +: CONF_W] = 8'd90;

    draft_parent_node_id[(1*`NODE_ID_W) +: `NODE_ID_W] = 4'd5;
    draft_token_id[(1*`TOKEN_ID_W) +: `TOKEN_ID_W] = 16'h0303;
    draft_referenced_token_id[(1*`TOKEN_ID_W) +: `TOKEN_ID_W] = 16'h3033;
    draft_referenced_position[(1*`POSITION_ID_W) +: `POSITION_ID_W] = 12'h023;
    draft_confidence[(1*CONF_W) +: CONF_W] = 8'd200;

    expect_ready_mask(1'b0, 4'b0010);
    @(posedge clk);
    clear_inputs();
    expect_pred(3'd2, 4'd5, 16'h0303, 16'h3033, 12'h023, 8'd200);
    expect_ready_mask(1'b0, {DRAFT_PORTS{1'b0}});

    consume_pred();
    expect_no_pred();

    // Case 2:
    // HHT and draft[0] tie on confidence; HHT should win deterministically.
    hht_cand_valid = 1'b1;
    hht_parent_node_id = 4'd6;
    hht_token_id = 16'h0404;
    hht_referenced_token_id = 16'h4044;
    hht_referenced_position = 12'h024;
    hht_confidence = 8'd150;

    draft_cand_valid = 4'b0001;
    draft_parent_node_id[(0*`NODE_ID_W) +: `NODE_ID_W] = 4'd7;
    draft_token_id[(0*`TOKEN_ID_W) +: `TOKEN_ID_W] = 16'h0505;
    draft_referenced_token_id[(0*`TOKEN_ID_W) +: `TOKEN_ID_W] = 16'h5055;
    draft_referenced_position[(0*`POSITION_ID_W) +: `POSITION_ID_W] = 12'h025;
    draft_confidence[(0*CONF_W) +: CONF_W] = 8'd150;

    expect_ready_mask(1'b1, {DRAFT_PORTS{1'b0}});
    @(posedge clk);
    clear_inputs();
    expect_pred({SOURCE_ID_W{1'b0}}, 4'd6, 16'h0404, 16'h4044, 12'h024, 8'd150);

    consume_pred();
    expect_no_pred();

    // Case 3:
    // all candidates below threshold should be dropped.
    hht_cand_valid = 1'b1;
    hht_parent_node_id = 4'd8;
    hht_token_id = 16'h0606;
    hht_referenced_token_id = 16'h6066;
    hht_referenced_position = 12'h026;
    hht_confidence = 8'd99;

    draft_cand_valid = 4'b0100;
    draft_parent_node_id[(2*`NODE_ID_W) +: `NODE_ID_W] = 4'd9;
    draft_token_id[(2*`TOKEN_ID_W) +: `TOKEN_ID_W] = 16'h0707;
    draft_referenced_token_id[(2*`TOKEN_ID_W) +: `TOKEN_ID_W] = 16'h7077;
    draft_referenced_position[(2*`POSITION_ID_W) +: `POSITION_ID_W] = 12'h027;
    draft_confidence[(2*CONF_W) +: CONF_W] = 8'd80;

    expect_ready_mask(1'b0, {DRAFT_PORTS{1'b0}});
    @(posedge clk);
    clear_inputs();
    expect_no_pred();

    $display("tb_control_chip_stage2_prediction_admission PASS");
    $finish;
end

endmodule
