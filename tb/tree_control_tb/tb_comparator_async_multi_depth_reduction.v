`timescale 1ns/1ps

`include "config/prediction_params.vh"
`include "config/interface_params.vh"

module tb_comparator_async_multi_depth_reduction;

localparam integer PRIVATE_DEPTH_W =
    (((`MAX_VERIFY_NODES_PER_BRANCH + 1) <= 2) ? 1 :
     $clog2(`MAX_VERIFY_NODES_PER_BRANCH + 1));
localparam integer BRANCH_EPOCH_W = 2;
localparam integer PATH_PACK_W =
    (`BRANCH_NUM * `MAX_VERIFY_NODES_PER_BRANCH * `NODE_ID_W);
localparam integer DEPTH_PACK_W =
    (`BRANCH_NUM * PRIVATE_DEPTH_W);
localparam integer EPOCH_PACK_W =
    (`BRANCH_NUM * BRANCH_EPOCH_W);

localparam [`REQ_ID_W-1:0] TEST_REQ_ID = 4'h9;

localparam [`BRANCH_ID_W-1:0] BRANCH_ABC1   = 2'd0;
localparam [`BRANCH_ID_W-1:0] BRANCH_ABC1D1 = 2'd1;
localparam [`BRANCH_ID_W-1:0] BRANCH_ABC2   = 2'd2;
localparam [`BRANCH_ID_W-1:0] BRANCH_ABC2D2 = 2'd3;

localparam [`NODE_ID_W-1:0] NODE_C1 = 4'd0;
localparam [`NODE_ID_W-1:0] NODE_D1 = 4'd1;
localparam [`NODE_ID_W-1:0] NODE_C2 = 4'd2;
localparam [`NODE_ID_W-1:0] NODE_D2 = 4'd3;
localparam [`NODE_ID_W-1:0] NODE_NONE = `TREE_PARENT_NONE_NODE_ID;

reg clk;
reg rst_n;

reg                         reduce_start_valid;
reg [`REQ_ID_W-1:0]        reduce_req_id;
reg [`BRANCH_NUM-1:0]      active_branch_valid;
reg [EPOCH_PACK_W-1:0]     active_branch_epoch;
reg [DEPTH_PACK_W-1:0]     active_branch_depth;
reg [PATH_PACK_W-1:0]      active_branch_node_id;
reg [PATH_PACK_W-1:0]      active_branch_parent_node_id;
reg [`BRANCH_NUM-1:0]      result_slot_valid;
reg [`REQ_ID_W-1:0]        result_req_id;
reg [`BRANCH_NUM*`BRANCH_ID_W-1:0] result_branch_id;
reg [EPOCH_PACK_W-1:0]     result_branch_epoch;
reg [DEPTH_PACK_W-1:0]     result_private_depth;
reg [`BRANCH_NUM*`NODE_ID_W-1:0] result_node_id;
reg [`BRANCH_NUM*`NODE_ID_W-1:0] result_parent_node_id;
reg [`BRANCH_NUM-1:0]      result_accept;

wire                       accepted_prefix_valid;
wire [`REQ_ID_W-1:0]       accepted_prefix_req_id;
wire [PRIVATE_DEPTH_W-1:0] accepted_prefix_depth;
wire [(`MAX_VERIFY_NODES_PER_BRANCH*`NODE_ID_W)-1:0] accepted_prefix_node_id;
wire [`BRANCH_NUM-1:0]     live_branch_mask;
wire [`BRANCH_NUM-1:0]     prune_branch_mask;

comparator u_comparator (
    .clk(clk),
    .rst_n(rst_n),
    .reduce_start_valid(reduce_start_valid),
    .reduce_req_id(reduce_req_id),
    .active_branch_valid(active_branch_valid),
    .active_branch_epoch(active_branch_epoch),
    .active_branch_depth(active_branch_depth),
    .active_branch_node_id(active_branch_node_id),
    .active_branch_parent_node_id(active_branch_parent_node_id),
    .result_slot_valid(result_slot_valid),
    .result_req_id(result_req_id),
    .result_branch_id(result_branch_id),
    .result_branch_epoch(result_branch_epoch),
    .result_private_depth(result_private_depth),
    .result_node_id(result_node_id),
    .result_parent_node_id(result_parent_node_id),
    .result_accept(result_accept),
    .accepted_prefix_valid(accepted_prefix_valid),
    .accepted_prefix_req_id(accepted_prefix_req_id),
    .accepted_prefix_depth(accepted_prefix_depth),
    .accepted_prefix_node_id(accepted_prefix_node_id),
    .live_branch_mask(live_branch_mask),
    .prune_branch_mask(prune_branch_mask)
);

always #5 clk = ~clk;

task clear_inputs;
    begin
        reduce_start_valid = 1'b0;
        reduce_req_id = {`REQ_ID_W{1'b0}};
        active_branch_valid = {`BRANCH_NUM{1'b0}};
        active_branch_epoch = {EPOCH_PACK_W{1'b0}};
        active_branch_depth = {DEPTH_PACK_W{1'b0}};
        active_branch_node_id = {PATH_PACK_W{1'b0}};
        active_branch_parent_node_id = {PATH_PACK_W{1'b0}};
        result_slot_valid = {`BRANCH_NUM{1'b0}};
        result_req_id = {`REQ_ID_W{1'b0}};
        result_branch_id = {(`BRANCH_NUM*`BRANCH_ID_W){1'b0}};
        result_branch_epoch = {EPOCH_PACK_W{1'b0}};
        result_private_depth = {DEPTH_PACK_W{1'b0}};
        result_node_id = {(`BRANCH_NUM*`NODE_ID_W){1'b0}};
        result_parent_node_id = {(`BRANCH_NUM*`NODE_ID_W){1'b0}};
        result_accept = {`BRANCH_NUM{1'b0}};
    end
endtask

task preload_active_branches;
    begin
        reduce_start_valid = 1'b1;
        reduce_req_id = TEST_REQ_ID;
        active_branch_valid = 4'b1111;

        active_branch_epoch[(BRANCH_ABC1*BRANCH_EPOCH_W) +: BRANCH_EPOCH_W] = 2'd0;
        active_branch_epoch[(BRANCH_ABC1D1*BRANCH_EPOCH_W) +: BRANCH_EPOCH_W] = 2'd0;
        active_branch_epoch[(BRANCH_ABC2*BRANCH_EPOCH_W) +: BRANCH_EPOCH_W] = 2'd0;
        active_branch_epoch[(BRANCH_ABC2D2*BRANCH_EPOCH_W) +: BRANCH_EPOCH_W] = 2'd0;

        active_branch_depth[(BRANCH_ABC1*PRIVATE_DEPTH_W) +: PRIVATE_DEPTH_W] = PRIVATE_DEPTH_W'(1);
        active_branch_depth[(BRANCH_ABC1D1*PRIVATE_DEPTH_W) +: PRIVATE_DEPTH_W] = PRIVATE_DEPTH_W'(2);
        active_branch_depth[(BRANCH_ABC2*PRIVATE_DEPTH_W) +: PRIVATE_DEPTH_W] = PRIVATE_DEPTH_W'(1);
        active_branch_depth[(BRANCH_ABC2D2*PRIVATE_DEPTH_W) +: PRIVATE_DEPTH_W] = PRIVATE_DEPTH_W'(2);

        active_branch_node_id[(((BRANCH_ABC1*`MAX_VERIFY_NODES_PER_BRANCH) + 0)*`NODE_ID_W) +: `NODE_ID_W] = NODE_C1;
        active_branch_parent_node_id[(((BRANCH_ABC1*`MAX_VERIFY_NODES_PER_BRANCH) + 0)*`NODE_ID_W) +: `NODE_ID_W] = NODE_NONE;

        active_branch_node_id[(((BRANCH_ABC1D1*`MAX_VERIFY_NODES_PER_BRANCH) + 0)*`NODE_ID_W) +: `NODE_ID_W] = NODE_C1;
        active_branch_parent_node_id[(((BRANCH_ABC1D1*`MAX_VERIFY_NODES_PER_BRANCH) + 0)*`NODE_ID_W) +: `NODE_ID_W] = NODE_NONE;
        active_branch_node_id[(((BRANCH_ABC1D1*`MAX_VERIFY_NODES_PER_BRANCH) + 1)*`NODE_ID_W) +: `NODE_ID_W] = NODE_D1;
        active_branch_parent_node_id[(((BRANCH_ABC1D1*`MAX_VERIFY_NODES_PER_BRANCH) + 1)*`NODE_ID_W) +: `NODE_ID_W] = NODE_C1;

        active_branch_node_id[(((BRANCH_ABC2*`MAX_VERIFY_NODES_PER_BRANCH) + 0)*`NODE_ID_W) +: `NODE_ID_W] = NODE_C2;
        active_branch_parent_node_id[(((BRANCH_ABC2*`MAX_VERIFY_NODES_PER_BRANCH) + 0)*`NODE_ID_W) +: `NODE_ID_W] = NODE_NONE;

        active_branch_node_id[(((BRANCH_ABC2D2*`MAX_VERIFY_NODES_PER_BRANCH) + 0)*`NODE_ID_W) +: `NODE_ID_W] = NODE_C2;
        active_branch_parent_node_id[(((BRANCH_ABC2D2*`MAX_VERIFY_NODES_PER_BRANCH) + 0)*`NODE_ID_W) +: `NODE_ID_W] = NODE_NONE;
        active_branch_node_id[(((BRANCH_ABC2D2*`MAX_VERIFY_NODES_PER_BRANCH) + 1)*`NODE_ID_W) +: `NODE_ID_W] = NODE_D2;
        active_branch_parent_node_id[(((BRANCH_ABC2D2*`MAX_VERIFY_NODES_PER_BRANCH) + 1)*`NODE_ID_W) +: `NODE_ID_W] = NODE_C2;
    end
endtask

task drive_first_discriminating_results;
    begin
        result_slot_valid = 4'b0101;
        result_req_id = TEST_REQ_ID;

        result_branch_id[(0*`BRANCH_ID_W) +: `BRANCH_ID_W] = BRANCH_ABC1;
        result_branch_epoch[(0*BRANCH_EPOCH_W) +: BRANCH_EPOCH_W] = 2'd0;
        result_private_depth[(0*PRIVATE_DEPTH_W) +: PRIVATE_DEPTH_W] = PRIVATE_DEPTH_W'(1);
        result_node_id[(0*`NODE_ID_W) +: `NODE_ID_W] = NODE_C1;
        result_parent_node_id[(0*`NODE_ID_W) +: `NODE_ID_W] = NODE_NONE;
        result_accept[0] = 1'b1;

        result_branch_id[(2*`BRANCH_ID_W) +: `BRANCH_ID_W] = BRANCH_ABC2;
        result_branch_epoch[(2*BRANCH_EPOCH_W) +: BRANCH_EPOCH_W] = 2'd0;
        result_private_depth[(2*PRIVATE_DEPTH_W) +: PRIVATE_DEPTH_W] = PRIVATE_DEPTH_W'(1);
        result_node_id[(2*`NODE_ID_W) +: `NODE_ID_W] = NODE_C2;
        result_parent_node_id[(2*`NODE_ID_W) +: `NODE_ID_W] = NODE_NONE;
        result_accept[2] = 1'b0;
    end
endtask

task expect_incremental_prune_result;
    begin
        #1;
        if (!accepted_prefix_valid ||
            (accepted_prefix_req_id != TEST_REQ_ID) ||
            (accepted_prefix_depth != PRIVATE_DEPTH_W'(1)) ||
            (accepted_prefix_node_id[`NODE_ID_W-1:0] != NODE_C1) ||
            (live_branch_mask != 4'b0011) ||
            (prune_branch_mask != 4'b1100)) begin
            $fatal(1, "async multi-depth comparator reduction mismatch");
        end
    end
endtask

initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    clear_inputs();

    repeat (3) @(posedge clk);
    rst_n = 1'b1;

    preload_active_branches();
    drive_first_discriminating_results();
    expect_incremental_prune_result();

    $display("tb_comparator_async_multi_depth_reduction PASS");
    $finish;
end

endmodule
