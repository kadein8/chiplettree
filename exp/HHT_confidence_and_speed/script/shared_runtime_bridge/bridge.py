import json
import hashlib
import shutil
import tempfile
import time
import traceback
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional

from rtl_backend.formats import read_json, write_json
from rtl_backend.ssd_bridge import load_sync_tree_step_payload


def _now_epoch_ms() -> int:
    return int(time.time() * 1000.0)


def _step_dir_name(step_index: int) -> str:
    return "step_{0:03d}".format(int(step_index))


def _session_exec_tag(session_root: Path) -> str:
    digest = hashlib.sha1(
        str(Path(session_root)).encode("utf-8")
    ).hexdigest()[:12]
    return "sess_{0}".format(digest)


def _ensure_session_manifest(session_root: Path) -> Path:
    session_root = Path(session_root)
    session_root.mkdir(parents=True, exist_ok=True)
    manifest_path = session_root / "session_manifest.json"
    if manifest_path.exists():
        return manifest_path
    write_json(
        manifest_path,
        {
            "format": "shared_runtime_bridge_session",
            "version": 1,
            "created_at_epoch_ms": _now_epoch_ms(),
        },
    )
    return manifest_path


def _write_ready_file(path: Path) -> Path:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("ready\n", encoding="utf-8")
    return path


def _step_paths(session_root: Path, step_index: int) -> Dict[str, Path]:
    step_dir = Path(session_root) / _step_dir_name(step_index)
    request_dir = step_dir / "request"
    response_dir = step_dir / "response"
    return {
        "step_dir": step_dir,
        "request_dir": request_dir,
        "response_dir": response_dir,
        "request_json": request_dir / "sync_tree_step_request.json",
        "request_meta_json": request_dir / "request_meta.json",
        "request_ready": request_dir / "request.ready",
        "response_json": response_dir / "step_result.json",
        "response_meta_json": response_dir / "response_meta.json",
        "response_ready": response_dir / "result.ready",
        "response_logs_dir": response_dir / "logs",
        "processing_lock": response_dir / "processing.lock",
        "worker_exec_dir": step_dir / "worker_exec",
    }


def _runtime_loop_step_result_from_dict(payload: Dict[str, Any]) -> object:
    from rtl_runtime.runtime_loop import RuntimeLoopStepResult  # type: ignore

    return RuntimeLoopStepResult.from_dict(payload)


def _runtime_loop_step_result_to_dict(result: object) -> Dict[str, Any]:
    if isinstance(result, dict):
        return dict(result)
    to_dict = getattr(result, "to_dict", None)
    if callable(to_dict):
        return dict(to_dict())
    return {
        "sequence_id": str(getattr(result, "sequence_id")),
        "step_index": int(getattr(result, "step_index")),
        "generated_token_ids": [
            int(token) for token in list(getattr(result, "generated_token_ids", []))
        ],
        "finish_seen": bool(getattr(result, "finish_seen", False)),
        "error_flag": (
            None
            if getattr(result, "error_flag", None) is None
            else int(getattr(result, "error_flag"))
        ),
        "event_counts": {
            str(key): int(value)
            for key, value in dict(getattr(result, "event_counts", {})).items()
        },
        "workdir": str(getattr(result, "workdir", "")),
        "accepted_tokens": [
            int(token) for token in list(getattr(result, "accepted_tokens", []))
        ],
        "next_recovery_token": (
            None
            if getattr(result, "next_recovery_token", None) is None
            else int(getattr(result, "next_recovery_token"))
        ),
    }


def _copy_latest_logs(backend_script: Optional[Path], dst_dir: Path) -> Dict[str, str]:
    copied = {}  # type: Dict[str, str]
    if backend_script is None:
        return copied

    logs_dir = Path(backend_script).parent.parent / "logs"
    if not logs_dir.exists():
        return copied

    dst_dir.mkdir(parents=True, exist_ok=True)
    for pattern in ("*summary.txt", "*_result.txt", "*_run.log"):
        candidates = sorted(
            logs_dir.glob(pattern),
            key=lambda candidate: candidate.stat().st_mtime,
            reverse=True,
        )
        if not candidates:
            continue
        src_path = candidates[0]
        dst_path = dst_dir / src_path.name
        shutil.copy2(str(src_path), str(dst_path))
        copied[src_path.name] = str(dst_path)
    return copied


class SharedFolderRuntimeBackendRunner:
    def __init__(
        self,
        session_root: Path,
        poll_interval_ms: int = 200,
        timeout_seconds: float = 300.0,
        created_by: str = "wsl2_runtime_loop",
    ) -> None:
        self.session_root = Path(session_root)
        self.poll_interval_ms = int(poll_interval_ms)
        self.timeout_seconds = float(timeout_seconds)
        self.created_by = str(created_by)

    def __call__(self, step_payload: object, step_workdir: Path) -> object:
        step_index = int(getattr(step_payload, "step_index"))
        paths = _step_paths(self.session_root, step_index)
        _ensure_session_manifest(self.session_root)

        if paths["request_ready"].exists() or paths["response_ready"].exists():
            raise RuntimeError(
                "shared bridge step already exists: {0}".format(paths["step_dir"])
            )

        paths["request_dir"].mkdir(parents=True, exist_ok=True)
        write_json(paths["request_json"], dict(step_payload.to_dict()))
        write_json(
            paths["request_meta_json"],
            {
                "sequence_id": str(getattr(step_payload, "sequence_id")),
                "step_index": step_index,
                "request_kind": "sync_tree_step",
                "created_by": self.created_by,
                "created_at_epoch_ms": _now_epoch_ms(),
                "client_workdir": str(step_workdir),
            },
        )
        _write_ready_file(paths["request_ready"])

        deadline = time.time() + self.timeout_seconds
        while time.time() < deadline:
            if paths["response_ready"].exists():
                break
            time.sleep(float(self.poll_interval_ms) / 1000.0)

        if not paths["response_ready"].exists():
            raise RuntimeError(
                "shared bridge timeout waiting for result.ready: {0}".format(
                    paths["response_ready"]
                )
            )

        response_meta = {}
        if paths["response_meta_json"].exists():
            response_meta = read_json(paths["response_meta_json"])
        if str(response_meta.get("status", "ok")) != "ok":
            raise RuntimeError(
                "shared bridge backend failed for step {0}: {1}".format(
                    step_index,
                    str(response_meta.get("error_message", "unknown_error")),
                )
            )

        if not paths["response_json"].exists():
            raise RuntimeError(
                "shared bridge missing step_result.json: {0}".format(
                    paths["response_json"]
                )
            )
        return _runtime_loop_step_result_from_dict(read_json(paths["response_json"]))


class SharedFolderVmBackendPoller:
    def __init__(
        self,
        session_root: Path,
        backend_executor: Callable[[object, Path], object],
        worker_name: str = "vm_poller",
        local_exec_root: Optional[Path] = None,
    ) -> None:
        self.session_root = Path(session_root)
        self.backend_executor = backend_executor
        self.worker_name = str(worker_name)
        if local_exec_root is None:
            local_exec_root = Path(tempfile.gettempdir()) / "shared_runtime_bridge_exec"
        self.local_exec_root = Path(local_exec_root)
        self.session_exec_root = self.local_exec_root / _session_exec_tag(
            self.session_root
        )

    def _local_exec_workdir(self, step_index: int) -> Path:
        return self.session_exec_root / _step_dir_name(step_index)

    def _iter_pending_step_indices(self) -> List[int]:
        if not self.session_root.exists():
            return []
        indices = []  # type: List[int]
        for child in sorted(self.session_root.glob("step_*")):
            if not child.is_dir():
                continue
            suffix = child.name.split("_", 1)[-1]
            if not suffix.isdigit():
                continue
            indices.append(int(suffix))
        return indices

    def _claim_step(self, paths: Dict[str, Path]) -> bool:
        if not paths["request_ready"].exists():
            return False
        if paths["response_ready"].exists():
            return False
        paths["response_dir"].mkdir(parents=True, exist_ok=True)
        try:
            with paths["processing_lock"].open("x", encoding="utf-8") as handle:
                handle.write(
                    "worker_name={0}\nclaimed_at_epoch_ms={1}\n".format(
                        self.worker_name,
                        _now_epoch_ms(),
                    )
                )
        except FileExistsError:
            return False
        return True

    def _write_response(
        self,
        paths: Dict[str, Path],
        status: str,
        step_result: Optional[Dict[str, Any]] = None,
        error_message: Optional[str] = None,
        copied_logs: Optional[Dict[str, str]] = None,
    ) -> None:
        response_meta = {
            "status": str(status),
            "worker_name": self.worker_name,
            "completed_at_epoch_ms": _now_epoch_ms(),
            "error_message": error_message,
            "copied_logs": dict(copied_logs or {}),
        }
        if step_result is not None:
            write_json(paths["response_json"], step_result)
            response_meta["step_index"] = int(step_result.get("step_index", 0))
            response_meta["sequence_id"] = str(step_result.get("sequence_id", ""))
        write_json(paths["response_meta_json"], response_meta)
        _write_ready_file(paths["response_ready"])

    def process_next_request(self) -> bool:
        _ensure_session_manifest(self.session_root)
        for step_index in self._iter_pending_step_indices():
            paths = _step_paths(self.session_root, step_index)
            if not self._claim_step(paths):
                continue
            try:
                step_payload = load_sync_tree_step_payload(paths["request_json"])
                exec_workdir = self._local_exec_workdir(step_index)
                if exec_workdir.exists():
                    shutil.rmtree(str(exec_workdir))
                exec_workdir.parent.mkdir(parents=True, exist_ok=True)
                step_result_obj = self.backend_executor(
                    step_payload,
                    exec_workdir,
                )
                step_result = _runtime_loop_step_result_to_dict(step_result_obj)
                copied_logs = _copy_latest_logs(
                    getattr(self.backend_executor, "backend_script", None),
                    paths["response_logs_dir"],
                )
                self._write_response(
                    paths,
                    status="ok",
                    step_result=step_result,
                    copied_logs=copied_logs,
                )
            except Exception as exc:
                copied_logs = _copy_latest_logs(
                    getattr(self.backend_executor, "backend_script", None),
                    paths["response_logs_dir"],
                )
                self._write_response(
                    paths,
                    status="fail",
                    error_message="{0}: {1}".format(
                        exc.__class__.__name__,
                        str(exc),
                    ),
                    copied_logs=copied_logs,
                )
                failure_trace = paths["response_dir"] / "failure_traceback.txt"
                failure_trace.write_text(traceback.format_exc(), encoding="utf-8")
            finally:
                if paths["processing_lock"].exists():
                    paths["processing_lock"].unlink()
            return True
        return False
