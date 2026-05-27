`include "config/prediction_params.vh"
`timescale 1ns/1ps

`include "config/interface_params.vh"
`include "config/memory_params.vh"

module request_controller (
    input                                               clk,
    input                                               rst_n,
    input                                               req_in_valid,
    output                                              req_in_ready,
    input                                               req_in_write,
    input  [`SRAM_ADDR_W-1:0]                           req_in_addr,
    input  [`SRAM_WDATA_W-1:0]                          req_in_wdata,
    input  [`REQ_ID_W-1:0]                              req_in_req_id,
    input  [`PE_MASK_W-1:0]                             req_in_pe_mask,
    input  [`REQ_PRIORITY_W-1:0]                        req_in_priority,
    input  [`BANK_ID_W-1:0]                             req_in_bank_id,
    input  [`SUBBANK_ID_W-1:0]                          req_in_subbank_id,
    output [`MEM_REQ_LANES-1:0]                         mem_req_valid,
    input  [`MEM_REQ_LANES-1:0]                         mem_req_ready,
    output [`MEM_REQ_LANES-1:0]                         mem_req_write,
    output [`MEM_REQ_LANES*`SRAM_ADDR_W-1:0]            mem_req_addr,
    output [`MEM_REQ_LANES*`SRAM_WDATA_W-1:0]           mem_req_wdata,
    output [`MEM_REQ_LANES*`REQ_ID_W-1:0]               mem_req_id,
    input  [`MEM_REQ_LANES-1:0]                         mem_resp_valid,
    input  [`MEM_REQ_LANES*`SRAM_RDATA_W-1:0]           mem_resp_rdata,
    input  [`MEM_REQ_LANES*`REQ_ID_W-1:0]               mem_resp_id,
    input  [`MEM_REQ_LANES-1:0]                         mem_resp_last,
    output [`MEM_REQ_LANES-1:0]                         resp_out_valid,
    input  [`MEM_REQ_LANES-1:0]                         resp_out_ready,
    output [`MEM_REQ_LANES*`SRAM_RDATA_W-1:0]           resp_out_rdata,
    output [`MEM_REQ_LANES*`REQ_ID_W-1:0]               resp_out_req_id,
    output [`MEM_REQ_LANES*`PE_MASK_W-1:0]              resp_out_pe_mask,
    output [`MEM_REQ_LANES-1:0]                         resp_out_last
);

localparam [2:0] STATE_IDLE      = 3'd0;
localparam [2:0] STATE_COLLECT   = 3'd1;
localparam [2:0] STATE_ISSUE     = 3'd2;
localparam [2:0] STATE_WAIT_RESP = 3'd3;
localparam [2:0] STATE_RESP      = 3'd4;

localparam integer LANE_IDX_W =
    ((`MEM_REQ_LANES <= 1) ? 1 : $clog2(`MEM_REQ_LANES));
localparam integer SRAM_ID_LSB =
    (`OFFSET_W + `ROW_ADDR_W + `SUBBANK_ID_W + `BANK_ID_W);

reg [2:0] state_r;

reg collect_wait_r;

reg [`MEM_REQ_LANES-1:0] lane_valid_r;
reg [`MEM_REQ_LANES-1:0] lane_merge_r;
reg [`MEM_REQ_LANES-1:0] lane_write_r;
reg [`MEM_REQ_LANES-1:0] lane_bypass_r;
reg [`MEM_REQ_LANES*`SRAM_ADDR_W-1:0] lane_addr_r;
reg [`MEM_REQ_LANES*`SRAM_WDATA_W-1:0] lane_wdata_r;
reg [`MEM_REQ_LANES*`SRAM_RDATA_W-1:0] lane_bypass_data_r;
reg [`MEM_REQ_LANES*`REQ_ID_W-1:0] lane_req_id_r;
reg [`MEM_REQ_LANES*`PE_MASK_W-1:0] lane_pe_mask_r;
reg [`MEM_REQ_LANES*`REQ_PRIORITY_W-1:0] lane_priority_r;
reg [`MEM_REQ_LANES*`BANK_ID_W-1:0] lane_bank_id_r;
reg [`MEM_REQ_LANES*`SUBBANK_ID_W-1:0] lane_subbank_id_r;

reg [`MEM_REQ_LANES-1:0] mem_req_valid_c;
reg [`MEM_REQ_LANES-1:0] mem_req_write_c;
reg [`MEM_REQ_LANES*`SRAM_ADDR_W-1:0] mem_req_addr_c;
reg [`MEM_REQ_LANES*`SRAM_WDATA_W-1:0] mem_req_wdata_c;
reg [`MEM_REQ_LANES*`REQ_ID_W-1:0] mem_req_id_c;

reg [`MEM_REQ_LANES-1:0] resp_valid_r;
reg [`MEM_REQ_LANES*`SRAM_RDATA_W-1:0] resp_rdata_r;
reg [`MEM_REQ_LANES*`REQ_ID_W-1:0] resp_req_id_r;
reg [`MEM_REQ_LANES*`PE_MASK_W-1:0] resp_pe_mask_r;
reg [`MEM_REQ_LANES-1:0] resp_last_r;

reg collect_ready_c;
reg accept_same_addr_merge_c;
reg accept_same_addr_bypass_c;
reg accept_independent_c;
reg accept_has_free_c;
reg merge_group_only_c;
reg merge_lane_present_c;
reg write_lane_present_c;
reg resource_conflict_c;
reg [LANE_IDX_W-1:0] accept_lane_idx_c;
reg [LANE_IDX_W-1:0] accept_store_idx_c;
reg [LANE_IDX_W-1:0] accept_bypass_source_idx_c;
reg issue_ready_c;
reg issue_has_response_c;
reg issue_has_sram_read_c;
reg resp_complete_c;

integer lane_i;
integer reset_i;
integer resp_i;
integer shift_i;

assign req_in_ready =
    (state_r == STATE_IDLE) ||
    ((state_r == STATE_COLLECT) && req_in_valid && collect_ready_c);

assign mem_req_valid = mem_req_valid_c;
assign mem_req_write = mem_req_write_c;
assign mem_req_addr = mem_req_addr_c;
assign mem_req_wdata = mem_req_wdata_c;
assign mem_req_id = mem_req_id_c;

assign resp_out_valid = resp_valid_r;
assign resp_out_rdata = resp_rdata_r;
assign resp_out_req_id = resp_req_id_r;
assign resp_out_pe_mask = resp_pe_mask_r;
assign resp_out_last = resp_last_r;

always @* begin
    collect_ready_c = 1'b0;
    accept_same_addr_merge_c = 1'b0;
    accept_same_addr_bypass_c = 1'b0;
    accept_independent_c = 1'b0;
    accept_has_free_c = 1'b0;
    merge_group_only_c = 1'b1;
    merge_lane_present_c = 1'b0;
    write_lane_present_c = 1'b0;
    resource_conflict_c = 1'b0;
    accept_lane_idx_c = {LANE_IDX_W{1'b0}};
    accept_store_idx_c = {LANE_IDX_W{1'b0}};
    accept_bypass_source_idx_c = {LANE_IDX_W{1'b0}};
    issue_ready_c = 1'b0;
    issue_has_response_c = 1'b0;
    issue_has_sram_read_c = 1'b0;
    resp_complete_c = 1'b0;

    mem_req_valid_c = {`MEM_REQ_LANES{1'b0}};
    mem_req_write_c = {`MEM_REQ_LANES{1'b0}};
    mem_req_addr_c = {(`MEM_REQ_LANES*`SRAM_ADDR_W){1'b0}};
    mem_req_wdata_c = {(`MEM_REQ_LANES*`SRAM_WDATA_W){1'b0}};
    mem_req_id_c = {(`MEM_REQ_LANES*`REQ_ID_W){1'b0}};

    for (lane_i = 1; lane_i < `MEM_REQ_LANES; lane_i = lane_i + 1) begin
        if (!lane_valid_r[lane_i] && !accept_has_free_c) begin
            accept_has_free_c = 1'b1;
            accept_lane_idx_c = lane_i[LANE_IDX_W-1:0];
        end
    end

    for (lane_i = 0; lane_i < `MEM_REQ_LANES; lane_i = lane_i + 1) begin
        if (lane_valid_r[lane_i] && lane_merge_r[lane_i]) begin
            merge_lane_present_c = 1'b1;
        end

        if (lane_valid_r[lane_i] && lane_write_r[lane_i]) begin
            write_lane_present_c = 1'b1;
        end

        if (lane_valid_r[lane_i] && !lane_merge_r[lane_i] &&
            !lane_bypass_r[lane_i]) begin
            if (req_in_addr[SRAM_ID_LSB +: `SRAM_ID_W] ==
                    lane_addr_r[(lane_i*`SRAM_ADDR_W + SRAM_ID_LSB) +: `SRAM_ID_W] &&
                req_in_bank_id ==
                    lane_bank_id_r[(lane_i*`BANK_ID_W) +: `BANK_ID_W] &&
                req_in_subbank_id ==
                    lane_subbank_id_r[(lane_i*`SUBBANK_ID_W) +: `SUBBANK_ID_W]) begin
                resource_conflict_c = 1'b1;
            end
        end

        if ((lane_i != 0) && lane_valid_r[lane_i] && !lane_merge_r[lane_i]) begin
            merge_group_only_c = 1'b0;
        end
    end

    accept_store_idx_c = accept_lane_idx_c;
    if ((state_r == STATE_COLLECT) && accept_has_free_c) begin
        if ((req_in_addr == lane_addr_r[0 +: `SRAM_ADDR_W]) &&
            lane_valid_r[0] && !lane_write_r[0] && !req_in_write &&
            merge_group_only_c) begin
            accept_same_addr_merge_c = 1'b1;
        end

        if (!accept_same_addr_merge_c && !merge_lane_present_c && req_in_write) begin
            for (lane_i = 0; lane_i < `MEM_REQ_LANES; lane_i = lane_i + 1) begin
                if (lane_valid_r[lane_i] &&
                    !lane_merge_r[lane_i] &&
                    !lane_bypass_r[lane_i] &&
                    (req_in_addr ==
                        lane_addr_r[(lane_i*`SRAM_ADDR_W) +: `SRAM_ADDR_W]) &&
                    !lane_write_r[lane_i] &&
                    !accept_same_addr_bypass_c) begin
                    accept_same_addr_bypass_c = 1'b1;
                    accept_bypass_source_idx_c = lane_i[LANE_IDX_W-1:0];
                end
            end
        end

        if (!accept_same_addr_merge_c &&
            !accept_same_addr_bypass_c &&
            (req_in_addr != lane_addr_r[0 +: `SRAM_ADDR_W]) &&
            !resource_conflict_c &&
            !write_lane_present_c) begin
            accept_independent_c = 1'b1;
        end
    end

    collect_ready_c = accept_same_addr_merge_c ||
                      accept_same_addr_bypass_c ||
                      accept_independent_c;

    if (accept_independent_c && !merge_lane_present_c &&
        !write_lane_present_c && !req_in_write) begin
        for (lane_i = 0; lane_i < `MEM_REQ_LANES; lane_i = lane_i + 1) begin
            if (lane_i < accept_lane_idx_c && lane_valid_r[lane_i] &&
                !lane_merge_r[lane_i] &&
                (req_in_priority >
                    lane_priority_r[(lane_i*`REQ_PRIORITY_W) +: `REQ_PRIORITY_W]) &&
                (accept_store_idx_c == accept_lane_idx_c)) begin
                accept_store_idx_c = lane_i[LANE_IDX_W-1:0];
            end
        end
    end

    if (state_r == STATE_ISSUE) begin
        issue_ready_c = 1'b1;
        for (lane_i = 0; lane_i < `MEM_REQ_LANES; lane_i = lane_i + 1) begin
            if (lane_valid_r[lane_i] && !lane_write_r[lane_i]) begin
                issue_has_response_c = 1'b1;
            end

            if (lane_valid_r[lane_i] && !lane_write_r[lane_i] &&
                !lane_merge_r[lane_i] && !lane_bypass_r[lane_i]) begin
                issue_has_sram_read_c = 1'b1;
            end

            if (lane_valid_r[lane_i] && !lane_merge_r[lane_i] &&
                !lane_bypass_r[lane_i]) begin
                mem_req_valid_c[lane_i] = 1'b1;
                mem_req_addr_c[(lane_i*`SRAM_ADDR_W) +: `SRAM_ADDR_W] =
                    lane_addr_r[(lane_i*`SRAM_ADDR_W) +: `SRAM_ADDR_W];
                mem_req_wdata_c[(lane_i*`SRAM_WDATA_W) +: `SRAM_WDATA_W] =
                    lane_wdata_r[(lane_i*`SRAM_WDATA_W) +: `SRAM_WDATA_W];
                mem_req_id_c[(lane_i*`REQ_ID_W) +: `REQ_ID_W] =
                    lane_req_id_r[(lane_i*`REQ_ID_W) +: `REQ_ID_W];
                mem_req_write_c[lane_i] = lane_write_r[lane_i];
                if (!mem_req_ready[lane_i]) begin
                    issue_ready_c = 1'b0;
                end
            end
        end
    end

    if (state_r == STATE_WAIT_RESP) begin
        resp_complete_c = 1'b1;
        for (lane_i = 0; lane_i < `MEM_REQ_LANES; lane_i = lane_i + 1) begin
            if (lane_valid_r[lane_i] && !lane_write_r[lane_i]) begin
                if (lane_merge_r[lane_i]) begin
                    if (!resp_valid_r[lane_i] && !mem_resp_valid[0]) begin
                        resp_complete_c = 1'b0;
                    end
                end else if (lane_bypass_r[lane_i]) begin
                    if (!resp_valid_r[lane_i]) begin
                        resp_complete_c = 1'b0;
                    end
                end else if (!resp_valid_r[lane_i] && !mem_resp_valid[lane_i]) begin
                    resp_complete_c = 1'b0;
                end
            end
        end
    end
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state_r <= STATE_IDLE;
        collect_wait_r <= 1'b0;
        lane_valid_r <= {`MEM_REQ_LANES{1'b0}};
        lane_merge_r <= {`MEM_REQ_LANES{1'b0}};
        lane_write_r <= {`MEM_REQ_LANES{1'b0}};
        lane_bypass_r <= {`MEM_REQ_LANES{1'b0}};
        lane_addr_r <= {(`MEM_REQ_LANES*`SRAM_ADDR_W){1'b0}};
        lane_wdata_r <= {(`MEM_REQ_LANES*`SRAM_WDATA_W){1'b0}};
        lane_bypass_data_r <= {(`MEM_REQ_LANES*`SRAM_RDATA_W){1'b0}};
        lane_req_id_r <= {(`MEM_REQ_LANES*`REQ_ID_W){1'b0}};
        lane_pe_mask_r <= {(`MEM_REQ_LANES*`PE_MASK_W){1'b0}};
        lane_priority_r <= {(`MEM_REQ_LANES*`REQ_PRIORITY_W){1'b0}};
        lane_bank_id_r <= {(`MEM_REQ_LANES*`BANK_ID_W){1'b0}};
        lane_subbank_id_r <= {(`MEM_REQ_LANES*`SUBBANK_ID_W){1'b0}};
        resp_valid_r <= {`MEM_REQ_LANES{1'b0}};
        resp_rdata_r <= {(`MEM_REQ_LANES*`SRAM_RDATA_W){1'b0}};
        resp_req_id_r <= {(`MEM_REQ_LANES*`REQ_ID_W){1'b0}};
        resp_pe_mask_r <= {(`MEM_REQ_LANES*`PE_MASK_W){1'b0}};
        resp_last_r <= {`MEM_REQ_LANES{1'b0}};
    end else begin
        case (state_r)
            STATE_IDLE: begin
                if (req_in_valid && req_in_ready) begin
                    collect_wait_r <= 1'b0;
                    lane_valid_r <= {{(`MEM_REQ_LANES-1){1'b0}}, 1'b1};
                    lane_merge_r <= {`MEM_REQ_LANES{1'b0}};
                    lane_write_r <= {{(`MEM_REQ_LANES-1){1'b0}}, req_in_write};
                    lane_bypass_r <= {`MEM_REQ_LANES{1'b0}};
                    lane_addr_r[0 +: `SRAM_ADDR_W] <= req_in_addr;
                    lane_wdata_r[0 +: `SRAM_WDATA_W] <= req_in_wdata;
                    lane_bypass_data_r <= {(`MEM_REQ_LANES*`SRAM_RDATA_W){1'b0}};
                    lane_req_id_r[0 +: `REQ_ID_W] <= req_in_req_id;
                    lane_pe_mask_r[0 +: `PE_MASK_W] <= req_in_pe_mask;
                    lane_priority_r[0 +: `REQ_PRIORITY_W] <= req_in_priority;
                    lane_bank_id_r[0 +: `BANK_ID_W] <= req_in_bank_id;
                    lane_subbank_id_r[0 +: `SUBBANK_ID_W] <= req_in_subbank_id;
                    resp_valid_r <= {`MEM_REQ_LANES{1'b0}};
                    if (req_in_write) begin
                        state_r <= STATE_ISSUE;
                    end else begin
                        state_r <= STATE_COLLECT;
                    end
                end
            end

            STATE_COLLECT: begin
                if (req_in_valid && collect_ready_c) begin
                    for (shift_i = `MEM_REQ_LANES-1; shift_i > 0; shift_i = shift_i - 1) begin
                        if (accept_independent_c && !merge_lane_present_c &&
                            (shift_i <= accept_lane_idx_c) &&
                            (shift_i > accept_store_idx_c)) begin
                            lane_valid_r[shift_i] <= lane_valid_r[shift_i-1];
                            lane_merge_r[shift_i] <= lane_merge_r[shift_i-1];
                            lane_write_r[shift_i] <= lane_write_r[shift_i-1];
                            lane_bypass_r[shift_i] <= lane_bypass_r[shift_i-1];
                            lane_addr_r[(shift_i*`SRAM_ADDR_W) +: `SRAM_ADDR_W] <=
                                lane_addr_r[((shift_i-1)*`SRAM_ADDR_W) +: `SRAM_ADDR_W];
                            lane_wdata_r[(shift_i*`SRAM_WDATA_W) +: `SRAM_WDATA_W] <=
                                lane_wdata_r[((shift_i-1)*`SRAM_WDATA_W) +: `SRAM_WDATA_W];
                            lane_bypass_data_r[(shift_i*`SRAM_RDATA_W) +: `SRAM_RDATA_W] <=
                                lane_bypass_data_r[((shift_i-1)*`SRAM_RDATA_W) +: `SRAM_RDATA_W];
                            lane_req_id_r[(shift_i*`REQ_ID_W) +: `REQ_ID_W] <=
                                lane_req_id_r[((shift_i-1)*`REQ_ID_W) +: `REQ_ID_W];
                            lane_pe_mask_r[(shift_i*`PE_MASK_W) +: `PE_MASK_W] <=
                                lane_pe_mask_r[((shift_i-1)*`PE_MASK_W) +: `PE_MASK_W];
                            lane_priority_r[(shift_i*`REQ_PRIORITY_W) +: `REQ_PRIORITY_W] <=
                                lane_priority_r[((shift_i-1)*`REQ_PRIORITY_W) +: `REQ_PRIORITY_W];
                            lane_bank_id_r[(shift_i*`BANK_ID_W) +: `BANK_ID_W] <=
                                lane_bank_id_r[((shift_i-1)*`BANK_ID_W) +: `BANK_ID_W];
                            lane_subbank_id_r[(shift_i*`SUBBANK_ID_W) +: `SUBBANK_ID_W] <=
                                lane_subbank_id_r[((shift_i-1)*`SUBBANK_ID_W) +: `SUBBANK_ID_W];
                        end
                    end

                    lane_valid_r[accept_store_idx_c] <= 1'b1;
                    lane_merge_r[accept_store_idx_c] <= accept_same_addr_merge_c;
                    lane_write_r[accept_store_idx_c] <= req_in_write;
                    lane_bypass_r[accept_store_idx_c] <=
                        accept_same_addr_bypass_c && !req_in_write;
                    lane_addr_r[(accept_store_idx_c*`SRAM_ADDR_W) +: `SRAM_ADDR_W] <=
                        req_in_addr;
                    lane_wdata_r[(accept_store_idx_c*`SRAM_WDATA_W) +: `SRAM_WDATA_W] <=
                        req_in_wdata;
                    if (accept_same_addr_bypass_c && !req_in_write) begin
                        lane_bypass_data_r[(accept_store_idx_c*`SRAM_RDATA_W) +: `SRAM_RDATA_W] <=
                            lane_wdata_r[(accept_bypass_source_idx_c*`SRAM_WDATA_W) +: `SRAM_WDATA_W];
                    end else begin
                        lane_bypass_data_r[(accept_store_idx_c*`SRAM_RDATA_W) +: `SRAM_RDATA_W] <=
                            {`SRAM_RDATA_W{1'b0}};
                    end
                    lane_req_id_r[(accept_store_idx_c*`REQ_ID_W) +: `REQ_ID_W] <=
                        req_in_req_id;
                    lane_pe_mask_r[(accept_store_idx_c*`PE_MASK_W) +: `PE_MASK_W] <=
                        req_in_pe_mask;
                    lane_priority_r[(accept_store_idx_c*`REQ_PRIORITY_W) +: `REQ_PRIORITY_W] <=
                        req_in_priority;
                    lane_bank_id_r[(accept_store_idx_c*`BANK_ID_W) +: `BANK_ID_W] <=
                        req_in_bank_id;
                    lane_subbank_id_r[(accept_store_idx_c*`SUBBANK_ID_W) +: `SUBBANK_ID_W] <=
                        req_in_subbank_id;

                    if (accept_same_addr_bypass_c && req_in_write) begin
                        lane_bypass_r[accept_bypass_source_idx_c] <= 1'b1;
                        lane_bypass_data_r[(accept_bypass_source_idx_c*`SRAM_RDATA_W) +: `SRAM_RDATA_W] <=
                            req_in_wdata;
                    end
                    collect_wait_r <= 1'b0;

                    if (accept_lane_idx_c == (`MEM_REQ_LANES-1)) begin
                        state_r <= STATE_ISSUE;
                    end
                end else if (collect_wait_r) begin
                    state_r <= STATE_ISSUE;
                end else begin
                    collect_wait_r <= 1'b1;
                end
            end

            STATE_ISSUE: begin
                if (issue_ready_c) begin
                    collect_wait_r <= 1'b0;
                    for (resp_i = 0; resp_i < `MEM_REQ_LANES; resp_i = resp_i + 1) begin
                        if (lane_valid_r[resp_i] && lane_bypass_r[resp_i] &&
                            !lane_write_r[resp_i]) begin
                            resp_valid_r[resp_i] <= 1'b1;
                            resp_rdata_r[(resp_i*`SRAM_RDATA_W) +: `SRAM_RDATA_W] <=
                                lane_bypass_data_r[(resp_i*`SRAM_RDATA_W) +: `SRAM_RDATA_W];
                            resp_req_id_r[(resp_i*`REQ_ID_W) +: `REQ_ID_W] <=
                                lane_req_id_r[(resp_i*`REQ_ID_W) +: `REQ_ID_W];
                            resp_pe_mask_r[(resp_i*`PE_MASK_W) +: `PE_MASK_W] <=
                                lane_pe_mask_r[(resp_i*`PE_MASK_W) +: `PE_MASK_W];
                            resp_last_r[resp_i] <= 1'b1;
                        end
                    end

                    if (!issue_has_response_c) begin
                        lane_valid_r <= {`MEM_REQ_LANES{1'b0}};
                        lane_merge_r <= {`MEM_REQ_LANES{1'b0}};
                        lane_write_r <= {`MEM_REQ_LANES{1'b0}};
                        lane_bypass_r <= {`MEM_REQ_LANES{1'b0}};
                        lane_priority_r <= {(`MEM_REQ_LANES*`REQ_PRIORITY_W){1'b0}};
                        state_r <= STATE_IDLE;
                    end else if (issue_has_sram_read_c) begin
                        state_r <= STATE_WAIT_RESP;
                    end else begin
                        state_r <= STATE_RESP;
                    end
                end
            end

            STATE_WAIT_RESP: begin
                for (resp_i = 0; resp_i < `MEM_REQ_LANES; resp_i = resp_i + 1) begin
                    if (lane_valid_r[resp_i] && !lane_write_r[resp_i] &&
                        !lane_merge_r[resp_i] && !lane_bypass_r[resp_i] &&
                        mem_resp_valid[resp_i]) begin
                        resp_valid_r[resp_i] <= 1'b1;
                        resp_rdata_r[(resp_i*`SRAM_RDATA_W) +: `SRAM_RDATA_W] <=
                            mem_resp_rdata[(resp_i*`SRAM_RDATA_W) +: `SRAM_RDATA_W];
                        resp_req_id_r[(resp_i*`REQ_ID_W) +: `REQ_ID_W] <=
                            lane_req_id_r[(resp_i*`REQ_ID_W) +: `REQ_ID_W];
                        resp_pe_mask_r[(resp_i*`PE_MASK_W) +: `PE_MASK_W] <=
                            lane_pe_mask_r[(resp_i*`PE_MASK_W) +: `PE_MASK_W];
                        resp_last_r[resp_i] <= mem_resp_last[resp_i];
                    end

                    if (lane_valid_r[resp_i] && !lane_write_r[resp_i] &&
                        lane_merge_r[resp_i] &&
                        mem_resp_valid[0]) begin
                        resp_valid_r[resp_i] <= 1'b1;
                        resp_rdata_r[(resp_i*`SRAM_RDATA_W) +: `SRAM_RDATA_W] <=
                            mem_resp_rdata[0 +: `SRAM_RDATA_W];
                        resp_req_id_r[(resp_i*`REQ_ID_W) +: `REQ_ID_W] <=
                            lane_req_id_r[(resp_i*`REQ_ID_W) +: `REQ_ID_W];
                        resp_pe_mask_r[(resp_i*`PE_MASK_W) +: `PE_MASK_W] <=
                            lane_pe_mask_r[(resp_i*`PE_MASK_W) +: `PE_MASK_W];
                        resp_last_r[resp_i] <= mem_resp_last[0];
                    end
                end

                if (resp_complete_c) begin
                    state_r <= STATE_RESP;
                end
            end

            STATE_RESP: begin
                for (resp_i = 0; resp_i < `MEM_REQ_LANES; resp_i = resp_i + 1) begin
                    if (resp_valid_r[resp_i] && resp_out_ready[resp_i]) begin
                        resp_valid_r[resp_i] <= 1'b0;
                    end
                end

                if ((resp_valid_r & ~resp_out_ready) == {`MEM_REQ_LANES{1'b0}}) begin
                    lane_valid_r <= {`MEM_REQ_LANES{1'b0}};
                    lane_merge_r <= {`MEM_REQ_LANES{1'b0}};
                    lane_write_r <= {`MEM_REQ_LANES{1'b0}};
                    lane_bypass_r <= {`MEM_REQ_LANES{1'b0}};
                    lane_priority_r <= {(`MEM_REQ_LANES*`REQ_PRIORITY_W){1'b0}};
                    state_r <= STATE_IDLE;
                end
            end

            default: begin
                state_r <= STATE_IDLE;
            end
        endcase
    end
end

endmodule
