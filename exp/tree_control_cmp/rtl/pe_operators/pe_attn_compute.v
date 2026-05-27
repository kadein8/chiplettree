`timescale 1ns/1ps
`include "config/interface_params.vh"
`include "config/model_params.vh"

// pe_attn_compute — Full Multi-Head Attention with RoPE, KV Cache, Tree Mask
//
// Implements the complete attention operation for the PE Arrays computation chain:
//   1. RoPE rotation on Q and K (per head)
//   2. KV cache write (store K, V at current position)
//   3. Attention scoring: Q . K^T / sqrt(HEAD_DIM) with tree mask
//   4. Softmax over visible positions
//   5. Weighted sum of V values
//   6. Concatenate head outputs
//
// All slots processed in parallel, single-cycle (behavioral).
// VCS path: behavioral real arithmetic
// Vlator path: DPI-C

module pe_attn_compute #(
    parameter integer HIDDEN_DIM = `MODEL_DMODEL,
    parameter integer HEAD_DIM   = `MODEL_HEAD_DIM,
    parameter integer NUM_HEADS  = `MODEL_HEAD_NUM,
    parameter integer MAX_POS    = `MODEL_MAX_POS_EMB,
    parameter integer N_LAYERS   = `MODEL_N_LAYERS,
    parameter integer DATA_W     = `FP16_TILE_DATA_W,
    parameter integer NUM_SLOTS  = `TREE_FRONTIER_SLOTS,
    parameter integer POS_W      = `POSITION_ID_W
) (
    input                              clk,
    input                              rst_n,
    input                              start,
    output reg                         done,
    input  [NUM_SLOTS-1:0]             active_slots,
    input  [5:0]                       layer_idx,
    input  [NUM_SLOTS*POS_W-1:0]       position,
    input  [NUM_SLOTS*MAX_POS-1:0]     visible_mask,
    input  [NUM_SLOTS*HIDDEN_DIM*DATA_W-1:0] vec_q,
    input  [NUM_SLOTS*HIDDEN_DIM*DATA_W-1:0] vec_k,
    input  [NUM_SLOTS*HIDDEN_DIM*DATA_W-1:0] vec_v,
    output reg [NUM_SLOTS*HIDDEN_DIM*DATA_W-1:0] vec_out
);

// KV cache: internal registers for simulation
// Shape: [layer][position][head][element]
reg [DATA_W-1:0] kv_cache_k [0:N_LAYERS-1][0:MAX_POS-1][0:NUM_HEADS-1][0:HEAD_DIM-1];
reg [DATA_W-1:0] kv_cache_v [0:N_LAYERS-1][0:MAX_POS-1][0:NUM_HEADS-1][0:HEAD_DIM-1];

`ifdef VERILATOR
// DPI-C path placeholder (to be implemented)
// For now, use same behavioral code wrapped differently
`endif

// RoPE theta
localparam real ROPE_THETA = 1000000.0;
localparam real SQRT_HEAD_DIM = 8.0; // sqrt(64) = 8

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

integer slot_i, head_i, pos_i, dim_i, pair_i;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        done <= 1'b0;
        vec_out <= {(NUM_SLOTS*HIDDEN_DIM*DATA_W){1'b0}};
    end else begin
        done <= 1'b0;
        if (start) begin
            for (slot_i = 0; slot_i < NUM_SLOTS; slot_i = slot_i + 1) begin
                if (active_slots[slot_i]) begin : attn_slot_blk
                    integer cur_pos;
                    real q_rot [0:HEAD_DIM-1];
                    real k_rot [0:HEAD_DIM-1];
                    real scores [0:MAX_POS-1];
                    real probs [0:MAX_POS-1];
                    real max_score, sum_exp, head_out_r;
                    real freq, angle, cs, sn, x0, x1;
                    integer vis_count;

                    cur_pos = position[slot_i*POS_W +: POS_W];

                    for (head_i = 0; head_i < NUM_HEADS; head_i = head_i + 1) begin
                        // --- RoPE on Q_head and K_head ---
                        for (dim_i = 0; dim_i < HEAD_DIM; dim_i = dim_i + 1) begin
                            q_rot[dim_i] = fp16_to_real(
                                vec_q[(slot_i*HIDDEN_DIM + head_i*HEAD_DIM + dim_i)*DATA_W +: DATA_W]);
                            k_rot[dim_i] = fp16_to_real(
                                vec_k[(slot_i*HIDDEN_DIM + head_i*HEAD_DIM + dim_i)*DATA_W +: DATA_W]);
                        end

                        // Apply RoPE rotation to pairs
                        for (pair_i = 0; pair_i < HEAD_DIM/2; pair_i = pair_i + 1) begin
                            freq = 1.0 / (ROPE_THETA ** (2.0 * $itor(pair_i) / $itor(HEAD_DIM)));
                            angle = $itor(cur_pos) * freq;
                            cs = $cos(angle);
                            sn = $sin(angle);
                            // Q rotation
                            x0 = q_rot[pair_i*2];
                            x1 = q_rot[pair_i*2 + 1];
                            q_rot[pair_i*2]     = x0 * cs - x1 * sn;
                            q_rot[pair_i*2 + 1] = x0 * sn + x1 * cs;
                            // K rotation
                            x0 = k_rot[pair_i*2];
                            x1 = k_rot[pair_i*2 + 1];
                            k_rot[pair_i*2]     = x0 * cs - x1 * sn;
                            k_rot[pair_i*2 + 1] = x0 * sn + x1 * cs;
                        end

                        // --- Store K, V into KV cache ---
                        for (dim_i = 0; dim_i < HEAD_DIM; dim_i = dim_i + 1) begin
                            kv_cache_k[layer_idx][cur_pos][head_i][dim_i] = real_to_fp16(k_rot[dim_i]);
                            kv_cache_v[layer_idx][cur_pos][head_i][dim_i] =
                                vec_v[(slot_i*HIDDEN_DIM + head_i*HEAD_DIM + dim_i)*DATA_W +: DATA_W];
                        end

                        // --- Compute attention scores ---
                        max_score = -65504.0;
                        vis_count = 0;
                        for (pos_i = 0; pos_i < MAX_POS; pos_i = pos_i + 1) begin
                            if (visible_mask[slot_i*MAX_POS + pos_i]) begin
                                scores[pos_i] = 0.0;
                                for (dim_i = 0; dim_i < HEAD_DIM; dim_i = dim_i + 1) begin
                                    scores[pos_i] = scores[pos_i] +
                                        q_rot[dim_i] * fp16_to_real(kv_cache_k[layer_idx][pos_i][head_i][dim_i]);
                                end
                                scores[pos_i] = scores[pos_i] / SQRT_HEAD_DIM;
                                if (scores[pos_i] > max_score)
                                    max_score = scores[pos_i];
                                vis_count = vis_count + 1;
                            end else begin
                                scores[pos_i] = -65504.0;
                            end
                        end

                        // --- Softmax ---
                        sum_exp = 0.0;
                        for (pos_i = 0; pos_i < MAX_POS; pos_i = pos_i + 1) begin
                            if (visible_mask[slot_i*MAX_POS + pos_i]) begin
                                probs[pos_i] = $exp(scores[pos_i] - max_score);
                                sum_exp = sum_exp + probs[pos_i];
                            end else begin
                                probs[pos_i] = 0.0;
                            end
                        end
                        if (sum_exp > 0.0) begin
                            for (pos_i = 0; pos_i < MAX_POS; pos_i = pos_i + 1)
                                probs[pos_i] = probs[pos_i] / sum_exp;
                        end

                        // --- Weighted sum of V ---
                        for (dim_i = 0; dim_i < HEAD_DIM; dim_i = dim_i + 1) begin
                            head_out_r = 0.0;
                            for (pos_i = 0; pos_i < MAX_POS; pos_i = pos_i + 1) begin
                                if (visible_mask[slot_i*MAX_POS + pos_i]) begin
                                    head_out_r = head_out_r +
                                        probs[pos_i] * fp16_to_real(kv_cache_v[layer_idx][pos_i][head_i][dim_i]);
                                end
                            end
                            vec_out[(slot_i*HIDDEN_DIM + head_i*HEAD_DIM + dim_i)*DATA_W +: DATA_W]
                                <= real_to_fp16(head_out_r);
                        end
                    end // head loop
                end // active slot
            end // slot loop
            done <= 1'b1;
        end
    end
end

endmodule
