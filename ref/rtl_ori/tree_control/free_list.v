`timescale 1ns/1ps

`include "config/prediction_params.vh"
`include "config/interface_params.vh"
`include "config/memory_params.vh"

module free_list (
    input                        clk,
    input                        rst_n,
    input                        cand_req_valid,
    output                       cand_req_ready,
    input  [`REQ_ID_W-1:0]       cand_req_req_id,
    input  [`BRANCH_ID_W-1:0]    cand_req_branch_id,
    input  [`NODE_ID_W-1:0]      cand_req_node_id,
    input  [`KV_GROUP_LEN_W-1:0] cand_req_size_subbank,
    input                        cand_req_shared,
    output                       cand_resp_valid,
    output                       cand_resp_grant,
    output [`REQ_ID_W-1:0]       cand_resp_req_id,
    output [`SRAM_ID_W-1:0]      cand_resp_sram_id,
    output [`BANK_ID_W-1:0]      cand_resp_bank_id,
    output [`SUBBANK_ID_W-1:0]   cand_resp_subbank_start,
    output [`KV_GROUP_LEN_W-1:0] cand_resp_group_len,
    output                       alloc_cand_valid,
    output [`REQ_ID_W-1:0]       alloc_cand_req_id,
    output [`BRANCH_ID_W-1:0]    alloc_cand_branch_id,
    output [`NODE_ID_W-1:0]      alloc_cand_node_id,
    output [`KV_GROUP_LEN_W-1:0] alloc_cand_size_subbank,
    output                       alloc_cand_shared,
    output [`SRAM_ID_W-1:0]      alloc_cand_sram_id,
    output [`BANK_ID_W-1:0]      alloc_cand_bank_id,
    output [`SUBBANK_ID_W-1:0]   alloc_cand_subbank_start,
    output [`KV_GROUP_LEN_W-1:0] alloc_cand_group_len,
    input                        flush_valid,
    input  [`REQ_ID_W-1:0]       flush_req_id,
    input  [`BRANCH_MASK_W-1:0]  flush_branch_mask,
    input  [`NODE_MASK_W-1:0]    flush_node_mask,
    output                       flush_drain_busy,
    output                       flush_reclaim_valid,
    output [`SRAM_ID_W-1:0]      flush_reclaim_sram_id,
    output [`BANK_ID_W-1:0]      flush_reclaim_bank_id,
    output [`SUBBANK_ID_W-1:0]   flush_reclaim_subbank_start,
    output [`KV_GROUP_LEN_W-1:0] flush_reclaim_group_len,
    input                        release_valid,
    input  [`SRAM_ID_W-1:0]      release_sram_id,
    input  [`BANK_ID_W-1:0]      release_bank_id,
    input  [`SUBBANK_ID_W-1:0]   release_subbank_start,
    input  [`KV_GROUP_LEN_W-1:0] release_group_len
);

localparam integer TOTAL_BANKS = `SRAM_NUM * `SRAM_BANK_NUM;

reg [`SUBBANK_NUM_PER_BANK-1:0] free_bitmap [0:TOTAL_BANKS-1];
reg [`SRAM_ID_W-1:0] cursor_sram;
reg [`BANK_ID_W-1:0] cursor_bank;
reg [`SUBBANK_ID_W-1:0] cursor_subbank;

reg cand_resp_valid_r;
reg cand_resp_grant_r;
reg [`REQ_ID_W-1:0] cand_resp_req_id_r;
reg [`SRAM_ID_W-1:0] cand_resp_sram_id_r;
reg [`BANK_ID_W-1:0] cand_resp_bank_id_r;
reg [`SUBBANK_ID_W-1:0] cand_resp_subbank_start_r;
reg [`KV_GROUP_LEN_W-1:0] cand_resp_group_len_r;
reg alloc_cand_valid_r;
reg [`REQ_ID_W-1:0] alloc_cand_req_id_r;
reg [`BRANCH_ID_W-1:0] alloc_cand_branch_id_r;
reg [`NODE_ID_W-1:0] alloc_cand_node_id_r;
reg [`KV_GROUP_LEN_W-1:0] alloc_cand_size_subbank_r;
reg alloc_cand_shared_r;
reg [`SRAM_ID_W-1:0] alloc_cand_sram_id_r;
reg [`BANK_ID_W-1:0] alloc_cand_bank_id_r;
reg [`SUBBANK_ID_W-1:0] alloc_cand_subbank_start_r;
reg [`KV_GROUP_LEN_W-1:0] alloc_cand_group_len_r;
reg flush_reclaim_valid_r;
reg [`SRAM_ID_W-1:0] flush_reclaim_sram_id_r;
reg [`BANK_ID_W-1:0] flush_reclaim_bank_id_r;
reg [`SUBBANK_ID_W-1:0] flush_reclaim_subbank_start_r;
reg [`KV_GROUP_LEN_W-1:0] flush_reclaim_group_len_r;
reg [`REQ_ID_W-1:0] entry_req_id [0:TOTAL_BANKS-1][0:`SUBBANK_NUM_PER_BANK-1];
reg [`BRANCH_ID_W-1:0] entry_branch_id [0:TOTAL_BANKS-1][0:`SUBBANK_NUM_PER_BANK-1];
reg [`NODE_ID_W-1:0] entry_node_id [0:TOTAL_BANKS-1][0:`SUBBANK_NUM_PER_BANK-1];
reg entry_shared [0:TOTAL_BANKS-1][0:`SUBBANK_NUM_PER_BANK-1];
reg pending_reclaim_valid [0:TOTAL_BANKS-1][0:`SUBBANK_NUM_PER_BANK-1];
reg [`KV_GROUP_LEN_W-1:0] pending_reclaim_group_len [0:TOTAL_BANKS-1][0:`SUBBANK_NUM_PER_BANK-1];

reg search_found;
reg [`SRAM_ID_W-1:0] search_sram_id;
reg [`BANK_ID_W-1:0] search_bank_id;
reg [`SUBBANK_ID_W-1:0] search_subbank_start;
reg [`KV_GROUP_LEN_W-1:0] search_group_len;

integer req_size_i;
integer cursor_flat_i;
integer bank_offset_i;
integer bank_idx_i;
integer start_base_i;
integer start_pos_i;
integer bit_idx_i;
integer search_flat_i;
integer release_flat_i;
reg range_free;
integer init_i;
integer clear_i;
integer release_i;
integer next_flat_i;
integer next_pos_i;
integer init_subbank_i;
integer flush_flat_i;
integer flush_idx_i;
integer flush_node_bit_i;
reg flush_hit;
reg flush_prev_contiguous_hit;
reg flush_head_hit;
integer flush_range_len_i;
integer flush_len_scan_i;
reg flush_emit_claimed;
reg pending_reclaim_found_comb;
reg [`SRAM_ID_W-1:0] pending_reclaim_sram_id_comb;
reg [`BANK_ID_W-1:0] pending_reclaim_bank_id_comb;
reg [`SUBBANK_ID_W-1:0] pending_reclaim_subbank_start_comb;
reg [`KV_GROUP_LEN_W-1:0] pending_reclaim_group_len_comb;
integer pending_reclaim_flat_idx_comb;
integer pending_scan_flat_i;
integer pending_scan_idx_i;

assign cand_req_ready = 1'b1;
assign cand_resp_valid = cand_resp_valid_r;
assign cand_resp_grant = cand_resp_grant_r;
assign cand_resp_req_id = cand_resp_req_id_r;
assign cand_resp_sram_id = cand_resp_sram_id_r;
assign cand_resp_bank_id = cand_resp_bank_id_r;
assign cand_resp_subbank_start = cand_resp_subbank_start_r;
assign cand_resp_group_len = cand_resp_group_len_r;
assign alloc_cand_valid = alloc_cand_valid_r;
assign alloc_cand_req_id = alloc_cand_req_id_r;
assign alloc_cand_branch_id = alloc_cand_branch_id_r;
assign alloc_cand_node_id = alloc_cand_node_id_r;
assign alloc_cand_size_subbank = alloc_cand_size_subbank_r;
assign alloc_cand_shared = alloc_cand_shared_r;
assign alloc_cand_sram_id = alloc_cand_sram_id_r;
assign alloc_cand_bank_id = alloc_cand_bank_id_r;
assign alloc_cand_subbank_start = alloc_cand_subbank_start_r;
assign alloc_cand_group_len = alloc_cand_group_len_r;
assign flush_drain_busy = pending_reclaim_found_comb;
assign flush_reclaim_valid = flush_reclaim_valid_r;
assign flush_reclaim_sram_id = flush_reclaim_sram_id_r;
assign flush_reclaim_bank_id = flush_reclaim_bank_id_r;
assign flush_reclaim_subbank_start = flush_reclaim_subbank_start_r;
assign flush_reclaim_group_len = flush_reclaim_group_len_r;

always @* begin
    search_found = 1'b0;
    search_sram_id = {`SRAM_ID_W{1'b0}};
    search_bank_id = {`BANK_ID_W{1'b0}};
    search_subbank_start = {`SUBBANK_ID_W{1'b0}};
    search_group_len = cand_req_size_subbank;

    req_size_i = cand_req_size_subbank;
    cursor_flat_i = (cursor_sram * `SRAM_BANK_NUM) + cursor_bank;

    if ((req_size_i > 0) && (req_size_i <= `SUBBANK_NUM_PER_BANK)) begin
        for (bank_offset_i = 0; bank_offset_i < TOTAL_BANKS; bank_offset_i = bank_offset_i + 1) begin
            bank_idx_i = (cursor_flat_i + bank_offset_i) % TOTAL_BANKS;
            if (bank_offset_i == 0) begin
                start_base_i = cursor_subbank;
            end else begin
                start_base_i = 0;
            end

            for (start_pos_i = start_base_i;
                 start_pos_i <= (`SUBBANK_NUM_PER_BANK - req_size_i);
                 start_pos_i = start_pos_i + 1) begin
                range_free = 1'b1;
                for (bit_idx_i = 0; bit_idx_i < req_size_i; bit_idx_i = bit_idx_i + 1) begin
                    if (!free_bitmap[bank_idx_i][start_pos_i + bit_idx_i]) begin
                        range_free = 1'b0;
                    end
                end

                if (!search_found && range_free) begin
                    search_found = 1'b1;
                    search_sram_id = bank_idx_i / `SRAM_BANK_NUM;
                    search_bank_id = bank_idx_i % `SRAM_BANK_NUM;
                    search_subbank_start = start_pos_i[`SUBBANK_ID_W-1:0];
                    search_group_len = cand_req_size_subbank;
                end
            end
        end
    end
end

always @* begin
    pending_reclaim_found_comb = 1'b0;
    pending_reclaim_sram_id_comb = {`SRAM_ID_W{1'b0}};
    pending_reclaim_bank_id_comb = {`BANK_ID_W{1'b0}};
    pending_reclaim_subbank_start_comb = {`SUBBANK_ID_W{1'b0}};
    pending_reclaim_group_len_comb = {`KV_GROUP_LEN_W{1'b0}};
    pending_reclaim_flat_idx_comb = 0;

    for (pending_scan_flat_i = 0;
         pending_scan_flat_i < TOTAL_BANKS;
         pending_scan_flat_i = pending_scan_flat_i + 1) begin
        for (pending_scan_idx_i = 0;
             pending_scan_idx_i < `SUBBANK_NUM_PER_BANK;
             pending_scan_idx_i = pending_scan_idx_i + 1) begin
            if (!pending_reclaim_found_comb &&
                pending_reclaim_valid[pending_scan_flat_i][pending_scan_idx_i]) begin
                pending_reclaim_found_comb = 1'b1;
                pending_reclaim_sram_id_comb = pending_scan_flat_i / `SRAM_BANK_NUM;
                pending_reclaim_bank_id_comb = pending_scan_flat_i % `SRAM_BANK_NUM;
                pending_reclaim_subbank_start_comb =
                    pending_scan_idx_i[`SUBBANK_ID_W-1:0];
                pending_reclaim_group_len_comb =
                    pending_reclaim_group_len[pending_scan_flat_i][pending_scan_idx_i];
                pending_reclaim_flat_idx_comb = pending_scan_flat_i;
            end
        end
    end
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        for (init_i = 0; init_i < TOTAL_BANKS; init_i = init_i + 1) begin
            free_bitmap[init_i] <= {`SUBBANK_NUM_PER_BANK{1'b1}};
            for (init_subbank_i = 0; init_subbank_i < `SUBBANK_NUM_PER_BANK; init_subbank_i = init_subbank_i + 1) begin
                entry_req_id[init_i][init_subbank_i] <= {`REQ_ID_W{1'b0}};
                entry_branch_id[init_i][init_subbank_i] <= {`BRANCH_ID_W{1'b0}};
                entry_node_id[init_i][init_subbank_i] <= {`NODE_ID_W{1'b0}};
                entry_shared[init_i][init_subbank_i] <= 1'b0;
                pending_reclaim_valid[init_i][init_subbank_i] <= 1'b0;
                pending_reclaim_group_len[init_i][init_subbank_i] <= {`KV_GROUP_LEN_W{1'b0}};
            end
        end
        cursor_sram <= {`SRAM_ID_W{1'b0}};
        cursor_bank <= {`BANK_ID_W{1'b0}};
        cursor_subbank <= {`SUBBANK_ID_W{1'b0}};
        cand_resp_valid_r <= 1'b0;
        cand_resp_grant_r <= 1'b0;
        cand_resp_req_id_r <= {`REQ_ID_W{1'b0}};
        cand_resp_sram_id_r <= {`SRAM_ID_W{1'b0}};
        cand_resp_bank_id_r <= {`BANK_ID_W{1'b0}};
        cand_resp_subbank_start_r <= {`SUBBANK_ID_W{1'b0}};
        cand_resp_group_len_r <= {`KV_GROUP_LEN_W{1'b0}};
        alloc_cand_valid_r <= 1'b0;
        alloc_cand_req_id_r <= {`REQ_ID_W{1'b0}};
        alloc_cand_branch_id_r <= {`BRANCH_ID_W{1'b0}};
        alloc_cand_node_id_r <= {`NODE_ID_W{1'b0}};
        alloc_cand_size_subbank_r <= {`KV_GROUP_LEN_W{1'b0}};
        alloc_cand_shared_r <= 1'b0;
        alloc_cand_sram_id_r <= {`SRAM_ID_W{1'b0}};
        alloc_cand_bank_id_r <= {`BANK_ID_W{1'b0}};
        alloc_cand_subbank_start_r <= {`SUBBANK_ID_W{1'b0}};
        alloc_cand_group_len_r <= {`KV_GROUP_LEN_W{1'b0}};
        flush_reclaim_valid_r <= 1'b0;
        flush_reclaim_sram_id_r <= {`SRAM_ID_W{1'b0}};
        flush_reclaim_bank_id_r <= {`BANK_ID_W{1'b0}};
        flush_reclaim_subbank_start_r <= {`SUBBANK_ID_W{1'b0}};
        flush_reclaim_group_len_r <= {`KV_GROUP_LEN_W{1'b0}};
    end else begin
        cand_resp_valid_r <= 1'b0;
        alloc_cand_valid_r <= 1'b0;
        flush_reclaim_valid_r <= 1'b0;
        flush_reclaim_sram_id_r <= {`SRAM_ID_W{1'b0}};
        flush_reclaim_bank_id_r <= {`BANK_ID_W{1'b0}};
        flush_reclaim_subbank_start_r <= {`SUBBANK_ID_W{1'b0}};
        flush_reclaim_group_len_r <= {`KV_GROUP_LEN_W{1'b0}};

        if (release_valid) begin
            release_flat_i = (release_sram_id * `SRAM_BANK_NUM) + release_bank_id;
            for (release_i = 0; release_i < release_group_len; release_i = release_i + 1) begin
                if ((release_subbank_start + release_i) < `SUBBANK_NUM_PER_BANK) begin
                    free_bitmap[release_flat_i][release_subbank_start + release_i] <= 1'b1;
                    entry_req_id[release_flat_i][release_subbank_start + release_i] <= {`REQ_ID_W{1'b0}};
                    entry_branch_id[release_flat_i][release_subbank_start + release_i] <= {`BRANCH_ID_W{1'b0}};
                    entry_node_id[release_flat_i][release_subbank_start + release_i] <= {`NODE_ID_W{1'b0}};
                    entry_shared[release_flat_i][release_subbank_start + release_i] <= 1'b0;
                end
            end
        end

        if (flush_valid) begin
            flush_emit_claimed = 1'b0;

            for (flush_flat_i = 0; flush_flat_i < TOTAL_BANKS; flush_flat_i = flush_flat_i + 1) begin
                for (flush_idx_i = 0; flush_idx_i < `SUBBANK_NUM_PER_BANK; flush_idx_i = flush_idx_i + 1) begin
                    flush_hit = 1'b0;
                    flush_node_bit_i = 0;
                    flush_prev_contiguous_hit = 1'b0;
                    flush_head_hit = 1'b0;
                    flush_range_len_i = 0;

                    if (!free_bitmap[flush_flat_i][flush_idx_i] &&
                        !entry_shared[flush_flat_i][flush_idx_i] &&
                        (entry_req_id[flush_flat_i][flush_idx_i] == flush_req_id) &&
                        (entry_branch_id[flush_flat_i][flush_idx_i] < `BRANCH_NUM)) begin
                        flush_node_bit_i =
                            (entry_branch_id[flush_flat_i][flush_idx_i] *
                             `MAX_VERIFY_NODES_PER_BRANCH) +
                            entry_node_id[flush_flat_i][flush_idx_i];

                        if ((flush_node_bit_i < `NODE_MASK_W) &&
                            flush_branch_mask[entry_branch_id[flush_flat_i][flush_idx_i]] &&
                            flush_node_mask[flush_node_bit_i]) begin
                            flush_hit = 1'b1;
                        end
                    end

                    if (flush_hit && (flush_idx_i > 0) &&
                        !free_bitmap[flush_flat_i][flush_idx_i - 1] &&
                        !entry_shared[flush_flat_i][flush_idx_i - 1] &&
                        (entry_req_id[flush_flat_i][flush_idx_i - 1] ==
                         entry_req_id[flush_flat_i][flush_idx_i]) &&
                        (entry_branch_id[flush_flat_i][flush_idx_i - 1] ==
                         entry_branch_id[flush_flat_i][flush_idx_i]) &&
                        (entry_node_id[flush_flat_i][flush_idx_i - 1] ==
                         entry_node_id[flush_flat_i][flush_idx_i])) begin
                        flush_prev_contiguous_hit = 1'b1;
                    end

                    flush_head_hit = flush_hit && !flush_prev_contiguous_hit;

                    if (flush_head_hit) begin
                        for (flush_len_scan_i = flush_idx_i;
                             flush_len_scan_i < `SUBBANK_NUM_PER_BANK;
                             flush_len_scan_i = flush_len_scan_i + 1) begin
                            if (!free_bitmap[flush_flat_i][flush_len_scan_i] &&
                                !entry_shared[flush_flat_i][flush_len_scan_i] &&
                                (entry_req_id[flush_flat_i][flush_len_scan_i] ==
                                 entry_req_id[flush_flat_i][flush_idx_i]) &&
                                (entry_branch_id[flush_flat_i][flush_len_scan_i] ==
                                 entry_branch_id[flush_flat_i][flush_idx_i]) &&
                                (entry_node_id[flush_flat_i][flush_len_scan_i] ==
                                 entry_node_id[flush_flat_i][flush_idx_i])) begin
                                flush_range_len_i = flush_range_len_i + 1;
                            end else begin
                                flush_len_scan_i = `SUBBANK_NUM_PER_BANK;
                            end
                        end

                        if (!flush_emit_claimed) begin
                            flush_reclaim_valid_r <= 1'b1;
                            flush_reclaim_sram_id_r <= flush_flat_i / `SRAM_BANK_NUM;
                            flush_reclaim_bank_id_r <= flush_flat_i % `SRAM_BANK_NUM;
                            flush_reclaim_subbank_start_r <=
                                flush_idx_i[`SUBBANK_ID_W-1:0];
                            flush_reclaim_group_len_r <=
                                flush_range_len_i[`KV_GROUP_LEN_W-1:0];
                            flush_emit_claimed = 1'b1;
                        end else begin
                            pending_reclaim_valid[flush_flat_i][flush_idx_i] <= 1'b1;
                            pending_reclaim_group_len[flush_flat_i][flush_idx_i] <=
                                flush_range_len_i[`KV_GROUP_LEN_W-1:0];
                        end
                    end

                    if (flush_hit) begin
                        free_bitmap[flush_flat_i][flush_idx_i] <= 1'b1;
                        entry_req_id[flush_flat_i][flush_idx_i] <= {`REQ_ID_W{1'b0}};
                        entry_branch_id[flush_flat_i][flush_idx_i] <= {`BRANCH_ID_W{1'b0}};
                        entry_node_id[flush_flat_i][flush_idx_i] <= {`NODE_ID_W{1'b0}};
                        entry_shared[flush_flat_i][flush_idx_i] <= 1'b0;
                    end
                end
            end
        end else if (pending_reclaim_found_comb) begin
            flush_reclaim_valid_r <= 1'b1;
            flush_reclaim_sram_id_r <= pending_reclaim_sram_id_comb;
            flush_reclaim_bank_id_r <= pending_reclaim_bank_id_comb;
            flush_reclaim_subbank_start_r <= pending_reclaim_subbank_start_comb;
            flush_reclaim_group_len_r <= pending_reclaim_group_len_comb;
            pending_reclaim_valid[pending_reclaim_flat_idx_comb]
                                 [pending_reclaim_subbank_start_comb] <= 1'b0;
            pending_reclaim_group_len[pending_reclaim_flat_idx_comb]
                                     [pending_reclaim_subbank_start_comb] <=
                {`KV_GROUP_LEN_W{1'b0}};
        end

        if (cand_req_valid && cand_req_ready) begin
            cand_resp_valid_r <= 1'b1;
            cand_resp_grant_r <= search_found;
            cand_resp_req_id_r <= cand_req_req_id;
            cand_resp_sram_id_r <= search_sram_id;
            cand_resp_bank_id_r <= search_bank_id;
            cand_resp_subbank_start_r <= search_subbank_start;
            cand_resp_group_len_r <= cand_req_size_subbank;
            alloc_cand_valid_r <= search_found;
            alloc_cand_req_id_r <= cand_req_req_id;
            alloc_cand_branch_id_r <= cand_req_branch_id;
            alloc_cand_node_id_r <= cand_req_node_id;
            alloc_cand_size_subbank_r <= cand_req_size_subbank;
            alloc_cand_shared_r <= cand_req_shared;
            alloc_cand_sram_id_r <= search_sram_id;
            alloc_cand_bank_id_r <= search_bank_id;
            alloc_cand_subbank_start_r <= search_subbank_start;
            alloc_cand_group_len_r <= cand_req_size_subbank;

            if (search_found) begin
                search_flat_i = (search_sram_id * `SRAM_BANK_NUM) + search_bank_id;
                for (clear_i = 0; clear_i < cand_req_size_subbank; clear_i = clear_i + 1) begin
                    free_bitmap[search_flat_i][search_subbank_start + clear_i] <= 1'b0;
                    entry_req_id[search_flat_i][search_subbank_start + clear_i] <= cand_req_req_id;
                    entry_branch_id[search_flat_i][search_subbank_start + clear_i] <= cand_req_branch_id;
                    entry_node_id[search_flat_i][search_subbank_start + clear_i] <= cand_req_node_id;
                    entry_shared[search_flat_i][search_subbank_start + clear_i] <= cand_req_shared;
                end

                next_flat_i = search_flat_i;
                next_pos_i = search_subbank_start + cand_req_size_subbank;
                if (next_pos_i >= `SUBBANK_NUM_PER_BANK) begin
                    next_flat_i = (search_flat_i + 1) % TOTAL_BANKS;
                    next_pos_i = 0;
                end

                cursor_sram <= next_flat_i / `SRAM_BANK_NUM;
                cursor_bank <= next_flat_i % `SRAM_BANK_NUM;
                cursor_subbank <= next_pos_i[`SUBBANK_ID_W-1:0];
            end
        end
    end
end

endmodule
