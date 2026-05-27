`timescale 1ns/1ps

`include "config/prediction_params.vh"
`include "config/interface_params.vh"
`include "config/memory_params.vh"

module tb_control_chip_tree_driven_reusable_idle_final_closure;

localparam integer CFG_W = 32;
localparam integer TREE_COUNT = 5;
localparam integer BACK_HALF_START = 3;
localparam [CFG_W-1:0] TREE0_CFG_DATA = 32'h04f0_0000;
localparam [CFG_W-1:0] TREE1_CFG_DATA = 32'h04f0_0001;
localparam [CFG_W-1:0] TREE2_CFG_DATA = 32'h04f0_0002;
localparam [CFG_W-1:0] TREE3_CFG_DATA = 32'h04f0_0003;
localparam [CFG_W-1:0] TREE4_CFG_DATA = 32'h04f0_0004;

localparam integer BUSY_ASSERT_TIMEOUT_CYCLES = 24;
localparam integer MODE_ASSERT_TIMEOUT_CYCLES = 12;
localparam integer TREE_VERIFY_TIMEOUT_CYCLES = 360;
localparam integer WRITEBACK_TIMEOUT_CYCLES = 280;
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
integer token_flush_edge_total;
integer flush_reclaim_edge_total;
reg flush_done_q;
reg hbm_write_q;
reg concurrency_window_q;
reg token_flush_q;
reg flush_reclaim_q;

reg clean_tree_cov_r;
reg single_flush_cov_r;
reg multi_flush_cov_r;
reg stale_drop_cov_r;
reg survivor_continue_cov_r;
reg multi_token_writeback_cov_r;
reg back_half_flush_cov_r;
reg back_half_multi_token_writeback_cov_r;
reg final_reusable_idle_cov_r;

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
        token_flush_q <= 1'b0;
        flush_reclaim_q <= 1'b0;
        flush_pulse_total <= 0;
        writeback_pulse_total <= 0;
        survivor_done_pulse_total <= 0;
        concurrency_window_total <= 0;
        token_flush_edge_total <= 0;
        flush_reclaim_edge_total <= 0;
    end else begin
        flush_done_q <= u_control_chip.u_prediction_unit_bounded_stub.flush_done;
        hbm_write_q <= hbm_req_valid && hbm_req_write;
        concurrency_window_q <=
            (lane_issue_count(
                u_control_chip.rc_mem_req_valid &
                u_control_chip.rc_mem_req_ready) >= 2);
        token_flush_q <= u_control_chip.token_flush_valid;
        flush_reclaim_q <= u_control_chip.flush_reclaim_valid;

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

        if (u_control_chip.token_flush_valid && !token_flush_q) begin
            token_flush_edge_total <= token_flush_edge_total + 1;
        end

        if (u_control_chip.flush_reclaim_valid && !flush_reclaim_q) begin
            flush_reclaim_edge_total <= flush_reclaim_edge_total + 1;
        end
    end
end

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
            token_flush_edge_total != 0 ||
            flush_reclaim_edge_total != 0 ||
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
    input integer tree_idx;
    reg seen_busy;
    begin
        seen_busy = 1'b0;
        for (cycle_i = 0; cycle_i < BUSY_ASSERT_TIMEOUT_CYCLES;
             cycle_i = cycle_i + 1) begin
            @(posedge clk);
            #1;
            if (error_flag) begin
                $fatal(1, "tree%0d: error_flag asserted before busy", tree_idx);
            end
            if (busy) begin
                seen_busy = 1'b1;
                break;
            end
        end

        if (!seen_busy) begin
            $fatal(1, "tree%0d: expected busy after cfg/start", tree_idx);
        end
    end
endtask

task automatic expect_tree_driven_mode_and_descriptor;
    input integer tree_idx;
    input [CFG_W-1:0] cfg_word;
    reg seen_mode;
    begin
        seen_mode = 1'b0;
        for (cycle_i = 0; cycle_i < MODE_ASSERT_TIMEOUT_CYCLES;
             cycle_i = cycle_i + 1) begin
            @(posedge clk);
            #1;
            if (u_control_chip.scenario_tree_driven_reusable_idle_final_mode_r &&
                (u_control_chip.scenario_tree_descriptor_id_r ==
                 cfg_word[7:0])) begin
                seen_mode = 1'b1;
                break;
            end
        end

        if (!seen_mode) begin
            $fatal(1,
                   "tree%0d: expected 4'hf reusable-idle final mode and descriptor id %0d",
                   tree_idx,
                   cfg_word[7:0]);
        end
    end
endtask

task automatic observe_runtime_tree_closure;
    input integer tree_idx;
    input integer base_flush_count;
    input integer base_writeback_count;
    input integer base_survivor_done_count;
    input integer base_concurrency_count;
    input integer base_token_flush_edges;
    input integer base_flush_reclaim_edges;
    output integer observed_effective_flush_count;
    integer first_flush_concurrency_count;
    integer first_flush_survivor_count;
    integer flush_delta;
    integer token_flush_delta;
    integer reclaim_delta;
    reg first_flush_seen;
    reg seen_concurrency_before_first_flush;
    reg seen_concurrency_after_flush;
    reg seen_survivor_after_flush;
    reg seen_stale_drop;
    reg seen_verify_done;
    begin
        observed_effective_flush_count = -1;
        first_flush_concurrency_count = base_concurrency_count;
        first_flush_survivor_count = base_survivor_done_count;
        first_flush_seen = 1'b0;
        seen_concurrency_before_first_flush = 1'b0;
        seen_concurrency_after_flush = 1'b0;
        seen_survivor_after_flush = 1'b0;
        seen_stale_drop = 1'b0;
        seen_verify_done = 1'b0;

        for (cycle_i = 0; cycle_i < TREE_VERIFY_TIMEOUT_CYCLES;
             cycle_i = cycle_i + 1) begin
            @(posedge clk);
            #1;

            if (error_flag) begin
                $fatal(1, "tree%0d: error_flag asserted before tree_verify_done",
                       tree_idx);
            end

            if (!busy) begin
                $fatal(1, "tree%0d: busy cleared before tree_verify_done",
                       tree_idx);
            end

            if (writeback_pulse_total != base_writeback_count) begin
                $fatal(1,
                       "tree%0d: writeback arrived before runtime tree verification closed",
                       tree_idx);
            end

            if ((concurrency_window_total > base_concurrency_count) &&
                !first_flush_seen) begin
                seen_concurrency_before_first_flush = 1'b1;
            end

            if (!first_flush_seen && (flush_pulse_total > base_flush_count)) begin
                first_flush_seen = 1'b1;
                first_flush_concurrency_count = concurrency_window_total;
                first_flush_survivor_count = survivor_done_pulse_total;
            end

            if (first_flush_seen &&
                (concurrency_window_total > first_flush_concurrency_count)) begin
                seen_concurrency_after_flush = 1'b1;
            end

            if (first_flush_seen &&
                (survivor_done_pulse_total > first_flush_survivor_count)) begin
                seen_survivor_after_flush = 1'b1;
            end

            if (u_control_chip.u_prediction_unit_bounded_stub.stale_event_drop_seen) begin
                seen_stale_drop = 1'b1;
            end

            if (u_control_chip.u_prediction_unit_bounded_stub.tree_verify_done) begin
                observed_effective_flush_count =
                    u_control_chip.u_prediction_unit_bounded_stub.effective_flush_count;
                seen_verify_done = 1'b1;
                break;
            end
        end

        if (!seen_verify_done) begin
            $fatal(1, "tree%0d: tree_verify_done did not appear", tree_idx);
        end

        flush_delta = flush_pulse_total - base_flush_count;
        token_flush_delta = token_flush_edge_total - base_token_flush_edges;
        reclaim_delta = flush_reclaim_edge_total - base_flush_reclaim_edges;

        if (flush_delta != observed_effective_flush_count) begin
            $fatal(1,
                   "tree%0d: effective_flush_count mismatch actual=%0d summary=%0d",
                   tree_idx,
                   flush_delta,
                   observed_effective_flush_count);
        end

        if (!seen_concurrency_before_first_flush) begin
            $fatal(1,
                   "tree%0d: expected at least one explicit concurrency window before closure",
                   tree_idx);
        end

        if (observed_effective_flush_count == 0) begin
            clean_tree_cov_r = 1'b1;
        end else begin
            if (!seen_survivor_after_flush) begin
                $fatal(1,
                       "tree%0d: flush-bearing tree should show survivor continuation after flush",
                       tree_idx);
            end
            survivor_continue_cov_r = 1'b1;

            if (observed_effective_flush_count == 1) begin
                single_flush_cov_r = 1'b1;
            end else begin
                if (!seen_concurrency_after_flush) begin
                    $fatal(1,
                           "tree%0d: multi-flush tree should show concurrency after an earlier flush",
                           tree_idx);
                end
                multi_flush_cov_r = 1'b1;
            end

            if (tree_idx >= BACK_HALF_START) begin
                back_half_flush_cov_r = 1'b1;
            end

            if (token_flush_delta < observed_effective_flush_count) begin
                $fatal(1,
                       "tree%0d: token_flush_valid edges %0d smaller than effective flush count %0d",
                       tree_idx,
                       token_flush_delta,
                       observed_effective_flush_count);
            end
            if (reclaim_delta < observed_effective_flush_count) begin
                $fatal(1,
                       "tree%0d: flush_reclaim_valid edges %0d smaller than effective flush count %0d",
                       tree_idx,
                       reclaim_delta,
                       observed_effective_flush_count);
            end
        end

        if (seen_stale_drop) begin
            if (observed_effective_flush_count == 0) begin
                $fatal(1,
                       "tree%0d: stale late-result drop should only appear on flush-bearing trees",
                       tree_idx);
            end
            stale_drop_cov_r = 1'b1;
            survivor_continue_cov_r = 1'b1;
        end
    end
endtask

task automatic expect_final_writeback_and_idle;
    input integer tree_idx;
    input integer effective_flush_count_i;
    input integer start_writeback_count;
    input integer frozen_flush_count;
    reg seen_writeback;
    reg [15:0] observed_len;
    begin
        seen_writeback = 1'b0;
        observed_len = 16'h0000;

        for (cycle_i = 0; cycle_i < WRITEBACK_TIMEOUT_CYCLES;
             cycle_i = cycle_i + 1) begin
            @(posedge clk);
            #1;

            if (error_flag) begin
                $fatal(1, "tree%0d: error_flag asserted before final writeback",
                       tree_idx);
            end

            if (flush_pulse_total != frozen_flush_count) begin
                $fatal(1,
                       "tree%0d: new flush arrived after tree_verify_done and before final writeback",
                       tree_idx);
            end

            if (writeback_pulse_total > (start_writeback_count + 1)) begin
                $fatal(1,
                       "tree%0d: observed more than one final top-level writeback",
                       tree_idx);
            end

            if (hbm_req_valid && hbm_req_write) begin
                if (hbm_req_addr == {`HBM_ADDR_W{1'b0}} ||
                    hbm_req_id == {`REQ_ID_W{1'b0}}) begin
                    $fatal(1,
                           "tree%0d: final writeback should carry non-zero address and req_id",
                           tree_idx);
                end
                observed_len = hbm_req_wdata[15:0];
                if (observed_len == 16'h0000) begin
                    $fatal(1, "tree%0d: final writeback length should be non-zero",
                           tree_idx);
                end
            end

            if (writeback_pulse_total == (start_writeback_count + 1)) begin
                seen_writeback = 1'b1;
            end

            if (seen_writeback && !busy) begin
                if ((effective_flush_count_i > 0) &&
                    (flush_pulse_total != frozen_flush_count)) begin
                    $fatal(1,
                           "tree%0d: final writeback must remain after the last effective flush",
                           tree_idx);
                end
                if (observed_len > 16'h0001) begin
                    multi_token_writeback_cov_r = 1'b1;
                    if (tree_idx >= BACK_HALF_START) begin
                        back_half_multi_token_writeback_cov_r = 1'b1;
                    end
                end
                break;
            end
        end

        if (!seen_writeback) begin
            $fatal(1, "tree%0d: final writeback did not appear", tree_idx);
        end

        if (writeback_pulse_total != (start_writeback_count + 1)) begin
            $fatal(1, "tree%0d: expected exactly one final writeback pulse",
                   tree_idx);
        end

        if (busy) begin
            $fatal(1, "tree%0d: busy should clear after final writeback",
                   tree_idx);
        end
    end
endtask

task automatic expect_reusable_idle_contract;
    input integer tree_idx;
    input integer exact_flush_count;
    input integer exact_writeback_count;
    input integer exact_survivor_done_count;
    begin
        for (cycle_i = 0; cycle_i < QUIET_GAP_CYCLES; cycle_i = cycle_i + 1) begin
            @(posedge clk);
            #1;

            if (busy || error_flag || hbm_req_valid || hbm_req_write) begin
                $fatal(1,
                       "tree%0d: expected clean top-level idle boundary before next launch",
                       tree_idx);
            end

            if ((flush_pulse_total != exact_flush_count) ||
                (writeback_pulse_total != exact_writeback_count) ||
                (survivor_done_pulse_total != exact_survivor_done_count)) begin
                $fatal(1,
                       "tree%0d: observed new flush, writeback, or survivor activity in reusable idle gap",
                       tree_idx);
            end

            if (u_control_chip.u_compute_module_bounded_stub.survivor_read_done ||
                u_control_chip.token_flush_valid ||
                u_control_chip.flush_reclaim_valid ||
                |u_control_chip.rc_mem_req_valid ||
                |u_control_chip.rc_mem_req_write) begin
                $fatal(1,
                       "tree%0d: expected no residual bounded activity in reusable idle gap",
                       tree_idx);
            end
        end

        if (tree_idx == (TREE_COUNT - 1)) begin
            final_reusable_idle_cov_r = 1'b1;
        end
    end
endtask

task automatic run_one_tree;
    input integer tree_idx;
    input [CFG_W-1:0] cfg_word;
    integer tree_flush_start;
    integer tree_writeback_start;
    integer tree_survivor_start;
    integer tree_concurrency_start;
    integer tree_token_flush_start;
    integer tree_reclaim_start;
    integer observed_effective_flush_count;
    begin
        tree_flush_start = flush_pulse_total;
        tree_writeback_start = writeback_pulse_total;
        tree_survivor_start = survivor_done_pulse_total;
        tree_concurrency_start = concurrency_window_total;
        tree_token_flush_start = token_flush_edge_total;
        tree_reclaim_start = flush_reclaim_edge_total;

        launch_bounded_scenario(cfg_word);
        expect_busy_assert(tree_idx);
        expect_tree_driven_mode_and_descriptor(tree_idx, cfg_word);

        observe_runtime_tree_closure(
            tree_idx,
            tree_flush_start,
            tree_writeback_start,
            tree_survivor_start,
            tree_concurrency_start,
            tree_token_flush_start,
            tree_reclaim_start,
            observed_effective_flush_count
        );

        expect_final_writeback_and_idle(
            tree_idx,
            observed_effective_flush_count,
            tree_writeback_start,
            tree_flush_start + observed_effective_flush_count
        );

        expect_reusable_idle_contract(
            tree_idx,
            flush_pulse_total,
            writeback_pulse_total,
            survivor_done_pulse_total
        );
    end
endtask

initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    flush_pulse_total = 0;
    writeback_pulse_total = 0;
    survivor_done_pulse_total = 0;
    concurrency_window_total = 0;
    token_flush_edge_total = 0;
    flush_reclaim_edge_total = 0;
    flush_done_q = 1'b0;
    hbm_write_q = 1'b0;
    concurrency_window_q = 1'b0;
    token_flush_q = 1'b0;
    flush_reclaim_q = 1'b0;
    clean_tree_cov_r = 1'b0;
    single_flush_cov_r = 1'b0;
    multi_flush_cov_r = 1'b0;
    stale_drop_cov_r = 1'b0;
    survivor_continue_cov_r = 1'b0;
    multi_token_writeback_cov_r = 1'b0;
    back_half_flush_cov_r = 1'b0;
    back_half_multi_token_writeback_cov_r = 1'b0;
    final_reusable_idle_cov_r = 1'b0;
    clear_inputs();

    apply_reset_and_check_idle();

    for (tree_i = 0; tree_i < TREE_COUNT; tree_i = tree_i + 1) begin
        run_one_tree(
            tree_i,
            tree_cfg_word(tree_i)
        );
    end

    if (!clean_tree_cov_r) begin
        $fatal(1, "whole_run: expected at least one runtime-classified no-flush closure");
    end

    if (!single_flush_cov_r) begin
        $fatal(1, "whole_run: expected at least one runtime-classified single-effective-flush closure");
    end

    if (!multi_flush_cov_r) begin
        $fatal(1, "whole_run: expected at least one runtime-classified multi-effective-flush closure");
    end

    if (!stale_drop_cov_r) begin
        $fatal(1, "whole_run: expected at least one stale late-result drop");
    end

    if (!survivor_continue_cov_r) begin
        $fatal(1, "whole_run: expected at least one survivor continuation after flush");
    end

    if (!multi_token_writeback_cov_r) begin
        $fatal(1, "whole_run: expected at least one multi-token final writeback");
    end

    if (!back_half_flush_cov_r) begin
        $fatal(1, "whole_run: expected at least one back-half flush-bearing closure");
    end

    if (!back_half_multi_token_writeback_cov_r) begin
        $fatal(1, "whole_run: expected at least one back-half multi-token final writeback");
    end

    if (!final_reusable_idle_cov_r) begin
        $fatal(1, "whole_run: expected the final tree to return to the same reusable idle contract");
    end

    if (busy || error_flag) begin
        $fatal(1,
               "whole_run: control_chip should end the bounded reusable-idle final-closure run without error");
    end

    $display("tb_control_chip_tree_driven_reusable_idle_final_closure PASS");
    $finish;
end

endmodule
