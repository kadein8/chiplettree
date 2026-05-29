# run_042_vcs_control_chip_post_flush_reentry

## Purpose

This run is the bounded Stage F post-flush re-entry target that followed the
VM-passing reference point:

1. `run_041_vcs_control_chip_bounded_orchestration`

It should prove one bounded post-flush top-level re-entry slice while
preserving the user-confirmed ownership split:

1. `AGU -> prefetch_queue -> free_list -> bank_state_table`
2. `AGU -> token_register`
3. `token_register lookup -> SRAM`
4. `PE -> request_controller -> SRAM -> PE response`

## Scope

Included bounded scope:

1. one wave-1 `run_041`-style bounded top-level closure
2. one post-wave-1 idle boundary
3. one second bounded top-level launch
4. one second bounded `token_register lookup -> SRAM` preparation
5. one second bounded PE-side read/response completion
6. regression re-run of:
   - `tb_control_chip_bounded_orchestration`
   - `tb_top_level_bounded_memory_integration`
   - `tb_request_controller_wide_concurrency`

Explicitly excluded:

1. a second required comparator/flush event
2. a second required top-level `HBM` writeback closure
3. a real external `HBM` read-response dependency
4. full compute-module RTL
5. full prediction-unit RTL
6. full chiplet closure
7. multi-chiplet behavior
8. direct `comparator -> token_register`
9. direct `comparator -> bank_state_table`
10. `bank_state_table -> token_register`
11. direct `token_register lookup -> request_controller`
12. SRAM internal flush

## VM Command

```bash
cd /home/ICer/first/verification/run_042_vcs_control_chip_post_flush_reentry/scripts
bash run_all_vcs.sh
```

## Judgment Rule

Read these files before claiming PASS or FAIL:

1. `logs/run_042_summary.txt`
2. `logs/tb_control_chip_post_flush_reentry_result.txt`
3. `logs/tb_control_chip_post_flush_reentry_run.log`
4. `logs/tb_control_chip_bounded_orchestration_result.txt`
5. `logs/tb_control_chip_bounded_orchestration_run.log`
6. `logs/tb_top_level_bounded_memory_integration_result.txt`
7. `logs/tb_top_level_bounded_memory_integration_run.log`
8. `logs/tb_request_controller_wide_concurrency_result.txt`
9. `logs/tb_request_controller_wide_concurrency_run.log`

## Current State

This run is now VM-proven as the latest bounded Stage F post-flush re-entry
reference point.

Evidence read for the PASS claim:

1. `logs/run_042_summary.txt` records `judge=PASS`
2. `logs/tb_control_chip_post_flush_reentry_result.txt` records `judge=PASS`
3. `logs/tb_control_chip_post_flush_reentry_run.log` contains
   `tb_control_chip_post_flush_reentry PASS`
4. `logs/tb_control_chip_bounded_orchestration_result.txt` records `judge=PASS`
5. `logs/tb_top_level_bounded_memory_integration_result.txt` records
   `judge=PASS`
6. `logs/tb_request_controller_wide_concurrency_result.txt` records
   `judge=PASS`

Interpretation boundary:

1. wave 1 preserves the `run_041` bounded closure shape
2. wave 2 proves bounded re-entry without requiring a second
   comparator/flush or a second top-level writeback closure
3. `run_042` still does not prove full chiplet closure
4. `run_042` still does not permit direct `comparator -> token_register`,
   direct `comparator -> bank_state_table`, `bank_state_table -> token_register`,
   direct `token_register lookup -> request_controller`, or SRAM internal flush
