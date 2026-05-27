`timescale 1ns/1ps

`include "config/interface_params.vh"

module tb_integration_writeback_part_min;

localparam integer RESULT_STATUS_W = 2;
localparam [RESULT_STATUS_W-1:0] STATUS_OK = 2'b00;
localparam [RESULT_STATUS_W-1:0] STATUS_ERR = 2'b10;

reg clk;
reg rst_n;

reg                        result_valid;
wire                       result_ready;
reg  [`TOKEN_ID_W-1:0]     result_token_id;
reg  [`SRAM_ADDR_W-1:0]    result_addr;
reg  [`SRAM_WDATA_W-1:0]   result_data;
reg  [RESULT_STATUS_W-1:0] result_status;

wire                       wb_valid;
reg                        wb_ready;
wire [`TOKEN_ID_W-1:0]     wb_token_id;
wire [`SRAM_ADDR_W-1:0]    wb_addr;
wire [`SRAM_WDATA_W-1:0]   wb_data;
wire [RESULT_STATUS_W-1:0] wb_status;
wire                       wb_done;
wire                       wb_error;

IntegrationWritebackPart #(
    .RESULT_STATUS_W(RESULT_STATUS_W)
) u_integration_writeback_part (
    .clk(clk),
    .rst_n(rst_n),
    .result_valid(result_valid),
    .result_ready(result_ready),
    .result_token_id(result_token_id),
    .result_addr(result_addr),
    .result_data(result_data),
    .result_status(result_status),
    .wb_valid(wb_valid),
    .wb_ready(wb_ready),
    .wb_token_id(wb_token_id),
    .wb_addr(wb_addr),
    .wb_data(wb_data),
    .wb_status(wb_status),
    .wb_done(wb_done),
    .wb_error(wb_error)
);

always #5 clk = ~clk;

task clear_result_inputs;
    begin
        result_valid = 1'b0;
        result_token_id = {`TOKEN_ID_W{1'b0}};
        result_addr = {`SRAM_ADDR_W{1'b0}};
        result_data = {`SRAM_WDATA_W{1'b0}};
        result_status = {RESULT_STATUS_W{1'b0}};
    end
endtask

task expect_idle;
    begin
        #1;
        if ((result_ready !== 1'b1) ||
            (wb_valid !== 1'b0) ||
            (wb_done !== 1'b0) ||
            (wb_error !== 1'b0)) begin
            $fatal(1, "writeback part should be idle");
        end
    end
endtask

task push_result;
    input [`TOKEN_ID_W-1:0] token_id;
    input [`SRAM_ADDR_W-1:0] addr;
    input [`SRAM_WDATA_W-1:0] data;
    input [RESULT_STATUS_W-1:0] status;
    begin
        if (result_ready !== 1'b1) begin
            $fatal(1, "writeback part is not ready to accept result");
        end

        result_valid = 1'b1;
        result_token_id = token_id;
        result_addr = addr;
        result_data = data;
        result_status = status;

        @(posedge clk);
        #1;
        result_valid = 1'b0;
    end
endtask

task expect_buffered_result;
    input [`TOKEN_ID_W-1:0] token_id;
    input [`SRAM_ADDR_W-1:0] addr;
    input [`SRAM_WDATA_W-1:0] data;
    input [RESULT_STATUS_W-1:0] status;
    begin
        #1;
        if ((result_ready !== 1'b0) ||
            (wb_valid !== 1'b1) ||
            (wb_token_id != token_id) ||
            (wb_addr != addr) ||
            (wb_data != data) ||
            (wb_status != status) ||
            (wb_done !== 1'b0) ||
            (wb_error !== 1'b0)) begin
            $fatal(1, "writeback buffered payload mismatch");
        end
    end
endtask

task consume_writeback;
    begin
        wb_ready = 1'b1;
        @(posedge clk);
        #1;
        wb_ready = 1'b0;
    end
endtask

task expect_completion_pulse;
    input expected_error;
    begin
        #1;
        if ((wb_valid !== 1'b0) ||
            (result_ready !== 1'b1) ||
            (wb_done !== 1'b1) ||
            (wb_error !== expected_error)) begin
            $fatal(1, "writeback completion pulse mismatch");
        end

        @(posedge clk);
        #1;
        if ((wb_done !== 1'b0) || (wb_error !== 1'b0)) begin
            $fatal(1, "writeback completion pulse should be one cycle");
        end
    end
endtask

initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    wb_ready = 1'b0;
    clear_result_inputs();

    repeat (3) @(posedge clk);
    rst_n = 1'b1;

    expect_idle();

    push_result(16'h0111, 19'h00021, 128'h0000_0000_0000_0000_0000_0000_0000_00AA,
        STATUS_OK);
    expect_buffered_result(16'h0111, 19'h00021,
        128'h0000_0000_0000_0000_0000_0000_0000_00AA, STATUS_OK);
    consume_writeback();
    expect_completion_pulse(1'b0);

    push_result(16'h0222, 19'h00045, 128'h0000_0000_0000_0000_0000_0000_0000_00CC,
        STATUS_ERR);
    expect_buffered_result(16'h0222, 19'h00045,
        128'h0000_0000_0000_0000_0000_0000_0000_00CC, STATUS_ERR);
    consume_writeback();
    expect_completion_pulse(1'b1);

    $display("tb_integration_writeback_part_min PASS");
    $finish;
end

endmodule
