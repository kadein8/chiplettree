# Run 004: VCS AGU Stage B

This run directory is reserved for the next VCS verification round focused on
the first AGU Stage B behavior slice.

## Scope

The current planned targets are:

1. `tb_alloc_metadata_flow.v`
2. `tb_commit_flush_lifecycle.v`
3. `tb_agu_stage_b_flow.v`

## Strategy

1. source RTL and testbench files are read from the shared project tree
2. VCS intermediate build products are redirected to a VM-local work directory
3. compile and run logs are written back to this run's `logs/` subdirectory
4. this run extends verification only to the new AGU Stage B behavior and does
   not yet claim SRAM-path or integrated chiplet validation
