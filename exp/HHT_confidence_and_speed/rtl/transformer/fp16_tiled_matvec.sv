`include "config/interface_params.vh"
`include "config/memory_params.vh"
`include "config/model_params.vh"
`timescale 1ns/1ps

module fp16_tiled_matvec #(
    parameter integer LANES = `FP16_TILE_LANES,
    parameter integer COLS = `FP16_TILE_COLS,
    parameter integer DATA_WIDTH = `FP16_TILE_DATA_W,
    parameter integer ADDR_W = `SRAM_ADDR_W,
    parameter integer DATA_BUS_W = `SRAM_WDATA_W,
    parameter integer REQ_ID_W = `REQ_ID_W,
    parameter integer RESULT_STATUS_W = 2,
    parameter integer MAX_MATRIX_ROWS = `QWEN3_INTERMEDIATE_SIZE,
    parameter integer MAX_MATRIX_COLS = `QWEN3_INTERMEDIATE_SIZE,
    parameter [RESULT_STATUS_W-1:0] RESULT_STATUS_OK = 2'b00
) (
    input  logic                       clk,
    input  logic                       rst_n,

    input  logic                       issue_valid,
    output logic                       issue_ready,
    input  logic [ADDR_W-1:0]          issue_weight_base_addr,
    input  logic [ADDR_W-1:0]          issue_vector_addr,
    input  logic [ADDR_W-1:0]          issue_result_addr,
    input  logic [REQ_ID_W-1:0]        issue_req_id,
    input  logic [15:0]                issue_matrix_rows,
    input  logic [15:0]                issue_matrix_cols,

    output logic                       sram_rd_valid,
    input  logic                       sram_rd_ready,
    output logic [ADDR_W-1:0]          sram_rd_addr,
    output logic [REQ_ID_W-1:0]        sram_rd_id,

    input  logic                       sram_resp_valid,
    output logic                       sram_resp_ready,
    input  logic [DATA_BUS_W-1:0]      sram_resp_data,
    input  logic [REQ_ID_W-1:0]        sram_resp_id,

    output logic                       sram_wr_valid,
    input  logic                       sram_wr_ready,
    output logic [ADDR_W-1:0]          sram_wr_addr,
    output logic [DATA_BUS_W-1:0]      sram_wr_data,

    output logic                       result_valid,
    input  logic                       result_ready,
    output logic [ADDR_W-1:0]          result_addr,
    output logic [DATA_BUS_W-1:0]      result_data,
    output logic [RESULT_STATUS_W-1:0] result_status
);

localparam integer ELEMS_PER_BEAT = DATA_BUS_W / DATA_WIDTH;
localparam integer WEIGHT_BEATS_PER_TILE = (LANES * COLS) / ELEMS_PER_BEAT;
localparam integer VECTOR_BEATS_PER_TILE = COLS / ELEMS_PER_BEAT;
localparam integer RESULT_BEATS_PER_TILE = LANES / ELEMS_PER_BEAT;
localparam logic [3:0]
    ST_IDLE        = 4'd0,
    ST_LOAD_V_REQ  = 4'd1,
    ST_LOAD_V_RESP = 4'd2,
    ST_LOAD_V_DRAIN = 4'd3,
    ST_LOAD_W_REQ  = 4'd4,
    ST_LOAD_W_RESP = 4'd5,
    ST_LOAD_W_DRAIN = 4'd6,
    ST_COMPUTE     = 4'd7,
    ST_WRITE       = 4'd8,
    ST_HOLD        = 4'd9;

function automatic [15:0] ceil_div_u16;
    input [15:0] numerator;
    input integer denominator;
    reg [31:0] tmp;
    begin
        if (numerator == 16'd0) begin
            ceil_div_u16 = 16'd0;
        end else begin
            tmp = numerator + denominator - 1;
            ceil_div_u16 = tmp / denominator;
        end
    end
endfunction

function automatic [ADDR_W-1:0] addr_from_u16;
    input [15:0] value;
    begin
        addr_from_u16 = {{(ADDR_W-16){1'b0}}, value};
    end
endfunction

function automatic [ADDR_W-1:0] addr_from_u32;
    input [31:0] value;
    begin
        addr_from_u32 = value[ADDR_W-1:0];
    end
endfunction

function automatic [DATA_WIDTH-1:0] lane_value_for_write;
    input integer beat_idx;
    input integer lane_in_beat;
    input [15:0] total_rows;
    input [15:0] tile_row;
    input [(LANES*DATA_WIDTH)-1:0] raw_data;
    integer global_lane;
    begin
        global_lane = (tile_row * LANES) + (beat_idx * ELEMS_PER_BEAT) + lane_in_beat;
        if (global_lane < total_rows) begin
            lane_value_for_write = raw_data[((beat_idx*ELEMS_PER_BEAT + lane_in_beat)*DATA_WIDTH) +: DATA_WIDTH];
        end else begin
            lane_value_for_write = {DATA_WIDTH{1'b0}};
        end
    end
endfunction

logic [3:0] state_r;
logic [ADDR_W-1:0] weight_base_addr_r;
logic [ADDR_W-1:0] vector_addr_r;
logic [ADDR_W-1:0] result_addr_r;
logic [REQ_ID_W-1:0] req_id_r;
logic [15:0] matrix_rows_r;
logic [15:0] matrix_cols_r;
logic [15:0] tile_rows_total_r;
logic [15:0] tile_cols_total_r;
logic [15:0] tile_row_r;
logic [15:0] tile_col_r;
logic [15:0] beat_idx_r;
logic [6:0] feed_col_r;
logic [DATA_WIDTH-1:0] tile_vector_val_r;
logic [(LANES*DATA_WIDTH)-1:0] tile_weights_r;
logic [(LANES*DATA_WIDTH)-1:0] partial_sum_r;
logic [(LANES*DATA_WIDTH)-1:0] final_result_r;
logic [(COLS*DATA_WIDTH)-1:0] vector_tile_r;
logic [(LANES*COLS*DATA_WIDTH)-1:0] weight_tile_r;
logic tile_start_r;
logic tile_accum_en_r;
logic load_v_req_accepted_r;
logic load_w_req_accepted_r;
logic tile_busy_w;
logic tile_done_w;
logic [(LANES*DATA_WIDTH)-1:0] tile_result_w;
logic [6:0] tile_col_idx_w;
logic [RESULT_STATUS_W-1:0] result_status_r;
wire load_v_resp_expected_w;
wire load_w_resp_expected_w;

logic [31:0] weight_tile_index_w;
logic [ADDR_W-1:0] weight_tile_base_w;
logic [ADDR_W-1:0] vector_tile_base_w;
logic [ADDR_W-1:0] row_result_base_w;
integer lane_idx_i;
integer elem_idx_i;

assign issue_ready = (state_r == ST_IDLE);
assign sram_rd_id = req_id_r;
assign load_v_resp_expected_w =
    ((state_r == ST_LOAD_V_REQ) &&
     (load_v_req_accepted_r || (sram_rd_valid && sram_rd_ready))) ||
    (state_r == ST_LOAD_V_RESP) ||
    (state_r == ST_LOAD_V_DRAIN);
assign load_w_resp_expected_w =
    ((state_r == ST_LOAD_W_REQ) &&
     (load_w_req_accepted_r || (sram_rd_valid && sram_rd_ready))) ||
    (state_r == ST_LOAD_W_RESP) ||
    (state_r == ST_LOAD_W_DRAIN);
assign sram_resp_ready =
    ((load_v_resp_expected_w || load_w_resp_expected_w ||
      (state_r == ST_WRITE) || (state_r == ST_HOLD))) &&
    (sram_resp_id == req_id_r);
assign result_valid = (state_r == ST_HOLD);
assign result_addr = result_addr_r;
assign result_data = final_result_r[0 +: DATA_BUS_W];
assign result_status = result_status_r;

assign weight_tile_index_w = (tile_row_r * tile_cols_total_r) + tile_col_r;
assign weight_tile_base_w = weight_base_addr_r + addr_from_u32(weight_tile_index_w * WEIGHT_BEATS_PER_TILE);
assign vector_tile_base_w = vector_addr_r + addr_from_u32(tile_col_r * VECTOR_BEATS_PER_TILE);
assign row_result_base_w = result_addr_r + addr_from_u32(tile_row_r * RESULT_BEATS_PER_TILE);

always_comb begin
    sram_rd_valid = 1'b0;
    sram_rd_addr = {ADDR_W{1'b0}};
    sram_wr_valid = 1'b0;
    sram_wr_addr = {ADDR_W{1'b0}};
    sram_wr_data = {DATA_BUS_W{1'b0}};

    case (state_r)
        ST_LOAD_V_REQ: begin
            sram_rd_valid = !load_v_req_accepted_r;
            sram_rd_addr = vector_tile_base_w + addr_from_u16(beat_idx_r);
        end
        ST_LOAD_W_REQ: begin
            sram_rd_valid = !load_w_req_accepted_r;
            sram_rd_addr = weight_tile_base_w + addr_from_u16(beat_idx_r);
        end
        ST_WRITE: begin
            sram_wr_valid = 1'b1;
            sram_wr_addr = row_result_base_w + addr_from_u16(beat_idx_r);
            for (elem_idx_i = 0; elem_idx_i < ELEMS_PER_BEAT; elem_idx_i = elem_idx_i + 1) begin
                sram_wr_data[(elem_idx_i*DATA_WIDTH) +: DATA_WIDTH] =
                    lane_value_for_write(beat_idx_r, elem_idx_i, matrix_rows_r, tile_row_r, final_result_r);
            end
        end
        default: begin
        end
    endcase
end

fp16_matvec_tile_acc #(
    .LANES(LANES),
    .COLS(COLS),
    .DATA_WIDTH(DATA_WIDTH)
) u_fp16_matvec_tile_acc (
    .clk(clk),
    .rst_n(rst_n),
    .start(tile_start_r),
    .vector_val(tile_vector_val_r),
    .weights(tile_weights_r),
    .init_accum(partial_sum_r),
    .accum_en(tile_accum_en_r),
    .busy(tile_busy_w),
    .done(tile_done_w),
    .result(tile_result_w),
    .col_idx(tile_col_idx_w)
);

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state_r <= ST_IDLE;
        weight_base_addr_r <= {ADDR_W{1'b0}};
        vector_addr_r <= {ADDR_W{1'b0}};
        result_addr_r <= {ADDR_W{1'b0}};
        req_id_r <= {REQ_ID_W{1'b0}};
        matrix_rows_r <= 16'd0;
        matrix_cols_r <= 16'd0;
        tile_rows_total_r <= 16'd0;
        tile_cols_total_r <= 16'd0;
        tile_row_r <= 16'd0;
        tile_col_r <= 16'd0;
        beat_idx_r <= 16'd0;
        feed_col_r <= 7'd0;
        tile_vector_val_r <= {DATA_WIDTH{1'b0}};
        tile_weights_r <= {(LANES*DATA_WIDTH){1'b0}};
        partial_sum_r <= {(LANES*DATA_WIDTH){1'b0}};
        final_result_r <= {(LANES*DATA_WIDTH){1'b0}};
        vector_tile_r <= {(COLS*DATA_WIDTH){1'b0}};
        weight_tile_r <= {(LANES*COLS*DATA_WIDTH){1'b0}};
        tile_start_r <= 1'b0;
        tile_accum_en_r <= 1'b0;
        load_v_req_accepted_r <= 1'b0;
        load_w_req_accepted_r <= 1'b0;
        result_status_r <= {RESULT_STATUS_W{1'b0}};
    end else begin
        tile_start_r <= 1'b0;

        case (state_r)
            ST_IDLE: begin
                if (issue_valid) begin
                    weight_base_addr_r <= issue_weight_base_addr;
                    vector_addr_r <= issue_vector_addr;
                    result_addr_r <= issue_result_addr;
                    req_id_r <= issue_req_id;
                    matrix_rows_r <= issue_matrix_rows;
                    matrix_cols_r <= issue_matrix_cols;
                    tile_rows_total_r <= ceil_div_u16(issue_matrix_rows, LANES);
                    tile_cols_total_r <= ceil_div_u16(issue_matrix_cols, COLS);
                    tile_row_r <= 16'd0;
                    tile_col_r <= 16'd0;
                    beat_idx_r <= 16'd0;
                    partial_sum_r <= {(LANES*DATA_WIDTH){1'b0}};
                    final_result_r <= {(LANES*DATA_WIDTH){1'b0}};
                    load_v_req_accepted_r <= 1'b0;
                    load_w_req_accepted_r <= 1'b0;
                    result_status_r <= RESULT_STATUS_OK;
                    if ((issue_matrix_rows == 16'd0) || (issue_matrix_cols == 16'd0)) begin
                        state_r <= ST_HOLD;
                    end else begin
                        state_r <= ST_LOAD_V_REQ;
                    end
                end
            end

            ST_LOAD_V_REQ: begin
                if ((load_v_req_accepted_r || (sram_rd_valid && sram_rd_ready)) &&
                    sram_resp_valid && sram_resp_ready) begin
                    vector_tile_r[(beat_idx_r*DATA_BUS_W) +: DATA_BUS_W] <= sram_resp_data;
                    load_v_req_accepted_r <= 1'b0;
                    state_r <= ST_LOAD_V_DRAIN;
                end else if (sram_rd_valid && sram_rd_ready) begin
                    load_v_req_accepted_r <= 1'b1;
                    state_r <= ST_LOAD_V_RESP;
                end
            end

            ST_LOAD_V_RESP: begin
                if (sram_resp_valid && sram_resp_ready) begin
                    vector_tile_r[(beat_idx_r*DATA_BUS_W) +: DATA_BUS_W] <= sram_resp_data;
                    load_v_req_accepted_r <= 1'b0;
                    state_r <= ST_LOAD_V_DRAIN;
                end
            end

            ST_LOAD_V_DRAIN: begin
                if (!(sram_resp_valid && sram_resp_ready)) begin
                    if (beat_idx_r == (VECTOR_BEATS_PER_TILE - 1)) begin
                        beat_idx_r <= 16'd0;
                        load_w_req_accepted_r <= 1'b0;
                        state_r <= ST_LOAD_W_REQ;
                    end else begin
                        beat_idx_r <= beat_idx_r + 16'd1;
                        state_r <= ST_LOAD_V_REQ;
                    end
                end
            end

            ST_LOAD_W_REQ: begin
                if ((load_w_req_accepted_r || (sram_rd_valid && sram_rd_ready)) &&
                    sram_resp_valid && sram_resp_ready) begin
                    weight_tile_r[(beat_idx_r*DATA_BUS_W) +: DATA_BUS_W] <= sram_resp_data;
                    load_w_req_accepted_r <= 1'b0;
                    state_r <= ST_LOAD_W_DRAIN;
                end else if (sram_rd_valid && sram_rd_ready) begin
                    load_w_req_accepted_r <= 1'b1;
                    state_r <= ST_LOAD_W_RESP;
                end
            end

            ST_LOAD_W_RESP: begin
                if (sram_resp_valid && sram_resp_ready) begin
                    weight_tile_r[(beat_idx_r*DATA_BUS_W) +: DATA_BUS_W] <= sram_resp_data;
                    load_w_req_accepted_r <= 1'b0;
                    state_r <= ST_LOAD_W_DRAIN;
                end
            end

            ST_LOAD_W_DRAIN: begin
                if (!(sram_resp_valid && sram_resp_ready)) begin
                    if (beat_idx_r == (WEIGHT_BEATS_PER_TILE - 1)) begin
                        beat_idx_r <= 16'd0;
                        feed_col_r <= 7'd0;
                        tile_accum_en_r <= (tile_col_r != 16'd0);
                        tile_start_r <= 1'b1;
                        tile_vector_val_r <= vector_tile_r[0 +: DATA_WIDTH];
                        for (lane_idx_i = 0; lane_idx_i < LANES; lane_idx_i = lane_idx_i + 1) begin
                            tile_weights_r[(lane_idx_i*DATA_WIDTH) +: DATA_WIDTH] <=
                                weight_tile_r[(lane_idx_i*DATA_WIDTH) +: DATA_WIDTH];
                        end
                        state_r <= ST_COMPUTE;
                    end else begin
                        beat_idx_r <= beat_idx_r + 16'd1;
                        state_r <= ST_LOAD_W_REQ;
                    end
                end
            end

            ST_COMPUTE: begin
                if (tile_busy_w && (feed_col_r < (COLS - 1))) begin
                    feed_col_r <= feed_col_r + 7'd1;
                    tile_vector_val_r <= vector_tile_r[((feed_col_r + 7'd1)*DATA_WIDTH) +: DATA_WIDTH];
                    for (lane_idx_i = 0; lane_idx_i < LANES; lane_idx_i = lane_idx_i + 1) begin
                        tile_weights_r[(lane_idx_i*DATA_WIDTH) +: DATA_WIDTH] <=
                            weight_tile_r[((((feed_col_r + 7'd1) * LANES) + lane_idx_i)*DATA_WIDTH) +: DATA_WIDTH];
                    end
                end

                if (tile_done_w) begin
                    partial_sum_r <= tile_result_w;
                    if (tile_col_r == (tile_cols_total_r - 1)) begin
                        final_result_r <= tile_result_w;
                        beat_idx_r <= 16'd0;
                        load_v_req_accepted_r <= 1'b0;
                        load_w_req_accepted_r <= 1'b0;
                        state_r <= ST_WRITE;
                    end else begin
                        tile_col_r <= tile_col_r + 16'd1;
                        beat_idx_r <= 16'd0;
                        load_v_req_accepted_r <= 1'b0;
                        load_w_req_accepted_r <= 1'b0;
                        state_r <= ST_LOAD_V_REQ;
                    end
                end
            end

            ST_WRITE: begin
                if (sram_wr_valid && sram_wr_ready) begin
                    if (beat_idx_r == (RESULT_BEATS_PER_TILE - 1)) begin
                        if (tile_row_r == (tile_rows_total_r - 1)) begin
                            state_r <= ST_HOLD;
                        end else begin
                            tile_row_r <= tile_row_r + 16'd1;
                            tile_col_r <= 16'd0;
                            beat_idx_r <= 16'd0;
                            partial_sum_r <= {(LANES*DATA_WIDTH){1'b0}};
                            final_result_r <= {(LANES*DATA_WIDTH){1'b0}};
                            load_v_req_accepted_r <= 1'b0;
                            load_w_req_accepted_r <= 1'b0;
                            state_r <= ST_LOAD_V_REQ;
                        end
                    end else begin
                        beat_idx_r <= beat_idx_r + 16'd1;
                    end
                end
            end

            ST_HOLD: begin
                if (result_valid && result_ready) begin
                    state_r <= ST_IDLE;
                end
            end

            default: begin
                state_r <= ST_IDLE;
            end
        endcase
    end
end

endmodule
