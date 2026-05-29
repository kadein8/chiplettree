# Run 006: VCS Stage B Realign

This run directory records the VCS verification round that revalidates the
current Stage B boundary after the AGU and prefetch-queue timing realignment.

## Scope

The planned targets are:

1. `tb_alloc_metadata_flow.v`
2. `tb_commit_flush_lifecycle.v`
3. `tb_agu_stage_b_flow.v`
4. `tb_prefetch_queue_selective_flush.v`

## Strategy

1. source RTL and testbench files are read from the shared project tree
2. VCS intermediate build products are redirected to a VM-local work directory
3. compile and run logs are written back to this run's `logs/` subdirectory
4. this run exists to revalidate the current effective Stage B contract:
   `AGU -> prefetch_queue -> free_list -> bank_state_table`
5. this run does not yet claim SRAM-path, request-controller, comparator, or
   integrated chiplet validation

## Usage

Run it in the same style as the earlier verification rounds:

1. `cd /home/ICer/first/verification/run_006_vcs_stage_b_realign/scripts`
2. `bash run_all_vcs.sh`

After that, all compile logs, run logs, result files, and the top-level
summary are written directly under:

1. `/home/ICer/first/verification/run_006_vcs_stage_b_realign/logs/`

## Result

`run_006_vcs_stage_b_realign` has now completed successfully:

1. `tb_alloc_metadata_flow` compiled and ran successfully
2. `tb_commit_flush_lifecycle` compiled and ran successfully
3. `tb_agu_stage_b_flow` compiled and ran successfully
4. `tb_prefetch_queue_selective_flush` compiled and ran successfully
5. the top-level summary now records `judge=PASS`
6. the final AGU testbench fix was a TB race correction, not an AGU RTL
   functional rewrite
