`timescale 1ns/1ps

`include "config/prediction_params.vh"
`include "config/interface_params.vh"
`include "config/memory_params.vh"

module bank_state_table (
    input                        clk,
    input                        rst_n,
    input                        cand_valid,
    output                       cand_ready,
    input  [`REQ_ID_W-1:0]       cand_req_id,
    input  [`BRANCH_ID_W-1:0]    cand_branch_id,
    input  [`NODE_ID_W-1:0]      cand_node_id,
    input  [`KV_GROUP_LEN_W-1:0] cand_size_subbank,
    input                        cand_shared,
    input  [`SRAM_ID_W-1:0]      cand_sram_id,
    input  [`BANK_ID_W-1:0]      cand_bank_id,
    input  [`SUBBANK_ID_W-1:0]   cand_subbank_start,
    input  [`KV_GROUP_LEN_W-1:0] cand_group_len,
    output                       alloc_resp_valid,
    output                       alloc_resp_grant,
    output [`REQ_ID_W-1:0]       alloc_resp_req_id,
    output [`SRAM_ID_W-1:0]      alloc_resp_sram_id,
    output [`BANK_ID_W-1:0]      alloc_resp_bank_id,
    output [`SUBBANK_ID_W-1:0]   alloc_resp_subbank_start,
    output [`KV_GROUP_LEN_W-1:0] alloc_resp_group_len,
    output [`BANK_OCC_BITMAP_W-1:0] alloc_resp_occ_bitmap,
    input                        commit_valid,
    input  [`REQ_ID_W-1:0]       commit_req_id,
    input  [`SRAM_ID_W-1:0]      commit_sram_id,
    input  [`BANK_ID_W-1:0]      commit_bank_id,
    input  [`SUBBANK_ID_W-1:0]   commit_subbank_start,
    input  [`KV_GROUP_LEN_W-1:0] commit_group_len,
    input  [`BRANCH_MASK_W-1:0]  commit_branch_mask,
    input  [`NODE_MASK_W-1:0]    commit_node_mask,
    input                        flush_valid,
    input  [`REQ_ID_W-1:0]       flush_req_id,
    input  [`BRANCH_MASK_W-1:0]  flush_branch_mask,
    input  [`NODE_MASK_W-1:0]    flush_node_mask,
    input                        reclaim_valid,
    input  [`SRAM_ID_W-1:0]      reclaim_sram_id,
    input  [`BANK_ID_W-1:0]      reclaim_bank_id,
    input  [`SUBBANK_ID_W-1:0]   reclaim_subbank_start,
    input  [`KV_GROUP_LEN_W-1:0] reclaim_group_len,
    input                        query_valid,
    input  [`SRAM_ID_W-1:0]      query_sram_id,
    input  [`BANK_ID_W-1:0]      query_bank_id,
    output                       query_resp_valid,
    output [`BANK_OCC_BITMAP_W-1:0] query_resp_occ_bitmap,
    output [`BANK_STATE_W-1:0]   query_resp_state,
    output [`BRANCH_MASK_W-1:0]  query_resp_branch_mask,
    output [`REFCNT_W-1:0]       query_resp_refcnt
);

localparam integer TOTAL_BANKS = `SRAM_NUM * `SRAM_BANK_NUM;
localparam [`BANK_STATE_W-1:0] BANK_STATE_FREE = {`BANK_STATE_W{1'b0}};
localparam [`BANK_STATE_W-1:0] BANK_STATE_SPEC = {{(`BANK_STATE_W-1){1'b0}}, 1'b1};
localparam [`BANK_STATE_W-1:0] BANK_STATE_COMMITTED = {{(`BANK_STATE_W-2){1'b0}}, 2'b10};

reg [`SUBBANK_NUM_PER_BANK-1:0] occ_bitmap [0:TOTAL_BANKS-1];
reg [`SUBBANK_NUM_PER_BANK-1:0] committed_bitmap [0:TOTAL_BANKS-1];
reg [`BRANCH_MASK_W-1:0] owner_mask [0:TOTAL_BANKS-1][0:`SUBBANK_NUM_PER_BANK-1];
reg [`REQ_ID_W-1:0] entry_req_id [0:TOTAL_BANKS-1][0:`SUBBANK_NUM_PER_BANK-1];
reg [`NODE_ID_W-1:0] entry_node_id [0:TOTAL_BANKS-1][0:`SUBBANK_NUM_PER_BANK-1];

reg alloc_resp_valid_r;
reg alloc_resp_grant_r;
reg [`REQ_ID_W-1:0] alloc_resp_req_id_r;
reg [`SRAM_ID_W-1:0] alloc_resp_sram_id_r;
reg [`BANK_ID_W-1:0] alloc_resp_bank_id_r;
reg [`SUBBANK_ID_W-1:0] alloc_resp_subbank_start_r;
reg [`KV_GROUP_LEN_W-1:0] alloc_resp_group_len_r;
reg [`BANK_OCC_BITMAP_W-1:0] alloc_resp_occ_bitmap_r;

reg query_resp_valid_r;
reg [`BANK_OCC_BITMAP_W-1:0] query_resp_occ_bitmap_r;
reg [`BANK_STATE_W-1:0] query_resp_state_r;
reg [`BRANCH_MASK_W-1:0] query_resp_branch_mask_r;
reg [`REFCNT_W-1:0] query_resp_refcnt_r;

reg cand_grant;
reg [`BANK_OCC_BITMAP_W-1:0] cand_occ_bitmap;
reg [`BRANCH_MASK_W-1:0] cand_branch_onehot;
reg query_any_occ;
reg query_any_committed;
reg [`BRANCH_MASK_W-1:0] query_branch_union;
reg [`REFCNT_W-1:0] query_refcnt_sum;

integer req_size_i;
integer cand_flat_i;
integer query_flat_i;
integer flush_flat_i;
integer reclaim_flat_i;
integer commit_flat_i;
integer bit_idx_i;
integer query_idx_i;
integer query_count_i;
integer flush_idx_i;
integer reclaim_idx_i;
integer commit_idx_i;
integer init_bank_i;
integer init_subbank_i;
reg range_free;
reg [`BRANCH_MASK_W-1:0] new_owner_mask;
reg [`BRANCH_MASK_W-1:0] selected_node_branch_mask;
reg [`BRANCH_MASK_W-1:0] commit_selected_mask;
reg [`BRANCH_MASK_W-1:0] flush_selected_mask;

function [`BRANCH_MASK_W-1:0] node_branch_select_mask;
    input [`NODE_ID_W-1:0] node_id_in;
    input [`NODE_MASK_W-1:0] node_mask_in;
    integer branch_idx_i;
    integer bit_index_i;
    begin
        node_branch_select_mask = {`BRANCH_MASK_W{1'b0}};
        if (node_id_in < `MAX_VERIFY_NODES_PER_BRANCH) begin
            for (branch_idx_i = 0; branch_idx_i < `BRANCH_NUM; branch_idx_i = branch_idx_i + 1) begin
                bit_index_i = (branch_idx_i * `MAX_VERIFY_NODES_PER_BRANCH) + node_id_in;
                if (bit_index_i < `NODE_MASK_W) begin
                    node_branch_select_mask[branch_idx_i] = node_mask_in[bit_index_i];
                end
            end
        end
    end
endfunction

assign cand_ready = 1'b1;
assign alloc_resp_valid = alloc_resp_valid_r;
assign alloc_resp_grant = alloc_resp_grant_r;
assign alloc_resp_req_id = alloc_resp_req_id_r;
assign alloc_resp_sram_id = alloc_resp_sram_id_r;
assign alloc_resp_bank_id = alloc_resp_bank_id_r;
assign alloc_resp_subbank_start = alloc_resp_subbank_start_r;
assign alloc_resp_group_len = alloc_resp_group_len_r;
assign alloc_resp_occ_bitmap = alloc_resp_occ_bitmap_r;
assign query_resp_valid = query_resp_valid_r;
assign query_resp_occ_bitmap = query_resp_occ_bitmap_r;
assign query_resp_state = query_resp_state_r;
assign query_resp_branch_mask = query_resp_branch_mask_r;
assign query_resp_refcnt = query_resp_refcnt_r;

always @* begin
    cand_grant = 1'b0;
    cand_occ_bitmap = {`BANK_OCC_BITMAP_W{1'b0}};
    cand_branch_onehot = {`BRANCH_MASK_W{1'b0}};
    req_size_i = cand_group_len;
    cand_flat_i = (cand_sram_id * `SRAM_BANK_NUM) + cand_bank_id;

    if (cand_branch_id < `BRANCH_NUM) begin
        cand_branch_onehot[cand_branch_id] = 1'b1;
    end

    if ((req_size_i > 0) && (req_size_i == cand_size_subbank) &&
        ((cand_subbank_start + req_size_i) <= `SUBBANK_NUM_PER_BANK)) begin
        range_free = 1'b1;
        for (bit_idx_i = 0; bit_idx_i < req_size_i; bit_idx_i = bit_idx_i + 1) begin
            if (occ_bitmap[cand_flat_i][cand_subbank_start + bit_idx_i]) begin
                range_free = 1'b0;
            end
        end

        if (range_free) begin
            cand_grant = 1'b1;
            cand_occ_bitmap = occ_bitmap[cand_flat_i];
            for (bit_idx_i = 0; bit_idx_i < req_size_i; bit_idx_i = bit_idx_i + 1) begin
                cand_occ_bitmap[cand_subbank_start + bit_idx_i] = 1'b1;
            end
        end
    end

    query_resp_valid_r = query_valid;
    query_resp_occ_bitmap_r = {`BANK_OCC_BITMAP_W{1'b0}};
    query_resp_state_r = BANK_STATE_FREE;
    query_resp_branch_mask_r = {`BRANCH_MASK_W{1'b0}};
    query_resp_refcnt_r = {`REFCNT_W{1'b0}};
    query_any_occ = 1'b0;
    query_any_committed = 1'b0;
    query_branch_union = {`BRANCH_MASK_W{1'b0}};
    query_refcnt_sum = {`REFCNT_W{1'b0}};
    query_flat_i = (query_sram_id * `SRAM_BANK_NUM) + query_bank_id;

    if (query_valid) begin
        query_resp_occ_bitmap_r = occ_bitmap[query_flat_i];
        for (query_idx_i = 0; query_idx_i < `SUBBANK_NUM_PER_BANK; query_idx_i = query_idx_i + 1) begin
            if (occ_bitmap[query_flat_i][query_idx_i]) begin
                query_any_occ = 1'b1;
            end
            if (committed_bitmap[query_flat_i][query_idx_i]) begin
                query_any_committed = 1'b1;
            end
            query_branch_union = query_branch_union | owner_mask[query_flat_i][query_idx_i];
        end

        for (query_count_i = 0; query_count_i < `BRANCH_MASK_W; query_count_i = query_count_i + 1) begin
            if (query_branch_union[query_count_i]) begin
                query_refcnt_sum = query_refcnt_sum + 1'b1;
            end
        end

        query_resp_branch_mask_r = query_branch_union;
        query_resp_refcnt_r = query_refcnt_sum;
        if (query_any_committed) begin
            query_resp_state_r = BANK_STATE_COMMITTED;
        end else if (query_any_occ) begin
            query_resp_state_r = BANK_STATE_SPEC;
        end
    end
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        for (init_bank_i = 0; init_bank_i < TOTAL_BANKS; init_bank_i = init_bank_i + 1) begin
            occ_bitmap[init_bank_i] <= {`SUBBANK_NUM_PER_BANK{1'b0}};
            committed_bitmap[init_bank_i] <= {`SUBBANK_NUM_PER_BANK{1'b0}};
            for (init_subbank_i = 0; init_subbank_i < `SUBBANK_NUM_PER_BANK; init_subbank_i = init_subbank_i + 1) begin
                owner_mask[init_bank_i][init_subbank_i] <= {`BRANCH_MASK_W{1'b0}};
                entry_req_id[init_bank_i][init_subbank_i] <= {`REQ_ID_W{1'b0}};
                entry_node_id[init_bank_i][init_subbank_i] <= {`NODE_ID_W{1'b0}};
            end
        end
        alloc_resp_valid_r <= 1'b0;
        alloc_resp_grant_r <= 1'b0;
        alloc_resp_req_id_r <= {`REQ_ID_W{1'b0}};
        alloc_resp_sram_id_r <= {`SRAM_ID_W{1'b0}};
        alloc_resp_bank_id_r <= {`BANK_ID_W{1'b0}};
        alloc_resp_subbank_start_r <= {`SUBBANK_ID_W{1'b0}};
        alloc_resp_group_len_r <= {`KV_GROUP_LEN_W{1'b0}};
        alloc_resp_occ_bitmap_r <= {`BANK_OCC_BITMAP_W{1'b0}};
    end else begin
        alloc_resp_valid_r <= 1'b0;

        if (reclaim_valid) begin
            reclaim_flat_i = (reclaim_sram_id * `SRAM_BANK_NUM) + reclaim_bank_id;
            for (reclaim_idx_i = 0; reclaim_idx_i < reclaim_group_len; reclaim_idx_i = reclaim_idx_i + 1) begin
                if ((reclaim_subbank_start + reclaim_idx_i) < `SUBBANK_NUM_PER_BANK) begin
                    occ_bitmap[reclaim_flat_i][reclaim_subbank_start + reclaim_idx_i] <= 1'b0;
                    committed_bitmap[reclaim_flat_i][reclaim_subbank_start + reclaim_idx_i] <= 1'b0;
                    owner_mask[reclaim_flat_i][reclaim_subbank_start + reclaim_idx_i] <= {`BRANCH_MASK_W{1'b0}};
                    entry_req_id[reclaim_flat_i][reclaim_subbank_start + reclaim_idx_i] <= {`REQ_ID_W{1'b0}};
                    entry_node_id[reclaim_flat_i][reclaim_subbank_start + reclaim_idx_i] <= {`NODE_ID_W{1'b0}};
                end
            end
        end

        if (flush_valid) begin
            for (flush_flat_i = 0; flush_flat_i < TOTAL_BANKS; flush_flat_i = flush_flat_i + 1) begin
                for (flush_idx_i = 0; flush_idx_i < `SUBBANK_NUM_PER_BANK; flush_idx_i = flush_idx_i + 1) begin
                    selected_node_branch_mask =
                        node_branch_select_mask(entry_node_id[flush_flat_i][flush_idx_i], flush_node_mask);
                    flush_selected_mask =
                        owner_mask[flush_flat_i][flush_idx_i] &
                        flush_branch_mask &
                        selected_node_branch_mask;
                    new_owner_mask = owner_mask[flush_flat_i][flush_idx_i] & ~flush_selected_mask;
                    if ((occ_bitmap[flush_flat_i][flush_idx_i]) &&
                        (entry_req_id[flush_flat_i][flush_idx_i] == flush_req_id) &&
                        (flush_selected_mask != {`BRANCH_MASK_W{1'b0}})) begin
                        owner_mask[flush_flat_i][flush_idx_i] <= new_owner_mask;
                        if (!committed_bitmap[flush_flat_i][flush_idx_i] &&
                            (new_owner_mask == {`BRANCH_MASK_W{1'b0}})) begin
                            occ_bitmap[flush_flat_i][flush_idx_i] <= 1'b0;
                            entry_req_id[flush_flat_i][flush_idx_i] <= {`REQ_ID_W{1'b0}};
                            entry_node_id[flush_flat_i][flush_idx_i] <= {`NODE_ID_W{1'b0}};
                        end
                    end
                end
            end
        end

        if (commit_valid) begin
            commit_flat_i = (commit_sram_id * `SRAM_BANK_NUM) + commit_bank_id;
            for (commit_idx_i = 0; commit_idx_i < commit_group_len; commit_idx_i = commit_idx_i + 1) begin
                if ((commit_subbank_start + commit_idx_i) < `SUBBANK_NUM_PER_BANK) begin
                    selected_node_branch_mask =
                        node_branch_select_mask(
                            entry_node_id[commit_flat_i][commit_subbank_start + commit_idx_i],
                            commit_node_mask
                        );
                    commit_selected_mask =
                        commit_branch_mask &
                        selected_node_branch_mask;
                    if (occ_bitmap[commit_flat_i][commit_subbank_start + commit_idx_i] &&
                        (entry_req_id[commit_flat_i][commit_subbank_start + commit_idx_i] == commit_req_id) &&
                        (commit_selected_mask != {`BRANCH_MASK_W{1'b0}})) begin
                        committed_bitmap[commit_flat_i][commit_subbank_start + commit_idx_i] <= 1'b1;
                        owner_mask[commit_flat_i][commit_subbank_start + commit_idx_i] <=
                            owner_mask[commit_flat_i][commit_subbank_start + commit_idx_i] |
                            commit_selected_mask;
                    end
                end
            end
        end

        if (cand_valid && cand_ready) begin
            alloc_resp_valid_r <= 1'b1;
            alloc_resp_grant_r <= cand_grant;
            alloc_resp_req_id_r <= cand_req_id;
            alloc_resp_sram_id_r <= cand_sram_id;
            alloc_resp_bank_id_r <= cand_bank_id;
            alloc_resp_subbank_start_r <= cand_subbank_start;
            alloc_resp_group_len_r <= cand_group_len;
            alloc_resp_occ_bitmap_r <= cand_occ_bitmap;

            if (cand_grant) begin
                for (bit_idx_i = 0; bit_idx_i < cand_group_len; bit_idx_i = bit_idx_i + 1) begin
                    occ_bitmap[cand_flat_i][cand_subbank_start + bit_idx_i] <= 1'b1;
                    committed_bitmap[cand_flat_i][cand_subbank_start + bit_idx_i] <= 1'b0;
                    owner_mask[cand_flat_i][cand_subbank_start + bit_idx_i] <= cand_branch_onehot;
                    entry_req_id[cand_flat_i][cand_subbank_start + bit_idx_i] <= cand_req_id;
                    entry_node_id[cand_flat_i][cand_subbank_start + bit_idx_i] <= cand_node_id;
                end
            end
        end
    end
end

endmodule
