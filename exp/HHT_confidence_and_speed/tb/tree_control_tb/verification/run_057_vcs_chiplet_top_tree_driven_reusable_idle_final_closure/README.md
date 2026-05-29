# run_057_vcs_control_chip_tree_driven_reusable_idle_final_closure

## Purpose

This run is the selected final project-internal sign-off checkpoint above:

1. `run_056_vcs_control_chip_tree_driven_serial_long_span_closure`

It is intended to prove one bounded strict-serial reusable-idle contract:

1. `Tree i -> idle -> Tree i+1`
2. no `overlap`
3. no `reopen-before-idle`
4. tree behavior comes from real bounded tree input plus runtime verification
   events
5. effective flush count remains runtime-derived
6. survivor continuation remains runtime-derived
7. final top-level writeback remains runtime-derived
8. after each tree, `control_chip` returns to one reusable idle contract
9. the next tree can launch from that same reusable idle contract and close
   again

while preserving the user-confirmed ownership split:

1. `AGU -> prefetch_queue -> free_list -> bank_state_table`
2. `AGU -> token_register`
3. `token_register lookup -> SRAM`
4. `PE -> request_controller -> SRAM -> PE response`

## Scope

Included bounded scope:

1. one strict-serial five-tree reusable-idle witness
2. one new bounded selector:
   `cfg_data[23:20] == 4'hf`
3. `cfg_data[7:0]` selects one bounded tree descriptor id
4. one new main TB:
   `tb_control_chip_tree_driven_reusable_idle_final_closure`
5. at least one no-flush tree
6. at least one single-effective-flush tree
7. at least one multi-effective-flush tree
8. at least one stale late-result drop on a flush-bearing tree
9. at least one survivor continuation after flush
10. at least one multi-token final writeback
11. at least one back-half flush-bearing closure
12. at least one back-half multi-token final writeback
13. reusable-idle return after every tree, including the final tree
14. regression re-run of the inherited `run_056` family beneath this
    checkpoint

Explicitly excluded:

1. overlapping tree launches
2. reopen-before-idle semantics
3. arbitrary unbounded tree counts
4. arbitrary unbounded flush counts
5. shortcut wiring across the preserved ownership split
6. SRAM internal flush
7. broader mathematical unbounded proof
8. broader full-chiplet closure outside the selected strict-serial
   reusable-idle project definition

## VM Command

Main TB:

```bash
cd /home/ICer/first/verification/run_057_vcs_control_chip_tree_driven_reusable_idle_final_closure/scripts
bash run_tb_control_chip_tree_driven_reusable_idle_final_closure.sh
```

Full suite:

```bash
cd /home/ICer/first/verification/run_057_vcs_control_chip_tree_driven_reusable_idle_final_closure/scripts
bash run_all_vcs.sh
```

## Judgment Rule

Read these files before claiming PASS or FAIL:

1. `logs/run_057_summary.txt`
2. `logs/tb_control_chip_tree_driven_reusable_idle_final_closure_result.txt`
3. `logs/tb_control_chip_tree_driven_reusable_idle_final_closure_run.log`
4. each included regression TB `*_result.txt`
5. each included regression TB `*_run.log`

All PASS/FAIL claims for this run must be based on those files.

## Current State

`run_057` is now VM-proven.

Interpretation boundary after VM proof:

1. `run_057` is now the latest VM-proven bounded Stage F checkpoint
2. `run_057` is now the final project-internal sign-off checkpoint for the
   selected strict-serial reusable-idle contract
3. `run_056` remains the bounded long-span witness reference point beneath
   `run_057`
4. `run_055` remains the bounded first strict-serial tree-driven five-tree
   reference point beneath `run_056`
5. PASS must be judged from:
   - `logs/run_057_summary.txt`
   - `logs/tb_control_chip_tree_driven_reusable_idle_final_closure_result.txt`
   - `logs/tb_control_chip_tree_driven_reusable_idle_final_closure_run.log`
   - each included regression TB `*_result.txt`
   - each included regression TB `*_run.log`
6. `run_057` still must not be described as overlap closure,
   reopen-before-idle closure, mathematical unbounded proof, or broader full
   chiplet closure outside the selected project definition
