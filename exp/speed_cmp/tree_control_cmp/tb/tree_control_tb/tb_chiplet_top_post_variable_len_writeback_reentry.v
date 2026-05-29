`timescale 1ns/1ps

`include "config/prediction_params.vh"
`include "config/interface_params.vh"
`include "config/memory_params.vh"

module tb_control_chip_post_variable_len_writeback_reentry;

localparam integer CFG_W = 32;
localparam [CFG_W-1:0] RUN_049_WAVE1_CFG_DATA = 32'h0480_0003;
localparam [CFG_W-1:0] RUN_049_WAVE2_CFG_DATA = 32'h0490_0001;
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
reg wave2_seen_prep_req;
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

function [`HBM_DATA_W-1:0] pack_expected_packet;
    input [15:0] len_i;
    input [15:0] token0_i;
    input [15:0] token1_i;
    input [15:0] token2_i;
    begin
        pack_expected_packet =
            {{(`HBM_DATA_W-64){1'b0}}, token2_i, token1_i, token0_i, len_i};
    end
endfunction

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

task apply_reset_and_check_idle;
    begin
        clear_inputs();
        rst_n = 1'b0;
        repeat (3) @(posedge clk);
        rst_n = 1'b1;

        @(posedge clk);
        #1;
        if (busy || error_flag || hbm_req_valid || hbm_req_write ||
            hbm_req_addr != {`HBM_ADDR_W{1'b0}} ||
            hbm_req_wdata != {`HBM_DATA_W{1'b0}} ||
            hbm_req_id != {`REQ_ID_W{1'b0}} ||
            u_control_chip.u_prediction_unit_bounded_stub.flush_done ||
            u_control_chip.u_compute_module_bounded_stub.prep_done ||
            u_control_chip.u_compute_module_bounded_stub.survivor_read_done) begin
            $fatal(1, "control_chip should be idle right after reset release");
        end
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

task expect_wave1_packet_and_busy_clear;
    reg seen_writeback;
    reg seen_busy_clear;
    reg [`HBM_DATA_W-1:0] expected_wdata;
    begin
        seen_writeback = 1'b0;
        seen_busy_clear = 1'b0;
        wave1_write_count = 0;
        expected_wdata =
            pack_expected_packet(16'h0003, 16'h0301, 16'h0302, 16'h0303);

        for (cycle_i = 0; cycle_i < WAVE1_WRITE_TIMEOUT_CYCLES;
             cycle_i = cycle_i + 1) begin
            @(posedge clk);
            #1;

            if (error_flag) begin
                $fatal(1, "wave1: control_chip raised error_flag before writeback");
            end

            if (u_control_chip.u_prediction_unit_bounded_stub.flush_done) begin
                $fatal(1, "wave1: run_048-style packet proof must not require flush");
            end

            if (hbm_req_valid && hbm_req_write) begin
                wave1_write_count = wave1_write_count + 1;

                if (wave1_write_count > 1) begin
                    $fatal(1, "wave1: expected exactly one top-level writeback packet");
                end

                if (hbm_req_addr == {`HBM_ADDR_W{1'b0}}) begin
                    $fatal(1, "wave1: expected non-zero bounded writeback address");
                end

                if (hbm_req_id == {`REQ_ID_W{1'b0}}) begin
                    $fatal(1, "wave1: expected non-zero bounded writeback req_id");
                end

                if (hbm_req_wdata !== expected_wdata) begin
                    $fatal(1,
                           "wave1: expected exact variable-length token packet %h, got %h",
                           expected_wdata,
                           hbm_req_wdata);
                end

                seen_writeback = 1'b1;
            end

            if (seen_writeback && !busy) begin
                seen_busy_clear = 1'b1;
                disable expect_wave1_packet_and_busy_clear;
            end
        end

        if (!seen_writeback) begin
            $fatal(1, "wave1: expected one bounded top-level writeback packet");
        end

        if (!seen_busy_clear) begin
            $fatal(1, "wave1: expected busy to clear after the writeback packet");
        end
    end
endtask

task expect_quiet_gap_after_wave1;
    begin
        for (cycle_i = 0; cycle_i < QUIET_GAP_CYCLES; cycle_i = cycle_i + 1) begin
            @(posedge clk);
            #1;
            if (busy || error_flag || hbm_req_valid || hbm_req_write) begin
                $fatal(1, "expected quiet gap after wave1 writeback");
            end
            if (u_control_chip.u_prediction_unit_bounded_stub.flush_done ||
                u_control_chip.prep_req_valid ||
                u_control_chip.u_compute_module_bounded_stub.survivor_read_done) begin
                $fatal(1, "quiet gap after wave1 should not contain wave2 activity");
            end
        end
    end
endtask

task expect_wave2_reentry_without_flush_or_writeback;
    begin
        wave2_seen_prep_req = 1'b0;
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
                       "wave2: bounded re-entry after run_048 must not require a new flush");
            end

            if (hbm_req_valid && hbm_req_write) begin
                $fatal(1,
                       "wave2: bounded re-entry after run_048 must not emit a second writeback packet");
            end

            if (u_control_chip.prep_req_valid) begin
                wave2_seen_prep_req = 1'b1;
            end

            if (u_control_chip.u_compute_module_bounded_stub.survivor_read_done) begin
                wave2_seen_read_done = 1'b1;
            end

            if (wave2_seen_prep_req && wave2_seen_read_done && !busy) begin
                disable expect_wave2_reentry_without_flush_or_writeback;
            end
        end

        if (!wave2_seen_prep_req) begin
            $fatal(1, "wave2: expected fresh prep_req_valid after second launch");
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
    wave2_seen_prep_req = 1'b0;
    wave2_seen_read_done = 1'b0;
    clear_inputs();

    apply_reset_and_check_idle();

    launch_bounded_scenario(RUN_049_WAVE1_CFG_DATA);
    expect_busy_assert("wave1");
    expect_wave1_packet_and_busy_clear();

    if (wave1_write_count != 1) begin
        $fatal(1, "wave1: expected exactly one bounded top-level writeback");
    end

    expect_quiet_gap_after_wave1();

    launch_bounded_scenario(RUN_049_WAVE2_CFG_DATA);
    expect_busy_assert("wave2");
    expect_wave2_reentry_without_flush_or_writeback();

    if (error_flag) begin
        $fatal(1,
               "control_chip should complete post-variable-length-writeback re-entry without error");
    end

    $display("tb_control_chip_post_variable_len_writeback_reentry PASS");
    $finish;
end

endmodule
