`include "config/interface_params.vh"
`include "config/memory_params.vh"
`include "config/model_params.vh"
`timescale 1ns/1ps

module tb_fp16_mha_controller;

localparam integer DATA_WIDTH = 16;
localparam integer DATA_BUS_W = `SRAM_WDATA_W;
localparam integer HIDDEN_DIM = 128;
localparam integer NUM_HEADS = 1;
localparam integer HEAD_DIM = 128;
localparam integer ELEMS_PER_BEAT = DATA_BUS_W / DATA_WIDTH;
localparam integer HIDDEN_BEATS = HIDDEN_DIM / ELEMS_PER_BEAT;
localparam integer HEAD_BEATS = HEAD_DIM / ELEMS_PER_BEAT;
localparam integer MATVEC_BEATS = (HIDDEN_DIM * HIDDEN_DIM) / ELEMS_PER_BEAT;
localparam integer MEM_DEPTH = 131072;
localparam integer MAX_WAIT_CYCLES = 150000;
localparam [15:0] FP_ONE = 16'h3c00;
localparam [15:0] FP_ONE_OVER_128 = 16'h2000;
localparam [15:0] FP_HALF = 16'h3800;
localparam [15:0] FP_QUARTER = 16'h3400;

localparam [`SRAM_ADDR_W-1:0] INPUT_BASE = 23'd256;
localparam [`SRAM_ADDR_W-1:0] WQ_BASE = 23'd2048;
localparam [`SRAM_ADDR_W-1:0] WK_BASE = 23'd8192;
localparam [`SRAM_ADDR_W-1:0] WV_BASE = 23'd14336;
localparam [`SRAM_ADDR_W-1:0] WO_BASE = 23'd20480;
localparam [`SRAM_ADDR_W-1:0] KV_CACHE_BASE = 23'd32768;
localparam [`SRAM_ADDR_W-1:0] RESULT_BASE = 23'd49152;
localparam [`SRAM_ADDR_W-1:0] SCRATCH_BASE = 23'd53248;

logic clk;
logic rst_n;
logic issue_valid;
logic issue_ready;
logic sram_rd_valid;
logic sram_rd_ready;
logic [`SRAM_ADDR_W-1:0] sram_rd_addr;
logic [`REQ_ID_W-1:0] sram_rd_id;
logic sram_resp_valid;
logic sram_resp_ready;
logic [DATA_BUS_W-1:0] sram_resp_data;
logic [`REQ_ID_W-1:0] sram_resp_id;
logic sram_wr_valid;
logic sram_wr_ready;
logic [`SRAM_ADDR_W-1:0] sram_wr_addr;
logic [DATA_BUS_W-1:0] sram_wr_data;
logic result_valid;
logic result_ready;
logic [`SRAM_ADDR_W-1:0] result_addr;
logic [DATA_BUS_W-1:0] result_data;
logic [1:0] result_status;
logic [15:0] issue_position;
logic issue_tree_mask_en;
logic [`BRANCH_ID_W-1:0] issue_branch_id;
logic [15:0] issue_prefix_len;

logic [DATA_BUS_W-1:0] mem [0:MEM_DEPTH-1];
logic [DATA_BUS_W-1:0] branch0_snap_r [0:HIDDEN_BEATS-1];
logic [DATA_BUS_W-1:0] branch1_snap_r [0:HIDDEN_BEATS-1];
logic rd_pending_r;
logic [`SRAM_ADDR_W-1:0] rd_addr_pending_r;
logic [`REQ_ID_W-1:0] rd_id_pending_r;

integer beat_idx_i;
integer elem_idx_i;
integer wait_cycles_i;
integer nonzero_count_i;

fp16_mha_controller #(
    .ADDR_W(`SRAM_ADDR_W),
    .DATA_WIDTH(DATA_WIDTH),
    .DATA_BUS_W(DATA_BUS_W),
    .REQ_ID_W(`REQ_ID_W),
    .RESULT_STATUS_W(2),
    .HIDDEN_DIM(HIDDEN_DIM),
    .NUM_HEADS(NUM_HEADS),
    .HEAD_DIM(HEAD_DIM),
    .RESULT_STATUS_OK(2'b00)
) u_dut (
    .clk(clk),
    .rst_n(rst_n),
    .issue_valid(issue_valid),
    .issue_ready(issue_ready),
    .issue_input_addr(INPUT_BASE),
    .issue_wq_addr(WQ_BASE),
    .issue_wk_addr(WK_BASE),
    .issue_wv_addr(WV_BASE),
    .issue_wo_addr(WO_BASE),
    .issue_kv_cache_addr(KV_CACHE_BASE),
    .issue_result_addr(RESULT_BASE),
    .issue_scratch_base_addr(SCRATCH_BASE),
    .issue_position(issue_position),
    .issue_layer_id(5'd0),
    .issue_req_id(4'h3),
    .issue_tree_mask_en(issue_tree_mask_en),
    .issue_branch_id(issue_branch_id),
    .issue_prefix_len(issue_prefix_len),
    .issue_visible_mask({`TOY_MAX_POS_EMB{1'b0}}),
    .issue_tree_batch_en(1'b0),
    .issue_tree_draft_kv_base({`SRAM_ADDR_W{1'b0}}),
    .issue_tree_query_slot({`SLOT_ID_W{1'b0}}),
    .issue_tree_slot_count(5'd0),
    .issue_tree_visible_slots({`VERIFY_WINDOW_SIZE{1'b0}}),
    .issue_tree_slot_is_seed({`VERIFY_WINDOW_SIZE{1'b0}}),
    .issue_tree_seed_kv_valid(1'b0),
    .issue_tree_kv_barrier_release(1'b1),
    .tree_kv_barrier_waiting(),
    .sram_rd_valid(sram_rd_valid),
    .sram_rd_ready(sram_rd_ready),
    .sram_rd_addr(sram_rd_addr),
    .sram_rd_id(sram_rd_id),
    .sram_resp_valid(sram_resp_valid),
    .sram_resp_ready(sram_resp_ready),
    .sram_resp_data(sram_resp_data),
    .sram_resp_id(sram_resp_id),
    .sram_wr_valid(sram_wr_valid),
    .sram_wr_ready(sram_wr_ready),
    .sram_wr_addr(sram_wr_addr),
    .sram_wr_data(sram_wr_data),
    .result_valid(result_valid),
    .result_ready(result_ready),
    .result_addr(result_addr),
    .result_data(result_data),
    .result_status(result_status)
);

always #5 clk = ~clk;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        rd_pending_r <= 1'b0;
        rd_addr_pending_r <= {`SRAM_ADDR_W{1'b0}};
        rd_id_pending_r <= {`REQ_ID_W{1'b0}};
        sram_resp_valid <= 1'b0;
        sram_resp_data <= {DATA_BUS_W{1'b0}};
        sram_resp_id <= {`REQ_ID_W{1'b0}};
    end else begin
        sram_resp_valid <= 1'b0;

        if (sram_rd_valid && sram_rd_ready) begin
            rd_pending_r <= 1'b1;
            rd_addr_pending_r <= sram_rd_addr;
            rd_id_pending_r <= sram_rd_id;
        end

        if (rd_pending_r) begin
            sram_resp_valid <= 1'b1;
            sram_resp_data <= mem[rd_addr_pending_r];
            sram_resp_id <= rd_id_pending_r;
            rd_pending_r <= 1'b0;
        end

        if (sram_wr_valid && sram_wr_ready)
            mem[sram_wr_addr] <= sram_wr_data;
    end
end

task automatic preload_vector;
    input integer base_addr;
    begin
        for (beat_idx_i = 0; beat_idx_i < HIDDEN_BEATS; beat_idx_i = beat_idx_i + 1) begin
            for (elem_idx_i = 0; elem_idx_i < ELEMS_PER_BEAT; elem_idx_i = elem_idx_i + 1)
                mem[base_addr + beat_idx_i][(elem_idx_i*DATA_WIDTH) +: DATA_WIDTH] = FP_ONE;
        end
    end
endtask

task automatic preload_matrix;
    input integer base_addr;
    begin
        for (beat_idx_i = 0; beat_idx_i < MATVEC_BEATS; beat_idx_i = beat_idx_i + 1) begin
            for (elem_idx_i = 0; elem_idx_i < ELEMS_PER_BEAT; elem_idx_i = elem_idx_i + 1)
                mem[base_addr + beat_idx_i][(elem_idx_i*DATA_WIDTH) +: DATA_WIDTH] = FP_ONE_OVER_128;
        end
    end
endtask

task automatic issue_once;
    input [15:0] position_v;
    input tree_mask_en_v;
    input [`BRANCH_ID_W-1:0] branch_id_v;
    input [15:0] prefix_len_v;
    input [255:0] case_name;
    begin
        wait (issue_ready);
        @(negedge clk);
        issue_position = position_v;
        issue_tree_mask_en = tree_mask_en_v;
        issue_branch_id = branch_id_v;
        issue_prefix_len = prefix_len_v;
        issue_valid = 1'b1;
        @(negedge clk);
        issue_valid = 1'b0;

        wait_cycles_i = 0;
        while (!result_valid && (wait_cycles_i < MAX_WAIT_CYCLES)) begin
            @(posedge clk);
            wait_cycles_i = wait_cycles_i + 1;
        end

        if (!result_valid)
            $fatal(1, "MHA controller timed out case=%0s after %0d cycles", case_name, MAX_WAIT_CYCLES);
        if (result_status !== 2'b00)
            $fatal(1, "MHA controller result_status mismatch case=%0s actual=%b", case_name, result_status);
        if (result_addr !== RESULT_BASE)
            $fatal(1, "MHA controller result_addr mismatch case=%0s actual=%0d expected=%0d",
                   case_name, result_addr, RESULT_BASE);

        nonzero_count_i = 0;
        for (beat_idx_i = 0; beat_idx_i < HIDDEN_BEATS; beat_idx_i = beat_idx_i + 1) begin
            for (elem_idx_i = 0; elem_idx_i < ELEMS_PER_BEAT; elem_idx_i = elem_idx_i + 1) begin
                if (mem[RESULT_BASE + beat_idx_i][(elem_idx_i*DATA_WIDTH) +: DATA_WIDTH] != 16'h0000)
                    nonzero_count_i = nonzero_count_i + 1;
            end
        end

        if (nonzero_count_i == 0)
            $fatal(1, "MHA controller output should not be all zero case=%0s", case_name);
    end
endtask

task automatic clear_result_region;
    begin
        for (beat_idx_i = 0; beat_idx_i < HIDDEN_BEATS; beat_idx_i = beat_idx_i + 1)
            mem[RESULT_BASE + beat_idx_i] = {DATA_BUS_W{1'b0}};
    end
endtask

task automatic snapshot_result_region;
    begin
        for (beat_idx_i = 0; beat_idx_i < HIDDEN_BEATS; beat_idx_i = beat_idx_i + 1)
            branch0_snap_r[beat_idx_i] = mem[RESULT_BASE + beat_idx_i];
    end
endtask

task automatic snapshot_result_region_branch1;
    begin
        for (beat_idx_i = 0; beat_idx_i < HIDDEN_BEATS; beat_idx_i = beat_idx_i + 1)
            branch1_snap_r[beat_idx_i] = mem[RESULT_BASE + beat_idx_i];
    end
endtask

task automatic compare_snapshots_not_equal;
    input [255:0] case_name;
    reg mismatch_found;
    begin
        mismatch_found = 1'b0;
        for (beat_idx_i = 0; beat_idx_i < HIDDEN_BEATS; beat_idx_i = beat_idx_i + 1) begin
            if (branch0_snap_r[beat_idx_i] !== branch1_snap_r[beat_idx_i])
                mismatch_found = 1'b1;
        end
        if (!mismatch_found)
            $fatal(1, "MHA controller snapshots unexpectedly identical case=%0s", case_name);
    end
endtask

task automatic preload_kv_position;
    input integer position_v;
    input [15:0] k_fill_value;
    input [15:0] v_fill_value;
    integer k_base_i;
    integer v_base_i;
    begin
        k_base_i = KV_CACHE_BASE + (position_v * HEAD_BEATS * 2);
        v_base_i = k_base_i + HEAD_BEATS;
        for (beat_idx_i = 0; beat_idx_i < HEAD_BEATS; beat_idx_i = beat_idx_i + 1) begin
            for (elem_idx_i = 0; elem_idx_i < ELEMS_PER_BEAT; elem_idx_i = elem_idx_i + 1) begin
                mem[k_base_i + beat_idx_i][(elem_idx_i*DATA_WIDTH) +: DATA_WIDTH] = k_fill_value;
                mem[v_base_i + beat_idx_i][(elem_idx_i*DATA_WIDTH) +: DATA_WIDTH] = v_fill_value;
            end
        end
    end
endtask

initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    issue_valid = 1'b0;
    issue_position = 16'd0;
    issue_tree_mask_en = 1'b0;
    issue_branch_id = {`BRANCH_ID_W{1'b0}};
    issue_prefix_len = 16'd0;
    sram_rd_ready = 1'b1;
    sram_wr_ready = 1'b1;
    result_ready = 1'b1;

    for (beat_idx_i = 0; beat_idx_i < MEM_DEPTH; beat_idx_i = beat_idx_i + 1)
        mem[beat_idx_i] = {DATA_BUS_W{1'b0}};

    preload_vector(INPUT_BASE);
    preload_matrix(WQ_BASE);
    preload_matrix(WK_BASE);
    preload_matrix(WV_BASE);
    preload_matrix(WO_BASE);
    preload_kv_position(0, FP_ONE, FP_ONE);
    preload_kv_position(1, FP_ONE, FP_ONE);
    preload_kv_position(2, FP_ONE, FP_HALF);
    preload_kv_position(3, FP_ONE, FP_HALF);
    preload_kv_position(4, FP_ONE, FP_QUARTER);

    repeat (3) @(posedge clk);
    rst_n = 1'b1;

    issue_once(16'd0, 1'b0, {`BRANCH_ID_W{1'b0}}, 16'd0, "position_0");
    issue_once(16'd1, 1'b0, {`BRANCH_ID_W{1'b0}}, 16'd0, "position_1");

    clear_result_region();
    issue_once(16'd5, 1'b1, 2'd0, 16'd2, "tree_mask_branch0");
    snapshot_result_region();
    clear_result_region();
    issue_once(16'd5, 1'b1, 2'd1, 16'd2, "tree_mask_branch1");
    snapshot_result_region_branch1();
    compare_snapshots_not_equal("tree_mask_branch0_vs_branch1");

    $display("tb_fp16_mha_controller PASS");
    $finish;
end

endmodule
