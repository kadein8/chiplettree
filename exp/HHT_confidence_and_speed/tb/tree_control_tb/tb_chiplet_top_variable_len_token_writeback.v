`timescale 1ns/1ps

`include "config/prediction_params.vh"
`include "config/interface_params.vh"
`include "config/memory_params.vh"

module tb_control_chip_variable_len_token_writeback;

localparam integer CFG_W = 32;
localparam [CFG_W-1:0] RUN_048_LEN1_CFG_DATA = 32'h0480_0001;
localparam [CFG_W-1:0] RUN_048_LEN2_CFG_DATA = 32'h0480_0002;
localparam [CFG_W-1:0] RUN_048_LEN3_CFG_DATA = 32'h0480_0003;
localparam integer BUSY_ASSERT_TIMEOUT_CYCLES = 24;
localparam integer WRITEBACK_TIMEOUT_CYCLES = 160;
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
            hbm_req_id != {`REQ_ID_W{1'b0}}) begin
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

task expect_single_packet_and_busy_clear;
    input [8*32-1:0] phase_name;
    input [`HBM_DATA_W-1:0] expected_wdata;
    reg seen_writeback;
    reg seen_busy_clear;
    integer write_count;
    begin
        seen_writeback = 1'b0;
        seen_busy_clear = 1'b0;
        write_count = 0;

        for (cycle_i = 0; cycle_i < WRITEBACK_TIMEOUT_CYCLES;
             cycle_i = cycle_i + 1) begin
            @(posedge clk);
            #1;

            if (error_flag) begin
                $fatal(1, "%0s: control_chip raised error_flag before writeback",
                       phase_name);
            end

            if (hbm_req_valid && hbm_req_write) begin
                write_count = write_count + 1;

                if (write_count > 1) begin
                    $fatal(1, "%0s: expected exactly one bounded top-level writeback",
                           phase_name);
                end

                if (hbm_req_addr == {`HBM_ADDR_W{1'b0}}) begin
                    $fatal(1, "%0s: expected non-zero bounded writeback address",
                           phase_name);
                end

                if (hbm_req_id == {`REQ_ID_W{1'b0}}) begin
                    $fatal(1, "%0s: expected non-zero bounded writeback req_id",
                           phase_name);
                end

                if (hbm_req_wdata !== expected_wdata) begin
                    $fatal(1,
                           "%0s: expected exact variable-length token packet %h, got %h",
                           phase_name,
                           expected_wdata,
                           hbm_req_wdata);
                end

                seen_writeback = 1'b1;
            end

            if (seen_writeback && !busy) begin
                seen_busy_clear = 1'b1;
                disable expect_single_packet_and_busy_clear;
            end
        end

        if (!seen_writeback) begin
            $fatal(1, "%0s: expected one bounded top-level writeback packet",
                   phase_name);
        end

        if (!seen_busy_clear) begin
            $fatal(1, "%0s: expected busy to clear after the single writeback",
                   phase_name);
        end
    end
endtask

task expect_quiet_gap;
    input [8*32-1:0] phase_name;
    begin
        for (cycle_i = 0; cycle_i < QUIET_GAP_CYCLES; cycle_i = cycle_i + 1) begin
            @(posedge clk);
            #1;
            if (busy || error_flag || hbm_req_valid || hbm_req_write) begin
                $fatal(1, "%0s: expected quiet gap after bounded writeback",
                       phase_name);
            end
        end
    end
endtask

initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    clear_inputs();

    apply_reset_and_check_idle();
    launch_bounded_scenario(RUN_048_LEN1_CFG_DATA);
    expect_busy_assert("len1");
    expect_single_packet_and_busy_clear(
        "len1",
        pack_expected_packet(16'h0001, 16'h0101, 16'h0000, 16'h0000)
    );
    expect_quiet_gap("len1");

    apply_reset_and_check_idle();
    launch_bounded_scenario(RUN_048_LEN2_CFG_DATA);
    expect_busy_assert("len2");
    expect_single_packet_and_busy_clear(
        "len2",
        pack_expected_packet(16'h0002, 16'h0201, 16'h0202, 16'h0000)
    );
    expect_quiet_gap("len2");

    apply_reset_and_check_idle();
    launch_bounded_scenario(RUN_048_LEN3_CFG_DATA);
    expect_busy_assert("len3");
    expect_single_packet_and_busy_clear(
        "len3",
        pack_expected_packet(16'h0003, 16'h0301, 16'h0302, 16'h0303)
    );
    expect_quiet_gap("len3");

    $display("tb_control_chip_variable_len_token_writeback PASS");
    $finish;
end

endmodule
