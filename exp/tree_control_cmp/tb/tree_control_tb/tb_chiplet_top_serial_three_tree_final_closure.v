`timescale 1ns/1ps

`include "config/prediction_params.vh"
`include "config/interface_params.vh"
`include "config/memory_params.vh"

module tb_control_chip_serial_three_tree_final_closure;

localparam integer CFG_W = 32;
localparam [CFG_W-1:0] TREE_A_CFG_DATA = 32'h04c0_0033;
localparam [CFG_W-1:0] TREE_B_CFG_DATA = 32'h04c0_0022;
localparam [CFG_W-1:0] TREE_C_CFG_DATA = 32'h04c0_0021;
localparam integer TREE_A_FLUSH_COUNT = 3;
localparam integer TREE_B_FLUSH_COUNT = 2;
localparam integer TREE_C_FLUSH_COUNT = 2;
localparam integer BUSY_ASSERT_TIMEOUT_CYCLES = 24;
localparam integer PHASE_WITNESS_TIMEOUT_CYCLES = 240;
localparam integer FLUSH_TIMEOUT_CYCLES = 120;
localparam integer WRITEBACK_TIMEOUT_CYCLES = 240;
localparam integer QUIET_GAP_CYCLES = 4;

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
integer flush_pulse_total;
integer writeback_pulse_total;
integer survivor_done_pulse_total;
integer concurrency_window_total;
integer tree_a_flush_start;
integer tree_a_writeback_start;
integer tree_b_flush_start;
integer tree_b_writeback_start;
integer tree_c_flush_start;
integer tree_c_writeback_start;
integer phase_survivor_base;
integer phase_concurrency_base;
reg flush_done_q;
reg hbm_write_q;
reg concurrency_window_q;

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

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        flush_done_q <= 1'b0;
        hbm_write_q <= 1'b0;
        concurrency_window_q <= 1'b0;
        flush_pulse_total <= 0;
        writeback_pulse_total <= 0;
        survivor_done_pulse_total <= 0;
        concurrency_window_total <= 0;
    end else begin
        flush_done_q <= u_control_chip.u_prediction_unit_bounded_stub.flush_done;
        hbm_write_q <= hbm_req_valid && hbm_req_write;
        concurrency_window_q <=
            (lane_issue_count(
                u_control_chip.rc_mem_req_valid &
                u_control_chip.rc_mem_req_ready) >= 2);

        if (u_control_chip.u_prediction_unit_bounded_stub.flush_done &&
            !flush_done_q) begin
            flush_pulse_total <= flush_pulse_total + 1;
        end

        if ((hbm_req_valid && hbm_req_write) && !hbm_write_q) begin
            writeback_pulse_total <= writeback_pulse_total + 1;
        end

        if (u_control_chip.u_compute_module_bounded_stub.survivor_read_done) begin
            survivor_done_pulse_total <= survivor_done_pulse_total + 1;
        end

        if ((lane_issue_count(
                 u_control_chip.rc_mem_req_valid &
                 u_control_chip.rc_mem_req_ready) >= 2) &&
            !concurrency_window_q) begin
            concurrency_window_total <= concurrency_window_total + 1;
        end
    end
end

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

function integer lane_issue_count;
    input [`MEM_REQ_LANES-1:0] issue_mask_i;
    integer lane_i;
    begin
        lane_issue_count = 0;
        for (lane_i = 0; lane_i < `MEM_REQ_LANES; lane_i = lane_i + 1) begin
            if (issue_mask_i[lane_i]) begin
                lane_issue_count = lane_issue_count + 1;
            end
        end
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
            flush_pulse_total != 0 ||
            writeback_pulse_total != 0 ||
            survivor_done_pulse_total != 0 ||
            concurrency_window_total != 0 ||
            u_control_chip.u_prediction_unit_bounded_stub.flush_done ||
            u_control_chip.u_compute_module_bounded_stub.prep_done ||
            u_control_chip.u_compute_module_bounded_stub.survivor_read_done ||
            u_control_chip.token_flush_valid ||
            u_control_chip.flush_reclaim_valid ||
            |u_control_chip.rc_mem_req_valid ||
            |u_control_chip.rc_mem_req_write) begin
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
    input [8*64-1:0] phase_name;
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

task expect_phase_witness_before_next_flush;
    input [8*96-1:0] phase_name;
    input integer base_flush_count;
    input integer base_writeback_count;
    input integer base_survivor_done_count;
    input integer base_concurrency_count;
    input integer require_prep_done;
    reg seen_prep_done;
    reg seen_survivor_done;
    reg seen_concurrency;
    reg seen_all;
    begin
        seen_prep_done = (require_prep_done == 0);
        seen_survivor_done = 1'b0;
        seen_concurrency = 1'b0;
        seen_all = 1'b0;

        for (cycle_i = 0; cycle_i < PHASE_WITNESS_TIMEOUT_CYCLES;
             cycle_i = cycle_i + 1) begin
            @(posedge clk);
            #1;

            if (error_flag) begin
                $fatal(1, "%0s: control_chip raised error_flag", phase_name);
            end

            if (!busy) begin
                $fatal(1, "%0s: busy cleared before the next bounded flush",
                       phase_name);
            end

            if (writeback_pulse_total != base_writeback_count) begin
                $fatal(1, "%0s: top-level writeback arrived before the required flush",
                       phase_name);
            end

            if (flush_pulse_total != base_flush_count) begin
                $fatal(1,
                       "%0s: flush arrived before the required witnesses (prep_done=%0d survivor_done_total=%0d base_survivor=%0d concurrency_total=%0d base_concurrency=%0d)",
                       phase_name,
                       seen_prep_done,
                       survivor_done_pulse_total,
                       base_survivor_done_count,
                       concurrency_window_total,
                       base_concurrency_count);
            end

            if (require_prep_done &&
                u_control_chip.u_compute_module_bounded_stub.prep_done) begin
                seen_prep_done = 1'b1;
            end

            if (survivor_done_pulse_total > base_survivor_done_count) begin
                seen_survivor_done = 1'b1;
            end

            if (concurrency_window_total > base_concurrency_count) begin
                seen_concurrency = 1'b1;
            end

            if (seen_prep_done && seen_survivor_done && seen_concurrency) begin
                seen_all = 1'b1;
                disable expect_phase_witness_before_next_flush;
            end
        end

        if (!seen_all) begin
            $fatal(1,
                   "%0s: expected prep/continuation/concurrency witnesses before flush",
                   phase_name);
        end
    end
endtask

task expect_next_flush_checkpoint;
    input [8*96-1:0] phase_name;
    input integer expected_flush_count;
    input integer base_writeback_count;
    output integer flush_edge_survivor_count;
    output integer flush_edge_concurrency_count;
    reg seen_token_flush;
    reg seen_reclaim;
    reg seen_all;
    reg seen_flush_edge;
    begin
        seen_token_flush = 1'b0;
        seen_reclaim = 1'b0;
        seen_all = 1'b0;
        seen_flush_edge = 1'b0;
        flush_edge_survivor_count = survivor_done_pulse_total;
        flush_edge_concurrency_count = concurrency_window_total;

        for (cycle_i = 0; cycle_i < FLUSH_TIMEOUT_CYCLES;
             cycle_i = cycle_i + 1) begin
            @(posedge clk);
            #1;

            if (error_flag) begin
                $fatal(1, "%0s: control_chip raised error_flag during flush wait",
                       phase_name);
            end

            if (writeback_pulse_total != base_writeback_count) begin
                $fatal(1, "%0s: writeback arrived before the bounded flush closed",
                       phase_name);
            end

            if (flush_pulse_total > expected_flush_count) begin
                $fatal(1,
                       "%0s: observed more flushes than the bounded target (expected_flush_count=%0d flush_total=%0d seen_token_flush=%0d seen_reclaim=%0d)",
                       phase_name,
                       expected_flush_count,
                       flush_pulse_total,
                       seen_token_flush,
                       seen_reclaim);
            end

            if (!seen_flush_edge &&
                (flush_pulse_total == expected_flush_count)) begin
                seen_flush_edge = 1'b1;
                flush_edge_survivor_count = survivor_done_pulse_total;
                flush_edge_concurrency_count = concurrency_window_total;
            end

            if (!busy &&
                !((flush_pulse_total == expected_flush_count) &&
                  seen_token_flush &&
                  seen_reclaim)) begin
                $fatal(1, "%0s: busy cleared before the bounded flush closed",
                       phase_name);
            end

            if (u_control_chip.token_flush_valid) begin
                seen_token_flush = 1'b1;
            end

            if (u_control_chip.flush_reclaim_valid) begin
                seen_reclaim = 1'b1;
            end

            if ((flush_pulse_total == expected_flush_count) &&
                seen_token_flush &&
                seen_reclaim) begin
                seen_all = 1'b1;
                disable expect_next_flush_checkpoint;
            end
        end

        if (!seen_all) begin
            $fatal(1,
                   "%0s: expected one new flush edge plus both ownership-path observables (expected_flush_count=%0d flush_total=%0d seen_flush_edge=%0d seen_token_flush=%0d seen_reclaim=%0d)",
                   phase_name,
                   expected_flush_count,
                   flush_pulse_total,
                   seen_flush_edge,
                   seen_token_flush,
                   seen_reclaim);
        end
    end
endtask

task expect_postflush_witness_before_final_writeback;
    input [8*96-1:0] phase_name;
    input integer exact_flush_count;
    input integer base_writeback_count;
    input integer base_survivor_done_count;
    input integer base_concurrency_count;
    reg seen_survivor_done;
    reg seen_concurrency;
    reg seen_all;
    begin
        seen_survivor_done = 1'b0;
        seen_concurrency = 1'b0;
        seen_all = 1'b0;

        for (cycle_i = 0; cycle_i < PHASE_WITNESS_TIMEOUT_CYCLES;
             cycle_i = cycle_i + 1) begin
            @(posedge clk);
            #1;

            if (error_flag) begin
                $fatal(1, "%0s: control_chip raised error_flag postflush",
                       phase_name);
            end

            if (!busy) begin
                $fatal(1, "%0s: busy cleared before the final survivor writeback",
                       phase_name);
            end

            if (flush_pulse_total > exact_flush_count) begin
                $fatal(1, "%0s: observed an unexpected extra flush before writeback",
                       phase_name);
            end

            if (writeback_pulse_total != base_writeback_count) begin
                $fatal(1,
                       "%0s: final writeback arrived before postflush survivor/concurrency witnesses",
                       phase_name);
            end

            if (survivor_done_pulse_total > base_survivor_done_count) begin
                seen_survivor_done = 1'b1;
            end

            if (concurrency_window_total > base_concurrency_count) begin
                seen_concurrency = 1'b1;
            end

            if (seen_survivor_done && seen_concurrency) begin
                seen_all = 1'b1;
                disable expect_postflush_witness_before_final_writeback;
            end
        end

        if (!seen_all) begin
            $fatal(1,
                   "%0s: expected one postflush survivor continuation and one concurrency window before writeback",
                   phase_name);
        end
    end
endtask

task expect_final_writeback_and_busy_clear;
    input [8*96-1:0] phase_name;
    input integer exact_flush_count;
    input integer start_writeback_count;
    input [`HBM_DATA_W-1:0] expected_wdata;
    reg seen_writeback;
    begin
        seen_writeback = 1'b0;

        for (cycle_i = 0; cycle_i < WRITEBACK_TIMEOUT_CYCLES;
             cycle_i = cycle_i + 1) begin
            @(posedge clk);
            #1;

            if (error_flag) begin
                $fatal(1, "%0s: control_chip raised error_flag before writeback",
                       phase_name);
            end

            if (flush_pulse_total > exact_flush_count) begin
                $fatal(1, "%0s: observed an unexpected extra flush after final checkpoint",
                       phase_name);
            end

            if (!busy && (writeback_pulse_total == start_writeback_count)) begin
                $fatal(1, "%0s: busy cleared before the final writeback appeared",
                       phase_name);
            end

            if (writeback_pulse_total > (start_writeback_count + 1)) begin
                $fatal(1, "%0s: observed more than one final top-level writeback",
                       phase_name);
            end

            if (hbm_req_valid && hbm_req_write) begin
                if (hbm_req_addr == {`HBM_ADDR_W{1'b0}}) begin
                    $fatal(1, "%0s: expected non-zero bounded writeback address",
                           phase_name);
                end
                if (hbm_req_id == {`REQ_ID_W{1'b0}}) begin
                    $fatal(1, "%0s: expected non-zero bounded writeback req_id",
                           phase_name);
                end
                if (hbm_req_wdata !== expected_wdata) begin
                    $fatal(1, "%0s: expected exact final writeback packet %h, got %h",
                           phase_name, expected_wdata, hbm_req_wdata);
                end
            end

            if (writeback_pulse_total == (start_writeback_count + 1)) begin
                seen_writeback = 1'b1;
            end

            if (seen_writeback && !busy) begin
                disable expect_final_writeback_and_busy_clear;
            end
        end

        if (writeback_pulse_total != (start_writeback_count + 1)) begin
            $fatal(1, "%0s: expected exactly one final writeback pulse",
                   phase_name);
        end

        if (busy) begin
            $fatal(1, "%0s: expected busy to clear after final writeback",
                   phase_name);
        end
    end
endtask

task expect_quiet_idle_gap;
    input [8*96-1:0] phase_name;
    input integer exact_flush_count;
    input integer exact_writeback_count;
    begin
        for (cycle_i = 0; cycle_i < QUIET_GAP_CYCLES; cycle_i = cycle_i + 1) begin
            @(posedge clk);
            #1;

            if (busy || error_flag || hbm_req_valid || hbm_req_write) begin
                $fatal(1, "%0s: expected clean top-level idle boundary",
                       phase_name);
            end

            if ((flush_pulse_total != exact_flush_count) ||
                (writeback_pulse_total != exact_writeback_count)) begin
                $fatal(1, "%0s: observed new flush or writeback activity in idle gap",
                       phase_name);
            end

            if (u_control_chip.u_compute_module_bounded_stub.survivor_read_done ||
                u_control_chip.token_flush_valid ||
                u_control_chip.flush_reclaim_valid ||
                |u_control_chip.rc_mem_req_valid ||
                |u_control_chip.rc_mem_req_write) begin
                $fatal(1, "%0s: expected no residual bounded activity in idle gap",
                       phase_name);
            end
        end
    end
endtask

initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    flush_pulse_total = 0;
    writeback_pulse_total = 0;
    survivor_done_pulse_total = 0;
    concurrency_window_total = 0;
    tree_a_flush_start = 0;
    tree_a_writeback_start = 0;
    tree_b_flush_start = 0;
    tree_b_writeback_start = 0;
    tree_c_flush_start = 0;
    tree_c_writeback_start = 0;
    phase_survivor_base = 0;
    phase_concurrency_base = 0;
    flush_done_q = 1'b0;
    hbm_write_q = 1'b0;
    concurrency_window_q = 1'b0;
    clear_inputs();

    apply_reset_and_check_idle();

    tree_a_flush_start = flush_pulse_total;
    tree_a_writeback_start = writeback_pulse_total;
    launch_bounded_scenario(TREE_A_CFG_DATA);
    expect_busy_assert("tree_a");
    phase_survivor_base = survivor_done_pulse_total;
    phase_concurrency_base = concurrency_window_total;
    expect_phase_witness_before_next_flush(
        "tree_a_before_flush1",
        tree_a_flush_start,
        tree_a_writeback_start,
        phase_survivor_base,
        phase_concurrency_base,
        1
    );
    expect_next_flush_checkpoint(
        "tree_a_flush1",
        tree_a_flush_start + 1,
        tree_a_writeback_start,
        phase_survivor_base,
        phase_concurrency_base
    );
    expect_phase_witness_before_next_flush(
        "tree_a_between_flush1_flush2",
        tree_a_flush_start + 1,
        tree_a_writeback_start,
        phase_survivor_base,
        phase_concurrency_base,
        0
    );
    expect_next_flush_checkpoint(
        "tree_a_flush2",
        tree_a_flush_start + 2,
        tree_a_writeback_start,
        phase_survivor_base,
        phase_concurrency_base
    );
    expect_phase_witness_before_next_flush(
        "tree_a_between_flush2_flush3",
        tree_a_flush_start + 2,
        tree_a_writeback_start,
        phase_survivor_base,
        phase_concurrency_base,
        0
    );
    expect_next_flush_checkpoint(
        "tree_a_flush3",
        tree_a_flush_start + TREE_A_FLUSH_COUNT,
        tree_a_writeback_start,
        phase_survivor_base,
        phase_concurrency_base
    );
    expect_postflush_witness_before_final_writeback(
        "tree_a_postflush_survivor_window",
        tree_a_flush_start + TREE_A_FLUSH_COUNT,
        tree_a_writeback_start,
        phase_survivor_base,
        phase_concurrency_base
    );
    expect_final_writeback_and_busy_clear(
        "tree_a_final_writeback",
        tree_a_flush_start + TREE_A_FLUSH_COUNT,
        tree_a_writeback_start,
        pack_expected_packet(16'h0003, 16'h0301, 16'h0302, 16'h0303)
    );

    if (flush_pulse_total != (tree_a_flush_start + TREE_A_FLUSH_COUNT)) begin
        $fatal(1, "tree_a: expected exactly three bounded flushes");
    end

    if (writeback_pulse_total != (tree_a_writeback_start + 1)) begin
        $fatal(1, "tree_a: expected exactly one final survivor writeback");
    end

    expect_quiet_idle_gap(
        "gap_after_tree_a",
        tree_a_flush_start + TREE_A_FLUSH_COUNT,
        tree_a_writeback_start + 1
    );

    tree_b_flush_start = flush_pulse_total;
    tree_b_writeback_start = writeback_pulse_total;
    launch_bounded_scenario(TREE_B_CFG_DATA);
    expect_busy_assert("tree_b");
    phase_survivor_base = survivor_done_pulse_total;
    phase_concurrency_base = concurrency_window_total;
    expect_phase_witness_before_next_flush(
        "tree_b_before_flush1",
        tree_b_flush_start,
        tree_b_writeback_start,
        phase_survivor_base,
        phase_concurrency_base,
        1
    );
    expect_next_flush_checkpoint(
        "tree_b_flush1",
        tree_b_flush_start + 1,
        tree_b_writeback_start,
        phase_survivor_base,
        phase_concurrency_base
    );
    expect_phase_witness_before_next_flush(
        "tree_b_between_flush1_flush2",
        tree_b_flush_start + 1,
        tree_b_writeback_start,
        phase_survivor_base,
        phase_concurrency_base,
        0
    );
    expect_next_flush_checkpoint(
        "tree_b_flush2",
        tree_b_flush_start + TREE_B_FLUSH_COUNT,
        tree_b_writeback_start,
        phase_survivor_base,
        phase_concurrency_base
    );
    expect_postflush_witness_before_final_writeback(
        "tree_b_postflush_survivor_window",
        tree_b_flush_start + TREE_B_FLUSH_COUNT,
        tree_b_writeback_start,
        phase_survivor_base,
        phase_concurrency_base
    );
    expect_final_writeback_and_busy_clear(
        "tree_b_final_writeback",
        tree_b_flush_start + TREE_B_FLUSH_COUNT,
        tree_b_writeback_start,
        pack_expected_packet(16'h0002, 16'h0201, 16'h0202, 16'h0000)
    );

    if (flush_pulse_total != (tree_b_flush_start + TREE_B_FLUSH_COUNT)) begin
        $fatal(1, "tree_b: expected exactly two bounded flushes");
    end

    if (writeback_pulse_total != (tree_b_writeback_start + 1)) begin
        $fatal(1, "tree_b: expected exactly one final survivor writeback");
    end

    expect_quiet_idle_gap(
        "gap_after_tree_b",
        tree_b_flush_start + TREE_B_FLUSH_COUNT,
        tree_b_writeback_start + 1
    );

    tree_c_flush_start = flush_pulse_total;
    tree_c_writeback_start = writeback_pulse_total;
    launch_bounded_scenario(TREE_C_CFG_DATA);
    expect_busy_assert("tree_c");
    phase_survivor_base = survivor_done_pulse_total;
    phase_concurrency_base = concurrency_window_total;
    expect_phase_witness_before_next_flush(
        "tree_c_before_flush1",
        tree_c_flush_start,
        tree_c_writeback_start,
        phase_survivor_base,
        phase_concurrency_base,
        1
    );
    expect_next_flush_checkpoint(
        "tree_c_flush1",
        tree_c_flush_start + 1,
        tree_c_writeback_start,
        phase_survivor_base,
        phase_concurrency_base
    );
    expect_phase_witness_before_next_flush(
        "tree_c_between_flush1_flush2",
        tree_c_flush_start + 1,
        tree_c_writeback_start,
        phase_survivor_base,
        phase_concurrency_base,
        0
    );
    expect_next_flush_checkpoint(
        "tree_c_flush2",
        tree_c_flush_start + TREE_C_FLUSH_COUNT,
        tree_c_writeback_start,
        phase_survivor_base,
        phase_concurrency_base
    );
    expect_postflush_witness_before_final_writeback(
        "tree_c_postflush_survivor_window",
        tree_c_flush_start + TREE_C_FLUSH_COUNT,
        tree_c_writeback_start,
        phase_survivor_base,
        phase_concurrency_base
    );
    expect_final_writeback_and_busy_clear(
        "tree_c_final_writeback",
        tree_c_flush_start + TREE_C_FLUSH_COUNT,
        tree_c_writeback_start,
        pack_expected_packet(16'h0001, 16'h0101, 16'h0000, 16'h0000)
    );

    if (flush_pulse_total != (tree_c_flush_start + TREE_C_FLUSH_COUNT)) begin
        $fatal(1, "tree_c: expected exactly two bounded flushes");
    end

    if (writeback_pulse_total != (tree_c_writeback_start + 1)) begin
        $fatal(1, "tree_c: expected exactly one final survivor writeback");
    end

    expect_quiet_idle_gap(
        "gap_after_tree_c",
        tree_c_flush_start + TREE_C_FLUSH_COUNT,
        tree_c_writeback_start + 1
    );

    if (error_flag) begin
        $fatal(1,
               "control_chip should close the bounded serial three-tree run without error");
    end

    $display("tb_control_chip_serial_three_tree_final_closure PASS");
    $finish;
end

endmodule
