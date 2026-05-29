`timescale 1ns/1ps

`include "config/prediction_params.vh"
`include "config/interface_params.vh"
`include "config/memory_params.vh"

module tb_comparator_free_list_flush;

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

reg alloc_resp_valid;
reg alloc_resp_grant;
reg [`REQ_ID_W-1:0] alloc_resp_req_id;
reg [`SRAM_ID_W-1:0] alloc_resp_sram_id;
reg [`BANK_ID_W-1:0] alloc_resp_bank_id;
reg [`SUBBANK_ID_W-1:0] alloc_resp_subbank_start;
reg [`KV_GROUP_LEN_W-1:0] alloc_resp_group_len;

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
    .release_valid(1'b0),
    .release_sram_id({`SRAM_ID_W{1'b0}}),
    .release_bank_id({`BANK_ID_W{1'b0}}),
    .release_subbank_start({`SUBBANK_ID_W{1'b0}}),
    .release_group_len({`KV_GROUP_LEN_W{1'b0}})
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

task clear_alloc_resp;
    begin
        alloc_resp_valid = 1'b0;
        alloc_resp_grant = 1'b0;
        alloc_resp_req_id = {`REQ_ID_W{1'b0}};
        alloc_resp_sram_id = {`SRAM_ID_W{1'b0}};
        alloc_resp_bank_id = {`BANK_ID_W{1'b0}};
        alloc_resp_subbank_start = {`SUBBANK_ID_W{1'b0}};
        alloc_resp_group_len = {`KV_GROUP_LEN_W{1'b0}};
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
                seen = 1'b1;
                disable wait_for_cand_resp;
            end
        end

        if (!seen) begin
            $fatal(1, "%0s: cand_resp did not appear within bounded wait", scenario_name);
        end
    end
endtask

task service_alloc_resp;
    input [`REQ_ID_W-1:0] req_id;
    begin
        @(posedge clk);
        #1;
        alloc_resp_valid = 1'b1;
        alloc_resp_grant = 1'b1;
        alloc_resp_req_id = req_id;
        alloc_resp_sram_id = {`SRAM_ID_W{1'b0}};
        alloc_resp_bank_id = {`BANK_ID_W{1'b0}};
        alloc_resp_subbank_start = {`SUBBANK_ID_W{1'b0}};
        alloc_resp_group_len = `KV_GROUP_SIZE_SUBBANK;

        @(posedge clk);
        #1;
        clear_alloc_resp();
    end
endtask

task issue_req_expect_grant;
    input [255:0] scenario_name;
    input [`REQ_ID_W-1:0] req_id;
    input [`BRANCH_ID_W-1:0] branch_id;
    input [`NODE_ID_W-1:0] node_id;
    begin
        drive_scalar_req(req_id, branch_id, node_id);
        wait_for_cand_resp(scenario_name, req_id, 1'b1);
        service_alloc_resp(req_id);
    end
endtask

task issue_req_expect_deny;
    input [255:0] scenario_name;
    input [`REQ_ID_W-1:0] req_id;
    input [`BRANCH_ID_W-1:0] branch_id;
    input [`NODE_ID_W-1:0] node_id;
    begin
        drive_scalar_req(req_id, branch_id, node_id);
        wait_for_cand_resp(scenario_name, req_id, 1'b0);
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
    clear_alloc_resp();

    repeat (3) @(posedge clk);
    rst_n = 1'b1;

    #1;
    expect_accept_open();

    issue_req_expect_grant("victim_alloc", 4'h3, 2'd1, 4'd2);
    issue_req_expect_grant("survivor_alloc", 4'h3, 2'd0, 4'd1);

    for (filler_i = 0; filler_i < FILLER_ALLOC_COUNT; filler_i = filler_i + 1) begin
        issue_req_expect_grant("filler_alloc", 4'h4, 2'd2, 4'd0);
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

    @(posedge clk);
    #1;
    clear_comparator_inputs();

    @(posedge clk);
    #1;
    expect_accept_open();

    issue_req_expect_grant("one_slot_restored", 4'h5, 2'd3, 4'd0);
    issue_req_expect_deny("survivor_not_reclaimed", 4'h6, 2'd3, 4'd1);

    $display("tb_comparator_free_list_flush PASS");
    $finish;
end

endmodule
