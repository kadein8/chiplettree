`include "config/interface_params.vh"
`include "config/memory_params.vh"
`timescale 1ns/1ps

module RecomputeControl #(
    parameter [`SRAM_ADDR_W-1:0] COMMIT_ADDR = {`SRAM_ADDR_W{1'b0}},
    parameter [`KV_GROUP_LEN_W-1:0] COMMIT_GROUP_LEN = `KV_GROUP_SIZE_SUBBANK,
    parameter [`REQ_ID_W-1:0] COMMIT_REQ_ID = {`REQ_ID_W{1'b0}}
) (
    input                         clk,
    input                         rst_n,
    input                         start_valid,
    output                        start_ready,
    input  [`TOKEN_ID_W-1:0]      start_token_id,
    input  [`TOKEN_ID_W-1:0]      start_referenced_token_id,
    input  [`BRANCH_ID_W-1:0]     start_branch_id,
    input  [`POSITION_ID_W-1:0]   start_current_position,
    input  [`POSITION_ID_W-1:0]   start_referenced_position,
    output                        recompute_req_valid,
    input                         recompute_req_ready,
    output [`TOKEN_ID_W-1:0]      recompute_req_token_id,
    output [`POSITION_ID_W-1:0]   recompute_req_current_position,
    output [`POSITION_ID_W-1:0]   recompute_req_referenced_position,
    output [`BRANCH_ID_W-1:0]     recompute_req_branch_id,
    output                        recompute_req_reason_stale,
    input                         recompute_resp_valid,
    output                        recompute_resp_ready,
    input                         recompute_resp_partial,
    input                         recompute_resp_full,
    input  [`REQ_ID_W-1:0]        recompute_resp_req_id,
    input  [`SRAM_WDATA_W-1:0]    recompute_resp_kv_data,
    input                         recompute_resp_last,
    output                        prep_req_valid,
    input                         prep_req_ready,
    output                        prep_req_write,
    output [`SRAM_ADDR_W-1:0]     prep_req_addr,
    output [`SRAM_WDATA_W-1:0]    prep_req_wdata,
    output [`REQ_ID_W-1:0]        prep_req_id,
    output                        kv_loc_wr_valid,
    output                        kv_state_wr_valid,
    output [`TOKEN_ID_W-1:0]      kv_wr_token_id,
    output [`POSITION_ID_W-1:0]   kv_wr_position_id,
    output [`SRAM_ID_W-1:0]       kv_wr_sram_id,
    output [`BANK_ID_W-1:0]       kv_wr_bank_id,
    output [`SUBBANK_ID_W-1:0]    kv_wr_subbank_start,
    output [`KV_GROUP_LEN_W-1:0]  kv_wr_group_len,
    output                        kv_wr_partial_ready,
    output                        kv_wr_full_ready,
    output                        issue_release,
    output                        busy,
    output                        recompute_done
);

localparam [2:0]
    ST_IDLE = 3'd0,
    ST_REQ = 3'd1,
    ST_WAIT_FIRST_RESP = 3'd2,
    ST_COMMIT_PARTIAL = 3'd3,
    ST_WAIT_FULL_RESP = 3'd4,
    ST_COMMIT_FULL = 3'd5;

reg [2:0] state_r;
reg [`TOKEN_ID_W-1:0] token_id_r;
reg [`TOKEN_ID_W-1:0] referenced_token_id_r;
reg [`BRANCH_ID_W-1:0] branch_id_r;
reg [`POSITION_ID_W-1:0] current_position_r;
reg [`POSITION_ID_W-1:0] referenced_position_r;
reg [`SRAM_WDATA_W-1:0] kv_data_r;
reg partial_committed_r;

wire start_fire_w;
wire req_fire_w;
wire partial_resp_fire_w;
wire full_resp_fire_w;
wire commit_partial_fire_w;
wire commit_full_fire_w;

assign start_ready = (state_r == ST_IDLE);
assign start_fire_w = start_valid && start_ready;

assign recompute_req_valid = (state_r == ST_REQ);
assign recompute_req_token_id = token_id_r;
assign recompute_req_current_position = current_position_r;
assign recompute_req_referenced_position = referenced_position_r;
assign recompute_req_branch_id = branch_id_r;
assign recompute_req_reason_stale = 1'b1;
assign req_fire_w = recompute_req_valid && recompute_req_ready;

assign recompute_resp_ready =
    (state_r == ST_WAIT_FIRST_RESP) || (state_r == ST_WAIT_FULL_RESP);
assign partial_resp_fire_w =
    recompute_resp_valid &&
    recompute_resp_ready &&
    recompute_resp_partial &&
    !recompute_resp_full &&
    recompute_resp_last;
assign full_resp_fire_w =
    recompute_resp_valid &&
    recompute_resp_ready &&
    !recompute_resp_partial &&
    recompute_resp_full &&
    recompute_resp_last;

assign prep_req_valid =
    (state_r == ST_COMMIT_PARTIAL) || (state_r == ST_COMMIT_FULL);
assign prep_req_write = 1'b1;
assign prep_req_addr = COMMIT_ADDR;
assign prep_req_wdata = kv_data_r;
assign prep_req_id = COMMIT_REQ_ID;
assign commit_partial_fire_w =
    (state_r == ST_COMMIT_PARTIAL) && prep_req_valid && prep_req_ready;
assign commit_full_fire_w =
    (state_r == ST_COMMIT_FULL) && prep_req_valid && prep_req_ready;

assign kv_loc_wr_valid = commit_partial_fire_w || commit_full_fire_w;
assign kv_state_wr_valid = commit_partial_fire_w || commit_full_fire_w;
assign kv_wr_token_id = referenced_token_id_r;
assign kv_wr_position_id = referenced_position_r;
assign kv_wr_sram_id =
    COMMIT_ADDR[(`OFFSET_W + `ROW_ADDR_W + `SUBBANK_ID_W + `BANK_ID_W) +: `SRAM_ID_W];
assign kv_wr_bank_id =
    COMMIT_ADDR[(`OFFSET_W + `ROW_ADDR_W + `SUBBANK_ID_W) +: `BANK_ID_W];
assign kv_wr_subbank_start =
    COMMIT_ADDR[(`OFFSET_W + `ROW_ADDR_W) +: `SUBBANK_ID_W];
assign kv_wr_group_len = COMMIT_GROUP_LEN;
assign kv_wr_partial_ready =
    commit_partial_fire_w || (commit_full_fire_w && partial_committed_r);
assign kv_wr_full_ready = commit_full_fire_w;

assign busy = (state_r != ST_IDLE);
assign issue_release = commit_partial_fire_w || commit_full_fire_w;
assign recompute_done = commit_full_fire_w;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state_r <= ST_IDLE;
        token_id_r <= {`TOKEN_ID_W{1'b0}};
        referenced_token_id_r <= {`TOKEN_ID_W{1'b0}};
        branch_id_r <= {`BRANCH_ID_W{1'b0}};
        current_position_r <= {`POSITION_ID_W{1'b0}};
        referenced_position_r <= {`POSITION_ID_W{1'b0}};
        kv_data_r <= {`SRAM_WDATA_W{1'b0}};
        partial_committed_r <= 1'b0;
    end else begin
        case (state_r)
            ST_IDLE: begin
                if (start_fire_w) begin
                    token_id_r <= start_token_id;
                    referenced_token_id_r <= start_referenced_token_id;
                    branch_id_r <= start_branch_id;
                    current_position_r <= start_current_position;
                    referenced_position_r <= start_referenced_position;
                    kv_data_r <= {`SRAM_WDATA_W{1'b0}};
                    partial_committed_r <= 1'b0;
                    state_r <= ST_REQ;
                end
            end

            ST_REQ: begin
                if (req_fire_w) begin
                    state_r <= ST_WAIT_FIRST_RESP;
                end
            end

            ST_WAIT_FIRST_RESP: begin
                if (partial_resp_fire_w) begin
                    kv_data_r <= recompute_resp_kv_data;
                    state_r <= ST_COMMIT_PARTIAL;
                end else if (full_resp_fire_w) begin
                    kv_data_r <= recompute_resp_kv_data;
                    state_r <= ST_COMMIT_FULL;
                end
            end

            ST_COMMIT_PARTIAL: begin
                if (commit_partial_fire_w) begin
                    partial_committed_r <= 1'b1;
                    state_r <= ST_WAIT_FULL_RESP;
                end
            end

            ST_WAIT_FULL_RESP: begin
                if (full_resp_fire_w) begin
                    kv_data_r <= recompute_resp_kv_data;
                    state_r <= ST_COMMIT_FULL;
                end
            end

            ST_COMMIT_FULL: begin
                if (commit_full_fire_w) begin
                    partial_committed_r <= 1'b0;
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
