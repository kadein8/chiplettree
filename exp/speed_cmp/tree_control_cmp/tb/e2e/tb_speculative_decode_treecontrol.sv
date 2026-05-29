`include "config/interface_params.vh"
`include "config/prediction_params.vh"
`include "config/model_params.vh"
`include "config/memory_params.vh"
`timescale 1ns/1ps

// tb_speculative_decode_treecontrol
//
// Testbench for the full TreeControl integration path.
// Same structure as tb_speculative_decode_e2e but instantiates
// speculative_decode_treecontrol_top instead.

module tb_speculative_decode_treecontrol;

localparam integer MEM_DEPTH = 270336;
localparam integer HBM_DEPTH = 32768;
localparam integer MAX_WAIT_CYCLES = 8000000;
localparam integer NUM_GEN_TOKENS = 8;
localparam integer CLK_PERIOD = 10;

logic clk, rst_n;
logic start;
logic [`TOKEN_ID_W-1:0] prompt_token_id;
logic [7:0] max_gen_tokens;
logic dut_done, dut_busy;
logic token_out_valid;
logic [`TOKEN_ID_W-1:0] token_out_id;
logic hbm_rd_valid, hbm_rd_ready;
logic [`HBM_ADDR_W-1:0] hbm_rd_addr;
logic hbm_resp_valid;
logic [`HBM_DATA_W-1:0] hbm_resp_data;
logic sram_preload_valid;
logic [`SRAM_ADDR_W-1:0] sram_preload_addr;
logic [`SRAM_WDATA_W-1:0] sram_preload_data;
logic [`SRAM_RDATA_W-1:0] sram_mem [0:MEM_DEPTH-1];
logic [`HBM_DATA_W-1:0] hbm_mem [0:HBM_DEPTH-1];
logic warmup_accept_valid;
logic [`NODE_ID_W-1:0] warmup_accept_parent_node_id;
logic [`TOKEN_ID_W-1:0] warmup_accept_token_id;
logic [`POSITION_ID_W-1:0] warmup_accept_position;

integer token_count, wait_cycles;
logic [`TOKEN_ID_W-1:0] generated_tokens [0:63];

// PLACEHOLDER_DUT_AND_LOGIC

// =========================================================================
// DUT
// =========================================================================
speculative_decode_treecontrol_top u_dut (
    .clk(clk), .rst_n(rst_n),
    .start(start),
    .prompt_token_id(prompt_token_id),
    .max_gen_tokens(max_gen_tokens),
    .done(dut_done), .busy(dut_busy),
    .token_out_valid(token_out_valid),
    .token_out_id(token_out_id),
    .hbm_rd_valid(hbm_rd_valid), .hbm_rd_ready(hbm_rd_ready),
    .hbm_rd_addr(hbm_rd_addr),
    .hbm_resp_valid(hbm_resp_valid), .hbm_resp_data(hbm_resp_data),
    .sram_preload_valid(sram_preload_valid),
    .sram_preload_addr(sram_preload_addr),
    .sram_preload_data(sram_preload_data),
    .warmup_accept_valid(warmup_accept_valid),
    .warmup_accept_parent_node_id(warmup_accept_parent_node_id),
    .warmup_accept_token_id(warmup_accept_token_id),
    .warmup_accept_position(warmup_accept_position)
);

// =========================================================================
// Clock
// =========================================================================
initial clk = 0;
always #(CLK_PERIOD/2) clk = ~clk;

// =========================================================================
// HBM model (2-cycle latency)
// =========================================================================
logic hbm_rd_pending_r;
logic [`HBM_ADDR_W-1:0] hbm_rd_addr_pending_r;
logic hbm_rd_stage2_r;
logic [`HBM_DATA_W-1:0] hbm_rd_data_stage2_r;

assign hbm_rd_ready = 1'b1;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        hbm_rd_pending_r <= 0;
        hbm_rd_stage2_r <= 0;
        hbm_resp_valid <= 0;
    end else begin
        hbm_rd_pending_r <= hbm_rd_valid;
        hbm_rd_addr_pending_r <= hbm_rd_addr;
        hbm_rd_stage2_r <= hbm_rd_pending_r;
        if (hbm_rd_pending_r && hbm_rd_addr_pending_r < HBM_DEPTH)
            hbm_rd_data_stage2_r <= hbm_mem[hbm_rd_addr_pending_r];
        else
            hbm_rd_data_stage2_r <= '0;
        hbm_resp_valid <= hbm_rd_stage2_r;
        hbm_resp_data <= hbm_rd_data_stage2_r;
    end
end

// =========================================================================
// Token collection
// =========================================================================
always @(posedge clk) begin
    if (token_out_valid) begin
        generated_tokens[token_count] = token_out_id;
        $display("  Token[%0d] = %0d (cycle %0d)", token_count, token_out_id, $time/CLK_PERIOD);
        token_count = token_count + 1;
    end
end

// =========================================================================
// Main test sequence
// =========================================================================
integer idx;
string sram_path, hbm_path;

initial begin
    // Init
    rst_n = 0;
    start = 0;
    prompt_token_id = 16'd0;
    max_gen_tokens = NUM_GEN_TOKENS;
    token_count = 0;
    sram_preload_valid = 0;
    sram_preload_addr = '0;
    sram_preload_data = '0;
    warmup_accept_valid = 0;
    warmup_accept_parent_node_id = '0;
    warmup_accept_token_id = '0;
    warmup_accept_position = '0;

    // Clear memories
    for (idx = 0; idx < MEM_DEPTH; idx = idx + 1) sram_mem[idx] = '0;
    for (idx = 0; idx < HBM_DEPTH; idx = idx + 1) hbm_mem[idx] = '0;

    // Load weight files
    sram_path = "generated/sram_preload.memh";
    hbm_path = "generated/hbm_weights.memh";
    $readmemh(sram_path, sram_mem);
    $readmemh(hbm_path, hbm_mem);
    $display("Loaded SRAM from %s", sram_path);
    $display("Loaded HBM from %s", hbm_path);

    // HBM -> SRAM staging removed: fp16_inference_top streams weights from HBM at runtime

    // Reset
    repeat (5) @(posedge clk);
    rst_n = 1;
    repeat (2) @(posedge clk);

    // Direct SRAM preload
    $display("Writing SRAM to DUT (shared SRAM)...");
    begin
        integer preload_cnt, ri;
        preload_cnt = 0;
        // Zero all behav_sram first
        for (ri = 0; ri < 270336; ri = ri + 1)
            u_dut.behav_sram[ri] = '0;
        for (ri = 0; ri < MEM_DEPTH; ri = ri + 1) begin
            if (sram_mem[ri] !== '0 && sram_mem[ri] !== {`SRAM_RDATA_W{1'bx}}) begin
                u_dut.behav_sram[ri] = sram_mem[ri];
                preload_cnt = preload_cnt + 1;
            end
        end
        $display("SRAM preload: %0d beats (single shared SRAM)", preload_cnt);
    end
    // Also preload HBM local memory in DUT
    for (idx = 0; idx < HBM_DEPTH; idx = idx + 1)
        u_dut.hbm_local_mem[idx] = hbm_mem[idx];
    $display("HBM local preload: %0d entries", HBM_DEPTH);
    repeat (10) @(posedge clk);

    // HHT warmup: inject sequence [0, 13, 6, 14, 11] multiple times
    begin
        integer wi, si_w;
        logic [15:0] warmup_seq [0:4];
        warmup_seq[0] = 16'd0;
        warmup_seq[1] = 16'd13;
        warmup_seq[2] = 16'd13;
        warmup_seq[3] = 16'd13;
        warmup_seq[4] = 16'd13;
        for (wi = 0; wi < 4; wi = wi + 1) begin
            for (si_w = 0; si_w < 5; si_w = si_w + 1) begin
                @(posedge clk);
                warmup_accept_valid = 1;
                warmup_accept_token_id = warmup_seq[si_w];
                warmup_accept_parent_node_id = 5'd1;
                warmup_accept_position = warmup_accept_position + 12'd1;
                @(posedge clk);
                warmup_accept_valid = 0;
            end
        end
    end
    repeat (2) @(posedge clk);
    $display("HHT warmup complete");

    // Start
    $display("Starting TreeControl speculative decode, prompt=%0d, max_gen=%0d",
        prompt_token_id, max_gen_tokens);
    @(negedge clk);
    start = 1;
    @(negedge clk);
    start = 0;

    // Wait for completion or timeout
    wait_cycles = 0;
    while (!dut_done && wait_cycles < MAX_WAIT_CYCLES) begin
        @(posedge clk);
        wait_cycles = wait_cycles + 1;
    end

    if (dut_done) begin
        $display("\nTreeControl decode completed in %0d cycles", wait_cycles);
        $display("Generated %0d tokens", token_count);
        if (token_count > 0)
            $display("tb_speculative_decode_treecontrol PASS");
        else
            $display("tb_speculative_decode_treecontrol FAIL (no tokens)");
    end else begin
        $display("tb_speculative_decode_treecontrol FAIL (timeout after %0d cycles)", wait_cycles);
    end

    repeat (10) @(posedge clk);
    $finish;
end

// =========================================================================
// Debug probes: trace where the pipeline stalls
// =========================================================================
reg [31:0] dbg_cnt;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) dbg_cnt <= 0;
    else dbg_cnt <= dbg_cnt + 1;
end

always @(posedge clk) begin
    // Print detailed state around tree_builder done time
    if (dbg_cnt >= 105 && dbg_cnt <= 130) begin
        $display("[TC_DBG c%0d] state=%0d tb_done=%b tb_tree_req_valid=%b tb_tree_req_ready=%b bridge_st=%0d bridge_req_valid=%b",
            dbg_cnt, u_dut.state_r, u_dut.tb_done, u_dut.tb_tree_req_valid, u_dut.tb_tree_req_ready,
            u_dut.u_bridge.state_r, u_dut.bridge_req_valid);
    end
    // Print every 512 cycles during verify
    if (u_dut.state_r == 4'd4 && dbg_cnt[8:0] == 9'd0 && dbg_cnt > 200) begin
        $display("[TC_DBG c%0d] VERIFY: issue_v=%b issue_r=%b lc_busy=%b lc_done=%b",
            dbg_cnt,
            u_dut.paper_issue_bundle_valid, u_dut.paper_issue_bundle_ready,
            u_dut.lc_busy_w, u_dut.lc_done_w);
    end
    // One-shot: when bridge fires
    if (u_dut.bridge_req_valid && u_dut.bridge_req_ready)
        $display("[TC_DBG c%0d] BRIDGE handshake: req_id=%0d", dbg_cnt, u_dut.bridge_req_id);
    if (u_dut.bridge_done)
        $display("[TC_DBG c%0d] BRIDGE done", dbg_cnt);
    // tree_builder done
    if (u_dut.tb_done)
        $display("[TC_DBG c%0d] tree_builder done: branch_valid=%b", dbg_cnt, u_dut.tb_branch_valid);
    if (u_dut.tb_tree_req_valid && u_dut.tb_tree_req_ready)
        $display("[TC_DBG c%0d] tree_builder req handshake", dbg_cnt);
    // STMP probes
    if (u_dut.u_stmp.prefix_valid && u_dut.u_stmp.prefix_ready)
        $display("[TC_DBG c%0d] tree_analyze prefix fired", dbg_cnt);
    if (u_dut.u_stmp.frontier_valid && u_dut.u_stmp.frontier_ready)
        $display("[TC_DBG c%0d] tree_analyze frontier fired", dbg_cnt);
    // Scheduler/emitter probes
    if (u_dut.sched_all_done)
        $display("[TC_DBG c%0d] scheduler all_done", dbg_cnt);
    if (u_dut.cmp2_result_valid)
        $display("[TC_DBG c%0d] comparator result: count=%0d", dbg_cnt, u_dut.cmp2_accepted_count);
    if (u_dut.emit_done_w)
        $display("[TC_DBG c%0d] emitter done: %0d tokens", dbg_cnt, u_dut.emit_tokens_emitted);
end

// Global timeout
initial begin
    #(5_000_000_000_000);
    $display("Fatal: Global timeout");
    $finish;
end

endmodule
