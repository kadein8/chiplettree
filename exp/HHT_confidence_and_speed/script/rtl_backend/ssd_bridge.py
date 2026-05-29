from pathlib import Path
from typing import Any, Dict, List, Optional

from rtl_backend.compat import dataclass, field
from rtl_backend.formats import read_json, write_json
from rtl_backend.rtl_driver import build_single_chiplet_demo_artifacts
from rtl_backend.ssd_step import (
    SyncTreeStepPayload,
    load_sync_tree_step_payload,
    save_sync_tree_step_payload,
    sync_tree_step_like_to_payload,
)
from rtl_backend.toy_decoder import ToyDecoderPackage


@dataclass(frozen=True)
class SequencePrompt:
    sequence_id: str
    prompt_token_ids: List[int]
    max_new_tokens: int = 4
    metadata: Dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> Dict[str, Any]:
        return {
            "sequence_id": self.sequence_id,
            "prompt_token_ids": list(self.prompt_token_ids),
            "max_new_tokens": self.max_new_tokens,
            "metadata": dict(self.metadata),
        }

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "SequencePrompt":
        return cls(
            sequence_id=str(data["sequence_id"]),
            prompt_token_ids=[int(token) for token in list(data["prompt_token_ids"])],
            max_new_tokens=int(data.get("max_new_tokens", 4)),
            metadata=dict(data.get("metadata", {})),
        )


def sequence_like_to_prompt(sequence_like: object) -> SequencePrompt:
    if isinstance(sequence_like, SequencePrompt):
        return sequence_like

    if isinstance(sequence_like, dict):
        return SequencePrompt.from_dict(sequence_like)

    seq_id = getattr(sequence_like, "seq_id", None)
    prompt_token_ids = getattr(sequence_like, "prompt_token_ids", None)
    max_new_tokens = getattr(sequence_like, "max_new_tokens", 4)

    if seq_id is None or prompt_token_ids is None:
        raise TypeError(
            "sequence_like must be a SequencePrompt, a dict, or an object with "
            "seq_id and prompt_token_ids"
        )

    return SequencePrompt(
        sequence_id=str(seq_id),
        prompt_token_ids=[int(token) for token in list(prompt_token_ids)],
        max_new_tokens=int(max_new_tokens),
    )


def save_sequence_prompt(path: Path, request: SequencePrompt) -> Path:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    write_json(path, request.to_dict())
    return path


def load_sequence_prompt(path: Path) -> SequencePrompt:
    return SequencePrompt.from_dict(read_json(Path(path)))


def build_demo_artifacts_from_sequence(
    workdir: Path,
    sequence_like: object,
    package: Optional[ToyDecoderPackage] = None,
    include_native_tree: bool = False,
) -> Path:
    workdir = Path(workdir)
    request = sequence_like_to_prompt(sequence_like)
    save_sequence_prompt(workdir / "sequence_request.json", request)
    return build_single_chiplet_demo_artifacts(
        workdir=workdir,
        prompt_tokens=request.prompt_token_ids,
        package=package,
        include_native_tree=include_native_tree,
    )


def build_sync_tree_step_payload(
    sequence_like: object,
    speculate_result: object,
    verify_result: object,
    step_index: int,
    metadata: Optional[Dict[str, Any]] = None,
) -> SyncTreeStepPayload:
    prompt = sequence_like_to_prompt(sequence_like)
    step_metadata = dict(metadata or {})

    recovery_token = getattr(sequence_like, "recovery_token_id", None)
    if recovery_token is None and isinstance(sequence_like, dict):
        recovery_token = sequence_like.get("recovery_token_id")

    raw_speculations = []
    if speculate_result is not None:
        raw_speculations = getattr(speculate_result, "speculations", [])
        if isinstance(speculate_result, dict):
            raw_speculations = speculate_result.get("speculations", raw_speculations)
    speculations = raw_speculations.tolist() if hasattr(raw_speculations, "tolist") else raw_speculations
    first_speculation = list(speculations[0]) if speculations else []
    if recovery_token is None and first_speculation:
        recovery_token = int(first_speculation[0])

    speculated_tokens = list(first_speculation)
    if speculated_tokens and recovery_token is not None and int(speculated_tokens[0]) == int(recovery_token):
        speculated_tokens = speculated_tokens[1:]

    raw_suffixes = []
    raw_recovery_tokens = []
    if verify_result is not None:
        raw_suffixes = getattr(verify_result, "new_suffixes", [])
        raw_recovery_tokens = getattr(verify_result, "recovery_tokens", [])
        if isinstance(verify_result, dict):
            raw_suffixes = verify_result.get("new_suffixes", raw_suffixes)
            raw_recovery_tokens = verify_result.get("recovery_tokens", raw_recovery_tokens)

    accepted_suffixes = raw_suffixes.tolist() if hasattr(raw_suffixes, "tolist") else raw_suffixes
    accepted_tokens = [int(token) for token in list(accepted_suffixes[0])] if accepted_suffixes else []
    recovery_tokens = (
        raw_recovery_tokens.tolist()
        if hasattr(raw_recovery_tokens, "tolist")
        else raw_recovery_tokens
    )
    next_recovery_token = int(recovery_tokens[0]) if recovery_tokens else int(recovery_token or 0)

    payload_like = {
        "sequence_id": prompt.sequence_id,
        "prompt_token_ids": list(prompt.prompt_token_ids),
        "step_index": int(step_index),
        "recovery_token": int(recovery_token or 0),
        "speculated_tokens": [int(token) for token in list(speculated_tokens)],
        "accepted_tokens": accepted_tokens,
        "next_recovery_token": next_recovery_token,
        "metadata": step_metadata,
    }
    return sync_tree_step_like_to_payload(payload_like)


def build_demo_artifacts_from_sync_tree_step(
    workdir: Path,
    step_payload_like: object,
    package: Optional[ToyDecoderPackage] = None,
) -> Path:
    workdir = Path(workdir)
    payload = sync_tree_step_like_to_payload(step_payload_like)
    save_sync_tree_step_payload(workdir / "sync_tree_step_request.json", payload)
    committed_context_tokens = []
    if any(
        int(mask) != 0
        for mask in list(payload.native_tree_request.frontier_tree_mask_en_by_level)
    ):
        committed_context_tokens = list(payload.prompt_token_ids)
        committed_context_tokens.append(int(payload.recovery_token))
    return build_single_chiplet_demo_artifacts(
        workdir=workdir,
        prompt_tokens=list(payload.prompt_token_ids) + [int(payload.recovery_token)],
        package=package,
        include_native_tree=payload.native_tree_request.valid,
        native_tree_request=payload.native_tree_request,
        enable_demo_draft_candidates=False,
        native_tree_launch_prefix_len=(
            len(payload.prompt_token_ids) + 1
        ),
        committed_context_tokens=committed_context_tokens,
    )


__all__ = [
    "SequencePrompt",
    "SyncTreeStepPayload",
    "build_demo_artifacts_from_sequence",
    "build_demo_artifacts_from_sync_tree_step",
    "build_sync_tree_step_payload",
    "load_sequence_prompt",
    "load_sync_tree_step_payload",
    "save_sequence_prompt",
    "save_sync_tree_step_payload",
    "sequence_like_to_prompt",
    "sync_tree_step_like_to_payload",
]
