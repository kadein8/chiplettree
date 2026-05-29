# run_033_vcs_comparator_async_multi_depth_stop_issue

## Purpose

This run is the second bounded verification target for async multi-depth
speculative-branch pruning.

It proves only the stop-issue slice:

1. one request may keep up to `4` speculative branches active
2. comparator accepted-prefix reduction may kill incompatible branches
3. AGU/control must stop issuing new work for killed branches
4. compatible surviving branches may still issue

## Scope

Included behavior:

1. comparator reduction reused from `run_032`
2. AGU-controlled new-work stop-issue after branch prune
3. bounded example family:
   - `ABC1`
   - `ABC1D1`
   - `ABC2`
   - `ABC2D2`

Explicitly excluded:

1. metadata-path updates
2. allocation/status lifecycle replay
3. stale late-result drop
4. SRAM internal flush

## VM Command

```bash
cd /home/ICer/first/verification/run_033_vcs_comparator_async_multi_depth_stop_issue/scripts
bash run_all_vcs.sh
cat ../logs/run_033_summary.txt
```

## Judgment Rule

Read these files before claiming PASS or FAIL:

1. `logs/run_033_summary.txt`
2. `logs/tb_comparator_async_multi_depth_stop_issue_result.txt`
3. `logs/tb_comparator_async_multi_depth_stop_issue_run.log`

## Current State

This run is prepared locally as the RED/GREEN target for bounded stop-issue
control after async multi-depth accepted-prefix reduction.
