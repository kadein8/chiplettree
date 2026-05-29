`timescale 1ns/1ps

module decoderFfnUnit #(
    parameter integer DATA_WIDTH = 16,
    parameter integer VECTOR_DIM = 4
) (
    input                                         clk,
    input                                         rst_n,
    input                                         start_valid,
    output                                        start_ready,
    input      [VECTOR_DIM*DATA_WIDTH-1:0]        context_value,
    input      [VECTOR_DIM*VECTOR_DIM*DATA_WIDTH-1:0] layer1_weight,
    input      [VECTOR_DIM*VECTOR_DIM*DATA_WIDTH-1:0] layer2_weight,
    output                                        ffn_valid,
    output reg [VECTOR_DIM*DATA_WIDTH-1:0]        ffn_value
);

localparam [1:0]
    ST_IDLE   = 2'd0,
    ST_L1_RUN = 2'd1,
    ST_L2_RUN = 2'd2,
    ST_HOLD   = 2'd3;

reg [1:0] state_r;
reg [VECTOR_DIM*DATA_WIDTH-1:0] context_value_r;
reg [VECTOR_DIM*DATA_WIDTH-1:0] hidden_value_r;
wire [VECTOR_DIM*DATA_WIDTH-1:0] hidden_after_relu_w;

wire layer1_reset_w;
wire layer2_reset_w;
wire [0:(VECTOR_DIM*DATA_WIDTH)-1] layer1_input_w;
wire [0:(VECTOR_DIM*VECTOR_DIM*DATA_WIDTH)-1] layer1_weights_w;
wire [0:(VECTOR_DIM*DATA_WIDTH)-1] layer1_output_w;
wire layer1_valid_w;
wire [VECTOR_DIM*DATA_WIDTH-1:0] layer1_output_std_w;
wire [0:(VECTOR_DIM*DATA_WIDTH)-1] layer2_input_w;
wire [0:(VECTOR_DIM*VECTOR_DIM*DATA_WIDTH)-1] layer2_weights_w;
wire [0:(VECTOR_DIM*DATA_WIDTH)-1] layer2_output_w;
wire layer2_valid_w;
wire [VECTOR_DIM*DATA_WIDTH-1:0] layer2_output_std_w;

assign layer1_input_w = context_value_r;
assign layer1_weights_w = layer1_weight;
assign layer1_output_std_w = layer1_output_w;
assign layer2_input_w = hidden_after_relu_w;
assign layer2_weights_w = layer2_weight;
assign layer2_output_std_w = layer2_output_w;

assign start_ready = (state_r == ST_IDLE);
assign ffn_valid = (state_r == ST_HOLD);
assign layer1_reset_w = !rst_n || (state_r != ST_L1_RUN);
assign layer2_reset_w = !rst_n || (state_r != ST_L2_RUN);

genvar gi;
generate
    for (gi = 0; gi < VECTOR_DIM; gi = gi + 1) begin : gen_relu
        assign hidden_after_relu_w[(gi*DATA_WIDTH) +: DATA_WIDTH] =
            hidden_value_r[(gi*DATA_WIDTH) + DATA_WIDTH - 1] ?
                {DATA_WIDTH{1'b0}} :
                hidden_value_r[(gi*DATA_WIDTH) +: DATA_WIDTH];
    end
endgenerate

transformLayerSingle1x1 #(
    .DATA_WIDTH(DATA_WIDTH),
    .INPUT_CHANNELS(VECTOR_DIM),
    .OUTPUT_UNITS(VECTOR_DIM)
) u_layer1 (
    .clk(clk),
    .reset(layer1_reset_w),
    .enable(state_r == ST_L1_RUN),
    .input_vector(layer1_input_w),
    .weights(layer1_weights_w),
    .output_vector(layer1_output_w),
    .output_valid(layer1_valid_w)
);

transformLayerSingle1x1 #(
    .DATA_WIDTH(DATA_WIDTH),
    .INPUT_CHANNELS(VECTOR_DIM),
    .OUTPUT_UNITS(VECTOR_DIM)
) u_layer2 (
    .clk(clk),
    .reset(layer2_reset_w),
    .enable(state_r == ST_L2_RUN),
    .input_vector(layer2_input_w),
    .weights(layer2_weights_w),
    .output_vector(layer2_output_w),
    .output_valid(layer2_valid_w)
);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state_r <= ST_IDLE;
        context_value_r <= {(VECTOR_DIM*DATA_WIDTH){1'b0}};
        hidden_value_r <= {(VECTOR_DIM*DATA_WIDTH){1'b0}};
        ffn_value <= {(VECTOR_DIM*DATA_WIDTH){1'b0}};
    end else begin
        case (state_r)
            ST_IDLE: begin
                if (start_valid) begin
                    context_value_r <= context_value;
                    state_r <= ST_L1_RUN;
                end
            end

            ST_L1_RUN: begin
                if (layer1_valid_w) begin
                    hidden_value_r <= layer1_output_std_w;
                    state_r <= ST_L2_RUN;
                end
            end

            ST_L2_RUN: begin
                if (layer2_valid_w) begin
                    ffn_value <= layer2_output_std_w;
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
