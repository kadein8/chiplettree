`timescale 1ns/1ps

`include "config/prediction_params.vh"
`include "config/interface_params.vh"
`include "config/memory_params.vh"

module tb_control_chip_serial_free_running_surrogate;

localparam integer CFG_W = 32;
localparam integer TREE_COUNT = 5;
localparam [CFG_W-1:0] TREE0_CFG_DATA = 32'h04c0_0033;
localparam [CFG_W-1:0] TREE1_CFG_DATA = 32'h04c0_0012;
localparam [CFG_W-1:0] TREE2_CFG_DATA = 32'h04c0_0021;
localparam [CFG_W-1:0] TREE3_CFG_DATA = 32'h04c0_0011;
localparam [CFG_W-1:0] TREE4_CFG_DATA = 32'h04c0_0032;
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
integer tree_i;
integer flush_pulse_total;
integer writeback_pulse_total;
integer survivor_done_pulse_total;
integer concurrency_window_total;
integer total_expected_flush;
integer total_expected_writeback;
reg flush_done_q;
reg hbm_write_q;
reg concurrency_window_q;
reg len_cov_1_r;
reg len_cov_2_r;
reg len_cov_3_r;
reg short_flush_cov_r;
reg long_flush_cov_r;

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

function [CFG_W-1:0] tree_cfg_word;
    input integer tree_idx;
    begin
        case (tree_idx)
            0: tree_cfg_word = TREE0_CFG_DATA;
            1: tree_cfg_word = TREE1_CFG_DATA;
            2: tree_cfg_word = TREE2_CFG_DATA;
            3: tree_cfg_word = TREE3_CFG_DATA;
            4: tree_cfg_word = TREE4_CFG_DATA;
            default: tree_cfg_word = {CFG_W{1'b0}};
        endcase
    end
endfunction

function integer tree_expected_flush;
    input integer tree_idx;
    begin
        case (tree_idx)
            0: tree_expected_flush = 3;
            1: tree_expected_flush = 1;
            2: tree_expected_flush = 2;
            3: tree_expected_flush = 1;
            4: tree_expected_flush = 3;
            default: tree_expected_flush = 0;
        endcase
    end
endfunction

function integer tree_expected_len;
    input integer tree_idx;
    begin
        case (tree_idx)
            0: tree_expected_len = 3;
            1: tree_expected_len = 2;
            2: tree_expected_len = 1;
            3: tree_expected_len = 1;
            4: tree_expected_len = 2;
            default: tree_expected_len = 0;
        endcase
    end
endfunction

function [`HBM_DATA_W-1:0] tree_expected_packet;
    input integer tree_idx;
    begin
        case (tree_expected_len(tree_idx))
            1: tree_expected_packet =
                pack_expected_packet(16'h0001, 16'h0101, 16'h0000, 16'h0000);
            2: tree_expected_packet =
                pack_expected_packet(16'h0002, 16'h0201, 16'h0202, 16'h0000);
            3: tree_expected_packet =
                pack_expected_packet(16'h0003, 16'h0301, 16'h0302, 16'h0303);
            default: tree_expected_packet = {`HBM_DATA_W{1'b0}};
        endcase
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

task automatic expect_busy_assert;
    input string phase_name;
    reg seen_busy;
    begin
        seen_busy = 1'b0;
        for (cycle_i = 0; cycle_i < BUSY_ASSERT_TIMEOUT_CYCLES;
             cycle_i = cycle_i + 1) begin
            @(posedge clk);
            #1;
            if (error_flag) begin
                $fatal(1, "%s: control_chip raised error_flag before busy asserted",
                       phase_name);
            end
            if (busy) begin
                seen_busy = 1'b1;
                break;
            end
        end

        if (!seen_busy) begin
            $fatal(1, "%s: expected control_chip to assert busy after cfg/start",
                   phase_name);
        end
    end
endtask

task automatic expect_phase_witness_before_next_flush;
    input string phase_name;
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
                $fatal(1, "%s: control_chip raised error_flag", phase_name);
            end

            if (!busy) begin
                $fatal(1, "%s: busy cleared before the next bounded flush",
                       phase_name);
            end

            if (writeback_pulse_total != base_writeback_count) begin
                $fatal(1, "%s: top-level writeback arrived before the required flush",
                       phase_name);
            end

            if (flush_pulse_total != base_flush_count) begin
                $fatal(1,
                       "%s: flush arrived before the required witnesses (prep_done=%0d survivor_done_total=%0d base_survivor=%0d concurrency_total=%0d base_concurrency=%0d)",
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
                break;
            end
        end

        if (!seen_all) begin
            $fatal(1,
                   "%s: expected prep/continuation/concurrency witnesses before flush",
                   phase_name);
        end
    end
endtask

task automatic expect_next_flush_checkpoint;
    input string phase_name;
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
                $fatal(1, "%s: control_chip raised error_flag during flush wait",
                       phase_name);
            end

            if (writeback_pulse_total != base_writeback_count) begin
                $fatal(1, "%s: writeback arrived before the bounded flush closed",
                       phase_name);
            end

            if (flush_pulse_total > expected_flush_count) begin
                $fatal(1,
                       "%s: observed more flushes than the bounded target (expected_flush_count=%0d flush_total=%0d seen_token_flush=%0d seen_reclaim=%0d)",
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
                $fatal(1, "%s: busy cleared before the bounded flush closed",
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
                break;
            end
        end

        if (!seen_all) begin
            $fatal(1,
                   "%s: expected one new flush edge plus both ownership-path observables (expected_flush_count=%0d flush_total=%0d seen_flush_edge=%0d seen_token_flush=%0d seen_reclaim=%0d)",
                   phase_name,
                   expected_flush_count,
                   flush_pulse_total,
                   seen_flush_edge,
                   seen_token_flush,
                   seen_reclaim);
        end
    end
endtask

task automatic expect_postflush_witness_before_final_writeback;
    input string phase_name;
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
                $fatal(1, "%s: control_chip raised error_flag postflush",
                       phase_name);
            end

            if (!busy) begin
                $fatal(1, "%s: busy cleared before the final survivor writeback",
                       phase_name);
            end

            if (flush_pulse_total > exact_flush_count) begin
                $fatal(1, "%s: observed an unexpected extra flush before writeback",
                       phase_name);
            end

            if (writeback_pulse_total != base_writeback_count) begin
                $fatal(1,
                       "%s: final writeback arrived before postflush survivor/concurrency witnesses",
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
                break;
            end
        end

        if (!seen_all) begin
            $fatal(1,
                   "%s: expected one postflush survivor continuation and one concurrency window before writeback",
                   phase_name);
        end
    end
endtask

task automatic expect_final_writeback_and_busy_clear;
    input string phase_name;
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
                $fatal(1, "%s: control_chip raised error_flag before writeback",
                       phase_name);
            end

            if (flush_pulse_total > exact_flush_count) begin
                $fatal(1, "%s: observed an unexpected extra flush after final checkpoint",
                       phase_name);
            end

            if (!busy && (writeback_pulse_total == start_writeback_count)) begin
                $fatal(1, "%s: busy cleared before the final writeback appeared",
                       phase_name);
            end

            if (writeback_pulse_total > (start_writeback_count + 1)) begin
                $fatal(1, "%s: observed more than one final top-level writeback",
                       phase_name);
            end

            if (hbm_req_valid && hbm_req_write) begin
                if (hbm_req_addr == {`HBM_ADDR_W{1'b0}}) begin
                    $fatal(1, "%s: expected non-zero bounded writeback address",
                           phase_name);
                end
                if (hbm_req_id == {`REQ_ID_W{1'b0}}) begin
                    $fatal(1, "%s: expected non-zero bounded writeback req_id",
                           phase_name);
                end
                if (hbm_req_wdata !== expected_wdata) begin
                    $fatal(1, "%s: expected exact final writeback packet %h, got %h",
                           phase_name, expected_wdata, hbm_req_wdata);
                end
            end

            if (writeback_pulse_total == (start_writeback_count + 1)) begin
                seen_writeback = 1'b1;
            end

            if (seen_writeback && !busy) begin
                break;
            end
        end

        if (writeback_pulse_total != (start_writeback_count + 1)) begin
            $fatal(1, "%s: expected exactly one final writeback pulse",
                   phase_name);
        end

        if (busy) begin
            $fatal(1, "%s: expected busy to clear after final writeback",
                   phase_name);
        end
    end
endtask

task automatic expect_quiet_idle_gap;
    input string phase_name;
    input integer exact_flush_count;
    input integer exact_writeback_count;
    begin
        for (cycle_i = 0; cycle_i < QUIET_GAP_CYCLES; cycle_i = cycle_i + 1) begin
            @(posedge clk);
            #1;

            if (busy || error_flag || hbm_req_valid || hbm_req_write) begin
                $fatal(1, "%s: expected clean top-level idle boundary",
                       phase_name);
            end

            if ((flush_pulse_total != exact_flush_count) ||
                (writeback_pulse_total != exact_writeback_count)) begin
                $fatal(1, "%s: observed new flush or writeback activity in idle gap",
                       phase_name);
            end

            if (u_control_chip.u_compute_module_bounded_stub.survivor_read_done ||
                u_control_chip.token_flush_valid ||
                u_control_chip.flush_reclaim_valid ||
                |u_control_chip.rc_mem_req_valid ||
                |u_control_chip.rc_mem_req_write) begin
                $fatal(1, "%s: expected no residual bounded activity in idle gap",
                       phase_name);
            end
        end
    end
endtask

task automatic update_coverage;
    input integer expected_flush_count;
    input integer expected_new_token_len;
    begin
        case (expected_new_token_len)
            1: len_cov_1_r = 1'b1;
            2: len_cov_2_r = 1'b1;
            3: len_cov_3_r = 1'b1;
            default: begin
            end
        endcase

        if (expected_flush_count == 1) begin
            short_flush_cov_r = 1'b1;
        end

        if (expected_flush_count >= 3) begin
            long_flush_cov_r = 1'b1;
        end
    end
endtask

task automatic run_one_tree_and_close;
    input integer tree_idx;
    input [CFG_W-1:0] cfg_word;
    input integer expected_flush_count;
    input integer expected_new_token_len;
    input [`HBM_DATA_W-1:0] expected_wdata;
    integer tree_flush_start;
    integer tree_writeback_start;
    integer phase_survivor_base;
    integer phase_concurrency_base;
    integer flush_idx;
    integer flush_edge_survivor_count;
    integer flush_edge_concurrency_count;
    begin
        tree_flush_start = flush_pulse_total;
        tree_writeback_start = writeback_pulse_total;

        launch_bounded_scenario(cfg_word);
        expect_busy_assert($sformatf("tree%0d_busy_assert", tree_idx));

        phase_survivor_base = survivor_done_pulse_total;
        phase_concurrency_base = concurrency_window_total;
        expect_phase_witness_before_next_flush(
            $sformatf("tree%0d_before_flush1", tree_idx),
            tree_flush_start,
            tree_writeback_start,
            phase_survivor_base,
            phase_concurrency_base,
            1
        );

        for (flush_idx = 1; flush_idx <= expected_flush_count;
             flush_idx = flush_idx + 1) begin
            expect_next_flush_checkpoint(
                $sformatf("tree%0d_flush%0d", tree_idx, flush_idx),
                tree_flush_start + flush_idx,
                tree_writeback_start,
                flush_edge_survivor_count,
                flush_edge_concurrency_count
            );

            phase_survivor_base = flush_edge_survivor_count;
            phase_concurrency_base = flush_edge_concurrency_count;

            if (flush_idx < expected_flush_count) begin
                expect_phase_witness_before_next_flush(
                    $sformatf("tree%0d_between_flush%0d_flush%0d",
                              tree_idx, flush_idx, flush_idx + 1),
                    tree_flush_start + flush_idx,
                    tree_writeback_start,
                    phase_survivor_base,
                    phase_concurrency_base,
                    0
                );
            end
        end

        expect_postflush_witness_before_final_writeback(
            $sformatf("tree%0d_postflush_survivor_window", tree_idx),
            tree_flush_start + expected_flush_count,
            tree_writeback_start,
            phase_survivor_base,
            phase_concurrency_base
        );

        expect_final_writeback_and_busy_clear(
            $sformatf("tree%0d_final_writeback", tree_idx),
            tree_flush_start + expected_flush_count,
            tree_writeback_start,
            expected_wdata
        );

        if (flush_pulse_total != (tree_flush_start + expected_flush_count)) begin
            $fatal(1,
                   "tree%0d: expected exactly %0d bounded flushes, saw %0d",
                   tree_idx,
                   expected_flush_count,
                   flush_pulse_total - tree_flush_start);
        end

        if (writeback_pulse_total != (tree_writeback_start + 1)) begin
            $fatal(1,
                   "tree%0d: expected exactly one final survivor writeback",
                   tree_idx);
        end

        expect_quiet_idle_gap(
            $sformatf("gap_after_tree%0d", tree_idx),
            tree_flush_start + expected_flush_count,
            tree_writeback_start + 1
        );

        update_coverage(expected_flush_count, expected_new_token_len);
        total_expected_flush = total_expected_flush + expected_flush_count;
        total_expected_writeback = total_expected_writeback + 1;
    end
endtask

initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    flush_pulse_total = 0;
    writeback_pulse_total = 0;
    survivor_done_pulse_total = 0;
    concurrency_window_total = 0;
    total_expected_flush = 0;
    total_expected_writeback = 0;
    flush_done_q = 1'b0;
    hbm_write_q = 1'b0;
    concurrency_window_q = 1'b0;
    len_cov_1_r = 1'b0;
    len_cov_2_r = 1'b0;
    len_cov_3_r = 1'b0;
    short_flush_cov_r = 1'b0;
    long_flush_cov_r = 1'b0;
    clear_inputs();

    apply_reset_and_check_idle();

    for (tree_i = 0; tree_i < TREE_COUNT; tree_i = tree_i + 1) begin
        run_one_tree_and_close(
            tree_i,
            tree_cfg_word(tree_i),
            tree_expected_flush(tree_i),
            tree_expected_len(tree_i),
            tree_expected_packet(tree_i)
        );
    end

    if (flush_pulse_total != total_expected_flush) begin
        $fatal(1,
               "whole_run: expected total flush count %0d, saw %0d",
               total_expected_flush,
               flush_pulse_total);
    end

    if (writeback_pulse_total != total_expected_writeback) begin
        $fatal(1,
               "whole_run: expected total writeback count %0d, saw %0d",
               total_expected_writeback,
               writeback_pulse_total);
    end

    if (!len_cov_1_r || !len_cov_2_r || !len_cov_3_r) begin
        $fatal(1,
               "whole_run: expected final new_token_len coverage across {1,2,3}");
    end

    if (!short_flush_cov_r || !long_flush_cov_r) begin
        $fatal(1,
               "whole_run: expected both short and long bounded flush-depth coverage");
    end

    if (busy || error_flag) begin
        $fatal(1,
               "whole_run: control_chip should end the bounded serial free-running surrogate without error");
    end

    $display("tb_control_chip_serial_free_running_surrogate PASS");
    $finish;
end

endmodule
