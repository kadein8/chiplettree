import json
import sys
import tempfile
import unittest
from pathlib import Path

import numpy as np


SCRIPT_ROOT = Path(__file__).resolve().parents[2]
REPO_ROOT = SCRIPT_ROOT.parents[1]
if str(SCRIPT_ROOT) not in sys.path:
    sys.path.insert(0, str(SCRIPT_ROOT))


TRACE_JSONL_TEXT = "\n".join(
    [
        '{"sequence_id":"host-vm-runtime-loop-0","prompt_token_ids":[16,17],"step_index":0,"recovery_token":18,"speculated_tokens":[[33],[34],[35],[36]],"accepted_tokens":[18,33],"next_recovery_token":48}',
        '{"sequence_id":"host-vm-runtime-loop-0","prompt_token_ids":[16,17,33],"step_index":1,"recovery_token":48,"speculated_tokens":[[34],[35],[36],[37]],"accepted_tokens":[48,34],"next_recovery_token":64}',
    ]
) + "\n"


try:
    from rtl_backend.ssd_bridge import SequencePrompt, save_sync_tree_step_payload  # type: ignore
    from rtl_backend.toy_decoder import build_demo_toy_decoder_package  # type: ignore
    from rtl_runtime.host_vm_flow import (  # type: ignore
        collect_tree_mask_e2e_strict_workdir,
        collect_runtime_loop_trace_workdir,
        collect_single_step_workdir,
        prepare_tree_mask_e2e_strict_workdir,
        prepare_runtime_loop_trace_workdir,
        prepare_single_step_workdir,
    )
    from rtl_runtime.runtime_adapter import (  # type: ignore
        prepare_runtime_workdir,
        runtime_request_from_sequence_like,
    )
except ImportError as exc:  # pragma: no cover - red phase
    IMPORT_ERROR = exc
    SequencePrompt = None  # type: ignore
    save_sync_tree_step_payload = None  # type: ignore
    build_demo_toy_decoder_package = None  # type: ignore
    collect_tree_mask_e2e_strict_workdir = None  # type: ignore
    collect_runtime_loop_trace_workdir = None  # type: ignore
    collect_single_step_workdir = None  # type: ignore
    prepare_tree_mask_e2e_strict_workdir = None  # type: ignore
    prepare_runtime_loop_trace_workdir = None  # type: ignore
    prepare_single_step_workdir = None  # type: ignore
    prepare_runtime_workdir = None  # type: ignore
    runtime_request_from_sequence_like = None  # type: ignore
else:
    IMPORT_ERROR = None


def _write_runtime_events(platform_workdir: Path, generated_token_ids) -> None:
    events_dir = platform_workdir / "events"
    events_dir.mkdir(parents=True, exist_ok=True)
    records = []
    cycle = 1
    for token_id in list(generated_token_ids):
        records.append(
            '{{"cycle":{0},"event":"wb_done","source":"rtl","token_id_hex":"0x{1:02x}","wb_error":0}}'.format(
                cycle, int(token_id)
            )
        )
        cycle += 1
    records.append(
        '{{"cycle":{0},"event":"finish","source":"rtl","busy_final":0,"error_flag":0}}'.format(
            cycle
        )
    )
    (events_dir / "events.jsonl").write_text(
        "\n".join(records) + "\n",
        encoding="utf-8",
    )


def _write_runtime_events_with_extra_records(
    platform_workdir: Path,
    generated_token_ids,
    extra_records,
) -> None:
    events_dir = platform_workdir / "events"
    events_dir.mkdir(parents=True, exist_ok=True)
    records = []
    cycle = 1
    for record in list(extra_records):
        payload = dict(record)
        payload.setdefault("cycle", cycle)
        payload.setdefault("source", "rtl")
        records.append(json.dumps(payload, ensure_ascii=False))
        cycle += 1
    for token_id in list(generated_token_ids):
        records.append(
            '{{"cycle":{0},"event":"wb_done","source":"rtl","token_id_hex":"0x{1:02x}","wb_error":0}}'.format(
                cycle, int(token_id)
            )
        )
        cycle += 1
    records.append(
        '{{"cycle":{0},"event":"finish","source":"rtl","busy_final":0,"error_flag":0}}'.format(
            cycle
        )
    )
    (events_dir / "events.jsonl").write_text(
        "\n".join(records) + "\n",
        encoding="utf-8",
    )


def _write_runtime_events_with_zero_wb_payload(
    platform_workdir: Path, generated_token_ids
) -> None:
    events_dir = platform_workdir / "events"
    events_dir.mkdir(parents=True, exist_ok=True)
    records = []
    cycle = 1
    for token_id in list(generated_token_ids):
        records.append(
            '{{"cycle":{0},"event":"wb","source":"rtl","token_id_hex":"0x{1:02x}","addr_hex":"0x24030","data_hex":"0","status_hex":"0x0"}}'.format(
                cycle, int(token_id)
            )
        )
        cycle += 1
        records.append(
            '{{"cycle":{0},"event":"wb_done","source":"rtl","token_id_hex":"0x{1:02x}","wb_error":0}}'.format(
                cycle, int(token_id)
            )
        )
        cycle += 1
    records.append(
        '{{"cycle":{0},"event":"finish","source":"rtl","busy_final":0,"error_flag":0}}'.format(
            cycle
        )
    )
    (events_dir / "events.jsonl").write_text(
        "\n".join(records) + "\n",
        encoding="utf-8",
    )


def _write_vm_return_events(root_workdir: Path, generated_token_ids) -> None:
    vm_return_dir = root_workdir / "vm_return"
    _write_runtime_events(vm_return_dir, generated_token_ids)


def _prepare_runtime_platform_workdir(platform_workdir: Path, sequence_id: str) -> None:
    package = build_demo_toy_decoder_package()  # type: ignore[misc]
    request = runtime_request_from_sequence_like(  # type: ignore[misc]
        SequencePrompt(  # type: ignore[misc]
            sequence_id=sequence_id,
            prompt_token_ids=[16, 17],
            max_new_tokens=1,
        )
    )
    prepare_runtime_workdir(  # type: ignore[misc]
        workdir=platform_workdir,
        request=request,
        package=package,
    )


def _write_fp16_memh_vector(path: Path, vector: np.ndarray) -> None:
    vector = np.asarray(vector, dtype=np.float16).reshape(-1)
    words_per_line = 8
    lines = []
    for offset in range(0, len(vector), words_per_line):
        chunk = vector[offset : offset + words_per_line]
        if len(chunk) < words_per_line:
            chunk = np.concatenate(
                [chunk, np.zeros((words_per_line - len(chunk),), dtype=np.float16)]
            )
        words = [
            "{:04x}".format(int(np.array([value], dtype=np.float16).view(np.uint16)[0]))
            for value in chunk
        ]
        lines.append("".join(reversed(words)))
    path.write_text("\n".join(lines) + "\n", encoding="ascii")


def _write_tree_mask_strict_events(
    platform_workdir: Path,
    generated_token_ids,
    extra_records=None,
) -> None:
    events_dir = platform_workdir / "events"
    events_dir.mkdir(parents=True, exist_ok=True)
    records = []
    cycle = 1
    for record in list(extra_records or []):
        payload = dict(record)
        payload.setdefault("cycle", cycle)
        payload.setdefault("source", "rtl")
        records.append(json.dumps(payload, ensure_ascii=False))
        cycle += 1
    for token_id in list(generated_token_ids):
        records.append(
            '{{"cycle":{0},"event":"wb_done","source":"rtl","token_id_hex":"0x{1:02x}","wb_error":0}}'.format(
                cycle, int(token_id)
            )
        )
        cycle += 1
    records.append(
        '{{"cycle":{0},"event":"finish","source":"rtl","busy_final":0,"error_flag":0}}'.format(
            cycle
        )
    )
    (events_dir / "events.jsonl").write_text(
        "\n".join(records) + "\n",
        encoding="utf-8",
    )


class HostVmFlowTest(unittest.TestCase):
    def test_host_vm_flow_module_is_available(self) -> None:
        self.assertIsNone(IMPORT_ERROR, msg=str(IMPORT_ERROR))

    @unittest.skipIf(IMPORT_ERROR is not None, "host_vm_flow module not ready yet")
    def test_prepare_runtime_loop_trace_workdir_creates_two_prepared_steps(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            tmpdir_path = Path(tmpdir)
            trace_path = tmpdir_path / "trace.jsonl"
            trace_path.write_text(TRACE_JSONL_TEXT, encoding="utf-8", newline="\n")
            package_dir = tmpdir_path / "weight_package"
            build_demo_toy_decoder_package().save(package_dir)  # type: ignore[misc]
            root_workdir = tmpdir_path / "runtime_loop_root"

            manifest_path = prepare_runtime_loop_trace_workdir(  # type: ignore[misc]
                root_workdir=root_workdir,
                trace_jsonl=trace_path,
                weight_package_dir=package_dir,
            )

            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            self.assertEqual(manifest["mode"], "runtime_loop_trace")
            self.assertEqual(manifest["step_count"], 2)
            self.assertTrue(
                (
                    root_workdir
                    / "step_000"
                    / "platform_real_ssd_sync_tree_step_payload"
                    / "sync_tree_step_request.json"
                ).exists()
            )
            self.assertTrue(
                (
                    root_workdir
                    / "step_001"
                    / "platform_real_ssd_sync_tree_step_payload"
                    / "stimulus"
                    / "stimulus.memh"
                ).exists()
            )

    @unittest.skipIf(IMPORT_ERROR is not None, "host_vm_flow module not ready yet")
    def test_collect_runtime_loop_trace_workdir_respects_serial_chain_projection_by_default(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            tmpdir_path = Path(tmpdir)
            trace_path = tmpdir_path / "trace.jsonl"
            trace_path.write_text(TRACE_JSONL_TEXT, encoding="utf-8", newline="\n")
            package_dir = tmpdir_path / "weight_package"
            build_demo_toy_decoder_package().save(package_dir)  # type: ignore[misc]
            root_workdir = tmpdir_path / "runtime_loop_root"

            prepare_runtime_loop_trace_workdir(  # type: ignore[misc]
                root_workdir=root_workdir,
                trace_jsonl=trace_path,
                weight_package_dir=package_dir,
            )
            _write_runtime_events(
                root_workdir
                / "step_000"
                / "platform_real_ssd_sync_tree_step_payload",
                [33, 34, 35, 36],
            )
            _write_runtime_events(
                root_workdir
                / "step_001"
                / "platform_real_ssd_sync_tree_step_payload",
                [34, 35, 36, 37],
            )

            summary_path = collect_runtime_loop_trace_workdir(  # type: ignore[misc]
                root_workdir=root_workdir
            )

            summary = json.loads(summary_path.read_text(encoding="utf-8"))
            self.assertTrue(summary["passed"])
            self.assertEqual(summary["mode"], "runtime_loop_trace")
            self.assertEqual(summary["step_count"], 2)
            self.assertEqual(
                summary["generated_token_ids"],
                [33, 34, 35, 36, 34, 35, 36, 37],
            )
            self.assertEqual(
                summary["steps"][0]["expected_generated_token_ids"],
                [33, 34, 35, 36],
            )
            self.assertEqual(
                summary["steps"][1]["actual_generated_token_ids"],
                [34, 35, 36, 37],
            )

    @unittest.skipIf(IMPORT_ERROR is not None, "host_vm_flow module not ready yet")
    def test_collect_runtime_loop_trace_workdir_supports_accepted_path_projection_override(self) -> None:
        accepted_path_trace = "\n".join(
            [
                '{"sequence_id":"host-vm-runtime-loop-0","prompt_token_ids":[16,17],"step_index":0,"recovery_token":18,"speculated_tokens":[[33],[34],[35],[36]],"accepted_tokens":[18,33],"next_recovery_token":48,"metadata":{"tree_projection_mode":"accepted_path"}}',
                '{"sequence_id":"host-vm-runtime-loop-0","prompt_token_ids":[16,17,33],"step_index":1,"recovery_token":48,"speculated_tokens":[[34],[35],[36],[37]],"accepted_tokens":[48,34],"next_recovery_token":64,"metadata":{"tree_projection_mode":"accepted_path"}}',
            ]
        ) + "\n"

        with tempfile.TemporaryDirectory() as tmpdir:
            tmpdir_path = Path(tmpdir)
            trace_path = tmpdir_path / "trace.jsonl"
            trace_path.write_text(accepted_path_trace, encoding="utf-8", newline="\n")
            package_dir = tmpdir_path / "weight_package"
            build_demo_toy_decoder_package().save(package_dir)  # type: ignore[misc]
            root_workdir = tmpdir_path / "runtime_loop_root"

            prepare_runtime_loop_trace_workdir(  # type: ignore[misc]
                root_workdir=root_workdir,
                trace_jsonl=trace_path,
                weight_package_dir=package_dir,
            )
            _write_runtime_events(
                root_workdir
                / "step_000"
                / "platform_real_ssd_sync_tree_step_payload",
                [33],
            )
            _write_runtime_events(
                root_workdir
                / "step_001"
                / "platform_real_ssd_sync_tree_step_payload",
                [34],
            )

            summary_path = collect_runtime_loop_trace_workdir(  # type: ignore[misc]
                root_workdir=root_workdir
            )

            summary = json.loads(summary_path.read_text(encoding="utf-8"))
            self.assertTrue(summary["passed"])
            self.assertEqual(summary["generated_token_ids"], [33, 34])
            self.assertEqual(summary["steps"][0]["expected_generated_token_ids"], [33])
            self.assertEqual(summary["steps"][1]["expected_generated_token_ids"], [34])

    @unittest.skipIf(IMPORT_ERROR is not None, "host_vm_flow module not ready yet")
    def test_collect_runtime_loop_trace_workdir_exposes_rtl_accepted_token_mismatch_for_accepted_path_projection(self) -> None:
        accepted_path_trace = "\n".join(
            [
                '{"sequence_id":"host-vm-runtime-loop-0","prompt_token_ids":[16,17],"step_index":0,"recovery_token":18,"speculated_tokens":[[33],[34],[35],[36]],"accepted_tokens":[18,127],"next_recovery_token":48,"metadata":{"tree_projection_mode":"accepted_path"}}',
                '{"sequence_id":"host-vm-runtime-loop-0","prompt_token_ids":[16,17,33],"step_index":1,"recovery_token":48,"speculated_tokens":[[34],[35],[36],[37]],"accepted_tokens":[48,126],"next_recovery_token":64,"metadata":{"tree_projection_mode":"accepted_path"}}',
            ]
        ) + "\n"

        with tempfile.TemporaryDirectory() as tmpdir:
            tmpdir_path = Path(tmpdir)
            trace_path = tmpdir_path / "trace.jsonl"
            trace_path.write_text(accepted_path_trace, encoding="utf-8", newline="\n")
            package_dir = tmpdir_path / "weight_package"
            build_demo_toy_decoder_package().save(package_dir)  # type: ignore[misc]
            root_workdir = tmpdir_path / "runtime_loop_root"

            prepare_runtime_loop_trace_workdir(  # type: ignore[misc]
                root_workdir=root_workdir,
                trace_jsonl=trace_path,
                weight_package_dir=package_dir,
            )
            _write_runtime_events_with_extra_records(
                root_workdir
                / "step_000"
                / "platform_real_ssd_sync_tree_step_payload",
                [33, 34, 35, 36],
                [
                    {"event": "accepted_token", "token_id_hex": "0x21"},
                    {"event": "bonus_token", "token_id_hex": "0x30"},
                ],
            )
            _write_runtime_events_with_extra_records(
                root_workdir
                / "step_001"
                / "platform_real_ssd_sync_tree_step_payload",
                [34, 35, 36, 37],
                [
                    {"event": "accepted_token", "token_id_hex": "0x22"},
                    {"event": "bonus_token", "token_id_hex": "0x40"},
                ],
            )

            summary_path = collect_runtime_loop_trace_workdir(  # type: ignore[misc]
                root_workdir=root_workdir
            )

            summary = json.loads(summary_path.read_text(encoding="utf-8"))
            self.assertFalse(summary["passed"])
            self.assertEqual(summary["generated_token_ids"], [33, 34])
            self.assertEqual(summary["steps"][0]["actual_generated_token_ids"], [33])
            self.assertEqual(summary["steps"][1]["actual_generated_token_ids"], [34])
            self.assertEqual(summary["steps"][0]["actual_accepted_tokens"], [18, 33])
            self.assertEqual(summary["steps"][1]["actual_accepted_tokens"], [48, 34])
            self.assertEqual(summary["steps"][0]["expected_generated_token_ids"], [127])
            self.assertEqual(summary["steps"][1]["expected_generated_token_ids"], [126])

    @unittest.skipIf(IMPORT_ERROR is not None, "host_vm_flow module not ready yet")
    def test_prepare_and_collect_single_step_workdir(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            tmpdir_path = Path(tmpdir)
            payload_path = tmpdir_path / "single_step_payload.json"
            save_sync_tree_step_payload(  # type: ignore[misc]
                payload_path,
                {
                    "sequence_id": "host-vm-sync-step-0",
                    "prompt_token_ids": [16, 17],
                    "step_index": 0,
                    "recovery_token": 18,
                    "speculated_tokens": [[33], [34], [35], [36]],
                    "accepted_tokens": [18, 33],
                    "next_recovery_token": 48,
                    "metadata": {"tree_projection_mode": "accepted_path"},
                },
            )
            package_dir = tmpdir_path / "weight_package"
            build_demo_toy_decoder_package().save(package_dir)  # type: ignore[misc]
            root_workdir = tmpdir_path / "single_step_root"

            manifest_path = prepare_single_step_workdir(  # type: ignore[misc]
                root_workdir=root_workdir,
                sync_step_json=payload_path,
                weight_package_dir=package_dir,
            )
            self.assertTrue(manifest_path.exists())

            _write_runtime_events(
                root_workdir / "platform_real_ssd_sync_tree_step_payload",
                [33],
            )

            summary_path = collect_single_step_workdir(  # type: ignore[misc]
                root_workdir=root_workdir
            )
            summary = json.loads(summary_path.read_text(encoding="utf-8"))
            self.assertTrue(summary["passed"])
            self.assertEqual(summary["mode"], "single_step")
            self.assertEqual(summary["expected_generated_token_ids"], [33])
            self.assertEqual(summary["actual_generated_token_ids"], [33])

    @unittest.skipIf(IMPORT_ERROR is not None, "host_vm_flow module not ready yet")
    def test_collect_single_step_workdir_prefers_vm_return_events_when_present(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            tmpdir_path = Path(tmpdir)
            payload_path = tmpdir_path / "single_step_payload.json"
            save_sync_tree_step_payload(  # type: ignore[misc]
                payload_path,
                {
                    "sequence_id": "host-vm-sync-step-0",
                    "prompt_token_ids": [16, 17],
                    "step_index": 0,
                    "recovery_token": 18,
                    "speculated_tokens": [[33], [34], [35], [36]],
                    "accepted_tokens": [18, 33],
                    "next_recovery_token": 48,
                    "metadata": {"tree_projection_mode": "accepted_path"},
                },
            )
            package_dir = tmpdir_path / "weight_package"
            build_demo_toy_decoder_package().save(package_dir)  # type: ignore[misc]
            root_workdir = tmpdir_path / "single_step_root"

            prepare_single_step_workdir(  # type: ignore[misc]
                root_workdir=root_workdir,
                sync_step_json=payload_path,
                weight_package_dir=package_dir,
            )
            _write_vm_return_events(root_workdir, [33])

            summary_path = collect_single_step_workdir(  # type: ignore[misc]
                root_workdir=root_workdir
            )

            summary = json.loads(summary_path.read_text(encoding="utf-8"))
            self.assertTrue(summary["passed"])
            self.assertEqual(summary["actual_generated_token_ids"], [33])

    @unittest.skipIf(IMPORT_ERROR is not None, "host_vm_flow module not ready yet")
    def test_collect_single_step_workdir_does_not_override_newer_platform_events_with_stale_vm_return(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            tmpdir_path = Path(tmpdir)
            payload_path = tmpdir_path / "single_step_payload.json"
            save_sync_tree_step_payload(  # type: ignore[misc]
                payload_path,
                {
                    "sequence_id": "host-vm-sync-step-0",
                    "prompt_token_ids": [16, 17],
                    "step_index": 0,
                    "recovery_token": 18,
                    "speculated_tokens": [[33], [34], [35], [36]],
                    "accepted_tokens": [18, 33],
                    "next_recovery_token": 48,
                },
            )
            package_dir = tmpdir_path / "weight_package"
            build_demo_toy_decoder_package().save(package_dir)  # type: ignore[misc]
            root_workdir = tmpdir_path / "single_step_root"

            prepare_single_step_workdir(  # type: ignore[misc]
                root_workdir=root_workdir,
                sync_step_json=payload_path,
                weight_package_dir=package_dir,
            )
            _write_vm_return_events(root_workdir, [34, 35, 36, 37])
            _write_runtime_events(
                root_workdir / "platform_real_ssd_sync_tree_step_payload",
                [33, 34, 35, 36],
            )

            summary_path = collect_single_step_workdir(  # type: ignore[misc]
                root_workdir=root_workdir
            )

            summary = json.loads(summary_path.read_text(encoding="utf-8"))
            self.assertTrue(summary["passed"])
            self.assertEqual(summary["actual_generated_token_ids"], [33, 34, 35, 36])

    @unittest.skipIf(IMPORT_ERROR is not None, "host_vm_flow module not ready yet")
    def test_collect_single_step_workdir_uses_wb_done_tokens_for_sync_tree_step_events(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            tmpdir_path = Path(tmpdir)
            payload_path = tmpdir_path / "single_step_payload.json"
            save_sync_tree_step_payload(  # type: ignore[misc]
                payload_path,
                {
                    "sequence_id": "host-vm-sync-step-0",
                    "prompt_token_ids": [16, 17],
                    "step_index": 0,
                    "recovery_token": 18,
                    "speculated_tokens": [[33], [34], [35], [36]],
                    "accepted_tokens": [18, 33],
                    "next_recovery_token": 48,
                },
            )
            package_dir = tmpdir_path / "weight_package"
            build_demo_toy_decoder_package().save(package_dir)  # type: ignore[misc]
            root_workdir = tmpdir_path / "single_step_root"

            prepare_single_step_workdir(  # type: ignore[misc]
                root_workdir=root_workdir,
                sync_step_json=payload_path,
                weight_package_dir=package_dir,
            )
            _write_runtime_events_with_zero_wb_payload(
                root_workdir / "platform_real_ssd_sync_tree_step_payload",
                [33, 34, 35, 36],
            )

            summary_path = collect_single_step_workdir(  # type: ignore[misc]
                root_workdir=root_workdir
            )

            summary = json.loads(summary_path.read_text(encoding="utf-8"))
            self.assertTrue(summary["passed"])
            self.assertEqual(summary["actual_generated_token_ids"], [33, 34, 35, 36])

    @unittest.skipIf(IMPORT_ERROR is not None, "host_vm_flow module not ready yet")
    def test_collect_tree_mask_e2e_strict_workdir_reports_step_kinds_hidden_cosine_and_lifecycle(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            tmpdir_path = Path(tmpdir)
            root_workdir = tmpdir_path / "tree_mask_e2e_root"
            steps = []

            for step_idx in range(5):
                step_root = root_workdir / ("step_%03d" % step_idx)
                platform_workdir = step_root / "platform_real_ssd_sync_tree_step_payload"
                _prepare_runtime_platform_workdir(
                    platform_workdir,
                    sequence_id="tree-mask-e2e-%d" % step_idx,
                )
                vector = np.linspace(
                    np.float32(step_idx),
                    np.float32(step_idx) + np.float32(1.0),
                    128,
                    dtype=np.float32,
                ).astype(np.float16)
                rtl_hidden_path = platform_workdir / ("rtl_step%d_final_hidden.memh" % step_idx)
                ref_hidden_path = step_root / ("ref_step%d_final_hidden.npy" % step_idx)
                _write_fp16_memh_vector(rtl_hidden_path, vector)
                np.save(ref_hidden_path, vector.astype(np.float16))

                extra_records = []
                step_kind = "verify_group" if step_idx == 2 else "single_step"
                if step_idx == 2:
                    extra_records = [
                        {"event": "accepted_prefix", "accepted_prefix_depth": 1},
                        {"event": "lifecycle_commit", "branch_id": 0},
                        {"event": "lifecycle_flush", "branch_id": 1},
                        {"event": "lifecycle_flush", "branch_id": 2},
                        {"event": "lifecycle_flush", "branch_id": 3},
                        {"event": "token_flush", "count": 3},
                        {"event": "flush_reclaim", "group_len": 3},
                    ]
                _write_tree_mask_strict_events(
                    platform_workdir,
                    [14 + step_idx],
                    extra_records=extra_records,
                )

                step_manifest = {
                    "step_index": step_idx,
                    "step_kind": step_kind,
                    "platform_workdir": str(platform_workdir),
                    "expected_generated_token_ids": [14 + step_idx],
                    "rtl_hidden_path": str(rtl_hidden_path),
                    "ref_hidden_path": str(ref_hidden_path),
                }
                if step_idx == 2:
                    step_manifest.update(
                        {
                            "expected_commit_branch_id": 0,
                            "expected_flush_branch_ids": [1, 2, 3],
                            "expected_accepted_prefix_depth": 1,
                            "expected_token_flush_count": 3,
                            "expected_flush_reclaim_count": 3,
                        }
                    )
                steps.append(step_manifest)

            manifest = {
                "mode": "tree_mask_e2e_strict",
                "root_workdir": str(root_workdir),
                "step_count": 5,
                "steps": steps,
            }
            root_workdir.mkdir(parents=True, exist_ok=True)
            (root_workdir / "host_vm_manifest.json").write_text(
                json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
                encoding="utf-8",
            )

            summary_path = collect_tree_mask_e2e_strict_workdir(  # type: ignore[misc]
                root_workdir=root_workdir
            )

            summary = json.loads(summary_path.read_text(encoding="utf-8"))
            self.assertEqual(summary["mode"], "tree_mask_e2e_strict")
            self.assertEqual(summary["step_count"], 5)
            self.assertTrue(summary["passed"])
            self.assertEqual(summary["steps"][0]["step_kind"], "single_step")
            self.assertEqual(summary["steps"][2]["step_kind"], "verify_group")
            self.assertGreater(summary["steps"][2]["final_hidden"]["cosine_similarity"], 0.999)
            self.assertEqual(summary["steps"][2]["lifecycle"]["commit_branch_id"], 0)
            self.assertEqual(summary["steps"][2]["lifecycle"]["flush_branch_ids"], [1, 2, 3])
            self.assertEqual(summary["steps"][2]["lifecycle"]["flush_reclaim_count"], 3)
            self.assertTrue(summary["steps"][2]["lifecycle"]["passed"])

    @unittest.skipIf(IMPORT_ERROR is not None, "host_vm_flow module not ready yet")
    def test_collect_tree_mask_e2e_strict_workdir_reports_hidden_numeric_mismatch_without_failing_process_pass(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            tmpdir_path = Path(tmpdir)
            root_workdir = tmpdir_path / "tree_mask_e2e_hidden_info_only"
            step_root = root_workdir / "step_000"
            platform_workdir = step_root / "platform_real_ssd_sync_tree_step_payload"
            _prepare_runtime_platform_workdir(
                platform_workdir,
                sequence_id="tree-mask-e2e-hidden-info-only",
            )

            rtl_hidden_path = platform_workdir / "rtl_step0_final_hidden.memh"
            ref_hidden_path = step_root / "ref_step0_final_hidden.npy"
            rtl_token_path = platform_workdir / "rtl_step0_token.txt"
            _write_fp16_memh_vector(
                rtl_hidden_path, np.zeros((128,), dtype=np.float16)
            )
            np.save(ref_hidden_path, np.ones((128,), dtype=np.float16))
            rtl_token_path.write_text("21\n", encoding="ascii")
            _write_tree_mask_strict_events(platform_workdir, [21])

            manifest = {
                "mode": "tree_mask_e2e_strict",
                "root_workdir": str(root_workdir),
                "step_count": 1,
                "steps": [
                    {
                        "step_index": 0,
                        "step_kind": "single_step",
                        "platform_workdir": str(platform_workdir),
                        "rtl_token_path": str(rtl_token_path),
                        "rtl_hidden_path": str(rtl_hidden_path),
                        "ref_hidden_path": str(ref_hidden_path),
                        "expected_generated_token_ids": [21],
                    }
                ],
            }
            root_workdir.mkdir(parents=True, exist_ok=True)
            (root_workdir / "host_vm_manifest.json").write_text(
                json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
                encoding="utf-8",
            )

            summary_path = collect_tree_mask_e2e_strict_workdir(  # type: ignore[misc]
                root_workdir=root_workdir
            )

            summary = json.loads(summary_path.read_text(encoding="utf-8"))
            self.assertTrue(summary["passed"])
            self.assertTrue(summary["steps"][0]["passed"])
            self.assertLess(summary["steps"][0]["final_hidden"]["cosine_similarity"], 0.5)

    @unittest.skipIf(IMPORT_ERROR is not None, "host_vm_flow module not ready yet")
    def test_collect_tree_mask_e2e_strict_workdir_uses_final_lifecycle_window_and_expected_depth_when_accepted_prefix_is_missing(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            tmpdir_path = Path(tmpdir)
            root_workdir = tmpdir_path / "tree_mask_e2e_final_lifecycle_window"
            step_root = root_workdir / "step_002"
            platform_workdir = step_root / "platform_real_ssd_sync_tree_step_payload"
            _prepare_runtime_platform_workdir(
                platform_workdir,
                sequence_id="tree-mask-e2e-final-lifecycle-window",
            )

            branch_hidden_path = (
                platform_workdir / "rtl_step2_branch0_level0_final_hidden.memh"
            )
            branch_token_path = platform_workdir / "rtl_step2_branch0_level0_token.txt"
            ref_hidden_path = step_root / "ref_step2_branch0_level0_final_hidden.npy"
            vector = np.full((128,), np.float16(6), dtype=np.float16)
            _write_fp16_memh_vector(branch_hidden_path, vector)
            np.save(ref_hidden_path, vector.astype(np.float16))
            branch_token_path.write_text("60\n", encoding="ascii")
            _write_tree_mask_strict_events(
                platform_workdir,
                [60],
                extra_records=[
                    {"event": "lifecycle_commit", "branch_id": 0, "branch_mask_hex": "0x0"},
                    {"event": "lifecycle_flush", "branch_id": 0, "branch_mask_hex": "0xf"},
                    {"event": "lifecycle_flush", "branch_id": 1, "branch_mask_hex": "0xf"},
                    {"event": "lifecycle_flush", "branch_id": 2, "branch_mask_hex": "0xf"},
                    {"event": "lifecycle_flush", "branch_id": 3, "branch_mask_hex": "0xf"},
                    {"event": "token_flush", "count": 4, "branch_mask_hex": "0xf"},
                    {"event": "lifecycle_commit", "branch_id": 0, "branch_mask_hex": "0x1"},
                    {"event": "lifecycle_flush", "branch_id": 1, "branch_mask_hex": "0xe"},
                    {"event": "lifecycle_flush", "branch_id": 2, "branch_mask_hex": "0xe"},
                    {"event": "lifecycle_flush", "branch_id": 3, "branch_mask_hex": "0xe"},
                    {"event": "token_flush", "count": 3, "branch_mask_hex": "0xe"},
                    {"event": "flush_reclaim", "group_len": 2, "count": 2},
                    {"event": "flush_reclaim", "group_len": 2, "count": 2},
                ],
            )

            manifest = {
                "mode": "tree_mask_e2e_strict",
                "root_workdir": str(root_workdir),
                "step_count": 1,
                "steps": [
                    {
                        "step_index": 2,
                        "step_kind": "verify_group",
                        "platform_workdir": str(platform_workdir),
                        "expected_generated_token_ids": [60],
                        "branch_hidden_pairs": [
                            {
                                "branch_index": 0,
                                "level_index": 0,
                                "branch_id": 0,
                                "level_id": 0,
                                "branch_path_key": "branch0_level0",
                                "rtl_hidden_path": str(branch_hidden_path),
                                "ref_hidden_path": str(ref_hidden_path),
                                "rtl_token_path": str(branch_token_path),
                                "expected_token_id": 60,
                            }
                        ],
                        "expected_commit_branch_id": 0,
                        "expected_flush_branch_ids": [1, 2, 3],
                        "expected_accepted_prefix_depth": 1,
                        "expected_token_flush_count": 3,
                        "expected_flush_reclaim_count": 3,
                    }
                ],
            }
            root_workdir.mkdir(parents=True, exist_ok=True)
            (root_workdir / "host_vm_manifest.json").write_text(
                json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
                encoding="utf-8",
            )

            summary_path = collect_tree_mask_e2e_strict_workdir(  # type: ignore[misc]
                root_workdir=root_workdir
            )

            summary = json.loads(summary_path.read_text(encoding="utf-8"))
            self.assertTrue(summary["passed"])
            self.assertEqual([60], summary["steps"][0]["actual_generated_token_ids"])
            self.assertEqual(0, summary["steps"][0]["lifecycle"]["commit_branch_id"])
            self.assertEqual([1, 2, 3], summary["steps"][0]["lifecycle"]["flush_branch_ids"])
            self.assertEqual(1, summary["steps"][0]["lifecycle"]["accepted_prefix_depth"])

    @unittest.skipIf(IMPORT_ERROR is not None, "host_vm_flow module not ready yet")
    def test_collect_tree_mask_e2e_strict_workdir_fails_without_required_tree_window_lifecycle(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            tmpdir_path = Path(tmpdir)
            root_workdir = tmpdir_path / "tree_mask_e2e_root_missing"
            steps = []

            for step_idx in range(5):
                step_root = root_workdir / ("step_%03d" % step_idx)
                platform_workdir = step_root / "platform_real_ssd_sync_tree_step_payload"
                _prepare_runtime_platform_workdir(
                    platform_workdir,
                    sequence_id="tree-mask-e2e-miss-%d" % step_idx,
                )
                vector = np.full((128,), np.float16(step_idx + 1), dtype=np.float16)
                rtl_hidden_path = platform_workdir / ("rtl_step%d_final_hidden.memh" % step_idx)
                ref_hidden_path = step_root / ("ref_step%d_final_hidden.npy" % step_idx)
                _write_fp16_memh_vector(rtl_hidden_path, vector)
                np.save(ref_hidden_path, vector.astype(np.float16))
                _write_tree_mask_strict_events(platform_workdir, [20 + step_idx])

                step_manifest = {
                    "step_index": step_idx,
                    "step_kind": "verify_group" if step_idx == 2 else "single_step",
                    "platform_workdir": str(platform_workdir),
                    "expected_generated_token_ids": [20 + step_idx],
                    "rtl_hidden_path": str(rtl_hidden_path),
                    "ref_hidden_path": str(ref_hidden_path),
                }
                if step_idx == 2:
                    step_manifest.update(
                        {
                            "expected_commit_branch_id": 0,
                            "expected_flush_branch_ids": [1, 2, 3],
                            "expected_accepted_prefix_depth": 1,
                            "expected_token_flush_count": 3,
                            "expected_flush_reclaim_count": 3,
                        }
                    )
                steps.append(step_manifest)

            manifest = {
                "mode": "tree_mask_e2e_strict",
                "root_workdir": str(root_workdir),
                "step_count": 5,
                "steps": steps,
            }
            root_workdir.mkdir(parents=True, exist_ok=True)
            (root_workdir / "host_vm_manifest.json").write_text(
                json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
                encoding="utf-8",
            )

            summary_path = collect_tree_mask_e2e_strict_workdir(  # type: ignore[misc]
                root_workdir=root_workdir
            )

            summary = json.loads(summary_path.read_text(encoding="utf-8"))
            self.assertFalse(summary["passed"])
            self.assertEqual(summary["steps"][2]["step_kind"], "verify_group")
            self.assertFalse(summary["steps"][2]["lifecycle"]["passed"])

    @unittest.skipIf(IMPORT_ERROR is not None, "host_vm_flow module not ready yet")
    def test_collect_tree_mask_e2e_strict_workdir_reports_branch_level_tree_window_hidden_comparisons(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            tmpdir_path = Path(tmpdir)
            root_workdir = tmpdir_path / "tree_mask_e2e_root_branch_hidden"
            steps = []

            for step_idx in range(5):
                step_root = root_workdir / ("step_%03d" % step_idx)
                platform_workdir = step_root / "platform_real_ssd_sync_tree_step_payload"
                _prepare_runtime_platform_workdir(
                    platform_workdir,
                    sequence_id="tree-mask-e2e-branch-%d" % step_idx,
                )
                _write_tree_mask_strict_events(
                    platform_workdir,
                    [30 + step_idx],
                    extra_records=(
                        [
                            {"event": "accepted_prefix", "accepted_prefix_depth": 1},
                            {"event": "lifecycle_commit", "branch_id": 0},
                            {"event": "lifecycle_flush", "branch_id": 1},
                            {"event": "lifecycle_flush", "branch_id": 2},
                            {"event": "lifecycle_flush", "branch_id": 3},
                            {"event": "token_flush", "count": 3},
                            {"event": "flush_reclaim", "group_len": 3},
                        ]
                        if step_idx == 2
                        else None
                    ),
                )

                step_manifest = {
                    "step_index": step_idx,
                    "step_kind": "verify_group" if step_idx == 2 else "single_step",
                    "platform_workdir": str(platform_workdir),
                    "expected_generated_token_ids": [30 + step_idx],
                }

                if step_idx == 2:
                    branch_hidden_pairs = []
                    for branch_idx in range(4):
                        vector = np.linspace(
                            np.float32(branch_idx),
                            np.float32(branch_idx) + np.float32(0.5),
                            128,
                            dtype=np.float32,
                        ).astype(np.float16)
                        rtl_hidden_path = (
                            platform_workdir
                            / ("rtl_step2_branch%d_final_hidden.memh" % branch_idx)
                        )
                        ref_hidden_path = (
                            step_root / ("ref_step2_branch%d_final_hidden.npy" % branch_idx)
                        )
                        _write_fp16_memh_vector(rtl_hidden_path, vector)
                        np.save(ref_hidden_path, vector.astype(np.float16))
                        rtl_token_path = (
                            platform_workdir
                            / ("rtl_step2_branch%d_token.txt" % branch_idx)
                        )
                        rtl_token_path.write_text(
                            "%d\n" % (40 + branch_idx),
                            encoding="ascii",
                        )
                        branch_hidden_pairs.append(
                            {
                                "branch_index": branch_idx,
                                "level_index": 0,
                                "branch_id": branch_idx,
                                "level_id": 0,
                                "branch_path_key": "branch%d_level0" % branch_idx,
                                "rtl_hidden_path": str(rtl_hidden_path),
                                "ref_hidden_path": str(ref_hidden_path),
                                "rtl_token_path": str(rtl_token_path),
                                "expected_token_id": 40 + branch_idx,
                            }
                        )
                    step_manifest.update(
                        {
                            "expected_generated_token_ids": [40],
                            "branch_hidden_pairs": branch_hidden_pairs,
                            "expected_commit_branch_id": 0,
                            "expected_flush_branch_ids": [1, 2, 3],
                            "expected_accepted_prefix_depth": 1,
                            "expected_token_flush_count": 3,
                            "expected_flush_reclaim_count": 3,
                        }
                    )
                else:
                    vector = np.full(
                        (128,),
                        np.float16(step_idx + 1),
                        dtype=np.float16,
                    )
                    rtl_hidden_path = (
                        platform_workdir / ("rtl_step%d_final_hidden.memh" % step_idx)
                    )
                    ref_hidden_path = (
                        step_root / ("ref_step%d_final_hidden.npy" % step_idx)
                    )
                    _write_fp16_memh_vector(rtl_hidden_path, vector)
                    np.save(ref_hidden_path, vector.astype(np.float16))
                    step_manifest.update(
                        {
                            "rtl_hidden_path": str(rtl_hidden_path),
                            "ref_hidden_path": str(ref_hidden_path),
                        }
                    )

                steps.append(step_manifest)

            manifest = {
                "mode": "tree_mask_e2e_strict",
                "root_workdir": str(root_workdir),
                "step_count": 5,
                "steps": steps,
            }
            root_workdir.mkdir(parents=True, exist_ok=True)
            (root_workdir / "host_vm_manifest.json").write_text(
                json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
                encoding="utf-8",
            )

            summary_path = collect_tree_mask_e2e_strict_workdir(  # type: ignore[misc]
                root_workdir=root_workdir
            )

            summary = json.loads(summary_path.read_text(encoding="utf-8"))
            self.assertTrue(summary["passed"])
            self.assertEqual(summary["steps"][2]["actual_generated_token_ids"], [40])
            self.assertEqual(len(summary["steps"][2]["branch_hidden"]), 4)
            self.assertEqual(0, summary["steps"][2]["branch_hidden"][0]["branch_id"])
            self.assertEqual(0, summary["steps"][2]["branch_hidden"][0]["level_id"])
            self.assertGreater(
                summary["steps"][2]["branch_hidden"][3]["final_hidden"]["cosine_similarity"],
                0.999,
            )

    @unittest.skipIf(IMPORT_ERROR is not None, "host_vm_flow module not ready yet")
    def test_prepare_tree_mask_e2e_strict_workdir_marks_branch_hidden_pairs_with_branch_and_level_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            tmpdir_path = Path(tmpdir)
            package_dir = tmpdir_path / "weight_package"
            build_demo_toy_decoder_package().save(package_dir)  # type: ignore[misc]
            root_workdir = tmpdir_path / "tree_mask_e2e_prepare_branch_level"

            manifest_path = prepare_tree_mask_e2e_strict_workdir(  # type: ignore[misc]
                root_workdir=root_workdir,
                weight_package_dir=package_dir,
            )

            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            branch_hidden_pairs = manifest["steps"][2]["branch_hidden_pairs"]
            self.assertEqual(16, len(branch_hidden_pairs))
            self.assertIn("branch_index", branch_hidden_pairs[0])
            self.assertIn("level_index", branch_hidden_pairs[0])
            self.assertIn("branch_id", branch_hidden_pairs[0])
            self.assertIn("level_id", branch_hidden_pairs[0])
            self.assertIn("branch_path_key", branch_hidden_pairs[0])
            self.assertNotIn("committed", branch_hidden_pairs[0])

    @unittest.skipIf(IMPORT_ERROR is not None, "host_vm_flow module not ready yet")
    def test_collect_tree_mask_e2e_strict_workdir_uses_commit_branch_and_accepted_depth_not_boolean_committed_flag(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            tmpdir_path = Path(tmpdir)
            root_workdir = tmpdir_path / "tree_mask_e2e_root_commit_depth"
            steps = []

            for step_idx in range(5):
                step_root = root_workdir / ("step_%03d" % step_idx)
                platform_workdir = step_root / "platform_real_ssd_sync_tree_step_payload"
                _prepare_runtime_platform_workdir(
                    platform_workdir,
                    sequence_id="tree-mask-e2e-commit-depth-%d" % step_idx,
                )
                _write_tree_mask_strict_events(
                    platform_workdir,
                    [90 + step_idx],
                    extra_records=(
                        [
                            {"event": "accepted_prefix", "accepted_prefix_depth": 2},
                            {"event": "lifecycle_commit", "branch_id": 2},
                            {"event": "lifecycle_flush", "branch_id": 0},
                            {"event": "lifecycle_flush", "branch_id": 1},
                            {"event": "lifecycle_flush", "branch_id": 3},
                            {"event": "token_flush", "count": 3},
                            {"event": "flush_reclaim", "group_len": 3},
                        ]
                        if step_idx == 2
                        else None
                    ),
                )

                step_manifest = {
                    "step_index": step_idx,
                    "step_kind": "verify_group" if step_idx == 2 else "single_step",
                    "platform_workdir": str(platform_workdir),
                    "expected_generated_token_ids": [90 + step_idx],
                }

                if step_idx == 2:
                    branch_hidden_pairs = []
                    token_base = 120
                    for branch_idx in range(4):
                        for level_idx in range(4):
                            token_id = token_base + (branch_idx * 10) + level_idx
                            vector = np.linspace(
                                np.float32(token_id),
                                np.float32(token_id + 0.25),
                                128,
                                dtype=np.float32,
                            ).astype(np.float16)
                            rtl_hidden_path = (
                                platform_workdir
                                / ("rtl_step2_branch%d_level%d_final_hidden.memh" % (branch_idx, level_idx))
                            )
                            ref_hidden_path = (
                                step_root
                                / ("ref_step2_branch%d_level%d_final_hidden.npy" % (branch_idx, level_idx))
                            )
                            rtl_token_path = (
                                platform_workdir
                                / ("rtl_step2_branch%d_level%d_token.txt" % (branch_idx, level_idx))
                            )
                            _write_fp16_memh_vector(rtl_hidden_path, vector)
                            np.save(ref_hidden_path, vector.astype(np.float16))
                            rtl_token_path.write_text("%d\n" % token_id, encoding="ascii")
                            branch_hidden_pairs.append(
                                {
                                    "branch_index": branch_idx,
                                    "level_index": level_idx,
                                    "branch_id": branch_idx,
                                    "level_id": level_idx,
                                    "branch_path_key": "b%d_l%d" % (branch_idx, level_idx),
                                    "rtl_hidden_path": str(rtl_hidden_path),
                                    "ref_hidden_path": str(ref_hidden_path),
                                    "rtl_token_path": str(rtl_token_path),
                                    "expected_token_id": token_id,
                                }
                            )
                    step_manifest.update(
                        {
                            "expected_generated_token_ids": [140, 141],
                            "branch_hidden_pairs": branch_hidden_pairs,
                            "expected_commit_branch_id": 2,
                            "expected_flush_branch_ids": [0, 1, 3],
                            "expected_accepted_prefix_depth": 2,
                            "expected_token_flush_count": 3,
                            "expected_flush_reclaim_count": 3,
                        }
                    )
                else:
                    vector = np.full((128,), np.float16(step_idx + 50), dtype=np.float16)
                    rtl_hidden_path = (
                        platform_workdir / ("rtl_step%d_final_hidden.memh" % step_idx)
                    )
                    ref_hidden_path = (
                        step_root / ("ref_step%d_final_hidden.npy" % step_idx)
                    )
                    _write_fp16_memh_vector(rtl_hidden_path, vector)
                    np.save(ref_hidden_path, vector.astype(np.float16))
                    step_manifest.update(
                        {
                            "rtl_hidden_path": str(rtl_hidden_path),
                            "ref_hidden_path": str(ref_hidden_path),
                        }
                    )

                steps.append(step_manifest)

            manifest = {
                "mode": "tree_mask_e2e_strict",
                "root_workdir": str(root_workdir),
                "step_count": 5,
                "steps": steps,
            }
            root_workdir.mkdir(parents=True, exist_ok=True)
            (root_workdir / "host_vm_manifest.json").write_text(
                json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
                encoding="utf-8",
            )

            summary_path = collect_tree_mask_e2e_strict_workdir(  # type: ignore[misc]
                root_workdir=root_workdir
            )

            summary = json.loads(summary_path.read_text(encoding="utf-8"))
            self.assertTrue(summary["passed"])
            self.assertEqual(
                [140, 141],
                summary["steps"][2]["actual_generated_token_ids"],
            )
            self.assertEqual(
                2,
                summary["steps"][2]["lifecycle"]["accepted_prefix_depth"],
            )
            self.assertEqual(
                2,
                summary["steps"][2]["lifecycle"]["commit_branch_id"],
            )

    @unittest.skipIf(IMPORT_ERROR is not None, "host_vm_flow module not ready yet")
    def test_collect_tree_mask_e2e_strict_workdir_syncs_rtl_artifacts_from_step_vm_return(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            tmpdir_path = Path(tmpdir)
            root_workdir = tmpdir_path / "tree_mask_e2e_vm_return_sync"
            steps = []

            for step_idx in range(5):
                step_root = root_workdir / ("step_%03d" % step_idx)
                platform_workdir = step_root / "platform_real_ssd_sync_tree_step_payload"
                vm_return_dir = step_root / "vm_return"
                _prepare_runtime_platform_workdir(
                    platform_workdir,
                    sequence_id="tree-mask-e2e-sync-%d" % step_idx,
                )
                _write_tree_mask_strict_events(
                    vm_return_dir,
                    [50 + step_idx],
                    extra_records=(
                        [
                            {"event": "accepted_prefix", "accepted_prefix_depth": 1},
                            {"event": "lifecycle_commit", "branch_id": 0},
                            {"event": "lifecycle_flush", "branch_id": 1},
                            {"event": "lifecycle_flush", "branch_id": 2},
                            {"event": "lifecycle_flush", "branch_id": 3},
                            {"event": "token_flush", "count": 3},
                            {"event": "flush_reclaim", "group_len": 3},
                        ]
                        if step_idx == 2
                        else None
                    ),
                )

                step_manifest = {
                    "step_index": step_idx,
                    "step_kind": "verify_group" if step_idx == 2 else "single_step",
                    "platform_workdir": str(platform_workdir),
                    "expected_generated_token_ids": [50 + step_idx],
                    "rtl_token_path": str(platform_workdir / ("rtl_step%d_token.txt" % step_idx)),
                    "rtl_hidden_path": str(
                        platform_workdir / ("rtl_step%d_final_hidden.memh" % step_idx)
                    ),
                    "ref_hidden_path": str(
                        step_root / ("ref_step%d_final_hidden.npy" % step_idx)
                    ),
                }

                if step_idx == 2:
                    branch_hidden_pairs = []
                    for branch_idx in range(4):
                        for level_idx in range(4):
                            token_id = 60 + (branch_idx * 4) + level_idx
                            vector = np.linspace(
                                np.float32(token_id),
                                np.float32(token_id + 0.5),
                                128,
                                dtype=np.float32,
                            ).astype(np.float16)
                            rtl_hidden_path = (
                                vm_return_dir / ("rtl_step2_branch%d_level%d_final_hidden.memh" % (branch_idx, level_idx))
                            )
                            ref_hidden_path = (
                                step_root / ("ref_step2_branch%d_level%d_final_hidden.npy" % (branch_idx, level_idx))
                            )
                            _write_fp16_memh_vector(rtl_hidden_path, vector)
                            np.save(ref_hidden_path, vector.astype(np.float16))
                            rtl_token_path = vm_return_dir / ("rtl_step2_branch%d_level%d_token.txt" % (branch_idx, level_idx))
                            rtl_token_path.parent.mkdir(parents=True, exist_ok=True)
                            rtl_token_path.write_text("%d\n" % token_id, encoding="ascii")
                            branch_hidden_pairs.append(
                                {
                                    "branch_index": branch_idx,
                                    "level_index": level_idx,
                                    "branch_id": branch_idx,
                                    "level_id": level_idx,
                                    "branch_path_key": "branch%d_level%d" % (branch_idx, level_idx),
                                    "rtl_hidden_path": str(
                                        platform_workdir
                                        / ("rtl_step2_branch%d_level%d_final_hidden.memh" % (branch_idx, level_idx))
                                    ),
                                    "ref_hidden_path": str(ref_hidden_path),
                                    "rtl_token_path": str(
                                        platform_workdir
                                        / ("rtl_step2_branch%d_level%d_token.txt" % (branch_idx, level_idx))
                                    ),
                                    "expected_token_id": token_id,
                                }
                            )
                    step_manifest.update(
                        {
                            "expected_generated_token_ids": [60],
                            "verify_group": {
                                "committed_len": 3,
                                "draft_count": 16,
                                "branch_count": 4,
                                "level_count": 4,
                            },
                            "branch_hidden_pairs": branch_hidden_pairs,
                            "expected_commit_branch_id": 0,
                            "expected_flush_branch_ids": [1, 2, 3],
                            "expected_accepted_prefix_depth": 1,
                            "expected_token_flush_count": 3,
                            "expected_flush_reclaim_count": 3,
                        }
                    )
                else:
                    vector = np.full((128,), np.float16(step_idx + 20), dtype=np.float16)
                    rtl_hidden_path = vm_return_dir / ("rtl_step%d_final_hidden.memh" % step_idx)
                    rtl_token_path = vm_return_dir / ("rtl_step%d_token.txt" % step_idx)
                    _write_fp16_memh_vector(rtl_hidden_path, vector)
                    rtl_token_path.parent.mkdir(parents=True, exist_ok=True)
                    rtl_token_path.write_text("%d\n" % (50 + step_idx), encoding="ascii")
                    np.save(
                        step_root / ("ref_step%d_final_hidden.npy" % step_idx),
                        vector.astype(np.float16),
                    )

                steps.append(step_manifest)

            manifest = {
                "mode": "tree_mask_e2e_strict",
                "root_workdir": str(root_workdir),
                "step_count": 5,
                "steps": steps,
            }
            root_workdir.mkdir(parents=True, exist_ok=True)
            (root_workdir / "host_vm_manifest.json").write_text(
                json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
                encoding="utf-8",
            )

            summary_path = collect_tree_mask_e2e_strict_workdir(  # type: ignore[misc]
                root_workdir=root_workdir
            )

            summary = json.loads(summary_path.read_text(encoding="utf-8"))
            self.assertTrue(summary["passed"])
            self.assertTrue(
                (
                    root_workdir
                    / "step_000"
                    / "platform_real_ssd_sync_tree_step_payload"
                    / "rtl_step0_token.txt"
                ).exists()
            )
            self.assertTrue(
                (
                    root_workdir
                    / "step_002"
                    / "platform_real_ssd_sync_tree_step_payload"
                    / "rtl_step2_branch3_level3_token.txt"
                ).exists()
            )

    @unittest.skipIf(IMPORT_ERROR is not None, "host_vm_flow module not ready yet")
    def test_collect_tree_mask_e2e_strict_workdir_falls_back_to_latest_existing_local_capture_for_single_steps(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            tmpdir_path = Path(tmpdir)
            root_workdir = tmpdir_path / "tree_mask_e2e_single_step_local_capture_fallback"
            root_workdir.mkdir(parents=True, exist_ok=True)

            step_root = root_workdir / "step_003"
            platform_workdir = step_root / "platform_real_ssd_sync_tree_step_payload"
            vm_return_dir = step_root / "vm_return"
            _prepare_runtime_platform_workdir(
                platform_workdir,
                sequence_id="tree-mask-e2e-single-step-local-capture-fallback",
            )
            _write_tree_mask_strict_events(vm_return_dir, [14])

            latest_hidden = np.linspace(
                np.float32(1.0),
                np.float32(2.0),
                128,
                dtype=np.float32,
            ).astype(np.float16)
            invalid_hidden_path = vm_return_dir / "rtl_capture_local1_final_hidden.memh"
            invalid_hidden_path.write_text("BAD0\n", encoding="ascii")
            (vm_return_dir / "rtl_capture_local0_token.txt").write_text("0\n", encoding="ascii")
            (vm_return_dir / "rtl_capture_local0_final_hidden.memh").write_text(
                "BAD0\n",
                encoding="ascii",
            )
            (vm_return_dir / "rtl_capture_local1_token.txt").write_text("13\n", encoding="ascii")
            _write_fp16_memh_vector(
                vm_return_dir / "rtl_capture_local2_final_hidden.memh",
                latest_hidden,
            )
            (vm_return_dir / "rtl_capture_local2_token.txt").write_text(
                "14\n",
                encoding="ascii",
            )
            ref_hidden_path = step_root / "ref_step3_final_hidden.npy"
            np.save(ref_hidden_path, latest_hidden.astype(np.float16))

            manifest = {
                "mode": "tree_mask_e2e_strict",
                "root_workdir": str(root_workdir),
                "step_count": 1,
                "steps": [
                    {
                        "step_index": 3,
                        "step_kind": "single_step",
                        "platform_workdir": str(platform_workdir),
                        "rtl_token_path": str(
                            platform_workdir / "rtl_capture_local4_token.txt"
                        ),
                        "rtl_hidden_path": str(
                            platform_workdir / "rtl_capture_local4_final_hidden.memh"
                        ),
                        "ref_hidden_path": str(ref_hidden_path),
                        "expected_generated_token_ids": [14],
                    }
                ],
            }
            (root_workdir / "host_vm_manifest.json").write_text(
                json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
                encoding="utf-8",
            )

            summary_path = collect_tree_mask_e2e_strict_workdir(  # type: ignore[misc]
                root_workdir=root_workdir
            )

            summary = json.loads(summary_path.read_text(encoding="utf-8"))
            self.assertTrue(summary["passed"])
            self.assertEqual([14], summary["steps"][0]["actual_generated_token_ids"])
            self.assertNotIn("error", summary["steps"][0]["final_hidden"])

    @unittest.skipIf(IMPORT_ERROR is not None, "host_vm_flow module not ready yet")
    def test_collect_tree_mask_e2e_strict_workdir_uses_latest_local_capture_token_for_single_steps_even_when_bonus_token_differs(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            tmpdir_path = Path(tmpdir)
            root_workdir = tmpdir_path / "tree_mask_e2e_single_step_local_capture_token"
            root_workdir.mkdir(parents=True, exist_ok=True)

            step_root = root_workdir / "step_004"
            platform_workdir = step_root / "platform_real_ssd_sync_tree_step_payload"
            vm_return_dir = step_root / "vm_return"
            _prepare_runtime_platform_workdir(
                platform_workdir,
                sequence_id="tree-mask-e2e-single-step-local-capture-token",
            )
            _write_tree_mask_strict_events(vm_return_dir, [4])

            hidden = np.linspace(
                np.float32(3.0),
                np.float32(4.0),
                128,
                dtype=np.float32,
            ).astype(np.float16)
            _write_fp16_memh_vector(
                vm_return_dir / "rtl_capture_local2_final_hidden.memh",
                hidden,
            )
            (vm_return_dir / "rtl_capture_local2_token.txt").write_text(
                "14\n",
                encoding="ascii",
            )
            ref_hidden_path = step_root / "ref_step4_final_hidden.npy"
            np.save(ref_hidden_path, hidden.astype(np.float16))

            manifest = {
                "mode": "tree_mask_e2e_strict",
                "root_workdir": str(root_workdir),
                "step_count": 1,
                "steps": [
                    {
                        "step_index": 4,
                        "step_kind": "single_step",
                        "platform_workdir": str(platform_workdir),
                        "rtl_token_path": str(
                            platform_workdir / "rtl_capture_local2_token.txt"
                        ),
                        "rtl_hidden_path": str(
                            platform_workdir / "rtl_capture_local2_final_hidden.memh"
                        ),
                        "ref_hidden_path": str(ref_hidden_path),
                        "expected_generated_token_ids": [14],
                    }
                ],
            }
            (root_workdir / "host_vm_manifest.json").write_text(
                json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
                encoding="utf-8",
            )

            summary_path = collect_tree_mask_e2e_strict_workdir(  # type: ignore[misc]
                root_workdir=root_workdir
            )

            summary = json.loads(summary_path.read_text(encoding="utf-8"))
            self.assertTrue(summary["passed"])
            self.assertEqual([14], summary["steps"][0]["actual_generated_token_ids"])
            self.assertEqual(
                str(platform_workdir / "rtl_capture_local2_token.txt"),
                summary["steps"][0]["rtl_token_path"],
            )

    @unittest.skipIf(IMPORT_ERROR is not None, "host_vm_flow module not ready yet")
    def test_collect_tree_mask_e2e_strict_workdir_reports_unknown_hidden_memh_instead_of_crashing(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            tmpdir_path = Path(tmpdir)
            root_workdir = tmpdir_path / "tree_mask_e2e_unknown_hidden"
            root_workdir.mkdir(parents=True, exist_ok=True)

            step_root = root_workdir / "step_002"
            platform_workdir = step_root / "platform_real_ssd_sync_tree_step_payload"
            vm_return_dir = step_root / "vm_return"
            _prepare_runtime_platform_workdir(
                platform_workdir,
                sequence_id="tree-mask-e2e-unknown-hidden",
            )
            _write_tree_mask_strict_events(
                vm_return_dir,
                [60],
                extra_records=[
                    {"event": "accepted_prefix", "accepted_prefix_depth": 1},
                    {"event": "lifecycle_commit", "branch_id": 0},
                    {"event": "lifecycle_flush", "branch_id": 1},
                    {"event": "lifecycle_flush", "branch_id": 2},
                    {"event": "lifecycle_flush", "branch_id": 3},
                    {"event": "token_flush", "count": 3},
                    {"event": "flush_reclaim", "group_len": 3},
                ],
            )
            branch_hidden_path = vm_return_dir / "rtl_step2_branch0_level0_final_hidden.memh"
            branch_hidden_path.write_text(
                "XXxx0000000000000000000000000000\n",
                encoding="ascii",
            )
            branch_token_path = vm_return_dir / "rtl_step2_branch0_level0_token.txt"
            branch_token_path.write_text("60\n", encoding="ascii")
            ref_hidden_path = step_root / "ref_step2_branch0_level0_final_hidden.npy"
            np.save(ref_hidden_path, np.zeros((8,), dtype=np.float16))

            manifest = {
                "mode": "tree_mask_e2e_strict",
                "root_workdir": str(root_workdir),
                "step_count": 1,
                "steps": [
                    {
                        "step_index": 2,
                        "step_kind": "verify_group",
                        "platform_workdir": str(platform_workdir),
                        "expected_generated_token_ids": [60],
                        "branch_hidden_pairs": [
                            {
                                "branch_index": 0,
                                "level_index": 0,
                                "branch_id": 0,
                                "level_id": 0,
                                "rtl_hidden_path": str(platform_workdir / branch_hidden_path.name),
                                "ref_hidden_path": str(ref_hidden_path),
                                "rtl_token_path": str(platform_workdir / branch_token_path.name),
                                "expected_token_id": 60,
                            }
                        ],
                        "expected_commit_branch_id": 0,
                        "expected_flush_branch_ids": [1, 2, 3],
                        "expected_accepted_prefix_depth": 1,
                        "expected_token_flush_count": 3,
                        "expected_flush_reclaim_count": 3,
                    }
                ],
            }
            (root_workdir / "host_vm_manifest.json").write_text(
                json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
                encoding="utf-8",
            )

            summary_path = collect_tree_mask_e2e_strict_workdir(  # type: ignore[misc]
                root_workdir=root_workdir
            )
            summary = json.loads(summary_path.read_text(encoding="utf-8"))
            self.assertFalse(summary["passed"])
            self.assertEqual(
                "unknown_memh_hex",
                summary["steps"][0]["branch_hidden"][0]["final_hidden"]["error"],
            )

    @unittest.skipIf(IMPORT_ERROR is not None, "host_vm_flow module not ready yet")
    def test_collect_tree_mask_e2e_strict_workdir_reports_missing_branch_artifact_instead_of_crashing(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            tmpdir_path = Path(tmpdir)
            root_workdir = tmpdir_path / "tree_mask_e2e_missing_branch_artifact"
            root_workdir.mkdir(parents=True, exist_ok=True)

            step_root = root_workdir / "step_002"
            platform_workdir = step_root / "platform_real_ssd_sync_tree_step_payload"
            vm_return_dir = step_root / "vm_return"
            _prepare_runtime_platform_workdir(
                platform_workdir,
                sequence_id="tree-mask-e2e-missing-branch-artifact",
            )
            _write_tree_mask_strict_events(
                vm_return_dir,
                [60],
                extra_records=[
                    {"event": "accepted_prefix", "accepted_prefix_depth": 1},
                    {"event": "lifecycle_commit", "branch_id": 0},
                    {"event": "lifecycle_flush", "branch_id": 1},
                    {"event": "lifecycle_flush", "branch_id": 2},
                    {"event": "lifecycle_flush", "branch_id": 3},
                    {"event": "token_flush", "count": 3},
                    {"event": "flush_reclaim", "group_len": 3},
                ],
            )
            branch_hidden_path = vm_return_dir / "rtl_step2_branch0_level0_final_hidden.memh"
            _write_fp16_memh_vector(branch_hidden_path, np.zeros((8,), dtype=np.float16))
            ref_hidden_path = step_root / "ref_step2_branch0_level0_final_hidden.npy"
            np.save(ref_hidden_path, np.zeros((8,), dtype=np.float16))

            manifest = {
                "mode": "tree_mask_e2e_strict",
                "root_workdir": str(root_workdir),
                "step_count": 1,
                "steps": [
                    {
                        "step_index": 2,
                        "step_kind": "verify_group",
                        "platform_workdir": str(platform_workdir),
                        "expected_generated_token_ids": [60],
                        "branch_hidden_pairs": [
                            {
                                "branch_index": 0,
                                "level_index": 0,
                                "branch_id": 0,
                                "level_id": 0,
                                "rtl_hidden_path": str(platform_workdir / branch_hidden_path.name),
                                "ref_hidden_path": str(ref_hidden_path),
                                "rtl_token_path": str(platform_workdir / "rtl_step2_branch0_level0_token.txt"),
                                "expected_token_id": 60,
                            }
                        ],
                        "expected_commit_branch_id": 0,
                        "expected_flush_branch_ids": [1, 2, 3],
                        "expected_accepted_prefix_depth": 1,
                        "expected_token_flush_count": 3,
                        "expected_flush_reclaim_count": 3,
                    }
                ],
            }
            (root_workdir / "host_vm_manifest.json").write_text(
                json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
                encoding="utf-8",
            )

            summary_path = collect_tree_mask_e2e_strict_workdir(  # type: ignore[misc]
                root_workdir=root_workdir
            )
            summary = json.loads(summary_path.read_text(encoding="utf-8"))
            self.assertFalse(summary["passed"])
            self.assertEqual(
                "missing_artifact",
                summary["steps"][0]["branch_hidden"][0]["error"],
            )

    @unittest.skipIf(IMPORT_ERROR is not None, "host_vm_flow module not ready yet")
    def test_prepare_tree_mask_e2e_strict_workdir_creates_five_step_manifest_with_tree_window_branch_refs(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            tmpdir_path = Path(tmpdir)
            package_dir = tmpdir_path / "weight_package"
            build_demo_toy_decoder_package().save(package_dir)  # type: ignore[misc]
            root_workdir = tmpdir_path / "tree_mask_e2e_prepared"

            manifest_path = prepare_tree_mask_e2e_strict_workdir(  # type: ignore[misc]
                root_workdir=root_workdir,
                weight_package_dir=package_dir,
            )

            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            self.assertEqual(manifest["mode"], "tree_mask_e2e_strict")
            self.assertEqual(manifest["step_count"], 5)
            self.assertEqual(manifest["steps"][2]["step_kind"], "verify_group")
            self.assertEqual(manifest["steps"][2]["verify_group"]["committed_len"], 3)
            self.assertEqual(manifest["steps"][2]["verify_group"]["draft_count"], 16)
            self.assertEqual(manifest["steps"][2]["verify_group"]["branch_count"], 4)
            self.assertEqual(manifest["steps"][2]["verify_group"]["level_count"], 4)
            self.assertEqual(
                len(manifest["steps"][2]["branch_hidden_pairs"]),
                16,
            )
            self.assertEqual(
                manifest["steps"][2]["expected_commit_branch_id"],
                0,
            )
            for step_idx, step_manifest in enumerate(manifest["steps"]):
                self.assertEqual(
                    step_manifest["platform_workdir"],
                    str(
                        root_workdir
                        / ("step_%03d" % step_idx)
                        / "platform_real_ssd_sync_tree_step_payload"
                    ),
                )
                self.assertTrue(
                    (
                        root_workdir
                        / ("step_%03d" % step_idx)
                        / "platform_real_ssd_sync_tree_step_payload"
                        / "weights"
                        / "toy_model_fp16"
                        / "sram_preload.memh"
                    ).exists()
                )
            self.assertTrue(
                (
                    root_workdir / "step_002" / "ref_step2_branch0_level0_final_hidden.npy"
                ).exists()
            )
            self.assertTrue(
                (
                    root_workdir / "tree_mask_e2e_strict_scenario.json"
                ).exists()
            )
            for step_idx in (0, 1, 3, 4):
                payload = json.loads(
                    (
                        root_workdir
                        / ("step_%03d" % step_idx)
                        / "platform_real_ssd_sync_tree_step_payload"
                        / "sync_tree_step_request.json"
                    ).read_text(encoding="utf-8")
                )
                request = payload["native_tree_request"]
                self.assertEqual(
                    int(request["frontier_tree_mask_en_by_level"][0]),
                    0,
                    msg="step_%03d should not enable tree-mask" % step_idx,
                )
                self.assertTrue(
                    Path(manifest["steps"][step_idx]["rtl_token_path"]).name.startswith(
                        "rtl_capture_local"
                    )
                )
                self.assertTrue(
                    Path(manifest["steps"][step_idx]["rtl_hidden_path"]).name.startswith(
                        "rtl_capture_local"
                    )
                )

            step0_payload = json.loads(
                (
                    root_workdir
                    / "step_000"
                    / "platform_real_ssd_sync_tree_step_payload"
                    / "sync_tree_step_request.json"
                ).read_text(encoding="utf-8")
            )
            self.assertEqual(step0_payload["prompt_token_ids"], [])
            self.assertEqual(step0_payload["recovery_token"], 0)
            self.assertEqual(
                step0_payload["native_tree_request"]["prefix_slot_valid"],
                0b0001,
            )
            self.assertEqual(
                step0_payload["native_tree_request"]["prefix_token_ids"][:1],
                [0],
            )
            self.assertEqual(
                step0_payload["native_tree_request"]["prefix_position_ids"][:1],
                [0],
            )
            self.assertEqual(step0_payload["accepted_tokens"], [0, 14])
            self.assertEqual(
                step0_payload["native_tree_request"]["frontier_position_ids_by_level"][0][0],
                1,
            )
            self.assertEqual(
                step0_payload["native_tree_request"]["frontier_referenced_position_ids_by_level"][0][0],
                0,
            )
            step2_payload = json.loads(
                (
                    root_workdir
                    / "step_002"
                    / "platform_real_ssd_sync_tree_step_payload"
                    / "sync_tree_step_request.json"
                ).read_text(encoding="utf-8")
            )
            self.assertEqual(
                [len(branch) for branch in step2_payload["speculated_branches"]],
                [4, 4, 4, 4],
            )
            step2_request = step2_payload["native_tree_request"]
            self.assertEqual(step2_request["committed_len"], 3)
            self.assertEqual(step2_request["prefix_slot_valid"], 0b0011)
            self.assertEqual(step2_request["prefix_token_ids"][:2], [0, 14])
            self.assertEqual(step2_request["prefix_position_ids"][:2], [0, 1])
            self.assertEqual(step2_request["draft_count"], 16)
            self.assertEqual(step2_request["branch_count"], 4)
            self.assertEqual(
                step2_request["frontier_position_ids_by_level"][0][:4],
                [3, 3, 3, 3],
            )
            self.assertEqual(
                step2_request["frontier_referenced_position_ids_by_level"][3][:4],
                [5, 5, 5, 5],
            )

    @unittest.skipIf(IMPORT_ERROR is not None, "host_vm_flow module not ready yet")
    def test_prepare_tree_mask_e2e_strict_workdir_uses_accepted_token_hidden_for_single_steps(self) -> None:
        from toy_model.toy_model_reference import build_weights, run_reference  # type: ignore

        with tempfile.TemporaryDirectory() as tmpdir:
            tmpdir_path = Path(tmpdir)
            package_dir = tmpdir_path / "weight_package"
            build_demo_toy_decoder_package().save(package_dir)  # type: ignore[misc]
            root_workdir = tmpdir_path / "tree_mask_e2e_prepared"

            prepare_tree_mask_e2e_strict_workdir(  # type: ignore[misc]
                root_workdir=root_workdir,
                weight_package_dir=package_dir,
            )

            weights = build_weights()
            kv_cache_k = np.zeros((2, 8, 2, 64), dtype=np.float16)
            kv_cache_v = np.zeros((2, 8, 2, 64), dtype=np.float16)
            _, kv_cache_k, kv_cache_v = run_reference(
                weights, token_id=0, position=0, kv_cache_k=kv_cache_k, kv_cache_v=kv_cache_v
            )
            step0_hidden, kv_cache_k, kv_cache_v = run_reference(
                weights, token_id=14, position=1, kv_cache_k=kv_cache_k, kv_cache_v=kv_cache_v
            )

            saved_step0 = np.load(
                root_workdir / "step_000" / "ref_step0_final_hidden.npy"
            ).astype(np.float16)
            self.assertTrue(
                np.allclose(
                    saved_step0.astype(np.float32),
                    np.asarray(step0_hidden["final_hidden"], dtype=np.float16).astype(np.float32),
                    rtol=1e-5,
                    atol=1e-5,
                )
            )

    @unittest.skipIf(IMPORT_ERROR is not None, "host_vm_flow module not ready yet")
    def test_prepare_tree_mask_e2e_strict_workdir_uses_local_capture_paths_for_single_steps(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            tmpdir_path = Path(tmpdir)
            package_dir = tmpdir_path / "weight_package"
            build_demo_toy_decoder_package().save(package_dir)  # type: ignore[misc]
            root_workdir = tmpdir_path / "tree_mask_e2e_prepared"

            manifest_path = prepare_tree_mask_e2e_strict_workdir(  # type: ignore[misc]
                root_workdir=root_workdir,
                weight_package_dir=package_dir,
            )

            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            for step_idx in (0, 1, 3, 4):
                self.assertTrue(
                    Path(manifest["steps"][step_idx]["rtl_token_path"]).name.startswith(
                        "rtl_capture_local"
                    )
                )
                self.assertTrue(
                    Path(manifest["steps"][step_idx]["rtl_hidden_path"]).name.startswith(
                        "rtl_capture_local"
                    )
                )

    @unittest.skipIf(IMPORT_ERROR is not None, "host_vm_flow module not ready yet")
    def test_prepare_tree_mask_e2e_strict_workdir_branch_hidden_uses_branch_serial_history(self) -> None:
        from toy_model.toy_model_reference import build_weights, run_reference  # type: ignore

        with tempfile.TemporaryDirectory() as tmpdir:
            tmpdir_path = Path(tmpdir)
            package_dir = tmpdir_path / "weight_package"
            build_demo_toy_decoder_package().save(package_dir)  # type: ignore[misc]
            root_workdir = tmpdir_path / "tree_mask_e2e_prepared"

            prepare_tree_mask_e2e_strict_workdir(  # type: ignore[misc]
                root_workdir=root_workdir,
                weight_package_dir=package_dir,
            )

            weights = build_weights()
            kv_cache_k = np.zeros((2, 8, 2, 64), dtype=np.float16)
            kv_cache_v = np.zeros((2, 8, 2, 64), dtype=np.float16)
            _, kv_cache_k, kv_cache_v = run_reference(
                weights, token_id=0, position=0, kv_cache_k=kv_cache_k, kv_cache_v=kv_cache_v
            )
            _, kv_cache_k, kv_cache_v = run_reference(
                weights, token_id=14, position=1, kv_cache_k=kv_cache_k, kv_cache_v=kv_cache_v
            )
            _, kv_cache_k, kv_cache_v = run_reference(
                weights, token_id=14, position=2, kv_cache_k=kv_cache_k, kv_cache_v=kv_cache_v
            )
            _, branch1_k, branch1_v = run_reference(
                weights, token_id=15, position=3, kv_cache_k=kv_cache_k.copy(), kv_cache_v=kv_cache_v.copy()
            )
            branch1_level1, _, _ = run_reference(
                weights, token_id=3, position=4, kv_cache_k=branch1_k, kv_cache_v=branch1_v
            )

            saved_branch1_level1 = np.load(
                root_workdir / "step_002" / "ref_step2_branch1_level1_final_hidden.npy"
            ).astype(np.float16)
            self.assertTrue(
                np.allclose(
                    saved_branch1_level1.astype(np.float32),
                    np.asarray(branch1_level1["final_hidden"], dtype=np.float16).astype(np.float32),
                    rtol=1e-5,
                    atol=1e-5,
                )
            )

    @unittest.skipIf(IMPORT_ERROR is not None, "host_vm_flow module not ready yet")
    def test_prepare_tree_mask_e2e_strict_workdir_removes_stale_rtl_artifacts(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            tmpdir_path = Path(tmpdir)
            package_dir = tmpdir_path / "weight_package"
            build_demo_toy_decoder_package().save(package_dir)  # type: ignore[misc]
            root_workdir = tmpdir_path / "tree_mask_e2e_prepared"
            stale_rtl_token = (
                root_workdir
                / "step_000"
                / "platform_real_ssd_sync_tree_step_payload"
                / "rtl_step0_token.txt"
            )
            stale_rtl_token.parent.mkdir(parents=True, exist_ok=True)
            stale_rtl_token.write_text("999\n", encoding="ascii")

            prepare_tree_mask_e2e_strict_workdir(  # type: ignore[misc]
                root_workdir=root_workdir,
                weight_package_dir=package_dir,
            )

            self.assertFalse(stale_rtl_token.exists(), msg=str(stale_rtl_token))

    def test_host_vm_scripts_and_inputs_exist(self) -> None:
        expected_paths = [
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
            / "30_vcs_control_chip_stage2_single_chiplet_real_ssd_sync_tree_step_payload_bringup"
            / "scripts"
            / "run_tb_control_chip_stage2_single_chiplet_real_ssd_sync_tree_step_payload_vm_prepared.sh",
            REPO_ROOT
            / "verification"
            / "stage2"
            / "30_vcs_control_chip_stage2_single_chiplet_real_ssd_sync_tree_step_payload_bringup"
            / "scripts"
            / "host_vm_single_step_payload.json",
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
            REPO_ROOT
            / "verification"
            / "stage2"
            / "31_vcs_control_chip_stage2_single_chiplet_ssd_sync_runtime_loop_bringup"
            / "scripts"
            / "run_tb_control_chip_stage2_single_chiplet_ssd_sync_runtime_loop_vm_prepared.sh",
            REPO_ROOT
            / "verification"
            / "stage2"
            / "31_vcs_control_chip_stage2_single_chiplet_ssd_sync_runtime_loop_bringup"
            / "scripts"
            / "host_vm_runtime_loop_2step_trace.jsonl",
            REPO_ROOT
            / "verification"
            / "stage2"
            / "41_vcs_control_chip_stage2_single_chiplet_tree_mask_e2e_strict_bringup"
            / "scripts"
            / "host_prepare_tree_mask_e2e_strict.ps1",
            REPO_ROOT
            / "verification"
            / "stage2"
            / "41_vcs_control_chip_stage2_single_chiplet_tree_mask_e2e_strict_bringup"
            / "scripts"
            / "host_collect_tree_mask_e2e_strict.ps1",
            REPO_ROOT
            / "verification"
            / "stage2"
            / "41_vcs_control_chip_stage2_single_chiplet_tree_mask_e2e_strict_bringup"
            / "scripts"
            / "run_tb_control_chip_stage2_single_chiplet_tree_mask_e2e_strict_vm_prepared.sh",
        ]

        for expected_path in expected_paths:
            self.assertTrue(expected_path.exists(), msg=str(expected_path))

    def test_tree_mask_e2e_strict_vm_script_is_not_a_stage30_placeholder(self) -> None:
        run_script = (
            REPO_ROOT
            / "verification"
            / "stage2"
            / "41_vcs_control_chip_stage2_single_chiplet_tree_mask_e2e_strict_bringup"
            / "scripts"
            / "run_tb_control_chip_stage2_single_chiplet_tree_mask_e2e_strict_vm_prepared.sh"
        )
        script_text = run_script.read_text(encoding="utf-8")
        self.assertIn('for step_dir in "${LOCAL_RUN_ROOT}"/step_*;', script_text)
        self.assertIn("run_tb_control_chip_stage2_single_chiplet_real_ssd_sync_tree_step_payload_vm_prepared.sh", script_text)
        self.assertIn("+strict_capture_index_base=", script_text)

    def test_tree_mask_e2e_strict_vm_script_overrides_nested_stage30_timeout(self) -> None:
        run_script = (
            REPO_ROOT
            / "verification"
            / "stage2"
            / "41_vcs_control_chip_stage2_single_chiplet_tree_mask_e2e_strict_bringup"
            / "scripts"
            / "run_tb_control_chip_stage2_single_chiplet_tree_mask_e2e_strict_vm_prepared.sh"
        )
        script_text = run_script.read_text(encoding="utf-8")
        self.assertIn(
            'export MAX_POST_STIMULUS_CYCLES="${MAX_POST_STIMULUS_CYCLES:-32000000}"',
            script_text,
        )

    def test_native_tree_platform_driver_vm_scripts_include_comparator_dependency(self) -> None:
        direct_compile_scripts = [
            REPO_ROOT
            / "verification"
            / "stage2"
            / "29_vcs_control_chip_stage2_single_chiplet_native_tree_main_frontend_real_vector_weight_bringup"
            / "scripts"
            / "run_tb_control_chip_stage2_single_chiplet_native_tree_main_frontend_real_vector_weight_bringup.sh",
            REPO_ROOT
            / "verification"
            / "stage2"
            / "30_vcs_control_chip_stage2_single_chiplet_real_ssd_sync_tree_step_payload_bringup"
            / "scripts"
            / "run_tb_control_chip_stage2_single_chiplet_real_ssd_sync_tree_step_payload_vm_prepared.sh",
        ]

        for script_path in direct_compile_scripts:
            script_text = script_path.read_text(encoding="utf-8")
            self.assertIn(
                "code/rtl/tree_control/comparator.v",
                script_text,
                msg=str(script_path),
            )

    def test_stage30_vm_prepared_script_copies_strict_tree_mask_artifacts(self) -> None:
        script_path = (
            REPO_ROOT
            / "verification"
            / "stage2"
            / "30_vcs_control_chip_stage2_single_chiplet_real_ssd_sync_tree_step_payload_bringup"
            / "scripts"
            / "run_tb_control_chip_stage2_single_chiplet_real_ssd_sync_tree_step_payload_vm_prepared.sh"
        )
        script_text = script_path.read_text(encoding="utf-8")
        self.assertIn("rtl_step*_final_hidden.memh", script_text)
        self.assertIn("rtl_step*_token.txt", script_text)
        self.assertIn("rtl_capture_local*_final_hidden.memh", script_text)
        self.assertIn("rtl_capture_local*_token.txt", script_text)
        self.assertIn("rtl_step2_branch*_level*_final_hidden.memh", script_text)
        self.assertIn("rtl_step2_branch*_level*_token.txt", script_text)

    def test_stage30_vm_prepared_script_rejects_stale_stimulus_manifest(self) -> None:
        script_path = (
            REPO_ROOT
            / "verification"
            / "stage2"
            / "30_vcs_control_chip_stage2_single_chiplet_real_ssd_sync_tree_step_payload_bringup"
            / "scripts"
            / "run_tb_control_chip_stage2_single_chiplet_real_ssd_sync_tree_step_payload_vm_prepared.sh"
        )
        script_text = script_path.read_text(encoding="utf-8")
        self.assertIn("EXPECTED_STIMULUS_BITS", script_text)
        self.assertIn("stimulus_bits", script_text)
        self.assertIn("host_prepare_sync_tree_step.ps1", script_text)

    def test_stage30_vm_prepared_script_preserves_vm_return_on_failure(self) -> None:
        script_path = (
            REPO_ROOT
            / "verification"
            / "stage2"
            / "30_vcs_control_chip_stage2_single_chiplet_real_ssd_sync_tree_step_payload_bringup"
            / "scripts"
            / "run_tb_control_chip_stage2_single_chiplet_real_ssd_sync_tree_step_payload_vm_prepared.sh"
        )
        script_text = script_path.read_text(encoding="utf-8")
        self.assertIn("copy_vm_return_artifacts()", script_text)
        self.assertIn("set +e", script_text)
        self.assertIn("set -e", script_text)
        self.assertIn('mkdir -p "${VM_RESULT_COPY_DIR}"', script_text)

    def test_tree_mask_e2e_vm_prepared_script_rejects_stale_stimulus_manifest(self) -> None:
        script_path = (
            REPO_ROOT
            / "verification"
            / "stage2"
            / "41_vcs_control_chip_stage2_single_chiplet_tree_mask_e2e_strict_bringup"
            / "scripts"
            / "run_tb_control_chip_stage2_single_chiplet_tree_mask_e2e_strict_vm_prepared.sh"
        )
        script_text = script_path.read_text(encoding="utf-8")
        self.assertIn("EXPECTED_STIMULUS_BITS", script_text)
        self.assertIn("stimulus_bits", script_text)
        self.assertIn("host_prepare_tree_mask_e2e_strict.ps1", script_text)

    def test_platform_driver_tb_declares_strict_tree_mask_artifacts(self) -> None:
        tb_path = (
            REPO_ROOT
            / "code"
            / "tb"
            / "tree_control_tb"
            / "tb_control_chip_stage2_single_chiplet_native_tree_main_frontend_platform_driver.v"
        )
        tb_text = tb_path.read_text(encoding="utf-8")
        required_markers = [
            "rtl_step2_branch0_level0_final_hidden.memh",
            "rtl_step2_branch3_level3_token.txt",
            "rtl_capture_local%0d_final_hidden.memh",
            "rtl_capture_local%0d_token.txt",
            "\"verify_group_capture\"",
            "\"verify_group_issue\"",
            "\"verify_group_done\"",
            "\"accepted_token\"",
            "\"accepted_prefix\"",
            "\"bonus_token\"",
            "\"lifecycle_commit\"",
            "\"lifecycle_flush\"",
            "\"token_flush\"",
            "\"flush_reclaim\"",
        ]
        for marker in required_markers:
            self.assertIn(marker, tb_text, msg=marker)

    def test_platform_driver_tb_dumps_single_step_query_token_not_bonus_wb_token(self) -> None:
        tb_path = (
            REPO_ROOT
            / "code"
            / "tb"
            / "tree_control_tb"
            / "tb_control_chip_stage2_single_chiplet_native_tree_main_frontend_platform_driver.v"
        )
        tb_text = tb_path.read_text(encoding="utf-8")
        self.assertIn(
            'u_control_chip_stage2_single_chiplet.wb_generated_token_id_w',
            tb_text,
        )
        self.assertIn(
            "reg [`TOKEN_ID_W-1:0] strict_capture_query_token_r;",
            tb_text,
        )
        self.assertIn(
            "strict_capture_query_token_r <=\n"
            "                    u_control_chip_stage2_single_chiplet.issue_token_id;",
            tb_text,
        )
        self.assertIn(
            "dump_strict_hidden_and_token(\n"
            "                    strict_capture_index_r,\n"
            "                    strict_branch_slot_r,\n"
            "                    strict_capture_query_token_r",
            tb_text,
        )
        self.assertNotIn(
            "dump_strict_hidden_and_token(\n"
            "                    strict_capture_index_r,\n"
            "                    strict_branch_slot_r,\n"
            "                    wb_token_id",
            tb_text,
        )

    def test_platform_driver_tb_force_mem_write_beat_avoids_auto_var_force_rhs(self) -> None:
        tb_path = (
            REPO_ROOT
            / "code"
            / "tb"
            / "tree_control_tb"
            / "tb_control_chip_stage2_single_chiplet_native_tree_main_frontend_platform_driver.v"
        )
        tb_text = tb_path.read_text(encoding="utf-8")
        self.assertIn("reg [`SRAM_ADDR_W-1:0] forced_mem_req_addr_shadow_r;", tb_text)
        self.assertIn("reg [`SRAM_WDATA_W-1:0] forced_mem_req_wdata_shadow_r;", tb_text)
        self.assertIn("forced_mem_req_addr_shadow_r = sram_addr_i;", tb_text)
        self.assertIn("forced_mem_req_wdata_shadow_r = sram_data_i;", tb_text)
        self.assertIn("forced_mem_req_addr_shadow_r};", tb_text)
        self.assertIn("forced_mem_req_wdata_shadow_r};", tb_text)
        self.assertNotIn("mem_req_addr =\n        {{((`MEM_REQ_LANES-1)*`SRAM_ADDR_W){1'b0}}, sram_addr_i};", tb_text)
        self.assertNotIn("mem_req_wdata =\n        {{((`MEM_REQ_LANES-1)*`SRAM_WDATA_W){1'b0}}, sram_data_i};", tb_text)

    def test_platform_driver_tb_supports_strict_capture_index_base_plusarg(self) -> None:
        tb_path = (
            REPO_ROOT
            / "code"
            / "tb"
            / "tree_control_tb"
            / "tb_control_chip_stage2_single_chiplet_native_tree_main_frontend_platform_driver.v"
        )
        tb_text = tb_path.read_text(encoding="utf-8")
        self.assertIn("integer strict_capture_index_base_r;", tb_text)
        self.assertIn('$value$plusargs("strict_capture_index_base=%d"', tb_text)
        self.assertIn("strict_capture_index_r <= strict_capture_index_base_r;", tb_text)

    def test_tree_mask_e2e_strict_vm_script_runs_steps_separately(self) -> None:
        run_script = (
            REPO_ROOT
            / "verification"
            / "stage2"
            / "41_vcs_control_chip_stage2_single_chiplet_tree_mask_e2e_strict_bringup"
            / "scripts"
            / "run_tb_control_chip_stage2_single_chiplet_tree_mask_e2e_strict_vm_prepared.sh"
        )
        script_text = run_script.read_text(encoding="utf-8")
        self.assertIn('for step_dir in "${LOCAL_RUN_ROOT}"/step_*;', script_text)
        self.assertIn("+strict_capture_index_base=", script_text)
        self.assertIn('platform_real_ssd_sync_tree_step_payload', script_text)


if __name__ == "__main__":
    unittest.main()
