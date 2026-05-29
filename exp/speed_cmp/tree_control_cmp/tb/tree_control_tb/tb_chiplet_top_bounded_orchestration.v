`timescale 1ns/1ps

`include "config/prediction_params.vh"
`include "config/interface_params.vh"
`include "config/memory_params.vh"

module tb_control_chip_bounded_orchestration;

localparam integer CFG_W = 32;
localparam [CFG_W-1:0] RUN_041_CFG_DATA = 32'h0410_0001;
localparam integer BUSY_ASSERT_TIMEOUT_CYCLES = 24;
localparam integer HBM_WRITE_TIMEOUT_CYCLES = 160;
localparam integer BUSY_CLEAR_TIMEOUT_CYCLES = 48;

reg clk;
reg rst_n;
reg cfg_valid;
reg [CFG_W-1:0] cfg_data;
reg start;
reg hbm_resp_valid;
reg [`HBM_DATA_W-1:0] hbm_resp_rdata;
reg [`REQ_ID_W-1:0] hbm_resp_id;

wire busy;
wire error_flag;
wire hbm_req_valid;
wire hbm_req_write;
wire [`HBM_ADDR_W-1:0] hbm_req_addr;
wire [`HBM_DATA_W-1:0] hbm_req_wdata;
wire [`REQ_ID_W-1:0] hbm_req_id;

integer cycle_i;

control_chip #(
    .CFG_W(CFG_W)
) u_control_chip (
    .clk(clk),
    .rst_n(rst_n),
    .cfg_valid(cfg_valid),
    .cfg_data(cfg_data),
    .start(start),
    .hbm_resp_valid(hbm_resp_valid),
    .hbm_resp_rdata(hbm_resp_rdata),
    .hbm_resp_id(hbm_resp_id),
    .busy(busy),
    .error_flag(error_flag),
    .hbm_req_valid(hbm_req_valid),
    .hbm_req_write(hbm_req_write),
    .hbm_req_addr(hbm_req_addr),
    .hbm_req_wdata(hbm_req_wdata),
    .hbm_req_id(hbm_req_id)
);

always #5 clk = ~clk;

task clear_inputs;
    begin
        cfg_valid = 1'b0;
        cfg_data = {CFG_W{1'b0}};
        start = 1'b0;
        hbm_resp_valid = 1'b0;
        hbm_resp_rdata = {`HBM_DATA_W{1'b0}};
        hbm_resp_id = {`REQ_ID_W{1'b0}};
    end
endtask

task launch_bounded_scenario;
    begin
        @(posedge clk);
        #1;
        cfg_valid = 1'b1;
        cfg_data = RUN_041_CFG_DATA;
        start = 1'b1;

        @(posedge clk);
        #1;
        cfg_valid = 1'b0;
        cfg_data = {CFG_W{1'b0}};
        start = 1'b0;
    end
endtask

task expect_busy_assert;
    reg seen_busy;
    begin
        seen_busy = 1'b0;
        for (cycle_i = 0; cycle_i < BUSY_ASSERT_TIMEOUT_CYCLES;
             cycle_i = cycle_i + 1) begin
            @(posedge clk);
            #1;
            if (error_flag) begin
                $fatal(1, "control_chip raised error_flag before orchestration");
            end
            if (busy) begin
                seen_busy = 1'b1;
                disable expect_busy_assert;
            end
        end

        if (!seen_busy) begin
            $fatal(1,
                   "expected control_chip to leave all-idle state after cfg/start");
        end
    end
endtask

task expect_hbm_writeback;
    reg seen_writeback;
    begin
        seen_writeback = 1'b0;
        for (cycle_i = 0; cycle_i < HBM_WRITE_TIMEOUT_CYCLES;
             cycle_i = cycle_i + 1) begin
            @(posedge clk);
            #1;
            if (error_flag) begin
                $fatal(1, "control_chip raised error_flag before writeback");
            end
            if (hbm_req_valid && hbm_req_write) begin
                if (hbm_req_addr == {`HBM_ADDR_W{1'b0}}) begin
                    $fatal(1, "expected non-zero bounded writeback address");
                end
                if (hbm_req_wdata == {`HBM_DATA_W{1'b0}}) begin
                    $fatal(1, "expected non-zero bounded writeback payload");
                end
                if (hbm_req_id == {`REQ_ID_W{1'b0}}) begin
                    $fatal(1, "expected non-zero bounded writeback req_id");
                end
                seen_writeback = 1'b1;
                disable expect_hbm_writeback;
            end
        end

        if (!seen_writeback) begin
            $fatal(1, "expected bounded top-level HBM writeback request");
        end
    end
endtask

task expect_busy_clear;
    reg seen_clear;
    begin
        seen_clear = 1'b0;
        for (cycle_i = 0; cycle_i < BUSY_CLEAR_TIMEOUT_CYCLES;
             cycle_i = cycle_i + 1) begin
            @(posedge clk);
            #1;
            if (!busy) begin
                seen_clear = 1'b1;
                disable expect_busy_clear;
            end
        end

        if (!seen_clear) begin
            $fatal(1, "control_chip did not return busy low after writeback");
        end
    end
endtask

initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    clear_inputs();

    repeat (3) @(posedge clk);
    rst_n = 1'b1;

    @(posedge clk);
    #1;
    if (busy || error_flag || hbm_req_valid || hbm_req_write ||
        hbm_req_addr != {`HBM_ADDR_W{1'b0}} ||
        hbm_req_wdata != {`HBM_DATA_W{1'b0}} ||
        hbm_req_id != {`REQ_ID_W{1'b0}}) begin
        $fatal(1, "control_chip should be idle right after reset release");
    end

    launch_bounded_scenario();
    expect_busy_assert();
    expect_hbm_writeback();
    expect_busy_clear();

    if (error_flag) begin
        $fatal(1, "control_chip should complete bounded scenario without error");
    end

    $display("tb_control_chip_bounded_orchestration PASS");
    $finish;
end

endmodule
