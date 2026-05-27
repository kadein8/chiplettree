# run_036_vcs_comparator_accepted_path_longest_path

## Purpose

This run is the next bounded comparator-only verification target after
`run_035`.

It proves accepted-path progression and longest-path survivor selection only:

1. one request may preload up to `4` active speculative branches
2. a shallower accepted result may first reduce the live family
3. a later compatible deeper accepted result may advance the accepted prefix
4. the deepest still-compatible branch becomes the only live survivor

## Scope

Included behavior:

1. comparator-only accepted-prefix reduction
2. compatible deeper accepted-path advancement
3. longest-path survivor selection
4. stability of the deeper accepted path after advancement

Explicitly excluded:

1. AGU stop-issue control
2. stale late-result drop
3. flush-window ordering
4. metadata replay
5. reclaim replay
6. SRAM internal flush

## VM Command

```bash
cd /home/ICer/first/verification/run_036_vcs_comparator_accepted_path_longest_path/scripts
bash run_all_vcs.sh
cat ../logs/run_036_summary.txt
```

## Judgment Rule

Read these files before claiming PASS or FAIL:

1. `logs/run_036_summary.txt`
2. `logs/tb_comparator_accepted_path_longest_path_result.txt`
3. `logs/tb_comparator_accepted_path_longest_path_run.log`

## Current State

This run is prepared locally as the RED/GREEN target for accepted-path
progression from `C1` to `C1,D1` and longest-path survivor reduction.
