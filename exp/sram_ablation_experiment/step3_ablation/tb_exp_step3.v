`timescale 1ns/1ps

`include "config/prediction_params.vh"
`include "config/interface_params.vh"
`include "config/memory_params.vh"

module tb_exp_step3;

`ifdef EXP_ENABLE_TOPOLOGY
localparam integer CFG_ENABLE_TOPOLOGY = 1;
`else
localparam integer CFG_ENABLE_TOPOLOGY = 0;
`endif

`ifdef EXP_ENABLE_FREEZE
localparam integer CFG_ENABLE_FREEZE = 1;
`else
localparam integer CFG_ENABLE_FREEZE = 0;
`endif

`ifdef EXP_ENABLE_PROMOTION
localparam integer CFG_ENABLE_PROMOTION = 1;
`else
localparam integer CFG_ENABLE_PROMOTION = 0;
`endif

`ifdef EXP_ENABLE_ISOLATION
localparam integer CFG_ENABLE_ISOLATION = 1;
`else
localparam integer CFG_ENABLE_ISOLATION = 0;
`endif

localparam integer SHARED_BANKS_PER_SRAM =
    (`SRAM_BANK_NUM >= 4) ? (`SRAM_BANK_NUM / 4) : 1;
localparam integer PRIVATE_BANKS_PER_SRAM =
    (`SRAM_BANK_NUM > SHARED_BANKS_PER_SRAM) ?
        (`SRAM_BANK_NUM - SHARED_BANKS_PER_SRAM) : 1;
localparam integer PRIVATE_BANKS_PER_BRANCH =
    (PRIVATE_BANKS_PER_SRAM >= `BRANCH_NUM) ?
        (PRIVATE_BANKS_PER_SRAM / `BRANCH_NUM) : 1;
localparam [`BANK_ID_W-1:0] BRANCH0_FIRST_BANK_ID =
    SHARED_BANKS_PER_SRAM;
localparam [`BANK_ID_W-1:0] BRANCH1_FIRST_BANK_ID =
    SHARED_BANKS_PER_SRAM + PRIVATE_BANKS_PER_BRANCH;
localparam [`SUBBANK_ID_W-1:0] KV_GROUP_SIZE_SUBBANK_ID =
    `KV_GROUP_SIZE_SUBBANK;
localparam [`BRANCH_MASK_W-1:0] BRANCH0_MASK =
    {{(`BRANCH_MASK_W-1){1'b0}}, 1'b1};
localparam [`BRANCH_MASK_W-1:0] BRANCH1_MASK =
    ({{(`BRANCH_MASK_W-1){1'b0}}, 1'b1} << 1);
localparam [`BANK_STATE_W-1:0] BANK_STATE_SPEC =
    {{(`BANK_STATE_W-1){1'b0}}, 1'b1};
localparam [`BANK_STATE_W-1:0] BANK_STATE_COMMITTED =
    {{(`BANK_STATE_W-2){1'b0}}, 2'b10};

localparam [`SRAM_RDATA_W-1:0] DATA_A =
    128'h71000000_11111111_22222222_33333333;
localparam [`SRAM_RDATA_W-1:0] DATA_B =
    128'h72000000_44444444_55555555_66666666;
localparam [`SRAM_RDATA_W-1:0] DATA_C =
    128'h73000000_77777777_88888888_99999999;
localparam [`SRAM_RDATA_W-1:0] UPDATED_A =
    128'h74000000_aaaaaaaa_bbbbbbbb_cccccccc;
localparam [`SRAM_RDATA_W-1:0] UPDATED_B =
    128'h75000000_dddddddd_eeeeeeee_ffffffff;

localparam [`REQ_ID_W-1:0] PRELOAD_A_REQ_ID = 4'h1;
localparam [`REQ_ID_W-1:0] PRELOAD_B_REQ_ID = 4'h2;
localparam [`REQ_ID_W-1:0] PRELOAD_C_REQ_ID = 4'h3;
localparam [`REQ_ID_W-1:0] MDV_A0_REQ_ID = 4'h4;
localparam [`REQ_ID_W-1:0] MDV_B0_REQ_ID = 4'h5;
localparam [`REQ_ID_W-1:0] MDV_A1_REQ_ID = 4'h6;
localparam [`REQ_ID_W-1:0] MDV_B1_REQ_ID = 4'h7;
localparam [`REQ_ID_W-1:0] WAR_A0_REQ_ID = 4'h8;
localparam [`REQ_ID_W-1:0] WAR_A1_REQ_ID = 4'h9;
localparam [`REQ_ID_W-1:0] WAR_WRITE_REQ_ID = 4'ha;
localparam [`REQ_ID_W-1:0] RAW_C_REQ_ID = 4'hb;
localparam [`REQ_ID_W-1:0] RAW_WRITE_REQ_ID = 4'hc;
localparam [`REQ_ID_W-1:0] RAW_B_REQ_ID = 4'hd;

localparam [`PE_MASK_W-1:0] MDV_A0_PE_MASK = 16'h0001;
localparam [`PE_MASK_W-1:0] MDV_B0_PE_MASK = 16'h0002;
localparam [`PE_MASK_W-1:0] MDV_A1_PE_MASK = 16'h0004;
localparam [`PE_MASK_W-1:0] MDV_B1_PE_MASK = 16'h0008;
localparam [`PE_MASK_W-1:0] WAR_A0_PE_MASK = 16'h0010;
localparam [`PE_MASK_W-1:0] WAR_A1_PE_MASK = 16'h0020;
localparam [`PE_MASK_W-1:0] RAW_C_PE_MASK = 16'h0040;
localparam [`PE_MASK_W-1:0] RAW_B_PE_MASK = 16'h0080;

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

reg req_in_valid;
wire req_in_ready;
reg req_in_write;
reg [`SRAM_ADDR_W-1:0] req_in_addr;
reg [`SRAM_WDATA_W-1:0] req_in_wdata;
reg [`REQ_ID_W-1:0] req_in_req_id;
reg [`PE_MASK_W-1:0] req_in_pe_mask;
reg [`REQ_PRIORITY_W-1:0] req_in_priority;
reg [`BANK_ID_W-1:0] req_in_bank_id;
reg [`SUBBANK_ID_W-1:0] req_in_subbank_id;

wire [`MEM_REQ_LANES-1:0] mem_req_valid;
wire [`MEM_REQ_LANES-1:0] mem_req_ready;
wire [`MEM_REQ_LANES-1:0] mem_req_write;
wire [`MEM_REQ_LANES*`SRAM_ADDR_W-1:0] mem_req_addr;
wire [`MEM_REQ_LANES*`SRAM_WDATA_W-1:0] mem_req_wdata;
wire [`MEM_REQ_LANES*`REQ_ID_W-1:0] mem_req_id;
wire [`MEM_REQ_LANES-1:0] mem_resp_valid;
wire [`MEM_REQ_LANES*`SRAM_RDATA_W-1:0] mem_resp_rdata;
wire [`MEM_REQ_LANES*`REQ_ID_W-1:0] mem_resp_id;
wire [`MEM_REQ_LANES-1:0] mem_resp_last;

wire [`MEM_REQ_LANES-1:0] resp_out_valid;
reg [`MEM_REQ_LANES-1:0] resp_out_ready;
wire [`MEM_REQ_LANES*`SRAM_RDATA_W-1:0] resp_out_rdata;
wire [`MEM_REQ_LANES*`REQ_ID_W-1:0] resp_out_req_id;
wire [`MEM_REQ_LANES*`PE_MASK_W-1:0] resp_out_pe_mask;
wire [`MEM_REQ_LANES-1:0] resp_out_last;

reg [`SRAM_ADDR_W-1:0] addr_a_r;
reg [`SRAM_ADDR_W-1:0] addr_b_r;
reg [`SRAM_ADDR_W-1:0] addr_c_r;

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
reg [`SRAM_ID_W-1:0] shared_reuse_sram_r;
reg [`BANK_ID_W-1:0] shared_reuse_bank_r;
reg [`SUBBANK_ID_W-1:0] shared_reuse_subbank_r;
reg [`KV_GROUP_LEN_W-1:0] shared_reuse_len_r;
reg [`SRAM_ID_W-1:0] isolated_sram_r;
reg [`BANK_ID_W-1:0] isolated_bank_r;
reg [`SUBBANK_ID_W-1:0] isolated_subbank_r;
reg [`KV_GROUP_LEN_W-1:0] isolated_len_r;

integer global_cycle_count_r;
integer mem_read_issue_total_count;
integer mem_write_issue_total_count;
integer mem_read_issue_addr_a_count;
integer mem_read_issue_addr_b_count;
integer mem_read_issue_addr_c_count;
integer mem_write_issue_addr_a_count;
integer mem_write_issue_addr_b_count;
integer private_region_hits_r;
integer shared_reuse_hits_r;
integer promotion_hits_r;
integer isolation_guard_hits_r;
integer mdv_response_lanes_count_r;
integer occupied_subbanks_r;
integer mon_i;
integer wait_i;
integer occ_i;

reg [`BANK_OCC_BITMAP_W-1:0] sampled_query_bitmap_r;
reg [`BANK_STATE_W-1:0] sampled_query_state_r;
reg [`BRANCH_MASK_W-1:0] sampled_query_branch_mask_r;
reg [`REFCNT_W-1:0] sampled_query_refcnt_r;

free_list #(
    .ENABLE_TOPOLOGY_AWARE_MAPPING(CFG_ENABLE_TOPOLOGY),
    .ENABLE_SHARED_PREFIX_FREEZE(CFG_ENABLE_FREEZE),
    .ENABLE_BRANCH_ISOLATION(CFG_ENABLE_ISOLATION)
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
    .ENABLE_SHARED_PREFIX_FREEZE(CFG_ENABLE_FREEZE),
    .ENABLE_PREFIX_PROMOTION(CFG_ENABLE_PROMOTION),
    .ENABLE_BRANCH_ISOLATION(CFG_ENABLE_ISOLATION)
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

request_controller u_request_controller (
    .clk(clk),
    .rst_n(rst_n),
    .req_in_valid(req_in_valid),
    .req_in_ready(req_in_ready),
    .req_in_write(req_in_write),
    .req_in_addr(req_in_addr),
    .req_in_wdata(req_in_wdata),
    .req_in_req_id(req_in_req_id),
    .req_in_pe_mask(req_in_pe_mask),
    .req_in_priority(req_in_priority),
    .req_in_bank_id(req_in_bank_id),
    .req_in_subbank_id(req_in_subbank_id),
    .mem_req_valid(mem_req_valid),
    .mem_req_ready(mem_req_ready),
    .mem_req_write(mem_req_write),
    .mem_req_addr(mem_req_addr),
    .mem_req_wdata(mem_req_wdata),
    .mem_req_id(mem_req_id),
    .mem_resp_valid(mem_resp_valid),
    .mem_resp_rdata(mem_resp_rdata),
    .mem_resp_id(mem_resp_id),
    .mem_resp_last(mem_resp_last),
    .resp_out_valid(resp_out_valid),
    .resp_out_ready(resp_out_ready),
    .resp_out_rdata(resp_out_rdata),
    .resp_out_req_id(resp_out_req_id),
    .resp_out_pe_mask(resp_out_pe_mask),
    .resp_out_last(resp_out_last)
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

always #5 clk = ~clk;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        global_cycle_count_r <= 0;
        mem_read_issue_total_count <= 0;
        mem_write_issue_total_count <= 0;
        mem_read_issue_addr_a_count <= 0;
        mem_read_issue_addr_b_count <= 0;
        mem_read_issue_addr_c_count <= 0;
        mem_write_issue_addr_a_count <= 0;
        mem_write_issue_addr_b_count <= 0;
    end else begin
        global_cycle_count_r <= global_cycle_count_r + 1;
        for (mon_i = 0; mon_i < `MEM_REQ_LANES; mon_i = mon_i + 1) begin
            if (mem_req_valid[mon_i] && mem_req_ready[mon_i]) begin
                if (mem_req_write[mon_i]) begin
                    mem_write_issue_total_count <= mem_write_issue_total_count + 1;
                    if (mem_req_addr[(mon_i*`SRAM_ADDR_W) +: `SRAM_ADDR_W] == addr_a_r) begin
                        mem_write_issue_addr_a_count <= mem_write_issue_addr_a_count + 1;
                    end
                    if (mem_req_addr[(mon_i*`SRAM_ADDR_W) +: `SRAM_ADDR_W] == addr_b_r) begin
                        mem_write_issue_addr_b_count <= mem_write_issue_addr_b_count + 1;
                    end
                end else begin
                    mem_read_issue_total_count <= mem_read_issue_total_count + 1;
                    if (mem_req_addr[(mon_i*`SRAM_ADDR_W) +: `SRAM_ADDR_W] == addr_a_r) begin
                        mem_read_issue_addr_a_count <= mem_read_issue_addr_a_count + 1;
                    end
                    if (mem_req_addr[(mon_i*`SRAM_ADDR_W) +: `SRAM_ADDR_W] == addr_b_r) begin
                        mem_read_issue_addr_b_count <= mem_read_issue_addr_b_count + 1;
                    end
                    if (mem_req_addr[(mon_i*`SRAM_ADDR_W) +: `SRAM_ADDR_W] == addr_c_r) begin
                        mem_read_issue_addr_c_count <= mem_read_issue_addr_c_count + 1;
                    end
                end
            end
        end
    end
end

task issue_candidate_expect_grant;
    input [255:0] scenario_name;
    input [`REQ_ID_W-1:0] req_id;
    input [`BRANCH_ID_W-1:0] branch_id;
    input [`NODE_ID_W-1:0] node_id;
    input is_shared;
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
            $fatal(1, "%0s: free_list did not grant candidate", scenario_name);
        end

        got_sram_id = cand_resp_sram_id;
        got_bank_id = cand_resp_bank_id;
        got_subbank_start = cand_resp_subbank_start;
        got_group_len = cand_resp_group_len;

        @(posedge clk);
        if (!alloc_resp_valid || !alloc_resp_grant) begin
            $fatal(1, "%0s: bank_state_table did not grant candidate", scenario_name);
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
    input [`SRAM_ID_W-1:0] sram_id;
    input [`BANK_ID_W-1:0] bank_id;
    begin
        @(posedge clk);
        query_valid <= 1'b1;
        query_sram_id <= sram_id;
        query_bank_id <= bank_id;
        #1;
        if (!query_resp_valid) begin
            $fatal(1, "query response missing");
        end
        sampled_query_bitmap_r <= query_resp_occ_bitmap;
        sampled_query_state_r <= query_resp_state;
        sampled_query_branch_mask_r <= query_resp_branch_mask;
        sampled_query_refcnt_r <= query_resp_refcnt;
        @(posedge clk);
        query_valid <= 1'b0;
    end
endtask

task clear_req;
    begin
        req_in_valid = 1'b0;
        req_in_write = 1'b0;
        req_in_addr = {`SRAM_ADDR_W{1'b0}};
        req_in_wdata = {`SRAM_WDATA_W{1'b0}};
        req_in_req_id = {`REQ_ID_W{1'b0}};
        req_in_pe_mask = {`PE_MASK_W{1'b0}};
        req_in_priority = {`REQ_PRIORITY_W{1'b0}};
        req_in_bank_id = {`BANK_ID_W{1'b0}};
        req_in_subbank_id = {`SUBBANK_ID_W{1'b0}};
    end
endtask

task drive_accepted_request;
    input do_write;
    input [`SRAM_ADDR_W-1:0] addr_i;
    input [`SRAM_WDATA_W-1:0] wdata_i;
    input [`REQ_ID_W-1:0] req_id_i;
    input [`PE_MASK_W-1:0] pe_mask_i;
    input [`REQ_PRIORITY_W-1:0] priority_i;
    begin
        @(posedge clk);
        #1;
        req_in_valid = 1'b1;
        req_in_write = do_write;
        req_in_addr = addr_i;
        req_in_wdata = wdata_i;
        req_in_req_id = req_id_i;
        req_in_pe_mask = pe_mask_i;
        req_in_priority = priority_i;
        req_in_bank_id =
            addr_i[`OFFSET_W + `ROW_ADDR_W + `SUBBANK_ID_W +: `BANK_ID_W];
        req_in_subbank_id =
            addr_i[`OFFSET_W + `ROW_ADDR_W +: `SUBBANK_ID_W];
        #1;
        if (!req_in_ready) begin
            $fatal(1, "request_controller did not accept request");
        end
        @(posedge clk);
        #1;
        clear_req();
    end
endtask

task release_response_mask;
    input [`MEM_REQ_LANES-1:0] ready_mask;
    begin
        resp_out_ready = ready_mask;
        @(posedge clk);
        #1;
        resp_out_ready = {`MEM_REQ_LANES{1'b0}};
    end
endtask

task wait_resp_mask;
    input [`MEM_REQ_LANES-1:0] expect_mask;
    begin
        for (wait_i = 0; wait_i < 20; wait_i = wait_i + 1) begin
            @(posedge clk);
            #1;
            if (resp_out_valid == expect_mask) begin
                release_response_mask(expect_mask);
                disable wait_resp_mask;
            end
        end
        $fatal(1, "expected response mask did not arrive");
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

    clear_req();
    resp_out_ready = {`MEM_REQ_LANES{1'b0}};

    private_region_hits_r = 0;
    shared_reuse_hits_r = 0;
    promotion_hits_r = 0;
    isolation_guard_hits_r = 0;
    mdv_response_lanes_count_r = 0;
    occupied_subbanks_r = 0;

    addr_a_r = pack_addr(2'h0, 4'h0, 5'h03, 8'h31, 4'h0);
    addr_b_r = pack_addr(2'h0, 4'h1, 5'h04, 8'h32, 4'h0);
    addr_c_r = pack_addr(2'h0, 4'h2, 5'h05, 8'h33, 4'h0);

    repeat (3) @(posedge clk);
    rst_n = 1'b1;

    issue_candidate_expect_grant(
        "branch0_private_first",
        4'he,
        2'd0,
        4'd0,
        1'b0,
        branch0_first_sram_r,
        branch0_first_bank_r,
        branch0_first_subbank_r,
        branch0_first_len_r
    );
    if (CFG_ENABLE_TOPOLOGY || CFG_ENABLE_ISOLATION) begin
        if (branch0_first_bank_r != BRANCH0_FIRST_BANK_ID) begin
            $fatal(1, "branch0 private bank mapping mismatch");
        end
        private_region_hits_r = private_region_hits_r + 1;
    end

    issue_candidate_expect_grant(
        "branch0_private_second",
        4'he,
        2'd0,
        4'd1,
        1'b0,
        branch0_second_sram_r,
        branch0_second_bank_r,
        branch0_second_subbank_r,
        branch0_second_len_r
    );
    if (CFG_ENABLE_TOPOLOGY || CFG_ENABLE_ISOLATION) begin
        if ((branch0_second_bank_r != branch0_first_bank_r) ||
            (branch0_second_subbank_r != KV_GROUP_SIZE_SUBBANK_ID)) begin
            $fatal(1, "branch0 contiguous private placement mismatch");
        end
        private_region_hits_r = private_region_hits_r + 1;
    end

    issue_candidate_expect_grant(
        "branch1_private_first",
        4'he,
        2'd1,
        4'd0,
        1'b0,
        branch1_first_sram_r,
        branch1_first_bank_r,
        branch1_first_subbank_r,
        branch1_first_len_r
    );
    if (CFG_ENABLE_TOPOLOGY || CFG_ENABLE_ISOLATION) begin
        if (branch1_first_bank_r != BRANCH1_FIRST_BANK_ID) begin
            $fatal(1, "branch1 private bank mapping mismatch");
        end
        private_region_hits_r = private_region_hits_r + 1;
    end

    issue_candidate_expect_grant(
        "shared_prefix_first",
        4'hf,
        2'd0,
        4'd2,
        1'b1,
        shared_sram_r,
        shared_bank_r,
        shared_subbank_r,
        shared_len_r
    );
    if (CFG_ENABLE_TOPOLOGY) begin
        if ((shared_bank_r != {`BANK_ID_W{1'b0}}) ||
            (shared_subbank_r != {`SUBBANK_ID_W{1'b0}})) begin
            $fatal(1, "shared prefix initial placement mismatch");
        end
    end

    issue_candidate_expect_grant(
        "shared_prefix_reuse",
        4'hf,
        2'd1,
        4'd2,
        1'b1,
        shared_reuse_sram_r,
        shared_reuse_bank_r,
        shared_reuse_subbank_r,
        shared_reuse_len_r
    );
    if (CFG_ENABLE_FREEZE) begin
        if ((shared_reuse_sram_r != shared_sram_r) ||
            (shared_reuse_bank_r != shared_bank_r) ||
            (shared_reuse_subbank_r != shared_subbank_r)) begin
            $fatal(1, "shared prefix reuse mismatch");
        end
        shared_reuse_hits_r = shared_reuse_hits_r + 1;
    end else begin
        if ((shared_reuse_sram_r == shared_sram_r) &&
            (shared_reuse_bank_r == shared_bank_r) &&
            (shared_reuse_subbank_r == shared_subbank_r)) begin
            $fatal(1, "baseline should not reuse shared prefix slot");
        end
    end

    sample_query_bank(shared_sram_r, shared_bank_r);
    if (sampled_query_state_r != BANK_STATE_SPEC) begin
        $fatal(1, "shared query state mismatch");
    end

    if (CFG_ENABLE_PROMOTION) begin
        if (!u_bank_state_table.promoted_bitmap
                [(shared_sram_r * `SRAM_BANK_NUM) + shared_bank_r][shared_subbank_r]) begin
            $fatal(1, "promotion bitmap should be set");
        end
        promotion_hits_r = promotion_hits_r + 1;
    end else begin
        if (u_bank_state_table.promoted_bitmap
                [(shared_sram_r * `SRAM_BANK_NUM) + shared_bank_r][shared_subbank_r]) begin
            $fatal(1, "promotion bitmap should stay clear");
        end
    end

    drive_commit(
        4'hf,
        shared_sram_r,
        shared_bank_r,
        shared_subbank_r,
        shared_len_r,
        BRANCH0_MASK | BRANCH1_MASK,
        node_mask_for_branch_node(2'd0, 4'd2) |
        node_mask_for_branch_node(2'd1, 4'd2)
    );
    sample_query_bank(shared_sram_r, shared_bank_r);
    if (sampled_query_state_r != BANK_STATE_COMMITTED) begin
        $fatal(1, "shared commit state mismatch");
    end

    issue_candidate_expect_grant(
        "private_isolated_entry",
        4'hd,
        2'd0,
        4'd3,
        1'b0,
        isolated_sram_r,
        isolated_bank_r,
        isolated_subbank_r,
        isolated_len_r
    );
    drive_commit(
        4'hd,
        isolated_sram_r,
        isolated_bank_r,
        isolated_subbank_r,
        isolated_len_r,
        BRANCH0_MASK | BRANCH1_MASK,
        node_mask_for_branch_node(2'd0, 4'd3) |
        node_mask_for_branch_node(2'd1, 4'd3)
    );
    sample_query_bank(isolated_sram_r, isolated_bank_r);
    if (CFG_ENABLE_ISOLATION && !CFG_ENABLE_PROMOTION) begin
        if (sampled_query_branch_mask_r != BRANCH0_MASK) begin
            $fatal(1, "branch isolation guard failed");
        end
        isolation_guard_hits_r = isolation_guard_hits_r + 1;
    end else if (sampled_query_branch_mask_r == BRANCH0_MASK) begin
        isolation_guard_hits_r = isolation_guard_hits_r + 1;
    end

    drive_accepted_request(1'b1, addr_a_r, DATA_A, PRELOAD_A_REQ_ID, 16'h0000, 2'd0);
    drive_accepted_request(1'b1, addr_b_r, DATA_B, PRELOAD_B_REQ_ID, 16'h0000, 2'd0);
    drive_accepted_request(1'b1, addr_c_r, DATA_C, PRELOAD_C_REQ_ID, 16'h0000, 2'd0);

    drive_accepted_request(1'b0, addr_a_r, {`SRAM_WDATA_W{1'b0}},
                           MDV_A0_REQ_ID, MDV_A0_PE_MASK, 2'd3);
    drive_accepted_request(1'b0, addr_b_r, {`SRAM_WDATA_W{1'b0}},
                           MDV_B0_REQ_ID, MDV_B0_PE_MASK, 2'd2);
    drive_accepted_request(1'b0, addr_a_r, {`SRAM_WDATA_W{1'b0}},
                           MDV_A1_REQ_ID, MDV_A1_PE_MASK, 2'd1);
    drive_accepted_request(1'b0, addr_b_r, {`SRAM_WDATA_W{1'b0}},
                           MDV_B1_REQ_ID, MDV_B1_PE_MASK, 2'd0);
    wait_resp_mask(4'b1111);
    mdv_response_lanes_count_r = 4;
    if ((mem_read_issue_addr_a_count != 1) || (mem_read_issue_addr_b_count != 1)) begin
        $fatal(1, "mdv physical read count mismatch");
    end

    drive_accepted_request(1'b0, addr_a_r, {`SRAM_WDATA_W{1'b0}},
                           WAR_A0_REQ_ID, WAR_A0_PE_MASK, 2'd3);
    drive_accepted_request(1'b0, addr_a_r, {`SRAM_WDATA_W{1'b0}},
                           WAR_A1_REQ_ID, WAR_A1_PE_MASK, 2'd2);
    drive_accepted_request(1'b1, addr_a_r, UPDATED_A,
                           WAR_WRITE_REQ_ID, 16'h0000, 2'd0);
    wait_resp_mask(4'b0011);

    drive_accepted_request(1'b0, addr_c_r, {`SRAM_WDATA_W{1'b0}},
                           RAW_C_REQ_ID, RAW_C_PE_MASK, 2'd3);
    drive_accepted_request(1'b1, addr_b_r, UPDATED_B,
                           RAW_WRITE_REQ_ID, 16'h0000, 2'd0);
    drive_accepted_request(1'b0, addr_b_r, {`SRAM_WDATA_W{1'b0}},
                           RAW_B_REQ_ID, RAW_B_PE_MASK, 2'd1);
    wait_resp_mask(4'b0101);

    occupied_subbanks_r = 0;
    for (occ_i = 0; occ_i < `SUBBANK_NUM_PER_BANK; occ_i = occ_i + 1) begin
        if (u_bank_state_table.occ_bitmap
                [(shared_sram_r * `SRAM_BANK_NUM) + shared_bank_r][occ_i]) begin
            occupied_subbanks_r = occupied_subbanks_r + 1;
        end
    end

    $display("PERF_METRIC,total_cycles,%0d", global_cycle_count_r);
    $display("PERF_METRIC,private_region_hits,%0d", private_region_hits_r);
    $display("PERF_METRIC,shared_reuse_hits,%0d", shared_reuse_hits_r);
    $display("PERF_METRIC,promotion_hits,%0d", promotion_hits_r);
    $display("PERF_METRIC,isolation_guard_hits,%0d", isolation_guard_hits_r);
    $display("PERF_METRIC,occupied_subbanks,%0d", occupied_subbanks_r);
    $display("PERF_METRIC,physical_reads,%0d", mem_read_issue_total_count);
    $display("PERF_METRIC,physical_writes,%0d", mem_write_issue_total_count);
    $display("PERF_METRIC,mdv_response_lanes,%0d", mdv_response_lanes_count_r);

    $display("tb_exp_step3 PASS");
    $finish;
end

endmodule
