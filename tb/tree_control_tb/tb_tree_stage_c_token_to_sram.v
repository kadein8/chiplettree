`timescale 1ns/1ps

`include "config/prediction_params.vh"
`include "config/interface_params.vh"
`include "config/memory_params.vh"

module tb_tree_stage_c_token_to_sram;

localparam [`REQ_ID_W-1:0] TEST_REQ_ID = 4'h9;
localparam [`NODE_ID_W-1:0] NODE_A = 4'h1;
localparam [`NODE_ID_W-1:0] NODE_C1 = 4'h3;
localparam integer SRAM_LANE = 0;

reg clk;
reg rst_n;

reg req_valid;
wire req_ready;
reg [`REQ_ID_W-1:0] req_id;
reg [`TREE_MAX_PREFIX_NODES-1:0] src_prefix_slot_valid;
reg [`TREE_MAX_PREFIX_NODES*`NODE_ID_W-1:0] src_prefix_node_id;
reg [`TREE_MAX_FRONTIER_LEVELS-1:0] src_frontier_level_valid;
reg [`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS-1:0] src_frontier_slot_valid;
reg [`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0] src_frontier_node_id;
reg [`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0] src_frontier_parent_node_id;

wire prefix_valid;
wire prefix_ready;
wire [`REQ_ID_W-1:0] prefix_req_id;
wire prefix_node_valid;
wire [`NODE_ID_W-1:0] prefix_node_id;
wire [`NODE_ID_W-1:0] prefix_parent_node_id;
wire [`TOKEN_ID_W-1:0] prefix_token_id;
wire [`POSITION_ID_W-1:0] prefix_position_id;
wire [`LAYER_ID_W-1:0] prefix_layer_id;
wire prefix_is_last;

wire frontier_valid;
wire frontier_ready;
wire [`REQ_ID_W-1:0] frontier_req_id;
wire [`TREE_LEVEL_ID_W-1:0] frontier_level_id;
wire [`TREE_FRONTIER_SLOTS-1:0] frontier_slot_valid;
wire [`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0] frontier_node_id;
wire [`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0] frontier_parent_node_id;
wire [`TREE_FRONTIER_SLOTS*`TOKEN_ID_W-1:0] frontier_token_id;
wire [`TREE_FRONTIER_SLOTS*`POSITION_ID_W-1:0] frontier_position_id;

wire prefetch_enq_ready;
wire prefetch_enq_valid;
wire [`REQ_ID_W-1:0] prefetch_enq_req_id;
wire [`BRANCH_ID_W-1:0] prefetch_enq_branch_id;
wire [`NODE_ID_W-1:0] prefetch_enq_node_id;
wire [`LAYER_ID_W-1:0] prefetch_enq_layer_id;
wire [`KV_GROUP_LEN_W-1:0] prefetch_enq_size_subbank;
wire prefetch_enq_shared;

wire prefetch_deq_valid;
wire prefetch_deq_ready;
wire [`REQ_ID_W-1:0] prefetch_deq_req_id;
wire [`BRANCH_ID_W-1:0] prefetch_deq_branch_id;
wire [`NODE_ID_W-1:0] prefetch_deq_node_id;
wire [`LAYER_ID_W-1:0] prefetch_deq_layer_id;
wire [`KV_GROUP_LEN_W-1:0] prefetch_deq_size_subbank;
wire prefetch_deq_shared;

wire cand_resp_valid;
wire cand_resp_grant;
wire [`REQ_ID_W-1:0] cand_resp_req_id;
wire [`SRAM_ID_W-1:0] cand_resp_sram_id;
wire [`BANK_ID_W-1:0] cand_resp_bank_id;
wire [`SUBBANK_ID_W-1:0] cand_resp_subbank_start;
wire [`KV_GROUP_LEN_W-1:0] cand_resp_group_len;

reg alloc_resp_valid;
reg alloc_resp_grant;
reg [`REQ_ID_W-1:0] alloc_resp_req_id;
reg [`SRAM_ID_W-1:0] alloc_resp_sram_id;
reg [`BANK_ID_W-1:0] alloc_resp_bank_id;
reg [`SUBBANK_ID_W-1:0] alloc_resp_subbank_start;
reg [`KV_GROUP_LEN_W-1:0] alloc_resp_group_len;
reg flush_freeze;

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

reg [`TOKEN_REG_INDEX_W-1:0] token_wr_index_r;

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

reg [`MEM_REQ_LANES-1:0] mem_req_valid;
wire [`MEM_REQ_LANES-1:0] mem_req_ready;
reg [`MEM_REQ_LANES-1:0] mem_req_write;
reg [`MEM_REQ_LANES*`SRAM_ADDR_W-1:0] mem_req_addr;
reg [`MEM_REQ_LANES*`SRAM_WDATA_W-1:0] mem_req_wdata;
reg [`MEM_REQ_LANES*`REQ_ID_W-1:0] mem_req_id;
wire [`MEM_REQ_LANES-1:0] mem_resp_valid;
wire [`MEM_REQ_LANES*`SRAM_RDATA_W-1:0] mem_resp_rdata;
wire [`MEM_REQ_LANES*`REQ_ID_W-1:0] mem_resp_id;
wire [`MEM_REQ_LANES-1:0] mem_resp_last;

tree_analyze u_tree_analyze (
    .clk(clk),
    .rst_n(rst_n),
    .req_valid(req_valid),
    .req_ready(req_ready),
    .req_id(req_id),
    .src_prefix_slot_valid(src_prefix_slot_valid),
    .src_prefix_node_id(src_prefix_node_id),
    .src_frontier_level_valid(src_frontier_level_valid),
    .src_frontier_slot_valid(src_frontier_slot_valid),
    .src_frontier_node_id(src_frontier_node_id),
    .src_frontier_parent_node_id(src_frontier_parent_node_id),
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
    .frontier_position_id(frontier_position_id)
);

agu u_agu (
    .clk(clk),
    .rst_n(rst_n),
    .tree_in_valid(1'b0),
    .tree_in_ready(),
    .tree_in_req_id({`REQ_ID_W{1'b0}}),
    .tree_in_branch_id({`BRANCH_ID_W{1'b0}}),
    .tree_in_node_id({`NODE_ID_W{1'b0}}),
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
    .flush_freeze(1'b0),
    .flush_drain_busy(1'b0),
    .flush_ctrl_valid(1'b0),
    .flush_ctrl_req_id({`REQ_ID_W{1'b0}}),
    .flush_ctrl_branch_mask({`BRANCH_MASK_W{1'b0}}),
    .flush_ctrl_node_mask({`NODE_MASK_W{1'b0}}),
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
    .prefetch_flush_valid(),
    .prefetch_flush_req_id(),
    .prefetch_flush_branch_mask(),
    .prefetch_flush_node_mask()
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
    .flush_valid(1'b0),
    .flush_req_id({`REQ_ID_W{1'b0}}),
    .flush_branch_mask({`BRANCH_MASK_W{1'b0}}),
    .flush_node_mask({`NODE_MASK_W{1'b0}}),
    .deq_valid(prefetch_deq_valid),
    .deq_ready(prefetch_deq_ready),
    .deq_req_id(prefetch_deq_req_id),
    .deq_branch_id(prefetch_deq_branch_id),
    .deq_node_id(prefetch_deq_node_id),
    .deq_layer_id(prefetch_deq_layer_id),
    .deq_size_subbank(prefetch_deq_size_subbank),
    .deq_shared(prefetch_deq_shared)
);

free_list u_free_list (
    .clk(clk),
    .rst_n(rst_n),
    .cand_req_valid(prefetch_deq_valid),
    .cand_req_ready(prefetch_deq_ready),
    .cand_req_req_id(prefetch_deq_req_id),
    .cand_req_branch_id(prefetch_deq_branch_id),
    .cand_req_node_id(prefetch_deq_node_id),
    .cand_req_size_subbank(prefetch_deq_size_subbank),
    .cand_req_shared(prefetch_deq_shared),
    .cand_resp_valid(cand_resp_valid),
    .cand_resp_grant(cand_resp_grant),
    .cand_resp_req_id(cand_resp_req_id),
    .cand_resp_sram_id(cand_resp_sram_id),
    .cand_resp_bank_id(cand_resp_bank_id),
    .cand_resp_subbank_start(cand_resp_subbank_start),
    .cand_resp_group_len(cand_resp_group_len),
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
    .flush_valid(1'b0),
    .flush_req_id({`REQ_ID_W{1'b0}}),
    .flush_branch_mask({`BRANCH_MASK_W{1'b0}}),
    .flush_node_mask({`NODE_MASK_W{1'b0}}),
    .release_valid(1'b0),
    .release_sram_id({`SRAM_ID_W{1'b0}}),
    .release_bank_id({`BANK_ID_W{1'b0}}),
    .release_subbank_start({`SUBBANK_ID_W{1'b0}}),
    .release_group_len({`KV_GROUP_LEN_W{1'b0}})
);

token_register u_token_register (
    .clk(clk),
    .rst_n(rst_n),
    .wr_valid(token_wr_valid),
    .wr_ready(),
    .wr_index(token_wr_index_r),
    .wr_req_id(token_wr_req_id),
    .wr_token_id(token_wr_token_id),
    .wr_position_id(token_wr_position_id),
    .wr_node_id(token_wr_node_id),
    .wr_branch_id(token_wr_branch_id),
    .wr_sram_id(token_wr_sram_id),
    .wr_bank_id(token_wr_bank_id),
    .wr_subbank_start(token_wr_subbank_start),
    .wr_group_len(token_wr_group_len),
    .wr_branch_mask(token_wr_branch_mask),
    .wr_is_shared(token_wr_is_shared),
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
    .flush_valid(1'b0),
    .flush_req_id({`REQ_ID_W{1'b0}}),
    .flush_branch_mask({`BRANCH_MASK_W{1'b0}}),
    .flush_node_mask({`NODE_MASK_W{1'b0}}),
    .entry_count(),
    .error_flag()
);

sram_subsystem u_sram_subsystem (
    .clk(clk),
    .rst_n(rst_n),
    .mem_req_valid(mem_req_valid),
    .mem_req_ready(mem_req_ready),
    .mem_req_write(mem_req_write),
    .mem_req_addr(mem_req_addr),
    .mem_req_wdata(mem_req_wdata),
    .mem_req_id(mem_req_id),
    .mem_resp_valid(mem_resp_valid),
    .mem_resp_rdata(mem_resp_rdata),
    .mem_resp_id(mem_resp_id),
    .mem_resp_last(mem_resp_last)
);

always #5 clk = ~clk;

function [`SRAM_ADDR_W-1:0] pack_addr;
    input [`SRAM_ID_W-1:0] sram_i;
    input [`BANK_ID_W-1:0] bank_i;
    input [`SUBBANK_ID_W-1:0] subbank_i;
    input [`ROW_ADDR_W-1:0] row_i;
    input [`OFFSET_W-1:0] offset_i;
    begin
        pack_addr = {sram_i, bank_i, subbank_i, row_i, offset_i};
    end
endfunction

task clear_tree_request;
    begin
        req_valid = 1'b0;
        req_id = {`REQ_ID_W{1'b0}};
        src_prefix_slot_valid = {`TREE_MAX_PREFIX_NODES{1'b0}};
        src_prefix_node_id = {(`TREE_MAX_PREFIX_NODES*`NODE_ID_W){1'b0}};
        src_frontier_level_valid = {`TREE_MAX_FRONTIER_LEVELS{1'b0}};
        src_frontier_slot_valid =
            {(`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS){1'b0}};
        src_frontier_node_id =
            {(`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`NODE_ID_W){1'b0}};
        src_frontier_parent_node_id =
            {(`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`NODE_ID_W){1'b0}};
    end
endtask

task load_simple_tree;
    begin
        clear_tree_request();
        req_valid = 1'b1;
        req_id = TEST_REQ_ID;
        src_prefix_slot_valid[0] = 1'b1;
        src_prefix_node_id[(0*`NODE_ID_W) +: `NODE_ID_W] = NODE_A;
        src_frontier_level_valid[0] = 1'b1;
        src_frontier_slot_valid[0] = 1'b1;
        src_frontier_node_id[(0*`NODE_ID_W) +: `NODE_ID_W] = NODE_C1;
        src_frontier_parent_node_id[(0*`NODE_ID_W) +: `NODE_ID_W] = NODE_A;
    end
endtask

task clear_mem_req;
    begin
        mem_req_valid = {`MEM_REQ_LANES{1'b0}};
        mem_req_write = {`MEM_REQ_LANES{1'b0}};
        mem_req_addr = {(`MEM_REQ_LANES*`SRAM_ADDR_W){1'b0}};
        mem_req_wdata = {(`MEM_REQ_LANES*`SRAM_WDATA_W){1'b0}};
        mem_req_id = {(`MEM_REQ_LANES*`REQ_ID_W){1'b0}};
    end
endtask

task wait_for_token_write;
    input [`NODE_ID_W-1:0] expected_node_id;
    integer wait_i;
    reg seen;
    begin
        seen = 1'b0;
        for (wait_i = 0; wait_i < 10; wait_i = wait_i + 1) begin
            @(posedge clk);
            #1;
            if (token_wr_valid) begin
                seen = 1'b1;
                if (token_wr_req_id != TEST_REQ_ID ||
                    token_wr_node_id != expected_node_id) begin
                    $fatal(1, "unexpected tree-driven token write");
                end
                disable wait_for_token_write;
            end
        end
        if (!seen) begin
            $fatal(1, "tree-driven token write did not occur");
        end
    end
endtask

task complete_current_alloc;
    begin
        alloc_resp_valid = 1'b1;
        alloc_resp_grant = 1'b1;
        alloc_resp_req_id = TEST_REQ_ID;
        alloc_resp_sram_id = token_wr_sram_id;
        alloc_resp_bank_id = token_wr_bank_id;
        alloc_resp_subbank_start = token_wr_subbank_start;
        alloc_resp_group_len = token_wr_group_len;
        @(posedge clk);
        #1;
        alloc_resp_valid = 1'b0;
    end
endtask

task wait_for_lookup_hit;
    integer wait_i;
    reg seen;
    begin
        seen = 1'b0;
        for (wait_i = 0; wait_i < 4; wait_i = wait_i + 1) begin
            @(posedge clk);
            #1;
            if (lookup_resp_valid) begin
                seen = 1'b1;
                if (!lookup_resp_hit ||
                    lookup_resp_req_id != TEST_REQ_ID) begin
                    $fatal(
                        1,
                        "tree-driven token lookup response mismatch; hit=%0b req_id=0x%0h",
                        lookup_resp_hit,
                        lookup_resp_req_id
                    );
                end
                disable wait_for_lookup_hit;
            end
        end
        if (!seen) begin
            $fatal(
                1,
                "tree-driven token lookup did not return; entry0_valid=%0b entry0_token=0x%0h entry1_valid=%0b entry1_token=0x%0h",
                u_token_register.valid_entry[0],
                u_token_register.entry_token_id[0],
                u_token_register.valid_entry[1],
                u_token_register.entry_token_id[1]
            );
        end
    end
endtask

initial begin
    reg [`SRAM_ADDR_W-1:0] lookup_addr;

    clk = 1'b0;
    rst_n = 1'b0;
    clear_tree_request();
    alloc_resp_valid = 1'b0;
    alloc_resp_grant = 1'b0;
    alloc_resp_req_id = {`REQ_ID_W{1'b0}};
    alloc_resp_sram_id = {`SRAM_ID_W{1'b0}};
    alloc_resp_bank_id = {`BANK_ID_W{1'b0}};
    alloc_resp_subbank_start = {`SUBBANK_ID_W{1'b0}};
    alloc_resp_group_len = {`KV_GROUP_LEN_W{1'b0}};
    flush_freeze = 1'b0;
    token_wr_index_r = {`TOKEN_REG_INDEX_W{1'b0}};
    lookup_valid = 1'b0;
    lookup_req_id = {`REQ_ID_W{1'b0}};
    lookup_token_id = {`TOKEN_ID_W{1'b0}};
    lookup_position_id = {`POSITION_ID_W{1'b0}};
    clear_mem_req();

    repeat (3) @(posedge clk);
    rst_n = 1'b1;

    load_simple_tree();
    @(posedge clk);
    #1;
    req_valid = 1'b0;

    wait_for_token_write(NODE_A);
    complete_current_alloc();

    wait_for_token_write(NODE_C1);
    complete_current_alloc();

    @(posedge clk);
    #1;
    lookup_valid = 1'b1;
    lookup_req_id = TEST_REQ_ID;
    lookup_token_id = {{(`TOKEN_ID_W-`NODE_ID_W){1'b0}}, NODE_C1};
    lookup_position_id = {{(`POSITION_ID_W-`NODE_ID_W){1'b0}}, NODE_C1};

    wait_for_lookup_hit();

    #1;
    lookup_valid = 1'b0;

    lookup_addr = pack_addr(
        lookup_resp_sram_id,
        lookup_resp_bank_id,
        lookup_resp_subbank_start,
        8'h03,
        4'h2
    );

    clear_mem_req();
    mem_req_valid[SRAM_LANE] = 1'b1;
    mem_req_write[SRAM_LANE] = 1'b1;
    mem_req_addr[(SRAM_LANE*`SRAM_ADDR_W) +: `SRAM_ADDR_W] = lookup_addr;
    mem_req_wdata[(SRAM_LANE*`SRAM_WDATA_W) +: `SRAM_WDATA_W] =
        128'h01234567_89abcdef_fedcba98_76543210;
    mem_req_id[(SRAM_LANE*`REQ_ID_W) +: `REQ_ID_W] = 4'ha;

    #1;
    if (!mem_req_ready[SRAM_LANE]) begin
        $fatal(1, "tree-driven lookup address should be writable through Stage C");
    end

    @(posedge clk);
    #1;
    clear_mem_req();

    @(posedge clk);
    #1;
    clear_mem_req();
    mem_req_valid[SRAM_LANE] = 1'b1;
    mem_req_write[SRAM_LANE] = 1'b0;
    mem_req_addr[(SRAM_LANE*`SRAM_ADDR_W) +: `SRAM_ADDR_W] = lookup_addr;
    mem_req_id[(SRAM_LANE*`REQ_ID_W) +: `REQ_ID_W] = 4'hb;

    #1;
    if (!mem_req_ready[SRAM_LANE]) begin
        $fatal(1, "tree-driven lookup address should be readable through Stage C");
    end

    @(posedge clk);
    #1;
    clear_mem_req();

    @(posedge clk);
    #1;
    if (!mem_resp_valid[SRAM_LANE]) begin
        $fatal(1, "tree-driven Stage C readback did not return");
    end

    if (mem_resp_id[(SRAM_LANE*`REQ_ID_W) +: `REQ_ID_W] != 4'hb ||
        !mem_resp_last[SRAM_LANE] ||
        mem_resp_rdata[(SRAM_LANE*`SRAM_RDATA_W) +: `SRAM_RDATA_W] !=
            128'h01234567_89abcdef_fedcba98_76543210) begin
        $fatal(1, "tree-driven Stage C readback mismatch");
    end

    $display("tb_tree_stage_c_token_to_sram PASS");
    $finish;
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        token_wr_index_r <= {`TOKEN_REG_INDEX_W{1'b0}};
    end else if (token_wr_valid) begin
        token_wr_index_r <= token_wr_index_r + 1'b1;
    end
end

endmodule
