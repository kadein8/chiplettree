`timescale 1ns/1ps

module tb_fp16_sampler;

localparam integer TOP_K_MAX = 16;
localparam [15:0] FP_ONE = 16'h3c00;
localparam [15:0] FP_HALF = 16'h3800;
localparam [15:0] FP_TWO = 16'h4000;
localparam [15:0] FP_QUARTER = 16'h3400;
localparam [15:0] FP_ZERO = 16'h0000;

logic clk;
logic rst_n;
logic start;
logic [31:0] argmax_token;
logic [15:0] top_logit;
logic [15:0] temperature;
logic [6:0] top_k;
logic [15:0] top_p;
logic [15:0] top_k_values [0:TOP_K_MAX-1];
logic [31:0] top_k_indices [0:TOP_K_MAX-1];
logic busy;
logic done;
logic [31:0] sampled_token;

integer idx_i;

task automatic load_equal_candidates;
    input [31:0] base_token;
    input integer candidate_count;
    begin
        for (idx_i = 0; idx_i < TOP_K_MAX; idx_i = idx_i + 1) begin
            top_k_values[idx_i] = FP_ONE;
            top_k_indices[idx_i] = base_token + idx_i;
        end
        argmax_token = base_token;
        top_k_indices[0] = argmax_token;
        top_k = candidate_count[6:0];
    end
endtask

task automatic load_descending_candidates;
    begin
        top_k_values[0] = FP_TWO;
        top_k_values[1] = FP_ONE;
        top_k_values[2] = FP_HALF;
        top_k_values[3] = FP_QUARTER;
        for (idx_i = 4; idx_i < TOP_K_MAX; idx_i = idx_i + 1)
            top_k_values[idx_i] = FP_ZERO;

        for (idx_i = 0; idx_i < TOP_K_MAX; idx_i = idx_i + 1)
            top_k_indices[idx_i] = 32'd200 + idx_i;

        argmax_token = 32'd200;
    end
endtask

fp16_sampler #(
    .TOP_K_MAX(TOP_K_MAX)
) u_dut (
    .clk(clk),
    .rst_n(rst_n),
    .start(start),
    .argmax_token(argmax_token),
    .top_logit(top_logit),
    .temperature(temperature),
    .top_k(top_k),
    .top_p(top_p),
    .top_k_values(top_k_values),
    .top_k_indices(top_k_indices),
    .busy(busy),
    .done(done),
    .sampled_token(sampled_token)
);

always #5 clk = ~clk;

task automatic kick;
    begin
        @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;
        wait (done);
        @(posedge clk);
    end
endtask

initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    start = 1'b0;
    argmax_token = 32'd3;
    top_logit = FP_ONE;
    temperature = FP_ONE;
    top_k = 7'd1;
    top_p = FP_ONE;
    load_equal_candidates(32'd100, 10);
    repeat (3) @(posedge clk);
    rst_n = 1'b1;

    top_k = 7'd1;
    kick();
    if (sampled_token !== argmax_token)
        $fatal(1, "top_k=1 should fall back to argmax");

    top_k = 7'd0;
    kick();
    if (sampled_token !== argmax_token)
        $fatal(1, "top_k=0 should default to greedy argmax");

    temperature = FP_ONE;
    top_p = FP_ONE;
    load_equal_candidates(32'd100, 10);
    top_k = 7'd10;
    kick();
    if ((sampled_token < 32'd100) || (sampled_token > 32'd109))
        $fatal(1, "sampled token must stay inside the top-k candidate set");

    temperature = FP_ONE;
    top_p = FP_HALF;
    top_k = 7'd4;
    load_descending_candidates();
    kick();
    if (sampled_token >= 32'd202)
        $fatal(1, "top_p=0.5 should truncate to the leading candidates");

    temperature = FP_HALF;
    top_p = FP_QUARTER;
    top_k = 7'd4;
    load_descending_candidates();
    kick();
    if (sampled_token !== 32'd200)
        $fatal(1, "low temperature with tight top_p should collapse to top-1");

    $display("tb_fp16_sampler PASS");
    $finish;
end

endmodule
