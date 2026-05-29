# run_012_vcs_request_controller_bootstrap

## Purpose

This run is the first bounded Stage D0 verification target after the passing
`run_011` Stage ABC baseline.

It verifies a narrow `request_controller -> sram_subsystem -> request_controller`
bootstrap path.

## Scope

Included behavior:

1. one upstream request accepted by `request_controller`
2. one physical lane-0 memory issue into real `sram_subsystem`
3. write passthrough without a fake read response
4. read response return with saved `req_id`, `pe_mask`, and `last`
5. upstream backpressure while one read is busy

Explicitly excluded:

1. same-address read-read merge
2. merged response fan-out
3. multi-lane parallel issue
4. comparator lifecycle behavior
5. full chiplet integration

## VM Command

```bash
cd /home/ICer/first/verification/run_012_vcs_request_controller_bootstrap/scripts
bash run_all_vcs.sh
```

## Judgment Rule

Read these files before claiming PASS or FAIL:

1. `logs/run_012_summary.txt`
2. `logs/tb_request_controller_bootstrap_result.txt`
3. `logs/tb_request_controller_bootstrap_run.log`
## VM Result

The VM execution on 2026-04-21 records PASS.

Evidence:

1. `logs/run_012_summary.txt` records `judge=PASS`
2. `logs/tb_request_controller_bootstrap_result.txt` records compile PASS and
   run PASS
3. `logs/tb_request_controller_bootstrap_run.log` contains
   `tb_request_controller_bootstrap PASS`

This is a bounded Stage D0 proof only. It does not prove same-address
read-read merge, multi-lane parallel issue, comparator lifecycle behavior, or
full chiplet integration.