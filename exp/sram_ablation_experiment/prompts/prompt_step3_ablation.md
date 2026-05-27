# Step 3：SRAM 高级特性消融实验

## 先说明实验口径修正

这一轮不能直接把 `ENABLE_*` 开关挂在
[`control_chip_stage2_single_chiplet.v`](/E:/Paper/Chen/first/code/rtl/tree_control/control_chip_stage2_single_chiplet.v)
上做对比，因为这条顶层路径本身不直接实例化：

1. [`free_list.v`](/E:/Paper/Chen/first/code/rtl/tree_control/free_list.v)
2. [`bank_state_table.v`](/E:/Paper/Chen/first/code/rtl/tree_control/bank_state_table.v)

为了让“SRAM 高级特性消融”名实相符，Step 3 改用真正覆盖以下链路的微基准：

`free_list -> bank_state_table -> request_controller -> sram_subsystem`

参考基线 testbench：
[`tb_tree_control_stage2_sram_advanced_features_full.v`](/E:/Paper/Chen/first/code/tb/tree_control_tb/tb_tree_control_stage2_sram_advanced_features_full.v)

## 目标

按配置开关量化以下特性：

1. Topology-Aware Mapping
2. Shared Prefix Freeze
3. Prefix Promotion
4. Branch Isolation
5. MDV / merge / bypass 作为固定基础设施持续开启并观测

## 产出文件

- [`tb_exp_step3.v`](/E:/Paper/Chen/first/exp/sram_ablation_experiment/step3_ablation/tb_exp_step3.v)
- [`run_exp_step3_all.sh`](/E:/Paper/Chen/first/exp/sram_ablation_experiment/step3_ablation/scripts/run_exp_step3_all.sh)
- [`analyze_ablation.py`](/E:/Paper/Chen/first/exp/sram_ablation_experiment/step3_ablation/analyze_ablation.py)
- [`report.md`](/E:/Paper/Chen/first/exp/sram_ablation_experiment/step3_ablation/report.md)

## 配置定义

| 配置 | Topology | Freeze | Promotion | Isolation | 说明 |
|------|----------|--------|-----------|-----------|------|
| `config_00_baseline` | 0 | 0 | 0 | 0 | 全关 |
| `config_01_topology` | 1 | 0 | 0 | 0 | 仅分区映射 |
| `config_02_freeze_promote` | 0 | 1 | 1 | 0 | 仅共享前缀冻结与提权 |
| `config_03_isolation` | 0 | 0 | 0 | 1 | 仅分支隔离 |
| `config_04_all_enabled` | 1 | 1 | 1 | 1 | 全开 |
| `config_05_incremental` | 1 | 1 | 1 | 1 | 累加终态快照 |

说明：

1. `ENABLE_PREFIX_PROMOTION` 只属于 `bank_state_table`，不要错误地下传给 `free_list`。
2. `request_controller` 的 merge/bypass 机制始终开启，不做单独开关。

## 建议输出指标

testbench 应输出：

```text
PERF_METRIC,total_cycles,<值>
PERF_METRIC,private_region_hits,<值>
PERF_METRIC,shared_reuse_hits,<值>
PERF_METRIC,promotion_hits,<值>
PERF_METRIC,isolation_guard_hits,<值>
PERF_METRIC,occupied_subbanks,<值>
PERF_METRIC,physical_reads,<值>
PERF_METRIC,physical_writes,<值>
PERF_METRIC,mdv_response_lanes,<值>
```

## 运行命令

```bash
bash exp/sram_ablation_experiment/step3_ablation/scripts/run_exp_step3_all.sh
python exp/sram_ablation_experiment/step3_ablation/analyze_ablation.py \
    exp/sram_ablation_experiment/step3_ablation/logs \
    exp/sram_ablation_experiment/step3_ablation/report.md
```
