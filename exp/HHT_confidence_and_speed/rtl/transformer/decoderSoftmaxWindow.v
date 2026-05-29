`timescale 1ns/1ps

`include "transformer/floatAdd.v"
`include "transformer/floatMult.v"
`include "transformer/exponent.v"
`include "transformer/floatReciprocal.v"

module decoderSoftmaxWindow #(
    parameter integer DATA_WIDTH = 16,
    parameter integer WINDOW_SLOTS = 1
) (
    input                                    clk,
    input                                    rst_n,
    input                                    start_valid,
    output                                   start_ready,
    input      [WINDOW_SLOTS*DATA_WIDTH-1:0] score_vector,
    output                                   weight_valid,
    output reg [WINDOW_SLOTS*DATA_WIDTH-1:0] weight_vector
);

localparam integer SLOT_COUNT = (WINDOW_SLOTS <= 0) ? 1 : WINDOW_SLOTS;
localparam [1:0]
    ST_IDLE       = 2'd0,
    ST_WAIT_EXP   = 2'd1,
    ST_WAIT_RECIP = 2'd2,
    ST_HOLD       = 2'd3;

localparam [DATA_WIDTH-1:0] FP_ZERO = {DATA_WIDTH{1'b0}};
localparam [DATA_WIDTH-1:0] FP_ONE =
    (DATA_WIDTH == 32) ? 32'h3f80_0000 : 16'h3c00;
reg [1:0] state_r;
reg [WINDOW_SLOTS*DATA_WIDTH-1:0] score_vector_r;
reg [WINDOW_SLOTS*DATA_WIDTH-1:0] exponent_vector_r;

wire [WINDOW_SLOTS-1:0] exp_ack_w;
wire [WINDOW_SLOTS*DATA_WIDTH-1:0] exp_input_vector_w;
wire [WINDOW_SLOTS*DATA_WIDTH-1:0] exponent_vector_w;
wire [DATA_WIDTH-1:0] exp_sum_chain_w [0:SLOT_COUNT];
wire [DATA_WIDTH-1:0] reciprocal_value_w;
wire reciprocal_ack_w;
wire [WINDOW_SLOTS*DATA_WIDTH-1:0] normalized_vector_w;
wire all_exp_ack_w;
wire exp_enable_w;
wire recip_enable_w;
genvar slot_idx_g;
genvar sum_idx_g;
genvar norm_idx_g;

assign start_ready = (state_r == ST_IDLE);
assign weight_valid = (state_r == ST_HOLD);
assign all_exp_ack_w = &exp_ack_w;
assign exp_sum_chain_w[0] = FP_ZERO;
assign exp_input_vector_w =
    ((state_r == ST_IDLE) && start_valid) ? score_vector : score_vector_r;
assign exp_enable_w =
    (SLOT_COUNT > 1) &&
    (((state_r == ST_IDLE) && start_valid) || (state_r == ST_WAIT_EXP));
assign recip_enable_w = (SLOT_COUNT > 1) && (state_r == ST_WAIT_RECIP);

generate
    for (slot_idx_g = 0; slot_idx_g < SLOT_COUNT; slot_idx_g = slot_idx_g + 1) begin : gen_exp
        exponent #(
            .DATA_WIDTH(DATA_WIDTH)
        ) u_exponent (
            .x(exp_input_vector_w[(slot_idx_g*DATA_WIDTH) +: DATA_WIDTH]),
            .clk(clk),
            .enable(exp_enable_w),
            .output_exp(exponent_vector_w[(slot_idx_g*DATA_WIDTH) +: DATA_WIDTH]),
            .ack(exp_ack_w[slot_idx_g])
        );
    end
endgenerate

generate
    for (sum_idx_g = 0; sum_idx_g < SLOT_COUNT; sum_idx_g = sum_idx_g + 1) begin : gen_sum
        if (DATA_WIDTH == 32) begin : gen_sum_fp32
            floatAdd u_float_add (
                .floatA(exponent_vector_r[(sum_idx_g*DATA_WIDTH) +: DATA_WIDTH]),
                .floatB(exp_sum_chain_w[sum_idx_g]),
                .sum(exp_sum_chain_w[sum_idx_g + 1])
            );
        end else begin : gen_sum_fp16
            floatAdd16 u_float_add16 (
                .floatA(exponent_vector_r[(sum_idx_g*DATA_WIDTH) +: DATA_WIDTH]),
                .floatB(exp_sum_chain_w[sum_idx_g]),
                .sum(exp_sum_chain_w[sum_idx_g + 1])
            );
        end
    end
endgenerate

floatReciprocal #(
    .DATA_WIDTH(DATA_WIDTH)
) u_float_reciprocal (
    .number(exp_sum_chain_w[SLOT_COUNT]),
    .enable(recip_enable_w),
    .clk(clk),
    .output_rec(reciprocal_value_w),
    .ack(reciprocal_ack_w)
);

generate
    for (norm_idx_g = 0; norm_idx_g < SLOT_COUNT; norm_idx_g = norm_idx_g + 1) begin : gen_norm
        if (DATA_WIDTH == 32) begin : gen_norm_fp32
            floatMult u_float_mult (
                .floatA(exponent_vector_r[(norm_idx_g*DATA_WIDTH) +: DATA_WIDTH]),
                .floatB(reciprocal_value_w),
                .product(normalized_vector_w[(norm_idx_g*DATA_WIDTH) +: DATA_WIDTH])
            );
        end else begin : gen_norm_fp16
            floatMult16 u_float_mult16 (
                .floatA(exponent_vector_r[(norm_idx_g*DATA_WIDTH) +: DATA_WIDTH]),
                .floatB(reciprocal_value_w),
                .product(normalized_vector_w[(norm_idx_g*DATA_WIDTH) +: DATA_WIDTH])
            );
        end
    end
endgenerate

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state_r <= ST_IDLE;
        score_vector_r <= {(WINDOW_SLOTS*DATA_WIDTH){1'b0}};
        exponent_vector_r <= {(WINDOW_SLOTS*DATA_WIDTH){1'b0}};
        weight_vector <= {(WINDOW_SLOTS*DATA_WIDTH){1'b0}};
    end else begin
        case (state_r)
            ST_IDLE: begin
                if (start_valid) begin
                    score_vector_r <= score_vector;
                    if (SLOT_COUNT == 1) begin
                        weight_vector <= FP_ONE;
                        state_r <= ST_HOLD;
                    end else begin
                        state_r <= ST_WAIT_EXP;
                    end
                end
            end

            ST_WAIT_EXP: begin
                if (all_exp_ack_w) begin
                    exponent_vector_r <= exponent_vector_w;
                    state_r <= ST_WAIT_RECIP;
                end
            end

            ST_WAIT_RECIP: begin
                if (reciprocal_ack_w) begin
                    weight_vector <= normalized_vector_w;
                    state_r <= ST_HOLD;
                end
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
