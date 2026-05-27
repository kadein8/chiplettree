`timescale 1ns/1ps

`include "config/prediction_params.vh"
`include "config/interface_params.vh"

module comparator #(
    parameter integer PRIVATE_DEPTH_W =
        (((`MAX_VERIFY_NODES_PER_BRANCH + 1) <= 2) ? 1 :
         $clog2(`MAX_VERIFY_NODES_PER_BRANCH + 1)),
    parameter integer BRANCH_EPOCH_W = 2,
    parameter integer BRANCH_PATH_PACK_W =
        (`BRANCH_NUM * `MAX_VERIFY_NODES_PER_BRANCH * `NODE_ID_W),
    parameter integer BRANCH_DEPTH_PACK_W = (`BRANCH_NUM * PRIVATE_DEPTH_W),
    parameter integer BRANCH_EPOCH_PACK_W = (`BRANCH_NUM * BRANCH_EPOCH_W)
) (
    input                         clk,
    input                         rst_n,
    input  [`REQ_ID_W-1:0]        cmp_req_id,
    input  [`BRANCH_NUM-1:0]      cmp_slot_valid,
    input  [`BRANCH_NUM*`TOKEN_ID_W-1:0] cmp_slot_real_token_id,
    input  [`BRANCH_NUM*`TOKEN_ID_W-1:0] cmp_slot_candidate_token_id,
    input  [`BRANCH_NUM*`NODE_ID_W-1:0]  cmp_slot_node_id,
    input  [`BRANCH_NUM*`NODE_ID_W-1:0]  cmp_slot_parent_node_id,
    input  [`BRANCH_NUM*`BRANCH_ID_W-1:0] cmp_slot_branch_id,
    input                         reduce_start_valid,
    input  [`REQ_ID_W-1:0]        reduce_req_id,
    input  [`BRANCH_NUM-1:0]      active_branch_valid,
    input  [BRANCH_EPOCH_PACK_W-1:0] active_branch_epoch,
    input  [BRANCH_DEPTH_PACK_W-1:0] active_branch_depth,
    input  [BRANCH_PATH_PACK_W-1:0] active_branch_node_id,
    input  [BRANCH_PATH_PACK_W-1:0] active_branch_parent_node_id,
    input  [`BRANCH_NUM-1:0]      result_slot_valid,
    input  [`REQ_ID_W-1:0]        result_req_id,
    input  [`BRANCH_NUM*`BRANCH_ID_W-1:0] result_branch_id,
    input  [BRANCH_EPOCH_PACK_W-1:0] result_branch_epoch,
    input  [BRANCH_DEPTH_PACK_W-1:0] result_private_depth,
    input  [`BRANCH_NUM*`NODE_ID_W-1:0] result_node_id,
    input  [`BRANCH_NUM*`NODE_ID_W-1:0] result_parent_node_id,
    input  [`BRANCH_NUM-1:0]      result_accept,
    output                        commit_valid,
    output [`BRANCH_MASK_W-1:0]   commit_branch_mask,
    output [`NODE_MASK_W-1:0]     commit_node_mask,
    output                        flush_valid,
    output [`BRANCH_MASK_W-1:0]   flush_branch_mask,
    output [`NODE_MASK_W-1:0]     flush_node_mask,
    output                        accepted_prefix_valid,
    output [`REQ_ID_W-1:0]        accepted_prefix_req_id,
    output [PRIVATE_DEPTH_W-1:0]  accepted_prefix_depth,
    output [(`MAX_VERIFY_NODES_PER_BRANCH*`NODE_ID_W)-1:0] accepted_prefix_node_id,
    output [`BRANCH_NUM-1:0]      live_branch_mask,
    output [`BRANCH_NUM-1:0]      prune_branch_mask
);

reg commit_valid_comb;
reg [`BRANCH_MASK_W-1:0] commit_branch_mask_comb;
reg [`NODE_MASK_W-1:0] commit_node_mask_comb;
reg flush_valid_comb;
reg [`BRANCH_MASK_W-1:0] flush_branch_mask_comb;
reg [`NODE_MASK_W-1:0] flush_node_mask_comb;

reg [`TOKEN_ID_W-1:0] slot_real_token_id_comb;
reg [`TOKEN_ID_W-1:0] slot_candidate_token_id_comb;
reg [`NODE_ID_W-1:0] slot_node_id_comb;
reg [`BRANCH_ID_W-1:0] slot_branch_id_comb;
reg slot_token_match_comb;

reg [`REQ_ID_W-1:0] current_req_id_state;
reg [`BRANCH_NUM-1:0] live_branch_mask_state;
reg [BRANCH_EPOCH_PACK_W-1:0] branch_epoch_state;
reg [BRANCH_DEPTH_PACK_W-1:0] branch_depth_state;
reg [BRANCH_PATH_PACK_W-1:0] branch_node_id_state;
reg [BRANCH_PATH_PACK_W-1:0] branch_parent_node_id_state;
reg accepted_prefix_valid_state;
reg [PRIVATE_DEPTH_W-1:0] accepted_prefix_depth_state;
reg [(`MAX_VERIFY_NODES_PER_BRANCH*`NODE_ID_W)-1:0] accepted_prefix_node_id_state;

reg [`REQ_ID_W-1:0] base_req_id_comb;
reg [`BRANCH_NUM-1:0] base_live_branch_mask_comb;
reg [BRANCH_EPOCH_PACK_W-1:0] base_branch_epoch_comb;
reg [BRANCH_DEPTH_PACK_W-1:0] base_branch_depth_comb;
reg [BRANCH_PATH_PACK_W-1:0] base_branch_node_id_comb;
reg [BRANCH_PATH_PACK_W-1:0] base_branch_parent_node_id_comb;
reg base_accepted_prefix_valid_comb;
reg [PRIVATE_DEPTH_W-1:0] base_accepted_prefix_depth_comb;
reg [(`MAX_VERIFY_NODES_PER_BRANCH*`NODE_ID_W)-1:0] base_accepted_prefix_node_id_comb;

reg [`REQ_ID_W-1:0] next_req_id_comb;
reg [`BRANCH_NUM-1:0] next_live_branch_mask_comb;
reg [BRANCH_EPOCH_PACK_W-1:0] next_branch_epoch_comb;
reg [BRANCH_DEPTH_PACK_W-1:0] next_branch_depth_comb;
reg [BRANCH_PATH_PACK_W-1:0] next_branch_node_id_comb;
reg [BRANCH_PATH_PACK_W-1:0] next_branch_parent_node_id_comb;
reg next_accepted_prefix_valid_comb;
reg [PRIVATE_DEPTH_W-1:0] next_accepted_prefix_depth_comb;
reg [(`MAX_VERIFY_NODES_PER_BRANCH*`NODE_ID_W)-1:0] next_accepted_prefix_node_id_comb;

reg accepted_update_found_comb;
reg [`BRANCH_ID_W-1:0] accepted_branch_id_comb;
reg [PRIVATE_DEPTH_W-1:0] accepted_result_depth_comb;
reg [BRANCH_EPOCH_W-1:0] accepted_result_epoch_comb;
reg [`NODE_ID_W-1:0] accepted_result_node_id_comb;
reg [`NODE_ID_W-1:0] accepted_result_parent_node_id_comb;
reg result_req_id_matches_state_comb;
reg branch_is_compatible_comb;
reg branch_epoch_match_comb;

integer slot_i;
integer result_slot_i;
integer branch_i;
integer depth_i;

function [`BRANCH_MASK_W-1:0] branch_onehot_mask;
    input [`BRANCH_ID_W-1:0] branch_id_in;
    begin
        branch_onehot_mask = {`BRANCH_MASK_W{1'b0}};
        if (branch_id_in < `BRANCH_NUM) begin
            branch_onehot_mask[branch_id_in] = 1'b1;
        end
    end
endfunction

function [`NODE_MASK_W-1:0] node_onehot_mask;
    input [`BRANCH_ID_W-1:0] branch_id_in;
    input [`NODE_ID_W-1:0] node_id_in;
    integer bit_index_i;
    begin
        node_onehot_mask = {`NODE_MASK_W{1'b0}};
        bit_index_i = (branch_id_in * `MAX_VERIFY_NODES_PER_BRANCH) + node_id_in;
        if ((branch_id_in < `BRANCH_NUM) &&
            (node_id_in < `MAX_VERIFY_NODES_PER_BRANCH) &&
            (bit_index_i < `NODE_MASK_W)) begin
            node_onehot_mask[bit_index_i] = 1'b1;
        end
    end
endfunction

function [PRIVATE_DEPTH_W-1:0] branch_depth_of;
    input [BRANCH_DEPTH_PACK_W-1:0] depth_bus_in;
    input [`BRANCH_ID_W-1:0] branch_id_in;
    begin
        branch_depth_of = depth_bus_in[(branch_id_in*PRIVATE_DEPTH_W) +: PRIVATE_DEPTH_W];
    end
endfunction

function [BRANCH_EPOCH_W-1:0] branch_epoch_of;
    input [BRANCH_EPOCH_PACK_W-1:0] epoch_bus_in;
    input [`BRANCH_ID_W-1:0] branch_id_in;
    begin
        branch_epoch_of = epoch_bus_in[(branch_id_in*BRANCH_EPOCH_W) +: BRANCH_EPOCH_W];
    end
endfunction

function [`NODE_ID_W-1:0] branch_path_node_of;
    input [BRANCH_PATH_PACK_W-1:0] path_bus_in;
    input [`BRANCH_ID_W-1:0] branch_id_in;
    input integer depth_idx_in;
    begin
        branch_path_node_of =
            path_bus_in[(((branch_id_in*`MAX_VERIFY_NODES_PER_BRANCH) + depth_idx_in)*`NODE_ID_W) +: `NODE_ID_W];
    end
endfunction

always @* begin
    commit_valid_comb = 1'b0;
    commit_branch_mask_comb = {`BRANCH_MASK_W{1'b0}};
    commit_node_mask_comb = {`NODE_MASK_W{1'b0}};
    flush_valid_comb = 1'b0;
    flush_branch_mask_comb = {`BRANCH_MASK_W{1'b0}};
    flush_node_mask_comb = {`NODE_MASK_W{1'b0}};

    slot_real_token_id_comb = {`TOKEN_ID_W{1'b0}};
    slot_candidate_token_id_comb = {`TOKEN_ID_W{1'b0}};
    slot_node_id_comb = {`NODE_ID_W{1'b0}};
    slot_branch_id_comb = {`BRANCH_ID_W{1'b0}};
    slot_token_match_comb = 1'b0;

    for (slot_i = 0; slot_i < `BRANCH_NUM; slot_i = slot_i + 1) begin
        if (cmp_slot_valid[slot_i]) begin
            slot_real_token_id_comb =
                cmp_slot_real_token_id[(slot_i*`TOKEN_ID_W) +: `TOKEN_ID_W];
            slot_candidate_token_id_comb =
                cmp_slot_candidate_token_id[(slot_i*`TOKEN_ID_W) +: `TOKEN_ID_W];
            slot_node_id_comb =
                cmp_slot_node_id[(slot_i*`NODE_ID_W) +: `NODE_ID_W];
            slot_branch_id_comb =
                cmp_slot_branch_id[(slot_i*`BRANCH_ID_W) +: `BRANCH_ID_W];
            slot_token_match_comb =
                (cmp_slot_real_token_id[(slot_i*`TOKEN_ID_W) +: `TOKEN_ID_W] ==
                 cmp_slot_candidate_token_id[(slot_i*`TOKEN_ID_W) +: `TOKEN_ID_W]);

            if (slot_token_match_comb) begin
                commit_valid_comb = 1'b1;
                commit_branch_mask_comb =
                    commit_branch_mask_comb | branch_onehot_mask(slot_branch_id_comb);
                commit_node_mask_comb =
                    commit_node_mask_comb | node_onehot_mask(slot_branch_id_comb, slot_node_id_comb);
            end else begin
                flush_valid_comb = 1'b1;
                flush_branch_mask_comb =
                    flush_branch_mask_comb | branch_onehot_mask(slot_branch_id_comb);
                flush_node_mask_comb =
                    flush_node_mask_comb | node_onehot_mask(slot_branch_id_comb, slot_node_id_comb);
            end
        end
    end
end

always @* begin
    base_req_id_comb = current_req_id_state;
    base_live_branch_mask_comb = live_branch_mask_state;
    base_branch_epoch_comb = branch_epoch_state;
    base_branch_depth_comb = branch_depth_state;
    base_branch_node_id_comb = branch_node_id_state;
    base_branch_parent_node_id_comb = branch_parent_node_id_state;
    base_accepted_prefix_valid_comb = accepted_prefix_valid_state;
    base_accepted_prefix_depth_comb = accepted_prefix_depth_state;
    base_accepted_prefix_node_id_comb = accepted_prefix_node_id_state;

    if (reduce_start_valid === 1'b1) begin
        base_req_id_comb = reduce_req_id;
        base_live_branch_mask_comb = active_branch_valid;
        base_branch_epoch_comb = active_branch_epoch;
        base_branch_depth_comb = active_branch_depth;
        base_branch_node_id_comb = active_branch_node_id;
        base_branch_parent_node_id_comb = active_branch_parent_node_id;
        base_accepted_prefix_valid_comb = 1'b0;
        base_accepted_prefix_depth_comb = {PRIVATE_DEPTH_W{1'b0}};
        base_accepted_prefix_node_id_comb =
            {(`MAX_VERIFY_NODES_PER_BRANCH*`NODE_ID_W){1'b0}};
    end

    next_req_id_comb = base_req_id_comb;
    next_live_branch_mask_comb = base_live_branch_mask_comb;
    next_branch_epoch_comb = base_branch_epoch_comb;
    next_branch_depth_comb = base_branch_depth_comb;
    next_branch_node_id_comb = base_branch_node_id_comb;
    next_branch_parent_node_id_comb = base_branch_parent_node_id_comb;
    next_accepted_prefix_valid_comb = base_accepted_prefix_valid_comb;
    next_accepted_prefix_depth_comb = base_accepted_prefix_depth_comb;
    next_accepted_prefix_node_id_comb = base_accepted_prefix_node_id_comb;

    accepted_update_found_comb = 1'b0;
    accepted_branch_id_comb = {`BRANCH_ID_W{1'b0}};
    accepted_result_depth_comb = {PRIVATE_DEPTH_W{1'b0}};
    accepted_result_epoch_comb = {BRANCH_EPOCH_W{1'b0}};
    accepted_result_node_id_comb = {`NODE_ID_W{1'b0}};
    accepted_result_parent_node_id_comb = {`NODE_ID_W{1'b0}};
    result_req_id_matches_state_comb = 1'b1;

    if (!(^result_req_id === 1'bx)) begin
        result_req_id_matches_state_comb = (result_req_id == base_req_id_comb);
    end

    for (result_slot_i = 0; result_slot_i < `BRANCH_NUM; result_slot_i = result_slot_i + 1) begin
        if ((result_slot_valid[result_slot_i] === 1'b1) &&
            result_req_id_matches_state_comb &&
            (result_accept[result_slot_i] === 1'b1) &&
            (result_branch_id[(result_slot_i*`BRANCH_ID_W) +: `BRANCH_ID_W] < `BRANCH_NUM) &&
            (base_live_branch_mask_comb[result_branch_id[(result_slot_i*`BRANCH_ID_W) +: `BRANCH_ID_W]] === 1'b1) &&
            (result_private_depth[(result_slot_i*PRIVATE_DEPTH_W) +: PRIVATE_DEPTH_W] != {PRIVATE_DEPTH_W{1'b0}}) &&
            (result_private_depth[(result_slot_i*PRIVATE_DEPTH_W) +: PRIVATE_DEPTH_W] <=
             branch_depth_of(
                 base_branch_depth_comb,
                 result_branch_id[(result_slot_i*`BRANCH_ID_W) +: `BRANCH_ID_W]
             )) &&
            (result_branch_epoch[(result_slot_i*BRANCH_EPOCH_W) +: BRANCH_EPOCH_W] ==
             branch_epoch_of(
                 base_branch_epoch_comb,
                 result_branch_id[(result_slot_i*`BRANCH_ID_W) +: `BRANCH_ID_W]
             )) &&
            (result_node_id[(result_slot_i*`NODE_ID_W) +: `NODE_ID_W] ==
             branch_path_node_of(
                 base_branch_node_id_comb,
                 result_branch_id[(result_slot_i*`BRANCH_ID_W) +: `BRANCH_ID_W],
                 result_private_depth[(result_slot_i*PRIVATE_DEPTH_W) +: PRIVATE_DEPTH_W] - 1
             ))) begin
            if ((!accepted_update_found_comb) ||
                (result_private_depth[(result_slot_i*PRIVATE_DEPTH_W) +: PRIVATE_DEPTH_W] >
                 accepted_result_depth_comb)) begin
                accepted_update_found_comb = 1'b1;
                accepted_branch_id_comb =
                    result_branch_id[(result_slot_i*`BRANCH_ID_W) +: `BRANCH_ID_W];
                accepted_result_depth_comb =
                    result_private_depth[(result_slot_i*PRIVATE_DEPTH_W) +: PRIVATE_DEPTH_W];
                accepted_result_epoch_comb =
                    result_branch_epoch[(result_slot_i*BRANCH_EPOCH_W) +: BRANCH_EPOCH_W];
                accepted_result_node_id_comb =
                    result_node_id[(result_slot_i*`NODE_ID_W) +: `NODE_ID_W];
                accepted_result_parent_node_id_comb =
                    result_parent_node_id[(result_slot_i*`NODE_ID_W) +: `NODE_ID_W];
            end
        end
    end

    if (accepted_update_found_comb) begin
        next_accepted_prefix_valid_comb = 1'b1;
        next_accepted_prefix_depth_comb = accepted_result_depth_comb;
        next_accepted_prefix_node_id_comb =
            {(`MAX_VERIFY_NODES_PER_BRANCH*`NODE_ID_W){1'b0}};

        for (depth_i = 0; depth_i < `MAX_VERIFY_NODES_PER_BRANCH; depth_i = depth_i + 1) begin
            if (depth_i < accepted_result_depth_comb) begin
                next_accepted_prefix_node_id_comb[(depth_i*`NODE_ID_W) +: `NODE_ID_W] =
                    branch_path_node_of(base_branch_node_id_comb, accepted_branch_id_comb, depth_i);
            end
        end

        next_live_branch_mask_comb = {`BRANCH_NUM{1'b0}};

        for (branch_i = 0; branch_i < `BRANCH_NUM; branch_i = branch_i + 1) begin
            branch_is_compatible_comb = 1'b0;
            branch_epoch_match_comb = 1'b0;

            if (base_live_branch_mask_comb[branch_i] === 1'b1) begin
                branch_epoch_match_comb =
                    (base_branch_epoch_comb[(branch_i*BRANCH_EPOCH_W) +: BRANCH_EPOCH_W] ==
                     accepted_result_epoch_comb);
                branch_is_compatible_comb = branch_epoch_match_comb;

                if (branch_depth_of(base_branch_depth_comb, branch_i) <
                    accepted_result_depth_comb) begin
                    branch_is_compatible_comb = 1'b0;
                end

                if (branch_is_compatible_comb) begin
                    for (depth_i = 0; depth_i < `MAX_VERIFY_NODES_PER_BRANCH; depth_i = depth_i + 1) begin
                        if (depth_i < accepted_result_depth_comb) begin
                            if (branch_path_node_of(
                                    base_branch_node_id_comb,
                                    branch_i,
                                    depth_i
                                ) !=
                                next_accepted_prefix_node_id_comb[(depth_i*`NODE_ID_W) +: `NODE_ID_W]) begin
                                branch_is_compatible_comb = 1'b0;
                            end
                        end
                    end
                end

                if (branch_is_compatible_comb) begin
                    next_live_branch_mask_comb[branch_i] = 1'b1;
                end
            end
        end
    end
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        current_req_id_state <= {`REQ_ID_W{1'b0}};
        live_branch_mask_state <= {`BRANCH_NUM{1'b0}};
        branch_epoch_state <= {BRANCH_EPOCH_PACK_W{1'b0}};
        branch_depth_state <= {BRANCH_DEPTH_PACK_W{1'b0}};
        branch_node_id_state <= {BRANCH_PATH_PACK_W{1'b0}};
        branch_parent_node_id_state <= {BRANCH_PATH_PACK_W{1'b0}};
        accepted_prefix_valid_state <= 1'b0;
        accepted_prefix_depth_state <= {PRIVATE_DEPTH_W{1'b0}};
        accepted_prefix_node_id_state <=
            {(`MAX_VERIFY_NODES_PER_BRANCH*`NODE_ID_W){1'b0}};
    end else begin
        current_req_id_state <= next_req_id_comb;
        live_branch_mask_state <= next_live_branch_mask_comb;
        branch_epoch_state <= next_branch_epoch_comb;
        branch_depth_state <= next_branch_depth_comb;
        branch_node_id_state <= next_branch_node_id_comb;
        branch_parent_node_id_state <= next_branch_parent_node_id_comb;
        accepted_prefix_valid_state <= next_accepted_prefix_valid_comb;
        accepted_prefix_depth_state <= next_accepted_prefix_depth_comb;
        accepted_prefix_node_id_state <= next_accepted_prefix_node_id_comb;
    end
end

assign commit_valid = commit_valid_comb;
assign commit_branch_mask = commit_branch_mask_comb;
assign commit_node_mask = commit_node_mask_comb;
assign flush_valid = flush_valid_comb;
assign flush_branch_mask = flush_branch_mask_comb;
assign flush_node_mask = flush_node_mask_comb;

assign accepted_prefix_valid = next_accepted_prefix_valid_comb;
assign accepted_prefix_req_id = next_req_id_comb;
assign accepted_prefix_depth = next_accepted_prefix_depth_comb;
assign accepted_prefix_node_id = next_accepted_prefix_node_id_comb;
assign live_branch_mask = next_live_branch_mask_comb;
assign prune_branch_mask = base_live_branch_mask_comb & (~next_live_branch_mask_comb);

endmodule
