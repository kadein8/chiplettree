# run_048_vcs_control_chip_variable_len_token_writeback

## Purpose

This run is the selected next bounded Stage F top-level target above the latest
VM-proven third-flush writeback reference point:

1. `run_047_vcs_control_chip_third_flush_writeback_closure`

It is selected to prove that `control_chip` can emit one bounded single-beat
top-level writeback packet carrying:

1. the real accepted `new_token_len`
2. `token0`
3. `token1`
4. `token2`

for one already-selected survivor branch while still preserving the
user-confirmed ownership split:

1. `AGU -> prefetch_queue -> free_list -> bank_state_table`
2. `AGU -> token_register`
3. `token_register lookup -> SRAM`
4. `PE -> request_controller -> SRAM -> PE response`

## Scope

Included bounded scope:

1. one dedicated `run_048` top-level mode
2. bounded single-beat top-level writeback packet proof only
3. exact payload proof for `new_token_len = 1`
4. exact payload proof for `new_token_len = 2`
5. exact payload proof for `new_token_len = 3`
6. exact field order proof for `token0`, `token1`, and `token2`
7. regression re-run of:
   - `tb_control_chip_third_flush_writeback_closure`
   - `tb_control_chip_third_flush_reclosure`
   - `tb_control_chip_post_second_flush_reentry`
   - `tb_control_chip_second_flush_writeback_closure`
   - `tb_control_chip_second_flush_reclosure`
   - `tb_control_chip_post_flush_reentry`
   - `tb_control_chip_bounded_orchestration`
   - `tb_top_level_bounded_memory_integration`
   - `tb_request_controller_wide_concurrency`

Explicitly excluded:

1. a new comparator/flush event in the same proof
2. a new survivor-selection proof in the same proof
3. multi-beat top-level writeback
4. multiple accepted branches in one packet
5. accepted new-token count beyond `3`
6. direct `comparator -> token_register`
7. direct `comparator -> bank_state_table`
8. `bank_state_table -> token_register`
9. direct `token_register lookup -> request_controller`
10. SRAM internal flush
11. full chiplet closure
12. steady-state next-round continuation

## VM Command

```bash
cd /home/ICer/first/verification/run_048_vcs_control_chip_variable_len_token_writeback/scripts
bash run_all_vcs.sh
```

## Judgment Rule

Read these files before claiming PASS or FAIL:

1. `logs/run_048_summary.txt`
2. `logs/tb_control_chip_variable_len_token_writeback_result.txt`
3. `logs/tb_control_chip_variable_len_token_writeback_run.log`
4. `logs/tb_control_chip_third_flush_writeback_closure_result.txt`
5. `logs/tb_control_chip_third_flush_writeback_closure_run.log`
6. `logs/tb_control_chip_third_flush_reclosure_result.txt`
7. `logs/tb_control_chip_third_flush_reclosure_run.log`
8. `logs/tb_control_chip_post_second_flush_reentry_result.txt`
9. `logs/tb_control_chip_post_second_flush_reentry_run.log`
10. `logs/tb_control_chip_second_flush_writeback_closure_result.txt`
11. `logs/tb_control_chip_second_flush_writeback_closure_run.log`
12. `logs/tb_control_chip_second_flush_reclosure_result.txt`
13. `logs/tb_control_chip_second_flush_reclosure_run.log`
14. `logs/tb_control_chip_post_flush_reentry_result.txt`
15. `logs/tb_control_chip_post_flush_reentry_run.log`
16. `logs/tb_control_chip_bounded_orchestration_result.txt`
17. `logs/tb_control_chip_bounded_orchestration_run.log`
18. `logs/tb_top_level_bounded_memory_integration_result.txt`
19. `logs/tb_top_level_bounded_memory_integration_run.log`
20. `logs/tb_request_controller_wide_concurrency_result.txt`
21. `logs/tb_request_controller_wide_concurrency_run.log`

## Current State

`run_048` is now VM-proven.

Interpretation boundary:

1. `run_048` is now the latest VM-proven bounded Stage F checkpoint
2. `run_047` remains the bounded third-flush writeback-closure reference point
   beneath `run_048`
3. `run_048` proves only the bounded top-level variable-length accepted-token
   packet proof with `new_token_len` in `{1, 2, 3}`
4. the PASS judgment is based on `logs/run_048_summary.txt`, the per-TB
   `*_result.txt` files, and the per-TB `*_run.log` PASS banners
5. `run_048` is still not allowed to claim full chiplet closure, steady-state
   next-round continuation, or the long-term multi-token control target
