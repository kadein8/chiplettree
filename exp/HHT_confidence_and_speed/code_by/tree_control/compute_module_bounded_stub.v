`timescale 1ns/1ps

`include "config/prediction_params.vh"
`include "config/interface_params.vh"
`include "config/memory_params.vh"

module compute_module_bounded_stub (
    input                            clk,
    input                            rst_n,
    input                            scenario_start,
    input                            scenario_reentry_mode,
    input                            scenario_second_flush_mode,
    input                            scenario_second_flush_writeback_mode,
    input                            scenario_third_flush_mode,
    input                            scenario_variable_len_token_writeback_mode,
    input  [1:0]                     scenario_variable_len_token_count_sel,
    input                            scenario_dual_tree_near_steady_state_mode,
    input  [1:0]                     scenario_dual_tree_flush_target,
    input                            scenario_tree_driven_strict_serial_mode,
    input                            tree_verify_done,
    input  [2:0]                     effective_flush_count,
    input                            flush_done,
    input                            token_wr_valid,
    input  [`TOKEN_REG_INDEX_W-1:0]  token_wr_index,
    input  [`REQ_ID_W-1:0]           token_wr_req_id,
    input  [`TOKEN_ID_W-1:0]         token_wr_token_id,
    input  [`POSITION_ID_W-1:0]      token_wr_position_id,
    input  [`NODE_ID_W-1:0]          token_wr_node_id,
    input  [`BRANCH_ID_W-1:0]        token_wr_branch_id,
    input  [`BRANCH_MASK_W-1:0]      token_wr_branch_mask,
    input                            token_wr_is_shared,
    input                            lookup_ready,
    output reg                       lookup_valid,
    output reg [`REQ_ID_W-1:0]       lookup_req_id,
    output reg [`TOKEN_ID_W-1:0]     lookup_token_id,
    output reg [`POSITION_ID_W-1:0]  lookup_position_id,
    input                            lookup_resp_valid,
    input                            lookup_resp_hit,
    input  [`REQ_ID_W-1:0]           lookup_resp_req_id,
    input  [`SRAM_ID_W-1:0]          lookup_resp_sram_id,
    input  [`BANK_ID_W-1:0]          lookup_resp_bank_id,
    input  [`SUBBANK_ID_W-1:0]       lookup_resp_subbank_start,
    input  [`KV_GROUP_LEN_W-1:0]     lookup_resp_group_len,
    input                            prep_ready,
    output reg                       prep_valid,
    output reg                       prep_write,
    output reg [`SRAM_ADDR_W-1:0]    prep_addr,
    output reg [`SRAM_WDATA_W-1:0]   prep_wdata,
    output reg [`REQ_ID_W-1:0]       prep_req_id,
    input                            pe_req_ready,
    output reg                       pe_req_valid,
    output reg                       pe_req_write,
    output reg [`SRAM_ADDR_W-1:0]    pe_req_addr,
    output reg [`SRAM_WDATA_W-1:0]   pe_req_wdata,
    output reg [`REQ_ID_W-1:0]       pe_req_req_id,
    output reg [`PE_MASK_W-1:0]      pe_req_pe_mask,
    output reg [`REQ_PRIORITY_W-1:0] pe_req_priority,
    output reg [`BANK_ID_W-1:0]      pe_req_bank_id,
    output reg [`SUBBANK_ID_W-1:0]   pe_req_subbank_id,
    input                            pe_resp_valid,
    input  [`SRAM_RDATA_W-1:0]       pe_resp_rdata,
    input  [`REQ_ID_W-1:0]           pe_resp_req_id,
    input                            pe_resp_last,
    output reg                       pe_resp_ready,
    output reg                       prep_done,
    output reg                       survivor_meta_valid,
    output reg [`TOKEN_REG_INDEX_W-1:0] survivor_commit_index,
    output reg [`REQ_ID_W-1:0]       survivor_commit_req_id,
    output reg [`BRANCH_MASK_W-1:0]  survivor_commit_branch_mask,
    output reg [`NODE_MASK_W-1:0]    survivor_commit_node_mask,
    output reg [`SRAM_ID_W-1:0]      survivor_commit_sram_id,
    output reg [`BANK_ID_W-1:0]      survivor_commit_bank_id,
    output reg [`SUBBANK_ID_W-1:0]   survivor_commit_subbank_start,
    output reg [`KV_GROUP_LEN_W-1:0] survivor_commit_group_len,
    output reg                       survivor_read_done,
    output reg [`SRAM_RDATA_W-1:0]   survivor_read_data,
    output reg [`TOKEN_ID_W-1:0]     survivor_new_token_len,
    output reg [`TOKEN_ID_W-1:0]     survivor_new_token0,
    output reg [`TOKEN_ID_W-1:0]     survivor_new_token1,
    output reg [`TOKEN_ID_W-1:0]     survivor_new_token2
);

localparam [`REQ_ID_W-1:0] TREE_REQ_ID = 4'h9;
localparam [`REQ_ID_W-1:0] PREP_REQ_ID = 4'hb;
localparam [`REQ_ID_W-1:0] PE_READ_REQ_ID = 4'hc;
localparam [`PE_MASK_W-1:0] PE_MASK_TEST = 16'h00f3;
localparam integer RUN052_BATCH_REQS = 4;
localparam [`SRAM_WDATA_W-1:0] PREP_DATA =
    128'h01234567_89abcdef_fedcba98_76543210;
localparam [`ROW_ADDR_W-1:0] PREP_ROW = 8'h06;
localparam [`OFFSET_W-1:0] PREP_OFFSET = 4'h4;

localparam [2:0] STATE_WAIT_TOKEN  = 3'd0;
localparam [2:0] STATE_LOOKUP_REQ  = 3'd1;
localparam [2:0] STATE_LOOKUP_RESP = 3'd2;
localparam [2:0] STATE_PREP_REQ    = 3'd3;
localparam [2:0] STATE_WAIT_FLUSH  = 3'd4;
localparam [2:0] STATE_PE_REQ      = 3'd5;
localparam [2:0] STATE_WAIT_RESP   = 3'd6;
localparam [2:0] STATE_CONSUME     = 3'd7;

reg [2:0] state_r;
reg [`TOKEN_ID_W-1:0] survivor_token_id_r;
reg [`POSITION_ID_W-1:0] survivor_position_id_r;
reg [`SRAM_ADDR_W-1:0] survivor_addr_r;
reg [2:0] run052_issue_count_r;
reg [1:0] run052_flush_seen_r;

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

function [`SRAM_ADDR_W-1:0] pack_addr;
    input [`SRAM_ID_W-1:0] sram_i;
    input [`BANK_ID_W-1:0] bank_i;
    input [`SUBBANK_ID_W-1:0] subbank_i;
    input [`ROW_ADDR_W-1:0] row_i;
    input [`OFFSET_W-1:0] offset_i;
    begin
        pack_addr = {sram_i, bank_i, subbank_i, row_i, offset_i};
    end
endfunction

function [`TOKEN_ID_W-1:0] tree_driven_token_len;
    input [2:0] flush_count_i;
    begin
        case (flush_count_i)
            3'd0: tree_driven_token_len = 16'h0001;
            3'd1: tree_driven_token_len = 16'h0002;
            default: tree_driven_token_len = 16'h0003;
        endcase
    end
endfunction

always @* begin
    lookup_valid = 1'b0;
    lookup_req_id = survivor_commit_req_id;
    lookup_token_id = survivor_token_id_r;
    lookup_position_id = survivor_position_id_r;
    prep_valid = 1'b0;
    prep_write = 1'b0;
    prep_addr = survivor_addr_r;
    prep_wdata = PREP_DATA;
    prep_req_id = PREP_REQ_ID;
    pe_req_valid = 1'b0;
    pe_req_write = 1'b0;
    pe_req_addr = survivor_addr_r;
    pe_req_wdata = {`SRAM_WDATA_W{1'b0}};
    pe_req_req_id = PE_READ_REQ_ID;
    pe_req_pe_mask = PE_MASK_TEST;
    pe_req_priority = {`REQ_PRIORITY_W{1'b0}};
    pe_req_bank_id = survivor_commit_bank_id;
    pe_req_subbank_id = survivor_commit_subbank_start;
    pe_resp_ready = 1'b0;

    case (state_r)
        STATE_LOOKUP_REQ: begin
            lookup_valid = 1'b1;
        end

        STATE_PREP_REQ: begin
            prep_valid = 1'b1;
            prep_write = 1'b1;
        end

        STATE_PE_REQ: begin
            pe_req_valid = 1'b1;
            if (scenario_dual_tree_near_steady_state_mode ||
                scenario_tree_driven_strict_serial_mode) begin
                pe_req_write = 1'b0;
                case (run052_issue_count_r)
                    3'd0: begin
                        pe_req_addr = pack_addr(2'h0, 4'h0, 5'h03, 8'h31, 4'h0);
                        pe_req_req_id = 4'h1;
                        pe_req_pe_mask = 16'h0001;
                        pe_req_priority = 2'd0;
                        pe_req_bank_id = 4'h0;
                        pe_req_subbank_id = 5'h03;
                    end
                    3'd1: begin
                        pe_req_addr = pack_addr(2'h0, 4'h1, 5'h04, 8'h32, 4'h0);
                        pe_req_req_id = 4'h2;
                        pe_req_pe_mask = 16'h0002;
                        pe_req_priority = 2'd3;
                        pe_req_bank_id = 4'h1;
                        pe_req_subbank_id = 5'h04;
                    end
                    3'd2: begin
                        pe_req_addr = pack_addr(2'h0, 4'h2, 5'h05, 8'h33, 4'h0);
                        pe_req_req_id = 4'h3;
                        pe_req_pe_mask = 16'h0004;
                        pe_req_priority = 2'd1;
                        pe_req_bank_id = 4'h2;
                        pe_req_subbank_id = 5'h05;
                    end
                    default: begin
                        pe_req_addr = pack_addr(2'h0, 4'h3, 5'h06, 8'h34, 4'h0);
                        pe_req_req_id = 4'h4;
                        pe_req_pe_mask = 16'h0008;
                        pe_req_priority = 2'd2;
                        pe_req_bank_id = 4'h3;
                        pe_req_subbank_id = 5'h06;
                    end
                endcase
            end
        end

        STATE_CONSUME: begin
            pe_resp_ready = 1'b1;
        end

        STATE_WAIT_RESP: begin
            if (scenario_dual_tree_near_steady_state_mode ||
                scenario_tree_driven_strict_serial_mode) begin
                pe_resp_ready = 1'b1;
            end
        end

        default: begin
        end
    endcase
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state_r <= STATE_WAIT_TOKEN;
        survivor_token_id_r <= {`TOKEN_ID_W{1'b0}};
        survivor_position_id_r <= {`POSITION_ID_W{1'b0}};
        survivor_addr_r <= {`SRAM_ADDR_W{1'b0}};
        prep_done <= 1'b0;
        survivor_meta_valid <= 1'b0;
        survivor_commit_index <= {`TOKEN_REG_INDEX_W{1'b0}};
        survivor_commit_req_id <= {`REQ_ID_W{1'b0}};
        survivor_commit_branch_mask <= {`BRANCH_MASK_W{1'b0}};
        survivor_commit_node_mask <= {`NODE_MASK_W{1'b0}};
        survivor_commit_sram_id <= {`SRAM_ID_W{1'b0}};
        survivor_commit_bank_id <= {`BANK_ID_W{1'b0}};
        survivor_commit_subbank_start <= {`SUBBANK_ID_W{1'b0}};
        survivor_commit_group_len <= {`KV_GROUP_LEN_W{1'b0}};
        survivor_read_done <= 1'b0;
        survivor_read_data <= {`SRAM_RDATA_W{1'b0}};
        survivor_new_token_len <= {`TOKEN_ID_W{1'b0}};
        survivor_new_token0 <= {`TOKEN_ID_W{1'b0}};
        survivor_new_token1 <= {`TOKEN_ID_W{1'b0}};
        survivor_new_token2 <= {`TOKEN_ID_W{1'b0}};
        run052_issue_count_r <= 3'd0;
        run052_flush_seen_r <= 2'b00;
    end else begin
        survivor_read_done <= 1'b0;

        if (scenario_start) begin
            state_r <= STATE_WAIT_TOKEN;
            survivor_token_id_r <= {`TOKEN_ID_W{1'b0}};
            survivor_position_id_r <= {`POSITION_ID_W{1'b0}};
            survivor_addr_r <= {`SRAM_ADDR_W{1'b0}};
            prep_done <= 1'b0;
            survivor_meta_valid <= 1'b0;
            survivor_commit_index <= {`TOKEN_REG_INDEX_W{1'b0}};
            survivor_commit_req_id <= {`REQ_ID_W{1'b0}};
            survivor_commit_branch_mask <= {`BRANCH_MASK_W{1'b0}};
            survivor_commit_node_mask <= {`NODE_MASK_W{1'b0}};
            survivor_commit_sram_id <= {`SRAM_ID_W{1'b0}};
            survivor_commit_bank_id <= {`BANK_ID_W{1'b0}};
            survivor_commit_subbank_start <= {`SUBBANK_ID_W{1'b0}};
            survivor_commit_group_len <= {`KV_GROUP_LEN_W{1'b0}};
            survivor_read_data <= {`SRAM_RDATA_W{1'b0}};
            survivor_new_token_len <= {`TOKEN_ID_W{1'b0}};
            survivor_new_token0 <= {`TOKEN_ID_W{1'b0}};
            survivor_new_token1 <= {`TOKEN_ID_W{1'b0}};
            survivor_new_token2 <= {`TOKEN_ID_W{1'b0}};
            run052_issue_count_r <= 3'd0;
            run052_flush_seen_r <= 2'b00;
            if (scenario_variable_len_token_writeback_mode ||
                scenario_dual_tree_near_steady_state_mode) begin
                case (scenario_variable_len_token_count_sel)
                    2'b01: begin
                        survivor_new_token_len <= 16'h0001;
                        survivor_new_token0 <= 16'h0101;
                    end
                    2'b10: begin
                        survivor_new_token_len <= 16'h0002;
                        survivor_new_token0 <= 16'h0201;
                        survivor_new_token1 <= 16'h0202;
                    end
                    2'b11: begin
                        survivor_new_token_len <= 16'h0003;
                        survivor_new_token0 <= 16'h0301;
                        survivor_new_token1 <= 16'h0302;
                        survivor_new_token2 <= 16'h0303;
                    end
                    default: begin
                    end
                endcase
            end
        end else begin
            case (state_r)
                STATE_WAIT_TOKEN: begin
                    if (token_wr_valid &&
                        (token_wr_req_id == TREE_REQ_ID) &&
                        !token_wr_is_shared) begin
                        survivor_token_id_r <= token_wr_token_id;
                        survivor_position_id_r <= token_wr_position_id;
                        survivor_commit_index <= token_wr_index;
                        survivor_commit_req_id <= token_wr_req_id;
                        survivor_commit_branch_mask <= token_wr_branch_mask;
                        survivor_commit_node_mask <=
                            node_onehot_mask(token_wr_branch_id, token_wr_node_id);
                        if (scenario_tree_driven_strict_serial_mode) begin
                            survivor_new_token_len <= 16'h0001;
                            survivor_new_token0 <= token_wr_token_id;
                            survivor_new_token1 <= 16'h0000;
                            survivor_new_token2 <= 16'h0000;
                        end else if (scenario_variable_len_token_writeback_mode ||
                            scenario_dual_tree_near_steady_state_mode) begin
                            case (scenario_variable_len_token_count_sel)
                                2'b01: begin
                                    survivor_new_token_len <= 16'h0001;
                                    survivor_new_token0 <= 16'h0101;
                                    survivor_new_token1 <= 16'h0000;
                                    survivor_new_token2 <= 16'h0000;
                                end
                                2'b10: begin
                                    survivor_new_token_len <= 16'h0002;
                                    survivor_new_token0 <= 16'h0201;
                                    survivor_new_token1 <= 16'h0202;
                                    survivor_new_token2 <= 16'h0000;
                                end
                                2'b11: begin
                                    survivor_new_token_len <= 16'h0003;
                                    survivor_new_token0 <= 16'h0301;
                                    survivor_new_token1 <= 16'h0302;
                                    survivor_new_token2 <= 16'h0303;
                                end
                                default: begin
                                    survivor_new_token_len <= 16'h0000;
                                    survivor_new_token0 <= 16'h0000;
                                    survivor_new_token1 <= 16'h0000;
                                    survivor_new_token2 <= 16'h0000;
                                end
                            endcase
                        end else begin
                            survivor_new_token_len <= 16'h0001;
                            survivor_new_token0 <= token_wr_token_id;
                            survivor_new_token1 <= 16'h0000;
                            survivor_new_token2 <= 16'h0000;
                        end
                        state_r <= STATE_LOOKUP_REQ;
                    end
                end

                STATE_LOOKUP_REQ: begin
                    if (lookup_ready) begin
                        state_r <= STATE_LOOKUP_RESP;
                    end
                end

                STATE_LOOKUP_RESP: begin
                    if (lookup_resp_valid &&
                        lookup_resp_hit &&
                        (lookup_resp_req_id == survivor_commit_req_id)) begin
                        survivor_commit_sram_id <= lookup_resp_sram_id;
                        survivor_commit_bank_id <= lookup_resp_bank_id;
                        survivor_commit_subbank_start <= lookup_resp_subbank_start;
                        survivor_commit_group_len <= lookup_resp_group_len;
                        survivor_addr_r <= pack_addr(
                            lookup_resp_sram_id,
                            lookup_resp_bank_id,
                            lookup_resp_subbank_start,
                            PREP_ROW,
                            PREP_OFFSET
                        );
                        survivor_meta_valid <= 1'b1;
                        state_r <= STATE_PREP_REQ;
                    end
                end

                STATE_PREP_REQ: begin
                    if (prep_ready) begin
                        prep_done <= 1'b1;
                        if (scenario_dual_tree_near_steady_state_mode ||
                            scenario_tree_driven_strict_serial_mode) begin
                            run052_issue_count_r <= 3'd0;
                            state_r <= STATE_PE_REQ;
                        end else if (scenario_reentry_mode ||
                            scenario_second_flush_mode ||
                            scenario_second_flush_writeback_mode ||
                            scenario_variable_len_token_writeback_mode) begin
                            state_r <= STATE_PE_REQ;
                        end else begin
                            state_r <= STATE_WAIT_FLUSH;
                        end
                    end
                end

                STATE_WAIT_FLUSH: begin
                    if (scenario_tree_driven_strict_serial_mode) begin
                        if (tree_verify_done) begin
                            state_r <= STATE_WAIT_TOKEN;
                        end else if (flush_done) begin
                            run052_issue_count_r <= 3'd0;
                            state_r <= STATE_PE_REQ;
                        end
                    end else if (scenario_dual_tree_near_steady_state_mode &&
                        flush_done) begin
                        run052_flush_seen_r <= run052_flush_seen_r + 1'b1;
                        run052_issue_count_r <= 3'd0;
                        state_r <= STATE_PE_REQ;
                    end else if (flush_done) begin
                        state_r <= STATE_PE_REQ;
                    end
                end

                STATE_PE_REQ: begin
                    if (scenario_dual_tree_near_steady_state_mode ||
                        scenario_tree_driven_strict_serial_mode) begin
                        if (pe_req_ready) begin
                            if (run052_issue_count_r == (RUN052_BATCH_REQS - 1)) begin
                                state_r <= STATE_WAIT_RESP;
                            end else begin
                                run052_issue_count_r <= run052_issue_count_r + 1'b1;
                            end
                        end
                    end else if (pe_req_ready) begin
                        state_r <= STATE_WAIT_RESP;
                    end
                end

                STATE_WAIT_RESP: begin
                    if ((scenario_dual_tree_near_steady_state_mode ||
                         scenario_tree_driven_strict_serial_mode) &&
                        pe_resp_valid &&
                        pe_resp_last) begin
                        survivor_read_data <= pe_resp_rdata;
                        state_r <= STATE_CONSUME;
                    end else if (pe_resp_valid &&
                        (pe_resp_req_id == PE_READ_REQ_ID) &&
                        pe_resp_last) begin
                        survivor_read_data <= pe_resp_rdata;
                        state_r <= STATE_CONSUME;
                    end
                end

                STATE_CONSUME: begin
                    survivor_read_done <= 1'b1;
                    if (scenario_tree_driven_strict_serial_mode) begin
                        survivor_new_token_len <=
                            tree_driven_token_len(effective_flush_count);
                        survivor_new_token0 <= survivor_token_id_r;
                        survivor_new_token1 <=
                            (tree_driven_token_len(effective_flush_count) >
                             16'h0001) ? (survivor_token_id_r + 16'h0001) :
                                         16'h0000;
                        survivor_new_token2 <=
                            (tree_driven_token_len(effective_flush_count) >
                             16'h0002) ? (survivor_token_id_r + 16'h0002) :
                                         16'h0000;
                        state_r <= STATE_WAIT_FLUSH;
                    end else if (scenario_dual_tree_near_steady_state_mode) begin
                        if (run052_flush_seen_r < scenario_dual_tree_flush_target) begin
                            state_r <= STATE_WAIT_FLUSH;
                        end else begin
                            state_r <= STATE_WAIT_TOKEN;
                        end
                    end else if ((scenario_second_flush_mode ||
                         scenario_second_flush_writeback_mode ||
                         scenario_third_flush_mode) &&
                        !flush_done) begin
                        state_r <= STATE_WAIT_FLUSH;
                    end else begin
                        state_r <= STATE_WAIT_TOKEN;
                    end
                end

                default: begin
                    state_r <= STATE_WAIT_TOKEN;
                end
            endcase
        end
    end
end

endmodule
