# Run 003: VCS Local Workdir Rerun

This run directory is reserved for the third VCS verification round after the
shared-directory symlink limitation was identified.

## Scope

The current planned targets are:

1. `tb_alloc_metadata_flow.v`
2. `tb_commit_flush_lifecycle.v`

## Strategy

1. source RTL and testbench files are still read from the shared project tree
2. VCS intermediate build products are redirected to a VM-local work directory
3. compile and run logs are still written back to this run's `logs/`
   subdirectory
