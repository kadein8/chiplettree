# Step 0 说明

本步骤只做最小计算链修补：

1. [`decoderFfnUnit.v`](/E:/Paper/Chen/first/code/rtl/transformer/decoderFfnUnit.v) 在 Layer1 和 Layer2 之间加入 inline ReLU。
2. [`decoderSoftmaxWindow.v`](/E:/Paper/Chen/first/code/rtl/transformer/decoderSoftmaxWindow.v) 当前 `WINDOW_SLOTS=1` 下不改，因为与单元素 softmax 等价。

验证入口仍然使用现有 run10：

```bash
bash verification/stage2/10_vcs_transformer_decoder_only_operator_chain_min_bringup/scripts/run_tb_transformer_decoder_only_operator_chain_min_bringup.sh
```
