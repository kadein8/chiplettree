# run_022_vcs_comparator_agu_freeze

## Purpose

This run is the next bounded Stage E lifecycle slice after the passing
`run_021` standalone comparator D0 baseline.

It verifies only the first comparator-driven control coupling:
`comparator.flush_valid -> agu.flush_freeze`.

## Scope

Included behavior:

1. `cmp_valid=0` keeps AGU front-end acceptance open
2. equal token ids keep comparator in commit-only mode and do not freeze AGU
3. unequal token ids drive `flush_valid=1`
4. comparator `flush_valid` freezes AGU `tree_in_ready`
5. comparator `flush_valid` freezes AGU `prefix_ready`
6. comparator `flush_valid` freezes AGU `frontier_ready`
7. comparator `flush_valid` suppresses new AGU `prefetch_enq_valid`
8. removing comparator flush reopens AGU acceptance if other local conditions
   allow it

Explicitly excluded:

1. `prefetch_queue` selective flush
2. `free_list` flush or release-side processing
3. `bank_state_table` ownership or lifecycle updates
4. `AGU/control -> token_register` metadata updates
5. direct `comparator -> token_register` wiring
6. `bank_state_table -> token_register` wiring
7. SRAM internal flush
8. chiplet integration

## VM Command

```bash
cd /home/ICer/first/verification/run_022_vcs_comparator_agu_freeze/scripts
bash run_all_vcs.sh
cat ../logs/run_022_summary.txt
```

## Judgment Rule

Read these files before claiming PASS or FAIL:

1. `logs/run_022_summary.txt`
2. `logs/tb_comparator_agu_freeze_result.txt`
3. `logs/tb_comparator_agu_freeze_run.log`

## VM Result

The VM execution on 2026-04-23 records PASS.

Evidence:

1. `logs/run_022_summary.txt` records `judge=PASS`
2. `logs/tb_comparator_agu_freeze_result.txt` records compile PASS and run
   PASS
3. `logs/tb_comparator_agu_freeze_run.log` contains
   `tb_comparator_agu_freeze PASS`

This is a bounded comparator-to-AGU freeze proof only. It does not prove
`prefetch_queue` selective flush, `free_list` release behavior,
`bank_state_table` lifecycle ownership updates, `AGU/control ->
token_register` metadata updates, SRAM flush, or chiplet integration.
