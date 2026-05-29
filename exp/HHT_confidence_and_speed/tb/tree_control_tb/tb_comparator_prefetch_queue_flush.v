`timescale 1ns/1ps

`include "config/prediction_params.vh"
`include "config/interface_params.vh"
`include "config/memory_params.vh"

module tb_comparator_prefetch_queue_flush;

reg clk;
reg rst_n;

reg [`REQ_ID_W-1:0] cmp_req_id;
reg [`BRANCH_NUM-1:0] cmp_slot_valid;
reg [`BRANCH_NUM*`TOKEN_ID_W-1:0] cmp_slot_real_token_id;
reg [`BRANCH_NUM*`TOKEN_ID_W-1:0] cmp_slot_candidate_token_id;
reg [`BRANCH_NUM*`NODE_ID_W-1:0] cmp_slot_node_id;
reg [`BRANCH_NUM*`NODE_ID_W-1:0] cmp_slot_parent_node_id;
reg [`BRANCH_NUM*`BRANCH_ID_W-1:0] cmp_slot_branch_id;

reg tree_in_valid;
wire tree_in_ready;
reg [`REQ_ID_W-1:0] tree_in_req_id;
reg [`BRANCH_ID_W-1:0] tree_in_branch_id;
reg [`NODE_ID_W-1:0] tree_in_node_id;

reg prefix_valid;
wire prefix_ready;
reg [`REQ_ID_W-1:0] prefix_req_id;
reg prefix_node_valid;
reg [`NODE_ID_W-1:0] prefix_node_id;
reg [`NODE_ID_W-1:0] prefix_parent_node_id;
reg [`TOKEN_ID_W-1:0] prefix_token_id;
reg [`POSITION_ID_W-1:0] prefix_position_id;
reg [`LAYER_ID_W-1:0] prefix_layer_id;
reg prefix_is_last;

reg frontier_valid;
wire frontier_ready;
reg [`REQ_ID_W-1:0] frontier_req_id;
reg [`TREE_LEVEL_ID_W-1:0] frontier_level_id;
reg [`TREE_FRONTIER_SLOTS-1:0] frontier_slot_valid;
reg [`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0] frontier_node_id;
reg [`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0] frontier_parent_node_id;
reg [`TREE_FRONTIER_SLOTS*`TOKEN_ID_W-1:0] frontier_token_id;
reg [`TREE_FRONTIER_SLOTS*`POSITION_ID_W-1:0] frontier_position_id;

wire prefetch_enq_ready;
reg cand_resp_valid;
reg cand_resp_grant;
reg [`REQ_ID_W-1:0] cand_resp_req_id;
reg [`SRAM_ID_W-1:0] cand_resp_sram_id;
reg [`BANK_ID_W-1:0] cand_resp_bank_id;
reg [`SUBBANK_ID_W-1:0] cand_resp_subbank_start;
reg [`KV_GROUP_LEN_W-1:0] cand_resp_group_len;
reg alloc_resp_valid;
reg alloc_resp_grant;
reg [`REQ_ID_W-1:0] alloc_resp_req_id;
reg [`SRAM_ID_W-1:0] alloc_resp_sram_id;
reg [`BANK_ID_W-1:0] alloc_resp_bank_id;
reg [`SUBBANK_ID_W-1:0] alloc_resp_subbank_start;
reg [`KV_GROUP_LEN_W-1:0] alloc_resp_group_len;

wire commit_valid;
wire [`BRANCH_MASK_W-1:0] commit_branch_mask;
wire [`NODE_MASK_W-1:0] commit_node_mask;
wire flush_valid;
wire [`BRANCH_MASK_W-1:0] flush_branch_mask;
wire [`NODE_MASK_W-1:0] flush_node_mask;
wire flush_freeze;

wire prefix_norm_valid;
wire [`REQ_ID_W-1:0] prefix_norm_req_id;
wire prefix_norm_node_valid;
wire [`NODE_ID_W-1:0] prefix_norm_node_id;
wire [`NODE_ID_W-1:0] prefix_norm_parent_node_id;
wire [`TOKEN_ID_W-1:0] prefix_norm_token_id;
wire [`POSITION_ID_W-1:0] prefix_norm_position_id;
wire [`LAYER_ID_W-1:0] prefix_norm_layer_id;
wire prefix_norm_is_last;
wire prefix_norm_is_shared;
wire frontier_norm_valid;
wire [`REQ_ID_W-1:0] frontier_norm_req_id;
wire [`TREE_LEVEL_ID_W-1:0] frontier_norm_level_id;
wire [`TREE_FRONTIER_SLOTS-1:0] frontier_norm_slot_valid;
wire [`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0] frontier_norm_node_id;
wire [`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0] frontier_norm_parent_node_id;
wire [`TREE_FRONTIER_SLOTS*`TOKEN_ID_W-1:0] frontier_norm_token_id;
wire [`TREE_FRONTIER_SLOTS*`POSITION_ID_W-1:0] frontier_norm_position_id;
wire [`TREE_FRONTIER_SLOTS*`KV_GROUP_LEN_W-1:0] frontier_norm_size_subbank;
wire [`TREE_FRONTIER_SLOTS-1:0] frontier_norm_slot_shared;
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
wire token_wr_valid;
wire [`REQ_ID_W-1:0] token_wr_req_id;
wire [`TOKEN_ID_W-1:0] token_wr_token_id;
wire [`POSITION_ID_W-1:0] token_wr_position_id;
wire [`NODE_ID_W-1:0] token_wr_node_id;
wire [`BRANCH_ID_W-1:0] token_wr_branch_id;
wire [`BRANCH_MASK_W-1:0] token_wr_branch_mask;
wire token_wr_is_shared;
wire [`SRAM_ID_W-1:0] token_wr_sram_id;
wire [`BANK_ID_W-1:0] token_wr_bank_id;
wire [`SUBBANK_ID_W-1:0] token_wr_subbank_start;
wire [`KV_GROUP_LEN_W-1:0] token_wr_group_len;
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

wire queue_deq_valid;
reg queue_deq_ready;
wire [`REQ_ID_W-1:0] queue_deq_req_id;
wire [`BRANCH_ID_W-1:0] queue_deq_branch_id;
wire [`NODE_ID_W-1:0] queue_deq_node_id;
wire [`LAYER_ID_W-1:0] queue_deq_layer_id;
wire [`KV_GROUP_LEN_W-1:0] queue_deq_size_subbank;
wire queue_deq_shared;

assign flush_freeze = flush_valid;

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

agu u_agu (
    .clk(clk),
    .rst_n(rst_n),
    .tree_in_valid(tree_in_valid),
    .tree_in_ready(tree_in_ready),
    .tree_in_req_id(tree_in_req_id),
    .tree_in_branch_id(tree_in_branch_id),
    .tree_in_node_id(tree_in_node_id),
    .prefix_valid(prefix_valid),
    .prefix_ready(prefix_ready),
    .prefix_req_id(prefix_req_id),
    .prefix_node_valid(prefix_node_valid),
    .prefix_node_id(prefix_node_id),
    .prefix_parent_node_id(prefix_parent_node_id),
    .prefix_token_id(prefix_token_id),
    .prefix_position_id(prefix_position_id),
    .prefix_layer_id(prefix_layer_id),
    .prefix_is_last(prefix_is_last),
    .frontier_valid(frontier_valid),
    .frontier_ready(frontier_ready),
    .frontier_req_id(frontier_req_id),
    .frontier_level_id(frontier_level_id),
    .frontier_slot_valid(frontier_slot_valid),
    .frontier_node_id(frontier_node_id),
    .frontier_parent_node_id(frontier_parent_node_id),
    .frontier_token_id(frontier_token_id),
    .frontier_position_id(frontier_position_id),
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
    .prefix_norm_valid(prefix_norm_valid),
    .prefix_norm_req_id(prefix_norm_req_id),
    .prefix_norm_node_valid(prefix_norm_node_valid),
    .prefix_norm_node_id(prefix_norm_node_id),
    .prefix_norm_parent_node_id(prefix_norm_parent_node_id),
    .prefix_norm_token_id(prefix_norm_token_id),
    .prefix_norm_position_id(prefix_norm_position_id),
    .prefix_norm_layer_id(prefix_norm_layer_id),
    .prefix_norm_is_last(prefix_norm_is_last),
    .prefix_norm_is_shared(prefix_norm_is_shared),
    .frontier_norm_valid(frontier_norm_valid),
    .frontier_norm_req_id(frontier_norm_req_id),
    .frontier_norm_level_id(frontier_norm_level_id),
    .frontier_norm_slot_valid(frontier_norm_slot_valid),
    .frontier_norm_node_id(frontier_norm_node_id),
    .frontier_norm_parent_node_id(frontier_norm_parent_node_id),
    .frontier_norm_token_id(frontier_norm_token_id),
    .frontier_norm_position_id(frontier_norm_position_id),
    .frontier_norm_size_subbank(frontier_norm_size_subbank),
    .frontier_norm_slot_shared(frontier_norm_slot_shared),
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
    .token_wr_valid(token_wr_valid),
    .token_wr_req_id(token_wr_req_id),
    .token_wr_token_id(token_wr_token_id),
    .token_wr_position_id(token_wr_position_id),
    .token_wr_node_id(token_wr_node_id),
    .token_wr_branch_id(token_wr_branch_id),
    .token_wr_branch_mask(token_wr_branch_mask),
    .token_wr_is_shared(token_wr_is_shared),
    .token_wr_sram_id(token_wr_sram_id),
    .token_wr_bank_id(token_wr_bank_id),
    .token_wr_subbank_start(token_wr_subbank_start),
    .token_wr_group_len(token_wr_group_len),
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
    .prefetch_flush_node_mask(prefetch_flush_node_mask)
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

task clear_agu_inputs;
    begin
        tree_in_valid = 1'b0;
        tree_in_req_id = {`REQ_ID_W{1'b0}};
        tree_in_branch_id = {`BRANCH_ID_W{1'b0}};
        tree_in_node_id = {`NODE_ID_W{1'b0}};
        prefix_valid = 1'b0;
        prefix_req_id = {`REQ_ID_W{1'b0}};
        prefix_node_valid = 1'b0;
        prefix_node_id = {`NODE_ID_W{1'b0}};
        prefix_parent_node_id = {`NODE_ID_W{1'b0}};
        prefix_token_id = {`TOKEN_ID_W{1'b0}};
        prefix_position_id = {`POSITION_ID_W{1'b0}};
        prefix_layer_id = {`LAYER_ID_W{1'b0}};
        prefix_is_last = 1'b0;
        frontier_valid = 1'b0;
        frontier_req_id = {`REQ_ID_W{1'b0}};
        frontier_level_id = {`TREE_LEVEL_ID_W{1'b0}};
        frontier_slot_valid = {`TREE_FRONTIER_SLOTS{1'b0}};
        frontier_node_id = {(`TREE_FRONTIER_SLOTS*`NODE_ID_W){1'b0}};
        frontier_parent_node_id = {(`TREE_FRONTIER_SLOTS*`NODE_ID_W){1'b0}};
        frontier_token_id = {(`TREE_FRONTIER_SLOTS*`TOKEN_ID_W){1'b0}};
        frontier_position_id = {(`TREE_FRONTIER_SLOTS*`POSITION_ID_W){1'b0}};
        cand_resp_valid = 1'b0;
        cand_resp_grant = 1'b0;
        cand_resp_req_id = {`REQ_ID_W{1'b0}};
        cand_resp_sram_id = {`SRAM_ID_W{1'b0}};
        cand_resp_bank_id = {`BANK_ID_W{1'b0}};
        cand_resp_subbank_start = {`SUBBANK_ID_W{1'b0}};
        cand_resp_group_len = {`KV_GROUP_LEN_W{1'b0}};
        alloc_resp_valid = 1'b0;
        alloc_resp_grant = 1'b0;
        alloc_resp_req_id = {`REQ_ID_W{1'b0}};
        alloc_resp_sram_id = {`SRAM_ID_W{1'b0}};
        alloc_resp_bank_id = {`BANK_ID_W{1'b0}};
        alloc_resp_subbank_start = {`SUBBANK_ID_W{1'b0}};
        alloc_resp_group_len = {`KV_GROUP_LEN_W{1'b0}};
    end
endtask

task drive_tree_and_prefix_pair;
    begin
        tree_in_valid = 1'b1;
        tree_in_req_id = 4'h3;
        tree_in_branch_id = 2'd1;
        tree_in_node_id = 4'd2;

        prefix_valid = 1'b1;
        prefix_req_id = 4'h4;
        prefix_node_valid = 1'b1;
        prefix_node_id = 4'd1;
        prefix_parent_node_id = 4'd0;
        prefix_token_id = 16'h0011;
        prefix_position_id = 16'h0022;
        prefix_layer_id = 6'd7;
        prefix_is_last = 1'b0;
    end
endtask

task service_pending_req;
    input [`REQ_ID_W-1:0] req_id;
    begin
        cand_resp_valid = 1'b1;
        cand_resp_grant = 1'b1;
        cand_resp_req_id = req_id;
        cand_resp_sram_id = {`SRAM_ID_W{1'b0}};
        cand_resp_bank_id = {`BANK_ID_W{1'b0}};
        cand_resp_subbank_start = {`SUBBANK_ID_W{1'b0}};
        cand_resp_group_len = `KV_GROUP_SIZE_SUBBANK;

        @(posedge clk);
        // Avoid a same-edge TB/DUT race on the candidate handshake edge.
        #1;

        cand_resp_valid = 1'b0;
        cand_resp_grant = 1'b0;
        cand_resp_req_id = {`REQ_ID_W{1'b0}};

        alloc_resp_valid = 1'b1;
        alloc_resp_grant = 1'b1;
        alloc_resp_req_id = req_id;
        alloc_resp_sram_id = {`SRAM_ID_W{1'b0}};
        alloc_resp_bank_id = {`BANK_ID_W{1'b0}};
        alloc_resp_subbank_start = {`SUBBANK_ID_W{1'b0}};
        alloc_resp_group_len = `KV_GROUP_SIZE_SUBBANK;

        @(posedge clk);
        // Avoid a same-edge TB/DUT race on the alloc-response edge.
        #1;

        alloc_resp_valid = 1'b0;
        alloc_resp_grant = 1'b0;
        alloc_resp_req_id = {`REQ_ID_W{1'b0}};
    end
endtask

task wait_for_agu_enqueue;
    input [255:0] scenario_name;
    input [`REQ_ID_W-1:0] req_id;
    input [`BRANCH_ID_W-1:0] branch_id;
    input [`NODE_ID_W-1:0] node_id;
    input [`LAYER_ID_W-1:0] layer_id;
    input [`KV_GROUP_LEN_W-1:0] size_subbank;
    input shared;
    integer wait_i;
    reg seen;
    begin
        seen = 1'b0;
        for (wait_i = 0; wait_i < 6; wait_i = wait_i + 1) begin
            @(negedge clk);
            #1;
            if (prefetch_enq_valid) begin
                if (prefetch_enq_req_id != req_id ||
                    prefetch_enq_branch_id != branch_id ||
                    prefetch_enq_node_id != node_id ||
                    prefetch_enq_layer_id != layer_id ||
                    prefetch_enq_size_subbank != size_subbank ||
                    prefetch_enq_shared != shared) begin
                    $fatal(1, "%0s: AGU enqueue payload mismatch", scenario_name);
                end
                seen = 1'b1;
                disable wait_for_agu_enqueue;
            end
        end
        if (!seen) begin
            $fatal(1, "%0s: AGU enqueue did not appear within bounded wait", scenario_name);
        end
    end
endtask

task wait_for_prefetch_head;
    input [255:0] scenario_name;
    input [`REQ_ID_W-1:0] req_id;
    input [`BRANCH_ID_W-1:0] branch_id;
    input [`NODE_ID_W-1:0] node_id;
    input [`LAYER_ID_W-1:0] layer_id;
    input [`KV_GROUP_LEN_W-1:0] size_subbank;
    input shared;
    integer wait_i;
    reg seen;
    begin
        seen = 1'b0;
        for (wait_i = 0; wait_i < 6; wait_i = wait_i + 1) begin
            @(negedge clk);
            #1;
            if (queue_deq_valid) begin
                if (queue_deq_req_id != req_id ||
                    queue_deq_branch_id != branch_id ||
                    queue_deq_node_id != node_id ||
                    queue_deq_layer_id != layer_id ||
                    queue_deq_size_subbank != size_subbank ||
                    queue_deq_shared != shared) begin
                    $fatal(1, "%0s: queue head payload mismatch", scenario_name);
                end
                seen = 1'b1;
                disable wait_for_prefetch_head;
            end
        end
        if (!seen) begin
            $fatal(1, "%0s: queue head did not appear within bounded wait", scenario_name);
        end
    end
endtask

task consume_prefetch_head;
    begin
        queue_deq_ready = 1'b1;
        @(posedge clk);
        queue_deq_ready = 1'b0;
    end
endtask

task expect_flush_frozen;
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
            $fatal(1, "AGU should own and forward queue flush controls");
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
            queue_deq_ready) begin
            $fatal(1, "AGU acceptance should be open when comparator flush is inactive");
        end
        if (prefetch_flush_valid) begin
            $fatal(1, "AGU queue flush output should be idle when comparator flush is inactive");
        end
    end
endtask

initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    queue_deq_ready = 1'b0;
    clear_comparator_inputs();
    clear_agu_inputs();

    repeat (3) @(posedge clk);
    rst_n = 1'b1;

    #1;
    expect_accept_open();

    drive_tree_and_prefix_pair();
    wait_for_agu_enqueue("tree_in_enqueue",
                         4'h3,
                         2'd1,
                         4'd2,
                         {`LAYER_ID_W{1'b0}},
                         `KV_GROUP_SIZE_SUBBANK,
                         1'b0);

    @(posedge clk);
    // Avoid a same-edge TB/DUT race so AGU can sample the prefix enqueue.
    #1;
    tree_in_valid = 1'b0;
    prefix_valid = 1'b0;

    service_pending_req(4'h3);

    wait_for_agu_enqueue("prefix_enqueue",
                         4'h4,
                         {`BRANCH_ID_W{1'b0}},
                         4'd1,
                         6'd7,
                         `KV_GROUP_SIZE_SUBBANK,
                         1'b1);

    @(posedge clk);
    service_pending_req(4'h4);

    wait_for_prefetch_head("queue_head_before_flush",
                           4'h3,
                           2'd1,
                           4'd2,
                           {`LAYER_ID_W{1'b0}},
                           `KV_GROUP_SIZE_SUBBANK,
                           1'b0);

    cmp_req_id = 4'h3;
    cmp_slot_valid[0] = 1'b1;
    cmp_slot_real_token_id[`TOKEN_ID_W-1:0] = 16'h0101;
    cmp_slot_candidate_token_id[`TOKEN_ID_W-1:0] = 16'h0202;
    cmp_slot_node_id[`NODE_ID_W-1:0] = 4'd2;
    cmp_slot_parent_node_id[`NODE_ID_W-1:0] = 4'd1;
    cmp_slot_branch_id[`BRANCH_ID_W-1:0] = 2'd1;
    expect_flush_frozen();

    @(posedge clk);
    clear_comparator_inputs();

    expect_accept_open();
    wait_for_prefetch_head("queue_head_after_flush",
                           4'h4,
                           {`BRANCH_ID_W{1'b0}},
                           4'd1,
                           6'd7,
                           `KV_GROUP_SIZE_SUBBANK,
                           1'b1);

    consume_prefetch_head();

    #1;
    if (queue_deq_valid) begin
        $fatal(1, "queue should contain only the surviving entry after selective flush");
    end

    $display("tb_comparator_prefetch_queue_flush PASS");
    $finish;
end

endmodule
