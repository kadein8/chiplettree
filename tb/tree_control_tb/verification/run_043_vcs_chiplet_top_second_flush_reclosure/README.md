# run_043_vcs_control_chip_second_flush_reclosure

## Purpose

This run is the latest VM-proven bounded Stage F top-level checkpoint after the
earlier reference point:

1. `run_042_vcs_control_chip_post_flush_reentry`

It should prove that `control_chip` can accept one second bounded
comparator/flush event on top of the `run_042` wave-2 re-entry prefix while
preserving the user-confirmed ownership split:

1. `AGU -> prefetch_queue -> free_list -> bank_state_table`
2. `AGU -> token_register`
3. `token_register lookup -> SRAM`
4. `PE -> request_controller -> SRAM -> PE response`

## Scope

Included bounded scope:

1. one wave-1 `run_041`-style bounded top-level closure
2. one post-wave-1 idle boundary
3. one wave-2 re-entry prefix aligned with `run_042`
4. one second bounded `token_register lookup -> SRAM` preparation
5. one wave-2 pre-second-flush bounded PE-side read/response completion
6. one second-wave bounded comparator/flush event
7. bounded hierarchy proof that the second flush again drives:
   - `AGU/control -> token_register`
   - `free_list -> bank_state_table` reclaim handoff
8. one later post-second-flush survivor-only continuation
9. regression re-run of:
   - `tb_control_chip_post_flush_reentry`
   - `tb_control_chip_bounded_orchestration`
   - `tb_top_level_bounded_memory_integration`
   - `tb_request_controller_wide_concurrency`

Explicitly excluded:

1. a third top-level launch
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
cd /home/ICer/first/verification/run_043_vcs_control_chip_second_flush_reclosure/scripts
bash run_all_vcs.sh
```

## Judgment Rule

Read these files before claiming PASS or FAIL:

1. `logs/run_043_summary.txt`
2. `logs/tb_control_chip_second_flush_reclosure_result.txt`
3. `logs/tb_control_chip_second_flush_reclosure_run.log`
4. `logs/tb_control_chip_post_flush_reentry_result.txt`
5. `logs/tb_control_chip_post_flush_reentry_run.log`
6. `logs/tb_control_chip_bounded_orchestration_result.txt`
7. `logs/tb_control_chip_bounded_orchestration_run.log`
8. `logs/tb_top_level_bounded_memory_integration_result.txt`
9. `logs/tb_top_level_bounded_memory_integration_run.log`
10. `logs/tb_request_controller_wide_concurrency_result.txt`
11. `logs/tb_request_controller_wide_concurrency_run.log`

## Current State

This run is now VM-proven as the latest bounded Stage F second-flush
re-closure reference point.

Evidence read for the PASS claim:

1. `logs/run_043_summary.txt` records `judge=PASS`
2. `logs/tb_control_chip_second_flush_reclosure_result.txt` records
   `judge=PASS`
3. `logs/tb_control_chip_second_flush_reclosure_run.log` contains
   `tb_control_chip_second_flush_reclosure PASS`
4. `logs/tb_control_chip_post_flush_reentry_result.txt` records `judge=PASS`
5. `logs/tb_control_chip_bounded_orchestration_result.txt` records `judge=PASS`
6. `logs/tb_top_level_bounded_memory_integration_result.txt` records
   `judge=PASS`
7. `logs/tb_request_controller_wide_concurrency_result.txt` records
   `judge=PASS`

Interpretation boundary:

1. wave 1 for `run_043` preserves `run_041`
2. the wave-2 prefix for `run_043` preserves `run_042`
3. the new proof adds one second bounded comparator/flush event in wave 2
4. the second flush again preserves the split between
   `AGU/control -> token_register` and
   `free_list -> bank_state_table` reclaim handoff
5. `run_043` still does not prove full chiplet closure
