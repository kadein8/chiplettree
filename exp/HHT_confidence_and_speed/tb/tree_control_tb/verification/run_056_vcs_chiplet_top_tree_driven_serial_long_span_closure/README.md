# run_056_vcs_control_chip_tree_driven_serial_long_span_closure

## Purpose

This run is the latest VM-proven bounded Stage F top-level checkpoint above:

1. `run_055_vcs_control_chip_tree_driven_strict_serial_closure`

It is intended to prove that `control_chip` can, in one bounded run:

1. accept a longer family of tree-structured inputs in strict serial order
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
9. preserve those closure properties into the later half of the same bounded
   run

while still preserving the user-confirmed ownership split:

1. `AGU -> prefetch_queue -> free_list -> bank_state_table`
2. `AGU -> token_register`
3. `token_register lookup -> SRAM`
4. `PE -> request_controller -> SRAM -> PE response`

## Scope

Included bounded scope:

1. one strict-serial eight-tree bounded witness
2. one new bounded selector:
   `cfg_data[23:20] == 4'he`
3. `cfg_data[7:0]` selects bounded tree descriptor id
4. one runtime-classified whole-run closure checker rather than one permanent
   per-tree hard-coded role table
5. at least one no-flush closure, one single-effective-flush closure, one
   multi-effective-flush closure, one stale-late-result-drop closure, one
   survivor-continuation closure, and one multi-token final writeback across
   the whole run
6. at least one back-half tree with flush-bearing closure
7. at least one back-half tree with multi-token final writeback
8. main-TB VM judgment from:
   - `logs/run_056_summary.txt`
   - `logs/tb_control_chip_tree_driven_serial_long_span_closure_result.txt`
   - `logs/tb_control_chip_tree_driven_serial_long_span_closure_run.log`
9. regression re-run of:
   - `tb_control_chip_tree_driven_strict_serial_closure`
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
15. wider accepted-token packet semantics beyond the bounded single-beat
    `{1, 2, 3}` range already established by `run_048`

## VM Command

Main TB:

```bash
cd /home/ICer/first/verification/run_056_vcs_control_chip_tree_driven_serial_long_span_closure/scripts
bash run_tb_control_chip_tree_driven_serial_long_span_closure.sh
```

Full suite:

```bash
cd /home/ICer/first/verification/run_056_vcs_control_chip_tree_driven_serial_long_span_closure/scripts
bash run_all_vcs.sh
```

## Judgment Rule

Read these files before claiming PASS or FAIL:

1. `logs/run_056_summary.txt`
2. `logs/tb_control_chip_tree_driven_serial_long_span_closure_result.txt`
3. `logs/tb_control_chip_tree_driven_serial_long_span_closure_run.log`
4. each included regression TB `*_result.txt`
5. each included regression TB `*_run.log`

## Current State

`run_056` is now VM-proven.

Interpretation boundary after VM proof:

1. `run_056` is now the latest VM-proven bounded Stage F checkpoint above
   `run_055`
2. `run_055` remains the bounded tree-driven strict-serial five-tree
   reference point beneath `run_056`
3. `run_056` proves one longer strict-serial tree-driven witness plus one
   later-span flush/writeback/concurrency continuation witness inside one
   bounded run
4. PASS must be judged from:
   - `logs/run_056_summary.txt`
   - `logs/tb_control_chip_tree_driven_serial_long_span_closure_result.txt`
   - `logs/tb_control_chip_tree_driven_serial_long_span_closure_run.log`
   - each included regression TB `*_result.txt`
   - each included regression TB `*_run.log`
5. `run_056` still must not be described as full chiplet closure, unbounded
   steady-state continuation, arbitrary-flush closure,
   overlap/reopen-before-idle semantics, or steady-state multi-token closure
