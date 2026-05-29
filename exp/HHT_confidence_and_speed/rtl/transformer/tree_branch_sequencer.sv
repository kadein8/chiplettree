`include "config/interface_params.vh"
`include "config/prediction_params.vh"
`timescale 1ns/1ps

module tree_branch_sequencer #(
    parameter integer BRANCH_NUM = `BRANCH_NUM,
    parameter integer BRANCH_ID_W = `BRANCH_ID_W,
    parameter integer TOKEN_ID_W = `TOKEN_ID_W,
    parameter integer MAX_PREFIX = `MAX_SHARED_PREFIX_NODES
) (
    input  logic                               clk,
    input  logic                               rst_n,

    input  logic                               cfg_valid,
    output logic                               cfg_ready,
    input  logic [BRANCH_NUM-1:0]              cfg_branch_valid,
    input  logic                               cfg_tree_mask_en,
    input  logic [15:0]                        cfg_prefix_len,
    input  logic [BRANCH_NUM*TOKEN_ID_W-1:0]   cfg_token_ids,
    input  logic [BRANCH_NUM*BRANCH_ID_W-1:0]  cfg_branch_ids,

    output logic                               issue_valid,
    input  logic                               issue_ready,
    output logic [TOKEN_ID_W-1:0]              issue_token_id,
    output logic [BRANCH_ID_W-1:0]             issue_branch_id,
    output logic                               issue_tree_mask_en,
    output logic [15:0]                        issue_prefix_len,
    output logic                               issue_prefix_kv_cached,

    input  logic                               result_valid,
    output logic                               result_ready,

    output logic                               all_branches_done,
    output logic [BRANCH_NUM-1:0]              completed_branches
);

localparam logic [2:0]
    ST_IDLE         = 3'd0,
    ST_ISSUE        = 3'd1,
    ST_WAIT_COMPUTE = 3'd2,
    ST_NEXT_BRANCH  = 3'd3,
    ST_DONE         = 3'd4;

logic [2:0] state_r;
logic [BRANCH_NUM-1:0] branch_valid_r;
logic [BRANCH_NUM*TOKEN_ID_W-1:0] token_ids_r;
logic [BRANCH_NUM*BRANCH_ID_W-1:0] branch_ids_r;
logic tree_mask_en_r;
logic [15:0] prefix_len_r;
logic [BRANCH_NUM-1:0] completed_branches_r;
logic prefix_cached_r;
logic [$clog2(BRANCH_NUM)-1:0] current_idx_r;
logic [$clog2(BRANCH_NUM)-1:0] next_idx_w;
logic found_next_w;

integer branch_i;

assign issue_valid = (state_r == ST_ISSUE);
assign cfg_ready = (state_r == ST_IDLE) || (state_r == ST_DONE);
assign issue_token_id =
    token_ids_r[(current_idx_r*TOKEN_ID_W) +: TOKEN_ID_W];
assign issue_branch_id =
    branch_ids_r[(current_idx_r*BRANCH_ID_W) +: BRANCH_ID_W];
assign issue_tree_mask_en = tree_mask_en_r;
assign issue_prefix_len = prefix_len_r;
assign issue_prefix_kv_cached = prefix_cached_r;
assign result_ready = (state_r == ST_WAIT_COMPUTE);
assign completed_branches = completed_branches_r;
assign all_branches_done = (state_r == ST_DONE);

always_comb begin
    next_idx_w = current_idx_r;
    found_next_w = 1'b0;

    for (branch_i = 0; branch_i < BRANCH_NUM; branch_i = branch_i + 1) begin
        if ((branch_i > current_idx_r) &&
            branch_valid_r[branch_i] &&
            !completed_branches_r[branch_i] &&
            !found_next_w) begin
            next_idx_w = branch_i[$clog2(BRANCH_NUM)-1:0];
            found_next_w = 1'b1;
        end
    end

    if (!found_next_w) begin
        for (branch_i = 0; branch_i < BRANCH_NUM; branch_i = branch_i + 1) begin
            if (branch_valid_r[branch_i] &&
                !completed_branches_r[branch_i] &&
                !found_next_w) begin
                next_idx_w = branch_i[$clog2(BRANCH_NUM)-1:0];
                found_next_w = 1'b1;
            end
        end
    end
end

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state_r <= ST_IDLE;
        branch_valid_r <= '0;
        token_ids_r <= '0;
        branch_ids_r <= '0;
        tree_mask_en_r <= 1'b0;
        prefix_len_r <= 16'd0;
        completed_branches_r <= '0;
        prefix_cached_r <= 1'b0;
        current_idx_r <= '0;
    end else begin
        case (state_r)
            ST_IDLE: begin
                if (cfg_valid) begin
                    branch_valid_r <= cfg_branch_valid;
                    token_ids_r <= cfg_token_ids;
                    branch_ids_r <= cfg_branch_ids;
                    tree_mask_en_r <= cfg_tree_mask_en;
                    prefix_len_r <= cfg_prefix_len;
                    completed_branches_r <= '0;
                    prefix_cached_r <= 1'b0;
                    current_idx_r <= '0;
                    if (cfg_branch_valid[0]) begin
                        state_r <= ST_ISSUE;
                    end else begin
                        state_r <= ST_NEXT_BRANCH;
                    end
                end
            end

            ST_ISSUE: begin
                if (issue_valid && issue_ready) begin
                    state_r <= ST_WAIT_COMPUTE;
                end
            end

            ST_WAIT_COMPUTE: begin
                if (result_valid && result_ready) begin
                    completed_branches_r[current_idx_r] <= 1'b1;
                    prefix_cached_r <= 1'b1;
                    state_r <= ST_NEXT_BRANCH;
                end
            end

            ST_NEXT_BRANCH: begin
                if (found_next_w) begin
                    current_idx_r <= next_idx_w;
                    state_r <= ST_ISSUE;
                end else begin
                    state_r <= ST_DONE;
                end
            end

            ST_DONE: begin
                if (cfg_valid) begin
                    branch_valid_r <= cfg_branch_valid;
                    token_ids_r <= cfg_token_ids;
                    branch_ids_r <= cfg_branch_ids;
                    tree_mask_en_r <= cfg_tree_mask_en;
                    prefix_len_r <= cfg_prefix_len;
                    completed_branches_r <= '0;
                    prefix_cached_r <= 1'b0;
                    current_idx_r <= '0;
                    if (cfg_branch_valid[0]) begin
                        state_r <= ST_ISSUE;
                    end else begin
                        state_r <= ST_NEXT_BRANCH;
                    end
                end else begin
                    state_r <= ST_DONE;
                end
            end

            default: begin
                state_r <= ST_IDLE;
            end
        endcase
    end
end

endmodule
