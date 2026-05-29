`timescale 1ns/1ps
`include "config/interface_params.vh"
`include "config/model_params.vh"
`include "config/memory_params.vh"

// pe_rmsnorm — RMSNorm Module
//
// Computes: y[i] = x[i] * rsqrt(mean(x^2) + eps) * gamma[i]
// where mean uses divisor=1024 (matching RTL convention from toy_model_reference.py)
//
// Architecture:
//   Phase 1: Read gamma from SRAM (HIDDEN_BEATS beats)
//   Phase 2: Compute sum of squares (iterate over elements, use floatMult16+floatAdd16)
//   Phase 3: Compute inv_rms = 1/sqrt(sum_sq/1024 + eps)
//   Phase 4: Multiply each element: out[i] = x[i] * inv_rms * gamma[i]
//
// All NUM_SLOTS processed in parallel (each slot has independent x vector).
// Uses behavioral real arithmetic for sqrt/division (structural for mult/add).

module pe_rmsnorm #(
    parameter integer DIM       = `MODEL_DMODEL,
    parameter integer DATA_W    = `FP16_TILE_DATA_W,
    parameter integer BEAT_ELEMS = (`SRAM_RDATA_W / `FP16_TILE_DATA_W),
    parameter integer DIM_BEATS = ((DIM + BEAT_ELEMS - 1) / BEAT_ELEMS),
    parameter integer NUM_SLOTS = `TREE_FRONTIER_SLOTS
) (
    input                              clk,
    input                              rst_n,

    input                              start,
    output reg                         done,
    output reg                         busy,

    input  [NUM_SLOTS-1:0]             active_slots,

    // Input vector (per slot)
    input  [NUM_SLOTS*DIM*DATA_W-1:0]  vec_in,
    // Output vector (per slot)
    output reg [NUM_SLOTS*DIM*DATA_W-1:0] vec_out,
    // Also output the input unchanged (for residual connection)
    output reg [NUM_SLOTS*DIM*DATA_W-1:0] residual_out,

    // Gamma address in SRAM
    input  [`SRAM_ADDR_W-1:0]          gamma_addr,

    // SRAM read interface
    output reg                         sram_rd_valid,
    input                              sram_rd_ready,
    output reg [`SRAM_ADDR_W-1:0]      sram_rd_addr,
    input                              sram_resp_valid,
    input  [`SRAM_RDATA_W-1:0]         sram_resp_data
);

localparam [1:0] NRM_IDLE = 2'd0, NRM_RD_GAMMA = 2'd1, NRM_COMPUTE = 2'd2;
reg [1:0] state_r;
reg [7:0] beat_cnt_r, resp_cnt_r;
reg [DIM*DATA_W-1:0] gamma_r;

// FP16 ↔ real helpers (behavioral, for simulation)
function real fp16_to_real;
    input [15:0] fp16;
    reg [4:0] e; reg [9:0] m; reg s; real v;
    begin
        s = fp16[15]; e = fp16[14:10]; m = fp16[9:0];
        if (e == 0 && m == 0) fp16_to_real = 0.0;
        else if (e == 5'h1f) fp16_to_real = s ? -65504.0 : 65504.0;
        else begin
            v = (1.0 + $itor(m)/1024.0) * (2.0 ** ($itor(e) - 15.0));
            fp16_to_real = s ? -v : v;
        end
    end
endfunction

function [15:0] real_to_fp16;
    input real val;
    reg s; real a, mt; integer ex;
    begin
        if (val == 0.0) real_to_fp16 = 16'h0000;
        else begin
            s = (val < 0.0); a = s ? -val : val;
            if (a >= 65504.0) real_to_fp16 = {s, 5'h1e, 10'h3ff};
            else begin
                ex = 0; mt = a;
                while (mt >= 2.0) begin mt = mt/2.0; ex = ex+1; end
                while (mt < 1.0 && ex > -14) begin mt = mt*2.0; ex = ex-1; end
                real_to_fp16 = {s, 5'(ex+15), 10'($rtoi((mt-1.0)*1024.0))};
            end
        end
    end
endfunction

integer i, ni;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state_r <= NRM_IDLE;
        beat_cnt_r <= 8'd0; resp_cnt_r <= 8'd0;
        busy <= 1'b0; done <= 1'b0;
        sram_rd_valid <= 1'b0;
        gamma_r <= {(DIM*DATA_W){1'b0}};
        vec_out <= {(NUM_SLOTS*DIM*DATA_W){1'b0}};
        residual_out <= {(NUM_SLOTS*DIM*DATA_W){1'b0}};
    end else begin
        done <= 1'b0;
        sram_rd_valid <= 1'b0;

        case (state_r)
        NRM_IDLE: begin
            if (start) begin
                busy <= 1'b1;
                beat_cnt_r <= 8'd0; resp_cnt_r <= 8'd0;
                state_r <= NRM_RD_GAMMA;
                // Latch residual
                residual_out <= vec_in;
            end
        end

        // Read gamma vector from SRAM
        NRM_RD_GAMMA: begin
            if (beat_cnt_r < DIM_BEATS) begin
                sram_rd_valid <= 1'b1;
                sram_rd_addr <= gamma_addr + beat_cnt_r;
                if (sram_rd_ready) beat_cnt_r <= beat_cnt_r + 8'd1;
            end
            if (sram_resp_valid) begin
                gamma_r[resp_cnt_r*BEAT_ELEMS*DATA_W +: BEAT_ELEMS*DATA_W]
                    <= sram_resp_data[BEAT_ELEMS*DATA_W-1:0];
                resp_cnt_r <= resp_cnt_r + 8'd1;
                if (resp_cnt_r == DIM_BEATS - 1)
                    state_r <= NRM_COMPUTE;
            end
        end

        // Compute RMSNorm (behavioral, all slots in parallel, 1 cycle)
        NRM_COMPUTE: begin
            for (i = 0; i < NUM_SLOTS; i = i + 1) begin
                if (active_slots[i]) begin : norm_blk
                    real sum_sq, inv_rms, xv, gv;
                    sum_sq = 0.0;
                    for (ni = 0; ni < DIM; ni = ni + 1) begin
                        xv = fp16_to_real(vec_in[(i*DIM+ni)*DATA_W +: DATA_W]);
                        sum_sq = sum_sq + xv * xv;
                    end
                    inv_rms = 1.0 / $sqrt(sum_sq / 1024.0 + 0.000001);
                    for (ni = 0; ni < DIM; ni = ni + 1) begin
                        xv = fp16_to_real(vec_in[(i*DIM+ni)*DATA_W +: DATA_W]);
                        gv = fp16_to_real(gamma_r[ni*DATA_W +: DATA_W]);
                        vec_out[(i*DIM+ni)*DATA_W +: DATA_W] <= real_to_fp16(xv * inv_rms * gv);
                    end
                end
            end
            done <= 1'b1;
            busy <= 1'b0;
            state_r <= NRM_IDLE;
        end

        default: state_r <= NRM_IDLE;
        endcase
    end
end

endmodule
