# run_038_vcs_stage_e_lifecycle_closure

## Purpose

This run is the immediate next bounded Stage E target after VM-passing
`run_037_vcs_comparator_async_ordering_wide`.

It is intended to close one bounded Stage E lifecycle slice by composing:

1. the accepted-prefix progression, longest-survivor, and wider async-ordering
   semantics from `run_037`
2. the real downstream two-path closure checks from `run_028`

The ownership split remains unchanged:

1. allocation/status path:
   `AGU -> prefetch_queue -> free_list -> bank_state_table`
2. metadata path:
   `AGU -> token_register`

## Scope

Included behavior:

1. accepted-path convergence before flush
2. one coordinated flush event after convergence
3. AGU-owned downstream flush controls for:
   - `prefetch_queue`
   - `free_list`
   - `token_register`
4. victim-only removal from:
   - `prefetch_queue`
   - `free_list`
   - `bank_state_table` through `free_list` reclaim handoff
   - `token_register`
5. survivor preservation across both downstream ownership paths
6. one later survivor-only continuation check
7. one later reclaimed-capacity reuse check
8. one later metadata lookup-stability check

Explicitly excluded:

1. direct `comparator -> token_register`
2. direct `comparator -> bank_state_table`
3. `bank_state_table -> token_register`
4. `token_register lookup -> request_controller`
5. request-controller participation
6. SRAM internal flush
7. chiplet-top integration
8. unbounded Stage E lifecycle claims

## VM Command

```bash
cd /home/ICer/first/verification/run_038_vcs_stage_e_lifecycle_closure/scripts
bash run_all_vcs.sh
cat ../logs/run_038_summary.txt
```

## Judgment Rule

Read these files before claiming PASS or FAIL:

1. `logs/run_038_summary.txt`
2. `logs/tb_stage_e_lifecycle_closure_result.txt`
3. `logs/tb_stage_e_lifecycle_closure_run.log`

## Current State

This run now passes in the VM.

Readback evidence:

1. `logs/run_038_summary.txt` records `judge=PASS`
2. `logs/tb_stage_e_lifecycle_closure_result.txt` records:
   - `compile_status=PASS`
   - `run_status=PASS`
   - `judge=PASS`
3. `logs/tb_stage_e_lifecycle_closure_run.log` contains
   `tb_stage_e_lifecycle_closure PASS`
