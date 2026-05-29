# 第二阶段 Transformer Testbench

本目录是第二阶段正式 `LLM decoder-only Transformer` 算子、层次模块和最小 bring-up 的 testbench 入口。

## 使用规则

1. 新的 operator 级和 integration 级 testbench 固定新建在本目录下。
2. 本目录服务于 `code/rtl/transformer/` 正式工作集，不再使用迁移前工作区作为新增 testbench 根目录。
3. 旧 `ann_my/legacy_cnn/` 样例只保留历史参考作用，不作为本目录的替代入口。

## 当前第一批入口

1. `tb_transform_unit1x1.v`
   - 对第一批 `1x1` 投影原语做最小行为检查。
2. `tb_integration_transform_part_min.v`
   - 对 `IntegrationTransformPart` 的最小 `issue -> mem req/resp -> result -> idle` 闭环做 operator 级检查。
3. `tb_integration_transform_part_decoder_only_chain_min.v`
   - 对 `IntegrationTransformPart` 在 `ENABLE_DECODER_CHAIN=1` 下的
     `Q/K/V -> score -> softmax -> value -> FFN -> result -> idle`
     最小链路做 operator 级检查。
4. `tb_decoder_softmax_window_real.v`
   - 对 `decoderSoftmaxWindow.v` 的多槽真实 softmax 行为做最小检查，
     用于确认它已不再是固定 `[1.0, 0, ...]` 桩逻辑。
5. `tb_integration_operator_part_real.v`
   - 对 `IntegrationOperatorPart.v` 的真实
     `issue -> op_req -> op_resp -> result -> idle` 闭环做检查，
     并确认内部 decoder-only 算子链已被实际 traversed。
6. `fp16_matvec_tile_tb.sv`
   - 对 `fp16_matvec_tile.sv` 的 `16 lane x 128 col` FP16 MatVec 原语做最小检查。
   - 覆盖零向量、全 1、全 2、lane-pattern 四类场景。
7. `tb_integration_operator_part_fp16_gemm_min.sv`
   - 对 `IntegrationOperatorPart.v` 在 `USE_FP16_GEMM=1` 下的
     `issue -> SRAM read -> MatVec -> 2 beat writeback -> result summary`
     最小闭环做检查。

## 后续建议新增

1. `tb_transform_layer_single1x1.v`
2. `tb_transform_layer_multi1x1.v`
3. `tb_attention_softmax_path.v`

