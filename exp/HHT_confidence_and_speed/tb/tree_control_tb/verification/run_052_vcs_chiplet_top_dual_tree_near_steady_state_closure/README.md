# run_052_vcs_control_chip_dual_tree_near_steady_state_closure

## Purpose

This run is now the latest VM-proven bounded Stage F top-level checkpoint
above:

1. `run_051_vcs_control_chip_second_post_reentry_flush_writeback_chain`

It proves that `control_chip` can, in one bounded run:

1. accept one first independent tree input `Tree A`
2. keep explicit multi-lane compute/SRAM concurrency visible before the first
   flush of `Tree A`
3. keep explicit multi-lane concurrency visible between the repeated flushes of
   `Tree A`
4. keep explicit multi-lane concurrency visible after the final flush of
   `Tree A` and before the final survivor writeback
5. emit one final postflush survivor multi-token top-level writeback for
   `Tree A`
6. return to a clean top-level idle boundary after `Tree A`
7. accept one second independent tree input `Tree B` only after that idle
   boundary
8. keep explicit multi-lane compute/SRAM concurrency visible before the first
   flush of `Tree B`, between its flushes, and after its final flush before its
   final survivor writeback
9. emit one final postflush survivor multi-token top-level writeback for
   `Tree B`
10. return to idle again after `Tree B`

while still preserving the user-confirmed ownership split:

1. `AGU -> prefetch_queue -> free_list -> bank_state_table`
2. `AGU -> token_register`
3. `token_register lookup -> SRAM`
4. `PE -> request_controller -> SRAM -> PE response`

## Scope

Included bounded scope:

1. one first tree launch `Tree A`
2. one bounded `Tree A` script with exactly three flush checkpoints in the
   first witness
3. one explicit multi-lane concurrency window before `Tree A` flush 1
4. one explicit multi-lane concurrency window between `Tree A` flush 1 and
   flush 2
5. one explicit multi-lane concurrency window between `Tree A` flush 2 and
   flush 3
6. one explicit multi-lane concurrency window after `Tree A` flush 3 and
   before final writeback
7. one final postflush survivor multi-token writeback for `Tree A`, targeted as
   `new_token_len = 3`
8. one clean idle boundary after `Tree A`
9. one second tree launch `Tree B` only after that idle boundary
10. one bounded `Tree B` script with exactly two flush checkpoints in the first
    witness
11. one explicit multi-lane concurrency window before `Tree B` flush 1
12. one explicit multi-lane concurrency window between `Tree B` flush 1 and
    flush 2
13. one explicit multi-lane concurrency window after `Tree B` flush 2 and
    before final writeback
14. one final postflush survivor multi-token writeback for `Tree B`, targeted
    as `new_token_len = 2`
15. one final return to idle after `Tree B`
16. regression re-run of:
    - `tb_control_chip_second_post_reentry_flush_writeback_chain`
    - `tb_control_chip_post_reentry_flush_writeback_closure`
    - `tb_control_chip_post_variable_len_writeback_reentry`
    - `tb_control_chip_variable_len_token_writeback`
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

1. overlapping `Tree B` launch before `Tree A` reaches idle
2. arbitrary unbounded flush counts
3. three or more top-level tree launches in the same proof
4. arbitrary free-running steady-state continuation
5. full chiplet closure
6. unbounded steady-state continuation
7. arbitrary-flush closure
8. direct `comparator -> token_register`
9. direct `comparator -> bank_state_table`
10. `bank_state_table -> token_register`
11. direct `token_register lookup -> request_controller`
12. SRAM internal flush

## VM Command

```bash
cd /home/ICer/first/verification/run_052_vcs_control_chip_dual_tree_near_steady_state_closure/scripts
bash run_tb_control_chip_dual_tree_near_steady_state_closure.sh
```

Full suite:

```bash
cd /home/ICer/first/verification/run_052_vcs_control_chip_dual_tree_near_steady_state_closure/scripts
bash run_all_vcs.sh
```

## Judgment Rule

Read these files before claiming PASS or FAIL:

1. `logs/run_052_summary.txt`
2. `logs/tb_control_chip_dual_tree_near_steady_state_closure_result.txt`
3. `logs/tb_control_chip_dual_tree_near_steady_state_closure_run.log`
4. `logs/tb_control_chip_second_post_reentry_flush_writeback_chain_result.txt`
5. `logs/tb_control_chip_second_post_reentry_flush_writeback_chain_run.log`
6. each regression TB `*_result.txt`
7. each regression TB `*_run.log`

## Current State

`run_052` is now VM-proven.

Interpretation boundary:

1. `run_052` is the latest VM-proven bounded Stage F checkpoint above
   `run_051`
2. `run_051` remains the bounded second post-reentry flush/writeback-chain
   reference point beneath `run_052`
3. the PASS or FAIL judgment for `run_052` is based on
   `logs/run_052_summary.txt`, the per-TB `*_result.txt` files, and the per-TB
   `*_run.log` files
4. the proven bounded scope remains exactly:
   `Tree A` first, exactly three bounded flush checkpoints, one final
   postflush survivor multi-token writeback with `new_token_len = 3`, then a
   clean idle boundary before `Tree B`, then `Tree B` with exactly two bounded
   flush checkpoints and one final postflush survivor multi-token writeback
   with `new_token_len = 2`
5. `run_052` must not be described as full chiplet closure, unbounded
   steady-state continuation, arbitrary-flush closure, or steady-state
   multi-token closure
