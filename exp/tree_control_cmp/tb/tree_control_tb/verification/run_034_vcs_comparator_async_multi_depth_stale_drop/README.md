# run_034_vcs_comparator_async_multi_depth_stale_drop

## Purpose

This run is the third bounded verification target for async multi-depth
speculative-branch pruning.

It proves only the stale late-result drop slice:

1. accepted-prefix reduction and AGU stop-issue reuse the `run_032` and
   `run_033` baseline
2. async result identity is tightened with `req_id + branch_id + branch_epoch`
3. a stale late result must not perturb accepted-prefix state
4. a stale late result must not reopen killed-branch issue in AGU

## Scope

Included behavior:

1. comparator reduction reused from `run_032`
2. AGU branch-liveness reuse from `run_033`
3. bounded stale-return check on async result identity
4. bounded survivor issue still works after the stale result is dropped

Explicitly excluded:

1. metadata-path updates
2. allocation/status lifecycle replay
3. SRAM internal flush
4. chiplet-top integration

## VM Command

```bash
cd /home/ICer/first/verification/run_034_vcs_comparator_async_multi_depth_stale_drop/scripts
bash run_all_vcs.sh
cat ../logs/run_034_summary.txt
```

## Judgment Rule

Read these files before claiming PASS or FAIL:

1. `logs/run_034_summary.txt`
2. `logs/tb_comparator_async_multi_depth_stale_drop_result.txt`
3. `logs/tb_comparator_async_multi_depth_stale_drop_run.log`

## Current State

This run is prepared locally as the RED/GREEN target for bounded stale
late-result drop after async multi-depth accepted-prefix reduction and AGU
stop-issue.
