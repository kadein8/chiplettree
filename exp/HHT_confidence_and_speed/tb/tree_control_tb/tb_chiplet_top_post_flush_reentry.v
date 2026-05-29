`timescale 1ns/1ps

`include "config/prediction_params.vh"
`include "config/interface_params.vh"
`include "config/memory_params.vh"

module tb_control_chip_post_flush_reentry;

localparam integer CFG_W = 32;
localparam [CFG_W-1:0] RUN_042_WAVE1_CFG_DATA = 32'h0420_0001;
localparam [CFG_W-1:0] RUN_042_WAVE2_CFG_DATA = 32'h0420_0002;
localparam integer BUSY_ASSERT_TIMEOUT_CYCLES = 24;
localparam integer WAVE1_WRITE_TIMEOUT_CYCLES = 160;
localparam integer BUSY_CLEAR_TIMEOUT_CYCLES = 48;
localparam integer QUIET_GAP_CYCLES = 4;
localparam integer WAVE2_COMPLETION_TIMEOUT_CYCLES = 160;

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
integer wave1_write_count;
reg wave2_seen_busy;
reg wave2_seen_prep_done;
reg wave2_seen_read_done;

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
    input [CFG_W-1:0] cfg_word;
    begin
        @(posedge clk);
        #1;
        cfg_valid = 1'b1;
        cfg_data = cfg_word;
        start = 1'b1;

        @(posedge clk);
        #1;
        cfg_valid = 1'b0;
        cfg_data = {CFG_W{1'b0}};
        start = 1'b0;
    end
endtask

task expect_busy_assert;
    input [8*32-1:0] phase_name;
    reg seen_busy;
    begin
        seen_busy = 1'b0;
        for (cycle_i = 0; cycle_i < BUSY_ASSERT_TIMEOUT_CYCLES;
             cycle_i = cycle_i + 1) begin
            @(posedge clk);
            #1;
            if (error_flag) begin
                $fatal(1, "%0s: control_chip raised error_flag before busy asserted",
                       phase_name);
            end
            if (busy) begin
                seen_busy = 1'b1;
                disable expect_busy_assert;
            end
        end

        if (!seen_busy) begin
            $fatal(1, "%0s: expected control_chip to assert busy after cfg/start",
                   phase_name);
        end
    end
endtask

task expect_wave1_writeback;
    reg seen_writeback;
    begin
        seen_writeback = 1'b0;
        wave1_write_count = 0;

        for (cycle_i = 0; cycle_i < WAVE1_WRITE_TIMEOUT_CYCLES;
             cycle_i = cycle_i + 1) begin
            @(posedge clk);
            #1;
            if (error_flag) begin
                $fatal(1, "wave1: control_chip raised error_flag before writeback");
            end
            if (hbm_req_valid && hbm_req_write) begin
                if (hbm_req_addr == {`HBM_ADDR_W{1'b0}}) begin
                    $fatal(1, "wave1: expected non-zero bounded writeback address");
                end
                if (hbm_req_wdata == {`HBM_DATA_W{1'b0}}) begin
                    $fatal(1, "wave1: expected non-zero bounded writeback payload");
                end
                if (hbm_req_id == {`REQ_ID_W{1'b0}}) begin
                    $fatal(1, "wave1: expected non-zero bounded writeback req_id");
                end
                wave1_write_count = wave1_write_count + 1;
                seen_writeback = 1'b1;
                disable expect_wave1_writeback;
            end
        end

        if (!seen_writeback) begin
            $fatal(1, "wave1: expected bounded top-level HBM writeback request");
        end
    end
endtask

task expect_busy_clear;
    input [8*32-1:0] phase_name;
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
            $fatal(1, "%0s: control_chip did not return busy low", phase_name);
        end
    end
endtask

task expect_quiet_gap_after_wave1;
    begin
        for (cycle_i = 0; cycle_i < QUIET_GAP_CYCLES; cycle_i = cycle_i + 1) begin
            @(posedge clk);
            #1;
            if (busy) begin
                $fatal(1, "expected quiet gap after wave1, but busy re-asserted");
            end
            if (error_flag) begin
                $fatal(1, "expected quiet gap after wave1, but error_flag asserted");
            end
            if (u_control_chip.u_compute_module_bounded_stub.survivor_read_done) begin
                $fatal(1, "wave2 survivor_read_done should not pulse during quiet gap");
            end
        end
    end
endtask

task expect_wave2_reentry_without_flush_or_writeback;
    begin
        wave2_seen_prep_done = 1'b0;
        wave2_seen_read_done = 1'b0;

        for (cycle_i = 0; cycle_i < WAVE2_COMPLETION_TIMEOUT_CYCLES;
             cycle_i = cycle_i + 1) begin
            @(posedge clk);
            #1;

            if (error_flag) begin
                $fatal(1, "wave2: control_chip raised error_flag during re-entry");
            end

            if (u_control_chip.u_prediction_unit_bounded_stub.flush_done) begin
                $fatal(1,
                       "wave2: bounded re-entry must not require a second flush closure");
            end

            if (hbm_req_valid && hbm_req_write) begin
                $fatal(1,
                       "wave2: bounded re-entry must not require a second top-level writeback closure");
            end

            if (u_control_chip.u_compute_module_bounded_stub.prep_done) begin
                wave2_seen_prep_done = 1'b1;
            end

            if (u_control_chip.u_compute_module_bounded_stub.survivor_read_done) begin
                wave2_seen_read_done = 1'b1;
            end

            if (wave2_seen_prep_done && wave2_seen_read_done && !busy) begin
                disable expect_wave2_reentry_without_flush_or_writeback;
            end
        end

        if (!wave2_seen_prep_done) begin
            $fatal(1, "wave2: expected prep_done to re-assert after second launch");
        end

        if (!wave2_seen_read_done) begin
            $fatal(1,
                   "wave2: expected survivor_read_done to pulse after second launch");
        end

        if (busy) begin
            $fatal(1, "wave2: expected busy to clear after second-wave completion");
        end
    end
endtask

initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    wave1_write_count = 0;
    wave2_seen_busy = 1'b0;
    wave2_seen_prep_done = 1'b0;
    wave2_seen_read_done = 1'b0;
    clear_inputs();

    repeat (3) @(posedge clk);
    rst_n = 1'b1;

    @(posedge clk);
    #1;
    if (busy || error_flag || hbm_req_valid || hbm_req_write ||
        hbm_req_addr != {`HBM_ADDR_W{1'b0}} ||
        hbm_req_wdata != {`HBM_DATA_W{1'b0}} ||
        hbm_req_id != {`REQ_ID_W{1'b0}} ||
        u_control_chip.u_compute_module_bounded_stub.prep_done ||
        u_control_chip.u_compute_module_bounded_stub.survivor_read_done) begin
        $fatal(1, "control_chip should be idle right after reset release");
    end

    launch_bounded_scenario(RUN_042_WAVE1_CFG_DATA);
    expect_busy_assert("wave1");
    expect_wave1_writeback();
    expect_busy_clear("wave1");

    if (wave1_write_count != 1) begin
        $fatal(1, "wave1: expected exactly one bounded top-level writeback");
    end

    expect_quiet_gap_after_wave1();

    launch_bounded_scenario(RUN_042_WAVE2_CFG_DATA);
    expect_busy_assert("wave2");
    wave2_seen_busy = 1'b1;
    expect_wave2_reentry_without_flush_or_writeback();

    if (!wave2_seen_busy) begin
        $fatal(1, "wave2: expected busy re-entry after second launch");
    end

    if (error_flag) begin
        $fatal(1, "control_chip should complete bounded re-entry scenario without error");
    end

    $display("tb_control_chip_post_flush_reentry PASS");
    $finish;
end

endmodule
