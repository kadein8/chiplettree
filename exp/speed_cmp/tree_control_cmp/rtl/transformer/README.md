# 第二阶段 Transformer RTL

本目录是第二阶段正式 `LLM decoder-only Transformer` RTL 工作区。

## 目录规则

1. 正式 RTL 统一收口在本目录下。
2. 本目录只允许保留一个次一级目录：`include/`。
3. 不再把旧 `ann_my`、`TALOS-V2-main`、`TPU` 参考代码直接混放为新的顶层语义。
4. 多头注意力、FFN、softmax、采样等后续正式实现都应继续向本目录收口。

## 当前正式层次

1. `transformUnit1x1.v`
   - 第二阶段第一批正式投影原语。
   - 基于旧 `convUnit` 的时序型累加结构轻改，语义改成 token 向量与权重向量的 `1x1` 投影。
2. `transformLayerSingle1x1.v`
   - 对单个输入向量并行生成多个输出投影。
3. `transformLayerMulti1x1.v`
   - 对多分支输入向量复用同一组权重，形成树结构多分支并行投影骨架。
4. `IntegrationTransformPart.v`
   - 第二阶段 `transform_mem_req_if / transform_mem_resp_if / operator_result_if` 的最小可握手骨架。
5. `decoderAttentionScore.v`
   - decoder-only attention score 最小算子。
6. `decoderSoftmaxWindow.v`
   - decoder-only attention 窗口 softmax 正式实现。
   - `WINDOW_SLOTS=1` 时按单元素 softmax 数学语义退化为 `1.0`。
   - `WINDOW_SLOTS>1` 时走 `exp -> sum -> reciprocal -> normalize` 真 softmax 链路。
7. `decoderAttentionValue.v`
   - attention value 聚合最小算子。
8. `decoderFfnUnit.v`
   - decoder-only FFN 最小算子。
9. `decoderOnlyTransformerChain.v`
   - 把 `Q/K/V -> score -> softmax -> value -> FFN` 串成单 branch、单 slice 最小主链。
10. `fp16_matvec_tile.sv`
   - 16 lane × 128 列归约的 FP16 MatVec 核心阵列。
   - 每 lane 直接复用 `floatMult16 + floatAdd16` 做逐拍累加。
11. `fp16_compute_module.sv`
   - 预加载权重/向量、驱动 `fp16_matvec_tile`、并完成 SRAM 写回的 FP16 GEMM 计算模块。

## 当前保留的可复用原语

1. `processingElement16.v`
2. `floatMult16.v`
3. `floatAdd16.v`
4. `exponent.v`
5. `floatReciprocal.v`
6. `softmax.v`

说明：

1. 当前 `decoderSoftmaxWindow.v` 已经不再复用固定 `[1.0, 0, ...]` 的桩逻辑。
2. 旧 `softmax.v` 仍保留为参考库原语，但当前正式 decoder 链路直接使用
   `decoderSoftmaxWindow.v` 内部展开的窗口 softmax 实现。
3. 从新增 FP16 GEMM 路径开始，`IntegrationOperatorPart.v` 支持：
   - `USE_FP16_GEMM=0`：原有 decoder-only 链路
   - `USE_FP16_GEMM=1`：新 `fp16_compute_module` 路径
4. 当前 `fp16_compute_module.sv` 的完整 `16 x FP16` 结果通过 `sram_wr_*`
   以 2 beat 写回；`result_data` 保持现有 stage2 `128bit` 摘要语义，
   返回低 8 lane 的第 1 个 result beat。

## 当前仍保留但不等于正式主链的文件

1. `convUnit.v`
2. `layer.v`
3. `matrixmul_unit.sv`
4. `processing_element.sv`
5. `rms_scale_engine.sv`
6. `sat_div16_engine.sv`
7. `systolic_matvec16_tile.sv`
8. `microgpt_categorical_sampler.sv`

这些文件目前仍可作为参考库，但不应被误写成第二阶段已经完成的正式 `decoder-only Transformer` 顶层。

## 当前边界提醒

1. `10_` 当前只准备证明 decoder-only operator 级最小链路，不等于单 chiplet 总装闭环。
2. `IntegrationTransformPart.v` 默认仍保持旧 pass-through 兼容模式。
3. 只有在 `ENABLE_DECODER_CHAIN=1` 时，才启用新的 decoder-only 最小链路。

