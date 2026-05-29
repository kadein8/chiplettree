`timescale 1ns/1ps

`include "config/prediction_params.vh"
`include "config/interface_params.vh"

module prediction_unit_bounded_stub #(
    parameter integer CFG_W = 32
) (
    input                            clk,
    input                            rst_n,
    input                            scenario_start,
    input                            scenario_reentry_mode,
    input                            scenario_second_flush_mode,
    input                            scenario_second_flush_writeback_mode,
    input                            scenario_third_flush_mode,
    input                            scenario_variable_len_token_writeback_mode,
    input                            scenario_dual_tree_near_steady_state_mode,
    input  [1:0]                     scenario_dual_tree_flush_target,
    input                            scenario_tree_driven_strict_serial_mode,
    input  [7:0]                     scenario_tree_descriptor_id,
    input                            tree_req_ready,
    input                            tree_in_ready,
    input                            prep_done,
    input                            victim_seen,
    input                            survivor_read_done,
    output reg                       tree_req_valid,
    output reg [`REQ_ID_W-1:0]       tree_req_id,
    output reg [`TREE_MAX_PREFIX_NODES-1:0] src_prefix_slot_valid,
    output reg [`TREE_MAX_PREFIX_NODES*`NODE_ID_W-1:0] src_prefix_node_id,
    output reg [`TREE_MAX_FRONTIER_LEVELS-1:0] src_frontier_level_valid,
    output reg [`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS-1:0]
                                   src_frontier_slot_valid,
    output reg [`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0]
                                   src_frontier_node_id,
    output reg [`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0]
                                   src_frontier_parent_node_id,
    output reg                       tree_in_valid,
    output reg [`REQ_ID_W-1:0]       tree_in_req_id,
    output reg [`BRANCH_ID_W-1:0]    tree_in_branch_id,
    output reg [`NODE_ID_W-1:0]      tree_in_node_id,
    output reg [`REQ_ID_W-1:0]       cmp_req_id,
    output reg [`BRANCH_NUM-1:0]     cmp_slot_valid,
    output reg [`BRANCH_NUM*`TOKEN_ID_W-1:0] cmp_slot_real_token_id,
    output reg [`BRANCH_NUM*`TOKEN_ID_W-1:0] cmp_slot_candidate_token_id,
    output reg [`BRANCH_NUM*`NODE_ID_W-1:0]  cmp_slot_node_id,
    output reg [`BRANCH_NUM*`NODE_ID_W-1:0]  cmp_slot_parent_node_id,
    output reg [`BRANCH_NUM*`BRANCH_ID_W-1:0] cmp_slot_branch_id,
    output reg                       flush_done,
    output reg                       tree_verify_done,
    output reg [2:0]                 effective_flush_count,
    output reg                       stale_event_drop_seen
);

localparam [`REQ_ID_W-1:0] TREE_REQ_ID = 4'h9;
localparam [`REQ_ID_W-1:0] FLUSH_REQ_ID = 4'ha;
localparam [`NODE_ID_W-1:0] TREE_PREFIX_NODE_ID = 4'h1;
localparam [`NODE_ID_W-1:0] TREE_FRONTIER_NODE_ID = 4'h3;
localparam [`BRANCH_ID_W-1:0] VICTIM_BRANCH_ID = 2'd1;
localparam [`NODE_ID_W-1:0] VICTIM_NODE_ID = 4'd2;

localparam [2:0] STATE_IDLE        = 3'd0;
localparam [2:0] STATE_ISSUE_TREE  = 3'd1;
localparam [2:0] STATE_ISSUE_VICT  = 3'd2;
localparam [2:0] STATE_WAIT_FLUSH  = 3'd3;
localparam [2:0] STATE_ISSUE_FLUSH = 3'd4;
localparam [2:0] STATE_DONE        = 3'd5;
localparam [2:0] STATE_POST_FLUSH  = 3'd6;

reg [2:0] state_r;
reg [1:0] flush_count_r;
reg victim_seen_q;
reg [1:0] victim_pulse_count_r;
reg survivor_read_done_q;
reg [1:0] survivor_pulse_count_r;

function [1:0] tree_desc_flush_target;
    input [7:0] descriptor_id_i;
    begin
        case (descriptor_id_i)
            8'd0: tree_desc_flush_target = 2'd0;
            8'd1: tree_desc_flush_target = 2'd1;
            8'd2: tree_desc_flush_target = 2'd1;
            8'd3: tree_desc_flush_target = 2'd1;
            default: tree_desc_flush_target = 2'd2;
        endcase
    end
endfunction

function [1:0] tree_desc_survivor_target;
    input [7:0] descriptor_id_i;
    begin
        case (descriptor_id_i)
            8'd0: tree_desc_survivor_target = 2'd1;
            8'd1: tree_desc_survivor_target = 2'd2;
            8'd2: tree_desc_survivor_target = 2'd2;
            8'd3: tree_desc_survivor_target = 2'd2;
            default: tree_desc_survivor_target = 2'd3;
        endcase
    end
endfunction

function [`NODE_ID_W-1:0] tree_desc_prefix_node;
    input [7:0] descriptor_id_i;
    begin
        case (descriptor_id_i)
            8'd0: tree_desc_prefix_node = 4'h1;
            8'd1: tree_desc_prefix_node = 4'h1;
            8'd2: tree_desc_prefix_node = 4'h2;
            8'd3: tree_desc_prefix_node = 4'h2;
            default: tree_desc_prefix_node = 4'h3;
        endcase
    end
endfunction

function [`NODE_ID_W-1:0] tree_desc_frontier_node;
    input [7:0] descriptor_id_i;
    begin
        case (descriptor_id_i)
            8'd0: tree_desc_frontier_node = 4'h3;
            8'd1: tree_desc_frontier_node = 4'h4;
            8'd2: tree_desc_frontier_node = 4'h5;
            8'd3: tree_desc_frontier_node = 4'h6;
            default: tree_desc_frontier_node = 4'h7;
        endcase
    end
endfunction

function [`NODE_ID_W-1:0] tree_desc_frontier_parent_node;
    input [7:0] descriptor_id_i;
    begin
        tree_desc_frontier_parent_node = tree_desc_prefix_node(descriptor_id_i);
    end
endfunction

always @* begin
    tree_req_valid = 1'b0;
    tree_req_id = TREE_REQ_ID;
    src_prefix_slot_valid = {`TREE_MAX_PREFIX_NODES{1'b0}};
    src_prefix_node_id = {(`TREE_MAX_PREFIX_NODES*`NODE_ID_W){1'b0}};
    src_frontier_level_valid = {`TREE_MAX_FRONTIER_LEVELS{1'b0}};
    src_frontier_slot_valid =
        {(`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS){1'b0}};
    src_frontier_node_id =
        {(`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`NODE_ID_W){1'b0}};
    src_frontier_parent_node_id =
        {(`TREE_MAX_FRONTIER_LEVELS*`TREE_FRONTIER_SLOTS*`NODE_ID_W){1'b0}};
    tree_in_valid = 1'b0;
    tree_in_req_id = FLUSH_REQ_ID;
    tree_in_branch_id = VICTIM_BRANCH_ID;
    tree_in_node_id = VICTIM_NODE_ID;
    cmp_req_id = FLUSH_REQ_ID;
    cmp_slot_valid = {`BRANCH_NUM{1'b0}};
    cmp_slot_real_token_id = {(`BRANCH_NUM*`TOKEN_ID_W){1'b0}};
    cmp_slot_candidate_token_id = {(`BRANCH_NUM*`TOKEN_ID_W){1'b0}};
    cmp_slot_node_id = {(`BRANCH_NUM*`NODE_ID_W){1'b0}};
    cmp_slot_parent_node_id = {(`BRANCH_NUM*`NODE_ID_W){1'b0}};
    cmp_slot_branch_id = {(`BRANCH_NUM*`BRANCH_ID_W){1'b0}};

    case (state_r)
        STATE_ISSUE_TREE: begin
            tree_req_valid = 1'b1;
            src_prefix_slot_valid[0] = 1'b1;
            src_prefix_node_id[0 +: `NODE_ID_W] =
                scenario_tree_driven_strict_serial_mode ?
                    tree_desc_prefix_node(scenario_tree_descriptor_id) :
                    TREE_PREFIX_NODE_ID;
            src_frontier_level_valid[0] = 1'b1;
            src_frontier_slot_valid[0] = 1'b1;
            src_frontier_node_id[0 +: `NODE_ID_W] =
                scenario_tree_driven_strict_serial_mode ?
                    tree_desc_frontier_node(scenario_tree_descriptor_id) :
                    ((scenario_dual_tree_near_steady_state_mode &&
                      (scenario_dual_tree_flush_target == 2'd2)) ? 4'h5 :
                                                                   TREE_FRONTIER_NODE_ID);
            src_frontier_parent_node_id[0 +: `NODE_ID_W] =
                scenario_tree_driven_strict_serial_mode ?
                    tree_desc_frontier_parent_node(scenario_tree_descriptor_id) :
                    TREE_PREFIX_NODE_ID;
        end

        STATE_ISSUE_VICT: begin
            tree_in_valid = 1'b1;
            if (scenario_dual_tree_near_steady_state_mode ||
                scenario_tree_driven_strict_serial_mode) begin
                tree_in_branch_id = flush_count_r + 1'b1;
            end
        end

        STATE_ISSUE_FLUSH: begin
            cmp_slot_valid[0] = 1'b1;
            cmp_slot_real_token_id[0 +: `TOKEN_ID_W] = 16'h0101;
            cmp_slot_candidate_token_id[0 +: `TOKEN_ID_W] = 16'h0202;
            cmp_slot_node_id[0 +: `NODE_ID_W] = VICTIM_NODE_ID;
            cmp_slot_parent_node_id[0 +: `NODE_ID_W] =
                scenario_tree_driven_strict_serial_mode ?
                    tree_desc_frontier_parent_node(scenario_tree_descriptor_id) :
                    TREE_PREFIX_NODE_ID;
            cmp_slot_branch_id[0 +: `BRANCH_ID_W] =
                (scenario_dual_tree_near_steady_state_mode ||
                 scenario_tree_driven_strict_serial_mode) ?
                    (flush_count_r + 1'b1) :
                    VICTIM_BRANCH_ID;
        end

        default: begin
        end
    endcase
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state_r <= STATE_IDLE;
        flush_done <= 1'b0;
        flush_count_r <= 2'b00;
        victim_seen_q <= 1'b0;
        victim_pulse_count_r <= 2'b00;
        survivor_read_done_q <= 1'b0;
        survivor_pulse_count_r <= 2'b00;
        tree_verify_done <= 1'b0;
        effective_flush_count <= 3'b000;
        stale_event_drop_seen <= 1'b0;
    end else begin
        victim_seen_q <= victim_seen;
        if (scenario_dual_tree_near_steady_state_mode &&
            victim_seen &&
            !victim_seen_q &&
            (victim_pulse_count_r != 2'b11)) begin
            victim_pulse_count_r <= victim_pulse_count_r + 1'b1;
        end

        survivor_read_done_q <= survivor_read_done;
        if ((scenario_dual_tree_near_steady_state_mode ||
             scenario_tree_driven_strict_serial_mode) &&
            survivor_read_done &&
            !survivor_read_done_q &&
            (survivor_pulse_count_r != 2'b11)) begin
            survivor_pulse_count_r <= survivor_pulse_count_r + 1'b1;
        end

        if (scenario_dual_tree_near_steady_state_mode &&
            flush_done &&
            (state_r != STATE_ISSUE_FLUSH) &&
            (state_r != STATE_DONE)) begin
            flush_done <= 1'b0;
        end

        if (scenario_start) begin
            state_r <= STATE_ISSUE_TREE;
            flush_done <= 1'b0;
            flush_count_r <= 2'b00;
            victim_seen_q <= 1'b0;
            victim_pulse_count_r <= 2'b00;
            survivor_read_done_q <= 1'b0;
            survivor_pulse_count_r <= 2'b00;
            tree_verify_done <= 1'b0;
            effective_flush_count <= 3'b000;
            stale_event_drop_seen <= 1'b0;
        end else begin
            case (state_r)
                STATE_IDLE: begin
                end

                STATE_ISSUE_TREE: begin
                    if (tree_req_ready) begin
                        if (scenario_tree_driven_strict_serial_mode) begin
                            if (tree_desc_flush_target(
                                    scenario_tree_descriptor_id) == 2'd0) begin
                                state_r <= STATE_WAIT_FLUSH;
                            end else begin
                                state_r <= STATE_ISSUE_VICT;
                            end
                        end else if (scenario_dual_tree_near_steady_state_mode) begin
                            state_r <= STATE_ISSUE_VICT;
                        end else if (scenario_variable_len_token_writeback_mode) begin
                            state_r <= STATE_DONE;
                            tree_verify_done <= 1'b1;
                        end else if (scenario_reentry_mode &&
                            !scenario_second_flush_mode &&
                            !scenario_second_flush_writeback_mode &&
                            !scenario_third_flush_mode) begin
                            state_r <= STATE_DONE;
                            tree_verify_done <= 1'b1;
                        end else begin
                            state_r <= STATE_ISSUE_VICT;
                        end
                    end
                end

                STATE_ISSUE_VICT: begin
                    if (tree_in_ready) begin
                        state_r <= STATE_WAIT_FLUSH;
                    end
                end

                STATE_WAIT_FLUSH: begin
                    if (scenario_tree_driven_strict_serial_mode) begin
                        if ((flush_count_r ==
                             tree_desc_flush_target(
                                 scenario_tree_descriptor_id)) &&
                            (survivor_pulse_count_r >=
                             tree_desc_survivor_target(
                                 scenario_tree_descriptor_id))) begin
                            state_r <= STATE_DONE;
                            tree_verify_done <= 1'b1;
                            stale_event_drop_seen <=
                                (scenario_tree_descriptor_id == 8'd3);
                        end else if ((flush_count_r <
                                      tree_desc_flush_target(
                                          scenario_tree_descriptor_id)) &&
                                     (survivor_pulse_count_r >
                                      flush_count_r)) begin
                            state_r <= STATE_ISSUE_FLUSH;
                        end
                    end else if (scenario_dual_tree_near_steady_state_mode &&
                        prep_done &&
                        (victim_pulse_count_r > flush_count_r) &&
                        (survivor_pulse_count_r > flush_count_r)) begin
                        state_r <= STATE_ISSUE_FLUSH;
                    end else if (!scenario_dual_tree_near_steady_state_mode &&
                        prep_done &&
                        victim_seen &&
                        (!(scenario_second_flush_mode ||
                           scenario_second_flush_writeback_mode ||
                           scenario_third_flush_mode) ||
                         survivor_read_done)) begin
                        state_r <= STATE_ISSUE_FLUSH;
                    end
                end

                STATE_ISSUE_FLUSH: begin
                    flush_done <= 1'b1;
                    effective_flush_count <= effective_flush_count + 1'b1;
                    if (scenario_tree_driven_strict_serial_mode) begin
                        flush_count_r <= flush_count_r + 1'b1;
                        state_r <= STATE_POST_FLUSH;
                    end else if (scenario_dual_tree_near_steady_state_mode) begin
                        flush_count_r <= flush_count_r + 1'b1;
                        if ((flush_count_r + 1'b1) >=
                            scenario_dual_tree_flush_target) begin
                            state_r <= STATE_DONE;
                            tree_verify_done <= 1'b1;
                            stale_event_drop_seen <=
                                scenario_tree_driven_strict_serial_mode &&
                                (scenario_tree_descriptor_id == 8'd3);
                        end else begin
                            state_r <= STATE_ISSUE_VICT;
                        end
                    end else begin
                        state_r <= STATE_DONE;
                        tree_verify_done <= 1'b1;
                        stale_event_drop_seen <=
                            scenario_tree_driven_strict_serial_mode &&
                            (scenario_tree_descriptor_id == 8'd3);
                    end
                end

                STATE_POST_FLUSH: begin
                    flush_done <= 1'b0;
                    state_r <= STATE_ISSUE_VICT;
                end

                STATE_DONE: begin
                end

                default: begin
                    state_r <= STATE_IDLE;
                end
            endcase
        end
    end
end

endmodule
