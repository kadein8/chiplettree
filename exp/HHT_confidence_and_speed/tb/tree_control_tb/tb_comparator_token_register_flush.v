`timescale 1ns/1ps

`include "config/prediction_params.vh"
`include "config/interface_params.vh"
`include "config/memory_params.vh"

module tb_comparator_token_register_flush;

localparam [`REQ_ID_W-1:0] TEST_REQ_ID = 4'h3;
localparam [`TOKEN_REG_INDEX_W-1:0] VICTIM_INDEX = {`TOKEN_REG_INDEX_W{1'b0}};
localparam [`TOKEN_REG_INDEX_W-1:0] SURVIVOR_INDEX = {{(`TOKEN_REG_INDEX_W-1){1'b0}}, 1'b1};

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

wire tree_in_ready;
wire prefix_ready;
wire frontier_ready;

wire token_flush_valid;
wire [`REQ_ID_W-1:0] token_flush_req_id;
wire [`BRANCH_MASK_W-1:0] token_flush_branch_mask;
wire [`NODE_MASK_W-1:0] token_flush_node_mask;

reg wr_valid;
wire wr_ready;
reg [`TOKEN_REG_INDEX_W-1:0] wr_index;
reg [`REQ_ID_W-1:0] wr_req_id;
reg [`TOKEN_ID_W-1:0] wr_token_id;
reg [`POSITION_ID_W-1:0] wr_position_id;
reg [`NODE_ID_W-1:0] wr_node_id;
reg [`BRANCH_ID_W-1:0] wr_branch_id;
reg [`SRAM_ID_W-1:0] wr_sram_id;
reg [`BANK_ID_W-1:0] wr_bank_id;
reg [`SUBBANK_ID_W-1:0] wr_subbank_start;
reg [`KV_GROUP_LEN_W-1:0] wr_group_len;
reg [`BRANCH_MASK_W-1:0] wr_branch_mask;
reg wr_is_shared;

reg lookup_valid;
wire lookup_ready;
reg [`REQ_ID_W-1:0] lookup_req_id;
reg [`TOKEN_ID_W-1:0] lookup_token_id;
reg [`POSITION_ID_W-1:0] lookup_position_id;
wire lookup_resp_valid;
wire lookup_resp_hit;
wire [`REQ_ID_W-1:0] lookup_resp_req_id;
wire [`SRAM_ID_W-1:0] lookup_resp_sram_id;
wire [`BANK_ID_W-1:0] lookup_resp_bank_id;
wire [`SUBBANK_ID_W-1:0] lookup_resp_subbank_start;
wire [`KV_GROUP_LEN_W-1:0] lookup_resp_group_len;
wire [`BRANCH_MASK_W-1:0] lookup_resp_branch_mask;
wire lookup_resp_is_shared;
wire [`TOKEN_STATE_W-1:0] lookup_resp_state;
wire [`TOKEN_REG_INDEX_W:0] entry_count;
wire error_flag;

function [`BRANCH_MASK_W-1:0] branch_onehot_mask;
    input [`BRANCH_ID_W-1:0] branch_id_in;
    begin
        branch_onehot_mask = {`BRANCH_MASK_W{1'b0}};
        if (branch_id_in < `BRANCH_NUM) begin
            branch_onehot_mask[branch_id_in] = 1'b1;
        end
    end
endfunction

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
    .tree_in_valid(1'b0),
    .tree_in_ready(tree_in_ready),
    .tree_in_req_id({`REQ_ID_W{1'b0}}),
    .tree_in_branch_id({`BRANCH_ID_W{1'b0}}),
    .tree_in_node_id({`NODE_ID_W{1'b0}}),
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
    .prefetch_enq_ready(1'b1),
    .cand_resp_valid(1'b0),
    .cand_resp_grant(1'b0),
    .cand_resp_req_id({`REQ_ID_W{1'b0}}),
    .cand_resp_sram_id({`SRAM_ID_W{1'b0}}),
    .cand_resp_bank_id({`BANK_ID_W{1'b0}}),
    .cand_resp_subbank_start({`SUBBANK_ID_W{1'b0}}),
    .cand_resp_group_len({`KV_GROUP_LEN_W{1'b0}}),
    .alloc_resp_valid(1'b0),
    .alloc_resp_grant(1'b0),
    .alloc_resp_req_id({`REQ_ID_W{1'b0}}),
    .alloc_resp_sram_id({`SRAM_ID_W{1'b0}}),
    .alloc_resp_bank_id({`BANK_ID_W{1'b0}}),
    .alloc_resp_subbank_start({`SUBBANK_ID_W{1'b0}}),
    .alloc_resp_group_len({`KV_GROUP_LEN_W{1'b0}}),
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
    .prefetch_enq_valid(),
    .prefetch_enq_req_id(),
    .prefetch_enq_branch_id(),
    .prefetch_enq_node_id(),
    .prefetch_enq_layer_id(),
    .prefetch_enq_size_subbank(),
    .prefetch_enq_shared(),
    .prefetch_flush_valid(),
    .prefetch_flush_req_id(),
    .prefetch_flush_branch_mask(),
    .prefetch_flush_node_mask(),
    .free_list_flush_valid(),
    .free_list_flush_req_id(),
    .free_list_flush_branch_mask(),
    .free_list_flush_node_mask(),
    .token_flush_valid(token_flush_valid),
    .token_flush_req_id(token_flush_req_id),
    .token_flush_branch_mask(token_flush_branch_mask),
    .token_flush_node_mask(token_flush_node_mask)
);

token_register u_token_register (
    .clk(clk),
    .rst_n(rst_n),
    .wr_valid(wr_valid),
    .wr_ready(wr_ready),
    .wr_index(wr_index),
    .wr_req_id(wr_req_id),
    .wr_token_id(wr_token_id),
    .wr_position_id(wr_position_id),
    .wr_node_id(wr_node_id),
    .wr_branch_id(wr_branch_id),
    .wr_sram_id(wr_sram_id),
    .wr_bank_id(wr_bank_id),
    .wr_subbank_start(wr_subbank_start),
    .wr_group_len(wr_group_len),
    .wr_branch_mask(wr_branch_mask),
    .wr_is_shared(wr_is_shared),
    .lookup_valid(lookup_valid),
    .lookup_ready(lookup_ready),
    .lookup_req_id(lookup_req_id),
    .lookup_token_id(lookup_token_id),
    .lookup_position_id(lookup_position_id),
    .lookup_resp_valid(lookup_resp_valid),
    .lookup_resp_hit(lookup_resp_hit),
    .lookup_resp_req_id(lookup_resp_req_id),
    .lookup_resp_sram_id(lookup_resp_sram_id),
    .lookup_resp_bank_id(lookup_resp_bank_id),
    .lookup_resp_subbank_start(lookup_resp_subbank_start),
    .lookup_resp_group_len(lookup_resp_group_len),
    .lookup_resp_branch_mask(lookup_resp_branch_mask),
    .lookup_resp_is_shared(lookup_resp_is_shared),
        .lookup_resp_entry_type(),
.lookup_resp_state(lookup_resp_state),
    .commit_valid(1'b0),
    .commit_index({`TOKEN_REG_INDEX_W{1'b0}}),
    .commit_req_id({`REQ_ID_W{1'b0}}),
    .commit_branch_mask({`BRANCH_MASK_W{1'b0}}),
    .commit_node_mask({`NODE_MASK_W{1'b0}}),
    .flush_valid(token_flush_valid),
    .flush_req_id(token_flush_req_id),
    .flush_branch_mask(token_flush_branch_mask),
    .flush_node_mask(token_flush_node_mask),
    .entry_count(entry_count),
    .error_flag(error_flag)
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

task clear_token_controls;
    begin
        wr_valid = 1'b0;
        wr_index = {`TOKEN_REG_INDEX_W{1'b0}};
        wr_req_id = {`REQ_ID_W{1'b0}};
        wr_token_id = {`TOKEN_ID_W{1'b0}};
        wr_position_id = {`POSITION_ID_W{1'b0}};
        wr_node_id = {`NODE_ID_W{1'b0}};
        wr_branch_id = {`BRANCH_ID_W{1'b0}};
        wr_sram_id = {`SRAM_ID_W{1'b0}};
        wr_bank_id = {`BANK_ID_W{1'b0}};
        wr_subbank_start = {`SUBBANK_ID_W{1'b0}};
        wr_group_len = {`KV_GROUP_LEN_W{1'b0}};
        wr_branch_mask = {`BRANCH_MASK_W{1'b0}};
        wr_is_shared = 1'b0;
        lookup_valid = 1'b0;
        lookup_req_id = {`REQ_ID_W{1'b0}};
        lookup_token_id = {`TOKEN_ID_W{1'b0}};
        lookup_position_id = {`POSITION_ID_W{1'b0}};
    end
endtask

task expect_accept_open;
    input [255:0] scenario_name;
    begin
        #1;
        if (flush_valid ||
            flush_freeze ||
            !tree_in_ready ||
            !prefix_ready ||
            !frontier_ready) begin
            $fatal(1, "%0s: AGU should remain open before flush", scenario_name);
        end
    end
endtask

task write_entry;
    input [`TOKEN_REG_INDEX_W-1:0] index_in;
    input [`TOKEN_ID_W-1:0] token_id_in;
    input [`POSITION_ID_W-1:0] position_id_in;
    input [`NODE_ID_W-1:0] node_id_in;
    input [`BRANCH_ID_W-1:0] branch_id_in;
    input [`SRAM_ID_W-1:0] sram_id_in;
    input [`BANK_ID_W-1:0] bank_id_in;
    input [`SUBBANK_ID_W-1:0] subbank_start_in;
    begin
        @(posedge clk);
        #1;
        wr_valid = 1'b1;
        wr_index = index_in;
        wr_req_id = TEST_REQ_ID;
        wr_token_id = token_id_in;
        wr_position_id = position_id_in;
        wr_node_id = node_id_in;
        wr_branch_id = branch_id_in;
        wr_sram_id = sram_id_in;
        wr_bank_id = bank_id_in;
        wr_subbank_start = subbank_start_in;
        wr_group_len = `KV_GROUP_SIZE_SUBBANK;
        wr_branch_mask = branch_onehot_mask(branch_id_in);
        wr_is_shared = 1'b0;

        @(posedge clk);
        #1;
        wr_valid = 1'b0;
    end
endtask

task lookup_expect;
    input [255:0] scenario_name;
    input [`TOKEN_ID_W-1:0] token_id_in;
    input [`POSITION_ID_W-1:0] position_id_in;
    input expect_hit;
    input [`BRANCH_MASK_W-1:0] expect_branch_mask;
    begin
        @(posedge clk);
        #1;
        lookup_valid = 1'b1;
        lookup_req_id = TEST_REQ_ID;
        lookup_token_id = token_id_in;
        lookup_position_id = position_id_in;

        @(posedge clk);
        #1;
        if (!lookup_resp_valid) begin
            $fatal(1, "%0s: lookup response missing", scenario_name);
        end
        if (lookup_resp_req_id != TEST_REQ_ID) begin
            $fatal(1, "%0s: lookup req_id mismatch", scenario_name);
        end
        if (lookup_resp_hit != expect_hit) begin
            $fatal(1, "%0s: lookup hit mismatch", scenario_name);
        end

        if (expect_hit) begin
            if (lookup_resp_state == {`TOKEN_STATE_W{1'b0}}) begin
                $fatal(1, "%0s: expected valid token state", scenario_name);
            end
            if (lookup_resp_branch_mask != expect_branch_mask) begin
                $fatal(1, "%0s: branch mask mismatch", scenario_name);
            end
        end else begin
            if (lookup_resp_state != {`TOKEN_STATE_W{1'b0}}) begin
                $fatal(1, "%0s: victim should return invalid state after flush",
                       scenario_name);
            end
        end

        lookup_valid = 1'b0;
    end
endtask

task trigger_flush_and_check_bridge;
    begin
        @(posedge clk);
        #1;
        cmp_req_id = TEST_REQ_ID;
        cmp_slot_valid[0] = 1'b1;
        cmp_slot_real_token_id[`TOKEN_ID_W-1:0] = 16'h0101;
        cmp_slot_candidate_token_id[`TOKEN_ID_W-1:0] = 16'h0202;
        cmp_slot_node_id[`NODE_ID_W-1:0] = 4'd2;
        cmp_slot_parent_node_id[`NODE_ID_W-1:0] = 4'd1;
        cmp_slot_branch_id[`BRANCH_ID_W-1:0] = 2'd1;

        #1;
        if (!flush_valid || commit_valid) begin
            $fatal(1, "comparator mismatch should generate flush-only behavior");
        end
        if (!flush_freeze || tree_in_ready || prefix_ready || frontier_ready) begin
            $fatal(1, "comparator flush should close AGU front-end readiness");
        end
        if (!token_flush_valid ||
            (token_flush_req_id != TEST_REQ_ID) ||
            (token_flush_branch_mask != flush_branch_mask) ||
            (token_flush_node_mask != flush_node_mask)) begin
            $fatal(1, "AGU should own and forward token_register flush controls");
        end

        @(posedge clk);
        #1;
        cmp_slot_valid = {`BRANCH_NUM{1'b0}};
    end
endtask

initial begin
    clk = 1'b0;
    rst_n = 1'b0;

    clear_comparator_inputs();
    clear_token_controls();

    repeat (3) @(posedge clk);
    rst_n = 1'b1;

    expect_accept_open("reset_release");

    write_entry(VICTIM_INDEX, 16'h1111, 16'h0010, 4'd2, 2'd1, 2'd0, 4'd1, 4'd2);
    write_entry(SURVIVOR_INDEX, 16'h2222, 16'h0020, 4'd1, 2'd0, 2'd1, 4'd3, 4'd4);

    #1;
    if (entry_count != 2) begin
        $fatal(1, "token_register should contain two entries before flush");
    end
    if (error_flag) begin
        $fatal(1, "token_register error_flag should stay low");
    end

    lookup_expect("victim_before_flush", 16'h1111, 16'h0010, 1'b1,
                  branch_onehot_mask(2'd1));
    lookup_expect("survivor_before_flush", 16'h2222, 16'h0020, 1'b1,
                  branch_onehot_mask(2'd0));

    trigger_flush_and_check_bridge();

    lookup_expect("victim_after_flush", 16'h1111, 16'h0010, 1'b0,
                  {`BRANCH_MASK_W{1'b0}});
    lookup_expect("survivor_after_flush", 16'h2222, 16'h0020, 1'b1,
                  branch_onehot_mask(2'd0));

    $display("tb_comparator_token_register_flush PASS");
    $finish;
end

endmodule
