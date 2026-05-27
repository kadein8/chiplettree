# SRAM 高级特性消融实验

## 实验目的

量化论文中 SRAM 管理协议关键优化部件的贡献，并把单 chiplet 计算链与 SRAM 协议级特性验证拆成两个互补层次：

1. `Step 0` 到 `Step 2` 使用 [`control_chip_stage2_single_chiplet`](/E:/Paper/Chen/first/code/rtl/tree_control/control_chip_stage2_single_chiplet.v) + [`IntegrationTransformPart`](/E:/Paper/Chen/first/code/rtl/transformer/IntegrationTransformPart.v)，覆盖单 chiplet bounded 端到端闭环与周期级吞吐。
2. `Step 3` 使用真正实例化 [`free_list.v`](/E:/Paper/Chen/first/code/rtl/tree_control/free_list.v)、[`bank_state_table.v`](/E:/Paper/Chen/first/code/rtl/tree_control/bank_state_table.v)、[`request_controller.v`](/E:/Paper/Chen/first/code/rtl/tree_control/request_controller.v) 的 SRAM 协议微基准链路，覆盖 Topology-Aware Mapping、Prefix Freeze/Promotion、Branch Isolation 与 MDV/Bypass 基础设施。

## 重要口径

1. 当前环境不运行 VCS，不运行 Python；这里只生成 RTL testbench、bash 脚本、Python 分析脚本和文档。
2. `Step 0` 使用现有 run10 做回归入口：
   `verification/stage2/10_vcs_transformer_decoder_only_operator_chain_min_bringup/scripts/run_tb_transformer_decoder_only_operator_chain_min_bringup.sh`
3. `Step 1/Step 2` 只用于单 chiplet bounded 闭环验证与测量，不夸大为 full chiplet closure 或 unbounded proof。
4. `Step 3` 不直接挂在 `control_chip_stage2_single_chiplet` 顶层上做开关实验，因为这条顶层路径本身不直接实例化 `free_list/bank_state_table`；为保证实验名实相符，`Step 3` 改为 SRAM 协议级微基准。
5. `decoderSoftmaxWindow.v` 在当前 `WINDOW_SLOTS=1` 条件下输出 `1.0`，与单元素 softmax 数学等价；本轮不修改它，只在文档里明确当前边界。

## 目录说明

- `prompts/`
  保存四个步骤的提示词文档，方便后续单独交给 AI 或做阶段复现。
- `step0_compute_fix/`
  Step 0 的产出说明。RTL 修改保留在原文件位置。
- `step1_functional_verification/`
  单 chiplet 两轮闭环功能验证。
- `step2_throughput/`
  单 chiplet 10 轮周期级吞吐量测量与日志解析。
- `step3_ablation/`
  SRAM 高级特性消融实验，覆盖 6 组配置、批量运行脚本与对比报告。

## 执行顺序

1. 先执行 `Step 0`，确认 FFN ReLU 改动不破坏现有 decoder-only 最小链路。
2. 再执行 `Step 1`，确认两轮 bounded 闭环均能走通。
3. 再执行 `Step 2`，导出 10 轮的周期级数据。
4. 最后执行 `Step 3`，做 SRAM 协议级消融并生成对比报告。

## 依赖

- VCS 仿真器
- Bash 运行环境
- Python 3.6+，仅标准库

## 当前步骤对应命令

### Step 0

```bash
bash verification/stage2/10_vcs_transformer_decoder_only_operator_chain_min_bringup/scripts/run_tb_transformer_decoder_only_operator_chain_min_bringup.sh
```

### Step 1

```bash
bash exp/sram_ablation_experiment/step1_functional_verification/scripts/run_exp_step1.sh
```

### Step 2

```bash
bash exp/sram_ablation_experiment/step2_throughput/scripts/run_exp_step2.sh
python exp/sram_ablation_experiment/step2_throughput/analyze_throughput.py \
    exp/sram_ablation_experiment/step2_throughput/logs/tb_exp_step2_run.log \
    exp/sram_ablation_experiment/step2_throughput/report.md
```

### Step 3

```bash
bash exp/sram_ablation_experiment/step3_ablation/scripts/run_exp_step3_all.sh
python exp/sram_ablation_experiment/step3_ablation/analyze_ablation.py \
    exp/sram_ablation_experiment/step3_ablation/logs \
    exp/sram_ablation_experiment/step3_ablation/report.md
```
