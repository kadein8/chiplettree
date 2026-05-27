`timescale 1ns/1ps

`include "config/prediction_params.vh"
`include "config/interface_params.vh"
`include "config/memory_params.vh"

module token_register (
    input                        clk,
    input                        rst_n,
    input                        wr_valid,
    output                       wr_ready,
    input  [`TOKEN_REG_INDEX_W-1:0] wr_index,
    input  [`REQ_ID_W-1:0]       wr_req_id,
    input  [`TOKEN_ID_W-1:0]     wr_token_id,
    input  [`POSITION_ID_W-1:0]  wr_position_id,
    input  [`NODE_ID_W-1:0]      wr_node_id,
    input  [`BRANCH_ID_W-1:0]    wr_branch_id,
    input  [`SRAM_ID_W-1:0]      wr_sram_id,
    input  [`BANK_ID_W-1:0]      wr_bank_id,
    input  [`SUBBANK_ID_W-1:0]   wr_subbank_start,
    input  [`KV_GROUP_LEN_W-1:0] wr_group_len,
    input  [`BRANCH_MASK_W-1:0]  wr_branch_mask,
    input                        wr_is_shared,
    input                        lookup_valid,
    output                       lookup_ready,
    input  [`REQ_ID_W-1:0]       lookup_req_id,
    input  [`TOKEN_ID_W-1:0]     lookup_token_id,
    input  [`POSITION_ID_W-1:0]  lookup_position_id,
    output                       lookup_resp_valid,
    output                       lookup_resp_hit,
    output [`REQ_ID_W-1:0]       lookup_resp_req_id,
    output [`SRAM_ID_W-1:0]      lookup_resp_sram_id,
    output [`BANK_ID_W-1:0]      lookup_resp_bank_id,
    output [`SUBBANK_ID_W-1:0]   lookup_resp_subbank_start,
    output [`KV_GROUP_LEN_W-1:0] lookup_resp_group_len,
    output [`BRANCH_MASK_W-1:0]  lookup_resp_branch_mask,
    output                       lookup_resp_is_shared,
    output [`TOKEN_STATE_W-1:0]  lookup_resp_state,
    input                        commit_valid,
    input  [`TOKEN_REG_INDEX_W-1:0] commit_index,
    input  [`REQ_ID_W-1:0]       commit_req_id,
    input  [`BRANCH_MASK_W-1:0]  commit_branch_mask,
    input  [`NODE_MASK_W-1:0]    commit_node_mask,
    input                        flush_valid,
    input  [`REQ_ID_W-1:0]       flush_req_id,
    input  [`BRANCH_MASK_W-1:0]  flush_branch_mask,
    input  [`NODE_MASK_W-1:0]    flush_node_mask,
    output [`TOKEN_REG_INDEX_W:0] entry_count,
    output                       error_flag
);

localparam [`TOKEN_STATE_W-1:0] TOKEN_STATE_INVALID   = {`TOKEN_STATE_W{1'b0}};
localparam [`TOKEN_STATE_W-1:0] TOKEN_STATE_SPEC      = {{(`TOKEN_STATE_W-1){1'b0}}, 1'b1};
localparam [`TOKEN_STATE_W-1:0] TOKEN_STATE_COMMITTED = {{(`TOKEN_STATE_W-2){1'b0}}, 2'b10};

reg valid_entry [0:`TOKEN_REG_DEPTH-1];
reg [`REQ_ID_W-1:0] entry_req_id [0:`TOKEN_REG_DEPTH-1];
reg [`TOKEN_ID_W-1:0] entry_token_id [0:`TOKEN_REG_DEPTH-1];
reg [`POSITION_ID_W-1:0] entry_position_id [0:`TOKEN_REG_DEPTH-1];
reg [`NODE_ID_W-1:0] entry_node_id [0:`TOKEN_REG_DEPTH-1];
reg [`BRANCH_ID_W-1:0] entry_branch_id [0:`TOKEN_REG_DEPTH-1];
reg [`SRAM_ID_W-1:0] entry_sram_id [0:`TOKEN_REG_DEPTH-1];
reg [`BANK_ID_W-1:0] entry_bank_id [0:`TOKEN_REG_DEPTH-1];
reg [`SUBBANK_ID_W-1:0] entry_subbank_start [0:`TOKEN_REG_DEPTH-1];
reg [`KV_GROUP_LEN_W-1:0] entry_group_len [0:`TOKEN_REG_DEPTH-1];
reg [`BRANCH_MASK_W-1:0] entry_branch_mask [0:`TOKEN_REG_DEPTH-1];
reg entry_is_shared [0:`TOKEN_REG_DEPTH-1];
reg [`TOKEN_STATE_W-1:0] entry_state [0:`TOKEN_REG_DEPTH-1];

reg lookup_hit_comb;
reg [`REQ_ID_W-1:0] lookup_req_id_comb;
reg [`SRAM_ID_W-1:0] lookup_sram_id_comb;
reg [`BANK_ID_W-1:0] lookup_bank_id_comb;
reg [`SUBBANK_ID_W-1:0] lookup_subbank_start_comb;
reg [`KV_GROUP_LEN_W-1:0] lookup_group_len_comb;
reg [`BRANCH_MASK_W-1:0] lookup_branch_mask_comb;
reg lookup_is_shared_comb;
reg [`TOKEN_STATE_W-1:0] lookup_state_comb;

reg lookup_resp_valid_r;
reg lookup_resp_hit_r;
reg [`REQ_ID_W-1:0] lookup_resp_req_id_r;
reg [`SRAM_ID_W-1:0] lookup_resp_sram_id_r;
reg [`BANK_ID_W-1:0] lookup_resp_bank_id_r;
reg [`SUBBANK_ID_W-1:0] lookup_resp_subbank_start_r;
reg [`KV_GROUP_LEN_W-1:0] lookup_resp_group_len_r;
reg [`BRANCH_MASK_W-1:0] lookup_resp_branch_mask_r;
reg lookup_resp_is_shared_r;
reg [`TOKEN_STATE_W-1:0] lookup_resp_state_r;

reg [`TOKEN_REG_INDEX_W:0] entry_count_r;

integer idx_i;
integer count_i;
integer init_i;
reg [`BRANCH_MASK_W-1:0] next_branch_mask;

function is_node_selected;
    input [`BRANCH_ID_W-1:0] branch_id_in;
    input [`NODE_ID_W-1:0] node_id_in;
    input [`NODE_MASK_W-1:0] node_mask_in;
    integer bit_index_i;
    begin
        bit_index_i = (branch_id_in * `MAX_VERIFY_NODES_PER_BRANCH) + node_id_in;
        if ((node_id_in < `MAX_VERIFY_NODES_PER_BRANCH) && (bit_index_i < `NODE_MASK_W)) begin
            is_node_selected = node_mask_in[bit_index_i];
        end else begin
            is_node_selected = 1'b0;
        end
    end
endfunction

assign wr_ready = 1'b1;
assign lookup_ready = 1'b1;
assign lookup_resp_valid = lookup_resp_valid_r;
assign lookup_resp_hit = lookup_resp_hit_r;
assign lookup_resp_req_id = lookup_resp_req_id_r;
assign lookup_resp_sram_id = lookup_resp_sram_id_r;
assign lookup_resp_bank_id = lookup_resp_bank_id_r;
assign lookup_resp_subbank_start = lookup_resp_subbank_start_r;
assign lookup_resp_group_len = lookup_resp_group_len_r;
assign lookup_resp_branch_mask = lookup_resp_branch_mask_r;
assign lookup_resp_is_shared = lookup_resp_is_shared_r;
assign lookup_resp_state = lookup_resp_state_r;
assign entry_count = entry_count_r;
assign error_flag = 1'b0;

always @* begin
    lookup_hit_comb = 1'b0;
    lookup_req_id_comb = lookup_req_id;
    lookup_sram_id_comb = {`SRAM_ID_W{1'b0}};
    lookup_bank_id_comb = {`BANK_ID_W{1'b0}};
    lookup_subbank_start_comb = {`SUBBANK_ID_W{1'b0}};
    lookup_group_len_comb = {`KV_GROUP_LEN_W{1'b0}};
    lookup_branch_mask_comb = {`BRANCH_MASK_W{1'b0}};
    lookup_is_shared_comb = 1'b0;
    lookup_state_comb = TOKEN_STATE_INVALID;
    entry_count_r = {(`TOKEN_REG_INDEX_W+1){1'b0}};

    for (count_i = 0; count_i < `TOKEN_REG_DEPTH; count_i = count_i + 1) begin
        if (valid_entry[count_i]) begin
            entry_count_r = entry_count_r + 1'b1;
        end

        if (!lookup_hit_comb &&
            valid_entry[count_i] &&
            (entry_req_id[count_i] == lookup_req_id) &&
            (entry_token_id[count_i] == lookup_token_id) &&
            (entry_position_id[count_i] == lookup_position_id) &&
            (entry_state[count_i] != TOKEN_STATE_INVALID)) begin
            lookup_hit_comb = 1'b1;
            lookup_sram_id_comb = entry_sram_id[count_i];
            lookup_bank_id_comb = entry_bank_id[count_i];
            lookup_subbank_start_comb = entry_subbank_start[count_i];
            lookup_group_len_comb = entry_group_len[count_i];
            lookup_branch_mask_comb = entry_branch_mask[count_i];
            lookup_is_shared_comb = entry_is_shared[count_i];
            lookup_state_comb = entry_state[count_i];
        end
    end
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        for (init_i = 0; init_i < `TOKEN_REG_DEPTH; init_i = init_i + 1) begin
            valid_entry[init_i] <= 1'b0;
            entry_req_id[init_i] <= {`REQ_ID_W{1'b0}};
            entry_token_id[init_i] <= {`TOKEN_ID_W{1'b0}};
            entry_position_id[init_i] <= {`POSITION_ID_W{1'b0}};
            entry_node_id[init_i] <= {`NODE_ID_W{1'b0}};
            entry_branch_id[init_i] <= {`BRANCH_ID_W{1'b0}};
            entry_sram_id[init_i] <= {`SRAM_ID_W{1'b0}};
            entry_bank_id[init_i] <= {`BANK_ID_W{1'b0}};
            entry_subbank_start[init_i] <= {`SUBBANK_ID_W{1'b0}};
            entry_group_len[init_i] <= {`KV_GROUP_LEN_W{1'b0}};
            entry_branch_mask[init_i] <= {`BRANCH_MASK_W{1'b0}};
            entry_is_shared[init_i] <= 1'b0;
            entry_state[init_i] <= TOKEN_STATE_INVALID;
        end
        lookup_resp_valid_r <= 1'b0;
        lookup_resp_hit_r <= 1'b0;
        lookup_resp_req_id_r <= {`REQ_ID_W{1'b0}};
        lookup_resp_sram_id_r <= {`SRAM_ID_W{1'b0}};
        lookup_resp_bank_id_r <= {`BANK_ID_W{1'b0}};
        lookup_resp_subbank_start_r <= {`SUBBANK_ID_W{1'b0}};
        lookup_resp_group_len_r <= {`KV_GROUP_LEN_W{1'b0}};
        lookup_resp_branch_mask_r <= {`BRANCH_MASK_W{1'b0}};
        lookup_resp_is_shared_r <= 1'b0;
        lookup_resp_state_r <= TOKEN_STATE_INVALID;
    end else begin
        lookup_resp_valid_r <= lookup_valid;
        lookup_resp_hit_r <= lookup_hit_comb;
        lookup_resp_req_id_r <= lookup_req_id_comb;
        lookup_resp_sram_id_r <= lookup_sram_id_comb;
        lookup_resp_bank_id_r <= lookup_bank_id_comb;
        lookup_resp_subbank_start_r <= lookup_subbank_start_comb;
        lookup_resp_group_len_r <= lookup_group_len_comb;
        lookup_resp_branch_mask_r <= lookup_branch_mask_comb;
        lookup_resp_is_shared_r <= lookup_is_shared_comb;
        lookup_resp_state_r <= lookup_state_comb;

        if (wr_valid && wr_ready) begin
            valid_entry[wr_index] <= 1'b1;
            entry_req_id[wr_index] <= wr_req_id;
            entry_token_id[wr_index] <= wr_token_id;
            entry_position_id[wr_index] <= wr_position_id;
            entry_node_id[wr_index] <= wr_node_id;
            entry_branch_id[wr_index] <= wr_branch_id;
            entry_sram_id[wr_index] <= wr_sram_id;
            entry_bank_id[wr_index] <= wr_bank_id;
            entry_subbank_start[wr_index] <= wr_subbank_start;
            entry_group_len[wr_index] <= wr_group_len;
            entry_branch_mask[wr_index] <= wr_branch_mask;
            entry_is_shared[wr_index] <= wr_is_shared;
            entry_state[wr_index] <= TOKEN_STATE_SPEC;
        end

        if (commit_valid) begin
            if (valid_entry[commit_index] &&
                (entry_req_id[commit_index] == commit_req_id) &&
                is_node_selected(entry_branch_id[commit_index], entry_node_id[commit_index], commit_node_mask)) begin
                entry_branch_mask[commit_index] <= entry_branch_mask[commit_index] | commit_branch_mask;
                entry_state[commit_index] <= TOKEN_STATE_COMMITTED;
            end
        end

        if (flush_valid) begin
            for (idx_i = 0; idx_i < `TOKEN_REG_DEPTH; idx_i = idx_i + 1) begin
                if (valid_entry[idx_i] &&
                    (entry_req_id[idx_i] == flush_req_id) &&
                    is_node_selected(entry_branch_id[idx_i], entry_node_id[idx_i], flush_node_mask) &&
                    ((entry_branch_mask[idx_i] & flush_branch_mask) != {`BRANCH_MASK_W{1'b0}})) begin
                    next_branch_mask = entry_branch_mask[idx_i] & ~flush_branch_mask;
                    if (next_branch_mask == {`BRANCH_MASK_W{1'b0}}) begin
                        valid_entry[idx_i] <= 1'b0;
                        entry_branch_mask[idx_i] <= {`BRANCH_MASK_W{1'b0}};
                        entry_state[idx_i] <= TOKEN_STATE_INVALID;
                    end else begin
                        entry_branch_mask[idx_i] <= next_branch_mask;
                    end
                end
            end
        end
    end
end

endmodule
