# run_023_vcs_comparator_prefetch_queue_flush

## Purpose

This run is the next bounded Stage E allocation/status slice after the passing
`run_022_vcs_comparator_agu_freeze` baseline.

It verifies only:

1. `comparator.flush_valid -> agu.flush_freeze`
2. `agu/control -> prefetch_queue` selective flush ownership

## Scope

Included behavior:

1. comparator mismatch still freezes AGU front-end acceptance
2. AGU owns the flush control signals consumed by `prefetch_queue`
3. `prefetch_queue` invalidates only the wrong-subtree queued entry matching
   `req_id + branch_mask + node_mask`
4. a surviving queued entry remains dequeueable with original payload intact

Explicitly excluded:

1. `free_list` flush or release-side processing
2. `bank_state_table` ownership or lifecycle updates
3. `AGU/control -> token_register` metadata updates
4. direct `comparator -> prefetch_queue` wiring
5. direct `comparator -> token_register` wiring
6. `bank_state_table -> token_register` wiring
7. SRAM internal flush
8. chiplet integration

## VM Command

```bash
cd /home/ICer/first/verification/run_023_vcs_comparator_prefetch_queue_flush/scripts
bash run_all_vcs.sh
cat ../logs/run_023_summary.txt
```

## Judgment Rule

Read these files before claiming PASS or FAIL:

1. `logs/run_023_summary.txt`
2. `logs/tb_comparator_prefetch_queue_flush_result.txt`
3. `logs/tb_comparator_prefetch_queue_flush_run.log`

## Current State

The VM execution on 2026-04-24 records PASS.

Evidence:

1. `logs/run_023_summary.txt` records `judge=PASS`
2. `logs/tb_comparator_prefetch_queue_flush_result.txt` records compile PASS
   and run PASS
3. `logs/tb_comparator_prefetch_queue_flush_run.log` contains
   `tb_comparator_prefetch_queue_flush PASS`

This is a bounded comparator-to-prefetch_queue proof only. It does not prove
`free_list` release behavior, `bank_state_table` lifecycle ownership updates,
`AGU/control -> token_register` metadata updates, SRAM flush, or chiplet
integration.
