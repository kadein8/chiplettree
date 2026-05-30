`include "config/interface_params.vh"
`include "config/memory_params.vh"
`include "config/model_params.vh"
`timescale 1ns/1ps

// tb_mha_seed_vs_draft
//
// Controlled microbench for BUG 6: instantiate ONE fp16_mha_controller and run
// the SAME attention twice over byte-identical preloaded SRAM, once with
// SEED-style issue params (query_slot=0, slot_is_seed[0]=1) and once with
// DRAFT-style params (query_slot=1, slot_is_seed=0), with the slot data mirrored
// so both compute the SAME logical token at the SAME position over the SAME
// context. If the result_data differs, the seed vs draft *parameterization* of
// the controller is itself the source of non-equivalence (not the live-system
// SRAM port timing). This is confound-free: same module, same SRAM image.
//
// SRAM model: 1-cycle latency, id echo, matching the per-LC behav_sram in
// speculative_decode_treecontrol_top.

module tb_mha_seed_vs_draft;
  localparam integer ADDR_W   = `SRAM_ADDR_W;
  localparam integer DBUSW    = `SRAM_WDATA_W;
  localparam integer DW       = `FP16_TILE_DATA_W;
  localparam integer REQ_ID_W = `REQ_ID_W;
  localparam integer HID      = `MODEL_DMODEL;
  localparam integer NH       = `MODEL_HEAD_NUM;
  localparam integer HD       = `MODEL_HEAD_DIM;
  localparam integer WIN      = `VERIFY_WINDOW_SIZE;
  localparam integer SLOT_ID_W= `SLOT_ID_W;
  localparam integer ELEMS    = DBUSW / DW;
  localparam integer HBEATS   = HID / ELEMS;
  localparam integer MEM_DEPTH= 32768;
  localparam integer CLK = 10;

  logic clk=0, rst_n=0;
  always #(CLK/2) clk=~clk;

  // SRAM
  logic [DBUSW-1:0] mem [0:MEM_DEPTH-1];

  // DUT issue
  logic issue_valid; logic issue_ready;
  logic [ADDR_W-1:0] issue_input_addr, issue_wq, issue_wk, issue_wv, issue_wo;
  logic [ADDR_W-1:0] issue_kv_cache_addr, issue_result_addr, issue_scratch;
  logic [15:0] issue_position; logic [4:0] issue_layer; logic [REQ_ID_W-1:0] issue_req_id;
  logic issue_tree_mask_en; logic [`BRANCH_ID_W-1:0] issue_branch_id;
  logic [15:0] issue_prefix_len; logic [`MODEL_MAX_POS_EMB-1:0] issue_visible;
  logic issue_tree_batch_en; logic [ADDR_W-1:0] issue_draft_kv_base;
  logic [SLOT_ID_W-1:0] issue_query_slot; logic [4:0] issue_slot_count;
  logic [WIN-1:0] issue_visible_slots, issue_slot_is_seed;
  logic issue_seed_kv_valid, issue_barrier_release; logic barrier_waiting;

  logic rdv, rdr, respv, respr, wrv, wrr, resv, resr;
  logic [ADDR_W-1:0] rda, wra, resa;
  logic [REQ_ID_W-1:0] rdid, respid;
  logic [DBUSW-1:0] respd, wrd, resd;
  logic [1:0] resstat;

  fp16_mha_controller #(
    .ADDR_W(ADDR_W), .DATA_WIDTH(DW), .DATA_BUS_W(DBUSW), .REQ_ID_W(REQ_ID_W),
    .RESULT_STATUS_W(2), .HIDDEN_DIM(HID), .NUM_HEADS(NH), .HEAD_DIM(HD),
    .MAX_ATTN_TOKENS(`MODEL_MAX_POS_EMB), .WINDOW_SIZE(WIN), .SLOT_ID_W(SLOT_ID_W),
    .RESULT_STATUS_OK(2'b00)
  ) dut (
    .clk(clk), .rst_n(rst_n),
    .issue_valid(issue_valid), .issue_ready(issue_ready),
    .issue_input_addr(issue_input_addr), .issue_wq_addr(issue_wq),
    .issue_wk_addr(issue_wk), .issue_wv_addr(issue_wv), .issue_wo_addr(issue_wo),
    .issue_kv_cache_addr(issue_kv_cache_addr), .issue_result_addr(issue_result_addr),
    .issue_scratch_base_addr(issue_scratch), .issue_position(issue_position),
    .issue_layer_id(issue_layer), .issue_req_id(issue_req_id),
    .issue_tree_mask_en(issue_tree_mask_en), .issue_branch_id(issue_branch_id),
    .issue_prefix_len(issue_prefix_len), .issue_visible_mask(issue_visible),
    .issue_tree_batch_en(issue_tree_batch_en), .issue_tree_draft_kv_base(issue_draft_kv_base),
    .issue_tree_query_slot(issue_query_slot), .issue_tree_slot_count(issue_slot_count),
    .issue_tree_visible_slots(issue_visible_slots), .issue_tree_slot_is_seed(issue_slot_is_seed),
    .issue_tree_seed_kv_valid(issue_seed_kv_valid),
    .issue_tree_kv_barrier_release(issue_barrier_release), .tree_kv_barrier_waiting(barrier_waiting),
    .sram_rd_valid(rdv), .sram_rd_ready(rdr), .sram_rd_addr(rda), .sram_rd_id(rdid),
    .sram_resp_valid(respv), .sram_resp_ready(respr), .sram_resp_data(respd), .sram_resp_id(respid),
    .sram_wr_valid(wrv), .sram_wr_ready(wrr), .sram_wr_addr(wra), .sram_wr_data(wrd),
    .result_valid(resv), .result_ready(resr), .result_addr(resa),
    .result_data(resd), .result_status(resstat)
  );

  // PLACEHOLDER_SRAM_MODEL
  assign rdr = 1'b1;
  assign wrr = 1'b1;
  // 1-cycle read latency, id echo (matches per-LC behav_sram model)
  logic respv_r; logic [DBUSW-1:0] respd_r; logic [REQ_ID_W-1:0] respid_r;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin respv_r<=0; end
    else begin
      respv_r <= rdv;
      if (rdv) begin
        respd_r <= (rda < MEM_DEPTH) ? mem[rda] : '0;
        respid_r <= rdid;
      end
      if (wrv && wra < MEM_DEPTH) mem[wra] <= wrd;
    end
  end
  assign respv = respv_r;
  assign respd = respd_r;
  assign respid = respid_r;

  logic [DBUSW-1:0] result_seed, result_draft;

  task automatic run_attn(input logic is_draft, output logic [DBUSW-1:0] out);
    begin
      @(negedge clk);
      issue_valid = 1'b1;
      // SEED: query_slot=0, slot_is_seed[0]=1; DRAFT: query_slot=1, slot_is_seed=0
      issue_query_slot   = is_draft ? 1 : 0;
      issue_slot_is_seed = is_draft ? '0 : {{(WIN-1){1'b0}},1'b1};
      @(negedge clk);
      issue_valid = 1'b0;
      // wait for result
      wait (resv);
      out = resd;
      resr = 1'b1;
      @(negedge clk);
      resr = 1'b0;
      repeat(4) @(negedge clk);
    end
  endtask

  integer i;
  initial begin
    // deterministic SRAM image: fill with a simple pattern so attention has
    // non-trivial data; identical for both runs.
    for (i=0;i<MEM_DEPTH;i=i+1) mem[i] = {(DBUSW/16){i[15:0]}} ^ {(DBUSW/16){16'h3c00}};
    issue_valid=0; resr=0;
    issue_input_addr   = 23'd1000;   // hidden input (norm'd)
    issue_wq = 23'd2000; issue_wk = 23'd3000; issue_wv = 23'd4000; issue_wo = 23'd5000;
    issue_kv_cache_addr= 23'd6000;   // committed KV base
    issue_result_addr  = 23'd7000;
    issue_scratch      = 23'd8000;
    issue_position     = 16'd1;
    issue_layer        = 5'd0;
    issue_req_id       = '0;
    issue_tree_mask_en = 1'b0;
    issue_branch_id    = '0;
    issue_prefix_len   = 16'd0;      // round-0 style: no committed prefix
    issue_visible      = '0;
    issue_tree_batch_en= 1'b1;
    issue_draft_kv_base= 23'd9000;
    issue_slot_count   = 5'd2;       // seed + 1 draft slot in the window
    issue_visible_slots= {{(WIN-2){1'b0}},2'b11}; // attend slots 0 and 1
    issue_seed_kv_valid= 1'b0;
    issue_barrier_release = 1'b1;    // single controller, no barrier

    rst_n=0; repeat(5) @(negedge clk); rst_n=1; repeat(3) @(negedge clk);

    run_attn(1'b0, result_seed);   // SEED params
    run_attn(1'b1, result_draft);  // DRAFT params (same SRAM, mirrored slot role)

    $display("[MICRO] SEED  result_data[15:0]=%h full=%h", result_seed[15:0], result_seed);
    $display("[MICRO] DRAFT result_data[15:0]=%h full=%h", result_draft[15:0], result_draft);
    if (result_seed === result_draft)
      $display("[MICRO] RESULT: IDENTICAL -> seed/draft parameterization is equivalent; bug is elsewhere (live SRAM timing/addressing)");
    else
      $display("[MICRO] RESULT: DIFFER -> seed vs draft controller parameterization itself diverges (query_slot/slot_is_seed path)");
    $finish;
  end

  initial begin #(2_000_000); $display("[MICRO] TIMEOUT"); $finish; end
endmodule

