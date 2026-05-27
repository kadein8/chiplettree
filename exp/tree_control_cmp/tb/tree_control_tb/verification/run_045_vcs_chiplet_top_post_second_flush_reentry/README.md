# run_045_vcs_control_chip_post_second_flush_reentry

## Purpose

This run is now the latest VM-proven bounded Stage F top-level re-entry
checkpoint above the earlier writeback-closure reference point:

1. `run_044_vcs_control_chip_second_flush_writeback_closure`

It should prove that `control_chip` can accept one third bounded top-level
launch after the full `run_044` second-flush writeback closure, and can finish
one new bounded `prepare -> PE consume -> completion` wave while preserving
the user-confirmed ownership split:

1. `AGU -> prefetch_queue -> free_list -> bank_state_table`
2. `AGU -> token_register`
3. `token_register lookup -> SRAM`
4. `PE -> request_controller -> SRAM -> PE response`

## Scope

Included bounded scope:

1. one wave-1 `run_041`-style bounded top-level closure
2. one wave-2 `run_044`-style second-flush writeback closure
3. one real idle boundary after the wave-2 writeback closure
4. one third bounded top-level launch
5. one third bounded allocation/status path walk
6. one third bounded metadata path walk
7. one third bounded `token_register lookup -> SRAM` preparation
8. one third bounded PE-side read/response completion
9. regression re-run of:
   - `tb_control_chip_second_flush_writeback_closure`
   - `tb_control_chip_second_flush_reclosure`
   - `tb_control_chip_post_flush_reentry`
   - `tb_control_chip_bounded_orchestration`
   - `tb_top_level_bounded_memory_integration`
   - `tb_request_controller_wide_concurrency`

Explicitly excluded:

1. a third bounded comparator/flush event
2. a third bounded `commit/writeback` closure
3. a third top-level `HBM` write request
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
cd /home/ICer/first/verification/run_045_vcs_control_chip_post_second_flush_reentry/scripts
bash run_all_vcs.sh
```

## Judgment Rule

Read these files before claiming PASS or FAIL:

1. `logs/run_045_summary.txt`
2. `logs/tb_control_chip_post_second_flush_reentry_result.txt`
3. `logs/tb_control_chip_post_second_flush_reentry_run.log`
4. `logs/tb_control_chip_second_flush_writeback_closure_result.txt`
5. `logs/tb_control_chip_second_flush_writeback_closure_run.log`
6. `logs/tb_control_chip_second_flush_reclosure_result.txt`
7. `logs/tb_control_chip_second_flush_reclosure_run.log`
8. `logs/tb_control_chip_post_flush_reentry_result.txt`
9. `logs/tb_control_chip_post_flush_reentry_run.log`
10. `logs/tb_control_chip_bounded_orchestration_result.txt`
11. `logs/tb_control_chip_bounded_orchestration_run.log`
12. `logs/tb_top_level_bounded_memory_integration_result.txt`
13. `logs/tb_top_level_bounded_memory_integration_run.log`
14. `logs/tb_request_controller_wide_concurrency_result.txt`
15. `logs/tb_request_controller_wide_concurrency_run.log`

## Current State

`run_045` is now VM-proven.

Verified interpretation boundary:

1. `run_044` remains the latest VM-proven bounded Stage F writeback-closure
   reference point beneath `run_045`
2. `run_045` proves one third bounded top-level re-entry wave only
3. `run_045` does not require a third flush
4. `run_045` does not require a third writeback
5. `run_045` does not require a third top-level `HBM` write request
6. `run_046` remains the planned next bounded third-flush re-closure target
7. `run_047` remains the later bounded third-flush writeback-closure target
8. `run_045` still does not prove full chiplet closure or the long-term
   multi-token steady-state control target
