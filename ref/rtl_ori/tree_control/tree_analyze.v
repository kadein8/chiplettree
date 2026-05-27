`timescale 1ns/1ps

`include "config/prediction_params.vh"
`include "config/interface_params.vh"

module tree_analyze (
    input  clk,
    input  rst_n,
    input  req_valid,
    output req_ready,
    input  [`REQ_ID_W-1:0] req_id,
    input  [`TREE_MAX_PREFIX_NODES-1:0] src_prefix_slot_valid,
    input  [`TREE_MAX_PREFIX_NODES*`NODE_ID_W-1:0] src_prefix_node_id,
    input  [`TREE_MAX_FRONTIER_LEVELS-1:0] src_frontier_level_valid,
    input  [`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS-1:0] src_frontier_slot_valid,
    input  [`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0] src_frontier_node_id,
    input  [`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0] src_frontier_parent_node_id,
    output prefix_valid,
    input  prefix_ready,
    output [`REQ_ID_W-1:0] prefix_req_id,
    output prefix_node_valid,
    output [`NODE_ID_W-1:0] prefix_node_id,
    output [`NODE_ID_W-1:0] prefix_parent_node_id,
    output [`TOKEN_ID_W-1:0] prefix_token_id,
    output [`POSITION_ID_W-1:0] prefix_position_id,
    output [`LAYER_ID_W-1:0] prefix_layer_id,
    output prefix_is_last,
    output frontier_valid,
    input  frontier_ready,
    output [`REQ_ID_W-1:0] frontier_req_id,
    output [`TREE_LEVEL_ID_W-1:0] frontier_level_id,
    output [`TREE_FRONTIER_SLOTS-1:0] frontier_slot_valid,
    output [`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0] frontier_node_id,
    output [`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0] frontier_parent_node_id,
    output [`TREE_FRONTIER_SLOTS*`TOKEN_ID_W-1:0] frontier_token_id,
    output [`TREE_FRONTIER_SLOTS*`POSITION_ID_W-1:0] frontier_position_id
);

localparam [1:0] TA_STATE_IDLE     = 2'd0;
localparam [1:0] TA_STATE_PREFIX   = 2'd1;
localparam [1:0] TA_STATE_FRONTIER = 2'd2;

reg [1:0] state_r;
reg [`REQ_ID_W-1:0] req_id_r;
reg [`TREE_MAX_PREFIX_NODES-1:0] prefix_slot_valid_r;
reg [`TREE_MAX_PREFIX_NODES*`NODE_ID_W-1:0] prefix_node_id_r;
reg [`TREE_MAX_FRONTIER_LEVELS-1:0] frontier_level_valid_r;
reg [`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS-1:0] frontier_slot_valid_r;
reg [`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0] frontier_node_id_r;
reg [`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0] frontier_parent_node_id_r;

reg [`TREE_LEVEL_ID_W-1:0] prefix_idx_r;
reg [`TREE_LEVEL_ID_W-1:0] frontier_level_idx_r;

reg [`TREE_LEVEL_ID_W-1:0] prefix_last_idx_comb;
reg [`TREE_LEVEL_ID_W-1:0] frontier_last_level_idx_comb;

reg [`TREE_FRONTIER_SLOTS*`TOKEN_ID_W-1:0] frontier_token_id_comb;
reg [`TREE_FRONTIER_SLOTS*`POSITION_ID_W-1:0] frontier_position_id_comb;

integer idx_i;
integer slot_i;
reg [`NODE_ID_W-1:0] current_prefix_node_comb;

assign req_ready = (state_r == TA_STATE_IDLE);

assign prefix_valid =
    (state_r == TA_STATE_PREFIX) &&
    prefix_slot_valid_r[prefix_idx_r];
assign prefix_req_id = req_id_r;
assign prefix_node_valid = prefix_valid;
assign prefix_node_id =
    prefix_node_id_r[(prefix_idx_r*`NODE_ID_W) +: `NODE_ID_W];
assign prefix_parent_node_id =
    (prefix_idx_r == {`TREE_LEVEL_ID_W{1'b0}}) ?
        `TREE_PARENT_NONE_NODE_ID :
        prefix_node_id_r[((prefix_idx_r - 1'b1)*`NODE_ID_W) +: `NODE_ID_W];
assign prefix_layer_id =
    {{(`LAYER_ID_W-`TREE_LEVEL_ID_W){1'b0}}, prefix_idx_r};
assign prefix_is_last = (prefix_idx_r == prefix_last_idx_comb);
assign prefix_token_id =
    {{(`TOKEN_ID_W-`NODE_ID_W){1'b0}}, prefix_node_id};
assign prefix_position_id =
    {{(`POSITION_ID_W-`NODE_ID_W){1'b0}}, prefix_node_id};

assign frontier_valid =
    (state_r == TA_STATE_FRONTIER) &&
    frontier_level_valid_r[frontier_level_idx_r];
assign frontier_req_id = req_id_r;
assign frontier_level_id = frontier_level_idx_r;
assign frontier_slot_valid =
    frontier_slot_valid_r[(frontier_level_idx_r*`TREE_FRONTIER_SLOTS) +: `TREE_FRONTIER_SLOTS];
assign frontier_node_id =
    frontier_node_id_r[(frontier_level_idx_r*`TREE_FRONTIER_SLOTS*`NODE_ID_W) +:
        (`TREE_FRONTIER_SLOTS*`NODE_ID_W)];
assign frontier_parent_node_id =
    frontier_parent_node_id_r[(frontier_level_idx_r*`TREE_FRONTIER_SLOTS*`NODE_ID_W) +:
        (`TREE_FRONTIER_SLOTS*`NODE_ID_W)];
assign frontier_token_id = frontier_token_id_comb;
assign frontier_position_id = frontier_position_id_comb;

always @* begin
    prefix_last_idx_comb = {`TREE_LEVEL_ID_W{1'b0}};
    for (idx_i = 0; idx_i < `TREE_MAX_PREFIX_NODES; idx_i = idx_i + 1) begin
        if (prefix_slot_valid_r[idx_i]) begin
            prefix_last_idx_comb = idx_i[`TREE_LEVEL_ID_W-1:0];
        end
    end

    frontier_last_level_idx_comb = {`TREE_LEVEL_ID_W{1'b0}};
    for (idx_i = 0; idx_i < `TREE_MAX_FRONTIER_LEVELS; idx_i = idx_i + 1) begin
        if (frontier_level_valid_r[idx_i]) begin
            frontier_last_level_idx_comb = idx_i[`TREE_LEVEL_ID_W-1:0];
        end
    end

    frontier_token_id_comb =
        {(`TREE_FRONTIER_SLOTS*`TOKEN_ID_W){1'b0}};
    frontier_position_id_comb =
        {(`TREE_FRONTIER_SLOTS*`POSITION_ID_W){1'b0}};
    for (slot_i = 0; slot_i < `TREE_FRONTIER_SLOTS; slot_i = slot_i + 1) begin
        current_prefix_node_comb =
            frontier_node_id[(slot_i*`NODE_ID_W) +: `NODE_ID_W];
        frontier_token_id_comb[(slot_i*`TOKEN_ID_W) +: `TOKEN_ID_W] =
            {{(`TOKEN_ID_W-`NODE_ID_W){1'b0}}, current_prefix_node_comb};
        frontier_position_id_comb[(slot_i*`POSITION_ID_W) +: `POSITION_ID_W] =
            {{(`POSITION_ID_W-`NODE_ID_W){1'b0}}, current_prefix_node_comb};
    end
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state_r <= TA_STATE_IDLE;
        req_id_r <= {`REQ_ID_W{1'b0}};
        prefix_slot_valid_r <= {`TREE_MAX_PREFIX_NODES{1'b0}};
        prefix_node_id_r <= {(`TREE_MAX_PREFIX_NODES*`NODE_ID_W){1'b0}};
        frontier_level_valid_r <= {`TREE_MAX_FRONTIER_LEVELS{1'b0}};
        frontier_slot_valid_r <=
            {(`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS){1'b0}};
        frontier_node_id_r <=
            {(`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`NODE_ID_W){1'b0}};
        frontier_parent_node_id_r <=
            {(`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`NODE_ID_W){1'b0}};
        prefix_idx_r <= {`TREE_LEVEL_ID_W{1'b0}};
        frontier_level_idx_r <= {`TREE_LEVEL_ID_W{1'b0}};
    end else begin
        case (state_r)
            TA_STATE_IDLE: begin
                if (req_valid && req_ready) begin
                    req_id_r <= req_id;
                    prefix_slot_valid_r <= src_prefix_slot_valid;
                    prefix_node_id_r <= src_prefix_node_id;
                    frontier_level_valid_r <= src_frontier_level_valid;
                    frontier_slot_valid_r <= src_frontier_slot_valid;
                    frontier_node_id_r <= src_frontier_node_id;
                    frontier_parent_node_id_r <= src_frontier_parent_node_id;
                    prefix_idx_r <= {`TREE_LEVEL_ID_W{1'b0}};
                    frontier_level_idx_r <= {`TREE_LEVEL_ID_W{1'b0}};

                    if (src_prefix_slot_valid != {`TREE_MAX_PREFIX_NODES{1'b0}}) begin
                        state_r <= TA_STATE_PREFIX;
                    end else if (src_frontier_level_valid != {`TREE_MAX_FRONTIER_LEVELS{1'b0}}) begin
                        state_r <= TA_STATE_FRONTIER;
                    end
                end
            end

            TA_STATE_PREFIX: begin
                if (prefix_valid && prefix_ready) begin
                    if (prefix_idx_r == prefix_last_idx_comb) begin
                        if (frontier_level_valid_r != {`TREE_MAX_FRONTIER_LEVELS{1'b0}}) begin
                            frontier_level_idx_r <= {`TREE_LEVEL_ID_W{1'b0}};
                            state_r <= TA_STATE_FRONTIER;
                        end else begin
                            state_r <= TA_STATE_IDLE;
                        end
                    end else begin
                        prefix_idx_r <= prefix_idx_r + 1'b1;
                    end
                end
            end

            TA_STATE_FRONTIER: begin
                if (frontier_valid && frontier_ready) begin
                    if (frontier_level_idx_r == frontier_last_level_idx_comb) begin
                        state_r <= TA_STATE_IDLE;
                    end else begin
                        frontier_level_idx_r <= frontier_level_idx_r + 1'b1;
                    end
                end
            end

            default: begin
                state_r <= TA_STATE_IDLE;
            end
        endcase
    end
end

endmodule
