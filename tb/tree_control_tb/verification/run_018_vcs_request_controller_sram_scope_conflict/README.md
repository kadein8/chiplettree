# run_018_vcs_request_controller_sram_scope_conflict

Bounded Stage D1e verification for SRAM-scoped bank/subbank conflict handling
in `request_controller`.

Expected D1e scope:

1. keep the single upstream request input
2. treat physical conflict keys as `sram_id + bank_id + subbank_id`
3. allow reads targeting different SRAM slices to issue together even when their
   bank/subbank numbers match
4. backpressure same-SRAM, same-bank, same-subbank, different-address reads
   instead of issuing them together or merging them incorrectly
5. preserve previous D0/D1a/D1b/D1c/D1d and corrected ABCD behavior through
   regressions

Included regressions:

1. `tb_request_controller_bootstrap`
2. `tb_request_controller_read_merge`
3. `tb_tree_stage_abcd_integration`
4. `tb_request_controller_multilane_issue`
5. `tb_request_controller_four_lane_issue`
6. `tb_request_controller_multi_merge`
7. `tb_request_controller_sram_scope_conflict`

Out of scope: complex priority ordering among multiple simultaneously visible
upstream candidates, merge depth beyond `MEM_REQ_LANES`, mixed read/write
parallelism, comparator, chiplet-top closure.