`include "config/interface_params.vh"
`include "config/memory_params.vh"
`include "config/model_params.vh"
`timescale 1ns/1ps

// tb_mha_concurrent
//
// BUG 6 decisive test: run TWO fp16_mha_controller draft lanes (slot1, slot2)
// CONCURRENTLY over ONE shared behav_sram (faithful per-LC model: per-lane 1-cycle
// latency, id echo) with the REAL barrier handshake (release only when BOTH lanes
// are waiting). Then run slot1 ALONE (slot2 inactive). If slot1's result_data
// CHANGES between concurrent and solo, the barrier/concurrency timing corrupts a
// draft slot's layer output -> that is BUG 6's mechanism.
module tb_mha_concurrent;
  localparam integer ADDR_W=`SRAM_ADDR_W, DBUSW=`SRAM_WDATA_W, DW=`FP16_TILE_DATA_W;
  localparam integer REQ_ID_W=`REQ_ID_W, HID=`MODEL_DMODEL, NH=`MODEL_HEAD_NUM, HD=`MODEL_HEAD_DIM;
  localparam integer WIN=`VERIFY_WINDOW_SIZE, SLOT_ID_W=`SLOT_ID_W;
  localparam integer MEM_DEPTH=32768, CLK=10;
  localparam integer NL=2; // two lanes

  logic clk=0, rst_n=0; always #(CLK/2) clk=~clk;
  logic [DBUSW-1:0] mem [0:MEM_DEPTH-1];

  // per-lane controller signals
  logic [NL-1:0] iv, irdy;
  logic [NL-1:0] rdv, respv, wrv, resv, resr, bwait, brel;
  logic [NL-1:0] rdr; logic [NL-1:0] respr;
  logic [NL*ADDR_W-1:0] rda, wra, resa;
  logic [NL*REQ_ID_W-1:0] rdid, respid;
  logic [NL*DBUSW-1:0] respd, wrd, resd;
  logic [NL*2-1:0] resstat;
  logic [NL*SLOT_ID_W-1:0] qslot;

  // shared issue (same for both except query_slot / result/scratch addr)
  logic [ADDR_W-1:0] in_addr[NL], scr[NL], rsl[NL];
  logic [15:0] pos[NL];
  logic [WIN-1:0] vslots[NL];

  // real barrier: release when all ACTIVE lanes are waiting
  logic [NL-1:0] lane_active;
  wire all_waiting = &(bwait | ~lane_active);
  wire barrier_rel = all_waiting;
  assign brel = {NL{barrier_rel}};

  genvar g;
  generate for (g=0; g<NL; g=g+1) begin: gl
    fp16_mha_controller #(
      .ADDR_W(ADDR_W), .DATA_WIDTH(DW), .DATA_BUS_W(DBUSW), .REQ_ID_W(REQ_ID_W),
      .RESULT_STATUS_W(2), .HIDDEN_DIM(HID), .NUM_HEADS(NH), .HEAD_DIM(HD),
      .MAX_ATTN_TOKENS(`MODEL_MAX_POS_EMB), .WINDOW_SIZE(WIN), .SLOT_ID_W(SLOT_ID_W),
      .RESULT_STATUS_OK(2'b00)
    ) u (
      .clk(clk), .rst_n(rst_n),
      .issue_valid(iv[g] & lane_active[g]), .issue_ready(irdy[g]),
      .issue_input_addr(in_addr[g]),
      .issue_wq_addr(23'd2000), .issue_wk_addr(23'd3000), .issue_wv_addr(23'd4000), .issue_wo_addr(23'd5000),
      .issue_kv_cache_addr(23'd6000), .issue_result_addr(rsl[g]), .issue_scratch_base_addr(scr[g]),
      .issue_position(pos[g]), .issue_layer_id(5'd0), .issue_req_id(g[REQ_ID_W-1:0]),
      .issue_tree_mask_en(1'b0), .issue_branch_id('0), .issue_prefix_len(16'd0), .issue_visible_mask('0),
      .issue_tree_batch_en(1'b1), .issue_tree_draft_kv_base(23'd9000),
      .issue_tree_query_slot(qslot[g*SLOT_ID_W +: SLOT_ID_W]), .issue_tree_slot_count(5'd3),
      .issue_tree_visible_slots(vslots[g]), .issue_tree_slot_is_seed('0),
      .issue_tree_seed_kv_valid(1'b0), .issue_tree_kv_barrier_release(brel[g]),
      .tree_kv_barrier_waiting(bwait[g]),
      .sram_rd_valid(rdv[g]), .sram_rd_ready(rdr[g]), .sram_rd_addr(rda[g*ADDR_W +: ADDR_W]),
      .sram_rd_id(rdid[g*REQ_ID_W +: REQ_ID_W]),
      .sram_resp_valid(respv[g]), .sram_resp_ready(respr[g]),
      .sram_resp_data(respd[g*DBUSW +: DBUSW]), .sram_resp_id(respid[g*REQ_ID_W +: REQ_ID_W]),
      .sram_wr_valid(wrv[g]), .sram_wr_ready(1'b1), .sram_wr_addr(wra[g*ADDR_W +: ADDR_W]),
      .sram_wr_data(wrd[g*DBUSW +: DBUSW]),
      .result_valid(resv[g]), .result_ready(resr[g]), .result_addr(resa[g*ADDR_W +: ADDR_W]),
      .result_data(resd[g*DBUSW +: DBUSW]), .result_status(resstat[g*2 +: 2])
    );
    assign rdr[g]=1'b1;
  end endgenerate

  // PLACEHOLDER_SRAM_AND_TEST
  // Shared multi-lane behav_sram model (faithful to per-LC model in treecontrol_top):
  // each lane 1-cycle read latency + id echo; writes apply at clock edge to shared mem.
  logic [NL-1:0] respv_r; logic [NL*DBUSW-1:0] respd_r; logic [NL*REQ_ID_W-1:0] respid_r;
  integer mi;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) respv_r <= '0;
    else begin
      for (mi=0; mi<NL; mi=mi+1) begin
        respv_r[mi] <= rdv[mi];
        if (rdv[mi]) begin
          respd_r[mi*DBUSW +: DBUSW] <= (rda[mi*ADDR_W +: ADDR_W] < MEM_DEPTH) ? mem[rda[mi*ADDR_W +: ADDR_W]] : '0;
          respid_r[mi*REQ_ID_W +: REQ_ID_W] <= rdid[mi*REQ_ID_W +: REQ_ID_W];
        end
        if (wrv[mi] && wra[mi*ADDR_W +: ADDR_W] < MEM_DEPTH)
          mem[wra[mi*ADDR_W +: ADDR_W]] <= wrd[mi*DBUSW +: DBUSW];
      end
    end
  end
  assign respv = respv_r;
  assign respd = respd_r;
  assign respid = respid_r;

  logic [DBUSW-1:0] slot1_concurrent, slot1_solo;

  task automatic init_issue;
    begin
      // slot1 (lane0): query_slot=1, slot2 (lane1): query_slot=2
      qslot[0*SLOT_ID_W +: SLOT_ID_W] = 1;
      qslot[1*SLOT_ID_W +: SLOT_ID_W] = 2;
      in_addr[0]=23'd1016; in_addr[1]=23'd1032;   // distinct per-slot input hidden
      scr[0]=23'd8000;    scr[1]=23'd8240;        // distinct scratch (240 apart, like SLOT_SCRATCH_STRIDE)
      rsl[0]=23'd7000;    rsl[1]=23'd7240;
      pos[0]=16'd1;       pos[1]=16'd2;
      vslots[0]={{(WIN-2){1'b0}},2'b11};          // slot1 attends slots 0,1
      vslots[1]={{(WIN-3){1'b0}},3'b111};         // slot2 attends slots 0,1,2
    end
  endtask

  task automatic do_run(input logic both, output logic [DBUSW-1:0] s1);
    begin
      lane_active = both ? 2'b11 : 2'b01;  // both lanes, or slot1 only
      @(negedge clk); iv = 2'b11;
      @(negedge clk); iv = 2'b00;
      // wait for slot1 (lane0) result
      wait (resv[0]);
      s1 = resd[0*DBUSW +: DBUSW];
      resr[0]=1'b1; resr[1]=1'b1;
      @(negedge clk); resr=2'b00;
      repeat(8) @(negedge clk);
    end
  endtask

  integer i;
  initial begin
    for (i=0;i<MEM_DEPTH;i=i+1) mem[i] = {(DBUSW/16){i[15:0]}} ^ {(DBUSW/16){16'h3c00}};
    iv=0; resr=0; lane_active=0; init_issue();
    rst_n=0; repeat(5) @(negedge clk); rst_n=1; repeat(3) @(negedge clk);

    do_run(1'b1, slot1_concurrent);  // slot1 + slot2 concurrent (live-like)
    // reset SRAM image to identical state before solo run
    for (i=0;i<MEM_DEPTH;i=i+1) mem[i] = {(DBUSW/16){i[15:0]}} ^ {(DBUSW/16){16'h3c00}};
    rst_n=0; repeat(3) @(negedge clk); rst_n=1; repeat(3) @(negedge clk);
    do_run(1'b0, slot1_solo);        // slot1 alone

    $display("[CONC] slot1 concurrent=%h", slot1_concurrent);
    $display("[CONC] slot1 solo      =%h", slot1_solo);
    if (slot1_concurrent === slot1_solo)
      $display("[CONC] RESULT: IDENTICAL -> concurrency/barrier does NOT corrupt slot1; bug is elsewhere");
    else
      $display("[CONC] RESULT: DIFFER -> concurrent barrier/multi-lane timing corrupts slot1's output = BUG 6 mechanism");
    $finish;
  end
  initial begin #(3_000_000); $display("[CONC] TIMEOUT"); $finish; end
endmodule

