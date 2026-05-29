# run_024_vcs_comparator_free_list_flush

## Purpose

This run is the next bounded Stage E allocation/status slice after the passing
`run_023_vcs_comparator_prefetch_queue_flush` baseline.

It verifies only:

1. `comparator.flush_valid -> agu.flush_freeze`
2. `agu/control -> prefetch_queue` flush ownership remains intact
3. `agu/control -> free_list` selective reclaim ownership

## Scope

Included behavior:

1. comparator mismatch still freezes AGU front-end acceptance
2. AGU owns the flush control signals consumed by `free_list`
3. `free_list` reclaims only matching wrong-subtree speculative reservations
4. a surviving reservation remains allocated after flush
5. one later allocation grant is restored after flush

Explicitly excluded:

1. `bank_state_table` flush or reclaim behavior
2. `free_list -> bank_state_table` flush-side propagation
3. `AGU/control -> token_register` metadata updates
4. direct `comparator -> free_list` wiring
5. direct `comparator -> token_register` wiring
6. `bank_state_table -> token_register` wiring
7. SRAM internal flush
8. chiplet integration

## VM Command

```bash
cd /home/ICer/first/verification/run_024_vcs_comparator_free_list_flush/scripts
bash run_all_vcs.sh
cat ../logs/run_024_summary.txt
```

## Judgment Rule

Read these files before claiming PASS or FAIL:

1. `logs/run_024_summary.txt`
2. `logs/tb_comparator_free_list_flush_result.txt`
3. `logs/tb_comparator_free_list_flush_run.log`

## Current State

The VM execution on 2026-04-24 records PASS.

Evidence:

1. `logs/run_024_summary.txt` records `judge=PASS`
2. `logs/tb_comparator_free_list_flush_result.txt` records compile PASS and
   run PASS
3. `logs/tb_comparator_free_list_flush_run.log` contains
   `tb_comparator_free_list_flush PASS`
