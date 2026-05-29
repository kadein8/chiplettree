`timescale 1ns/1ps

module decoderOnlyTransformerChain #(
    parameter integer DATA_WIDTH = 16,
    parameter integer VECTOR_DIM = 4
) (
    input                                         clk,
    input                                         rst_n,
    input                                         start_valid,
    output                                        start_ready,
    input      [VECTOR_DIM*DATA_WIDTH-1:0]        token_vector_i,
    input      [VECTOR_DIM*DATA_WIDTH-1:0]        kv_vector_i,
    output                                        result_valid,
    output [VECTOR_DIM*DATA_WIDTH-1:0]            result_vector_o,
    output                                        debug_qkv_valid,
    output                                        debug_score_valid,
    output                                        debug_softmax_valid,
    output                                        debug_value_valid,
    output                                        debug_ffn_valid
);

localparam [2:0]
    ST_IDLE        = 3'd0,
    ST_QKV_RUN     = 3'd1,
    ST_QKV_HOLD    = 3'd2,
    ST_SCORE       = 3'd3,
    ST_SOFTMAX     = 3'd4,
    ST_VALUE       = 3'd5,
    ST_FFN         = 3'd6,
    ST_HOLD_RESULT = 3'd7;

reg [2:0] state_r;
reg [VECTOR_DIM*DATA_WIDTH-1:0] token_vector_r;
reg [VECTOR_DIM*DATA_WIDTH-1:0] kv_vector_r;
reg [VECTOR_DIM*DATA_WIDTH-1:0] q_value_r;
reg [VECTOR_DIM*DATA_WIDTH-1:0] k_value_r;
reg [VECTOR_DIM*DATA_WIDTH-1:0] v_value_r;
reg [DATA_WIDTH-1:0] score_value_r;
reg [DATA_WIDTH-1:0] softmax_value_r;
reg [VECTOR_DIM*DATA_WIDTH-1:0] context_value_r;
reg [VECTOR_DIM*DATA_WIDTH-1:0] result_vector_r;

wire q_reset_w;
wire kv_reset_w;
wire qkv_enable_w;
wire [0:(VECTOR_DIM*DATA_WIDTH)-1] q_input_w;
wire [0:(VECTOR_DIM*DATA_WIDTH)-1] kv_input_w;
wire [0:(VECTOR_DIM*VECTOR_DIM*DATA_WIDTH)-1] q_weights_w;
wire [0:(VECTOR_DIM*VECTOR_DIM*DATA_WIDTH)-1] k_weights_w;
wire [0:(VECTOR_DIM*VECTOR_DIM*DATA_WIDTH)-1] v_weights_w;
wire [0:(VECTOR_DIM*DATA_WIDTH)-1] q_output_w;
wire [0:(VECTOR_DIM*DATA_WIDTH)-1] k_output_w;
wire [0:(VECTOR_DIM*DATA_WIDTH)-1] v_output_w;
wire q_valid_w;
wire k_valid_w;
wire v_valid_w;
wire [VECTOR_DIM*DATA_WIDTH-1:0] q_output_std_w;
wire [VECTOR_DIM*DATA_WIDTH-1:0] k_output_std_w;
wire [VECTOR_DIM*DATA_WIDTH-1:0] v_output_std_w;
wire score_start_ready_w;
wire score_valid_w;
wire [DATA_WIDTH-1:0] score_output_w;
wire softmax_start_ready_w;
wire softmax_valid_w;
wire [DATA_WIDTH-1:0] softmax_output_w;
wire value_start_ready_w;
wire value_valid_w;
wire [VECTOR_DIM*DATA_WIDTH-1:0] value_output_w;
wire ffn_start_ready_w;
wire ffn_valid_w;
wire [VECTOR_DIM*DATA_WIDTH-1:0] ffn_output_w;
wire [VECTOR_DIM*VECTOR_DIM*DATA_WIDTH-1:0] q_proj_weight_w;
wire [VECTOR_DIM*VECTOR_DIM*DATA_WIDTH-1:0] k_proj_weight_w;
wire [VECTOR_DIM*VECTOR_DIM*DATA_WIDTH-1:0] v_proj_weight_w;
wire [VECTOR_DIM*VECTOR_DIM*DATA_WIDTH-1:0] ffn_layer1_weight_w;
wire [VECTOR_DIM*VECTOR_DIM*DATA_WIDTH-1:0] ffn_layer2_weight_w;

assign q_input_w = token_vector_r;
assign kv_input_w = kv_vector_r;
assign q_weights_w = q_proj_weight_w;
assign k_weights_w = k_proj_weight_w;
assign v_weights_w = v_proj_weight_w;
assign q_output_std_w = q_output_w;
assign k_output_std_w = k_output_w;
assign v_output_std_w = v_output_w;

assign start_ready = (state_r == ST_IDLE);
assign result_valid = (state_r == ST_HOLD_RESULT);
assign result_vector_o = result_vector_r;
assign debug_qkv_valid = (state_r == ST_QKV_HOLD);
assign debug_score_valid = (state_r == ST_SCORE) && score_valid_w;
assign debug_softmax_valid = (state_r == ST_SOFTMAX) && softmax_valid_w;
assign debug_value_valid = (state_r == ST_VALUE) && value_valid_w;
assign debug_ffn_valid = (state_r == ST_FFN) && ffn_valid_w;
assign qkv_enable_w =
    (state_r == ST_QKV_RUN) || (state_r == ST_QKV_HOLD);
assign q_reset_w =
    !rst_n || ((state_r != ST_QKV_RUN) && (state_r != ST_QKV_HOLD));
assign kv_reset_w =
    !rst_n || ((state_r != ST_QKV_RUN) && (state_r != ST_QKV_HOLD));

ToyDecoderWeightBank #(
    .DATA_WIDTH(DATA_WIDTH),
    .VECTOR_DIM(VECTOR_DIM)
) u_toy_decoder_weight_bank (
    .q_proj_weight(q_proj_weight_w),
    .k_proj_weight(k_proj_weight_w),
    .v_proj_weight(v_proj_weight_w),
    .ffn_layer1_weight(ffn_layer1_weight_w),
    .ffn_layer2_weight(ffn_layer2_weight_w)
);

transformLayerSingle1x1 #(
    .DATA_WIDTH(DATA_WIDTH),
    .INPUT_CHANNELS(VECTOR_DIM),
    .OUTPUT_UNITS(VECTOR_DIM)
) u_query_proj (
    .clk(clk),
    .reset(q_reset_w),
    .enable(qkv_enable_w),
    .input_vector(q_input_w),
    .weights(q_weights_w),
    .output_vector(q_output_w),
    .output_valid(q_valid_w)
);

transformLayerSingle1x1 #(
    .DATA_WIDTH(DATA_WIDTH),
    .INPUT_CHANNELS(VECTOR_DIM),
    .OUTPUT_UNITS(VECTOR_DIM)
) u_key_proj (
    .clk(clk),
    .reset(kv_reset_w),
    .enable(qkv_enable_w),
    .input_vector(kv_input_w),
    .weights(k_weights_w),
    .output_vector(k_output_w),
    .output_valid(k_valid_w)
);

transformLayerSingle1x1 #(
    .DATA_WIDTH(DATA_WIDTH),
    .INPUT_CHANNELS(VECTOR_DIM),
    .OUTPUT_UNITS(VECTOR_DIM)
) u_value_proj (
    .clk(clk),
    .reset(kv_reset_w),
    .enable(qkv_enable_w),
    .input_vector(kv_input_w),
    .weights(v_weights_w),
    .output_vector(v_output_w),
    .output_valid(v_valid_w)
);

decoderAttentionScore #(
    .DATA_WIDTH(DATA_WIDTH),
    .VECTOR_DIM(VECTOR_DIM)
) u_decoder_attention_score (
    .clk(clk),
    .rst_n(rst_n),
    .start_valid((state_r == ST_SCORE) && score_start_ready_w),
    .start_ready(score_start_ready_w),
    .query_value(q_value_r),
    .key_value(k_value_r),
    .score_valid(score_valid_w),
    .score_value(score_output_w)
);

decoderSoftmaxWindow #(
    .DATA_WIDTH(DATA_WIDTH),
    .WINDOW_SLOTS(1)
) u_decoder_softmax_window (
    .clk(clk),
    .rst_n(rst_n),
    .start_valid((state_r == ST_SOFTMAX) && softmax_start_ready_w),
    .start_ready(softmax_start_ready_w),
    .score_vector(score_value_r),
    .weight_valid(softmax_valid_w),
    .weight_vector(softmax_output_w)
);

decoderAttentionValue #(
    .DATA_WIDTH(DATA_WIDTH),
    .VECTOR_DIM(VECTOR_DIM)
) u_decoder_attention_value (
    .clk(clk),
    .rst_n(rst_n),
    .start_valid((state_r == ST_VALUE) && value_start_ready_w),
    .start_ready(value_start_ready_w),
    .score_weight(softmax_value_r),
    .value_data(v_value_r),
    .context_valid(value_valid_w),
    .context_value(value_output_w)
);

decoderFfnUnit #(
    .DATA_WIDTH(DATA_WIDTH),
    .VECTOR_DIM(VECTOR_DIM)
) u_decoder_ffn_unit (
    .clk(clk),
    .rst_n(rst_n),
    .start_valid((state_r == ST_FFN) && ffn_start_ready_w),
    .start_ready(ffn_start_ready_w),
    .context_value(context_value_r),
    .layer1_weight(ffn_layer1_weight_w),
    .layer2_weight(ffn_layer2_weight_w),
    .ffn_valid(ffn_valid_w),
    .ffn_value(ffn_output_w)
);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state_r <= ST_IDLE;
        token_vector_r <= {(VECTOR_DIM*DATA_WIDTH){1'b0}};
        kv_vector_r <= {(VECTOR_DIM*DATA_WIDTH){1'b0}};
        q_value_r <= {(VECTOR_DIM*DATA_WIDTH){1'b0}};
        k_value_r <= {(VECTOR_DIM*DATA_WIDTH){1'b0}};
        v_value_r <= {(VECTOR_DIM*DATA_WIDTH){1'b0}};
        score_value_r <= {DATA_WIDTH{1'b0}};
        softmax_value_r <= {DATA_WIDTH{1'b0}};
        context_value_r <= {(VECTOR_DIM*DATA_WIDTH){1'b0}};
        result_vector_r <= {(VECTOR_DIM*DATA_WIDTH){1'b0}};
    end else begin
        case (state_r)
            ST_IDLE: begin
                if (start_valid) begin
                    token_vector_r <= token_vector_i;
                    kv_vector_r <= kv_vector_i;
                    state_r <= ST_QKV_RUN;
                end
            end

            ST_QKV_RUN: begin
                if (q_valid_w && k_valid_w && v_valid_w) begin
                    state_r <= ST_QKV_HOLD;
                end
            end

            ST_QKV_HOLD: begin
                if (q_valid_w && k_valid_w && v_valid_w) begin
                    q_value_r <= q_output_std_w;
                    k_value_r <= k_output_std_w;
                    v_value_r <= v_output_std_w;
                    state_r <= ST_SCORE;
                end
            end

            ST_SCORE: begin
                if (score_valid_w) begin
                    score_value_r <= score_output_w;
                    state_r <= ST_SOFTMAX;
                end
            end

            ST_SOFTMAX: begin
                if (softmax_valid_w) begin
                    softmax_value_r <= softmax_output_w[0 +: DATA_WIDTH];
                    state_r <= ST_VALUE;
                end
            end

            ST_VALUE: begin
                if (value_valid_w) begin
                    context_value_r <= value_output_w;
                    state_r <= ST_FFN;
                end
            end

            ST_FFN: begin
                if (ffn_valid_w) begin
                    result_vector_r <= ffn_output_w;
                    state_r <= ST_HOLD_RESULT;
                end
            end

            ST_HOLD_RESULT: begin
                state_r <= ST_IDLE;
            end

            default: begin
                state_r <= ST_IDLE;
                end
        endcase
    end
end

endmodule
