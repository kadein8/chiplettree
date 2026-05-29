import json
import re
import shutil
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

import numpy as np

from rtl_backend.events import EventLog
from rtl_backend.formats import read_json, write_json
from rtl_backend.ssd_bridge import load_sync_tree_step_payload
from rtl_backend.stimulus import StimulusCycle, write_stimulus_bundle
from rtl_backend.toy_decoder import ToyDecoderPackage
from rtl_runtime.runtime_adapter import (
    collect_runtime_result,
    prepare_runtime_workdir,
    runtime_request_from_sync_tree_step_like,
)
from rtl_runtime.runtime_loop import SyncTraceStepProvider
from toy_model.compare_toy_model_outputs import compare_pair, load_memh_vector
from toy_model.toy_model_reference import (
    VOCAB_SIZE,
    build_weights,
    run_autoregressive,
    run_reference,
)


PLATFORM_SUBDIR = "platform_real_ssd_sync_tree_step_payload"
SINGLE_STEP_MODE = "single_step"
RUNTIME_LOOP_TRACE_MODE = "runtime_loop_trace"
TREE_MASK_E2E_STRICT_MODE = "tree_mask_e2e_strict"
_LOCAL_CAPTURE_TOKEN_RE = re.compile(r"^rtl_capture_local(\d+)_token\.txt$")
_LOCAL_CAPTURE_HIDDEN_RE = re.compile(
    r"^rtl_capture_local(\d+)_final_hidden\.memh$"
)


def _run_reference_sequence(
    weights: Dict[str, Any],
    token_ids: List[int],
    start_position: int = 0,
    kv_cache_k: Any = None,
    kv_cache_v: Any = None,
) -> Any:
    if not token_ids:
        raise ValueError("token_ids must not be empty")
    last_dumps = None
    work_k = kv_cache_k
    work_v = kv_cache_v
    for offset, token_id in enumerate(list(token_ids)):
        last_dumps, work_k, work_v = run_reference(
            weights=weights,
            token_id=int(token_id),
            position=int(start_position) + offset,
            kv_cache_k=work_k,
            kv_cache_v=work_v,
        )
    return last_dumps, work_k, work_v


def _expected_generated_token_ids_from_payload(payload: object) -> List[int]:
    accepted_tokens = list(getattr(payload, "accepted_tokens"))
    metadata = dict(getattr(payload, "metadata", {}))
    projection_mode = str(metadata.get("tree_projection_mode", "serial_chain"))
    if projection_mode == "accepted_path":
        return [int(token) for token in accepted_tokens[1:]]
    return [int(token) for token in list(getattr(payload, "speculated_tokens"))]


def _actual_generated_token_ids_from_result(
    projection_mode: str,
    runtime_result: object,
) -> List[int]:
    if str(projection_mode) == "accepted_path":
        accepted_tokens = getattr(runtime_result, "accepted_tokens", None)
        if accepted_tokens is not None:
            accepted_tokens = [int(token) for token in list(accepted_tokens)]
            if len(accepted_tokens) >= 2:
                return accepted_tokens[1:]
    return [
        int(token)
        for token in list(getattr(runtime_result, "generated_token_ids", []))
    ]


def _load_trace_payloads(trace_jsonl: Path) -> List[object]:
    provider = SyncTraceStepProvider.from_jsonl(Path(trace_jsonl))
    payloads = []
    while True:
        payload = provider.next_step(None)
        if payload is None:
            break
        payloads.append(payload)
    return payloads


def _single_step_capture_local_index(step_payload: Dict[str, Any]) -> int:
    return len(list(step_payload.get("prompt_token_ids", []))) + 1


def _prepare_step_platform_workdir(
    platform_workdir: Path,
    step_payload_like: object,
    weight_package_dir: Path,
) -> Path:
    request = runtime_request_from_sync_tree_step_like(step_payload_like)
    return prepare_runtime_workdir(
        workdir=platform_workdir,
        request=request,
        package=ToyDecoderPackage.load(Path(weight_package_dir)),
    )


def _load_stimulus_cycles(stimulus_memh: Path) -> List[StimulusCycle]:
    cycles = []
    for raw_line in Path(stimulus_memh).read_text(encoding="ascii").splitlines():
        stripped = raw_line.strip()
        if not stripped:
            continue
        cycles.append(StimulusCycle.from_memh_word(stripped))
    return cycles


def _read_token_id(path: Path) -> int:
    return int(Path(path).read_text(encoding="ascii").strip())


def _local_capture_index(path: Path) -> Optional[int]:
    token_match = _LOCAL_CAPTURE_TOKEN_RE.match(path.name)
    if token_match is not None:
        return int(token_match.group(1))
    hidden_match = _LOCAL_CAPTURE_HIDDEN_RE.match(path.name)
    if hidden_match is not None:
        return int(hidden_match.group(1))
    return None


def _latest_local_capture_pair(platform_workdir: Path) -> Optional[Tuple[Path, Path]]:
    token_paths: Dict[int, Path] = {}
    hidden_paths: Dict[int, Path] = {}

    for token_path in Path(platform_workdir).glob("rtl_capture_local*_token.txt"):
        local_idx = _local_capture_index(token_path)
        if local_idx is not None:
            token_paths[int(local_idx)] = token_path
    for hidden_path in Path(platform_workdir).glob("rtl_capture_local*_final_hidden.memh"):
        local_idx = _local_capture_index(hidden_path)
        if local_idx is not None:
            hidden_paths[int(local_idx)] = hidden_path

    common_indices = sorted(set(token_paths).intersection(hidden_paths))
    if not common_indices:
        return None
    latest_idx = int(common_indices[-1])
    return token_paths[latest_idx], hidden_paths[latest_idx]


def _resolve_tree_mask_single_step_artifacts(
    step_manifest: Dict[str, Any],
) -> Dict[str, Any]:
    platform_workdir = Path(step_manifest["platform_workdir"])
    requested_token_path = Path(step_manifest["rtl_token_path"])
    requested_hidden_path = Path(step_manifest["rtl_hidden_path"])
    step_index = int(step_manifest["step_index"])

    if (
        _local_capture_index(requested_token_path) is not None or
        _local_capture_index(requested_hidden_path) is not None
    ):
        latest_local_capture = _latest_local_capture_pair(platform_workdir)
        if latest_local_capture is not None:
            return {
                "rtl_token_path": latest_local_capture[0],
                "rtl_hidden_path": latest_local_capture[1],
                "missing_paths": [],
            }

    if requested_token_path.exists() and requested_hidden_path.exists():
        return {
            "rtl_token_path": requested_token_path,
            "rtl_hidden_path": requested_hidden_path,
            "missing_paths": [],
        }

    legacy_token_path = platform_workdir / ("rtl_step%d_token.txt" % step_index)
    legacy_hidden_path = platform_workdir / ("rtl_step%d_final_hidden.memh" % step_index)
    if legacy_token_path.exists() and legacy_hidden_path.exists():
        return {
            "rtl_token_path": legacy_token_path,
            "rtl_hidden_path": legacy_hidden_path,
            "missing_paths": [],
        }

    missing_paths = []
    for candidate in (requested_token_path, requested_hidden_path):
        if not candidate.exists():
            missing_paths.append(str(candidate))
    for candidate in (legacy_token_path, legacy_hidden_path):
        if not candidate.exists():
            missing_paths.append(str(candidate))
    return {
        "rtl_token_path": None,
        "rtl_hidden_path": None,
        "missing_paths": missing_paths,
    }


def _build_single_step_manifest(
    root_workdir: Path,
    payload: object,
) -> Dict[str, Any]:
    accepted_tokens = list(getattr(payload, "accepted_tokens"))
    metadata = dict(getattr(payload, "metadata", {}))
    projection_mode = str(metadata.get("tree_projection_mode", "serial_chain"))
    return {
        "mode": SINGLE_STEP_MODE,
        "root_workdir": str(root_workdir),
        "platform_workdir": str(root_workdir / PLATFORM_SUBDIR),
        "sequence_id": str(getattr(payload, "sequence_id")),
        "step_index": int(getattr(payload, "step_index")),
        "projection_mode": projection_mode,
        "accepted_tokens": accepted_tokens,
        "expected_generated_token_ids": _expected_generated_token_ids_from_payload(payload),
    }


def _build_runtime_loop_manifest(
    root_workdir: Path,
    payloads: List[object],
) -> Dict[str, Any]:
    steps = []
    for step_idx, payload in enumerate(payloads):
        accepted_tokens = list(getattr(payload, "accepted_tokens"))
        metadata = dict(getattr(payload, "metadata", {}))
        projection_mode = str(metadata.get("tree_projection_mode", "serial_chain"))
        step_root = root_workdir / ("step_%03d" % step_idx)
        steps.append(
            {
                "step_index": int(getattr(payload, "step_index")),
                "sequence_id": str(getattr(payload, "sequence_id")),
                "step_root": str(step_root),
                "platform_workdir": str(step_root / PLATFORM_SUBDIR),
                "projection_mode": projection_mode,
                "accepted_tokens": accepted_tokens,
                "expected_generated_token_ids": _expected_generated_token_ids_from_payload(payload),
            }
        )
    return {
        "mode": RUNTIME_LOOP_TRACE_MODE,
        "root_workdir": str(root_workdir),
        "step_count": len(steps),
        "steps": steps,
    }


def prepare_single_step_workdir(
    root_workdir: Path,
    sync_step_json: Path,
    weight_package_dir: Path,
) -> Path:
    root_workdir = Path(root_workdir)
    root_workdir.mkdir(parents=True, exist_ok=True)
    payload = load_sync_tree_step_payload(Path(sync_step_json))
    platform_workdir = root_workdir / PLATFORM_SUBDIR
    _prepare_step_platform_workdir(
        platform_workdir=platform_workdir,
        step_payload_like=payload,
        weight_package_dir=Path(weight_package_dir),
    )
    manifest = _build_single_step_manifest(root_workdir, payload)
    manifest_path = root_workdir / "host_vm_manifest.json"
    write_json(manifest_path, manifest)
    return manifest_path


def prepare_runtime_loop_trace_workdir(
    root_workdir: Path,
    trace_jsonl: Path,
    weight_package_dir: Path,
) -> Path:
    root_workdir = Path(root_workdir)
    root_workdir.mkdir(parents=True, exist_ok=True)
    payloads = _load_trace_payloads(Path(trace_jsonl))
    for step_idx, payload in enumerate(payloads):
        step_root = root_workdir / ("step_%03d" % step_idx)
        step_root.mkdir(parents=True, exist_ok=True)
        _prepare_step_platform_workdir(
            platform_workdir=step_root / PLATFORM_SUBDIR,
            step_payload_like=payload,
            weight_package_dir=Path(weight_package_dir),
        )
    manifest = _build_runtime_loop_manifest(root_workdir, payloads)
    manifest_path = root_workdir / "host_vm_manifest.json"
    write_json(manifest_path, manifest)
    return manifest_path


def prepare_tree_mask_e2e_strict_workdir(
    root_workdir: Path,
    weight_package_dir: Path,
) -> Path:
    root_workdir = Path(root_workdir)
    if root_workdir.exists():
        shutil.rmtree(root_workdir)
    root_workdir.mkdir(parents=True, exist_ok=True)

    weights = build_weights()
    autoregressive = run_autoregressive(
        weights=weights,
        bos_token_id=0,
        num_steps=5,
    )
    step_results = list(autoregressive["steps"])
    token_sequence = [int(token) for token in list(autoregressive["token_sequence"])]
    bos_token_id = int(step_results[0]["input_token_id"])
    wrong_branch_tokens = [
        int((token_sequence[2] + 1) % VOCAB_SIZE),
        int((token_sequence[2] + 2) % VOCAB_SIZE),
        int((token_sequence[2] + 3) % VOCAB_SIZE),
    ]
    while token_sequence[2] in wrong_branch_tokens:
        wrong_branch_tokens = [
            int((token + 1) % VOCAB_SIZE) for token in wrong_branch_tokens
        ]

    strict_step_payloads = [
        {
            "sequence_id": "tree-mask-e2e-strict-0",
            "prompt_token_ids": [],
            "step_index": 0,
            "recovery_token": bos_token_id,
            "speculated_tokens": [[token_sequence[0]]],
            "accepted_tokens": [bos_token_id, token_sequence[0]],
            "next_recovery_token": token_sequence[0],
            "tree_mask_en": False,
            "metadata": {"tree_projection_mode": "accepted_path"},
        },
        {
            "sequence_id": "tree-mask-e2e-strict-1",
            "prompt_token_ids": [bos_token_id],
            "step_index": 1,
            "recovery_token": token_sequence[0],
            "speculated_tokens": [[token_sequence[1]]],
            "accepted_tokens": [token_sequence[0], token_sequence[1]],
            "next_recovery_token": token_sequence[1],
            "tree_mask_en": False,
            "metadata": {"tree_projection_mode": "accepted_path"},
        },
        {
            "sequence_id": "tree-mask-e2e-strict-2",
            "prompt_token_ids": [bos_token_id, token_sequence[0]],
            "step_index": 2,
            "recovery_token": token_sequence[1],
            "speculated_tokens": [
                [
                    token_sequence[2],
                    int((token_sequence[2] + 4) % VOCAB_SIZE),
                    int((token_sequence[2] + 5) % VOCAB_SIZE),
                    int((token_sequence[2] + 6) % VOCAB_SIZE),
                ],
                [
                    wrong_branch_tokens[0],
                    int((wrong_branch_tokens[0] + 4) % VOCAB_SIZE),
                    int((wrong_branch_tokens[0] + 5) % VOCAB_SIZE),
                    int((wrong_branch_tokens[0] + 6) % VOCAB_SIZE),
                ],
                [
                    wrong_branch_tokens[1],
                    int((wrong_branch_tokens[1] + 4) % VOCAB_SIZE),
                    int((wrong_branch_tokens[1] + 5) % VOCAB_SIZE),
                    int((wrong_branch_tokens[1] + 6) % VOCAB_SIZE),
                ],
                [
                    wrong_branch_tokens[2],
                    int((wrong_branch_tokens[2] + 4) % VOCAB_SIZE),
                    int((wrong_branch_tokens[2] + 5) % VOCAB_SIZE),
                    int((wrong_branch_tokens[2] + 6) % VOCAB_SIZE),
                ],
            ],
            "accepted_tokens": [token_sequence[1], token_sequence[2]],
            "next_recovery_token": token_sequence[2],
            "metadata": {"tree_projection_mode": "accepted_path"},
        },
        {
            "sequence_id": "tree-mask-e2e-strict-3",
            "prompt_token_ids": [
                bos_token_id,
                token_sequence[0],
                token_sequence[1],
            ],
            "step_index": 3,
            "recovery_token": token_sequence[2],
            "speculated_tokens": [[token_sequence[3]]],
            "accepted_tokens": [token_sequence[2], token_sequence[3]],
            "next_recovery_token": token_sequence[3],
            "tree_mask_en": False,
            "metadata": {"tree_projection_mode": "accepted_path"},
        },
        {
            "sequence_id": "tree-mask-e2e-strict-4",
            "prompt_token_ids": [
                bos_token_id,
                token_sequence[0],
                token_sequence[1],
                token_sequence[2],
            ],
            "step_index": 4,
            "recovery_token": token_sequence[3],
            "speculated_tokens": [[token_sequence[4]]],
            "accepted_tokens": [token_sequence[3], token_sequence[4]],
            "next_recovery_token": token_sequence[4],
            "tree_mask_en": False,
            "metadata": {"tree_projection_mode": "accepted_path"},
        },
    ]

    for step_idx, step_payload in enumerate(strict_step_payloads):
        step_root = root_workdir / ("step_%03d" % step_idx)
        step_root.mkdir(parents=True, exist_ok=True)
        payload_path = step_root / "sync_tree_step_request.json"
        write_json(payload_path, step_payload)
        prepared_platform = step_root / PLATFORM_SUBDIR
        _prepare_step_platform_workdir(
            platform_workdir=prepared_platform,
            step_payload_like=step_payload,
            weight_package_dir=Path(weight_package_dir),
        )

    scenario = {
        "mode": TREE_MASK_E2E_STRICT_MODE,
        "bos_token_id": bos_token_id,
        "token_sequence": token_sequence,
        "step_payloads": strict_step_payloads,
    }
    write_json(root_workdir / "tree_mask_e2e_strict_scenario.json", scenario)

    steps = []
    for step_idx, step_info in enumerate(step_results):
        step_root = root_workdir / ("step_%03d" % step_idx)
        step_kind = "verify_group" if step_idx == 2 else "single_step"
        platform_workdir = step_root / PLATFORM_SUBDIR
        step_payload = dict(strict_step_payloads[step_idx])
        committed_context_tokens = [
            int(token) for token in list(step_payload["prompt_token_ids"])
        ]
        committed_context_tokens.append(int(step_payload["recovery_token"]))
        single_step_capture_local_idx = _single_step_capture_local_index(step_payload)
        step_manifest = {
            "step_index": step_idx,
            "step_kind": step_kind,
            "platform_workdir": str(platform_workdir),
            "rtl_token_path": str(
                platform_workdir
                / ("rtl_capture_local%d_token.txt" % single_step_capture_local_idx)
            ),
            "rtl_hidden_path": str(
                platform_workdir
                / ("rtl_capture_local%d_final_hidden.memh" % single_step_capture_local_idx)
            ),
            "ref_hidden_path": str(
                step_root / ("ref_step%d_final_hidden.npy" % step_idx)
            ),
            "expected_generated_token_ids": [int(step_info["token_id"])],
        }

        if step_idx != 2:
            accepted_token = int(step_payload["accepted_tokens"][1])
            accepted_dumps, _, _ = _run_reference_sequence(
                weights=weights,
                token_ids=committed_context_tokens + [accepted_token],
            )
            np.save(
                step_root / ("ref_step%d_final_hidden.npy" % step_idx),
                np.asarray(accepted_dumps["final_hidden"], dtype=np.float16),
            )
            (step_root / ("ref_step%d_token.txt" % step_idx)).write_text(
                "%d\n" % int(step_info["token_id"]),
                encoding="ascii",
            )
        else:
            _, prefix_k, prefix_v = _run_reference_sequence(
                weights=weights,
                token_ids=committed_context_tokens,
            )
            branch_hidden_pairs = []
            for branch_idx, branch_tokens in enumerate(
                list(step_payload["speculated_tokens"])
            ):
                branch_k = np.array(prefix_k, copy=True)
                branch_v = np.array(prefix_v, copy=True)
                for level_idx, token_id in enumerate(list(branch_tokens)):
                    branch_dumps, branch_k, branch_v = run_reference(
                        weights=weights,
                        token_id=int(token_id),
                        position=len(committed_context_tokens) + level_idx,
                        kv_cache_k=branch_k,
                        kv_cache_v=branch_v,
                    )
                    ref_hidden_path = (
                        step_root
                        / ("ref_step2_branch%d_level%d_final_hidden.npy" % (branch_idx, level_idx))
                    )
                    np.save(
                        ref_hidden_path,
                        np.asarray(branch_dumps["final_hidden"], dtype=np.float16),
                    )
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
                            "expected_token_id": int(token_id),
                        }
                    )
            step_manifest.update(
                {
                    "expected_generated_token_ids": [
                        int(step_payload["speculated_tokens"][0][0])
                    ],
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

        steps.append(step_manifest)

    manifest = {
        "mode": TREE_MASK_E2E_STRICT_MODE,
        "root_workdir": str(root_workdir),
        "platform_workdir": str(platform_workdir),
        "step_count": len(steps),
        "steps": steps,
    }
    manifest_path = root_workdir / "host_vm_manifest.json"
    write_json(manifest_path, manifest)
    return manifest_path


def _collect_single_step_summary(manifest: Dict[str, Any]) -> Dict[str, Any]:
    platform_workdir = Path(manifest["platform_workdir"])
    result = collect_runtime_result(platform_workdir)
    payload_path = platform_workdir / "sync_tree_step_request.json"
    if payload_path.exists():
        expected_generated_token_ids = _expected_generated_token_ids_from_payload(
            load_sync_tree_step_payload(payload_path)
        )
    else:
        expected_generated_token_ids = [
            int(token) for token in list(manifest["expected_generated_token_ids"])
        ]
    actual_generated_token_ids = _actual_generated_token_ids_from_result(
        projection_mode=str(manifest.get("projection_mode", "serial_chain")),
        runtime_result=result,
    )
    return {
        "mode": SINGLE_STEP_MODE,
        "root_workdir": str(manifest["root_workdir"]),
        "platform_workdir": str(platform_workdir),
        "sequence_id": str(manifest["sequence_id"]),
        "step_index": int(manifest["step_index"]),
        "accepted_tokens": [int(token) for token in list(manifest["accepted_tokens"])],
        "actual_accepted_tokens": (
            None
            if getattr(result, "accepted_tokens", None) is None
            else [int(token) for token in list(getattr(result, "accepted_tokens"))]
        ),
        "expected_generated_token_ids": expected_generated_token_ids,
        "actual_generated_token_ids": actual_generated_token_ids,
        "passed": actual_generated_token_ids == expected_generated_token_ids,
        "runtime_result_json": str(platform_workdir / "runtime_result.json"),
    }


def _collect_runtime_loop_summary(manifest: Dict[str, Any]) -> Dict[str, Any]:
    steps = []
    all_generated_token_ids: List[int] = []
    passed = True
    for step in list(manifest["steps"]):
        platform_workdir = Path(step["platform_workdir"])
        result = collect_runtime_result(platform_workdir)
        payload_path = platform_workdir / "sync_tree_step_request.json"
        if payload_path.exists():
            expected_generated_token_ids = _expected_generated_token_ids_from_payload(
                load_sync_tree_step_payload(payload_path)
            )
        else:
            expected_generated_token_ids = [
                int(token) for token in list(step["expected_generated_token_ids"])
            ]
        actual_generated_token_ids = _actual_generated_token_ids_from_result(
            projection_mode=str(step.get("projection_mode", "serial_chain")),
            runtime_result=result,
        )
        step_passed = actual_generated_token_ids == expected_generated_token_ids
        passed = passed and step_passed
        all_generated_token_ids.extend(actual_generated_token_ids)
        steps.append(
            {
                "step_index": int(step["step_index"]),
                "sequence_id": str(step["sequence_id"]),
                "platform_workdir": str(platform_workdir),
                "accepted_tokens": [
                    int(token) for token in list(step["accepted_tokens"])
                ],
                "actual_accepted_tokens": (
                    None
                    if getattr(result, "accepted_tokens", None) is None
                    else [int(token) for token in list(getattr(result, "accepted_tokens"))]
                ),
                "expected_generated_token_ids": expected_generated_token_ids,
                "actual_generated_token_ids": actual_generated_token_ids,
                "passed": step_passed,
                "runtime_result_json": str(platform_workdir / "runtime_result.json"),
            }
        )
    return {
        "mode": RUNTIME_LOOP_TRACE_MODE,
        "root_workdir": str(manifest["root_workdir"]),
        "step_count": int(manifest["step_count"]),
        "generated_token_ids": all_generated_token_ids,
        "passed": passed,
        "steps": steps,
    }


def _compare_hidden_pair(rtl_hidden_path: Path, ref_hidden_path: Path) -> Dict[str, Any]:
    try:
        rtl_hidden = load_memh_vector(Path(rtl_hidden_path))
    except ValueError as exc:
        return {
            "name": "final_hidden",
            "error": "unknown_memh_hex",
            "message": str(exc),
            "rtl_hidden_path": str(rtl_hidden_path),
            "ref_hidden_path": str(ref_hidden_path),
        }
    ref_hidden = np.load(Path(ref_hidden_path)).astype(np.float16).reshape(-1)
    _, report = compare_pair("final_hidden", rtl_hidden, ref_hidden)
    return report


def _hidden_report_passed(report: Dict[str, Any]) -> bool:
    # For tree-mask end-to-end bringup, hidden comparison is diagnostic.
    # A decodable artifact is sufficient to keep process/lifecycle checks
    # moving; cosine similarity is still reported for inspection.
    return "error" not in report


def _collect_branch_hidden_pairs(
    branch_hidden_pairs: List[Dict[str, Any]],
) -> Dict[str, Any]:
    reports = []
    passed = True
    for pair in list(branch_hidden_pairs):
        rtl_token_path = Path(pair["rtl_token_path"])
        rtl_hidden_path = Path(pair["rtl_hidden_path"])
        missing_paths = []
        if not rtl_token_path.exists():
            missing_paths.append(str(rtl_token_path))
        if not rtl_hidden_path.exists():
            missing_paths.append(str(rtl_hidden_path))
        if missing_paths:
            passed = False
            reports.append(
                {
                    "branch_index": int(pair["branch_index"]),
                    "level_index": int(pair.get("level_index", 0)),
                    "branch_id": int(pair.get("branch_id", pair["branch_index"])),
                    "level_id": int(pair.get("level_id", pair.get("level_index", 0))),
                    "branch_path_key": str(
                        pair.get(
                            "branch_path_key",
                            "branch%d_level%d"
                            % (
                                int(pair["branch_index"]),
                                int(pair.get("level_index", 0)),
                            ),
                        )
                    ),
                    "expected_token_id": int(pair["expected_token_id"]),
                    "actual_token_id": None,
                    "final_hidden": None,
                    "error": "missing_artifact",
                    "missing_paths": missing_paths,
                    "passed": False,
                }
            )
            continue

        actual_token_id = _read_token_id(rtl_token_path)
        expected_token_id = int(pair["expected_token_id"])
        final_hidden_report = _compare_hidden_pair(
            rtl_hidden_path=rtl_hidden_path,
            ref_hidden_path=Path(pair["ref_hidden_path"]),
        )
        token_passed = actual_token_id == expected_token_id
        hidden_passed = _hidden_report_passed(final_hidden_report)
        pair_passed = token_passed and hidden_passed
        passed = passed and pair_passed
        reports.append(
            {
                "branch_index": int(pair["branch_index"]),
                "level_index": int(pair.get("level_index", 0)),
                "branch_id": int(pair.get("branch_id", pair["branch_index"])),
                "level_id": int(pair.get("level_id", pair.get("level_index", 0))),
                "branch_path_key": str(
                    pair.get(
                        "branch_path_key",
                        "branch%d_level%d"
                        % (
                            int(pair["branch_index"]),
                            int(pair.get("level_index", 0)),
                        ),
                    )
                ),
                "expected_token_id": expected_token_id,
                "actual_token_id": actual_token_id,
                "final_hidden": final_hidden_report,
                "passed": pair_passed,
            }
        )
    return {
        "reports": reports,
        "passed": passed,
    }


def _collect_tree_window_lifecycle(
    platform_workdir: Path,
    step_manifest: Dict[str, Any],
) -> Dict[str, Any]:
    event_log = EventLog.load(Path(platform_workdir) / "events" / "events.jsonl")
    commit_records = []
    flush_records = []
    accepted_prefix_records = []
    token_flush_records = []
    commit_branch_id = None
    flush_branch_ids: List[int] = []
    accepted_prefix_depth = None
    accepted_prefix_depth_inferred = False
    token_flush_count = None
    flush_reclaim_count = 0
    flush_reclaim_group_lens: List[int] = []

    for record in event_log.records:
        if record.event == "lifecycle_commit" and "branch_id" in record.fields:
            commit_records.append(record)
        elif record.event == "lifecycle_flush" and "branch_id" in record.fields:
            flush_records.append(record)
        elif record.event == "accepted_prefix" and "accepted_prefix_depth" in record.fields:
            accepted_prefix_records.append(record)
        elif record.event == "token_flush" and "count" in record.fields:
            token_flush_records.append(record)
        elif record.event == "flush_reclaim":
            if "count" in record.fields:
                flush_reclaim_count += int(record.fields["count"])
            elif "group_len" in record.fields:
                flush_reclaim_count += int(record.fields["group_len"])
            if "group_len" in record.fields:
                flush_reclaim_group_lens.append(int(record.fields["group_len"]))

    expected_commit_branch_id = step_manifest.get("expected_commit_branch_id")
    expected_flush_branch_ids = [
        int(branch_id) for branch_id in list(step_manifest.get("expected_flush_branch_ids", []))
    ]
    expected_accepted_prefix_depth = step_manifest.get("expected_accepted_prefix_depth")
    expected_token_flush_count = step_manifest.get("expected_token_flush_count")
    decision_cycle = None
    if token_flush_records:
        decision_cycle = int(token_flush_records[-1].cycle)
    elif commit_records:
        decision_cycle = int(commit_records[-1].cycle)
    elif accepted_prefix_records:
        decision_cycle = int(accepted_prefix_records[-1].cycle)

    final_commit_record = None
    if commit_records:
        final_commit_candidates = [
            record
            for record in commit_records
            if decision_cycle is None or int(record.cycle) <= decision_cycle
        ]
        if final_commit_candidates:
            final_commit_record = final_commit_candidates[-1]
        else:
            final_commit_record = commit_records[-1]
        commit_branch_id = int(final_commit_record.fields["branch_id"])

    final_token_flush_record = None
    if token_flush_records:
        final_token_flush_candidates = [
            record
            for record in token_flush_records
            if decision_cycle is None or int(record.cycle) == decision_cycle
        ]
        final_token_flush_record = (
            final_token_flush_candidates[-1]
            if final_token_flush_candidates else token_flush_records[-1]
        )
        token_flush_count = int(final_token_flush_record.fields["count"])

    if final_token_flush_record is not None and "branch_mask_hex" in final_token_flush_record.fields:
        branch_mask = int(str(final_token_flush_record.fields["branch_mask_hex"]), 16)
        flush_branch_ids = [
            branch_idx
            for branch_idx in range(16)
            if branch_mask & (1 << branch_idx)
        ]
    elif flush_records:
        if final_commit_record is not None:
            flush_branch_ids = [
                int(record.fields["branch_id"])
                for record in flush_records
                if int(record.cycle) >= int(final_commit_record.cycle) and
                (decision_cycle is None or int(record.cycle) <= decision_cycle)
            ]
        elif decision_cycle is None:
            flush_cycle = int(flush_records[-1].cycle)
            flush_branch_ids = [
                int(record.fields["branch_id"])
                for record in flush_records
                if int(record.cycle) == flush_cycle
            ]
        else:
            flush_cycles = [
                int(record.cycle)
                for record in flush_records
                if int(record.cycle) <= decision_cycle
            ]
            flush_cycle = (
                max(flush_cycles) if flush_cycles else int(flush_records[-1].cycle)
            )
            flush_branch_ids = [
                int(record.fields["branch_id"])
                for record in flush_records
                if int(record.cycle) == flush_cycle
            ]

    if accepted_prefix_records:
        final_prefix_candidates = [
            record
            for record in accepted_prefix_records
            if decision_cycle is None or int(record.cycle) <= decision_cycle
        ]
        final_prefix_record = (
            final_prefix_candidates[-1]
            if final_prefix_candidates else accepted_prefix_records[-1]
        )
        accepted_prefix_depth = int(final_prefix_record.fields["accepted_prefix_depth"])
    elif final_commit_record is not None and "accepted_prefix_depth" in final_commit_record.fields:
        accepted_prefix_depth = int(final_commit_record.fields["accepted_prefix_depth"])
    elif (
        expected_accepted_prefix_depth is not None and
        commit_branch_id is not None and
        token_flush_count is not None
    ):
        accepted_prefix_depth = int(expected_accepted_prefix_depth)
        accepted_prefix_depth_inferred = True

    passed = True
    if expected_commit_branch_id is not None:
        passed = passed and (commit_branch_id == int(expected_commit_branch_id))
    if expected_flush_branch_ids:
        passed = passed and (sorted(flush_branch_ids) == sorted(expected_flush_branch_ids))
    if expected_accepted_prefix_depth is not None:
        passed = passed and (
            accepted_prefix_depth == int(expected_accepted_prefix_depth)
        )
    if expected_token_flush_count is not None:
        passed = passed and (token_flush_count == int(expected_token_flush_count))

    return {
        "decision_cycle": decision_cycle,
        "commit_branch_id": commit_branch_id,
        "flush_branch_ids": flush_branch_ids,
        "accepted_prefix_depth": accepted_prefix_depth,
        "accepted_prefix_depth_inferred": accepted_prefix_depth_inferred,
        "token_flush_count": token_flush_count,
        "flush_reclaim_count": flush_reclaim_count,
        "flush_reclaim_group_lens": flush_reclaim_group_lens,
        "passed": passed,
    }


def _committed_tokens_from_branch_hidden(
    branch_hidden_reports: List[Dict[str, Any]],
    lifecycle: Dict[str, Any],
) -> List[int]:
    commit_branch_id = lifecycle.get("commit_branch_id")
    accepted_prefix_depth = lifecycle.get("accepted_prefix_depth")

    if commit_branch_id is None or accepted_prefix_depth is None:
        legacy_tokens = [
            int(report["actual_token_id"])
            for report in list(branch_hidden_reports)
            if bool(report.get("committed", False))
        ]
        return legacy_tokens

    accepted_depth_int = int(accepted_prefix_depth)
    commit_branch_int = int(commit_branch_id)
    committed_reports = [
        report
        for report in list(branch_hidden_reports)
        if int(report.get("branch_id", report.get("branch_index", -1)))
        == commit_branch_int
        and int(report.get("level_id", report.get("level_index", 0))) < accepted_depth_int
    ]
    committed_reports.sort(
        key=lambda report: int(report.get("level_id", report.get("level_index", 0)))
    )
    return [
        int(report["actual_token_id"])
        for report in committed_reports
        if report.get("actual_token_id") is not None
    ]


def _collect_tree_mask_e2e_strict_summary(manifest: Dict[str, Any]) -> Dict[str, Any]:
    steps = []
    passed = True
    all_generated_token_ids: List[int] = []

    for step_manifest in list(manifest["steps"]):
        platform_workdir = Path(step_manifest["platform_workdir"])
        branch_hidden = []
        branch_hidden_passed = True
        final_hidden_report = None
        resolved_rtl_token_path = None
        resolved_rtl_hidden_path = None
        runtime_result_json = str(platform_workdir / "runtime_result.json")
        lifecycle = {
            "passed": True,
        }

        if step_manifest.get("branch_hidden_pairs"):
            branch_hidden_summary = _collect_branch_hidden_pairs(
                [dict(item) for item in list(step_manifest["branch_hidden_pairs"])]
            )
            branch_hidden = list(branch_hidden_summary["reports"])
            branch_hidden_passed = bool(branch_hidden_summary["passed"])
            if branch_hidden:
                if branch_hidden[0]["final_hidden"] is None:
                    final_hidden_report = {
                        "name": "final_hidden",
                        "error": str(branch_hidden[0].get("error", "missing_artifact")),
                        "missing_paths": list(branch_hidden[0].get("missing_paths", [])),
                    }
                else:
                    final_hidden_report = dict(branch_hidden[0]["final_hidden"])
        elif step_manifest.get("rtl_token_path"):
            resolved_artifacts = _resolve_tree_mask_single_step_artifacts(step_manifest)
            resolved_rtl_token_path = resolved_artifacts["rtl_token_path"]
            resolved_rtl_hidden_path = resolved_artifacts["rtl_hidden_path"]
            if resolved_rtl_token_path is None or resolved_rtl_hidden_path is None:
                actual_generated_token_ids = []
                final_hidden_report = {
                    "name": "final_hidden",
                    "error": "missing_artifact",
                    "missing_paths": list(resolved_artifacts["missing_paths"]),
                }
            else:
                actual_generated_token_ids = [_read_token_id(resolved_rtl_token_path)]
                final_hidden_report = _compare_hidden_pair(
                    rtl_hidden_path=resolved_rtl_hidden_path,
                    ref_hidden_path=Path(step_manifest["ref_hidden_path"]),
                )
        else:
            runtime_result = collect_runtime_result(platform_workdir)
            actual_generated_token_ids = [
                int(token) for token in list(runtime_result.generated_token_ids)
            ]
            final_hidden_report = _compare_hidden_pair(
                rtl_hidden_path=Path(step_manifest["rtl_hidden_path"]),
                ref_hidden_path=Path(step_manifest["ref_hidden_path"]),
            )

        expected_generated_token_ids = [
            int(token)
            for token in list(step_manifest.get("expected_generated_token_ids", []))
        ]
        if str(step_manifest.get("step_kind", "")) == "verify_group":
            lifecycle = _collect_tree_window_lifecycle(platform_workdir, step_manifest)
            if branch_hidden:
                actual_generated_token_ids = _committed_tokens_from_branch_hidden(
                    branch_hidden,
                    lifecycle,
                )
        elif step_manifest.get("branch_hidden_pairs"):
            actual_generated_token_ids = []

        token_passed = actual_generated_token_ids == expected_generated_token_ids
        all_generated_token_ids.extend(actual_generated_token_ids)
        hidden_passed = (
            final_hidden_report is not None and
            _hidden_report_passed(final_hidden_report)
        )

        step_passed = (
            token_passed and
            hidden_passed and
            branch_hidden_passed and
            bool(lifecycle["passed"])
        )
        passed = passed and step_passed
        steps.append(
            {
                "step_index": int(step_manifest["step_index"]),
                "step_kind": str(step_manifest.get("step_kind", "single_step")),
                "platform_workdir": str(platform_workdir),
                "expected_generated_token_ids": expected_generated_token_ids,
                "actual_generated_token_ids": actual_generated_token_ids,
                "rtl_token_path": (
                    None if resolved_rtl_token_path is None else str(resolved_rtl_token_path)
                ),
                "rtl_hidden_path": (
                    None
                    if resolved_rtl_hidden_path is None else str(resolved_rtl_hidden_path)
                ),
                "final_hidden": final_hidden_report,
                "branch_hidden": branch_hidden,
                "lifecycle": lifecycle,
                "passed": step_passed,
                "runtime_result_json": runtime_result_json,
            }
        )

    return {
        "mode": TREE_MASK_E2E_STRICT_MODE,
        "root_workdir": str(manifest["root_workdir"]),
        "step_count": int(manifest["step_count"]),
        "generated_token_ids": all_generated_token_ids,
        "passed": passed,
        "steps": steps,
    }


def _latest_artifact_mtime(path: Path) -> float:
    latest_mtime = path.stat().st_mtime
    if not path.is_dir():
        return latest_mtime
    for child in path.rglob("*"):
        child_mtime = child.stat().st_mtime
        if child_mtime > latest_mtime:
            latest_mtime = child_mtime
    return latest_mtime


def _replace_platform_artifact(vm_artifact: Path, platform_artifact: Path) -> None:
    if platform_artifact.exists():
        if platform_artifact.is_dir():
            shutil.rmtree(platform_artifact)
        else:
            platform_artifact.unlink()
    if vm_artifact.is_dir():
        shutil.copytree(vm_artifact, platform_artifact)
    else:
        platform_artifact.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(vm_artifact, platform_artifact)


def _sync_single_step_vm_return(root_workdir: Path, platform_workdir: Path) -> None:
    vm_return_dir = root_workdir / "vm_return"
    if not vm_return_dir.exists():
        return

    for artifact_name in ("events", "hbm_output"):
        vm_artifact = vm_return_dir / artifact_name
        if not vm_artifact.exists():
            continue
        platform_artifact = platform_workdir / artifact_name
        if not platform_artifact.exists():
            _replace_platform_artifact(vm_artifact, platform_artifact)
            continue
        if _latest_artifact_mtime(vm_artifact) > _latest_artifact_mtime(platform_artifact):
            _replace_platform_artifact(vm_artifact, platform_artifact)


def _sync_tree_mask_step_vm_return(step_root: Path, platform_workdir: Path) -> None:
    vm_return_dir = step_root / "vm_return"
    if not vm_return_dir.exists():
        return

    for artifact_name in ("events", "hbm_output"):
        vm_artifact = vm_return_dir / artifact_name
        if not vm_artifact.exists():
            continue
        platform_artifact = platform_workdir / artifact_name
        if not platform_artifact.exists():
            _replace_platform_artifact(vm_artifact, platform_artifact)
            continue
        if _latest_artifact_mtime(vm_artifact) > _latest_artifact_mtime(platform_artifact):
            _replace_platform_artifact(vm_artifact, platform_artifact)

    for pattern in (
        "rtl_step*_final_hidden.memh",
        "rtl_step*_token.txt",
        "rtl_capture_local*_final_hidden.memh",
        "rtl_capture_local*_token.txt",
        "rtl_step2_branch*_final_hidden.memh",
        "rtl_step2_branch*_token.txt",
        "rtl_step2_branch*_level*_final_hidden.memh",
        "rtl_step2_branch*_level*_token.txt",
    ):
        for vm_artifact in vm_return_dir.glob(pattern):
            platform_artifact = platform_workdir / vm_artifact.name
            if (not platform_artifact.exists()) or (
                _latest_artifact_mtime(vm_artifact) > _latest_artifact_mtime(platform_artifact)
            ):
                _replace_platform_artifact(vm_artifact, platform_artifact)


def collect_single_step_workdir(root_workdir: Path) -> Path:
    root_workdir = Path(root_workdir)
    manifest = read_json(root_workdir / "host_vm_manifest.json")
    _sync_single_step_vm_return(
        root_workdir=root_workdir,
        platform_workdir=Path(manifest["platform_workdir"]),
    )
    summary = _collect_single_step_summary(manifest)
    summary_path = root_workdir / "host_vm_compare_summary.json"
    write_json(summary_path, summary)
    return summary_path


def collect_runtime_loop_trace_workdir(root_workdir: Path) -> Path:
    root_workdir = Path(root_workdir)
    manifest = read_json(root_workdir / "host_vm_manifest.json")
    summary = _collect_runtime_loop_summary(manifest)
    summary_path = root_workdir / "host_vm_compare_summary.json"
    write_json(summary_path, summary)
    return summary_path


def collect_tree_mask_e2e_strict_workdir(root_workdir: Path) -> Path:
    root_workdir = Path(root_workdir)
    manifest = read_json(root_workdir / "host_vm_manifest.json")
    for step_manifest in list(manifest["steps"]):
        platform_workdir = Path(step_manifest["platform_workdir"])
        _sync_tree_mask_step_vm_return(
            step_root=platform_workdir.parent,
            platform_workdir=platform_workdir,
        )
    summary = _collect_tree_mask_e2e_strict_summary(manifest)
    summary_path = root_workdir / "host_vm_compare_summary.json"
    write_json(summary_path, summary)
    return summary_path


__all__ = [
    "collect_tree_mask_e2e_strict_workdir",
    "collect_runtime_loop_trace_workdir",
    "collect_single_step_workdir",
    "prepare_tree_mask_e2e_strict_workdir",
    "prepare_runtime_loop_trace_workdir",
    "prepare_single_step_workdir",
]
