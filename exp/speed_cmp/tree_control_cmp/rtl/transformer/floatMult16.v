// IEEE 754 FP16 Multiplier with round-to-nearest-even
`timescale 100 ns / 10 ps

module floatMult16 (floatA, floatB, product);

input  [15:0] floatA, floatB;
output reg [15:0] product;

reg        sign;
reg signed [6:0] exp_sum;  // wider to detect overflow/underflow
reg [10:0] fracA, fracB;
reg [21:0] frac_full;      // 11x11 = 22 bits
reg [9:0]  mantissa;
reg        guard, round_bit, sticky;
reg [10:0] mant_rounded;

always @(*) begin
    if (floatA[14:0] == 15'd0 || floatB[14:0] == 15'd0) begin
        product = 16'd0;
    end else begin
        sign = floatA[15] ^ floatB[15];
        fracA = {1'b1, floatA[9:0]};
        fracB = {1'b1, floatB[9:0]};
        frac_full = fracA * fracB;  // 22-bit result

        // Product of 1.mA * 1.mB is in [1.0, 4.0)
        // Leading 1 at bit 21 means result in [2.0, 4.0) → need exp+1
        // Leading 1 at bit 20 means result in [1.0, 2.0) → exp unchanged
        if (frac_full[21]) begin
            // Result in [2, 4): mantissa = [20:11], G=bit10, R=bit9, S=|bits[8:0]
            mantissa   = frac_full[20:11];
            guard      = frac_full[10];
            round_bit  = frac_full[9];
            sticky     = |frac_full[8:0];
            exp_sum    = {2'b0, floatA[14:10]} + {2'b0, floatB[14:10]} - 7'd15 + 7'd1;
        end else begin
            // Result in [1, 2): mantissa = [19:10], G=bit9, R=bit8, S=|bits[7:0]
            mantissa   = frac_full[19:10];
            guard      = frac_full[9];
            round_bit  = frac_full[8];
            sticky     = |frac_full[7:0];
            exp_sum    = {2'b0, floatA[14:10]} + {2'b0, floatB[14:10]} - 7'd15;
        end

        // Round to nearest even
        mant_rounded = {1'b0, mantissa};
        if (guard && (round_bit || sticky || mantissa[0])) begin
            mant_rounded = {1'b0, mantissa} + 11'd1;
        end

        // Handle mantissa overflow from rounding
        if (mant_rounded[10]) begin
            exp_sum = exp_sum + 7'd1;
            // mantissa becomes 0 (1.0 after implicit bit)
            mantissa = 10'd0;
        end else begin
            mantissa = mant_rounded[9:0];
        end

        // Assemble result
        if (exp_sum <= 0) begin
            product = 16'd0;  // underflow to zero
        end else if (exp_sum >= 7'd31) begin
            product = {sign, 5'b11111, 10'd0};  // overflow to infinity
        end else begin
            product = {sign, exp_sum[4:0], mantissa};
        end
    end
end

endmodule
