import sys
import tempfile
import unittest
from unittest import mock
from pathlib import Path


SCRIPT_ROOT = Path(__file__).resolve().parents[2]
if str(SCRIPT_ROOT) not in sys.path:
    sys.path.insert(0, str(SCRIPT_ROOT))


from rtl_backend.rtl_driver import (  # type: ignore
    build_single_chiplet_demo_artifacts,
    materialize_hbm_output_from_events,
)
from rtl_backend.ssd_step import sync_tree_step_like_to_payload  # type: ignore
from rtl_backend.stimulus import StimulusCycle  # type: ignore


class RtlDriverTest(unittest.TestCase):
    def test_native_tree_visible_mask_generation_does_not_import_toy_model_reference(self) -> None:
        from rtl_backend import rtl_driver as rtl_driver_module  # type: ignore

        original_import = __import__

        def guarded_import(name, globals=None, locals=None, fromlist=(), level=0):
            if name == "toy_model.toy_model_reference":
                raise AssertionError("unexpected toy_model_reference import")
            if name == "toy_model" and fromlist and "toy_model_reference" in fromlist:
                raise AssertionError("unexpected toy_model_reference import")
            return original_import(name, globals, locals, fromlist, level)

        request = rtl_driver_module._build_default_native_tree_request()
        with mock.patch("builtins.__import__", side_effect=guarded_import):
            visible_mask = rtl_driver_module._first_native_tree_visible_mask(request)
        self.assertEqual(visible_mask, 0b00000111)

    def test_native_tree_visible_mask_generation_uses_frontier_position_ids(self) -> None:
        from rtl_backend import rtl_driver as rtl_driver_module  # type: ignore
        from rtl_backend.stimulus import NativeTreeRequest  # type: ignore

        request = NativeTreeRequest(
            valid=True,
            req_id=1,
            prefix_slot_valid=0b0011,
            prefix_node_ids=[1, 2],
            prefix_token_ids=[0x10, 0x11],
            prefix_position_ids=[0, 1],
            frontier_level_valid=0b0011,
            frontier_slot_valid_by_level=[0b0001, 0b0001],
            frontier_tree_mask_en_by_level=[0b0001, 0b0001],
            frontier_node_ids_by_level=[
                [13, 0, 0, 0],
                [11, 0, 0, 0],
            ],
            frontier_parent_node_ids_by_level=[
                [11, 0, 0, 0],
                [2, 0, 0, 0],
            ],
            frontier_token_ids_by_level=[
                [0x21, 0, 0, 0],
                [0x20, 0, 0, 0],
            ],
            frontier_referenced_token_ids_by_level=[
                [0x20, 0, 0, 0],
                [0x11, 0, 0, 0],
            ],
            frontier_position_ids_by_level=[
                [6, 0, 0, 0],
                [4, 0, 0, 0],
            ],
            frontier_referenced_position_ids_by_level=[
                [4, 0, 0, 0],
                [1, 0, 0, 0],
            ],
        )

        visible_mask = rtl_driver_module._first_native_tree_visible_mask(request)
        self.assertEqual(visible_mask, 0b01010011)

    def test_sync_tree_step_visible_mask_includes_recovery_position_for_empty_prompt(self) -> None:
        from rtl_backend import rtl_driver as rtl_driver_module  # type: ignore

        payload = sync_tree_step_like_to_payload(
            {
                "sequence_id": "tree-seq-empty-0",
                "prompt_token_ids": [],
                "step_index": 0,
                "recovery_token": 0x00,
                "speculated_tokens": [[0x0E]],
                "accepted_tokens": [0x00, 0x0E],
                "next_recovery_token": 0x0E,
                "tree_mask_en": False,
                "metadata": {"tree_projection_mode": "accepted_path"},
            }
        )

        visible_mask = rtl_driver_module._first_native_tree_visible_mask(
            payload.native_tree_request
        )
        self.assertEqual(visible_mask, 0b00000011)

    def test_sync_tree_step_visible_mask_keeps_recovery_between_prefix_and_frontier(self) -> None:
        from rtl_backend import rtl_driver as rtl_driver_module  # type: ignore

        payload = sync_tree_step_like_to_payload(
            {
                "sequence_id": "tree-seq-0",
                "prompt_token_ids": [0x10, 0x11],
                "step_index": 2,
                "recovery_token": 0x12,
                "speculated_tokens": [
                    [0x21, 0x31, 0x41],
                    [0x22, 0x32],
                    [0x23],
                    [0x24, 0x34],
                ],
                "accepted_tokens": [0x12, 0x21],
                "next_recovery_token": 0x30,
                "tree_parent_map": {
                    "3": 2,
                    "4": 2,
                    "5": 2,
                    "6": 2,
                    "7": 3,
                    "8": 4,
                    "9": 6,
                    "10": 7,
                },
                "shared_prefix_nodes": [2],
            }
        )

        visible_mask = rtl_driver_module._first_native_tree_visible_mask(
            payload.native_tree_request
        )
        self.assertEqual(visible_mask, 0b00001111)

    def test_native_tree_demo_stimulus_uses_six_frontier_levels_and_visible_mask(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            workdir = Path(tmpdir) / "demo_tree_mask"
            build_single_chiplet_demo_artifacts(
                workdir,
                prompt_tokens=[0x10, 0x11],
                include_native_tree=True,
            )

            stimulus_lines = (
                workdir / "stimulus" / "stimulus.memh"
            ).read_text(encoding="utf-8").splitlines()
            decoded_cycles = [StimulusCycle.from_memh_word(line) for line in stimulus_lines]
            native_cycles = [
                cycle for cycle in decoded_cycles if cycle.native_tree_request.valid
            ]
            self.assertTrue(native_cycles)
            request = native_cycles[0].native_tree_request
            self.assertEqual(len(request.frontier_slot_valid_by_level), 6)
            self.assertEqual(len(request.frontier_node_ids_by_level), 6)
            self.assertEqual(len(request.frontier_parent_node_ids_by_level), 6)
            self.assertEqual(len(request.frontier_token_ids_by_level), 6)
            self.assertEqual(len(request.frontier_position_ids_by_level), 6)
            self.assertNotEqual(native_cycles[0].visible_mask, 0)

    def test_sync_tree_step_demo_stimulus_emits_nonzero_visible_mask(self) -> None:
        from rtl_backend.ssd_bridge import build_demo_artifacts_from_sync_tree_step  # type: ignore

        with tempfile.TemporaryDirectory() as tmpdir:
            workdir = Path(tmpdir) / "sync_tree_tree_mask"
            build_demo_artifacts_from_sync_tree_step(
                workdir=workdir,
                step_payload_like={
                    "sequence_id": "tree-seq-0",
                    "prompt_token_ids": [0x10, 0x11],
                    "step_index": 2,
                    "recovery_token": 0x12,
                    "speculated_tokens": [
                        [0x21, 0x31, 0x41],
                        [0x22, 0x32],
                        [0x23],
                        [0x24, 0x34],
                    ],
                    "accepted_tokens": [0x12, 0x21],
                    "next_recovery_token": 0x30,
                    "tree_parent_map": {
                        "3": 2,
                        "4": 2,
                        "5": 2,
                        "6": 2,
                        "7": 3,
                        "8": 4,
                        "9": 6,
                        "10": 7,
                    },
                    "shared_prefix_nodes": [2],
                },
            )

            stimulus_lines = (
                workdir / "stimulus" / "stimulus.memh"
            ).read_text(encoding="utf-8").splitlines()
            decoded_cycles = [StimulusCycle.from_memh_word(line) for line in stimulus_lines]
            native_cycles = [
                cycle for cycle in decoded_cycles if cycle.native_tree_request.valid
            ]
            self.assertTrue(native_cycles)
            self.assertNotEqual(native_cycles[0].visible_mask, 0)
            native_cycle_index = decoded_cycles.index(native_cycles[0])
            self.assertEqual(decoded_cycles[0].cfg_data, 3)
            self.assertEqual(native_cycle_index, 3)

    def test_sync_tree_step_demo_stimulus_prefills_committed_context_before_native_tree(self) -> None:
        from rtl_backend.ssd_bridge import build_demo_artifacts_from_sync_tree_step  # type: ignore

        with tempfile.TemporaryDirectory() as tmpdir:
            workdir = Path(tmpdir) / "sync_tree_committed_prefill"
            build_demo_artifacts_from_sync_tree_step(
                workdir=workdir,
                step_payload_like={
                    "sequence_id": "tree-mask-e2e-strict-2",
                    "prompt_token_ids": [0x00, 0x0E],
                    "step_index": 2,
                    "recovery_token": 0x0E,
                    "speculated_tokens": [
                        [0x0E, 0x02, 0x03, 0x04],
                        [0x0F, 0x03, 0x04, 0x05],
                        [0x00, 0x04, 0x05, 0x06],
                        [0x01, 0x05, 0x06, 0x07],
                    ],
                    "accepted_tokens": [0x0E, 0x0E],
                    "next_recovery_token": 0x0E,
                    "metadata": {"tree_projection_mode": "accepted_path"},
                },
            )

            stimulus_lines = (
                workdir / "stimulus" / "stimulus.memh"
            ).read_text(encoding="utf-8").splitlines()
            decoded_cycles = [StimulusCycle.from_memh_word(line) for line in stimulus_lines]
            native_cycles = [
                cycle for cycle in decoded_cycles if cycle.native_tree_request.valid
            ]
            self.assertTrue(native_cycles)
            native_cycle_index = decoded_cycles.index(native_cycles[0])
            self.assertEqual(native_cycle_index, 3)

            prefill_cycles = decoded_cycles[1:native_cycle_index]
            self.assertEqual(len(prefill_cycles), 2)
            self.assertEqual(
                [
                    [candidate.token_id for candidate in cycle.draft_candidates if candidate.valid]
                    for cycle in prefill_cycles
                ],
                [[0x0E], [0x0E]],
            )
            self.assertEqual(
                [
                    [
                        candidate.referenced_position
                        for candidate in cycle.draft_candidates
                        if candidate.valid
                    ]
                    for cycle in prefill_cycles
                ],
                [[0], [1]],
            )
            self.assertTrue(
                all(
                    cycle.recompute_response.valid and cycle.recompute_response.full
                    for cycle in prefill_cycles
                )
            )

    def test_sync_tree_step_demo_preloads_committed_kv_cache_for_deep_prefix(self) -> None:
        from rtl_backend.ssd_bridge import build_demo_artifacts_from_sync_tree_step  # type: ignore
        from toy_model.toy_model_reference import (  # type: ignore
            ELEMS_PER_SRAM_BEAT,
            HEAD_DIM,
            NUM_HEADS,
            build_weights,
            pack_sram_beat,
            run_reference,
        )

        committed_context_tokens = [0x00, 0x0E, 0x0E, 0x0E]
        kv_committed_base = 49152
        kv_layer_stride = 4096
        head_beats = HEAD_DIM // ELEMS_PER_SRAM_BEAT

        with tempfile.TemporaryDirectory() as tmpdir:
            workdir = Path(tmpdir) / "sync_tree_committed_kv_preload"
            build_demo_artifacts_from_sync_tree_step(
                workdir=workdir,
                step_payload_like={
                    "sequence_id": "tree-mask-e2e-strict-3",
                    "prompt_token_ids": committed_context_tokens[:-1],
                    "step_index": 3,
                    "recovery_token": committed_context_tokens[-1],
                    "speculated_tokens": [[0x0E]],
                    "accepted_tokens": [0x0E, 0x0E],
                    "next_recovery_token": 0x0E,
                    "metadata": {"tree_projection_mode": "accepted_path"},
                },
            )

            preload_lines = (
                workdir / "weights" / "toy_model_fp16" / "sram_preload.memh"
            ).read_text(encoding="ascii").splitlines()

            weights = build_weights()
            kv_cache_k = None
            kv_cache_v = None
            for position, token_id in enumerate(committed_context_tokens):
                _, kv_cache_k, kv_cache_v = run_reference(
                    weights=weights,
                    token_id=int(token_id),
                    position=position,
                    kv_cache_k=kv_cache_k,
                    kv_cache_v=kv_cache_v,
                )

            target_layer = 0
            target_position = 3
            target_head = 1
            position_base = (
                kv_committed_base
                + (target_layer * kv_layer_stride)
                + (target_position * NUM_HEADS * head_beats * 2)
            )
            k_addr = position_base + (target_head * head_beats)
            v_addr = position_base + (NUM_HEADS * head_beats) + (target_head * head_beats)
            expected_k = pack_sram_beat(
                kv_cache_k[target_layer, target_position, target_head, 0:ELEMS_PER_SRAM_BEAT]
            )
            expected_v = pack_sram_beat(
                kv_cache_v[target_layer, target_position, target_head, 0:ELEMS_PER_SRAM_BEAT]
            )

            self.assertEqual(preload_lines[k_addr], expected_k)
            self.assertEqual(preload_lines[v_addr], expected_v)

    def test_sync_tree_step_single_branch_does_not_preload_committed_kv_cache(self) -> None:
        from rtl_backend.rtl_driver import build_single_chiplet_demo_artifacts  # type: ignore
        from rtl_backend.ssd_bridge import build_demo_artifacts_from_sync_tree_step  # type: ignore

        with tempfile.TemporaryDirectory() as tmpdir:
            workdir = Path(tmpdir) / "sync_tree_single_branch_no_committed_kv_preload"
            baseline_workdir = Path(tmpdir) / "sync_tree_single_branch_baseline"
            build_demo_artifacts_from_sync_tree_step(
                workdir=workdir,
                step_payload_like={
                    "sequence_id": "tree-mask-e2e-strict-1",
                    "prompt_token_ids": [0x00],
                    "step_index": 1,
                    "recovery_token": 0x0E,
                    "speculated_tokens": [[0x0E]],
                    "accepted_tokens": [0x0E, 0x0E],
                    "next_recovery_token": 0x0E,
                    "tree_mask_en": False,
                    "metadata": {"tree_projection_mode": "accepted_path"},
                },
            )
            build_single_chiplet_demo_artifacts(
                workdir=baseline_workdir,
                prompt_tokens=[0x00, 0x0E],
                include_native_tree=True,
                enable_demo_draft_candidates=False,
            )

            preload_text = (
                workdir / "weights" / "toy_model_fp16" / "sram_preload.memh"
            ).read_text(encoding="ascii")
            baseline_preload_text = (
                baseline_workdir / "weights" / "toy_model_fp16" / "sram_preload.memh"
            ).read_text(encoding="ascii")

            self.assertEqual(preload_text, baseline_preload_text)

    def test_sync_tree_step_with_empty_prompt_still_emits_native_tree_cycle(self) -> None:
        from rtl_backend.ssd_bridge import build_demo_artifacts_from_sync_tree_step  # type: ignore

        with tempfile.TemporaryDirectory() as tmpdir:
            workdir = Path(tmpdir) / "sync_tree_empty_prompt"
            build_demo_artifacts_from_sync_tree_step(
                workdir=workdir,
                step_payload_like={
                    "sequence_id": "tree-seq-empty-0",
                    "prompt_token_ids": [],
                    "step_index": 0,
                    "recovery_token": 0x00,
                    "speculated_tokens": [[0x0E]],
                    "accepted_tokens": [0x00, 0x0E],
                    "next_recovery_token": 0x0E,
                    "tree_mask_en": False,
                    "metadata": {"tree_projection_mode": "accepted_path"},
                },
            )

            stimulus_lines = (
                workdir / "stimulus" / "stimulus.memh"
            ).read_text(encoding="utf-8").splitlines()
            decoded_cycles = [StimulusCycle.from_memh_word(line) for line in stimulus_lines]
            native_cycles = [
                cycle for cycle in decoded_cycles if cycle.native_tree_request.valid
            ]
            self.assertTrue(native_cycles)
            self.assertEqual(native_cycles[0].native_tree_request.req_id, 0x1)
            self.assertEqual(native_cycles[0].native_tree_request.prefix_slot_valid, 0)
            self.assertEqual(
                native_cycles[0].native_tree_request.frontier_tree_mask_en_by_level[0],
                0,
            )
            self.assertEqual(
                native_cycles[0].native_tree_request.frontier_parent_node_ids_by_level[0][0],
                0,
            )
            self.assertGreater(len(decoded_cycles), 2)
            self.assertTrue(
                any(cycle.recompute_response.valid for cycle in decoded_cycles[2:])
            )

    def test_demo_artifacts_and_postprocess(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            workdir = Path(tmpdir) / "demo"
            build_single_chiplet_demo_artifacts(
                workdir,
                prompt_tokens=[0x10, 0x11],
                include_native_tree=True,
            )

            self.assertTrue((workdir / "stimulus" / "stimulus.memh").exists())
            self.assertTrue((workdir / "weights" / "toy_decoder" / "manifest.json").exists())
            self.assertTrue((workdir / "hbm_input" / "manifest.json").exists())
            weight_beats = (
                workdir / "hbm_input" / "regions" / "WEIGHT.jsonl"
            ).read_text(encoding="utf-8").splitlines()
            self.assertGreaterEqual(len(weight_beats), 5)

            stimulus_lines = (
                workdir / "stimulus" / "stimulus.memh"
            ).read_text(encoding="utf-8").splitlines()
            decoded_cycles = [StimulusCycle.from_memh_word(line) for line in stimulus_lines]
            native_cycles = [
                cycle for cycle in decoded_cycles if cycle.native_tree_request.valid
            ]
            self.assertTrue(native_cycles)
            self.assertEqual(native_cycles[0].native_tree_request.req_id, 0xD)
            self.assertEqual(
                native_cycles[0].native_tree_request.prefix_token_ids[:2],
                [0x10, 0x11],
            )
            self.assertEqual(
                native_cycles[0].native_tree_request.frontier_slot_valid_by_level[:2],
                [0b0011, 0b0011],
            )

            events_path = workdir / "events" / "events.jsonl"
            events_path.parent.mkdir(parents=True, exist_ok=True)
            events_path.write_text(
                '\n'.join(
                    [
                        '{"cycle":1,"event":"hbm_write","source":"rtl","addr_hex":"0x20000000","data_hex":"'
                        + ("aa" * 32)
                        + '","req_id":1}',
                        '{"cycle":2,"event":"finish","source":"rtl","busy_final":0,"error_flag":0}',
                    ]
                )
                + '\n',
                encoding="utf-8",
            )

            out_dir = workdir / "hbm_output"
            materialize_hbm_output_from_events(workdir, out_dir)
            self.assertTrue((out_dir / "manifest.json").exists())
            self.assertTrue((out_dir / "regions" / "OUTPUT.jsonl").exists())


if __name__ == "__main__":
    unittest.main()
