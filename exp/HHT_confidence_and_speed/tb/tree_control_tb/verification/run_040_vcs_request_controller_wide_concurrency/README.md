# run_040_vcs_request_controller_wide_concurrency

## Purpose

This run is the next bounded PE-side request-controller target after
VM-passing `run_039_vcs_top_level_bounded_memory_integration`.

It stays on the PE-side memory path only:

1. `PE -> request_controller -> SRAM -> PE response`

It widens bounded pressure by adding:

1. a wider read-only collection window with priority ordering
2. repeated mixed read/write rounds across multiple issue windows
3. repeated held-response windows where PE readiness is delayed

## Scope

Included behavior:

1. one four-read priority-sorted issue round
2. one held-response backlog window with upstream backpressure
3. one wider same-address read/write bypass round plus an unrelated read
4. one independent read/write round on separate resources
5. one later readback round that confirms write persistence
6. regression re-run of:
   - `tb_request_controller_mixed_read_write`
   - `tb_top_level_bounded_memory_integration`

Explicitly excluded:

1. comparator lifecycle widening
2. metadata replay
3. allocation/status replay
4. direct `token_register lookup -> request_controller`
5. SRAM internal flush
6. full chiplet closure

## VM Command

```bash
cd /home/ICer/first/verification/run_040_vcs_request_controller_wide_concurrency/scripts
bash run_all_vcs.sh
```

## Judgment Rule

Read these files before claiming PASS or FAIL:

1. `logs/run_040_summary.txt`
2. `logs/tb_request_controller_wide_concurrency_result.txt`
3. `logs/tb_request_controller_wide_concurrency_run.log`
4. `logs/tb_request_controller_mixed_read_write_result.txt`
5. `logs/tb_request_controller_mixed_read_write_run.log`
6. `logs/tb_top_level_bounded_memory_integration_result.txt`
7. `logs/tb_top_level_bounded_memory_integration_run.log`

## Current State

This run now has VM PASS evidence.

The current evidence chain is:

1. `logs/run_040_summary.txt` records `judge=PASS`
2. `logs/tb_request_controller_wide_concurrency_result.txt` records
   `compile_status=PASS`, `run_status=PASS`, and `judge=PASS`
3. `logs/tb_request_controller_wide_concurrency_run.log` contains
   `tb_request_controller_wide_concurrency PASS`
4. `logs/tb_request_controller_mixed_read_write_result.txt` records
   `judge=PASS`
5. `logs/tb_top_level_bounded_memory_integration_result.txt` records
   `judge=PASS`
