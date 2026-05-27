# Step 1：单 chiplet 两轮端到端功能验证

## 目标

在不夸大边界的前提下，为 [`control_chip_stage2_single_chiplet.v`](/E:/Paper/Chen/first/code/rtl/tree_control/control_chip_stage2_single_chiplet.v) 建一个两轮 bounded 功能验证：

1. 第一轮确认单轮闭环成立
2. 第二轮确认返回 idle 后可以再次启动，不被首轮残留状态破坏

## 产出文件

- [`tb_exp_step1.v`](/E:/Paper/Chen/first/exp/sram_ablation_experiment/step1_functional_verification/tb_exp_step1.v)
- [`run_exp_step1.sh`](/E:/Paper/Chen/first/exp/sram_ablation_experiment/step1_functional_verification/scripts/run_exp_step1.sh)
- `logs/`

## 设计约束

1. 基于已有 [`tb_control_chip_stage2_single_chiplet_full_top_min.v`](/E:/Paper/Chen/first/code/tb/tree_control_tb/tb_control_chip_stage2_single_chiplet_full_top_min.v) 的 task 风格扩成两轮。
2. 继续使用 `ENABLE_DECODER_CHAIN=1`。
3. 每轮都走：
   `prediction admission -> tree_window side-band -> stale 判定 -> recompute full-KV -> decoder chain -> writeback -> idle`
4. 两轮使用不同 `selected token_id / referenced token_id / referenced_position`。
5. 不把本 run 描述成 full chiplet closure 或 unbounded proof。

## 建议检查点

每轮至少检查：

1. `busy` 拉高并最终回零
2. `tree_window_valid` 被观察到
3. `recompute_req_valid` 被观察到，且 `recompute_req_reason_stale=1`
4. `debug_decoder_qkv_valid`
5. `debug_decoder_score_valid`
6. `debug_decoder_softmax_valid`
7. `debug_decoder_value_valid`
8. `debug_decoder_ffn_valid`
9. `wb_done`
10. `error_flag=0`

## 运行命令

```bash
bash exp/sram_ablation_experiment/step1_functional_verification/scripts/run_exp_step1.sh
```
