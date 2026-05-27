import argparse
import os
import subprocess
from pathlib import Path
from typing import Any, Callable, Dict, Iterable, List, Optional

from rtl_backend.compat import dataclass, field
from rtl_backend.formats import read_json, write_json
from rtl_backend.ssd_bridge import (
    build_sync_tree_step_payload,
    load_sync_tree_step_payload,
    sync_tree_step_like_to_payload,
)
from rtl_backend.ssd_step import SyncTreeStepPayload
from rtl_runtime.runtime_adapter import (
    collect_runtime_result,
    parse_prompt_tokens,
    prepare_runtime_workdir,
    runtime_request_from_sync_tree_step_like,
)


def _prefer_absolute_shell_paths() -> bool:
    return os.name != "nt"


def _merge_event_counts(
    base: Dict[str, int], update: Dict[str, int]
) -> Dict[str, int]:
    merged = dict(base)
    for key, value in update.items():
        merged[key] = int(merged.get(key, 0)) + int(value)
    return merged


def _read_kv_text_file(path: Path) -> Dict[str, str]:
    values = {}  # type: Dict[str, str]
    path = Path(path)
    if not path.exists():
        return values
    for line in path.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if not stripped or "=" not in stripped:
            continue
        key, value = stripped.split("=", 1)
        values[str(key)] = str(value)
    return values


def _summarize_backend_failure(backend_script: Path) -> str:
    logs_dir = Path(backend_script).parent.parent / "logs"
    if not logs_dir.exists():
        return ""

    parts = []  # type: List[str]
    result_files = sorted(
        logs_dir.glob("*_result.txt"),
        key=lambda path: path.stat().st_mtime,
        reverse=True,
    )
    if result_files:
        result_path = result_files[0]
        parts.append("result_file={0}".format(result_path))
        result_kv = _read_kv_text_file(result_path)
        for key in (
            "reason",
            "compile_status",
            "run_status",
            "judge",
            "export_log",
            "prep_log",
            "compile_log",
            "run_log",
            "sync_step_json",
            "platform_workdir",
        ):
            if key in result_kv:
                parts.append("{0}={1}".format(key, result_kv[key]))

    summary_files = sorted(
        logs_dir.glob("*summary.txt"),
        key=lambda path: path.stat().st_mtime,
        reverse=True,
    )
    if summary_files:
        summary_path = summary_files[0]
        parts.append("summary_file={0}".format(summary_path))
        summary_kv = _read_kv_text_file(summary_path)
        for key in ("judge", "running", "scope"):
            if key in summary_kv:
                parts.append("summary_{0}={1}".format(key, summary_kv[key]))

    return "; ".join(parts)


def _coerce_step_payloads(step_payloads: Iterable[object]) -> List[SyncTreeStepPayload]:
    return [sync_tree_step_like_to_payload(payload) for payload in step_payloads]


@dataclass
class RuntimeLoopState:
    sequence_id: Optional[str] = None
    prompt_token_ids: List[int] = field(default_factory=list)
    generated_token_ids: List[int] = field(default_factory=list)
    step_index: int = 0
    finish_seen: bool = False
    error_flag: Optional[int] = None
    next_recovery_token: Optional[int] = None


@dataclass(frozen=True)
class RuntimeLoopStepResult:
    sequence_id: str
    step_index: int
    generated_token_ids: List[int]
    finish_seen: bool
    error_flag: Optional[int]
    event_counts: Dict[str, int]
    workdir: str
    accepted_tokens: List[int] = field(default_factory=list)
    next_recovery_token: Optional[int] = None

    def to_dict(self) -> Dict[str, Any]:
        return {
            "sequence_id": self.sequence_id,
            "step_index": self.step_index,
            "generated_token_ids": list(self.generated_token_ids),
            "finish_seen": self.finish_seen,
            "error_flag": self.error_flag,
            "event_counts": dict(self.event_counts),
            "workdir": self.workdir,
            "accepted_tokens": list(self.accepted_tokens),
            "next_recovery_token": self.next_recovery_token,
        }

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "RuntimeLoopStepResult":
        return cls(
            sequence_id=str(data["sequence_id"]),
            step_index=int(data["step_index"]),
            generated_token_ids=[
                int(token) for token in list(data.get("generated_token_ids", []))
            ],
            finish_seen=bool(data.get("finish_seen", False)),
            error_flag=(
                None
                if data.get("error_flag") is None
                else int(data.get("error_flag"))
            ),
            event_counts={
                str(key): int(value)
                for key, value in dict(data.get("event_counts", {})).items()
            },
            workdir=str(data["workdir"]),
            accepted_tokens=[
                int(token) for token in list(data.get("accepted_tokens", []))
            ],
            next_recovery_token=(
                None
                if data.get("next_recovery_token") is None
                else int(data.get("next_recovery_token"))
            ),
        )

    @classmethod
    def from_runtime_result(cls, runtime_result: object) -> "RuntimeLoopStepResult":
        step_index = getattr(runtime_result, "step_index", None)
        if step_index is None and isinstance(runtime_result, dict):
            step_index = runtime_result.get("step_index")
        accepted_tokens = getattr(runtime_result, "accepted_tokens", None)
        if accepted_tokens is None and isinstance(runtime_result, dict):
            accepted_tokens = runtime_result.get("accepted_tokens", [])
        next_recovery_token = getattr(runtime_result, "next_recovery_token", None)
        if next_recovery_token is None and isinstance(runtime_result, dict):
            next_recovery_token = runtime_result.get("next_recovery_token")
        event_counts = getattr(runtime_result, "event_counts", None)
        if event_counts is None and isinstance(runtime_result, dict):
            event_counts = runtime_result.get("event_counts", {})
        return cls(
            sequence_id=str(
                getattr(runtime_result, "sequence_id", None)
                if not isinstance(runtime_result, dict)
                else runtime_result.get("sequence_id")
            ),
            step_index=int(step_index if step_index is not None else 0),
            generated_token_ids=[
                int(token)
                for token in list(
                    getattr(runtime_result, "generated_token_ids", None)
                    if not isinstance(runtime_result, dict)
                    else runtime_result.get("generated_token_ids", [])
                )
            ],
            finish_seen=bool(
                getattr(runtime_result, "finish_seen", None)
                if not isinstance(runtime_result, dict)
                else runtime_result.get("finish_seen", False)
            ),
            error_flag=(
                None
                if (
                    getattr(runtime_result, "error_flag", None)
                    if not isinstance(runtime_result, dict)
                    else runtime_result.get("error_flag")
                )
                is None
                else int(
                    getattr(runtime_result, "error_flag", None)
                    if not isinstance(runtime_result, dict)
                    else runtime_result.get("error_flag")
                )
            ),
            event_counts={
                str(key): int(value) for key, value in dict(event_counts or {}).items()
            },
            workdir=str(
                getattr(runtime_result, "workdir", None)
                if not isinstance(runtime_result, dict)
                else runtime_result.get("workdir", "")
            ),
            accepted_tokens=[int(token) for token in list(accepted_tokens or [])],
            next_recovery_token=(
                None
                if next_recovery_token is None
                else int(next_recovery_token)
            ),
        )


@dataclass(frozen=True)
class RuntimeLoopResult:
    sequence_id: str
    prompt_token_ids: List[int]
    step_count: int
    generated_token_ids: List[int]
    all_token_ids: List[int]
    finish_seen: bool
    error_flag: Optional[int]
    event_counts: Dict[str, int]
    step_results: List[RuntimeLoopStepResult]
    root_workdir: str
    next_recovery_token: Optional[int] = None

    def to_dict(self) -> Dict[str, Any]:
        return {
            "sequence_id": self.sequence_id,
            "prompt_token_ids": list(self.prompt_token_ids),
            "step_count": self.step_count,
            "generated_token_ids": list(self.generated_token_ids),
            "all_token_ids": list(self.all_token_ids),
            "finish_seen": self.finish_seen,
            "error_flag": self.error_flag,
            "event_counts": dict(self.event_counts),
            "step_results": [result.to_dict() for result in self.step_results],
            "root_workdir": self.root_workdir,
            "next_recovery_token": self.next_recovery_token,
        }


class SyncTraceStepProvider:
    def __init__(self, step_payloads: Iterable[object]):
        self._step_payloads = _coerce_step_payloads(step_payloads)
        self._cursor = 0

    @classmethod
    def from_jsonl(cls, path: Path) -> "SyncTraceStepProvider":
        payloads = []
        path = Path(path)
        if path.exists():
            for line in path.read_text(encoding="utf-8").splitlines():
                stripped = line.strip()
                if not stripped:
                    continue
                payloads.append(load_sync_tree_step_payload_obj(stripped))
        return cls(payloads)

    def next_step(self, state: Optional[RuntimeLoopState]) -> Optional[SyncTreeStepPayload]:
        if self._cursor >= len(self._step_payloads):
            return None
        payload = self._step_payloads[self._cursor]
        self._cursor += 1
        return payload


def load_sync_tree_step_payload_obj(raw_json: str) -> SyncTreeStepPayload:
    return sync_tree_step_like_to_payload(read_json_like(raw_json))


def read_json_like(raw_json: str) -> Dict[str, Any]:
    import json

    return dict(json.loads(raw_json))


class ShellSyncRuntimeBackendRunner:
    def __init__(
        self,
        backend_script: Path,
        run_name: str,
        extra_env: Optional[Dict[str, str]] = None,
        python_bin: str = "python3",
        platform_subdir: str = "platform_real_ssd_sync_tree_step_payload",
    ) -> None:
        self.backend_script = Path(backend_script)
        self.run_name = run_name
        self.extra_env = dict(extra_env or {})
        self.python_bin = python_bin
        self.platform_subdir = platform_subdir

    @staticmethod
    def _shell_quote(value: str) -> str:
        return "'" + str(value).replace("'", "'\"'\"'") + "'"

    @staticmethod
    def _shell_path_from(base_dir: Path, target: Path) -> str:
        if _prefer_absolute_shell_paths():
            return str(Path(target)).replace("\\", "/")
        try:
            return os.path.relpath(str(target), start=str(base_dir)).replace("\\", "/")
        except ValueError:
            return str(target).replace("\\", "/")

    def __call__(
        self, step_payload: SyncTreeStepPayload, step_workdir: Path
    ) -> RuntimeLoopStepResult:
        step_workdir = Path(step_workdir)
        request = runtime_request_from_sync_tree_step_like(step_payload)
        prepare_runtime_workdir(step_workdir, request)

        step_payload_path = step_workdir / "sync_tree_step_request.json"
        vcs_work_root = step_workdir / "vcs"
        vcs_work_root.mkdir(parents=True, exist_ok=True)

        env = os.environ.copy()
        env.update(self.extra_env)
        env["PYTHON_BIN"] = self.python_bin
        env["SYNC_STEP_JSON"] = str(step_payload_path)
        env["VCS_WORK_ROOT"] = str(vcs_work_root)

        shell_sync_step_json = self._shell_path_from(
            self.backend_script.parent, step_payload_path
        )
        shell_vcs_work_root = self._shell_path_from(
            self.backend_script.parent, vcs_work_root
        )

        wrapper_lines = [
            "#!/usr/bin/env bash",
            "set -eu",
            "export PYTHON_BIN={0}".format(
                self._shell_quote(str(env["PYTHON_BIN"]))
            ),
            "export SYNC_STEP_JSON={0}".format(
                self._shell_quote(shell_sync_step_json)
            ),
            "export VCS_WORK_ROOT={0}".format(
                self._shell_quote(shell_vcs_work_root)
            ),
        ]
        for key, value in sorted(self.extra_env.items()):
            wrapper_lines.append(
                "export {0}={1}".format(
                    str(key),
                    self._shell_quote(str(value)),
                )
            )
        wrapper_lines.append(
            "exec bash {0}".format(
                self._shell_quote(self.backend_script.name)
            )
        )
        wrapper_path = step_workdir / "run_backend_wrapper.sh"
        with wrapper_path.open("w", encoding="utf-8", newline="\n") as handle:
            handle.write("\n".join(wrapper_lines) + "\n")
        wrapper_relpath = self._shell_path_from(
            self.backend_script.parent, wrapper_path
        )

        proc = subprocess.run(
            ["bash", wrapper_relpath],
            cwd=str(self.backend_script.parent),
            env=env,
            check=False,
        )
        if proc.returncode != 0:
            failure_summary = _summarize_backend_failure(self.backend_script)
            message = (
                f"backend script failed for step {step_payload.step_index}: "
                f"exit_code={proc.returncode}"
            )
            if failure_summary:
                message = message + "; " + failure_summary
            raise RuntimeError(
                message
            )

        platform_workdir = (
            vcs_work_root / self.run_name / self.platform_subdir
        )
        runtime_result = collect_runtime_result(platform_workdir)
        return RuntimeLoopStepResult.from_runtime_result(runtime_result)


@dataclass
class RealSsdSyncStepRecord:
    sequence_before: object
    speculate_result: object
    verify_result: object
    metadata: Dict[str, Any] = field(default_factory=dict)
    stop_after: bool = False


class _DefaultRealSsdSyncLiveStepSource:
    def __init__(
        self,
        sequence_id: str,
        prompt_token_ids: List[int],
        model_path: Optional[str] = None,
        draft_model_path: Optional[str] = None,
        lookahead: int = 1,
        max_new_tokens: int = 32,
    ) -> None:
        self.sequence_id = str(sequence_id)
        self.prompt_token_ids = [int(token) for token in list(prompt_token_ids)]
        self.model_path = model_path
        self.draft_model_path = draft_model_path or model_path
        self.lookahead = int(lookahead)
        self.max_new_tokens = int(max_new_tokens)
        self._engine = None
        self._inference_step = None
        self._prefill_done = False

    def _ensure_initialized(self) -> None:
        if self._engine is not None:
            return
        if not self.model_path:
            raise RuntimeError(
                "real SSD sync step provider requires --real-model-path "
                "when no injected live_step_source is provided"
            )

        try:
            from ssd.engine.llm_engine import LLMEngine  # type: ignore
            from ssd.engine.step import SpecDecodeStep  # type: ignore
            from ssd.sampling_params import SamplingParams  # type: ignore
        except ModuleNotFoundError as exc:
            raise RuntimeError(
                "real SSD sync step provider requires the ssd-main runtime "
                "environment with LLMEngine support"
            ) from exc

        engine = LLMEngine(
            model=str(self.model_path),
            draft=str(self.draft_model_path or self.model_path),
            speculate=True,
            draft_async=False,
            speculate_k=self.lookahead,
            max_num_seqs=1,
            num_gpus=1,
            verbose=False,
        )
        sampling_params = SamplingParams(
            max_new_tokens=max(self.max_new_tokens, self.lookahead + 1)
        )
        engine.add_request(list(self.prompt_token_ids), sampling_params)
        inference_step = engine.create_inference_step(engine.config)
        if not isinstance(inference_step, SpecDecodeStep):
            raise RuntimeError(
                "real SSD sync step provider expected SpecDecodeStep "
                "from the SSD runtime"
            )
        self._engine = engine
        self._inference_step = inference_step

    def _run_prefill_if_needed(self) -> None:
        if self._prefill_done:
            return
        self._ensure_initialized()
        assert self._engine is not None
        assert self._inference_step is not None
        seqs, is_prefill = self._engine.scheduler.schedule()
        if not seqs:
            raise RuntimeError(
                "real SSD sync step provider could not obtain a prefill batch"
            )
        if not is_prefill:
            raise RuntimeError(
                "real SSD sync step provider expected the first SSD batch "
                "to be prefill"
            )
        self._inference_step.prefill(seqs)
        self._prefill_done = True

    @staticmethod
    def _capture_saved_state(seqs: List[object]) -> List[tuple]:
        return [
            (
                len(seq.token_ids),
                seq.num_tokens,
                seq.last_token,
                seq.num_draft_cached_tokens,
                seq.num_cached_tokens,
            )
            for seq in seqs
        ]

    @staticmethod
    def _restore_saved_state(seqs: List[object], saved_state: List[tuple]) -> None:
        for seq, (orig_len, orig_nt, orig_lt, orig_ndc, orig_nct) in zip(
            seqs, saved_state
        ):
            del seq.token_ids[orig_len:]
            seq.num_tokens = orig_nt
            seq.last_token = orig_lt
            seq.num_draft_cached_tokens = orig_ndc
            seq.num_cached_tokens = orig_nct

    def next_step_record(self) -> Optional[RealSsdSyncStepRecord]:
        self._run_prefill_if_needed()
        assert self._engine is not None
        assert self._inference_step is not None

        if self._engine.is_finished():
            return None

        seqs, is_prefill = self._engine.scheduler.schedule()
        if not seqs:
            return None
        if is_prefill:
            raise RuntimeError(
                "real SSD sync step provider encountered an unexpected "
                "prefill batch after initialization"
            )

        try:
            from ssd.engine.helpers.speculate_types import VerifyResult  # type: ignore
        except ModuleNotFoundError as exc:
            raise RuntimeError(
                "real SSD sync step provider requires SSD speculate types"
            ) from exc

        step = self._inference_step
        saved_sequences = [seq.clone_spec() for seq in seqs]
        saved_state = self._capture_saved_state(seqs)
        eagle_sentinel = True if step.eagle else None
        in_verify_result = VerifyResult(
            new_suffixes=[],
            recovery_tokens=[],
            eagle_acts=eagle_sentinel,
        )
        speculate_result = step.speculator.speculate(seqs, in_verify_result)
        verify_result = step.verifier.verify(
            seqs, speculate_result, eagle=step.eagle
        )
        self._restore_saved_state(seqs, saved_state)
        step.scheduler.postprocess_speculate(
            seqs,
            verify_result.new_suffixes,
            verify_result.recovery_tokens,
            eagle_acts=verify_result.eagle_acts if step.eagle else None,
        )

        stop_after = bool(self._engine.is_finished()) or bool(
            getattr(seqs[0], "is_finished", False)
        )
        return RealSsdSyncStepRecord(
            sequence_before=saved_sequences[0],
            speculate_result=speculate_result,
            verify_result=verify_result,
            metadata={"provider_mode": "real_ssd_sync"},
            stop_after=stop_after,
        )

    def close(self) -> None:
        engine = self._engine
        self._engine = None
        self._inference_step = None
        if engine is None:
            return
        exit_fn = getattr(engine, "exit", None)
        if callable(exit_fn):
            try:
                exit_fn(hard=False)
            except Exception:
                pass


@dataclass
class RealSsdSyncStepProvider:
    sequence_id: str
    prompt_token_ids: List[int]
    model_path: Optional[str] = None
    draft_model_path: Optional[str] = None
    lookahead: int = 1
    ssd_sequence: object = None
    live_step_source: object = None
    max_new_tokens: int = 32
    stop_requested: bool = False

    def _resolve_live_step_source(self) -> object:
        if self.live_step_source is None:
            self.live_step_source = _DefaultRealSsdSyncLiveStepSource(
                sequence_id=self.sequence_id,
                prompt_token_ids=self.prompt_token_ids,
                model_path=self.model_path,
                draft_model_path=self.draft_model_path,
                lookahead=self.lookahead,
                max_new_tokens=self.max_new_tokens,
            )
        return self.live_step_source

    def _build_sequence_before_like(self, sequence_before: object) -> Dict[str, Any]:
        prompt_token_ids = list(getattr(sequence_before, "token_ids", []))
        if not prompt_token_ids:
            prompt_token_ids = list(self.prompt_token_ids)
        recovery_token_id = getattr(sequence_before, "recovery_token_id", None)
        if recovery_token_id is None and self.prompt_token_ids:
            recovery_token_id = int(self.prompt_token_ids[-1])
        return {
            "sequence_id": str(self.sequence_id),
            "prompt_token_ids": [int(token) for token in list(prompt_token_ids)],
            "recovery_token_id": int(recovery_token_id or 0),
            "max_new_tokens": int(self.max_new_tokens),
        }

    def next_step(self, state: Optional[RuntimeLoopState]) -> Optional[SyncTreeStepPayload]:
        if self.stop_requested:
            return None
        if state is not None:
            if state.finish_seen:
                return None
            if state.error_flag not in (None, 0):
                return None

        live_step_source = self._resolve_live_step_source()
        next_step_record = getattr(live_step_source, "next_step_record", None)
        if not callable(next_step_record):
            raise RuntimeError(
                "real SSD sync step provider live_step_source must expose "
                "next_step_record()"
            )

        record = next_step_record()
        if record is None:
            self.stop_requested = True
            close_fn = getattr(live_step_source, "close", None)
            if callable(close_fn):
                close_fn()
            return None
        if not isinstance(record, RealSsdSyncStepRecord):
            record = RealSsdSyncStepRecord(**dict(record))

        provider_metadata = {"provider_mode": "real_ssd_sync"}
        provider_metadata.update(dict(record.metadata))
        payload = build_sync_tree_step_payload(
            sequence_like=self._build_sequence_before_like(record.sequence_before),
            speculate_result=record.speculate_result,
            verify_result=record.verify_result,
            step_index=0 if state is None else int(state.step_index),
            metadata=provider_metadata,
        )
        if record.stop_after:
            self.stop_requested = True
            close_fn = getattr(live_step_source, "close", None)
            if callable(close_fn):
                close_fn()
        return payload

    def close(self) -> None:
        close_fn = getattr(self.live_step_source, "close", None)
        if callable(close_fn):
            close_fn()


def build_real_ssd_sync_step_provider(
    sequence_id: str,
    prompt_token_ids: List[int],
    model_path: Optional[str] = None,
    draft_model_path: Optional[str] = None,
    lookahead: int = 1,
    live_step_source: object = None,
    max_new_tokens: int = 32,
) -> object:
    if live_step_source is not None:
        return RealSsdSyncStepProvider(
            sequence_id=str(sequence_id),
            prompt_token_ids=list(prompt_token_ids),
            model_path=model_path,
            draft_model_path=draft_model_path,
            lookahead=int(lookahead),
            live_step_source=live_step_source,
            max_new_tokens=int(max_new_tokens),
        )

    try:
        import torch  # type: ignore  # noqa: F401
        import transformers  # type: ignore  # noqa: F401
    except ModuleNotFoundError as exc:
        raise RuntimeError(
            "real SSD sync step provider requires torch and transformers; "
            "please run it in the VM runtime environment"
        ) from exc

    try:
        from ssd.engine.sequence import Sequence  # type: ignore
        from ssd.sampling_params import SamplingParams  # type: ignore
    except ModuleNotFoundError as exc:
        raise RuntimeError(
            "real SSD sync step provider requires ssd-main python environment"
        ) from exc

    sampling_params = SamplingParams(max_new_tokens=lookahead + 1)
    seq = Sequence(list(prompt_token_ids), sampling_params)
    return RealSsdSyncStepProvider(
        sequence_id=str(sequence_id),
        prompt_token_ids=list(prompt_token_ids),
        model_path=model_path,
        draft_model_path=draft_model_path,
        lookahead=int(lookahead),
        ssd_sequence=seq,
        max_new_tokens=int(max(max_new_tokens, lookahead + 1)),
    )


def build_step_provider(
    provider_mode: str,
    step_trace_jsonl: Optional[Path] = None,
    sequence_id: str = "runtime-loop-0",
    prompt_token_ids: Optional[List[int]] = None,
    model_path: Optional[str] = None,
    draft_model_path: Optional[str] = None,
    lookahead: int = 1,
    live_step_source: object = None,
    max_new_tokens: int = 32,
) -> object:
    mode = str(provider_mode)
    if mode == "trace":
        if step_trace_jsonl is None:
            raise RuntimeError("trace provider requires --step-trace-jsonl")
        return SyncTraceStepProvider.from_jsonl(Path(step_trace_jsonl))
    if mode == "real_ssd_sync":
        if prompt_token_ids is None:
            raise RuntimeError("real_ssd_sync provider requires --prompt-tokens")
        return build_real_ssd_sync_step_provider(
            sequence_id=sequence_id,
            prompt_token_ids=list(prompt_token_ids),
            model_path=model_path,
            draft_model_path=draft_model_path,
            lookahead=int(lookahead),
            live_step_source=live_step_source,
            max_new_tokens=int(max_new_tokens),
    )
    raise RuntimeError("unknown provider mode: {0}".format(mode))


def build_backend_runner(
    backend_mode: str,
    backend_script: Path,
    run_name: str,
    extra_env: Optional[Dict[str, str]] = None,
    python_bin: str = "python3",
    shared_session_root: Optional[Path] = None,
    shared_poll_interval_ms: int = 200,
    shared_timeout_seconds: float = 300.0,
) -> object:
    mode = str(backend_mode)
    if mode == "shell_local":
        return ShellSyncRuntimeBackendRunner(
            backend_script=Path(backend_script),
            run_name=str(run_name),
            extra_env=extra_env,
            python_bin=str(python_bin),
        )
    if mode == "shared_folder":
        if shared_session_root is None:
            raise RuntimeError(
                "shared_folder backend requires --shared-session-root"
            )
        from shared_runtime_bridge.bridge import (  # type: ignore
            SharedFolderRuntimeBackendRunner,
        )

        return SharedFolderRuntimeBackendRunner(
            session_root=Path(shared_session_root),
            poll_interval_ms=int(shared_poll_interval_ms),
            timeout_seconds=float(shared_timeout_seconds),
        )
    raise RuntimeError("unknown backend mode: {0}".format(mode))


def run_sync_runtime_loop(
    provider: object,
    backend_runner: Callable[[SyncTreeStepPayload, Path], RuntimeLoopStepResult],
    root_workdir: Path,
    max_steps: Optional[int] = None,
) -> RuntimeLoopResult:
    root_workdir = Path(root_workdir)
    root_workdir.mkdir(parents=True, exist_ok=True)

    state = RuntimeLoopState()
    step_results: List[RuntimeLoopStepResult] = []
    prompt_token_ids: List[int] = []
    generated_token_ids: List[int] = []
    event_counts: Dict[str, int] = {}
    finish_seen = False
    error_flag: Optional[int] = None
    next_recovery_token: Optional[int] = None

    try:
        while True:
            if max_steps is not None and state.step_index >= max_steps:
                break

            payload = provider.next_step(state)
            if payload is None:
                break

            if not prompt_token_ids:
                prompt_token_ids = list(payload.prompt_token_ids)
                if state.sequence_id is None:
                    state.sequence_id = payload.sequence_id

            step_workdir = root_workdir / f"step_{state.step_index:03d}"
            step_workdir.mkdir(parents=True, exist_ok=True)

            step_result = backend_runner(payload, step_workdir)
            if not isinstance(step_result, RuntimeLoopStepResult):
                step_result = RuntimeLoopStepResult.from_runtime_result(step_result)

            write_json(
                step_workdir / "runtime_loop_step_result.json", step_result.to_dict()
            )

            step_results.append(step_result)
            generated_token_ids.extend(step_result.generated_token_ids)
            event_counts = _merge_event_counts(event_counts, step_result.event_counts)
            finish_seen = finish_seen or step_result.finish_seen
            if step_result.error_flag is not None:
                error_flag = step_result.error_flag
            if step_result.next_recovery_token is not None:
                next_recovery_token = step_result.next_recovery_token

            state.generated_token_ids = list(generated_token_ids)
            state.step_index += 1
            state.finish_seen = finish_seen
            state.error_flag = error_flag
            state.next_recovery_token = next_recovery_token

            if error_flag not in (None, 0):
                break
    finally:
        close_fn = getattr(provider, "close", None)
        if callable(close_fn):
            close_fn()

    sequence_id = state.sequence_id or (
        step_results[0].sequence_id if step_results else "runtime-loop-0"
    )
    all_token_ids = list(prompt_token_ids) + list(generated_token_ids)
    result = RuntimeLoopResult(
        sequence_id=sequence_id,
        prompt_token_ids=prompt_token_ids,
        step_count=len(step_results),
        generated_token_ids=generated_token_ids,
        all_token_ids=all_token_ids,
        finish_seen=finish_seen,
        error_flag=error_flag,
        event_counts=event_counts,
        step_results=step_results,
        root_workdir=str(root_workdir),
        next_recovery_token=next_recovery_token,
    )
    write_json(root_workdir / "runtime_loop_result.json", result.to_dict())
    return result


def build_argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Bounded SSD sync runtime loop for the single-chiplet backend."
    )
    subparsers = parser.add_subparsers(dest="command")

    run_parser = subparsers.add_parser("run")
    run_parser.add_argument("--workdir", required=True)
    run_parser.add_argument(
        "--provider-mode",
        default="trace",
        choices=["trace", "real_ssd_sync"],
    )
    run_parser.add_argument("--step-trace-jsonl")
    run_parser.add_argument("--backend-script", required=True)
    run_parser.add_argument("--run-name", default="30_vcs_control_chip_stage2_single_chiplet_real_ssd_sync_tree_step_payload_bringup")
    run_parser.add_argument(
        "--backend-mode",
        default="shell_local",
        choices=["shell_local", "shared_folder"],
    )
    run_parser.add_argument("--python-bin", default="python3")
    run_parser.add_argument("--max-steps", type=int, default=None)
    run_parser.add_argument("--sequence-id", default="runtime-loop-0")
    run_parser.add_argument("--prompt-tokens")
    run_parser.add_argument("--real-model-path")
    run_parser.add_argument("--real-draft-model-path")
    run_parser.add_argument("--real-weight-fixture-json")
    run_parser.add_argument("--real-model-name")
    run_parser.add_argument("--token-vocab-json")
    run_parser.add_argument("--draft-table-json")
    run_parser.add_argument("--recompute-table-json")
    run_parser.add_argument("--result-decode-table-json")
    run_parser.add_argument("--lookahead", type=int, default=1)
    run_parser.add_argument("--provider-max-new-tokens", type=int, default=32)
    run_parser.add_argument("--shared-session-root")
    run_parser.add_argument("--shared-poll-interval-ms", type=int, default=200)
    run_parser.add_argument("--shared-timeout-seconds", type=float, default=300.0)
    return parser


def main(argv: Optional[List[str]] = None) -> int:
    parser = build_argument_parser()
    args = parser.parse_args(argv)

    if getattr(args, "command", None) != "run":
        parser.print_usage()
        return 2

    prompt_token_ids = (
        None if not args.prompt_tokens else parse_prompt_tokens(args.prompt_tokens)
    )
    provider = build_step_provider(
        provider_mode=str(args.provider_mode),
        step_trace_jsonl=(
            None if not args.step_trace_jsonl else Path(args.step_trace_jsonl)
        ),
        sequence_id=str(args.sequence_id),
        prompt_token_ids=prompt_token_ids,
        model_path=args.real_model_path,
        draft_model_path=args.real_draft_model_path,
        lookahead=int(args.lookahead),
        max_new_tokens=int(args.provider_max_new_tokens),
    )
    extra_env: Dict[str, str] = {}
    for key, value in (
        ("REAL_MODEL_PATH", args.real_model_path),
        ("REAL_DRAFT_MODEL_PATH", args.real_draft_model_path),
        ("REAL_WEIGHT_FIXTURE_JSON", args.real_weight_fixture_json),
        ("REAL_MODEL_NAME", args.real_model_name),
        ("TOKEN_VOCAB_JSON", args.token_vocab_json),
        ("DRAFT_TABLE_JSON", args.draft_table_json),
        ("RECOMPUTE_TABLE_JSON", args.recompute_table_json),
        ("RESULT_DECODE_TABLE_JSON", args.result_decode_table_json),
    ):
        if value:
            extra_env[key] = str(value)

    runner = build_backend_runner(
        backend_mode=str(args.backend_mode),
        backend_script=Path(args.backend_script),
        run_name=str(args.run_name),
        extra_env=extra_env,
        python_bin=str(args.python_bin),
        shared_session_root=(
            None if not args.shared_session_root else Path(args.shared_session_root)
        ),
        shared_poll_interval_ms=int(args.shared_poll_interval_ms),
        shared_timeout_seconds=float(args.shared_timeout_seconds),
    )
    run_sync_runtime_loop(
        provider=provider,
        backend_runner=runner,
        root_workdir=Path(args.workdir),
        max_steps=args.max_steps,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
