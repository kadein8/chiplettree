# run_030_vcs_comparator_multi_branch_alloc_status_reuse

## Purpose

This run is the next bounded Stage E target after the VM-passing
`run_029_vcs_comparator_multi_branch_flush` baseline.

It strengthens only the allocation/status path proof after one multi-branch
flush event by checking multiple later post-flush reuse allocations.

## Scope

Included behavior:

1. one comparator event with two mismatch slots ORs together multi-branch masks
2. AGU freezes front-end acceptance during that flush event
3. AGU forwards the same multi-branch masks to:
   - `prefetch_queue`
   - `free_list`
4. `free_list` clears both victim allocations locally
5. `free_list` serializes multiple reclaim handoffs into `bank_state_table`
6. `prefetch_queue` removes both queued victims and preserves the survivor
7. a first later allocation reuses the first reclaimed victim range
8. a second later allocation reuses the second reclaimed victim range
9. one further same-size request is denied again after the reclaimed capacity
   is consumed

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
cd /home/ICer/first/verification/run_030_vcs_comparator_multi_branch_alloc_status_reuse/scripts
bash run_all_vcs.sh
cat ../logs/run_030_summary.txt
```

## Judgment Rule

Read these files before claiming PASS or FAIL:

1. `logs/run_030_summary.txt`
2. `logs/tb_comparator_multi_branch_alloc_status_reuse_result.txt`
3. `logs/tb_comparator_multi_branch_alloc_status_reuse_run.log`

## Current State

This run is VM-validated and PASS.

Evidence files:

1. `logs/run_030_summary.txt` records `judge=PASS`
2. `logs/tb_comparator_multi_branch_alloc_status_reuse_result.txt` records
   compile PASS and run PASS
3. `logs/tb_comparator_multi_branch_alloc_status_reuse_run.log` contains
   `tb_comparator_multi_branch_alloc_status_reuse PASS`
