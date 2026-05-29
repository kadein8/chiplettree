`include "config/model_params.vh"
`timescale 1ns/1ps

module fp16_rope #(
    parameter integer DATA_WIDTH = `FP16_TILE_DATA_W,
    parameter integer HEAD_DIM = `QWEN3_HEAD_DIM,
    parameter integer PARALLEL_PAIRS = 8
) (
    input  logic                               clk,
    input  logic                               rst_n,
    input  logic                               start_valid,
    output logic                               start_ready,
    input  logic [15:0]                        position,
    input  logic [(HEAD_DIM*DATA_WIDTH)-1:0]   head_vector,
    output logic                               rotated_valid,
    output logic [(HEAD_DIM*DATA_WIDTH)-1:0]   rotated_vector
);

localparam integer PAIR_COUNT = HEAD_DIM / 2;
localparam integer LUT_SIZE = 1024;
localparam real PI_REAL = 3.14159265358979323846;
localparam real TWO_PI_REAL = 6.28318530717958647692;
localparam real ROPE_THETA_REAL = `QWEN3_ROPE_THETA;
localparam logic [1:0]
    ST_IDLE = 2'd0,
    ST_RUN  = 2'd1,
    ST_HOLD = 2'd2;

function automatic [9:0] lut_index_from_phase;
    input [47:0] phase_q16;
    begin
        lut_index_from_phase = phase_q16[25:16] & 10'h3ff;
    end
endfunction

function automatic [31:0] real_to_q16_16;
    input real value;
    integer scaled_v;
    begin
        if (value <= 0.0) begin
            real_to_q16_16 = 32'd0;
        end else begin
            scaled_v = $rtoi((value * 65536.0) + 0.5);
            if (scaled_v < 0)
                real_to_q16_16 = 32'd0;
            else
                real_to_q16_16 = scaled_v[31:0];
        end
    end
endfunction

function automatic [15:0] real_to_fp16;
    input real value;
    integer sign_v;
    integer exp_v;
    integer biased_exp_v;
    real abs_v;
    real norm_v;
    real frac_v;
    integer man_v;
    integer rounded_v;
    begin
        if (value !== value) begin
            real_to_fp16 = 16'h7e00;
        end else begin
            sign_v = (value < 0.0) ? 1 : 0;
            abs_v = sign_v ? -value : value;

            if (abs_v == 0.0) begin
                real_to_fp16 = 16'h0000;
            end else begin
                exp_v = 0;
                norm_v = abs_v;

                while (norm_v >= 2.0) begin
                    norm_v = norm_v / 2.0;
                    exp_v = exp_v + 1;
                end

                while (norm_v < 1.0) begin
                    norm_v = norm_v * 2.0;
                    exp_v = exp_v - 1;
                end

                frac_v = norm_v - 1.0;
                biased_exp_v = exp_v + 15;

                if (biased_exp_v >= 31) begin
                    real_to_fp16 = {sign_v[0], 5'h1f, 10'd0};
                end else if (biased_exp_v <= 0) begin
                    frac_v = abs_v / (2.0 ** (-14));
                    man_v = $rtoi(frac_v * 1024.0);
                    rounded_v = man_v;

                    if (rounded_v <= 0) begin
                        real_to_fp16 = 16'h0000;
                    end else if (rounded_v >= 1024) begin
                        real_to_fp16 = {sign_v[0], 5'd1, 10'd0};
                    end else begin
                        real_to_fp16 = {sign_v[0], 5'd0, rounded_v[9:0]};
                    end
                end else begin
                    man_v = $rtoi(frac_v * 1024.0);
                    rounded_v = man_v;

                    if (rounded_v == 1024) begin
                        rounded_v = 0;
                        biased_exp_v = biased_exp_v + 1;
                    end

                    if (biased_exp_v >= 31)
                        real_to_fp16 = {sign_v[0], 5'h1f, 10'd0};
                    else
                        real_to_fp16 = {sign_v[0], biased_exp_v[4:0], rounded_v[9:0]};
                end
            end
        end
    end
endfunction

logic [1:0] state_r;
logic [15:0] position_r;
logic [(HEAD_DIM*DATA_WIDTH)-1:0] head_vector_r;
logic [(HEAD_DIM*DATA_WIDTH)-1:0] rotated_vector_r;
logic [6:0] pair_base_r;

logic [31:0] freq_table_q16 [0:PAIR_COUNT-1];
logic [DATA_WIDTH-1:0] cos_table [0:LUT_SIZE-1];
logic [DATA_WIDTH-1:0] sin_table [0:LUT_SIZE-1];

logic [DATA_WIDTH-1:0] x0_w [0:PARALLEL_PAIRS-1];
logic [DATA_WIDTH-1:0] x1_w [0:PARALLEL_PAIRS-1];
logic [6:0] pair_idx_w [0:PARALLEL_PAIRS-1];
logic [31:0] freq_q16_w [0:PARALLEL_PAIRS-1];
logic [47:0] phase_q16_w [0:PARALLEL_PAIRS-1];
logic [9:0] lut_idx_w [0:PARALLEL_PAIRS-1];
logic [DATA_WIDTH-1:0] cos_w [0:PARALLEL_PAIRS-1];
logic [DATA_WIDTH-1:0] sin_w [0:PARALLEL_PAIRS-1];
logic [DATA_WIDTH-1:0] x0_cos_w [0:PARALLEL_PAIRS-1];
logic [DATA_WIDTH-1:0] x1_sin_w [0:PARALLEL_PAIRS-1];
logic [DATA_WIDTH-1:0] x0_sin_w [0:PARALLEL_PAIRS-1];
logic [DATA_WIDTH-1:0] x1_cos_w [0:PARALLEL_PAIRS-1];
logic [DATA_WIDTH-1:0] rot0_w [0:PARALLEL_PAIRS-1];
logic [DATA_WIDTH-1:0] rot1_w [0:PARALLEL_PAIRS-1];
logic [DATA_WIDTH-1:0] neg_x1_sin_w [0:PARALLEL_PAIRS-1];

integer pair_idx_i;
integer init_idx_i;
genvar pair_g;
real angle_real;
real freq_real;
real phase_step_real;

assign start_ready = (state_r == ST_IDLE);
assign rotated_valid = (state_r == ST_HOLD);
assign rotated_vector = rotated_vector_r;

initial begin
    for (init_idx_i = 0; init_idx_i < PAIR_COUNT; init_idx_i = init_idx_i + 1)
        freq_table_q16[init_idx_i] = 32'd0;
    for (init_idx_i = 0; init_idx_i < LUT_SIZE; init_idx_i = init_idx_i + 1) begin
        cos_table[init_idx_i] = {DATA_WIDTH{1'b0}};
        sin_table[init_idx_i] = {DATA_WIDTH{1'b0}};
    end
    for (init_idx_i = 0; init_idx_i < LUT_SIZE; init_idx_i = init_idx_i + 1) begin
        angle_real = (TWO_PI_REAL * init_idx_i) / LUT_SIZE;
        cos_table[init_idx_i] = real_to_fp16($cos(angle_real));
        sin_table[init_idx_i] = real_to_fp16($sin(angle_real));
    end
    for (init_idx_i = 0; init_idx_i < PAIR_COUNT; init_idx_i = init_idx_i + 1) begin
        freq_real = $exp(-((2.0 * init_idx_i) / (1.0 * HEAD_DIM)) * $ln(ROPE_THETA_REAL));
        phase_step_real = freq_real * LUT_SIZE / TWO_PI_REAL;
        freq_table_q16[init_idx_i] = real_to_q16_16(phase_step_real);
    end
end

generate
    for (pair_g = 0; pair_g < PARALLEL_PAIRS; pair_g = pair_g + 1) begin : gen_rope_pair
        assign pair_idx_w[pair_g] = pair_base_r + pair_g;
        assign x0_w[pair_g] =
            head_vector_r[((pair_idx_w[pair_g] * 2) * DATA_WIDTH) +: DATA_WIDTH];
        assign x1_w[pair_g] =
            head_vector_r[(((pair_idx_w[pair_g] * 2) + 1) * DATA_WIDTH) +: DATA_WIDTH];
        assign freq_q16_w[pair_g] = (pair_idx_w[pair_g] < PAIR_COUNT) ? freq_table_q16[pair_idx_w[pair_g]] : 32'd0;
        assign phase_q16_w[pair_g] = position_r * freq_q16_w[pair_g];
        assign lut_idx_w[pair_g] = lut_index_from_phase(phase_q16_w[pair_g]);
        assign cos_w[pair_g] = cos_table[lut_idx_w[pair_g]];
        assign sin_w[pair_g] = sin_table[lut_idx_w[pair_g]];
        assign neg_x1_sin_w[pair_g] =
            (x1_sin_w[pair_g] == 16'h0000) ? 16'h0000 :
            {~x1_sin_w[pair_g][15], x1_sin_w[pair_g][14:0]};

        floatMult16 u_mul_x0_cos (
            .floatA(x0_w[pair_g]),
            .floatB(cos_w[pair_g]),
            .product(x0_cos_w[pair_g])
        );

        floatMult16 u_mul_x1_sin (
            .floatA(x1_w[pair_g]),
            .floatB(sin_w[pair_g]),
            .product(x1_sin_w[pair_g])
        );

        floatMult16 u_mul_x0_sin (
            .floatA(x0_w[pair_g]),
            .floatB(sin_w[pair_g]),
            .product(x0_sin_w[pair_g])
        );

        floatMult16 u_mul_x1_cos (
            .floatA(x1_w[pair_g]),
            .floatB(cos_w[pair_g]),
            .product(x1_cos_w[pair_g])
        );

        floatAdd16 u_add_rot0 (
            .floatA(x0_cos_w[pair_g]),
            .floatB(neg_x1_sin_w[pair_g]),
            .sum(rot0_w[pair_g])
        );

        floatAdd16 u_add_rot1 (
            .floatA(x0_sin_w[pair_g]),
            .floatB(x1_cos_w[pair_g]),
            .sum(rot1_w[pair_g])
        );
    end
endgenerate

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state_r <= ST_IDLE;
        position_r <= 16'd0;
        head_vector_r <= {(HEAD_DIM*DATA_WIDTH){1'b0}};
        rotated_vector_r <= {(HEAD_DIM*DATA_WIDTH){1'b0}};
        pair_base_r <= 7'd0;
    end else begin
        case (state_r)
            ST_IDLE: begin
                if (start_valid) begin
                    position_r <= position;
                    head_vector_r <= head_vector;
                    rotated_vector_r <= head_vector;
                    pair_base_r <= 7'd0;
                    state_r <= ST_RUN;
                end
            end

            ST_RUN: begin
                for (pair_idx_i = 0; pair_idx_i < PARALLEL_PAIRS; pair_idx_i = pair_idx_i + 1) begin
                    if ((pair_base_r + pair_idx_i) < PAIR_COUNT) begin
                        rotated_vector_r[(((pair_base_r + pair_idx_i) * 2) * DATA_WIDTH) +: DATA_WIDTH] <= rot0_w[pair_idx_i];
                        rotated_vector_r[((((pair_base_r + pair_idx_i) * 2) + 1) * DATA_WIDTH) +: DATA_WIDTH] <= rot1_w[pair_idx_i];
                    end
                end

                if ((pair_base_r + PARALLEL_PAIRS) >= PAIR_COUNT) begin
                    state_r <= ST_HOLD;
                end else begin
                    pair_base_r <= pair_base_r + PARALLEL_PAIRS;
                end
            end

            ST_HOLD: begin
                state_r <= ST_IDLE;
            end

            default: state_r <= ST_IDLE;
        endcase
    end
end

endmodule
