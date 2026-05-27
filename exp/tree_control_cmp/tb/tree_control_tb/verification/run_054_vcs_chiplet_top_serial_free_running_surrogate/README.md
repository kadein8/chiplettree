# run_054_vcs_control_chip_serial_free_running_surrogate

## Purpose

This run is the latest VM-proven bounded Stage F top-level checkpoint above:

1. `run_053_vcs_control_chip_serial_three_tree_final_closure`

It is intended to prove that `control_chip` can, in one bounded run:

1. accept a longer serial sequence of heterogeneous tree inputs
2. keep explicit multi-lane compute/SRAM concurrency visible before the first
   flush of each tree
3. keep explicit multi-lane compute/SRAM concurrency visible between flushes
   for trees that require multiple flushes
4. keep explicit multi-lane compute/SRAM concurrency visible after the final
   flush of each tree and before final writeback
5. emit one final postflush survivor multi-token top-level writeback per tree
6. return to a clean top-level idle boundary after each tree
7. reuse the same bounded top-level path across later trees in the same run

while still preserving the user-confirmed ownership split:

1. `AGU -> prefetch_queue -> free_list -> bank_state_table`
2. `AGU -> token_register`
3. `token_register lookup -> SRAM`
4. `PE -> request_controller -> SRAM -> PE response`

## Scope

Included bounded scope:

1. one descriptor-driven serial tree sequence
2. at least five distinct tree launches in one run
3. each later tree launch only after the previous tree reaches clean idle
4. one common per-tree closure checker instead of one hard-coded
   three-tree-only script
5. per tree, one explicit multi-lane concurrency window before the first flush
6. for multi-flush trees, one explicit multi-lane concurrency window between
   adjacent flushes
7. per tree, one explicit multi-lane concurrency window after the final flush
   and before final writeback
8. per tree, one final postflush survivor multi-token writeback only after that
   tree's last bounded flush
9. whole-run coverage of final `new_token_len = {1, 2, 3}`
10. whole-run coverage of both short and long bounded flush chains
11. one final return to idle after the last tree
12. regression re-run of:
    - `tb_control_chip_serial_three_tree_final_closure`
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

Reuse-first rule:

1. first implementation must reuse `cfg_data[23:20] == 4'hc`
2. `cfg_data[5:4]` continues to carry bounded flush target
3. `cfg_data[1:0]` continues to carry final bounded token count
4. do not add a new top-level selector unless the first VM red result proves
   the current helper path is insufficient

Explicitly excluded:

1. overlapping tree launches
2. arbitrary unbounded flush counts
3. arbitrary unbounded tree counts
4. arbitrary free-running steady-state continuation
5. full chiplet closure
6. unbounded steady-state continuation
7. arbitrary-flush closure
8. overlap or reopen-before-idle semantics
9. direct `comparator -> token_register`
10. direct `comparator -> bank_state_table`
11. `bank_state_table -> token_register`
12. direct `token_register lookup -> request_controller`
13. SRAM internal flush

## VM Command

```bash
cd /home/ICer/first/verification/run_054_vcs_control_chip_serial_free_running_surrogate/scripts
bash run_tb_control_chip_serial_free_running_surrogate.sh
```

Full suite:

```bash
cd /home/ICer/first/verification/run_054_vcs_control_chip_serial_free_running_surrogate/scripts
bash run_all_vcs.sh
```

## Judgment Rule

Read these files before claiming PASS or FAIL:

1. `logs/run_054_summary.txt`
2. `logs/tb_control_chip_serial_free_running_surrogate_result.txt`
3. `logs/tb_control_chip_serial_free_running_surrogate_run.log`
4. `logs/tb_control_chip_serial_three_tree_final_closure_result.txt`
5. `logs/tb_control_chip_serial_three_tree_final_closure_run.log`
6. each regression TB `*_result.txt`
7. each regression TB `*_run.log`

## Current State

`run_054` is now VM-proven.

Interpretation boundary after VM PASS:

1. `run_054` is the latest VM-proven bounded Stage F checkpoint
2. `run_053` remains the bounded serial three-tree final-closure reference
   point beneath `run_054`
3. `logs/run_054_summary.txt` records the main TB exit at `0`, every listed
   regression run-script exit at `0`, and the final `judge=PASS`
4. `logs/tb_control_chip_serial_free_running_surrogate_result.txt` records
   `compile_status=PASS`, `run_status=PASS`, and `judge=PASS`
5. `logs/tb_control_chip_serial_free_running_surrogate_run.log` contains
   `tb_control_chip_serial_free_running_surrogate PASS`
6. `run_054` proves a strong bounded serial free-running surrogate across five
   heterogeneous trees using the current helper semantics
7. `run_054` must not be described as full chiplet closure, unbounded
   steady-state continuation, arbitrary-flush closure, overlap/reopen-before-
   idle semantics, or steady-state multi-token closure
