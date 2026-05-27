# run_035_vcs_comparator_async_ordering

## Purpose

This run is the fourth bounded verification target for async multi-depth
speculative-branch pruning.

It proves one composed ordering slice only:

1. accepted-prefix reduction happens first
2. killed branches stop issuing immediately after reduction
3. stale late results do not perturb accepted-prefix state
4. one later flush window closes AGU acceptance without reopening dead branches
5. survivor issue resumes after the flush window deasserts

## Scope

Included behavior:

1. comparator accepted-prefix reduction reused from `run_032`
2. AGU branch-liveness reuse from `run_033`
3. stale-result identity reuse from `run_034`
4. one bounded `flush_freeze + flush_ctrl_*` ordering window on `AGU/control`

Explicitly excluded:

1. metadata-path replay
2. allocation/status reclaim replay
3. SRAM internal flush
4. chiplet-top integration
5. any new ownership path beyond `comparator + AGU/control`

## VM Command

```bash
cd /home/ICer/first/verification/run_035_vcs_comparator_async_ordering/scripts
bash run_all_vcs.sh
cat ../logs/run_035_summary.txt
```

## Judgment Rule

Read these files before claiming PASS or FAIL:

1. `logs/run_035_summary.txt`
2. `logs/tb_comparator_async_ordering_result.txt`
3. `logs/tb_comparator_async_ordering_run.log`

## Current State

This run is prepared locally as the RED/GREEN target for bounded ordering
across reduction, stale-drop, and one later flush window.
