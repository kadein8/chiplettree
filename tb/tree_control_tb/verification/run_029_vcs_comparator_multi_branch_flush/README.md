# run_029_vcs_comparator_multi_branch_flush

## Purpose

This run is the next bounded Stage E target after the VM-passing
`run_028_vcs_comparator_dual_path_flush_coherence` baseline.

It upgrades the bounded proof from one single-victim coordinated flush event to
one multi-slot comparator event that emits multi-branch flush masks.

## Scope

Included behavior:

1. one comparator event with two mismatch slots ORs together multi-branch masks
2. AGU freezes front-end acceptance during that flush event
3. AGU forwards the same multi-branch masks to:
   - `prefetch_queue`
   - `free_list`
   - `token_register`
4. `free_list` clears both victim allocations locally
5. `free_list` serializes multiple reclaim handoffs into `bank_state_table`
6. `prefetch_queue` removes both queued victims and preserves the survivor
7. `token_register` removes both victim metadata entries and preserves the survivor
8. one later allocation reuses reclaimed capacity
9. later metadata lookup still shows victim miss and survivor hit

Explicitly excluded:

1. direct `comparator -> token_register`
2. direct `comparator -> bank_state_table`
3. `bank_state_table -> token_register`
4. SRAM internal flush
5. full Stage E lifecycle closure
6. chiplet integration

## VM Command

```bash
cd /home/ICer/first/verification/run_029_vcs_comparator_multi_branch_flush/scripts
bash run_all_vcs.sh
cat ../logs/run_029_summary.txt
```

## Judgment Rule

Read these files before claiming PASS or FAIL:

1. `logs/run_029_summary.txt`
2. `logs/tb_comparator_multi_branch_flush_result.txt`
3. `logs/tb_comparator_multi_branch_flush_run.log`

## Current State

This run is VM-validated and PASS.

Evidence files:

1. `logs/run_029_summary.txt` records `judge=PASS`
2. `logs/tb_comparator_multi_branch_flush_result.txt` records compile PASS and
   run PASS
3. `logs/tb_comparator_multi_branch_flush_run.log` contains
   `tb_comparator_multi_branch_flush PASS`
