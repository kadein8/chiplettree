# run_020_vcs_request_controller_mixed_read_write

Bounded Stage D1f verification for mixed read/write behavior in `request_controller`.

Expected D1f scope:

1. keep the single upstream request input
2. preserve D0/D1a/D1b/D1c/D1d/D1e request-controller behavior through regressions
3. allow independent read/write requests that target different SRAM resources to issue together on separate physical lanes
4. backpressure same-SRAM, same-bank, same-subbank read/write requests when they target different addresses
5. implement same-address read/write as write-first plus request-controller bypass: one physical SRAM write is issued, and the logical read response returns the write data with the read request metadata
6. keep same-address read-read merge separate from read/write bypass
7. keep write-write requests serialized; no write merge or write coalescing is claimed

Included regressions:

1. `tb_request_controller_bootstrap`
2. `tb_request_controller_read_merge`
3. `tb_tree_stage_abcd_integration`
4. `tb_request_controller_multilane_issue`
5. `tb_request_controller_four_lane_issue`
6. `tb_request_controller_multi_merge`
7. `tb_request_controller_sram_scope_conflict`
8. `tb_request_controller_priority_order`
9. `tb_request_controller_mixed_read_write`

Out of scope: multiple simultaneous upstream input ports, merge depth beyond `MEM_REQ_LANES`, comparator behavior, chiplet-top closure, and full chiplet closure.