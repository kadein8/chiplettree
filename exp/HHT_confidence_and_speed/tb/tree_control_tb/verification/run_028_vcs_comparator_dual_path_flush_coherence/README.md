# run_028_vcs_comparator_dual_path_flush_coherence

## Purpose

This run is the next bounded Stage E checkpoint after the VM-passing
`run_026_vcs_comparator_alloc_status_flush_path` and
`run_027_vcs_comparator_token_register_flush` baselines.

It prepares one coordinated flush proof across the two user-confirmed Stage E
paths:

1. `comparator -> AGU freeze -> prefetch_queue -> free_list -> bank_state_table`
2. `comparator -> AGU/control -> token_register`

## Scope

Included behavior:

1. one comparator mismatch event raises `flush_valid`
2. AGU freezes front-end acceptance during that flush event
3. AGU owns and forwards the downstream flush controls for:
   - `prefetch_queue`
   - `free_list`
   - `token_register`
4. `free_list` remains the reclaim owner for `bank_state_table`
5. the victim is removed from:
   - `prefetch_queue`
   - `free_list`
   - `bank_state_table`
   - `token_register`
6. the survivor remains valid in those bounded downstream consumers
7. one later allocation reuses the victim-reclaimed capacity
8. later metadata lookup still shows victim miss and survivor hit

Explicitly excluded:

1. direct `comparator -> token_register`
2. direct `comparator -> bank_state_table`
3. `bank_state_table -> token_register`
4. SRAM internal flush
5. multi-branch flush
6. chiplet integration
7. full Stage E lifecycle closure

## VM Command

```bash
cd /home/ICer/first/verification/run_028_vcs_comparator_dual_path_flush_coherence/scripts
bash run_all_vcs.sh
cat ../logs/run_028_summary.txt
```

## Judgment Rule

Read these files before claiming PASS or FAIL:

1. `logs/run_028_summary.txt`
2. `logs/tb_comparator_dual_path_flush_coherence_result.txt`
3. `logs/tb_comparator_dual_path_flush_coherence_run.log`

## Current State

This run workspace is prepared locally and awaits VM execution.
