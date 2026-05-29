`timescale 1ns/1ps

`include "config/prediction_params.vh"
`include "config/interface_params.vh"
`include "config/memory_params.vh"

module tb_prefetch_queue_selective_flush;

localparam [`BRANCH_MASK_W-1:0] BRANCH1_MASK =
    ({{(`BRANCH_MASK_W-1){1'b0}}, 1'b1} << 1);
localparam [`NODE_MASK_W-1:0] BR1_NODE1_MASK =
    ({{(`NODE_MASK_W-1){1'b0}}, 1'b1} <<
     ((1 * `MAX_VERIFY_NODES_PER_BRANCH) + 1));

reg clk;
reg rst_n;

reg enq_valid;
wire enq_ready;
reg [`REQ_ID_W-1:0] enq_req_id;
reg [`BRANCH_ID_W-1:0] enq_branch_id;
reg [`NODE_ID_W-1:0] enq_node_id;
reg [`LAYER_ID_W-1:0] enq_layer_id;
reg [`KV_GROUP_LEN_W-1:0] enq_size_subbank;
reg enq_shared;

reg flush_valid;
reg [`REQ_ID_W-1:0] flush_req_id;
reg [`BRANCH_MASK_W-1:0] flush_branch_mask;
reg [`NODE_MASK_W-1:0] flush_node_mask;

wire deq_valid;
reg deq_ready;
wire [`REQ_ID_W-1:0] deq_req_id;
wire [`BRANCH_ID_W-1:0] deq_branch_id;
wire [`NODE_ID_W-1:0] deq_node_id;
wire [`LAYER_ID_W-1:0] deq_layer_id;
wire [`KV_GROUP_LEN_W-1:0] deq_size_subbank;
wire deq_shared;

prefetch_queue u_prefetch_queue (
    .clk(clk),
    .rst_n(rst_n),
    .enq_valid(enq_valid),
    .enq_ready(enq_ready),
    .enq_req_id(enq_req_id),
    .enq_branch_id(enq_branch_id),
    .enq_node_id(enq_node_id),
    .enq_layer_id(enq_layer_id),
    .enq_size_subbank(enq_size_subbank),
    .enq_shared(enq_shared),
    .flush_valid(flush_valid),
    .flush_req_id(flush_req_id),
    .flush_branch_mask(flush_branch_mask),
    .flush_node_mask(flush_node_mask),
    .deq_valid(deq_valid),
    .deq_ready(deq_ready),
    .deq_req_id(deq_req_id),
    .deq_branch_id(deq_branch_id),
    .deq_node_id(deq_node_id),
    .deq_layer_id(deq_layer_id),
    .deq_size_subbank(deq_size_subbank),
    .deq_shared(deq_shared)
);

always #5 clk = ~clk;

task enqueue_task;
    input [`REQ_ID_W-1:0] req_id;
    input [`BRANCH_ID_W-1:0] branch_id;
    input [`NODE_ID_W-1:0] node_id;
    input [`LAYER_ID_W-1:0] layer_id;
    input [`KV_GROUP_LEN_W-1:0] size_subbank;
    input shared;
    begin
        @(posedge clk);
        if (!enq_ready) begin
            $fatal(1, "prefetch_queue not ready for enqueue");
        end
        enq_valid <= 1'b1;
        enq_req_id <= req_id;
        enq_branch_id <= branch_id;
        enq_node_id <= node_id;
        enq_layer_id <= layer_id;
        enq_size_subbank <= size_subbank;
        enq_shared <= shared;

        @(posedge clk);
        enq_valid <= 1'b0;
    end
endtask

task expect_dequeue;
    input [`REQ_ID_W-1:0] req_id;
    input [`BRANCH_ID_W-1:0] branch_id;
    input [`NODE_ID_W-1:0] node_id;
    input [`LAYER_ID_W-1:0] layer_id;
    input [`KV_GROUP_LEN_W-1:0] size_subbank;
    input shared;
    begin
        #1;
        if (!deq_valid) begin
            $fatal(1, "expected dequeue item but queue reported empty");
        end
        if (deq_req_id != req_id ||
            deq_branch_id != branch_id ||
            deq_node_id != node_id ||
            deq_layer_id != layer_id ||
            deq_size_subbank != size_subbank ||
            deq_shared != shared) begin
            $fatal(1, "dequeue payload mismatch");
        end
        deq_ready <= 1'b1;
        @(posedge clk);
        deq_ready <= 1'b0;
    end
endtask

initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    enq_valid = 1'b0;
    enq_req_id = {`REQ_ID_W{1'b0}};
    enq_branch_id = {`BRANCH_ID_W{1'b0}};
    enq_node_id = {`NODE_ID_W{1'b0}};
    enq_layer_id = {`LAYER_ID_W{1'b0}};
    enq_size_subbank = {`KV_GROUP_LEN_W{1'b0}};
    enq_shared = 1'b0;
    flush_valid = 1'b0;
    flush_req_id = {`REQ_ID_W{1'b0}};
    flush_branch_mask = {`BRANCH_MASK_W{1'b0}};
    flush_node_mask = {`NODE_MASK_W{1'b0}};
    deq_ready = 1'b0;

    repeat (3) @(posedge clk);
    rst_n = 1'b1;

    enqueue_task(4'h3, 2'd0, 4'd0, 6'd0, `KV_GROUP_SIZE_SUBBANK, 1'b0);
    enqueue_task(4'h3, 2'd1, 4'd1, 6'd0, `KV_GROUP_SIZE_SUBBANK, 1'b1);
    enqueue_task(4'h4, 2'd2, 4'd0, 6'd1, `KV_GROUP_SIZE_SUBBANK, 1'b0);

    @(posedge clk);
    flush_valid <= 1'b1;
    flush_req_id <= 4'h3;
    flush_branch_mask <= BRANCH1_MASK;
    flush_node_mask <= BR1_NODE1_MASK;

    @(posedge clk);
    flush_valid <= 1'b0;

    expect_dequeue(4'h3, 2'd0, 4'd0, 6'd0, `KV_GROUP_SIZE_SUBBANK, 1'b0);
    expect_dequeue(4'h4, 2'd2, 4'd0, 6'd1, `KV_GROUP_SIZE_SUBBANK, 1'b0);

    #1;
    if (deq_valid) begin
        $fatal(1, "queue should be empty after dequeuing surviving entries");
    end

    $display("tb_prefetch_queue_selective_flush PASS");
    $finish;
end

endmodule
