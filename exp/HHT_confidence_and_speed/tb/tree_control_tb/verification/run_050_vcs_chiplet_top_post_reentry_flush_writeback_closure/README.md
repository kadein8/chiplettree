# run_050_vcs_control_chip_post_reentry_flush_writeback_closure

## Purpose

This run is the selected next bounded Stage F top-level target above the latest
VM-proven post-writeback re-entry reference point:

1. `run_049_vcs_control_chip_post_variable_len_writeback_reentry`

It is selected to prove that `control_chip` can:

1. complete one exact `run_048`-style variable-length writeback wave
2. return to a clean idle boundary
3. accept one later bounded re-entry launch
4. complete one bounded preflush PE-side completion
5. issue one new flush across the separated ownership paths
6. complete one later postflush survivor continuation
7. emit one new top-level writeback only after that new flush

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
4. one preflush `prep_done` plus one preflush `survivor_read_done`
5. one new `flush_done` marker plus one new `token_flush_valid` and
   `flush_reclaim_valid`
6. one later postflush `survivor_read_done`
7. one later top-level writeback only after the new flush
8. one later return to idle
9. regression re-run of:
   - `tb_control_chip_post_variable_len_writeback_reentry`
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

1. any wave-3 or later continuation in the same proof
2. more than one new flush event in the wave-2 slice
3. any top-level writeback before the new flush
4. a new accepted-token-length sweep beyond the reused wave-1 packet case
5. full chiplet closure
6. steady-state multi-round continuation
7. steady-state multi-token closure
8. direct `comparator -> token_register`
9. direct `comparator -> bank_state_table`
10. `bank_state_table -> token_register`
11. direct `token_register lookup -> request_controller`
12. SRAM internal flush

## VM Command

```bash
cd /home/ICer/first/verification/run_050_vcs_control_chip_post_reentry_flush_writeback_closure/scripts
bash run_tb_control_chip_post_reentry_flush_writeback_closure.sh
```

Full suite:

```bash
cd /home/ICer/first/verification/run_050_vcs_control_chip_post_reentry_flush_writeback_closure/scripts
bash run_all_vcs.sh
```

## Judgment Rule

Read these files before claiming PASS or FAIL:

1. `logs/run_050_summary.txt`
2. `logs/tb_control_chip_post_reentry_flush_writeback_closure_result.txt`
3. `logs/tb_control_chip_post_reentry_flush_writeback_closure_run.log`
4. `logs/tb_control_chip_post_variable_len_writeback_reentry_result.txt`
5. `logs/tb_control_chip_post_variable_len_writeback_reentry_run.log`
6. each regression TB `*_result.txt`
7. each regression TB `*_run.log`

## Current State

`run_050` is now VM-proven.

Interpretation boundary:

1. `run_050` is now the latest VM-proven bounded Stage F checkpoint
2. `run_049` remains the bounded post-writeback re-entry reference point
   beneath `run_050`
3. the PASS judgment is based on `logs/run_050_summary.txt`, the per-TB
   `*_result.txt` files, and the per-TB `*_run.log` PASS banners
4. `run_050` is still not allowed to claim full chiplet closure,
   steady-state multi-round continuation, or the long-term multi-token control
   target
