`include "config/interface_params.vh"
`timescale 1ns/1ps

module HHTContextPredictor #(
    parameter integer CONF_W = 8,
    parameter integer HISTORY_LEN = 2,
    parameter integer SET_NUM = 2,
    parameter integer WAY_NUM = 2,
    parameter integer LRU_W = 16,
    parameter [CONF_W-1:0] CONF_MIN = {{(CONF_W-1){1'b0}}, 1'b1}
) (
    input                           clk,
    input                           rst_n,
    input                           admission_enable,
    input                           accept_valid,
    input      [`NODE_ID_W-1:0]     accept_parent_node_id,
    input      [`TOKEN_ID_W-1:0]    accept_token_id,
    input      [`POSITION_ID_W-1:0] accept_position,
    output                          cand_valid,
    output     [`NODE_ID_W-1:0]     cand_parent_node_id,
    output     [`TOKEN_ID_W-1:0]    cand_token_id,
    output     [`TOKEN_ID_W-1:0]    cand_referenced_token_id,
    output     [`POSITION_ID_W-1:0] cand_referenced_position,
    output     [CONF_W-1:0]         cand_confidence,

    // Speculative lookup (read-only, does not modify internal state)
    input      [`TOKEN_ID_W-1:0]    spec_token_0,
    input      [`TOKEN_ID_W-1:0]    spec_token_1,
    input                           spec_query_valid,
    output                          spec_hit,
    output     [`TOKEN_ID_W-1:0]    spec_prediction
);

localparam integer SET_INDEX_W =
    (SET_NUM <= 2) ? 1 : $clog2(SET_NUM);
localparam integer WAY_INDEX_W =
    (WAY_NUM <= 2) ? 1 : $clog2(WAY_NUM);
localparam integer ENTRY_NUM = SET_NUM * WAY_NUM;
localparam integer ENTRY_INDEX_W =
    (ENTRY_NUM <= 2) ? 1 : $clog2(ENTRY_NUM);
localparam integer TAG_W = `TOKEN_ID_W - SET_INDEX_W;
localparam integer HISTORY_COUNT_W =
    (HISTORY_LEN <= 2) ? 2 : $clog2(HISTORY_LEN + 1);
localparam [HISTORY_COUNT_W-1:0] HISTORY_LEN_W = HISTORY_LEN;
localparam [HISTORY_COUNT_W-1:0] HISTORY_COUNT_ONE_W =
    {{(HISTORY_COUNT_W-1){1'b0}}, 1'b1};

reg [HISTORY_COUNT_W-1:0] history_count_r;
reg [`TOKEN_ID_W-1:0] history_token_0_r;
reg [`TOKEN_ID_W-1:0] history_token_1_r;
reg [`POSITION_ID_W-1:0] history_position_0_r;
reg [`POSITION_ID_W-1:0] history_position_1_r;
reg [`NODE_ID_W-1:0] history_parent_0_r;
reg [`NODE_ID_W-1:0] history_parent_1_r;

// Entry storage: packed vectors (avoids VCS unpacked array sensitivity bug)
reg [ENTRY_NUM-1:0]                    entry_valid_r;
reg [ENTRY_NUM*TAG_W-1:0]              entry_tag_r;
reg [ENTRY_NUM*`TOKEN_ID_W-1:0]        entry_prediction_r;
reg [ENTRY_NUM*CONF_W-1:0]             entry_confidence_r;
reg [ENTRY_NUM*LRU_W-1:0]              entry_last_use_r;
reg [LRU_W-1:0] lru_counter_r;

reg lookup_hit_w;
reg [ENTRY_INDEX_W-1:0] lookup_hit_index_w;
reg victim_found_w;
reg [ENTRY_INDEX_W-1:0] victim_index_w;
reg invalid_found_w;
reg [ENTRY_INDEX_W-1:0] invalid_index_w;
reg [LRU_W-1:0] victim_lru_w;

integer set_way_idx;
integer lookup_entry_idx;

wire history_full_w;
wire [`TOKEN_ID_W-1:0] lookup_hash_w;
wire [SET_INDEX_W-1:0] lookup_set_w;
wire [TAG_W-1:0] lookup_tag_w;
wire [LRU_W-1:0] next_lru_w;

function [`TOKEN_ID_W-1:0] context_hash;
    input [`TOKEN_ID_W-1:0] older_token_i;
    input [`TOKEN_ID_W-1:0] newer_token_i;
    begin
        context_hash =
            older_token_i ^
            {newer_token_i[`TOKEN_ID_W-2:0], newer_token_i[`TOKEN_ID_W-1]};
    end
endfunction

function [CONF_W-1:0] saturating_increment;
    input [CONF_W-1:0] value_i;
    begin
        if (&value_i) begin
            saturating_increment = value_i;
        end else begin
            saturating_increment = value_i + {{(CONF_W-1){1'b0}}, 1'b1};
        end
    end
endfunction

function [CONF_W-1:0] floor_decrement;
    input [CONF_W-1:0] value_i;
    begin
        if (value_i > CONF_MIN) begin
            floor_decrement = value_i - {{(CONF_W-1){1'b0}}, 1'b1};
        end else begin
            floor_decrement = CONF_MIN;
        end
    end
endfunction

assign history_full_w = (history_count_r == HISTORY_LEN_W);
assign lookup_hash_w = context_hash(history_token_0_r, history_token_1_r);
assign lookup_set_w = lookup_hash_w[0 +: SET_INDEX_W];
assign lookup_tag_w = lookup_hash_w[SET_INDEX_W +: TAG_W];
assign next_lru_w = lru_counter_r + {{(LRU_W-1){1'b0}}, 1'b1};

always @* begin
    lookup_hit_w = 1'b0;
    lookup_hit_index_w = {ENTRY_INDEX_W{1'b0}};
    victim_found_w = 1'b0;
    victim_index_w = {ENTRY_INDEX_W{1'b0}};
    invalid_found_w = 1'b0;
    invalid_index_w = {ENTRY_INDEX_W{1'b0}};
    victim_lru_w = {LRU_W{1'b0}};

    for (set_way_idx = 0; set_way_idx < WAY_NUM; set_way_idx = set_way_idx + 1) begin
        lookup_entry_idx = (lookup_set_w * WAY_NUM) + set_way_idx;

        if (history_full_w &&
            entry_valid_r[lookup_entry_idx] &&
            (entry_tag_r[lookup_entry_idx*TAG_W +: TAG_W] == lookup_tag_w) &&
            !lookup_hit_w) begin
            lookup_hit_w = 1'b1;
            lookup_hit_index_w = lookup_entry_idx[ENTRY_INDEX_W-1:0];
        end

        if (!entry_valid_r[lookup_entry_idx] && !invalid_found_w) begin
            invalid_found_w = 1'b1;
            invalid_index_w = lookup_entry_idx[ENTRY_INDEX_W-1:0];
        end

        if (!victim_found_w ||
            (entry_last_use_r[lookup_entry_idx*LRU_W +: LRU_W] < victim_lru_w)) begin
            victim_found_w = 1'b1;
            victim_index_w = lookup_entry_idx[ENTRY_INDEX_W-1:0];
            victim_lru_w = entry_last_use_r[lookup_entry_idx*LRU_W +: LRU_W];
        end
    end
end

assign cand_valid =
    admission_enable &&
    history_full_w &&
    lookup_hit_w &&
    (entry_confidence_r[lookup_hit_index_w*CONF_W +: CONF_W] >= CONF_MIN);

// synthesis translate_off
always @(posedge clk) begin
    if (admission_enable && history_full_w && !cand_valid)
        $display("[HHT] cand_valid=0: hit=%b hash=%h set=%0d tag=%h hist=[%0d,%0d]",
            lookup_hit_w, lookup_hash_w, lookup_set_w, lookup_tag_w,
            history_token_0_r, history_token_1_r);
    if (accept_valid && history_full_w)
        $display("[HHT] accept: token=%0d hist=[%0d,%0d] hash=%h set=%0d hit=%b",
            accept_token_id, history_token_0_r, history_token_1_r,
            lookup_hash_w, lookup_set_w, lookup_hit_w);
end
// synthesis translate_on

// =========================================================================
// Speculative lookup: combinational read-only query into the table
// tree_builder uses this to explore multi-level predictions without
// modifying HHT internal state.
// =========================================================================
wire [`TOKEN_ID_W-1:0] spec_hash_w = context_hash(spec_token_0, spec_token_1);
wire [SET_INDEX_W-1:0] spec_set_w = spec_hash_w[0 +: SET_INDEX_W];
wire [TAG_W-1:0] spec_tag_w = spec_hash_w[SET_INDEX_W +: TAG_W];

// Speculative lookup: registered output (avoids VCS always @* sensitivity bug with unpacked arrays)
reg spec_hit_r;
reg [`TOKEN_ID_W-1:0] spec_prediction_r;

integer spec_i;
always @(posedge clk or negedge rst_n) begin : spec_lookup_blk
    if (!rst_n) begin
        spec_hit_r <= 1'b0;
        spec_prediction_r <= {`TOKEN_ID_W{1'b0}};
    end else begin
        spec_hit_r <= 1'b0;
        spec_prediction_r <= {`TOKEN_ID_W{1'b0}};
        if (spec_query_valid) begin
            // synthesis translate_off
            $display("[HHT_SPEC] query: t0=%0d t1=%0d hash=%h set=%0d tag=%h",
                spec_token_0, spec_token_1, spec_hash_w, spec_set_w, spec_tag_w);
            // synthesis translate_on
            for (spec_i = 0; spec_i < ENTRY_NUM; spec_i = spec_i + 1) begin
                if (entry_valid_r[spec_i] &&
                    ((spec_i / WAY_NUM) == spec_set_w) &&
                    (entry_tag_r[spec_i*TAG_W +: TAG_W] == spec_tag_w) &&
                    (entry_confidence_r[spec_i*CONF_W +: CONF_W] >= CONF_MIN)) begin
                    spec_hit_r <= 1'b1;
                    spec_prediction_r <= entry_prediction_r[spec_i*`TOKEN_ID_W +: `TOKEN_ID_W];
                end
            end
        end
    end
end

assign spec_hit = spec_hit_r;
assign spec_prediction = spec_prediction_r;
assign cand_parent_node_id =
    cand_valid ? history_parent_1_r : {`NODE_ID_W{1'b0}};
assign cand_token_id =
    cand_valid ? entry_prediction_r[lookup_hit_index_w*`TOKEN_ID_W +: `TOKEN_ID_W] :
                 {`TOKEN_ID_W{1'b0}};
assign cand_referenced_token_id =
    cand_valid ? history_token_1_r : {`TOKEN_ID_W{1'b0}};
assign cand_referenced_position =
    cand_valid ? history_position_1_r : {`POSITION_ID_W{1'b0}};
assign cand_confidence =
    cand_valid ? entry_confidence_r[lookup_hit_index_w*CONF_W +: CONF_W] : {CONF_W{1'b0}};

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        history_count_r <= {HISTORY_COUNT_W{1'b0}};
        history_token_0_r <= {`TOKEN_ID_W{1'b0}};
        history_token_1_r <= {`TOKEN_ID_W{1'b0}};
        history_position_0_r <= {`POSITION_ID_W{1'b0}};
        history_position_1_r <= {`POSITION_ID_W{1'b0}};
        history_parent_0_r <= {`NODE_ID_W{1'b0}};
        history_parent_1_r <= {`NODE_ID_W{1'b0}};
        lru_counter_r <= {LRU_W{1'b0}};
        entry_valid_r <= {ENTRY_NUM{1'b0}};
        entry_tag_r <= {(ENTRY_NUM*TAG_W){1'b0}};
        entry_prediction_r <= {(ENTRY_NUM*`TOKEN_ID_W){1'b0}};
        entry_confidence_r <= {(ENTRY_NUM*CONF_W){1'b0}};
        entry_last_use_r <= {(ENTRY_NUM*LRU_W){1'b0}};
    end else if (accept_valid) begin
        if (history_full_w) begin
            lru_counter_r <= next_lru_w;
            if (lookup_hit_w) begin
                entry_valid_r[lookup_hit_index_w] <= 1'b1;
                entry_tag_r[lookup_hit_index_w*TAG_W +: TAG_W] <= lookup_tag_w;
                if (entry_prediction_r[lookup_hit_index_w*`TOKEN_ID_W +: `TOKEN_ID_W] == accept_token_id) begin
                    // Prediction matches: boost confidence
                    entry_confidence_r[lookup_hit_index_w*CONF_W +: CONF_W] <=
                        saturating_increment(
                            entry_confidence_r[lookup_hit_index_w*CONF_W +: CONF_W]);
                end else begin
                    // Prediction mismatch: decrement confidence only, keep prediction
                    entry_confidence_r[lookup_hit_index_w*CONF_W +: CONF_W] <=
                        floor_decrement(
                            entry_confidence_r[lookup_hit_index_w*CONF_W +: CONF_W]);
                end
                entry_last_use_r[lookup_hit_index_w*LRU_W +: LRU_W] <= next_lru_w;
            end else if (invalid_found_w) begin
                entry_valid_r[invalid_index_w] <= 1'b1;
                entry_tag_r[invalid_index_w*TAG_W +: TAG_W] <= lookup_tag_w;
                entry_prediction_r[invalid_index_w*`TOKEN_ID_W +: `TOKEN_ID_W] <= accept_token_id;
                entry_confidence_r[invalid_index_w*CONF_W +: CONF_W] <= CONF_MIN;
                entry_last_use_r[invalid_index_w*LRU_W +: LRU_W] <= next_lru_w;
            end else begin
                entry_valid_r[victim_index_w] <= 1'b1;
                entry_tag_r[victim_index_w*TAG_W +: TAG_W] <= lookup_tag_w;
                entry_prediction_r[victim_index_w*`TOKEN_ID_W +: `TOKEN_ID_W] <= accept_token_id;
                entry_confidence_r[victim_index_w*CONF_W +: CONF_W] <= CONF_MIN;
                entry_last_use_r[victim_index_w*LRU_W +: LRU_W] <= next_lru_w;
            end
        end

        if (history_count_r == {HISTORY_COUNT_W{1'b0}}) begin
            history_token_1_r <= accept_token_id;
            history_position_1_r <= accept_position;
            history_parent_1_r <= accept_parent_node_id;
            history_count_r <= HISTORY_COUNT_ONE_W;
        end else if (history_count_r == HISTORY_COUNT_ONE_W) begin
            history_token_0_r <= history_token_1_r;
            history_position_0_r <= history_position_1_r;
            history_parent_0_r <= history_parent_1_r;
            history_token_1_r <= accept_token_id;
            history_position_1_r <= accept_position;
            history_parent_1_r <= accept_parent_node_id;
            history_count_r <= HISTORY_LEN_W;
        end else begin
            history_token_0_r <= history_token_1_r;
            history_position_0_r <= history_position_1_r;
            history_parent_0_r <= history_parent_1_r;
            history_token_1_r <= accept_token_id;
            history_position_1_r <= accept_position;
            history_parent_1_r <= accept_parent_node_id;
        end
    end
end

endmodule
