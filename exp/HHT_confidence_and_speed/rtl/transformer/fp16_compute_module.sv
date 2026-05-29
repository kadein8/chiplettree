`include "config/interface_params.vh"
`include "config/memory_params.vh"
`include "config/model_params.vh"
`timescale 1ns/1ps

module fp16_compute_module #(
    parameter integer LANES = `FP16_TILE_LANES,
    parameter integer COLS = `FP16_TILE_COLS,
    parameter integer DATA_WIDTH = `FP16_TILE_DATA_W,
    parameter integer ADDR_W = `SRAM_ADDR_W,
    parameter integer DATA_BUS_W = `SRAM_WDATA_W,
    parameter integer TOKEN_ID_W = `TOKEN_ID_W,
    parameter integer REQ_ID_W = `REQ_ID_W,
    parameter integer RESULT_STATUS_W = 2,
    parameter [RESULT_STATUS_W-1:0] RESULT_STATUS_OK = 2'b00
) (
    input  logic                          clk,
    input  logic                          rst_n,

    input  logic                          issue_valid,
    output logic                          issue_ready,
    input  logic [TOKEN_ID_W-1:0]         issue_token_id,
    input  logic [ADDR_W-1:0]             issue_src_addr,
    input  logic [ADDR_W-1:0]             issue_dst_addr,
    input  logic [REQ_ID_W-1:0]           issue_req_id,
    input  logic [15:0]                   issue_weight_rows,
    input  logic [15:0]                   issue_weight_cols,

    output logic                          sram_rd_valid,
    input  logic                          sram_rd_ready,
    output logic [ADDR_W-1:0]             sram_rd_addr,
    output logic [REQ_ID_W-1:0]           sram_rd_id,

    input  logic                          sram_resp_valid,
    output logic                          sram_resp_ready,
    input  logic [DATA_BUS_W-1:0]         sram_resp_data,
    input  logic [REQ_ID_W-1:0]           sram_resp_id,

    output logic                          sram_wr_valid,
    input  logic                          sram_wr_ready,
    output logic [ADDR_W-1:0]             sram_wr_addr,
    output logic [DATA_BUS_W-1:0]         sram_wr_data,

    output logic                          result_valid,
    input  logic                          result_ready,
    output logic [TOKEN_ID_W-1:0]         result_token_id,
    output logic [ADDR_W-1:0]             result_addr,
    output logic [DATA_BUS_W-1:0]         result_data,
    output logic [RESULT_STATUS_W-1:0]    result_status
);

localparam integer ELEMS_PER_BEAT = DATA_BUS_W / DATA_WIDTH;
localparam integer WEIGHT_WORDS = LANES * COLS;
localparam integer WEIGHT_BEATS = WEIGHT_WORDS / ELEMS_PER_BEAT;
localparam integer VECTOR_BEATS = COLS / ELEMS_PER_BEAT;
localparam integer RESULT_BEATS = LANES / ELEMS_PER_BEAT;
localparam [2:0]
    ST_IDLE         = 3'd0,
    ST_LOAD_WEIGHTS = 3'd1,
    ST_LOAD_VECTOR  = 3'd2,
    ST_COMPUTE      = 3'd3,
    ST_WRITE_RESULT = 3'd4,
    ST_HOLD_RESULT  = 3'd5;

logic [2:0] state_r;
logic [TOKEN_ID_W-1:0] token_id_r;
logic [ADDR_W-1:0] src_addr_r;
logic [ADDR_W-1:0] dst_addr_r;
logic [REQ_ID_W-1:0] req_id_r;
logic [15:0] weight_rows_r;
logic [15:0] weight_cols_r;
logic [15:0] rd_req_count_r;
logic [15:0] rd_resp_count_r;
logic [15:0] wr_count_r;
logic [6:0] feed_col_r;
logic [ADDR_W-1:0] vector_base_addr_w;
logic tile_start_r;
logic [DATA_WIDTH-1:0] tile_vector_val_r;
logic [(LANES*DATA_WIDTH)-1:0] tile_weights_r;
logic tile_busy_w;
logic tile_done_w;
logic [(LANES*DATA_WIDTH)-1:0] tile_result_w;
logic [6:0] tile_col_idx_w;
logic [(WEIGHT_WORDS*DATA_WIDTH)-1:0] weights_mem_r;
logic [(COLS*DATA_WIDTH)-1:0] vector_mem_r;
logic [(LANES*DATA_WIDTH)-1:0] packed_result_r;
logic [RESULT_STATUS_W-1:0] result_status_r;
logic load_weights_rd_valid_w;
logic load_vector_rd_valid_w;
logic [ADDR_W-1:0] weight_beats_addr_w;
logic [ADDR_W-1:0] rd_req_count_addr_w;
logic [ADDR_W-1:0] wr_count_addr_w;
integer beat_idx_i;
integer lane_idx_i;

assign weight_beats_addr_w = WEIGHT_BEATS;
assign rd_req_count_addr_w = {{(ADDR_W-16){1'b0}}, rd_req_count_r};
assign wr_count_addr_w = {{(ADDR_W-16){1'b0}}, wr_count_r};
assign vector_base_addr_w = src_addr_r + weight_beats_addr_w;
assign load_weights_rd_valid_w =
    (state_r == ST_LOAD_WEIGHTS) && (rd_req_count_r < WEIGHT_BEATS);
assign load_vector_rd_valid_w =
    (state_r == ST_LOAD_VECTOR) && (rd_req_count_r < VECTOR_BEATS);

assign issue_ready = (state_r == ST_IDLE);
assign sram_rd_valid = load_weights_rd_valid_w || load_vector_rd_valid_w;
assign sram_rd_id = req_id_r;
assign sram_resp_ready =
    ((state_r == ST_LOAD_WEIGHTS) || (state_r == ST_LOAD_VECTOR)) &&
    (sram_resp_id == req_id_r);
assign sram_wr_valid = (state_r == ST_WRITE_RESULT);
assign sram_wr_addr = dst_addr_r + wr_count_addr_w;
assign result_valid = (state_r == ST_HOLD_RESULT);
assign result_token_id = token_id_r;
assign result_addr = dst_addr_r;
assign result_data = packed_result_r[0 +: DATA_BUS_W];
assign result_status = result_status_r;

always_comb begin
    if (state_r == ST_LOAD_WEIGHTS) begin
        sram_rd_addr = src_addr_r + rd_req_count_addr_w;
    end else begin
        sram_rd_addr = vector_base_addr_w + rd_req_count_addr_w;
    end
end

always_comb begin
    sram_wr_data = {DATA_BUS_W{1'b0}};
    for (beat_idx_i = 0; beat_idx_i < ELEMS_PER_BEAT; beat_idx_i = beat_idx_i + 1) begin
        sram_wr_data[(beat_idx_i*DATA_WIDTH) +: DATA_WIDTH] =
            packed_result_r[((wr_count_r*ELEMS_PER_BEAT + beat_idx_i)*DATA_WIDTH) +: DATA_WIDTH];
    end
end

fp16_matvec_tile #(
    .LANES(LANES),
    .COLS(COLS),
    .DATA_WIDTH(DATA_WIDTH)
) u_fp16_matvec_tile (
    .clk(clk),
    .rst_n(rst_n),
    .start(tile_start_r),
    .vector_val(tile_vector_val_r),
    .weights(tile_weights_r),
    .busy(tile_busy_w),
    .done(tile_done_w),
    .result(tile_result_w),
    .col_idx(tile_col_idx_w)
);

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state_r <= ST_IDLE;
        token_id_r <= {TOKEN_ID_W{1'b0}};
        src_addr_r <= {ADDR_W{1'b0}};
        dst_addr_r <= {ADDR_W{1'b0}};
        req_id_r <= {REQ_ID_W{1'b0}};
        weight_rows_r <= 16'd0;
        weight_cols_r <= 16'd0;
        rd_req_count_r <= 16'd0;
        rd_resp_count_r <= 16'd0;
        wr_count_r <= 16'd0;
        feed_col_r <= 7'd0;
        tile_start_r <= 1'b0;
        tile_vector_val_r <= {DATA_WIDTH{1'b0}};
        tile_weights_r <= {(LANES*DATA_WIDTH){1'b0}};
        weights_mem_r <= {(WEIGHT_WORDS*DATA_WIDTH){1'b0}};
        vector_mem_r <= {(COLS*DATA_WIDTH){1'b0}};
        packed_result_r <= {(LANES*DATA_WIDTH){1'b0}};
        result_status_r <= {RESULT_STATUS_W{1'b0}};
    end else begin
        tile_start_r <= 1'b0;

        case (state_r)
            ST_IDLE: begin
                if (issue_valid) begin
                    token_id_r <= issue_token_id;
                    src_addr_r <= issue_src_addr;
                    dst_addr_r <= issue_dst_addr;
                    req_id_r <= issue_req_id;
                    weight_rows_r <= issue_weight_rows;
                    weight_cols_r <= issue_weight_cols;
                    rd_req_count_r <= 16'd0;
                    rd_resp_count_r <= 16'd0;
                    wr_count_r <= 16'd0;
                    feed_col_r <= 7'd0;
                    packed_result_r <= {(LANES*DATA_WIDTH){1'b0}};
                    result_status_r <= RESULT_STATUS_OK;
                    state_r <= ST_LOAD_WEIGHTS;
                end
            end

            ST_LOAD_WEIGHTS: begin
                if (sram_rd_valid && sram_rd_ready) begin
                    rd_req_count_r <= rd_req_count_r + 16'd1;
                end
                if (sram_resp_valid && sram_resp_ready) begin
                    weights_mem_r[(rd_resp_count_r*DATA_BUS_W) +: DATA_BUS_W] <= sram_resp_data;
                    if (rd_resp_count_r == (WEIGHT_BEATS - 1)) begin
                        rd_req_count_r <= 16'd0;
                        rd_resp_count_r <= 16'd0;
                        state_r <= ST_LOAD_VECTOR;
                    end else begin
                        rd_resp_count_r <= rd_resp_count_r + 16'd1;
                    end
                end
            end

            ST_LOAD_VECTOR: begin
                if (sram_rd_valid && sram_rd_ready) begin
                    rd_req_count_r <= rd_req_count_r + 16'd1;
                end
                if (sram_resp_valid && sram_resp_ready) begin
                    vector_mem_r[(rd_resp_count_r*DATA_BUS_W) +: DATA_BUS_W] <= sram_resp_data;
                    if (rd_resp_count_r == (VECTOR_BEATS - 1)) begin
                        rd_resp_count_r <= 16'd0;
                        feed_col_r <= 7'd0;
                        tile_start_r <= 1'b1;
                        tile_vector_val_r <= vector_mem_r[0 +: DATA_WIDTH];
                        for (lane_idx_i = 0; lane_idx_i < LANES; lane_idx_i = lane_idx_i + 1) begin
                            tile_weights_r[(lane_idx_i*DATA_WIDTH) +: DATA_WIDTH] <=
                                weights_mem_r[((lane_idx_i)*DATA_WIDTH) +: DATA_WIDTH];
                        end
                        state_r <= ST_COMPUTE;
                    end else begin
                        rd_resp_count_r <= rd_resp_count_r + 16'd1;
                    end
                end
            end

            ST_COMPUTE: begin
                if (tile_busy_w && (feed_col_r < (COLS - 1))) begin
                    feed_col_r <= feed_col_r + 7'd1;
                    tile_vector_val_r <= vector_mem_r[((feed_col_r + 7'd1)*DATA_WIDTH) +: DATA_WIDTH];
                    for (lane_idx_i = 0; lane_idx_i < LANES; lane_idx_i = lane_idx_i + 1) begin
                        tile_weights_r[(lane_idx_i*DATA_WIDTH) +: DATA_WIDTH] <=
                            weights_mem_r[(((feed_col_r + 7'd1)*LANES + lane_idx_i)*DATA_WIDTH) +: DATA_WIDTH];
                    end
                end

                if (tile_done_w) begin
                    packed_result_r <= tile_result_w;
                    wr_count_r <= 16'd0;
                    state_r <= ST_WRITE_RESULT;
                end
            end

            ST_WRITE_RESULT: begin
                if (sram_wr_valid && sram_wr_ready) begin
                    if (wr_count_r == (RESULT_BEATS - 1)) begin
                        state_r <= ST_HOLD_RESULT;
                    end else begin
                        wr_count_r <= wr_count_r + 16'd1;
                    end
                end
            end

            ST_HOLD_RESULT: begin
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
