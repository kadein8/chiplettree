# run_031_vcs_comparator_alloc_status_drain_ordering

## Purpose

This run is the next bounded Stage E target after the VM-passing
`run_030_vcs_comparator_multi_branch_alloc_status_reuse` baseline.

It strengthens only the allocation/status path proof during the serialized
reclaim drain window by checking that AGU acceptance does not reopen too early.

## Scope

Included behavior:

1. one comparator event with four mismatch slots ORs together multi-branch masks
2. AGU freezes front-end acceptance during that flush event
3. AGU stays closed while `free_list` still reports serialized reclaim drain
   busy
4. AGU forwards the same multi-branch masks to:
   - `prefetch_queue`
   - `free_list`
5. `free_list` clears four victim allocations locally
6. `free_list` serializes multiple reclaim handoffs into `bank_state_table`
7. `prefetch_queue` removes all flushed queued victims
8. one request attempt during the drain window remains blocked
9. one later allocation reuses the first reclaimed victim range after reopen

Explicitly excluded:

1. direct `comparator -> token_register`
2. direct `comparator -> bank_state_table`
3. `bank_state_table -> token_register`
4. metadata-path lookup checks
5. SRAM internal flush
6. full Stage E lifecycle closure
7. chiplet integration

## VM Command

```bash
cd /home/ICer/first/verification/run_031_vcs_comparator_alloc_status_drain_ordering/scripts
bash run_all_vcs.sh
cat ../logs/run_031_summary.txt
```

## Judgment Rule

Read these files before claiming PASS or FAIL:

1. `logs/run_031_summary.txt`
2. `logs/tb_comparator_alloc_status_drain_ordering_result.txt`
3. `logs/tb_comparator_alloc_status_drain_ordering_run.log`

## Current State

This run is prepared locally and awaits VM execution.

After the VM run, read:

1. `logs/run_031_summary.txt`
2. `logs/tb_comparator_alloc_status_drain_ordering_result.txt`
3. `logs/tb_comparator_alloc_status_drain_ordering_run.log`
