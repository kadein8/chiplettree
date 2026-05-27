# run_019_vcs_request_controller_priority_arbitration

Bounded Stage D1e completion verification for conflict, priority arbitration,
and backpressure behavior in `request_controller`.

Expected complete D1e scope:

1. keep the single upstream request input
2. keep physical conflict keys scoped as `sram_id + bank_id + subbank_id`
3. backpressure conflicting requests that cannot be granted in the current issue
   group; the upstream owner must hold/replay them through ready/valid
4. order collected independent read requests by `req_in_priority` before issue,
   with higher numeric priority using lower-numbered SRAM/PE response lanes
5. preserve arrival order as the tie-break rule for equal priority
6. preserve previous D0/D1a/D1b/D1c/D1d and corrected ABCD behavior through
   regressions

Included regressions:

1. `tb_request_controller_bootstrap`
2. `tb_request_controller_read_merge`
3. `tb_tree_stage_abcd_integration`
4. `tb_request_controller_multilane_issue`
5. `tb_request_controller_four_lane_issue`
6. `tb_request_controller_multi_merge`
7. `tb_request_controller_sram_scope_conflict`
8. `tb_request_controller_priority_order`

Out of scope: multiple simultaneous upstream input ports, merge depth beyond
`MEM_REQ_LANES`, mixed read/write parallelism, comparator, chiplet-top closure.