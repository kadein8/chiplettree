# run_055_vcs_control_chip_tree_driven_strict_serial_closure

## Purpose

This run is the latest VM-proven bounded Stage F top-level checkpoint above:

1. `run_054_vcs_control_chip_serial_free_running_surrogate`

It is intended to prove that `control_chip` can, in one bounded run:

1. accept five tree-structured inputs in strict serial order
2. keep the top-level launch rule:
   `Tree i -> idle -> Tree i+1`
3. derive effective flush behavior from tree input plus runtime verification
   events
4. avoid prewriting per-tree expected flush count
5. avoid prewriting per-tree expected final `new_token_len`
6. preserve explicit multi-lane compute/SRAM concurrency inside each tree
7. preserve wrong-subtree selective flush semantics
8. emit final top-level survivor writeback only from runtime-derived survivor
   results

while still preserving the user-confirmed ownership split:

1. `AGU -> prefetch_queue -> free_list -> bank_state_table`
2. `AGU -> token_register`
3. `token_register lookup -> SRAM`
4. `PE -> request_controller -> SRAM -> PE response`

## Scope

Included bounded scope:

1. one strict-serial five-tree bounded witness
2. one new bounded selector:
   `cfg_data[23:20] == 4'hd`
3. `cfg_data[7:0]` selects bounded tree descriptor id
4. one clean no-flush tree
5. one single-effective-flush tree
6. one flush-then-continue tree
7. one stale-late-result-drop tree
8. one multi-effective-flush tree
9. one common per-tree closure checker rather than per-tree hard-coded truth
10. main-TB VM judgment from:
    - `logs/run_055_summary.txt`
    - `logs/tb_control_chip_tree_driven_strict_serial_closure_result.txt`
    - `logs/tb_control_chip_tree_driven_strict_serial_closure_run.log`
11. regression re-run of:
    - `tb_control_chip_serial_free_running_surrogate`
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

Explicitly excluded:

1. overlapping tree launches
2. reopen-before-idle semantics
3. arbitrary unbounded flush counts
4. arbitrary unbounded tree counts
5. arbitrary free-running steady-state continuation
6. full chiplet closure
7. unbounded steady-state continuation
8. arbitrary-flush closure
9. steady-state multi-token closure
10. direct `comparator -> token_register`
11. direct `comparator -> bank_state_table`
12. `bank_state_table -> token_register`
13. direct `token_register lookup -> request_controller`
14. SRAM internal flush

## VM Command

Main TB:

```bash
cd /home/ICer/first/verification/run_055_vcs_control_chip_tree_driven_strict_serial_closure/scripts
bash run_tb_control_chip_tree_driven_strict_serial_closure.sh
```

Full suite:

```bash
cd /home/ICer/first/verification/run_055_vcs_control_chip_tree_driven_strict_serial_closure/scripts
bash run_all_vcs.sh
```

## Judgment Rule

Read these files before claiming PASS or FAIL:

1. `logs/run_055_summary.txt`
2. `logs/tb_control_chip_tree_driven_strict_serial_closure_result.txt`
3. `logs/tb_control_chip_tree_driven_strict_serial_closure_run.log`
4. each included regression TB `*_result.txt`
5. each included regression TB `*_run.log`

## Current State

`run_055` is now VM-proven.

Verified interpretation boundary:

1. `run_055` is now the latest VM-proven bounded Stage F checkpoint above
   `run_054`
2. the main TB PASS evidence is:
   - `logs/run_055_summary.txt`
   - `logs/tb_control_chip_tree_driven_strict_serial_closure_result.txt`
   - `logs/tb_control_chip_tree_driven_strict_serial_closure_run.log`
3. the full `run_055` suite also preserves PASS for every included regression
   TB `result` and `run.log`
4. `run_055` proves the first tree-driven strict-serial five-tree bounded
   complete-closure witness
5. `run_055` still must not be described as full chiplet closure, unbounded
   steady-state continuation, arbitrary-flush closure,
   overlap/reopen-before-idle semantics, or steady-state multi-token closure
