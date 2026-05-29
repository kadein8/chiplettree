`timescale 1ns/1ps

`include "config/interface_params.vh"
`include "config/memory_params.vh"
`include "config/model_params.vh"

/*
 * 文件作用：
 * 1. 这是 strict tree-mask 论文主路径后半段的正式 postprocess 边界。
 * 2. 它位于：
 *      PaperPeArrays16x128Mesh / StrictTreeMaskPaperMeshBackend
 *          -> StrictTreeMaskPaperLogitsPostprocess
 *          -> StrictTreeMaskPaperReadout
 *    这一段 ownership 上。
 * 3. 这个模块存在的目的不是引入新的 shortcut，而是把：
 *      raw mesh tile
 *          -> hidden/logits 数值后处理
 *          -> formal tile result
 *    这层边界稳定下来。
 * 4. 当前这一轮先保持透明直通，避免再次改动顶层和 lifecycle 接线。
 * 5. 后续真实的 hidden -> logits tile 数值核，只允许收敛在这个模块内部，
 *    不能再直接回写顶层、readout 或 mesh ownership。
 */
module StrictTreeMaskPaperLogitsPostprocess #(
    parameter integer PRIVATE_DEPTH_W =
        (((`MAX_VERIFY_NODES_PER_BRANCH + 1) <= 2) ? 1 :
         $clog2(`MAX_VERIFY_NODES_PER_BRANCH + 1)),
    parameter integer DEPTH_PACK_W = (`BRANCH_NUM * PRIVATE_DEPTH_W)
) (
    /* verilator lint_off UNUSED */
    input                             clk,
    input                             rst_n,
    /* verilator lint_on UNUSED */

    /*
     * 来自 strict mesh backend 的 raw tile 边界。
     * 当前实现先透明转发，后续在这里接入真实的 hidden/logits 数值核。
     */
    input                             mesh_tile_valid,
    input      [`REQ_ID_W-1:0]        mesh_tile_req_id,
    input      [`BRANCH_NUM-1:0]      mesh_tile_slot_valid,
    input      [`BRANCH_NUM*`BRANCH_ID_W-1:0] mesh_tile_branch_id,
    input      [DEPTH_PACK_W-1:0]     mesh_tile_private_depth,
    input      [`BRANCH_NUM*`NODE_ID_W-1:0] mesh_tile_node_id,
    input      [`BRANCH_NUM*`NODE_ID_W-1:0] mesh_tile_parent_node_id,
    input      [1:0]                  mesh_tile_kind,
    input      [15:0]                 mesh_tile_tile_index,
    input      [`BRANCH_NUM-1:0]      mesh_tile_last,
    input      [`BRANCH_NUM*`SRAM_RDATA_W-1:0] mesh_tile_data,
    input      [`SRAM_ADDR_W-1:0]      final_norm_gamma_addr,
    input      [`SRAM_ADDR_W-1:0]      lm_head_weight_base_addr,
    output                            mem_active,
    output     [`MEM_REQ_LANES-1:0]   vec_req_valid,
    input      [`MEM_REQ_LANES-1:0]   vec_req_ready,
    output     [`MEM_REQ_LANES-1:0]   vec_req_write,
    output     [`MEM_REQ_LANES*`SRAM_ADDR_W-1:0] vec_req_addr,
    output     [`MEM_REQ_LANES*`SRAM_WDATA_W-1:0] vec_req_wdata,
    output     [`MEM_REQ_LANES*`REQ_ID_W-1:0] vec_req_req_id,
    output     [`MEM_REQ_LANES*`PE_MASK_W-1:0] vec_req_pe_mask,
    output     [`MEM_REQ_LANES*`REQ_PRIORITY_W-1:0] vec_req_priority,
    output     [`MEM_REQ_LANES*`BANK_ID_W-1:0] vec_req_bank_id,
    output     [`MEM_REQ_LANES*`SUBBANK_ID_W-1:0] vec_req_subbank_id,
    input      [`PE_MASK_W-1:0]       mc_resp_valid,
    output     [`PE_MASK_W-1:0]       mc_resp_ready,
    input      [`PE_MASK_W*`SRAM_RDATA_W-1:0] mc_resp_rdata,
    input      [`PE_MASK_W*`REQ_ID_W-1:0] mc_resp_req_id,
    input      [`PE_MASK_W*`PE_MASK_W-1:0] mc_resp_pe_mask,
    input      [`PE_MASK_W-1:0]       mc_resp_last,

    /*
     * 发给 outer readout 的 formal tile 边界。
     * 当前保持与 raw tile 一致；后续这里会变成真正的 logits tile。
     */
    output                            tile_result_valid,
    output     [`REQ_ID_W-1:0]        tile_result_req_id,
    output     [`BRANCH_NUM-1:0]      tile_result_slot_valid,
    output     [`BRANCH_NUM*`BRANCH_ID_W-1:0] tile_result_branch_id,
    output     [DEPTH_PACK_W-1:0]     tile_result_private_depth,
    output     [`BRANCH_NUM*`NODE_ID_W-1:0] tile_result_node_id,
    output     [`BRANCH_NUM*`NODE_ID_W-1:0] tile_result_parent_node_id,
    output     [1:0]                  tile_result_kind,
    output     [15:0]                 tile_result_tile_index,
    output     [`BRANCH_NUM-1:0]      tile_result_last,
    output     [`BRANCH_NUM*`SRAM_RDATA_W-1:0] tile_result_data,

    output                            busy
);

localparam [1:0] TILE_KIND_HIDDEN = 2'd0;
localparam [1:0] TILE_KIND_LOGITS = 2'd1;
localparam integer FP16_ELEMS_PER_BEAT =
    (`SRAM_RDATA_W / `FP16_TILE_DATA_W);
localparam integer MODEL_HIDDEN_BEATS =
    ((`MODEL_DMODEL + FP16_ELEMS_PER_BEAT - 1) / FP16_ELEMS_PER_BEAT);
wire postprocess_mem_landing_zone_unused_w;
wire hidden_capture_state_observed_w;
reg hidden_capture_active_r;
reg [`REQ_ID_W-1:0] hidden_capture_req_id_r;
reg [`BRANCH_NUM-1:0] hidden_expected_mask_r;
reg [`BRANCH_NUM-1:0] hidden_done_mask_r;
reg [(`BRANCH_NUM*MODEL_HIDDEN_BEATS*`SRAM_RDATA_W)-1:0]
    hidden_tile_store_r;
integer branch_i;

/*
 * 当前版本不引入新的内部状态机：
 * 1. busy 直接镜像输入 valid；
 * 2. 所有结构元数据透明直通；
 * 3. 这样先把顶层 ownership 固定住，后续再把真实数值核替换进来。
 */
assign tile_result_valid = mesh_tile_valid;
assign tile_result_req_id = mesh_tile_req_id;
assign tile_result_slot_valid = mesh_tile_slot_valid;
assign tile_result_branch_id = mesh_tile_branch_id;
assign tile_result_private_depth = mesh_tile_private_depth;
assign tile_result_node_id = mesh_tile_node_id;
assign tile_result_parent_node_id = mesh_tile_parent_node_id;
/*
 * kind 翻译是当前 postprocess 唯一已经落地的正式职责：
 * 1. mesh backend 只能声明自己产出 raw hidden tile；
 * 2. formal logits tile 的语义必须从 postprocess 开始对外生效；
 * 3. 后续真正的 hidden -> logits 数值核接入时，仍沿用这条 ownership 边界。
 */
assign tile_result_kind =
    (mesh_tile_kind == TILE_KIND_HIDDEN) ?
        TILE_KIND_LOGITS : mesh_tile_kind;
assign tile_result_tile_index = mesh_tile_tile_index;
assign tile_result_last = mesh_tile_last;
assign tile_result_data = mesh_tile_data;
assign mem_active = 1'b0;
assign vec_req_valid = {`MEM_REQ_LANES{1'b0}};
assign vec_req_write = {`MEM_REQ_LANES{1'b0}};
assign vec_req_addr = {(`MEM_REQ_LANES*`SRAM_ADDR_W){1'b0}};
assign vec_req_wdata = {(`MEM_REQ_LANES*`SRAM_WDATA_W){1'b0}};
assign vec_req_req_id = {(`MEM_REQ_LANES*`REQ_ID_W){1'b0}};
assign vec_req_pe_mask = {(`MEM_REQ_LANES*`PE_MASK_W){1'b0}};
assign vec_req_priority = {(`MEM_REQ_LANES*`REQ_PRIORITY_W){1'b0}};
assign vec_req_bank_id = {(`MEM_REQ_LANES*`BANK_ID_W){1'b0}};
assign vec_req_subbank_id = {(`MEM_REQ_LANES*`SUBBANK_ID_W){1'b0}};
assign mc_resp_ready = {`PE_MASK_W{1'b0}};
assign postprocess_mem_landing_zone_unused_w =
    ^{final_norm_gamma_addr,
      lm_head_weight_base_addr,
      vec_req_ready,
      mc_resp_valid,
      mc_resp_rdata,
      mc_resp_req_id,
      mc_resp_pe_mask,
      mc_resp_last};
assign hidden_capture_state_observed_w =
    ^{hidden_capture_req_id_r,
      hidden_expected_mask_r,
      hidden_done_mask_r,
      hidden_tile_store_r};
assign busy =
    mesh_tile_valid ||
    hidden_capture_active_r ||
    (mem_active && postprocess_mem_landing_zone_unused_w) ||
    (1'b0 && hidden_capture_state_observed_w);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        hidden_capture_active_r <= 1'b0;
        hidden_capture_req_id_r <= {`REQ_ID_W{1'b0}};
        hidden_expected_mask_r <= {`BRANCH_NUM{1'b0}};
        hidden_done_mask_r <= {`BRANCH_NUM{1'b0}};
        hidden_tile_store_r <=
            {(`BRANCH_NUM*MODEL_HIDDEN_BEATS*`SRAM_RDATA_W){1'b0}};
    end else if (mesh_tile_valid && (mesh_tile_kind == TILE_KIND_HIDDEN)) begin
        /*
         * hidden capture 鏄湡瀹?logits kernel 涔嬪墠鐨勫繀瑕佺姸鎬佽竟鐣岋細
         * 1. mesh 鎶?raw hidden tile 鎸夋媿鎺ㄩ€佽繘鏉ワ紱
         * 2. postprocess 鍏堟寜 branch/tile_index 鎶婂畠鏀跺畬锛?
         * 3. 鍚庣画 final norm / lm_head 鍙杩欎釜鍐呴儴 hidden store 璐熻矗锛屼笉鍐嶅洖澶寸储瑕?mesh 鎴栭《灞傜姸鎬併€?
         */
        if (!hidden_capture_active_r ||
            (hidden_capture_req_id_r != mesh_tile_req_id)) begin
            hidden_capture_req_id_r <= mesh_tile_req_id;
            hidden_expected_mask_r <= mesh_tile_slot_valid;
            hidden_done_mask_r <= mesh_tile_slot_valid & mesh_tile_last;
            hidden_capture_active_r <=
                ((mesh_tile_slot_valid != {`BRANCH_NUM{1'b0}}) &&
                 ((mesh_tile_slot_valid & mesh_tile_last) !=
                  mesh_tile_slot_valid));
        end else begin
            hidden_done_mask_r <=
                hidden_done_mask_r | (mesh_tile_slot_valid & mesh_tile_last);
            hidden_capture_active_r <=
                ((hidden_expected_mask_r != {`BRANCH_NUM{1'b0}}) &&
                 ((hidden_done_mask_r |
                   (mesh_tile_slot_valid & mesh_tile_last)) !=
                  hidden_expected_mask_r));
        end

        for (branch_i = 0; branch_i < `BRANCH_NUM; branch_i = branch_i + 1) begin
            if (mesh_tile_slot_valid[branch_i] &&
                ({{16{1'b0}}, mesh_tile_tile_index} < MODEL_HIDDEN_BEATS)) begin
                hidden_tile_store_r[
                    (((branch_i * MODEL_HIDDEN_BEATS) +
                      {{16{1'b0}}, mesh_tile_tile_index}) *
                     `SRAM_RDATA_W) +:
                    `SRAM_RDATA_W] <=
                    mesh_tile_data[
                        (branch_i*`SRAM_RDATA_W) +:
                        `SRAM_RDATA_W];
            end
        end
    end
end

endmodule
