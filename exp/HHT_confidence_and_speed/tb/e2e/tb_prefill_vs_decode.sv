`include "config/interface_params.vh"
`include "config/prediction_params.vh"
`include "config/model_params.vh"
`include "config/memory_params.vh"
`timescale 1ns/1ps

// tb_prefill_vs_decode
//
// BUG 6 real-data test: drive ONE fp16_inference_lc_wrapper with REAL weights
// (generated/sram_preload.memh + hbm_weights.memh). Compare:
//   RUN A (batch width 3): slots=[prompt,11,14] @pos[0,1,2], prefix_len=0, causal mask
//                          -> capture slot2 (tip) generated token.
//   RUN B (autoregressive): 3 sequential 1-slot runs, prefix_len 0->1->2, committing each
//                          token's KV to the committed region -> capture 3rd token.
// If A.slot2 != B.3rd, the one-pass batch prefill is not equivalent to incremental decode
// on REAL weights (suspected inherent FP16 non-associativity). Tokens [prompt=0,11,14] mirror
// the live divergence (greedy after [0,11,14] = 6; live batch branch2 = 11).
module tb_prefill_vs_decode;
  localparam integer LC_SLOTS = `TREE_FRONTIER_SLOTS;
  localparam integer KV_SLOT_STRIDE = 16384;
  localparam integer KV_REGION_END  = `KV_DRAFT_BASE_MIN + 1*KV_SLOT_STRIDE;
  localparam integer WEIGHT_BASE = (`MODEL_WEIGHT_SRAM_BASE > KV_REGION_END) ? `MODEL_WEIGHT_SRAM_BASE : KV_REGION_END;
  localparam integer MEM_DEPTH = WEIGHT_BASE + 1*33792 + 4096;
  localparam integer HBM_DEPTH = 32768;
  localparam integer CLK = 10;
  localparam integer KV_POS_STRIDE_L = `MODEL_HEAD_NUM * (`MODEL_HEAD_DIM/(`SRAM_RDATA_W/`FP16_TILE_DATA_W)) * 2;

  logic clk=0, rst_n=0; always #(CLK/2) clk=~clk;

  logic start, done, busy;
  logic [LC_SLOTS-1:0] slot_valid;
  logic [LC_SLOTS*`TOKEN_ID_W-1:0] slot_token_id;
  logic [LC_SLOTS*`POSITION_ID_W-1:0] slot_position_id;
  logic [LC_SLOTS*LC_SLOTS-1:0] tree_mask;
  logic [15:0] committed_prefix_len;
  logic [LC_SLOTS-1:0] out_token_valid;
  logic [LC_SLOTS*`TOKEN_ID_W-1:0] out_token_id;

  logic [`MEM_REQ_LANES-1:0] vrv, vrr, vrw;
  logic [`MEM_REQ_LANES*`SRAM_ADDR_W-1:0] vra, vrwd;
  logic [`MEM_REQ_LANES*`REQ_ID_W-1:0] vrid;
  logic [`MEM_REQ_LANES*`PE_MASK_W-1:0] vrpm;
  logic [`MEM_REQ_LANES*`REQ_PRIORITY_W-1:0] vrpr;
  logic [`MEM_REQ_LANES*`BANK_ID_W-1:0] vrb; logic [`MEM_REQ_LANES*`SUBBANK_ID_W-1:0] vrsb;
  logic [`PE_MASK_W-1:0] mcrv, mcrr, mcrl;
  logic [`PE_MASK_W*`SRAM_RDATA_W-1:0] mcrd;
  logic [`PE_MASK_W*`REQ_ID_W-1:0] mcid;
  logic swv, swr; logic [`SRAM_ADDR_W-1:0] swa; logic [`SRAM_WDATA_W-1:0] swd;
  logic hrv, hrr, hpv; logic [`HBM_ADDR_W-1:0] hra; logic [`HBM_DATA_W-1:0] hpd;

  reg [`SRAM_RDATA_W-1:0] behav_sram [0:MEM_DEPTH-1];
  reg [`HBM_DATA_W-1:0]   hbm_local  [0:HBM_DEPTH-1];

  fp16_inference_lc_wrapper #(
    .KV_BASE(`KV_DRAFT_BASE_MIN), .W_SRAM_BASE(WEIGHT_BASE[22:0]), .HBM_W_BASE(`MODEL_HBM_WEIGHT_BASE)
  ) u_lc (
    .clk(clk), .rst_n(rst_n), .start(start), .done(done), .busy(busy),
    .slot_valid(slot_valid), .slot_token_id(slot_token_id), .slot_position_id(slot_position_id),
    .tree_mask(tree_mask),
    .embedding_base_addr(`MODEL_EMB_BASE), .hidden0_base_addr(`MODEL_WORK_HIDDEN0_BASE),
    .hidden1_base_addr(`MODEL_WORK_HIDDEN1_BASE), .final_base_addr(`MODEL_WORK_FINAL_BASE),
    .weight_sram_base_addr(WEIGHT_BASE[22:0]), .kv_cache_base_addr(`KV_DRAFT_BASE_MIN),
    .final_norm_gamma_addr(`MODEL_FINAL_NORM_GAMMA_ADDR), .lm_head_weight_base_addr(`MODEL_LM_HEAD_WEIGHT_BASE),
    .hbm_weight_base_addr(`MODEL_HBM_WEIGHT_BASE), .committed_prefix_len(committed_prefix_len),
    .vec_req_valid(vrv), .vec_req_ready(vrr), .vec_req_write(vrw), .vec_req_addr(vra),
    .vec_req_wdata(vrwd), .vec_req_req_id(vrid), .vec_req_pe_mask(vrpm), .vec_req_priority(vrpr),
    .vec_req_bank_id(vrb), .vec_req_subbank_id(vrsb),
    .mc_resp_valid(mcrv), .mc_resp_ready(mcrr), .mc_resp_rdata(mcrd), .mc_resp_req_id(mcid), .mc_resp_last(mcrl),
    .sram_wr_valid(swv), .sram_wr_ready(swr), .sram_wr_addr(swa), .sram_wr_data(swd),
    .hbm_rd_valid(hrv), .hbm_rd_ready(1'b1), .hbm_rd_addr(hra),
    .hbm_resp_valid(hpv), .hbm_resp_data(hpd),
    .out_token_valid(out_token_valid), .out_token_id(out_token_id)
  );
  // PLACEHOLDER_MODEL
  // Per-LC behav_sram vec model (faithful copy of treecontrol_top gen_lc block)
  assign vrr = {`MEM_REQ_LANES{1'b1}};
  assign swr = 1'b1;
  reg [`MEM_REQ_LANES-1:0] rvr; reg [`MEM_REQ_LANES*`SRAM_RDATA_W-1:0] rdr;
  reg [`MEM_REQ_LANES*`REQ_ID_W-1:0] rir; reg [`MEM_REQ_LANES-1:0] rlr;
  integer mi;
  always @(posedge clk) begin
    for (mi=0; mi<`MEM_REQ_LANES; mi=mi+1) begin
      rvr[mi] <= vrv[mi] && !vrw[mi];
      if (vrv[mi]) begin
        if (vrw[mi]) begin
          if (vra[mi*`SRAM_ADDR_W +: `SRAM_ADDR_W] < MEM_DEPTH)
            behav_sram[vra[mi*`SRAM_ADDR_W +: `SRAM_ADDR_W]] <= vrwd[mi*`SRAM_WDATA_W +: `SRAM_WDATA_W];
        end else begin
          if (vra[mi*`SRAM_ADDR_W +: `SRAM_ADDR_W] < MEM_DEPTH)
            rdr[mi*`SRAM_RDATA_W +: `SRAM_RDATA_W] <= behav_sram[vra[mi*`SRAM_ADDR_W +: `SRAM_ADDR_W]];
          else rdr[mi*`SRAM_RDATA_W +: `SRAM_RDATA_W] <= '0;
        end
        rir[mi*`REQ_ID_W +: `REQ_ID_W] <= vrid[mi*`REQ_ID_W +: `REQ_ID_W];
      end
      rlr[mi] <= vrv[mi] && !vrw[mi];
    end
    if (swv && swa < MEM_DEPTH) behav_sram[swa] <= swd;
  end
  assign mcrv = rvr; assign mcrd = rdr; assign mcid = rir; assign mcrl = rlr;

  // HBM pipe (2-cycle), faithful copy
  reg hp1v; reg [`HBM_ADDR_W-1:0] hp1a; reg hp2v; reg [`HBM_DATA_W-1:0] hp2d;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin hp1v<=0; hp2v<=0; end
    else begin
      hp1v<=hrv; hp1a<=hra; hp2v<=hp1v;
      if (hp1v && hp1a<HBM_DEPTH) hp2d<=hbm_local[hp1a]; else hp2d<='0;
    end
  end
  assign hpv=hp2v; assign hpd=hp2d;

  // KV commit: copy committed token kv_tok from this LC's draft slot kv_tok to committed pos.
  task automatic kv_commit(input integer count, input integer old_prefix);
    integer t,l,b,src,dst;
    begin
      for (t=0;t<count;t=t+1)
        for (l=0;l<`MODEL_N_LAYERS;l=l+1) begin
          src = `KV_DRAFT_BASE_MIN + l*4096 + t*KV_POS_STRIDE_L;
          dst = `KV_COMMITTED_BASE + l*4096 + (old_prefix+t)*KV_POS_STRIDE_L;
          for (b=0;b<KV_POS_STRIDE_L;b=b+1) behav_sram[dst+b] = behav_sram[src+b];
        end
    end
  endtask

  integer ci, ri, tip;
  string sp, hp;
  logic [`TOKEN_ID_W-1:0] tok_batch3, tok_auto3;
  logic [`TOKEN_ID_W-1:0] tok_batch2, tok_auto2;

  task automatic load_weights;
    begin
      for (ci=0;ci<MEM_DEPTH;ci=ci+1) behav_sram[ci]='0;
      for (ci=0;ci<HBM_DEPTH;ci=ci+1) hbm_local[ci]='0;
      begin
        reg [`SRAM_RDATA_W-1:0] sm [0:MEM_DEPTH-1]; reg [`HBM_DATA_W-1:0] hm [0:HBM_DEPTH-1];
        for (ci=0;ci<MEM_DEPTH;ci=ci+1) sm[ci]='0;
        for (ci=0;ci<HBM_DEPTH;ci=ci+1) hm[ci]='0;
        $readmemh("generated/sram_preload.memh", sm);
        $readmemh("generated/hbm_weights.memh", hm);
        for (ci=0;ci<MEM_DEPTH;ci=ci+1)
          if (sm[ci]!=='0 && sm[ci]!=={`SRAM_RDATA_W{1'bx}}) behav_sram[ci]=sm[ci];
        for (ci=0;ci<HBM_DEPTH;ci=ci+1) hbm_local[ci]=hm[ci];
      end
    end
  endtask

  task automatic set_slot(input integer s, input integer tok, input integer pos);
    begin
      slot_valid[s]=1'b1;
      slot_token_id[s*`TOKEN_ID_W +: `TOKEN_ID_W]=tok[`TOKEN_ID_W-1:0];
      slot_position_id[s*`POSITION_ID_W +: `POSITION_ID_W]=pos[`POSITION_ID_W-1:0];
    end
  endtask

  task automatic build_causal_mask(input integer nslots);
    integer qi,kj;
    begin
      tree_mask='0;
      for (qi=0;qi<nslots;qi=qi+1)
        for (kj=0;kj<=qi;kj=kj+1)
          tree_mask[qi*LC_SLOTS + kj]=1'b1;
    end
  endtask

  task automatic run_once(output logic [`TOKEN_ID_W-1:0] tipout);
    integer s;
    begin
      @(negedge clk); start=1'b1; @(negedge clk); start=1'b0;
      wait(done);
      // tip = last valid slot
      tipout='0;
      for (s=0;s<LC_SLOTS;s=s+1)
        if (slot_valid[s]) tipout=out_token_id[s*`TOKEN_ID_W +: `TOKEN_ID_W];
      repeat(4) @(negedge clk);
    end
  endtask

  initial begin
    start=0; slot_valid='0; slot_token_id='0; slot_position_id='0; tree_mask='0; committed_prefix_len=0;
    load_weights();
    rst_n=0; repeat(5) @(negedge clk); rst_n=1; repeat(4) @(negedge clk);

    // ===== RUN A: batch width 3 over [0,11,14] @ pos 0,1,2 =====
    slot_valid='0; committed_prefix_len=16'd0;
    set_slot(0,0,0); set_slot(1,11,1); set_slot(2,14,2);
    build_causal_mask(3);
    run_once(tok_batch3);

    // ===== RUN A2: batch width 2 over [0,11] @ pos 0,1 (depth-1 analog) =====
    slot_valid='0; committed_prefix_len=16'd0;
    set_slot(0,0,0); set_slot(1,11,1);
    build_causal_mask(2);
    run_once(tok_batch2);

    // ===== RUN B: autoregressive 3 steps, prefix 0->1->2, committing KV each step =====
    load_weights();  // fresh SRAM
    rst_n=0; repeat(3) @(negedge clk); rst_n=1; repeat(3) @(negedge clk);
    // step0: token0 @pos0, prefix0
    slot_valid='0; committed_prefix_len=16'd0; set_slot(0,0,0); build_causal_mask(1);
    run_once(tip); kv_commit(1,0);
    // step1: token11 @pos1, prefix1
    slot_valid='0; committed_prefix_len=16'd1; set_slot(0,11,1); build_causal_mask(1);
    run_once(tok_auto2); kv_commit(1,1);   // tok_auto2 = decode f([0,11])
    // step2: token14 @pos2, prefix2
    slot_valid='0; committed_prefix_len=16'd2; set_slot(0,14,2); build_causal_mask(1);
    run_once(tok_auto3);

    $display("[PVD] batch2 slot1 (one-pass [0,11])       = %0d", tok_batch2);
    $display("[PVD] auto2  (decode 0->11, f([0,11]))     = %0d", tok_auto2);
    $display("[PVD] batch3 slot2 (one-pass [0,11,14])    = %0d", tok_batch3);
    $display("[PVD] auto3  (decode 0->11->14, committed) = %0d", tok_auto3);
    $display("[PVD] depth1(batch2==auto2)=%0d  depth2(batch3==auto3)=%0d",
        (tok_batch2===tok_auto2), (tok_batch3===tok_auto3));
    if (tok_batch3 === tok_auto3)
      $display("[PVD] RESULT: SAME -> batch prefill == autoregressive decode on real weights");
    else
      $display("[PVD] RESULT: DIFFER -> one-pass batch prefill != incremental decode (FP16 prefill/decode divergence)");
    $finish;
  end
  initial begin #(20_000_000); $display("[PVD] TIMEOUT"); $finish; end
endmodule

