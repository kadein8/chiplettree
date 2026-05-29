# run_037_vcs_comparator_async_ordering_wide

## Purpose

This run is the next bounded `comparator + AGU/control` verification target
after VM-passing `run_036`.

It widens the async ordering proof only:

1. a shallower accepted result first reduces the branch family
2. a later compatible deeper accepted result advances the accepted path
3. only the longest-path survivor may still issue
4. a later non-live late result must not reopen a shorter path
5. one later flush window must temporarily close AGU acceptance without
   reopening any dead branch

## Scope

Included behavior:

1. accepted-path progression reused from `run_036`
2. AGU issue gating under the final longest-path survivor only
3. non-live late-result drop after deeper accepted-path advancement
4. one later bounded `flush_freeze + flush_ctrl_*` window
5. post-flush reopen for only the longest-path survivor

Explicitly excluded:

1. metadata replay
2. reclaim replay
3. SRAM internal flush
4. request-controller changes
5. chiplet-top integration

## VM Command

```bash
cd /home/ICer/first/verification/run_037_vcs_comparator_async_ordering_wide/scripts
bash run_all_vcs.sh
cat ../logs/run_037_summary.txt
```

## Judgment Rule

Read these files before claiming PASS or FAIL:

1. `logs/run_037_summary.txt`
2. `logs/tb_comparator_async_ordering_wide_result.txt`
3. `logs/tb_comparator_async_ordering_wide_run.log`

## Current State

This run is prepared locally as the RED/GREEN target for wider async ordering
after accepted-path progression to the final longest-path survivor.
