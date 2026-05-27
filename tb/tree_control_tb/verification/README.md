# Verification Workspace

This directory is the executable verification workspace for the project.

## Policy

1. each verification round gets its own numbered run directory
2. each run directory contains only:
   - `scripts/`
   - `logs/`
3. scripts are prepared in this shared workspace and executed by the user in
   the CentOS VM through the existing soft link
4. pass/fail judgment is performed later by reading the generated log files
5. new run directories should only be created after the target RTL stage has
   real behavior
6. before claiming PASS or FAIL, read `run_*_summary.txt`, per-TB
   `*_result.txt`, and `*_run.log`

## Current Prepared And Historical Runs

1. `run_001_vcs_bringup`
2. `run_004_vcs_agu_stage_b`
3. `run_005_vcs_prefetch_queue_stage_b`
4. `run_006_vcs_stage_b_realign`
5. `run_007_vcs_stage_c_sram_min`
6. `run_008_vcs_tree_analyze_agu_frontend`
7. `run_009_vcs_tree_stage_b_dispatch`
8. `run_010_vcs_tree_stage_c_token_to_sram`
9. `run_011_vcs_tree_stage_abc_integration`
10. `run_012_vcs_request_controller_bootstrap`
11. `run_013_vcs_tree_stage_abcd_integration`
12. `run_014_vcs_request_controller_read_merge`
13. `run_015_vcs_request_controller_multilane_issue`
14. `run_016_vcs_request_controller_four_lane_issue`
15. `run_017_vcs_request_controller_multi_merge`
16. `run_018_vcs_request_controller_sram_scope_conflict`
17. `run_019_vcs_request_controller_priority_arbitration`
18. `run_020_vcs_request_controller_mixed_read_write`
19. `run_021_vcs_comparator_d0_basic`
20. `run_022_vcs_comparator_agu_freeze`
21. `run_023_vcs_comparator_prefetch_queue_flush`
22. `run_024_vcs_comparator_free_list_flush`
23. `run_025_vcs_comparator_bank_state_table_flush`
24. `run_026_vcs_comparator_alloc_status_flush_path`
25. `run_027_vcs_comparator_token_register_flush`
26. `run_028_vcs_comparator_dual_path_flush_coherence`
27. `run_029_vcs_comparator_multi_branch_flush`
28. `run_030_vcs_comparator_multi_branch_alloc_status_reuse`
29. `run_031_vcs_comparator_alloc_status_drain_ordering`
30. `run_032_vcs_comparator_async_multi_depth_reduction`
31. `run_033_vcs_comparator_async_multi_depth_stop_issue`
32. `run_034_vcs_comparator_async_multi_depth_stale_drop`
33. `run_035_vcs_comparator_async_ordering`
34. `run_036_vcs_comparator_accepted_path_longest_path`
35. `run_037_vcs_comparator_async_ordering_wide`
36. `run_038_vcs_stage_e_lifecycle_closure`
37. `run_039_vcs_top_level_bounded_memory_integration`
38. `run_040_vcs_request_controller_wide_concurrency`
39. `run_041_vcs_control_chip_bounded_orchestration`
40. `run_042_vcs_control_chip_post_flush_reentry`
41. `run_043_vcs_control_chip_second_flush_reclosure`
42. `run_044_vcs_control_chip_second_flush_writeback_closure`
43. `run_045_vcs_control_chip_post_second_flush_reentry`
44. `run_046_vcs_control_chip_third_flush_reclosure`
45. `run_047_vcs_control_chip_third_flush_writeback_closure`
46. `run_048_vcs_control_chip_variable_len_token_writeback`
47. `run_049_vcs_control_chip_post_variable_len_writeback_reentry`
48. `run_050_vcs_control_chip_post_reentry_flush_writeback_closure`
49. `run_051_vcs_control_chip_second_post_reentry_flush_writeback_chain`
50. `run_052_vcs_control_chip_dual_tree_near_steady_state_closure`
51. `run_053_vcs_control_chip_serial_three_tree_final_closure`
52. `run_054_vcs_control_chip_serial_free_running_surrogate`
53. `run_055_vcs_control_chip_tree_driven_strict_serial_closure`
54. `run_056_vcs_control_chip_tree_driven_serial_long_span_closure`

## Current Passing Interpretation Boundary

The current VCS-backed passing baseline covers:

1. Stage A allocation and metadata core
2. the current Stage B AGU slice under the realigned
   `AGU -> prefetch_queue -> free_list -> bank_state_table` contract
3. the Stage B `prefetch_queue` selective-flush slice
4. the bounded Stage C SRAM slice in `sram_subbank`, `sram_bank`, and
   `sram_subsystem`
5. the bounded `tree_analyze -> AGU` shared-prefix plus layered-frontier
   front-end normalization slice
6. the first tree-driven Stage B dispatch slice
7. the first tree-driven Stage C bridge from `token_register` lookup into real
   SRAM access
8. the first bounded Stage ABC tree-driven integration slice
9. the first corrected bounded Stage ABCD integration slice using a PE/compute
   stub into `request_controller`
10. bounded Stage D0 request-controller bootstrap in `request_controller`
11. bounded Stage D1a same-address read-read merge in `request_controller`
12. bounded Stage D1b two-lane independent read issue and PE-side multi-lane
    response in `request_controller`
13. bounded Stage D1c four-lane independent read issue and PE-side four-lane
    response in `request_controller`
14. bounded Stage D1d four-entry same-address read-read merge and PE-side
    four-lane fan-out in `request_controller`
15. bounded Stage D1e SRAM-scoped conflict handling and priority arbitration in
    `request_controller`
16. bounded Stage D1f mixed read/write handling in `request_controller`
17. bounded standalone comparator D0 mask generation in `comparator`
18. bounded comparator-driven AGU freeze using
    `comparator.flush_valid -> agu.flush_freeze`
19. bounded comparator-driven AGU-owned `prefetch_queue` selective flush
20. bounded comparator-driven AGU-owned `free_list` selective reclaim
21. bounded comparator-driven `free_list -> bank_state_table` reclaim handoff
22. bounded complete first allocation/status flush path with one later reuse
    check
23. bounded comparator-driven AGU-owned metadata flush into `token_register`
24. bounded coordinated single-flush dual-path coherence across the separated
    allocation/status path and metadata path
25. bounded multi-branch dual-path flush with serialized
    `free_list -> bank_state_table` reclaim and one later allocation reuse
    plus survivor metadata stability
26. bounded allocation/status-only post-flush multi-reuse closure after one
    multi-branch flush event
27. bounded allocation/status-only drain ordering where AGU acceptance stays
    closed until serialized reclaim drain completes, then reopens for one
    later stable reuse
28. bounded comparator-only async multi-depth accepted-prefix reduction with
    up to `4` live branches and one shallower discriminating prune event
29. bounded AGU stop-issue after async multi-depth accepted-prefix reduction
30. bounded stale late-result drop after async multi-depth accepted-prefix
    reduction and stop-issue
31. bounded async ordering across reduction, stale-drop, one later flush
    window, and post-flush survivor reopen
32. bounded accepted-path progression from shallow to deep compatible
    acceptance with longest-path survivor selection
33. bounded wider async ordering after accepted-path progression to the final
    longest-path survivor
34. bounded Stage E lifecycle closure after accepted-path convergence, with one
    coordinated downstream flush across the separated allocation/status path
    and metadata path, one later survivor continuation, one later reclaimed-
    capacity reuse, and one later metadata lookup-stability check
35. bounded top-level memory/control reassembly that keeps
    `tree/front-end -> AGU`, allocation/status path, metadata path,
    `token_register lookup -> SRAM`, and
    `PE -> request_controller -> SRAM -> PE response` in one run without
    ownership collapse
36. bounded wider PE-side request-controller concurrency with repeated mixed
    read/write windows, delayed PE-ready hold windows, and preserved `run_020`
    plus `run_039` regressions
37. bounded Stage F single-chiplet orchestration with one bounded
    comparator/flush event, one bounded survivor continuation, and one real
    top-level `HBM` write request
38. bounded Stage F post-flush re-entry with one `run_041`-style first wave,
    one idle boundary, one second bounded top-level launch, one second bounded
    `token_register lookup -> SRAM` preparation, one second bounded PE-side
    read/response completion, and no second required flush/writeback proof
39. bounded Stage F second-flush re-closure with one `run_041`-style first
    wave, one `run_042`-style wave-2 re-entry prefix, one second bounded
    comparator/flush event, re-closure of both separated downstream ownership
    paths, one later survivor-only continuation, and no second required
    top-level writeback closure
40. bounded Stage F second-flush writeback closure with one bounded post-
    second-flush survivor `commit/writeback` action plus one second top-level
    `HBM` write request before idle returns
41. bounded Stage F post-second-flush re-entry with one bounded `run_044`-
    style wave-2 closure, one real idle boundary, one third bounded top-level
    launch, one third bounded `prepare -> PE consume -> completion` wave, and
    no third flush/writeback/top-level-`HBM`-write requirement
42. bounded Stage F third-flush re-closure with one bounded `run_045`-style
    wave-3 re-entry prefix, one bounded third preflush prepare, one bounded
    third PE-side completion before flush, exactly one bounded third flush,
    both `token_flush_valid` and `flush_reclaim_valid`, one later
    survivor-only continuation, and one later return to idle, without a third
    writeback closure or a third top-level `HBM` write request
43. bounded Stage F third-flush writeback closure with one bounded
    post-third-flush survivor `commit/writeback` action plus one third
    top-level `HBM` write request before idle returns
44. bounded Stage F variable-length top-level token writeback with one
    single-beat accepted-token packet carrying real `new_token_len` in
    `{1, 2, 3}` plus ordered `token0`, `token1`, and `token2` fields inside
    `hbm_req_wdata`
45. bounded Stage F post-variable-length-writeback re-entry with one exact
    `run_048`-style writeback wave, one clean idle boundary after that
    writeback, and one later bounded re-entry wave with one fresh
    `prep_req_valid` window plus one later `survivor_read_done` pulse
46. bounded Stage F post-reentry flush/writeback closure with one exact
    `run_048`-style writeback wave, one clean idle boundary after that
    writeback, one later bounded wave-2 preflush completion, exactly one new
    flush, one later postflush survivor continuation, and one later top-level
    writeback only after that new flush
47. bounded Stage F second post-reentry flush/writeback chain with one exact
    `run_048`-style wave-1 packet case, one exact `run_050`-style wave-2
    closure, one second clean idle boundary, and one later bounded wave-3
    slice with one preflush completion, one new flush, one later postflush
    survivor continuation, and one new top-level writeback only after that
    new flush
48. bounded Stage F dual-tree near-steady-state closure with one serial
    `Tree A -> idle -> Tree B -> idle` witness, repeated per-tree flushes,
    preserved per-tree concurrency windows, and one final postflush survivor
    multi-token writeback per tree
49. bounded Stage F serial three-tree final closure with one serial
    `Tree A -> idle -> Tree B -> idle -> Tree C -> idle` witness, repeated
    per-tree flushes, preserved per-tree concurrency windows, and one final
    postflush survivor multi-token writeback per tree
50. bounded Stage F tree-driven strict-serial closure with one serial
    five-tree witness, runtime-derived effective flushes, one clean no-flush
    closure role, one stale late-result drop role, preserved survivor
    continuation after effective flush, and one runtime-derived final survivor
    writeback per tree
51. bounded Stage F tree-driven serial long-span closure with one strict-serial
    eight-tree witness, runtime-classified whole-run checking, runtime-derived
    effective flushes, and one later-span back-half flush/writeback witness
52. bounded Stage F tree-driven reusable-idle final closure with one
    strict-serial five-tree witness, one reusable idle contract after every
    finished tree, and one final return to the same reusable idle contract

The current passing reference runs are:

1. `run_006_vcs_stage_b_realign`
2. `run_007_vcs_stage_c_sram_min`
3. `run_008_vcs_tree_analyze_agu_frontend`
4. `run_009_vcs_tree_stage_b_dispatch`
5. `run_010_vcs_tree_stage_c_token_to_sram`
6. `run_011_vcs_tree_stage_abc_integration`
7. `run_012_vcs_request_controller_bootstrap`
8. `run_013_vcs_tree_stage_abcd_integration`
9. `run_014_vcs_request_controller_read_merge`
10. `run_015_vcs_request_controller_multilane_issue`
11. `run_016_vcs_request_controller_four_lane_issue`
12. `run_017_vcs_request_controller_multi_merge`
13. `run_018_vcs_request_controller_sram_scope_conflict`
14. `run_019_vcs_request_controller_priority_arbitration`
15. `run_020_vcs_request_controller_mixed_read_write`
16. `run_021_vcs_comparator_d0_basic`
17. `run_022_vcs_comparator_agu_freeze`
18. `run_023_vcs_comparator_prefetch_queue_flush`
19. `run_024_vcs_comparator_free_list_flush`
20. `run_025_vcs_comparator_bank_state_table_flush`
21. `run_026_vcs_comparator_alloc_status_flush_path`
22. `run_027_vcs_comparator_token_register_flush`
23. `run_028_vcs_comparator_dual_path_flush_coherence`
24. `run_029_vcs_comparator_multi_branch_flush`
25. `run_030_vcs_comparator_multi_branch_alloc_status_reuse`
26. `run_031_vcs_comparator_alloc_status_drain_ordering`
27. `run_032_vcs_comparator_async_multi_depth_reduction`
28. `run_033_vcs_comparator_async_multi_depth_stop_issue`
29. `run_034_vcs_comparator_async_multi_depth_stale_drop`
30. `run_035_vcs_comparator_async_ordering`
31. `run_036_vcs_comparator_accepted_path_longest_path`
32. `run_037_vcs_comparator_async_ordering_wide`
33. `run_038_vcs_stage_e_lifecycle_closure`
34. `run_039_vcs_top_level_bounded_memory_integration`
35. `run_040_vcs_request_controller_wide_concurrency`
36. `run_041_vcs_control_chip_bounded_orchestration`
37. `run_042_vcs_control_chip_post_flush_reentry`
38. `run_043_vcs_control_chip_second_flush_reclosure`
39. `run_044_vcs_control_chip_second_flush_writeback_closure`
40. `run_045_vcs_control_chip_post_second_flush_reentry`
41. `run_046_vcs_control_chip_third_flush_reclosure`
42. `run_047_vcs_control_chip_third_flush_writeback_closure`
43. `run_048_vcs_control_chip_variable_len_token_writeback`
44. `run_049_vcs_control_chip_post_variable_len_writeback_reentry`
45. `run_050_vcs_control_chip_post_reentry_flush_writeback_closure`
46. `run_051_vcs_control_chip_second_post_reentry_flush_writeback_chain`
47. `run_052_vcs_control_chip_dual_tree_near_steady_state_closure`
48. `run_053_vcs_control_chip_serial_three_tree_final_closure`
49. `run_054_vcs_control_chip_serial_free_running_surrogate`
50. `run_055_vcs_control_chip_tree_driven_strict_serial_closure`
51. `run_056_vcs_control_chip_tree_driven_serial_long_span_closure`
52. `run_057_vcs_control_chip_tree_driven_reusable_idle_final_closure`

What the current passing baseline still does not prove:

1. multiple simultaneous upstream input ports into `request_controller`
2. merge depth beyond `MEM_REQ_LANES`
3. wider multi-wave or multi-event Stage F orchestration around `control_chip`
   beyond the bounded `run_057` tree-driven reusable-idle proof
4. full end-to-end chiplet closure beyond bounded run workspaces
5. fully input-driven or unbounded top-level free-running continuation across
   arbitrary later trees and later bounded flush schedules
6. accepted-token writeback behavior beyond the bounded single-beat `{1, 2, 3}`
   packet range from `run_048`, plus any wider multi-wave continuation beyond
   `run_057`

## Latest Completed Run

The latest completed bounded run is
`run_057_vcs_control_chip_tree_driven_reusable_idle_final_closure`.

Its scope is:

1. one tree-driven strict-serial five-tree reusable-idle sequence in one
   bounded run
2. every later tree launch occurs only after the previous tree reaches the
   same reusable idle contract
3. whole-run coverage of one clean no-flush closure, one single-effective-
   flush closure, one multi-effective-flush closure, one stale-late-result-
   drop closure, one survivor-continuation closure, and one multi-token final
   writeback
4. at least one back-half tree with flush-bearing closure
5. at least one back-half tree with multi-token final writeback
6. effective flush count derived from tree input plus runtime verification
   events instead of prewritten per-tree helper truth
7. one visible stale late-result drop case without reviving wrong-side work
8. preserved survivor continuation after effective flush
9. one runtime-derived final survivor writeback per tree, with each writeback
   occurring only after that tree's last effective flush when a flush occurs
10. strict serial `Tree i -> idle -> Tree i+1` top-level launch order
11. final return to the same reusable idle contract after the last tree
12. regression preservation for `tb_control_chip_tree_driven_serial_long_span_closure`
13. regression preservation for `tb_control_chip_tree_driven_strict_serial_closure`
14. regression preservation for `tb_control_chip_serial_free_running_surrogate`
15. regression preservation for `tb_control_chip_serial_three_tree_final_closure`
16. regression preservation for `tb_control_chip_dual_tree_near_steady_state_closure`
17. regression preservation for `tb_control_chip_second_post_reentry_flush_writeback_chain`
18. regression preservation for `tb_control_chip_post_reentry_flush_writeback_closure`
19. regression preservation for `tb_control_chip_post_variable_len_writeback_reentry`
20. regression preservation for `tb_control_chip_variable_len_token_writeback`
21. regression preservation for `tb_control_chip_third_flush_writeback_closure`
22. regression preservation for `tb_control_chip_third_flush_reclosure`
23. regression preservation for `tb_control_chip_post_second_flush_reentry`
24. regression preservation for `tb_control_chip_second_flush_writeback_closure`
25. regression preservation for `tb_control_chip_second_flush_reclosure`
26. regression preservation for `tb_control_chip_post_flush_reentry`
27. regression preservation for `tb_control_chip_bounded_orchestration`
28. regression preservation for `tb_top_level_bounded_memory_integration`
29. regression preservation for `tb_request_controller_wide_concurrency`
30. the proof remains bounded and does not claim overlap closure,
    reopen-before-idle closure, mathematical unbounded proof, or broader full
    chiplet closure outside the selected strict-serial reusable-idle contract

Latest VM-side result:

1. `run_057_summary.txt` records `judge=PASS` and all listed run-script exit
   codes at `0`
2. `tb_control_chip_tree_driven_reusable_idle_final_closure_result.txt`
   records:
   - `compile_status=PASS`
   - `run_status=PASS`
   - `judge=PASS`
3. `tb_control_chip_tree_driven_reusable_idle_final_closure_run.log`
   contains `tb_control_chip_tree_driven_reusable_idle_final_closure PASS`
4. the full `run_057` suite keeps each included TB `*_result.txt` at
   `judge=PASS`
5. the full `run_057` suite keeps each included TB `*_run.log` PASS banner
   intact

## Next Recommended Step

The current bounded Stage F status after `run_057` is:

1. `run_057_vcs_control_chip_tree_driven_reusable_idle_final_closure` is now
   the latest VM-proven bounded Stage F checkpoint
2. `run_056_vcs_control_chip_tree_driven_serial_long_span_closure` remains the
   bounded long-span witness reference point beneath `run_057`
3. `run_055_vcs_control_chip_tree_driven_strict_serial_closure` remains the
   bounded tree-driven strict-serial five-tree reference point beneath
   `run_056`
4. `run_054_vcs_control_chip_serial_free_running_surrogate` remains the
   bounded serial free-running surrogate reference point beneath `run_055`
5. keep the existing path split:
   `AGU -> prefetch_queue -> free_list -> bank_state_table`,
   `AGU -> token_register`,
   `token_register lookup -> SRAM`, and
   `PE -> request_controller -> SRAM -> PE response`
6. `run_057` proves one bounded strict-serial reusable-idle witness where
   top-level launch stays strictly serial, effective flushes are
   runtime-derived, stale late results are dropped, survivor work continues,
   multi-token final writeback remains runtime-derived, and the final tree
   returns to the same reusable idle contract
7. the verified VM PASS evidence for `run_057` is
   `verification/run_057_vcs_control_chip_tree_driven_reusable_idle_final_closure/logs/run_057_summary.txt`
   plus each per-TB `result` and `run.log`
8. the `run_056` design doc is
    `docs/design/00_project/2026-05-01-stage-f-chiplet-top-tree-driven-serial-long-span-closure-design.md`
9. the `run_056` implementation plan is
    `docs/design/00_project/2026-05-01-stage-f-chiplet-top-tree-driven-serial-long-span-closure-implementation-plan.md`
10. the `run_057` design doc is
    `docs/design/00_project/2026-05-01-stage-f-chiplet-top-tree-driven-reusable-idle-final-closure-design.md`
11. the `run_057` implementation plan is
    `docs/design/00_project/2026-05-01-stage-f-chiplet-top-tree-driven-reusable-idle-final-closure-implementation-plan.md`
12. record the long-term final top-level control target as steady-state
    per-tree operation with parallel compute, multiple-token output, bounded
    flush handling, and clean next-round restart while preserving the ownership
    split
13. within the selected project definition, `run_057` is the final
    project-internal sign-off checkpoint
14. `run_057` still does not prove overlap, reopen-before-idle,
    mathematical unbounded continuation, arbitrary-flush closure, or broader
    full-chiplet closure outside that selected contract
15. no later stronger bounded Stage F target is planned after `run_057`
    unless scope changes
16. do not introduce direct `comparator -> token_register`, direct
    `comparator -> bank_state_table`, `bank_state_table -> token_register`,
    direct `token_register lookup -> request_controller`, or SRAM internal flush
17. any later scope expansion must remain separate from `run_057`

The current carry-forward flush interpretation is wrong-subtree selective
rather than whole-tree global stop: only the killed wrong subtree is pruned,
compatible survivors continue, killed branches stop issuing, stale late
results are dropped, and later nodes inside the killed wrong subtree do not
continue verification as if the flush did not happen.

Any later target above `run_057` must remain bounded and preserve the same ownership split,
no-shortcut rules, and no-SRAM-internal-flush rule.

Reference docs for the broader Stage F line:

1. the Stage F design doc is
   `docs/design/00_project/2026-04-26-stage-f-chiplet-top-bounded-orchestration-design.md`
2. the Stage F implementation plan is
   `docs/design/00_project/2026-04-26-stage-f-chiplet-top-bounded-orchestration-implementation-plan.md`

## Latest Passing Stage E Run

The latest bounded Stage E lifecycle-closure run is:

1. `run_038_vcs_stage_e_lifecycle_closure`
2. it verifies:
   - accepted-path convergence to the longest-path survivor before flush
   - one coordinated flush event across the separated allocation/status path
     and metadata path
   - victim-only removal from `prefetch_queue`, `free_list`,
     `bank_state_table`, and `token_register`
   - survivor preservation across both ownership paths
   - one later survivor-only continuation check
   - one later reclaimed-capacity reuse check
   - one later metadata lookup-stability check
3. it does not verify:
   - full top-level memory/control reassembly
   - request-controller participation in the same run
   - SRAM internal flush
4. it now passes in the VM
5. `run_032_vcs_comparator_async_multi_depth_reduction` remains the bounded
    comparator-only accepted-prefix reduction checkpoint
6. `run_036` remains the bounded accepted-path / longest-path checkpoint
   below `run_037`, and `run_037` remains the widened async-ordering
   checkpoint immediately below `run_038`
7. `run_038` stays AGU-controlled and does not rely on direct
   `comparator -> token_register` wiring
8. `run_038` does not rely on direct `comparator -> bank_state_table` wiring
9. `run_038` does not rely on `bank_state_table -> token_register`
10. `run_039` now passes in the VM and proves bounded top-level
    memory/control reassembly without collapsing ownership
11. `run_040` now passes in the VM and proves wider PE-side sustained
    request-controller pressure without reintroducing comparator lifecycle or
    metadata/allocation replay
12. the `run_038 -> run_039 -> run_040` ladder is now complete
13. none of the future Stage F runs may violate the user-confirmed ownership
    split or add SRAM internal flush

The current metadata-oriented reference run preserves
`comparator -> AGU/control -> token_register`.

SRAM internals are not a Stage E flush target.
`prefetch_queue` flush controls must continue to come from `AGU/control`, and
`free_list` flush controls must also continue to come from `AGU/control`.
`bank_state_table` must not be wired as the driver of `token_register`.

Comparator D0 still excludes:

1. parent-walk and broader accepted-path closure beyond the current bounded
   incremental reduction
2. parent-walk semantics
3. downstream lifecycle consumers
4. Stage E lifecycle closure
5. chiplet-top integration
