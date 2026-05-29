# Run 009: VCS Tree Stage B Dispatch

This run directory records the first tree-driven Stage B propagation round after
freezing the `tree_analyze -> AGU` front-end format.

## Scope

The planned targets are:

1. `tb_alloc_metadata_flow.v`
2. `tb_commit_flush_lifecycle.v`
3. `tb_agu_stage_b_flow.v`
4. `tb_prefetch_queue_selective_flush.v`
5. `tb_tree_analyze_agu_layered_frontier.v`
6. `tb_agu_tree_stage_b_dispatch.v`

## Strategy

1. source RTL and testbench files are read from the shared project tree
2. VCS intermediate build products are redirected to a VM-local work directory
3. compile and run logs are written back to this run's `logs/` subdirectory
4. this run keeps the proven Stage A and scalar Stage B regression coverage intact
5. this run adds the first tree-driven dispatch check from `tree_analyze` into the
   real `AGU -> prefetch_queue -> free_list` Stage B path
6. Stage C tree-driven integration is intentionally deferred until this first part
   is stable

## Usage

Run it in the same style as the earlier verification rounds:

1. `cd /home/ICer/first/verification/run_009_vcs_tree_stage_b_dispatch/scripts`
2. `bash run_all_vcs.sh`

After that, all compile logs, run logs, result files, and the top-level
summary are written directly under:

1. `/home/ICer/first/verification/run_009_vcs_tree_stage_b_dispatch/logs/`