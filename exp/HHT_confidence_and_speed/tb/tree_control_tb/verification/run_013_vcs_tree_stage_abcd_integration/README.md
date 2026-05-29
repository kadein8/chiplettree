# run_013_vcs_tree_stage_abcd_integration

## Purpose

This run is the corrected bounded ABCD integration target after `run_011` and
`run_012`.

It follows the architecture diagram:

1. Stage ABC prepares allocation and token/SRAM state
2. `token_register lookup -> SRAM` is used for token/SRAM preparation
3. PE/compute-side request stub enters `request_controller`
4. `request_controller` communicates with SRAM and returns response metadata to
   the PE/compute side

## Scope

Included behavior:

1. `tree_analyze -> AGU -> prefetch_queue -> free_list -> bank_state_table`
   with same-step `free_list -> AGU` candidate feedback
2. parallel `AGU -> token_register`
3. token lookup obtains SRAM physical location
4. SRAM data is prepared at the lookup-derived location
5. PE-stub read request enters `request_controller`
6. `request_controller -> sram_subsystem -> request_controller response`
7. response data, `req_id`, `pe_mask`, and `last` return to the PE-stub side

Explicitly excluded:

1. direct `token_register lookup -> request_controller` wiring
2. same-address read-read merge
3. multi-lane parallel issue
4. full PE compute
5. comparator lifecycle behavior
6. full chiplet integration

## VM Command

```bash
cd /home/ICer/first/verification/run_013_vcs_tree_stage_abcd_integration/scripts
bash run_all_vcs.sh
```

## Judgment Rule

Read these files before claiming PASS or FAIL:

1. `logs/run_013_summary.txt`
2. `logs/tb_tree_stage_abcd_integration_result.txt`
3. `logs/tb_tree_stage_abcd_integration_compile.log`
4. `logs/tb_tree_stage_abcd_integration_run.log`
