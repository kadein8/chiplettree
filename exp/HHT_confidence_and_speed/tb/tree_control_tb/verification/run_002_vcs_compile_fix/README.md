# Run 002: VCS Compile Fix Recheck

This run directory is reserved for the second VCS verification round after the
first compile-failure fixes.

## Scope

The current planned targets are:

1. `tb_alloc_metadata_flow.v`
2. `tb_commit_flush_lifecycle.v`

## Directory Layout

1. `scripts/`
   - VCS execution scripts for this round
2. `logs/`
   - compile and run outputs generated in the VM for this round

## Workflow

1. enter the `scripts/` directory in the CentOS VM
2. run `bash run_all_vcs.sh`
3. collect generated outputs under `logs/`
4. read those logs back in the host-side dialogue to judge correctness
