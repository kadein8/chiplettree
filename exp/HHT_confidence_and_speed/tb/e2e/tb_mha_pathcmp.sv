`include "config/interface_params.vh"
`include "config/memory_params.vh"
`include "config/model_params.vh"
`timescale 1ns/1ps

// tb_mha_pathcmp
//
// BUG 6 final isolation: does the COMMITTED-history attention path and the
// FULL-DRAFT-batch attention path compute the SAME result for byte-identical KV?
// One fp16_mha_controller, idealized SRAM. Preload so committed region pos{0,1}
// and draft region slot{0,1} hold IDENTICAL KV (same logical history). Query =
// token at position 2 with the SAME input hidden in both runs.
//   (a) BATCH path:     prefix_len=0, slot_count=3, query_slot=2, attend draft slots 0,1,2
//   (b) COMMITTED path: prefix_len=2, slot_count=1, query_slot=0, attend committed pos 0,1 + self
// If result_data differs, the committed-vs-draft attention paths are NOT
// numerically equivalent = BUG 6 mechanism.
module tb_mha_pathcmp;
  localparam integer ADDR_W=`SRAM_ADDR_W, DBUSW=`SRAM_WDATA_W, DW=`FP16_TILE_DATA_W;
  localparam integer REQ_ID_W=`REQ_ID_W, HID=`MODEL_DMODEL, NH=`MODEL_HEAD_NUM, HD=`MODEL_HEAD_DIM;
  localparam integer WIN=`VERIFY_WINDOW_SIZE, SLOT_ID_W=`SLOT_ID_W;
  localparam integer ELEMS=DBUSW/DW, HBEATS=HID/ELEMS, HEAD_BEATS=HD/ELEMS;
  localparam integer KVPOS=NH*HEAD_BEATS*2;       // per-position KV stride (beats)
  localparam integer COMMIT_BASE=`KV_COMMITTED_BASE, DRAFT_BASE=`KV_DRAFT_BASE_MIN;
  localparam integer SCRATCH=23'd8000, INADDR=23'd1000;
  localparam integer MEM_DEPTH=131072, CLK=10;

  logic clk=0, rst_n=0; always #(CLK/2) clk=~clk;
  logic [DBUSW-1:0] mem [0:MEM_DEPTH-1];

  logic iv, irdy, rdv, rdr, respv, respr, wrv, wrr, resv, resr, bwait, brel;
  logic [ADDR_W-1:0] rda, wra, resa;
  logic [REQ_ID_W-1:0] rdid, respid;
  logic [DBUSW-1:0] respd, wrd, resd;
  logic [1:0] resstat;
  logic [15:0] i_prefix; logic [4:0] i_slotcnt; logic [SLOT_ID_W-1:0] i_qslot;
  logic [WIN-1:0] i_vslots, i_isseed;

  fp16_mha_controller #(
    .ADDR_W(ADDR_W), .DATA_WIDTH(DW), .DATA_BUS_W(DBUSW), .REQ_ID_W(REQ_ID_W),
    .RESULT_STATUS_W(2), .HIDDEN_DIM(HID), .NUM_HEADS(NH), .HEAD_DIM(HD),
    .MAX_ATTN_TOKENS(`MODEL_MAX_POS_EMB), .WINDOW_SIZE(WIN), .SLOT_ID_W(SLOT_ID_W),
    .RESULT_STATUS_OK(2'b00)
  ) u (
    .clk(clk), .rst_n(rst_n), .issue_valid(iv), .issue_ready(irdy),
    .issue_input_addr(INADDR), .issue_wq_addr(23'd2000), .issue_wk_addr(23'd3000),
    .issue_wv_addr(23'd4000), .issue_wo_addr(23'd5000),
    .issue_kv_cache_addr(COMMIT_BASE), .issue_result_addr(23'd7000), .issue_scratch_base_addr(SCRATCH),
    .issue_position(16'd2), .issue_layer_id(5'd0), .issue_req_id('0),
    .issue_tree_mask_en(1'b0), .issue_branch_id('0), .issue_prefix_len(i_prefix), .issue_visible_mask('0),
    .issue_tree_batch_en(1'b1), .issue_tree_draft_kv_base(DRAFT_BASE),
    .issue_tree_query_slot(i_qslot), .issue_tree_slot_count(i_slotcnt),
    .issue_tree_visible_slots(i_vslots), .issue_tree_slot_is_seed(i_isseed),
    .issue_tree_seed_kv_valid(1'b0), .issue_tree_kv_barrier_release(1'b1), .tree_kv_barrier_waiting(bwait),
    .sram_rd_valid(rdv), .sram_rd_ready(1'b1), .sram_rd_addr(rda), .sram_rd_id(rdid),
    .sram_resp_valid(respv), .sram_resp_ready(respr), .sram_resp_data(respd), .sram_resp_id(respid),
    .sram_wr_valid(wrv), .sram_wr_ready(1'b1), .sram_wr_addr(wra), .sram_wr_data(wrd),
    .result_valid(resv), .result_ready(resr), .result_addr(resa), .result_data(resd), .result_status(resstat)
  );

  // PLACEHOLDER_PATHCMP
  logic respv_r; logic [DBUSW-1:0] respd_r; logic [REQ_ID_W-1:0] respid_r;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) respv_r<=0;
    else begin
      respv_r <= rdv;
      if (rdv) begin
        respd_r <= (rda < MEM_DEPTH) ? mem[rda] : '0;
        respid_r <= rdid;
      end
      if (wrv && wra<MEM_DEPTH) mem[wra] <= wrd;
    end
  end
  assign respv=respv_r; assign respd=respd_r; assign respid=respid_r;

  logic [DBUSW-1:0] r_batch, r_commit;
  integer k;

  task automatic preload;
    begin
      // deterministic, address-keyed pattern for everything
      for (k=0;k<MEM_DEPTH;k=k+1) mem[k] = {(DBUSW/16){k[15:0]}} ^ {(DBUSW/16){16'h3c00}};
      // Make committed pos0/pos1 KV IDENTICAL to draft slot0/slot1 KV (both layers),
      // so the only difference between the two runs is the attention PATH, not data.
      for (k=0;k<KVPOS;k=k+1) begin
        mem[COMMIT_BASE + 0*KVPOS + k] = mem[DRAFT_BASE + 0*KVPOS + k]; // L0 pos0==slot0
        mem[COMMIT_BASE + 1*KVPOS + k] = mem[DRAFT_BASE + 1*KVPOS + k]; // L0 pos1==slot1
        mem[COMMIT_BASE + 4096 + 0*KVPOS + k] = mem[DRAFT_BASE + 4096 + 0*KVPOS + k]; // L1
        mem[COMMIT_BASE + 4096 + 1*KVPOS + k] = mem[DRAFT_BASE + 4096 + 1*KVPOS + k];
        // query's SELF KV: config(a) writes/reads it at draft slot2, config(b) at draft slot0.
        // Make slot0 == slot2 so the self-token KV is identical in both runs.
        mem[DRAFT_BASE + 0*KVPOS + k]        = mem[DRAFT_BASE + 2*KVPOS + k];
        mem[DRAFT_BASE + 4096 + 0*KVPOS + k] = mem[DRAFT_BASE + 4096 + 2*KVPOS + k];
      end
    end
  endtask

  task automatic run(input logic batch, output logic [DBUSW-1:0] out);
    begin
      if (batch) begin
        i_prefix=16'd0; i_slotcnt=5'd3; i_qslot=2;
        i_vslots={{(WIN-3){1'b0}},3'b111}; i_isseed={{(WIN-1){1'b0}},1'b1};
      end else begin
        i_prefix=16'd2; i_slotcnt=5'd1; i_qslot=0;
        // query (slot0) attends committed pos0,1 (always visible) + its OWN slot
        // (ctx_slot 0 at pos=prefix). Make that self-slot visible so this path
        // attends the SAME logical set as the batch path (prompt,11,self).
        i_vslots={{(WIN-1){1'b0}},1'b1}; i_isseed={{(WIN-1){1'b0}},1'b1};
      end
      @(negedge clk); iv=1'b1; @(negedge clk); iv=1'b0;
      wait(resv); out=resd; resr=1'b1; @(negedge clk); resr=1'b0;
      repeat(6) @(negedge clk);
    end
  endtask

  initial begin
    iv=0; resr=0; preload();
    rst_n=0; repeat(5) @(negedge clk); rst_n=1; repeat(3) @(negedge clk);
    run(1'b1, r_batch);
    preload();  // restore identical SRAM
    rst_n=0; repeat(3) @(negedge clk); rst_n=1; repeat(3) @(negedge clk);
    run(1'b0, r_commit);
    $display("[PATHCMP] batch(prefix0,3slots,q2) =%h", r_batch);
    $display("[PATHCMP] commit(prefix2,1slot,q0) =%h", r_commit);
    if (r_batch === r_commit)
      $display("[PATHCMP] RESULT: IDENTICAL -> committed/draft attention paths equivalent; bug elsewhere");
    else
      $display("[PATHCMP] RESULT: DIFFER -> committed vs full-draft attention path NOT equivalent = BUG 6");
    $finish;
  end
  initial begin #(3_000_000); $display("[PATHCMP] TIMEOUT"); $finish; end
endmodule

