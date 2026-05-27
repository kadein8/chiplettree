# run_041_vcs_control_chip_bounded_orchestration

## Purpose

This run is the latest VM-passing bounded Stage F single-chiplet orchestration
target after:

1. `run_038_vcs_stage_e_lifecycle_closure`
2. `run_039_vcs_top_level_bounded_memory_integration`
3. `run_040_vcs_request_controller_wide_concurrency`

It should prove one bounded `control_chip` orchestration slice while preserving
the user-confirmed ownership split:

1. `AGU -> prefetch_queue -> free_list -> bank_state_table`
2. `AGU -> token_register`
3. `token_register lookup -> SRAM`
4. `PE -> request_controller -> SRAM -> PE response`

## Scope

Included bounded scope:

1. one `cfg/start`-launched top-level scenario
2. one bounded prepare flow inside `control_chip`
3. one bounded PE-side consume flow
4. one bounded comparator/flush event
5. one bounded survivor continuation after flush
6. one bounded top-level `HBM` write request
7. regression re-run of:
   - `tb_top_level_bounded_memory_integration`
   - `tb_request_controller_wide_concurrency`

Explicitly excluded:

1. full compute-module RTL
2. full prediction-unit RTL
3. full chiplet closure
4. multi-chiplet behavior
5. direct `comparator -> token_register`
6. direct `comparator -> bank_state_table`
7. `bank_state_table -> token_register`
8. direct `token_register lookup -> request_controller`
9. SRAM internal flush

## VM Command

```bash
cd /home/ICer/first/verification/run_041_vcs_control_chip_bounded_orchestration/scripts
bash run_all_vcs.sh
```

## Judgment Rule

Read these files before claiming PASS or FAIL:

1. `logs/run_041_summary.txt`
2. `logs/tb_control_chip_bounded_orchestration_result.txt`
3. `logs/tb_control_chip_bounded_orchestration_run.log`
4. `logs/tb_top_level_bounded_memory_integration_result.txt`
5. `logs/tb_top_level_bounded_memory_integration_run.log`
6. `logs/tb_request_controller_wide_concurrency_result.txt`
7. `logs/tb_request_controller_wide_concurrency_run.log`

## Current State

This run now passes in the VM as the latest bounded Stage F single-chiplet
orchestration reference point.

Current PASS evidence is:

1. `logs/run_041_summary.txt` says `judge=PASS`
2. `logs/tb_control_chip_bounded_orchestration_result.txt` says
   `compile_status=PASS`, `run_status=PASS`, and `judge=PASS`
3. `logs/tb_control_chip_bounded_orchestration_run.log` contains
   `tb_control_chip_bounded_orchestration PASS`
4. `logs/tb_top_level_bounded_memory_integration_result.txt` says `judge=PASS`
5. `logs/tb_top_level_bounded_memory_integration_run.log` contains
   `tb_top_level_bounded_memory_integration PASS`
6. `logs/tb_request_controller_wide_concurrency_result.txt` says `judge=PASS`
7. `logs/tb_request_controller_wide_concurrency_run.log` contains
   `tb_request_controller_wide_concurrency PASS`

This run still stays bounded:

1. it proves one bounded `control_chip` orchestration slice
2. it includes one bounded comparator/flush event and one real top-level `HBM`
   write request
3. it does not claim full chiplet closure
4. it does not permit forbidden shortcut wiring or SRAM internal flush
