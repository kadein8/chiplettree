`timescale 1ns/1ps
`include "config/interface_params.vh"
`include "config/prediction_params.vh"
`include "config/model_params.vh"
`include "config/memory_params.vh"

module tb_batch_single_token;

localparam HIDDEN_DIM = `MODEL_DMODEL;
localparam INTERMEDIATE = `MODEL_INTERMEDIATE_DIM;
localparam NUM_HEADS = `MODEL_HEAD_NUM;
localparam HEAD_DIM = `MODEL_HEAD_DIM;
localparam N_LAYERS = `MODEL_N_LAYERS;
localparam VOCAB_SIZE = `MODEL_VOCAB_SIZE;
localparam MAX_POS = `MODEL_MAX_POS_EMB;
localparam WINDOW_SIZE = `VERIFY_WINDOW_SIZE;
localparam ADDR_W = `SRAM_ADDR_W;
localparam HBM_ADDR_W = `HBM_ADDR_W;
localparam HBM_DATA_W = `HBM_DATA_W;
localparam DATA_BUS_W = `SRAM_RDATA_W;

reg clk, rst_n;
initial clk = 0;
always #5 clk = ~clk;

// fp16_inference_top signals
reg token_in_valid;
wire token_in_ready;
reg [31:0] token_in_id;
reg token_in_is_bos;
wire token_out_valid;
wire [31:0] token_out_id;

reg batch_in_valid;
wire batch_in_ready;
reg [4:0] batch_in_count;
reg [WINDOW_SIZE*32-1:0] batch_in_token_ids;
reg [WINDOW_SIZE*16-1:0] batch_in_positions;
reg [WINDOW_SIZE*WINDOW_SIZE-1:0] batch_in_tree_mask;
reg [15:0] batch_in_prefix_len;
reg batch_in_seed_kv_valid;
reg [WINDOW_SIZE-1:0] batch_in_slot_is_seed;
wire batch_out_valid;
wire [4:0] batch_out_count;
wire [WINDOW_SIZE*32-1:0] batch_out_token_ids;

// SRAM
wire sram_rd_valid, sram_wr_valid;
wire [ADDR_W-1:0] sram_rd_addr, sram_wr_addr;
wire [`REQ_ID_W-1:0] sram_rd_id;
reg sram_resp_valid;
reg [DATA_BUS_W-1:0] sram_resp_data;
reg [`REQ_ID_W-1:0] sram_resp_id;
wire [DATA_BUS_W-1:0] sram_wr_data;

// Vec SRAM
wire [`MEM_REQ_LANES-1:0] vec_rd_valid, vec_wr_valid;
reg [`MEM_REQ_LANES-1:0] vec_rd_ready;
wire [`MEM_REQ_LANES*ADDR_W-1:0] vec_rd_addr, vec_wr_addr;
wire [`MEM_REQ_LANES*`REQ_ID_W-1:0] vec_rd_id;
wire [`MEM_REQ_LANES*`PE_MASK_W-1:0] vec_rd_pe_mask;
reg [`MEM_REQ_LANES-1:0] vec_resp_valid;
reg [`MEM_REQ_LANES*DATA_BUS_W-1:0] vec_resp_data;
reg [`MEM_REQ_LANES*`REQ_ID_W-1:0] vec_resp_id;
wire [`MEM_REQ_LANES*DATA_BUS_W-1:0] vec_wr_data;

// HBM
wire hbm_rd_valid;
wire [HBM_ADDR_W-1:0] hbm_rd_addr;
reg hbm_resp_valid;
reg [HBM_DATA_W-1:0] hbm_resp_data;

// Behavioral SRAM + HBM
localparam SRAM_DEPTH = 270336;
reg [DATA_BUS_W-1:0] sram_mem [0:SRAM_DEPTH-1];
localparam HBM_DEPTH = 32768;
reg [HBM_DATA_W-1:0] hbm_mem [0:HBM_DEPTH-1];
// PLACEHOLDER_DUT

fp16_inference_top #(
    .HIDDEN_DIM(HIDDEN_DIM), .INTERMEDIATE_DIM(INTERMEDIATE),
    .NUM_HEADS(NUM_HEADS), .HEAD_DIM(HEAD_DIM),
    .N_LAYERS(N_LAYERS), .VOCAB_SIZE(VOCAB_SIZE),
    .MAX_ATTN_TOKENS(MAX_POS), .WINDOW_SIZE(WINDOW_SIZE)
) u_dut (
    .clk(clk), .rst_n(rst_n),
    .token_in_valid(token_in_valid), .token_in_ready(token_in_ready),
    .token_in_id(token_in_id), .token_in_is_bos(token_in_is_bos),
    .token_out_valid(token_out_valid), .token_out_ready(1'b1), .token_out_id(token_out_id),
    .cfg_embedding_base(`MODEL_EMB_BASE),
    .cfg_final_norm_gamma_addr(`MODEL_FINAL_NORM_GAMMA_ADDR),
    .cfg_do_sample(1'b0), .cfg_top_k(7'd1), .cfg_top_p(16'd0),
    .cfg_tree_mask_en(1'b0), .cfg_branch_id(2'd0),
    .cfg_prefix_len(16'd0), .cfg_visible_mask({MAX_POS{1'b1}}),
    .cfg_position(16'd0), .cfg_position_ovr(1'b0),
    .batch_in_valid(batch_in_valid), .batch_in_ready(batch_in_ready),
    .batch_in_count(batch_in_count),
    .batch_in_token_ids(batch_in_token_ids),
    .batch_in_positions(batch_in_positions),
    .batch_in_tree_mask(batch_in_tree_mask),
    .batch_in_prefix_len(batch_in_prefix_len),
    .batch_in_seed_kv_valid(batch_in_seed_kv_valid),
    .batch_in_slot_is_seed(batch_in_slot_is_seed),
    .batch_out_valid(batch_out_valid), .batch_out_ready(1'b1),
    .batch_out_count(batch_out_count),
    .batch_out_token_ids(batch_out_token_ids),
    .hbm_rd_valid(hbm_rd_valid), .hbm_rd_ready(1'b1),
    .hbm_rd_addr(hbm_rd_addr),
    .hbm_resp_valid(hbm_resp_valid), .hbm_resp_ready(),
    .hbm_resp_data(hbm_resp_data),
    .sram_rd_valid(sram_rd_valid), .sram_rd_ready(1'b1),
    .sram_rd_addr(sram_rd_addr), .sram_rd_id(sram_rd_id),
    .sram_resp_valid(sram_resp_valid), .sram_resp_ready(),
    .sram_resp_data(sram_resp_data), .sram_resp_id(sram_resp_id),
    .sram_wr_valid(sram_wr_valid), .sram_wr_ready(1'b1),
    .sram_wr_addr(sram_wr_addr), .sram_wr_data(sram_wr_data),
    .vec_sram_rd_valid(vec_rd_valid), .vec_sram_rd_ready(vec_rd_ready),
    .vec_sram_rd_addr(vec_rd_addr), .vec_sram_rd_id(vec_rd_id),
    .vec_sram_rd_pe_mask(vec_rd_pe_mask),
    .vec_sram_resp_valid(vec_resp_valid), .vec_sram_resp_ready(),
    .vec_sram_resp_data(vec_resp_data), .vec_sram_resp_id(vec_resp_id),
    .vec_sram_wr_valid(vec_wr_valid), .vec_sram_wr_ready({`MEM_REQ_LANES{1'b1}}),
    .vec_sram_wr_addr(vec_wr_addr), .vec_sram_wr_data(vec_wr_data),
    .vec_sram_wr_id(), .vec_sram_wr_pe_mask(),
    .busy(), .current_position(), .current_layer_debug()
);
// PLACEHOLDER_SRAM_MODEL

// Scalar SRAM model (1-cycle)
always @(posedge clk) begin
    sram_resp_valid <= sram_rd_valid;
    if (sram_rd_valid) begin
        sram_resp_data <= (sram_rd_addr < SRAM_DEPTH) ? sram_mem[sram_rd_addr] : {DATA_BUS_W{1'b0}};
        sram_resp_id <= sram_rd_id;
    end
    if (sram_wr_valid && sram_wr_addr < SRAM_DEPTH)
        sram_mem[sram_wr_addr] <= sram_wr_data;
end

// Vec SRAM model (1-cycle)
integer vi;
always @(posedge clk) begin
    for (vi = 0; vi < `MEM_REQ_LANES; vi = vi + 1) begin
        vec_rd_ready[vi] <= 1'b1;
        vec_resp_valid[vi] <= vec_rd_valid[vi];
        if (vec_rd_valid[vi]) begin
            if (vec_rd_addr[vi*ADDR_W +: ADDR_W] < SRAM_DEPTH)
                vec_resp_data[vi*DATA_BUS_W +: DATA_BUS_W] <= sram_mem[vec_rd_addr[vi*ADDR_W +: ADDR_W]];
            else
                vec_resp_data[vi*DATA_BUS_W +: DATA_BUS_W] <= {DATA_BUS_W{1'b0}};
            vec_resp_id[vi*`REQ_ID_W +: `REQ_ID_W] <= vec_rd_id[vi*`REQ_ID_W +: `REQ_ID_W];
        end
    end
    for (vi = 0; vi < `MEM_REQ_LANES; vi = vi + 1) begin
        if (vec_wr_valid[vi] && vec_wr_addr[vi*ADDR_W +: ADDR_W] < SRAM_DEPTH)
            sram_mem[vec_wr_addr[vi*ADDR_W +: ADDR_W]] <= vec_wr_data[vi*DATA_BUS_W +: DATA_BUS_W];
    end
end

// HBM model (2-cycle)
reg hbm_pipe_valid;
reg [HBM_ADDR_W-1:0] hbm_pipe_addr;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        hbm_pipe_valid <= 0;
        hbm_resp_valid <= 0;
    end else begin
        hbm_pipe_valid <= hbm_rd_valid;
        hbm_pipe_addr <= hbm_rd_addr;
        hbm_resp_valid <= hbm_pipe_valid;
        if (hbm_pipe_valid)
            hbm_resp_data <= (hbm_pipe_addr < HBM_DEPTH) ? hbm_mem[hbm_pipe_addr] : {HBM_DATA_W{1'b0}};
    end
end
// PLACEHOLDER_INITIAL

initial begin
    $readmemh("generated/sram_preload.memh", sram_mem);
    $readmemh("generated/hbm_weights.memh", hbm_mem);
    $display("Loaded SRAM and HBM");

    rst_n = 0;
    token_in_valid = 0;
    batch_in_valid = 0;
    batch_in_count = 0;
    batch_in_token_ids = 0;
    batch_in_positions = 0;
    batch_in_tree_mask = 0;
    batch_in_prefix_len = 0;
    batch_in_seed_kv_valid = 0;
    batch_in_slot_is_seed = 0;
    token_in_id = 0;
    token_in_is_bos = 0;

    #100;
    rst_n = 1;
    #20;

    // Test 1: Single-token path, token=0, position=0
    $display("\n=== Test 1: Single-token path, token=0 ===");
    @(posedge clk);
    token_in_valid <= 1;
    token_in_id <= 32'd0;
    token_in_is_bos <= 1;
    @(posedge clk);
    while (!token_in_ready) @(posedge clk);
    token_in_valid <= 0;
    while (!token_out_valid) @(posedge clk);
    $display("Single-token output: token=%0d", token_out_id);
    @(posedge clk);

    // Wait for module to go idle
    #2000;

    // Test 2: Batch path, count=1, token=0, position=0
    $display("\n=== Test 2: Batch path, count=1, token=0 ===");
    @(posedge clk);
    batch_in_valid <= 1;
    batch_in_count <= 5'd1;
    batch_in_token_ids <= 0;
    batch_in_token_ids[31:0] <= 32'd0;
    batch_in_positions <= 0;
    batch_in_positions[15:0] <= 16'd0;
    batch_in_tree_mask <= 0;
    batch_in_tree_mask[0] <= 1'b1;
    batch_in_prefix_len <= 16'd0;
    batch_in_seed_kv_valid <= 1'b0;
    batch_in_slot_is_seed <= 0;
    batch_in_slot_is_seed[0] <= 1'b1;
    @(posedge clk);
    while (!batch_in_ready) @(posedge clk);
    batch_in_valid <= 0;
    while (!batch_out_valid) @(posedge clk);
    $display("Batch output: token=%0d count=%0d", batch_out_token_ids[31:0], batch_out_count);
    @(posedge clk);

    #100;
    $display("\n=== DONE ===");
    $finish;
end

initial begin
    #100000000;
    $display("TIMEOUT");
    $finish;
end

endmodule
