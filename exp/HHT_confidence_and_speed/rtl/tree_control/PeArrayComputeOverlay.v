`timescale 1ns/1ps

`include "config/prediction_params.vh"
`include "config/interface_params.vh"
`include "config/memory_params.vh"
`include "config/model_params.vh"

// PeArrayComputeOverlay
//
// This module overlays real FP16 MAC computation on top of the existing
// PaperPeArrays16x128Mesh memory orchestration framework.
//
// Architecture:
//   - The existing mesh handles all memory request/response orchestration.
//   - This overlay intercepts mc_resp_rdata and feeds it to MAC units.
//   - It also intercepts tile_result_data and replaces it with computed values.
//
// Two-pass operation per matrix-vector multiply:
//   Pass 1 (vector load): mesh reads input vector, overlay stores in local regs.
//   Pass 2 (MAC compute): mesh reads weight columns, overlay feeds to MAC units.
//
// For the toy model (d_model=128, SRAM beat=8 FP16):
//   - Vector load: 16 beats × 8 elements = 128 elements per cell
//   - MAC compute: 128 beats × 8 weights = 128 MAC cycles per cell
//   - Each cell produces 8 output elements
//   - 16 cells × 8 = 128 output elements = full d_model

module PeArrayComputeOverlay #(
    parameter integer PE_TOTAL = `PE_NUM,
    parameter integer LANES_PER_PE = (`SRAM_RDATA_W / `FP16_TILE_DATA_W),
    parameter integer MAC_DEPTH = `MAC_NUM_PER_PE,
    parameter integer VECTOR_BEATS = ((`MODEL_DMODEL + LANES_PER_PE - 1) / LANES_PER_PE),
    parameter integer DATA_W = `FP16_TILE_DATA_W
) (
    input                                    clk,
    input                                    rst_n,

    // Operation control from layer controller
    input                                    op_start,
    input  [1:0]                             op_mode,
    output                                   op_done,

    // Intercept: response data from multicast network (to PE cells)
    input  [`PE_MASK_W-1:0]                  mc_resp_valid,
    input  [`PE_MASK_W*`SRAM_RDATA_W-1:0]    mc_resp_rdata,

    // Intercept: replace tile_result_data with computed values
    output [PE_TOTAL*LANES_PER_PE*DATA_W-1:0] computed_data,
    output [PE_TOTAL-1:0]                    cell_done
);

// Operation modes
localparam [1:0] OP_PASSTHROUGH  = 2'd0;  // no computation, pass data through
localparam [1:0] OP_VECTOR_LOAD  = 2'd1;  // store response data as input vector
localparam [1:0] OP_MAC_COMPUTE  = 2'd2;  // feed response data as weights to MAC
localparam [1:0] OP_CLEAR        = 2'd3;  // clear accumulators

// Per-cell vector register: stores the input vector for MAC computation
// Each cell stores VECTOR_BEATS × LANES_PER_PE = 16 × 8 = 128 FP16 values
reg [MAC_DEPTH*DATA_W-1:0] cell_vector_r [0:PE_TOTAL-1];

// Per-cell MAC beat counter (which vector element to use)
reg [6:0] cell_mac_beat_r [0:PE_TOTAL-1];

// MAC unit interface signals
wire [PE_TOTAL-1:0] mac_clear_w;
wire [PE_TOTAL-1:0] mac_valid_w;
wire [PE_TOTAL*DATA_W-1:0] mac_vector_val_w;
wire [PE_TOTAL*LANES_PER_PE*DATA_W-1:0] mac_weight_col_w;
wire [PE_TOTAL*LANES_PER_PE*DATA_W-1:0] mac_result_w;
wire [PE_TOTAL-1:0] mac_done_w;

reg [1:0] op_mode_r;
reg op_active_r;

assign op_done = (op_mode_r == OP_MAC_COMPUTE) && (&mac_done_w);
assign computed_data = mac_result_w;
assign cell_done = mac_done_w;

// Instantiate 16 MAC units
genvar pe_i;
generate
    for (pe_i = 0; pe_i < PE_TOTAL; pe_i = pe_i + 1) begin : gen_pe_mac

        assign mac_clear_w[pe_i] = (op_mode_r == OP_CLEAR);

        assign mac_valid_w[pe_i] =
            (op_mode_r == OP_MAC_COMPUTE) && mc_resp_valid[pe_i];

        // Select vector element based on MAC beat counter
        assign mac_vector_val_w[pe_i*DATA_W +: DATA_W] =
            cell_vector_r[pe_i][cell_mac_beat_r[pe_i]*DATA_W +: DATA_W];

        // Weight column comes directly from SRAM response
        assign mac_weight_col_w[pe_i*LANES_PER_PE*DATA_W +: LANES_PER_PE*DATA_W] =
            mc_resp_rdata[pe_i*`SRAM_RDATA_W +: LANES_PER_PE*DATA_W];

        pe_mac_unit #(
            .LANES(LANES_PER_PE),
            .DEPTH(MAC_DEPTH),
            .DATA_W(DATA_W)
        ) u_mac (
            .clk(clk),
            .rst_n(rst_n),
            .clear(mac_clear_w[pe_i]),
            .mac_valid(mac_valid_w[pe_i]),
            .vector_val(mac_vector_val_w[pe_i*DATA_W +: DATA_W]),
            .weight_col(mac_weight_col_w[pe_i*LANES_PER_PE*DATA_W +: LANES_PER_PE*DATA_W]),
            .depth_cfg({LANES_PER_PE{1'b0}}),
            .result(mac_result_w[pe_i*LANES_PER_PE*DATA_W +: LANES_PER_PE*DATA_W]),
            .done(mac_done_w[pe_i])
        );
    end
endgenerate

// Vector load and MAC beat tracking
integer cell_idx;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        op_mode_r <= OP_PASSTHROUGH;
        op_active_r <= 1'b0;
        for (cell_idx = 0; cell_idx < PE_TOTAL; cell_idx = cell_idx + 1) begin
            cell_vector_r[cell_idx] <= {(MAC_DEPTH*DATA_W){1'b0}};
            cell_mac_beat_r[cell_idx] <= 7'd0;
        end
    end else begin
        if (op_start) begin
            op_mode_r <= op_mode;
            op_active_r <= 1'b1;
            if (op_mode == OP_CLEAR || op_mode == OP_MAC_COMPUTE) begin
                for (cell_idx = 0; cell_idx < PE_TOTAL; cell_idx = cell_idx + 1) begin
                    cell_mac_beat_r[cell_idx] <= 7'd0;
                end
            end
        end

        // Vector load: store response data into vector register
        if (op_mode_r == OP_VECTOR_LOAD) begin
            for (cell_idx = 0; cell_idx < PE_TOTAL; cell_idx = cell_idx + 1) begin
                if (mc_resp_valid[cell_idx]) begin
                    cell_vector_r[cell_idx][
                        cell_mac_beat_r[cell_idx]*LANES_PER_PE*DATA_W +:
                        LANES_PER_PE*DATA_W] <=
                        mc_resp_rdata[cell_idx*`SRAM_RDATA_W +: LANES_PER_PE*DATA_W];
                    cell_mac_beat_r[cell_idx] <=
                        cell_mac_beat_r[cell_idx] + 7'd1;
                end
            end
        end

        // MAC compute: advance beat counter on each valid response
        if (op_mode_r == OP_MAC_COMPUTE) begin
            for (cell_idx = 0; cell_idx < PE_TOTAL; cell_idx = cell_idx + 1) begin
                if (mc_resp_valid[cell_idx]) begin
                    cell_mac_beat_r[cell_idx] <=
                        cell_mac_beat_r[cell_idx] + 7'd1;
                end
            end
        end

        // Auto-deactivate on completion
        if (op_done) begin
            op_active_r <= 1'b0;
            op_mode_r <= OP_PASSTHROUGH;
        end
    end
end

endmodule
