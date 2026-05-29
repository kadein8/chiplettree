# run_016_vcs_request_controller_four_lane_issue

Bounded Stage D1c verification for full `MEM_REQ_LANES=4` read issue and
PE-side four-lane response in `request_controller`.

Expected D1c scope:

1. keep the single upstream request input
2. collect four independent reads targeting different bank/subbank resources
3. issue them together on SRAM lane0/lane1/lane2/lane3
4. return four PE-side response lanes together with per-lane `req_id` and
   `pe_mask`
5. preserve previous D0/D1a/D1b and corrected ABCD behavior through regressions

Included regressions:

1. `tb_request_controller_bootstrap`
2. `tb_request_controller_read_merge`
3. `tb_tree_stage_abcd_integration`
4. `tb_request_controller_multilane_issue`
5. `tb_request_controller_four_lane_issue`

Out of scope: multi-entry same-address merge queues, complex priority
arbitration, mixed read/write parallelism, comparator, chiplet-top closure.