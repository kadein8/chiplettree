`timescale 1ns/1ps

`include "config/interface_params.vh"
`include "config/memory_params.vh"

module commit_writeback_bounded_shim (
    input                            clk,
    input                            rst_n,
    input                            scenario_start,
    input                            scenario_reentry_mode,
    input                            scenario_second_flush_mode,
    input                            scenario_second_flush_writeback_mode,
    input                            scenario_third_flush_mode,
    input                            scenario_third_flush_writeback_mode,
    input                            scenario_dual_tree_near_steady_state_mode,
    input  [1:0]                     scenario_dual_tree_flush_target,
    input                            scenario_tree_driven_strict_serial_mode,
    input  [1:0]                     scenario_variable_len_token_count_sel,
    input                            tree_verify_done,
    input  [2:0]                     effective_flush_count,
    input                            survivor_meta_valid,
    input  [`TOKEN_REG_INDEX_W-1:0]  survivor_commit_index,
    input  [`REQ_ID_W-1:0]           survivor_commit_req_id,
    input  [`BRANCH_MASK_W-1:0]      survivor_commit_branch_mask,
    input  [`NODE_MASK_W-1:0]        survivor_commit_node_mask,
    input  [`SRAM_ID_W-1:0]          survivor_commit_sram_id,
    input  [`BANK_ID_W-1:0]          survivor_commit_bank_id,
    input  [`SUBBANK_ID_W-1:0]       survivor_commit_subbank_start,
    input  [`KV_GROUP_LEN_W-1:0]     survivor_commit_group_len,
    input                            flush_done,
    input                            survivor_read_done,
    input  [`SRAM_RDATA_W-1:0]       survivor_read_data,
    input  [`TOKEN_ID_W-1:0]         survivor_new_token_len,
    input  [`TOKEN_ID_W-1:0]         survivor_new_token0,
    input  [`TOKEN_ID_W-1:0]         survivor_new_token1,
    input  [`TOKEN_ID_W-1:0]         survivor_new_token2,
    output reg                       token_commit_valid,
    output reg [`TOKEN_REG_INDEX_W-1:0] token_commit_index,
    output reg [`REQ_ID_W-1:0]       token_commit_req_id,
    output reg [`BRANCH_MASK_W-1:0]  token_commit_branch_mask,
    output reg [`NODE_MASK_W-1:0]    token_commit_node_mask,
    output reg                       bank_commit_valid,
    output reg [`REQ_ID_W-1:0]       bank_commit_req_id,
    output reg [`SRAM_ID_W-1:0]      bank_commit_sram_id,
    output reg [`BANK_ID_W-1:0]      bank_commit_bank_id,
    output reg [`SUBBANK_ID_W-1:0]   bank_commit_subbank_start,
    output reg [`KV_GROUP_LEN_W-1:0] bank_commit_group_len,
    output reg [`BRANCH_MASK_W-1:0]  bank_commit_branch_mask,
    output reg [`NODE_MASK_W-1:0]    bank_commit_node_mask,
    output reg                       hbm_req_valid,
    output reg                       hbm_req_write,
    output reg [`HBM_ADDR_W-1:0]     hbm_req_addr,
    output reg [`HBM_DATA_W-1:0]     hbm_req_wdata,
    output reg [`REQ_ID_W-1:0]       hbm_req_id,
    output reg                       scenario_done
);

localparam [`REQ_ID_W-1:0] HBM_WRITE_REQ_ID = 4'hd;

reg flush_done_q;
reg [1:0] run052_flush_seen_r;
reg survivor_result_valid_r;
reg final_writeback_done_r;
reg [`TOKEN_REG_INDEX_W-1:0] captured_commit_index_r;
reg [`REQ_ID_W-1:0] captured_commit_req_id_r;
reg [`BRANCH_MASK_W-1:0] captured_commit_branch_mask_r;
reg [`NODE_MASK_W-1:0] captured_commit_node_mask_r;
reg [`SRAM_ID_W-1:0] captured_commit_sram_id_r;
reg [`BANK_ID_W-1:0] captured_commit_bank_id_r;
reg [`SUBBANK_ID_W-1:0] captured_commit_subbank_start_r;
reg [`KV_GROUP_LEN_W-1:0] captured_commit_group_len_r;
reg [`TOKEN_ID_W-1:0] captured_new_token_len_r;
reg [`TOKEN_ID_W-1:0] captured_new_token0_r;
reg [`TOKEN_ID_W-1:0] captured_new_token1_r;
reg [`TOKEN_ID_W-1:0] captured_new_token2_r;

function [`HBM_DATA_W-1:0] pack_token_writeback_wdata;
    input [`TOKEN_ID_W-1:0] new_token_len_i;
    input [`TOKEN_ID_W-1:0] token0_i;
    input [`TOKEN_ID_W-1:0] token1_i;
    input [`TOKEN_ID_W-1:0] token2_i;
    begin
        pack_token_writeback_wdata = {
            {(`HBM_DATA_W-(4*`TOKEN_ID_W)){1'b0}},
            token2_i,
            token1_i,
            token0_i,
            new_token_len_i
        };
    end
endfunction

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        token_commit_valid <= 1'b0;
        token_commit_index <= {`TOKEN_REG_INDEX_W{1'b0}};
        token_commit_req_id <= {`REQ_ID_W{1'b0}};
        token_commit_branch_mask <= {`BRANCH_MASK_W{1'b0}};
        token_commit_node_mask <= {`NODE_MASK_W{1'b0}};
        bank_commit_valid <= 1'b0;
        bank_commit_req_id <= {`REQ_ID_W{1'b0}};
        bank_commit_sram_id <= {`SRAM_ID_W{1'b0}};
        bank_commit_bank_id <= {`BANK_ID_W{1'b0}};
        bank_commit_subbank_start <= {`SUBBANK_ID_W{1'b0}};
        bank_commit_group_len <= {`KV_GROUP_LEN_W{1'b0}};
        bank_commit_branch_mask <= {`BRANCH_MASK_W{1'b0}};
        bank_commit_node_mask <= {`NODE_MASK_W{1'b0}};
        hbm_req_valid <= 1'b0;
        hbm_req_write <= 1'b0;
        hbm_req_addr <= {`HBM_ADDR_W{1'b0}};
        hbm_req_wdata <= {`HBM_DATA_W{1'b0}};
        hbm_req_id <= {`REQ_ID_W{1'b0}};
        scenario_done <= 1'b0;
        flush_done_q <= 1'b0;
        run052_flush_seen_r <= 2'b00;
        survivor_result_valid_r <= 1'b0;
        final_writeback_done_r <= 1'b0;
        captured_commit_index_r <= {`TOKEN_REG_INDEX_W{1'b0}};
        captured_commit_req_id_r <= {`REQ_ID_W{1'b0}};
        captured_commit_branch_mask_r <= {`BRANCH_MASK_W{1'b0}};
        captured_commit_node_mask_r <= {`NODE_MASK_W{1'b0}};
        captured_commit_sram_id_r <= {`SRAM_ID_W{1'b0}};
        captured_commit_bank_id_r <= {`BANK_ID_W{1'b0}};
        captured_commit_subbank_start_r <= {`SUBBANK_ID_W{1'b0}};
        captured_commit_group_len_r <= {`KV_GROUP_LEN_W{1'b0}};
        captured_new_token_len_r <= {`TOKEN_ID_W{1'b0}};
        captured_new_token0_r <= {`TOKEN_ID_W{1'b0}};
        captured_new_token1_r <= {`TOKEN_ID_W{1'b0}};
        captured_new_token2_r <= {`TOKEN_ID_W{1'b0}};
    end else begin
        token_commit_valid <= 1'b0;
        bank_commit_valid <= 1'b0;
        hbm_req_valid <= 1'b0;
        hbm_req_write <= 1'b0;
        scenario_done <= 1'b0;
        flush_done_q <= flush_done;

        if (scenario_start) begin
            token_commit_index <= {`TOKEN_REG_INDEX_W{1'b0}};
            token_commit_req_id <= {`REQ_ID_W{1'b0}};
            token_commit_branch_mask <= {`BRANCH_MASK_W{1'b0}};
            token_commit_node_mask <= {`NODE_MASK_W{1'b0}};
            bank_commit_req_id <= {`REQ_ID_W{1'b0}};
            bank_commit_sram_id <= {`SRAM_ID_W{1'b0}};
            bank_commit_bank_id <= {`BANK_ID_W{1'b0}};
            bank_commit_subbank_start <= {`SUBBANK_ID_W{1'b0}};
            bank_commit_group_len <= {`KV_GROUP_LEN_W{1'b0}};
            bank_commit_branch_mask <= {`BRANCH_MASK_W{1'b0}};
            bank_commit_node_mask <= {`NODE_MASK_W{1'b0}};
            hbm_req_addr <= {`HBM_ADDR_W{1'b0}};
            hbm_req_wdata <= {`HBM_DATA_W{1'b0}};
            hbm_req_id <= {`REQ_ID_W{1'b0}};
            run052_flush_seen_r <= 2'b00;
            survivor_result_valid_r <= 1'b0;
            final_writeback_done_r <= 1'b0;
            captured_commit_index_r <= {`TOKEN_REG_INDEX_W{1'b0}};
            captured_commit_req_id_r <= {`REQ_ID_W{1'b0}};
            captured_commit_branch_mask_r <= {`BRANCH_MASK_W{1'b0}};
            captured_commit_node_mask_r <= {`NODE_MASK_W{1'b0}};
            captured_commit_sram_id_r <= {`SRAM_ID_W{1'b0}};
            captured_commit_bank_id_r <= {`BANK_ID_W{1'b0}};
            captured_commit_subbank_start_r <= {`SUBBANK_ID_W{1'b0}};
            captured_commit_group_len_r <= {`KV_GROUP_LEN_W{1'b0}};
            captured_new_token_len_r <= {`TOKEN_ID_W{1'b0}};
            captured_new_token0_r <= {`TOKEN_ID_W{1'b0}};
            captured_new_token1_r <= {`TOKEN_ID_W{1'b0}};
            captured_new_token2_r <= {`TOKEN_ID_W{1'b0}};
        end else begin
            if (survivor_meta_valid && survivor_read_done) begin
                survivor_result_valid_r <= 1'b1;
                captured_commit_index_r <= survivor_commit_index;
                captured_commit_req_id_r <= survivor_commit_req_id;
                captured_commit_branch_mask_r <= survivor_commit_branch_mask;
                captured_commit_node_mask_r <= survivor_commit_node_mask;
                captured_commit_sram_id_r <= survivor_commit_sram_id;
                captured_commit_bank_id_r <= survivor_commit_bank_id;
                captured_commit_subbank_start_r <= survivor_commit_subbank_start;
                captured_commit_group_len_r <= survivor_commit_group_len;
                captured_new_token_len_r <= survivor_new_token_len;
                captured_new_token0_r <= survivor_new_token0;
                captured_new_token1_r <= survivor_new_token1;
                captured_new_token2_r <= survivor_new_token2;
            end

            if (scenario_dual_tree_near_steady_state_mode) begin
            if (flush_done && !flush_done_q &&
                (run052_flush_seen_r < scenario_dual_tree_flush_target)) begin
                run052_flush_seen_r <= run052_flush_seen_r + 1'b1;
            end

            if (survivor_meta_valid &&
                survivor_read_done &&
                (run052_flush_seen_r == scenario_dual_tree_flush_target)) begin
                token_commit_valid <= 1'b1;
                token_commit_index <= survivor_commit_index;
                token_commit_req_id <= survivor_commit_req_id;
                token_commit_branch_mask <= survivor_commit_branch_mask;
                token_commit_node_mask <= survivor_commit_node_mask;

                bank_commit_valid <= 1'b1;
                bank_commit_req_id <= survivor_commit_req_id;
                bank_commit_sram_id <= survivor_commit_sram_id;
                bank_commit_bank_id <= survivor_commit_bank_id;
                bank_commit_subbank_start <= survivor_commit_subbank_start;
                bank_commit_group_len <= survivor_commit_group_len;
                bank_commit_branch_mask <= survivor_commit_branch_mask;
                bank_commit_node_mask <= survivor_commit_node_mask;

                hbm_req_valid <= 1'b1;
                hbm_req_write <= 1'b1;
                hbm_req_addr <= {
                    17'h04120,
                    survivor_commit_sram_id,
                    survivor_commit_bank_id,
                    survivor_commit_subbank_start,
                    4'h1
                };
                hbm_req_wdata <= pack_token_writeback_wdata(
                    {{(`TOKEN_ID_W-2){1'b0}}, scenario_variable_len_token_count_sel},
                    survivor_new_token0,
                    survivor_new_token1,
                    survivor_new_token2
                );
                hbm_req_id <= HBM_WRITE_REQ_ID;
                scenario_done <= 1'b1;
            end
            end else if (scenario_tree_driven_strict_serial_mode) begin
                if (tree_verify_done &&
                    survivor_result_valid_r &&
                    !final_writeback_done_r) begin
                    token_commit_valid <= 1'b1;
                    token_commit_index <= captured_commit_index_r;
                    token_commit_req_id <= captured_commit_req_id_r;
                    token_commit_branch_mask <= captured_commit_branch_mask_r;
                    token_commit_node_mask <= captured_commit_node_mask_r;

                    bank_commit_valid <= 1'b1;
                    bank_commit_req_id <= captured_commit_req_id_r;
                    bank_commit_sram_id <= captured_commit_sram_id_r;
                    bank_commit_bank_id <= captured_commit_bank_id_r;
                    bank_commit_subbank_start <= captured_commit_subbank_start_r;
                    bank_commit_group_len <= captured_commit_group_len_r;
                    bank_commit_branch_mask <= captured_commit_branch_mask_r;
                    bank_commit_node_mask <= captured_commit_node_mask_r;

                    hbm_req_valid <= 1'b1;
                    hbm_req_write <= 1'b1;
                    hbm_req_addr <= {
                        17'h04120,
                        captured_commit_sram_id_r,
                        captured_commit_bank_id_r,
                        captured_commit_subbank_start_r,
                        4'h1
                    };
                    hbm_req_wdata <= pack_token_writeback_wdata(
                        captured_new_token_len_r,
                        captured_new_token0_r,
                        captured_new_token1_r,
                        captured_new_token2_r
                    );
                    hbm_req_id <= HBM_WRITE_REQ_ID;
                    scenario_done <= 1'b1;
                    final_writeback_done_r <= 1'b1;
                end
            end else if (survivor_meta_valid &&
                     survivor_read_done &&
                     (!(scenario_second_flush_mode ||
                        scenario_second_flush_writeback_mode ||
                        scenario_third_flush_mode) ||
                      flush_done)) begin
            if (!scenario_reentry_mode ||
                scenario_second_flush_writeback_mode ||
                scenario_third_flush_writeback_mode) begin
                token_commit_valid <= 1'b1;
                token_commit_index <= survivor_commit_index;
                token_commit_req_id <= survivor_commit_req_id;
                token_commit_branch_mask <= survivor_commit_branch_mask;
                token_commit_node_mask <= survivor_commit_node_mask;

                bank_commit_valid <= 1'b1;
                bank_commit_req_id <= survivor_commit_req_id;
                bank_commit_sram_id <= survivor_commit_sram_id;
                bank_commit_bank_id <= survivor_commit_bank_id;
                bank_commit_subbank_start <= survivor_commit_subbank_start;
                bank_commit_group_len <= survivor_commit_group_len;
                bank_commit_branch_mask <= survivor_commit_branch_mask;
                bank_commit_node_mask <= survivor_commit_node_mask;

                hbm_req_valid <= 1'b1;
                hbm_req_write <= 1'b1;
                hbm_req_addr <= {
                    17'h04120,
                    survivor_commit_sram_id,
                    survivor_commit_bank_id,
                    survivor_commit_subbank_start,
                    4'h1
                };
                hbm_req_wdata <= pack_token_writeback_wdata(
                    survivor_new_token_len,
                    survivor_new_token0,
                    survivor_new_token1,
                    survivor_new_token2
                );
                hbm_req_id <= HBM_WRITE_REQ_ID;
            end
                scenario_done <= 1'b1;
            end
        end
    end
end

endmodule
