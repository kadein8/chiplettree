# Run 001: VCS Bring-Up

This run directory is reserved for the first VCS verification bring-up of the
current single-chiplet RTL stage.

## Scope

The first planned targets are:

1. `tb_alloc_metadata_flow.v`
2. `tb_commit_flush_lifecycle.v`

## Directory Layout

1. `scripts/`
   - VCS execution scripts written on the host side
2. `logs/`
   - compile and run outputs generated in the VM

## Workflow

1. prepare scripts in `scripts/`
2. run them in the CentOS VM through the soft-linked workspace
3. collect generated outputs under `logs/`
4. read those logs back in the host-side dialogue to judge correctness

## Planned Log Files

For each testbench, the scripts will generate:

1. `<tb_name>_compile.log`
2. `<tb_name>_run.log`
3. `<tb_name>_result.txt`

The batch script will additionally generate:

1. `run_001_summary.txt`
