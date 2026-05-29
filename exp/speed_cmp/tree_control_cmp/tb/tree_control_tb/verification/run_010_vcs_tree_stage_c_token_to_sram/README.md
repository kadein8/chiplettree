# Run 010: VCS Tree Stage C Token To SRAM

This run directory records the first bounded VCS verification round for the
approved Stage C extension that keeps tree semantics above SRAM and proves only
the `token_register lookup -> SRAM` bridge.

## Scope

The target is intentionally narrow:

1. `tb_tree_stage_c_token_to_sram.v`

## Strategy

1. source RTL and testbench files are read from the shared project tree
2. VCS intermediate build products are redirected to a VM-local work directory
3. compile and run logs are written back to this run's `logs/` subdirectory
4. this run isolates the glue point between the already-passing
   tree-driven Stage B path and the already-passing Stage C SRAM path
5. this run does not push shared-prefix, sibling, or parent-path semantics into
   `sram_subsystem`, `sram_bank`, or `sram_subbank`

## Latest VM-Side Result

1. `run_010` records `judge=PASS`
2. `tb_tree_stage_c_token_to_sram` compiled and ran successfully
3. the passing boundary now includes the bounded tree-driven Stage C bridge
   from `token_register` lookup into real SRAM write/readback access

## Usage

Run it in the same style as the earlier verification rounds:

1. `cd /home/ICer/first/verification/run_010_vcs_tree_stage_c_token_to_sram/scripts`
2. `bash run_all_vcs.sh`

After that, all compile logs, run logs, result files, and the top-level
summary are written directly under:

1. `/home/ICer/first/verification/run_010_vcs_tree_stage_c_token_to_sram/logs/`