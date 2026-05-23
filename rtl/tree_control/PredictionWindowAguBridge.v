`timescale 1ns/1ps

`include "config/prediction_params.vh"
`include "config/interface_params.vh"

module PredictionWindowAguBridge #(
    parameter integer SOURCE_ID_W = 3,
    parameter integer CONF_W = 8,
    parameter integer WINDOW_BRANCH_SLOTS = `TREE_FRONTIER_SLOTS,
    parameter [`NODE_ID_W-1:0] BRIDGE_SYNTH_NODE_BASE =
        {`NODE_ID_W{1'b0}}
) (
    input clk,
    input rst_n,

    input src_tree_window_valid,
    output src_tree_window_ready,
    input [`REQ_ID_W-1:0] src_tree_window_req_id,
    input [`NODE_ID_W-1:0] src_tree_window_parent_node_id,
    input [WINDOW_BRANCH_SLOTS-1:0] src_tree_window_slot_valid,
    input [WINDOW_BRANCH_SLOTS*SOURCE_ID_W-1:0] src_tree_window_source_id,
    input [WINDOW_BRANCH_SLOTS*`TOKEN_ID_W-1:0] src_tree_window_token_id,
    input [WINDOW_BRANCH_SLOTS*`TOKEN_ID_W-1:0]
        src_tree_window_referenced_token_id,
    input [WINDOW_BRANCH_SLOTS*`POSITION_ID_W-1:0]
        src_tree_window_referenced_position,
    input [WINDOW_BRANCH_SLOTS*CONF_W-1:0] src_tree_window_confidence,

    output frontier_valid,
    input frontier_ready,
    output [`REQ_ID_W-1:0] frontier_req_id,
    output [`TREE_LEVEL_ID_W-1:0] frontier_level_id,
    output [WINDOW_BRANCH_SLOTS-1:0] frontier_slot_valid,
    output [WINDOW_BRANCH_SLOTS*`NODE_ID_W-1:0] frontier_node_id,
    output [WINDOW_BRANCH_SLOTS*`NODE_ID_W-1:0] frontier_parent_node_id,
    output [WINDOW_BRANCH_SLOTS*`TOKEN_ID_W-1:0] frontier_token_id,
    output [WINDOW_BRANCH_SLOTS*`POSITION_ID_W-1:0] frontier_position_id
);

reg [WINDOW_BRANCH_SLOTS*`NODE_ID_W-1:0] frontier_node_id_r;
reg [WINDOW_BRANCH_SLOTS*`NODE_ID_W-1:0] frontier_parent_node_id_r;

wire [WINDOW_BRANCH_SLOTS*SOURCE_ID_W +
      WINDOW_BRANCH_SLOTS*`TOKEN_ID_W +
      WINDOW_BRANCH_SLOTS*CONF_W +
      2 - 1:0] retained_bounded_inputs_w;

integer slot_i;

assign retained_bounded_inputs_w = {
    clk,
    rst_n,
    src_tree_window_source_id,
    src_tree_window_referenced_token_id,
    src_tree_window_confidence
};

assign src_tree_window_ready = frontier_ready;

assign frontier_valid = src_tree_window_valid;
assign frontier_req_id = src_tree_window_req_id;
assign frontier_level_id = {`TREE_LEVEL_ID_W{1'b0}};
assign frontier_slot_valid = src_tree_window_slot_valid;
assign frontier_node_id = frontier_node_id_r;
assign frontier_parent_node_id = frontier_parent_node_id_r;
assign frontier_token_id = src_tree_window_token_id;
assign frontier_position_id = src_tree_window_referenced_position;

always @* begin
    frontier_node_id_r = {(WINDOW_BRANCH_SLOTS*`NODE_ID_W){1'b0}};
    frontier_parent_node_id_r = {(WINDOW_BRANCH_SLOTS*`NODE_ID_W){1'b0}};

    for (slot_i = 0; slot_i < WINDOW_BRANCH_SLOTS; slot_i = slot_i + 1) begin
        frontier_node_id_r[(slot_i*`NODE_ID_W) +: `NODE_ID_W] =
            BRIDGE_SYNTH_NODE_BASE + slot_i;
        frontier_parent_node_id_r[(slot_i*`NODE_ID_W) +: `NODE_ID_W] =
            src_tree_window_parent_node_id;
    end
end

endmodule
