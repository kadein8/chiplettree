# run_039_vcs_top_level_bounded_memory_integration

## Purpose

This run is the planned bounded top-level memory/control integration target
after VM-passing `run_038_vcs_stage_e_lifecycle_closure`.

It keeps the user-confirmed ownership split intact while reassembling these
bounded paths in one run:

1. `tree/front-end -> AGU`
2. `AGU -> prefetch_queue -> free_list -> bank_state_table`
3. `AGU -> token_register`
4. `token_register lookup -> SRAM`
5. `PE -> request_controller -> SRAM -> PE response`
6. bounded comparator/control participation in the same workspace

## Scope

Included behavior:

1. one tree/front-end request prepares token and SRAM state
2. one separate lifecycle request is allocated on the scalar AGU path
3. one comparator mismatch flush removes only the lifecycle victim
4. `free_list` reclaims victim capacity and hands reclaim information to
   `bank_state_table`
5. the unrelated tree-prepared token still hits after the flush
6. one PE-side read still returns the prepared SRAM data after the flush

Explicitly excluded:

1. direct `comparator -> token_register`
2. direct `comparator -> bank_state_table`
3. `bank_state_table -> token_register`
4. `token_register lookup -> request_controller`
5. SRAM internal flush
6. chiplet-top or unbounded system closure
7. widened request-controller concurrency claims

## VM Command

```bash
cd /home/ICer/first/verification/run_039_vcs_top_level_bounded_memory_integration/scripts
bash run_all_vcs.sh
```

## Judgment Rule

Read these files before claiming PASS or FAIL:

1. `logs/run_039_summary.txt`
2. `logs/tb_top_level_bounded_memory_integration_result.txt`
3. `logs/tb_top_level_bounded_memory_integration_run.log`

## Current State

This run now passes in the VM.

Readback evidence:

1. `logs/run_039_summary.txt` records `judge=PASS`
2. `logs/tb_top_level_bounded_memory_integration_result.txt` records:
   - `compile_status=PASS`
   - `run_status=PASS`
   - `judge=PASS`
3. `logs/tb_top_level_bounded_memory_integration_run.log` contains
   `tb_top_level_bounded_memory_integration PASS`
