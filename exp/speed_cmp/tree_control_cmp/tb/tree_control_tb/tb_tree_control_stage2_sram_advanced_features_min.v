`timescale 1ns/1ps

`include "config/prediction_params.vh"
`include "config/interface_params.vh"
`include "config/memory_params.vh"

module tb_tree_control_stage2_sram_advanced_features_min;

localparam integer SHARED_BANKS_PER_SRAM =
    (`SRAM_BANK_NUM >= 4) ? (`SRAM_BANK_NUM / 4) : 1;
localparam integer PRIVATE_BANKS_PER_SRAM =
    (`SRAM_BANK_NUM > SHARED_BANKS_PER_SRAM) ?
        (`SRAM_BANK_NUM - SHARED_BANKS_PER_SRAM) : 1;
localparam integer PRIVATE_BANKS_PER_BRANCH =
    (PRIVATE_BANKS_PER_SRAM >= `BRANCH_NUM) ?
        (PRIVATE_BANKS_PER_SRAM / `BRANCH_NUM) : 1;
localparam [`BANK_ID_W-1:0] SHARED_BANKS_PER_SRAM_BANK_ID =
    SHARED_BANKS_PER_SRAM;
localparam [`BANK_ID_W-1:0] BRANCH1_FIRST_BANK_ID =
    SHARED_BANKS_PER_SRAM + PRIVATE_BANKS_PER_BRANCH;
localparam [`SUBBANK_ID_W-1:0] KV_GROUP_SIZE_SUBBANK_ID =
    `KV_GROUP_SIZE_SUBBANK;
localparam [`SUBBANK_ID_W-1:0] DOUBLE_KV_GROUP_SIZE_SUBBANK_ID =
    (2 * `KV_GROUP_SIZE_SUBBANK);
localparam [`BRANCH_MASK_W-1:0] BRANCH0_MASK =
    {{(`BRANCH_MASK_W-1){1'b0}}, 1'b1};
localparam [`BRANCH_MASK_W-1:0] BRANCH1_MASK =
    ({{(`BRANCH_MASK_W-1){1'b0}}, 1'b1} << 1);
localparam [`BANK_STATE_W-1:0] BANK_STATE_SPEC =
    {{(`BANK_STATE_W-1){1'b0}}, 1'b1};
localparam [`BANK_STATE_W-1:0] BANK_STATE_COMMITTED =
    {{(`BANK_STATE_W-2){1'b0}}, 2'b10};

reg clk;
reg rst_n;

reg cand_req_valid;
wire cand_req_ready;
reg [`REQ_ID_W-1:0] cand_req_req_id;
reg [`BRANCH_ID_W-1:0] cand_req_branch_id;
reg [`NODE_ID_W-1:0] cand_req_node_id;
reg [`KV_GROUP_LEN_W-1:0] cand_req_size_subbank;
reg cand_req_shared;

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

reg commit_valid;
reg [`REQ_ID_W-1:0] commit_req_id;
reg [`SRAM_ID_W-1:0] commit_sram_id;
reg [`BANK_ID_W-1:0] commit_bank_id;
reg [`SUBBANK_ID_W-1:0] commit_subbank_start;
reg [`KV_GROUP_LEN_W-1:0] commit_group_len;
reg [`BRANCH_MASK_W-1:0] commit_branch_mask;
reg [`NODE_MASK_W-1:0] commit_node_mask;

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

reg [`BANK_OCC_BITMAP_W-1:0] sampled_query_bitmap_r;
reg [`BANK_STATE_W-1:0] sampled_query_state_r;
reg [`BRANCH_MASK_W-1:0] sampled_query_branch_mask_r;
reg [`REFCNT_W-1:0] sampled_query_refcnt_r;

reg [`SRAM_ID_W-1:0] branch0_first_sram_r;
reg [`BANK_ID_W-1:0] branch0_first_bank_r;
reg [`SUBBANK_ID_W-1:0] branch0_first_subbank_r;
reg [`KV_GROUP_LEN_W-1:0] branch0_first_len_r;

reg [`SRAM_ID_W-1:0] branch0_second_sram_r;
reg [`BANK_ID_W-1:0] branch0_second_bank_r;
reg [`SUBBANK_ID_W-1:0] branch0_second_subbank_r;
reg [`KV_GROUP_LEN_W-1:0] branch0_second_len_r;

reg [`SRAM_ID_W-1:0] branch1_first_sram_r;
reg [`BANK_ID_W-1:0] branch1_first_bank_r;
reg [`SUBBANK_ID_W-1:0] branch1_first_subbank_r;
reg [`KV_GROUP_LEN_W-1:0] branch1_first_len_r;

reg [`SRAM_ID_W-1:0] shared_sram_r;
reg [`BANK_ID_W-1:0] shared_bank_r;
reg [`SUBBANK_ID_W-1:0] shared_subbank_r;
reg [`KV_GROUP_LEN_W-1:0] shared_len_r;

reg [`SRAM_ID_W-1:0] isolated_sram_r;
reg [`BANK_ID_W-1:0] isolated_bank_r;
reg [`SUBBANK_ID_W-1:0] isolated_subbank_r;
reg [`KV_GROUP_LEN_W-1:0] isolated_len_r;

free_list #(
    .ENABLE_TOPOLOGY_AWARE_MAPPING(1),
    .ENABLE_SHARED_PREFIX_FREEZE(1),
    .ENABLE_BRANCH_ISOLATION(1)
) u_free_list (
    .clk(clk),
    .rst_n(rst_n),
    .cand_req_valid(cand_req_valid),
    .cand_req_ready(cand_req_ready),
    .cand_req_req_id(cand_req_req_id),
    .cand_req_branch_id(cand_req_branch_id),
    .cand_req_node_id(cand_req_node_id),
    .cand_req_size_subbank(cand_req_size_subbank),
    .cand_req_shared(cand_req_shared),
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
    .flush_valid(1'b0),
    .flush_req_id({`REQ_ID_W{1'b0}}),
    .flush_branch_mask({`BRANCH_MASK_W{1'b0}}),
    .flush_node_mask({`NODE_MASK_W{1'b0}}),
    .flush_drain_busy(),
    .flush_reclaim_valid(),
    .flush_reclaim_sram_id(),
    .flush_reclaim_bank_id(),
    .flush_reclaim_subbank_start(),
    .flush_reclaim_group_len(),
    .release_valid(1'b0),
    .release_sram_id({`SRAM_ID_W{1'b0}}),
    .release_bank_id({`BANK_ID_W{1'b0}}),
    .release_subbank_start({`SUBBANK_ID_W{1'b0}}),
    .release_group_len({`KV_GROUP_LEN_W{1'b0}})
);

bank_state_table #(
    .ENABLE_SHARED_PREFIX_FREEZE(1),
    .ENABLE_PREFIX_PROMOTION(1),
    .ENABLE_BRANCH_ISOLATION(1)
) u_bank_state_table (
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
    .commit_valid(commit_valid),
    .commit_req_id(commit_req_id),
    .commit_sram_id(commit_sram_id),
    .commit_bank_id(commit_bank_id),
    .commit_subbank_start(commit_subbank_start),
    .commit_group_len(commit_group_len),
    .commit_branch_mask(commit_branch_mask),
    .commit_node_mask(commit_node_mask),
    .flush_valid(1'b0),
    .flush_req_id({`REQ_ID_W{1'b0}}),
    .flush_branch_mask({`BRANCH_MASK_W{1'b0}}),
    .flush_node_mask({`NODE_MASK_W{1'b0}}),
    .reclaim_valid(1'b0),
    .reclaim_sram_id({`SRAM_ID_W{1'b0}}),
    .reclaim_bank_id({`BANK_ID_W{1'b0}}),
    .reclaim_subbank_start({`SUBBANK_ID_W{1'b0}}),
    .reclaim_group_len({`KV_GROUP_LEN_W{1'b0}}),
    .query_valid(query_valid),
    .query_sram_id(query_sram_id),
    .query_bank_id(query_bank_id),
    .query_resp_valid(query_resp_valid),
    .query_resp_occ_bitmap(query_resp_occ_bitmap),
    .query_resp_state(query_resp_state),
    .query_resp_branch_mask(query_resp_branch_mask),
    .query_resp_refcnt(query_resp_refcnt)
);

function [`NODE_MASK_W-1:0] node_mask_for_branch_node;
    input [`BRANCH_ID_W-1:0] branch_id_in;
    input [`NODE_ID_W-1:0] node_id_in;
    integer bit_index_i;
    begin
        node_mask_for_branch_node = {`NODE_MASK_W{1'b0}};
        bit_index_i =
            (branch_id_in * `MAX_VERIFY_NODES_PER_BRANCH) + node_id_in;
        if ((branch_id_in < `BRANCH_NUM) &&
            (node_id_in < `MAX_VERIFY_NODES_PER_BRANCH) &&
            (bit_index_i < `NODE_MASK_W)) begin
            node_mask_for_branch_node[bit_index_i] = 1'b1;
        end
    end
endfunction

always #5 clk = ~clk;

task issue_candidate_expect_grant;
    input [255:0] scenario_name;
    input [`REQ_ID_W-1:0] req_id;
    input [`BRANCH_ID_W-1:0] branch_id;
    input [`NODE_ID_W-1:0] node_id;
    input is_shared;
    input [`BANK_ID_W-1:0] expect_bank_id;
    input [`SUBBANK_ID_W-1:0] expect_subbank_start;
    output [`SRAM_ID_W-1:0] got_sram_id;
    output [`BANK_ID_W-1:0] got_bank_id;
    output [`SUBBANK_ID_W-1:0] got_subbank_start;
    output [`KV_GROUP_LEN_W-1:0] got_group_len;
    begin
        @(posedge clk);
        cand_req_valid <= 1'b1;
        cand_req_req_id <= req_id;
        cand_req_branch_id <= branch_id;
        cand_req_node_id <= node_id;
        cand_req_size_subbank <= `KV_GROUP_SIZE_SUBBANK;
        cand_req_shared <= is_shared;

        @(posedge clk);
        cand_req_valid <= 1'b0;

        @(posedge clk);
        if (!cand_resp_valid || !cand_resp_grant) begin
            $fatal(1, "%0s: free_list did not return a granted candidate", scenario_name);
        end
        if (cand_resp_req_id != req_id ||
            cand_resp_bank_id != expect_bank_id ||
            cand_resp_subbank_start != expect_subbank_start ||
            cand_resp_group_len != `KV_GROUP_SIZE_SUBBANK) begin
            $fatal(1, "%0s: free_list candidate mismatch", scenario_name);
        end

        got_sram_id = cand_resp_sram_id;
        got_bank_id = cand_resp_bank_id;
        got_subbank_start = cand_resp_subbank_start;
        got_group_len = cand_resp_group_len;

        @(posedge clk);
        if (!alloc_resp_valid || !alloc_resp_grant) begin
            $fatal(1, "%0s: bank_state_table did not grant the candidate", scenario_name);
        end
        if (alloc_resp_req_id != req_id ||
            alloc_resp_sram_id != got_sram_id ||
            alloc_resp_bank_id != got_bank_id ||
            alloc_resp_subbank_start != got_subbank_start ||
            alloc_resp_group_len != got_group_len) begin
            $fatal(1, "%0s: bank_state_table response mismatch", scenario_name);
        end
    end
endtask

task drive_commit;
    input [`REQ_ID_W-1:0] req_id;
    input [`SRAM_ID_W-1:0] sram_id;
    input [`BANK_ID_W-1:0] bank_id;
    input [`SUBBANK_ID_W-1:0] subbank_start;
    input [`KV_GROUP_LEN_W-1:0] group_len;
    input [`BRANCH_MASK_W-1:0] branch_mask;
    input [`NODE_MASK_W-1:0] node_mask;
    begin
        @(posedge clk);
        commit_valid <= 1'b1;
        commit_req_id <= req_id;
        commit_sram_id <= sram_id;
        commit_bank_id <= bank_id;
        commit_subbank_start <= subbank_start;
        commit_group_len <= group_len;
        commit_branch_mask <= branch_mask;
        commit_node_mask <= node_mask;

        @(posedge clk);
        commit_valid <= 1'b0;
        commit_req_id <= {`REQ_ID_W{1'b0}};
        commit_sram_id <= {`SRAM_ID_W{1'b0}};
        commit_bank_id <= {`BANK_ID_W{1'b0}};
        commit_subbank_start <= {`SUBBANK_ID_W{1'b0}};
        commit_group_len <= {`KV_GROUP_LEN_W{1'b0}};
        commit_branch_mask <= {`BRANCH_MASK_W{1'b0}};
        commit_node_mask <= {`NODE_MASK_W{1'b0}};
    end
endtask

task sample_query_bank;
    input [255:0] scenario_name;
    input [`SRAM_ID_W-1:0] sram_id;
    input [`BANK_ID_W-1:0] bank_id;
    begin
        @(posedge clk);
        query_valid <= 1'b1;
        query_sram_id <= sram_id;
        query_bank_id <= bank_id;
        #1;
        if (!query_resp_valid) begin
            $fatal(1, "%0s: query response missing", scenario_name);
        end
        sampled_query_bitmap_r <= query_resp_occ_bitmap;
        sampled_query_state_r <= query_resp_state;
        sampled_query_branch_mask_r <= query_resp_branch_mask;
        sampled_query_refcnt_r <= query_resp_refcnt;
        @(posedge clk);
        query_valid <= 1'b0;
    end
endtask

initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    cand_req_valid = 1'b0;
    cand_req_req_id = {`REQ_ID_W{1'b0}};
    cand_req_branch_id = {`BRANCH_ID_W{1'b0}};
    cand_req_node_id = {`NODE_ID_W{1'b0}};
    cand_req_size_subbank = {`KV_GROUP_LEN_W{1'b0}};
    cand_req_shared = 1'b0;
    commit_valid = 1'b0;
    commit_req_id = {`REQ_ID_W{1'b0}};
    commit_sram_id = {`SRAM_ID_W{1'b0}};
    commit_bank_id = {`BANK_ID_W{1'b0}};
    commit_subbank_start = {`SUBBANK_ID_W{1'b0}};
    commit_group_len = {`KV_GROUP_LEN_W{1'b0}};
    commit_branch_mask = {`BRANCH_MASK_W{1'b0}};
    commit_node_mask = {`NODE_MASK_W{1'b0}};
    query_valid = 1'b0;
    query_sram_id = {`SRAM_ID_W{1'b0}};
    query_bank_id = {`BANK_ID_W{1'b0}};
    sampled_query_bitmap_r = {`BANK_OCC_BITMAP_W{1'b0}};
    sampled_query_state_r = {`BANK_STATE_W{1'b0}};
    sampled_query_branch_mask_r = {`BRANCH_MASK_W{1'b0}};
    sampled_query_refcnt_r = {`REFCNT_W{1'b0}};

    branch0_first_sram_r = {`SRAM_ID_W{1'b0}};
    branch0_first_bank_r = {`BANK_ID_W{1'b0}};
    branch0_first_subbank_r = {`SUBBANK_ID_W{1'b0}};
    branch0_first_len_r = {`KV_GROUP_LEN_W{1'b0}};
    branch0_second_sram_r = {`SRAM_ID_W{1'b0}};
    branch0_second_bank_r = {`BANK_ID_W{1'b0}};
    branch0_second_subbank_r = {`SUBBANK_ID_W{1'b0}};
    branch0_second_len_r = {`KV_GROUP_LEN_W{1'b0}};
    branch1_first_sram_r = {`SRAM_ID_W{1'b0}};
    branch1_first_bank_r = {`BANK_ID_W{1'b0}};
    branch1_first_subbank_r = {`SUBBANK_ID_W{1'b0}};
    branch1_first_len_r = {`KV_GROUP_LEN_W{1'b0}};
    shared_sram_r = {`SRAM_ID_W{1'b0}};
    shared_bank_r = {`BANK_ID_W{1'b0}};
    shared_subbank_r = {`SUBBANK_ID_W{1'b0}};
    shared_len_r = {`KV_GROUP_LEN_W{1'b0}};
    isolated_sram_r = {`SRAM_ID_W{1'b0}};
    isolated_bank_r = {`BANK_ID_W{1'b0}};
    isolated_subbank_r = {`SUBBANK_ID_W{1'b0}};
    isolated_len_r = {`KV_GROUP_LEN_W{1'b0}};

    repeat (3) @(posedge clk);
    rst_n = 1'b1;

    issue_candidate_expect_grant(
        "branch0_private_first",
        4'h1,
        2'd0,
        4'd0,
        1'b0,
        SHARED_BANKS_PER_SRAM_BANK_ID,
        {`SUBBANK_ID_W{1'b0}},
        branch0_first_sram_r,
        branch0_first_bank_r,
        branch0_first_subbank_r,
        branch0_first_len_r
    );

    issue_candidate_expect_grant(
        "branch0_private_second",
        4'h1,
        2'd0,
        4'd1,
        1'b0,
        SHARED_BANKS_PER_SRAM_BANK_ID,
        KV_GROUP_SIZE_SUBBANK_ID,
        branch0_second_sram_r,
        branch0_second_bank_r,
        branch0_second_subbank_r,
        branch0_second_len_r
    );

    issue_candidate_expect_grant(
        "branch1_private_first",
        4'h1,
        2'd1,
        4'd0,
        1'b0,
        BRANCH1_FIRST_BANK_ID,
        {`SUBBANK_ID_W{1'b0}},
        branch1_first_sram_r,
        branch1_first_bank_r,
        branch1_first_subbank_r,
        branch1_first_len_r
    );

    issue_candidate_expect_grant(
        "shared_prefix_first",
        4'h2,
        2'd0,
        4'd2,
        1'b1,
        {`BANK_ID_W{1'b0}},
        {`SUBBANK_ID_W{1'b0}},
        shared_sram_r,
        shared_bank_r,
        shared_subbank_r,
        shared_len_r
    );

    issue_candidate_expect_grant(
        "shared_prefix_reuse",
        4'h2,
        2'd0,
        4'd2,
        1'b1,
        shared_bank_r,
        shared_subbank_r,
        shared_sram_r,
        shared_bank_r,
        shared_subbank_r,
        shared_len_r
    );

    if (!u_bank_state_table.entry_shared
            [(shared_sram_r * `SRAM_BANK_NUM) + shared_bank_r][shared_subbank_r] ||
        !u_bank_state_table.promoted_bitmap
            [(shared_sram_r * `SRAM_BANK_NUM) + shared_bank_r][shared_subbank_r]) begin
        $fatal(1, "shared_prefix_reuse: bank_state_table should mark shared promotion metadata");
    end

    if (!u_free_list.entry_shared
            [(shared_sram_r * `SRAM_BANK_NUM) + shared_bank_r][shared_subbank_r] ||
        (u_free_list.entry_branch_mask
            [(shared_sram_r * `SRAM_BANK_NUM) + shared_bank_r][shared_subbank_r] !=
         {`BRANCH_MASK_W{1'b1}})) begin
        $fatal(1, "shared_prefix_reuse: free_list should freeze shared-prefix ownership conservatively");
    end

    sample_query_bank("shared_prefix_before_commit", shared_sram_r, shared_bank_r);
    if (sampled_query_bitmap_r[shared_subbank_r +: `KV_GROUP_SIZE_SUBBANK] !=
            {`KV_GROUP_SIZE_SUBBANK{1'b1}} ||
        sampled_query_state_r != BANK_STATE_SPEC ||
        sampled_query_branch_mask_r != BRANCH0_MASK ||
        sampled_query_refcnt_r != {{(`REFCNT_W-1){1'b0}}, 1'b1}) begin
        $fatal(1, "shared_prefix_before_commit: query state mismatch");
    end

    drive_commit(
        4'h2,
        shared_sram_r,
        shared_bank_r,
        shared_subbank_r,
        shared_len_r,
        BRANCH0_MASK | BRANCH1_MASK,
        node_mask_for_branch_node(2'd0, 4'd2) |
        node_mask_for_branch_node(2'd1, 4'd2)
    );

    sample_query_bank("shared_prefix_after_commit", shared_sram_r, shared_bank_r);
    if (sampled_query_state_r != BANK_STATE_COMMITTED ||
        sampled_query_branch_mask_r != (BRANCH0_MASK | BRANCH1_MASK) ||
        sampled_query_refcnt_r != {{(`REFCNT_W-2){1'b0}}, 2'b10}) begin
        $fatal(1, "shared_prefix_after_commit: promotion branch visibility mismatch");
    end

    issue_candidate_expect_grant(
        "private_isolated_entry",
        4'h3,
        2'd0,
        4'd3,
        1'b0,
        SHARED_BANKS_PER_SRAM_BANK_ID,
        DOUBLE_KV_GROUP_SIZE_SUBBANK_ID,
        isolated_sram_r,
        isolated_bank_r,
        isolated_subbank_r,
        isolated_len_r
    );

    drive_commit(
        4'h3,
        isolated_sram_r,
        isolated_bank_r,
        isolated_subbank_r,
        isolated_len_r,
        BRANCH0_MASK | BRANCH1_MASK,
        node_mask_for_branch_node(2'd0, 4'd3) |
        node_mask_for_branch_node(2'd1, 4'd3)
    );

    sample_query_bank("private_after_illegal_multibranch_commit",
                      isolated_sram_r, isolated_bank_r);
    if (sampled_query_state_r != BANK_STATE_COMMITTED ||
        sampled_query_branch_mask_r != BRANCH0_MASK ||
        sampled_query_refcnt_r != {{(`REFCNT_W-1){1'b0}}, 1'b1} ||
        u_bank_state_table.promoted_bitmap
            [(isolated_sram_r * `SRAM_BANK_NUM) + isolated_bank_r][isolated_subbank_r]) begin
        $fatal(1, "private_after_illegal_multibranch_commit: branch isolation invariant broken");
    end

    $display("tb_tree_control_stage2_sram_advanced_features_min PASS");
    $finish;
end

endmodule
