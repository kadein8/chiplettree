# run_021_vcs_comparator_d0_basic

## Purpose

This run is the first bounded standalone comparator verification target after
the passing `run_020` request-controller mixed read/write baseline.

It verifies only the D0 compare rule in `code/comparator.v`.

## Scope

Included behavior:

1. `cmp_valid=0` drives all outputs to zero
2. equal token ids produce commit-only one-hot masks
3. unequal token ids produce flush-only one-hot masks
4. branch low/high boundary values map to the correct branch mask bits
5. node low/high boundary values map to the correct node mask bits

Explicitly excluded:

1. accepted-path or longest-path selection
2. parent-walk through `cmp_parent_node_id`
3. simultaneous commit plus flush
4. comparator-driven lifecycle consumers
5. full Stage E closure or chiplet integration

## VM Command

```bash
cd /home/ICer/first/verification/run_021_vcs_comparator_d0_basic/scripts
bash run_all_vcs.sh
```

## Judgment Rule

Read these files before claiming PASS or FAIL:

1. `logs/run_021_summary.txt`
2. `logs/tb_comparator_d0_basic_result.txt`
3. `logs/tb_comparator_d0_basic_run.log`

## VM Result

The VM execution on 2026-04-23 records PASS.

Evidence:

1. `logs/run_021_summary.txt` records `judge=PASS`
2. `logs/tb_comparator_d0_basic_result.txt` records compile PASS and run PASS
3. `logs/tb_comparator_d0_basic_run.log` contains
   `tb_comparator_d0_basic PASS`

This is a bounded standalone comparator D0 proof only. It does not prove
accepted-path selection, comparator-driven lifecycle behavior, or full chiplet
integration.
