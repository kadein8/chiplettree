# Step 2：单 chiplet 10 轮周期级吞吐量测量

## 目标

在 Step 1 的 bounded 功能链路基础上，连续执行 10 轮最小闭环，并输出可解析的周期级性能数据。

## 产出文件

- [`tb_exp_step2.v`](/E:/Paper/Chen/first/exp/sram_ablation_experiment/step2_throughput/tb_exp_step2.v)
- [`run_exp_step2.sh`](/E:/Paper/Chen/first/exp/sram_ablation_experiment/step2_throughput/scripts/run_exp_step2.sh)
- [`analyze_throughput.py`](/E:/Paper/Chen/first/exp/sram_ablation_experiment/step2_throughput/analyze_throughput.py)
- [`report.md`](/E:/Paper/Chen/first/exp/sram_ablation_experiment/step2_throughput/report.md)

## 数据要求

testbench 结束时输出如下结构化行：

```text
PERF_METRIC,global_cycles,<值>
PERF_METRIC,total_rounds,<值>
PERF_METRIC,total_wb_tokens,<值>
PERF_METRIC,total_sram_reads,<值>
PERF_METRIC,total_sram_writes,<值>
PERF_METRIC,total_flush_events,<值>
PERF_METRIC,total_error_events,<值>
PERF_METRIC,avg_cycles_per_round,<值>
PERF_METRIC,tokens_per_cycle_x1000,<值>
PERF_ROUND,<round_id>,<start_cycle>,<wb_done_cycle>,<busy_drop_cycle>,<round_cycles>
```

## 指标口径

1. `global_cycles`
   仿真全局时钟周期数
2. `total_rounds`
   成功完成的轮次数
3. `total_wb_tokens`
   观察到的 `wb_done` 脉冲数
4. `total_sram_reads`
   通过层次引用统计 `u_dut.mem_req_valid & mem_req_ready & !mem_req_write`
5. `total_sram_writes`
   通过层次引用统计 `u_dut.mem_req_valid & mem_req_ready & mem_req_write`
6. `total_flush_events`
   当前顶层无显式 flush 脉冲，保留占位统计，预期为 0
7. `tokens_per_cycle_x1000`
   用整数输出 `tokens/cycle * 1000`

## 运行命令

```bash
bash exp/sram_ablation_experiment/step2_throughput/scripts/run_exp_step2.sh
python exp/sram_ablation_experiment/step2_throughput/analyze_throughput.py \
    exp/sram_ablation_experiment/step2_throughput/logs/tb_exp_step2_run.log \
    exp/sram_ablation_experiment/step2_throughput/report.md
```
