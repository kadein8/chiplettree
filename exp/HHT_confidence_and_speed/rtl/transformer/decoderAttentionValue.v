`timescale 1ns/1ps

module decoderAttentionValue #(
    parameter integer DATA_WIDTH = 16,
    parameter integer VECTOR_DIM = 4
) (
    input                                         clk,
    input                                         rst_n,
    input                                         start_valid,
    output                                        start_ready,
    input      [DATA_WIDTH-1:0]                   score_weight,
    input      [VECTOR_DIM*DATA_WIDTH-1:0]        value_data,
    output                                        context_valid,
    output reg [VECTOR_DIM*DATA_WIDTH-1:0]        context_value
);

localparam [1:0]
    ST_IDLE = 2'd0,
    ST_RUN  = 2'd1,
    ST_HOLD = 2'd2;

reg [1:0] state_r;
wire [VECTOR_DIM*DATA_WIDTH-1:0] scaled_value_w;
genvar lane_idx_g;

assign start_ready = (state_r == ST_IDLE);
assign context_valid = (state_r == ST_HOLD);

generate
    for (lane_idx_g = 0; lane_idx_g < VECTOR_DIM; lane_idx_g = lane_idx_g + 1) begin : gen_value_scale
        floatMult16 u_float_mult16 (
            .floatA(score_weight),
            .floatB(value_data[(lane_idx_g*DATA_WIDTH) +: DATA_WIDTH]),
            .product(scaled_value_w[(lane_idx_g*DATA_WIDTH) +: DATA_WIDTH])
        );
    end
endgenerate

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state_r <= ST_IDLE;
        context_value <= {(VECTOR_DIM*DATA_WIDTH){1'b0}};
    end else begin
        case (state_r)
            ST_IDLE: begin
                if (start_valid) begin
                    state_r <= ST_RUN;
                end
            end

            ST_RUN: begin
                context_value <= scaled_value_w;
                state_r <= ST_HOLD;
            end

            ST_HOLD: begin
                state_r <= ST_IDLE;
            end

            default: begin
                state_r <= ST_IDLE;
                end
        endcase
    end
end

endmodule
