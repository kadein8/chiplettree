`timescale 1ns/1ps

// pe_mac_unit_wide
// 128-lane FP16 multiply-accumulate unit (16 beats × 8 elements per beat).
//
// Operation:
//   - On `clear`: reset all accumulators to zero.
//   - On each cycle with `mac_valid`:
//       For each of 16 beats (b=0..15):
//         accum[b*8+lane] += vector_val[b] * weight_col[b*8+lane]  (lane 0..7)
//   - After DEPTH valid cycles, `done` pulses for one cycle.
//   - `result` holds the final accumulated values until next `clear`.
//
// This processes 16 SRAM beats per cycle (128 FP16 MACs), matching the paper's
// "128 MAC per PE" specification. Each cycle consumes 16 input vector elements
// and 16×8 weight elements, producing partial sums for 128 output elements.
//
// The 16 vector_val inputs correspond to 16 consecutive elements of the input
// vector (one per beat). Each is broadcast to 8 weight lanes.

module pe_mac_unit_wide #(
    parameter integer LANES_PER_BEAT = 8,
    parameter integer BEATS_PER_CYCLE = 16,
    parameter integer TOTAL_LANES = LANES_PER_BEAT * BEATS_PER_CYCLE,  // 128
    parameter integer DEPTH = 256,   // max input dimension / BEATS_PER_CYCLE
    parameter integer DATA_W = 16,
    parameter integer DEPTH_W = (DEPTH <= 2) ? 1 : $clog2(DEPTH)
) (
    input                                    clk,
    input                                    rst_n,
    input                                    clear,
    input                                    mac_valid,
    // 16 vector values (one per beat, 16 consecutive input elements)
    input      [BEATS_PER_CYCLE*DATA_W-1:0]  vector_val,
    // 16×8 = 128 weight values (16 beats × 8 lanes)
    input      [TOTAL_LANES*DATA_W-1:0]      weight_col,
    input      [DEPTH_W-1:0]                 depth_cfg,
    output reg [TOTAL_LANES*DATA_W-1:0]      result,
    output reg                               done
);

reg [DEPTH_W-1:0] cycle_cnt_r;
wire [DEPTH_W-1:0] actual_depth_w = (depth_cfg == {DEPTH_W{1'b0}}) ?
    DEPTH_W'(DEPTH - 1) : (depth_cfg - {{(DEPTH_W-1){1'b0}}, 1'b1});
wire [TOTAL_LANES*DATA_W-1:0] mul_w;
wire [TOTAL_LANES*DATA_W-1:0] add_w;
reg  [TOTAL_LANES*DATA_W-1:0] accum_r;

// 16 beats × 8 lanes = 128 parallel multiply-accumulate units
genvar b, g;
generate
    for (b = 0; b < BEATS_PER_CYCLE; b = b + 1) begin : gen_beat
        for (g = 0; g < LANES_PER_BEAT; g = g + 1) begin : gen_lane
            localparam integer IDX = b * LANES_PER_BEAT + g;
            floatMult16 u_mult (
                .floatA(vector_val[b*DATA_W +: DATA_W]),
                .floatB(weight_col[IDX*DATA_W +: DATA_W]),
                .product(mul_w[IDX*DATA_W +: DATA_W])
            );
            floatAdd16 u_add (
                .floatA(mul_w[IDX*DATA_W +: DATA_W]),
                .floatB(accum_r[IDX*DATA_W +: DATA_W]),
                .sum(add_w[IDX*DATA_W +: DATA_W])
            );
        end
    end
endgenerate

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        accum_r <= {(TOTAL_LANES*DATA_W){1'b0}};
        result <= {(TOTAL_LANES*DATA_W){1'b0}};
        cycle_cnt_r <= {DEPTH_W{1'b0}};
        done <= 1'b0;
    end else if (clear) begin
        accum_r <= {(TOTAL_LANES*DATA_W){1'b0}};
        cycle_cnt_r <= {DEPTH_W{1'b0}};
        done <= 1'b0;
    end else begin
        done <= 1'b0;
        if (mac_valid) begin
            accum_r <= add_w;
            if (cycle_cnt_r == actual_depth_w) begin
                result <= add_w;
                done <= 1'b1;
                cycle_cnt_r <= {DEPTH_W{1'b0}};
            end else begin
                cycle_cnt_r <= cycle_cnt_r + {{(DEPTH_W-1){1'b0}}, 1'b1};
            end
        end
    end
end

// synthesis translate_off
always @(posedge clk) begin
    if (done)
        $display("[WIDE_MAC] done: result[0:7]=%h %h %h %h %h %h %h %h",
            result[0*DATA_W +: DATA_W], result[1*DATA_W +: DATA_W],
            result[2*DATA_W +: DATA_W], result[3*DATA_W +: DATA_W],
            result[4*DATA_W +: DATA_W], result[5*DATA_W +: DATA_W],
            result[6*DATA_W +: DATA_W], result[7*DATA_W +: DATA_W]);
end
// synthesis translate_on

endmodule
