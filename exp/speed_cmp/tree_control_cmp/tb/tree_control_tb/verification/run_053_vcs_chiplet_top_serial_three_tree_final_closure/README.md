# run_053_vcs_control_chip_serial_three_tree_final_closure

## Purpose

This run is the latest VM-proven bounded Stage F top-level checkpoint above:

1. `run_052_vcs_control_chip_dual_tree_near_steady_state_closure`

It is intended to prove that `control_chip` can, in one bounded run:

1. accept one first independent tree input `Tree A`
2. keep explicit multi-lane compute/SRAM concurrency visible before the first
   flush of `Tree A`, between its flushes, and after its final flush before
   final writeback
3. emit one final postflush survivor multi-token top-level writeback for
   `Tree A`
4. return to a clean top-level idle boundary after `Tree A`
5. accept one second independent tree input `Tree B` only after that idle
   boundary
6. keep explicit multi-lane compute/SRAM concurrency visible before the first
   flush of `Tree B`, between its flushes, and after its final flush before
   final writeback
7. emit one final postflush survivor multi-token top-level writeback for
   `Tree B`
8. return to a clean top-level idle boundary after `Tree B`
9. accept one third independent tree input `Tree C` only after that second
   idle boundary
10. keep explicit multi-lane compute/SRAM concurrency visible before the first
    flush of `Tree C`, between its flushes, and after its final flush before
    final writeback
11. emit one final postflush survivor multi-token top-level writeback for
    `Tree C`
12. return to idle again after `Tree C`

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
7. one final postflush survivor multi-token writeback for `Tree A`, targeted
   as `new_token_len = 3`
8. one clean idle boundary after `Tree A`
9. one second tree launch `Tree B` only after that idle boundary
10. one bounded `Tree B` script with exactly two flush checkpoints in the
    first witness
11. one explicit multi-lane concurrency window before `Tree B` flush 1
12. one explicit multi-lane concurrency window between `Tree B` flush 1 and
    flush 2
13. one explicit multi-lane concurrency window after `Tree B` flush 2 and
    before final writeback
14. one final postflush survivor multi-token writeback for `Tree B`, targeted
    as `new_token_len = 2`
15. one clean idle boundary after `Tree B`
16. one third tree launch `Tree C` only after that idle boundary
17. one bounded `Tree C` script with exactly two flush checkpoints in the
    first witness
18. one explicit multi-lane concurrency window before `Tree C` flush 1
19. one explicit multi-lane concurrency window between `Tree C` flush 1 and
    flush 2
20. one explicit multi-lane concurrency window after `Tree C` flush 2 and
    before final writeback
21. one final postflush survivor multi-token writeback for `Tree C`, targeted
    as `new_token_len = 1`
22. one final return to idle after `Tree C`
23. regression re-run of:
    - `tb_control_chip_dual_tree_near_steady_state_closure`
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
2. overlapping `Tree C` launch before `Tree B` reaches idle
3. arbitrary unbounded flush counts
4. four or more top-level tree launches in the same proof
5. arbitrary free-running steady-state continuation
6. full chiplet closure
7. unbounded steady-state continuation
8. arbitrary-flush closure
9. direct `comparator -> token_register`
10. direct `comparator -> bank_state_table`
11. `bank_state_table -> token_register`
12. direct `token_register lookup -> request_controller`
13. SRAM internal flush

## VM Command

```bash
cd /home/ICer/first/verification/run_053_vcs_control_chip_serial_three_tree_final_closure/scripts
bash run_tb_control_chip_serial_three_tree_final_closure.sh
```

Full suite:

```bash
cd /home/ICer/first/verification/run_053_vcs_control_chip_serial_three_tree_final_closure/scripts
bash run_all_vcs.sh
```

## Judgment Rule

Read these files before claiming PASS or FAIL:

1. `logs/run_053_summary.txt`
2. `logs/tb_control_chip_serial_three_tree_final_closure_result.txt`
3. `logs/tb_control_chip_serial_three_tree_final_closure_run.log`
4. `logs/tb_control_chip_dual_tree_near_steady_state_closure_result.txt`
5. `logs/tb_control_chip_dual_tree_near_steady_state_closure_run.log`
6. each regression TB `*_result.txt`
7. each regression TB `*_run.log`

## Current State

`run_053` is now VM-proven.

Verified PASS evidence:

1. `logs/run_053_summary.txt` records `judge=PASS`
2. `logs/tb_control_chip_serial_three_tree_final_closure_result.txt` records
   compile PASS, run PASS, and `judge=PASS`
3. `logs/tb_control_chip_serial_three_tree_final_closure_run.log` contains
   `tb_control_chip_serial_three_tree_final_closure PASS`
4. the full `run_053` suite keeps each included TB `*_result.txt` at
   `judge=PASS`
5. the full `run_053` suite keeps each included TB `*_run.log` PASS banner
   intact

Interpretation boundary after VM PASS:

1. `run_053` is now the bounded serial three-tree final-closure checkpoint
   beneath `run_054`
2. `run_052` remains the bounded dual-tree near-steady-state checkpoint
   beneath `run_053`
3. the PASS or FAIL judgment for `run_053` must still be based on
   `logs/run_053_summary.txt`, the per-TB `*_result.txt` files, and the per-TB
   `*_run.log` files
4. `run_053` must not be described as full chiplet closure, unbounded
   steady-state continuation, arbitrary-flush closure, overlap/reopen-before-
   idle semantics, or steady-state multi-token closure
5. `run_054` is now the later VM-proven checkpoint above `run_053`
