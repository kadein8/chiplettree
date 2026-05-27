# SRAM Advanced Features Ablation Report

## Configurations

| Config | Topology | Freeze | Promotion | Isolation |
|--------|----------|--------|-----------|-----------|
| config_00_baseline | OFF | OFF | OFF | OFF |
| config_01_topology | ON | OFF | OFF | OFF |
| config_02_freeze_promote | OFF | ON | ON | OFF |
| config_03_isolation | OFF | OFF | OFF | ON |
| config_04_all_enabled | ON | ON | ON | ON |
| config_05_incremental | ON | ON | ON | ON |

## Core Metrics

| Config | total_cycles | physical_reads | physical_writes | shared_reuse_hits | promotion_hits | isolation_guard_hits |
|--------|--------------|----------------|-----------------|-------------------|----------------|----------------------|
| config_00_baseline | 74 | 2 | 5 | 0 | 0 | 0 |
| config_01_topology | 74 | 2 | 5 | 0 | 0 | 0 |
| config_02_freeze_promote | 74 | 2 | 5 | 1 | 1 | 0 |
| config_03_isolation | 74 | 2 | 5 | 0 | 0 | 1 |
| config_04_all_enabled | 74 | 2 | 5 | 1 | 1 | 1 |
| config_05_incremental | 74 | 2 | 5 | 1 | 1 | 1 |

## Relative Improvement vs Baseline

| Config | cycle_improve_pct | read_reduce_pct | shared_reuse_growth_pct |
|--------|-------------------|-----------------|-------------------------|
| config_00_baseline | baseline | baseline | baseline |
| config_01_topology | 0.00 | 0.00 | 0.00 |
| config_02_freeze_promote | 0.00 | 0.00 | 0.00 |
| config_03_isolation | 0.00 | 0.00 | 0.00 |
| config_04_all_enabled | 0.00 | 0.00 | 0.00 |
| config_05_incremental | 0.00 | 0.00 | 0.00 |

## Notes

- Read `summary.txt` and `run.log` for each config before drawing conclusions.
- High `shared_reuse_hits` and `promotion_hits` indicate freeze/promotion paths are active.
- Non-zero `isolation_guard_hits` indicates branch isolation was actually exercised.
- Improvements in private placement or physical access count indicate topology-aware mapping is active.
