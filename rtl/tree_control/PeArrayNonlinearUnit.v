`timescale 1ns/1ps

`include "config/interface_params.vh"
`include "config/model_params.vh"
`include "config/memory_params.vh"

// PeArrayNonlinearUnit
//
// Handles non-matrix-multiply operations for the PE Mesh transformer path:
//   - RMSNorm: x * rsqrt(mean(x^2) + eps) * gamma
//   - Softmax: exp(x - max(x)) / sum(exp(x - max(x)))
//   - RoPE: rotary position embedding (cos/sin rotation on pairs)
//   - SiLU: x * sigmoid(x)
//   - Residual add: a + b
//   - Argmax: find index of maximum value
//
// All operations are performed element-wise or with simple reductions,
// using FP16 arithmetic. The unit reads/writes vectors from/to SRAM.
//
// For the toy model (d_model=128):
//   - Vector = 16 SRAM beats of 8 FP16 elements each
//   - Operations complete in O(HIDDEN_DIM) cycles

module PeArrayNonlinearUnit #(
    parameter integer HIDDEN_DIM   = `MODEL_DMODEL,
    parameter integer MAX_SEQ_LEN  = `MODEL_MAX_POS_EMB,
    parameter integer VOCAB_SIZE   = `MODEL_VOCAB_SIZE,
    parameter integer DATA_W       = `FP16_TILE_DATA_W,
    parameter integer BEAT_ELEMS   = (`SRAM_RDATA_W / `FP16_TILE_DATA_W),
    parameter integer HIDDEN_BEATS = ((HIDDEN_DIM + BEAT_ELEMS - 1) / BEAT_ELEMS)
) (
    input                              clk,
    input                              rst_n,

    // Operation control
    input                              start,
    input  [2:0]                       op_type,
    output reg                         done,
    output reg                         busy,

    // Position for RoPE
    input  [`POSITION_ID_W-1:0]        position,

    // SRAM read interface
    output reg                         sram_rd_valid,
    input                              sram_rd_ready,
    output reg [`SRAM_ADDR_W-1:0]      sram_rd_addr,
    input                              sram_resp_valid,
    input  [`SRAM_RDATA_W-1:0]         sram_resp_data,

    // SRAM write interface
    output reg                         sram_wr_valid,
    input                              sram_wr_ready,
    output reg [`SRAM_ADDR_W-1:0]      sram_wr_addr,
    output reg [`SRAM_WDATA_W-1:0]     sram_wr_data,

    // Source/destination addresses
    input  [`SRAM_ADDR_W-1:0]          src_addr,
    input  [`SRAM_ADDR_W-1:0]          src2_addr,    // second source (for residual add)
    input  [`SRAM_ADDR_W-1:0]          gamma_addr,   // gamma for RMSNorm
    input  [`SRAM_ADDR_W-1:0]          dst_addr,

    // Argmax result
    output reg [`TOKEN_ID_W-1:0]       argmax_result,
    output reg                         argmax_valid
);

// Operation types
localparam [2:0]
    OP_RMSNORM      = 3'd0,
    OP_SOFTMAX      = 3'd1,
    OP_ROPE         = 3'd2,
    OP_SILU         = 3'd3,
    OP_RESIDUAL_ADD = 3'd4,
    OP_ARGMAX       = 3'd5,
    OP_ELEM_MUL     = 3'd6;

// Internal state
localparam [2:0]
    NL_IDLE     = 3'd0,
    NL_READ1    = 3'd1,
    NL_READ2    = 3'd2,
    NL_COMPUTE  = 3'd3,
    NL_WRITE    = 3'd4,
    NL_DONE     = 3'd5;

reg [2:0] nl_state_r;
reg [2:0] op_type_r;
reg [6:0] beat_cnt_r;
reg [6:0] resp_cnt_r;

// Vector storage
reg [HIDDEN_DIM*DATA_W-1:0] vec_a_r;
reg [HIDDEN_DIM*DATA_W-1:0] vec_b_r;
reg [HIDDEN_DIM*DATA_W-1:0] vec_gamma_r;
reg [HIDDEN_DIM*DATA_W-1:0] vec_out_r;

// RMSNorm intermediate
reg [31:0] sum_sq_r;       // FP32 accumulator for sum of squares
reg [15:0] inv_rms_r;      // 1/sqrt(mean_sq + eps)

// Softmax intermediate
reg [15:0] max_val_r;
reg [31:0] exp_sum_r;

// Argmax intermediate
reg [15:0] max_logit_r;
reg [`TOKEN_ID_W-1:0] max_idx_r;
reg [15:0] cur_elem_idx_r;

// FP16 arithmetic wires (shared)
wire [15:0] mult_a_w, mult_b_w, mult_out_w;
wire [15:0] add_a_w, add_b_w, add_out_w;

floatMult16 u_shared_mult (
    .floatA(mult_a_w),
    .floatB(mult_b_w),
    .product(mult_out_w)
);

floatAdd16 u_shared_add (
    .floatA(add_a_w),
    .floatB(add_b_w),
    .sum(add_out_w)
);

// For RMSNorm: square current element
assign mult_a_w = (op_type_r == OP_RMSNORM && nl_state_r == NL_COMPUTE) ?
    vec_a_r[beat_cnt_r*DATA_W +: DATA_W] : 16'd0;
assign mult_b_w = (op_type_r == OP_RMSNORM && nl_state_r == NL_COMPUTE) ?
    vec_a_r[beat_cnt_r*DATA_W +: DATA_W] : 16'd0;

// For residual add
assign add_a_w = (op_type_r == OP_RESIDUAL_ADD && nl_state_r == NL_COMPUTE) ?
    vec_a_r[beat_cnt_r*DATA_W +: DATA_W] : 16'd0;
assign add_b_w = (op_type_r == OP_RESIDUAL_ADD && nl_state_r == NL_COMPUTE) ?
    vec_b_r[beat_cnt_r*DATA_W +: DATA_W] : 16'd0;

// Main state machine
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        nl_state_r <= NL_IDLE;
        op_type_r <= 3'd0;
        beat_cnt_r <= 7'd0;
        resp_cnt_r <= 7'd0;
        busy <= 1'b0;
        done <= 1'b0;
        sram_rd_valid <= 1'b0;
        sram_wr_valid <= 1'b0;
        argmax_valid <= 1'b0;
        argmax_result <= {`TOKEN_ID_W{1'b0}};
        vec_a_r <= {(HIDDEN_DIM*DATA_W){1'b0}};
        vec_b_r <= {(HIDDEN_DIM*DATA_W){1'b0}};
        vec_gamma_r <= {(HIDDEN_DIM*DATA_W){1'b0}};
        vec_out_r <= {(HIDDEN_DIM*DATA_W){1'b0}};
        sum_sq_r <= 32'd0;
        inv_rms_r <= 16'd0;
        max_val_r <= 16'hFC00; // -inf in FP16
        exp_sum_r <= 32'd0;
        max_logit_r <= 16'hFC00;
        max_idx_r <= {`TOKEN_ID_W{1'b0}};
        cur_elem_idx_r <= 16'd0;
    end else begin
        done <= 1'b0;
        sram_rd_valid <= 1'b0;
        sram_wr_valid <= 1'b0;
        argmax_valid <= 1'b0;

        case (nl_state_r)
        NL_IDLE: begin
            if (start) begin
                busy <= 1'b1;
                op_type_r <= op_type;
                beat_cnt_r <= 7'd0;
                resp_cnt_r <= 7'd0;
                nl_state_r <= NL_READ1;
                sum_sq_r <= 32'd0;
                max_val_r <= 16'hFC00;
                max_logit_r <= 16'hFC00;
                max_idx_r <= {`TOKEN_ID_W{1'b0}};
                cur_elem_idx_r <= 16'd0;
            end
        end

        // Read first source vector
        NL_READ1: begin
            if (beat_cnt_r < HIDDEN_BEATS[6:0]) begin
                sram_rd_valid <= 1'b1;
                sram_rd_addr <= src_addr + `SRAM_ADDR_W'(beat_cnt_r);
                if (sram_rd_ready)
                    beat_cnt_r <= beat_cnt_r + 7'd1;
            end
            if (sram_resp_valid) begin
                vec_a_r[resp_cnt_r*BEAT_ELEMS*DATA_W +: BEAT_ELEMS*DATA_W] <=
                    sram_resp_data[BEAT_ELEMS*DATA_W-1:0];
                resp_cnt_r <= resp_cnt_r + 7'd1;
                if (resp_cnt_r == HIDDEN_BEATS[6:0] - 7'd1) begin
                    beat_cnt_r <= 7'd0;
                    resp_cnt_r <= 7'd0;
                    // Some ops need a second read
                    if (op_type_r == OP_RESIDUAL_ADD || op_type_r == OP_ELEM_MUL)
                        nl_state_r <= NL_READ2;
                    else if (op_type_r == OP_RMSNORM)
                        nl_state_r <= NL_READ2; // read gamma
                    else
                        nl_state_r <= NL_COMPUTE;
                end
            end
        end

        // Read second source (gamma for norm, or second vector for add/mul)
        NL_READ2: begin
            if (beat_cnt_r < HIDDEN_BEATS[6:0]) begin
                sram_rd_valid <= 1'b1;
                sram_rd_addr <= (op_type_r == OP_RMSNORM) ?
                    (gamma_addr + `SRAM_ADDR_W'(beat_cnt_r)) :
                    (src2_addr + `SRAM_ADDR_W'(beat_cnt_r));
                if (sram_rd_ready)
                    beat_cnt_r <= beat_cnt_r + 7'd1;
            end
            if (sram_resp_valid) begin
                if (op_type_r == OP_RMSNORM)
                    vec_gamma_r[resp_cnt_r*BEAT_ELEMS*DATA_W +: BEAT_ELEMS*DATA_W] <=
                        sram_resp_data[BEAT_ELEMS*DATA_W-1:0];
                else
                    vec_b_r[resp_cnt_r*BEAT_ELEMS*DATA_W +: BEAT_ELEMS*DATA_W] <=
                        sram_resp_data[BEAT_ELEMS*DATA_W-1:0];
                resp_cnt_r <= resp_cnt_r + 7'd1;
                if (resp_cnt_r == HIDDEN_BEATS[6:0] - 7'd1) begin
                    beat_cnt_r <= 7'd0;
                    nl_state_r <= NL_COMPUTE;
                end
            end
        end

        // Compute (element-wise, takes HIDDEN_DIM cycles for full precision)
        NL_COMPUTE: begin
            // For initial bringup: behavioral computation
            // Real structural implementation would pipeline through shared FP units
            nl_state_r <= NL_WRITE;
            beat_cnt_r <= 7'd0;

            case (op_type_r)
            OP_RESIDUAL_ADD: begin
                // vec_out = vec_a + vec_b (element-wise)
                // Behavioral: done in one cycle for bringup
                vec_out_r <= vec_a_r; // placeholder
            end
            OP_RMSNORM: begin
                // vec_out = rmsnorm(vec_a, vec_gamma)
                vec_out_r <= vec_a_r; // placeholder
            end
            OP_SILU: begin
                // vec_out = silu(vec_a)
                vec_out_r <= vec_a_r; // placeholder
            end
            OP_ELEM_MUL: begin
                // vec_out = vec_a * vec_b (element-wise)
                vec_out_r <= vec_a_r; // placeholder
            end
            OP_ARGMAX: begin
                // Find max element index
                nl_state_r <= NL_DONE;
                argmax_result <= max_idx_r;
                argmax_valid <= 1'b1;
            end
            default: begin
                vec_out_r <= vec_a_r;
            end
            endcase
        end

        // Write result back to SRAM
        NL_WRITE: begin
            if (beat_cnt_r < HIDDEN_BEATS[6:0]) begin
                sram_wr_valid <= 1'b1;
                sram_wr_addr <= dst_addr + `SRAM_ADDR_W'(beat_cnt_r);
                sram_wr_data <= vec_out_r[beat_cnt_r*BEAT_ELEMS*DATA_W +: `SRAM_WDATA_W];
                if (sram_wr_ready)
                    beat_cnt_r <= beat_cnt_r + 7'd1;
            end else begin
                nl_state_r <= NL_DONE;
            end
        end

        NL_DONE: begin
            done <= 1'b1;
            busy <= 1'b0;
            nl_state_r <= NL_IDLE;
        end

        default: nl_state_r <= NL_IDLE;
        endcase
    end
end

endmodule
