`timescale 1ns/1ps

module fp16_inv_sqrt_nr #(
    parameter integer DATA_WIDTH = 16,
    parameter integer ITERATIONS = 4
) (
    input  logic                  clk,
    input  logic                  rst_n,
    input  logic                  start,
    input  logic [DATA_WIDTH-1:0] value,
    output logic                  busy,
    output logic                  done,
    output logic [DATA_WIDTH-1:0] result
);

localparam logic [DATA_WIDTH-1:0] FP_ZERO      = 16'h0000;
localparam logic [DATA_WIDTH-1:0] FP_HALF      = 16'h3800;
localparam logic [DATA_WIDTH-1:0] FP_ONE       = 16'h3c00;
localparam logic [DATA_WIDTH-1:0] FP_ONE_HALF  = 16'h3e00;
localparam logic [4:0] FP16_EXP_INF = 5'h1f;
localparam integer SIM_LATENCY = ITERATIONS;

function automatic [DATA_WIDTH-1:0] fp16_abs;
    input [DATA_WIDTH-1:0] value;
    begin
        fp16_abs = {1'b0, value[DATA_WIDTH-2:0]};
    end
endfunction

logic [DATA_WIDTH-1:0] value_r;
logic [DATA_WIDTH-1:0] y_r;
logic [1:0] iter_r;

logic [DATA_WIDTH-1:0] y_sq_w;
logic [DATA_WIDTH-1:0] xy_sq_w;
logic [DATA_WIDTH-1:0] half_xy_sq_w;
logic [DATA_WIDTH-1:0] correction_w;
logic [DATA_WIDTH-1:0] next_y_w;
logic [DATA_WIDTH-1:0] neg_half_xy_sq_w;
logic [DATA_WIDTH-1:0] next_y_abs_w;

assign neg_half_xy_sq_w = {1'b1, half_xy_sq_w[DATA_WIDTH-2:0]};
assign next_y_abs_w = fp16_abs(next_y_w);

`ifdef SYNTHESIS

floatMult16 u_mul_y_sq (
    .floatA(y_r),
    .floatB(y_r),
    .product(y_sq_w)
);

floatMult16 u_mul_xy_sq (
    .floatA(value_r),
    .floatB(y_sq_w),
    .product(xy_sq_w)
);

floatMult16 u_mul_half (
    .floatA(xy_sq_w),
    .floatB(FP_HALF),
    .product(half_xy_sq_w)
);

floatAdd16 u_add_correction (
    .floatA(FP_ONE_HALF),
    .floatB(neg_half_xy_sq_w),
    .sum(correction_w)
);

floatMult16 u_mul_next_y (
    .floatA(y_r),
    .floatB(correction_w),
    .product(next_y_w)
);

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        value_r <= FP_ZERO;
        y_r <= FP_ONE;
        iter_r <= 2'd0;
        busy <= 1'b0;
        done <= 1'b0;
        result <= FP_ZERO;
    end else begin
        done <= 1'b0;

        if (start && !busy) begin
            value_r <= (value == FP_ZERO) ? FP_ONE : value;
            y_r <= FP_ONE;
            iter_r <= 2'd0;
            busy <= 1'b1;
            result <= FP_ZERO;
        end else if (busy) begin
            y_r <= next_y_abs_w;
            if (iter_r == (ITERATIONS-1)) begin
                busy <= 1'b0;
                done <= 1'b1;
                result <= next_y_abs_w;
            end else begin
                iter_r <= iter_r + 2'd1;
            end
        end
end
end

`else
logic [DATA_WIDTH-1:0] value_r_sim;
logic [$clog2(SIM_LATENCY+1)-1:0] cycle_count_r;

function automatic real fp16_to_real;
    input [15:0] bits;
    integer sign_v;
    integer exp_v;
    integer man_v;
    real frac_v;
    integer shift_v;
    begin
        sign_v = bits[15] ? -1 : 1;
        exp_v = bits[14:10];
        man_v = bits[9:0];
        if ((exp_v == 0) && (man_v == 0)) begin
            fp16_to_real = 0.0;
        end else if (exp_v == 0) begin
            frac_v = man_v;
            for (shift_v = 0; shift_v < 10; shift_v = shift_v + 1)
                frac_v = frac_v / 2.0;
            fp16_to_real = sign_v * frac_v * (2.0 ** (-14));
        end else if (exp_v == FP16_EXP_INF) begin
            if (man_v == 0)
                fp16_to_real = sign_v * 1.0e30;
            else
                fp16_to_real = 0.0;
        end else begin
            frac_v = 1.0 + (man_v / (2.0 ** 10));
            fp16_to_real = sign_v * frac_v * (2.0 ** (exp_v - 15));
        end
    end
endfunction

function automatic [15:0] real_to_fp16;
    input real value;
    integer sign_v;
    real abs_v;
    integer exp_v;
    integer biased_exp_v;
    real norm_v;
    integer man_v;
    integer rounded_v;
    begin
        if (!(value < 0.0 || value >= 0.0)) begin
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

                if ((exp_v + 15) >= 31) begin
                    real_to_fp16 = {sign_v[0], FP16_EXP_INF, 10'd0};
                end else if ((exp_v + 15) <= 0) begin
                    norm_v = abs_v / (2.0 ** (-14));
                    rounded_v = $rtoi(norm_v * (2.0 ** 10) + 0.5);
                    if (rounded_v <= 0)
                        real_to_fp16 = 16'h0000;
                    else if (rounded_v >= (1 << 10))
                        real_to_fp16 = {sign_v[0], 5'd1, 10'd0};
                    else
                        real_to_fp16 = {sign_v[0], 5'd0, rounded_v[9:0]};
                end else begin
                    man_v = $rtoi((norm_v - 1.0) * (2.0 ** 10) + 0.5);
                    if (man_v == (1 << 10)) begin
                        man_v = 0;
                        exp_v = exp_v + 1;
                    end
                    biased_exp_v = exp_v + 15;
                    if (biased_exp_v >= 31)
                        real_to_fp16 = {sign_v[0], FP16_EXP_INF, 10'd0};
                    else
                        real_to_fp16 = {sign_v[0], biased_exp_v[4:0], man_v[9:0]};
                end
            end
        end
    end
endfunction

function automatic [DATA_WIDTH-1:0] compute_inv_sqrt_bits;
    input [DATA_WIDTH-1:0] in_bits;
    real in_real;
    real out_real;
    begin
        in_real = fp16_to_real(in_bits[15:0]);
        if (in_real <= 0.0)
            compute_inv_sqrt_bits = FP_ZERO;
        else begin
            out_real = 1.0 / $sqrt(in_real);
            compute_inv_sqrt_bits = real_to_fp16(out_real);
        end
    end
endfunction

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        value_r_sim <= FP_ZERO;
        cycle_count_r <= {$clog2(SIM_LATENCY+1){1'b0}};
        busy <= 1'b0;
        done <= 1'b0;
        result <= FP_ZERO;
    end else begin
        done <= 1'b0;
        if (start && !busy) begin
            value_r_sim <= (value == FP_ZERO) ? FP_ONE : value;
            cycle_count_r <= 1;
            busy <= 1'b1;
            result <= FP_ZERO;
        end else if (busy) begin
            if (cycle_count_r == SIM_LATENCY) begin
                busy <= 1'b0;
                done <= 1'b1;
                result <= compute_inv_sqrt_bits(value_r_sim);
                cycle_count_r <= {$clog2(SIM_LATENCY+1){1'b0}};
            end else begin
                cycle_count_r <= cycle_count_r + 1'b1;
            end
        end
    end
end
`endif

endmodule
