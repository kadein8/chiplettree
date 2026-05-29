# run_032_vcs_comparator_async_multi_depth_reduction

## Purpose

This run is the first bounded verification target for async multi-depth
speculative-branch pruning.

It is intentionally comparator-only and proves only the first semantic slice:

1. one request may preload up to `4` active speculative branches
2. a shallower discriminating result may immediately update the accepted prefix
3. incompatible deeper branches are pruned immediately
4. compatible descendants remain alive

## Scope

Included behavior:

1. comparator-only accepted-prefix reduction
2. branch-liveness reduction from one discriminating result batch
3. bounded example family:
   - `ABC1`
   - `ABC1D1`
   - `ABC2`
   - `ABC2D2`

Explicitly excluded:

1. AGU stop-issue control
2. stale late-result drop
3. metadata-path updates
4. allocation/status lifecycle convergence
5. SRAM internal flush

## VM Command

```bash
cd /home/ICer/first/verification/run_032_vcs_comparator_async_multi_depth_reduction/scripts
bash run_all_vcs.sh
cat ../logs/run_032_summary.txt
```

## Judgment Rule

Read these files before claiming PASS or FAIL:

1. `logs/run_032_summary.txt`
2. `logs/tb_comparator_async_multi_depth_reduction_result.txt`
3. `logs/tb_comparator_async_multi_depth_reduction_run.log`

## Current State

This run is prepared locally as the first RED/GREEN target for the async
multi-depth pruning ladder.
