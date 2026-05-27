import sys
import unittest
from pathlib import Path
import re


SCRIPT_ROOT = Path(__file__).resolve().parents[2]
REPO_ROOT = SCRIPT_ROOT.parents[1]


class StaticRtlWeightIntegrationTest(unittest.TestCase):
    def test_tree_mask_phase0_parameters_expand_to_six_verify_nodes(self) -> None:
        prediction_text = (
            REPO_ROOT / "code" / "rtl" / "config" / "prediction_params.vh"
        ).read_text(encoding="utf-8")
        interface_text = (
            REPO_ROOT / "code" / "rtl" / "config" / "interface_params.vh"
        ).read_text(encoding="utf-8")
        model_text = (
            REPO_ROOT / "code" / "rtl" / "config" / "model_params.vh"
        ).read_text(encoding="utf-8")

        self.assertIn("`define MAX_PRIVATE_NODES_PER_BRANCH 4", prediction_text)
        self.assertIn("`define MAX_VERIFY_NODES_PER_BRANCH  6", prediction_text)
        self.assertIn("`define PREFETCH_Q_DEPTH         24", prediction_text)
        self.assertIn("`define TOKEN_REG_DEPTH          96", prediction_text)
        self.assertIn("`define REQ_CTRL_DEPTH           48", prediction_text)
        self.assertIn("`define FREE_LIST_DEPTH          64", prediction_text)
        self.assertIn("`define TREE_LEVEL_ID_W          3", interface_text)
        self.assertIn("`define TOY_MAX_POS_EMB          32", model_text)

    def test_tree_mask_phase1_prefix_len_is_dynamic_not_hardcoded(self) -> None:
        tree_analyze_text = (
            REPO_ROOT / "code" / "rtl" / "tree_control" / "tree_analyze.v"
        ).read_text(encoding="utf-8")
        native_tree_text = (
            REPO_ROOT / "code" / "rtl" / "tree_control" / "NativeTreeMainFrontend.v"
        ).read_text(encoding="utf-8")
        dispatcher_text = (
            REPO_ROOT
            / "code"
            / "rtl"
            / "tree_control"
            / "PredictionWindowSerialDispatcher.v"
        ).read_text(encoding="utf-8")

        self.assertIn("output [15:0] prefix_count", tree_analyze_text)
        self.assertIn("assign prefix_count =", tree_analyze_text)
        self.assertIn("ta_prefix_count_w", native_tree_text)
        self.assertIn("captured_prefix_count_r", native_tree_text)
        self.assertNotIn(
            "assign tc_pred_prefix_len = `TREE_MAX_PREFIX_NODES;",
            native_tree_text,
        )
        self.assertNotIn("DEFAULT_TREE_PREFIX_LEN", dispatcher_text)
        self.assertIn("session_prefix_len_r", dispatcher_text)

    def test_tree_analyze_and_sidecar_use_explicit_referenced_token_position_ports(self) -> None:
        tree_analyze_text = (
            REPO_ROOT / "code" / "rtl" / "tree_control" / "tree_analyze.v"
        ).read_text(encoding="utf-8")
        sidecar_text = (
            REPO_ROOT
            / "code"
            / "rtl"
            / "tree_control"
            / "NativeTreeOwnershipClosureSidecar.v"
        ).read_text(encoding="utf-8")

        self.assertNotIn("resolve_token_id(", tree_analyze_text)
        self.assertNotIn("resolve_position_id(", tree_analyze_text)
        self.assertIn("assign prefix_token_id =", tree_analyze_text)
        self.assertIn("assign prefix_position_id =", tree_analyze_text)
        self.assertIn(".src_frontier_referenced_token_id(", sidecar_text)
        self.assertIn(".src_frontier_referenced_position_id(", sidecar_text)
        self.assertIn(".prefix_count(", sidecar_text)
        self.assertIn(".frontier_referenced_token_id(", sidecar_text)
        self.assertIn(".frontier_referenced_position_id(", sidecar_text)

    def test_tree_mask_phase2_visible_mask_flows_to_mha(self) -> None:
        mha_text = (
            REPO_ROOT / "code" / "rtl" / "transformer" / "fp16_mha_controller.sv"
        ).read_text(encoding="utf-8")
        layer_text = (
            REPO_ROOT / "code" / "rtl" / "transformer" / "fp16_transformer_layer.sv"
        ).read_text(encoding="utf-8")
        scheduler_text = (
            REPO_ROOT / "code" / "rtl" / "transformer" / "fp16_layer_scheduler.sv"
        ).read_text(encoding="utf-8")
        top_text = (
            REPO_ROOT / "code" / "rtl" / "transformer" / "fp16_inference_top.sv"
        ).read_text(encoding="utf-8")
        adapter_text = (
            REPO_ROOT / "code" / "rtl" / "transformer" / "fp16_inference_adapter.sv"
        ).read_text(encoding="utf-8")
        op_text = (
            REPO_ROOT / "code" / "rtl" / "tree_control" / "IntegrationOperatorPart.v"
        ).read_text(encoding="utf-8")
        tc_text = (
            REPO_ROOT / "code" / "rtl" / "tree_control" / "IntegrationTreeControlPart.v"
        ).read_text(encoding="utf-8")
        chip_text = (
            REPO_ROOT
            / "code"
            / "rtl"
            / "tree_control"
            / "control_chip_stage2_single_chiplet.v"
        ).read_text(encoding="utf-8")

        self.assertIn("issue_visible_mask", mha_text)
        self.assertIn("visible_mask_r", mha_text)
        self.assertIn("visible_mask_r[pos_idx_r]", mha_text)
        self.assertNotIn("branch_of_pos_w = private_offset_w >> 1;", mha_text)
        self.assertIn("issue_visible_mask", layer_text)
        self.assertIn("issue_visible_mask", scheduler_text)
        self.assertIn("cfg_visible_mask", top_text)
        self.assertIn("issue_visible_mask", adapter_text)
        self.assertIn("issue_visible_mask", op_text)
        self.assertIn("issue_visible_mask", tc_text)
        self.assertIn("issue_visible_mask", chip_text)

    def test_tree_mask_phase3_generator_is_instantiated_in_native_tree_path(self) -> None:
        generator_path = (
            REPO_ROOT / "code" / "rtl" / "tree_control" / "tree_mask_generator.v"
        )
        generator_text = generator_path.read_text(encoding="utf-8")
        chip_text = (
            REPO_ROOT
            / "code"
            / "rtl"
            / "tree_control"
            / "control_chip_stage2_single_chiplet.v"
        ).read_text(encoding="utf-8")
        native_tree_text = (
            REPO_ROOT / "code" / "rtl" / "tree_control" / "NativeTreeMainFrontend.v"
        ).read_text(encoding="utf-8")

        self.assertTrue(generator_path.exists())
        self.assertIn("tree_mask_generator", chip_text)
        self.assertIn("issue_visible_mask", native_tree_text)
        self.assertIn("src_committed_len", generator_text)
        self.assertIn("src_frontier_branch_id", generator_text)
        self.assertIn("src_frontier_level_id", generator_text)

    def test_recompute_prefill_commits_into_kv_committed_region(self) -> None:
        tree_control_text = (
            REPO_ROOT / "code" / "rtl" / "tree_control" / "IntegrationTreeControlPart.v"
        ).read_text(encoding="utf-8")
        inference_top_text = (
            REPO_ROOT / "code" / "rtl" / "transformer" / "fp16_inference_top.sv"
        ).read_text(encoding="utf-8")

        self.assertIn(
            ".COMMIT_ADDR(`KV_COMMITTED_BASE)",
            tree_control_text,
        )
        self.assertNotIn(
            ".COMMIT_ADDR(ISSUE_SRC_ADDR)",
            tree_control_text,
        )
        self.assertIn(
            "parameter [ADDR_W-1:0] KV_CACHE_SRAM_BASE = `KV_COMMITTED_BASE,",
            inference_top_text,
        )

    def test_native_tree_main_frontend_prefix_tokens_are_forwarded_to_main_issue_path(self) -> None:
        native_tree_text = (
            REPO_ROOT / "code" / "rtl" / "tree_control" / "NativeTreeMainFrontend.v"
        ).read_text(encoding="utf-8")

        self.assertNotIn("if (prefix_valid_w) begin", native_tree_text)
        self.assertIn("slot_prefix_phase_r", native_tree_text)
        self.assertIn("slot_tree_mask_en_r <= {WINDOW_BRANCH_SLOTS{1'b0}};", native_tree_text)
        self.assertIn("slot_token_id_r[(first_slot_idx_comb*`TOKEN_ID_W) +: `TOKEN_ID_W] <=", native_tree_text)
        self.assertIn("prefix_token_id_w", native_tree_text)
        self.assertIn("prefix_position_id_w", native_tree_text)

    def test_toy_model_lm_head_base_does_not_overlap_layer_preload_window(self) -> None:
        import importlib.util

        ref_text = (
            REPO_ROOT / "code" / "script" / "toy_model" / "toy_model_reference.py"
        ).read_text(encoding="utf-8")
        top_text = (
            REPO_ROOT / "code" / "rtl" / "transformer" / "fp16_inference_top.sv"
        ).read_text(encoding="utf-8")
        adapter_text = (
            REPO_ROOT / "code" / "rtl" / "transformer" / "fp16_inference_adapter.sv"
        ).read_text(encoding="utf-8")
        tb_top_text = (
            REPO_ROOT / "code" / "tb" / "transformer" / "tb_fp16_inference_top_toy_real.sv"
        ).read_text(encoding="utf-8")
        tb_adapter_text = (
            REPO_ROOT / "code" / "tb" / "transformer" / "tb_fp16_inference_adapter.sv"
        ).read_text(encoding="utf-8")

        spec = importlib.util.spec_from_file_location(
            "toy_model_reference",
            REPO_ROOT / "code" / "script" / "toy_model" / "toy_model_reference.py",
        )
        self.assertIsNotNone(spec)
        assert spec is not None
        module = importlib.util.module_from_spec(spec)
        assert spec.loader is not None
        spec.loader.exec_module(module)

        lm_head_base = int(module.LM_HEAD_BASE)
        n_layers = int(module.N_LAYERS)
        weight_sram_base = int(module.WEIGHT_SRAM_BASE)
        weight_window_beats = int(module.WEIGHT_WINDOW_BEATS)
        hidden_beats = int(module.HIDDEN_BEATS)
        intermediate_beats = int(module.INTERMEDIATE_BEATS)
        preload_window_limit = weight_sram_base + (2 * hidden_beats) + weight_window_beats
        layer_scratch_stride = (hidden_beats * 8) + (intermediate_beats * 3)
        layer_workspace_limit = preload_window_limit + (n_layers * layer_scratch_stride)

        self.assertGreaterEqual(lm_head_base, layer_workspace_limit)
        self.assertIn(f"LM_HEAD_BASE = {lm_head_base}", ref_text)
        self.assertIn(f"LM_HEAD_WEIGHT_BASE = 23'd{lm_head_base}", top_text)
        self.assertIn(f"LM_HEAD_WEIGHT_BASE = 23'd{lm_head_base}", adapter_text)
        self.assertIn(
            f"localparam [`SRAM_ADDR_W-1:0] LM_HEAD_BASE = 23'd{lm_head_base};",
            tb_top_text,
        )
        self.assertIn(
            f"localparam [`SRAM_ADDR_W-1:0] LM_HEAD_BASE = 23'd{lm_head_base};",
            tb_adapter_text,
        )

    def test_decoder_chain_uses_weight_bank_instead_of_fp_one(self) -> None:
        text = (
            REPO_ROOT / "code" / "rtl" / "transformer" / "decoderOnlyTransformerChain.v"
        ).read_text(encoding="utf-8")
        self.assertIn("ToyDecoderWeightBank", text)
        self.assertIn("parameter integer VECTOR_DIM = 4", text)
        self.assertNotIn("assign q_weights_w = FP_ONE;", text)
        self.assertNotIn("assign kv_weights_w = FP_ONE;", text)

    def test_ffn_unit_no_longer_binds_fixed_fp_one_weights(self) -> None:
        text = (
            REPO_ROOT / "code" / "rtl" / "transformer" / "decoderFfnUnit.v"
        ).read_text(encoding="utf-8")
        self.assertNotIn("assign layer1_weights_w = FP_ONE;", text)
        self.assertNotIn("assign layer2_weights_w = FP_ONE;", text)
        self.assertIn(
            "input      [VECTOR_DIM*VECTOR_DIM*DATA_WIDTH-1:0] layer1_weight", text
        )
        self.assertIn(
            "input      [VECTOR_DIM*VECTOR_DIM*DATA_WIDTH-1:0] layer2_weight", text
        )

    def test_stage2_run_script_passes_weight_memh_plusarg(self) -> None:
        text = (
            REPO_ROOT
            / "verification"
            / "stage2"
            / "25_vcs_control_chip_stage2_single_chiplet_platform_driver_bringup"
            / "scripts"
            / "run_tb_control_chip_stage2_single_chiplet_platform_driver_bringup.sh"
        ).read_text(encoding="utf-8")
        self.assertIn("+toy_weight_memh=", text)
        self.assertIn("ToyDecoderWeightBank.v", text)

    def test_stage2_real_weight_bringup_script_exists(self) -> None:
        script_path = (
            REPO_ROOT
            / "verification"
            / "stage2"
            / "26_vcs_control_chip_stage2_single_chiplet_real_weight_package_bringup"
            / "scripts"
            / "run_tb_control_chip_stage2_single_chiplet_real_weight_package_bringup.sh"
        )
        self.assertTrue(script_path.exists())
        text = script_path.read_text(encoding="utf-8")
        self.assertIn("rtl_backend.real_weight_export", text)
        self.assertIn("REAL_MODEL_PATH", text)
        self.assertIn("+toy_weight_memh=", text)
        self.assertIn("placeholder_real_model_path", text)
        self.assertIn("real_model_path_not_found", text)

    def test_platform_driver_path_plusargs_have_extended_string_buffers(self) -> None:
        tb_text = (
            REPO_ROOT
            / "code"
            / "tb"
            / "tree_control_tb"
            / "tb_control_chip_stage2_single_chiplet_platform_driver.v"
        ).read_text(encoding="utf-8")
        weight_bank_text = (
            REPO_ROOT / "code" / "rtl" / "transformer" / "ToyDecoderWeightBank.v"
        ).read_text(encoding="utf-8")

        self.assertIn("reg [4095:0] stimulus_memh_path;", tb_text)
        self.assertIn("reg [4095:0] events_jsonl_path;", tb_text)
        self.assertIn("reg [4095:0] weight_memh_path_r;", weight_bank_text)

    def test_top_and_tb_have_native_tree_platform_hooks(self) -> None:
        top_text = (
            REPO_ROOT
            / "code"
            / "rtl"
            / "tree_control"
            / "control_chip_stage2_single_chiplet.v"
        ).read_text(encoding="utf-8")
        tb_text = (
            REPO_ROOT
            / "code"
            / "tb"
            / "tree_control_tb"
            / "tb_control_chip_stage2_single_chiplet_platform_driver.v"
        ).read_text(encoding="utf-8")
        sidecar_path = (
            REPO_ROOT
            / "code"
            / "rtl"
            / "tree_control"
            / "NativeTreeOwnershipClosureSidecar.v"
        )

        self.assertIn("ENABLE_NATIVE_TREE_SIDECAR", top_text)
        self.assertIn("native_tree_req_valid", top_text)
        self.assertIn("native_tree_src_frontier_parent_node_id", top_text)
        self.assertIn("native_tree_req_valid", tb_text)
        self.assertIn("\"native_tree_req\"", tb_text)
        self.assertIn("\"native_tree_pe_resp\"", tb_text)
        self.assertTrue(sidecar_path.exists())

    def test_transform_path_and_top_include_29_native_tree_main_frontend_hooks(self) -> None:
        transform_text = (
            REPO_ROOT
            / "code"
            / "rtl"
            / "transformer"
            / "IntegrationTransformPart.v"
        ).read_text(encoding="utf-8")
        top_text = (
            REPO_ROOT
            / "code"
            / "rtl"
            / "tree_control"
            / "control_chip_stage2_single_chiplet.v"
        ).read_text(encoding="utf-8")
        main_frontend_path = (
            REPO_ROOT
            / "code"
            / "rtl"
            / "tree_control"
            / "NativeTreeMainFrontend.v"
        )

        self.assertIn("parameter integer DECODER_VECTOR_DIM = 4", transform_text)
        self.assertIn("op_resp_rdata[(4*DECODER_DATA_WIDTH)-1:0]", transform_text)
        self.assertIn("op_resp_rdata[(8*DECODER_DATA_WIDTH)-1:(4*DECODER_DATA_WIDTH)]", transform_text)
        self.assertIn("ENABLE_NATIVE_TREE_MAIN_FRONTEND", top_text)
        self.assertIn("NativeTreeMainFrontend", top_text)
        self.assertTrue(main_frontend_path.exists())

    def test_transform_path_keeps_legacy_compact_payload_compatibility(self) -> None:
        transform_text = (
            REPO_ROOT
            / "code"
            / "rtl"
            / "transformer"
            / "IntegrationTransformPart.v"
        ).read_text(encoding="utf-8")

        self.assertIn("legacy_compact_payload_w", transform_text)
        self.assertIn("legacy_token_vector_w", transform_text)
        self.assertIn("legacy_kv_vector_w", transform_text)

    def test_weight_bank_fallback_is_identity_like_not_dense_all_ones(self) -> None:
        weight_bank_text = (
            REPO_ROOT
            / "code"
            / "rtl"
            / "transformer"
            / "ToyDecoderWeightBank.v"
        ).read_text(encoding="utf-8")

        self.assertIn("weight_mem[weight_idx_i] = {DATA_WIDTH{1'b0}};", weight_bank_text)
        self.assertIn("diag_idx_i", weight_bank_text)
        self.assertIn("weight_mem[(weight_idx_i*WEIGHT_BLOCK_WORDS)", weight_bank_text)

    def test_stage2_27_run_script_exists(self) -> None:
        script_path = (
            REPO_ROOT
            / "verification"
            / "stage2"
            / "27_vcs_control_chip_stage2_single_chiplet_native_tree_real_weight_platform_bringup"
            / "scripts"
            / "run_tb_control_chip_stage2_single_chiplet_native_tree_real_weight_platform_bringup.sh"
        )
        self.assertTrue(script_path.exists())
        text = script_path.read_text(encoding="utf-8")
        self.assertIn("NativeTreeOwnershipClosureSidecar.v", text)
        self.assertIn("+stimulus_memh=", text)
        self.assertIn("+toy_weight_memh=", text)

    def test_platform_driver_run_scripts_include_new_top_dependencies(self) -> None:
        script_paths = [
            REPO_ROOT
            / "verification"
            / "stage2"
            / "25_vcs_control_chip_stage2_single_chiplet_platform_driver_bringup"
            / "scripts"
            / "run_tb_control_chip_stage2_single_chiplet_platform_driver_bringup.sh",
            REPO_ROOT
            / "verification"
            / "stage2"
            / "26_vcs_control_chip_stage2_single_chiplet_real_weight_package_bringup"
            / "scripts"
            / "run_tb_control_chip_stage2_single_chiplet_real_weight_package_bringup.sh",
            REPO_ROOT
            / "verification"
            / "stage2"
            / "27_vcs_control_chip_stage2_single_chiplet_native_tree_real_weight_platform_bringup"
            / "scripts"
            / "run_tb_control_chip_stage2_single_chiplet_native_tree_real_weight_platform_bringup.sh",
            REPO_ROOT
            / "verification"
            / "stage2"
            / "28_vcs_control_chip_stage2_single_chiplet_ssd_runtime_adapter_bringup"
            / "scripts"
            / "run_tb_control_chip_stage2_single_chiplet_ssd_runtime_adapter_bringup.sh",
        ]

        for script_path in script_paths:
            text = script_path.read_text(encoding="utf-8")
            self.assertIn("PredictionWindowSerialDispatcher.v", text)
            self.assertIn("NativeTreeMainFrontend.v", text)

    def test_stage2_29_run_script_exists(self) -> None:
        script_path = (
            REPO_ROOT
            / "verification"
            / "stage2"
            / "29_vcs_control_chip_stage2_single_chiplet_native_tree_main_frontend_real_vector_weight_bringup"
            / "scripts"
            / "run_tb_control_chip_stage2_single_chiplet_native_tree_main_frontend_real_vector_weight_bringup.sh"
        )
        self.assertTrue(script_path.exists())
        text = script_path.read_text(encoding="utf-8")
        self.assertIn("NativeTreeMainFrontend.v", text)
        self.assertIn("+toy_weight_memh=", text)

    def test_stage2_29_tb_enables_native_tree_main_frontend(self) -> None:
        tb_path = (
            REPO_ROOT
            / "code"
            / "tb"
            / "tree_control_tb"
            / "tb_control_chip_stage2_single_chiplet_native_tree_main_frontend_platform_driver.v"
        )
        self.assertTrue(tb_path.exists())
        text = tb_path.read_text(encoding="utf-8")
        self.assertIn(".ENABLE_TREE_WINDOW_CONSUMER(0)", text)
        self.assertIn(".ENABLE_NATIVE_TREE_MAIN_FRONTEND(1)", text)
        self.assertIn(".ENABLE_NATIVE_TREE_SIDECAR(0)", text)

    def test_stage2_29_tb_waits_for_real_writeback_completion_before_pass(self) -> None:
        tb_path = (
            REPO_ROOT
            / "code"
            / "tb"
            / "tree_control_tb"
            / "tb_control_chip_stage2_single_chiplet_native_tree_main_frontend_platform_driver.v"
        )
        text = tb_path.read_text(encoding="utf-8")
        self.assertIn("wb_done_seen_r", text)
        self.assertIn("hbm_write_seen_r", text)
        self.assertIn("DEFAULT_MAX_POST_STIMULUS_CYCLES", text)
        self.assertIn("max_post_stimulus_cycles", text)
        self.assertIn(
            'if (!$value$plusargs("max_post_stimulus_cycles=%d",',
            text,
        )
        self.assertIn("for (drain_count_r = 0;", text)
        self.assertIn("drain_count_r < max_post_stimulus_cycles;", text)
        self.assertIn("busy !== 1'b0", text)
        self.assertIn("if (!wb_done_seen_r)", text)
        self.assertIn("if (!hbm_write_seen_r)", text)

    def test_stage2_30_native_tree_platform_driver_drain_keeps_recompute_and_wb_ready_high(self) -> None:
        tb_path = (
            REPO_ROOT
            / "code"
            / "tb"
            / "tree_control_tb"
            / "tb_control_chip_stage2_single_chiplet_native_tree_main_frontend_platform_driver.v"
        )
        text = tb_path.read_text(encoding="utf-8")
        self.assertIn(
            "for (drain_count_r = 0;\n"
            "         drain_count_r < max_post_stimulus_cycles;\n"
            "         drain_count_r = drain_count_r + 1) begin\n"
            "        @(negedge clk);\n"
            "        clear_driven_inputs();\n"
            "        recompute_req_ready = 1'b1;\n"
            "        wb_ready = 1'b1;\n",
            text,
        )

    def test_stage2_30_native_tree_protocol_carries_explicit_referenced_fields(self) -> None:
        tb_text = (
            REPO_ROOT
            / "code"
            / "tb"
            / "tree_control_tb"
            / "tb_control_chip_stage2_single_chiplet_native_tree_main_frontend_platform_driver.v"
        ).read_text(encoding="utf-8")
        tree_analyze_text = (
            REPO_ROOT
            / "code"
            / "rtl"
            / "tree_control"
            / "tree_analyze.v"
        ).read_text(encoding="utf-8")
        frontend_text = (
            REPO_ROOT
            / "code"
            / "rtl"
            / "tree_control"
            / "NativeTreeMainFrontend.v"
        ).read_text(encoding="utf-8")

        self.assertNotIn("localparam integer STIMULUS_BITS = 2525;", tb_text)
        self.assertIn("localparam integer STIMULUS_BITS =", tb_text)
        self.assertIn("native_tree_src_committed_len", tb_text)
        self.assertIn("native_tree_src_frontier_branch_id", tb_text)
        self.assertIn("native_tree_src_frontier_level_id", tb_text)
        self.assertIn("native_tree_src_frontier_referenced_token_id", tb_text)
        self.assertIn("native_tree_src_frontier_referenced_position_id", tb_text)
        self.assertIn("native_tree_src_frontier_tree_mask_en", tb_text)
        self.assertIn("src_committed_len", tree_analyze_text)
        self.assertIn("frontier_branch_id", tree_analyze_text)
        self.assertIn("frontier_level_slot_count", tree_analyze_text)
        self.assertIn("src_frontier_referenced_token_id", tree_analyze_text)
        self.assertIn("frontier_referenced_token_id", tree_analyze_text)
        self.assertIn("src_frontier_referenced_position_id", tree_analyze_text)
        self.assertIn("frontier_referenced_position_id", tree_analyze_text)
        self.assertIn("src_frontier_tree_mask_en", tree_analyze_text)
        self.assertIn("frontier_tree_mask_en", tree_analyze_text)
        self.assertIn("src_committed_len", frontend_text)
        self.assertIn("src_frontier_branch_id", frontend_text)
        self.assertIn("src_frontier_level_id", frontend_text)
        self.assertIn("src_frontier_referenced_token_id", frontend_text)
        self.assertIn("src_frontier_referenced_position_id", frontend_text)
        self.assertIn("src_frontier_tree_mask_en", frontend_text)
        self.assertIn("slot_referenced_token_id_r <=\n                        frontier_referenced_token_id_w;", frontend_text)
        self.assertIn("slot_referenced_position_r <=\n                        frontier_referenced_position_id_w;", frontend_text)
        self.assertNotIn("assign tc_pred_tree_mask_en = request_active_r;", frontend_text)
        self.assertIn("slot_tree_mask_en_r", frontend_text)

    def test_stage2_parallel_verify_group_uses_explicit_native_tree_branch_and_level_metadata(self) -> None:
        analyze_text = (
            REPO_ROOT
            / "code"
            / "rtl"
            / "tree_control"
            / "tree_analyze.v"
        ).read_text(encoding="utf-8")
        frontend_text = (
            REPO_ROOT
            / "code"
            / "rtl"
            / "tree_control"
            / "NativeTreeMainFrontend.v"
        ).read_text(encoding="utf-8")
        control_text = (
            REPO_ROOT
            / "code"
            / "rtl"
            / "tree_control"
            / "control_chip_stage2_single_chiplet.v"
        ).read_text(encoding="utf-8")

        self.assertIn("output     [`BRANCH_ID_W-1:0]     tc_pred_branch_id", frontend_text)
        self.assertIn("output     [`TREE_LEVEL_ID_W-1:0] tc_pred_level_id", frontend_text)
        self.assertIn("slot_branch_id_r", frontend_text)
        self.assertIn("captured_frontier_level_id_r", frontend_text)
        self.assertNotIn("assign frontier_level_id = frontier_level_idx_r;", analyze_text)
        self.assertNotIn(
            "{{(16-`TREE_LEVEL_ID_W){1'b0}}, frontier_level_idx_r} + 16'd1;",
            analyze_text,
        )
        self.assertIn("frontier_level_id_r[", analyze_text)
        self.assertIn("frontier_level_slot_count_comb", analyze_text)
        self.assertIn("native_tree_main_pred_branch_id_w", control_text)
        self.assertIn("native_tree_main_pred_level_id_w", control_text)
        self.assertNotIn(
            "native_tree_main_pred_source_id_w[`BRANCH_ID_W-1:0]",
            control_text,
        )

    def test_stage2_parallel_verify_group_lifecycle_is_not_single_active_branch_only(self) -> None:
        control_text = (
            REPO_ROOT
            / "code"
            / "rtl"
            / "tree_control"
            / "control_chip_stage2_single_chiplet.v"
        ).read_text(encoding="utf-8")

        self.assertNotIn("active_lifecycle_branch_id_r", control_text)
        self.assertNotIn("active_lifecycle_last_slot_r", control_text)
        self.assertIn("active_issue_branch_id_r", control_text)
        self.assertIn("active_issue_private_depth_r", control_text)
        self.assertIn("lifecycle_candidate_depth_by_branch_r", control_text)
        self.assertIn("lifecycle_result_depth_by_branch_r", control_text)

    def test_stage2_25_platform_driver_tracks_extended_native_tree_stimulus_fields(self) -> None:
        tb_text = (
            REPO_ROOT
            / "code"
            / "tb"
            / "tree_control_tb"
            / "tb_control_chip_stage2_single_chiplet_platform_driver.v"
        ).read_text(encoding="utf-8")

        self.assertIn("localparam integer STIMULUS_BITS = 2525;", tb_text)
        self.assertIn("native_tree_src_committed_len", tb_text)
        self.assertIn("native_tree_src_frontier_branch_id", tb_text)
        self.assertIn("native_tree_src_frontier_level_id", tb_text)
        self.assertIn("native_tree_src_frontier_tree_mask_en", tb_text)

    def test_native_tree_main_frontend_uses_protocol_tree_mask_and_non_native_path_can_override_issue_position(self) -> None:
        frontend_text = (
            REPO_ROOT
            / "code"
            / "rtl"
            / "tree_control"
            / "NativeTreeMainFrontend.v"
        ).read_text(encoding="utf-8")
        dispatcher_text = (
            REPO_ROOT
            / "code"
            / "rtl"
            / "tree_control"
            / "PredictionWindowSerialDispatcher.v"
        ).read_text(encoding="utf-8")
        control_text = (
            REPO_ROOT
            / "code"
            / "rtl"
            / "tree_control"
            / "control_chip_stage2_single_chiplet.v"
        ).read_text(encoding="utf-8")
        tc_text = (
            REPO_ROOT
            / "code"
            / "rtl"
            / "tree_control"
            / "IntegrationTreeControlPart.v"
        ).read_text(encoding="utf-8")

        self.assertIn("tc_pred_issue_position", dispatcher_text)
        self.assertIn("slot_issue_position_r", dispatcher_text)
        self.assertIn("dispatch_pred_issue_position", control_text)
        self.assertNotIn(
            "(pred_tree_mask_en_r && pred_issue_position_valid_r)",
            tc_text,
        )
        self.assertIn(
            "ENABLE_PREDICTION_INPUT ?\n        pred_issue_position_valid_r :",
            tc_text,
        )

    def test_integration_tree_control_avoids_constant_position_stale_check_for_issue_position_override(self) -> None:
        tc_text = (
            REPO_ROOT
            / "code"
            / "rtl"
            / "tree_control"
            / "IntegrationTreeControlPart.v"
        ).read_text(encoding="utf-8")

        self.assertIn("effective_pred_issue_position_valid_w", tc_text)
        self.assertIn("effective_pred_issue_position_w", tc_text)
        self.assertNotIn(
            "(CURRENT_POSITION >= pred_referenced_position) ?",
            tc_text,
        )

    def test_fp16_inference_adapter_passes_issue_position_override_on_first_issue_cycle(self) -> None:
        adapter_text = (
            REPO_ROOT
            / "code"
            / "rtl"
            / "transformer"
            / "fp16_inference_adapter.sv"
        ).read_text(encoding="utf-8")

        self.assertIn("wire [15:0] active_position_ovr_val_w;", adapter_text)
        self.assertIn("wire active_position_ovr_en_w;", adapter_text)
        self.assertIn(
            "assign active_position_ovr_val_w =\n"
            "    (state_r == ST_IDLE) ? issue_position : position_ovr_val_r;",
            adapter_text,
        )
        self.assertIn(
            "assign active_position_ovr_en_w =\n"
            "    (state_r == ST_IDLE) ? issue_position_ovr : position_ovr_en_r;",
            adapter_text,
        )
        self.assertIn(".cfg_position(active_position_ovr_val_w)", adapter_text)
        self.assertIn(".cfg_position_ovr(active_position_ovr_en_w)", adapter_text)

    def test_stage2_30_platform_driver_logs_issue_and_fp16_progress_boundaries(self) -> None:
        tb_text = (
            REPO_ROOT
            / "code"
            / "tb"
            / "tree_control_tb"
            / "tb_control_chip_stage2_single_chiplet_native_tree_main_frontend_platform_driver.v"
        ).read_text(encoding="utf-8")

        self.assertIn('\\"event\\":\\"issue_accept\\"', tb_text)
        self.assertIn('\\"event\\":\\"fp16_token_out\\"', tb_text)
        self.assertIn('\\"event\\":\\"operator_result\\"', tb_text)

    def test_stage2_30_platform_driver_supports_long_configurable_fp16_drain(self) -> None:
        tb_text = (
            REPO_ROOT
            / "code"
            / "tb"
            / "tree_control_tb"
            / "tb_control_chip_stage2_single_chiplet_native_tree_main_frontend_platform_driver.v"
        ).read_text(encoding="utf-8")

        self.assertIn(
            'localparam integer DEFAULT_MAX_POST_STIMULUS_CYCLES = 2000000;',
            tb_text,
        )
        self.assertIn(
            '$value$plusargs("max_post_stimulus_cycles=%d",',
            tb_text,
        )
        self.assertNotIn(
            "localparam integer MAX_POST_STIMULUS_CYCLES = 256;",
            tb_text,
        )

    def test_stage2_30_run_script_exists(self) -> None:
        script_path = (
            REPO_ROOT
            / "verification"
            / "stage2"
            / "30_vcs_control_chip_stage2_single_chiplet_real_ssd_sync_tree_step_payload_bringup"
            / "scripts"
            / "run_tb_control_chip_stage2_single_chiplet_real_ssd_sync_tree_step_payload_bringup.sh"
        )
        self.assertTrue(script_path.exists())
        text = script_path.read_text(encoding="utf-8")
        self.assertIn("SYNC_STEP_JSON", text)
        self.assertIn("--sync-step-json", text)
        self.assertIn("rtl_runtime.runtime_adapter", text)

    def test_stage2_30_vm_prepared_script_sets_long_fp16_drain_window(self) -> None:
        script_path = (
            REPO_ROOT
            / "verification"
            / "stage2"
            / "30_vcs_control_chip_stage2_single_chiplet_real_ssd_sync_tree_step_payload_bringup"
            / "scripts"
            / "run_tb_control_chip_stage2_single_chiplet_real_ssd_sync_tree_step_payload_vm_prepared.sh"
        )
        text = script_path.read_text(encoding="utf-8")
        self.assertIn('MAX_POST_STIMULUS_CYCLES="${MAX_POST_STIMULUS_CYCLES:-8000000}"', text)
        self.assertIn("+max_post_stimulus_cycles=${MAX_POST_STIMULUS_CYCLES}", text)

    def test_stage2_30_vm_prepared_script_copies_strict_artifacts_from_tb_workdir(self) -> None:
        script_path = (
            REPO_ROOT
            / "verification"
            / "stage2"
            / "30_vcs_control_chip_stage2_single_chiplet_real_ssd_sync_tree_step_payload_bringup"
            / "scripts"
            / "run_tb_control_chip_stage2_single_chiplet_real_ssd_sync_tree_step_payload_vm_prepared.sh"
        )
        text = script_path.read_text(encoding="utf-8")
        self.assertIn('TB_RESULT_FILE="${RUN_DIR}/logs/${TB_NAME}_result.txt"', text)
        self.assertIn('TB_WORKDIR="$(grep -o', text)
        self.assertIn('"${TB_RESULT_FILE}"', text)
        self.assertIn('local_tb_workdir=', text)
        self.assertIn('find "${TB_WORKDIR}" -maxdepth 1 -type f', text)

    def test_stage2_41_vm_prepared_script_checks_nested_result_judge(self) -> None:
        script_path = (
            REPO_ROOT
            / "verification"
            / "stage2"
            / "41_vcs_control_chip_stage2_single_chiplet_tree_mask_e2e_strict_bringup"
            / "scripts"
            / "run_tb_control_chip_stage2_single_chiplet_tree_mask_e2e_strict_vm_prepared.sh"
        )
        text = script_path.read_text(encoding="utf-8")
        self.assertIn('STEP30_RESULT_FILE=', text)
        self.assertIn('grep -q "^judge=PASS$" "${STEP30_RESULT_FILE}"', text)
        self.assertIn('write_summary 1', text)

    def test_stage2_30_run_script_autogenerates_default_sync_step_payload(self) -> None:
        script_path = (
            REPO_ROOT
            / "verification"
            / "stage2"
            / "30_vcs_control_chip_stage2_single_chiplet_real_ssd_sync_tree_step_payload_bringup"
            / "scripts"
            / "run_tb_control_chip_stage2_single_chiplet_real_ssd_sync_tree_step_payload_bringup.sh"
        )
        text = script_path.read_text(encoding="utf-8")
        self.assertIn("default_sync_tree_step_payload.json", text)
        self.assertIn("rtl_backend.ssd_bridge", text)

    def test_stage2_31_run_script_exists(self) -> None:
        script_path = (
            REPO_ROOT
            / "verification"
            / "stage2"
            / "31_vcs_control_chip_stage2_single_chiplet_ssd_sync_runtime_loop_bringup"
            / "scripts"
            / "run_tb_control_chip_stage2_single_chiplet_ssd_sync_runtime_loop_bringup.sh"
        )
        self.assertTrue(script_path.exists())
        text = script_path.read_text(encoding="utf-8")
        self.assertIn("rtl_runtime.runtime_loop", text)
        self.assertIn("--step-trace-jsonl", text)
        self.assertIn("BACKEND_SCRIPT", text)

    def test_stage2_31_run_script_exports_ssd_main_pythonpath(self) -> None:
        script_path = (
            REPO_ROOT
            / "verification"
            / "stage2"
            / "31_vcs_control_chip_stage2_single_chiplet_ssd_sync_runtime_loop_bringup"
            / "scripts"
            / "run_tb_control_chip_stage2_single_chiplet_ssd_sync_runtime_loop_bringup.sh"
        )
        text = script_path.read_text(encoding="utf-8")
        self.assertIn(
            'PYTHONPATH="${REPO_ROOT}/code/script:${REPO_ROOT}/code/script/ssd-main',
            text,
        )

    def test_stage2_single_chiplet_native_tree_path_has_comparator_flush_lifecycle_closure(self) -> None:
        top_text = (
            REPO_ROOT
            / "code"
            / "rtl"
            / "tree_control"
            / "control_chip_stage2_single_chiplet.v"
        ).read_text(encoding="utf-8")

        self.assertIn("comparator u_comparator", top_text)
        self.assertIn(".flush_freeze(flush_valid)", top_text)
        self.assertIn(".flush_ctrl_valid(flush_valid)", top_text)
        self.assertIn(
            ".branch_liveness_valid(branch_liveness_update_valid_w)",
            top_text,
        )
        self.assertIn(".prefetch_flush_valid(prefetch_flush_valid)", top_text)
        self.assertIn(".free_list_flush_valid(free_list_flush_valid)", top_text)
        self.assertIn(".token_flush_valid(token_flush_valid)", top_text)
        self.assertIn(".flush_valid(prefetch_flush_valid)", top_text)
        self.assertIn(".flush_valid(free_list_flush_valid)", top_text)
        self.assertIn(".flush_valid(token_flush_valid)", top_text)

    def test_stage2_single_chiplet_native_tree_compare_uses_real_generated_token(self) -> None:
        top_text = (
            REPO_ROOT
            / "code"
            / "rtl"
            / "tree_control"
            / "control_chip_stage2_single_chiplet.v"
        ).read_text(encoding="utf-8")

        self.assertIn("cmp_slot_real_token_id", top_text)
        self.assertIn("wb_data[15:0]", top_text)
        self.assertIn("cmp_slot_candidate_token_id", top_text)

    def test_stage2_single_chiplet_native_tree_lifecycle_regs_are_driven(self) -> None:
        top_text = (
            REPO_ROOT
            / "code"
            / "rtl"
            / "tree_control"
            / "control_chip_stage2_single_chiplet.v"
        ).read_text(encoding="utf-8")

        self.assertIn("lifecycle_window_active_r <=", top_text)
        self.assertTrue(
            ("active_lifecycle_slot_valid_r <=" in top_text)
            or ("lifecycle_slot_meta_valid_r <=" in top_text)
        )
        self.assertIn("lifecycle_cmp_fire_r <=", top_text)
        self.assertIn("token_wr_index_r <=", top_text)

    def test_tree_parallel_plan_is_integrated_into_stage2_main_path(self) -> None:
        top_text = (
            REPO_ROOT
            / "code"
            / "rtl"
            / "tree_control"
            / "control_chip_stage2_single_chiplet.v"
        ).read_text(encoding="utf-8")
        batch_top_text = (
            REPO_ROOT
            / "code"
            / "rtl"
            / "transformer"
            / "fp16_inference_top.sv"
        ).read_text(encoding="utf-8")
        attn_text = (
            REPO_ROOT
            / "code"
            / "rtl"
            / "transformer"
            / "fp16_mha_tree_attention.sv"
        ).read_text(encoding="utf-8")

        self.assertIn("tree_verify_dispatcher u_tree_verify_dispatcher", top_text)
        self.assertIn("fp16_inference_top u_tree_parallel_batch_inference_top", top_text)
        self.assertIn(".tree_req_valid(tree_parallel_req_valid_w)", top_text)
        self.assertIn(".tree_req_ready(tree_parallel_req_ready_w)", top_text)
        self.assertIn(".batch_out_valid(tree_parallel_batch_valid_w)", top_text)
        self.assertIn(".batch_out_ready(tree_parallel_batch_ready_w)", top_text)
        self.assertIn(".fwd_result_valid(tree_parallel_fwd_result_valid_w)", top_text)
        self.assertIn(".fwd_result_ready(tree_parallel_fwd_result_ready_w)", top_text)
        self.assertIn(".commit_valid(tree_parallel_commit_valid_w)", top_text)
        self.assertIn(".batch_in_valid(tree_parallel_batch_valid_w)", top_text)
        self.assertIn(".batch_in_ready(tree_parallel_batch_ready_w)", top_text)
        self.assertIn(".batch_out_valid(tree_parallel_fwd_result_valid_w)", top_text)
        self.assertIn(".batch_out_ready(tree_parallel_fwd_result_ready_w)", top_text)
        self.assertIn("wire use_tree_parallel_sram_req_w;", top_text)
        self.assertIn("wire tree_parallel_sram_req_valid_w;", top_text)
        self.assertIn("wire tree_parallel_resp_select_w;", top_text)
        self.assertIn("wire tree_parallel_sram_resp_valid_w;", top_text)
        self.assertIn(".sram_resp_valid(tree_parallel_sram_resp_valid_w)", top_text)
        self.assertIn(".sram_resp_ready(tree_parallel_sram_resp_ready_w)", top_text)
        self.assertIn(".sram_resp_data(tree_parallel_sram_resp_data_w)", top_text)
        self.assertIn(".sram_resp_id(tree_parallel_sram_resp_id_w)", top_text)
        self.assertIn("assign rc_main_req_valid_w =", top_text)
        self.assertIn("use_tree_parallel_sram_req_w ?", top_text)
        self.assertIn("tree_parallel_sram_req_valid_w", top_text)
        self.assertIn("assign tree_parallel_sram_rd_ready_w =", top_text)
        self.assertIn("assign tree_parallel_sram_wr_ready_w =", top_text)
        self.assertIn("assign tree_parallel_sram_resp_valid_w =", top_text)
        self.assertIn("tree_parallel_resp_select_w ?", top_text)
        self.assertIn("tree_parallel_sram_resp_ready_w", top_text)
        self.assertNotIn("assign batch_in_ready = 1'b0;", batch_top_text)
        self.assertNotIn("assign batch_out_valid = 1'b0;", batch_top_text)
        self.assertNotIn("TODO: Drive sram_rd_valid", attn_text)
        self.assertIn(".sram_rd_valid(batch_mha_rd_valid_w)", batch_top_text)
        self.assertIn(".sram_rd_ready(sram_rd_ready)", batch_top_text)
        self.assertIn(".sram_rd_addr(batch_mha_rd_addr_w)", batch_top_text)
        self.assertIn(".sram_rd_id(batch_mha_rd_id_w)", batch_top_text)
        self.assertIn(".sram_resp_valid(sram_resp_valid)", batch_top_text)
        self.assertIn(".sram_resp_ready(batch_mha_resp_ready_w)", batch_top_text)
        self.assertIn(".sram_resp_data(sram_resp_data)", batch_top_text)
        self.assertIn(".sram_resp_id(sram_resp_id)", batch_top_text)
        self.assertIn(".sram_wr_valid(batch_mha_wr_valid_w)", batch_top_text)
        self.assertIn(".sram_wr_ready(sram_wr_ready)", batch_top_text)
        self.assertIn(".sram_wr_addr(batch_mha_wr_addr_w)", batch_top_text)
        self.assertIn(".sram_wr_data(batch_mha_wr_data_w)", batch_top_text)
        self.assertNotIn(".sram_rd_valid()", batch_top_text)
        self.assertNotIn(".sram_wr_valid()", batch_top_text)
        self.assertNotIn(".sram_resp_valid(1'b0)", batch_top_text)
        self.assertIn("sram_rd_valid = batch_mha_rd_valid_w;", batch_top_text)
        self.assertIn("sram_resp_ready = batch_mha_resp_ready_w;", batch_top_text)
        self.assertIn("sram_wr_valid = batch_mha_wr_valid_w;", batch_top_text)

    def test_tree_parallel_mode_preserves_treecontrol_frontend_but_suppresses_serial_compute_launch(self) -> None:
        top_text = (
            REPO_ROOT
            / "code"
            / "rtl"
            / "tree_control"
            / "control_chip_stage2_single_chiplet.v"
        ).read_text(encoding="utf-8")

        self.assertIn("wire agu_tree_in_ready_w;", top_text)
        self.assertIn("assign native_tree_main_pred_ready_w =", top_text)
        self.assertIn("tree_parallel_mode_w ? agu_tree_in_ready_w : pred_ready", top_text)
        self.assertIn(
            "(tree_parallel_req_ready_w &&\n"
            "                 native_tree_main_req_ready_w &&\n"
            "                 native_tree_ownership_req_ready_w)",
            top_text,
        )
        self.assertIn(
            ".req_valid(\n"
            "        (ENABLE_NATIVE_TREE_MAIN_FRONTEND) ?\n"
            "            native_tree_req_valid : 1'b0)",
            top_text,
        )
        self.assertIn(
            ".src_req_valid(\n"
            "        (ENABLE_NATIVE_TREE_MAIN_FRONTEND) ?\n"
            "            native_tree_req_valid : 1'b0)",
            top_text,
        )
        self.assertIn(
            ".tree_in_valid(\n"
            "        tree_parallel_mode_w ?",
            top_text,
        )
        self.assertIn(".tree_in_ready(agu_tree_in_ready_w)", top_text)
        self.assertIn(
            "ENABLE_NATIVE_TREE_MAIN_FRONTEND ?\n"
            "        (tree_parallel_mode_w ? 1'b0 : native_tree_main_cfg_valid_w) :",
            top_text,
        )
        self.assertIn(
            "ENABLE_NATIVE_TREE_MAIN_FRONTEND ?\n"
            "        (tree_parallel_mode_w ? 1'b0 : native_tree_main_start_w) :",
            top_text,
        )
        self.assertIn(".tc_busy(tree_parallel_mode_w ? 1'b0 : tree_busy)", top_text)
        self.assertNotIn("!tree_parallel_mode_w) ?\n            native_tree_req_valid", top_text)

    def test_tree_parallel_mode_reinjects_batch_results_into_existing_lifecycle_paths(self) -> None:
        top_text = (
            REPO_ROOT
            / "code"
            / "rtl"
            / "tree_control"
            / "control_chip_stage2_single_chiplet.v"
        ).read_text(encoding="utf-8")
        dispatcher_text = (
            REPO_ROOT
            / "code"
            / "rtl"
            / "transformer"
            / "tree_verify_dispatcher.sv"
        ).read_text(encoding="utf-8")

        self.assertIn("tree_parallel_commit_valid_w", top_text)
        self.assertIn("tree_parallel_commit_branch_id_w", top_text)
        self.assertIn("tree_parallel_commit_depth_w", top_text)
        self.assertIn("tree_parallel_commit_flush_mask_w", top_text)
        self.assertIn(
            "if (tree_parallel_mode_w &&\n"
            "            tree_parallel_commit_valid_w &&\n"
            "            lifecycle_window_active_r)",
            top_text,
        )
        self.assertIn("lifecycle_cmp_fire_r <= 1'b1;", top_text)
        self.assertIn("lifecycle_window_active_r <= 1'b0;", top_text)
        self.assertIn("lifecycle_slot_result_valid_r <= tree_parallel_branch_valid_w;", top_text)
        self.assertIn("lifecycle_cmp_real_token_id_r[", top_text)
        self.assertIn("lifecycle_result_depth_by_branch_r[", top_text)
        self.assertIn(
            "lifecycle_result_accept_comb <=\n"
            "                tree_parallel_branch_valid_w &\n"
            "                ~tree_parallel_commit_flush_mask_w;",
            top_text,
        )
        self.assertIn("cmp_flush_mask = lat_branch_valid;", dispatcher_text)
        self.assertIn("cmp_flush_mask[best_branch] = 1'b0;", dispatcher_text)
        self.assertIn("winner_has_unaccepted_suffix =", dispatcher_text)
        self.assertIn("cmp_flush_mask = lat_branch_valid;", dispatcher_text)
        self.assertIn("if (winner_has_unaccepted_suffix) begin", dispatcher_text)
        self.assertIn("cmp_flush_mask[best_branch] = 1'b1;", dispatcher_text)

    def test_tree_parallel_winner_suffix_flush_does_not_include_accepted_prefix_nodes(self) -> None:
        top_text = (
            REPO_ROOT
            / "code"
            / "rtl"
            / "tree_control"
            / "control_chip_stage2_single_chiplet.v"
        ).read_text(encoding="utf-8")

        self.assertIn("tree_parallel_commit_flush_mask_w[tree_parallel_reduce_branch_i]", top_text)
        self.assertIn("tree_parallel_reduce_branch_i !=", top_text)
        self.assertIn("tree_parallel_commit_branch_id_w", top_text)
        self.assertIn(
            "tree_parallel_reduce_level_i >=\n"
            "                      tree_parallel_commit_depth_w",
            top_text,
        )

    def test_tree_parallel_depth_zero_clears_liveness_without_faking_prefix_accept(self) -> None:
        top_text = (
            REPO_ROOT
            / "code"
            / "rtl"
            / "tree_control"
            / "control_chip_stage2_single_chiplet.v"
        ).read_text(encoding="utf-8")

        self.assertIn(
            "assign accepted_prefix_valid =\n"
            "    tree_parallel_mode_w ?\n"
            "        (tree_parallel_commit_valid_w &&\n"
            "         (tree_parallel_commit_depth_w != 3'd0)) :\n"
            "        cmp_accepted_prefix_valid_w;",
            top_text,
        )
        self.assertIn(
            "assign branch_liveness_update_valid_w =\n"
            "    tree_parallel_mode_w ? tree_parallel_commit_valid_w :\n"
            "    cmp_accepted_prefix_valid_w;",
            top_text,
        )
        self.assertIn(
            "if (tree_parallel_commit_valid_w &&\n"
            "        (tree_parallel_commit_depth_w != 3'd0) &&\n"
            "        (tree_parallel_commit_branch_id_w < `BRANCH_NUM)) begin",
            top_text,
        )
        self.assertIn(
            "tree_parallel_prune_branch_mask_comb =\n"
            "        tree_parallel_branch_valid_w &\n"
            "        ~tree_parallel_live_branch_mask_comb;",
            top_text,
        )
        self.assertIn(
            ".branch_liveness_valid(branch_liveness_update_valid_w)",
            top_text,
        )

    def test_stage2_single_chiplet_native_tree_comparator_reduces_after_result_ready(self) -> None:
        top_text = (
            REPO_ROOT
            / "code"
            / "rtl"
            / "tree_control"
            / "control_chip_stage2_single_chiplet.v"
        ).read_text(encoding="utf-8")

        self.assertIn(".reduce_start_valid(lifecycle_cmp_fire_r)", top_text)
        self.assertIn(".reduce_req_id(lifecycle_req_id_r)", top_text)
        self.assertIn("assign token_commit_valid =", top_text)
        self.assertIn("tree_parallel_commit_replay_active_r ?", top_text)
        self.assertIn("(commit_valid && lifecycle_commit_select_valid_comb)", top_text)
        self.assertIn("assign bank_commit_valid =", top_text)

    def test_tree_parallel_commit_path_uses_kv_commit_copier(self) -> None:
        top_text = (
            REPO_ROOT
            / "code"
            / "rtl"
            / "tree_control"
            / "control_chip_stage2_single_chiplet.v"
        ).read_text(encoding="utf-8")
        copier_text = (
            REPO_ROOT
            / "code"
            / "rtl"
            / "tree_control"
            / "kv_commit_copier.v"
        ).read_text(encoding="utf-8")

        self.assertIn("module kv_commit_copier", copier_text)
        self.assertIn("kv_commit_copier", top_text)
        self.assertIn("u_tree_parallel_kv_commit_copier", top_text)
        self.assertIn("tree_parallel_kv_commit_start_w", top_text)
        self.assertIn("tree_parallel_kv_commit_done_w", top_text)
        self.assertIn("tree_parallel_kv_commit_busy_w", top_text)
        self.assertIn("tree_parallel_kv_commit_slots_w", top_text)
        self.assertIn("tree_parallel_kv_commit_positions_w", top_text)
        self.assertIn("use_tree_parallel_kv_commit_req_w", top_text)
        self.assertIn("tree_parallel_kv_commit_sram_rd_valid_w", top_text)
        self.assertIn("tree_parallel_kv_commit_sram_wr_valid_w", top_text)
        self.assertIn("tree_parallel_kv_commit_resp_select_w", top_text)
        self.assertIn(
            "tree_parallel_commit_pending_r ||\n"
            "    tree_parallel_commit_replay_active_r ||\n"
            "    tree_parallel_kv_commit_busy_w ||",
            top_text,
        )

    def test_tree_parallel_kv_commit_copier_carries_layer_dimension(self) -> None:
        copier_text = (
            REPO_ROOT
            / "code"
            / "rtl"
            / "tree_control"
            / "kv_commit_copier.v"
        ).read_text(encoding="utf-8")

        self.assertIn("parameter integer N_LAYERS", copier_text)
        self.assertIn("parameter integer KV_LAYER_STRIDE", copier_text)
        self.assertIn("parameter integer DATA_BUS_W", copier_text)
        self.assertIn("parameter integer HEAD_DIM", copier_text)
        self.assertIn("parameter integer DATA_WIDTH", copier_text)
        self.assertIn("parameter integer ELEMS_PER_BEAT", copier_text)
        self.assertIn("logic [7:0]             layer_cnt", copier_text)
        self.assertIn("layer_base_offset", copier_text)
        self.assertIn("layer_cnt} * KV_LAYER_STRIDE", copier_text)
        self.assertIn("parameter integer HEAD_BEATS = HEAD_DIM / ELEMS_PER_BEAT", copier_text)
        self.assertIn("layer_cnt == N_LAYERS - 1", copier_text)
        self.assertIn("slot_cnt == lat_depth - 3'd1", copier_text)

    def test_tree_parallel_dispatcher_carries_real_node_parent_topology(self) -> None:
        control_text = (
            REPO_ROOT
            / "code"
            / "rtl"
            / "tree_control"
            / "control_chip_stage2_single_chiplet.v"
        ).read_text(encoding="utf-8")
        dispatcher_text = (
            REPO_ROOT
            / "code"
            / "rtl"
            / "transformer"
            / "tree_verify_dispatcher.sv"
        ).read_text(encoding="utf-8")
        flatten_text = (
            REPO_ROOT
            / "code"
            / "rtl"
            / "tree_control"
            / "tree_flatten.v"
        ).read_text(encoding="utf-8")

        self.assertIn("tree_parallel_branch_node_ids_w", control_text)
        self.assertIn("tree_parallel_branch_parent_node_ids_w", control_text)
        self.assertIn(".branch_node_ids(tree_parallel_branch_node_ids_w)", control_text)
        self.assertIn(
            ".branch_parent_node_ids(tree_parallel_branch_parent_node_ids_w)",
            control_text,
        )
        self.assertIn("input  logic [BRANCH_NUM*MAX_LEVELS*`NODE_ID_W-1:0] branch_node_ids", dispatcher_text)
        self.assertIn(
            "input  logic [BRANCH_NUM*MAX_LEVELS*`NODE_ID_W-1:0] branch_parent_node_ids",
            dispatcher_text,
        )
        self.assertIn("lat_branch_node_ids", dispatcher_text)
        self.assertIn("lat_branch_parent_node_ids", dispatcher_text)
        self.assertIn(".branch_node_ids(lat_branch_node_ids)", dispatcher_text)
        self.assertIn(".branch_parent_node_ids(lat_branch_parent_node_ids)", dispatcher_text)
        self.assertNotIn("branch_parent_slot", dispatcher_text)
        self.assertIn("input  wire [BRANCH_NUM*MAX_LEVELS*NODE_ID_W-1:0]    branch_node_ids", flatten_text)
        self.assertIn(
            "input  wire [BRANCH_NUM*MAX_LEVELS*NODE_ID_W-1:0]    branch_parent_node_ids",
            flatten_text,
        )
        self.assertNotIn("branch_parent_slot", flatten_text)
        self.assertNotIn("if (l == 0)\n                        cur_parent_slot = {SLOT_ID_W{1'b0}};", flatten_text)
        self.assertNotIn("tree_parallel_branch_parent_slot_w", control_text)

    def test_tree_parallel_batch_attention_uses_weight_addrs_in_real_compute_path(self) -> None:
        attn_text = (
            REPO_ROOT
            / "code"
            / "rtl"
            / "transformer"
            / "fp16_mha_tree_attention.sv"
        ).read_text(encoding="utf-8")

        self.assertIn("issue_wq_addr", attn_text)
        self.assertIn("issue_wk_addr", attn_text)
        self.assertIn("issue_wv_addr", attn_text)
        self.assertIn("issue_wo_addr", attn_text)
        self.assertIn("wq_addr_r <= issue_wq_addr", attn_text)
        self.assertIn("wk_addr_r <= issue_wk_addr", attn_text)
        self.assertIn("wv_addr_r <= issue_wv_addr", attn_text)
        self.assertIn("wo_addr_r <= issue_wo_addr", attn_text)
        self.assertNotIn("synthesized_token_w =", attn_text)
        self.assertNotIn("write_hidden_word_w =", attn_text)

    def test_tree_parallel_batch_attention_is_not_placeholder_token_formula(self) -> None:
        attn_text = (
            REPO_ROOT
            / "code"
            / "rtl"
            / "transformer"
            / "fp16_mha_tree_attention.sv"
        ).read_text(encoding="utf-8")

        self.assertIn("KV_COMMITTED_BASE", attn_text)
        self.assertIn("KV_DRAFT_BASE", attn_text)
        self.assertIn("issue_prefix_len", attn_text)
        self.assertIn("issue_slot_is_seed", attn_text)
        self.assertIn("issue_seed_kv_valid", attn_text)
        self.assertIn("sram_rd_valid", attn_text)
        self.assertIn("sram_resp_valid", attn_text)
        self.assertIn("sram_wr_valid", attn_text)
        self.assertIn("slot_is_seed_r", attn_text)
        self.assertNotIn("visible_count_w", attn_text)
        self.assertNotIn("next_token_w =", attn_text)
        self.assertNotIn("slot_token_w +", attn_text)
        self.assertNotIn("prefix_len_r +", attn_text)
        self.assertNotIn("slot_position_w +", attn_text)

    def test_tree_parallel_batch_attention_has_committed_prefix_and_draft_window_phases(self) -> None:
        attn_text = (
            REPO_ROOT
            / "code"
            / "rtl"
            / "transformer"
            / "fp16_mha_tree_attention.sv"
        ).read_text(encoding="utf-8")
        controller_text = (
            REPO_ROOT
            / "code"
            / "rtl"
            / "transformer"
            / "fp16_mha_controller.sv"
        ).read_text(encoding="utf-8")

        self.assertIn("layer_kv_committed_base_w", attn_text)
        self.assertIn("layer_kv_draft_base_w", attn_text)
        self.assertIn("seed_visible_row_w", attn_text)
        self.assertIn(".issue_tree_batch_en(1'b1)", attn_text)
        self.assertIn("tree_ctx_is_committed_w", controller_text)
        self.assertIn("tree_ctx_slot_idx_u16_w", controller_text)
        self.assertIn("tree_ctx_is_committed_w", controller_text)
        self.assertIn("kv_tree_hist_committed_k_base_w", controller_text)
        self.assertIn("kv_tree_hist_draft_k_base_w", controller_text)
        self.assertIn("tree_visible_slots_r", controller_text)
        self.assertIn("issue_tree_slot_count", controller_text)

    def test_tree_parallel_mha_controller_skips_invisible_and_seed_duplicate_draft_slots(self) -> None:
        controller_text = (
            REPO_ROOT
            / "code"
            / "rtl"
            / "transformer"
            / "fp16_mha_controller.sv"
        ).read_text(encoding="utf-8")

        self.assertIn("tree_query_needs_kv_w", controller_text)
        self.assertIn("tree_dot_needs_read_w", controller_text)
        self.assertIn("tree_wv_needs_read_w", controller_text)
        self.assertIn("tree_softmax_skip_w", controller_text)
        self.assertIn("if (tree_batch_en_r && !tree_query_needs_kv_w)", controller_text)
        self.assertIn("if (tree_batch_en_r && !tree_dot_needs_read_w)", controller_text)
        self.assertIn("if (tree_batch_en_r && !tree_softmax_skip_w)", controller_text)
        self.assertIn("if (tree_batch_en_r && !tree_wv_needs_read_w)", controller_text)

    def test_tree_parallel_batch_attention_runs_full_layer_phases_across_slots(self) -> None:
        attn_text = (
            REPO_ROOT
            / "code"
            / "rtl"
            / "transformer"
            / "fp16_mha_tree_attention.sv"
        ).read_text(encoding="utf-8")

        self.assertIn('`include "transformer/fp16_rmsnorm.sv"', attn_text)
        self.assertIn('`include "transformer/fp16_mha_controller.sv"', attn_text)
        self.assertIn('`include "transformer/fp16_residual_add.sv"', attn_text)
        self.assertIn('`include "transformer/fp16_ffn_swiglu.sv"', attn_text)
        self.assertIn("issue_pre_norm_gamma_addr", attn_text)
        self.assertIn("issue_post_norm_gamma_addr", attn_text)
        self.assertIn("issue_gate_w_addr", attn_text)
        self.assertIn("issue_up_w_addr", attn_text)
        self.assertIn("issue_down_w_addr", attn_text)
        self.assertIn("issue_scratch_base_addr", attn_text)
        self.assertIn("ST_PRE_ISSUE", attn_text)
        self.assertIn("ST_MHA_ISSUE", attn_text)
        self.assertIn("ST_RES1_SEED_ISSUE", attn_text)
        self.assertIn("ST_POST_SEED_ISSUE", attn_text)
        self.assertIn("ST_FFN_SEED_ISSUE", attn_text)
        self.assertIn("ST_RES2_SEED_ISSUE", attn_text)
        self.assertIn("ST_RES1_DRAFT_ISSUE", attn_text)
        self.assertIn("ST_POST_DRAFT_ISSUE", attn_text)
        self.assertIn("ST_FFN_DRAFT_ISSUE", attn_text)
        self.assertIn("ST_RES2_DRAFT_ISSUE", attn_text)
        self.assertIn("draft_slot_scratch_base_w", attn_text)
        self.assertIn("fp16_rmsnorm #(", attn_text)
        self.assertIn("fp16_mha_controller #(", attn_text)
        self.assertIn("fp16_residual_add #(", attn_text)
        self.assertIn("fp16_ffn_swiglu #(", attn_text)
        self.assertIn(".issue_tree_batch_en(1'b1)", attn_text)
        self.assertIn(".issue_tree_draft_kv_base(layer_kv_draft_base_w)", attn_text)
        self.assertIn('.issue_tree_query_slot({SLOT_ID_W{1\'b0}})', attn_text)
        self.assertIn(".issue_tree_visible_slots(seed_visible_row_w)", attn_text)
        self.assertNotIn("fp16_transformer_layer #(", attn_text)

    def test_tree_parallel_batch_path_embeds_slots_before_tree_attention(self) -> None:
        top_text = (
            REPO_ROOT
            / "code"
            / "rtl"
            / "transformer"
            / "fp16_inference_top.sv"
        ).read_text(encoding="utf-8")

        self.assertIn("ST_BATCH_EMBED_ISSUE", top_text)
        self.assertIn("ST_BATCH_EMBED_WAIT", top_text)
        self.assertIn("batch_embed_slot_idx_r", top_text)
        self.assertIn("state_r == ST_BATCH_EMBED_ISSUE", top_text)
        self.assertIn("state_r == ST_BATCH_EMBED_WAIT", top_text)
        self.assertIn(".issue_input_base_addr(batch_layer_input_base_w)", top_text)
        self.assertNotIn(".issue_input_base_addr(WORK_FINAL_BASE)", top_text)

    def test_tree_parallel_batch_attention_reads_slot_input_workspace(self) -> None:
        attn_text = (
            REPO_ROOT
            / "code"
            / "rtl"
            / "transformer"
            / "fp16_mha_tree_attention.sv"
        ).read_text(encoding="utf-8")

        self.assertIn("pre_slot_input_addr_w", attn_text)
        self.assertIn("input_base_addr_r", attn_text)
        self.assertIn(".issue_x_addr(pre_slot_input_addr_w)", attn_text)
        self.assertIn("wire [ADDR_W-1:0] seed_input_addr_w = seed_pre_norm_out_base_w;", attn_text)
        self.assertIn(".issue_input_addr(seed_input_addr_w)", attn_text)
        self.assertIn("localparam logic [4:0] ST_ISSUE = ST_PRE_ISSUE;", attn_text)

    def test_tree_parallel_batch_attention_uses_hidden_workspace_stride_and_not_token_formula(self) -> None:
        attn_text = (
            REPO_ROOT
            / "code"
            / "rtl"
            / "transformer"
            / "fp16_mha_tree_attention.sv"
        ).read_text(encoding="utf-8")

        self.assertIn("HIDDEN_BEATS", attn_text)
        self.assertIn("addr_from_u32(pre_slot_idx_r * HIDDEN_BEATS)", attn_text)
        self.assertNotIn("{16'd0, cur_slot_token_w} +", attn_text)
        self.assertNotIn("{16'd0, cur_slot_position_w} +", attn_text)
        self.assertNotIn("{16'd0, prefix_len_r} +", attn_text)

    def test_tree_parallel_batch_top_uses_real_model_cfg_addresses_not_zero(self) -> None:
        top_text = (
            REPO_ROOT
            / "code"
            / "rtl"
            / "tree_control"
            / "control_chip_stage2_single_chiplet.v"
        ).read_text(encoding="utf-8")

        self.assertIn(".cfg_embedding_base(ISSUE_SRC_ADDR)", top_text)
        self.assertIn("TREE_PARALLEL_FINAL_NORM_GAMMA_ADDR", top_text)
        self.assertIn(
            ".cfg_final_norm_gamma_addr(TREE_PARALLEL_FINAL_NORM_GAMMA_ADDR)",
            top_text,
        )
        self.assertNotIn(".cfg_embedding_base({`SRAM_ADDR_W{1'b0}})", top_text)
        self.assertNotIn(
            ".cfg_final_norm_gamma_addr({`SRAM_ADDR_W{1'b0}})",
            top_text,
        )

    def test_tree_parallel_batch_path_runs_layer_loop_and_slot_postprocess(self) -> None:
        top_text = (
            REPO_ROOT
            / "code"
            / "rtl"
            / "transformer"
            / "fp16_inference_top.sv"
        ).read_text(encoding="utf-8")

        self.assertIn("ST_BATCH_LAYER_ISSUE", top_text)
        self.assertIn("ST_BATCH_LAYER_WAIT", top_text)
        self.assertIn("ST_BATCH_NORM_SEED_ISSUE", top_text)
        self.assertIn("ST_BATCH_NORM_SEED_WAIT", top_text)
        self.assertIn("ST_BATCH_NORM_DRAFT_ISSUE", top_text)
        self.assertIn("ST_BATCH_NORM_DRAFT_WAIT", top_text)
        self.assertIn("ST_BATCH_LOGITS_SEED_ISSUE", top_text)
        self.assertIn("ST_BATCH_LOGITS_SEED_WAIT", top_text)
        self.assertIn("ST_BATCH_LOGITS_DRAFT_ISSUE", top_text)
        self.assertIn("ST_BATCH_LOGITS_DRAFT_WAIT", top_text)
        self.assertIn("batch_layer_idx_r", top_text)
        self.assertIn("batch_tail_done_r", top_text)
        self.assertIn("batch_layer_input_base_w", top_text)
        self.assertIn("batch_layer_output_base_w", top_text)
        self.assertIn(".issue_valid(state_r == ST_BATCH_LAYER_ISSUE)", top_text)
        self.assertIn(".issue_layer_id(batch_layer_idx_r[4:0])", top_text)
        self.assertIn(".issue_input_base_addr(batch_layer_input_base_w)", top_text)
        self.assertIn(".issue_result_base_addr(batch_layer_output_base_w)", top_text)
        self.assertIn("wire [ADDR_W-1:0] norm_issue_x_addr_w =", top_text)
        self.assertIn("wire [ADDR_W-1:0] norm_issue_result_addr_w =", top_text)
        self.assertIn("wire [ADDR_W-1:0] lm_issue_hidden_addr_w =", top_text)
        self.assertIn(".issue_x_addr(norm_issue_x_addr_w)", top_text)
        self.assertIn(".issue_result_addr(norm_issue_result_addr_w)", top_text)
        self.assertIn(".issue_hidden_addr(lm_issue_hidden_addr_w)", top_text)
        self.assertNotIn("state_r == ST_BATCH_ISSUE", top_text)

    def test_tree_parallel_batch_attention_uses_real_weight_window_addresses(self) -> None:
        top_text = (
            REPO_ROOT
            / "code"
            / "rtl"
            / "transformer"
            / "fp16_inference_top.sv"
        ).read_text(encoding="utf-8")

        self.assertIn("wire [ADDR_W-1:0] batch_wq_addr_w =", top_text)
        self.assertIn("wire [ADDR_W-1:0] batch_wk_addr_w =", top_text)
        self.assertIn("wire [ADDR_W-1:0] batch_wv_addr_w =", top_text)
        self.assertIn("wire [ADDR_W-1:0] batch_wo_addr_w =", top_text)
        self.assertIn(".issue_wq_addr(batch_wq_addr_w)", top_text)
        self.assertIn(".issue_wk_addr(batch_wk_addr_w)", top_text)
        self.assertIn(".issue_wv_addr(batch_wv_addr_w)", top_text)
        self.assertIn(".issue_wo_addr(batch_wo_addr_w)", top_text)
        self.assertNotIn(".issue_wq_addr({ADDR_W{1'b0}})", top_text)
        self.assertNotIn(".issue_wk_addr({ADDR_W{1'b0}})", top_text)
        self.assertNotIn(".issue_wv_addr({ADDR_W{1'b0}})", top_text)
        self.assertNotIn(".issue_wo_addr({ADDR_W{1'b0}})", top_text)

    def test_tree_parallel_batch_path_preloads_layer_weights_from_hbm(self) -> None:
        top_text = (
            REPO_ROOT
            / "code"
            / "rtl"
            / "transformer"
            / "fp16_inference_top.sv"
        ).read_text(encoding="utf-8")

        self.assertIn("ST_BATCH_HBM_REQ", top_text)
        self.assertIn("ST_BATCH_HBM_RESP", top_text)
        self.assertIn("ST_BATCH_HBM_WRITE0", top_text)
        self.assertIn("ST_BATCH_HBM_WRITE1", top_text)
        self.assertIn("batch_preload_idx_r", top_text)
        self.assertIn("batch_hbm_beat_r", top_text)
        self.assertIn("batch_hbm_rd_addr_w", top_text)
        self.assertIn("batch_weight_write0_addr_w", top_text)
        self.assertIn("batch_weight_write1_addr_w", top_text)
        self.assertIn("ST_BATCH_HBM_REQ,", top_text)
        self.assertIn("ST_BATCH_HBM_RESP: begin", top_text)
        self.assertIn("ST_BATCH_HBM_WRITE0: begin", top_text)
        self.assertIn("ST_BATCH_HBM_WRITE1: begin", top_text)

    def test_tree_parallel_batch_attention_writes_hidden_workspace_vectors(self) -> None:
        attn_text = (
            REPO_ROOT
            / "code"
            / "rtl"
            / "transformer"
            / "fp16_mha_tree_attention.sv"
        ).read_text(encoding="utf-8")

        self.assertIn("issue_result_base_addr", attn_text)
        self.assertIn("result_base_addr_r", attn_text)
        self.assertIn("HIDDEN_BEATS", attn_text)
        self.assertIn("draft_slot_result_addr_w", attn_text)
        self.assertIn(".issue_result_addr(draft_slot_result_addr_w)", attn_text)
        self.assertIn("sram_wr_addr = layer_wr_addr_w;", attn_text)
        self.assertIn("sram_wr_data = layer_wr_data_w;", attn_text)
        self.assertNotIn("assign result_base_addr = input_base_addr_r;", attn_text)

    def test_stage2_30_native_tree_platform_driver_uses_real_fp16_inference_top(self) -> None:
        tb_text = (
            REPO_ROOT
            / "code"
            / "tb"
            / "tree_control_tb"
            / "tb_control_chip_stage2_single_chiplet_native_tree_main_frontend_platform_driver.v"
        ).read_text(encoding="utf-8")

        self.assertIn(".ENABLE_NATIVE_TREE_MAIN_FRONTEND(1)", tb_text)
        self.assertIn(".USE_FP16_INFERENCE_TOP(1)", tb_text)
        self.assertIn("toy_model_memh_dir_path", tb_text)
        self.assertIn("$readmemh(preload_memh_path_r", tb_text)
        self.assertIn("$readmemh(hbm_memh_path_r", tb_text)
        self.assertIn("storage_bytes", tb_text)

    def test_stage2_30_native_tree_platform_driver_advances_strict_capture_index_by_branch_slot(self) -> None:
        tb_text = (
            REPO_ROOT
            / "code"
            / "tb"
            / "tree_control_tb"
            / "tb_control_chip_stage2_single_chiplet_native_tree_main_frontend_platform_driver.v"
        ).read_text(encoding="utf-8")

        self.assertIn(
            "end else if (strict_branch_slot_r == (`BRANCH_NUM - 1)) begin",
            tb_text,
        )

    def test_stage2_30_and_31_vm_scripts_require_fp16_preload_assets(self) -> None:
        script_paths = [
            REPO_ROOT
            / "verification"
            / "stage2"
            / "30_vcs_control_chip_stage2_single_chiplet_real_ssd_sync_tree_step_payload_bringup"
            / "scripts"
            / "run_tb_control_chip_stage2_single_chiplet_real_ssd_sync_tree_step_payload_vm_prepared.sh",
            REPO_ROOT
            / "verification"
            / "stage2"
            / "31_vcs_control_chip_stage2_single_chiplet_ssd_sync_runtime_loop_bringup"
            / "scripts"
            / "run_tb_control_chip_stage2_single_chiplet_ssd_sync_runtime_loop_vm_prepared.sh",
        ]

        for script_path in script_paths:
            text = script_path.read_text(encoding="utf-8")
            self.assertIn("sram_preload.memh", text, msg=str(script_path))
            self.assertIn("hbm_weights.memh", text, msg=str(script_path))
            self.assertIn("+toy_model_memh_dir=", text, msg=str(script_path))

    def test_common_vcs_uses_short_tb_workdir_paths(self) -> None:
        script_path = (
            REPO_ROOT
            / "verification"
            / "stage2"
            / "30_vcs_control_chip_stage2_single_chiplet_real_ssd_sync_tree_step_payload_bringup"
            / "scripts"
            / "common_vcs.sh"
        )
        text = script_path.read_text(encoding="utf-8")
        self.assertIn('tb_name_short="$(printf \'%s\' "${tb_name}" | md5sum', text)
        self.assertIn('local_tb_root="${VCS_WORK_ROOT}/${RUN_NAME_SHORT}"', text)
        self.assertIn('tb_workdir="${local_tb_root}/${tb_name_short}"', text)
        self.assertIn('csrc_dir="${tb_workdir}/csrc"', text)

    def test_host_vm_flow_scripts_exist_for_single_step_and_runtime_loop(self) -> None:
        runtime_init_text = (
            REPO_ROOT / "code" / "script" / "rtl_runtime" / "__init__.py"
        ).read_text(encoding="utf-8")
        self.assertIn("prepare_single_step_workdir", runtime_init_text)
        self.assertIn("collect_single_step_workdir", runtime_init_text)
        self.assertIn("prepare_runtime_loop_trace_workdir", runtime_init_text)
        self.assertIn("collect_runtime_loop_trace_workdir", runtime_init_text)

        single_prepare = (
            REPO_ROOT
            / "verification"
            / "stage2"
            / "30_vcs_control_chip_stage2_single_chiplet_real_ssd_sync_tree_step_payload_bringup"
            / "scripts"
            / "host_prepare_sync_tree_step.ps1"
        )
        single_collect = (
            REPO_ROOT
            / "verification"
            / "stage2"
            / "30_vcs_control_chip_stage2_single_chiplet_real_ssd_sync_tree_step_payload_bringup"
            / "scripts"
            / "host_collect_sync_tree_step.ps1"
        )
        single_vm = (
            REPO_ROOT
            / "verification"
            / "stage2"
            / "30_vcs_control_chip_stage2_single_chiplet_real_ssd_sync_tree_step_payload_bringup"
            / "scripts"
            / "run_tb_control_chip_stage2_single_chiplet_real_ssd_sync_tree_step_payload_vm_prepared.sh"
        )
        runtime_prepare = (
            REPO_ROOT
            / "verification"
            / "stage2"
            / "31_vcs_control_chip_stage2_single_chiplet_ssd_sync_runtime_loop_bringup"
            / "scripts"
            / "host_prepare_runtime_loop_2step.ps1"
        )
        runtime_collect = (
            REPO_ROOT
            / "verification"
            / "stage2"
            / "31_vcs_control_chip_stage2_single_chiplet_ssd_sync_runtime_loop_bringup"
            / "scripts"
            / "host_collect_runtime_loop_2step.ps1"
        )
        runtime_vm = (
            REPO_ROOT
            / "verification"
            / "stage2"
            / "31_vcs_control_chip_stage2_single_chiplet_ssd_sync_runtime_loop_bringup"
            / "scripts"
            / "run_tb_control_chip_stage2_single_chiplet_ssd_sync_runtime_loop_vm_prepared.sh"
        )

        self.assertTrue(single_prepare.exists())
        self.assertTrue(single_collect.exists())
        self.assertTrue(single_vm.exists())
        self.assertTrue(runtime_prepare.exists())
        self.assertTrue(runtime_collect.exists())
        self.assertTrue(runtime_vm.exists())

        self.assertIn("prepare_single_step_workdir", single_prepare.read_text(encoding="utf-8"))
        self.assertIn("collect_single_step_workdir", single_collect.read_text(encoding="utf-8"))
        self.assertIn("run_vcs_testbench", single_vm.read_text(encoding="utf-8"))
        self.assertIn("prepare_runtime_loop_trace_workdir", runtime_prepare.read_text(encoding="utf-8"))
        self.assertIn("collect_runtime_loop_trace_workdir", runtime_collect.read_text(encoding="utf-8"))
        self.assertIn("run_tb_control_chip_stage2_single_chiplet_real_ssd_sync_tree_step_payload_vm_prepared.sh", runtime_vm.read_text(encoding="utf-8"))

    def test_stage2_scripts_that_compile_single_chiplet_top_include_comparator_dependency(self) -> None:
        stage2_root = REPO_ROOT / "verification" / "stage2"
        missing = []
        for script_path in stage2_root.rglob("*.sh"):
            text = script_path.read_text(encoding="utf-8")
            if "code/rtl/tree_control/control_chip_stage2_single_chiplet.v" not in text:
                continue
            if "code/rtl/tree_control/comparator.v" in text:
                continue
            missing.append(str(script_path))

        self.assertEqual([], missing)

    def test_stage30_single_step_scripts_use_stimulus_memh_line_count(self) -> None:
        script_paths = [
            REPO_ROOT
            / "verification"
            / "stage2"
            / "30_vcs_control_chip_stage2_single_chiplet_real_ssd_sync_tree_step_payload_bringup"
            / "scripts"
            / "run_tb_control_chip_stage2_single_chiplet_real_ssd_sync_tree_step_payload_bringup.sh",
            REPO_ROOT
            / "verification"
            / "stage2"
            / "30_vcs_control_chip_stage2_single_chiplet_real_ssd_sync_tree_step_payload_bringup"
            / "scripts"
            / "run_tb_control_chip_stage2_single_chiplet_real_ssd_sync_tree_step_payload_vm_prepared.sh",
        ]

        for script_path in script_paths:
            text = script_path.read_text(encoding="utf-8")
            self.assertIn('wc -l < "${STIMULUS_MEMH}"', text, msg=str(script_path))

    def test_host_vm_powershell_scripts_avoid_python_dash_c_windows_path_quoting(self) -> None:
        script_paths = [
            REPO_ROOT
            / "verification"
            / "stage2"
            / "30_vcs_control_chip_stage2_single_chiplet_real_ssd_sync_tree_step_payload_bringup"
            / "scripts"
            / "host_prepare_sync_tree_step.ps1",
            REPO_ROOT
            / "verification"
            / "stage2"
            / "30_vcs_control_chip_stage2_single_chiplet_real_ssd_sync_tree_step_payload_bringup"
            / "scripts"
            / "host_collect_sync_tree_step.ps1",
            REPO_ROOT
            / "verification"
            / "stage2"
            / "31_vcs_control_chip_stage2_single_chiplet_ssd_sync_runtime_loop_bringup"
            / "scripts"
            / "host_prepare_runtime_loop_2step.ps1",
            REPO_ROOT
            / "verification"
            / "stage2"
            / "31_vcs_control_chip_stage2_single_chiplet_ssd_sync_runtime_loop_bringup"
            / "scripts"
            / "host_collect_runtime_loop_2step.ps1",
        ]

        for script_path in script_paths:
            text = script_path.read_text(encoding="utf-8")
            self.assertNotIn(" -c @\"", text)
            self.assertIn("| py -3 -", text) if "py -3" in text else self.assertIn("| python -", text)


if __name__ == "__main__":
    unittest.main()
