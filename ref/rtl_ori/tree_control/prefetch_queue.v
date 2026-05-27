`timescale 1ns/1ps

`include "config/prediction_params.vh"
`include "config/interface_params.vh"
`include "config/memory_params.vh"

module prefetch_queue (
    input                       clk,
    input                       rst_n,
    input                       enq_valid,
    output                      enq_ready,
    input  [`REQ_ID_W-1:0]      enq_req_id,
    input  [`BRANCH_ID_W-1:0]   enq_branch_id,
    input  [`NODE_ID_W-1:0]     enq_node_id,
    input  [`LAYER_ID_W-1:0]    enq_layer_id,
    input  [`KV_GROUP_LEN_W-1:0] enq_size_subbank,
    input                       enq_shared,
    input                       flush_valid,
    input  [`REQ_ID_W-1:0]      flush_req_id,
    input  [`BRANCH_MASK_W-1:0] flush_branch_mask,
    input  [`NODE_MASK_W-1:0]   flush_node_mask,
    output                      deq_valid,
    input                       deq_ready,
    output [`REQ_ID_W-1:0]      deq_req_id,
    output [`BRANCH_ID_W-1:0]   deq_branch_id,
    output [`NODE_ID_W-1:0]     deq_node_id,
    output [`LAYER_ID_W-1:0]    deq_layer_id,
    output [`KV_GROUP_LEN_W-1:0] deq_size_subbank,
    output                      deq_shared
);

localparam integer PREFETCH_Q_COUNT_W =
    ((`PREFETCH_Q_DEPTH <= 1) ? 1 : $clog2(`PREFETCH_Q_DEPTH + 1));

reg                          entry_valid_r [0:`PREFETCH_Q_DEPTH-1];
reg [`REQ_ID_W-1:0]          entry_req_id_r [0:`PREFETCH_Q_DEPTH-1];
reg [`BRANCH_ID_W-1:0]       entry_branch_id_r [0:`PREFETCH_Q_DEPTH-1];
reg [`NODE_ID_W-1:0]         entry_node_id_r [0:`PREFETCH_Q_DEPTH-1];
reg [`LAYER_ID_W-1:0]        entry_layer_id_r [0:`PREFETCH_Q_DEPTH-1];
reg [`KV_GROUP_LEN_W-1:0]    entry_size_subbank_r [0:`PREFETCH_Q_DEPTH-1];
reg                          entry_shared_r [0:`PREFETCH_Q_DEPTH-1];
reg [PREFETCH_Q_COUNT_W-1:0] entry_count_r;

reg                          entry_valid_n [0:`PREFETCH_Q_DEPTH-1];
reg [`REQ_ID_W-1:0]          entry_req_id_n [0:`PREFETCH_Q_DEPTH-1];
reg [`BRANCH_ID_W-1:0]       entry_branch_id_n [0:`PREFETCH_Q_DEPTH-1];
reg [`NODE_ID_W-1:0]         entry_node_id_n [0:`PREFETCH_Q_DEPTH-1];
reg [`LAYER_ID_W-1:0]        entry_layer_id_n [0:`PREFETCH_Q_DEPTH-1];
reg [`KV_GROUP_LEN_W-1:0]    entry_size_subbank_n [0:`PREFETCH_Q_DEPTH-1];
reg                          entry_shared_n [0:`PREFETCH_Q_DEPTH-1];
reg [PREFETCH_Q_COUNT_W-1:0] entry_count_n;

reg deq_valid_comb;
reg [`REQ_ID_W-1:0] deq_req_id_comb;
reg [`BRANCH_ID_W-1:0] deq_branch_id_comb;
reg [`NODE_ID_W-1:0] deq_node_id_comb;
reg [`LAYER_ID_W-1:0] deq_layer_id_comb;
reg [`KV_GROUP_LEN_W-1:0] deq_size_subbank_comb;
reg deq_shared_comb;

integer slot_i;
integer pack_idx_i;
integer node_mask_index_i;
reg branch_hit_comb;
reg node_hit_comb;

assign enq_ready = (entry_count_r < `PREFETCH_Q_DEPTH);
assign deq_valid = deq_valid_comb;
assign deq_req_id = deq_req_id_comb;
assign deq_branch_id = deq_branch_id_comb;
assign deq_node_id = deq_node_id_comb;
assign deq_layer_id = deq_layer_id_comb;
assign deq_size_subbank = deq_size_subbank_comb;
assign deq_shared = deq_shared_comb;

always @* begin
    deq_valid_comb = (entry_count_r != {PREFETCH_Q_COUNT_W{1'b0}});
    deq_req_id_comb = {`REQ_ID_W{1'b0}};
    deq_branch_id_comb = {`BRANCH_ID_W{1'b0}};
    deq_node_id_comb = {`NODE_ID_W{1'b0}};
    deq_layer_id_comb = {`LAYER_ID_W{1'b0}};
    deq_size_subbank_comb = {`KV_GROUP_LEN_W{1'b0}};
    deq_shared_comb = 1'b0;

    if (entry_count_r != {PREFETCH_Q_COUNT_W{1'b0}}) begin
        deq_req_id_comb = entry_req_id_r[0];
        deq_branch_id_comb = entry_branch_id_r[0];
        deq_node_id_comb = entry_node_id_r[0];
        deq_layer_id_comb = entry_layer_id_r[0];
        deq_size_subbank_comb = entry_size_subbank_r[0];
        deq_shared_comb = entry_shared_r[0];
    end
end

always @* begin
    for (slot_i = 0; slot_i < `PREFETCH_Q_DEPTH; slot_i = slot_i + 1) begin
        entry_valid_n[slot_i] = 1'b0;
        entry_req_id_n[slot_i] = {`REQ_ID_W{1'b0}};
        entry_branch_id_n[slot_i] = {`BRANCH_ID_W{1'b0}};
        entry_node_id_n[slot_i] = {`NODE_ID_W{1'b0}};
        entry_layer_id_n[slot_i] = {`LAYER_ID_W{1'b0}};
        entry_size_subbank_n[slot_i] = {`KV_GROUP_LEN_W{1'b0}};
        entry_shared_n[slot_i] = 1'b0;
    end

    pack_idx_i = 0;
    for (slot_i = 0; slot_i < `PREFETCH_Q_DEPTH; slot_i = slot_i + 1) begin
        if (entry_valid_r[slot_i]) begin
            branch_hit_comb = 1'b0;
            node_hit_comb = 1'b0;
            node_mask_index_i =
                (entry_branch_id_r[slot_i] * `MAX_VERIFY_NODES_PER_BRANCH) +
                entry_node_id_r[slot_i];

            if (flush_valid &&
                (entry_req_id_r[slot_i] == flush_req_id) &&
                (entry_branch_id_r[slot_i] < `BRANCH_NUM) &&
                flush_branch_mask[entry_branch_id_r[slot_i]]) begin
                branch_hit_comb = 1'b1;
            end

            if (branch_hit_comb &&
                (node_mask_index_i >= 0) &&
                (node_mask_index_i < `NODE_MASK_W) &&
                flush_node_mask[node_mask_index_i]) begin
                node_hit_comb = 1'b1;
            end

            if (!(flush_valid && branch_hit_comb && node_hit_comb)) begin
                if (!(deq_ready && deq_valid_comb && (slot_i == 0) && !flush_valid)) begin
                    entry_valid_n[pack_idx_i] = 1'b1;
                    entry_req_id_n[pack_idx_i] = entry_req_id_r[slot_i];
                    entry_branch_id_n[pack_idx_i] = entry_branch_id_r[slot_i];
                    entry_node_id_n[pack_idx_i] = entry_node_id_r[slot_i];
                    entry_layer_id_n[pack_idx_i] = entry_layer_id_r[slot_i];
                    entry_size_subbank_n[pack_idx_i] =
                        entry_size_subbank_r[slot_i];
                    entry_shared_n[pack_idx_i] = entry_shared_r[slot_i];
                    pack_idx_i = pack_idx_i + 1;
                end
            end
        end
    end

    if (enq_valid && enq_ready) begin
        entry_valid_n[pack_idx_i] = 1'b1;
        entry_req_id_n[pack_idx_i] = enq_req_id;
        entry_branch_id_n[pack_idx_i] = enq_branch_id;
        entry_node_id_n[pack_idx_i] = enq_node_id;
        entry_layer_id_n[pack_idx_i] = enq_layer_id;
        entry_size_subbank_n[pack_idx_i] = enq_size_subbank;
        entry_shared_n[pack_idx_i] = enq_shared;
        pack_idx_i = pack_idx_i + 1;
    end

    entry_count_n = pack_idx_i[PREFETCH_Q_COUNT_W-1:0];
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        entry_count_r <= {PREFETCH_Q_COUNT_W{1'b0}};
        for (slot_i = 0; slot_i < `PREFETCH_Q_DEPTH; slot_i = slot_i + 1) begin
            entry_valid_r[slot_i] <= 1'b0;
            entry_req_id_r[slot_i] <= {`REQ_ID_W{1'b0}};
            entry_branch_id_r[slot_i] <= {`BRANCH_ID_W{1'b0}};
            entry_node_id_r[slot_i] <= {`NODE_ID_W{1'b0}};
            entry_layer_id_r[slot_i] <= {`LAYER_ID_W{1'b0}};
            entry_size_subbank_r[slot_i] <= {`KV_GROUP_LEN_W{1'b0}};
            entry_shared_r[slot_i] <= 1'b0;
        end
    end else begin
        entry_count_r <= entry_count_n;
        for (slot_i = 0; slot_i < `PREFETCH_Q_DEPTH; slot_i = slot_i + 1) begin
            entry_valid_r[slot_i] <= entry_valid_n[slot_i];
            entry_req_id_r[slot_i] <= entry_req_id_n[slot_i];
            entry_branch_id_r[slot_i] <= entry_branch_id_n[slot_i];
            entry_node_id_r[slot_i] <= entry_node_id_n[slot_i];
            entry_layer_id_r[slot_i] <= entry_layer_id_n[slot_i];
            entry_size_subbank_r[slot_i] <= entry_size_subbank_n[slot_i];
            entry_shared_r[slot_i] <= entry_shared_n[slot_i];
        end
    end
end

endmodule
