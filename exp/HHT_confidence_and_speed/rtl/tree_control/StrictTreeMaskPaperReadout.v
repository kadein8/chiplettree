`timescale 1ns/1ps

`include "config/interface_params.vh"
`include "config/memory_params.vh"
`include "config/model_params.vh"

/*
 * 文件作用：
 * 1. 这是 strict tree-mask 论文主链里的外层 readout 边界。
 * 2. 它位于：
 *      PaperPeArrays16x128Mesh / StrictTreeMaskPaperMeshBackend
 *          -> StrictTreeMaskPaperReadout
 *          -> lifecycle / comparator
 *    这一段正式论文后端边界上。
 * 3. 按用户裁决的“结果边界方案2”，mesh backend 只允许先输出
 *    hidden/logits tile，不能直接输出最终 token compare 语义。
 * 4. 因此本模块负责把 tile 级结果收敛成外层 token/readout 结果。
 * 5. 当前阶段先把 ownership 和握手边界收紧：
 *    - 消费 tile_result_*；
 *    - 产出 readout_result_*；
 *    - 后续真实 hidden -> logits -> argmax 数值路径继续收进这里。
 */
module StrictTreeMaskPaperReadout #(
    parameter integer PRIVATE_DEPTH_W =
        (((`MAX_VERIFY_NODES_PER_BRANCH + 1) <= 2) ? 1 :
         $clog2(`MAX_VERIFY_NODES_PER_BRANCH + 1)),
    parameter integer DEPTH_PACK_W = (`BRANCH_NUM * PRIVATE_DEPTH_W)
) (
    input                             clk,
    input                             rst_n,

    /*
     * 来自 strict mesh backend 的正式 tile 结果边界。
     * 这组输入是方案2冻结后的唯一来源，不能回退成 mesh 直接吐 token。
     */
    input                             tile_result_valid,
    input      [`REQ_ID_W-1:0]        tile_result_req_id,
    input      [`BRANCH_NUM-1:0]      tile_result_slot_valid,
    input      [`BRANCH_NUM*`BRANCH_ID_W-1:0] tile_result_branch_id,
    input      [DEPTH_PACK_W-1:0]     tile_result_private_depth,
    input      [`BRANCH_NUM*`NODE_ID_W-1:0] tile_result_node_id,
    input      [`BRANCH_NUM*`NODE_ID_W-1:0] tile_result_parent_node_id,
    input      [1:0]                  tile_result_kind,
    input      [15:0]                 tile_result_tile_index,
    input      [`BRANCH_NUM-1:0]      tile_result_last,
    input      [`BRANCH_NUM*`SRAM_RDATA_W-1:0] tile_result_data,

    /*
     * 发给 lifecycle/comparator 的外层 readout 结果。
     * 当前先导出最终 token 和 compare 需要的结构元数据。
     */
    output                            readout_result_valid,
    output     [`REQ_ID_W-1:0]        readout_result_req_id,
    output     [`BRANCH_NUM-1:0]      readout_result_slot_valid,
    output     [`BRANCH_NUM*`TOKEN_ID_W-1:0] readout_result_real_token_id,
    output     [`BRANCH_NUM*`BRANCH_ID_W-1:0] readout_result_branch_id,
    output     [DEPTH_PACK_W-1:0]     readout_result_private_depth,
    output     [`BRANCH_NUM*`NODE_ID_W-1:0] readout_result_node_id,
    output     [`BRANCH_NUM*`NODE_ID_W-1:0] readout_result_parent_node_id,

    output                            busy
);

localparam [1:0] TILE_KIND_HIDDEN = 2'd0;
localparam [1:0] TILE_KIND_LOGITS = 2'd1;
localparam integer FP16_ELEMS_PER_BEAT = (`SRAM_RDATA_W / `FP16_TILE_DATA_W);

integer branch_i;
integer elem_i;
integer token_idx_i;

/*
 * IEEE754 half 的可比较顺序键。
 * 这里只做 argmax 所需的大小关系映射：
 * - 正数：把符号位翻成 1，保持指数/尾数自然顺序；
 * - 负数：整字按位取反，使“绝对值更小的负数”排序更大。
 * 不在这里处理 NaN 的特殊语义，当前 strict 数值链默认输入是正常 logits。
 */
function [15:0] fp16_order_key;
    input [15:0] fp16_bits;
    begin
        if (fp16_bits[15]) begin
            fp16_order_key = ~fp16_bits;
        end else begin
            fp16_order_key = {1'b1, fp16_bits[14:0]};
        end
    end
endfunction

/*
 * `logits_active_r`：
 * - 表示当前正在聚合一个 strict paper bundle 的 logits tile；
 * - 只要还有 branch 没收到 `tile_result_last`，外层 readout 就保持 busy。
 */
reg logits_active_r;
reg [`BRANCH_NUM-1:0] logits_expected_mask_r;
reg [`BRANCH_NUM-1:0] logits_done_mask_r;
reg [`BRANCH_NUM-1:0] logits_argmax_valid_r;
reg [`BRANCH_NUM*`TOKEN_ID_W-1:0] logits_argmax_token_id_r;
reg [`BRANCH_NUM*16-1:0] logits_argmax_score_bits_r;

reg readout_result_valid_r;
reg [`REQ_ID_W-1:0] readout_result_req_id_r;
reg [`BRANCH_NUM-1:0] readout_result_slot_valid_r;
reg [`BRANCH_NUM*`TOKEN_ID_W-1:0] readout_result_real_token_id_r;
reg [`BRANCH_NUM*`BRANCH_ID_W-1:0] readout_result_branch_id_r;
reg [DEPTH_PACK_W-1:0] readout_result_private_depth_r;
reg [`BRANCH_NUM*`NODE_ID_W-1:0] readout_result_node_id_r;
reg [`BRANCH_NUM*`NODE_ID_W-1:0] readout_result_parent_node_id_r;

reg logits_active_next_c;
reg [`BRANCH_NUM-1:0] logits_expected_mask_next_c;
reg [`BRANCH_NUM-1:0] logits_done_mask_next_c;
reg [`BRANCH_NUM-1:0] logits_argmax_valid_next_c;
reg [`BRANCH_NUM*`TOKEN_ID_W-1:0] logits_argmax_token_id_next_c;
reg [`BRANCH_NUM*16-1:0] logits_argmax_score_bits_next_c;
reg readout_result_valid_next_c;
reg [`REQ_ID_W-1:0] readout_result_req_id_next_c;
reg [`BRANCH_NUM-1:0] readout_result_slot_valid_next_c;
reg [`BRANCH_NUM*`TOKEN_ID_W-1:0] readout_result_real_token_id_next_c;
reg [`BRANCH_NUM*`BRANCH_ID_W-1:0] readout_result_branch_id_next_c;
reg [DEPTH_PACK_W-1:0] readout_result_private_depth_next_c;
reg [`BRANCH_NUM*`NODE_ID_W-1:0] readout_result_node_id_next_c;
reg [`BRANCH_NUM*`NODE_ID_W-1:0] readout_result_parent_node_id_next_c;
reg [15:0] candidate_fp16_bits_c;
reg [15:0] candidate_order_key_c;
reg [15:0] best_fp16_bits_c;
reg [15:0] best_order_key_c;
reg [`TOKEN_ID_W-1:0] best_token_id_c;

assign readout_result_valid = readout_result_valid_r;
assign readout_result_req_id = readout_result_req_id_r;
assign readout_result_slot_valid = readout_result_slot_valid_r;
assign readout_result_real_token_id = readout_result_real_token_id_r;
assign readout_result_branch_id = readout_result_branch_id_r;
assign readout_result_private_depth = readout_result_private_depth_r;
assign readout_result_node_id = readout_result_node_id_r;
assign readout_result_parent_node_id = readout_result_parent_node_id_r;
assign busy = logits_active_r;

/*
 * 组合 next-state：
 * 1. 默认保持当前聚合状态；
 * 2. 只在 `TILE_KIND_LOGITS` 时更新 argmax；
 * 3. 当所有 active branch 都见到 `tile_result_last` 时，一次性吐出最终 token。
 */
always @* begin
    logits_active_next_c = logits_active_r;
    logits_expected_mask_next_c = logits_expected_mask_r;
    logits_done_mask_next_c = logits_done_mask_r;
    logits_argmax_valid_next_c = logits_argmax_valid_r;
    logits_argmax_token_id_next_c = logits_argmax_token_id_r;
    logits_argmax_score_bits_next_c = logits_argmax_score_bits_r;

    readout_result_valid_next_c = 1'b0;
    readout_result_req_id_next_c = readout_result_req_id_r;
    readout_result_slot_valid_next_c = readout_result_slot_valid_r;
    readout_result_real_token_id_next_c = readout_result_real_token_id_r;
    readout_result_branch_id_next_c = readout_result_branch_id_r;
    readout_result_private_depth_next_c = readout_result_private_depth_r;
    readout_result_node_id_next_c = readout_result_node_id_r;
    readout_result_parent_node_id_next_c = readout_result_parent_node_id_r;

    candidate_fp16_bits_c = 16'h0000;
    candidate_order_key_c = 16'h0000;
    best_fp16_bits_c = 16'h0000;
    best_order_key_c = 16'h0000;
    best_token_id_c = {`TOKEN_ID_W{1'b0}};

    if (tile_result_valid && (tile_result_kind == TILE_KIND_LOGITS)) begin
        /*
         * logits tile 的结构元数据在整次 readout 周期内应当一致。
         * 这里每拍都允许覆盖成同值，避免对“首拍/末拍才锁存”做额外时序假设。
         */
        readout_result_req_id_next_c = tile_result_req_id;
        readout_result_slot_valid_next_c = tile_result_slot_valid;
        readout_result_branch_id_next_c = tile_result_branch_id;
        readout_result_private_depth_next_c = tile_result_private_depth;
        readout_result_node_id_next_c = tile_result_node_id;
        readout_result_parent_node_id_next_c = tile_result_parent_node_id;

        if (!logits_active_r) begin
            logits_active_next_c = 1'b1;
            logits_expected_mask_next_c = tile_result_slot_valid;
            logits_done_mask_next_c = {`BRANCH_NUM{1'b0}};
            logits_argmax_valid_next_c = {`BRANCH_NUM{1'b0}};
            logits_argmax_token_id_next_c =
                {(`BRANCH_NUM*`TOKEN_ID_W){1'b0}};
            logits_argmax_score_bits_next_c = {(`BRANCH_NUM*16){1'b0}};
        end

        /*
         * 每个 branch 的 `tile_result_data` 是一拍 logits beat。
         * 这里按 `tile_result_tile_index` 计算它对应 vocab 里的哪一段 token，
         * 再在本拍所有 FP16 元素里更新 branch 局部 argmax。
         */
        for (branch_i = 0; branch_i < `BRANCH_NUM; branch_i = branch_i + 1) begin
            if (tile_result_slot_valid[branch_i]) begin
                best_token_id_c =
                    logits_argmax_token_id_next_c[
                        (branch_i*`TOKEN_ID_W) +: `TOKEN_ID_W];
                best_fp16_bits_c =
                    logits_argmax_score_bits_next_c[
                        (branch_i*16) +: 16];
                best_order_key_c = fp16_order_key(best_fp16_bits_c);

                for (elem_i = 0;
                     elem_i < FP16_ELEMS_PER_BEAT;
                     elem_i = elem_i + 1) begin
                    token_idx_i =
                        (tile_result_tile_index * FP16_ELEMS_PER_BEAT) + elem_i;
                    if (token_idx_i < `MODEL_VOCAB_SIZE) begin
                        candidate_fp16_bits_c =
                            tile_result_data[
                                (branch_i*`SRAM_RDATA_W) +
                                (elem_i*`FP16_TILE_DATA_W) +:
                                `FP16_TILE_DATA_W];
                        candidate_order_key_c =
                            fp16_order_key(candidate_fp16_bits_c);

                        if (!logits_argmax_valid_next_c[branch_i] ||
                            (candidate_order_key_c > best_order_key_c)) begin
                            best_token_id_c =
                                token_idx_i[`TOKEN_ID_W-1:0];
                            best_fp16_bits_c = candidate_fp16_bits_c;
                            best_order_key_c = candidate_order_key_c;
                            logits_argmax_valid_next_c[branch_i] = 1'b1;
                        end
                    end
                end

                logits_argmax_token_id_next_c[
                    (branch_i*`TOKEN_ID_W) +: `TOKEN_ID_W] =
                    best_token_id_c;
                logits_argmax_score_bits_next_c[
                    (branch_i*16) +: 16] =
                    best_fp16_bits_c;

                if (tile_result_last[branch_i]) begin
                    logits_done_mask_next_c[branch_i] = 1'b1;
                end
            end
        end

        /*
         * 只有当本次请求里所有 active branch 都收齐最后一个 logits tile，
         * 才把外层 readout 结果一次性提交给 lifecycle/comparator。
         */
        if ((logits_expected_mask_next_c != {`BRANCH_NUM{1'b0}}) &&
            (logits_done_mask_next_c == logits_expected_mask_next_c)) begin
            readout_result_valid_next_c = 1'b1;
            readout_result_slot_valid_next_c = logits_expected_mask_next_c;
            readout_result_real_token_id_next_c =
                logits_argmax_token_id_next_c;
            logits_active_next_c = 1'b0;
            logits_expected_mask_next_c = {`BRANCH_NUM{1'b0}};
            logits_done_mask_next_c = {`BRANCH_NUM{1'b0}};
            logits_argmax_valid_next_c = {`BRANCH_NUM{1'b0}};
        end
    end
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        logits_active_r <= 1'b0;
        logits_expected_mask_r <= {`BRANCH_NUM{1'b0}};
        logits_done_mask_r <= {`BRANCH_NUM{1'b0}};
        logits_argmax_valid_r <= {`BRANCH_NUM{1'b0}};
        logits_argmax_token_id_r <= {(`BRANCH_NUM*`TOKEN_ID_W){1'b0}};
        logits_argmax_score_bits_r <= {(`BRANCH_NUM*16){1'b0}};
        readout_result_valid_r <= 1'b0;
        readout_result_req_id_r <= {`REQ_ID_W{1'b0}};
        readout_result_slot_valid_r <= {`BRANCH_NUM{1'b0}};
        readout_result_real_token_id_r <= {(`BRANCH_NUM*`TOKEN_ID_W){1'b0}};
        readout_result_branch_id_r <= {(`BRANCH_NUM*`BRANCH_ID_W){1'b0}};
        readout_result_private_depth_r <= {DEPTH_PACK_W{1'b0}};
        readout_result_node_id_r <= {(`BRANCH_NUM*`NODE_ID_W){1'b0}};
        readout_result_parent_node_id_r <=
            {(`BRANCH_NUM*`NODE_ID_W){1'b0}};
    end else begin
        logits_active_r <= logits_active_next_c;
        logits_expected_mask_r <= logits_expected_mask_next_c;
        logits_done_mask_r <= logits_done_mask_next_c;
        logits_argmax_valid_r <= logits_argmax_valid_next_c;
        logits_argmax_token_id_r <= logits_argmax_token_id_next_c;
        logits_argmax_score_bits_r <= logits_argmax_score_bits_next_c;
        readout_result_valid_r <= readout_result_valid_next_c;
        readout_result_req_id_r <= readout_result_req_id_next_c;
        readout_result_slot_valid_r <= readout_result_slot_valid_next_c;
        readout_result_real_token_id_r <=
            readout_result_real_token_id_next_c;
        readout_result_branch_id_r <= readout_result_branch_id_next_c;
        readout_result_private_depth_r <=
            readout_result_private_depth_next_c;
        readout_result_node_id_r <= readout_result_node_id_next_c;
        readout_result_parent_node_id_r <=
            readout_result_parent_node_id_next_c;
    end
end

endmodule
