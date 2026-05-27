# 第二阶段 `transformer_my` RTL 工作集说明

本目录是第二阶段 `LLM decoder-only Transformer` 算子 RTL 工作集。

## 当前目录边界

1. `primitive/`
2. `talos_reuse/`
3. `reference_only/`
4. `legacy_cnn/`
5. `config/`

其中 `config/` 当前承担三类边界文件：

1. `stage2_transformer_my_formal_workset.f`
2. `stage2_transformer_my_reference_manifest.txt`
3. `stage2_transformer_my_legacy_manifest.txt`

## 正式规则

1. 第二阶段正式目标固定为单芯粒 `LLM decoder-only Transformer`。
2. 本目录正式主链不是 `ViT`、不是 `LeViT`、不是 image transformer。
3. 正式主链语义固定为 `token / vector / head / branch / KV`。
4. 允许使用 `grouped-conv` 或 `grouped 1x1 projection` 的结构实现多头注意力。
5. 不再把 `image / pixel / receptive-field / pooling` 语义直接带入正式主链。
6. `primitive/` 和 `talos_reuse/` 是当前正式工作集来源。
7. `reference_only/` 只保留结构参考，不作为默认编译输入。
8. 明显不进入第二阶段正式主链的旧 CNN 资产，统一移入 `legacy_cnn/`。
9. 正式工作集编译入口固定为 `config/stage2_transformer_my_formal_workset.f`。

## 当前正式工作集

### 1. `primitive/fp16/`

1. `floatAdd16.v`
2. `floatMult16.v`
3. `processingElement16.v`

说明：

1. 这一组是当前最直接的 FP16 primitive。
2. 后续最小 bring-up 优先复用这一组。

### 2. `primitive/fp32/`

1. `floatAdd.v`
2. `floatMult.v`
3. `processingElement.v`

说明：

1. 这一组保留作历史兼容与数值参考。
2. 当前 stage2 最小闭环不优先依赖它们。

### 3. `primitive/projection_templates/`

1. `convUnit.v`
2. `layer.v`

说明：

1. `convUnit.v` 保留为 `grouped 1x1 projection` / 点积单元模板。
2. `layer.v` 只保留调度思路，不再视为“可直接拿来接入”的正式 primitive。
3. 这两个文件后续应派生出新的 `transformUnit1x1`、`transformLayerSingle1x1`、`transformLayerMulti1x1`。

### 4. `primitive/numeric_templates/`

1. `exponent.v`
2. `floatReciprocal.v`
3. `softmax.v`
4. `softmax_1.v`
5. `softmax_2.v`

说明：

1. 这一组是 attention score 路径的旧数值模板。
2. 它们仍需做参数化、握手和时序风格改造后，再进入正式 `IntegrationTransformPart`。
3. 当前不再把它们误表述为“已经适配好 stage2 接口”的成品模块。

### 5. `talos_reuse/`

1. `systolic_matvec16_tile.sv`
2. `processing_element.sv`
3. `matrixmul_unit.sv`
4. `rms_scale_engine.sv`
5. `sat_div16_engine.sv`
6. `microgpt_categorical_sampler.sv`
7. `include/microgpt_exact_core_math.svh`
8. `include/microgpt_exact_core_params.svh`

说明：

1. 这是从 `code/TALOS-V2-main` 中筛出的可直接复用或轻改复用工作集。
2. 它们适合作为 decoder-only Transformer 的 matvec、归一化、除法和采样引擎来源。
3. 这些文件进入了 `transformer_my`，但不等于把 `microgpt_exact_core` 整核直接带入当前主链。

## 已明确排除的外部文件

以下文件没有进入当前工作集：

1. `microgpt_exact_core.sv`
2. `de1_soc_microgpt_rtl.sv`
3. `sys_pll_56_25.v`
4. `include/microgpt_exact_core_rom_init.svh`
5. `pipeline_mac.v`
6. `pipeline_mac_wrapper.v`
7. `Attention_core.sv`
8. `Stage_2head.sv`
9. `Stage_4head.sv`
10. `Tiny_LeViT_top.sv`
11. `FIFO.sv`
12. `Divid.sv`
13. `Exp.sv`
14. `Tanh.sv`

原因统一为以下几类：

1. 板级 / PLL / JTAG 绑定
2. `readmemh` / 内置 ROM / 内置 KV cache
3. Xilinx 浮点 IP 依赖
4. 错误的 LeViT/attention 语义
5. 与当前 `LLM decoder-only Transformer` 主链不兼容

## `reference_only/` 的使用规则

1. `reference_only/vit_fpga_tpu/`
   - 保留 `systolic_array` 组织方式
   - `PE.sv` 仍依赖未复制的 vendor 浮点包装，只能看结构，不能直接编译接入
2. `reference_only/tiny_levit/`
   - 只保留 `PE_MAC`、`PE_2D`、`PE_ROW*` 一类阵列/流水结构模板
   - 不把其 attention / tanh / top-level 语义带入正式主链
3. `reference_only/` 全部文件默认不进入 stage2 正式 filelist。

## 最小 bring-up 切入点

当前建议的 `IntegrationTransformPart` 最小切入点是：

1. 先复用 `primitive/fp16/` 里的 FP16 primitive。
2. 从 `primitive/projection_templates/convUnit.v` 派生 `transformUnit1x1.v`。
3. 复用 `primitive/numeric_templates/softmax.v`、`exponent.v`、`floatReciprocal.v` 的数值路径思路。
4. 需要更干净的 matvec tile 时，优先参考 `talos_reuse/systolic_matvec16_tile.sv`。
5. `reference_only/` 不进入第一版最小闭环。

## 当前目录管理结论

1. `primitive/` 与 `talos_reuse/` 继续作为第二阶段 `transformer_my` 正式工作集。
2. `reference_only/` 只保留“外部结构参考库”定位，不进入默认 filelist。
3. `legacy_cnn/` 只保留“旧 CNN 历史参考”定位，不进入默认 filelist。
4. 后续新的 operator 级 testbench 固定放入 `code/tb/transformer_my/`。
5. 后续新的 bring-up 向量、假权重、KV 参考数据固定放入 `code/weight/transformer_my/`。
