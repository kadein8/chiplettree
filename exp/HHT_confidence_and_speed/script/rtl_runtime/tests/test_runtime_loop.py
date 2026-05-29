import os
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
from pathlib import Path


SCRIPT_ROOT = Path(__file__).resolve().parents[2]
if str(SCRIPT_ROOT) not in sys.path:
    sys.path.insert(0, str(SCRIPT_ROOT))


try:
    from rtl_runtime.runtime_loop import (  # type: ignore
        RealSsdSyncStepProvider,
        RealSsdSyncStepRecord,
        RuntimeLoopResult,
        RuntimeLoopState,
        RuntimeLoopStepResult,
        ShellSyncRuntimeBackendRunner,
        build_step_provider,
        build_backend_runner,
        build_real_ssd_sync_step_provider,
        SyncTraceStepProvider,
        run_sync_runtime_loop,
    )
except ImportError as exc:  # pragma: no cover - exercised in red phase
    IMPORT_ERROR = exc
    RealSsdSyncStepProvider = None  # type: ignore
    RealSsdSyncStepRecord = None  # type: ignore
    RuntimeLoopResult = None  # type: ignore
    RuntimeLoopState = None  # type: ignore
    RuntimeLoopStepResult = None  # type: ignore
    ShellSyncRuntimeBackendRunner = None  # type: ignore
    build_step_provider = None  # type: ignore
    build_backend_runner = None  # type: ignore
    build_real_ssd_sync_step_provider = None  # type: ignore
    SyncTraceStepProvider = None  # type: ignore
    run_sync_runtime_loop = None  # type: ignore
else:
    IMPORT_ERROR = None


class _DummyLiveSequence(object):
    def __init__(self, prompt_token_ids, recovery_token_id) -> None:
        self.prompt_token_ids = list(prompt_token_ids)
        self.recovery_token_id = int(recovery_token_id)


class _FakeLiveStepSource(object):
    def __init__(self) -> None:
        self._records = [
            RealSsdSyncStepRecord(  # type: ignore[misc]
                sequence_before=_DummyLiveSequence([0x10, 0x11], 0x12),
                speculate_result={
                    "speculations": [[0x12, 0x21, 0x22]],
                },
                verify_result={
                    "new_suffixes": [[0x12, 0x21]],
                    "recovery_tokens": [0x30],
                },
                metadata={"source": "fake_live_step_source", "phase": "s0"},
            ),
            RealSsdSyncStepRecord(  # type: ignore[misc]
                sequence_before=_DummyLiveSequence([0x10, 0x11, 0x21], 0x30),
                speculate_result={
                    "speculations": [[0x30, 0x22]],
                },
                verify_result={
                    "new_suffixes": [[0x30, 0x22]],
                    "recovery_tokens": [0x40],
                },
                metadata={"source": "fake_live_step_source", "phase": "s1"},
                stop_after=True,
            ),
        ]
        self._cursor = 0

    def next_step_record(self):
        if self._cursor >= len(self._records):
            return None
        record = self._records[self._cursor]
        self._cursor += 1
        return record


class RuntimeLoopTest(unittest.TestCase):
    def test_runtime_loop_module_is_available(self) -> None:
        self.assertIsNone(IMPORT_ERROR, msg=str(IMPORT_ERROR))

    @unittest.skipIf(IMPORT_ERROR is not None, "runtime_loop module not ready yet")
    def test_sync_runtime_loop_aggregates_multiple_steps(self) -> None:
        provider = SyncTraceStepProvider(  # type: ignore[misc]
            step_payloads=[
                {
                    "sequence_id": "loop-seq-0",
                    "prompt_token_ids": [0x10, 0x11],
                    "step_index": 0,
                    "recovery_token": 0x12,
                    "speculated_tokens": [0x21],
                    "accepted_tokens": [0x12, 0x21],
                    "next_recovery_token": 0x30,
                    "metadata": {"source": "runtime-loop-test", "step_label": "s0"},
                },
                {
                    "sequence_id": "loop-seq-0",
                    "prompt_token_ids": [0x10, 0x11, 0x21],
                    "step_index": 1,
                    "recovery_token": 0x30,
                    "speculated_tokens": [0x22],
                    "accepted_tokens": [0x30, 0x22],
                    "next_recovery_token": 0x40,
                    "metadata": {"source": "runtime-loop-test", "step_label": "s1"},
                },
            ]
        )

        observed = []

        def fake_backend_runner(step_payload, workdir):
            observed.append((step_payload.step_index, Path(workdir).name))
            if step_payload.step_index == 0:
                return RuntimeLoopStepResult(  # type: ignore[misc]
                    sequence_id=step_payload.sequence_id,
                    step_index=0,
                    generated_token_ids=[0x21],
                    finish_seen=False,
                    error_flag=0,
                    event_counts={"native_tree_req": 1, "wb_done": 1},
                    workdir=str(workdir),
                    accepted_tokens=[0x12, 0x21],
                    next_recovery_token=0x30,
                )
            return RuntimeLoopStepResult(  # type: ignore[misc]
                sequence_id=step_payload.sequence_id,
                step_index=1,
                generated_token_ids=[0x22],
                finish_seen=True,
                error_flag=0,
                event_counts={"native_tree_req": 1, "wb_done": 1, "finish": 1},
                workdir=str(workdir),
                accepted_tokens=[0x30, 0x22],
                next_recovery_token=0x40,
            )

        with tempfile.TemporaryDirectory() as tmpdir:
            result = run_sync_runtime_loop(  # type: ignore[misc]
                provider=provider,
                backend_runner=fake_backend_runner,
                root_workdir=Path(tmpdir) / "loop_run",
            )

        self.assertIsInstance(result, RuntimeLoopResult)
        self.assertEqual(result.sequence_id, "loop-seq-0")
        self.assertEqual(result.step_count, 2)
        self.assertEqual(result.generated_token_ids, [0x21, 0x22])
        self.assertEqual(result.all_token_ids, [0x10, 0x11, 0x21, 0x22])
        self.assertTrue(result.finish_seen)
        self.assertEqual(result.error_flag, 0)
        self.assertEqual(result.event_counts["native_tree_req"], 2)
        self.assertEqual(result.event_counts["wb_done"], 2)
        self.assertEqual(result.event_counts["finish"], 1)
        self.assertEqual(len(result.step_results), 2)
        self.assertEqual(observed, [(0, "step_000"), (1, "step_001")])

    @unittest.skipIf(IMPORT_ERROR is not None, "runtime_loop module not ready yet")
    def test_real_ssd_provider_is_lazy_and_reports_missing_deps(self) -> None:
        with self.assertRaises(RuntimeError) as ctx:
            build_real_ssd_sync_step_provider(  # type: ignore[misc]
                sequence_id="loop-seq-0",
                prompt_token_ids=[0x10, 0x11],
            )
        self.assertIn("torch", str(ctx.exception))
        self.assertIn("transformers", str(ctx.exception))

    @unittest.skipIf(IMPORT_ERROR is not None, "runtime_loop module not ready yet")
    def test_real_ssd_sync_provider_builds_payloads_from_live_source(self) -> None:
        provider = RealSsdSyncStepProvider(  # type: ignore[misc]
            sequence_id="live-seq-0",
            prompt_token_ids=[0x10, 0x11],
            live_step_source=_FakeLiveStepSource(),
        )

        state = RuntimeLoopState()  # type: ignore[misc]
        payload0 = provider.next_step(state)
        self.assertIsNotNone(payload0)
        self.assertEqual(payload0.sequence_id, "live-seq-0")
        self.assertEqual(payload0.step_index, 0)
        self.assertEqual(payload0.recovery_token, 0x12)
        self.assertEqual(payload0.speculated_tokens, [0x21, 0x22])
        self.assertEqual(payload0.accepted_tokens, [0x12, 0x21])
        self.assertEqual(payload0.next_recovery_token, 0x30)
        self.assertEqual(payload0.metadata["phase"], "s0")

        state.step_index = 1
        payload1 = provider.next_step(state)
        self.assertIsNotNone(payload1)
        self.assertEqual(payload1.step_index, 1)
        self.assertEqual(payload1.recovery_token, 0x30)
        self.assertEqual(payload1.speculated_tokens, [0x22])
        self.assertEqual(payload1.accepted_tokens, [0x30, 0x22])
        self.assertEqual(payload1.metadata["phase"], "s1")

        state.step_index = 2
        self.assertIsNone(provider.next_step(state))

    @unittest.skipIf(IMPORT_ERROR is not None, "runtime_loop module not ready yet")
    def test_runtime_loop_accepts_real_ssd_sync_provider(self) -> None:
        provider = RealSsdSyncStepProvider(  # type: ignore[misc]
            sequence_id="live-seq-0",
            prompt_token_ids=[0x10, 0x11],
            live_step_source=_FakeLiveStepSource(),
        )

        def fake_backend_runner(step_payload, workdir):
            finish = step_payload.step_index == 1
            generated = step_payload.accepted_tokens[1:]
            return RuntimeLoopStepResult(  # type: ignore[misc]
                sequence_id=step_payload.sequence_id,
                step_index=step_payload.step_index,
                generated_token_ids=generated,
                finish_seen=finish,
                error_flag=0,
                event_counts={"native_tree_req": 1, "wb_done": 1, "finish": 1 if finish else 0},
                workdir=str(workdir),
                accepted_tokens=list(step_payload.accepted_tokens),
                next_recovery_token=step_payload.next_recovery_token,
            )

        with tempfile.TemporaryDirectory() as tmpdir:
            result = run_sync_runtime_loop(  # type: ignore[misc]
                provider=provider,
                backend_runner=fake_backend_runner,
                root_workdir=Path(tmpdir) / "live_loop_run",
            )

        self.assertEqual(result.sequence_id, "live-seq-0")
        self.assertEqual(result.step_count, 2)
        self.assertEqual(result.generated_token_ids, [0x21, 0x22])
        self.assertTrue(result.finish_seen)
        self.assertEqual(result.event_counts["native_tree_req"], 2)
        self.assertEqual(result.event_counts["wb_done"], 2)
        self.assertEqual(result.event_counts["finish"], 1)

    @unittest.skipIf(IMPORT_ERROR is not None, "runtime_loop module not ready yet")
    def test_build_step_provider_supports_trace_and_real_modes(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            trace_path = Path(tmpdir) / "trace.jsonl"
            trace_path.write_text(
                "\n".join(
                    [
                        '{"sequence_id":"trace-seq-0","prompt_token_ids":[16,17],"step_index":0,"recovery_token":18,"speculated_tokens":[33],"accepted_tokens":[18,33],"next_recovery_token":48}',
                        "",
                    ]
                ),
                encoding="utf-8",
                newline="\n",
            )
            trace_provider = build_step_provider(  # type: ignore[misc]
                provider_mode="trace",
                step_trace_jsonl=trace_path,
            )

        self.assertIsInstance(trace_provider, SyncTraceStepProvider)

        real_provider = build_step_provider(  # type: ignore[misc]
            provider_mode="real_ssd_sync",
            sequence_id="live-seq-0",
            prompt_token_ids=[0x10, 0x11],
            live_step_source=_FakeLiveStepSource(),
        )
        self.assertIsInstance(real_provider, RealSsdSyncStepProvider)

    @unittest.skipIf(IMPORT_ERROR is not None, "runtime_loop module not ready yet")
    def test_build_backend_runner_supports_shared_folder_mode(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            runner = build_backend_runner(  # type: ignore[misc]
                backend_mode="shared_folder",
                backend_script=Path(tmpdir) / "unused_backend.sh",
                run_name="unused_run",
                shared_session_root=Path(tmpdir) / "session_000",
                shared_poll_interval_ms=10,
                shared_timeout_seconds=2.0,
            )
        self.assertEqual(runner.__class__.__name__, "SharedFolderRuntimeBackendRunner")

    @unittest.skipIf(IMPORT_ERROR is not None, "runtime_loop module not ready yet")
    def test_runtime_loop_module_runs_without_self_import_warning(self) -> None:
        env = os.environ.copy()
        env["PYTHONPATH"] = str(SCRIPT_ROOT)
        proc = subprocess.run(
            [
                sys.executable,
                "-W",
                "error",
                "-m",
                "rtl_runtime.runtime_loop",
                "--help",
            ],
            env=env,
            capture_output=True,
            text=True,
        )
        self.assertEqual(proc.returncode, 0, msg=proc.stderr)
        self.assertNotIn("RuntimeWarning", proc.stderr)

    @unittest.skipIf(IMPORT_ERROR is not None, "runtime_loop module not ready yet")
    def test_shell_backend_runner_invokes_script_from_its_directory(self) -> None:
        payload = SyncTraceStepProvider(  # type: ignore[misc]
            step_payloads=[
                {
                    "sequence_id": "loop-seq-0",
                    "prompt_token_ids": [0x10, 0x11],
                    "step_index": 0,
                    "recovery_token": 0x12,
                    "speculated_tokens": [0x21],
                    "accepted_tokens": [0x12, 0x21],
                    "next_recovery_token": 0x30,
                }
            ]
        ).next_step(None)
        self.assertIsNotNone(payload)

        with tempfile.TemporaryDirectory() as tmpdir:
            tmpdir_path = Path(tmpdir)
            backend_script = tmpdir_path / "fake_backend.sh"
            backend_script.write_text(
                "\n".join(
                    [
                        "#!/usr/bin/env bash",
                        "set -eu",
                        'RUN_NAME="test_backend_run"',
                        ': "${EXTRA_SENTINEL:?}"',
                        'VCS_WORK_ROOT="${VCS_WORK_ROOT:-$PWD/vcs_work_root}"',
                        'PLATFORM_WORKDIR="${VCS_WORK_ROOT}/${RUN_NAME}/platform_real_ssd_sync_tree_step_payload"',
                        'SOURCE_WORKDIR="$(cd "$(dirname "${SYNC_STEP_JSON}")" && pwd)"',
                        'mkdir -p "${PLATFORM_WORKDIR}"',
                        'test -f "${SYNC_STEP_JSON}"',
                        'cp "${SOURCE_WORKDIR}/runtime_request.json" "${PLATFORM_WORKDIR}/runtime_request.json"',
                        'cp -R "${SOURCE_WORKDIR}/weights" "${PLATFORM_WORKDIR}/weights"',
                        'cp -R "${SOURCE_WORKDIR}/hbm_input" "${PLATFORM_WORKDIR}/hbm_input"',
                        'test -f "${PLATFORM_WORKDIR}/runtime_request.json"',
                        'test -f "${PLATFORM_WORKDIR}/weights/toy_decoder/manifest.json"',
                        'test -f "${PLATFORM_WORKDIR}/hbm_input/manifest.json"',
                        'mkdir -p "${PLATFORM_WORKDIR}/events"',
                        'cat > "${PLATFORM_WORKDIR}/events/events.jsonl" <<\'EOF\'',
                        '{"cycle":1,"event":"wb_done","source":"rtl","token_id_hex":"0x21","wb_error":0}',
                        '{"cycle":2,"event":"finish","source":"rtl","busy_final":0,"error_flag":0}',
                        "EOF",
                    ]
                )
                + "\n",
                encoding="utf-8",
                newline="\n",
            )
            os.chmod(str(backend_script), 0o755)

            runner = ShellSyncRuntimeBackendRunner(  # type: ignore[misc]
                backend_script=backend_script,
                run_name="test_backend_run",
                extra_env={"EXTRA_SENTINEL": "runtime-loop-ok"},
                python_bin="python",
            )
            result = runner(payload, tmpdir_path / "step_000")  # type: ignore[misc]

        self.assertEqual(result.step_index, 0)
        self.assertEqual(result.generated_token_ids, [0x21])
        self.assertTrue(result.finish_seen)

    @unittest.skipIf(IMPORT_ERROR is not None, "runtime_loop module not ready yet")
    def test_shell_backend_runner_uses_absolute_shell_paths_on_posix(self) -> None:
        payload = SyncTraceStepProvider(  # type: ignore[misc]
            step_payloads=[
                {
                    "sequence_id": "loop-seq-0",
                    "prompt_token_ids": [0x10, 0x11],
                    "step_index": 0,
                    "recovery_token": 0x12,
                    "speculated_tokens": [0x21],
                    "accepted_tokens": [0x12, 0x21],
                    "next_recovery_token": 0x30,
                }
            ]
        ).next_step(None)
        self.assertIsNotNone(payload)

        with tempfile.TemporaryDirectory() as tmpdir:
            tmpdir_path = Path(tmpdir)
            backend_script = tmpdir_path / "fake_backend.sh"
            backend_script.write_text(
                "#!/usr/bin/env bash\nexit 0\n",
                encoding="utf-8",
                newline="\n",
            )
            os.chmod(str(backend_script), 0o755)

            runner = ShellSyncRuntimeBackendRunner(  # type: ignore[misc]
                backend_script=backend_script,
                run_name="test_backend_run",
                extra_env={"EXTRA_SENTINEL": "runtime-loop-ok"},
                python_bin="python3",
            )

            with mock.patch(
                "rtl_runtime.runtime_loop._prefer_absolute_shell_paths",
                return_value=True,
            ):
                with mock.patch(
                    "rtl_runtime.runtime_loop.subprocess.run",
                    return_value=mock.Mock(returncode=0),
                ) as run_mock:
                    with mock.patch(
                        "rtl_runtime.runtime_loop.collect_runtime_result",
                        return_value={
                            "sequence_id": "loop-seq-0",
                            "step_index": 0,
                            "generated_token_ids": [0x21],
                            "finish_seen": True,
                            "error_flag": 0,
                            "event_counts": {"wb_done": 1, "finish": 1},
                            "workdir": str(tmpdir_path / "dummy_platform"),
                            "accepted_tokens": [0x12, 0x21],
                            "next_recovery_token": 0x30,
                        },
                    ):
                        result = runner(payload, tmpdir_path / "step_000")  # type: ignore[misc]

            wrapper_path = tmpdir_path / "step_000" / "run_backend_wrapper.sh"
            wrapper_text = wrapper_path.read_text(encoding="utf-8")
            expected_sync_json = str(
                tmpdir_path / "step_000" / "sync_tree_step_request.json"
            ).replace("\\", "/")
            expected_vcs_root = str(
                tmpdir_path / "step_000" / "vcs"
            ).replace("\\", "/")
            expected_wrapper_path = str(wrapper_path).replace("\\", "/")
            self.assertIn(
                "export SYNC_STEP_JSON='{0}'".format(expected_sync_json),
                wrapper_text,
            )
            self.assertIn(
                "export VCS_WORK_ROOT='{0}'".format(expected_vcs_root),
                wrapper_text,
            )
            self.assertEqual(run_mock.call_args[0][0][0], "bash")
            self.assertEqual(run_mock.call_args[0][0][1], expected_wrapper_path)
            self.assertEqual(result.generated_token_ids, [0x21])

    @unittest.skipIf(IMPORT_ERROR is not None, "runtime_loop module not ready yet")
    def test_shell_backend_runner_reports_backend_failure_reason(self) -> None:
        payload = SyncTraceStepProvider(  # type: ignore[misc]
            step_payloads=[
                {
                    "sequence_id": "loop-seq-0",
                    "prompt_token_ids": [0x10, 0x11],
                    "step_index": 0,
                    "recovery_token": 0x12,
                    "speculated_tokens": [0x21],
                    "accepted_tokens": [0x12, 0x21],
                    "next_recovery_token": 0x30,
                }
            ]
        ).next_step(None)
        self.assertIsNotNone(payload)

        with tempfile.TemporaryDirectory() as tmpdir:
            tmpdir_path = Path(tmpdir)
            run_dir = tmpdir_path / "fake_run"
            scripts_dir = run_dir / "scripts"
            logs_dir = run_dir / "logs"
            scripts_dir.mkdir(parents=True, exist_ok=True)
            logs_dir.mkdir(parents=True, exist_ok=True)
            backend_script = scripts_dir / "fake_backend.sh"
            backend_script.write_text(
                "#!/usr/bin/env bash\nexit 1\n",
                encoding="utf-8",
                newline="\n",
            )
            os.chmod(str(backend_script), 0o755)
            (logs_dir / "fake_backend_result.txt").write_text(
                "\n".join(
                    [
                        "reason=python_export_failed",
                        "export_log=/tmp/fake_export.log",
                        "prep_log=/tmp/fake_prep.log",
                    ]
                )
                + "\n",
                encoding="utf-8",
                newline="\n",
            )

            runner = ShellSyncRuntimeBackendRunner(  # type: ignore[misc]
                backend_script=backend_script,
                run_name="test_backend_run",
                python_bin="python",
            )
            with mock.patch(
                "rtl_runtime.runtime_loop.subprocess.run",
                return_value=mock.Mock(returncode=1),
            ):
                with self.assertRaises(RuntimeError) as ctx:
                    runner(payload, tmpdir_path / "step_000")  # type: ignore[misc]

        message = str(ctx.exception)
        self.assertIn("python_export_failed", message)
        self.assertIn("fake_backend_result.txt", message)
        self.assertIn("/tmp/fake_export.log", message)


if __name__ == "__main__":
    unittest.main()
