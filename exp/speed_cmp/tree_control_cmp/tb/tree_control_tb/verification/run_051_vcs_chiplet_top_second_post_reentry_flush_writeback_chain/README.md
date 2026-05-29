# run_051_vcs_control_chip_second_post_reentry_flush_writeback_chain

## Purpose

This run is the latest VM-proven bounded Stage F top-level checkpoint above the
earlier post-reentry flush/writeback closure reference point:

1. `run_050_vcs_control_chip_post_reentry_flush_writeback_closure`

It is selected to prove that `control_chip` can:

1. complete one exact `run_048`-style variable-length writeback wave
2. return to a clean idle boundary
3. complete one exact `run_050`-style wave-2 flush/writeback closure
4. return to one second clean idle boundary
5. accept one later bounded wave-3 re-entry launch
6. complete one bounded wave-3 preflush PE-side completion
7. issue one new later wave-3 flush across the separated ownership paths
8. complete one later wave-3 postflush survivor continuation
9. emit one new later wave-3 top-level writeback only after that new flush

while still preserving the user-confirmed ownership split:

1. `AGU -> prefetch_queue -> free_list -> bank_state_table`
2. `AGU -> token_register`
3. `token_register lookup -> SRAM`
4. `PE -> request_controller -> SRAM -> PE response`

## Scope

Included bounded scope:

1. one first-wave exact `run_048`-style variable-length writeback packet case
2. one clean idle boundary after that packet
3. one exact `run_050`-style wave-2 closure
4. one second clean idle boundary after the wave-2 writeback
5. one later bounded third launch
6. one wave-3 preflush `prep_done` plus one wave-3 preflush
   `survivor_read_done`
7. one new wave-3 `flush_done` marker plus one new wave-3
   `token_flush_valid` and `flush_reclaim_valid`
8. one later wave-3 postflush `survivor_read_done`
9. one later wave-3 top-level writeback only after the new wave-3 flush
10. one later final return to idle
11. regression re-run of:
   - `tb_control_chip_post_reentry_flush_writeback_closure`
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

1. any wave-4 or later continuation in the same proof
2. more than one new flush event in the wave-3 slice
3. any wave-3 top-level writeback before the new wave-3 flush
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
cd /home/ICer/first/verification/run_051_vcs_control_chip_second_post_reentry_flush_writeback_chain/scripts
bash run_tb_control_chip_second_post_reentry_flush_writeback_chain.sh
```

Full suite:

```bash
cd /home/ICer/first/verification/run_051_vcs_control_chip_second_post_reentry_flush_writeback_chain/scripts
bash run_all_vcs.sh
```

## Judgment Rule

Read these files before claiming PASS or FAIL:

1. `logs/run_051_summary.txt`
2. `logs/tb_control_chip_second_post_reentry_flush_writeback_chain_result.txt`
3. `logs/tb_control_chip_second_post_reentry_flush_writeback_chain_run.log`
4. `logs/tb_control_chip_post_reentry_flush_writeback_closure_result.txt`
5. `logs/tb_control_chip_post_reentry_flush_writeback_closure_run.log`
6. each regression TB `*_result.txt`
7. each regression TB `*_run.log`

## Current State

`run_051` is now VM-proven.

Interpretation boundary:

1. `run_051` is now the latest VM-proven bounded Stage F checkpoint
2. `run_050` remains the bounded first post-reentry flush/writeback reference
   point beneath `run_051`
3. the PASS judgment is based on `logs/run_051_summary.txt`, the per-TB
   `*_result.txt` files, and the per-TB `*_run.log` files
4. `run_051` is still not allowed to claim full chiplet closure,
   steady-state multi-round continuation, or the long-term multi-token control
   target
