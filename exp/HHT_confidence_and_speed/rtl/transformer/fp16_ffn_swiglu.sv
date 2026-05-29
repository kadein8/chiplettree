`include "config/interface_params.vh"
`include "config/memory_params.vh"
`include "config/model_params.vh"
`timescale 1ns/1ps

module fp16_ffn_swiglu #(
    parameter integer ADDR_W = `SRAM_ADDR_W,
    parameter integer DATA_WIDTH = `FP16_TILE_DATA_W,
    parameter integer DATA_BUS_W = `SRAM_WDATA_W,
    parameter integer REQ_ID_W = `REQ_ID_W,
    parameter integer RESULT_STATUS_W = 2,
    parameter integer HIDDEN_DIM = `QWEN3_DMODEL,
    parameter integer INTERMEDIATE_DIM = `QWEN3_INTERMEDIATE_SIZE,
    parameter [RESULT_STATUS_W-1:0] RESULT_STATUS_OK = 2'b00
) (
    input  logic                       clk,
    input  logic                       rst_n,
    input  logic                       issue_valid,
    output logic                       issue_ready,
    input  logic [ADDR_W-1:0]          issue_input_addr,
    input  logic [ADDR_W-1:0]          issue_gate_w_addr,
    input  logic [ADDR_W-1:0]          issue_up_w_addr,
    input  logic [ADDR_W-1:0]          issue_down_w_addr,
    input  logic [ADDR_W-1:0]          issue_result_addr,
    input  logic [ADDR_W-1:0]          issue_scratch_base_addr,
    input  logic [REQ_ID_W-1:0]        issue_req_id,

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
localparam integer HIDDEN_BEATS = HIDDEN_DIM / ELEMS_PER_BEAT;
localparam integer INTERMEDIATE_BEATS = INTERMEDIATE_DIM / ELEMS_PER_BEAT;
localparam logic [4:0]
    ST_IDLE            = 5'd0,
    ST_GATE_ISSUE      = 5'd1,
    ST_GATE_WAIT       = 5'd2,
    ST_UP_ISSUE        = 5'd3,
    ST_UP_WAIT         = 5'd4,
    ST_ACT_GATE_REQ    = 5'd5,
    ST_ACT_GATE_RESP   = 5'd6,
    ST_ACT_GATE_DRAIN  = 5'd7,
    ST_ACT_UP_REQ      = 5'd8,
    ST_ACT_UP_RESP     = 5'd9,
    ST_ACT_UP_DRAIN    = 5'd10,
    ST_ACT_SILU_ISSUE  = 5'd11,
    ST_ACT_SILU_WAIT   = 5'd12,
    ST_ACT_WRITE       = 5'd13,
    ST_DOWN_ISSUE      = 5'd14,
    ST_DOWN_WAIT       = 5'd15,
    ST_HOLD            = 5'd16;

function automatic [ADDR_W-1:0] addr_from_u16;
    input [15:0] value;
    begin
        addr_from_u16 = {{(ADDR_W-16){1'b0}}, value};
    end
endfunction

logic [4:0] state_r;
logic [ADDR_W-1:0] input_addr_r;
logic [ADDR_W-1:0] gate_w_addr_r;
logic [ADDR_W-1:0] up_w_addr_r;
logic [ADDR_W-1:0] down_w_addr_r;
logic [ADDR_W-1:0] result_addr_r;
logic [ADDR_W-1:0] scratch_base_addr_r;
logic [REQ_ID_W-1:0] req_id_r;
logic [15:0] beat_idx_r;
logic [DATA_BUS_W-1:0] gate_beat_r;
logic [DATA_BUS_W-1:0] up_beat_r;
logic [DATA_BUS_W-1:0] fused_beat_r;
logic [DATA_BUS_W-1:0] result_data_r;
logic [RESULT_STATUS_W-1:0] result_status_r;
logic gate_req_accepted_r;
logic up_req_accepted_r;

logic matvec_issue_valid_w;
logic matvec_issue_ready_w;
logic [ADDR_W-1:0] matvec_weight_addr_w;
logic [ADDR_W-1:0] matvec_vector_addr_w;
logic [ADDR_W-1:0] matvec_result_addr_cfg_w;
logic [15:0] matvec_rows_w;
logic [15:0] matvec_cols_w;
logic matvec_rd_valid_w;
logic [ADDR_W-1:0] matvec_rd_addr_w;
logic [REQ_ID_W-1:0] matvec_rd_id_w;
logic matvec_resp_ready_w;
logic matvec_wr_valid_w;
logic [ADDR_W-1:0] matvec_wr_addr_w;
logic [DATA_BUS_W-1:0] matvec_wr_data_w;
logic matvec_result_valid_w;
logic matvec_result_ready_w;
logic [ADDR_W-1:0] matvec_result_addr_w;
logic [DATA_BUS_W-1:0] matvec_result_data_w;
logic [RESULT_STATUS_W-1:0] matvec_result_status_w;

logic silu_start_ready_w;
logic silu_result_valid_w;
logic [DATA_BUS_W-1:0] silu_result_beat_w;
logic [DATA_WIDTH-1:0] mul_beat_w [0:ELEMS_PER_BEAT-1];

wire [ADDR_W-1:0] gate_buf_base_w = scratch_base_addr_r;
wire [ADDR_W-1:0] up_buf_base_w = scratch_base_addr_r + INTERMEDIATE_BEATS;
wire [ADDR_W-1:0] fused_buf_base_w = scratch_base_addr_r + (INTERMEDIATE_BEATS * 2);

genvar elem_g;
generate
    for (elem_g = 0; elem_g < ELEMS_PER_BEAT; elem_g = elem_g + 1) begin : gen_swiglu_mul
        floatMult16 u_mul_gate_up (
            .floatA(silu_result_beat_w[(elem_g*DATA_WIDTH) +: DATA_WIDTH]),
            .floatB(up_beat_r[(elem_g*DATA_WIDTH) +: DATA_WIDTH]),
            .product(mul_beat_w[elem_g])
        );
    end
endgenerate

fp16_silu #(
    .DATA_WIDTH(DATA_WIDTH),
    .DATA_BUS_W(DATA_BUS_W)
) u_fp16_silu (
    .clk(clk),
    .rst_n(rst_n),
    .start_valid(state_r == ST_ACT_SILU_ISSUE),
    .start_ready(silu_start_ready_w),
    .x_beat(gate_beat_r),
    .result_valid(silu_result_valid_w),
    .result_beat(silu_result_beat_w)
);

assign matvec_issue_valid_w =
    (state_r == ST_GATE_ISSUE) ||
    (state_r == ST_UP_ISSUE) ||
    (state_r == ST_DOWN_ISSUE);

assign matvec_weight_addr_w =
    (state_r == ST_GATE_ISSUE) ? gate_w_addr_r :
    (state_r == ST_UP_ISSUE) ? up_w_addr_r :
    down_w_addr_r;

assign matvec_vector_addr_w =
    (state_r == ST_DOWN_ISSUE) ? fused_buf_base_w : input_addr_r;

assign matvec_result_addr_cfg_w =
    (state_r == ST_GATE_ISSUE) ? gate_buf_base_w :
    (state_r == ST_UP_ISSUE) ? up_buf_base_w :
    result_addr_r;

assign matvec_rows_w =
    (state_r == ST_DOWN_ISSUE) ? HIDDEN_DIM[15:0] : INTERMEDIATE_DIM[15:0];

assign matvec_cols_w =
    (state_r == ST_DOWN_ISSUE) ? INTERMEDIATE_DIM[15:0] : HIDDEN_DIM[15:0];

wire matvec_resp_quiet_w =
    !(sram_resp_valid && (sram_resp_id == req_id_r));
assign matvec_result_ready_w =
    ((state_r == ST_GATE_WAIT) ||
     (state_r == ST_UP_WAIT) ||
     (state_r == ST_DOWN_WAIT)) &&
    matvec_resp_quiet_w;

fp16_tiled_matvec #(
    .LANES(`FP16_TILE_LANES),
    .COLS(`FP16_TILE_COLS),
    .DATA_WIDTH(DATA_WIDTH),
    .ADDR_W(ADDR_W),
    .DATA_BUS_W(DATA_BUS_W),
    .REQ_ID_W(REQ_ID_W),
    .RESULT_STATUS_W(RESULT_STATUS_W),
    .MAX_MATRIX_ROWS(INTERMEDIATE_DIM),
    .MAX_MATRIX_COLS(INTERMEDIATE_DIM),
    .RESULT_STATUS_OK(RESULT_STATUS_OK)
) u_fp16_tiled_matvec (
    .clk(clk),
    .rst_n(rst_n),
    .issue_valid(matvec_issue_valid_w),
    .issue_ready(matvec_issue_ready_w),
    .issue_weight_base_addr(matvec_weight_addr_w),
    .issue_vector_addr(matvec_vector_addr_w),
    .issue_result_addr(matvec_result_addr_cfg_w),
    .issue_req_id(req_id_r),
    .issue_matrix_rows(matvec_rows_w),
    .issue_matrix_cols(matvec_cols_w),
    .sram_rd_valid(matvec_rd_valid_w),
    .sram_rd_ready(sram_rd_ready),
    .sram_rd_addr(matvec_rd_addr_w),
    .sram_rd_id(matvec_rd_id_w),
    .sram_resp_valid(sram_resp_valid),
    .sram_resp_ready(matvec_resp_ready_w),
    .sram_resp_data(sram_resp_data),
    .sram_resp_id(sram_resp_id),
    .sram_wr_valid(matvec_wr_valid_w),
    .sram_wr_ready(sram_wr_ready),
    .sram_wr_addr(matvec_wr_addr_w),
    .sram_wr_data(matvec_wr_data_w),
    .result_valid(matvec_result_valid_w),
    .result_ready(matvec_result_ready_w),
    .result_addr(matvec_result_addr_w),
    .result_data(matvec_result_data_w),
    .result_status(matvec_result_status_w)
);

assign issue_ready = (state_r == ST_IDLE);
assign sram_rd_id = req_id_r;
assign result_valid = (state_r == ST_HOLD);
assign result_addr = result_addr_r;
assign result_data = result_data_r;
assign result_status = result_status_r;

always_comb begin
    sram_rd_valid = 1'b0;
    sram_rd_addr = {ADDR_W{1'b0}};
    sram_resp_ready = 1'b0;
    sram_wr_valid = 1'b0;
    sram_wr_addr = {ADDR_W{1'b0}};
    sram_wr_data = {DATA_BUS_W{1'b0}};

    case (state_r)
        ST_GATE_ISSUE,
        ST_GATE_WAIT,
        ST_UP_ISSUE,
        ST_UP_WAIT,
        ST_DOWN_ISSUE,
        ST_DOWN_WAIT: begin
            sram_rd_valid = matvec_rd_valid_w;
            sram_rd_addr = matvec_rd_addr_w;
            sram_resp_ready = matvec_resp_ready_w;
            sram_wr_valid = matvec_wr_valid_w;
            sram_wr_addr = matvec_wr_addr_w;
            sram_wr_data = matvec_wr_data_w;
        end

        ST_ACT_GATE_REQ: begin
            sram_rd_valid = 1'b1;
            sram_rd_addr = gate_buf_base_w + addr_from_u16(beat_idx_r);
            sram_resp_ready =
                (sram_resp_id == req_id_r) &&
                (gate_req_accepted_r || (sram_rd_valid && sram_rd_ready));
        end

        ST_ACT_GATE_RESP,
        ST_ACT_GATE_DRAIN: begin
            sram_resp_ready = (sram_resp_id == req_id_r);
        end

        ST_ACT_UP_REQ: begin
            sram_rd_valid = 1'b1;
            sram_rd_addr = up_buf_base_w + addr_from_u16(beat_idx_r);
            sram_resp_ready =
                (sram_resp_id == req_id_r) &&
                (up_req_accepted_r || (sram_rd_valid && sram_rd_ready));
        end

        ST_ACT_UP_RESP,
        ST_ACT_UP_DRAIN: begin
            sram_resp_ready = (sram_resp_id == req_id_r);
        end

        ST_ACT_WRITE: begin
            sram_wr_valid = 1'b1;
            sram_wr_addr = fused_buf_base_w + addr_from_u16(beat_idx_r);
            sram_wr_data = fused_beat_r;
        end

        default: begin
        end
    endcase
end

integer elem_idx_i;
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state_r <= ST_IDLE;
        input_addr_r <= {ADDR_W{1'b0}};
        gate_w_addr_r <= {ADDR_W{1'b0}};
        up_w_addr_r <= {ADDR_W{1'b0}};
        down_w_addr_r <= {ADDR_W{1'b0}};
        result_addr_r <= {ADDR_W{1'b0}};
        scratch_base_addr_r <= {ADDR_W{1'b0}};
        req_id_r <= {REQ_ID_W{1'b0}};
        beat_idx_r <= 16'd0;
        gate_beat_r <= {DATA_BUS_W{1'b0}};
        up_beat_r <= {DATA_BUS_W{1'b0}};
        fused_beat_r <= {DATA_BUS_W{1'b0}};
        result_data_r <= {DATA_BUS_W{1'b0}};
        result_status_r <= {RESULT_STATUS_W{1'b0}};
        gate_req_accepted_r <= 1'b0;
        up_req_accepted_r <= 1'b0;
    end else begin
        case (state_r)
            ST_IDLE: begin
                if (issue_valid) begin
                    input_addr_r <= issue_input_addr;
                    gate_w_addr_r <= issue_gate_w_addr;
                    up_w_addr_r <= issue_up_w_addr;
                    down_w_addr_r <= issue_down_w_addr;
                    result_addr_r <= issue_result_addr;
                    scratch_base_addr_r <= issue_scratch_base_addr;
                    req_id_r <= issue_req_id;
                    beat_idx_r <= 16'd0;
                    result_data_r <= {DATA_BUS_W{1'b0}};
                    result_status_r <= RESULT_STATUS_OK;
                    gate_req_accepted_r <= 1'b0;
                    up_req_accepted_r <= 1'b0;
                    state_r <= ST_GATE_ISSUE;
                end
            end

            ST_GATE_ISSUE: begin
                if (matvec_issue_valid_w && matvec_issue_ready_w)
                    state_r <= ST_GATE_WAIT;
            end

            ST_GATE_WAIT: begin
                if (matvec_result_valid_w && matvec_result_ready_w)
                    state_r <= ST_UP_ISSUE;
            end

            ST_UP_ISSUE: begin
                if (matvec_issue_valid_w && matvec_issue_ready_w)
                    state_r <= ST_UP_WAIT;
            end

            ST_UP_WAIT: begin
                if (matvec_result_valid_w && matvec_result_ready_w) begin
                    beat_idx_r <= 16'd0;
                    gate_req_accepted_r <= 1'b0;
                    up_req_accepted_r <= 1'b0;
                    state_r <= ST_ACT_GATE_REQ;
                end
            end

            ST_ACT_GATE_REQ: begin
                if ((gate_req_accepted_r || (sram_rd_valid && sram_rd_ready)) &&
                    sram_resp_valid && sram_resp_ready) begin
                    gate_beat_r <= sram_resp_data;
                    gate_req_accepted_r <= 1'b0;
                    state_r <= ST_ACT_GATE_DRAIN;
                end else if (sram_rd_valid && sram_rd_ready) begin
                    gate_req_accepted_r <= 1'b1;
                    state_r <= ST_ACT_GATE_RESP;
                end
            end

            ST_ACT_GATE_RESP: begin
                if (sram_resp_valid && sram_resp_ready) begin
                    gate_beat_r <= sram_resp_data;
                    gate_req_accepted_r <= 1'b0;
                    state_r <= ST_ACT_GATE_DRAIN;
                end
            end

            ST_ACT_GATE_DRAIN: begin
                if (!(sram_resp_valid && sram_resp_ready)) begin
                    state_r <= ST_ACT_UP_REQ;
                end
            end

            ST_ACT_UP_REQ: begin
                if ((up_req_accepted_r || (sram_rd_valid && sram_rd_ready)) &&
                    sram_resp_valid && sram_resp_ready) begin
                    up_beat_r <= sram_resp_data;
                    up_req_accepted_r <= 1'b0;
                    state_r <= ST_ACT_UP_DRAIN;
                end else if (sram_rd_valid && sram_rd_ready) begin
                    up_req_accepted_r <= 1'b1;
                    state_r <= ST_ACT_UP_RESP;
                end
            end

            ST_ACT_UP_RESP: begin
                if (sram_resp_valid && sram_resp_ready) begin
                    up_beat_r <= sram_resp_data;
                    up_req_accepted_r <= 1'b0;
                    state_r <= ST_ACT_UP_DRAIN;
                end
            end

            ST_ACT_UP_DRAIN: begin
                if (!(sram_resp_valid && sram_resp_ready)) begin
                    state_r <= ST_ACT_SILU_ISSUE;
                end
            end

            ST_ACT_SILU_ISSUE: begin
                if (silu_start_ready_w)
                    state_r <= ST_ACT_SILU_WAIT;
            end

            ST_ACT_SILU_WAIT: begin
                if (silu_result_valid_w) begin
                    for (elem_idx_i = 0; elem_idx_i < ELEMS_PER_BEAT; elem_idx_i = elem_idx_i + 1)
                        fused_beat_r[(elem_idx_i*DATA_WIDTH) +: DATA_WIDTH] <= mul_beat_w[elem_idx_i];
                    state_r <= ST_ACT_WRITE;
                end
            end

            ST_ACT_WRITE: begin
                if (sram_wr_valid && sram_wr_ready) begin
                    if (beat_idx_r == (INTERMEDIATE_BEATS - 1)) begin
                        gate_req_accepted_r <= 1'b0;
                        up_req_accepted_r <= 1'b0;
                        state_r <= ST_DOWN_ISSUE;
                    end else begin
                        beat_idx_r <= beat_idx_r + 16'd1;
                        gate_req_accepted_r <= 1'b0;
                        up_req_accepted_r <= 1'b0;
                        state_r <= ST_ACT_GATE_REQ;
                    end
                end
            end

            ST_DOWN_ISSUE: begin
                if (matvec_issue_valid_w && matvec_issue_ready_w)
                    state_r <= ST_DOWN_WAIT;
            end

            ST_DOWN_WAIT: begin
                if (matvec_result_valid_w && matvec_result_ready_w) begin
                    result_data_r <= matvec_result_data_w;
                    result_status_r <= matvec_result_status_w;
                    state_r <= ST_HOLD;
                end
            end

            ST_HOLD: begin
                if (result_valid && result_ready) begin
                    gate_req_accepted_r <= 1'b0;
                    up_req_accepted_r <= 1'b0;
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
