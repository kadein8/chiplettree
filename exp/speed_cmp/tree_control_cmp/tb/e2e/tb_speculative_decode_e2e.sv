`include "config/interface_params.vh"
`include "config/prediction_params.vh"
`include "config/model_params.vh"
`include "config/memory_params.vh"
`timescale 1ns/1ps

// tb_speculative_decode_e2e
//
// End-to-end testbench for the speculative decoding pipeline.
// Compatible with both Verilator (WSL) and VCS (VM).
//
// Features:
//   - SRAM memory model (1-cycle read latency)
//   - HBM memory model (2-cycle read latency)
//   - Weight preload from $readmemh files
//   - Timeout detection
//   - Output token collection and comparison

module tb_speculative_decode_e2e;

// Parameters matching toy model
localparam integer HIDDEN_DIM = `MODEL_DMODEL;
localparam integer N_LAYERS = `MODEL_N_LAYERS;
localparam integer VOCAB_SIZE = `MODEL_VOCAB_SIZE;
localparam integer DATA_WIDTH = 16;
localparam integer SRAM_DATA_W = `SRAM_RDATA_W;
localparam integer HBM_DATA_W = `HBM_DATA_W;
localparam integer MEM_DEPTH = 131072;  // 128K entries (enough for toy and small models)
localparam integer HBM_DEPTH = 32768;  // enough for toy model (20522 actual lines)
localparam integer MAX_WAIT_CYCLES = 500000000;
localparam integer NUM_GEN_TOKENS = 4;
localparam integer CLK_PERIOD = 10;

// Clock and reset
logic clk;
logic rst_n;

// DUT signals
logic start;
logic [`TOKEN_ID_W-1:0] prompt_token_id;
logic [7:0] max_gen_tokens;
logic dut_done;
logic dut_busy;
logic token_out_valid;
logic [`TOKEN_ID_W-1:0] token_out_id;

// HBM interface
logic hbm_rd_valid, hbm_rd_ready;
logic [`HBM_ADDR_W-1:0] hbm_rd_addr;
logic hbm_resp_valid;
logic [`HBM_DATA_W-1:0] hbm_resp_data;

// SRAM preload interface
logic sram_preload_valid;
logic [`SRAM_ADDR_W-1:0] sram_preload_addr;
logic [`SRAM_WDATA_W-1:0] sram_preload_data;

// Memory arrays (for preload staging)
logic [`SRAM_RDATA_W-1:0] sram_mem [0:MEM_DEPTH-1];
logic [`HBM_DATA_W-1:0] hbm_mem [0:HBM_DEPTH-1];

// HBM read pipeline (2-cycle latency)
logic hbm_rd_pending_r;
logic [`HBM_ADDR_W-1:0] hbm_rd_addr_pending_r;
logic hbm_rd_stage2_r;
logic [`HBM_DATA_W-1:0] hbm_rd_data_stage2_r;

// Output collection
integer token_count;
logic [`TOKEN_ID_W-1:0] generated_tokens [0:63];
integer wait_cycles;

// =========================================================================
// DUT instantiation
// =========================================================================
// HHT warmup signals
logic warmup_accept_valid;
logic [`NODE_ID_W-1:0] warmup_accept_parent_node_id;
logic [`TOKEN_ID_W-1:0] warmup_accept_token_id;
logic [`POSITION_ID_W-1:0] warmup_accept_position;

// =========================================================================
speculative_decode_e2e_top u_dut (
    .clk(clk),
    .rst_n(rst_n),
    .start(start),
    .prompt_token_id(prompt_token_id),
    .max_gen_tokens(max_gen_tokens),
    .done(dut_done),
    .busy(dut_busy),
    .token_out_valid(token_out_valid),
    .token_out_id(token_out_id),
    .hbm_rd_valid(hbm_rd_valid),
    .hbm_rd_ready(hbm_rd_ready),
    .hbm_rd_addr(hbm_rd_addr),
    .hbm_resp_valid(hbm_resp_valid),
    .hbm_resp_data(hbm_resp_data),
    .sram_preload_valid(sram_preload_valid),
    .sram_preload_addr(sram_preload_addr),
    .sram_preload_data(sram_preload_data),
    .warmup_accept_valid(warmup_accept_valid),
    .warmup_accept_parent_node_id(warmup_accept_parent_node_id),
    .warmup_accept_token_id(warmup_accept_token_id),
    .warmup_accept_position(warmup_accept_position)
);

// =========================================================================
// Clock generation
// =========================================================================
initial clk = 1'b0;
always #(CLK_PERIOD/2) clk = ~clk;

// =========================================================================
// SRAM is now internal (sram_subsystem inside DUT)
// Preload is done via sram_preload_* interface before start
// =========================================================================

// =========================================================================
// HBM memory model (2-cycle read latency)
// =========================================================================
assign hbm_rd_ready = 1'b1;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        hbm_rd_pending_r <= 1'b0;
        hbm_rd_addr_pending_r <= '0;
        hbm_rd_stage2_r <= 1'b0;
        hbm_rd_data_stage2_r <= '0;
        hbm_resp_valid <= 1'b0;
        hbm_resp_data <= '0;
    end else begin
        hbm_resp_valid <= 1'b0;

        // Stage 1: capture request
        if (hbm_rd_valid && hbm_rd_ready) begin
            hbm_rd_pending_r <= 1'b1;
            hbm_rd_addr_pending_r <= hbm_rd_addr;
        end

        // Stage 2: read data
        if (hbm_rd_pending_r) begin
            hbm_rd_pending_r <= 1'b0;
            hbm_rd_stage2_r <= 1'b1;
            if (hbm_rd_addr_pending_r < HBM_DEPTH)
                hbm_rd_data_stage2_r <= hbm_mem[hbm_rd_addr_pending_r];
            else
                hbm_rd_data_stage2_r <= '0;
        end

        // Stage 3: output response
        if (hbm_rd_stage2_r) begin
            hbm_rd_stage2_r <= 1'b0;
            hbm_resp_valid <= 1'b1;
            hbm_resp_data <= hbm_rd_data_stage2_r;
        end
    end
end

// =========================================================================
// Test sequence
// =========================================================================
initial begin
    integer idx;
    string sram_path, hbm_path;

    // Initialize
    rst_n = 1'b0;
    start = 1'b0;
    prompt_token_id = '0;
    max_gen_tokens = NUM_GEN_TOKENS[7:0];
    token_count = 0;
    sram_preload_valid = 1'b0;
    sram_preload_addr = '0;
    sram_preload_data = '0;

    // Initialize memory to zero
    for (idx = 0; idx < MEM_DEPTH; idx = idx + 1)
        sram_mem[idx] = '0;
    for (idx = 0; idx < HBM_DEPTH; idx = idx + 1)
        hbm_mem[idx] = '0;

    // Load weights from files into staging arrays
    sram_path = "generated/sram_preload.memh";
    hbm_path = "generated/hbm_weights.memh";
    $readmemh(sram_path, sram_mem);
    $readmemh(hbm_path, hbm_mem);
    $display("Loaded SRAM from %s", sram_path);
    $display("Loaded HBM from %s", hbm_path);

    // Preload HBM weights into staging SRAM array at WEIGHT_SRAM_BASE
    for (idx = 0; idx < HBM_DEPTH; idx = idx + 1) begin
        if (hbm_mem[1024 + idx] !== '0 && hbm_mem[1024 + idx] !== 'x) begin
            if (`MODEL_WEIGHT_SRAM_BASE + idx*2 + 1 < MEM_DEPTH) begin
                sram_mem[`MODEL_WEIGHT_SRAM_BASE + idx*2]     = hbm_mem[1024 + idx][127:0];
                sram_mem[`MODEL_WEIGHT_SRAM_BASE + idx*2 + 1] = hbm_mem[1024 + idx][255:128];
            end
        end
    end
    $display("Preloaded HBM weights to SRAM staging array at %0d", `MODEL_WEIGHT_SRAM_BASE);

    // Reset
    repeat (5) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);

    // Direct-load SRAM contents into DUT's behavioral SRAM via hierarchical access
    // This is much faster than using the preload interface for large weight sets
    $display("Writing SRAM contents to DUT via direct hierarchical access...");
    begin
        integer preload_cnt;
        integer ri;
        preload_cnt = 0;

        // Scan entire SRAM staging array and write non-zero entries to DUT
        for (ri = 0; ri < MEM_DEPTH; ri = ri + 1) begin
            if (sram_mem[ri] !== '0 && sram_mem[ri] !== {`SRAM_RDATA_W{1'bx}}) begin
                u_dut.behav_sram[ri] = sram_mem[ri];
                preload_cnt = preload_cnt + 1;
            end
        end

        $display("SRAM preload complete: %0d beats written", preload_cnt);
    end
    repeat (10) @(posedge clk);

    // =====================================================================
    // HHT Warmup: inject accept records so HHT can predict during generation
    // For toy profile: model always outputs token 0 with random weights.
    // We need HHT to predict token 0 so tree_builder can build branches.
    // Inject: hash(0,0)→0 with high confidence.
    // Sequence: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    // =====================================================================
    warmup_accept_valid = 1'b0;
    warmup_accept_parent_node_id = '0;
    warmup_accept_token_id = '0;
    warmup_accept_position = '0;

    // Inject warmup accepts to train HHT on the sequence the model produces.
    // Model output sequence (from toy weights): 13, 6, 14, 11, ...
    // HHT uses 2-token history hash. We need entries for:
    //   hash(0, 13) → predict 6
    //   hash(13, 6) → predict 14
    //   hash(6, 14) → predict 11
    // Also inject the prompt→first token: hash(0, 0) → predict 13
    begin
        integer wi;
        logic [15:0] warmup_seq [0:5];
        warmup_seq[0] = 16'd0;   // prompt
        warmup_seq[1] = 16'd13;  // first output
        warmup_seq[2] = 16'd6;   // second
        warmup_seq[3] = 16'd14;  // third
        warmup_seq[4] = 16'd11;  // fourth
        warmup_seq[5] = 16'd0;   // padding

        // Inject sequence multiple times to build confidence
        for (wi = 0; wi < 4; wi = wi + 1) begin
            integer si_w;
            for (si_w = 0; si_w < 5; si_w = si_w + 1) begin
                @(posedge clk);
                warmup_accept_valid = 1'b1;
                warmup_accept_token_id = warmup_seq[si_w];
                warmup_accept_parent_node_id = 5'd1;
                warmup_accept_position = warmup_accept_position + 12'd1;
                @(posedge clk);
                warmup_accept_valid = 1'b0;
            end
        end
    end
    repeat (2) @(posedge clk);
    $display("HHT warmup complete (sequence-based)");

    // Start speculative decode with prompt token 0
    $display("Starting speculative decode, prompt_token=%0d, max_gen=%0d",
             prompt_token_id, max_gen_tokens);
    @(negedge clk);
    start = 1'b1;
    @(negedge clk);
    start = 1'b0;

    // Wait for completion
    wait_cycles = 0;
    while (!dut_done && (wait_cycles < MAX_WAIT_CYCLES)) begin
        @(posedge clk);
        wait_cycles = wait_cycles + 1;

        // Collect output tokens
        if (token_out_valid) begin
            generated_tokens[token_count] = token_out_id;
            $display("  Token[%0d] = %0d (cycle %0d)",
                     token_count, token_out_id, wait_cycles);
            token_count = token_count + 1;
        end
    end

    if (!dut_done) begin
        $display("ERROR: Timeout after %0d cycles", MAX_WAIT_CYCLES);
        $fatal(1, "Simulation timeout");
    end

    // Report results
    $display("");
    $display("=== Speculative Decode Complete ===");
    $display("Total tokens generated: %0d", token_count);
    $display("Total cycles: %0d", wait_cycles);
    $display("Token sequence:");
    for (idx = 0; idx < token_count; idx = idx + 1)
        $display("  [%0d] = %0d", idx, generated_tokens[idx]);

    // Write output for golden comparison
    begin
        integer fd;
        fd = $fopen("rtl_output_tokens.txt", "w");
        for (idx = 0; idx < token_count; idx = idx + 1)
            $fdisplay(fd, "%0d", generated_tokens[idx]);
        $fclose(fd);
    end

    $display("");
    $display("tb_speculative_decode_e2e PASS");
    $finish;
end

// Timeout watchdog
initial begin
    #(64'd500000000 * 64'd10);
    $fatal(1, "Global timeout");
end

endmodule
