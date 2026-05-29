# run_046_vcs_control_chip_third_flush_reclosure

## Purpose

This run is the selected next bounded Stage F top-level control target above
the latest VM-proven post-second-flush re-entry reference point:

1. `run_045_vcs_control_chip_post_second_flush_reentry`

It should prove that `control_chip` can accept one third bounded
comparator/flush event after the `run_045` third-wave re-entry prefix, and can
still finish one later survivor-only continuation while preserving the
user-confirmed ownership split:

1. `AGU -> prefetch_queue -> free_list -> bank_state_table`
2. `AGU -> token_register`
3. `token_register lookup -> SRAM`
4. `PE -> request_controller -> SRAM -> PE response`

## Scope

Included bounded scope:

1. one wave-1 `run_041`-style bounded top-level closure
2. one wave-2 `run_044`-style second-flush writeback closure
3. one real idle boundary after the wave-2 writeback closure
4. one third bounded top-level launch matching the `run_045` re-entry prefix
5. one third bounded allocation/status path walk
6. one third bounded metadata path walk
7. one third bounded `token_register lookup -> SRAM` preparation
8. one third bounded PE-side completion before the third flush
9. one third bounded comparator/flush event
10. one later survivor-only continuation after the third flush
11. regression re-run of:
    - `tb_control_chip_post_second_flush_reentry`
    - `tb_control_chip_second_flush_writeback_closure`
    - `tb_control_chip_second_flush_reclosure`
    - `tb_control_chip_post_flush_reentry`
    - `tb_control_chip_bounded_orchestration`
    - `tb_top_level_bounded_memory_integration`
    - `tb_request_controller_wide_concurrency`

Explicitly excluded:

1. a third bounded `commit/writeback` closure
2. a third top-level `HBM` write request
3. a fourth top-level launch
4. a real external `HBM` read-response dependency
5. full compute-module RTL
6. full prediction-unit RTL
7. full chiplet closure
8. multi-chiplet behavior
9. direct `comparator -> token_register`
10. direct `comparator -> bank_state_table`
11. `bank_state_table -> token_register`
12. direct `token_register lookup -> request_controller`
13. SRAM internal flush
14. top-level proof of multiple-token output in one run

## VM Command

```bash
cd /home/ICer/first/verification/run_046_vcs_control_chip_third_flush_reclosure/scripts
bash run_all_vcs.sh
```

## Judgment Rule

Read these files before claiming PASS or FAIL:

1. `logs/run_046_summary.txt`
2. `logs/tb_control_chip_third_flush_reclosure_result.txt`
3. `logs/tb_control_chip_third_flush_reclosure_run.log`
4. `logs/tb_control_chip_post_second_flush_reentry_result.txt`
5. `logs/tb_control_chip_post_second_flush_reentry_run.log`
6. `logs/tb_control_chip_second_flush_writeback_closure_result.txt`
7. `logs/tb_control_chip_second_flush_writeback_closure_run.log`
8. `logs/tb_control_chip_second_flush_reclosure_result.txt`
9. `logs/tb_control_chip_second_flush_reclosure_run.log`
10. `logs/tb_control_chip_post_flush_reentry_result.txt`
11. `logs/tb_control_chip_post_flush_reentry_run.log`
12. `logs/tb_control_chip_bounded_orchestration_result.txt`
13. `logs/tb_control_chip_bounded_orchestration_run.log`
14. `logs/tb_top_level_bounded_memory_integration_result.txt`
15. `logs/tb_top_level_bounded_memory_integration_run.log`
16. `logs/tb_request_controller_wide_concurrency_result.txt`
17. `logs/tb_request_controller_wide_concurrency_run.log`

## Current State

`run_046` is now VM-proven.

Interpretation boundary:

1. `run_045` remains the bounded Stage F re-entry reference point beneath
   `run_046`
2. `run_046` proves exactly one third bounded comparator/flush event above
   the `run_045` wave-3 preflush prefix
3. `run_046` proves both `token_flush_valid` and `flush_reclaim_valid`
4. `run_046` still finishes one later survivor-only continuation
5. `run_046` does not require a third writeback closure
6. `run_046` does not require a third top-level `HBM` write request
7. `run_047` is now the planned next bounded third-flush writeback-closure
   target
8. `run_046` still does not prove full chiplet closure or the long-term
   multi-token steady-state control target
