import json
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT_ROOT = Path(__file__).resolve().parents[2]
if str(SCRIPT_ROOT) not in sys.path:
    sys.path.insert(0, str(SCRIPT_ROOT))


from rtl_backend.toy_decoder import build_demo_toy_decoder_package  # type: ignore
from rtl_backend.stimulus import StimulusCycle  # type: ignore


try:
    from rtl_backend.ssd_bridge import save_sync_tree_step_payload  # type: ignore
    from rtl_runtime.runtime_adapter import main  # type: ignore
except ImportError as exc:  # pragma: no cover - exercised in red phase
    IMPORT_ERROR = exc
    main = None  # type: ignore
    save_sync_tree_step_payload = None  # type: ignore
else:
    IMPORT_ERROR = None


class RuntimeSyncTreeStepTest(unittest.TestCase):
    def test_runtime_adapter_symbols_for_sync_tree_step_are_available(self) -> None:
        self.assertIsNone(IMPORT_ERROR, msg=str(IMPORT_ERROR))

    @unittest.skipIf(IMPORT_ERROR is not None, "runtime sync tree step path not ready yet")
    def test_cli_prepare_and_collect_sync_tree_step_round_trip(self) -> None:
        payload_dict = {
            "sequence_id": "sync-tree-step-runtime-0",
            "prompt_token_ids": [0x10, 0x11],
            "step_index": 1,
            "recovery_token": 0x12,
            "speculated_tokens": [0x21, 0x22, 0x23],
            "accepted_tokens": [0x12, 0x21],
            "next_recovery_token": 0x30,
            "native_tree_request": {
                "valid": True,
                "req_id": 0x6,
                "prefix_slot_valid": 0b0011,
                "prefix_node_ids": [0x1, 0x2],
                "frontier_level_valid": 0b0111,
                "frontier_slot_valid_by_level": [0b0001, 0b0001, 0b0001],
                "frontier_node_ids_by_level": [
                    [0x3],
                    [0x4],
                    [0x5],
                ],
                "frontier_parent_node_ids_by_level": [
                    [0x2],
                    [0x3],
                    [0x4],
                ],
            },
            "metadata": {
                "source": "runtime-sync-tree-step-test",
            },
        }

        with tempfile.TemporaryDirectory() as tmpdir:
            workdir = Path(tmpdir) / "runtime_sync_tree_step"
            package_dir = Path(tmpdir) / "package"
            payload_path = Path(tmpdir) / "sync_tree_step_payload.json"
            package = build_demo_toy_decoder_package()
            package.save(package_dir)
            save_sync_tree_step_payload(payload_path, payload_dict)  # type: ignore[misc]

            status = main(  # type: ignore[misc]
                [
                    "prepare",
                    "--workdir",
                    str(workdir),
                    "--sync-step-json",
                    str(payload_path),
                    "--weight-package-dir",
                    str(package_dir),
                ]
            )
            self.assertEqual(status, 0)

            runtime_request = json.loads(
                (workdir / "runtime_request.json").read_text(encoding="utf-8")
            )
            self.assertEqual(runtime_request["request_kind"], "sync_tree_step")
            self.assertEqual(
                runtime_request["step_payload"]["native_tree_request"]["req_id"],
                0x6,
            )
            self.assertTrue((workdir / "sync_tree_step_request.json").exists())

            (workdir / "events" / "events.jsonl").write_text(
                "\n".join(
                    [
                        '{"cycle":1,"event":"native_tree_req","source":"rtl","req_id_hex":"0x6"}',
                        '{"cycle":2,"event":"native_tree_main_frontier_capture","source":"rtl"}',
                        '{"cycle":3,"event":"native_tree_main_pred","source":"rtl"}',
                        '{"cycle":4,"event":"wb_done","source":"rtl","token_id_hex":"0x21","wb_error":0}',
                        '{"cycle":5,"event":"finish","source":"rtl","busy_final":0,"error_flag":0}',
                    ]
                )
                + "\n",
                encoding="utf-8",
            )

            status = main(  # type: ignore[misc]
                [
                    "collect",
                    "--workdir",
                    str(workdir),
                ]
            )
            self.assertEqual(status, 0)

            result_json = json.loads(
                (workdir / "runtime_result.json").read_text(encoding="utf-8")
            )
            self.assertEqual(result_json["request_kind"], "sync_tree_step")
            self.assertEqual(result_json["step_index"], 1)
            self.assertEqual(result_json["accepted_tokens"], [0x12, 0x21])
            self.assertEqual(result_json["next_recovery_token"], 0x30)
            self.assertEqual(result_json["native_tree_req_id"], 0x6)
            self.assertEqual(result_json["generated_token_ids"], [0x21])

    @unittest.skipIf(IMPORT_ERROR is not None, "runtime sync tree step path not ready yet")
    def test_prepare_builds_native_tree_request_from_legacy_minimal_payload_json(self) -> None:
        payload_dict = {
            "sequence_id": "sync-tree-step-runtime-legacy-0",
            "prompt_token_ids": [0x10, 0x11],
            "step_index": 0,
            "recovery_token": 0x12,
            "speculated_tokens": [[0x21], [0x22], [0x23], [0x24]],
            "accepted_tokens": [0x12, 0x21],
            "next_recovery_token": 0x30,
        }

        with tempfile.TemporaryDirectory() as tmpdir:
            workdir = Path(tmpdir) / "runtime_sync_tree_step_legacy"
            package_dir = Path(tmpdir) / "package"
            payload_path = Path(tmpdir) / "sync_tree_step_payload_legacy.json"
            package = build_demo_toy_decoder_package()
            package.save(package_dir)
            payload_path.write_text(
                json.dumps(payload_dict, ensure_ascii=False, indent=2) + "\n",
                encoding="utf-8",
            )

            status = main(  # type: ignore[misc]
                [
                    "prepare",
                    "--workdir",
                    str(workdir),
                    "--sync-step-json",
                    str(payload_path),
                    "--weight-package-dir",
                    str(package_dir),
                ]
            )
            self.assertEqual(status, 0)

            runtime_request = json.loads(
                (workdir / "runtime_request.json").read_text(encoding="utf-8")
            )
            self.assertTrue(
                runtime_request["step_payload"]["native_tree_request"]["valid"]
            )

            saved_request = json.loads(
                (workdir / "sync_tree_step_request.json").read_text(encoding="utf-8")
            )
            self.assertTrue(saved_request["native_tree_request"]["valid"])

            stimulus_lines = (
                workdir / "stimulus" / "stimulus.memh"
            ).read_text(encoding="utf-8").splitlines()
            native_cycles = [
                StimulusCycle.from_memh_word(line)
                for line in stimulus_lines
                if StimulusCycle.from_memh_word(line).native_tree_request.valid
            ]
            self.assertTrue(native_cycles)
            self.assertEqual(
                native_cycles[0].native_tree_request.frontier_token_ids_by_level[0][:4],
                [0x21, 0x22, 0x23, 0x24],
            )
            self.assertEqual(
                native_cycles[0].native_tree_request.frontier_referenced_token_ids_by_level[0][:4],
                [0x12, 0x12, 0x12, 0x12],
            )
            self.assertEqual(
                native_cycles[0].native_tree_request.frontier_referenced_position_ids_by_level[0][:4],
                [0x2, 0x2, 0x2, 0x2],
            )

    @unittest.skipIf(IMPORT_ERROR is not None, "runtime sync tree step path not ready yet")
    def test_prepare_sync_tree_step_stimulus_uses_only_committed_prefill_candidates(self) -> None:
        payload_dict = {
            "sequence_id": "sync-tree-step-runtime-no-demo-draft-0",
            "prompt_token_ids": [0x10, 0x11],
            "step_index": 0,
            "recovery_token": 0x12,
            "speculated_tokens": [[0x21], [0x22], [0x23], [0x24]],
            "accepted_tokens": [0x12, 0x21],
            "next_recovery_token": 0x30,
        }

        with tempfile.TemporaryDirectory() as tmpdir:
            workdir = Path(tmpdir) / "runtime_sync_tree_step_no_demo_draft"
            package_dir = Path(tmpdir) / "package"
            payload_path = Path(tmpdir) / "sync_tree_step_payload_no_demo_draft.json"
            package = build_demo_toy_decoder_package()
            package.save(package_dir)
            payload_path.write_text(
                json.dumps(payload_dict, ensure_ascii=False, indent=2) + "\n",
                encoding="utf-8",
            )

            status = main(  # type: ignore[misc]
                [
                    "prepare",
                    "--workdir",
                    str(workdir),
                    "--sync-step-json",
                    str(payload_path),
                    "--weight-package-dir",
                    str(package_dir),
                ]
            )
            self.assertEqual(status, 0)

            stimulus_lines = (
                workdir / "stimulus" / "stimulus.memh"
            ).read_text(encoding="utf-8").splitlines()
            decoded_cycles = [StimulusCycle.from_memh_word(line) for line in stimulus_lines]
            draft_valid_counts = [
                sum(1 for cand in cycle.draft_candidates if cand.valid)
                for cycle in decoded_cycles
            ]
            self.assertEqual(draft_valid_counts[:4], [0, 1, 1, 0])
            self.assertTrue(all(count <= 1 for count in draft_valid_counts))
            self.assertEqual(
                [
                    [cand.token_id for cand in cycle.draft_candidates if cand.valid]
                    for cycle in decoded_cycles[:4]
                ],
                [[], [0x11], [0x12], []],
            )

    @unittest.skipIf(IMPORT_ERROR is not None, "runtime sync tree step path not ready yet")
    def test_prepare_sync_tree_step_stimulus_appends_full_recompute_tail_for_native_tree_path(self) -> None:
        payload_dict = {
            "sequence_id": "sync-tree-step-runtime-recompute-tail-0",
            "prompt_token_ids": [0x10, 0x11],
            "step_index": 0,
            "recovery_token": 0x12,
            "speculated_tokens": [[0x21], [0x22], [0x23], [0x24]],
            "accepted_tokens": [0x12, 0x21],
            "next_recovery_token": 0x30,
        }

        with tempfile.TemporaryDirectory() as tmpdir:
            workdir = Path(tmpdir) / "runtime_sync_tree_step_recompute_tail"
            package_dir = Path(tmpdir) / "package"
            payload_path = Path(tmpdir) / "sync_tree_step_payload_recompute_tail.json"
            package = build_demo_toy_decoder_package()
            package.save(package_dir)
            payload_path.write_text(
                json.dumps(payload_dict, ensure_ascii=False, indent=2) + "\n",
                encoding="utf-8",
            )

            status = main(  # type: ignore[misc]
                [
                    "prepare",
                    "--workdir",
                    str(workdir),
                    "--sync-step-json",
                    str(payload_path),
                    "--weight-package-dir",
                    str(package_dir),
                ]
            )
            self.assertEqual(status, 0)

            stimulus_lines = (
                workdir / "stimulus" / "stimulus.memh"
            ).read_text(encoding="utf-8").splitlines()
            decoded_cycles = [StimulusCycle.from_memh_word(line) for line in stimulus_lines]
            self.assertGreater(len(decoded_cycles), 3)
            native_cycle_index = next(
                idx
                for idx, cycle in enumerate(decoded_cycles)
                if cycle.native_tree_request.valid
            )

            response_cycle_indices = [
                idx
                for idx, cycle in enumerate(decoded_cycles)
                if cycle.recompute_response.valid
            ]
            self.assertTrue(response_cycle_indices)
            tail_response_cycle_indices = [
                idx for idx in response_cycle_indices if idx > native_cycle_index
            ]
            self.assertGreaterEqual(tail_response_cycle_indices[0], native_cycle_index + 5)
            self.assertGreaterEqual(len(tail_response_cycle_indices), 3)
            self.assertTrue(
                any(
                    cycle.recompute_response.full and cycle.recompute_response.last
                    for cycle in decoded_cycles[native_cycle_index + 1 :]
                )
            )
            self.assertTrue(
                all(decoded_cycles[idx].recompute_req_ready for idx in tail_response_cycle_indices)
            )
            self.assertTrue(
                all(decoded_cycles[idx].wb_ready for idx in tail_response_cycle_indices)
            )

if __name__ == "__main__":
    unittest.main()
