`timescale 1ns/1ps

module decoderAttentionScore #(
    parameter integer DATA_WIDTH = 16,
    parameter integer VECTOR_DIM = 4
) (
    input                                         clk,
    input                                         rst_n,
    input                                         start_valid,
    output                                        start_ready,
    input      [VECTOR_DIM*DATA_WIDTH-1:0]        query_value,
    input      [VECTOR_DIM*DATA_WIDTH-1:0]        key_value,
    output                                        score_valid,
    output reg [DATA_WIDTH-1:0]                   score_value
);

localparam [1:0]
    ST_IDLE = 2'd0,
    ST_RUN  = 2'd1,
    ST_HOLD = 2'd2;

reg [1:0] state_r;
wire core_reset_w;
wire core_valid_w;
wire [DATA_WIDTH-1:0] core_result_w;
wire [0:(VECTOR_DIM*DATA_WIDTH)-1] query_vector_w;
wire [0:(VECTOR_DIM*DATA_WIDTH)-1] key_vector_w;
wire [DATA_WIDTH-1:0] core_result_std_w;

assign query_vector_w = query_value;
assign key_vector_w = key_value;
assign core_result_std_w = core_result_w;

assign start_ready = (state_r == ST_IDLE);
assign score_valid = (state_r == ST_HOLD);
assign core_reset_w = !rst_n || (state_r == ST_IDLE);

transformUnit1x1 #(
    .DATA_WIDTH(DATA_WIDTH),
    .CHANNELS(VECTOR_DIM)
) u_transform_unit1x1 (
    .clk(clk),
    .reset(core_reset_w),
    .enable(state_r == ST_RUN),
    .input_vector(query_vector_w),
    .weight_vector(key_vector_w),
    .result(core_result_w),
    .valid(core_valid_w)
);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state_r <= ST_IDLE;
        score_value <= {DATA_WIDTH{1'b0}};
    end else begin
        case (state_r)
            ST_IDLE: begin
                if (start_valid) begin
                    state_r <= ST_RUN;
                end
            end

            ST_RUN: begin
                if (core_valid_w) begin
                    score_value <= core_result_std_w;
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
