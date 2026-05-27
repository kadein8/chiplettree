# run_027_vcs_comparator_token_register_flush

## Purpose

This run is the next bounded Stage E metadata slice after the VM-passing
`run_026_vcs_comparator_alloc_status_flush_path` baseline.

It verifies only:

1. `comparator.flush_valid -> agu.flush_freeze`
2. `agu/control -> token_register` metadata flush ownership remains intact
3. one wrong-subtree victim metadata entry is removed
4. one survivor metadata entry remains lookup-hit

## Scope

Included behavior:

1. comparator mismatch still freezes AGU front-end acceptance
2. AGU owns the metadata flush controls consumed by `token_register`
3. `token_register` removes only the victim metadata entry selected by
   `req_id + branch_mask + node_mask`
4. a non-victim survivor metadata entry remains valid

Explicitly excluded:

1. direct `comparator -> token_register` wiring
2. `bank_state_table -> token_register` wiring
3. `prefetch_queue`, `free_list`, or `bank_state_table` lifecycle updates
4. SRAM internal flush
5. chiplet integration

## VM Command

```bash
cd /home/ICer/first/verification/run_027_vcs_comparator_token_register_flush/scripts
bash run_all_vcs.sh
cat ../logs/run_027_summary.txt
```

## Judgment Rule

Read these files before claiming PASS or FAIL:

1. `logs/run_027_summary.txt`
2. `logs/tb_comparator_token_register_flush_result.txt`
3. `logs/tb_comparator_token_register_flush_run.log`

## Current State

This run is VM-validated and PASS.

Evidence files:

1. `logs/run_027_summary.txt` records `judge=PASS`
2. `logs/tb_comparator_token_register_flush_result.txt` records compile PASS
   and run PASS
3. `logs/tb_comparator_token_register_flush_run.log` contains
   `tb_comparator_token_register_flush PASS`
