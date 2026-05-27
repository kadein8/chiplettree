`timescale 1ns/1ps

`include "config/prediction_params.vh"
`include "config/interface_params.vh"
`include "config/memory_params.vh"

module tb_comparator_bank_state_table_flush;

localparam integer TOTAL_GROUPS =
    (`SRAM_NUM * `SRAM_BANK_NUM *
     (`SUBBANK_NUM_PER_BANK / `KV_GROUP_SIZE_SUBBANK));
localparam integer FILLER_ALLOC_COUNT = (TOTAL_GROUPS - 2);

reg clk;
reg rst_n;

reg [`REQ_ID_W-1:0] cmp_req_id;
reg [`BRANCH_NUM-1:0] cmp_slot_valid;
reg [`BRANCH_NUM*`TOKEN_ID_W-1:0] cmp_slot_real_token_id;
reg [`BRANCH_NUM*`TOKEN_ID_W-1:0] cmp_slot_candidate_token_id;
reg [`BRANCH_NUM*`NODE_ID_W-1:0] cmp_slot_node_id;
reg [`BRANCH_NUM*`NODE_ID_W-1:0] cmp_slot_parent_node_id;
reg [`BRANCH_NUM*`BRANCH_ID_W-1:0] cmp_slot_branch_id;

wire commit_valid;
wire [`BRANCH_MASK_W-1:0] commit_branch_mask;
wire [`NODE_MASK_W-1:0] commit_node_mask;
wire flush_valid;
wire [`BRANCH_MASK_W-1:0] flush_branch_mask;
wire [`NODE_MASK_W-1:0] flush_node_mask;
wire flush_freeze;

reg tree_in_valid;
wire tree_in_ready;
reg [`REQ_ID_W-1:0] tree_in_req_id;
reg [`BRANCH_ID_W-1:0] tree_in_branch_id;
reg [`NODE_ID_W-1:0] tree_in_node_id;

wire prefix_ready;
wire frontier_ready;

wire prefetch_enq_ready;
wire prefetch_enq_valid;
wire [`REQ_ID_W-1:0] prefetch_enq_req_id;
wire [`BRANCH_ID_W-1:0] prefetch_enq_branch_id;
wire [`NODE_ID_W-1:0] prefetch_enq_node_id;
wire [`LAYER_ID_W-1:0] prefetch_enq_layer_id;
wire [`KV_GROUP_LEN_W-1:0] prefetch_enq_size_subbank;
wire prefetch_enq_shared;

wire prefetch_flush_valid;
wire [`REQ_ID_W-1:0] prefetch_flush_req_id;
wire [`BRANCH_MASK_W-1:0] prefetch_flush_branch_mask;
wire [`NODE_MASK_W-1:0] prefetch_flush_node_mask;

wire free_list_flush_valid;
wire [`REQ_ID_W-1:0] free_list_flush_req_id;
wire [`BRANCH_MASK_W-1:0] free_list_flush_branch_mask;
wire [`NODE_MASK_W-1:0] free_list_flush_node_mask;

wire queue_deq_valid;
wire queue_deq_ready;
wire [`REQ_ID_W-1:0] queue_deq_req_id;
wire [`BRANCH_ID_W-1:0] queue_deq_branch_id;
wire [`NODE_ID_W-1:0] queue_deq_node_id;
wire [`LAYER_ID_W-1:0] queue_deq_layer_id;
wire [`KV_GROUP_LEN_W-1:0] queue_deq_size_subbank;
wire queue_deq_shared;

wire cand_resp_valid;
wire cand_resp_grant;
wire [`REQ_ID_W-1:0] cand_resp_req_id;
wire [`SRAM_ID_W-1:0] cand_resp_sram_id;
wire [`BANK_ID_W-1:0] cand_resp_bank_id;
wire [`SUBBANK_ID_W-1:0] cand_resp_subbank_start;
wire [`KV_GROUP_LEN_W-1:0] cand_resp_group_len;

wire alloc_cand_valid;
wire [`REQ_ID_W-1:0] alloc_cand_req_id;
wire [`BRANCH_ID_W-1:0] alloc_cand_branch_id;
wire [`NODE_ID_W-1:0] alloc_cand_node_id;
wire [`KV_GROUP_LEN_W-1:0] alloc_cand_size_subbank;
wire alloc_cand_shared;
wire [`SRAM_ID_W-1:0] alloc_cand_sram_id;
wire [`BANK_ID_W-1:0] alloc_cand_bank_id;
wire [`SUBBANK_ID_W-1:0] alloc_cand_subbank_start;
wire [`KV_GROUP_LEN_W-1:0] alloc_cand_group_len;

wire flush_reclaim_valid;
wire [`SRAM_ID_W-1:0] flush_reclaim_sram_id;
wire [`BANK_ID_W-1:0] flush_reclaim_bank_id;
wire [`SUBBANK_ID_W-1:0] flush_reclaim_subbank_start;
wire [`KV_GROUP_LEN_W-1:0] flush_reclaim_group_len;

wire alloc_resp_valid;
wire alloc_resp_grant;
wire [`REQ_ID_W-1:0] alloc_resp_req_id;
wire [`SRAM_ID_W-1:0] alloc_resp_sram_id;
wire [`BANK_ID_W-1:0] alloc_resp_bank_id;
wire [`SUBBANK_ID_W-1:0] alloc_resp_subbank_start;
wire [`KV_GROUP_LEN_W-1:0] alloc_resp_group_len;
wire [`BANK_OCC_BITMAP_W-1:0] alloc_resp_occ_bitmap;

reg query_valid;
reg [`SRAM_ID_W-1:0] query_sram_id;
reg [`BANK_ID_W-1:0] query_bank_id;
wire query_resp_valid;
wire [`BANK_OCC_BITMAP_W-1:0] query_resp_occ_bitmap;
wire [`BANK_STATE_W-1:0] query_resp_state;
wire [`BRANCH_MASK_W-1:0] query_resp_branch_mask;
wire [`REFCNT_W-1:0] query_resp_refcnt;

reg [`SRAM_ID_W-1:0] victim_sram_id_r;
reg [`BANK_ID_W-1:0] victim_bank_id_r;
reg [`SUBBANK_ID_W-1:0] victim_subbank_start_r;
reg [`KV_GROUP_LEN_W-1:0] victim_group_len_r;

reg [`SRAM_ID_W-1:0] survivor_sram_id_r;
reg [`BANK_ID_W-1:0] survivor_bank_id_r;
reg [`SUBBANK_ID_W-1:0] survivor_subbank_start_r;
reg [`KV_GROUP_LEN_W-1:0] survivor_group_len_r;

reg [`BANK_OCC_BITMAP_W-1:0] query_bitmap_r;

comparator u_comparator (
    .clk(clk),
    .rst_n(rst_n),
    .cmp_req_id(cmp_req_id),
    .cmp_slot_valid(cmp_slot_valid),
    .cmp_slot_real_token_id(cmp_slot_real_token_id),
    .cmp_slot_candidate_token_id(cmp_slot_candidate_token_id),
    .cmp_slot_node_id(cmp_slot_node_id),
    .cmp_slot_parent_node_id(cmp_slot_parent_node_id),
    .cmp_slot_branch_id(cmp_slot_branch_id),
    .commit_valid(commit_valid),
    .commit_branch_mask(commit_branch_mask),
    .commit_node_mask(commit_node_mask),
    .flush_valid(flush_valid),
    .flush_branch_mask(flush_branch_mask),
    .flush_node_mask(flush_node_mask)
);

assign flush_freeze = flush_valid;

agu u_agu (
    .clk(clk),
    .rst_n(rst_n),
    .tree_in_valid(tree_in_valid),
    .tree_in_ready(tree_in_ready),
    .tree_in_req_id(tree_in_req_id),
    .tree_in_branch_id(tree_in_branch_id),
    .tree_in_node_id(tree_in_node_id),
    .prefix_valid(1'b0),
    .prefix_ready(prefix_ready),
    .prefix_req_id({`REQ_ID_W{1'b0}}),
    .prefix_node_valid(1'b0),
    .prefix_node_id({`NODE_ID_W{1'b0}}),
    .prefix_parent_node_id({`NODE_ID_W{1'b0}}),
    .prefix_token_id({`TOKEN_ID_W{1'b0}}),
    .prefix_position_id({`POSITION_ID_W{1'b0}}),
    .prefix_layer_id({`LAYER_ID_W{1'b0}}),
    .prefix_is_last(1'b0),
    .frontier_valid(1'b0),
    .frontier_ready(frontier_ready),
    .frontier_req_id({`REQ_ID_W{1'b0}}),
    .frontier_level_id({`TREE_LEVEL_ID_W{1'b0}}),
    .frontier_slot_valid({`TREE_FRONTIER_SLOTS{1'b0}}),
    .frontier_node_id({(`TREE_FRONTIER_SLOTS*`NODE_ID_W){1'b0}}),
    .frontier_parent_node_id({(`TREE_FRONTIER_SLOTS*`NODE_ID_W){1'b0}}),
    .frontier_token_id({(`TREE_FRONTIER_SLOTS*`TOKEN_ID_W){1'b0}}),
    .frontier_position_id({(`TREE_FRONTIER_SLOTS*`POSITION_ID_W){1'b0}}),
    .prefetch_enq_ready(prefetch_enq_ready),
    .cand_resp_valid(cand_resp_valid),
    .cand_resp_grant(cand_resp_grant),
    .cand_resp_req_id(cand_resp_req_id),
    .cand_resp_sram_id(cand_resp_sram_id),
    .cand_resp_bank_id(cand_resp_bank_id),
    .cand_resp_subbank_start(cand_resp_subbank_start),
    .cand_resp_group_len(cand_resp_group_len),
    .alloc_resp_valid(alloc_resp_valid),
    .alloc_resp_grant(alloc_resp_grant),
    .alloc_resp_req_id(alloc_resp_req_id),
    .alloc_resp_sram_id(alloc_resp_sram_id),
    .alloc_resp_bank_id(alloc_resp_bank_id),
    .alloc_resp_subbank_start(alloc_resp_subbank_start),
    .alloc_resp_group_len(alloc_resp_group_len),
    .flush_freeze(flush_valid),
    .flush_drain_busy(1'b0),
    .flush_ctrl_valid(flush_valid),
    .flush_ctrl_req_id(cmp_req_id),
    .flush_ctrl_branch_mask(flush_branch_mask),
    .flush_ctrl_node_mask(flush_node_mask),
    .prefix_norm_valid(),
    .prefix_norm_req_id(),
    .prefix_norm_node_valid(),
    .prefix_norm_node_id(),
    .prefix_norm_parent_node_id(),
    .prefix_norm_token_id(),
    .prefix_norm_position_id(),
    .prefix_norm_layer_id(),
    .prefix_norm_is_last(),
    .prefix_norm_is_shared(),
    .frontier_norm_valid(),
    .frontier_norm_req_id(),
    .frontier_norm_level_id(),
    .frontier_norm_slot_valid(),
    .frontier_norm_node_id(),
    .frontier_norm_parent_node_id(),
    .frontier_norm_token_id(),
    .frontier_norm_position_id(),
    .frontier_norm_size_subbank(),
    .frontier_norm_slot_shared(),
    .alloc_cand_valid(),
    .alloc_cand_req_id(),
    .alloc_cand_branch_id(),
    .alloc_cand_node_id(),
    .alloc_cand_size_subbank(),
    .alloc_cand_shared(),
    .alloc_cand_sram_id(),
    .alloc_cand_bank_id(),
    .alloc_cand_subbank_start(),
    .alloc_cand_group_len(),
    .token_wr_valid(),
    .token_wr_req_id(),
    .token_wr_token_id(),
    .token_wr_position_id(),
    .token_wr_node_id(),
    .token_wr_branch_id(),
    .token_wr_branch_mask(),
    .token_wr_is_shared(),
    .token_wr_sram_id(),
    .token_wr_bank_id(),
    .token_wr_subbank_start(),
    .token_wr_group_len(),
    .prefetch_enq_valid(prefetch_enq_valid),
    .prefetch_enq_req_id(prefetch_enq_req_id),
    .prefetch_enq_branch_id(prefetch_enq_branch_id),
    .prefetch_enq_node_id(prefetch_enq_node_id),
    .prefetch_enq_layer_id(prefetch_enq_layer_id),
    .prefetch_enq_size_subbank(prefetch_enq_size_subbank),
    .prefetch_enq_shared(prefetch_enq_shared),
    .prefetch_flush_valid(prefetch_flush_valid),
    .prefetch_flush_req_id(prefetch_flush_req_id),
    .prefetch_flush_branch_mask(prefetch_flush_branch_mask),
    .prefetch_flush_node_mask(prefetch_flush_node_mask),
    .free_list_flush_valid(free_list_flush_valid),
    .free_list_flush_req_id(free_list_flush_req_id),
    .free_list_flush_branch_mask(free_list_flush_branch_mask),
    .free_list_flush_node_mask(free_list_flush_node_mask)
);

prefetch_queue u_prefetch_queue (
    .clk(clk),
    .rst_n(rst_n),
    .enq_valid(prefetch_enq_valid),
    .enq_ready(prefetch_enq_ready),
    .enq_req_id(prefetch_enq_req_id),
    .enq_branch_id(prefetch_enq_branch_id),
    .enq_node_id(prefetch_enq_node_id),
    .enq_layer_id(prefetch_enq_layer_id),
    .enq_size_subbank(prefetch_enq_size_subbank),
    .enq_shared(prefetch_enq_shared),
    .flush_valid(prefetch_flush_valid),
    .flush_req_id(prefetch_flush_req_id),
    .flush_branch_mask(prefetch_flush_branch_mask),
    .flush_node_mask(prefetch_flush_node_mask),
    .deq_valid(queue_deq_valid),
    .deq_ready(queue_deq_ready),
    .deq_req_id(queue_deq_req_id),
    .deq_branch_id(queue_deq_branch_id),
    .deq_node_id(queue_deq_node_id),
    .deq_layer_id(queue_deq_layer_id),
    .deq_size_subbank(queue_deq_size_subbank),
    .deq_shared(queue_deq_shared)
);

free_list u_free_list (
    .clk(clk),
    .rst_n(rst_n),
    .cand_req_valid(queue_deq_valid),
    .cand_req_ready(queue_deq_ready),
    .cand_req_req_id(queue_deq_req_id),
    .cand_req_branch_id(queue_deq_branch_id),
    .cand_req_node_id(queue_deq_node_id),
    .cand_req_size_subbank(queue_deq_size_subbank),
    .cand_req_shared(queue_deq_shared),
    .cand_resp_valid(cand_resp_valid),
    .cand_resp_grant(cand_resp_grant),
    .cand_resp_req_id(cand_resp_req_id),
    .cand_resp_sram_id(cand_resp_sram_id),
    .cand_resp_bank_id(cand_resp_bank_id),
    .cand_resp_subbank_start(cand_resp_subbank_start),
    .cand_resp_group_len(cand_resp_group_len),
    .alloc_cand_valid(alloc_cand_valid),
    .alloc_cand_req_id(alloc_cand_req_id),
    .alloc_cand_branch_id(alloc_cand_branch_id),
    .alloc_cand_node_id(alloc_cand_node_id),
    .alloc_cand_size_subbank(alloc_cand_size_subbank),
    .alloc_cand_shared(alloc_cand_shared),
    .alloc_cand_sram_id(alloc_cand_sram_id),
    .alloc_cand_bank_id(alloc_cand_bank_id),
    .alloc_cand_subbank_start(alloc_cand_subbank_start),
    .alloc_cand_group_len(alloc_cand_group_len),
    .flush_valid(free_list_flush_valid),
    .flush_req_id(free_list_flush_req_id),
    .flush_branch_mask(free_list_flush_branch_mask),
    .flush_node_mask(free_list_flush_node_mask),
    .flush_reclaim_valid(flush_reclaim_valid),
    .flush_reclaim_sram_id(flush_reclaim_sram_id),
    .flush_reclaim_bank_id(flush_reclaim_bank_id),
    .flush_reclaim_subbank_start(flush_reclaim_subbank_start),
    .flush_reclaim_group_len(flush_reclaim_group_len),
    .release_valid(1'b0),
    .release_sram_id({`SRAM_ID_W{1'b0}}),
    .release_bank_id({`BANK_ID_W{1'b0}}),
    .release_subbank_start({`SUBBANK_ID_W{1'b0}}),
    .release_group_len({`KV_GROUP_LEN_W{1'b0}})
);

bank_state_table u_bank_state_table (
    .clk(clk),
    .rst_n(rst_n),
    .cand_valid(alloc_cand_valid),
    .cand_ready(),
    .cand_req_id(alloc_cand_req_id),
    .cand_branch_id(alloc_cand_branch_id),
    .cand_node_id(alloc_cand_node_id),
    .cand_size_subbank(alloc_cand_size_subbank),
    .cand_shared(alloc_cand_shared),
    .cand_sram_id(alloc_cand_sram_id),
    .cand_bank_id(alloc_cand_bank_id),
    .cand_subbank_start(alloc_cand_subbank_start),
    .cand_group_len(alloc_cand_group_len),
    .alloc_resp_valid(alloc_resp_valid),
    .alloc_resp_grant(alloc_resp_grant),
    .alloc_resp_req_id(alloc_resp_req_id),
    .alloc_resp_sram_id(alloc_resp_sram_id),
    .alloc_resp_bank_id(alloc_resp_bank_id),
    .alloc_resp_subbank_start(alloc_resp_subbank_start),
    .alloc_resp_group_len(alloc_resp_group_len),
    .alloc_resp_occ_bitmap(alloc_resp_occ_bitmap),
    .commit_valid(1'b0),
    .commit_req_id({`REQ_ID_W{1'b0}}),
    .commit_sram_id({`SRAM_ID_W{1'b0}}),
    .commit_bank_id({`BANK_ID_W{1'b0}}),
    .commit_subbank_start({`SUBBANK_ID_W{1'b0}}),
    .commit_group_len({`KV_GROUP_LEN_W{1'b0}}),
    .commit_branch_mask({`BRANCH_MASK_W{1'b0}}),
    .commit_node_mask({`NODE_MASK_W{1'b0}}),
    .flush_valid(1'b0),
    .flush_req_id({`REQ_ID_W{1'b0}}),
    .flush_branch_mask({`BRANCH_MASK_W{1'b0}}),
    .flush_node_mask({`NODE_MASK_W{1'b0}}),
    .reclaim_valid(flush_reclaim_valid),
    .reclaim_sram_id(flush_reclaim_sram_id),
    .reclaim_bank_id(flush_reclaim_bank_id),
    .reclaim_subbank_start(flush_reclaim_subbank_start),
    .reclaim_group_len(flush_reclaim_group_len),
    .query_valid(query_valid),
    .query_sram_id(query_sram_id),
    .query_bank_id(query_bank_id),
    .query_resp_valid(query_resp_valid),
    .query_resp_occ_bitmap(query_resp_occ_bitmap),
    .query_resp_state(query_resp_state),
    .query_resp_branch_mask(query_resp_branch_mask),
    .query_resp_refcnt(query_resp_refcnt)
);

always #5 clk = ~clk;

task clear_comparator_inputs;
    begin
        cmp_req_id = {`REQ_ID_W{1'b0}};
        cmp_slot_valid = {`BRANCH_NUM{1'b0}};
        cmp_slot_real_token_id = {(`BRANCH_NUM*`TOKEN_ID_W){1'b0}};
        cmp_slot_candidate_token_id = {(`BRANCH_NUM*`TOKEN_ID_W){1'b0}};
        cmp_slot_node_id = {(`BRANCH_NUM*`NODE_ID_W){1'b0}};
        cmp_slot_parent_node_id = {(`BRANCH_NUM*`NODE_ID_W){1'b0}};
        cmp_slot_branch_id = {(`BRANCH_NUM*`BRANCH_ID_W){1'b0}};
    end
endtask

task clear_tree_input;
    begin
        tree_in_valid = 1'b0;
        tree_in_req_id = {`REQ_ID_W{1'b0}};
        tree_in_branch_id = {`BRANCH_ID_W{1'b0}};
        tree_in_node_id = {`NODE_ID_W{1'b0}};
    end
endtask

task clear_query;
    begin
        query_valid = 1'b0;
        query_sram_id = {`SRAM_ID_W{1'b0}};
        query_bank_id = {`BANK_ID_W{1'b0}};
    end
endtask

task drive_scalar_req;
    input [`REQ_ID_W-1:0] req_id;
    input [`BRANCH_ID_W-1:0] branch_id;
    input [`NODE_ID_W-1:0] node_id;
    begin
        @(posedge clk);
        #1;
        if (!tree_in_ready) begin
            $fatal(1, "AGU not ready for scalar request");
        end

        tree_in_valid = 1'b1;
        tree_in_req_id = req_id;
        tree_in_branch_id = branch_id;
        tree_in_node_id = node_id;

        @(posedge clk);
        #1;
        clear_tree_input();
    end
endtask

task wait_for_cand_resp;
    input [255:0] scenario_name;
    input [`REQ_ID_W-1:0] expect_req_id;
    input expect_grant;
    input [1:0] capture_kind;
    integer wait_i;
    reg seen;
    begin
        seen = 1'b0;
        for (wait_i = 0; wait_i < 40; wait_i = wait_i + 1) begin
            @(negedge clk);
            #1;
            if (cand_resp_valid) begin
                if (cand_resp_req_id != expect_req_id) begin
                    $fatal(1, "%0s: cand_resp req_id mismatch", scenario_name);
                end
                if (cand_resp_grant != expect_grant) begin
                    $fatal(1, "%0s: cand_resp grant mismatch", scenario_name);
                end
                if (expect_grant &&
                    (cand_resp_group_len != `KV_GROUP_SIZE_SUBBANK)) begin
                    $fatal(1, "%0s: cand_resp group length mismatch", scenario_name);
                end
                if (expect_grant && (capture_kind == 2'd1)) begin
                    victim_sram_id_r = cand_resp_sram_id;
                    victim_bank_id_r = cand_resp_bank_id;
                    victim_subbank_start_r = cand_resp_subbank_start;
                    victim_group_len_r = cand_resp_group_len;
                end else if (expect_grant && (capture_kind == 2'd2)) begin
                    survivor_sram_id_r = cand_resp_sram_id;
                    survivor_bank_id_r = cand_resp_bank_id;
                    survivor_subbank_start_r = cand_resp_subbank_start;
                    survivor_group_len_r = cand_resp_group_len;
                end
                seen = 1'b1;
                disable wait_for_cand_resp;
            end
        end

        if (!seen) begin
            $fatal(1, "%0s: cand_resp did not appear within bounded wait", scenario_name);
        end
    end
endtask

task wait_for_alloc_resp;
    input [255:0] scenario_name;
    input [`REQ_ID_W-1:0] expect_req_id;
    integer wait_i;
    reg seen;
    begin
        seen = 1'b0;
        for (wait_i = 0; wait_i < 40; wait_i = wait_i + 1) begin
            @(negedge clk);
            #1;
            if (alloc_resp_valid) begin
                if (!alloc_resp_grant) begin
                    $fatal(1, "%0s: alloc_resp grant mismatch", scenario_name);
                end
                if (alloc_resp_req_id != expect_req_id) begin
                    $fatal(1, "%0s: alloc_resp req_id mismatch", scenario_name);
                end
                seen = 1'b1;
                disable wait_for_alloc_resp;
            end
        end

        if (!seen) begin
            $fatal(1, "%0s: alloc_resp did not appear within bounded wait", scenario_name);
        end
    end
endtask

task issue_req_expect_grant;
    input [255:0] scenario_name;
    input [`REQ_ID_W-1:0] req_id;
    input [`BRANCH_ID_W-1:0] branch_id;
    input [`NODE_ID_W-1:0] node_id;
    input [1:0] capture_kind;
    begin
        drive_scalar_req(req_id, branch_id, node_id);
        wait_for_cand_resp(scenario_name, req_id, 1'b1, capture_kind);
        wait_for_alloc_resp(scenario_name, req_id);
    end
endtask

task issue_req_expect_deny;
    input [255:0] scenario_name;
    input [`REQ_ID_W-1:0] req_id;
    input [`BRANCH_ID_W-1:0] branch_id;
    input [`NODE_ID_W-1:0] node_id;
    begin
        drive_scalar_req(req_id, branch_id, node_id);
        wait_for_cand_resp(scenario_name, req_id, 1'b0, 1'b0);
    end
endtask

task query_bank_bitmap;
    input [`SRAM_ID_W-1:0] sram_id;
    input [`BANK_ID_W-1:0] bank_id;
    begin
        @(posedge clk);
        #1;
        query_valid = 1'b1;
        query_sram_id = sram_id;
        query_bank_id = bank_id;
        #1;
        if (!query_resp_valid) begin
            $fatal(1, "bank_state_table query response missing");
        end
        query_bitmap_r = query_resp_occ_bitmap;
        @(posedge clk);
        #1;
        clear_query();
    end
endtask

task expect_range_occupied;
    input [255:0] scenario_name;
    input [`BANK_OCC_BITMAP_W-1:0] bitmap;
    input [`SUBBANK_ID_W-1:0] subbank_start;
    input [`KV_GROUP_LEN_W-1:0] group_len;
    integer idx_i;
    begin
        for (idx_i = 0; idx_i < group_len; idx_i = idx_i + 1) begin
            if (!bitmap[subbank_start + idx_i]) begin
                $fatal(1, "%0s: expected occupied range bit missing", scenario_name);
            end
        end
    end
endtask

task expect_range_free;
    input [255:0] scenario_name;
    input [`BANK_OCC_BITMAP_W-1:0] bitmap;
    input [`SUBBANK_ID_W-1:0] subbank_start;
    input [`KV_GROUP_LEN_W-1:0] group_len;
    integer idx_i;
    begin
        for (idx_i = 0; idx_i < group_len; idx_i = idx_i + 1) begin
            if (bitmap[subbank_start + idx_i]) begin
                $fatal(1, "%0s: expected free range bit still occupied", scenario_name);
            end
        end
    end
endtask

task expect_flush_bridge_active;
    begin
        #1;
        if (!flush_valid ||
            (flush_freeze !== 1'b1) ||
            commit_valid ||
            tree_in_ready ||
            prefix_ready ||
            frontier_ready ||
            prefetch_enq_valid) begin
            $fatal(1, "comparator mismatch should freeze AGU front-end acceptance");
        end

        if (!prefetch_flush_valid ||
            (prefetch_flush_req_id != cmp_req_id) ||
            (prefetch_flush_branch_mask != flush_branch_mask) ||
            (prefetch_flush_node_mask != flush_node_mask)) begin
            $fatal(1, "AGU should still own prefetch_queue flush controls");
        end

        if (!free_list_flush_valid ||
            (free_list_flush_req_id != cmp_req_id) ||
            (free_list_flush_branch_mask != flush_branch_mask) ||
            (free_list_flush_node_mask != flush_node_mask)) begin
            $fatal(1, "AGU should own and forward free_list flush controls");
        end
    end
endtask

task expect_reclaim_handoff_victim_only;
    integer wait_i;
    reg seen;
    begin
        seen = 1'b0;
        for (wait_i = 0; wait_i < 20; wait_i = wait_i + 1) begin
            @(negedge clk);
            #1;
            if (flush_reclaim_valid) begin
                if ((flush_reclaim_sram_id != victim_sram_id_r) ||
                    (flush_reclaim_bank_id != victim_bank_id_r) ||
                    (flush_reclaim_subbank_start != victim_subbank_start_r) ||
                    (flush_reclaim_group_len != victim_group_len_r)) begin
                    $fatal(1, "free_list reclaim handoff did not match victim range");
                end
                seen = 1'b1;
                disable expect_reclaim_handoff_victim_only;
            end
        end

        if (!seen) begin
            $fatal(1, "free_list reclaim handoff did not appear");
        end
    end
endtask

task expect_accept_open;
    begin
        #1;
        if (flush_valid ||
            (flush_freeze !== 1'b0) ||
            !tree_in_ready ||
            !prefix_ready ||
            !frontier_ready ||
            prefetch_flush_valid ||
            free_list_flush_valid) begin
            $fatal(1, "AGU acceptance should reopen when comparator flush is inactive");
        end
    end
endtask

integer filler_i;

initial begin
    clk = 1'b0;
    rst_n = 1'b0;

    clear_comparator_inputs();
    clear_tree_input();
    clear_query();
    victim_sram_id_r = {`SRAM_ID_W{1'b0}};
    victim_bank_id_r = {`BANK_ID_W{1'b0}};
    victim_subbank_start_r = {`SUBBANK_ID_W{1'b0}};
    victim_group_len_r = {`KV_GROUP_LEN_W{1'b0}};
    survivor_sram_id_r = {`SRAM_ID_W{1'b0}};
    survivor_bank_id_r = {`BANK_ID_W{1'b0}};
    survivor_subbank_start_r = {`SUBBANK_ID_W{1'b0}};
    survivor_group_len_r = {`KV_GROUP_LEN_W{1'b0}};
    query_bitmap_r = {`BANK_OCC_BITMAP_W{1'b0}};

    repeat (3) @(posedge clk);
    rst_n = 1'b1;

    #1;
    expect_accept_open();

    issue_req_expect_grant("victim_alloc", 4'h3, 2'd1, 4'd2, 2'd1);
    issue_req_expect_grant("survivor_alloc", 4'h3, 2'd0, 4'd1, 2'd2);

    query_bank_bitmap(victim_sram_id_r, victim_bank_id_r);
    expect_range_occupied("victim_before_flush", query_bitmap_r,
                          victim_subbank_start_r, victim_group_len_r);
    if ((victim_sram_id_r == survivor_sram_id_r) &&
        (victim_bank_id_r == survivor_bank_id_r)) begin
        expect_range_occupied("survivor_before_flush_same_bank", query_bitmap_r,
                              survivor_subbank_start_r, survivor_group_len_r);
    end else begin
        query_bank_bitmap(survivor_sram_id_r, survivor_bank_id_r);
        expect_range_occupied("survivor_before_flush_other_bank", query_bitmap_r,
                              survivor_subbank_start_r, survivor_group_len_r);
    end

    for (filler_i = 0; filler_i < FILLER_ALLOC_COUNT; filler_i = filler_i + 1) begin
        issue_req_expect_grant("filler_alloc", 4'h4, 2'd2, 4'd0, 2'd0);
    end

    issue_req_expect_deny("full_before_flush", 4'h5, 2'd3, 4'd0);

    @(posedge clk);
    #1;
    cmp_req_id = 4'h3;
    cmp_slot_valid[0] = 1'b1;
    cmp_slot_real_token_id[`TOKEN_ID_W-1:0] = 16'h0101;
    cmp_slot_candidate_token_id[`TOKEN_ID_W-1:0] = 16'h0202;
    cmp_slot_node_id[`NODE_ID_W-1:0] = 4'd2;
    cmp_slot_parent_node_id[`NODE_ID_W-1:0] = 4'd1;
    cmp_slot_branch_id[`BRANCH_ID_W-1:0] = 2'd1;

    expect_flush_bridge_active();
    expect_reclaim_handoff_victim_only();

    @(posedge clk);
    #1;
    clear_comparator_inputs();

    @(posedge clk);
    #1;
    expect_accept_open();

    query_bank_bitmap(victim_sram_id_r, victim_bank_id_r);
    expect_range_free("victim_after_flush", query_bitmap_r,
                      victim_subbank_start_r, victim_group_len_r);
    if ((victim_sram_id_r == survivor_sram_id_r) &&
        (victim_bank_id_r == survivor_bank_id_r)) begin
        expect_range_occupied("survivor_after_flush_same_bank", query_bitmap_r,
                              survivor_subbank_start_r, survivor_group_len_r);
    end else begin
        query_bank_bitmap(survivor_sram_id_r, survivor_bank_id_r);
        expect_range_occupied("survivor_after_flush_other_bank", query_bitmap_r,
                              survivor_subbank_start_r, survivor_group_len_r);
    end

    issue_req_expect_grant("one_slot_restored", 4'h5, 2'd3, 4'd0, 2'd0);
    issue_req_expect_deny("survivor_not_reclaimed", 4'h6, 2'd3, 4'd1);

    $display("tb_comparator_bank_state_table_flush PASS");
    $finish;
end

endmodule
