`timescale 1ns/1ps

module tb_control_chip_stage2_single_chiplet_full_chiplet_closure_run;

localparam integer POST_BASE_DRAIN_CYCLES = 128;

integer sidecar_window_fire_count_r;
integer sidecar_token_wr_count_r;
integer sidecar_lookup_hit_count_r;
integer sidecar_pe_req_count_r;
integer sidecar_pe_resp_count_r;
integer hbm_req_count_r;
integer idle_quiet_cycles_r;
integer post_base_cycle_count_r;

tb_control_chip_stage2_single_chiplet_strongest_bounded_window_hht_feedback_top_min
    u_base();

defparam u_base.ENABLE_FINAL_FINISH = 0;
defparam u_base.u_control_chip_stage2_single_chiplet
    .ENABLE_OWNERSHIP_CLOSURE_SIDECAR = 1;
defparam u_base.u_control_chip_stage2_single_chiplet
    .ENABLE_TOP_HBM_WRITEBACK_SHIM = 1;

always @(posedge u_base.clk or negedge u_base.rst_n) begin
    if (!u_base.rst_n) begin
        sidecar_window_fire_count_r <= 0;
        sidecar_token_wr_count_r <= 0;
        sidecar_lookup_hit_count_r <= 0;
        sidecar_pe_req_count_r <= 0;
        sidecar_pe_resp_count_r <= 0;
        hbm_req_count_r <= 0;
        idle_quiet_cycles_r <= 0;
    end else begin
        if (u_base.u_control_chip_stage2_single_chiplet
                .closure_sidecar_window_fire_w) begin
            sidecar_window_fire_count_r <= sidecar_window_fire_count_r + 1;
        end

        if (u_base.u_control_chip_stage2_single_chiplet
                .closure_sidecar_token_wr_fire_w) begin
            sidecar_token_wr_count_r <= sidecar_token_wr_count_r + 1;
        end

        if (u_base.u_control_chip_stage2_single_chiplet
                .closure_sidecar_lookup_hit_w) begin
            sidecar_lookup_hit_count_r <= sidecar_lookup_hit_count_r + 1;
        end

        if (u_base.u_control_chip_stage2_single_chiplet
                .closure_sidecar_pe_req_fire_w) begin
            sidecar_pe_req_count_r <= sidecar_pe_req_count_r + 1;
        end

        if (u_base.u_control_chip_stage2_single_chiplet
                .closure_sidecar_pe_resp_fire_w) begin
            sidecar_pe_resp_count_r <= sidecar_pe_resp_count_r + 1;
        end

        if (u_base.u_control_chip_stage2_single_chiplet.hbm_req_valid &&
            u_base.u_control_chip_stage2_single_chiplet.hbm_req_write) begin
            hbm_req_count_r <= hbm_req_count_r + 1;
        end

        if ((u_base.u_control_chip_stage2_single_chiplet.busy == 1'b0) &&
            !u_base.u_control_chip_stage2_single_chiplet.hbm_req_valid &&
            !u_base.u_control_chip_stage2_single_chiplet
                 .closure_sidecar_pe_req_fire_w &&
            !u_base.u_control_chip_stage2_single_chiplet
                 .closure_sidecar_pe_resp_fire_w) begin
            idle_quiet_cycles_r <= idle_quiet_cycles_r + 1;
        end else begin
            idle_quiet_cycles_r <= 0;
        end
    end
end

initial begin
    post_base_cycle_count_r = 0;
    wait (u_base.scenario_complete_r === 1'b1);

    while ((post_base_cycle_count_r < POST_BASE_DRAIN_CYCLES) &&
           ((sidecar_window_fire_count_r < 2) ||
            (sidecar_token_wr_count_r < 1) ||
            (sidecar_lookup_hit_count_r < 1) ||
            (sidecar_pe_req_count_r < 1) ||
            (sidecar_pe_resp_count_r < 1) ||
            (hbm_req_count_r < 2) ||
            (u_base.u_control_chip_stage2_single_chiplet.busy !== 1'b0) ||
            (u_base.u_control_chip_stage2_single_chiplet.error_flag !== 1'b0) ||
            (idle_quiet_cycles_r < 2))) begin
        @(posedge u_base.clk);
        #1;
        post_base_cycle_count_r = post_base_cycle_count_r + 1;
    end

    $display(
        "22_ drain summary: cycles=%0d window=%0d token_wr=%0d lookup_hit=%0d pe_req=%0d pe_resp=%0d hbm=%0d idle_quiet=%0d busy=%b error=%b",
        post_base_cycle_count_r,
        sidecar_window_fire_count_r,
        sidecar_token_wr_count_r,
        sidecar_lookup_hit_count_r,
        sidecar_pe_req_count_r,
        sidecar_pe_resp_count_r,
        hbm_req_count_r,
        idle_quiet_cycles_r,
        u_base.u_control_chip_stage2_single_chiplet.busy,
        u_base.u_control_chip_stage2_single_chiplet.error_flag
    );

    if (sidecar_window_fire_count_r < 2) begin
        $fatal(1, "22_ expected at least two sidecar tree_window fires");
    end
    if (sidecar_token_wr_count_r < 1) begin
        $fatal(1, "22_ expected at least one sidecar token write");
    end
    if (sidecar_lookup_hit_count_r < 1) begin
        $fatal(1, "22_ expected at least one sidecar lookup hit");
    end
    if (sidecar_pe_req_count_r < 1) begin
        $fatal(1, "22_ expected at least one sidecar PE request");
    end
    if (sidecar_pe_resp_count_r < 1) begin
        $fatal(1, "22_ expected at least one sidecar PE response");
    end
    if (hbm_req_count_r < 2) begin
        $fatal(1, "22_ expected at least two top-level HBM writeback pulses");
    end
    if (u_base.u_control_chip_stage2_single_chiplet.busy !== 1'b0) begin
        $fatal(1, "22_ top must return to reusable idle");
    end
    if (u_base.u_control_chip_stage2_single_chiplet.error_flag !== 1'b0) begin
        $fatal(1, "22_ top error_flag must stay low");
    end
    if (idle_quiet_cycles_r < 2) begin
        $fatal(1, "22_ final reusable-idle quiet window was not observed");
    end
    $display("tb_control_chip_stage2_single_chiplet_full_chiplet_closure_run PASS");
    $finish;
end

endmodule
