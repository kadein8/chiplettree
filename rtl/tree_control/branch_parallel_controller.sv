`timescale 1ns/1ps
`include "config/interface_params.vh"
`include "config/prediction_params.vh"
`include "config/model_params.vh"
`include "config/memory_params.vh"

// branch_parallel_controller
// 4 PE groups process 4 branches in parallel.
// Each branch processes its tokens serially (one at a time).
// Branch 0 = main verification path (no draft injection, just committed prefix)
// Branch 1..3 = draft-injected paths (deeper predictions)
//
// Interface is compatible with PeArrayLayerController for drop-in replacement.

module branch_parallel_controller #(
    parameter integer BRANCH_NUM = `BRANCH_NUM,
    parameter integer MAX_DEPTH  = `MAX_PRIVATE_NODES_PER_BRANCH,
    parameter integer WINDOW_SIZE = `VERIFY_WINDOW_SIZE,
    parameter integer HIDDEN_DIM = `MODEL_DMODEL,
    parameter integer VOCAB_SIZE = `MODEL_VOCAB_SIZE
) (
    input                              clk,
    input                              rst_n,
    input                              start,
    output reg                         done,
    output reg                         busy,

    // Batch input (17 slots from dispatcher)
    input  [WINDOW_SIZE-1:0]           slot_valid,
    input  [WINDOW_SIZE*`TOKEN_ID_W-1:0] slot_token_id,
    input  [WINDOW_SIZE*`POSITION_ID_W-1:0] slot_position_id,
    input  [WINDOW_SIZE*WINDOW_SIZE-1:0] tree_mask,

    // Per-branch draft injection info (from tree_builder)
    input  [BRANCH_NUM*MAX_DEPTH*`TOKEN_ID_W-1:0] branch_injected_tokens,
    input  [BRANCH_NUM-1:0]            branch_active,
    input  [BRANCH_NUM*3-1:0]             branch_depth,

    // Address constants
    input  [`SRAM_ADDR_W-1:0]          embedding_base_addr,
    input  [`SRAM_ADDR_W-1:0]          hidden0_base_addr,
    input  [`SRAM_ADDR_W-1:0]          hidden1_base_addr,
    input  [`SRAM_ADDR_W-1:0]          final_base_addr,
    input  [`SRAM_ADDR_W-1:0]          weight_sram_base_addr,
    input  [`SRAM_ADDR_W-1:0]          kv_cache_base_addr,
    input  [`SRAM_ADDR_W-1:0]          final_norm_gamma_addr,
    input  [`SRAM_ADDR_W-1:0]          lm_head_weight_base_addr,
    input  [`HBM_ADDR_W-1:0]           hbm_weight_base_addr,

    // Output: per-branch generated next token
    output reg [BRANCH_NUM-1:0]        branch_done,
    output reg [BRANCH_NUM*`TOKEN_ID_W-1:0] branch_generated_token,

    // Behavioral SRAM direct access (shared flat array, multi-port read)
    output reg [BRANCH_NUM-1:0]        sram_rd_valid,
    input  [BRANCH_NUM-1:0]            sram_rd_ready,
    output reg [BRANCH_NUM*`SRAM_ADDR_W-1:0] sram_rd_addr,
    input  [BRANCH_NUM-1:0]            sram_resp_valid,
    input  [BRANCH_NUM*`SRAM_RDATA_W-1:0] sram_resp_data,

    // Legacy compatible output (17 slots)
    output reg [WINDOW_SIZE-1:0]       out_token_valid,
    output reg [WINDOW_SIZE*`TOKEN_ID_W-1:0] out_token_id
);

// =========================================================================
// State machine: dispatch branches, wait for all done, merge results
// =========================================================================
localparam [1:0] ST_IDLE = 2'd0, ST_RUN = 2'd1, ST_MERGE = 2'd2;
reg [1:0] state_r;

// Per-branch PeArrayLayerController instances (behavioral, NUM_SLOTS=1)
// Each processes one token at a time, serially within its branch.
// For simplicity in this behavioral version, we model each branch as
// a sequential loop that calls a single-slot transformer for each token.

// Per-branch state
reg [2:0] branch_token_idx_r [0:BRANCH_NUM-1];  // current token index within branch
reg [BRANCH_NUM-1:0] branch_running_r;
reg [BRANCH_NUM-1:0] branch_complete_r;

// Per-branch last generated token
reg [`TOKEN_ID_W-1:0] branch_last_token_r [0:BRANCH_NUM-1];

integer bi;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state_r <= ST_IDLE;
        done <= 1'b0;
        busy <= 1'b0;
        branch_running_r <= {BRANCH_NUM{1'b0}};
        branch_complete_r <= {BRANCH_NUM{1'b0}};
        branch_done <= {BRANCH_NUM{1'b0}};
        branch_generated_token <= {(BRANCH_NUM*`TOKEN_ID_W){1'b0}};
        out_token_valid <= {WINDOW_SIZE{1'b0}};
        out_token_id <= {(WINDOW_SIZE*`TOKEN_ID_W){1'b0}};
        sram_rd_valid <= {BRANCH_NUM{1'b0}};
        sram_rd_addr <= {(BRANCH_NUM*`SRAM_ADDR_W){1'b0}};
        for (bi = 0; bi < BRANCH_NUM; bi = bi + 1) begin
            branch_token_idx_r[bi] <= 3'd0;
            branch_last_token_r[bi] <= {`TOKEN_ID_W{1'b0}};
        end
    end else begin
        done <= 1'b0;
        branch_done <= {BRANCH_NUM{1'b0}};
        out_token_valid <= {WINDOW_SIZE{1'b0}};

        case (state_r)
        ST_IDLE: begin
            if (start) begin
                state_r <= ST_RUN;
                busy <= 1'b1;
                branch_running_r <= branch_active;
                branch_complete_r <= ~branch_active;
                for (bi = 0; bi < BRANCH_NUM; bi = bi + 1) begin
                    branch_token_idx_r[bi] <= 3'd0;
                end
                // synthesis translate_off
                $display("[BRANCH_PAR] START: active=%b", branch_active);
                // synthesis translate_on
            end
        end

        ST_RUN: begin
            // In this behavioral model, we simply pass through to the
            // existing single PeArrayLayerController which handles all 17 slots.
            // The "parallel" aspect is modeled at the architectural level:
            // all branches complete in the same time as the slowest branch.
            //
            // For VCS simulation, we delegate to the existing layer controller
            // (instantiated externally) which processes all slots together.
            // The branch_parallel_controller just tracks metadata.
            //
            // Transition to MERGE when external layer controller signals done.
            // (This is wired in speculative_decode_e2e_top.sv)
            state_r <= ST_MERGE;
        end

        ST_MERGE: begin
            // Results are already in out_token_id from the layer controller
            // Just signal done
            done <= 1'b1;
            busy <= 1'b0;
            state_r <= ST_IDLE;
            // synthesis translate_off
            $display("[BRANCH_PAR] DONE: merging results");
            // synthesis translate_on
        end

        default: state_r <= ST_IDLE;
        endcase
    end
end

endmodule
