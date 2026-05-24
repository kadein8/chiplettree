`timescale 1ns/1ps

// pe_mac_unit
// 8-lane FP16 multiply-accumulate unit for one PE cell in the paper mesh.
//
// Operation:
//   - On `clear`: reset all accumulators to zero.
//   - On each cycle with `mac_valid`:
//       accum[lane] += vector_val * weight_col[lane]   (for lane 0..7)
//   - After DEPTH valid cycles, `done` pulses for one cycle.
//   - `result` holds the final accumulated values until next `clear`.
//
// Matches SRAM beat width: 128 bits = 8 × FP16.
// 16 of these units (one per mesh cell) produce 16×8 = 128 output elements
// per mesh pass, covering the full d_model=128 for the toy profile.

module pe_mac_unit #(
    parameter integer LANES = 8,
    parameter integer DEPTH = 256,
    parameter integer DATA_W = 16,
    parameter integer DEPTH_W = (DEPTH <= 2) ? 1 : $clog2(DEPTH)
) (
    input                          clk,
    input                          rst_n,
    input                          clear,
    input                          mac_valid,
    input      [DATA_W-1:0]        vector_val,
    input      [LANES*DATA_W-1:0]  weight_col,
    input      [DEPTH_W-1:0]       depth_cfg,  // runtime depth (0 = use DEPTH)
    output reg [LANES*DATA_W-1:0]  result,
    output reg                     done
);

reg [DEPTH_W-1:0] cycle_cnt_r;
wire [DEPTH_W-1:0] actual_depth_w = (depth_cfg == {DEPTH_W{1'b0}}) ?
    DEPTH_W'(DEPTH - 1) : (depth_cfg - {{(DEPTH_W-1){1'b0}}, 1'b1});
wire [LANES*DATA_W-1:0] mul_w;
wire [LANES*DATA_W-1:0] add_w;
reg  [LANES*DATA_W-1:0] accum_r;

// 8 parallel multiply-accumulate lanes
genvar g;
generate
    for (g = 0; g < LANES; g = g + 1) begin : gen_mac_lane
        floatMult16 u_mult (
            .floatA(vector_val),
            .floatB(weight_col[g*DATA_W +: DATA_W]),
            .product(mul_w[g*DATA_W +: DATA_W])
        );
        floatAdd16 u_add (
            .floatA(mul_w[g*DATA_W +: DATA_W]),
            .floatB(accum_r[g*DATA_W +: DATA_W]),
            .sum(add_w[g*DATA_W +: DATA_W])
        );
    end
endgenerate

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        accum_r <= {(LANES*DATA_W){1'b0}};
        result <= {(LANES*DATA_W){1'b0}};
        cycle_cnt_r <= {DEPTH_W{1'b0}};
        done <= 1'b0;
    end else if (clear) begin
        accum_r <= {(LANES*DATA_W){1'b0}};
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

endmodule
