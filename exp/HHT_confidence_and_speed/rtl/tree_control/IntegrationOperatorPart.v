`include "config/interface_params.vh"
`include "config/memory_params.vh"
`include "config/model_params.vh"
`timescale 1ns/1ps

/*
 * 文件作用：
 * 1. 本文件实现论文/整合 RTL 路径中的算子整合壳 IntegrationOperatorPart。
 * 2. 它把上游 issue 请求接进来后，根据编译参数/模式选择不同执行后端：
 *    - 传统 decoder/integration transform 路径；
 *    - fp16_gemm 计算模块；
 *    - fp16_inference_top 适配器。
 * 3. 在完整路径里，它位于：
 *    IntegrationTreeControlPart / dispatcher / issue source
 *      -> IntegrationOperatorPart
 *      -> request_controller / HBM / result
 * 4. 这个模块本身不做数值计算，它的职责是：
 *    - 选择哪条算子后端真正激活；
 *    - 把统一的 issue 接口翻译成后端各自的请求接口；
 *    - 把后端产生的 result/debug 再统一输出。
 */
module IntegrationOperatorPart #(
    parameter MODEL_ID_W = 8,
    parameter OP_CLASS_W = 8,
    parameter TOKEN_LEN_W = 16,
    parameter RESULT_STATUS_W = 2,
    parameter integer CONF_W = 8,
    parameter integer ENABLE_DECODER_CHAIN = 1,
    parameter integer DECODER_DATA_WIDTH = 16,
    parameter integer DECODER_VECTOR_DIM = 4,
    parameter integer USE_FP16_GEMM = 0,
    parameter integer USE_FP16_INFERENCE_TOP = 0,
    parameter [RESULT_STATUS_W-1:0] RESULT_STATUS_OK = 2'b00
) (
    // 时钟与复位。
    input                        clk,
    input                        rst_n,

    // 统一 issue 输入：
    // 来自 TreeControl / verify / 上层调度器。
    input                        issue_valid,
    output                       issue_ready,
    input  [`TOKEN_ID_W-1:0]     issue_token_id,
    input  [`BRANCH_ID_W-1:0]    issue_branch_id,
    input  [1:0]                 issue_epoch,
    input  [MODEL_ID_W-1:0]      issue_model_id,
    input  [OP_CLASS_W-1:0]      issue_op_class,
    input  [`SRAM_ADDR_W-1:0]    issue_src_addr,
    input  [`SRAM_ADDR_W-1:0]    issue_dst_addr,
    input  [TOKEN_LEN_W-1:0]     issue_token_len,
    input  [`REQ_ID_W-1:0]       issue_req_id,
    input  [1:0]                 issue_flush_epoch,
    input                        issue_tree_mask_en,
    input  [`BRANCH_ID_W-1:0]    issue_tree_mask_branch_id,
    input  [15:0]                issue_prefix_len,
    input  [`TOY_MAX_POS_EMB-1:0] issue_visible_mask,
    input  [15:0]                issue_position,
    input                        issue_position_ovr,

    // SRAM 操作请求输出：
    // 统一导向 request_controller。
    output                       op_req_valid,
    input                        op_req_ready,
    output                       op_req_write,
    output [`SRAM_ADDR_W-1:0]    op_req_addr,
    output [`SRAM_WDATA_W-1:0]   op_req_wdata,
    output [`REQ_ID_W-1:0]       op_req_id,
    output                       op_req_last,
    output [`TOKEN_ID_W-1:0]     op_req_tag,

    // SRAM 返回输入。
    input                        op_resp_valid,
    output                       op_resp_ready,
    input  [`SRAM_RDATA_W-1:0]   op_resp_rdata,
    input  [`REQ_ID_W-1:0]       op_resp_id,
    input                        op_resp_last,

    // HBM 返回/请求接口：
    // 当前这个整合壳只对 fp16_inference_top 预留了 HBM 相关通道。
    input                        hbm_resp_valid,
    input  [`HBM_DATA_W-1:0]     hbm_resp_rdata,
    input  [`REQ_ID_W-1:0]       hbm_resp_id,
    output                       hbm_req_valid,
    output                       hbm_req_write,
    output [`HBM_ADDR_W-1:0]     hbm_req_addr,
    output [`HBM_DATA_W-1:0]     hbm_req_wdata,
    output [`REQ_ID_W-1:0]       hbm_req_id,

    // 统一 result 输出。
    output                       result_valid,
    input                        result_ready,
    output [`TOKEN_ID_W-1:0]     result_token_id,
    output [`SRAM_ADDR_W-1:0]    result_addr,
    output [`SRAM_WDATA_W-1:0]   result_data,
    output [RESULT_STATUS_W-1:0] result_status,

    output                       debug_decoder_qkv_valid,
    output                       debug_decoder_score_valid,
    output                       debug_decoder_softmax_valid,
    output                       debug_decoder_value_valid,
    output                       debug_decoder_ffn_valid
);

// 后端选择条件：
// 1. USE_FP16_INFERENCE_TOP 优先级最高；
// 2. 其后是 USE_FP16_GEMM；
// 3. 两者都没开时，走传统 decoder/transform 路径。
wire use_fp16_inference_w = (USE_FP16_INFERENCE_TOP != 0);
wire use_fp16_gemm_w = !use_fp16_inference_w && (USE_FP16_GEMM != 0);

// decoder 路径接口。
wire decoder_issue_ready_w;
wire decoder_op_req_valid_w;
wire decoder_op_req_write_w;
wire [`SRAM_ADDR_W-1:0] decoder_op_req_addr_w;
wire [`SRAM_WDATA_W-1:0] decoder_op_req_wdata_w;
wire [`REQ_ID_W-1:0] decoder_op_req_id_w;
wire decoder_op_req_last_w;
wire [`TOKEN_ID_W-1:0] decoder_op_req_tag_w;
wire decoder_op_resp_ready_w;
wire decoder_result_valid_w;
wire [`TOKEN_ID_W-1:0] decoder_result_token_id_w;
wire [`SRAM_ADDR_W-1:0] decoder_result_addr_w;
wire [`SRAM_WDATA_W-1:0] decoder_result_data_w;
wire [RESULT_STATUS_W-1:0] decoder_result_status_w;
wire decoder_debug_qkv_w;
wire decoder_debug_score_w;
wire decoder_debug_softmax_w;
wire decoder_debug_value_w;
wire decoder_debug_ffn_w;

// fp16_gemm 路径接口。
wire fp16_gemm_issue_ready_w;
wire fp16_gemm_op_req_valid_w;
wire fp16_gemm_op_req_write_w;
wire [`SRAM_ADDR_W-1:0] fp16_gemm_op_req_addr_w;
wire [`SRAM_WDATA_W-1:0] fp16_gemm_op_req_wdata_w;
wire [`REQ_ID_W-1:0] fp16_gemm_op_req_id_w;
wire fp16_gemm_op_req_last_w;
wire [`TOKEN_ID_W-1:0] fp16_gemm_op_req_tag_w;
wire fp16_gemm_op_resp_ready_w;
wire fp16_gemm_result_valid_w;
wire [`TOKEN_ID_W-1:0] fp16_gemm_result_token_id_w;
wire [`SRAM_ADDR_W-1:0] fp16_gemm_result_addr_w;
wire [`SRAM_WDATA_W-1:0] fp16_gemm_result_data_w;
wire [RESULT_STATUS_W-1:0] fp16_gemm_result_status_w;
wire [`TOKEN_ID_W-1:0] fp16_token_id_w;
wire [`REQ_ID_W-1:0] fp16_req_id_w;

// fp16_inference_top 路径接口。
wire fp16_inf_issue_ready_w;
wire fp16_inf_op_req_valid_w;
wire fp16_inf_op_req_write_w;
wire [`SRAM_ADDR_W-1:0] fp16_inf_op_req_addr_w;
wire [`SRAM_WDATA_W-1:0] fp16_inf_op_req_wdata_w;
wire [`REQ_ID_W-1:0] fp16_inf_op_req_id_w;
wire fp16_inf_op_req_last_w;
wire [`TOKEN_ID_W-1:0] fp16_inf_op_req_tag_w;
wire fp16_inf_op_resp_ready_w;
wire fp16_inf_result_valid_w;
wire [`TOKEN_ID_W-1:0] fp16_inf_result_token_id_w;
wire [`SRAM_ADDR_W-1:0] fp16_inf_result_addr_w;
wire [`SRAM_WDATA_W-1:0] fp16_inf_result_data_w;
wire [RESULT_STATUS_W-1:0] fp16_inf_result_status_w;

// 把统一 issue / SRAM / result / debug 总线复用到当前选中的后端。
assign issue_ready =
    use_fp16_inference_w ? fp16_inf_issue_ready_w :
    (use_fp16_gemm_w ? fp16_gemm_issue_ready_w : decoder_issue_ready_w);

assign op_req_valid =
    use_fp16_inference_w ? fp16_inf_op_req_valid_w :
    (use_fp16_gemm_w ? fp16_gemm_op_req_valid_w : decoder_op_req_valid_w);
assign op_req_write =
    use_fp16_inference_w ? fp16_inf_op_req_write_w :
    (use_fp16_gemm_w ? fp16_gemm_op_req_write_w : decoder_op_req_write_w);
assign op_req_addr =
    use_fp16_inference_w ? fp16_inf_op_req_addr_w :
    (use_fp16_gemm_w ? fp16_gemm_op_req_addr_w : decoder_op_req_addr_w);
assign op_req_wdata =
    use_fp16_inference_w ? fp16_inf_op_req_wdata_w :
    (use_fp16_gemm_w ? fp16_gemm_op_req_wdata_w : decoder_op_req_wdata_w);
assign op_req_id =
    use_fp16_inference_w ? fp16_inf_op_req_id_w :
    (use_fp16_gemm_w ? fp16_gemm_op_req_id_w : decoder_op_req_id_w);
assign op_req_last =
    use_fp16_inference_w ? fp16_inf_op_req_last_w :
    (use_fp16_gemm_w ? fp16_gemm_op_req_last_w : decoder_op_req_last_w);
assign op_req_tag =
    use_fp16_inference_w ? fp16_inf_op_req_tag_w :
    (use_fp16_gemm_w ? fp16_gemm_op_req_tag_w : decoder_op_req_tag_w);
assign op_resp_ready =
    use_fp16_inference_w ? fp16_inf_op_resp_ready_w :
    (use_fp16_gemm_w ? fp16_gemm_op_resp_ready_w : decoder_op_resp_ready_w);

// 当前实现里，只有更外层/更专用模块会真正驱动 HBM；
// 这里缺省把 HBM 请求置 0。
assign hbm_req_valid = 1'b0;
assign hbm_req_write = 1'b0;
assign hbm_req_addr = {`HBM_ADDR_W{1'b0}};
assign hbm_req_wdata = {`HBM_DATA_W{1'b0}};
assign hbm_req_id = {`REQ_ID_W{1'b0}};

assign result_valid =
    use_fp16_inference_w ? fp16_inf_result_valid_w :
    (use_fp16_gemm_w ? fp16_gemm_result_valid_w : decoder_result_valid_w);
assign result_token_id =
    use_fp16_inference_w ? fp16_inf_result_token_id_w :
    (use_fp16_gemm_w ? fp16_gemm_result_token_id_w : decoder_result_token_id_w);
assign result_addr =
    use_fp16_inference_w ? fp16_inf_result_addr_w :
    (use_fp16_gemm_w ? fp16_gemm_result_addr_w : decoder_result_addr_w);
assign result_data =
    use_fp16_inference_w ? fp16_inf_result_data_w :
    (use_fp16_gemm_w ? fp16_gemm_result_data_w : decoder_result_data_w);
assign result_status =
    use_fp16_inference_w ? fp16_inf_result_status_w :
    (use_fp16_gemm_w ? fp16_gemm_result_status_w : decoder_result_status_w);

assign debug_decoder_qkv_valid =
    use_fp16_inference_w ? 1'b0 :
    (use_fp16_gemm_w ? 1'b0 : decoder_debug_qkv_w);
assign debug_decoder_score_valid =
    use_fp16_inference_w ? 1'b0 :
    (use_fp16_gemm_w ? 1'b0 : decoder_debug_score_w);
assign debug_decoder_softmax_valid =
    use_fp16_inference_w ? 1'b0 :
    (use_fp16_gemm_w ? 1'b0 : decoder_debug_softmax_w);
assign debug_decoder_value_valid =
    use_fp16_inference_w ? 1'b0 :
    (use_fp16_gemm_w ? 1'b0 : decoder_debug_value_w);
assign debug_decoder_ffn_valid =
    use_fp16_inference_w ? 1'b0 :
    (use_fp16_gemm_w ? 1'b0 : decoder_debug_ffn_w);

// fp16_gemm 模式下，需要额外记住最近一次被 issue 的 token_id/req_id，
// 因为读写请求和结果输出要继续复用这两个标签。
generate
    if (USE_FP16_GEMM != 0) begin : gen_fp16_gemm_state
        reg [`TOKEN_ID_W-1:0] fp16_token_id_r;
        reg [`REQ_ID_W-1:0] fp16_req_id_r;

        always @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                fp16_token_id_r <= {`TOKEN_ID_W{1'b0}};
                fp16_req_id_r <= {`REQ_ID_W{1'b0}};
            end else if (!use_fp16_inference_w) begin
                if (issue_valid && fp16_gemm_issue_ready_w) begin
                    // 接受一笔 fp16_gemm issue 时锁存它的 token/req 标签。
                    fp16_token_id_r <= issue_token_id;
                    fp16_req_id_r <= issue_req_id;
                end
            end
        end

        assign fp16_token_id_w = fp16_token_id_r;
        assign fp16_req_id_w = fp16_req_id_r;
    end else begin : gen_no_fp16_gemm_state
        assign fp16_token_id_w = {`TOKEN_ID_W{1'b0}};
        assign fp16_req_id_w = {`REQ_ID_W{1'b0}};
    end
endgenerate

// fp16_gemm 后端实例化与接口整理。
generate
    if (USE_FP16_GEMM != 0) begin : gen_fp16_gemm
        wire fp16_rd_valid_w;
        wire fp16_rd_ready_w;
        wire [`SRAM_ADDR_W-1:0] fp16_rd_addr_w;
        wire [`REQ_ID_W-1:0] fp16_rd_id_w;
        wire fp16_resp_ready_w;
        wire fp16_wr_valid_w;
        wire [`SRAM_ADDR_W-1:0] fp16_wr_addr_w;
        wire [`SRAM_WDATA_W-1:0] fp16_wr_data_w;

        fp16_compute_module #(
            .LANES(`FP16_TILE_LANES),
            .COLS(`FP16_TILE_COLS),
            .DATA_WIDTH(`FP16_TILE_DATA_W),
            .ADDR_W(`SRAM_ADDR_W),
            .DATA_BUS_W(`SRAM_WDATA_W),
            .TOKEN_ID_W(`TOKEN_ID_W),
            .REQ_ID_W(`REQ_ID_W),
            .RESULT_STATUS_W(RESULT_STATUS_W),
            .RESULT_STATUS_OK(RESULT_STATUS_OK)
        ) u_fp16_compute_module (
            .clk(clk),
            .rst_n(rst_n),

            // 只有在 fp16_gemm 被选中时，issue 才真正送给这个后端。
            .issue_valid(issue_valid && use_fp16_gemm_w),
            .issue_ready(fp16_gemm_issue_ready_w),
            .issue_token_id(issue_token_id),
            .issue_src_addr(issue_src_addr),
            .issue_dst_addr(issue_dst_addr),
            .issue_req_id(issue_req_id),
            .issue_weight_rows({8'd0, issue_branch_id, issue_epoch, issue_flush_epoch}),
            .issue_weight_cols(issue_token_len),
            .sram_rd_valid(fp16_rd_valid_w),
            .sram_rd_ready(fp16_rd_ready_w),
            .sram_rd_addr(fp16_rd_addr_w),
            .sram_rd_id(fp16_rd_id_w),
            .sram_resp_valid(op_resp_valid),
            .sram_resp_ready(fp16_resp_ready_w),
            .sram_resp_data(op_resp_rdata),
            .sram_resp_id(op_resp_id),
            .sram_wr_valid(fp16_wr_valid_w),
            .sram_wr_ready(op_req_ready),
            .sram_wr_addr(fp16_wr_addr_w),
            .sram_wr_data(fp16_wr_data_w),
            .result_valid(fp16_gemm_result_valid_w),
            .result_ready(result_ready),
            .result_token_id(fp16_gemm_result_token_id_w),
            .result_addr(fp16_gemm_result_addr_w),
            .result_data(fp16_gemm_result_data_w),
            .result_status(fp16_gemm_result_status_w)
        );

        // fp16_compute_module 内部把读请求和写请求拆开了；
        // 这里重新把它们复用回统一的 op_req_* 单口：
        // 写优先于读，读在没有写时占用该口。
        assign fp16_gemm_op_req_valid_w = fp16_rd_valid_w | fp16_wr_valid_w;
        assign fp16_rd_ready_w =
            op_req_ready & fp16_rd_valid_w & ~fp16_wr_valid_w;
        assign fp16_gemm_op_req_write_w = fp16_wr_valid_w;
        assign fp16_gemm_op_req_addr_w =
            fp16_wr_valid_w ? fp16_wr_addr_w : fp16_rd_addr_w;
        assign fp16_gemm_op_req_wdata_w =
            fp16_wr_valid_w ? fp16_wr_data_w : {`SRAM_WDATA_W{1'b0}};
        assign fp16_gemm_op_req_id_w =
            fp16_wr_valid_w ? fp16_req_id_w : fp16_rd_id_w;
        assign fp16_gemm_op_req_last_w = 1'b1;
        assign fp16_gemm_op_req_tag_w = fp16_token_id_w;
        assign fp16_gemm_op_resp_ready_w = fp16_resp_ready_w;
    end else begin : gen_no_fp16_gemm
        // 未启用 fp16_gemm 时，整条路径全部回 0。
        assign fp16_gemm_issue_ready_w = 1'b0;
        assign fp16_gemm_op_req_valid_w = 1'b0;
        assign fp16_gemm_op_req_write_w = 1'b0;
        assign fp16_gemm_op_req_addr_w = {`SRAM_ADDR_W{1'b0}};
        assign fp16_gemm_op_req_wdata_w = {`SRAM_WDATA_W{1'b0}};
        assign fp16_gemm_op_req_id_w = {`REQ_ID_W{1'b0}};
        assign fp16_gemm_op_req_last_w = 1'b0;
        assign fp16_gemm_op_req_tag_w = {`TOKEN_ID_W{1'b0}};
        assign fp16_gemm_op_resp_ready_w = 1'b0;
        assign fp16_gemm_result_valid_w = 1'b0;
        assign fp16_gemm_result_token_id_w = {`TOKEN_ID_W{1'b0}};
        assign fp16_gemm_result_addr_w = {`SRAM_ADDR_W{1'b0}};
        assign fp16_gemm_result_data_w = {`SRAM_WDATA_W{1'b0}};
        assign fp16_gemm_result_status_w = {RESULT_STATUS_W{1'b0}};
    end
endgenerate

// fp16_inference_top 适配器实例化。
generate
    if (USE_FP16_INFERENCE_TOP != 0) begin : gen_fp16_inference
        fp16_inference_adapter #(
            .ADDR_W(`SRAM_ADDR_W),
            .DATA_BUS_W(`SRAM_WDATA_W),
            .REQ_ID_W(`REQ_ID_W),
            .HBM_ADDR_W(`HBM_ADDR_W),
            .HBM_DATA_W(`HBM_DATA_W),
            .TOKEN_ID_W(`TOKEN_ID_W),
            .RESULT_STATUS_W(RESULT_STATUS_W),
            .RESULT_STATUS_OK(RESULT_STATUS_OK)
        ) u_fp16_inference_adapter (
            .clk(clk),
            .rst_n(rst_n),

            // 只有在 fp16_inference_top 被选中时，issue 才送到这条路径。
            .issue_valid(issue_valid && use_fp16_inference_w),
            .issue_ready(fp16_inf_issue_ready_w),
            .issue_token_id(issue_token_id),
            .issue_branch_id(issue_branch_id),
            .issue_epoch(issue_epoch),
            .issue_model_id(issue_model_id),
            .issue_op_class(issue_op_class),
            .issue_src_addr(issue_src_addr),
            .issue_dst_addr(issue_dst_addr),
            .issue_token_len(issue_token_len),
            .issue_req_id(issue_req_id),
            .issue_flush_epoch(issue_flush_epoch),
            .issue_tree_mask_en(issue_tree_mask_en),
            .issue_tree_mask_branch_id(issue_tree_mask_branch_id),
            .issue_prefix_len(issue_prefix_len),
            .issue_visible_mask(issue_visible_mask),
            .issue_position(issue_position),
            .issue_position_ovr(issue_position_ovr),
            .op_req_valid(fp16_inf_op_req_valid_w),
            .op_req_ready(op_req_ready),
            .op_req_write(fp16_inf_op_req_write_w),
            .op_req_addr(fp16_inf_op_req_addr_w),
            .op_req_wdata(fp16_inf_op_req_wdata_w),
            .op_req_id(fp16_inf_op_req_id_w),
            .op_req_last(fp16_inf_op_req_last_w),
            .op_req_tag(fp16_inf_op_req_tag_w),
            .op_resp_valid(op_resp_valid),
            .op_resp_ready(fp16_inf_op_resp_ready_w),
            .op_resp_rdata(op_resp_rdata),
            .op_resp_id(op_resp_id),
            .op_resp_last(op_resp_last),
            .result_valid(fp16_inf_result_valid_w),
            .result_ready(result_ready),
            .result_token_id(fp16_inf_result_token_id_w),
            .result_addr(fp16_inf_result_addr_w),
            .result_data(fp16_inf_result_data_w),
            .result_status(fp16_inf_result_status_w)
        );
    end else begin : gen_no_fp16_inference
        // 未启用 fp16_inference_top 时，整条路径全部回 0。
        assign fp16_inf_issue_ready_w = 1'b0;
        assign fp16_inf_op_req_valid_w = 1'b0;
        assign fp16_inf_op_req_write_w = 1'b0;
        assign fp16_inf_op_req_addr_w = {`SRAM_ADDR_W{1'b0}};
        assign fp16_inf_op_req_wdata_w = {`SRAM_WDATA_W{1'b0}};
        assign fp16_inf_op_req_id_w = {`REQ_ID_W{1'b0}};
        assign fp16_inf_op_req_last_w = 1'b0;
        assign fp16_inf_op_req_tag_w = {`TOKEN_ID_W{1'b0}};
        assign fp16_inf_op_resp_ready_w = 1'b0;
        assign fp16_inf_result_valid_w = 1'b0;
        assign fp16_inf_result_token_id_w = {`TOKEN_ID_W{1'b0}};
        assign fp16_inf_result_addr_w = {`SRAM_ADDR_W{1'b0}};
        assign fp16_inf_result_data_w = {`SRAM_WDATA_W{1'b0}};
        assign fp16_inf_result_status_w = {RESULT_STATUS_W{1'b0}};
    end
endgenerate

// 传统 decoder / integration transform 路径：
// 当前既不是 fp16_inference_top，也不是 fp16_gemm 时，走这条默认后端。
IntegrationTransformPart #(
    .MODEL_ID_W(MODEL_ID_W),
    .OP_CLASS_W(OP_CLASS_W),
    .TOKEN_LEN_W(TOKEN_LEN_W),
    .CONF_W(CONF_W),
    .ENABLE_DECODER_CHAIN(ENABLE_DECODER_CHAIN),
    .DECODER_DATA_WIDTH(DECODER_DATA_WIDTH),
    .DECODER_VECTOR_DIM(DECODER_VECTOR_DIM),
    .RESULT_STATUS_W(RESULT_STATUS_W),
    .RESULT_STATUS_OK(RESULT_STATUS_OK)
) u_integration_transform_part (
    .clk(clk),
    .rst_n(rst_n),
    .issue_valid(issue_valid && !use_fp16_inference_w && !use_fp16_gemm_w),
    .issue_ready(decoder_issue_ready_w),
    .issue_token_id(issue_token_id),
    .issue_branch_id(issue_branch_id),
    .issue_epoch(issue_epoch),
    .issue_model_id(issue_model_id),
    .issue_op_class(issue_op_class),
    .issue_src_addr(issue_src_addr),
    .issue_dst_addr(issue_dst_addr),
    .issue_token_len(issue_token_len),
    .issue_req_id(issue_req_id),
    .issue_flush_epoch(issue_flush_epoch),
    .issue_parent_node_id({`NODE_ID_W{1'b0}}),
    .issue_confidence({CONF_W{1'b0}}),
    .op_req_valid(decoder_op_req_valid_w),
    .op_req_ready(op_req_ready),
    .op_req_write(decoder_op_req_write_w),
    .op_req_addr(decoder_op_req_addr_w),
    .op_req_wdata(decoder_op_req_wdata_w),
    .op_req_id(decoder_op_req_id_w),
    .op_req_last(decoder_op_req_last_w),
    .op_req_tag(decoder_op_req_tag_w),
    .op_resp_valid(op_resp_valid),
    .op_resp_ready(decoder_op_resp_ready_w),
    .op_resp_rdata(op_resp_rdata),
    .op_resp_id(op_resp_id),
    .op_resp_last(op_resp_last),
    .result_valid(decoder_result_valid_w),
    .result_ready(result_ready),
    .result_token_id(decoder_result_token_id_w),
    .result_addr(decoder_result_addr_w),
    .result_data(decoder_result_data_w),
    .result_status(decoder_result_status_w),
    .debug_decoder_qkv_valid(decoder_debug_qkv_w),
    .debug_decoder_score_valid(decoder_debug_score_w),
    .debug_decoder_softmax_valid(decoder_debug_softmax_w),
    .debug_decoder_value_valid(decoder_debug_value_w),
    .debug_decoder_ffn_valid(decoder_debug_ffn_w)
);

endmodule
