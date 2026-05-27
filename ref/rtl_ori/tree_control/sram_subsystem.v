`timescale 1ns/1ps

`include "config/interface_params.vh"
`include "config/memory_params.vh"

module sram_subsystem (
    input                                               clk,
    input                                               rst_n,
    input  [`MEM_REQ_LANES-1:0]                         mem_req_valid,
    output [`MEM_REQ_LANES-1:0]                         mem_req_ready,
    input  [`MEM_REQ_LANES-1:0]                         mem_req_write,
    input  [`MEM_REQ_LANES*`SRAM_ADDR_W-1:0]            mem_req_addr,
    input  [`MEM_REQ_LANES*`SRAM_WDATA_W-1:0]           mem_req_wdata,
    input  [`MEM_REQ_LANES*`REQ_ID_W-1:0]               mem_req_id,
    output [`MEM_REQ_LANES-1:0]                         mem_resp_valid,
    output [`MEM_REQ_LANES*`SRAM_RDATA_W-1:0]           mem_resp_rdata,
    output [`MEM_REQ_LANES*`REQ_ID_W-1:0]               mem_resp_id,
    output [`MEM_REQ_LANES-1:0]                         mem_resp_last
);

localparam integer TOTAL_BANKS = `SRAM_NUM * `SRAM_BANK_NUM;
localparam integer TOTAL_BANKS_W =
    ((TOTAL_BANKS <= 1) ? 1 : $clog2(TOTAL_BANKS));
localparam integer LANE_IDX_W =
    ((`MEM_REQ_LANES <= 1) ? 1 : $clog2(`MEM_REQ_LANES));

reg [`SUBBANK_NUM_PER_BANK-1:0] bank_req_valid_r [0:TOTAL_BANKS-1];
reg [`SUBBANK_NUM_PER_BANK-1:0] bank_req_write_r [0:TOTAL_BANKS-1];
reg [`SUBBANK_NUM_PER_BANK*`ROW_ADDR_W-1:0] bank_req_row_addr_r [0:TOTAL_BANKS-1];
reg [`SUBBANK_NUM_PER_BANK*`OFFSET_W-1:0] bank_req_offset_r [0:TOTAL_BANKS-1];
reg [`SUBBANK_NUM_PER_BANK*`SRAM_WDATA_W-1:0] bank_req_wdata_r [0:TOTAL_BANKS-1];
reg [`SUBBANK_NUM_PER_BANK*`REQ_ID_W-1:0] bank_req_id_r [0:TOTAL_BANKS-1];
wire [`SUBBANK_NUM_PER_BANK-1:0] bank_req_ready_w [0:TOTAL_BANKS-1];
wire [`SUBBANK_NUM_PER_BANK-1:0] bank_resp_valid_w [0:TOTAL_BANKS-1];
wire [`SUBBANK_NUM_PER_BANK*`SRAM_RDATA_W-1:0] bank_resp_rdata_w [0:TOTAL_BANKS-1];
wire [`SUBBANK_NUM_PER_BANK*`REQ_ID_W-1:0] bank_resp_id_w [0:TOTAL_BANKS-1];
wire [`SUBBANK_NUM_PER_BANK-1:0] bank_resp_last_w [0:TOTAL_BANKS-1];

reg [`MEM_REQ_LANES-1:0] mem_req_ready_r;
reg [`MEM_REQ_LANES-1:0] mem_resp_valid_r;
reg [`MEM_REQ_LANES*`SRAM_RDATA_W-1:0] mem_resp_rdata_r;
reg [`MEM_REQ_LANES*`REQ_ID_W-1:0] mem_resp_id_r;
reg [`MEM_REQ_LANES-1:0] mem_resp_last_r;
reg [`MEM_REQ_LANES-1:0] lane_release_now_r;

reg [`SUBBANK_NUM_PER_BANK-1:0] claimed_subbank_r [0:TOTAL_BANKS-1];
reg [`MEM_REQ_LANES-1:0] lane_accept_valid_r;
reg [`MEM_REQ_LANES-1:0] lane_accept_read_r;
reg [TOTAL_BANKS_W-1:0] lane_target_bank_r [0:`MEM_REQ_LANES-1];
reg [`SUBBANK_ID_W-1:0] lane_target_subbank_r [0:`MEM_REQ_LANES-1];

reg lane_busy_r [0:`MEM_REQ_LANES-1];
reg owner_valid_r [0:TOTAL_BANKS-1][0:`SUBBANK_NUM_PER_BANK-1];
reg [LANE_IDX_W-1:0] owner_lane_r [0:TOTAL_BANKS-1][0:`SUBBANK_NUM_PER_BANK-1];

genvar bank_gi;
integer bank_i;
integer subbank_i;
integer lane_i;
integer owner_lane_i;
integer target_bank_i;
reg [`SRAM_ADDR_W-1:0] lane_addr_value;
reg [`SRAM_ID_W-1:0] lane_sram_id_value;
reg [`BANK_ID_W-1:0] lane_bank_id_value;
reg [`SUBBANK_ID_W-1:0] lane_subbank_id_value;
reg [`ROW_ADDR_W-1:0] lane_row_addr_value;
reg [`OFFSET_W-1:0] lane_offset_value;

assign mem_req_ready = mem_req_ready_r;
assign mem_resp_valid = mem_resp_valid_r;
assign mem_resp_rdata = mem_resp_rdata_r;
assign mem_resp_id = mem_resp_id_r;
assign mem_resp_last = mem_resp_last_r;

generate
    for (bank_gi = 0; bank_gi < TOTAL_BANKS; bank_gi = bank_gi + 1) begin : gen_banks
        sram_bank u_sram_bank (
            .clk(clk),
            .rst_n(rst_n),
            .req_valid(bank_req_valid_r[bank_gi]),
            .req_ready(bank_req_ready_w[bank_gi]),
            .req_write(bank_req_write_r[bank_gi]),
            .req_row_addr(bank_req_row_addr_r[bank_gi]),
            .req_offset(bank_req_offset_r[bank_gi]),
            .req_wdata(bank_req_wdata_r[bank_gi]),
            .req_id(bank_req_id_r[bank_gi]),
            .resp_valid(bank_resp_valid_w[bank_gi]),
            .resp_ready({`SUBBANK_NUM_PER_BANK{1'b1}}),
            .resp_rdata(bank_resp_rdata_w[bank_gi]),
            .resp_id(bank_resp_id_w[bank_gi]),
            .resp_last(bank_resp_last_w[bank_gi])
        );
    end
endgenerate

always @* begin
    mem_req_ready_r = {`MEM_REQ_LANES{1'b0}};
    mem_resp_valid_r = {`MEM_REQ_LANES{1'b0}};
    mem_resp_rdata_r = {(`MEM_REQ_LANES*`SRAM_RDATA_W){1'b0}};
    mem_resp_id_r = {(`MEM_REQ_LANES*`REQ_ID_W){1'b0}};
    mem_resp_last_r = {`MEM_REQ_LANES{1'b0}};
    lane_release_now_r = {`MEM_REQ_LANES{1'b0}};
    lane_accept_valid_r = {`MEM_REQ_LANES{1'b0}};
    lane_accept_read_r = {`MEM_REQ_LANES{1'b0}};

    for (lane_i = 0; lane_i < `MEM_REQ_LANES; lane_i = lane_i + 1) begin
        lane_target_bank_r[lane_i] = {TOTAL_BANKS_W{1'b0}};
        lane_target_subbank_r[lane_i] = {`SUBBANK_ID_W{1'b0}};
    end

    for (bank_i = 0; bank_i < TOTAL_BANKS; bank_i = bank_i + 1) begin
        bank_req_valid_r[bank_i] = {`SUBBANK_NUM_PER_BANK{1'b0}};
        bank_req_write_r[bank_i] = {`SUBBANK_NUM_PER_BANK{1'b0}};
        bank_req_row_addr_r[bank_i] =
            {(`SUBBANK_NUM_PER_BANK*`ROW_ADDR_W){1'b0}};
        bank_req_offset_r[bank_i] =
            {(`SUBBANK_NUM_PER_BANK*`OFFSET_W){1'b0}};
        bank_req_wdata_r[bank_i] =
            {(`SUBBANK_NUM_PER_BANK*`SRAM_WDATA_W){1'b0}};
        bank_req_id_r[bank_i] =
            {(`SUBBANK_NUM_PER_BANK*`REQ_ID_W){1'b0}};
        claimed_subbank_r[bank_i] = {`SUBBANK_NUM_PER_BANK{1'b0}};
    end

    for (bank_i = 0; bank_i < TOTAL_BANKS; bank_i = bank_i + 1) begin
        for (subbank_i = 0;
             subbank_i < `SUBBANK_NUM_PER_BANK;
             subbank_i = subbank_i + 1) begin
            if (bank_resp_valid_w[bank_i][subbank_i] &&
                owner_valid_r[bank_i][subbank_i]) begin
                owner_lane_i = owner_lane_r[bank_i][subbank_i];
                lane_release_now_r[owner_lane_i] = 1'b1;
                mem_resp_valid_r[owner_lane_i] = 1'b1;
                mem_resp_rdata_r[(owner_lane_i*`SRAM_RDATA_W) +: `SRAM_RDATA_W] =
                    bank_resp_rdata_w[bank_i][(subbank_i*`SRAM_RDATA_W) +: `SRAM_RDATA_W];
                mem_resp_id_r[(owner_lane_i*`REQ_ID_W) +: `REQ_ID_W] =
                    bank_resp_id_w[bank_i][(subbank_i*`REQ_ID_W) +: `REQ_ID_W];
                mem_resp_last_r[owner_lane_i] = bank_resp_last_w[bank_i][subbank_i];
            end
        end
    end

    for (lane_i = 0; lane_i < `MEM_REQ_LANES; lane_i = lane_i + 1) begin
        lane_addr_value = mem_req_addr[(lane_i*`SRAM_ADDR_W) +: `SRAM_ADDR_W];
        lane_offset_value = lane_addr_value[`OFFSET_W-1:0];
        lane_row_addr_value =
            lane_addr_value[`OFFSET_W +: `ROW_ADDR_W];
        lane_subbank_id_value =
            lane_addr_value[(`OFFSET_W + `ROW_ADDR_W) +: `SUBBANK_ID_W];
        lane_bank_id_value =
            lane_addr_value[(`OFFSET_W + `ROW_ADDR_W + `SUBBANK_ID_W) +: `BANK_ID_W];
        lane_sram_id_value =
            lane_addr_value[(`OFFSET_W + `ROW_ADDR_W + `SUBBANK_ID_W + `BANK_ID_W) +: `SRAM_ID_W];
        target_bank_i = (lane_sram_id_value * `SRAM_BANK_NUM) + lane_bank_id_value;

        if (mem_req_valid[lane_i] &&
            (!lane_busy_r[lane_i] || lane_release_now_r[lane_i])) begin
            if (!claimed_subbank_r[target_bank_i][lane_subbank_id_value]) begin
                bank_req_valid_r[target_bank_i][lane_subbank_id_value] = 1'b1;
                bank_req_write_r[target_bank_i][lane_subbank_id_value] =
                    mem_req_write[lane_i];
                bank_req_row_addr_r[target_bank_i]
                    [(lane_subbank_id_value*`ROW_ADDR_W) +: `ROW_ADDR_W] =
                    lane_row_addr_value;
                bank_req_offset_r[target_bank_i]
                    [(lane_subbank_id_value*`OFFSET_W) +: `OFFSET_W] =
                    lane_offset_value;
                bank_req_wdata_r[target_bank_i]
                    [(lane_subbank_id_value*`SRAM_WDATA_W) +: `SRAM_WDATA_W] =
                    mem_req_wdata[(lane_i*`SRAM_WDATA_W) +: `SRAM_WDATA_W];
                bank_req_id_r[target_bank_i]
                    [(lane_subbank_id_value*`REQ_ID_W) +: `REQ_ID_W] =
                    mem_req_id[(lane_i*`REQ_ID_W) +: `REQ_ID_W];
                claimed_subbank_r[target_bank_i][lane_subbank_id_value] = 1'b1;

                if (bank_req_ready_w[target_bank_i][lane_subbank_id_value]) begin
                    mem_req_ready_r[lane_i] = 1'b1;
                    lane_accept_valid_r[lane_i] = 1'b1;
                    lane_accept_read_r[lane_i] = !mem_req_write[lane_i];
                    lane_target_bank_r[lane_i] = target_bank_i[TOTAL_BANKS_W-1:0];
                    lane_target_subbank_r[lane_i] = lane_subbank_id_value;
                end
            end
        end
    end
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        for (lane_i = 0; lane_i < `MEM_REQ_LANES; lane_i = lane_i + 1) begin
            lane_busy_r[lane_i] <= 1'b0;
        end
        for (bank_i = 0; bank_i < TOTAL_BANKS; bank_i = bank_i + 1) begin
            for (subbank_i = 0;
                 subbank_i < `SUBBANK_NUM_PER_BANK;
                 subbank_i = subbank_i + 1) begin
                owner_valid_r[bank_i][subbank_i] <= 1'b0;
                owner_lane_r[bank_i][subbank_i] <= {LANE_IDX_W{1'b0}};
            end
        end
    end else begin
        for (bank_i = 0; bank_i < TOTAL_BANKS; bank_i = bank_i + 1) begin
            for (subbank_i = 0;
                 subbank_i < `SUBBANK_NUM_PER_BANK;
                 subbank_i = subbank_i + 1) begin
                if (bank_resp_valid_w[bank_i][subbank_i] &&
                    owner_valid_r[bank_i][subbank_i]) begin
                    lane_busy_r[owner_lane_r[bank_i][subbank_i]] <= 1'b0;
                    owner_valid_r[bank_i][subbank_i] <= 1'b0;
                end
            end
        end

        for (lane_i = 0; lane_i < `MEM_REQ_LANES; lane_i = lane_i + 1) begin
            if (lane_accept_valid_r[lane_i] && lane_accept_read_r[lane_i]) begin
                lane_busy_r[lane_i] <= 1'b1;
                owner_valid_r[lane_target_bank_r[lane_i]][lane_target_subbank_r[lane_i]] <=
                    1'b1;
                owner_lane_r[lane_target_bank_r[lane_i]][lane_target_subbank_r[lane_i]] <=
                    lane_i[LANE_IDX_W-1:0];
            end
        end
    end
end

endmodule
