`timescale 1ns/1ps
`include "config/interface_params.vh"
`include "config/model_params.vh"

// pe_rmsnorm_compute — Compute-only RMSNorm (no SRAM interface)
//
// Computes: y[i] = x[i] * rsqrt(sum(x^2)/1024 + eps) * gamma[i]
// Gamma is provided as input (controller handles SRAM read).
// All slots processed in parallel, single-cycle.
//
// VCS path: behavioral real arithmetic
// Vlator path: DPI-C (real type not supported in older versions)

module pe_rmsnorm_compute #(
    parameter integer DIM       = `MODEL_DMODEL,
    parameter integer DATA_W    = `FP16_TILE_DATA_W,
    parameter integer NUM_SLOTS = `TREE_FRONTIER_SLOTS
) (
    input                              clk,
    input                              rst_n,
    input                              start,
    output reg                         done,
    input  [NUM_SLOTS-1:0]             active_slots,
    input  [NUM_SLOTS*DIM*DATA_W-1:0]  vec_in,
    input  [DIM*DATA_W-1:0]            gamma,
    output reg [NUM_SLOTS*DIM*DATA_W-1:0] vec_out
);

`ifdef VERILATOR
// DPI-C implementation for Verilator
import "DPI-C" function void dpi_rmsnorm(
    input  bit [NUM_SLOTS*DIM*DATA_W-1:0] vec_in_flat,
    input  bit [DIM*DATA_W-1:0]           gamma_flat,
    input  bit [NUM_SLOTS-1:0]            active_slots_in,
    output bit [NUM_SLOTS*DIM*DATA_W-1:0] vec_out_flat,
    input  int                            num_slots_in,
    input  int                            dim_in
);

reg [NUM_SLOTS*DIM*DATA_W-1:0] dpi_out;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        done <= 1'b0;
        vec_out <= {(NUM_SLOTS*DIM*DATA_W){1'b0}};
    end else begin
        done <= 1'b0;
        if (start) begin
            dpi_rmsnorm(vec_in, gamma, active_slots, dpi_out, NUM_SLOTS, DIM);
            vec_out <= dpi_out;
            done <= 1'b1;
        end
    end
end

`else
// Behavioral real implementation for VCS/simulation

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
        done <= 1'b0;
        vec_out <= {(NUM_SLOTS*DIM*DATA_W){1'b0}};
    end else begin
        done <= 1'b0;
        if (start) begin
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
                        gv = fp16_to_real(gamma[ni*DATA_W +: DATA_W]);
                        vec_out[(i*DIM+ni)*DATA_W +: DATA_W] <= real_to_fp16(xv * inv_rms * gv);
                    end
                end
            end
            done <= 1'b1;
        end
    end
end
`endif

endmodule
