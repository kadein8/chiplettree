# run_047_vcs_control_chip_third_flush_writeback_closure

## Purpose

This run is the latest VM-proven bounded Stage F top-level control checkpoint
above the third-flush re-closure reference point:

1. `run_046_vcs_control_chip_third_flush_reclosure`

It proves that `control_chip` can complete one bounded wave-3
post-third-flush survivor `commit/writeback` closure, emit one third top-level
`HBM` write request, and still preserve the user-confirmed ownership split:

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
11. one bounded wave-3 `commit/writeback` closure after that third flush
12. one third top-level `HBM` write request
13. regression re-run of:
    - `tb_control_chip_third_flush_reclosure`
    - `tb_control_chip_post_second_flush_reentry`
    - `tb_control_chip_second_flush_writeback_closure`
    - `tb_control_chip_second_flush_reclosure`
    - `tb_control_chip_post_flush_reentry`
    - `tb_control_chip_bounded_orchestration`
    - `tb_top_level_bounded_memory_integration`
    - `tb_request_controller_wide_concurrency`

Explicitly excluded:

1. a fourth top-level launch
2. a fourth bounded comparator/flush event
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
14. steady-state next-round continuation

## VM Command

```bash
cd /home/ICer/first/verification/run_047_vcs_control_chip_third_flush_writeback_closure/scripts
bash run_all_vcs.sh
```

## Judgment Rule

Read these files before claiming PASS or FAIL:

1. `logs/run_047_summary.txt`
2. `logs/tb_control_chip_third_flush_writeback_closure_result.txt`
3. `logs/tb_control_chip_third_flush_writeback_closure_run.log`
4. `logs/tb_control_chip_third_flush_reclosure_result.txt`
5. `logs/tb_control_chip_third_flush_reclosure_run.log`
6. `logs/tb_control_chip_post_second_flush_reentry_result.txt`
7. `logs/tb_control_chip_post_second_flush_reentry_run.log`
8. `logs/tb_control_chip_second_flush_writeback_closure_result.txt`
9. `logs/tb_control_chip_second_flush_writeback_closure_run.log`
10. `logs/tb_control_chip_second_flush_reclosure_result.txt`
11. `logs/tb_control_chip_second_flush_reclosure_run.log`
12. `logs/tb_control_chip_post_flush_reentry_result.txt`
13. `logs/tb_control_chip_post_flush_reentry_run.log`
14. `logs/tb_control_chip_bounded_orchestration_result.txt`
15. `logs/tb_control_chip_bounded_orchestration_run.log`
16. `logs/tb_top_level_bounded_memory_integration_result.txt`
17. `logs/tb_top_level_bounded_memory_integration_run.log`
18. `logs/tb_request_controller_wide_concurrency_result.txt`
19. `logs/tb_request_controller_wide_concurrency_run.log`

## Current State

`run_047` is now VM-proven.

Latest VM-side result:

1. `logs/run_047_summary.txt` records `judge=PASS`
2. `logs/tb_control_chip_third_flush_writeback_closure_result.txt` records
   `compile_status=PASS`, `run_status=PASS`, and `judge=PASS`
3. `logs/tb_control_chip_third_flush_writeback_closure_run.log` contains
   `tb_control_chip_third_flush_writeback_closure PASS`
4. the regression `*_result.txt` files for
   `tb_control_chip_third_flush_reclosure`,
   `tb_control_chip_post_second_flush_reentry`,
   `tb_control_chip_second_flush_writeback_closure`,
   `tb_control_chip_second_flush_reclosure`,
   `tb_control_chip_post_flush_reentry`,
   `tb_control_chip_bounded_orchestration`,
   `tb_top_level_bounded_memory_integration`, and
   `tb_request_controller_wide_concurrency` each record `judge=PASS`
5. the corresponding regression `*_run.log` files each contain their PASS
   banner

Interpretation boundary:

1. `run_046` remains the bounded Stage F third-flush re-closure reference
   point beneath `run_047`
2. `run_047` adds exactly one bounded wave-3 post-third-flush
   `commit/writeback` closure above the `run_046` checkpoint
3. `run_047` also adds one third top-level `HBM` write request
4. `run_047` still preserves both `token_flush_valid` and
   `flush_reclaim_valid` at the third-flush checkpoint
5. `run_047` still keeps the ownership split intact
6. `run_047` is now the latest bounded Stage F third-flush
   writeback-closure reference point
7. `run_047` is not allowed to claim full chiplet closure or the long-term
   multi-token steady-state control target
