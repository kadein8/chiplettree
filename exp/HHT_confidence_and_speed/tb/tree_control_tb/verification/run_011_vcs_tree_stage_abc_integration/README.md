# Run 011: VCS Tree Stage ABC Integration

This run directory records the first bounded VCS verification round for the
real Stage ABC tree-driven integration slice.

## Scope

The target remains intentionally narrow:

1. `tb_tree_stage_abc_integration.v`

## Proven Boundary

This run now has VM-side `judge=PASS`.

It proves:

1. the real `tree_analyze -> AGU -> prefetch_queue -> free_list -> bank_state_table`
   path, with same-step `free_list -> AGU` candidate feedback,
   allocation path
2. the parallel `AGU -> token_register -> lookup -> SRAM` bridge
3. the intended boundary that `bank_state_table` and `token_register` do not
   communicate directly

It still keeps these items out of scope:

1. `request_controller`
2. `comparator`
3. wider Stage D semantics
4. full end-to-end chiplet closure

## Strategy

1. source RTL and testbench files are read from the shared project tree
2. VCS intermediate build products are redirected to a VM-local work directory
3. compile and run logs are written back to this run's `logs/` subdirectory
4. this run reuses the already passing `run_008`, `run_009`, and `run_010`
   building blocks in one new integration harness

## Workflow Notes From This Run

1. when a VM script reports that `/usr/bin/env` or the shebang cannot be found,
   check for BOM or CRLF line endings first
2. VM-facing shell scripts should be UTF-8 without BOM and use LF line endings
3. the same check also applies to newly added VM-compiled TB files
4. judge pass or fail from `run_011_summary.txt`, per-TB `*_result.txt`, and
   `*_run.log`

## Usage

1. `cd /home/ICer/first/verification/run_011_vcs_tree_stage_abc_integration/scripts`
2. `bash run_all_vcs.sh`

After that, all compile logs, run logs, result files, and the top-level
summary are written directly under:

1. `/home/ICer/first/verification/run_011_vcs_tree_stage_abc_integration/logs/`
