# run_014_vcs_request_controller_read_merge

Bounded Stage D1a verification for same-address read-read merge in
`request_controller`.

Expected D1a scope:

1. two upstream reads to the same SRAM address may be accepted while the first
   read is in flight
2. only one physical SRAM read is issued for the merged pair
3. two logical responses are returned with their own `req_id` and `pe_mask`
4. the existing bootstrap path still passes, with different-address busy
   backpressure preserved
5. multi-lane issue, different-address arbitration, comparator, and chiplet-top
   closure remain out of scope

Included TBs:

1. `tb_request_controller_bootstrap`
2. `tb_request_controller_read_merge`