# Run 005: VCS Prefetch Queue Stage B

This run directory records the VCS verification round focused on the Stage B
`prefetch_queue` selective-flush behavior slice.

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
4. this run extends verification only to the new Stage B
   `prefetch_queue` selective-flush slice and does not yet claim SRAM-path or
   integrated chiplet validation

