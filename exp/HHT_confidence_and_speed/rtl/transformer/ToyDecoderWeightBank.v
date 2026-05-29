`timescale 1ns/1ps

module ToyDecoderWeightBank #(
    parameter integer DATA_WIDTH = 16,
    parameter integer VECTOR_DIM = 4
) (
    output [VECTOR_DIM*VECTOR_DIM*DATA_WIDTH-1:0] q_proj_weight,
    output [VECTOR_DIM*VECTOR_DIM*DATA_WIDTH-1:0] k_proj_weight,
    output [VECTOR_DIM*VECTOR_DIM*DATA_WIDTH-1:0] v_proj_weight,
    output [VECTOR_DIM*VECTOR_DIM*DATA_WIDTH-1:0] ffn_layer1_weight,
    output [VECTOR_DIM*VECTOR_DIM*DATA_WIDTH-1:0] ffn_layer2_weight
);

localparam integer WEIGHT_BLOCK_WORDS = VECTOR_DIM * VECTOR_DIM;
localparam integer WEIGHT_COUNT = 5 * WEIGHT_BLOCK_WORDS;
localparam [DATA_WIDTH-1:0] FP_ONE =
    (DATA_WIDTH == 16) ? 16'h3c00 : 32'h3f80_0000;

reg [DATA_WIDTH-1:0] weight_mem [0:WEIGHT_COUNT-1];
reg [4095:0] weight_memh_path_r;
integer weight_idx_i;
integer diag_idx_i;
genvar weight_word_idx_g;

initial begin
    for (weight_idx_i = 0; weight_idx_i < WEIGHT_COUNT; weight_idx_i = weight_idx_i + 1) begin
        weight_mem[weight_idx_i] = {DATA_WIDTH{1'b0}};
    end

    // Default fallback keeps the old single-lane bring-up semantics:
    // every projection/FFN block behaves like an identity matrix.
    for (weight_idx_i = 0; weight_idx_i < 5; weight_idx_i = weight_idx_i + 1) begin
        for (diag_idx_i = 0; diag_idx_i < VECTOR_DIM; diag_idx_i = diag_idx_i + 1) begin
            weight_mem[(weight_idx_i*WEIGHT_BLOCK_WORDS) +
                       (diag_idx_i*VECTOR_DIM) +
                       diag_idx_i] = FP_ONE;
        end
    end

    if ($value$plusargs("toy_weight_memh=%s", weight_memh_path_r)) begin
        $display(
            "ToyDecoderWeightBank loading decoder weights from %0s",
            weight_memh_path_r
        );
        $readmemh(weight_memh_path_r, weight_mem);
    end else begin
        $display(
            "ToyDecoderWeightBank using built-in diagonal FP_ONE fallback weights"
        );
    end
end

generate
    for (weight_word_idx_g = 0;
         weight_word_idx_g < WEIGHT_BLOCK_WORDS;
         weight_word_idx_g = weight_word_idx_g + 1) begin : gen_weight_map
        assign q_proj_weight[(weight_word_idx_g*DATA_WIDTH) +: DATA_WIDTH] =
            weight_mem[weight_word_idx_g];
        assign k_proj_weight[(weight_word_idx_g*DATA_WIDTH) +: DATA_WIDTH] =
            weight_mem[WEIGHT_BLOCK_WORDS + weight_word_idx_g];
        assign v_proj_weight[(weight_word_idx_g*DATA_WIDTH) +: DATA_WIDTH] =
            weight_mem[(2*WEIGHT_BLOCK_WORDS) + weight_word_idx_g];
        assign ffn_layer1_weight[(weight_word_idx_g*DATA_WIDTH) +: DATA_WIDTH] =
            weight_mem[(3*WEIGHT_BLOCK_WORDS) + weight_word_idx_g];
        assign ffn_layer2_weight[(weight_word_idx_g*DATA_WIDTH) +: DATA_WIDTH] =
            weight_mem[(4*WEIGHT_BLOCK_WORDS) + weight_word_idx_g];
    end
endgenerate

endmodule
