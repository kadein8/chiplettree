module PredictionWindowSerialDispatcher #(
    parameter integer CFG_W = 32,
    parameter integer WINDOW_BRANCH_SLOTS = `TREE_FRONTIER_SLOTS,
    parameter integer SOURCE_ID_W = 3,
    parameter integer CONF_W = 8,
    parameter integer SLOT_IDX_W =
        (WINDOW_BRANCH_SLOTS <= 2) ? 1 : $clog2(WINDOW_BRANCH_SLOTS)
) (
    input                             clk,
    input                             rst_n,

    input                             session_cfg_valid,
    input      [CFG_W-1:0]            session_cfg_data,
    input                             session_start,
    output                            busy,

    input                             src_pred_valid,
    output                            src_pred_ready,
    input      [SOURCE_ID_W-1:0]      src_pred_source_id,
    input      [`NODE_ID_W-1:0]       src_pred_parent_node_id,
    input      [`TOKEN_ID_W-1:0]      src_pred_token_id,
    input      [`TOKEN_ID_W-1:0]      src_pred_referenced_token_id,
    input      [`POSITION_ID_W-1:0]   src_pred_referenced_position,
    input      [CONF_W-1:0]           src_pred_confidence,
    input                             src_pred_is_last_in_window,

    input                             src_tree_window_valid,
    output                            src_tree_window_ready,
    input      [`NODE_ID_W-1:0]       src_tree_window_parent_node_id,
    input      [WINDOW_BRANCH_SLOTS-1:0] src_tree_window_slot_valid,
    input      [WINDOW_BRANCH_SLOTS*SOURCE_ID_W-1:0]
                                      src_tree_window_source_id,
    input      [WINDOW_BRANCH_SLOTS*`TOKEN_ID_W-1:0]
                                      src_tree_window_token_id,
    input      [WINDOW_BRANCH_SLOTS*`TOKEN_ID_W-1:0]
                                      src_tree_window_referenced_token_id,
    input      [WINDOW_BRANCH_SLOTS*`POSITION_ID_W-1:0]
                                      src_tree_window_referenced_position,
    input      [WINDOW_BRANCH_SLOTS*CONF_W-1:0]
                                      src_tree_window_confidence,

    output                            tc_cfg_valid,
    output     [CFG_W-1:0]            tc_cfg_data,
    output                            tc_start,
    input                             tc_busy,

    output                            tc_pred_valid,
    input                             tc_pred_ready,
    output     [SOURCE_ID_W-1:0]      tc_pred_source_id,
    output     [`NODE_ID_W-1:0]       tc_pred_parent_node_id,
    output     [`TOKEN_ID_W-1:0]      tc_pred_token_id,
    output     [`TOKEN_ID_W-1:0]      tc_pred_referenced_token_id,
    output     [`POSITION_ID_W-1:0]   tc_pred_referenced_position,
    output     [`POSITION_ID_W-1:0]   tc_pred_issue_position,
    output     [CONF_W-1:0]           tc_pred_confidence,
    output                            tc_pred_is_last_in_window,
    output     [SLOT_IDX_W-1:0]       tc_pred_slot_idx,
    output                            tc_pred_tree_mask_en,
    output     [15:0]                 tc_pred_prefix_len
);

localparam [2:0] ST_IDLE = 3'd0;
localparam [2:0] ST_WAIT_CAPTURE = 3'd1;
localparam [2:0] ST_LAUNCH_START = 3'd2;
localparam [2:0] ST_WAIT_PRED_ACCEPT = 3'd3;
localparam [2:0] ST_WAIT_SLOT_DONE = 3'd4;

reg [2:0] state_r;
reg [CFG_W-1:0] session_cfg_data_r;
reg [WINDOW_BRANCH_SLOTS-1:0] slot_valid_r;
reg [WINDOW_BRANCH_SLOTS*SOURCE_ID_W-1:0] slot_source_id_r;
reg [WINDOW_BRANCH_SLOTS*`NODE_ID_W-1:0] slot_parent_node_id_r;
reg [WINDOW_BRANCH_SLOTS*`TOKEN_ID_W-1:0] slot_token_id_r;
reg [WINDOW_BRANCH_SLOTS*`TOKEN_ID_W-1:0] slot_referenced_token_id_r;
reg [WINDOW_BRANCH_SLOTS*`POSITION_ID_W-1:0] slot_referenced_position_r;
reg [WINDOW_BRANCH_SLOTS*`POSITION_ID_W-1:0] slot_issue_position_r;
reg [WINDOW_BRANCH_SLOTS*CONF_W-1:0] slot_confidence_r;
reg [SLOT_IDX_W-1:0] current_slot_idx_r;
reg window_mode_r;
reg [15:0] session_prefix_len_r;

wire session_start_fire_w;
wire capture_window_fire_w;
wire capture_pred_fire_w;
wire pred_accept_fire_w;

reg next_slot_valid_w;
reg current_slot_is_last_w;
reg [SLOT_IDX_W-1:0] next_slot_idx_w;
integer slot_idx;

assign session_start_fire_w =
    session_cfg_valid &&
    session_start &&
    (state_r == ST_IDLE);
assign capture_window_fire_w =
    (state_r == ST_WAIT_CAPTURE) &&
    !tc_busy &&
    src_pred_valid &&
    src_tree_window_valid;
assign capture_pred_fire_w =
    (state_r == ST_WAIT_CAPTURE) &&
    !tc_busy &&
    src_pred_valid &&
    !src_tree_window_valid;
assign pred_accept_fire_w = tc_pred_valid && tc_pred_ready;

assign busy = (state_r != ST_IDLE);

assign src_pred_ready = capture_window_fire_w || capture_pred_fire_w;
assign src_tree_window_ready = capture_window_fire_w;

assign tc_cfg_valid = (state_r == ST_LAUNCH_START);
assign tc_cfg_data = session_cfg_data_r;
assign tc_start = (state_r == ST_LAUNCH_START);

assign tc_pred_valid = (state_r == ST_WAIT_PRED_ACCEPT);
assign tc_pred_source_id =
    slot_source_id_r[(current_slot_idx_r*SOURCE_ID_W) +: SOURCE_ID_W];
assign tc_pred_parent_node_id =
    slot_parent_node_id_r[(current_slot_idx_r*`NODE_ID_W) +: `NODE_ID_W];
assign tc_pred_token_id =
    slot_token_id_r[(current_slot_idx_r*`TOKEN_ID_W) +: `TOKEN_ID_W];
assign tc_pred_referenced_token_id =
    slot_referenced_token_id_r[(current_slot_idx_r*`TOKEN_ID_W) +:
                               `TOKEN_ID_W];
assign tc_pred_referenced_position =
    slot_referenced_position_r[(current_slot_idx_r*`POSITION_ID_W) +:
                               `POSITION_ID_W];
assign tc_pred_issue_position =
    slot_issue_position_r[(current_slot_idx_r*`POSITION_ID_W) +:
                          `POSITION_ID_W];
assign tc_pred_confidence =
    slot_confidence_r[(current_slot_idx_r*CONF_W) +: CONF_W];
assign tc_pred_is_last_in_window = current_slot_is_last_w;
assign tc_pred_slot_idx = current_slot_idx_r;
assign tc_pred_tree_mask_en = window_mode_r;
assign tc_pred_prefix_len = window_mode_r ? session_prefix_len_r : 16'd0;

always @* begin
    next_slot_valid_w = 1'b0;
    current_slot_is_last_w = 1'b1;
    next_slot_idx_w = {SLOT_IDX_W{1'b0}};

    for (slot_idx = 0; slot_idx < WINDOW_BRANCH_SLOTS; slot_idx = slot_idx + 1) begin
        if ((slot_idx > current_slot_idx_r) &&
            slot_valid_r[slot_idx] &&
            !next_slot_valid_w) begin
            next_slot_valid_w = 1'b1;
            current_slot_is_last_w = 1'b0;
            next_slot_idx_w = slot_idx[SLOT_IDX_W-1:0];
        end
    end
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state_r <= ST_IDLE;
        session_cfg_data_r <= {CFG_W{1'b0}};
        slot_valid_r <= {WINDOW_BRANCH_SLOTS{1'b0}};
        slot_source_id_r <= {(WINDOW_BRANCH_SLOTS*SOURCE_ID_W){1'b0}};
        slot_parent_node_id_r <= {(WINDOW_BRANCH_SLOTS*`NODE_ID_W){1'b0}};
        slot_token_id_r <= {(WINDOW_BRANCH_SLOTS*`TOKEN_ID_W){1'b0}};
        slot_referenced_token_id_r <=
            {(WINDOW_BRANCH_SLOTS*`TOKEN_ID_W){1'b0}};
        slot_referenced_position_r <=
            {(WINDOW_BRANCH_SLOTS*`POSITION_ID_W){1'b0}};
        slot_issue_position_r <=
            {(WINDOW_BRANCH_SLOTS*`POSITION_ID_W){1'b0}};
        slot_confidence_r <= {(WINDOW_BRANCH_SLOTS*CONF_W){1'b0}};
        current_slot_idx_r <= {SLOT_IDX_W{1'b0}};
        window_mode_r <= 1'b0;
        session_prefix_len_r <= 16'd0;
    end else begin
        case (state_r)
            ST_IDLE: begin
                if (session_start_fire_w) begin
                    session_cfg_data_r <= session_cfg_data;
                    session_prefix_len_r <= session_cfg_data[15:0];
                    state_r <= ST_WAIT_CAPTURE;
                end
            end

            ST_WAIT_CAPTURE: begin
                if (capture_window_fire_w) begin
                    slot_valid_r <= src_tree_window_slot_valid;
                    slot_source_id_r <= src_tree_window_source_id;
                    slot_parent_node_id_r <=
                        {WINDOW_BRANCH_SLOTS{src_tree_window_parent_node_id}};
                    slot_token_id_r <= src_tree_window_token_id;
                    slot_referenced_token_id_r <=
                        src_tree_window_referenced_token_id;
                    slot_referenced_position_r <=
                        src_tree_window_referenced_position;
                    slot_issue_position_r <=
                        src_tree_window_referenced_position;
                    slot_confidence_r <= src_tree_window_confidence;
                    current_slot_idx_r <= {SLOT_IDX_W{1'b0}};
                    window_mode_r <= 1'b1;
                    state_r <= ST_LAUNCH_START;
                end else if (capture_pred_fire_w) begin
                    slot_valid_r <= {{(WINDOW_BRANCH_SLOTS-1){1'b0}}, 1'b1};
                    slot_source_id_r <=
                        {{((WINDOW_BRANCH_SLOTS-1)*SOURCE_ID_W){1'b0}},
                         src_pred_source_id};
                    slot_parent_node_id_r <=
                        {{((WINDOW_BRANCH_SLOTS-1)*`NODE_ID_W){1'b0}},
                         src_pred_parent_node_id};
                    slot_token_id_r <=
                        {{((WINDOW_BRANCH_SLOTS-1)*`TOKEN_ID_W){1'b0}},
                         src_pred_token_id};
                    slot_referenced_token_id_r <=
                        {{((WINDOW_BRANCH_SLOTS-1)*`TOKEN_ID_W){1'b0}},
                         src_pred_referenced_token_id};
                    slot_referenced_position_r <=
                        {{((WINDOW_BRANCH_SLOTS-1)*`POSITION_ID_W){1'b0}},
                         src_pred_referenced_position};
                    slot_issue_position_r <=
                        {{((WINDOW_BRANCH_SLOTS-1)*`POSITION_ID_W){1'bx}},
                         {`POSITION_ID_W{1'bx}}};
                    slot_confidence_r <=
                        {{((WINDOW_BRANCH_SLOTS-1)*CONF_W){1'b0}},
                         src_pred_confidence};
                    current_slot_idx_r <= {SLOT_IDX_W{1'b0}};
                    window_mode_r <= 1'b0;
                    state_r <= ST_LAUNCH_START;
                end
            end

            ST_LAUNCH_START: begin
                state_r <= ST_WAIT_PRED_ACCEPT;
            end

            ST_WAIT_PRED_ACCEPT: begin
                if (pred_accept_fire_w) begin
                    state_r <= ST_WAIT_SLOT_DONE;
                end
            end

            ST_WAIT_SLOT_DONE: begin
                if (!tc_busy) begin
                    if (next_slot_valid_w) begin
                        current_slot_idx_r <= next_slot_idx_w;
                        state_r <= ST_LAUNCH_START;
                    end else begin
                        slot_valid_r <= {WINDOW_BRANCH_SLOTS{1'b0}};
                        window_mode_r <= 1'b0;
                        state_r <= ST_IDLE;
                    end
                end
            end

            default: begin
                state_r <= ST_IDLE;
            end
        endcase
    end
end

endmodule
