# run_015_vcs_request_controller_multilane_issue

Bounded Stage D1b verification for real multi-lane issue and PE-side
multi-lane response in `request_controller`.

Expected D1b scope:

1. `request_controller` may buffer a second independent read after the first
   read, without changing the single upstream request input
2. two independent reads targeting different bank/subbank resources may issue
   to SRAM lane0/lane1 together
3. two SRAM responses may return to PE-side response lane0/lane1 together
4. PE-side response is multi-lane; do not serialize two different PE responses
   through a single `resp_out_*` port
5. full four-lane scheduling, complex priority arbitration, write/read mixed
   parallelism, comparator, and chiplet-top closure remain out of scope

Included regressions:

1. `tb_request_controller_bootstrap`
2. `tb_request_controller_read_merge`
3. `tb_tree_stage_abcd_integration`
4. `tb_request_controller_multilane_issue`