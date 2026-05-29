`include "config/interface_params.vh"
`include "config/prediction_params.vh"
`include "config/model_params.vh"
`include "transformer/tree_verify_dispatcher.sv"
`include "transformer/fp16_inference_top.sv"
`timescale 1ns/1ps

module tb_tree_parallel_verify;

localparam integer BRANCH_NUM = `BRANCH_NUM;
localparam integer MAX_LEVELS = `MAX_PRIVATE_NODES_PER_BRANCH;
localparam integer WINDOW_SIZE = `VERIFY_WINDOW_SIZE;
localparam integer TOKEN_ID_W = `TOKEN_ID_W;
localparam integer POSITION_ID_W = `POSITION_ID_W;
localparam integer BRANCH_ID_W = `BRANCH_ID_W;
localparam integer SLOT_ID_W = `SLOT_ID_W;

logic clk;
logic rst_n;

logic tree_req_valid;
logic tree_req_ready;
logic [TOKEN_ID_W-1:0] seed_token_id;
logic [POSITION_ID_W-1:0] seed_position;
logic [BRANCH_NUM-1:0] branch_valid;
logic [BRANCH_NUM*MAX_LEVELS*TOKEN_ID_W-1:0] branch_draft_tokens;
logic [BRANCH_NUM*MAX_LEVELS*POSITION_ID_W-1:0] branch_draft_positions;
logic [BRANCH_NUM*MAX_LEVELS*SLOT_ID_W-1:0] branch_parent_slot;
logic [BRANCH_NUM*MAX_LEVELS-1:0] branch_levels_valid;
logic [15:0] committed_prefix_len;

logic batch_req_valid;
logic batch_req_ready;
logic [4:0] batch_req_count;
logic [WINDOW_SIZE*32-1:0] batch_req_token_ids;
logic [WINDOW_SIZE*16-1:0] batch_req_positions;
logic [WINDOW_SIZE*WINDOW_SIZE-1:0] batch_req_tree_mask;
logic [15:0] batch_req_prefix_len;
logic batch_req_seed_kv_valid;
logic [WINDOW_SIZE-1:0] batch_req_slot_is_seed;

logic fwd_result_valid;
logic fwd_result_ready;
logic [4:0] fwd_result_count;
logic [WINDOW_SIZE*32-1:0] fwd_result_token_ids;

logic commit_valid;
logic [BRANCH_ID_W-1:0] commit_branch_id;
logic [2:0] commit_depth;
logic [TOKEN_ID_W-1:0] commit_bonus_token_id;
logic [BRANCH_NUM-1:0] commit_flush_mask;
logic [MAX_LEVELS*SLOT_ID_W-1:0] commit_slots;
logic busy;

logic hbm_rd_valid;
logic hbm_rd_ready;
logic [`HBM_ADDR_W-1:0] hbm_rd_addr;
logic hbm_resp_valid;
logic hbm_resp_ready;
logic [`HBM_DATA_W-1:0] hbm_resp_data;
logic sram_rd_valid;
logic sram_rd_ready;
logic [`SRAM_ADDR_W-1:0] sram_rd_addr;
logic [`REQ_ID_W-1:0] sram_rd_id;
logic sram_resp_valid;
logic sram_resp_ready;
logic [`SRAM_WDATA_W-1:0] sram_resp_data;
logic [`REQ_ID_W-1:0] sram_resp_id;
logic sram_wr_valid;
logic sram_wr_ready;
logic [`SRAM_ADDR_W-1:0] sram_wr_addr;
logic [`SRAM_WDATA_W-1:0] sram_wr_data;
logic inf_busy;
logic [15:0] current_position;
logic [4:0] current_layer_debug;

integer pass_count;
integer fail_count;
integer cycle_count;

tree_verify_dispatcher u_dispatcher (
    .clk(clk),
    .rst_n(rst_n),
    .tree_req_valid(tree_req_valid),
    .tree_req_ready(tree_req_ready),
    .seed_token_id(seed_token_id),
    .seed_position(seed_position),
    .branch_valid(branch_valid),
    .branch_draft_tokens(branch_draft_tokens),
    .branch_draft_positions(branch_draft_positions),
    .branch_parent_slot(branch_parent_slot),
    .branch_levels_valid(branch_levels_valid),
    .committed_prefix_len(committed_prefix_len),
    .batch_out_valid(batch_req_valid),
    .batch_out_ready(batch_req_ready),
    .batch_out_count(batch_req_count),
    .batch_out_token_ids(batch_req_token_ids),
    .batch_out_positions(batch_req_positions),
    .batch_out_tree_mask(batch_req_tree_mask),
    .batch_out_prefix_len(batch_req_prefix_len),
    .batch_out_seed_kv_valid(batch_req_seed_kv_valid),
    .batch_out_slot_is_seed(batch_req_slot_is_seed),
    .fwd_result_valid(fwd_result_valid),
    .fwd_result_ready(fwd_result_ready),
    .fwd_result_count(fwd_result_count),
    .fwd_result_token_ids(fwd_result_token_ids),
    .commit_valid(commit_valid),
    .commit_branch_id(commit_branch_id),
    .commit_depth(commit_depth),
    .commit_bonus_token_id(commit_bonus_token_id),
    .commit_flush_mask(commit_flush_mask),
    .commit_slots(commit_slots),
    .busy(busy)
);

fp16_inference_top #(
    .ADDR_W(`SRAM_ADDR_W),
    .DATA_BUS_W(`SRAM_WDATA_W),
    .REQ_ID_W(`REQ_ID_W),
    .HBM_ADDR_W(`HBM_ADDR_W),
    .HBM_DATA_W(`HBM_DATA_W)
) u_inference_top (
    .clk(clk),
    .rst_n(rst_n),
    .token_in_valid(1'b0),
    .token_in_ready(),
    .token_in_id(32'd0),
    .token_in_is_bos(1'b0),
    .token_out_valid(),
    .token_out_ready(1'b0),
    .token_out_id(),
    .cfg_embedding_base({`SRAM_ADDR_W{1'b0}}),
    .cfg_final_norm_gamma_addr({`SRAM_ADDR_W{1'b0}}),
    .cfg_do_sample(1'b0),
    .cfg_top_k(7'd1),
    .cfg_top_p(16'h3c00),
    .cfg_tree_mask_en(1'b0),
    .cfg_branch_id({`BRANCH_ID_W{1'b0}}),
    .cfg_prefix_len(16'd0),
    .cfg_visible_mask({`TOY_MAX_POS_EMB{1'b0}}),
    .cfg_position(16'd0),
    .cfg_position_ovr(1'b0),
    .batch_in_valid(batch_req_valid),
    .batch_in_ready(batch_req_ready),
    .batch_in_count(batch_req_count),
    .batch_in_token_ids(batch_req_token_ids),
    .batch_in_positions(batch_req_positions),
    .batch_in_tree_mask(batch_req_tree_mask),
    .batch_in_prefix_len(batch_req_prefix_len),
    .batch_in_seed_kv_valid(batch_req_seed_kv_valid),
    .batch_in_slot_is_seed(batch_req_slot_is_seed),
    .batch_out_valid(fwd_result_valid),
    .batch_out_ready(fwd_result_ready),
    .batch_out_count(fwd_result_count),
    .batch_out_token_ids(fwd_result_token_ids),
    .hbm_rd_valid(hbm_rd_valid),
    .hbm_rd_ready(hbm_rd_ready),
    .hbm_rd_addr(hbm_rd_addr),
    .hbm_resp_valid(hbm_resp_valid),
    .hbm_resp_ready(hbm_resp_ready),
    .hbm_resp_data(hbm_resp_data),
    .sram_rd_valid(sram_rd_valid),
    .sram_rd_ready(sram_rd_ready),
    .sram_rd_addr(sram_rd_addr),
    .sram_rd_id(sram_rd_id),
    .sram_resp_valid(sram_resp_valid),
    .sram_resp_ready(sram_resp_ready),
    .sram_resp_data(sram_resp_data),
    .sram_resp_id(sram_resp_id),
    .sram_wr_valid(sram_wr_valid),
    .sram_wr_ready(sram_wr_ready),
    .sram_wr_addr(sram_wr_addr),
    .sram_wr_data(sram_wr_data),
    .vec_sram_rd_valid(),
    .vec_sram_rd_ready({`MEM_REQ_LANES{1'b0}}),
    .vec_sram_rd_addr(),
    .vec_sram_rd_id(),
    .vec_sram_rd_pe_mask(),
    .vec_sram_resp_valid({`MEM_REQ_LANES{1'b0}}),
    .vec_sram_resp_ready(),
    .vec_sram_resp_data({(`MEM_REQ_LANES*`SRAM_RDATA_W){1'b0}}),
    .vec_sram_resp_id({(`MEM_REQ_LANES*`REQ_ID_W){1'b0}}),
    .vec_sram_wr_valid(),
    .vec_sram_wr_ready({`MEM_REQ_LANES{1'b0}}),
    .vec_sram_wr_addr(),
    .vec_sram_wr_data(),
    .vec_sram_wr_id(),
    .vec_sram_wr_pe_mask(),
    .busy(inf_busy),
    .current_position(current_position),
    .current_layer_debug(current_layer_debug)
);

always #5 clk = ~clk;

initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    tree_req_valid = 1'b0;
    seed_token_id = '0;
    seed_position = '0;
    branch_valid = '0;
    branch_draft_tokens = '0;
    branch_draft_positions = '0;
    branch_parent_slot = '0;
    branch_levels_valid = '0;
    committed_prefix_len = 16'd0;
    hbm_rd_ready = 1'b1;
    hbm_resp_valid = 1'b0;
    hbm_resp_data = '0;
    sram_rd_ready = 1'b1;
    sram_resp_valid = 1'b0;
    sram_resp_data = '0;
    sram_resp_id = '0;
    sram_wr_ready = 1'b1;
    pass_count = 0;
    fail_count = 0;
    cycle_count = 0;
    repeat (5) @(posedge clk);
    rst_n = 1'b1;
end

always @(posedge clk) begin
    cycle_count <= cycle_count + 1;
    if (cycle_count > 2000) begin
        $display("[TIMEOUT]");
        $finish;
    end
end

task automatic set_branch_draft;
    input integer br;
    input integer lvl;
    input logic [TOKEN_ID_W-1:0] tok;
    input logic [POSITION_ID_W-1:0] pos;
    begin
        branch_draft_tokens[(br*MAX_LEVELS + lvl)*TOKEN_ID_W +: TOKEN_ID_W] = tok;
        branch_draft_positions[(br*MAX_LEVELS + lvl)*POSITION_ID_W +: POSITION_ID_W] = pos;
        branch_parent_slot[(br*MAX_LEVELS + lvl)*SLOT_ID_W +: SLOT_ID_W] = lvl[SLOT_ID_W-1:0];
        branch_levels_valid[br*MAX_LEVELS + lvl] = 1'b1;
    end
endtask

task automatic check_result;
    input string name_s;
    input logic [BRANCH_ID_W-1:0] exp_branch;
    input logic [2:0] exp_depth;
    input logic [TOKEN_ID_W-1:0] exp_bonus;
    input logic [BRANCH_NUM-1:0] exp_flush;
    begin
        wait (commit_valid);
        #1;
        if ((commit_branch_id !== exp_branch) ||
            (commit_depth !== exp_depth) ||
            (commit_bonus_token_id !== exp_bonus) ||
            (commit_flush_mask !== exp_flush)) begin
            $display("[%s] FAIL branch=%0d depth=%0d bonus=0x%0h flush=%b",
                name_s, commit_branch_id, commit_depth, commit_bonus_token_id, commit_flush_mask);
            fail_count = fail_count + 1;
        end else begin
            $display("[%s] PASS", name_s);
            pass_count = pass_count + 1;
        end
    end
endtask

initial begin
    @(posedge rst_n);
    repeat (2) @(posedge clk);

    seed_token_id = 16'h0001;
    seed_position = 16'd3;
    committed_prefix_len = 16'd4;
    branch_valid = 4'b1111;
    branch_draft_tokens = '0;
    branch_draft_positions = '0;
    branch_parent_slot = '0;
    branch_levels_valid = '0;

    set_branch_draft(0, 0, 16'h0009, 16'd4);
    set_branch_draft(0, 1, 16'h0017, 16'd5);
    set_branch_draft(0, 2, 16'h0028, 16'd6);
    set_branch_draft(0, 3, 16'h003a, 16'd7);
    set_branch_draft(1, 0, 16'h0009, 16'd4);
    set_branch_draft(1, 1, 16'h0018, 16'd5);
    set_branch_draft(1, 2, 16'h0029, 16'd6);
    set_branch_draft(1, 3, 16'h003b, 16'd7);
    set_branch_draft(2, 0, 16'h0010, 16'd4);
    set_branch_draft(2, 1, 16'h0020, 16'd5);
    set_branch_draft(2, 2, 16'h0030, 16'd6);
    set_branch_draft(2, 3, 16'h0040, 16'd7);
    set_branch_draft(3, 0, 16'h0009, 16'd4);
    set_branch_draft(3, 1, 16'h0017, 16'd5);
    set_branch_draft(3, 2, 16'h0029, 16'd6);
    set_branch_draft(3, 3, 16'h003b, 16'd7);

    @(posedge clk);
    tree_req_valid = 1'b1;
    @(posedge clk);
    tree_req_valid = 1'b0;

    check_result("scenario1", 2'd0, 3'd4, 16'h004d, 4'b1110);
    wait (!busy);
    repeat (4) @(posedge clk);

    seed_token_id = 16'h0010;
    seed_position = 16'd2;
    committed_prefix_len = 16'd2;
    branch_valid = 4'b1111;
    branch_draft_tokens = '0;
    branch_draft_positions = '0;
    branch_parent_slot = '0;
    branch_levels_valid = '0;

    set_branch_draft(0, 0, 16'h00ff, 16'd3);
    set_branch_draft(1, 0, 16'h00fe, 16'd3);
    set_branch_draft(2, 0, 16'h00fd, 16'd3);
    set_branch_draft(3, 0, 16'h00fc, 16'd3);

    @(posedge clk);
    tree_req_valid = 1'b1;
    @(posedge clk);
    tree_req_valid = 1'b0;

    check_result("scenario2", 2'd0, 3'd0, 16'h0017, 4'b1110);
    wait (!busy);
    repeat (4) @(posedge clk);

    $display("PASSED=%0d FAILED=%0d", pass_count, fail_count);
    if (fail_count == 0)
        $display("tb_tree_parallel_verify PASS");
    $finish;
end

endmodule
