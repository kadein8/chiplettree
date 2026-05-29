# run_049_vcs_control_chip_post_variable_len_writeback_reentry

## Purpose

This run is the selected next bounded Stage F top-level target above the latest
VM-proven variable-length writeback reference point:

1. `run_048_vcs_control_chip_variable_len_token_writeback`

It is selected to prove that `control_chip` can:

1. complete one already-proven `run_048`-style variable-length writeback wave
2. return to a clean idle boundary
3. accept one later bounded re-entry launch
4. finish one later bounded `prepare -> PE consume -> completion` wave

while still preserving the user-confirmed ownership split:

1. `AGU -> prefetch_queue -> free_list -> bank_state_table`
2. `AGU -> token_register`
3. `token_register lookup -> SRAM`
4. `PE -> request_controller -> SRAM -> PE response`

## Scope

Included bounded scope:

1. one first-wave exact `run_048`-style variable-length writeback packet case
2. one clean idle boundary after that packet
3. one later bounded second launch
4. second-wave `busy` re-assertion
5. one fresh second-wave `prep_req_valid` window plus one later
   `survivor_read_done` pulse
6. no second-wave flush marker
7. no second-wave top-level writeback packet
8. regression re-run of:
   - `tb_control_chip_variable_len_token_writeback`
   - `tb_control_chip_third_flush_writeback_closure`
   - `tb_control_chip_third_flush_reclosure`
   - `tb_control_chip_post_second_flush_reentry`
   - `tb_control_chip_second_flush_writeback_closure`
   - `tb_control_chip_second_flush_reclosure`
   - `tb_control_chip_post_flush_reentry`
   - `tb_control_chip_bounded_orchestration`
   - `tb_top_level_bounded_memory_integration`
   - `tb_request_controller_wide_concurrency`

Explicitly excluded:

1. a new comparator/flush event in the same proof
2. a second top-level variable-length writeback packet in the same proof
3. a new survivor-selection proof in the same proof
4. a new accepted-token-length sweep in the same proof
5. full chiplet closure
6. steady-state multi-round continuation
7. direct `comparator -> token_register`
8. direct `comparator -> bank_state_table`
9. `bank_state_table -> token_register`
10. direct `token_register lookup -> request_controller`
11. SRAM internal flush

## VM Command

```bash
cd /home/ICer/first/verification/run_049_vcs_control_chip_post_variable_len_writeback_reentry/scripts
bash run_tb_control_chip_post_variable_len_writeback_reentry.sh
```

Full suite:

```bash
cd /home/ICer/first/verification/run_049_vcs_control_chip_post_variable_len_writeback_reentry/scripts
bash run_all_vcs.sh
```

## Judgment Rule

Read these files before claiming PASS or FAIL:

1. `logs/run_049_summary.txt`
2. `logs/tb_control_chip_post_variable_len_writeback_reentry_result.txt`
3. `logs/tb_control_chip_post_variable_len_writeback_reentry_run.log`
4. `logs/tb_control_chip_variable_len_token_writeback_result.txt`
5. `logs/tb_control_chip_variable_len_token_writeback_run.log`
6. each regression TB `*_result.txt`
7. each regression TB `*_run.log`

## Current State

`run_049` is now VM-proven.

Interpretation boundary:

1. `run_049` is now the latest VM-proven bounded Stage F checkpoint
2. `run_048` remains the bounded variable-length writeback reference point
   beneath `run_049`
3. the PASS judgment is based on `logs/run_049_summary.txt`, the per-TB
   `*_result.txt` files, and the per-TB `*_run.log` PASS banners
4. `run_049` is still not allowed to claim full chiplet closure, steady-state
   multi-round continuation, or the long-term multi-token control target
