import json
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path


SCRIPT_ROOT = Path(__file__).resolve().parents[2]
if str(SCRIPT_ROOT) not in sys.path:
    sys.path.insert(0, str(SCRIPT_ROOT))


from rtl_runtime.runtime_loop import (  # type: ignore
    RuntimeLoopResult,
    RuntimeLoopStepResult,
    SyncTraceStepProvider,
    run_sync_runtime_loop,
)
from shared_runtime_bridge.bridge import (  # type: ignore
    SharedFolderRuntimeBackendRunner,
    SharedFolderVmBackendPoller,
)


class SharedFolderBridgeTest(unittest.TestCase):
    def _build_payload(self):
        provider = SyncTraceStepProvider(
            step_payloads=[
                {
                    "sequence_id": "bridge-seq-0",
                    "prompt_token_ids": [0x10, 0x11],
                    "step_index": 0,
                    "recovery_token": 0x12,
                    "speculated_tokens": [0x21],
                    "accepted_tokens": [0x12, 0x21],
                    "next_recovery_token": 0x30,
                    "metadata": {"source": "bridge-test"},
                }
            ]
        )
        payload = provider.next_step(None)
        self.assertIsNotNone(payload)
        return payload

    def test_shared_folder_backend_runner_publishes_request_and_reads_response(self) -> None:
        payload = self._build_payload()

        with tempfile.TemporaryDirectory() as tmpdir:
            session_root = Path(tmpdir) / "session_000"
            step_result = RuntimeLoopStepResult(
                sequence_id="bridge-seq-0",
                step_index=0,
                generated_token_ids=[0x21],
                finish_seen=False,
                error_flag=0,
                event_counts={"wb_done": 1},
                workdir="/vm/work/step_000",
                accepted_tokens=[0x12, 0x21],
                next_recovery_token=0x30,
            )

            def respond_from_vm() -> None:
                request_ready = session_root / "step_000" / "request" / "request.ready"
                deadline = time.time() + 2.0
                while time.time() < deadline:
                    if request_ready.exists():
                        break
                    time.sleep(0.01)
                self.assertTrue(request_ready.exists())

                request_json = session_root / "step_000" / "request" / "sync_tree_step_request.json"
                request_payload = json.loads(request_json.read_text(encoding="utf-8"))
                self.assertEqual(request_payload["sequence_id"], "bridge-seq-0")
                self.assertEqual(request_payload["step_index"], 0)

                response_dir = session_root / "step_000" / "response"
                response_dir.mkdir(parents=True, exist_ok=True)
                (response_dir / "logs").mkdir(parents=True, exist_ok=True)
                (response_dir / "step_result.json").write_text(
                    json.dumps(step_result.to_dict(), ensure_ascii=False, indent=2),
                    encoding="utf-8",
                )
                (response_dir / "response_meta.json").write_text(
                    json.dumps({"status": "ok", "step_index": 0}, ensure_ascii=False, indent=2),
                    encoding="utf-8",
                )
                (response_dir / "result.ready").write_text("ready\n", encoding="utf-8")

            thread = threading.Thread(target=respond_from_vm)
            thread.start()
            runner = SharedFolderRuntimeBackendRunner(
                session_root=session_root,
                poll_interval_ms=10,
                timeout_seconds=2.0,
            )
            result = runner(payload, Path(tmpdir) / "loop_root" / "step_000")
            thread.join()

        self.assertEqual(result.sequence_id, "bridge-seq-0")
        self.assertEqual(result.step_index, 0)
        self.assertEqual(result.generated_token_ids, [0x21])
        self.assertEqual(result.next_recovery_token, 0x30)

    def test_vm_poller_claims_request_and_writes_response_once(self) -> None:
        payload = self._build_payload()

        with tempfile.TemporaryDirectory() as tmpdir:
            session_root = Path(tmpdir) / "session_000"
            request_dir = session_root / "step_000" / "request"
            request_dir.mkdir(parents=True, exist_ok=True)
            (request_dir / "sync_tree_step_request.json").write_text(
                json.dumps(payload.to_dict(), ensure_ascii=False, indent=2),
                encoding="utf-8",
            )
            (request_dir / "request_meta.json").write_text(
                json.dumps({"sequence_id": "bridge-seq-0", "step_index": 0}, ensure_ascii=False, indent=2),
                encoding="utf-8",
            )
            (request_dir / "request.ready").write_text("ready\n", encoding="utf-8")

            observed = []

            def fake_executor(step_payload, exec_workdir):
                observed.append((step_payload.sequence_id, step_payload.step_index, str(exec_workdir)))
                return RuntimeLoopStepResult(
                    sequence_id=step_payload.sequence_id,
                    step_index=step_payload.step_index,
                    generated_token_ids=[0x21],
                    finish_seen=True,
                    error_flag=0,
                    event_counts={"wb_done": 1, "finish": 1},
                    workdir=str(exec_workdir),
                    accepted_tokens=[0x12, 0x21],
                    next_recovery_token=0x30,
                )

            poller = SharedFolderVmBackendPoller(
                session_root=session_root,
                backend_executor=fake_executor,
                worker_name="vm-test-worker",
            )

            handled = poller.process_next_request()
            handled_again = poller.process_next_request()

            response_dir = session_root / "step_000" / "response"
            step_result = json.loads((response_dir / "step_result.json").read_text(encoding="utf-8"))
            response_meta = json.loads((response_dir / "response_meta.json").read_text(encoding="utf-8"))

        self.assertTrue(handled)
        self.assertFalse(handled_again)
        self.assertEqual(len(observed), 1)
        self.assertEqual(step_result["generated_token_ids"], [0x21])
        self.assertEqual(response_meta["status"], "ok")
        self.assertEqual(response_meta["worker_name"], "vm-test-worker")

    def test_vm_poller_can_execute_in_local_short_path_outside_shared_session(self) -> None:
        payload = self._build_payload()

        with tempfile.TemporaryDirectory() as tmpdir:
            tmpdir_path = Path(tmpdir)
            session_root = tmpdir_path / "very_deep_shared_session_root"
            local_exec_root = tmpdir_path / "local_exec_root"
            request_dir = session_root / "step_000" / "request"
            request_dir.mkdir(parents=True, exist_ok=True)
            (request_dir / "sync_tree_step_request.json").write_text(
                json.dumps(payload.to_dict(), ensure_ascii=False, indent=2),
                encoding="utf-8",
            )
            (request_dir / "request_meta.json").write_text(
                json.dumps(
                    {"sequence_id": "bridge-seq-0", "step_index": 0},
                    ensure_ascii=False,
                    indent=2,
                ),
                encoding="utf-8",
            )
            (request_dir / "request.ready").write_text("ready\n", encoding="utf-8")

            observed = []

            def fake_executor(step_payload, exec_workdir):
                observed.append(Path(exec_workdir))
                return RuntimeLoopStepResult(
                    sequence_id=step_payload.sequence_id,
                    step_index=step_payload.step_index,
                    generated_token_ids=[0x21],
                    finish_seen=True,
                    error_flag=0,
                    event_counts={"wb_done": 1, "finish": 1},
                    workdir=str(exec_workdir),
                    accepted_tokens=[0x12, 0x21],
                    next_recovery_token=0x30,
                )

            poller = SharedFolderVmBackendPoller(
                session_root=session_root,
                backend_executor=fake_executor,
                worker_name="vm-test-worker",
                local_exec_root=local_exec_root,
            )

            handled = poller.process_next_request()

        self.assertTrue(handled)
        self.assertEqual(len(observed), 1)
        self.assertTrue(str(observed[0]).startswith(str(local_exec_root)))
        self.assertNotIn(str(session_root), str(observed[0]))

    def test_shared_folder_bridge_integrates_with_runtime_loop(self) -> None:
        provider = SyncTraceStepProvider(
            step_payloads=[
                {
                    "sequence_id": "bridge-loop-seq-0",
                    "prompt_token_ids": [0x10, 0x11],
                    "step_index": 0,
                    "recovery_token": 0x12,
                    "speculated_tokens": [0x21],
                    "accepted_tokens": [0x12, 0x21],
                    "next_recovery_token": 0x30,
                    "metadata": {"source": "bridge-loop-test"},
                }
            ]
        )

        with tempfile.TemporaryDirectory() as tmpdir:
            session_root = Path(tmpdir) / "session_000"
            runner = SharedFolderRuntimeBackendRunner(
                session_root=session_root,
                poll_interval_ms=10,
                timeout_seconds=2.0,
            )

            def fake_executor(step_payload, exec_workdir):
                return RuntimeLoopStepResult(
                    sequence_id=step_payload.sequence_id,
                    step_index=step_payload.step_index,
                    generated_token_ids=[0x21],
                    finish_seen=True,
                    error_flag=0,
                    event_counts={"wb_done": 1, "finish": 1},
                    workdir=str(exec_workdir),
                    accepted_tokens=list(step_payload.accepted_tokens),
                    next_recovery_token=step_payload.next_recovery_token,
                )

            poller = SharedFolderVmBackendPoller(
                session_root=session_root,
                backend_executor=fake_executor,
                worker_name="vm-loop-worker",
            )

            stop_flag = {"done": False}

            def serve_vm() -> None:
                deadline = time.time() + 2.0
                while time.time() < deadline and not stop_flag["done"]:
                    if poller.process_next_request():
                        return
                    time.sleep(0.01)

            thread = threading.Thread(target=serve_vm)
            thread.start()
            result = run_sync_runtime_loop(
                provider=provider,
                backend_runner=runner,
                root_workdir=Path(tmpdir) / "runtime_loop_root",
            )
            stop_flag["done"] = True
            thread.join()

        self.assertIsInstance(result, RuntimeLoopResult)
        self.assertEqual(result.sequence_id, "bridge-loop-seq-0")
        self.assertEqual(result.step_count, 1)
        self.assertEqual(result.generated_token_ids, [0x21])
        self.assertTrue(result.finish_seen)


if __name__ == "__main__":
    unittest.main()
