`timescale 1ns/1ps

module fp16_sampler #(
    parameter integer TOP_K_MAX = 128
) (
    input  logic         clk,
    input  logic         rst_n,
    input  logic         start,
    input  logic [31:0]  argmax_token,
    input  logic [15:0]  top_logit,
    input  logic [15:0]  temperature,
    input  logic [6:0]   top_k,
    input  logic [15:0]  top_p,
    input  logic [15:0]  top_k_values [0:TOP_K_MAX-1],
    input  logic [31:0]  top_k_indices [0:TOP_K_MAX-1],
    output logic         busy,
    output logic         done,
    output logic [31:0]  sampled_token
);

localparam logic [3:0]
    ST_IDLE        = 4'd0,
    ST_INV_TEMP    = 4'd1,
    ST_SCALE       = 4'd2,
    ST_FIND_MAX    = 4'd3,
    ST_EXP_SETUP   = 4'd4,
    ST_EXP_WAIT    = 4'd5,
    ST_INV_SUM     = 4'd6,
    ST_NORM        = 4'd7,
    ST_TOPP        = 4'd8,
    ST_SAMPLE_PREP = 4'd9,
    ST_SAMPLE_LOOP = 4'd10,
    ST_HOLD        = 4'd11;

function automatic [6:0] clamp_top_k;
    input [6:0] requested_k;
    begin
        if (requested_k == 7'd0)
            clamp_top_k = 7'd1;
        else if (requested_k > TOP_K_MAX[6:0])
            clamp_top_k = TOP_K_MAX[6:0];
        else
            clamp_top_k = requested_k;
    end
endfunction

function automatic [15:0] fp16_neg;
    input [15:0] value;
    begin
        if (value == 16'h0000)
            fp16_neg = 16'h0000;
        else
            fp16_neg = {~value[15], value[14:0]};
    end
endfunction

function automatic bit fp16_gt;
    input [15:0] a;
    input [15:0] b;
    begin
        if (a == b) begin
            fp16_gt = 1'b0;
        end else if (a[15] != b[15]) begin
            fp16_gt = b[15];
        end else if (!a[15]) begin
            fp16_gt = (a[14:0] > b[14:0]);
        end else begin
            fp16_gt = (a[14:0] < b[14:0]);
        end
    end
endfunction

function automatic bit fp16_ge;
    input [15:0] a;
    input [15:0] b;
    begin
        fp16_ge = (a == b) || fp16_gt(a, b);
    end
endfunction

function automatic [31:0] fp16_prob_to_weight;
    input [15:0] value;
    integer exponent_v;
    integer mantissa_v;
    integer shift_v;
    integer scaled_v;
    begin
        if ((value == 16'h0000) || value[15]) begin
            fp16_prob_to_weight = 32'd0;
        end else begin
            exponent_v = value[14:10] - 15;
            mantissa_v = {1'b1, value[9:0]};
            shift_v = exponent_v + 6;
            if (shift_v >= 0)
                scaled_v = mantissa_v <<< shift_v;
            else
                scaled_v = mantissa_v >>> (-shift_v);

            if (scaled_v < 0)
                scaled_v = 0;
            if (scaled_v > 32'h7fff_ffff)
                scaled_v = 32'h7fff_ffff;

            fp16_prob_to_weight = scaled_v[31:0];
        end
    end
endfunction

logic [3:0] state_r;
logic [6:0] active_k_r;
logic [6:0] elem_idx_r;
logic [6:0] cutoff_idx_r;
logic [31:0] rng_r;
logic [31:0] sampled_token_r;
logic [31:0] sample_cut_r;
logic [31:0] sample_accum_r;
logic [31:0] total_weight_r;
logic [15:0] inv_temp_r;
logic [15:0] max_logit_r;
logic [15:0] delta_r;
logic [15:0] exp_sum_r;
logic [15:0] inv_sum_r;
logic [15:0] cumsum_r;
logic [31:0] candidate_indices_r [0:TOP_K_MAX-1];
logic [15:0] raw_values_r [0:TOP_K_MAX-1];
logic [15:0] scaled_values_r [0:TOP_K_MAX-1];
logic [15:0] exp_values_r [0:TOP_K_MAX-1];
logic [15:0] prob_values_r [0:TOP_K_MAX-1];
logic [15:0] inv_temp_w;
logic inv_temp_ack_w;
logic [15:0] scale_mul_w;
logic [15:0] delta_w;
logic [15:0] exp_out_w;
logic exp_ack_w;
logic [15:0] exp_sum_add_w;
logic [15:0] inv_sum_w;
logic inv_sum_ack_w;
logic [15:0] prob_mul_w;
logic [15:0] cumsum_add_w;

assign sampled_token = sampled_token_r;

floatReciprocal #(
    .DATA_WIDTH(16)
) u_inv_temp (
    .number(temperature),
    .enable(state_r == ST_INV_TEMP),
    .clk(clk),
    .output_rec(inv_temp_w),
    .ack(inv_temp_ack_w)
);

floatMult16 u_scale_mul (
    .floatA(raw_values_r[elem_idx_r]),
    .floatB(inv_temp_r),
    .product(scale_mul_w)
);

floatAdd16 u_delta_add (
    .floatA(scaled_values_r[elem_idx_r]),
    .floatB(fp16_neg(max_logit_r)),
    .sum(delta_w)
);

exponent #(
    .DATA_WIDTH(16)
) u_exp (
    .x(delta_r),
    .clk(clk),
    .enable(state_r == ST_EXP_WAIT),
    .output_exp(exp_out_w),
    .ack(exp_ack_w)
);

floatAdd16 u_exp_sum_add (
    .floatA(exp_sum_r),
    .floatB(exp_out_w),
    .sum(exp_sum_add_w)
);

floatReciprocal #(
    .DATA_WIDTH(16)
) u_inv_sum (
    .number(exp_sum_r),
    .enable(state_r == ST_INV_SUM),
    .clk(clk),
    .output_rec(inv_sum_w),
    .ack(inv_sum_ack_w)
);

floatMult16 u_prob_mul (
    .floatA(exp_values_r[elem_idx_r]),
    .floatB(inv_sum_r),
    .product(prob_mul_w)
);

floatAdd16 u_cumsum_add (
    .floatA(cumsum_r),
    .floatB(prob_values_r[elem_idx_r]),
    .sum(cumsum_add_w)
);

always_ff @(posedge clk or negedge rst_n) begin
    integer copy_idx_i;
    reg [31:0] rng_next_v;
    reg [31:0] weight_v;
    reg [31:0] acc_next_v;
    if (!rst_n) begin
        state_r <= ST_IDLE;
        active_k_r <= 7'd0;
        elem_idx_r <= 7'd0;
        cutoff_idx_r <= 7'd0;
        rng_r <= 32'h1020_3040;
        sampled_token_r <= 32'd0;
        sample_cut_r <= 32'd0;
        sample_accum_r <= 32'd0;
        total_weight_r <= 32'd0;
        inv_temp_r <= 16'h0000;
        max_logit_r <= 16'hfc00;
        delta_r <= 16'h0000;
        exp_sum_r <= 16'h0000;
        inv_sum_r <= 16'h0000;
        cumsum_r <= 16'h0000;
        busy <= 1'b0;
        done <= 1'b0;
        for (copy_idx_i = 0; copy_idx_i < TOP_K_MAX; copy_idx_i = copy_idx_i + 1) begin
            candidate_indices_r[copy_idx_i] <= 32'd0;
            raw_values_r[copy_idx_i] <= 16'h0000;
            scaled_values_r[copy_idx_i] <= 16'h0000;
            exp_values_r[copy_idx_i] <= 16'h0000;
            prob_values_r[copy_idx_i] <= 16'h0000;
        end
    end else begin
        done <= 1'b0;

        case (state_r)
            ST_IDLE: begin
                busy <= 1'b0;
                if (start) begin
                    sampled_token_r <= argmax_token;
                    active_k_r <= clamp_top_k(top_k);
                    elem_idx_r <= 7'd0;
                    cutoff_idx_r <= 7'd0;
                    sample_cut_r <= 32'd0;
                    sample_accum_r <= 32'd0;
                    total_weight_r <= 32'd0;
                    inv_temp_r <= 16'h0000;
                    max_logit_r <= 16'hfc00;
                    delta_r <= 16'h0000;
                    exp_sum_r <= 16'h0000;
                    inv_sum_r <= 16'h0000;
                    cumsum_r <= 16'h0000;
                    busy <= 1'b1;
                    for (copy_idx_i = 0; copy_idx_i < TOP_K_MAX; copy_idx_i = copy_idx_i + 1) begin
                        candidate_indices_r[copy_idx_i] <= top_k_indices[copy_idx_i];
                        raw_values_r[copy_idx_i] <= top_k_values[copy_idx_i];
                        scaled_values_r[copy_idx_i] <= 16'h0000;
                        exp_values_r[copy_idx_i] <= 16'h0000;
                        prob_values_r[copy_idx_i] <= 16'h0000;
                    end

                    if ((temperature == 16'h0000) || (clamp_top_k(top_k) <= 7'd1)) begin
                        state_r <= ST_HOLD;
                    end else begin
                        state_r <= ST_INV_TEMP;
                    end
                end
            end

            ST_INV_TEMP: begin
                if (inv_temp_ack_w) begin
                    inv_temp_r <= inv_temp_w;
                    elem_idx_r <= 7'd0;
                    state_r <= ST_SCALE;
                end
            end

            ST_SCALE: begin
                scaled_values_r[elem_idx_r] <= scale_mul_w;
                if (elem_idx_r == (active_k_r - 1)) begin
                    elem_idx_r <= 7'd0;
                    max_logit_r <= 16'hfc00;
                    state_r <= ST_FIND_MAX;
                end else begin
                    elem_idx_r <= elem_idx_r + 7'd1;
                end
            end

            ST_FIND_MAX: begin
                if (fp16_gt(scaled_values_r[elem_idx_r], max_logit_r))
                    max_logit_r <= scaled_values_r[elem_idx_r];

                if (elem_idx_r == (active_k_r - 1)) begin
                    elem_idx_r <= 7'd0;
                    exp_sum_r <= 16'h0000;
                    state_r <= ST_EXP_SETUP;
                end else begin
                    elem_idx_r <= elem_idx_r + 7'd1;
                end
            end

            ST_EXP_SETUP: begin
                delta_r <= delta_w;
                state_r <= ST_EXP_WAIT;
            end

            ST_EXP_WAIT: begin
                if (exp_ack_w) begin
                    exp_values_r[elem_idx_r] <= exp_out_w;
                    exp_sum_r <= exp_sum_add_w;
                    if (elem_idx_r == (active_k_r - 1)) begin
                        state_r <= ST_INV_SUM;
                    end else begin
                        elem_idx_r <= elem_idx_r + 7'd1;
                        state_r <= ST_EXP_SETUP;
                    end
                end
            end

            ST_INV_SUM: begin
                if (inv_sum_ack_w) begin
                    inv_sum_r <= inv_sum_w;
                    elem_idx_r <= 7'd0;
                    state_r <= ST_NORM;
                end
            end

            ST_NORM: begin
                prob_values_r[elem_idx_r] <= prob_mul_w;
                if (elem_idx_r == (active_k_r - 1)) begin
                    elem_idx_r <= 7'd0;
                    cutoff_idx_r <= active_k_r - 7'd1;
                    cumsum_r <= 16'h0000;
                    state_r <= ST_TOPP;
                end else begin
                    elem_idx_r <= elem_idx_r + 7'd1;
                end
            end

            ST_TOPP: begin
                cumsum_r <= cumsum_add_w;
                if (fp16_ge(cumsum_add_w, top_p) || (elem_idx_r == (active_k_r - 1))) begin
                    cutoff_idx_r <= elem_idx_r;
                    total_weight_r <= fp16_prob_to_weight(cumsum_add_w);
                    elem_idx_r <= 7'd0;
                    state_r <= ST_SAMPLE_PREP;
                end else begin
                    elem_idx_r <= elem_idx_r + 7'd1;
                end
            end

            ST_SAMPLE_PREP: begin
                rng_next_v = (rng_r * 32'h0001_49fb) + 32'h0000_1234;
                rng_r <= rng_next_v;
                sampled_token_r <= argmax_token;
                sample_accum_r <= 32'd0;
                elem_idx_r <= 7'd0;
                if (total_weight_r == 32'd0) begin
                    sample_cut_r <= 32'd0;
                    state_r <= ST_HOLD;
                end else begin
                    sample_cut_r <= rng_next_v % total_weight_r;
                    state_r <= ST_SAMPLE_LOOP;
                end
            end

            ST_SAMPLE_LOOP: begin
                weight_v = fp16_prob_to_weight(prob_values_r[elem_idx_r]);
                acc_next_v = sample_accum_r + weight_v;
                if ((elem_idx_r == cutoff_idx_r) || (acc_next_v > sample_cut_r)) begin
                    sampled_token_r <= candidate_indices_r[elem_idx_r];
                    state_r <= ST_HOLD;
                end else begin
                    sample_accum_r <= acc_next_v;
                    elem_idx_r <= elem_idx_r + 7'd1;
                end
            end

            ST_HOLD: begin
                busy <= 1'b0;
                done <= 1'b1;
                state_r <= ST_IDLE;
            end

            default: begin
                busy <= 1'b0;
                state_r <= ST_IDLE;
            end
        endcase
    end
end

endmodule
