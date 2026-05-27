# RTL Workspace

This directory holds the RTL source files for the single-chiplet project.

## Current structure

- `config/`: shared header files for parameters and interface widths
- root `.v` files: synthesizable RTL modules (one module per file)
- `tb/`: all testbench files (one testbench per file)
- current RTL modules:
  - `control_chip`
  - `free_list`
  - `bank_state_table`
  - `token_register`
  - `request_controller`
  - `sram_subsystem`
  - `sram_bank`
  - `sram_subbank`
  - `agu`
  - `prefetch_queue`
  - `comparator`
- current testbenches (under `tb/`):
  - `tb_alloc_metadata_flow`
  - `tb_commit_flush_lifecycle`
  - `tb_agu_stage_b_flow`
  - `tb_prefetch_queue_selective_flush`

## Current policy

1. one module per file
2. frozen interface assumptions should come from `config/` and `docs/design/`
3. unfinished skeletons must fail safely by backpressuring requests rather than
   silently accepting and dropping them
4. `sram_subsystem` is treated here as the wrapper boundary around the on-chip
   SRAM hierarchy, not as a separate logical accelerator block
5. current behavior bring-up starts with `free_list`, `bank_state_table`, and
   `token_register`
6. Stage B AGU bring-up now adds `tb_agu_stage_b_flow` for the first AGU-side
   coordination slice across `prefetch_queue`, `free_list`,
   `bank_state_table`, and `token_register`
7. Stage B prefetch-queue bring-up now targets selective wrong-subtree flush
   rather than whole-queue clear
8. the current local environment does not provide `vcs`, `iverilog`, or
   `verilator`, so existing testbenches are staged but not yet executable here
9. all testbench files must be placed under `code/tb/`, not in `code/` root
10. verification scripts must reference testbenches as `code/tb/tb_xxx.v`
