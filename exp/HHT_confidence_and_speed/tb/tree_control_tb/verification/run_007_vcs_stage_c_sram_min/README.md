# Run 007: VCS Stage C SRAM Min

This run directory records the VCS verification round for the first bounded
Stage C SRAM behavior slice.

## Scope

The planned targets are:

1. `tb_alloc_metadata_flow.v`
2. `tb_commit_flush_lifecycle.v`
3. `tb_agu_stage_b_flow.v`
4. `tb_prefetch_queue_selective_flush.v`
5. `tb_sram_subbank_stage_c_basic.v`
6. `tb_sram_bank_stage_c_parallel.v`
7. `tb_sram_subsystem_stage_c_route.v`

## Strategy

1. source RTL and testbench files are read from the shared project tree
2. VCS intermediate build products are redirected to a VM-local work directory
3. compile and run logs are written back to this run's `logs/` subdirectory
4. this run keeps the proven Stage A and Stage B regression coverage intact
5. this run adds the first Stage C SRAM behavior checks without widening scope

## Usage

Run it in the same style as the earlier verification rounds:

1. `cd /home/ICer/first/verification/run_007_vcs_stage_c_sram_min/scripts`
2. `bash run_all_vcs.sh`

After that, all compile logs, run logs, result files, and the top-level
summary are written directly under:

1. `/home/ICer/first/verification/run_007_vcs_stage_c_sram_min/logs/`

