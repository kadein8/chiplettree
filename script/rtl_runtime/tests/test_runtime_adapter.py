import json
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT_ROOT = Path(__file__).resolve().parents[2]
if str(SCRIPT_ROOT) not in sys.path:
    sys.path.insert(0, str(SCRIPT_ROOT))


from rtl_backend.ssd_bridge import SequencePrompt  # type: ignore
from rtl_backend.toy_decoder import build_demo_toy_decoder_package  # type: ignore


try:
    from rtl_runtime.runtime_adapter import (  # type: ignore
        RuntimeSequenceResult,
        collect_runtime_result,
        main,
        prepare_runtime_workdir,
        runtime_request_from_sequence_like,
    )
except ImportError as exc:  # pragma: no cover - exercised in red phase
    IMPORT_ERROR = exc
    RuntimeSequenceResult = None  # type: ignore
    collect_runtime_result = None  # type: ignore
    main = None  # type: ignore
    prepare_runtime_workdir = None  # type: ignore
    runtime_request_from_sequence_like = None  # type: ignore
else:
    IMPORT_ERROR = None


class _DummySequence(object):
    def __init__(self) -> None:
        self.seq_id = 7
        self.prompt_token_ids = [0x10, 0x11]
        self.max_new_tokens = 3


class RuntimeAdapterTest(unittest.TestCase):
    def test_runtime_adapter_module_is_available(self) -> None:
        self.assertIsNone(IMPORT_ERROR, msg=str(IMPORT_ERROR))

    @unittest.skipIf(IMPORT_ERROR is not None, "runtime_adapter module not ready yet")
    def test_runtime_request_and_prepare_workdir_from_duck_typed_sequence(self) -> None:
        request = runtime_request_from_sequence_like(  # type: ignore[misc]
            _DummySequence(),
            include_native_tree=True,
            metadata={"source": "ssd-sequence-like"},
        )
        self.assertEqual(request.sequence_id, "7")
        self.assertEqual(request.prompt_token_ids, [16, 17])
        self.assertTrue(request.include_native_tree)

        package = build_demo_toy_decoder_package()
        with tempfile.TemporaryDirectory() as tmpdir:
            workdir = Path(tmpdir) / "runtime_prepare"
            prepare_runtime_workdir(  # type: ignore[misc]
                workdir=workdir,
                request=request,
                package=package,
            )

            runtime_request = json.loads(
                (workdir / "runtime_request.json").read_text(encoding="utf-8")
            )
            sequence_request = json.loads(
                (workdir / "sequence_request.json").read_text(encoding="utf-8")
            )
            self.assertEqual(runtime_request["sequence_id"], "7")
            self.assertEqual(runtime_request["prompt_token_ids"], [16, 17])
            self.assertTrue(runtime_request["include_native_tree"])
            self.assertEqual(sequence_request["sequence_id"], "7")
            self.assertTrue((workdir / "stimulus" / "manifest.json").exists())
            self.assertTrue(
                (workdir / "weights" / "toy_decoder" / "manifest.json").exists()
            )
            self.assertTrue(
                (workdir / "weights" / "toy_model_fp16" / "sram_preload.memh").exists()
            )
            self.assertTrue(
                (workdir / "weights" / "toy_model_fp16" / "hbm_weights.memh").exists()
            )
            self.assertTrue(
                (workdir / "weights" / "toy_model_fp16" / "ref_token_id.txt").exists()
            )

    @unittest.skipIf(IMPORT_ERROR is not None, "runtime_adapter module not ready yet")
    def test_collect_runtime_result_reconstructs_tokens_text_and_counts(self) -> None:
        package = build_demo_toy_decoder_package()
        request = runtime_request_from_sequence_like(  # type: ignore[misc]
            SequencePrompt(
                sequence_id="runtime-seq-0",
                prompt_token_ids=[0x10, 0x11],
                max_new_tokens=4,
            )
        )

        with tempfile.TemporaryDirectory() as tmpdir:
            workdir = Path(tmpdir) / "runtime_collect"
            prepare_runtime_workdir(  # type: ignore[misc]
                workdir=workdir,
                request=request,
                package=package,
            )

            (workdir / "events" / "events.jsonl").write_text(
                "\n".join(
                    [
                        '{"cycle":1,"event":"wb_done","source":"rtl","token_id_hex":"0x11","wb_error":0}',
                        '{"cycle":2,"event":"wb_done","source":"rtl","token_id_hex":"0x12","wb_error":0}',
                        '{"cycle":3,"event":"hbm_write","source":"rtl","addr_hex":"0x20000000","data_hex":"'
                        + ("aa" * 32)
                        + '","req_id":1}',
                        '{"cycle":4,"event":"finish","source":"rtl","busy_final":0,"error_flag":0}',
                    ]
                )
                + "\n",
                encoding="utf-8",
            )

            result = collect_runtime_result(workdir)  # type: ignore[misc]
            self.assertIsInstance(result, RuntimeSequenceResult)
            self.assertEqual(result.sequence_id, "runtime-seq-0")
            self.assertEqual(result.generated_token_ids, [17, 18])
            self.assertEqual(result.all_token_ids, [16, 17, 17, 18])
            self.assertEqual(result.generated_text, "AB")
            self.assertTrue(result.finish_seen)
            self.assertEqual(result.error_flag, 0)
            self.assertEqual(result.wb_done_count, 2)
            self.assertEqual(result.event_counts["wb_done"], 2)
            self.assertEqual(result.event_counts["finish"], 1)

            saved_result = json.loads(
                (workdir / "runtime_result.json").read_text(encoding="utf-8")
            )
            self.assertEqual(saved_result["generated_token_ids"], [17, 18])
            self.assertEqual(saved_result["generated_text"], "AB")

    @unittest.skipIf(IMPORT_ERROR is not None, "runtime_adapter module not ready yet")
    def test_collect_runtime_result_tolerates_unmapped_hbm_write_events(self) -> None:
        package = build_demo_toy_decoder_package()
        request = runtime_request_from_sequence_like(  # type: ignore[misc]
            SequencePrompt(
                sequence_id="runtime-seq-unmapped-hbm",
                prompt_token_ids=[0x10, 0x11],
                max_new_tokens=4,
            )
        )

        with tempfile.TemporaryDirectory() as tmpdir:
            workdir = Path(tmpdir) / "runtime_collect_unmapped_hbm"
            prepare_runtime_workdir(  # type: ignore[misc]
                workdir=workdir,
                request=request,
                package=package,
            )

            (workdir / "events" / "events.jsonl").write_text(
                "\n".join(
                    [
                        '{"cycle":1,"event":"wb_done","source":"rtl","token_id_hex":"0x21","wb_error":0}',
                        '{"cycle":2,"event":"hbm_write","source":"rtl","addr_hex":"0x24030","data_hex":"0","req_id":1}',
                        '{"cycle":3,"event":"finish","source":"rtl","busy_final":0,"error_flag":0}',
                    ]
                )
                + "\n",
                encoding="utf-8",
            )

            result = collect_runtime_result(workdir)  # type: ignore[misc]
            self.assertIsInstance(result, RuntimeSequenceResult)
            self.assertEqual(result.sequence_id, "runtime-seq-unmapped-hbm")
            self.assertEqual(result.generated_token_ids, [33])
            self.assertTrue(result.finish_seen)
            self.assertEqual(result.wb_done_count, 1)
            self.assertEqual(result.event_counts["hbm_write"], 1)
            self.assertTrue((workdir / "hbm_output" / "regions" / "STATE.jsonl").exists())
            self.assertTrue((workdir / "runtime_result.json").exists())

    @unittest.skipIf(IMPORT_ERROR is not None, "runtime_adapter module not ready yet")
    def test_collect_runtime_result_prefers_wb_data_low16_for_generated_tokens(self) -> None:
        package = build_demo_toy_decoder_package()
        request = runtime_request_from_sequence_like(  # type: ignore[misc]
            SequencePrompt(
                sequence_id="runtime-seq-wb-data-token",
                prompt_token_ids=[0x10, 0x11],
                max_new_tokens=1,
            )
        )

        with tempfile.TemporaryDirectory() as tmpdir:
            workdir = Path(tmpdir) / "runtime_collect_wb_data_token"
            prepare_runtime_workdir(  # type: ignore[misc]
                workdir=workdir,
                request=request,
                package=package,
            )

            (workdir / "events" / "events.jsonl").write_text(
                "\n".join(
                    [
                        '{"cycle":1,"event":"wb","source":"rtl","token_id_hex":"0xaa","addr_hex":"0x24030","data_hex":"00000000000000000000000000000021","status_hex":"0x0"}',
                        '{"cycle":2,"event":"wb_done","source":"rtl","token_id_hex":"0xaa","wb_error":0}',
                        '{"cycle":3,"event":"finish","source":"rtl","busy_final":0,"error_flag":0}',
                    ]
                )
                + "\n",
                encoding="utf-8",
            )

            result = collect_runtime_result(workdir)  # type: ignore[misc]
            self.assertIsInstance(result, RuntimeSequenceResult)
            self.assertEqual(result.generated_token_ids, [0x21])
            self.assertEqual(result.wb_done_count, 1)
            self.assertEqual(result.event_counts["wb"], 1)
            self.assertEqual(result.event_counts["wb_done"], 1)

    @unittest.skipIf(IMPORT_ERROR is not None, "runtime_adapter module not ready yet")
    def test_collect_sync_tree_step_result_prefers_wb_done_tokens_over_wb_payload(self) -> None:
        package = build_demo_toy_decoder_package()

        with tempfile.TemporaryDirectory() as tmpdir:
            tmpdir_path = Path(tmpdir)
            package_dir = tmpdir_path / "package"
            payload_path = tmpdir_path / "sync_tree_step_payload.json"
            package.save(package_dir)
            payload_path.write_text(
                json.dumps(
                    {
                        "sequence_id": "runtime-sync-step-wb-done-token",
                        "prompt_token_ids": [0x10, 0x11],
                        "step_index": 0,
                        "recovery_token": 0x12,
                        "speculated_tokens": [[0x21], [0x22], [0x23], [0x24]],
                        "accepted_tokens": [0x12, 0x21],
                        "next_recovery_token": 0x30,
                    },
                    ensure_ascii=False,
                    indent=2,
                )
                + "\n",
                encoding="utf-8",
            )

            status = main(  # type: ignore[misc]
                [
                    "prepare",
                    "--workdir",
                    str(tmpdir_path / "runtime_sync_tree_step"),
                    "--sync-step-json",
                    str(payload_path),
                    "--weight-package-dir",
                    str(package_dir),
                ]
            )
            self.assertEqual(status, 0)

            workdir = tmpdir_path / "runtime_sync_tree_step"
            (workdir / "events" / "events.jsonl").write_text(
                "\n".join(
                    [
                        '{"cycle":1,"event":"wb","source":"rtl","token_id_hex":"0x21","addr_hex":"0x24030","data_hex":"0","status_hex":"0x0"}',
                        '{"cycle":2,"event":"wb_done","source":"rtl","token_id_hex":"0x21","wb_error":0}',
                        '{"cycle":3,"event":"finish","source":"rtl","busy_final":0,"error_flag":0}',
                    ]
                )
                + "\n",
                encoding="utf-8",
            )

            result = collect_runtime_result(workdir)  # type: ignore[misc]
            self.assertIsInstance(result, RuntimeSequenceResult)
            self.assertEqual(result.request_kind, "sync_tree_step")
            self.assertEqual(result.generated_token_ids, [0x21])
            self.assertEqual(result.accepted_tokens, [0x12, 0x21])
            self.assertEqual(result.next_recovery_token, 0x30)

    @unittest.skipIf(IMPORT_ERROR is not None, "runtime_adapter module not ready yet")
    def test_collect_sync_tree_step_result_prefers_rtl_acceptance_events_over_payload_echo(self) -> None:
        package = build_demo_toy_decoder_package()

        with tempfile.TemporaryDirectory() as tmpdir:
            tmpdir_path = Path(tmpdir)
            package_dir = tmpdir_path / "package"
            payload_path = tmpdir_path / "sync_tree_step_payload.json"
            package.save(package_dir)
            payload_path.write_text(
                json.dumps(
                    {
                        "sequence_id": "runtime-sync-step-rtl-acceptance",
                        "prompt_token_ids": [0x10, 0x11],
                        "step_index": 0,
                        "recovery_token": 0x12,
                        "speculated_tokens": [[0x21], [0x22], [0x23], [0x24]],
                        "accepted_tokens": [0x12, 0x7F],
                        "next_recovery_token": 0x55,
                    },
                    ensure_ascii=False,
                    indent=2,
                )
                + "\n",
                encoding="utf-8",
            )

            status = main(  # type: ignore[misc]
                [
                    "prepare",
                    "--workdir",
                    str(tmpdir_path / "runtime_sync_tree_step"),
                    "--sync-step-json",
                    str(payload_path),
                    "--weight-package-dir",
                    str(package_dir),
                ]
            )
            self.assertEqual(status, 0)

            workdir = tmpdir_path / "runtime_sync_tree_step"
            (workdir / "events" / "events.jsonl").write_text(
                "\n".join(
                    [
                        '{"cycle":1,"event":"accepted_token","source":"rtl","token_id_hex":"0x21"}',
                        '{"cycle":2,"event":"bonus_token","source":"rtl","token_id_hex":"0x30"}',
                        '{"cycle":3,"event":"wb","source":"rtl","token_id_hex":"0x21","addr_hex":"0x24030","data_hex":"0","status_hex":"0x0"}',
                        '{"cycle":4,"event":"wb_done","source":"rtl","token_id_hex":"0x21","wb_error":0}',
                        '{"cycle":5,"event":"finish","source":"rtl","busy_final":0,"error_flag":0}',
                    ]
                )
                + "\n",
                encoding="utf-8",
            )

            result = collect_runtime_result(workdir)  # type: ignore[misc]
            self.assertIsInstance(result, RuntimeSequenceResult)
            self.assertEqual(result.request_kind, "sync_tree_step")
            self.assertEqual(result.generated_token_ids, [0x21])
            self.assertEqual(result.accepted_tokens, [0x12, 0x21])
            self.assertEqual(result.next_recovery_token, 0x30)

    @unittest.skipIf(IMPORT_ERROR is not None, "runtime_adapter module not ready yet")
    def test_cli_prepare_and_collect_round_trip(self) -> None:
        package = build_demo_toy_decoder_package()

        with tempfile.TemporaryDirectory() as tmpdir:
            workdir = Path(tmpdir) / "runtime_cli"
            package_dir = Path(tmpdir) / "package"
            package.save(package_dir)

            status = main(  # type: ignore[misc]
                [
                    "prepare",
                    "--workdir",
                    str(workdir),
                    "--prompt-tokens",
                    "0x10,0x11",
                    "--sequence-id",
                    "cli-runtime-0",
                    "--max-new-tokens",
                    "4",
                    "--weight-package-dir",
                    str(package_dir),
                ]
            )
            self.assertEqual(status, 0)
            self.assertTrue((workdir / "runtime_request.json").exists())

            (workdir / "events" / "events.jsonl").write_text(
                "\n".join(
                    [
                        '{"cycle":1,"event":"wb_done","source":"rtl","token_id_hex":"0x11","wb_error":0}',
                        '{"cycle":2,"event":"finish","source":"rtl","busy_final":0,"error_flag":0}',
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
            self.assertEqual(result_json["sequence_id"], "cli-runtime-0")
            self.assertEqual(result_json["generated_token_ids"], [17])


if __name__ == "__main__":
    unittest.main()
