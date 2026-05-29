`timescale 1ns/1ps
`include "config/interface_params.vh"
`include "config/model_params.vh"

// pe_residual_add — Element-wise Vector Addition
//
// Computes: out[i] = a[i] + b[i] for all elements, all slots in parallel.
// Single-cycle operation (behavioral FP16 add).

module pe_residual_add #(
    parameter integer DIM       = `MODEL_DMODEL,
    parameter integer DATA_W    = `FP16_TILE_DATA_W,
    parameter integer NUM_SLOTS = `TREE_FRONTIER_SLOTS
) (
    input                              clk,
    input                              rst_n,
    input                              start,
    output reg                         done,
    input  [NUM_SLOTS-1:0]             active_slots,
    input  [NUM_SLOTS*DIM*DATA_W-1:0]  vec_a,
    input  [NUM_SLOTS*DIM*DATA_W-1:0]  vec_b,
    output reg [NUM_SLOTS*DIM*DATA_W-1:0] vec_out
);

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

integer i, j;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        done <= 1'b0;
        vec_out <= {(NUM_SLOTS*DIM*DATA_W){1'b0}};
    end else begin
        done <= 1'b0;
        if (start) begin
            for (i = 0; i < NUM_SLOTS; i = i + 1) begin
                if (active_slots[i]) begin
                    for (j = 0; j < DIM; j = j + 1) begin
                        vec_out[(i*DIM+j)*DATA_W +: DATA_W] <= real_to_fp16(
                            fp16_to_real(vec_a[(i*DIM+j)*DATA_W +: DATA_W]) +
                            fp16_to_real(vec_b[(i*DIM+j)*DATA_W +: DATA_W]));
                    end
                end
            end
            done <= 1'b1;
        end
    end
end
endmodule
