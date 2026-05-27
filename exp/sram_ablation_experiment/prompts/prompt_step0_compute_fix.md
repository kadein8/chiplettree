# Step 0：完善 IntegrationTransformPart 的计算路径

## 目标

当前 [`IntegrationTransformPart.v`](/E:/Paper/Chen/first/code/rtl/transformer/IntegrationTransformPart.v) 在 `ENABLE_DECODER_CHAIN=1` 时已经能走通最小 decoder-only 链路，但 FFN 仍缺少激活函数。本步骤只做最小修补，不改变既有接口和层次。

## 当前结论

### 1. `decoderSoftmaxWindow.v` 当前不改

文件：
[`code/rtl/transformer/decoderSoftmaxWindow.v`](/E:/Paper/Chen/first/code/rtl/transformer/decoderSoftmaxWindow.v)

原因：

1. 当前最小原型固定 `WINDOW_SLOTS=1`。
2. 单元素 softmax 的数学结果恒为 `1.0`。
3. 当前实现输出 `FP_ONE`，在这个边界内等价成立。

因此：

- 本步骤不修改 `decoderSoftmaxWindow.v`
- 后续如扩成多槽 attention window，再替换成完整 softmax 实现

### 2. `decoderFfnUnit.v` 需要补 ReLU

文件：
[`code/rtl/transformer/decoderFfnUnit.v`](/E:/Paper/Chen/first/code/rtl/transformer/decoderFfnUnit.v)

当前问题：

- Layer1 和 Layer2 之间没有激活函数，FFN 仍是纯线性映射

修补要求：

1. 不改 port list
2. 不改 `DATA_WIDTH=16`、`VECTOR_DIM=4` 参数体系
3. 不新增子模块
4. 只在 `hidden_value_r` 和 Layer2 输入之间插一个 inline ReLU

参考实现方式：

```verilog
genvar gi;
generate
    for (gi = 0; gi < VECTOR_DIM; gi = gi + 1) begin : gen_relu
        assign hidden_after_relu_w[(gi*DATA_WIDTH) +: DATA_WIDTH] =
            hidden_value_r[(gi*DATA_WIDTH) + DATA_WIDTH - 1] ?
                {DATA_WIDTH{1'b0}} :
                hidden_value_r[(gi*DATA_WIDTH) +: DATA_WIDTH];
    end
endgenerate
```

然后把 Layer2 输入从 `hidden_value_r` 改成 `hidden_after_relu_w`。

### 3. 顶层参数传递只做确认，不重构

文件：
[`code/rtl/tree_control/control_chip_stage2_single_chiplet.v`](/E:/Paper/Chen/first/code/rtl/tree_control/control_chip_stage2_single_chiplet.v)

确认点：

1. `ENABLE_DECODER_CHAIN` 已从顶层参数透传给 `IntegrationTransformPart`
2. 当前不需要改动该透传路径

## 验证命令

本地不执行，由用户手动运行：

```bash
bash verification/stage2/10_vcs_transformer_decoder_only_operator_chain_min_bringup/scripts/run_tb_transformer_decoder_only_operator_chain_min_bringup.sh
```

## PASS 判定

只认以下三类文件：

1. `summary`
2. `result`
3. `run.log`

若 run10 继续 `judge=PASS`，则 Step 0 完成。
