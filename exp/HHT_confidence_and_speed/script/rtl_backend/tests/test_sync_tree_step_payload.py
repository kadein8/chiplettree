import json
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT_ROOT = Path(__file__).resolve().parents[2]
if str(SCRIPT_ROOT) not in sys.path:
    sys.path.insert(0, str(SCRIPT_ROOT))


try:
    from rtl_backend.ssd_bridge import (  # type: ignore
        build_demo_artifacts_from_sync_tree_step,
        build_sync_tree_step_payload,
        save_sync_tree_step_payload,
    )
    from rtl_backend.stimulus import StimulusCycle  # type: ignore
except ImportError as exc:  # pragma: no cover - exercised in red phase
    IMPORT_ERROR = exc
    build_demo_artifacts_from_sync_tree_step = None  # type: ignore
    build_sync_tree_step_payload = None  # type: ignore
    save_sync_tree_step_payload = None  # type: ignore
    StimulusCycle = None  # type: ignore
else:
    IMPORT_ERROR = None


class _DummySequence(object):
    def __init__(self) -> None:
        self.seq_id = 9
        self.prompt_token_ids = [0x10, 0x11]
        self.recovery_token_id = 0x12
        self.max_new_tokens = 4


class SyncTreeStepPayloadTest(unittest.TestCase):
    def test_sync_tree_step_bridge_symbols_are_available(self) -> None:
        self.assertIsNone(IMPORT_ERROR, msg=str(IMPORT_ERROR))

    @unittest.skipIf(IMPORT_ERROR is not None, "sync tree step bridge not ready yet")
    def test_build_sync_tree_step_payload_and_artifacts(self) -> None:
        payload = build_sync_tree_step_payload(  # type: ignore[misc]
            sequence_like=_DummySequence(),
            speculate_result={
                "speculations": [[0x12, 0x21, 0x22, 0x23]],
            },
            verify_result={
                "new_suffixes": [[0x12, 0x21]],
                "recovery_tokens": [0x30],
            },
            step_index=2,
            metadata={"source": "unit-test-sync-step"},
        )

        self.assertEqual(payload.sequence_id, "9")
        self.assertEqual(payload.prompt_token_ids, [16, 17])
        self.assertEqual(payload.step_index, 2)
        self.assertEqual(payload.recovery_token, 0x12)
        self.assertEqual(payload.speculated_tokens, [0x21, 0x22, 0x23])
        self.assertEqual(payload.accepted_tokens, [0x12, 0x21])
        self.assertEqual(payload.next_recovery_token, 0x30)
        self.assertEqual(payload.native_tree_request.req_id, 0x6)
        self.assertEqual(payload.native_tree_request.prefix_slot_valid, 0b0111)
        self.assertEqual(
            payload.native_tree_request.prefix_node_ids[:3],
            [0x1, 0x2, 0x3],
        )
        self.assertEqual(
            payload.native_tree_request.prefix_token_ids[:3],
            [0x10, 0x11, 0x12],
        )
        self.assertEqual(
            payload.native_tree_request.prefix_position_ids[:3],
            [0x0, 0x1, 0x2],
        )
        self.assertEqual(payload.native_tree_request.frontier_level_valid, 0b0111)
        self.assertEqual(
            payload.native_tree_request.frontier_slot_valid_by_level[:3],
            [0b0001, 0b0001, 0b0001],
        )
        self.assertEqual(
            payload.native_tree_request.frontier_tree_mask_en_by_level[:3],
            [0b0001, 0b0001, 0b0001],
        )
        self.assertEqual(
            payload.native_tree_request.frontier_parent_node_ids_by_level[0][0],
            0x3,
        )
        self.assertEqual(
            payload.native_tree_request.frontier_parent_node_ids_by_level[2][0],
            0x5,
        )

        with tempfile.TemporaryDirectory() as tmpdir:
            workdir = Path(tmpdir) / "sync_tree_step_demo"
            payload_json = workdir / "sync_tree_step_payload.json"
            save_sync_tree_step_payload(payload_json, payload)  # type: ignore[misc]

            build_demo_artifacts_from_sync_tree_step(  # type: ignore[misc]
                workdir=workdir,
                step_payload_like=payload,
            )

            payload_dict = json.loads(payload_json.read_text(encoding="utf-8"))
            self.assertEqual(payload_dict["step_index"], 2)
            self.assertEqual(payload_dict["recovery_token"], 0x12)

            saved_request = json.loads(
                (workdir / "sync_tree_step_request.json").read_text(encoding="utf-8")
            )
            self.assertEqual(saved_request["native_tree_request"]["req_id"], 0x6)
            self.assertEqual(
                saved_request["native_tree_request"]["prefix_slot_valid"],
                0b0111,
            )
            self.assertEqual(
                saved_request["native_tree_request"]["frontier_level_valid"],
                0b0111,
            )

            stimulus_lines = (
                workdir / "stimulus" / "stimulus.memh"
            ).read_text(encoding="utf-8").splitlines()
            native_cycles = [
                StimulusCycle.from_memh_word(line)  # type: ignore[union-attr]
                for line in stimulus_lines
                if StimulusCycle.from_memh_word(line).native_tree_request.valid
            ]
            self.assertTrue(native_cycles)
            self.assertEqual(native_cycles[0].native_tree_request.req_id, 0x6)
            self.assertEqual(
                native_cycles[0].native_tree_request.frontier_level_valid,
                0b0111,
            )
            self.assertEqual(
                native_cycles[0].native_tree_request.frontier_slot_valid_by_level[:3],
                [0b0001, 0b0001, 0b0001],
            )
            self.assertEqual(
                native_cycles[0].native_tree_request.frontier_tree_mask_en_by_level[:3],
                [0b0001, 0b0001, 0b0001],
            )
            self.assertNotEqual(native_cycles[0].visible_mask, 0)


if __name__ == "__main__":
    unittest.main()
