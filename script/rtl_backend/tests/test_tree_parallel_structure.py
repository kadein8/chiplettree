import json
from pathlib import Path
import inspect
import re
import sys


ROOT = Path(__file__).resolve().parents[4]


def read(rel: str) -> str:
    return (ROOT / rel).read_text(encoding="utf-8")


def test_control_chip_uses_request_controller_vec_path():
    text = read("code/rtl/tree_control/control_chip_stage2_single_chiplet.v")
    iface = read("code/rtl/config/interface_params.vh")
    assert "`define PE_MASK_W                16" in iface
    assert "`define TREE_VERIFY_PE_LANES     `PE_MASK_W" in iface
    assert "`define MEM_REQ_LANES            `TREE_VERIFY_PE_LANES" in iface
    assert "`define NODE_ID_W                5" in iface
    assert "tree_verify_dispatcher u_tree_verify_dispatcher" in text
    assert ".tree_req_valid(tree_parallel_req_valid_w)" in text
    assert ".batch_out_valid(tree_parallel_batch_valid_w)" in text
    assert ".vec_req_valid(tree_parallel_vec_req_valid_w)" in text
    assert ".vec_req_ready(tree_parallel_vec_req_ready_w)" in text
    assert ".vec_req_write(tree_parallel_vec_req_write_w)" in text
    assert ".vec_req_addr(tree_parallel_vec_req_addr_w)" in text
    assert ".vec_req_wdata(tree_parallel_vec_req_wdata_w)" in text
    assert ".vec_req_req_id(tree_parallel_vec_req_req_id_w)" in text
    assert ".vec_req_pe_mask(tree_parallel_vec_req_pe_mask_w)" in text
    assert "assign rc_main_req_pe_mask_w = 16'h0001;" not in text
    assert "assign rc_main_req_pe_mask_w = {{(`PE_MASK_W-1){1'b0}}, 1'b1};" in text
    assert ".vec_req_valid({`MEM_REQ_LANES{1'b0}})" not in text
    assert "wire [`MEM_REQ_LANES-1:0] tree_parallel_vec_resp_valid_raw_w;" in text
    assert "assign tree_parallel_vec_resp_valid_raw_w = mc_pe_valid_w;" in text
    assert ".vec_sram_resp_valid(tree_parallel_vec_resp_valid_w)" in text
    assert ".vec_sram_resp_ready(tree_parallel_vec_resp_ready_w)" in text
    assert "wire tree_parallel_scalar_resp_select_w;" in text
    assert "assign tree_parallel_sram_resp_valid_w =" in text
    assert "tree_parallel_scalar_resp_orphan_drain_w" in text
    assert re.search(
        r"assign\s+tree_parallel_sram_resp_valid_w\s*=\s*"
        r"\(tree_parallel_scalar_resp_select_w\s*&&[\s\S]*?"
        r"!\s*tree_parallel_scalar_resp_orphan_drain_w\)\s*\?\s*"
        r"lane0_resp_valid_w\s*:\s*1'b0;",
        text,
    )
    assert "multicast_network u_multicast_network" in text
    assert "request_controller u_request_controller" in text


def test_tree_parallel_lane0_scalar_orphan_response_is_drained_before_next_scalar_read():
    text = read("code/rtl/tree_control/control_chip_stage2_single_chiplet.v")
    assert "wire tree_parallel_scalar_resp_orphan_drain_w;" in text
    assert "wire tree_parallel_scalar_resp_consume_w;" in text
    assert re.search(
        r"assign\s+tree_parallel_scalar_resp_orphan_drain_w\s*=\s*"
        r"tree_parallel_scalar_resp_select_w\s*&&[\s\S]*?"
        r"tree_parallel_sram_rd_valid_w\s*&&[\s\S]*?"
        r"!\s*tree_parallel_sram_rd_ready_w\s*&&[\s\S]*?"
        r"!\s*tree_parallel_sram_resp_ready_w",
        text,
    ), (
        "tree-parallel scalar lane0 must be able to drain an orphan response "
        "before the next scalar read has been accepted"
    )
    assert re.search(
        r"assign\s+tree_parallel_scalar_resp_consume_w\s*=\s*"
        r"tree_parallel_sram_resp_ready_w\s*\|\|[\s\S]*?"
        r"tree_parallel_scalar_resp_orphan_drain_w",
        text,
    )
    assert re.search(
        r"tree_parallel_scalar_resp_select_w\s*\?\s*"
        r"\{\{\(`PE_MASK_W-1\)\{1'b1\}\},\s*"
        r"tree_parallel_scalar_resp_consume_w\}",
        text,
    )


def test_tree_parallel_vector_orphan_responses_are_drained_before_next_draft_reads():
    text = read("code/rtl/tree_control/control_chip_stage2_single_chiplet.v")
    assert "wire [`MEM_REQ_LANES-1:0] tree_parallel_vec_resp_orphan_drain_w;" in text
    assert "wire [`MEM_REQ_LANES-1:0] tree_parallel_vec_resp_consume_w;" in text
    assert re.search(
        r"assign\s+tree_parallel_vec_resp_orphan_drain_w\[\s*"
        r"tree_parallel_vec_resp_lane_g\]\s*=\s*"
        r"tree_parallel_vec_resp_is_draft_w\[tree_parallel_vec_resp_lane_g\]\s*&&[\s\S]*?"
        r"tree_parallel_vec_rd_valid_raw_w\[tree_parallel_vec_resp_lane_g\]\s*&&[\s\S]*?"
        r"!\s*tree_parallel_vec_req_ready_w\[tree_parallel_vec_resp_lane_g\]\s*&&[\s\S]*?"
        r"!\s*tree_parallel_vec_resp_ready_w\[tree_parallel_vec_resp_lane_g\]",
        text,
    ), (
        "tree-parallel draft lanes must drain parked vector responses before a "
        "new draft read has been accepted on the same lane"
    )
    assert re.search(
        r"assign\s+tree_parallel_vec_resp_consume_w\[\s*tree_parallel_vec_resp_lane_g\]\s*=\s*"
        r"tree_parallel_vec_resp_ready_w\[tree_parallel_vec_resp_lane_g\]\s*\|\|[\s\S]*?"
        r"tree_parallel_vec_resp_orphan_drain_w\[\s*tree_parallel_vec_resp_lane_g\]",
        text,
    )
    assert re.search(
        r"assign\s+tree_parallel_vec_resp_valid_w\[\s*tree_parallel_vec_resp_lane_g\]\s*=\s*"
        r"tree_parallel_vec_resp_orphan_drain_w\[\s*tree_parallel_vec_resp_lane_g\]\s*\?\s*1'b0\s*:\s*"
        r"tree_parallel_vec_resp_valid_raw_w\[\s*tree_parallel_vec_resp_lane_g\]",
        text,
    )
    assert re.search(
        r"assign\s+mc_pe_ready_w\s*=\s*[\s\S]*?"
        r"tree_parallel_resp_select_w\s*\?\s*"
        r"tree_parallel_vec_resp_consume_w\s*:",
        text,
    )


def test_request_controller_allows_vector_writes():
    text = read("code/rtl/tree_control/request_controller.v")
    assert "if (vec_req_write[vec_i] === 1'b1) begin" not in text
    assert "vec_group_supported_c = 1'b1;" in text
    assert "vec_accept_same_addr_merge_c = 1'b1;" in text


def test_request_controller_can_serialize_conflicting_vector_groups():
    text = read("code/rtl/tree_control/request_controller.v")
    assert "lane_issued_r" in text
    assert "issue_all_reqs_accepted_c" in text
    assert "!lane_issued_r[lane_i]" in text
    assert "if (mem_req_valid_c[resp_i] && mem_req_ready[resp_i]) begin" in text
    assert "if (!issue_all_reqs_accepted_c) begin" in text


def test_request_controller_registers_vector_responses_before_feeding_multicast_ready():
    text = read("code/rtl/tree_control/request_controller.v")
    assert "assign resp_out_valid = resp_valid_r;" in text
    assert "assign resp_out_valid = resp_valid_r | resp_now_valid_c;" not in text
    assert "if (resp_now_valid_c[resp_i]) begin" in text
    assert "if (resp_now_valid_c[resp_i] && !resp_out_ready[resp_i]) begin" not in text
    assert "if (lane_valid_r[resp_i] && !lane_write_r[resp_i] &&\n                            !lane_merge_r[resp_i] && !lane_bypass_r[resp_i] &&\n                            mem_resp_valid[resp_i]) begin" in text
    assert "resp_out_rdata_c[(lane_i*`SRAM_RDATA_W) +: `SRAM_RDATA_W] =" in text


def test_batch_verify_path_exposes_vector_sram_ports():
    inference = read("code/rtl/transformer/fp16_inference_top.sv")
    tree_attn = read("code/rtl/transformer/fp16_mha_tree_attention.sv")
    dispatcher = read("code/rtl/transformer/tree_verify_dispatcher.sv")
    assert "vec_sram_rd_valid" in inference
    assert "vec_sram_wr_valid" in inference
    assert "vec_sram_rd_valid" in tree_attn
    assert "vec_sram_wr_valid" in tree_attn
    assert "batch_in_tree_mask" in inference
    assert "batch_in_slot_is_seed" in inference
    assert "batch_out_tree_mask" in dispatcher
    assert "batch_out_slot_is_seed" in dispatcher
    assert "commit_slots" in dispatcher
    assert "commit_slot_positions" in dispatcher
    assert "gen_mha_slot" in tree_attn or "generate" in tree_attn
    assert "draft_mha_barrier_release_w" in tree_attn
    assert "draft_mha_result_ready_w =" in tree_attn
    assert "localparam [REQ_ID_W-1:0] SLOT_REQ_ID_W" in tree_attn
    assert "localparam [SLOT_ID_W-1:0] SLOT_QUERY_ID_W" in tree_attn
    assert ".issue_req_id(SLOT_REQ_ID_W)" in tree_attn
    assert ".issue_tree_query_slot(SLOT_QUERY_ID_W)" in tree_attn
    assert "vec_sram_rd_valid = draft_mha_rd_valid_w;" in tree_attn
    assert "vec_sram_wr_valid = draft_mha_wr_valid_w;" in tree_attn
    assert "vec_sram_rd_pe_mask = draft_mha_rd_pe_mask_w;" in tree_attn
    assert "vec_sram_wr_pe_mask = draft_mha_wr_pe_mask_w;" in tree_attn
    assert "({{(`PE_MASK_W-1){1'b0}}, 1'b1} << gen_mha_slot)" in tree_attn


def test_batch_mha_draft_lane_pe_mask_is_not_gated_by_one_cycle_issue_pulse():
    tree_attn = read("code/rtl/transformer/fp16_mha_tree_attention.sv")
    assert "draft_slot_issue_valid_w ?\n" not in tree_attn
    assert "draft_mha_active_w[gen_mha_slot]" in tree_attn


def test_batch_draft_lane_req_ids_have_16_unique_nonzero_codes():
    iface = read("code/rtl/config/interface_params.vh")
    stimulus = read("code/script/rtl_backend/stimulus.py")
    tree_attn = read("code/rtl/transformer/fp16_mha_tree_attention.sv")
    req_id_match = re.search(r"`define REQ_ID_W\s+(\d+)", iface)
    assert req_id_match, "REQ_ID_W define missing"
    assert int(req_id_match.group(1)) >= 5
    assert re.search(r"^REQ_ID_W\s*=\s*5\s*$", stimulus, re.MULTILINE)
    assert "function automatic [REQ_ID_W-1:0] nonzero_slot_req_id;" not in tree_attn
    assert "nonzero_slot_req_id = {REQ_ID_W{1'b1}};" not in tree_attn
    assert (
        "localparam [REQ_ID_W-1:0] SLOT_REQ_ID_W =\n"
        "            SLOT_WIRE_IDX[REQ_ID_W-1:0];"
    ) in tree_attn


def test_stimulus_bit_width_is_derived_from_req_id_width_on_host_and_tb():
    stimulus = read("code/script/rtl_backend/stimulus.py")
    tb = read(
        "code/tb/tree_control_tb/"
        "tb_control_chip_stage2_single_chiplet_native_tree_main_frontend_platform_driver.v"
    )
    assert "STIMULUS_BITS = 2525" not in stimulus
    assert "localparam integer STIMULUS_BITS = 2525;" not in tb
    assert re.search(r"STIMULUS_BITS\s*=\s*\(", stimulus), (
        "host stimulus width must be derived, not hardcoded"
    )
    assert re.search(r"localparam integer STIMULUS_BITS\s*=\s*[\s\S]*?REQ_ID_W", tb), (
        "tb stimulus width must depend on REQ_ID_W"
    )


def test_tb_declares_stimulus_helper_localparams_before_stimulus_bits_uses_them():
    tb = read(
        "code/tb/tree_control_tb/"
        "tb_control_chip_stage2_single_chiplet_native_tree_main_frontend_platform_driver.v"
    )
    stimulus_bits_idx = tb.index("localparam integer STIMULUS_BITS =")
    frontier_levels_idx = tb.index("localparam integer STIMULUS_FRONTIER_LEVELS =")
    visible_mask_idx = tb.index("localparam integer STIMULUS_VISIBLE_MASK_W =")
    assert frontier_levels_idx < stimulus_bits_idx
    assert visible_mask_idx < stimulus_bits_idx


def test_tree_parallel_timeout_dump_includes_residual_add_and_lane_valid_write_state():
    tb = read(
        "code/tb/tree_control_tb/"
        "tb_control_chip_stage2_single_chiplet_native_tree_main_frontend_platform_driver.v"
    )
    assert "res1draft0_state=%0d" in tb
    assert "res1draft15_state=%0d" in tb
    assert "res1draft0_x_req_accepted=%0d" in tb
    assert "res1draft15_r_req_accepted=%0d" in tb
    assert "postdraft0_state=%0d" in tb
    assert "postdraft15_state=%0d" in tb
    assert "postdraft0_x_req_accepted=%0d" in tb
    assert "postdraft15_g_req_accepted=%0d" in tb
    assert "ffndraft0_state=%0d" in tb
    assert "ffndraft15_state=%0d" in tb
    assert "ffndraft0_gate_req_accepted=%0d" in tb
    assert "ffndraft15_up_req_accepted=%0d" in tb
    assert "lane_valid=%0d" in tb
    assert "lane_write=%0d" in tb


def test_tree_parallel_timeout_dump_includes_top_level_lifecycle_busy_breakdown():
    tb = read(
        "code/tb/tree_control_tb/"
        "tb_control_chip_stage2_single_chiplet_native_tree_main_frontend_platform_driver.v"
    )
    assert "[tree-parallel-debug] busy=%0d tree_busy=%0d" in tb
    assert "tree_parallel_mode=%0d" in tb
    assert "tree_parallel_busy=%0d" in tb
    assert "native_tree_main_busy=%0d" in tb
    assert "closure_sidecar_busy=%0d" in tb
    assert "native_tree_sidecar_busy=%0d" in tb
    assert "native_tree_lifecycle_busy=%0d" in tb
    assert "lifecycle_window_active=%0d" in tb
    assert "tree_parallel_session_active=%0d" in tb
    assert "active_issue_valid=%0d" in tb
    assert "lifecycle_cmp_fire=%0d" in tb
    assert "tree_parallel_commit_pending=%0d" in tb
    assert "tree_parallel_commit_replay_active=%0d" in tb
    assert "tree_parallel_kv_commit_busy=%0d" in tb
    assert "tree_parallel_wb_pending_state=%0d" in tb
    assert "token_wr_valid=%0d" in tb
    assert "free_list_flush_drain_busy=%0d" in tb


def test_tb_emits_preload_progress_events_before_cfg_start():
    tb = read(
        "code/tb/tree_control_tb/"
        "tb_control_chip_stage2_single_chiplet_native_tree_main_frontend_platform_driver.v"
    )
    assert r"\"event\":\"preload_start\"" in tb
    assert r"\"event\":\"preload_progress\"" in tb
    assert r"\"event\":\"preload_done\"" in tb
    assert r"\"phase\":\"sram\"" in tb
    assert r"\"phase\":\"hbm\"" in tb
    assert "localparam integer PRELOAD_PROGRESS_STRIDE = 256;" in tb


def test_tb_flushes_preload_events_so_vm_side_monitoring_sees_live_progress():
    tb = read(
        "code/tb/tree_control_tb/"
        "tb_control_chip_stage2_single_chiplet_native_tree_main_frontend_platform_driver.v"
    )
    preload_region = tb[
        tb.index("task automatic emit_preload_start;"):
        tb.index("task automatic preload_toy_model_memh_once;")
    ]
    assert preload_region.count("$fflush(event_fd);") >= 3


def test_tb_flushes_key_runtime_events_so_post_preload_liveness_is_observable():
    tb = read(
        "code/tb/tree_control_tb/"
        "tb_control_chip_stage2_single_chiplet_native_tree_main_frontend_platform_driver.v"
    )
    cfg_start_region = tb[
        tb.index("if (cfg_valid && start) begin"):
        tb.index("if (|(draft_cand_valid & draft_cand_ready)) begin")
    ]
    verify_capture_region = tb[
        tb.index("if (u_control_chip_stage2_single_chiplet.native_tree_main_frontier_capture_fire_w) begin"):
        tb.index("if (u_control_chip_stage2_single_chiplet.native_tree_main_pred_fire_w ||")
    ]
    native_tree_req_region = tb[
        tb.index("if (native_tree_req_valid && native_tree_req_ready) begin"):
        tb.index("if (u_control_chip_stage2_single_chiplet.native_tree_main_req_fire_w) begin")
    ]
    native_tree_main_req_region = tb[
        tb.index("if (u_control_chip_stage2_single_chiplet.native_tree_main_req_fire_w) begin"):
        tb.index("if (u_control_chip_stage2_single_chiplet.native_tree_main_frontier_capture_fire_w) begin")
    ]
    verify_issue_region = tb[
        tb.index("if (u_control_chip_stage2_single_chiplet.native_tree_main_pred_fire_w ||"):
        tb.index("if (u_control_chip_stage2_single_chiplet.issue_valid &&")
    ]
    wb_done_start = tb.index("if (wb_done) begin")
    wb_done_region = tb[wb_done_start:wb_done_start + 1600]
    assert "$fflush(event_fd);" in cfg_start_region
    assert "$fflush(event_fd);" in native_tree_req_region
    assert "$fflush(event_fd);" in native_tree_main_req_region
    assert "$fflush(event_fd);" in verify_capture_region
    assert "$fflush(event_fd);" in verify_issue_region
    assert "$fflush(event_fd);" in wb_done_region


def test_tb_logs_tree_parallel_entry_and_state_progress_for_live_stall_localization():
    tb = read(
        "code/tb/tree_control_tb/"
        "tb_control_chip_stage2_single_chiplet_native_tree_main_frontend_platform_driver.v"
    )
    assert r"\"event\":\"tree_parallel_req_fire\"" in tb
    assert r"\"event\":\"tree_parallel_dispatcher_state\"" in tb
    assert r"\"event\":\"tree_parallel_batch_top_state\"" in tb
    assert "tree_parallel_dispatcher_state_prev_r" in tb
    assert "tree_parallel_batch_top_state_prev_r" in tb
    assert tb.count("$fflush(event_fd);") >= 10


def test_tb_logs_tree_parallel_batch_inner_state_heartbeat_for_long_layer_waits():
    tb = read(
        "code/tb/tree_control_tb/"
        "tb_control_chip_stage2_single_chiplet_native_tree_main_frontend_platform_driver.v"
    )
    assert r"\"event\":\"tree_parallel_batch_inner_state\"" in tb
    assert r"\"reason\":\"%0s\"" in tb
    assert r"\"tree_attn_state\":%0d" in tb
    assert r"\"seed_mha_state\":%0d" in tb
    assert r"\"draft0_state\":%0d" in tb
    assert r"\"draft15_state\":%0d" in tb
    assert r"\"ffn_draft0_state\":%0d" in tb
    assert r"\"ffn_draft15_state\":%0d" in tb
    assert r"\"ffn_draft15_matvec_state\":%0d" in tb
    assert r"\"ffn_draft15_matvec_beat_idx\":%0d" in tb
    assert r"\"ffn_draft15_matvec_tile_row\":%0d" in tb
    assert r"\"ffn_draft15_matvec_tile_col\":%0d" in tb
    assert r"\"ffn_draft15_gate_req_accepted\":%0d" in tb
    assert r"\"ffn_draft15_up_req_accepted\":%0d" in tb
    assert r"\"draft_active_mask_hex\":\"0x%0h\"" in tb
    assert r"\"draft_done_mask_hex\":\"0x%0h\"" in tb
    assert r"\"vec_resp_valid_mask_hex\":\"0x%0h\"" in tb
    assert r"\"vec_resp_ready_mask_hex\":\"0x%0h\"" in tb
    assert r"\"rc_lane_valid_mask_hex\":\"0x%0h\"" in tb
    assert r"\"rc_lane_issued_mask_hex\":\"0x%0h\"" in tb
    assert r"\"sram_lane_busy_mask_hex\":\"0x%0h\"" in tb
    assert r"\"req_ctrl_state\":%0d" in tb
    assert "TREE_PARALLEL_BATCH_WAIT_HEARTBEAT_CYCLES" in tb


def test_tb_does_not_emit_large_inner_state_snapshot_on_req_ctrl_microstate_only():
    tb = read(
        "code/tb/tree_control_tb/"
        "tb_control_chip_stage2_single_chiplet_native_tree_main_frontend_platform_driver.v"
    )
    trigger_region = tb[
        tb.index(
            "if ((u_control_chip_stage2_single_chiplet\n"
            "                 .u_tree_parallel_batch_inference_top\n"
            "                 .u_fp16_mha_tree_attention\n"
            "                 .state_r !== tree_parallel_tree_attn_state_prev_r) ||"
        ):
        tb.index('emit_tree_parallel_batch_inner_state("state_change");')
    ]
    assert ".u_request_controller.state_r !==" not in trigger_region
    assert r"\"req_ctrl_state\":%0d" in tb
    assert 'emit_tree_parallel_batch_inner_state("heartbeat");' in tb


def test_agu_does_not_wait_on_bank_state_alloc_ack_before_releasing_tree_progress():
    agu = read("code/rtl/tree_control/agu.v")
    assert "if (alloc_resp_valid && (alloc_resp_req_id == pending_req_id_r)) begin" not in agu


def test_strict_single_step_token_dump_uses_query_token_instead_of_bonus_wb_token():
    tb = read(
        "code/tb/tree_control_tb/"
        "tb_control_chip_stage2_single_chiplet_native_tree_main_frontend_platform_driver.v"
    )
    assert "reg [`TOKEN_ID_W-1:0] strict_capture_query_token_r;" in tb
    assert (
        "dump_strict_hidden_and_token(\n"
        "                    strict_capture_index_r,\n"
        "                    strict_branch_slot_r,\n"
        "                    strict_capture_query_token_r"
    ) in tb
    assert (
        "strict_capture_query_token_r <=\n"
        "                    u_control_chip_stage2_single_chiplet.issue_token_id;"
    ) in tb
    assert (
        "dump_strict_hidden_and_token(\n"
        "                    strict_capture_index_r,\n"
        "                    strict_branch_slot_r,\n"
        "                    wb_token_id"
    ) not in tb
    assert (
        "dump_strict_hidden_and_token(\n"
        "                    strict_capture_index_r,\n"
        "                    strict_branch_slot_r,\n"
        "                    u_control_chip_stage2_single_chiplet.hht_active_token_id_r"
    ) not in tb


def test_tree_parallel_strict_capture_token_dump_uses_dispatcher_slot_tokens():
    tb = read(
        "code/tb/tree_control_tb/"
        "tb_control_chip_stage2_single_chiplet_native_tree_main_frontend_platform_driver.v"
    )
    task_region = tb[
        tb.index("task automatic dump_tree_parallel_strict_capture;"):
        tb.index("task automatic dump_tree_parallel_batch_debug_state;")
    ]
    assert (
        "u_control_chip_stage2_single_chiplet\n"
        "                        .u_tree_verify_dispatcher\n"
        "                        .lat_slot_token_id["
    ) in task_region
    assert (
        "u_control_chip_stage2_single_chiplet\n"
        "                        .tree_parallel_fwd_result_token_ids_w[\n"
        "                            slot_idx_i*32 +: `TOKEN_ID_W];"
    ) not in task_region


def test_tree_parallel_strict_capture_uses_private_level_stride_not_verify_stride():
    tb = read(
        "code/tb/tree_control_tb/"
        "tb_control_chip_stage2_single_chiplet_native_tree_main_frontend_platform_driver.v"
    )
    assert "flat_idx_i = (branch_i * `MAX_PRIVATE_NODES_PER_BRANCH) + level_i;" in tb
    assert "flat_idx_i = (branch_i * `MAX_VERIFY_NODES_PER_BRANCH) + level_i;" not in tb


def test_tb_single_step_strict_hidden_dump_uses_capture_shadow_while_tree_parallel_reads_slot_sram():
    tb = read(
        "code/tb/tree_control_tb/"
        "tb_control_chip_stage2_single_chiplet_native_tree_main_frontend_platform_driver.v"
    )
    assert "task automatic read_sram_storage_beat;" in tb
    assert "reg [`SRAM_WDATA_W-1:0] strict_final_hidden_sram_shadow" in tb
    assert "tree_parallel_final_hidden_sram_shadow" in tb
    dump_single = tb[
        tb.index("task automatic dump_strict_hidden_and_token;"):
        tb.index("task automatic dump_tree_parallel_hidden_and_token;")
    ]
    dump_tree = tb[
        tb.index("task automatic dump_tree_parallel_hidden_and_token;"):
        tb.index("task automatic dump_tree_parallel_strict_capture;")
    ]
    assert "strict_final_hidden_shadow[strict_dump_idx_i]" in dump_single
    assert "read_sram_storage_beat(" not in dump_single
    assert "read_sram_storage_beat(" in dump_tree
    assert "tree_parallel_final_hidden_sram_shadow[slot_idx_i][beat_i]" not in dump_tree


def test_tb_hidden_dump_does_not_depend_on_lane0_mem_req_shadow():
    tb = read(
        "code/tb/tree_control_tb/"
        "tb_control_chip_stage2_single_chiplet_native_tree_main_frontend_platform_driver.v"
    )
    region = tb[
        tb.index("task automatic dump_strict_hidden_and_token;"):
        tb.index("initial begin")
    ]
    assert "mem_req_valid[0]" not in region
    assert ".fp16_sram_wr_valid_w" not in region
    assert ".batch_norm_draft_wr_valid_w" not in region
    assert "storage_beats_debug[" in tb


def test_tb_hidden_dump_tracks_accepted_work_final_writes_from_mem_req_fabric():
    tb = read(
        "code/tb/tree_control_tb/"
        "tb_control_chip_stage2_single_chiplet_native_tree_main_frontend_platform_driver.v"
    )
    runtime_region = tb[
        tb.index("if (u_control_chip_stage2_single_chiplet.native_tree_main_pred_fire_w ||"):
        tb.index("if (hbm_req_valid && hbm_req_write) begin")
    ]
    assert "for (mem_shadow_lane_i = 0;" in runtime_region
    assert "u_control_chip_stage2_single_chiplet.mem_req_valid[mem_shadow_lane_i]" in runtime_region
    assert "u_control_chip_stage2_single_chiplet.mem_req_ready[mem_shadow_lane_i]" in runtime_region
    assert "u_control_chip_stage2_single_chiplet.mem_req_write[mem_shadow_lane_i]" in runtime_region
    assert "u_control_chip_stage2_single_chiplet.mem_req_addr[" in runtime_region
    assert "u_control_chip_stage2_single_chiplet.mem_req_wdata[" in runtime_region
    assert "strict_final_hidden_sram_shadow[mem_final_hidden_idx_i] <=" in runtime_region
    assert (
        "tree_parallel_final_hidden_sram_shadow[\n"
        "                            mem_final_slot_idx_i][mem_final_hidden_idx_i] <="
    ) in runtime_region
    assert ".u_fp16_inference_adapter\n                    .fp16_sram_wr_addr_w - FP16_WORK_FINAL_BASE" not in runtime_region
    assert ".batch_norm_draft_wr_addr_w[" not in runtime_region


def test_tb_logs_tree_parallel_forward_result_tokens_for_seed_and_first_drafts():
    tb = read(
        "code/tb/tree_control_tb/"
        "tb_control_chip_stage2_single_chiplet_native_tree_main_frontend_platform_driver.v"
    )
    assert r"\"event\":\"tree_parallel_fwd_result\"" in tb
    assert r"\"token0_hex\":\"0x%0h\"" in tb
    assert r"\"token1_hex\":\"0x%0h\"" in tb
    assert r"\"token2_hex\":\"0x%0h\"" in tb
    assert r"\"token3_hex\":\"0x%0h\"" in tb
    assert (
        "u_control_chip_stage2_single_chiplet\n"
        "                    .tree_parallel_fwd_result_token_ids_w[0 +: `TOKEN_ID_W]"
    ) in tb
    assert (
        "u_control_chip_stage2_single_chiplet\n"
        "                    .tree_parallel_fwd_result_token_ids_w[32 +: `TOKEN_ID_W]"
    ) in tb


def test_tb_logs_tree_parallel_seed_and_draft_logits_before_forward_result_latch():
    tb = read(
        "code/tb/tree_control_tb/"
        "tb_control_chip_stage2_single_chiplet_native_tree_main_frontend_platform_driver.v"
    )
    assert r"\"event\":\"tree_parallel_logits_seed\"" in tb
    assert r"\"event\":\"tree_parallel_logits_draft\"" in tb
    assert ".u_tree_parallel_batch_inference_top" in tb
    assert ".lm_result_valid_w" in tb
    assert ".batch_lm_draft_result_valid_w[tree_parallel_lane_i]" in tb


def test_tb_logs_fp16_issue_and_embedding_address_context_for_zero_output_debug():
    tb = read(
        "code/tb/tree_control_tb/"
        "tb_control_chip_stage2_single_chiplet_native_tree_main_frontend_platform_driver.v"
    )
    assert r"\"src_addr_hex\":\"0x%0h\"" in tb
    assert r"\"dst_addr_hex\":\"0x%0h\"" in tb
    assert r"\"event\":\"fp16_embedding_issue\"" in tb
    assert r"\"embedding_base_hex\":\"0x%0h\"" in tb
    assert r"\"result_addr_hex\":\"0x%0h\"" in tb
    assert r"\"event\":\"fp16_embedding_read\"" in tb
    assert r"\"read_addr_hex\":\"0x%0h\"" in tb


def test_tb_logs_first_embedding_final_hidden_and_lm_read_data_for_zero_output_debug():
    tb = read(
        "code/tb/tree_control_tb/"
        "tb_control_chip_stage2_single_chiplet_native_tree_main_frontend_platform_driver.v"
    )
    assert r"\"event\":\"fp16_embedding_resp\"" in tb
    assert r"\"event\":\"fp16_pre_norm_write\"" in tb
    assert r"\"event\":\"fp16_mha_out_write\"" in tb
    assert r"\"event\":\"fp16_res1_write\"" in tb
    assert r"\"event\":\"fp16_post_norm_write\"" in tb
    assert r"\"event\":\"fp16_ffn_out_write\"" in tb
    assert r"\"event\":\"fp16_res2_write\"" in tb
    assert r"\"event\":\"fp16_layer_result_write\"" in tb
    assert r"\"event\":\"fp16_final_norm_x_read\"" in tb
    assert r"\"event\":\"fp16_final_norm_gamma_read\"" in tb
    assert r"\"event\":\"fp16_final_hidden_write\"" in tb
    assert r"\"event\":\"fp16_lm_hidden_read\"" in tb
    assert r"\"event\":\"fp16_lm_weight_read\"" in tb
    assert r"\"beat_index\":%0d" in tb
    assert r"\"data_hex\":\"%0h\"" in tb
    assert "fp16_embedding_resp_logged_r" in tb
    assert "fp16_pre_norm_write_logged_r" in tb
    assert "fp16_mha_out_write_logged_r" in tb
    assert "fp16_res1_write_logged_r" in tb
    assert "fp16_post_norm_write_logged_r" in tb
    assert "fp16_ffn_out_write_logged_r" in tb
    assert "fp16_res2_write_logged_r" in tb
    assert "fp16_layer_result_write_logged_r" in tb
    assert "fp16_final_norm_x_read_logged_r" in tb
    assert "fp16_final_norm_gamma_read_logged_r" in tb
    assert "fp16_final_hidden_write_logged_r" in tb
    assert "fp16_lm_hidden_read_logged_r" in tb
    assert "fp16_lm_weight_read_logged_r" in tb
    assert ".norm_wr_ready_w" not in tb
    assert ".u_fp16_transformer_layer\n                .sram_wr_valid" in tb
    assert ".u_fp16_mha_controller\n                 .state_r == 5'd31" not in tb
    assert ".u_fp16_ffn_swiglu\n                 .state_r == 5'd15" not in tb
    assert (
        "u_control_chip_stage2_single_chiplet\n"
        "                .u_integration_operator_part\n"
        "                .gen_fp16_inference\n"
        "                .u_fp16_inference_adapter\n"
        "                .u_fp16_inference_top\n"
        "                .sram_wr_ready"
    ) in tb


def test_tb_logs_lm_head_issue_addresses_for_serial_and_tree_parallel_seed_paths():
    tb = read(
        "code/tb/tree_control_tb/"
        "tb_control_chip_stage2_single_chiplet_native_tree_main_frontend_platform_driver.v"
    )
    assert r"\"event\":\"fp16_lm_issue\"" in tb
    assert r"\"event\":\"tree_parallel_seed_lm_issue\"" in tb
    assert r"\"hidden_addr_hex\":\"0x%0h\"" in tb
    assert r"\"weight_addr_hex\":\"0x%0h\"" in tb


def test_tree_verify_dispatcher_bonus_comes_from_parent_prediction_not_same_slot_prediction():
    dispatcher = read("code/rtl/transformer/tree_verify_dispatcher.sv")
    assert "model_tok = lat_fwd_token_ids[0 +: TOKEN_ID_W];" in dispatcher
    assert (
        "model_tok = lat_fwd_token_ids[\n"
        "                                lat_branch_slot_map[(cb*MAX_LEVELS + (cl-1))*SLOT_ID_W +: SLOT_ID_W]\n"
        "                                * 32 +: TOKEN_ID_W];"
    ) in dispatcher
    assert "winner_last_slot_idx" in dispatcher
    assert "winner_predict_slot_idx" in dispatcher
    assert (
        "bonus_token =\n"
        "                lat_fwd_token_ids[winner_predict_slot_idx*32 +: TOKEN_ID_W];"
    ) in dispatcher


def test_serial_and_tree_batch_paths_share_the_same_committed_kv_base():
    iface = read("code/rtl/config/interface_params.vh")
    top = read("code/rtl/transformer/fp16_inference_top.sv")
    adapter = read("code/rtl/transformer/fp16_inference_adapter.sv")
    assert "`define KV_COMMITTED_BASE        23'd49152" in iface
    assert "parameter [ADDR_W-1:0] KV_CACHE_SRAM_BASE = `KV_COMMITTED_BASE" in top
    assert "parameter [ADDR_W-1:0] KV_CACHE_SRAM_BASE = `KV_COMMITTED_BASE" in adapter
    assert "parameter [ADDR_W-1:0] KV_CACHE_SRAM_BASE = 23'd57344" not in top
    assert "parameter [ADDR_W-1:0] KV_CACHE_SRAM_BASE = 23'd57344" not in adapter


def test_vm_prepared_scripts_read_expected_stimulus_bits_from_current_python_source():
    stage41_script = read(
        "verification/stage2/"
        "41_vcs_control_chip_stage2_single_chiplet_tree_mask_e2e_strict_bringup/"
        "scripts/run_tb_control_chip_stage2_single_chiplet_tree_mask_e2e_strict_vm_prepared.sh"
    )
    stage30_script = read(
        "verification/stage2/"
        "30_vcs_control_chip_stage2_single_chiplet_real_ssd_sync_tree_step_payload_bringup/"
        "scripts/run_tb_control_chip_stage2_single_chiplet_real_ssd_sync_tree_step_payload_vm_prepared.sh"
    )
    assert "EXPECTED_STIMULUS_BITS=2525" not in stage41_script
    assert "EXPECTED_STIMULUS_BITS=2525" not in stage30_script
    assert "StimulusCycle.STIMULUS_BITS" in stage41_script
    assert "StimulusCycle.STIMULUS_BITS" in stage30_script


def test_tree_mask_vm_prepared_script_copies_nested_stage30_logs_into_vm_return():
    text = read(
        "verification/stage2/"
        "41_vcs_control_chip_stage2_single_chiplet_tree_mask_e2e_strict_bringup/"
        "scripts/run_tb_control_chip_stage2_single_chiplet_tree_mask_e2e_strict_vm_prepared.sh"
    )
    assert "STEP30_LOG_DIR=" in text
    assert "STEP30_TB_RESULT_FILE=" in text
    assert "cp \"${STEP30_LOG_DIR}/${TB_NAME}_run.log\"" in text
    assert "cp \"${STEP30_TB_RESULT_FILE}\"" in text


def test_tree_mask_vm_prepared_script_uses_unique_nested_vcs_work_root_per_outer_run():
    text = read(
        "verification/stage2/"
        "41_vcs_control_chip_stage2_single_chiplet_tree_mask_e2e_strict_bringup/"
        "scripts/run_tb_control_chip_stage2_single_chiplet_tree_mask_e2e_strict_vm_prepared.sh"
    )
    assert "STAGE41_VCS_SESSION_TAG=" in text
    assert "STAGE41_VCS_SESSION_ROOT=" in text
    assert 'mkdir -p "${STAGE41_VCS_SESSION_ROOT}"' in text
    assert 'export VCS_WORK_ROOT="${VCS_WORK_ROOT:-${STAGE41_VCS_SESSION_ROOT}/${step_name}}"' in text
    assert 'export VCS_WORK_ROOT="${VCS_WORK_ROOT:-/tmp/codex_vcs_work/${step_name}}"' not in text


def test_vm_prepared_scripts_clear_stale_summary_files_before_new_run():
    stage41_text = read(
        "verification/stage2/"
        "41_vcs_control_chip_stage2_single_chiplet_tree_mask_e2e_strict_bringup/"
        "scripts/run_tb_control_chip_stage2_single_chiplet_tree_mask_e2e_strict_vm_prepared.sh"
    )
    stage30_text = read(
        "verification/stage2/"
        "30_vcs_control_chip_stage2_single_chiplet_real_ssd_sync_tree_step_payload_bringup/"
        "scripts/run_tb_control_chip_stage2_single_chiplet_real_ssd_sync_tree_step_payload_vm_prepared.sh"
    )
    assert 'rm -f "${SUMMARY_FILE}"' in stage41_text
    assert 'rm -f "${SUMMARY_FILE}"' in stage30_text


def test_stage30_vm_prepared_script_materializes_wrapper_result_for_outer_stage_copy():
    text = read(
        "verification/stage2/"
        "30_vcs_control_chip_stage2_single_chiplet_real_ssd_sync_tree_step_payload_bringup/"
        "scripts/run_tb_control_chip_stage2_single_chiplet_real_ssd_sync_tree_step_payload_vm_prepared.sh"
    )
    assert 'cp "${TB_RESULT_FILE}" "${RESULT_FILE}"' in text
    assert 'cp "${RESULT_FILE}" "${VM_RESULT_COPY_DIR}/${TB_NAME}_vm_prepared_result.txt"' in text


def test_tree_mask_vm_prepared_script_cleans_stale_stage41_owned_simv_before_new_outer_run():
    text = read(
        "verification/stage2/"
        "41_vcs_control_chip_stage2_single_chiplet_tree_mask_e2e_strict_bringup/"
        "scripts/run_tb_control_chip_stage2_single_chiplet_tree_mask_e2e_strict_vm_prepared.sh"
    )
    assert "cleanup_stale_stage41_simv() {" in text
    assert "STAGE41_STALE_SIMV_PATTERN=" in text
    assert 'stale_simv_pids="$(pgrep -f -- "${STAGE41_STALE_SIMV_PATTERN}" || true)"' in text
    assert 'kill ${stale_simv_pids}' in text
    assert 'sleep 1' in text
    assert 'kill -9 ${stale_simv_pids}' in text
    assert "cleanup_stale_stage41_simv" in text


def test_common_vcs_cleans_stale_rtl_step_artifacts_from_tb_workdir_before_run():
    common_vcs = read(
        "verification/stage2/"
        "30_vcs_control_chip_stage2_single_chiplet_real_ssd_sync_tree_step_payload_bringup/"
        "scripts/common_vcs.sh"
    )
    assert "find \"${tb_workdir}\" -maxdepth 1 -type f \\" in common_vcs
    assert "-name 'rtl_step*_final_hidden.memh' -o \\" in common_vcs
    assert "-name 'rtl_step*_token.txt' -o \\" in common_vcs
    assert "-name 'rtl_step2_branch*_level*_token.txt' \\" in common_vcs
    assert "\\) -delete" in common_vcs


def test_common_vcs_waits_briefly_for_vcs_license_before_compile_failure():
    stage30 = read(
        "verification/stage2/"
        "30_vcs_control_chip_stage2_single_chiplet_real_ssd_sync_tree_step_payload_bringup/"
        "scripts/common_vcs.sh"
    )
    stage41 = read(
        "verification/stage2/"
        "41_vcs_control_chip_stage2_single_chiplet_tree_mask_e2e_strict_bringup/"
        "scripts/common_vcs.sh"
    )
    for text in (stage30, stage41):
        assert 'VCS_LICENSE_WAIT_MINUTES="${VCS_LICENSE_WAIT_MINUTES:-1}"' in text
        assert '-licwait "${VCS_LICENSE_WAIT_MINUTES}" \\' in text


def test_tree_attention_delays_draft_mha_result_accept_until_vector_resp_lane_quiets():
    tree_attn = read("code/rtl/transformer/fp16_mha_tree_attention.sv")
    assert "logic [`MEM_REQ_LANES-1:0] draft_mha_result_arm_r;" in tree_attn
    assert "logic [`MEM_REQ_LANES-1:0] draft_mha_resp_quiet_r;" in tree_attn
    assert "assign draft_mha_result_ready_w =" in tree_attn
    assert (
        "draft_mha_result_arm_r & draft_mha_resp_quiet_r &\n"
        "    ~vec_sram_resp_valid & draft_mha_active_w;"
    ) in tree_attn
    assert "assign draft_mha_result_ready_w = {`MEM_REQ_LANES{1'b1}};" not in tree_attn
    assert (
        "if (draft_mha_result_valid_w[lane_i] &&\n"
        "                        !draft_mha_done_r[lane_i]) begin\n"
        "                        draft_mha_result_arm_r[lane_i] <= 1'b1;\n"
        "                    end"
    ) in tree_attn
    assert (
        "draft_mha_resp_quiet_r <=\n"
        "                    ~vec_sram_resp_valid & draft_mha_active_w;"
    ) in tree_attn


def test_tiled_matvec_keeps_resp_ready_high_while_result_is_held():
    matvec = read("code/rtl/transformer/fp16_tiled_matvec.sv")
    assert "(state_r == ST_HOLD)" in matvec


def test_tiled_matvec_drains_registered_read_responses_between_beats_and_phases():
    matvec = read("code/rtl/transformer/fp16_tiled_matvec.sv")
    assert "ST_LOAD_V_DRAIN" in matvec
    assert "ST_LOAD_W_DRAIN" in matvec
    assert "(state_r == ST_LOAD_V_DRAIN)" in matvec
    assert "(state_r == ST_LOAD_W_DRAIN)" in matvec
    assert "state_r <= ST_LOAD_V_DRAIN;" in matvec
    assert "state_r <= ST_LOAD_W_DRAIN;" in matvec
    assert "ST_LOAD_V_DRAIN: begin" in matvec
    assert "ST_LOAD_W_DRAIN: begin" in matvec
    assert "if (!(sram_resp_valid && sram_resp_ready)) begin" in matvec


def test_mha_waits_for_quiet_matvec_resp_channel_before_phase_advance():
    mha = read("code/rtl/transformer/fp16_mha_controller.sv")
    assert "wire matvec_resp_quiet_w =" in mha
    assert "!(sram_resp_valid && (sram_resp_id == req_id_r))" in mha
    assert "if (matvec_result_valid_w && matvec_result_ready_w)" in mha
    assert "matvec_result_valid_w &&\n    matvec_resp_quiet_w" in mha


def test_ffn_waits_for_quiet_matvec_resp_channel_before_phase_advance():
    ffn = read("code/rtl/transformer/fp16_ffn_swiglu.sv")
    assert "wire matvec_resp_quiet_w =" in ffn
    assert "!(sram_resp_valid && (sram_resp_id == req_id_r))" in ffn
    assert "matvec_resp_quiet_w;" in ffn


def test_ffn_activation_reads_decouple_read_accept_from_response_and_drain_between_phases():
    ffn = read("code/rtl/transformer/fp16_ffn_swiglu.sv")
    assert "logic gate_req_accepted_r;" in ffn
    assert "logic up_req_accepted_r;" in ffn
    assert "ST_ACT_GATE_DRAIN" in ffn
    assert "ST_ACT_UP_DRAIN" in ffn
    assert (
        "sram_resp_ready =\n"
        "                (sram_resp_id == req_id_r) &&\n"
        "                (gate_req_accepted_r || (sram_rd_valid && sram_rd_ready));"
    ) in ffn
    assert (
        "sram_resp_ready =\n"
        "                (sram_resp_id == req_id_r) &&\n"
        "                (up_req_accepted_r || (sram_rd_valid && sram_rd_ready));"
    ) in ffn
    assert "state_r <= ST_ACT_GATE_DRAIN;" in ffn
    assert "state_r <= ST_ACT_UP_DRAIN;" in ffn


def test_req_states_can_consume_same_cycle_responses_on_main_verify_path():
    mha = read("code/rtl/transformer/fp16_mha_controller.sv")
    ffn = read("code/rtl/transformer/fp16_ffn_swiglu.sv")
    emb = read("code/rtl/transformer/fp16_embedding.sv")
    lm = read("code/rtl/transformer/fp16_lm_head.sv")
    assert "ST_LOAD_Q_REQ: begin\n                if (sram_resp_valid && sram_resp_ready) begin" in mha
    assert "ST_DOT_REQ: begin" in mha and "else if (sram_rd_valid && sram_rd_ready) begin" in mha
    assert (
        "ST_ACT_GATE_REQ: begin\n"
        "                if ((gate_req_accepted_r || (sram_rd_valid && sram_rd_ready)) &&\n"
        "                    sram_resp_valid && sram_resp_ready) begin"
    ) in ffn
    assert "ST_REQ: begin\n                if (sram_resp_valid && sram_resp_ready) begin" in emb
    assert (
        "ST_LOAD_H_REQ: begin\n"
        "                if ((load_h_req_accepted_r || (sram_rd_valid && sram_rd_ready)) &&\n"
        "                    sram_resp_valid && sram_resp_ready) begin"
    ) in lm


def test_lm_head_decouples_read_accept_from_response_on_batch_vector_path():
    lm = read("code/rtl/transformer/fp16_lm_head.sv")
    assert "logic load_h_req_accepted_r;" in lm
    assert "logic load_w_req_accepted_r;" in lm
    assert (
        "assign sram_resp_ready =\n"
        "    ((((state_r == ST_LOAD_H_REQ) &&\n"
        "       (load_h_req_accepted_r || (sram_rd_valid && sram_rd_ready))) ||\n"
        "      (state_r == ST_LOAD_H_RESP) ||\n"
        "      (state_r == ST_LOAD_H_DRAIN) ||\n"
        "      ((state_r == ST_LOAD_W_REQ) &&\n"
        "       (load_w_req_accepted_r || (sram_rd_valid && sram_rd_ready))) ||\n"
        "      (state_r == ST_LOAD_W_RESP) ||\n"
        "      (state_r == ST_LOAD_W_DRAIN)) &&\n"
        "     (sram_resp_id == req_id_r));"
    ) in lm
    assert "sram_rd_valid = !load_h_req_accepted_r;" in lm
    assert "sram_rd_valid = !load_w_req_accepted_r;" in lm
    assert (
        "ST_LOAD_H_REQ: begin\n"
        "                if ((load_h_req_accepted_r || (sram_rd_valid && sram_rd_ready)) &&\n"
        "                    sram_resp_valid && sram_resp_ready) begin"
    ) in lm
    assert (
        "ST_LOAD_W_REQ: begin\n"
        "                if ((load_w_req_accepted_r || (sram_rd_valid && sram_rd_ready)) &&\n"
        "                    sram_resp_valid && sram_resp_ready) begin"
    ) in lm


def test_lm_head_inserts_drain_cycles_between_registered_read_responses_and_next_beats():
    lm = read("code/rtl/transformer/fp16_lm_head.sv")
    assert "ST_LOAD_H_DRAIN" in lm
    assert "ST_LOAD_W_DRAIN" in lm
    assert "(state_r == ST_LOAD_H_DRAIN)" in lm
    assert "(state_r == ST_LOAD_W_DRAIN)" in lm
    assert "state_r <= ST_LOAD_H_DRAIN;" in lm
    assert "state_r <= ST_LOAD_W_DRAIN;" in lm
    assert "if (!(sram_resp_valid && sram_resp_ready)) begin" in lm


def test_rmsnorm_decouples_read_accept_from_response_and_drains_between_phases():
    rms = read("code/rtl/transformer/fp16_rmsnorm.sv")
    assert "logic x_req_accepted_r;" in rms
    assert "logic g_req_accepted_r;" in rms
    assert "ST_X_DRAIN" in rms
    assert "ST_G_DRAIN" in rms
    assert (
        "assign sram_resp_ready =\n"
        "    ((((state_r == ST_X_REQ) &&\n"
        "       (x_req_accepted_r || (sram_rd_valid && sram_rd_ready))) ||\n"
        "      (state_r == ST_X_RESP) ||\n"
        "      (state_r == ST_X_DRAIN) ||\n"
        "      ((state_r == ST_G_REQ) &&\n"
        "       (g_req_accepted_r || (sram_rd_valid && sram_rd_ready))) ||\n"
        "      (state_r == ST_G_RESP) ||\n"
        "      (state_r == ST_G_DRAIN)) &&\n"
        "    (sram_resp_id == req_id_r));"
    ) in rms
    assert "state_r <= ST_X_DRAIN;" in rms
    assert "state_r <= ST_G_DRAIN;" in rms


def test_inference_top_assigns_distinct_serial_sram_req_ids_per_stage():
    top = read("code/rtl/transformer/fp16_inference_top.sv")
    assert "localparam [REQ_ID_W-1:0] EMBEDDING_REQ_ID" in top
    assert "localparam [REQ_ID_W-1:0] LAYER_SCHED_REQ_ID" in top
    assert "localparam [REQ_ID_W-1:0] FINAL_NORM_REQ_ID" in top
    assert "localparam [REQ_ID_W-1:0] LM_HEAD_REQ_ID" in top
    assert ".issue_req_id(EMBEDDING_REQ_ID)" in top
    assert ".issue_req_id(LAYER_SCHED_REQ_ID)" in top
    assert ".issue_req_id(FINAL_NORM_REQ_ID)" in top
    assert ".issue_req_id(LM_HEAD_REQ_ID)" in top
    assert ".issue_req_id({REQ_ID_W{1'b0}})" not in top


def test_fp16_scalar_internal_req_ids_stay_above_tree_parallel_draft_slot_band():
    top = read("code/rtl/transformer/fp16_inference_top.sv")
    layer = read("code/rtl/transformer/fp16_transformer_layer.sv")
    assert "localparam [REQ_ID_W-1:0] EMBEDDING_REQ_ID = 5'h11;" in top
    assert "localparam [REQ_ID_W-1:0] LAYER_SCHED_REQ_ID = 5'h12;" in top
    assert "localparam [REQ_ID_W-1:0] FINAL_NORM_REQ_ID = 5'h19;" in top
    assert "localparam [REQ_ID_W-1:0] LM_HEAD_REQ_ID = 5'h1a;" in top
    assert "localparam [REQ_ID_W-1:0] PRE_NORM_REQ_ID = 5'h13;" in layer
    assert "localparam [REQ_ID_W-1:0] MHA_REQ_ID = 5'h14;" in layer
    assert "localparam [REQ_ID_W-1:0] RES1_REQ_ID = 5'h15;" in layer
    assert "localparam [REQ_ID_W-1:0] POST_NORM_REQ_ID = 5'h16;" in layer
    assert "localparam [REQ_ID_W-1:0] FFN_REQ_ID = 5'h17;" in layer
    assert "localparam [REQ_ID_W-1:0] RES2_REQ_ID = 5'h18;" in layer
    assert "localparam [REQ_ID_W-1:0] EMBEDDING_REQ_ID = 5'h10;" not in top
    assert "localparam [REQ_ID_W-1:0] PRE_NORM_REQ_ID = 5'h12;" not in layer


def test_layer_wrappers_preserve_child_sram_req_ids_instead_of_flattening_them():
    sched = read("code/rtl/transformer/fp16_layer_scheduler.sv")
    layer = read("code/rtl/transformer/fp16_transformer_layer.sv")
    assert "sram_rd_id = layer_rd_id_w;" in sched
    assert "assign sram_rd_id = req_id_r;" not in sched
    assert "localparam [REQ_ID_W-1:0] PRE_NORM_REQ_ID" in layer
    assert "localparam [REQ_ID_W-1:0] MHA_REQ_ID" in layer
    assert "localparam [REQ_ID_W-1:0] RES1_REQ_ID" in layer
    assert "localparam [REQ_ID_W-1:0] POST_NORM_REQ_ID" in layer
    assert "localparam [REQ_ID_W-1:0] FFN_REQ_ID" in layer
    assert "localparam [REQ_ID_W-1:0] RES2_REQ_ID" in layer
    assert ".issue_req_id(PRE_NORM_REQ_ID)" in layer
    assert ".issue_req_id(MHA_REQ_ID)" in layer
    assert ".issue_req_id(RES1_REQ_ID)" in layer
    assert ".issue_req_id(POST_NORM_REQ_ID)" in layer
    assert ".issue_req_id(FFN_REQ_ID)" in layer
    assert ".issue_req_id(RES2_REQ_ID)" in layer
    assert "sram_rd_id = pre_rd_id_w;" in layer
    assert "sram_rd_id = mha_rd_id_w;" in layer
    assert "sram_rd_id = res1_rd_id_w;" in layer
    assert "sram_rd_id = post_rd_id_w;" in layer
    assert "sram_rd_id = ffn_rd_id_w;" in layer
    assert "sram_rd_id = res2_rd_id_w;" in layer
    assert "assign sram_rd_id = req_id_r;" not in layer


def test_tree_parallel_lane0_vector_response_classification_is_bounded_to_slot_req_ids():
    text = read("code/rtl/tree_control/control_chip_stage2_single_chiplet.v")
    assert (
        "tree_parallel_vec_resp_req_id_w[\n"
        "                tree_parallel_vec_resp_lane_g*`REQ_ID_W +: `REQ_ID_W] !=\n"
        "              {`REQ_ID_W{1'b0}}"
    ) in text
    assert (
        "tree_parallel_vec_resp_req_id_w[\n"
        "                tree_parallel_vec_resp_lane_g*`REQ_ID_W +: `REQ_ID_W] <=\n"
        "             `MEM_REQ_LANES"
    ) in text
    assert (
        "((tree_parallel_vec_resp_req_id_w[\n"
        "                tree_parallel_vec_resp_lane_g*`REQ_ID_W +: `REQ_ID_W] !=\n"
        "              {`REQ_ID_W{1'b0}}) ||"
    ) not in text


def test_residual_add_waits_for_registered_read_response_before_advancing_to_next_read():
    res = read("code/rtl/transformer/fp16_residual_add.sv")
    assert "logic x_req_accepted_r;" in res
    assert "logic r_req_accepted_r;" in res
    assert "if (x_req_accepted_r && sram_resp_valid && sram_resp_ready) begin" in res
    assert "if (r_req_accepted_r && sram_resp_valid && sram_resp_ready) begin" in res
    assert "ST_X_REQ: begin\n                if (sram_resp_valid && sram_resp_ready) begin" not in res
    assert "ST_R_REQ: begin\n                if (sram_resp_valid && sram_resp_ready) begin" not in res


def test_residual_add_only_acks_responses_after_the_matching_read_has_been_accepted():
    res = read("code/rtl/transformer/fp16_residual_add.sv")
    assert (
        "assign sram_resp_ready =\n"
        "    (((state_r == ST_X_REQ) && x_req_accepted_r) ||\n"
        "     (state_r == ST_X_RESP) ||\n"
        "     (state_r == ST_X_DRAIN) ||\n"
        "     ((state_r == ST_R_REQ) && r_req_accepted_r) ||\n"
        "     (state_r == ST_R_RESP) ||\n"
        "     (state_r == ST_R_DRAIN)) &&\n"
        "    (sram_resp_id == req_id_r);"
    ) in res
    assert (
        "((state_r == ST_X_REQ) || (state_r == ST_X_RESP) ||\n"
        "     (state_r == ST_R_REQ) || (state_r == ST_R_RESP)) &&\n"
        "    (sram_resp_id == req_id_r);"
    ) not in res


def test_residual_add_inserts_a_drain_cycle_between_read_response_and_next_phase():
    res = read("code/rtl/transformer/fp16_residual_add.sv")
    assert "ST_X_DRAIN" in res
    assert "ST_R_DRAIN" in res
    assert "state_r <= ST_X_DRAIN;" in res
    assert "ST_X_DRAIN: begin" in res
    assert "state_r <= ST_R_REQ;" in res
    assert "state_r <= ST_R_DRAIN;" in res
    assert "ST_R_DRAIN: begin" in res
    assert "state_r <= ST_WRITE;" in res


def test_mha_keeps_resp_ready_high_across_rope_and_kv_write_transitions():
    mha = read("code/rtl/transformer/fp16_mha_controller.sv")
    assert "ST_ROPE_Q_START," in mha
    assert "ST_ROPE_Q_WAIT," in mha
    assert "ST_ROPE_K_START," in mha
    assert "ST_ROPE_K_WAIT: begin" in mha or "ST_ROPE_K_WAIT,\n" in mha
    assert "ST_CACHE_K_WRITE: begin\n            sram_resp_ready = (sram_resp_id == req_id_r);" in mha
    assert "ST_CACHE_V_WRITE: begin\n            sram_resp_ready = (sram_resp_id == req_id_r);" in mha


def test_batch_seed_mha_does_not_wait_on_draft_barrier_release():
    tree_attn = read("code/rtl/transformer/fp16_mha_tree_attention.sv")
    assert ".issue_tree_kv_barrier_release(1'b1)" in tree_attn
    assert ".issue_tree_kv_barrier_release(draft_mha_barrier_release_w)" in tree_attn


def test_single_token_scheduler_ties_off_transformer_layer_tree_batch_ports():
    scheduler = read("code/rtl/transformer/fp16_layer_scheduler.sv")
    assert ".issue_tree_batch_en(1'b0)" in scheduler
    assert ".issue_tree_draft_kv_base({ADDR_W{1'b0}})" in scheduler
    assert ".issue_tree_query_slot({`SLOT_ID_W{1'b0}})" in scheduler
    assert ".issue_tree_slot_count(5'd0)" in scheduler
    assert ".issue_tree_visible_slots({`VERIFY_WINDOW_SIZE{1'b0}})" in scheduler
    assert ".issue_tree_slot_is_seed({`VERIFY_WINDOW_SIZE{1'b0}})" in scheduler
    assert ".issue_tree_seed_kv_valid(1'b0)" in scheduler


def test_tree_parallel_post_mha_path_is_not_slot_replay_state_machine():
    tree_attn = read("code/rtl/transformer/fp16_mha_tree_attention.sv")
    assert "ST_RES1_NEXT" not in tree_attn
    assert "ST_POST_NEXT" not in tree_attn
    assert "ST_FFN_NEXT" not in tree_attn
    assert "ST_RES2_NEXT" not in tree_attn
    assert "slot_idx_r <= slot_idx_r + 5'd1;" not in tree_attn


def test_batch_final_norm_and_lm_are_not_output_slot_replay_loops():
    inference = read("code/rtl/transformer/fp16_inference_top.sv")
    assert "batch_output_slot_idx_r" not in inference
    assert "ST_BATCH_FINAL_NORM_ISSUE" not in inference
    assert "ST_BATCH_FINAL_NORM_WAIT" not in inference
    assert "ST_BATCH_LM_ISSUE" not in inference
    assert "ST_BATCH_LM_WAIT" not in inference


def test_batch_tree_scratch_region_is_not_anchored_inside_weight_preload_space():
    inference = read("code/rtl/transformer/fp16_inference_top.sv")
    assert "TREE_BATCH_SCRATCH_BASE_P" in inference
    assert "`KV_DRAFT_BASE_MIN" in inference
    assert "TREE_BATCH_LAYER_SCRATCH_STRIDE_P" in inference
    assert (
        "batch_layer_weight_base_w +\n"
        "    addr_from_u32(\n"
        "        TOTAL_LAYER_PRELOAD_BEATS_P +"
    ) not in inference


def test_tree_batch_slot_scratch_stride_covers_ffn_output_buffer_without_overlap():
    inference = read("code/rtl/transformer/fp16_inference_top.sv")
    tree_attn = read("code/rtl/transformer/fp16_mha_tree_attention.sv")
    assert "TREE_BATCH_SLOT_SCRATCH_STRIDE_P =" in inference
    assert "(HIDDEN_BEATS_P * 9) + (INTERMEDIATE_BEATS_P * 3)" in inference
    assert "parameter integer SLOT_SCRATCH_STRIDE    = (HIDDEN_BEATS * 9) + (INTERMEDIATE_BEATS * 3)" in tree_attn
    assert "(HIDDEN_BEATS_P * 8) + (INTERMEDIATE_BEATS_P * 3)" not in inference
    assert "parameter integer SLOT_SCRATCH_STRIDE    = (HIDDEN_BEATS * 8) + (INTERMEDIATE_BEATS * 3)" not in tree_attn


def test_generate_block_labels_do_not_reuse_genvar_identifiers():
    inference = read("code/rtl/transformer/fp16_inference_top.sv")
    tree_attn = read("code/rtl/transformer/fp16_mha_tree_attention.sv")
    assert re.search(r"begin\s*:\s*gen_mha_slot(\s|$)", tree_attn) is None
    assert re.search(r"begin\s*:\s*gen_post_slot(\s|$)", tree_attn) is None
    assert re.search(r"begin\s*:\s*gen_tail_slot(\s|$)", inference) is None


def test_batch_logits_draft_wait_does_not_contain_extra_end():
    inference = read("code/rtl/transformer/fp16_inference_top.sv")
    assert (
        "if (batch_lm_draft_all_done_w)\n"
        "                    state_r <= ST_BATCH_HOLD;\n"
        "                end\n"
        "            end"
    ) not in inference


def test_mc_pe_ready_mux_does_not_have_extra_closing_paren():
    text = read("code/rtl/tree_control/control_chip_stage2_single_chiplet.v")
    assert "op_resp_ready))))};" not in text


def test_sram_subbank_stores_whole_beats_at_full_row_offset_indices():
    subbank = read("code/rtl/tree_control/sram_subbank.v")
    assert "localparam integer SUBBANK_DEPTH = `SUBBANK_SIZE_BYTES;" in subbank
    assert "reg [`SRAM_RDATA_W-1:0] storage_beats [0:SUBBANK_DEPTH-1];" in subbank
    assert "req_base_addr_i = {req_row_addr, req_offset};" in subbank
    assert (
        "resp_base_addr_i =\n"
        "                {read_pending_row_addr_r, read_pending_offset_r};"
    ) in subbank
    assert "resp_rdata_r <= storage_beats[resp_base_addr_i];" in subbank
    assert "storage_beats[req_base_addr_i] <= req_wdata;" in subbank
    assert "req_base_addr_i = (req_row_addr << `OFFSET_W) + req_offset;" not in subbank
    assert "(read_pending_row_addr_r << `OFFSET_W) + read_pending_offset_r" not in subbank
    assert "storage_bytes[" not in subbank
    assert "for (byte_i = 0; byte_i < SRAM_BEAT_BYTES; byte_i = byte_i + 1)" not in subbank


def test_sram_subsystem_debug_shadow_tracks_full_beats_at_row_offset_indices():
    subsystem = read("code/rtl/tree_control/sram_subsystem.v")
    assert "reg [`SRAM_WDATA_W-1:0] storage_beats_debug [0:TOTAL_BANKS-1]" in subsystem
    assert "[0:`SUBBANK_NUM_PER_BANK-1][0:`SUBBANK_SIZE_BYTES-1];" in subsystem
    assert (
        "debug_base_addr_i =\n"
        "                    {debug_row_addr_value, debug_offset_value};"
    ) in subsystem
    assert "storage_beats_debug[" in subsystem
    assert "debug_base_addr_i] <=" in subsystem
    assert "mem_req_wdata[(lane_i*`SRAM_WDATA_W) +: `SRAM_WDATA_W];" in subsystem
    assert "(debug_row_addr_value << `OFFSET_W) + debug_offset_value" not in subsystem
    assert "storage_bytes_debug[" not in subsystem
    assert "debug_byte_i" not in subsystem


def test_sram_subsystem_does_not_fixed_priority_starve_high_lanes_on_conflicts():
    subsystem = read("code/rtl/tree_control/sram_subsystem.v")
    assert "reg [LANE_IDX_W-1:0] lane_issue_rr_start_r;" in subsystem
    assert "issue_scan_step_i" in subsystem
    assert "issue_lane_i = (lane_issue_rr_start_r + issue_scan_step_i);" in subsystem
    assert "lane_issue_rr_start_r <= lane_issue_rr_start_r + 1'b1;" in subsystem
    assert "for (lane_i = 0; lane_i < `MEM_REQ_LANES; lane_i = lane_i + 1) begin" in subsystem


def test_stage41_tb_reads_debug_shadow_by_beat_index_not_overlapping_byte_window():
    tb = read(
        "code/tb/tree_control_tb/"
        "tb_control_chip_stage2_single_chiplet_native_tree_main_frontend_platform_driver.v"
    )
    assert "base_addr_v = {row_addr_v, offset_v};" in tb
    assert ".storage_beats_debug[total_bank_idx_v][subbank_id_v]" in tb
    assert "[base_addr_v];" in tb
    assert "(row_addr_v << `OFFSET_W) + offset_v" not in tb
    assert "base_byte_addr_v" not in tb


def test_mc_pe_ready_mux_uses_flattened_helper_wires():
    text = read("code/rtl/tree_control/control_chip_stage2_single_chiplet.v")
    assert "wire native_tree_or_sidecar_pe_resp_ready_w;" in text
    assert "wire tree_parallel_scalar_tail_resp_ready_w;" in text
    assert "assign native_tree_or_sidecar_pe_resp_ready_w =" in text
    assert "assign tree_parallel_scalar_tail_resp_ready_w =" in text
    assert "tree_parallel_scalar_tail_resp_ready_w" in text


def test_token_register_promotes_tree_entry_to_stream_entry():
    text = read("code/rtl/tree_control/token_register.v")
    assert "entry_type[wr_index] <= `TOKEN_ENTRY_TREE;" in text
    assert "entry_type[commit_index] <= `TOKEN_ENTRY_STREAM;" in text
    assert "(entry_type[idx_i] == `TOKEN_ENTRY_TREE)" in text


def test_control_chip_replays_tree_parallel_commits_into_token_register():
    text = read("code/rtl/tree_control/control_chip_stage2_single_chiplet.v")
    assert "tree_parallel_commit_replay_active_r" in text
    assert "tree_parallel_commit_issue_valid_comb" in text
    assert "assign token_commit_valid =" in text
    assert "assign token_commit_index =" in text
    assert "assign token_commit_branch_mask =" in text
    assert "assign token_commit_node_mask =" in text
    assert ".commit_valid(token_commit_valid)" in text
    assert ".commit_index(token_commit_index)" in text


def test_tree_parallel_ownership_and_commit_replay_use_level_local_node_indices():
    text = read("code/rtl/tree_control/control_chip_stage2_single_chiplet.v")
    assert re.search(
        r"\.tree_in_node_id\(\s*tree_parallel_mode_w\s*\?\s*"
        r"\{\{\(`NODE_ID_W-`TREE_LEVEL_ID_W\)\{1'b0\}\},\s*"
        r"native_tree_main_pred_level_id_w\}",
        text,
    ), "tree-parallel AGU ownership path must key branch-local nodes by level index"
    assert (
        "tree_parallel_accepted_prefix_node_id_comb[\n"
        "                    (tree_parallel_reduce_level_i*`NODE_ID_W) +: `NODE_ID_W] =\n"
        "                    tree_parallel_reduce_level_i[`NODE_ID_W-1:0];"
    ) in text


def test_tree_parallel_agu_frontier_ownership_uses_level_local_node_indices():
    text = read("code/rtl/tree_control/control_chip_stage2_single_chiplet.v")
    assert "wire [`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0] agu_frontier_node_id_w;" in text
    assert "reg [`TREE_FRONTIER_SLOTS*`NODE_ID_W-1:0] agu_tree_parallel_frontier_node_id_comb;" in text
    assert re.search(
        r"assign\s+agu_frontier_node_id_w\s*=\s*tree_parallel_mode_w\s*\?\s*"
        r"agu_tree_parallel_frontier_node_id_comb\s*:\s*frontier_node_id\s*;",
        text,
    ), "tree-parallel AGU frontier ownership path must normalize node ids by level"
    assert ".frontier_node_id(agu_frontier_node_id_w)" in text


def test_tree_parallel_agu_ownership_is_driven_by_frontier_queue_not_placeholder_pred_fire():
    text = read("code/rtl/tree_control/control_chip_stage2_single_chiplet.v")
    assert re.search(
        r"\.tree_in_valid\(\s*tree_parallel_mode_w\s*\?\s*1'b0\s*:\s*pred_accept_fire_w\s*\)",
        text,
    ), (
        "tree-parallel AGU ownership must come from tree_analyze/frontier queue, "
        "not NativeTreeMainFrontend placeholder pred fire pulses"
    )
    assert (
        "native_tree_main_pred_valid_w && native_tree_main_pred_ready_w &&\n"
        "             native_tree_main_pred_tree_mask_en_w"
    ) not in text


def test_agu_aborts_nonlive_pending_branch_even_after_flush_pulse_has_passed():
    text = read("code/rtl/tree_control/agu.v")
    assert "reg pending_live_comb;" in text
    assert re.search(
        r"pending_live_comb\s*=\s*branch_live_for_req\(",
        text,
    ), "AGU must evaluate persistent branch liveness for the current pending node"
    assert re.search(
        r"if\s*\(\s*!\s*pending_live_comb\s*&&\s*\(agu_state_r\s*!=\s*AGU_STATE_IDLE\)\s*\)",
        text,
    ), (
        "AGU must drop a pending non-shared node when compare/flush has already "
        "pruned its branch, even if the one-cycle flush pulse is gone"
    )


def test_tree_parallel_request_accept_preloads_lifecycle_branch_metadata():
    text = read("code/rtl/tree_control/control_chip_stage2_single_chiplet.v")
    assert "if (tree_parallel_req_mode_w) begin" in text
    assert "lifecycle_slot_meta_valid_r[tree_parallel_branch_idx_i] <= 1'b1;" in text
    assert "lifecycle_candidate_depth_by_branch_r[" in text
    assert (
        "lifecycle_candidate_node_path_by_branch_r[\n"
        "                            (((tree_parallel_branch_idx_i*\n"
        "                               `MAX_VERIFY_NODES_PER_BRANCH) +\n"
        "                              tree_parallel_level_idx_i)*`NODE_ID_W) +:\n"
        "                             `NODE_ID_W] <=\n"
        "                            tree_parallel_level_idx_i[`NODE_ID_W-1:0];"
    ) in text


def test_tree_parallel_commit_meta_capture_stays_open_until_replay_drains():
    text = read("code/rtl/tree_control/control_chip_stage2_single_chiplet.v")
    assert re.search(
        r"if\s*\(\s*\(\s*lifecycle_window_active_r\s*\|\|\s*"
        r"tree_parallel_session_active_r\s*\|\|\s*"
        r"tree_parallel_commit_pending_r\s*\|\|\s*"
        r"tree_parallel_commit_replay_active_r\s*\)\s*&&\s*"
        r"!token_wr_is_shared",
        text,
    ), "tree-parallel commit metadata capture must remain live after the compare pulse"


def test_tree_parallel_flush_is_gated_by_commit_pulse():
    text = read("code/rtl/tree_control/control_chip_stage2_single_chiplet.v")
    assert re.search(
        r"if\s*\(\s*tree_parallel_commit_valid_w\s*&&\s*"
        r"tree_parallel_commit_flush_mask_w\[tree_parallel_reduce_branch_i\]\s*\)",
        text,
    ), "tree-parallel flush must only fire on the commit pulse"


def test_control_chip_exposes_token_register_entry_type_lifecycle():
    text = read("code/rtl/tree_control/control_chip_stage2_single_chiplet.v")
    assert "wire [`TOKEN_ENTRY_TYPE_W-1:0] kv_lookup_entry_type_w;" in text
    assert ".lookup_resp_entry_type(kv_lookup_entry_type_w)" in text


def test_tree_parallel_seed_uses_frontier_referenced_metadata():
    text = read("code/rtl/tree_control/control_chip_stage2_single_chiplet.v")
    assert re.search(
        r"tree_parallel_seed_token_id_w\s*=\s*[\s\S]{0,220}?"
        r"native_tree_src_frontier_referenced_token_id",
        text,
    )
    assert re.search(
        r"tree_parallel_seed_position_w\s*=\s*[\s\S]{0,220}?"
        r"native_tree_src_frontier_referenced_position_id",
        text,
    )


def test_stage2_token_register_lookup_uses_real_kv_lookup_inputs():
    text = read("code/rtl/tree_control/control_chip_stage2_single_chiplet.v")
    assert ".lookup_valid(kv_lookup_valid)" in text
    assert ".lookup_token_id(kv_lookup_token_id)" in text
    assert ".lookup_position_id(kv_lookup_position_id)" in text
    assert ".lookup_token_id({`TOKEN_ID_W{1'b0}})" not in text
    assert ".lookup_position_id({`POSITION_ID_W{1'b0}})" not in text


def test_tree_flatten_shared_slot_match_requires_token_and_parent_topology():
    text = read("code/rtl/tree_control/tree_flatten.v")
    assert "alloc_parent[s] == cur_parent_slot" in text
    assert "alloc_token_id[s] == cur_token_id" in text
    assert "alloc_position[s] == cur_position" in text
    assert "alloc_node_id[s] == cur_node_id" not in text


def test_tree_parallel_comb_blocks_do_not_use_always_star_with_module_temps():
    flatten = read("code/rtl/tree_control/tree_flatten.v")
    dispatcher = read("code/rtl/transformer/tree_verify_dispatcher.sv")
    assert "always @(*) begin : flatten_logic" not in flatten
    assert "always @(*) begin : mask_gen_logic" not in dispatcher
    assert "always @(*) begin : comparator_logic" not in dispatcher
    assert "always @(*) begin : commit_derive_logic" not in dispatcher


def test_control_chip_top_level_exposes_token_register_entry_type_lifecycle():
    text = read("code/rtl/tree_control/control_chip.v")
    assert "wire [`TOKEN_ENTRY_TYPE_W-1:0] lookup_resp_entry_type;" in text
    assert ".lookup_resp_entry_type(lookup_resp_entry_type)" in text


def test_tree_parallel_writeback_flows_through_standard_writeback_part():
    text = read("code/rtl/tree_control/control_chip_stage2_single_chiplet.v")
    assert "wire tree_parallel_wb_result_valid_w;" in text
    assert "wire tree_parallel_wb_result_ready_w;" in text
    assert "wire tree_parallel_wb_pending_r;" in text
    assert "assign tree_parallel_wb_result_ready_w = writeback_result_ready_w;" in text
    assert "assign operator_result_valid_w =" in text
    assert "tree_parallel_wb_result_valid_w" in text
    assert "assign operator_result_token_id_w =" in text
    assert "assign operator_result_addr_w =" in text
    assert "assign operator_result_data_w =" in text
    assert "assign operator_result_status_w =" in text
    assert "tree_parallel_commit_bonus_token_id_w" in text


def test_tree_parallel_batch_hbm_reads_are_exported_to_top_level():
    text = read("code/rtl/tree_control/control_chip_stage2_single_chiplet.v")
    assert "wire tree_parallel_hbm_rd_valid_w;" in text
    assert re.search(
        r"assign\s+hbm_req_valid_w\s*=\s*[\s\S]*?tree_parallel_hbm_rd_valid_w",
        text,
    ), "top-level HBM valid mux must include tree-parallel batch reads"
    assert re.search(
        r"assign\s+hbm_req_addr_w\s*=\s*[\s\S]*?tree_parallel_hbm_rd_addr_w",
        text,
    ), "top-level HBM addr mux must include tree-parallel batch read address"


def test_tree_parallel_batch_hbm_handshake_is_closed_at_stage2_top():
    text = read("code/rtl/tree_control/control_chip_stage2_single_chiplet.v")
    assert "wire tree_parallel_hbm_rd_ready_w;" in text
    assert "wire tree_parallel_hbm_resp_ready_w;" in text
    assert re.search(
        r"assign\s+tree_parallel_hbm_rd_ready_w\s*=\s*1'b1\s*;",
        text,
    ), "tree-parallel batch HBM request path must not leave rd_ready floating"
    assert re.search(
        r"assign\s+tree_parallel_hbm_resp_ready_w\s*=\s*1'b1\s*;",
        text,
    ), "tree-parallel batch HBM response path must not leave resp_ready floating"


def test_tree_parallel_kv_commit_copier_decouples_read_accept_from_response():
    text = read("code/rtl/tree_control/kv_commit_copier.v")
    assert "logic                    rd_req_accepted_r;" in text
    assert "if (sram_rd_ready)\n                        rd_req_accepted_r <= 1'b1;" in text
    assert "if (sram_resp_valid && (rd_req_accepted_r || sram_rd_ready)) begin" in text
    assert "assign sram_rd_valid  = (state == ST_READ_BEAT) && !rd_req_accepted_r;" in text
    assert "if (sram_rd_ready && sram_resp_valid)" not in text


def test_fp16_tiled_matvec_decouples_read_accept_from_response():
    text = read("code/rtl/transformer/fp16_tiled_matvec.sv")
    assert "logic load_v_req_accepted_r;" in text
    assert "logic load_w_req_accepted_r;" in text
    assert "assign sram_resp_ready =" in text
    assert "load_v_req_accepted_r || (sram_rd_valid && sram_rd_ready)" in text
    assert "load_w_req_accepted_r || (sram_rd_valid && sram_rd_ready)" in text
    assert "(state_r == ST_WRITE)" in text
    assert "sram_resp_valid && sram_resp_ready" in text
    assert "if (sram_resp_valid && (sram_resp_id == req_id_r)) begin" not in text
    assert "sram_rd_valid = !load_v_req_accepted_r;" in text
    assert "sram_rd_valid = !load_w_req_accepted_r;" in text


def test_fp16_mha_controller_load_req_states_accept_late_responses():
    text = read("code/rtl/transformer/fp16_mha_controller.sv")
    assert "ST_LOAD_Q_REQ:" in text
    assert "ST_LOAD_K_REQ:" in text
    assert "ST_LOAD_V_REQ:" in text
    assert "ST_DOT_REQ:" in text
    assert "ST_WV_REQ:" in text
    assert "sram_resp_ready = (sram_resp_id == req_id_r);" in text
    assert "if (sram_resp_valid && sram_resp_ready) begin" in text
    assert "else if (sram_rd_valid && sram_rd_ready) begin" in text


def test_fp16_mha_controller_decouples_read_accept_from_response_for_scalar_read_phases():
    text = read("code/rtl/transformer/fp16_mha_controller.sv")
    assert "logic rd_req_accepted_r;" in text
    assert "rd_req_accepted_r || (sram_rd_valid && sram_rd_ready)" in text
    assert "sram_rd_valid = !rd_req_accepted_r;" in text
    assert "ST_LOAD_Q_REQ" in text
    assert "ST_LOAD_K_REQ" in text
    assert "ST_LOAD_V_REQ" in text
    assert "ST_DOT_REQ" in text
    assert "ST_WV_REQ" in text


def test_fp16_mha_controller_inserts_drain_cycles_between_registered_read_responses():
    text = read("code/rtl/transformer/fp16_mha_controller.sv")
    assert "ST_LOAD_Q_DRAIN" in text
    assert "ST_LOAD_K_DRAIN" in text
    assert "ST_LOAD_V_DRAIN" in text
    assert "ST_DOT_DRAIN" in text
    assert "ST_WV_DRAIN" in text
    assert "state_r <= ST_LOAD_Q_DRAIN;" in text
    assert "state_r <= ST_LOAD_K_DRAIN;" in text
    assert "state_r <= ST_LOAD_V_DRAIN;" in text
    assert "state_r <= ST_DOT_DRAIN;" in text
    assert "state_r <= ST_WV_DRAIN;" in text
    assert "if (!(sram_resp_valid && sram_resp_ready)) begin" in text


def test_fp16_mha_controller_softmax_accumulates_on_serial_path_not_only_tree_batch():
    text = read("code/rtl/transformer/fp16_mha_controller.sv")
    assert "ST_SOFT_EXP_WAIT: begin" in text
    assert "if (exp_ack_w) begin" in text
    assert "!tree_batch_en_r || !tree_softmax_skip_w" in text, (
        "serial MHA must still write exp weights and accumulate exp_sum when "
        "tree_batch_en_r is 0"
    )
    assert "if (tree_batch_en_r && !tree_softmax_skip_w) begin" not in text


def test_platform_driver_strict_capture_understands_tree_parallel_batch_path():
    text = read(
        "code/tb/tree_control_tb/"
        "tb_control_chip_stage2_single_chiplet_native_tree_main_frontend_platform_driver.v"
    )
    assert "tree_parallel_strict_capture_valid_r" in text
    assert "u_tree_parallel_batch_inference_top" in text
    assert "tree_parallel_fwd_result_valid_w" in text
    assert "rtl_step2_branch%0d_level%0d_final_hidden.memh" in text
    assert "rtl_step2_branch%0d_level%0d_token.txt" in text


def test_platform_driver_logs_tree_parallel_batch_progress_not_only_serial_pred_fire():
    text = read(
        "code/tb/tree_control_tb/"
        "tb_control_chip_stage2_single_chiplet_native_tree_main_frontend_platform_driver.v"
    )
    assert ".tree_parallel_batch_valid_w &&" in text
    assert "tree_parallel_batch_ready_w" in text
    assert "verify_group_issue" in text
    assert ".tree_parallel_fwd_result_valid_w &&" in text
    assert "verify_group_done" in text


def test_platform_driver_overrides_issue_src_addr_to_toy_embedding_base():
    tb = read(
        "code/tb/tree_control_tb/"
        "tb_control_chip_stage2_single_chiplet_native_tree_main_frontend_platform_driver.v"
    )
    manifest = json.loads(
        read("code/script/toy_model/generated/manifest.json")
    )
    emb_base = manifest["layout"]["emb_base"]
    assert (
        f"localparam [`SRAM_ADDR_W-1:0] TOY_MODEL_EMB_BASE = 23'd{emb_base};"
        in tb
    )
    assert ".ISSUE_SRC_ADDR(TOY_MODEL_EMB_BASE)" in tb


def test_platform_driver_timeout_dumps_tree_parallel_batch_states():
    text = read(
        "code/tb/tree_control_tb/"
        "tb_control_chip_stage2_single_chiplet_native_tree_main_frontend_platform_driver.v"
    )
    assert "task automatic dump_tree_parallel_batch_debug_state;" in text
    assert ".u_tree_parallel_batch_inference_top.state_r" in text
    assert ".u_fp16_mha_tree_attention.state_r" in text
    assert ".u_fp16_mha_seed_controller.state_r" in text
    assert re.search(
        r"\.gen_mha_slot_block\[0\][\s\S]*?\.u_fp16_mha_draft_controller\.state_r",
        text,
    )
    assert re.search(
        r"\.gen_mha_slot_block\[15\][\s\S]*?\.u_fp16_mha_draft_controller\.state_r",
        text,
    )
    assert ".u_request_controller.state_r" in text
    assert "agu_state=%0d treeq_count=%0d pending_req=%0d pending_branch=%0d pending_node=%0d pending_shared=%0d pending_live=%0d" in text
    assert "commit_replay_cursor=%0d commit_replay_depth=%0d commit_replay_branch=%0d commit_meta_ready=%0d commit_issue_valid=%0d commit_issue_index=%0d meta_valid_bitmap=0x%0h" in text


def test_platform_driver_lifecycle_commit_log_carries_accepted_prefix_depth():
    text = read(
        "code/tb/tree_control_tb/"
        "tb_control_chip_stage2_single_chiplet_native_tree_main_frontend_platform_driver.v"
    )
    assert "lifecycle_commit" in text
    assert "\\\"accepted_prefix_depth\\\":%0d" in text


def test_platform_driver_timeout_dump_reports_scalar_verify_path_states():
    text = read(
        "code/tb/tree_control_tb/"
        "tb_control_chip_stage2_single_chiplet_native_tree_main_frontend_platform_driver.v"
    )
    assert (
        "scalar_adapter_state=%0d scalar_map_state=%0d scalar_fp16_busy=%0d "
        "scalar_layer=%0d scalar_top_state=%0d scalar_sched_state=%0d "
        "scalar_layer_state=%0d"
    ) in text
    assert "scalar_issue_valid=%0d scalar_issue_ready=%0d op_req_valid=%0d op_req_ready=%0d" in text
    assert (
        "mem_req_valid=0x%0h mem_req_ready=0x%0h mem_resp_valid=0x%0h "
        "pe_resp_valid=0x%0h pe_resp_ready=0x%0h"
    ) in text
    assert ".u_fp16_inference_adapter.state_r" in text
    assert ".u_fp16_inference_adapter.map_state_r" in text
    assert ".u_fp16_inference_adapter.fp16_busy_w" in text
    assert ".u_fp16_inference_adapter.fp16_current_layer_debug_w" in text
    assert ".u_fp16_inference_top.state_r" in text
    assert ".u_fp16_layer_scheduler.state_r" in text
    assert ".u_fp16_transformer_layer.state_r" in text


def test_platform_driver_timeout_dump_uses_true_lane_request_state_not_stale_response_registers():
    tb = read(
        "code/tb/tree_control_tb/"
        "tb_control_chip_stage2_single_chiplet_native_tree_main_frontend_platform_driver.v"
    )
    dump_region = tb[
        tb.index("task automatic dump_tree_parallel_batch_debug_state;"):
        tb.index("task automatic force_mem_write_beat;")
    ]
    assert ".u_request_controller.lane_req_id_r[" in dump_region
    assert ".u_request_controller.lane_addr_r[" in dump_region
    assert ".u_request_controller.resp_req_id_r[" not in dump_region
    assert ".pe_resp_ready[lane_i]" in dump_region
    assert "tree_parallel_vec_resp_ready_w[lane_i]" not in dump_region


def test_platform_driver_auto_responds_to_tree_parallel_hbm_reads():
    text = read(
        "code/tb/tree_control_tb/"
        "tb_control_chip_stage2_single_chiplet_native_tree_main_frontend_platform_driver.v"
    )
    assert "reg hbm_auto_resp_pending_r;" in text
    assert "task automatic drive_auto_hbm_response;" in text
    assert re.search(r"if\s*\(\s*!hbm_resp_valid\s*&&\s*hbm_req_valid\s*&&\s*!hbm_req_write\s*\)", text)
    assert "toy_model_hbm_mem[hbm_req_addr]" in text
    assert re.search(r"else\s+if\s*\(\s*hbm_auto_resp_pending_r\s*\)", text)


def test_platform_driver_legacy_strict_capture_uses_mem_req_write_accept_path():
    text = read(
        "code/tb/tree_control_tb/"
        "tb_control_chip_stage2_single_chiplet_native_tree_main_frontend_platform_driver.v"
    )
    runtime_region = text[
        text.index("if (u_control_chip_stage2_single_chiplet.native_tree_main_pred_fire_w ||"):
        text.index("if (hbm_req_valid && hbm_req_write) begin")
    ]
    assert ".u_fp16_inference_top\n                .final_wr_valid_w" not in runtime_region
    assert ".u_fp16_inference_adapter\n                .fp16_sram_wr_valid_w" not in runtime_region
    assert "u_control_chip_stage2_single_chiplet.mem_req_valid[mem_shadow_lane_i]" in runtime_region
    assert "u_control_chip_stage2_single_chiplet.mem_req_ready[mem_shadow_lane_i]" in runtime_region
    assert "u_control_chip_stage2_single_chiplet.mem_req_write[mem_shadow_lane_i]" in runtime_region


def test_tree_parallel_vector_response_classification_does_not_depend_only_on_nonzero_req_id():
    text = read("code/rtl/tree_control/control_chip_stage2_single_chiplet.v")
    assert "tree_parallel_vec_resp_req_id_w[" in text
    assert "tree_parallel_vec_resp_pe_mask_w[" in text
    assert re.search(r"tree_parallel_vec_resp_req_id_w\[[\s\S]*?\{`REQ_ID_W\{1'b0\}\}", text)
    assert re.search(r"~\{\{\(`PE_MASK_W-1\)\{1'b0\}\}, 1'b1\}", text)
    assert re.search(r"\{`PE_MASK_W\{1'b0\}\}", text)


def test_common_vcs_refuses_to_reenter_same_simv_workdir_while_prior_run_is_alive():
    text = read(
        "verification/stage2/"
        "30_vcs_control_chip_stage2_single_chiplet_real_ssd_sync_tree_step_payload_bringup/"
        "scripts/common_vcs.sh"
    )
    assert 'existing_simv_pids="$(pgrep -f -- "${simv_path}" || true)"' in text
    assert 'reason" "simv_already_running"' in text
    assert 'existing_simv_pids=${existing_simv_pids//$\'\\n\'/,}' in text
    assert 'another simv is already running for ${simv_path}' in text


def test_common_vcs_records_failure_summary_into_result_logs():
    stage30 = read(
        "verification/stage2/"
        "30_vcs_control_chip_stage2_single_chiplet_real_ssd_sync_tree_step_payload_bringup/"
        "scripts/common_vcs.sh"
    )
    stage41 = read(
        "verification/stage2/"
        "41_vcs_control_chip_stage2_single_chiplet_tree_mask_e2e_strict_bringup/"
        "scripts/common_vcs.sh"
    )
    for text in (stage30, stage41):
        assert "append_run_failure_summary_from_log()" in text
        assert 'append_result_kv "${result_file}" "run_error_summary"' in text
        assert 'append_result_kv "${result_file}" "run_error_context"' in text
        assert 'append_result_kv "${result_file}" "fatal_summary"' in text
        assert 'append_result_kv "${result_file}" "fatal_context"' in text
        assert 'append_run_failure_summary_from_log "${result_file}" "${run_log}"' in text
        nonzero_region = text[
            text.index("if [[ ${run_rc} -ne 0 ]]; then"):
            text.index('if ! grep -q "${tb_name} PASS" "${run_log}"; then')
        ]
        assert 'append_run_failure_summary_from_log "${result_file}" "${run_log}"' in nonzero_region


def test_common_vcs_records_compile_failure_summary_into_result_logs():
    stage30 = read(
        "verification/stage2/"
        "30_vcs_control_chip_stage2_single_chiplet_real_ssd_sync_tree_step_payload_bringup/"
        "scripts/common_vcs.sh"
    )
    stage41 = read(
        "verification/stage2/"
        "41_vcs_control_chip_stage2_single_chiplet_tree_mask_e2e_strict_bringup/"
        "scripts/common_vcs.sh"
    )
    for text in (stage30, stage41):
        assert "append_compile_failure_summary_from_log()" in text
        assert 'append_result_kv "${result_file}" "compile_error_summary"' in text
        assert 'append_result_kv "${result_file}" "compile_error_context"' in text
        compile_failed_region = text[
            text.index("if [[ ${compile_rc} -ne 0 || ! -x \"${simv_path}\" ]]; then"):
            text.index('append_result_kv "${result_file}" "compile_status" "PASS"')
        ]
        assert 'append_compile_failure_summary_from_log "${result_file}" "${compile_log}"' in compile_failed_region


def main() -> int:
    current_module = sys.modules[__name__]
    test_items = sorted(
        (
            name,
            func,
        )
        for name, func in inspect.getmembers(current_module, inspect.isfunction)
        if name.startswith("test_")
    )
    for name, func in test_items:
        func()
        print(f"{name}: PASS")
    print(f"{len(test_items)} tests passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
