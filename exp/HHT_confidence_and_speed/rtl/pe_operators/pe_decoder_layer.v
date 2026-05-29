`timescale 1ns/1ps
`include "config/interface_params.vh"
`include "config/model_params.vh"
`include "config/memory_params.vh"

// pe_decoder_layer — Single Transformer Decoder Layer
//
// Instantiates and sequences:
//   1. pre_norm (RMSNorm)
//   2. Wv projection (matvec) — for pos-0: attn_out = V
//   3. Wo projection (matvec)
//   4. residual_add (hidden + attn_out)
//   5. post_norm (RMSNorm)
//   6. gate projection (matvec, hidden→intermediate)
//   7. up projection (matvec, hidden→intermediate)
//   8. silu_mul (silu(gate) * up)
//   9. down projection (matvec, intermediate→hidden)
//  10. residual_add (hidden + ffn_out)
//
// Position-0 simplification: single-token attention = V (softmax=1.0)
// All slots processed in parallel through shared SRAM port.

module pe_decoder_layer #(
    parameter integer HIDDEN_DIM  = `MODEL_DMODEL,
    parameter integer INTERMEDIATE = `MODEL_INTERMEDIATE_DIM,
    parameter integer DATA_W      = `FP16_TILE_DATA_W,
    parameter integer BEAT_ELEMS  = (`SRAM_RDATA_W / `FP16_TILE_DATA_W),
    parameter integer NUM_SLOTS   = `TREE_FRONTIER_SLOTS,
    // Weight offsets within layer's SRAM region
    parameter integer PRE_GAMMA_OFF  = 0,
    parameter integer POST_GAMMA_OFF = 16,
    parameter integer WV_OFF   = 32 + 256 + 256,  // after pre+post gamma + Wq + Wk
    parameter integer WO_OFF   = 32 + 256*3,
    parameter integer GATE_OFF = 32 + 256*4,
    parameter integer UP_OFF   = 32 + 256*4 + 512,
    parameter integer DOWN_OFF = 32 + 256*4 + 512*2
) (
    input                              clk,
    input                              rst_n,

    input                              start,
    output                             done,
    output                             busy,

    input  [NUM_SLOTS-1:0]             active_slots,

    // Hidden state in/out (per slot)
    input  [NUM_SLOTS*HIDDEN_DIM*DATA_W-1:0] hidden_in,
    output [NUM_SLOTS*HIDDEN_DIM*DATA_W-1:0] hidden_out,

    // Layer weight base address in SRAM
    input  [`SRAM_ADDR_W-1:0]          layer_weight_base,

    // Shared SRAM interface (active module drives, others idle)
    output                             sram_rd_valid,
    input                              sram_rd_ready,
    output [`SRAM_ADDR_W-1:0]          sram_rd_addr,
    input                              sram_resp_valid,
    input  [`SRAM_RDATA_W-1:0]         sram_resp_data
);

// =========================================================================
// Internal wires
// =========================================================================
localparam integer H = HIDDEN_DIM;
localparam integer I = INTERMEDIATE;
localparam integer VW = NUM_SLOTS * H * DATA_W;
localparam integer IW = NUM_SLOTS * I * DATA_W;

// State sequencer
localparam [3:0]
    DL_IDLE      = 4'd0,
    DL_PRE_NORM  = 4'd1,
    DL_WV       = 4'd2,
    DL_WO       = 4'd3,
    DL_RES1     = 4'd4,
    DL_POST_NORM = 4'd5,
    DL_GATE     = 4'd6,
    DL_UP       = 4'd7,
    DL_SILU     = 4'd8,
    DL_DOWN     = 4'd9,
    DL_RES2     = 4'd10,
    DL_DONE     = 4'd11;

reg [3:0] state_r;
assign busy = (state_r != DL_IDLE);
assign done = (state_r == DL_DONE);

// Intermediate registers
reg [VW-1:0] hidden_r;
reg [VW-1:0] residual_r;
reg [VW-1:0] norm_out_r;
reg [VW-1:0] v_out_r;
reg [VW-1:0] wo_out_r;
reg [IW-1:0] gate_out_r;
reg [IW-1:0] up_out_r;
reg [IW-1:0] silu_out_r;
reg [VW-1:0] down_out_r;

assign hidden_out = hidden_r;

// Sub-module control signals
reg norm_start, mv_start, res_start, silu_start;
wire norm_done, mv_done, res_done, silu_done;

// Norm module
wire norm_sram_rd_valid;
wire [`SRAM_ADDR_W-1:0] norm_sram_rd_addr;
reg [`SRAM_ADDR_W-1:0] norm_gamma_addr_r;
wire [VW-1:0] norm_vec_out;
wire [VW-1:0] norm_residual_out;

pe_rmsnorm #(.DIM(H), .NUM_SLOTS(NUM_SLOTS)) u_norm (
    .clk(clk), .rst_n(rst_n),
    .start(norm_start), .done(norm_done), .busy(),
    .active_slots(active_slots),
    .vec_in(hidden_r),
    .vec_out(norm_vec_out),
    .residual_out(norm_residual_out),
    .gamma_addr(norm_gamma_addr_r),
    .sram_rd_valid(norm_sram_rd_valid),
    .sram_rd_ready(sram_rd_ready),
    .sram_rd_addr(norm_sram_rd_addr),
    .sram_resp_valid(sram_resp_valid),
    .sram_resp_data(sram_resp_data)
);

// Matvec module (reused for Wv, Wo, gate, up, down)
wire mv_sram_rd_valid;
wire [`SRAM_ADDR_W-1:0] mv_sram_rd_addr;
reg [`SRAM_ADDR_W-1:0] mv_weight_base_r;
reg [VW-1:0] mv_vec_in_r;  // input to matvec (hidden-dim)

// For gate/up: output is INTERMEDIATE dim
// For Wv/Wo/down: output is HIDDEN dim
// We use the larger buffer and select appropriately
wire [IW-1:0] mv_vec_out_wide;

pe_matvec #(.IN_DIM(H), .OUT_DIM(I), .NUM_SLOTS(NUM_SLOTS)) u_matvec (
    .clk(clk), .rst_n(rst_n),
    .start(mv_start), .done(mv_done), .busy(),
    .active_slots(active_slots),
    .vec_in(mv_vec_in_r),
    .vec_out(mv_vec_out_wide),
    .weight_base_addr(mv_weight_base_r),
    .sram_rd_valid(mv_sram_rd_valid),
    .sram_rd_ready(sram_rd_ready),
    .sram_rd_addr(mv_sram_rd_addr),
    .sram_resp_valid(sram_resp_valid),
    .sram_resp_data(sram_resp_data)
);

// Residual add
wire [VW-1:0] res_vec_out;
pe_residual_add #(.DIM(H), .NUM_SLOTS(NUM_SLOTS)) u_res (
    .clk(clk), .rst_n(rst_n),
    .start(res_start), .done(res_done),
    .active_slots(active_slots),
    .vec_a(residual_r),
    .vec_b(hidden_r), // will be overwritten with matvec output before start
    .vec_out(res_vec_out)
);

// SiLU mul
wire [IW-1:0] silu_vec_out;
pe_silu_mul #(.DIM(I), .NUM_SLOTS(NUM_SLOTS)) u_silu (
    .clk(clk), .rst_n(rst_n),
    .start(silu_start), .done(silu_done),
    .active_slots(active_slots),
    .vec_gate(gate_out_r),
    .vec_up(up_out_r),
    .vec_out(silu_vec_out)
);

// SRAM mux: norm or matvec drives SRAM
assign sram_rd_valid = (state_r == DL_PRE_NORM || state_r == DL_POST_NORM) ?
    norm_sram_rd_valid : mv_sram_rd_valid;
assign sram_rd_addr = (state_r == DL_PRE_NORM || state_r == DL_POST_NORM) ?
    norm_sram_rd_addr : mv_sram_rd_addr;

// =========================================================================
// Sequencer state machine
// =========================================================================
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state_r <= DL_IDLE;
        hidden_r <= {VW{1'b0}};
        residual_r <= {VW{1'b0}};
        norm_out_r <= {VW{1'b0}};
        v_out_r <= {VW{1'b0}};
        wo_out_r <= {VW{1'b0}};
        gate_out_r <= {IW{1'b0}};
        up_out_r <= {IW{1'b0}};
        silu_out_r <= {IW{1'b0}};
        down_out_r <= {VW{1'b0}};
        norm_start <= 1'b0;
        mv_start <= 1'b0;
        res_start <= 1'b0;
        silu_start <= 1'b0;
        norm_gamma_addr_r <= {`SRAM_ADDR_W{1'b0}};
        mv_weight_base_r <= {`SRAM_ADDR_W{1'b0}};
        mv_vec_in_r <= {VW{1'b0}};
    end else begin
        norm_start <= 1'b0;
        mv_start <= 1'b0;
        res_start <= 1'b0;
        silu_start <= 1'b0;

        case (state_r)
        DL_IDLE: begin
            if (start) begin
                hidden_r <= hidden_in;
                state_r <= DL_PRE_NORM;
                norm_gamma_addr_r <= layer_weight_base + PRE_GAMMA_OFF;
                norm_start <= 1'b1;
            end
        end

        DL_PRE_NORM: begin
            if (norm_done) begin
                norm_out_r <= norm_vec_out;
                residual_r <= norm_residual_out;
                // Start Wv matvec
                mv_vec_in_r <= norm_vec_out;
                mv_weight_base_r <= layer_weight_base + WV_OFF;
                mv_start <= 1'b1;
                state_r <= DL_WV;
            end
        end

        DL_WV: begin
            if (mv_done) begin
                v_out_r <= mv_vec_out_wide[VW-1:0];
                // Start Wo matvec (Wo @ V)
                mv_vec_in_r <= mv_vec_out_wide[VW-1:0];
                mv_weight_base_r <= layer_weight_base + WO_OFF;
                mv_start <= 1'b1;
                state_r <= DL_WO;
            end
        end

        DL_WO: begin
            if (mv_done) begin
                wo_out_r <= mv_vec_out_wide[VW-1:0];
                // Residual add: hidden = residual + Wo_out
                hidden_r <= mv_vec_out_wide[VW-1:0];
                res_start <= 1'b1;
                state_r <= DL_RES1;
            end
        end

        DL_RES1: begin
            if (res_done) begin
                hidden_r <= res_vec_out;
                // Start post-norm
                norm_gamma_addr_r <= layer_weight_base + POST_GAMMA_OFF;
                norm_start <= 1'b1;
                state_r <= DL_POST_NORM;
            end
        end

        DL_POST_NORM: begin
            if (norm_done) begin
                norm_out_r <= norm_vec_out;
                residual_r <= norm_residual_out;
                // Start gate matvec
                mv_vec_in_r <= norm_vec_out;
                mv_weight_base_r <= layer_weight_base + GATE_OFF;
                mv_start <= 1'b1;
                state_r <= DL_GATE;
            end
        end

        DL_GATE: begin
            if (mv_done) begin
                gate_out_r <= mv_vec_out_wide;
                // Start up matvec
                mv_vec_in_r <= norm_out_r;
                mv_weight_base_r <= layer_weight_base + UP_OFF;
                mv_start <= 1'b1;
                state_r <= DL_UP;
            end
        end

        DL_UP: begin
            if (mv_done) begin
                up_out_r <= mv_vec_out_wide;
                // SiLU(gate) * up
                silu_start <= 1'b1;
                state_r <= DL_SILU;
            end
        end

        DL_SILU: begin
            if (silu_done) begin
                silu_out_r <= silu_vec_out;
                // Down matvec (intermediate → hidden)
                mv_vec_in_r <= {{(VW-IW){1'b0}}, silu_vec_out}; // pad to VW width
                mv_weight_base_r <= layer_weight_base + DOWN_OFF;
                mv_start <= 1'b1;
                state_r <= DL_DOWN;
            end
        end

        DL_DOWN: begin
            if (mv_done) begin
                down_out_r <= mv_vec_out_wide[VW-1:0];
                // Residual add: hidden = residual + down_out
                hidden_r <= mv_vec_out_wide[VW-1:0];
                res_start <= 1'b1;
                state_r <= DL_RES2;
            end
        end

        DL_RES2: begin
            if (res_done) begin
                hidden_r <= res_vec_out;
                state_r <= DL_DONE;
            end
        end

        DL_DONE: begin
            state_r <= DL_IDLE;
        end

        default: state_r <= DL_IDLE;
        endcase
    end
end

endmodule
