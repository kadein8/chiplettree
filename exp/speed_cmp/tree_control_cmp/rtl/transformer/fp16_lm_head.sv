`include "config/interface_params.vh"
`include "config/memory_params.vh"
`include "config/model_params.vh"
`timescale 1ns/1ps

module fp16_lm_head #(
    parameter integer DATA_WIDTH = `FP16_TILE_DATA_W,
    parameter integer ADDR_W = `SRAM_ADDR_W,
    parameter integer DATA_BUS_W = `SRAM_WDATA_W,
    parameter integer REQ_ID_W = `REQ_ID_W,
    parameter integer HIDDEN_DIM = `QWEN3_DMODEL,
    parameter integer VOCAB_SIZE = `QWEN3_VOCAB_SIZE,
    parameter integer RESULT_STATUS_W = 2,
    parameter integer TOP_K_MAX = 128
) (
    input  logic                  clk,
    input  logic                  rst_n,
    input  logic                  issue_valid,
    output logic                  issue_ready,
    input  logic [ADDR_W-1:0]     issue_hidden_addr,
    input  logic [ADDR_W-1:0]     issue_emb_weight_addr,
    input  logic                  issue_do_sample,
    input  logic [15:0]           issue_temperature,
    input  logic [6:0]            issue_top_k,
    input  logic [15:0]           issue_top_p,
    input  logic [REQ_ID_W-1:0]   issue_req_id,

    output logic                  sram_rd_valid,
    input  logic                  sram_rd_ready,
    output logic [ADDR_W-1:0]     sram_rd_addr,
    output logic [REQ_ID_W-1:0]   sram_rd_id,
    input  logic                  sram_resp_valid,
    output logic                  sram_resp_ready,
    input  logic [DATA_BUS_W-1:0] sram_resp_data,
    input  logic [REQ_ID_W-1:0]   sram_resp_id,

    output logic                  result_valid,
    input  logic                  result_ready,
    output logic [31:0]           result_token_id,
    output logic [15:0]           result_logit
);

localparam integer LANES = `FP16_TILE_LANES;
localparam integer COLS = `FP16_TILE_COLS;
localparam integer ELEMS_PER_BEAT = DATA_BUS_W / DATA_WIDTH;
localparam integer HIDDEN_BEATS = HIDDEN_DIM / ELEMS_PER_BEAT;
localparam integer VOCAB_TILE_ROWS = (VOCAB_SIZE + LANES - 1) / LANES;
localparam integer WEIGHT_TILE_BEATS = (LANES * COLS) / ELEMS_PER_BEAT;
localparam logic [3:0]
    ST_IDLE         = 4'd0,
    ST_LOAD_H_REQ   = 4'd1,
    ST_LOAD_H_RESP  = 4'd2,
    ST_LOAD_H_DRAIN = 4'd3,
    ST_LOAD_W_REQ   = 4'd4,
    ST_LOAD_W_RESP  = 4'd5,
    ST_LOAD_W_DRAIN = 4'd6,
    ST_TILE_RUN     = 4'd7,
    ST_TILE_UPDATE  = 4'd8,
    ST_SAMPLE       = 4'd9,
    ST_HOLD         = 4'd10;

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

function automatic [15:0] fp16_max;
    input [15:0] a;
    input [15:0] b;
    begin
        if (a[15] != b[15])
            fp16_max = a[15] ? b : a;
        else if (!a[15])
            fp16_max = (a[14:0] >= b[14:0]) ? a : b;
        else
            fp16_max = (a[14:0] <= b[14:0]) ? a : b;
    end
endfunction

function automatic bit fp16_gt;
    input [15:0] a;
    input [15:0] b;
    begin
        if (a == b) begin
            fp16_gt = 1'b0;
        end else if (a[15] != b[15]) begin
            fp16_gt = b[15];
        end else if (!a[15]) begin
            fp16_gt = (a[14:0] > b[14:0]);
        end else begin
            fp16_gt = (a[14:0] < b[14:0]);
        end
    end
endfunction

logic [3:0] state_r;
logic [ADDR_W-1:0] hidden_addr_r;
logic [ADDR_W-1:0] emb_weight_addr_r;
logic [REQ_ID_W-1:0] req_id_r;
logic do_sample_r;
logic [15:0] temperature_r;
logic [6:0] top_k_r;
logic [15:0] top_p_r;
logic [15:0] hidden_beat_idx_r;
logic [15:0] weight_beat_idx_r;
logic [15:0] tile_row_idx_r;
logic [6:0] feed_col_r;
logic [31:0] argmax_token_r;
logic [15:0] top_logit_r;
logic [(COLS*DATA_WIDTH)-1:0] hidden_mem_r;
logic [(LANES*COLS*DATA_WIDTH)-1:0] weight_tile_r;
logic [DATA_WIDTH-1:0] tile_vector_val_r;
logic [(LANES*DATA_WIDTH)-1:0] tile_weights_r;
logic tile_start_r;
logic tile_busy_w;
logic tile_done_w;
logic [(LANES*DATA_WIDTH)-1:0] tile_result_w;
logic [6:0] tile_col_idx_w;
logic sample_start_r;
logic sample_done_w;
logic [31:0] sampled_token_w;
logic load_h_req_accepted_r;
logic load_w_req_accepted_r;
logic [15:0] top_k_values_r [0:TOP_K_MAX-1];
logic [31:0] top_k_indices_r [0:TOP_K_MAX-1];
logic [15:0] worst_top_k_value_r;
logic [6:0] worst_top_k_slot_r;

integer lane_idx_i;
integer topk_idx_i;
integer update_idx_i;
reg [15:0] candidate_value_v;
reg [31:0] candidate_token_v;
reg [15:0] best_logit_v;
reg [31:0] best_token_v;

assign issue_ready = (state_r == ST_IDLE);
assign sram_rd_id = req_id_r;
assign sram_resp_ready =
    ((((state_r == ST_LOAD_H_REQ) &&
       (load_h_req_accepted_r || (sram_rd_valid && sram_rd_ready))) ||
      (state_r == ST_LOAD_H_RESP) ||
      (state_r == ST_LOAD_H_DRAIN) ||
      ((state_r == ST_LOAD_W_REQ) &&
       (load_w_req_accepted_r || (sram_rd_valid && sram_rd_ready))) ||
      (state_r == ST_LOAD_W_RESP) ||
      (state_r == ST_LOAD_W_DRAIN)) &&
     (sram_resp_id == req_id_r));
assign result_valid = (state_r == ST_HOLD);
assign result_token_id = do_sample_r ? sampled_token_w : argmax_token_r;
assign result_logit = top_logit_r;

always_comb begin
    sram_rd_valid = 1'b0;
    sram_rd_addr = {ADDR_W{1'b0}};

    case (state_r)
        ST_LOAD_H_REQ: begin
            sram_rd_valid = !load_h_req_accepted_r;
            sram_rd_addr = hidden_addr_r + addr_from_u16(hidden_beat_idx_r);
        end
        ST_LOAD_W_REQ: begin
            sram_rd_valid = !load_w_req_accepted_r;
            sram_rd_addr = emb_weight_addr_r +
                           addr_from_u32((tile_row_idx_r * WEIGHT_TILE_BEATS) + weight_beat_idx_r);
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
    .init_accum({(LANES*DATA_WIDTH){1'b0}}),
    .accum_en(1'b0),
    .busy(tile_busy_w),
    .done(tile_done_w),
    .result(tile_result_w),
    .col_idx(tile_col_idx_w)
);

fp16_sampler #(
    .TOP_K_MAX(TOP_K_MAX)
) u_fp16_sampler (
    .clk(clk),
    .rst_n(rst_n),
    .start(sample_start_r),
    .argmax_token(argmax_token_r),
    .top_logit(top_logit_r),
    .temperature(temperature_r),
    .top_k(top_k_r),
    .top_p(top_p_r),
    .top_k_values(top_k_values_r),
    .top_k_indices(top_k_indices_r),
    .busy(),
    .done(sample_done_w),
    .sampled_token(sampled_token_w)
);

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state_r <= ST_IDLE;
        hidden_addr_r <= {ADDR_W{1'b0}};
        emb_weight_addr_r <= {ADDR_W{1'b0}};
        req_id_r <= {REQ_ID_W{1'b0}};
        do_sample_r <= 1'b0;
        temperature_r <= 16'h3c00;
        top_k_r <= 7'd1;
        top_p_r <= 16'h3c00;
        hidden_beat_idx_r <= 16'd0;
        weight_beat_idx_r <= 16'd0;
        tile_row_idx_r <= 16'd0;
        feed_col_r <= 7'd0;
        argmax_token_r <= 32'd0;
        top_logit_r <= 16'hfc00;
        hidden_mem_r <= {(COLS*DATA_WIDTH){1'b0}};
        weight_tile_r <= {(LANES*COLS*DATA_WIDTH){1'b0}};
        tile_vector_val_r <= {DATA_WIDTH{1'b0}};
        tile_weights_r <= {(LANES*DATA_WIDTH){1'b0}};
        tile_start_r <= 1'b0;
        sample_start_r <= 1'b0;
        load_h_req_accepted_r <= 1'b0;
        load_w_req_accepted_r <= 1'b0;
        worst_top_k_value_r <= 16'hfc00;
        worst_top_k_slot_r <= 7'd0;
        for (topk_idx_i = 0; topk_idx_i < TOP_K_MAX; topk_idx_i = topk_idx_i + 1) begin
            top_k_values_r[topk_idx_i] <= 16'hfc00;
            top_k_indices_r[topk_idx_i] <= 32'd0;
        end
    end else begin
        tile_start_r <= 1'b0;
        sample_start_r <= 1'b0;

        case (state_r)
            ST_IDLE: begin
                if (issue_valid) begin
                    hidden_addr_r <= issue_hidden_addr;
                    emb_weight_addr_r <= issue_emb_weight_addr;
                    req_id_r <= issue_req_id;
                    do_sample_r <= issue_do_sample;
                    temperature_r <= issue_temperature;
                    top_k_r <= (issue_top_k == 7'd0) ? 7'd1 : issue_top_k;
                    top_p_r <= issue_top_p;
                    hidden_beat_idx_r <= 16'd0;
                    weight_beat_idx_r <= 16'd0;
                    tile_row_idx_r <= 16'd0;
                    argmax_token_r <= 32'd0;
                    top_logit_r <= 16'hfc00;
                    worst_top_k_value_r <= 16'hfc00;
                    worst_top_k_slot_r <= 7'd0;
                    load_h_req_accepted_r <= 1'b0;
                    load_w_req_accepted_r <= 1'b0;
                    for (topk_idx_i = 0; topk_idx_i < TOP_K_MAX; topk_idx_i = topk_idx_i + 1) begin
                        top_k_values_r[topk_idx_i] <= 16'hfc00;
                        top_k_indices_r[topk_idx_i] <= 32'd0;
                    end
                    state_r <= ST_LOAD_H_REQ;
                end
            end

            ST_LOAD_H_REQ: begin
                if ((load_h_req_accepted_r || (sram_rd_valid && sram_rd_ready)) &&
                    sram_resp_valid && sram_resp_ready) begin
                    load_h_req_accepted_r <= 1'b0;
                    hidden_mem_r[(hidden_beat_idx_r*DATA_BUS_W) +: DATA_BUS_W] <= sram_resp_data;
                    load_w_req_accepted_r <= 1'b0;
                    state_r <= ST_LOAD_H_DRAIN;
                end else if (sram_rd_valid && sram_rd_ready) begin
                    load_h_req_accepted_r <= 1'b1;
                    state_r <= ST_LOAD_H_RESP;
                end
            end

            ST_LOAD_H_RESP: begin
                if (sram_resp_valid && sram_resp_ready) begin
                    load_h_req_accepted_r <= 1'b0;
                    hidden_mem_r[(hidden_beat_idx_r*DATA_BUS_W) +: DATA_BUS_W] <= sram_resp_data;
                    load_w_req_accepted_r <= 1'b0;
                    state_r <= ST_LOAD_H_DRAIN;
                end
            end

            ST_LOAD_H_DRAIN: begin
                if (!(sram_resp_valid && sram_resp_ready)) begin
                    if (hidden_beat_idx_r == (HIDDEN_BEATS - 1)) begin
                        weight_beat_idx_r <= 16'd0;
                        load_w_req_accepted_r <= 1'b0;
                        state_r <= ST_LOAD_W_REQ;
                    end else begin
                        hidden_beat_idx_r <= hidden_beat_idx_r + 16'd1;
                        state_r <= ST_LOAD_H_REQ;
                    end
                end
            end

            ST_LOAD_W_REQ: begin
                if ((load_w_req_accepted_r || (sram_rd_valid && sram_rd_ready)) &&
                    sram_resp_valid && sram_resp_ready) begin
                    load_w_req_accepted_r <= 1'b0;
                    weight_tile_r[(weight_beat_idx_r*DATA_BUS_W) +: DATA_BUS_W] <= sram_resp_data;
                    state_r <= ST_LOAD_W_DRAIN;
                end else if (sram_rd_valid && sram_rd_ready) begin
                    load_w_req_accepted_r <= 1'b1;
                    state_r <= ST_LOAD_W_RESP;
                end
            end

            ST_LOAD_W_RESP: begin
                if (sram_resp_valid && sram_resp_ready) begin
                    load_w_req_accepted_r <= 1'b0;
                    weight_tile_r[(weight_beat_idx_r*DATA_BUS_W) +: DATA_BUS_W] <= sram_resp_data;
                    state_r <= ST_LOAD_W_DRAIN;
                end
            end

            ST_LOAD_W_DRAIN: begin
                if (!(sram_resp_valid && sram_resp_ready)) begin
                    if (weight_beat_idx_r == (WEIGHT_TILE_BEATS - 1)) begin
                        feed_col_r <= 7'd0;
                        tile_vector_val_r <= hidden_mem_r[0 +: DATA_WIDTH];
                        for (lane_idx_i = 0; lane_idx_i < LANES; lane_idx_i = lane_idx_i + 1)
                            tile_weights_r[(lane_idx_i*DATA_WIDTH) +: DATA_WIDTH] <=
                                weight_tile_r[(lane_idx_i*DATA_WIDTH) +: DATA_WIDTH];
                        tile_start_r <= 1'b1;
                        state_r <= ST_TILE_RUN;
                    end else begin
                        weight_beat_idx_r <= weight_beat_idx_r + 16'd1;
                        state_r <= ST_LOAD_W_REQ;
                    end
                end
            end

            ST_TILE_RUN: begin
                if (tile_busy_w && (feed_col_r < (COLS - 1))) begin
                    feed_col_r <= feed_col_r + 7'd1;
                    tile_vector_val_r <= hidden_mem_r[((feed_col_r + 7'd1)*DATA_WIDTH) +: DATA_WIDTH];
                    for (lane_idx_i = 0; lane_idx_i < LANES; lane_idx_i = lane_idx_i + 1)
                        tile_weights_r[(lane_idx_i*DATA_WIDTH) +: DATA_WIDTH] <=
                            weight_tile_r[((((feed_col_r + 7'd1) * LANES) + lane_idx_i)*DATA_WIDTH) +: DATA_WIDTH];
                end

                if (tile_done_w)
                    state_r <= ST_TILE_UPDATE;
            end

            ST_TILE_UPDATE: begin
                best_logit_v = top_logit_r;
                best_token_v = argmax_token_r;
                worst_top_k_value_r <= top_k_values_r[0];
                worst_top_k_slot_r <= 7'd0;

                for (lane_idx_i = 0; lane_idx_i < LANES; lane_idx_i = lane_idx_i + 1) begin
                    if (((tile_row_idx_r * LANES) + lane_idx_i) < VOCAB_SIZE) begin
                        candidate_value_v = tile_result_w[(lane_idx_i*DATA_WIDTH) +: DATA_WIDTH];
                        candidate_token_v = (tile_row_idx_r * LANES) + lane_idx_i;

                        if (fp16_gt(candidate_value_v, best_logit_v)) begin
                            best_logit_v = candidate_value_v;
                            best_token_v = candidate_token_v;
                        end

                        if ((lane_idx_i < TOP_K_MAX) && (tile_row_idx_r == 16'd0)) begin
                            top_k_values_r[lane_idx_i] <= candidate_value_v;
                            top_k_indices_r[lane_idx_i] <= candidate_token_v;
                        end else if (fp16_max(candidate_value_v, worst_top_k_value_r) == candidate_value_v) begin
                            top_k_values_r[worst_top_k_slot_r] <= candidate_value_v;
                            top_k_indices_r[worst_top_k_slot_r] <= candidate_token_v;
                        end
                    end
                end

                top_logit_r <= best_logit_v;
                argmax_token_r <= best_token_v;

                for (update_idx_i = 0; update_idx_i < TOP_K_MAX; update_idx_i = update_idx_i + 1) begin
                    if (fp16_max(worst_top_k_value_r, top_k_values_r[update_idx_i]) == worst_top_k_value_r) begin
                        worst_top_k_value_r <= top_k_values_r[update_idx_i];
                        worst_top_k_slot_r <= update_idx_i[6:0];
                    end
                end

                if (tile_row_idx_r == (VOCAB_TILE_ROWS - 1)) begin
                    if (do_sample_r) begin
                        sample_start_r <= 1'b1;
                        state_r <= ST_SAMPLE;
                    end else begin
                        state_r <= ST_HOLD;
                    end
                end else begin
                    tile_row_idx_r <= tile_row_idx_r + 16'd1;
                    weight_beat_idx_r <= 16'd0;
                    load_w_req_accepted_r <= 1'b0;
                    state_r <= ST_LOAD_W_REQ;
                end
            end

            ST_SAMPLE: begin
                if (sample_done_w)
                    state_r <= ST_HOLD;
            end

            ST_HOLD: begin
                if (result_valid && result_ready)
                    state_r <= ST_IDLE;
            end

            default: state_r <= ST_IDLE;
        endcase
    end
end

endmodule
