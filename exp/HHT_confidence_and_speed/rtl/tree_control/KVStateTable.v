`include "config/interface_params.vh"
`timescale 1ns/1ps

module KVStateTable #(
    parameter integer ENTRY_NUM = 8
) (
    input                        clk,
    input                        rst_n,
    input                        wr_valid,
    input  [`TOKEN_ID_W-1:0]     wr_token_id,
    input  [`POSITION_ID_W-1:0]  wr_position_id,
    input                        wr_partial_ready,
    input                        wr_full_ready,
    input                        lookup_valid,
    input  [`TOKEN_ID_W-1:0]     lookup_token_id,
    input  [`POSITION_ID_W-1:0]  lookup_position_id,
    output                       lookup_ready,
    output                       lookup_hit,
    output                       lookup_partial_ready,
    output                       lookup_full_ready,
    input                        tree_lookup_valid,
    input  [`TOKEN_ID_W-1:0]     tree_lookup_token_id,
    input  [`POSITION_ID_W-1:0]  tree_lookup_position_id,
    output                       tree_lookup_ready,
    output                       tree_lookup_hit,
    output                       tree_lookup_partial_ready,
    output                       tree_lookup_full_ready
);

localparam integer ENTRY_IDX_W = (ENTRY_NUM <= 1) ? 1 : $clog2(ENTRY_NUM);

reg valid_r [0:ENTRY_NUM-1];
reg [`TOKEN_ID_W-1:0] token_id_r [0:ENTRY_NUM-1];
reg [`POSITION_ID_W-1:0] position_id_r [0:ENTRY_NUM-1];
reg partial_ready_r [0:ENTRY_NUM-1];
reg full_ready_r [0:ENTRY_NUM-1];

reg wr_hit_found_w;
reg wr_empty_found_w;
reg [ENTRY_IDX_W-1:0] wr_index_w;

reg lookup_hit_w;
reg lookup_partial_ready_w;
reg lookup_full_ready_w;
reg tree_lookup_hit_w;
reg tree_lookup_partial_ready_w;
reg tree_lookup_full_ready_w;

integer idx;
integer init_idx;

assign lookup_ready = 1'b1;
assign lookup_hit = lookup_hit_w;
assign lookup_partial_ready = lookup_partial_ready_w;
assign lookup_full_ready = lookup_full_ready_w;
assign tree_lookup_ready = 1'b1;
assign tree_lookup_hit = tree_lookup_hit_w;
assign tree_lookup_partial_ready = tree_lookup_partial_ready_w;
assign tree_lookup_full_ready = tree_lookup_full_ready_w;

always @* begin
    wr_hit_found_w = 1'b0;
    wr_empty_found_w = 1'b0;
    wr_index_w = {ENTRY_IDX_W{1'b0}};

    for (idx = 0; idx < ENTRY_NUM; idx = idx + 1) begin
        if (!wr_hit_found_w &&
            valid_r[idx] &&
            (token_id_r[idx] == wr_token_id) &&
            (position_id_r[idx] == wr_position_id)) begin
            wr_hit_found_w = 1'b1;
            wr_index_w = idx[ENTRY_IDX_W-1:0];
        end
    end

    if (!wr_hit_found_w) begin
        for (idx = 0; idx < ENTRY_NUM; idx = idx + 1) begin
            if (!wr_empty_found_w && !valid_r[idx]) begin
                wr_empty_found_w = 1'b1;
                wr_index_w = idx[ENTRY_IDX_W-1:0];
            end
        end
    end

    lookup_hit_w = 1'b0;
    lookup_partial_ready_w = 1'b0;
    lookup_full_ready_w = 1'b0;

    if (lookup_valid === 1'b1) begin
        for (idx = 0; idx < ENTRY_NUM; idx = idx + 1) begin
            if (!lookup_hit_w &&
                valid_r[idx] &&
                (token_id_r[idx] == lookup_token_id) &&
                (position_id_r[idx] == lookup_position_id)) begin
                lookup_hit_w = 1'b1;
                lookup_partial_ready_w = partial_ready_r[idx];
                lookup_full_ready_w = full_ready_r[idx];
            end
        end
    end

    tree_lookup_hit_w = 1'b0;
    tree_lookup_partial_ready_w = 1'b0;
    tree_lookup_full_ready_w = 1'b0;

    if (tree_lookup_valid === 1'b1) begin
        for (idx = 0; idx < ENTRY_NUM; idx = idx + 1) begin
            if (!tree_lookup_hit_w &&
                valid_r[idx] &&
                (token_id_r[idx] == tree_lookup_token_id) &&
                (position_id_r[idx] == tree_lookup_position_id)) begin
                tree_lookup_hit_w = 1'b1;
                tree_lookup_partial_ready_w = partial_ready_r[idx];
                tree_lookup_full_ready_w = full_ready_r[idx];
            end
        end
    end
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        for (init_idx = 0; init_idx < ENTRY_NUM; init_idx = init_idx + 1) begin
            valid_r[init_idx] <= 1'b0;
            token_id_r[init_idx] <= {`TOKEN_ID_W{1'b0}};
            position_id_r[init_idx] <= {`POSITION_ID_W{1'b0}};
            partial_ready_r[init_idx] <= 1'b0;
            full_ready_r[init_idx] <= 1'b0;
        end
    end else if (wr_valid) begin
        valid_r[wr_index_w] <= 1'b1;
        token_id_r[wr_index_w] <= wr_token_id;
        position_id_r[wr_index_w] <= wr_position_id;
        partial_ready_r[wr_index_w] <= wr_partial_ready;
        full_ready_r[wr_index_w] <= wr_full_ready;
    end
end

endmodule
