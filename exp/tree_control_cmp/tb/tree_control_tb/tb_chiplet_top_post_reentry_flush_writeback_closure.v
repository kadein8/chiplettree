`timescale 1ns/1ps

`include "config/prediction_params.vh"
`include "config/interface_params.vh"
`include "config/memory_params.vh"

module tb_control_chip_post_reentry_flush_writeback_closure;

localparam integer CFG_W = 32;
localparam [CFG_W-1:0] RUN_050_WAVE1_CFG_DATA = 32'h0480_0003;
localparam [CFG_W-1:0] RUN_050_WAVE2_CFG_DATA = 32'h04a0_0001;
localparam integer BUSY_ASSERT_TIMEOUT_CYCLES = 24;
localparam integer WAVE1_WRITE_TIMEOUT_CYCLES = 160;
localparam integer QUIET_GAP_CYCLES = 4;
localparam integer WAVE2_PREFLUSH_TIMEOUT_CYCLES = 160;
localparam integer WAVE2_FLUSH_TIMEOUT_CYCLES = 80;
localparam integer WAVE2_POSTFLUSH_TIMEOUT_CYCLES = 160;
localparam integer WAVE2_WRITEBACK_TIMEOUT_CYCLES = 160;

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
integer wave2_write_count;
integer wave2_flush_pulse_count;
reg wave2_seen_prep_done;
reg wave2_seen_preflush_read_done;
reg wave2_seen_flush_done;
reg wave2_seen_token_flush;
reg wave2_seen_reclaim_handoff;
reg wave2_seen_postflush_read_done;
reg wave2_seen_postflush_writeback;

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
            u_control_chip.u_compute_module_bounded_stub.survivor_read_done ||
            u_control_chip.token_flush_valid ||
            u_control_chip.flush_reclaim_valid) begin
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
    input [8*40-1:0] phase_name;
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
                u_control_chip.u_compute_module_bounded_stub.survivor_read_done ||
                u_control_chip.token_flush_valid ||
                u_control_chip.flush_reclaim_valid) begin
                $fatal(1, "quiet gap after wave1 should not contain wave2 activity");
            end
        end
    end
endtask

task expect_wave2_preflush_consume;
    begin
        wave2_seen_prep_done = 1'b0;
        wave2_seen_preflush_read_done = 1'b0;

        for (cycle_i = 0; cycle_i < WAVE2_PREFLUSH_TIMEOUT_CYCLES;
             cycle_i = cycle_i + 1) begin
            @(posedge clk);
            #1;

            if (error_flag) begin
                $fatal(1, "wave2: control_chip raised error_flag before preflush consume");
            end

            if (hbm_req_valid && hbm_req_write) begin
                $fatal(1,
                       "wave2: new writeback must not arrive before the new flush checkpoint");
            end

            if (u_control_chip.u_prediction_unit_bounded_stub.flush_done ||
                u_control_chip.token_flush_valid ||
                u_control_chip.flush_reclaim_valid) begin
                $fatal(1,
                       "wave2: new flush arrived before the required preflush consume step");
            end

            if (u_control_chip.u_compute_module_bounded_stub.prep_done) begin
                wave2_seen_prep_done = 1'b1;
            end

            if (u_control_chip.u_compute_module_bounded_stub.survivor_read_done) begin
                wave2_seen_preflush_read_done = 1'b1;
                disable expect_wave2_preflush_consume;
            end
        end

        if (!wave2_seen_prep_done) begin
            $fatal(1, "wave2: expected prep_done to assert before the new flush");
        end

        if (!wave2_seen_preflush_read_done) begin
            $fatal(1,
                   "wave2: expected one bounded PE-side completion before the new flush");
        end
    end
endtask

task expect_wave2_flush_reclosure;
    begin
        wave2_seen_flush_done = 1'b0;
        wave2_seen_token_flush = 1'b0;
        wave2_seen_reclaim_handoff = 1'b0;
        wave2_flush_pulse_count = 0;

        for (cycle_i = 0; cycle_i < WAVE2_FLUSH_TIMEOUT_CYCLES;
             cycle_i = cycle_i + 1) begin
            @(posedge clk);
            #1;

            if (error_flag) begin
                $fatal(1, "wave2: control_chip raised error_flag during flush wait");
            end

            if (!busy &&
                !(wave2_seen_flush_done &&
                  wave2_seen_token_flush &&
                  wave2_seen_reclaim_handoff)) begin
                $fatal(1,
                       "wave2: busy cleared before the new flush re-closure was observed");
            end

            if (hbm_req_valid && hbm_req_write) begin
                $fatal(1,
                       "wave2: new writeback must not arrive before the new flush re-closure completes");
            end

            if (u_control_chip.u_prediction_unit_bounded_stub.flush_done &&
                !wave2_seen_flush_done) begin
                wave2_seen_flush_done = 1'b1;
                wave2_flush_pulse_count = wave2_flush_pulse_count + 1;
            end

            if (u_control_chip.token_flush_valid) begin
                wave2_seen_token_flush = 1'b1;
            end

            if (u_control_chip.flush_reclaim_valid) begin
                wave2_seen_reclaim_handoff = 1'b1;
            end

            if (wave2_seen_flush_done &&
                wave2_seen_token_flush &&
                wave2_seen_reclaim_handoff) begin
                disable expect_wave2_flush_reclosure;
            end
        end

        if (!wave2_seen_flush_done) begin
            $fatal(1, "wave2: expected exactly one new flush marker after preflush consume");
        end

        if (wave2_flush_pulse_count != 1) begin
            $fatal(1, "wave2: expected exactly one new flush marker pulse");
        end

        if (!wave2_seen_token_flush) begin
            $fatal(1, "wave2: expected new metadata-path flush activity");
        end

        if (!wave2_seen_reclaim_handoff) begin
            $fatal(1, "wave2: expected new allocation/status reclaim handoff");
        end
    end
endtask

task expect_wave2_postflush_survivor_continuation;
    begin
        wave2_seen_postflush_read_done = 1'b0;

        for (cycle_i = 0; cycle_i < WAVE2_POSTFLUSH_TIMEOUT_CYCLES;
             cycle_i = cycle_i + 1) begin
            @(posedge clk);
            #1;

            if (error_flag) begin
                $fatal(1,
                       "wave2: control_chip raised error_flag before postflush survivor continuation");
            end

            if (!busy && !wave2_seen_postflush_read_done) begin
                $fatal(1,
                       "wave2: busy cleared before the postflush survivor continuation completed");
            end

            if (hbm_req_valid && hbm_req_write) begin
                $fatal(1,
                       "wave2: new writeback must not arrive before the postflush survivor continuation");
            end

            if (u_control_chip.u_compute_module_bounded_stub.survivor_read_done) begin
                wave2_seen_postflush_read_done = 1'b1;
                disable expect_wave2_postflush_survivor_continuation;
            end
        end

        if (!wave2_seen_postflush_read_done) begin
            $fatal(1,
                   "wave2: expected one later survivor-only continuation after the new flush");
        end
    end
endtask

task expect_wave2_postflush_writeback_closure;
    reg seen_writeback;
    begin
        seen_writeback = 1'b0;
        wave2_write_count = 0;
        wave2_seen_postflush_writeback = 1'b0;

        for (cycle_i = 0; cycle_i < WAVE2_WRITEBACK_TIMEOUT_CYCLES;
             cycle_i = cycle_i + 1) begin
            @(posedge clk);
            #1;

            if (error_flag) begin
                $fatal(1,
                       "wave2: control_chip raised error_flag before postflush writeback");
            end

            if (!busy && !seen_writeback) begin
                $fatal(1,
                       "wave2: busy cleared before the postflush writeback closure completed");
            end

            if (hbm_req_valid && hbm_req_write) begin
                if (hbm_req_addr == {`HBM_ADDR_W{1'b0}}) begin
                    $fatal(1, "wave2: expected non-zero bounded writeback address");
                end
                if (hbm_req_wdata == {`HBM_DATA_W{1'b0}}) begin
                    $fatal(1, "wave2: expected non-zero bounded writeback payload");
                end
                if (hbm_req_id == {`REQ_ID_W{1'b0}}) begin
                    $fatal(1, "wave2: expected non-zero bounded writeback req_id");
                end
                wave2_write_count = wave2_write_count + 1;
                wave2_seen_postflush_writeback = 1'b1;
                seen_writeback = 1'b1;
            end

            if (seen_writeback && !busy) begin
                disable expect_wave2_postflush_writeback_closure;
            end
        end

        if (!seen_writeback) begin
            $fatal(1,
                   "wave2: expected one bounded postflush top-level writeback request");
        end

        if (wave2_write_count != 1) begin
            $fatal(1,
                   "wave2: expected exactly one bounded postflush top-level writeback request");
        end

        if (busy) begin
            $fatal(1, "wave2: expected busy to clear after the new writeback closure");
        end
    end
endtask

initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    wave1_write_count = 0;
    wave2_write_count = 0;
    wave2_flush_pulse_count = 0;
    wave2_seen_prep_done = 1'b0;
    wave2_seen_preflush_read_done = 1'b0;
    wave2_seen_flush_done = 1'b0;
    wave2_seen_token_flush = 1'b0;
    wave2_seen_reclaim_handoff = 1'b0;
    wave2_seen_postflush_read_done = 1'b0;
    wave2_seen_postflush_writeback = 1'b0;
    clear_inputs();

    apply_reset_and_check_idle();

    launch_bounded_scenario(RUN_050_WAVE1_CFG_DATA);
    expect_busy_assert("wave1");
    expect_wave1_packet_and_busy_clear();

    if (wave1_write_count != 1) begin
        $fatal(1, "wave1: expected exactly one bounded top-level writeback");
    end

    expect_quiet_gap_after_wave1();

    launch_bounded_scenario(RUN_050_WAVE2_CFG_DATA);
    expect_busy_assert("wave2");
    expect_wave2_preflush_consume();
    expect_wave2_flush_reclosure();
    expect_wave2_postflush_survivor_continuation();
    expect_wave2_postflush_writeback_closure();

    if (!wave2_seen_prep_done) begin
        $fatal(1, "wave2: expected one bounded preparation step before the new flush");
    end

    if (!wave2_seen_preflush_read_done) begin
        $fatal(1, "wave2: expected one bounded preflush PE-side completion");
    end

    if (!wave2_seen_flush_done) begin
        $fatal(1, "wave2: expected one bounded new flush marker");
    end

    if (!wave2_seen_token_flush || !wave2_seen_reclaim_handoff) begin
        $fatal(1, "wave2: expected both ownership-path flush observables");
    end

    if (!wave2_seen_postflush_read_done) begin
        $fatal(1, "wave2: expected one bounded postflush survivor continuation");
    end

    if (!wave2_seen_postflush_writeback) begin
        $fatal(1, "wave2: expected one bounded postflush writeback closure");
    end

    if (error_flag) begin
        $fatal(1,
               "control_chip should complete post-reentry flush/writeback closure without error");
    end

    $display("tb_control_chip_post_reentry_flush_writeback_closure PASS");
    $finish;
end

endmodule
