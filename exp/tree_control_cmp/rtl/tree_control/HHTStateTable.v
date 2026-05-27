`include "config/interface_params.vh"
`timescale 1ns/1ps

module HHTStateTable #(
    parameter integer CONF_W = 8,
    parameter integer ENTRY_NUM = 4,
    parameter integer HIT_COUNT_W = 8,
    parameter integer LRU_W = 16,
    parameter integer ENTRY_INDEX_W =
        (ENTRY_NUM <= 2) ? 1 : $clog2(ENTRY_NUM)
) (
    input clk,
    input rst_n,

    input probe_valid,
    input [`NODE_ID_W-1:0] probe_parent_node_id,
    input [`TOKEN_ID_W-1:0] probe_token_id,
    input [`TOKEN_ID_W-1:0] probe_referenced_token_id,
    input [`POSITION_ID_W-1:0] probe_referenced_position,
    output probe_hit,
    output [ENTRY_INDEX_W-1:0] probe_hit_index,

    input accept_hit_valid,
    input [ENTRY_INDEX_W-1:0] accept_hit_index,

    input update_valid,
    input [`NODE_ID_W-1:0] update_parent_node_id,
    input [`TOKEN_ID_W-1:0] update_token_id,
    input [`TOKEN_ID_W-1:0] update_referenced_token_id,
    input [`POSITION_ID_W-1:0] update_referenced_position,
    input [CONF_W-1:0] update_confidence
);

reg entry_valid_r [0:ENTRY_NUM-1];
reg [`NODE_ID_W-1:0] entry_parent_node_id_r [0:ENTRY_NUM-1];
reg [`TOKEN_ID_W-1:0] entry_token_id_r [0:ENTRY_NUM-1];
reg [`TOKEN_ID_W-1:0] entry_referenced_token_id_r [0:ENTRY_NUM-1];
reg [`POSITION_ID_W-1:0] entry_referenced_position_r [0:ENTRY_NUM-1];
reg [CONF_W-1:0] entry_confidence_r [0:ENTRY_NUM-1];
reg [HIT_COUNT_W-1:0] entry_hit_count_r [0:ENTRY_NUM-1];
reg [LRU_W-1:0] entry_last_use_r [0:ENTRY_NUM-1];
reg [LRU_W-1:0] lru_counter_r;

reg probe_hit_r;
reg [ENTRY_INDEX_W-1:0] probe_hit_index_r;

reg update_match_found_w;
reg [ENTRY_INDEX_W-1:0] update_match_index_w;
reg free_slot_found_w;
reg [ENTRY_INDEX_W-1:0] free_slot_index_w;
reg [ENTRY_INDEX_W-1:0] lru_victim_index_w;
reg [LRU_W-1:0] lru_victim_value_w;
reg [ENTRY_INDEX_W-1:0] update_target_index_w;

integer entry_idx;

function entry_key_match;
    input entry_valid_i;
    input [`NODE_ID_W-1:0] entry_parent_node_id_i;
    input [`TOKEN_ID_W-1:0] entry_token_id_i;
    input [`TOKEN_ID_W-1:0] entry_referenced_token_id_i;
    input [`POSITION_ID_W-1:0] entry_referenced_position_i;
    input [`NODE_ID_W-1:0] key_parent_node_id_i;
    input [`TOKEN_ID_W-1:0] key_token_id_i;
    input [`TOKEN_ID_W-1:0] key_referenced_token_id_i;
    input [`POSITION_ID_W-1:0] key_referenced_position_i;
    begin
        entry_key_match =
            entry_valid_i &&
            (entry_parent_node_id_i == key_parent_node_id_i) &&
            (entry_token_id_i == key_token_id_i) &&
            (entry_referenced_token_id_i == key_referenced_token_id_i) &&
            (entry_referenced_position_i == key_referenced_position_i);
    end
endfunction

assign probe_hit = probe_hit_r;
assign probe_hit_index = probe_hit_index_r;

always @* begin
    probe_hit_r = 1'b0;
    probe_hit_index_r = {ENTRY_INDEX_W{1'b0}};
    for (entry_idx = 0; entry_idx < ENTRY_NUM; entry_idx = entry_idx + 1) begin
        if (probe_valid &&
            !probe_hit_r &&
            entry_key_match(
                entry_valid_r[entry_idx],
                entry_parent_node_id_r[entry_idx],
                entry_token_id_r[entry_idx],
                entry_referenced_token_id_r[entry_idx],
                entry_referenced_position_r[entry_idx],
                probe_parent_node_id,
                probe_token_id,
                probe_referenced_token_id,
                probe_referenced_position)) begin
            probe_hit_r = 1'b1;
            probe_hit_index_r = entry_idx[ENTRY_INDEX_W-1:0];
        end
    end
end

always @* begin
    update_match_found_w = 1'b0;
    update_match_index_w = {ENTRY_INDEX_W{1'b0}};
    free_slot_found_w = 1'b0;
    free_slot_index_w = {ENTRY_INDEX_W{1'b0}};
    lru_victim_index_w = {ENTRY_INDEX_W{1'b0}};
    lru_victim_value_w = {LRU_W{1'b0}};
    update_target_index_w = {ENTRY_INDEX_W{1'b0}};

    for (entry_idx = 0; entry_idx < ENTRY_NUM; entry_idx = entry_idx + 1) begin
        if (!update_match_found_w &&
            entry_key_match(
                entry_valid_r[entry_idx],
                entry_parent_node_id_r[entry_idx],
                entry_token_id_r[entry_idx],
                entry_referenced_token_id_r[entry_idx],
                entry_referenced_position_r[entry_idx],
                update_parent_node_id,
                update_token_id,
                update_referenced_token_id,
                update_referenced_position)) begin
            update_match_found_w = 1'b1;
            update_match_index_w = entry_idx[ENTRY_INDEX_W-1:0];
        end

        if (!free_slot_found_w && !entry_valid_r[entry_idx]) begin
            free_slot_found_w = 1'b1;
            free_slot_index_w = entry_idx[ENTRY_INDEX_W-1:0];
        end

        if ((entry_idx == 0) ||
            (entry_last_use_r[entry_idx] < lru_victim_value_w)) begin
            lru_victim_value_w = entry_last_use_r[entry_idx];
            lru_victim_index_w = entry_idx[ENTRY_INDEX_W-1:0];
        end
    end

    if (update_match_found_w) begin
        update_target_index_w = update_match_index_w;
    end else if (free_slot_found_w) begin
        update_target_index_w = free_slot_index_w;
    end else begin
        update_target_index_w = lru_victim_index_w;
    end
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        lru_counter_r <= {LRU_W{1'b0}};
        for (entry_idx = 0; entry_idx < ENTRY_NUM; entry_idx = entry_idx + 1) begin
            entry_valid_r[entry_idx] <= 1'b0;
            entry_parent_node_id_r[entry_idx] <= {`NODE_ID_W{1'b0}};
            entry_token_id_r[entry_idx] <= {`TOKEN_ID_W{1'b0}};
            entry_referenced_token_id_r[entry_idx] <= {`TOKEN_ID_W{1'b0}};
            entry_referenced_position_r[entry_idx] <= {`POSITION_ID_W{1'b0}};
            entry_confidence_r[entry_idx] <= {CONF_W{1'b0}};
            entry_hit_count_r[entry_idx] <= {HIT_COUNT_W{1'b0}};
            entry_last_use_r[entry_idx] <= {LRU_W{1'b0}};
        end
    end else if (update_valid) begin
        lru_counter_r <= lru_counter_r + {{(LRU_W-1){1'b0}}, 1'b1};
        entry_valid_r[update_target_index_w] <= 1'b1;
        entry_parent_node_id_r[update_target_index_w] <= update_parent_node_id;
        entry_token_id_r[update_target_index_w] <= update_token_id;
        entry_referenced_token_id_r[update_target_index_w] <=
            update_referenced_token_id;
        entry_referenced_position_r[update_target_index_w] <=
            update_referenced_position;
        entry_confidence_r[update_target_index_w] <= update_confidence;
        if (!update_match_found_w) begin
            entry_hit_count_r[update_target_index_w] <= {HIT_COUNT_W{1'b0}};
        end
        entry_last_use_r[update_target_index_w] <=
            lru_counter_r + {{(LRU_W-1){1'b0}}, 1'b1};
    end else if (accept_hit_valid && entry_valid_r[accept_hit_index]) begin
        lru_counter_r <= lru_counter_r + {{(LRU_W-1){1'b0}}, 1'b1};
        entry_hit_count_r[accept_hit_index] <=
            entry_hit_count_r[accept_hit_index] +
            {{(HIT_COUNT_W-1){1'b0}}, 1'b1};
        entry_last_use_r[accept_hit_index] <=
            lru_counter_r + {{(LRU_W-1){1'b0}}, 1'b1};
    end
end

endmodule
