// IEEE 754 FP16 Adder with round-to-nearest-even and proper sticky bits
`timescale 100 ns / 10 ps

module floatAdd16 (floatA, floatB, sum);

input  [15:0] floatA, floatB;
output reg [15:0] sum;

reg        signA, signB, sign_res;
reg [4:0]  expA, expB;
reg signed [6:0] exp_wide;
reg [10:0] fracA, fracB;
// Use 25 bits: 11 fraction + 14 extra (enough for max shift of 13 + GRS)
reg [24:0] wideA, wideB;
reg [25:0] frac_sum;
reg [24:0] frac_abs;
reg [9:0]  mantissa;
reg        guard, round_bit, sticky;
reg [10:0] mant_rounded;
reg [4:0]  shift_amt;
reg [3:0]  norm_shift;
reg [24:0] shifted_out_mask;

always @(*) begin
    if (floatA[14:0] == 15'd0) begin
        sum = floatB;
    end else if (floatB[14:0] == 15'd0) begin
        sum = floatA;
    end else begin
        signA = floatA[15];
        signB = floatB[15];
        expA  = floatA[14:10];
        expB  = floatB[14:10];
        fracA = {1'b1, floatA[9:0]};
        fracB = {1'b1, floatB[9:0]};

        // Wide format: fraction in bits [24:14], GRS space in [13:0]
        wideA = {fracA, 14'd0};
        wideB = {fracB, 14'd0};

        // Align exponents
        if (expA > expB) begin
            shift_amt = expA - expB;
            if (shift_amt >= 5'd25)
                wideB = 25'd0;
            else
                wideB = {fracB, 14'd0} >> shift_amt;
            // Sticky: OR of all bits shifted out
            if (shift_amt >= 5'd25)
                wideB[0] = |{fracB, 14'd0};
            else if (shift_amt > 0)
                wideB[0] = wideB[0] | (|({fracB, 14'd0} << (25 - shift_amt)));
            exp_wide = {2'b0, expA};
        end else if (expB > expA) begin
            shift_amt = expB - expA;
            if (shift_amt >= 5'd25)
                wideA = 25'd0;
            else
                wideA = {fracA, 14'd0} >> shift_amt;
            if (shift_amt >= 5'd25)
                wideA[0] = |{fracA, 14'd0};
            else if (shift_amt > 0)
                wideA[0] = wideA[0] | (|({fracA, 14'd0} << (25 - shift_amt)));
            exp_wide = {2'b0, expB};
        end else begin
            shift_amt = 5'd0;
            exp_wide = {2'b0, expA};
        end

        if (signA == signB) begin
            // Same sign: add
            frac_sum = {1'b0, wideA} + {1'b0, wideB};
            sign_res = signA;
            if (frac_sum[25]) begin
                // Overflow: shift right 1
                sticky    = frac_sum[0] | frac_sum[1] | frac_sum[2];
                round_bit = frac_sum[3];
                guard     = frac_sum[4];
                mantissa  = frac_sum[24:15];
                exp_wide  = exp_wide + 7'd1;
            end else begin
                sticky    = |frac_sum[2:0];
                round_bit = frac_sum[3];
                guard     = frac_sum[3];
                // Normal: leading 1 at bit 24
                guard     = frac_sum[3];
                round_bit = frac_sum[2];
                sticky    = frac_sum[1] | frac_sum[0];
                mantissa  = frac_sum[23:14];
            end
        end else begin
            // Different signs: subtract
            if (wideA >= wideB) begin
                frac_abs = wideA - wideB;
                sign_res = signA;
            end else begin
                frac_abs = wideB - wideA;
                sign_res = signB;
            end

            if (frac_abs == 25'd0) begin
                sum = 16'd0;
            end else begin
                // Normalize
                norm_shift = 4'd0;
                if      (frac_abs[24]) norm_shift = 4'd0;
                else if (frac_abs[23]) norm_shift = 4'd1;
                else if (frac_abs[22]) norm_shift = 4'd2;
                else if (frac_abs[21]) norm_shift = 4'd3;
                else if (frac_abs[20]) norm_shift = 4'd4;
                else if (frac_abs[19]) norm_shift = 4'd5;
                else if (frac_abs[18]) norm_shift = 4'd6;
                else if (frac_abs[17]) norm_shift = 4'd7;
                else if (frac_abs[16]) norm_shift = 4'd8;
                else if (frac_abs[15]) norm_shift = 4'd9;
                else if (frac_abs[14]) norm_shift = 4'd10;
                else if (frac_abs[13]) norm_shift = 4'd11;
                else if (frac_abs[12]) norm_shift = 4'd12;
                else                   norm_shift = 4'd13;

                frac_abs = frac_abs << norm_shift;
                exp_wide = exp_wide - {3'b0, norm_shift};

                mantissa  = frac_abs[23:14];
                guard     = frac_abs[13];
                round_bit = frac_abs[12];
                sticky    = |frac_abs[11:0];
            end
        end

        // Round and assemble (skip if subtraction was zero)
        if (!(signA != signB && wideA == wideB) &&
            !(signA != signB && frac_abs == 25'd0)) begin
            mant_rounded = {1'b0, mantissa};
            if (guard && (round_bit || sticky || mantissa[0])) begin
                mant_rounded = {1'b0, mantissa} + 11'd1;
            end

            if (mant_rounded[10]) begin
                exp_wide = exp_wide + 7'd1;
                mantissa = 10'd0;
            end else begin
                mantissa = mant_rounded[9:0];
            end

            if (exp_wide <= 0) begin
                sum = 16'd0;
            end else if (exp_wide >= 7'd31) begin
                sum = {sign_res, 5'b11111, 10'd0};
            end else begin
                sum = {sign_res, exp_wide[4:0], mantissa};
            end
        end
    end
end

endmodule
