# run_017_vcs_request_controller_multi_merge

Bounded Stage D1d verification for multi-entry same-address read-read merge in
`request_controller`.

Expected D1d scope:

1. keep the single upstream request input
2. accept up to `MEM_REQ_LANES=4` logical same-address read requests in one
   collect window
3. issue exactly one physical SRAM read for that same-address group
4. fan out the returned SRAM lane0 data to PE response lane0-3 with per-lane
   `req_id` and `pe_mask`
5. preserve previous D0/D1a/D1b/D1c and corrected ABCD behavior through
   regressions

Included regressions:

1. `tb_request_controller_bootstrap`
2. `tb_request_controller_read_merge`
3. `tb_tree_stage_abcd_integration`
4. `tb_request_controller_multilane_issue`
5. `tb_request_controller_four_lane_issue`
6. `tb_request_controller_multi_merge`

Out of scope: merge depth beyond `MEM_REQ_LANES`, mixed same-address and
independent-read packing in the same issue group, complex priority arbitration,
mixed read/write parallelism, comparator, chiplet-top closure.