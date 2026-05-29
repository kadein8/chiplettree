`timescale 1ns/1ps

`include "config/prediction_params.vh"
`include "config/interface_params.vh"
`include "config/memory_params.vh"

module tb_control_chip_third_flush_reclosure;

localparam integer CFG_W = 32;
localparam [CFG_W-1:0] RUN_046_WAVE1_CFG_DATA = 32'h0430_0001;
// Wave 2 keeps the already-proven run_044 writeback-closure contract.
localparam [CFG_W-1:0] RUN_046_WAVE2_CFG_DATA = 32'h0440_0002;
// Wave 3 uses its own bounded config so run_046 can demand one third flush
// without silently reusing the run_045 re-entry-only behavior.
localparam [CFG_W-1:0] RUN_046_WAVE3_CFG_DATA = 32'h0460_0003;
localparam integer BUSY_ASSERT_TIMEOUT_CYCLES = 24;
localparam integer WAVE1_WRITE_TIMEOUT_CYCLES = 160;
localparam integer BUSY_CLEAR_TIMEOUT_CYCLES = 48;
localparam integer QUIET_GAP_CYCLES = 4;
localparam integer WAVE2_PREFLUSH_TIMEOUT_CYCLES = 160;
localparam integer WAVE2_SECOND_FLUSH_TIMEOUT_CYCLES = 80;
localparam integer WAVE2_POSTFLUSH_TIMEOUT_CYCLES = 160;
localparam integer WAVE2_WRITEBACK_TIMEOUT_CYCLES = 160;
localparam integer WAVE3_PREFLUSH_TIMEOUT_CYCLES = 160;
localparam integer WAVE3_THIRD_FLUSH_TIMEOUT_CYCLES = 80;
localparam integer WAVE3_POSTFLUSH_TIMEOUT_CYCLES = 160;

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
integer wave3_flush_pulse_count;
reg wave2_seen_busy;
reg wave2_seen_prep_done;
reg wave2_seen_preflush_read_done;
reg wave2_seen_second_flush_marker;
reg wave2_seen_token_flush;
reg wave2_seen_reclaim_handoff;
reg wave2_seen_postflush_read_done;
reg wave2_seen_postflush_writeback;
reg wave3_seen_busy;
reg wave3_seen_prep_done;
reg wave3_seen_preflush_read_done;
reg wave3_seen_third_flush_marker;
reg wave3_seen_token_flush;
reg wave3_seen_reclaim_handoff;
reg wave3_seen_postflush_read_done;

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
            if (u_control_chip.u_compute_module_bounded_stub.survivor_read_done ||
                u_control_chip.token_flush_valid ||
                u_control_chip.flush_reclaim_valid) begin
                $fatal(1, "quiet gap after wave1 should not contain wave2 activity");
            end
        end
    end
endtask

task expect_quiet_gap_after_wave2;
    begin
        for (cycle_i = 0; cycle_i < QUIET_GAP_CYCLES; cycle_i = cycle_i + 1) begin
            @(posedge clk);
            #1;
            if (busy) begin
                $fatal(1, "expected quiet gap after wave2, but busy re-asserted");
            end
            if (error_flag) begin
                $fatal(1, "expected quiet gap after wave2, but error_flag asserted");
            end
            if (hbm_req_valid || hbm_req_write ||
                u_control_chip.token_flush_valid ||
                u_control_chip.flush_reclaim_valid) begin
                $fatal(1,
                       "quiet gap after wave2 should not contain wave3 activity or leftover wave2 traffic");
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
                       "wave2: second writeback must not arrive before the second flush checkpoint");
            end

            if (u_control_chip.u_prediction_unit_bounded_stub.flush_done ||
                u_control_chip.token_flush_valid ||
                u_control_chip.flush_reclaim_valid) begin
                $fatal(1,
                       "wave2: second flush arrived before the required preflush consume step");
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
            $fatal(1, "wave2: expected prep_done to re-assert before second flush");
        end

        if (!wave2_seen_preflush_read_done) begin
            $fatal(1,
                   "wave2: expected one bounded PE-side completion before the second flush");
        end
    end
endtask

task expect_wave2_second_flush_reclosure;
    begin
        wave2_seen_second_flush_marker = 1'b0;
        wave2_seen_token_flush = 1'b0;
        wave2_seen_reclaim_handoff = 1'b0;
        wave2_flush_pulse_count = 0;

        for (cycle_i = 0; cycle_i < WAVE2_SECOND_FLUSH_TIMEOUT_CYCLES;
             cycle_i = cycle_i + 1) begin
            @(posedge clk);
            #1;

            if (error_flag) begin
                $fatal(1, "wave2: control_chip raised error_flag during second flush wait");
            end

            if (hbm_req_valid && hbm_req_write) begin
                $fatal(1,
                       "wave2: second writeback must not arrive before second-flush closure completes");
            end

            if (u_control_chip.u_prediction_unit_bounded_stub.flush_done &&
                !wave2_seen_second_flush_marker) begin
                wave2_seen_second_flush_marker = 1'b1;
                wave2_flush_pulse_count = wave2_flush_pulse_count + 1;
            end

            if (u_control_chip.token_flush_valid) begin
                wave2_seen_token_flush = 1'b1;
            end

            if (u_control_chip.flush_reclaim_valid) begin
                wave2_seen_reclaim_handoff = 1'b1;
            end

            if (wave2_seen_second_flush_marker &&
                wave2_seen_token_flush &&
                wave2_seen_reclaim_handoff) begin
                disable expect_wave2_second_flush_reclosure;
            end
        end

        if (!wave2_seen_second_flush_marker) begin
            $fatal(1,
                   "wave2: expected exactly one second-wave flush marker after preflush consume");
        end

        if (wave2_flush_pulse_count != 1) begin
            $fatal(1, "wave2: expected exactly one second-wave flush marker pulse");
        end

        if (!wave2_seen_token_flush) begin
            $fatal(1, "wave2: expected second-wave metadata-path flush activity");
        end

        if (!wave2_seen_reclaim_handoff) begin
            $fatal(1,
                   "wave2: expected second-wave allocation/status reclaim handoff");
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

            if (hbm_req_valid && hbm_req_write) begin
                $fatal(1,
                       "wave2: writeback must not arrive before the postflush survivor continuation");
            end

            if (u_control_chip.u_compute_module_bounded_stub.survivor_read_done) begin
                wave2_seen_postflush_read_done = 1'b1;
                disable expect_wave2_postflush_survivor_continuation;
            end
        end

        if (!wave2_seen_postflush_read_done) begin
            $fatal(1,
                   "wave2: expected one later survivor-only continuation after the second flush");
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
                       "wave2: control_chip raised error_flag before post-second-flush writeback");
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
                   "wave2: expected one bounded post-second-flush top-level writeback request");
        end

        if (wave2_write_count != 1) begin
            $fatal(1,
                   "wave2: expected exactly one post-second-flush top-level writeback request");
        end

        if (busy) begin
            $fatal(1, "wave2: expected busy to clear after the second writeback closure");
        end
    end
endtask

task expect_wave3_preflush_consume;
    begin
        wave3_seen_prep_done = 1'b0;
        wave3_seen_preflush_read_done = 1'b0;

        for (cycle_i = 0; cycle_i < WAVE3_PREFLUSH_TIMEOUT_CYCLES;
             cycle_i = cycle_i + 1) begin
            @(posedge clk);
            #1;

            if (error_flag) begin
                $fatal(1, "wave3: control_chip raised error_flag before preflush consume");
            end

            if (hbm_req_valid && hbm_req_write) begin
                $fatal(1,
                       "wave3: third writeback must not arrive before the third flush checkpoint");
            end

            if (u_control_chip.u_prediction_unit_bounded_stub.flush_done ||
                u_control_chip.token_flush_valid ||
                u_control_chip.flush_reclaim_valid) begin
                $fatal(1,
                       "wave3: third flush arrived before the required preflush consume step");
            end

            if (u_control_chip.u_compute_module_bounded_stub.prep_done) begin
                wave3_seen_prep_done = 1'b1;
            end

            if (u_control_chip.u_compute_module_bounded_stub.survivor_read_done) begin
                wave3_seen_preflush_read_done = 1'b1;
                disable expect_wave3_preflush_consume;
            end
        end

        if (!wave3_seen_prep_done) begin
            $fatal(1, "wave3: expected prep_done to re-assert before the third flush");
        end

        if (!wave3_seen_preflush_read_done) begin
            $fatal(1,
                   "wave3: expected one bounded PE-side completion before the third flush");
        end
    end
endtask

task expect_wave3_third_flush_reclosure;
    begin
        wave3_seen_third_flush_marker = 1'b0;
        wave3_seen_token_flush = 1'b0;
        wave3_seen_reclaim_handoff = 1'b0;
        wave3_flush_pulse_count = 0;

        for (cycle_i = 0; cycle_i < WAVE3_THIRD_FLUSH_TIMEOUT_CYCLES;
             cycle_i = cycle_i + 1) begin
            @(posedge clk);
            #1;

            if (error_flag) begin
                $fatal(1, "wave3: control_chip raised error_flag during third flush wait");
            end

            if (!busy &&
                !(wave3_seen_third_flush_marker &&
                  wave3_seen_token_flush &&
                  wave3_seen_reclaim_handoff)) begin
                $fatal(1,
                       "wave3: busy cleared before the third-flush re-closure was observed");
            end

            if (hbm_req_valid && hbm_req_write) begin
                $fatal(1,
                       "wave3: third writeback must not arrive before third-flush re-closure completes");
            end

            if (u_control_chip.u_prediction_unit_bounded_stub.flush_done &&
                !wave3_seen_third_flush_marker) begin
                wave3_seen_third_flush_marker = 1'b1;
                wave3_flush_pulse_count = wave3_flush_pulse_count + 1;
            end

            if (u_control_chip.token_flush_valid) begin
                wave3_seen_token_flush = 1'b1;
            end

            if (u_control_chip.flush_reclaim_valid) begin
                wave3_seen_reclaim_handoff = 1'b1;
            end

            if (wave3_seen_third_flush_marker &&
                wave3_seen_token_flush &&
                wave3_seen_reclaim_handoff) begin
                disable expect_wave3_third_flush_reclosure;
            end
        end

        if (!wave3_seen_third_flush_marker) begin
            $fatal(1,
                   "wave3: expected exactly one third-wave flush marker after preflush consume");
        end

        if (wave3_flush_pulse_count != 1) begin
            $fatal(1, "wave3: expected exactly one third-wave flush marker pulse");
        end

        if (!wave3_seen_token_flush) begin
            $fatal(1, "wave3: expected third-wave metadata-path flush activity");
        end

        if (!wave3_seen_reclaim_handoff) begin
            $fatal(1,
                   "wave3: expected third-wave allocation/status reclaim handoff");
        end
    end
endtask

task expect_wave3_postflush_survivor_continuation;
    reg seen_completion;
    begin
        seen_completion = 1'b0;
        wave3_seen_postflush_read_done = 1'b0;

        for (cycle_i = 0; cycle_i < WAVE3_POSTFLUSH_TIMEOUT_CYCLES;
             cycle_i = cycle_i + 1) begin
            @(posedge clk);
            #1;

            if (error_flag) begin
                $fatal(1,
                       "wave3: control_chip raised error_flag before postflush survivor continuation");
            end

            if (hbm_req_valid && hbm_req_write) begin
                $fatal(1,
                       "wave3: third writeback must not arrive before the post-third-flush survivor continuation");
            end

            if (!busy && !seen_completion) begin
                $fatal(1,
                       "wave3: busy cleared before the post-third-flush survivor continuation completed");
            end

            if (u_control_chip.u_compute_module_bounded_stub.survivor_read_done) begin
                wave3_seen_postflush_read_done = 1'b1;
                seen_completion = 1'b1;
            end

            if (seen_completion && !busy) begin
                disable expect_wave3_postflush_survivor_continuation;
            end
        end

        if (!wave3_seen_postflush_read_done) begin
            $fatal(1,
                   "wave3: expected one later survivor-only continuation after the third flush");
        end

        if (busy) begin
            $fatal(1,
                   "wave3: expected busy to clear after the post-third-flush survivor continuation");
        end
    end
endtask

initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    wave1_write_count = 0;
    wave2_write_count = 0;
    wave2_flush_pulse_count = 0;
    wave3_flush_pulse_count = 0;
    wave2_seen_busy = 1'b0;
    wave2_seen_prep_done = 1'b0;
    wave2_seen_preflush_read_done = 1'b0;
    wave2_seen_second_flush_marker = 1'b0;
    wave2_seen_token_flush = 1'b0;
    wave2_seen_reclaim_handoff = 1'b0;
    wave2_seen_postflush_read_done = 1'b0;
    wave2_seen_postflush_writeback = 1'b0;
    wave3_seen_busy = 1'b0;
    wave3_seen_prep_done = 1'b0;
    wave3_seen_preflush_read_done = 1'b0;
    wave3_seen_third_flush_marker = 1'b0;
    wave3_seen_token_flush = 1'b0;
    wave3_seen_reclaim_handoff = 1'b0;
    wave3_seen_postflush_read_done = 1'b0;
    clear_inputs();

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

    launch_bounded_scenario(RUN_046_WAVE1_CFG_DATA);
    expect_busy_assert("wave1");
    expect_wave1_writeback();
    expect_busy_clear("wave1");

    if (wave1_write_count != 1) begin
        $fatal(1, "wave1: expected exactly one bounded top-level writeback");
    end

    expect_quiet_gap_after_wave1();

    launch_bounded_scenario(RUN_046_WAVE2_CFG_DATA);
    expect_busy_assert("wave2");
    wave2_seen_busy = 1'b1;
    expect_wave2_preflush_consume();
    expect_wave2_second_flush_reclosure();
    expect_wave2_postflush_survivor_continuation();
    expect_wave2_postflush_writeback_closure();

    if (!wave2_seen_busy) begin
        $fatal(1, "wave2: expected busy re-entry after second launch");
    end

    if (!wave2_seen_postflush_writeback) begin
        $fatal(1, "wave2: expected one bounded post-second-flush writeback closure");
    end

    if (error_flag) begin
        $fatal(1,
               "control_chip should complete second-flush writeback closure without error");
    end

    expect_quiet_gap_after_wave2();

    launch_bounded_scenario(RUN_046_WAVE3_CFG_DATA);
    expect_busy_assert("wave3");
    wave3_seen_busy = 1'b1;
    expect_wave3_preflush_consume();
    expect_wave3_third_flush_reclosure();
    expect_wave3_postflush_survivor_continuation();

    if (!wave3_seen_busy) begin
        $fatal(1, "wave3: expected busy re-entry after third launch");
    end

    if (!wave3_seen_prep_done) begin
        $fatal(1, "wave3: expected one bounded third-wave preparation step");
    end

    if (!wave3_seen_preflush_read_done) begin
        $fatal(1, "wave3: expected one bounded third-wave preflush PE-side completion");
    end

    if (!wave3_seen_third_flush_marker) begin
        $fatal(1, "wave3: expected one bounded third-wave flush marker");
    end

    if (!wave3_seen_token_flush || !wave3_seen_reclaim_handoff) begin
        $fatal(1, "wave3: expected both ownership-path flush observables");
    end

    if (!wave3_seen_postflush_read_done) begin
        $fatal(1, "wave3: expected one bounded post-third-flush survivor continuation");
    end

    if (error_flag) begin
        $fatal(1,
               "control_chip should complete third-flush re-closure without error");
    end

    $display("tb_control_chip_third_flush_reclosure PASS");
    $finish;
end

endmodule
