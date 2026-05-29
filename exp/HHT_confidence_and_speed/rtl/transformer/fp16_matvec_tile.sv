`timescale 1ns/1ps

module fp16_matvec_tile #(
    parameter integer LANES = 16,
    parameter integer COLS = 128,
    parameter integer DATA_WIDTH = 16
) (
    input  logic                          clk,
    input  logic                          rst_n,
    input  logic                          start,
    input  logic [DATA_WIDTH-1:0]         vector_val,
    input  logic [(LANES*DATA_WIDTH)-1:0] weights,
    output logic                          busy,
    output logic                          done,
    output logic [(LANES*DATA_WIDTH)-1:0] result,
    output logic [6:0]                    col_idx
);

logic [(LANES*DATA_WIDTH)-1:0] accum_r;
logic [(LANES*DATA_WIDTH)-1:0] mul_w;
logic [(LANES*DATA_WIDTH)-1:0] add_w;
logic [6:0] col_idx_next_w;
logic active_w;
genvar lane_idx_g;

assign active_w = busy;
assign col_idx_next_w = col_idx + 7'd1;

generate
    for (lane_idx_g = 0; lane_idx_g < LANES; lane_idx_g = lane_idx_g + 1) begin : gen_lane
        floatMult16 u_float_mult16 (
            .floatA(vector_val),
            .floatB(weights[(lane_idx_g*DATA_WIDTH) +: DATA_WIDTH]),
            .product(mul_w[(lane_idx_g*DATA_WIDTH) +: DATA_WIDTH])
        );

        floatAdd16 u_float_add16 (
            .floatA(mul_w[(lane_idx_g*DATA_WIDTH) +: DATA_WIDTH]),
            .floatB(accum_r[(lane_idx_g*DATA_WIDTH) +: DATA_WIDTH]),
            .sum(add_w[(lane_idx_g*DATA_WIDTH) +: DATA_WIDTH])
        );
    end
endgenerate

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        accum_r <= {(LANES*DATA_WIDTH){1'b0}};
        result <= {(LANES*DATA_WIDTH){1'b0}};
        busy <= 1'b0;
        done <= 1'b0;
        col_idx <= 7'd0;
    end else begin
        done <= 1'b0;

        if (start && !busy) begin
            accum_r <= {(LANES*DATA_WIDTH){1'b0}};
            result <= {(LANES*DATA_WIDTH){1'b0}};
            busy <= 1'b1;
            col_idx <= 7'd0;
        end else if (active_w) begin
            accum_r <= add_w;
            if (col_idx == (COLS-1)) begin
                result <= add_w;
                busy <= 1'b0;
                done <= 1'b1;
                col_idx <= col_idx;
            end else begin
                col_idx <= col_idx_next_w;
            end
        end
    end
end

endmodule
