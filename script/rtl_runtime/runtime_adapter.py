import argparse
import json
from pathlib import Path
from typing import Any, Dict, List, Optional

from rtl_backend.compat import dataclass, field
from rtl_backend.events import EventLog
from rtl_backend.formats import read_json, write_json
from rtl_backend.rtl_driver import materialize_hbm_output_from_events
from rtl_backend.ssd_bridge import (
    SequencePrompt,
    SyncTreeStepPayload,
    build_demo_artifacts_from_sync_tree_step,
    build_demo_artifacts_from_sequence,
    load_sync_tree_step_payload,
    sequence_like_to_prompt,
    sync_tree_step_like_to_payload,
)
from rtl_backend.toy_decoder import ToyDecoderPackage


@dataclass(frozen=True)
class RuntimeSequenceRequest:
    sequence_id: str
    prompt_token_ids: List[int]
    max_new_tokens: int = 4
    include_native_tree: bool = False
    request_kind: str = "sequence_prompt"
    step_payload: Optional[Dict[str, Any]] = None
    metadata: Dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> Dict[str, Any]:
        return {
            "sequence_id": self.sequence_id,
            "prompt_token_ids": list(self.prompt_token_ids),
            "max_new_tokens": self.max_new_tokens,
            "include_native_tree": self.include_native_tree,
            "request_kind": self.request_kind,
            "step_payload": (
                None if self.step_payload is None else dict(self.step_payload)
            ),
            "metadata": dict(self.metadata),
        }

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "RuntimeSequenceRequest":
        return cls(
            sequence_id=str(data["sequence_id"]),
            prompt_token_ids=[int(token) for token in list(data["prompt_token_ids"])],
            max_new_tokens=int(data.get("max_new_tokens", 4)),
            include_native_tree=bool(data.get("include_native_tree", False)),
            request_kind=str(data.get("request_kind", "sequence_prompt")),
            step_payload=(
                None
                if data.get("step_payload") is None
                else dict(data.get("step_payload", {}))
            ),
            metadata=dict(data.get("metadata", {})),
        )


@dataclass(frozen=True)
class RuntimeSequenceResult:
    sequence_id: str
    model_name: str
    prompt_token_ids: List[int]
    generated_token_ids: List[int]
    all_token_ids: List[int]
    prompt_text: str
    generated_text: str
    all_text: str
    finish_seen: bool
    error_flag: Optional[int]
    wb_done_count: int
    event_counts: Dict[str, int]
    workdir: str
    weight_package_dir: str
    request_kind: str = "sequence_prompt"
    step_index: Optional[int] = None
    accepted_tokens: Optional[List[int]] = None
    accepted_tokens_source: Optional[str] = None
    next_recovery_token: Optional[int] = None
    next_recovery_token_source: Optional[str] = None
    native_tree_req_id: Optional[int] = None

    def to_dict(self) -> Dict[str, Any]:
        return {
            "sequence_id": self.sequence_id,
            "model_name": self.model_name,
            "prompt_token_ids": list(self.prompt_token_ids),
            "generated_token_ids": list(self.generated_token_ids),
            "all_token_ids": list(self.all_token_ids),
            "prompt_text": self.prompt_text,
            "generated_text": self.generated_text,
            "all_text": self.all_text,
            "finish_seen": self.finish_seen,
            "error_flag": self.error_flag,
            "wb_done_count": self.wb_done_count,
            "event_counts": dict(self.event_counts),
            "workdir": self.workdir,
            "weight_package_dir": self.weight_package_dir,
            "request_kind": self.request_kind,
            "step_index": self.step_index,
            "accepted_tokens": (
                None if self.accepted_tokens is None else list(self.accepted_tokens)
            ),
            "accepted_tokens_source": self.accepted_tokens_source,
            "next_recovery_token": self.next_recovery_token,
            "next_recovery_token_source": self.next_recovery_token_source,
            "native_tree_req_id": self.native_tree_req_id,
        }


def parse_prompt_tokens(spec: str) -> List[int]:
    tokens = []
    for raw_part in spec.split(","):
        part = raw_part.strip()
        if not part:
            continue
        tokens.append(int(part, 0))
    return tokens


def runtime_request_from_sequence_like(
    sequence_like: object,
    include_native_tree: bool = False,
    metadata: Optional[Dict[str, Any]] = None,
) -> RuntimeSequenceRequest:
    prompt = sequence_like_to_prompt(sequence_like)
    request_metadata = dict(metadata or {})
    if isinstance(sequence_like, dict):
        request_metadata.update(dict(sequence_like.get("metadata", {})))
    return RuntimeSequenceRequest(
        sequence_id=prompt.sequence_id,
        prompt_token_ids=list(prompt.prompt_token_ids),
        max_new_tokens=prompt.max_new_tokens,
        include_native_tree=include_native_tree,
        request_kind="sequence_prompt",
        metadata=request_metadata,
    )


def runtime_request_from_sync_tree_step_like(
    step_like: object,
    metadata: Optional[Dict[str, Any]] = None,
) -> RuntimeSequenceRequest:
    payload = sync_tree_step_like_to_payload(step_like)
    request_metadata = dict(payload.metadata)
    request_metadata.update(dict(metadata or {}))
    return RuntimeSequenceRequest(
        sequence_id=payload.sequence_id,
        prompt_token_ids=list(payload.prompt_token_ids),
        max_new_tokens=max(len(payload.speculated_tokens), len(payload.accepted_tokens), 1),
        include_native_tree=bool(payload.native_tree_request.valid),
        request_kind="sync_tree_step",
        step_payload=payload.to_dict(),
        metadata=request_metadata,
    )


def save_runtime_request(path: Path, request: RuntimeSequenceRequest) -> Path:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    write_json(path, request.to_dict())
    return path


def load_runtime_request(path: Path) -> RuntimeSequenceRequest:
    return RuntimeSequenceRequest.from_dict(read_json(Path(path)))


def prepare_runtime_workdir(
    workdir: Path,
    request: RuntimeSequenceRequest,
    package: Optional[ToyDecoderPackage] = None,
) -> Path:
    workdir = Path(workdir)
    save_runtime_request(workdir / "runtime_request.json", request)
    prompt = SequencePrompt(
        sequence_id=request.sequence_id,
        prompt_token_ids=list(request.prompt_token_ids),
        max_new_tokens=request.max_new_tokens,
        metadata=dict(request.metadata),
    )
    if request.request_kind == "sync_tree_step":
        step_payload = sync_tree_step_like_to_payload(request.step_payload or {})
        build_demo_artifacts_from_sync_tree_step(
            workdir=workdir,
            step_payload_like=step_payload,
            package=package,
        )
    else:
        build_demo_artifacts_from_sequence(
            workdir=workdir,
            sequence_like=prompt,
            package=package,
            include_native_tree=request.include_native_tree,
        )
    return workdir


def _load_state_shadow(workdir: Path) -> Dict[str, Any]:
    state_path = Path(workdir) / "hbm_output" / "regions" / "STATE.jsonl"
    if not state_path.exists():
        return {}
    payload_bytes = bytearray()
    for line in state_path.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        beat = json.loads(stripped)
        # UTF-8 shadow text is stored in full-width HBM beats, so the last beat
        # may contain zero padding on either side depending on how the sparse
        # image was materialized. Trim per-beat zeros before reconstructing the
        # byte stream.
        payload_bytes.extend(bytes.fromhex(str(beat["data_hex"])).strip(b"\x00"))
    decoded = payload_bytes.rstrip(b"\x00").decode("utf-8")
    return json.loads(decoded) if decoded else {}


def _render_tokens(token_ids: List[int], token_vocab: Dict[str, str]) -> str:
    rendered = []
    for token_id in token_ids:
        rendered.append(str(token_vocab.get(str(token_id), "<unk:{}>".format(token_id))))
    return "".join(rendered)


def _count_events(event_log: EventLog) -> Dict[str, int]:
    event_counts = {}  # type: Dict[str, int]
    for record in event_log.records:
        event_counts[record.event] = int(event_counts.get(record.event, 0)) + 1
    return event_counts


def _parse_event_token_id(fields: Dict[str, Any]) -> Optional[int]:
    if "token_id" in fields:
        return int(fields["token_id"])
    if "token_id_hex" in fields:
        return int(str(fields["token_id_hex"]), 16)
    return None


def _extract_sync_tree_step_acceptance_from_events(
    event_log: EventLog,
    step_payload: SyncTreeStepPayload,
) -> Dict[str, Any]:
    accepted_suffix = []  # type: List[int]
    bonus_token = None  # type: Optional[int]

    for record in event_log.records:
        if record.event == "accepted_token":
            token_id = _parse_event_token_id(record.fields)
            if token_id is not None:
                accepted_suffix.append(int(token_id))
        elif record.event == "bonus_token":
            token_id = _parse_event_token_id(record.fields)
            if token_id is not None:
                bonus_token = int(token_id)

    if not accepted_suffix and bonus_token is None:
        return {
            "accepted_tokens": None,
            "accepted_tokens_source": None,
            "next_recovery_token": None,
            "next_recovery_token_source": None,
        }

    return {
        "accepted_tokens": [int(step_payload.recovery_token)] + accepted_suffix,
        "accepted_tokens_source": "rtl_event",
        "next_recovery_token": bonus_token,
        "next_recovery_token_source": (
            None if bonus_token is None else "rtl_event"
        ),
    }


def collect_runtime_result(workdir: Path) -> RuntimeSequenceResult:
    workdir = Path(workdir)
    materialize_hbm_output_from_events(workdir)

    runtime_request = load_runtime_request(workdir / "runtime_request.json")
    package_dir = workdir / "weights" / "toy_decoder"
    package = ToyDecoderPackage.load(package_dir)
    event_log = EventLog.load(workdir / "events" / "events.jsonl")
    state_shadow = _load_state_shadow(workdir)

    step_payload = None  # type: Optional[SyncTreeStepPayload]
    if runtime_request.request_kind == "sync_tree_step":
        payload_path = workdir / "sync_tree_step_request.json"
        if payload_path.exists():
            step_payload = load_sync_tree_step_payload(payload_path)
        elif runtime_request.step_payload is not None:
            step_payload = sync_tree_step_like_to_payload(runtime_request.step_payload)

    derived_acceptance = {
        "accepted_tokens": None,
        "accepted_tokens_source": None,
        "next_recovery_token": None,
        "next_recovery_token_source": None,
    }  # type: Dict[str, Any]
    if step_payload is not None:
        derived_acceptance = _extract_sync_tree_step_acceptance_from_events(
            event_log=event_log,
            step_payload=step_payload,
        )

    payload_generated_token_ids = [
        int(token) for token in list(state_shadow.get("wb_payload_tokens", []))
    ]
    wb_done_generated_token_ids = [
        int(token) for token in list(state_shadow.get("wb_done_tokens", []))
    ]
    if runtime_request.request_kind == "sync_tree_step":
        generated_token_ids = (
            wb_done_generated_token_ids
            if wb_done_generated_token_ids
            else payload_generated_token_ids
        )
    else:
        generated_token_ids = (
            payload_generated_token_ids
            if payload_generated_token_ids
            else wb_done_generated_token_ids
        )
    prompt_token_ids = list(runtime_request.prompt_token_ids)
    all_token_ids = prompt_token_ids + generated_token_ids
    token_vocab = dict(package.token_vocab)
    accepted_tokens = (
        [int(token) for token in list(derived_acceptance["accepted_tokens"])]
        if derived_acceptance["accepted_tokens"] is not None
        else (None if step_payload is None else list(step_payload.accepted_tokens))
    )
    accepted_tokens_source = (
        str(derived_acceptance["accepted_tokens_source"])
        if derived_acceptance["accepted_tokens_source"] is not None
        else ("request_payload" if step_payload is not None else None)
    )
    next_recovery_token = (
        int(derived_acceptance["next_recovery_token"])
        if derived_acceptance["next_recovery_token"] is not None
        else (
            None
            if step_payload is None
            else int(step_payload.next_recovery_token)
        )
    )
    next_recovery_token_source = (
        str(derived_acceptance["next_recovery_token_source"])
        if derived_acceptance["next_recovery_token_source"] is not None
        else ("request_payload" if step_payload is not None else None)
    )
    result = RuntimeSequenceResult(
        sequence_id=runtime_request.sequence_id,
        model_name=package.model_name,
        prompt_token_ids=prompt_token_ids,
        generated_token_ids=generated_token_ids,
        all_token_ids=all_token_ids,
        prompt_text=_render_tokens(prompt_token_ids, token_vocab),
        generated_text=_render_tokens(generated_token_ids, token_vocab),
        all_text=_render_tokens(all_token_ids, token_vocab),
        finish_seen=bool(state_shadow.get("finish_seen", False)),
        error_flag=(
            None
            if state_shadow.get("error_flag") is None
            else int(state_shadow.get("error_flag"))
        ),
        wb_done_count=int(state_shadow.get("wb_done_count", 0)),
        event_counts=_count_events(event_log),
        workdir=str(workdir),
        weight_package_dir=str(package_dir),
        request_kind=runtime_request.request_kind,
        step_index=(None if step_payload is None else int(step_payload.step_index)),
        accepted_tokens=accepted_tokens,
        accepted_tokens_source=accepted_tokens_source,
        next_recovery_token=next_recovery_token,
        next_recovery_token_source=next_recovery_token_source,
        native_tree_req_id=(
            None if step_payload is None else int(step_payload.native_tree_request.req_id)
        ),
    )
    write_json(workdir / "runtime_result.json", result.to_dict())
    return result


def build_argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Minimal SSD-style runtime adapter for the bounded single-chiplet RTL backend."
    )
    subparsers = parser.add_subparsers(dest="command")

    prepare_parser = subparsers.add_parser("prepare")
    prepare_parser.add_argument("--workdir", required=True)
    prepare_parser.add_argument("--prompt-tokens")
    prepare_parser.add_argument("--sequence-id", default="runtime-seq-0")
    prepare_parser.add_argument("--max-new-tokens", type=int, default=4)
    prepare_parser.add_argument("--weight-package-dir")
    prepare_parser.add_argument("--include-native-tree", action="store_true")
    prepare_parser.add_argument("--sync-step-json")

    collect_parser = subparsers.add_parser("collect")
    collect_parser.add_argument("--workdir", required=True)

    return parser


def main(argv: Optional[List[str]] = None) -> int:
    parser = build_argument_parser()
    args = parser.parse_args(argv)

    if not getattr(args, "command", None):
        parser.print_usage()
        return 2

    if args.command == "prepare":
        if args.sync_step_json:
            request = runtime_request_from_sync_tree_step_like(
                load_sync_tree_step_payload(Path(args.sync_step_json))
            )
        else:
            if not args.prompt_tokens:
                parser.error("prepare requires --prompt-tokens or --sync-step-json")
            request = RuntimeSequenceRequest(
                sequence_id=args.sequence_id,
                prompt_token_ids=parse_prompt_tokens(args.prompt_tokens),
                max_new_tokens=args.max_new_tokens,
                include_native_tree=bool(args.include_native_tree),
            )
        package = None
        if args.weight_package_dir:
            package = ToyDecoderPackage.load(Path(args.weight_package_dir))
        prepare_runtime_workdir(
            workdir=Path(args.workdir),
            request=request,
            package=package,
        )
        return 0

    if args.command == "collect":
        collect_runtime_result(Path(args.workdir))
        return 0

    parser.error("unknown command")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
