# Run 001 Scripts

This directory holds the first VCS execution scripts for
`run_001_vcs_bringup`.

## Current Scripts

1. `common_vcs.sh`
   - shared helpers for path resolution, VCS invocation, and result-file
     generation
2. `run_tb_alloc_metadata_flow.sh`
   - runs `tb_alloc_metadata_flow`
3. `run_tb_commit_flush_lifecycle.sh`
   - runs `tb_commit_flush_lifecycle`
4. `run_all_vcs.sh`
   - runs the current run-001 testbench batch and writes a summary file

## Execution Note

These scripts are intended to be executed inside the CentOS VM environment.
