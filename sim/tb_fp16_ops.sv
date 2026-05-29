`timescale 1ns/1ps
module tb_fp16_ops;

reg [15:0] a, b;
wire [15:0] prod, sum_out;

floatMult16 u_mul(.floatA(a), .floatB(b), .product(prod));
floatAdd16 u_add(.floatA(a), .floatB(b), .sum(sum_out));

initial begin
    // Test cases: a * b and a + b
    // 1.5 * 2.0 = 3.0
    a = 16'h3e00; b = 16'h4000; #10;
    $display("MUL: %h * %h = %h (expect 4200)", a, b, prod);
    $display("ADD: %h + %h = %h (expect 41c0)", a, b, sum_out);

    // 0.5 * 0.5 = 0.25
    a = 16'h3800; b = 16'h3800; #10;
    $display("MUL: %h * %h = %h (expect 3400)", a, b, prod);

    // -1.0 + 0.5 = -0.5
    a = 16'hbc00; b = 16'h3800; #10;
    $display("ADD: %h + %h = %h (expect b800)", a, b, sum_out);

    // 1.001 * 1.5 = 1.5015 -> fp16 = ?
    a = 16'h3c01; b = 16'h3e00; #10;
    $display("MUL: %h * %h = %h", a, b, prod);

    // Large + small: 1024 + 0.001
    a = 16'h6400; b = 16'h0418; #10;
    $display("ADD: %h + %h = %h (expect 6400)", a, b, sum_out);

    $finish;
end
endmodule
