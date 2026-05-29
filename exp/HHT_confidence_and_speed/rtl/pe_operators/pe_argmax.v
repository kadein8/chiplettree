`timescale 1ns/1ps
`include "config/interface_params.vh"
`include "config/model_params.vh"

// pe_argmax — Argmax over a vector
//
// Finds the index of the maximum element in vec_in for each slot.
// Uses FP16 sortable-integer comparison for correct sign handling.
// Takes VOCAB_SIZE cycles (one comparison per element per cycle).

module pe_argmax #(
    parameter integer DIM       = `MODEL_VOCAB_SIZE,
    parameter integer DATA_W    = `FP16_TILE_DATA_W,
    parameter integer NUM_SLOTS = `TREE_FRONTIER_SLOTS,
    parameter integer IDX_W     = `TOKEN_ID_W
) (
    input                              clk,
    input                              rst_n,
    input                              start,
    output reg                         done,
    output reg                         busy,
    input  [NUM_SLOTS-1:0]             active_slots,
    input  [NUM_SLOTS*DIM*DATA_W-1:0]  vec_in,
    output reg [NUM_SLOTS*IDX_W-1:0]   idx_out
);

reg [15:0] elem_cnt_r;
reg [DATA_W-1:0] max_val_r [0:NUM_SLOTS-1];
reg [IDX_W-1:0] max_idx_r [0:NUM_SLOTS-1];

integer i;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        busy <= 1'b0; done <= 1'b0;
        elem_cnt_r <= 16'd0;
        idx_out <= {(NUM_SLOTS*IDX_W){1'b0}};
        for (i = 0; i < NUM_SLOTS; i = i + 1) begin
            max_val_r[i] <= 16'h0000;
            max_idx_r[i] <= {IDX_W{1'b0}};
        end
    end else begin
        done <= 1'b0;
        if (!busy && start) begin
            busy <= 1'b1;
            elem_cnt_r <= 16'd0;
            for (i = 0; i < NUM_SLOTS; i = i + 1) begin
                max_val_r[i] <= 16'h0000;
                max_idx_r[i] <= {IDX_W{1'b0}};
            end
        end else if (busy) begin
            if (elem_cnt_r < DIM) begin
                for (i = 0; i < NUM_SLOTS; i = i + 1) begin
                    if (active_slots[i]) begin
                        if (elem_cnt_r == 16'd0) begin
                            max_val_r[i] <= vec_in[(i*DIM)*DATA_W +: DATA_W];
                            max_idx_r[i] <= {IDX_W{1'b0}};
                        end else begin
                            // FP16 sortable compare: neg→flip all, pos→flip sign bit
                            if ((vec_in[(i*DIM+elem_cnt_r)*DATA_W + DATA_W-1] ?
                                    ~vec_in[(i*DIM+elem_cnt_r)*DATA_W +: DATA_W] :
                                    {1'b1, vec_in[(i*DIM+elem_cnt_r)*DATA_W +: DATA_W-1]})
                                >
                                (max_val_r[i][DATA_W-1] ?
                                    ~max_val_r[i] :
                                    {1'b1, max_val_r[i][DATA_W-2:0]}))
                            begin
                                max_val_r[i] <= vec_in[(i*DIM+elem_cnt_r)*DATA_W +: DATA_W];
                                max_idx_r[i] <= elem_cnt_r[IDX_W-1:0];
                            end
                        end
                    end
                end
                elem_cnt_r <= elem_cnt_r + 16'd1;
            end else begin
                for (i = 0; i < NUM_SLOTS; i = i + 1)
                    idx_out[i*IDX_W +: IDX_W] <= max_idx_r[i];
                done <= 1'b1;
                busy <= 1'b0;
            end
        end
    end
end
endmodule
