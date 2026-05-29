# run_044_vcs_control_chip_second_flush_writeback_closure

## Purpose

This run is now the latest VM-proven bounded Stage F top-level writeback-
closure checkpoint above the earlier reference point:

1. `run_043_vcs_control_chip_second_flush_reclosure`

It should prove that `control_chip` can complete one bounded wave-2
post-second-flush survivor `commit/writeback` closure on top of the `run_043`
checkpoint while preserving the user-confirmed ownership split:

1. `AGU -> prefetch_queue -> free_list -> bank_state_table`
2. `AGU -> token_register`
3. `token_register lookup -> SRAM`
4. `PE -> request_controller -> SRAM -> PE response`

## Scope

Included bounded scope:

1. one wave-1 `run_041`-style bounded top-level closure
2. one post-wave-1 idle boundary
3. one wave-2 re-entry prefix aligned with `run_042`
4. one wave-2 second-flush checkpoint aligned with `run_043`
5. one later post-second-flush survivor-only continuation
6. one bounded wave-2 survivor `commit/writeback` action
7. one second top-level `HBM` write request
8. bounded hierarchy proof that the second flush again drives:
   - `AGU/control -> token_register`
   - `free_list -> bank_state_table` reclaim handoff
9. regression re-run of:
   - `tb_control_chip_second_flush_reclosure`
   - `tb_control_chip_post_flush_reentry`
   - `tb_control_chip_bounded_orchestration`
   - `tb_top_level_bounded_memory_integration`
   - `tb_request_controller_wide_concurrency`

Explicitly excluded:

1. a third top-level launch
2. a third bounded comparator/flush event
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
13. top-level proof of multiple-token output in one run

## VM Command

```bash
cd /home/ICer/first/verification/run_044_vcs_control_chip_second_flush_writeback_closure/scripts
bash run_all_vcs.sh
```

## Judgment Rule

Read these files before claiming PASS or FAIL:

1. `logs/run_044_summary.txt`
2. `logs/tb_control_chip_second_flush_writeback_closure_result.txt`
3. `logs/tb_control_chip_second_flush_writeback_closure_run.log`
4. `logs/tb_control_chip_second_flush_reclosure_result.txt`
5. `logs/tb_control_chip_second_flush_reclosure_run.log`
6. `logs/tb_control_chip_post_flush_reentry_result.txt`
7. `logs/tb_control_chip_post_flush_reentry_run.log`
8. `logs/tb_control_chip_bounded_orchestration_result.txt`
9. `logs/tb_control_chip_bounded_orchestration_run.log`
10. `logs/tb_top_level_bounded_memory_integration_result.txt`
11. `logs/tb_top_level_bounded_memory_integration_run.log`
12. `logs/tb_request_controller_wide_concurrency_result.txt`
13. `logs/tb_request_controller_wide_concurrency_run.log`

## Current State

The full `run_044` suite is now VM-passing.

Evidence already read:

1. `logs/run_044_summary.txt` records `judge=PASS`
2. `logs/tb_control_chip_second_flush_writeback_closure_result.txt` records
   `compile_status=PASS`
3. `logs/tb_control_chip_second_flush_writeback_closure_result.txt` records
   `run_status=PASS`
4. `logs/tb_control_chip_second_flush_writeback_closure_result.txt` records
   `judge=PASS`
5. `logs/tb_control_chip_second_flush_writeback_closure_run.log` contains
   `tb_control_chip_second_flush_writeback_closure PASS`
6. `logs/tb_control_chip_second_flush_reclosure_result.txt`,
   `logs/tb_control_chip_post_flush_reentry_result.txt`,
   `logs/tb_control_chip_bounded_orchestration_result.txt`,
   `logs/tb_top_level_bounded_memory_integration_result.txt`, and
   `logs/tb_request_controller_wide_concurrency_result.txt` each record
   `judge=PASS`
7. each corresponding regression `run.log` contains its PASS banner

Interpretation boundary at this step:

1. wave 1 for `run_044` preserves `run_041`
2. the wave-2 prefix for `run_044` preserves `run_042`
3. the wave-2 second-flush checkpoint for `run_044` preserves `run_043`
4. the second flush again preserves the split between
   `AGU/control -> token_register` and
   `free_list -> bank_state_table` reclaim handoff
5. the main TB now also proves one bounded wave-2 survivor
   `commit/writeback` closure plus one second top-level `HBM` write request
6. the bounded regression re-run confirms that `run_041`, `run_042`,
   `run_043`, `run_039`, and `run_040` checkpoints remain preserved beneath
   `run_044`
7. `run_044` still does not prove full chiplet closure or the long-term
   multi-token steady-state control target
