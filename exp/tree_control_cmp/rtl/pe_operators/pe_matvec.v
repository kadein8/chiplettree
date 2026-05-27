`timescale 1ns/1ps
`include "config/interface_params.vh"
`include "config/model_params.vh"
`include "config/memory_params.vh"

// pe_matvec — Matrix-Vector Multiply Module
//
// Computes y = W @ x where:
//   W is [OUT_DIM × IN_DIM] stored column-major in SRAM tiles
//   x is [IN_DIM] stored in input register
//   y is [OUT_DIM] output register
//
// Uses pe_mac_unit (8 lanes, IN_DIM depth) internally.
// Processes OUT_DIM/8 output groups sequentially, each group in IN_DIM cycles.
// All NUM_SLOTS slots computed in parallel (shared weights, per-slot input).
//
// Interface: valid/ready handshake. Start → busy → done pulse.
// SRAM access: reads weight beats pipelined (1 beat per MAC cycle).

module pe_matvec #(
    parameter integer IN_DIM    = `MODEL_DMODEL,   // input vector dimension
    parameter integer OUT_DIM   = `MODEL_DMODEL,   // output vector dimension
    parameter integer DATA_W    = `FP16_TILE_DATA_W,
    parameter integer BEAT_ELEMS = (`SRAM_RDATA_W / `FP16_TILE_DATA_W),
    parameter integer NUM_SLOTS = `TREE_FRONTIER_SLOTS
) (
    input                              clk,
    input                              rst_n,

    // Control
    input                              start,
    output reg                         done,
    output reg                         busy,

    // Slot mask
    input  [NUM_SLOTS-1:0]             active_slots,

    // Input vectors (one per slot, IN_DIM elements each)
    input  [NUM_SLOTS*IN_DIM*DATA_W-1:0] vec_in,

    // Output vectors (one per slot, OUT_DIM elements each)
    output reg [NUM_SLOTS*OUT_DIM*DATA_W-1:0] vec_out,

    // Weight base address in SRAM
    input  [`SRAM_ADDR_W-1:0]          weight_base_addr,

    // SRAM read interface
    output reg                         sram_rd_valid,
    input                              sram_rd_ready,
    output reg [`SRAM_ADDR_W-1:0]      sram_rd_addr,
    input                              sram_resp_valid,
    input  [`SRAM_RDATA_W-1:0]         sram_resp_data
);

localparam integer OUT_GROUPS = OUT_DIM / BEAT_ELEMS;
localparam integer OUT_GROUP_W = (OUT_GROUPS <= 2) ? 1 : $clog2(OUT_GROUPS);

// State
localparam [1:0] MV_IDLE = 2'd0, MV_RUN = 2'd1, MV_STORE = 2'd2;
reg [1:0] state_r;
reg [8:0] beat_cnt_r;
reg [8:0] resp_cnt_r;
reg [OUT_GROUP_W-1:0] out_group_r;

// MAC units (one per slot)
reg  [NUM_SLOTS-1:0]              mac_clear;
reg  [NUM_SLOTS-1:0]              mac_valid;
reg  [BEAT_ELEMS*DATA_W-1:0]      mac_weight_col;
wire [NUM_SLOTS*BEAT_ELEMS*DATA_W-1:0] mac_result;
wire [NUM_SLOTS-1:0]              mac_done;
reg  [NUM_SLOTS-1:0]              mac_done_latch_r;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) mac_done_latch_r <= {NUM_SLOTS{1'b0}};
    else begin
        mac_done_latch_r <= mac_done_latch_r | mac_done;
        if (|mac_clear) mac_done_latch_r <= {NUM_SLOTS{1'b0}};
    end
end
wire all_mac_done_w = &(mac_done_latch_r | mac_done | ~active_slots);

// MAC instantiation
genvar si;
generate
    for (si = 0; si < NUM_SLOTS; si = si + 1) begin : gen_mac
        pe_mac_unit #(.LANES(BEAT_ELEMS), .DEPTH(IN_DIM), .DATA_W(DATA_W))
        u_mac (
            .clk(clk), .rst_n(rst_n),
            .clear(mac_clear[si]),
            .mac_valid(mac_valid[si]),
            .vector_val(vec_in[(si*IN_DIM + resp_cnt_r)*DATA_W +: DATA_W]),
            .weight_col(mac_weight_col),
            .result(mac_result[si*BEAT_ELEMS*DATA_W +: BEAT_ELEMS*DATA_W]),
            .done(mac_done[si])
        );
    end
endgenerate

// Main FSM
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state_r <= MV_IDLE;
        beat_cnt_r <= 9'd0;
        resp_cnt_r <= 9'd0;
        out_group_r <= {OUT_GROUP_W{1'b0}};
        busy <= 1'b0;
        done <= 1'b0;
        sram_rd_valid <= 1'b0;
        sram_rd_addr <= {`SRAM_ADDR_W{1'b0}};
        mac_clear <= {NUM_SLOTS{1'b0}};
        mac_valid <= {NUM_SLOTS{1'b0}};
        mac_weight_col <= {(BEAT_ELEMS*DATA_W){1'b0}};
        vec_out <= {(NUM_SLOTS*OUT_DIM*DATA_W){1'b0}};
    end else begin
        done <= 1'b0;
        sram_rd_valid <= 1'b0;
        mac_clear <= {NUM_SLOTS{1'b0}};
        mac_valid <= {NUM_SLOTS{1'b0}};

        case (state_r)
        MV_IDLE: begin
            if (start) begin
                busy <= 1'b1;
                out_group_r <= {OUT_GROUP_W{1'b0}};
                beat_cnt_r <= 9'd0;
                resp_cnt_r <= 9'd0;
                mac_clear <= active_slots;
                state_r <= MV_RUN;
            end
        end

        // Pipelined: issue SRAM reads + feed MAC on responses
        MV_RUN: begin
            // Issue weight read: addr = base + col * OUT_GROUPS + out_group
            if (beat_cnt_r < IN_DIM) begin
                sram_rd_valid <= 1'b1;
                sram_rd_addr <= weight_base_addr +
                    (beat_cnt_r * OUT_GROUPS) + out_group_r;
                if (sram_rd_ready)
                    beat_cnt_r <= beat_cnt_r + 9'd1;
            end
            // Feed responses to MAC
            if (sram_resp_valid) begin
                mac_weight_col <= sram_resp_data[BEAT_ELEMS*DATA_W-1:0];
                mac_valid <= active_slots;
                resp_cnt_r <= resp_cnt_r + 9'd1;
            end
            // Done when all MACs complete
            if (all_mac_done_w)
                state_r <= MV_STORE;
        end

        // Store result for this output group, advance
        MV_STORE: begin
            // Copy MAC results to output
            for (integer gi = 0; gi < NUM_SLOTS; gi = gi + 1) begin
                if (active_slots[gi])
                    vec_out[(gi*OUT_DIM + out_group_r*BEAT_ELEMS)*DATA_W +: BEAT_ELEMS*DATA_W]
                        <= mac_result[gi*BEAT_ELEMS*DATA_W +: BEAT_ELEMS*DATA_W];
            end
            // Next group or done
            if (out_group_r == OUT_GROUPS - 1) begin
                done <= 1'b1;
                busy <= 1'b0;
                state_r <= MV_IDLE;
            end else begin
                out_group_r <= out_group_r + 1;
                beat_cnt_r <= 9'd0;
                resp_cnt_r <= 9'd0;
                mac_clear <= active_slots;
                state_r <= MV_RUN;
            end
        end

        default: state_r <= MV_IDLE;
        endcase
    end
end

endmodule
