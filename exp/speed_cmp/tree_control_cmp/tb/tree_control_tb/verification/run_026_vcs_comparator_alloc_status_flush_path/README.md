# run_026_vcs_comparator_alloc_status_flush_path

## Purpose

This run is the next bounded Stage E allocation/status slice after the passing
`run_025_vcs_comparator_bank_state_table_flush` baseline.

It verifies only:

1. `comparator.flush_valid -> agu.flush_freeze`
2. `agu/control -> prefetch_queue` flush ownership remains intact
3. `agu/control -> free_list` selective reclaim ownership remains intact
4. `free_list -> bank_state_table` reclaim handoff ownership remains intact
5. a queue-held wrong-subtree victim is selectively removed
6. a later allocation can reuse the reclaimed capacity

## Scope

Included behavior:

1. comparator mismatch still freezes AGU front-end acceptance
2. AGU owns the flush control signals consumed by `prefetch_queue`
3. AGU owns the flush control signals consumed by `free_list`
4. `prefetch_queue` drops a stalled wrong-subtree victim entry
5. `free_list` emits one reclaim handoff for the allocated wrong-subtree
   victim range
6. `bank_state_table` reclaims only that victim range through its existing
   reclaim-side inputs
7. a surviving reservation remains occupied after flush
8. one later allocation grant is restored after flush

Explicitly excluded:

1. direct `comparator -> bank_state_table` wiring
2. direct `comparator -> token_register` wiring
3. `bank_state_table -> token_register` wiring
4. metadata flush updates
5. SRAM internal flush
6. chiplet integration

## VM Command

```bash
cd /home/ICer/first/verification/run_026_vcs_comparator_alloc_status_flush_path/scripts
bash run_all_vcs.sh
cat ../logs/run_026_summary.txt
```

## Judgment Rule

Read these files before claiming PASS or FAIL:

1. `logs/run_026_summary.txt`
2. `logs/tb_comparator_alloc_status_flush_path_result.txt`
3. `logs/tb_comparator_alloc_status_flush_path_run.log`

## Current State

This run is VM-validated and PASS.

Evidence files:

1. `logs/run_026_summary.txt` records `judge=PASS`
2. `logs/tb_comparator_alloc_status_flush_path_result.txt` records compile
   PASS and run PASS
3. `logs/tb_comparator_alloc_status_flush_path_run.log` contains
   `tb_comparator_alloc_status_flush_path PASS`
