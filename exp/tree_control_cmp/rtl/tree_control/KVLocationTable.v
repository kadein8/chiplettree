`include "config/interface_params.vh"
`include "config/memory_params.vh"
`timescale 1ns/1ps

module KVLocationTable #(
    parameter integer ENTRY_NUM = 8
) (
    input                         clk,
    input                         rst_n,
    input                         wr_valid,
    input  [`TOKEN_ID_W-1:0]      wr_token_id,
    input  [`POSITION_ID_W-1:0]   wr_position_id,
    input  [`SRAM_ID_W-1:0]       wr_sram_id,
    input  [`BANK_ID_W-1:0]       wr_bank_id,
    input  [`SUBBANK_ID_W-1:0]    wr_subbank_start,
    input  [`KV_GROUP_LEN_W-1:0]  wr_group_len,
    input                         lookup_valid,
    input  [`TOKEN_ID_W-1:0]      lookup_token_id,
    input  [`POSITION_ID_W-1:0]   lookup_position_id,
    output                        lookup_ready,
    output                        lookup_hit,
    output [`SRAM_ID_W-1:0]       lookup_sram_id,
    output [`BANK_ID_W-1:0]       lookup_bank_id,
    output [`SUBBANK_ID_W-1:0]    lookup_subbank_start,
    output [`KV_GROUP_LEN_W-1:0]  lookup_group_len,
    input                         tree_lookup_valid,
    input  [`TOKEN_ID_W-1:0]      tree_lookup_token_id,
    input  [`POSITION_ID_W-1:0]   tree_lookup_position_id,
    output                        tree_lookup_ready,
    output                        tree_lookup_hit,
    output [`SRAM_ID_W-1:0]       tree_lookup_sram_id,
    output [`BANK_ID_W-1:0]       tree_lookup_bank_id,
    output [`SUBBANK_ID_W-1:0]    tree_lookup_subbank_start,
    output [`KV_GROUP_LEN_W-1:0]  tree_lookup_group_len
);

localparam integer ENTRY_IDX_W = (ENTRY_NUM <= 1) ? 1 : $clog2(ENTRY_NUM);

reg valid_r [0:ENTRY_NUM-1];
reg [`TOKEN_ID_W-1:0] token_id_r [0:ENTRY_NUM-1];
reg [`POSITION_ID_W-1:0] position_id_r [0:ENTRY_NUM-1];
reg [`SRAM_ID_W-1:0] sram_id_r [0:ENTRY_NUM-1];
reg [`BANK_ID_W-1:0] bank_id_r [0:ENTRY_NUM-1];
reg [`SUBBANK_ID_W-1:0] subbank_start_r [0:ENTRY_NUM-1];
reg [`KV_GROUP_LEN_W-1:0] group_len_r [0:ENTRY_NUM-1];

reg wr_hit_found_w;
reg wr_empty_found_w;
reg [ENTRY_IDX_W-1:0] wr_index_w;

reg lookup_hit_w;
reg [`SRAM_ID_W-1:0] lookup_sram_id_w;
reg [`BANK_ID_W-1:0] lookup_bank_id_w;
reg [`SUBBANK_ID_W-1:0] lookup_subbank_start_w;
reg [`KV_GROUP_LEN_W-1:0] lookup_group_len_w;
reg tree_lookup_hit_w;
reg [`SRAM_ID_W-1:0] tree_lookup_sram_id_w;
reg [`BANK_ID_W-1:0] tree_lookup_bank_id_w;
reg [`SUBBANK_ID_W-1:0] tree_lookup_subbank_start_w;
reg [`KV_GROUP_LEN_W-1:0] tree_lookup_group_len_w;

integer idx;
integer init_idx;

assign lookup_ready = 1'b1;
assign lookup_hit = lookup_hit_w;
assign lookup_sram_id = lookup_sram_id_w;
assign lookup_bank_id = lookup_bank_id_w;
assign lookup_subbank_start = lookup_subbank_start_w;
assign lookup_group_len = lookup_group_len_w;
assign tree_lookup_ready = 1'b1;
assign tree_lookup_hit = tree_lookup_hit_w;
assign tree_lookup_sram_id = tree_lookup_sram_id_w;
assign tree_lookup_bank_id = tree_lookup_bank_id_w;
assign tree_lookup_subbank_start = tree_lookup_subbank_start_w;
assign tree_lookup_group_len = tree_lookup_group_len_w;

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
    lookup_sram_id_w = {`SRAM_ID_W{1'b0}};
    lookup_bank_id_w = {`BANK_ID_W{1'b0}};
    lookup_subbank_start_w = {`SUBBANK_ID_W{1'b0}};
    lookup_group_len_w = {`KV_GROUP_LEN_W{1'b0}};

    if (lookup_valid === 1'b1) begin
        for (idx = 0; idx < ENTRY_NUM; idx = idx + 1) begin
            if (!lookup_hit_w &&
                valid_r[idx] &&
                (token_id_r[idx] == lookup_token_id) &&
                (position_id_r[idx] == lookup_position_id)) begin
                lookup_hit_w = 1'b1;
                lookup_sram_id_w = sram_id_r[idx];
                lookup_bank_id_w = bank_id_r[idx];
                lookup_subbank_start_w = subbank_start_r[idx];
                lookup_group_len_w = group_len_r[idx];
            end
        end
    end

    tree_lookup_hit_w = 1'b0;
    tree_lookup_sram_id_w = {`SRAM_ID_W{1'b0}};
    tree_lookup_bank_id_w = {`BANK_ID_W{1'b0}};
    tree_lookup_subbank_start_w = {`SUBBANK_ID_W{1'b0}};
    tree_lookup_group_len_w = {`KV_GROUP_LEN_W{1'b0}};

    if (tree_lookup_valid === 1'b1) begin
        for (idx = 0; idx < ENTRY_NUM; idx = idx + 1) begin
            if (!tree_lookup_hit_w &&
                valid_r[idx] &&
                (token_id_r[idx] == tree_lookup_token_id) &&
                (position_id_r[idx] == tree_lookup_position_id)) begin
                tree_lookup_hit_w = 1'b1;
                tree_lookup_sram_id_w = sram_id_r[idx];
                tree_lookup_bank_id_w = bank_id_r[idx];
                tree_lookup_subbank_start_w = subbank_start_r[idx];
                tree_lookup_group_len_w = group_len_r[idx];
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
            sram_id_r[init_idx] <= {`SRAM_ID_W{1'b0}};
            bank_id_r[init_idx] <= {`BANK_ID_W{1'b0}};
            subbank_start_r[init_idx] <= {`SUBBANK_ID_W{1'b0}};
            group_len_r[init_idx] <= {`KV_GROUP_LEN_W{1'b0}};
        end
    end else if (wr_valid) begin
        valid_r[wr_index_w] <= 1'b1;
        token_id_r[wr_index_w] <= wr_token_id;
        position_id_r[wr_index_w] <= wr_position_id;
        sram_id_r[wr_index_w] <= wr_sram_id;
        bank_id_r[wr_index_w] <= wr_bank_id;
        subbank_start_r[wr_index_w] <= wr_subbank_start;
        group_len_r[wr_index_w] <= wr_group_len;
    end
end

endmodule
