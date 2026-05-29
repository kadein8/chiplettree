from typing import Any, Dict, Iterable, List, Optional

from rtl_backend.compat import dataclass, field
from rtl_backend.formats import read_json, write_json
from rtl_backend.stimulus import (
    NativeTreeRequest,
    TREE_FRONTIER_SLOTS,
    TREE_MAX_FRONTIER_LEVELS,
    TREE_MAX_PREFIX_NODES,
)


def _as_mapping(value: object) -> Dict[str, Any]:
    if isinstance(value, dict):
        return dict(value)
    return {
        name: getattr(value, name)
        for name in dir(value)
        if not name.startswith("_") and hasattr(value, name)
    }


def _coerce_int_list(value: object) -> List[int]:
    if value is None:
        return []
    if hasattr(value, "tolist"):
        value = value.tolist()
    if isinstance(value, (list, tuple)):
        return [int(item) for item in value]
    return [int(value)]


def _coerce_nested_int_lists(value: object) -> List[List[int]]:
    if value is None:
        return []
    if hasattr(value, "tolist"):
        value = value.tolist()
    if not isinstance(value, (list, tuple)):
        return [[int(value)]]
    if not value:
        return []
    first = value[0]
    if isinstance(first, (list, tuple)) or hasattr(first, "tolist"):
        return [_coerce_int_list(item) for item in value]
    return [_coerce_int_list(value)]


def _coerce_int_matrix(value: object) -> List[List[int]]:
    if value is None:
        return []
    if hasattr(value, "tolist"):
        value = value.tolist()
    if not isinstance(value, (list, tuple)):
        return [_coerce_int_list(value)]
    if not value:
        return []
    first = value[0]
    if isinstance(first, (list, tuple)) or hasattr(first, "tolist"):
        return [_coerce_int_list(row) for row in value]
    return [_coerce_int_list(value)]


def _first_row(value: object) -> List[int]:
    matrix = _coerce_int_matrix(value)
    return matrix[0] if matrix else []


def _get_field(value: object, key: str, default: Any = None) -> Any:
    if value is None:
        return default
    if isinstance(value, dict):
        return value.get(key, default)
    return getattr(value, key, default)


def _coerce_parent_map(value: object) -> Dict[int, int]:
    if value is None:
        return {}
    if isinstance(value, dict):
        return {int(key): int(parent) for key, parent in value.items()}
    return {
        int(key): int(parent)
        for key, parent in dict(value).items()  # type: ignore[arg-type]
    }


def _compute_prefix_node_ids(
    prompt_token_ids: List[int],
    recovery_token: Optional[int],
) -> List[int]:
    prefix_count = len(prompt_token_ids)
    if recovery_token is not None:
        prefix_count += 1
    prefix_count = min(TREE_MAX_PREFIX_NODES, prefix_count)
    return [index + 1 for index in range(prefix_count)]


def _flatten_speculated_tokens(speculated_tokens: List[List[int]]) -> List[int]:
    flat = []
    for branch_tokens in speculated_tokens:
        flat.extend(int(token) for token in branch_tokens)
    return flat


def _build_native_tree_request(
    sequence_id: str,
    prompt_token_ids: List[int],
    recovery_token: int,
    speculated_tokens: List[List[int]],
    step_index: int,
    tree_parent_map: Optional[Dict[int, int]] = None,
    shared_prefix_nodes: Optional[List[int]] = None,
    tree_mask_en: bool = True,
) -> NativeTreeRequest:
    prefix_slot_valid = 0
    committed_prefix_token_ids = list(prompt_token_ids)
    if recovery_token is not None:
        committed_prefix_token_ids.append(int(recovery_token))
    prefix_node_ids = _compute_prefix_node_ids(
        prompt_token_ids=prompt_token_ids,
        recovery_token=recovery_token,
    )
    prefix_token_ids = committed_prefix_token_ids[:TREE_MAX_PREFIX_NODES]
    prefix_position_ids = list(range(len(prefix_token_ids)))
    for index in range(len(prefix_node_ids)):
        prefix_slot_valid |= 1 << index

    flat_speculated_tokens = _flatten_speculated_tokens(speculated_tokens)
    frontier_levels = min(
        max((len(branch_tokens) for branch_tokens in speculated_tokens), default=0),
        TREE_MAX_FRONTIER_LEVELS,
    )
    frontier_level_valid = 0
    frontier_slot_valid_by_level: List[int] = []
    frontier_tree_mask_en_by_level: List[int] = []
    frontier_node_ids_by_level: List[List[int]] = []
    frontier_parent_node_ids_by_level: List[List[int]] = []
    frontier_token_ids_by_level: List[List[int]] = []
    frontier_referenced_token_ids_by_level: List[List[int]] = []
    frontier_position_ids_by_level: List[List[int]] = []
    frontier_referenced_position_ids_by_level: List[List[int]] = []
    frontier_branch_ids_by_level: List[List[int]] = []
    frontier_level_ids_by_level: List[List[int]] = []

    node_ids = list(
        range(
            len(prefix_node_ids) + 1,
            len(prefix_node_ids) + 1 + len(flat_speculated_tokens),
        )
    )
    shared_nodes = {int(node_id) for node_id in list(shared_prefix_nodes or [])}
    node_parent_map = dict(tree_parent_map or {})
    branch_node_ids: List[List[int]] = [[] for _ in speculated_tokens]
    node_cursor = 0
    for level_idx in range(frontier_levels):
        for branch_idx, branch_tokens in enumerate(
            speculated_tokens[:TREE_FRONTIER_SLOTS]
        ):
            if level_idx >= len(branch_tokens):
                continue
            branch_node_ids[branch_idx].append(node_ids[node_cursor])
            node_cursor += 1

    if not node_parent_map:
        prefix_parent = prefix_node_ids[-1] if prefix_node_ids else 0
        for branch_ids in branch_node_ids:
            parent_node_id = prefix_parent
            for node_id in branch_ids:
                node_parent_map[node_id] = parent_node_id
                parent_node_id = node_id

    for level_idx in range(TREE_MAX_FRONTIER_LEVELS):
        level_nodes = [0] * TREE_FRONTIER_SLOTS
        level_parents = [0] * TREE_FRONTIER_SLOTS
        level_tokens = [0] * TREE_FRONTIER_SLOTS
        level_referenced_tokens = [0] * TREE_FRONTIER_SLOTS
        level_positions = [0] * TREE_FRONTIER_SLOTS
        level_referenced_positions = [0] * TREE_FRONTIER_SLOTS
        level_branch_ids = [0] * TREE_FRONTIER_SLOTS
        level_level_ids = [0] * TREE_FRONTIER_SLOTS
        slot_valid = 0
        for branch_idx, branch_ids in enumerate(
            branch_node_ids[:TREE_FRONTIER_SLOTS]
        ):
            if level_idx >= len(branch_ids):
                continue
            node_id = branch_ids[level_idx]
            parent_node_id = int(
                node_parent_map.get(
                    node_id,
                    prefix_node_ids[-1] if prefix_node_ids else 0,
                )
            )
            if parent_node_id in shared_nodes and parent_node_id not in prefix_node_ids:
                shared_nodes.add(node_id)
            slot_valid |= 1 << branch_idx
            level_nodes[branch_idx] = node_id
            level_parents[branch_idx] = parent_node_id
            level_branch_ids[branch_idx] = branch_idx
            level_level_ids[branch_idx] = level_idx
            level_tokens[branch_idx] = int(speculated_tokens[branch_idx][level_idx])
            if level_idx == 0:
                level_referenced_tokens[branch_idx] = int(recovery_token)
                level_referenced_positions[branch_idx] = len(prompt_token_ids)
            else:
                parent_level_idx = level_idx - 1
                level_referenced_tokens[branch_idx] = int(
                    speculated_tokens[branch_idx][parent_level_idx]
                )
                level_referenced_positions[branch_idx] = (
                    len(prompt_token_ids) +
                    (1 if recovery_token is not None else 0) +
                    parent_level_idx
                )
            level_positions[branch_idx] = (
                len(prompt_token_ids) + (1 if recovery_token is not None else 0) + level_idx
            )
        if slot_valid != 0:
            frontier_level_valid |= 1 << level_idx
        frontier_slot_valid_by_level.append(slot_valid)
        frontier_tree_mask_en_by_level.append(slot_valid if tree_mask_en else 0)
        frontier_node_ids_by_level.append(level_nodes)
        frontier_parent_node_ids_by_level.append(level_parents)
        frontier_token_ids_by_level.append(level_tokens)
        frontier_referenced_token_ids_by_level.append(level_referenced_tokens)
        frontier_position_ids_by_level.append(level_positions)
        frontier_referenced_position_ids_by_level.append(level_referenced_positions)
        frontier_branch_ids_by_level.append(level_branch_ids)
        frontier_level_ids_by_level.append(level_level_ids)

    req_id = ((step_index + len(prompt_token_ids) + int(recovery_token)) & 0xF) or 0x1
    return NativeTreeRequest(
        valid=True,
        req_id=req_id,
        prefix_slot_valid=prefix_slot_valid,
        committed_len=len(committed_prefix_token_ids),
        draft_count=len(flat_speculated_tokens),
        branch_count=min(len(speculated_tokens), TREE_FRONTIER_SLOTS),
        prefix_node_ids=prefix_node_ids[:TREE_MAX_PREFIX_NODES],
        prefix_token_ids=prefix_token_ids,
        prefix_position_ids=prefix_position_ids,
        frontier_level_valid=frontier_level_valid,
        frontier_slot_valid_by_level=frontier_slot_valid_by_level,
        frontier_tree_mask_en_by_level=frontier_tree_mask_en_by_level,
        frontier_node_ids_by_level=frontier_node_ids_by_level,
        frontier_parent_node_ids_by_level=frontier_parent_node_ids_by_level,
        frontier_token_ids_by_level=frontier_token_ids_by_level,
        frontier_referenced_token_ids_by_level=
            frontier_referenced_token_ids_by_level,
        frontier_position_ids_by_level=frontier_position_ids_by_level,
        frontier_referenced_position_ids_by_level=
            frontier_referenced_position_ids_by_level,
        frontier_branch_ids_by_level=frontier_branch_ids_by_level,
        frontier_level_ids_by_level=frontier_level_ids_by_level,
    )


@dataclass(frozen=True)
class SyncTreeStepPayload:
    sequence_id: str
    prompt_token_ids: List[int]
    step_index: int
    recovery_token: int
    speculated_tokens: List[int]
    accepted_tokens: List[int]
    next_recovery_token: int
    native_tree_request: NativeTreeRequest
    speculated_branches: List[List[int]] = field(default_factory=list)
    metadata: Dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> Dict[str, Any]:
        return {
            "sequence_id": self.sequence_id,
            "prompt_token_ids": list(self.prompt_token_ids),
            "step_index": self.step_index,
            "recovery_token": self.recovery_token,
            "speculated_tokens": list(self.speculated_tokens),
            "speculated_branches": [list(branch) for branch in self.speculated_branches],
            "accepted_tokens": list(self.accepted_tokens),
            "next_recovery_token": self.next_recovery_token,
            "native_tree_request": self.native_tree_request.to_dict(),
            "metadata": dict(self.metadata),
        }

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "SyncTreeStepPayload":
        native_tree_request_data = data.get("native_tree_request")
        if isinstance(native_tree_request_data, NativeTreeRequest):
            native_tree_request = native_tree_request_data
        elif native_tree_request_data is None:
            native_tree_request = NativeTreeRequest()
        else:
            native_tree_request = NativeTreeRequest.from_dict(
                dict(native_tree_request_data)
            )
        raw_speculated_tokens = data.get("speculated_tokens", [])
        speculated_branches = [
            [int(token) for token in list(branch)]
            for branch in list(data.get("speculated_branches", []))
        ]
        if not speculated_branches:
            speculated_branches = _coerce_nested_int_lists(raw_speculated_tokens)
        speculated_tokens = _flatten_speculated_tokens(speculated_branches)
        return cls(
            sequence_id=str(data["sequence_id"]),
            prompt_token_ids=[int(token) for token in list(data.get("prompt_token_ids", []))],
            step_index=int(data.get("step_index", 0)),
            recovery_token=int(data.get("recovery_token", 0)),
            speculated_tokens=speculated_tokens,
            accepted_tokens=[
                int(token) for token in list(data.get("accepted_tokens", []))
            ],
            next_recovery_token=int(data.get("next_recovery_token", 0)),
            native_tree_request=native_tree_request,
            speculated_branches=speculated_branches,
            metadata=dict(data.get("metadata", {})),
        )


def sync_tree_step_like_to_payload(step_like: object) -> SyncTreeStepPayload:
    if isinstance(step_like, SyncTreeStepPayload):
        return step_like
    if isinstance(step_like, dict):
        resolved = dict(step_like)
        if "native_tree_request" not in resolved:
            speculated_branches = _coerce_nested_int_lists(
                resolved.get("speculated_tokens", [])
            )
            resolved["speculated_tokens"] = _flatten_speculated_tokens(
                speculated_branches
            )
            resolved["native_tree_request"] = _build_native_tree_request(
                sequence_id=str(resolved["sequence_id"]),
                prompt_token_ids=_coerce_int_list(
                    resolved.get("prompt_token_ids", [])
                ),
                recovery_token=int(resolved.get("recovery_token", 0)),
                speculated_tokens=speculated_branches,
                step_index=int(resolved.get("step_index", 0)),
                tree_parent_map=_coerce_parent_map(
                    resolved.get("tree_parent_map", {})
                ),
                shared_prefix_nodes=_coerce_int_list(
                    resolved.get("shared_prefix_nodes", [])
                ),
                tree_mask_en=bool(resolved.get("tree_mask_en", True)),
            ).to_dict()
            resolved["speculated_branches"] = speculated_branches
        return SyncTreeStepPayload.from_dict(resolved)

    sequence_id = _get_field(step_like, "sequence_id", _get_field(step_like, "seq_id"))
    prompt_token_ids = _coerce_int_list(
        _get_field(step_like, "prompt_token_ids", _get_field(step_like, "token_ids"))
    )
    step_index = int(_get_field(step_like, "step_index", 0))
    recovery_token = _get_field(step_like, "recovery_token")
    if recovery_token is None:
        recovery_token = _get_field(step_like, "recovery_token_id", 0)
    raw_speculated_tokens = _get_field(step_like, "speculated_tokens")
    speculated_branches = _coerce_nested_int_lists(raw_speculated_tokens)
    speculated_tokens = _flatten_speculated_tokens(speculated_branches)
    accepted_tokens = _coerce_int_list(_get_field(step_like, "accepted_tokens"))
    next_recovery_token = _get_field(step_like, "next_recovery_token")
    if next_recovery_token is None:
        next_recovery_token = _get_field(step_like, "next_recovery_token_id", 0)
    metadata = dict(_get_field(step_like, "metadata", {}))

    speculate_result = _get_field(step_like, "speculate_result")
    if speculate_result is not None and not speculated_tokens:
        speculated_branches = _coerce_nested_int_lists(
            _get_field(speculate_result, "speculations")
        )
        if not speculated_branches:
            speculated_branches = _coerce_nested_int_lists(
                _get_field(speculate_result, "tokens")
            )
        speculated_tokens = _flatten_speculated_tokens(speculated_branches)

    verify_result = _get_field(step_like, "verify_result")
    if verify_result is not None and not accepted_tokens:
        accepted_tokens = _first_row(_get_field(verify_result, "new_suffixes"))
        if next_recovery_token in (None, 0):
            recovery_tokens = _coerce_int_list(
                _get_field(verify_result, "recovery_tokens")
            )
            if recovery_tokens:
                next_recovery_token = recovery_tokens[0]

    if recovery_token in (None, 0):
        if accepted_tokens:
            recovery_token = accepted_tokens[0]
        elif speculated_tokens:
            recovery_token = speculated_tokens[0]

    if not accepted_tokens and recovery_token is not None:
        accepted_tokens = [int(recovery_token)]

    if not speculated_tokens:
        speculated_tokens = list(accepted_tokens[1:])
    if not speculated_branches:
        if raw_speculated_tokens is not None:
            speculated_branches = _coerce_nested_int_lists(raw_speculated_tokens)
        elif speculated_tokens:
            speculated_branches = [list(speculated_tokens)]

    if next_recovery_token in (None, 0):
        next_recovery_token = int(recovery_token)

    if sequence_id is None:
        raise TypeError("sync_tree_step_like must provide sequence_id or seq_id")

    native_tree_request = _get_field(step_like, "native_tree_request")
    if native_tree_request is None:
        native_tree_request = _build_native_tree_request(
            sequence_id=str(sequence_id),
            prompt_token_ids=prompt_token_ids,
            recovery_token=int(recovery_token),
            speculated_tokens=speculated_branches,
            step_index=step_index,
            tree_parent_map=_coerce_parent_map(
                _get_field(step_like, "tree_parent_map", {})
            ),
            shared_prefix_nodes=_coerce_int_list(
                _get_field(step_like, "shared_prefix_nodes", [])
            ),
            tree_mask_en=bool(_get_field(step_like, "tree_mask_en", True)),
        )
    elif not isinstance(native_tree_request, NativeTreeRequest):
        native_tree_request = NativeTreeRequest.from_dict(
            _as_mapping(native_tree_request)
        )

    metadata.setdefault("payload_kind", "sync_tree_step")
    metadata.setdefault("tree_projection_mode", "serial_chain")

    return SyncTreeStepPayload(
        sequence_id=str(sequence_id),
        prompt_token_ids=prompt_token_ids,
        step_index=step_index,
        recovery_token=int(recovery_token),
        speculated_tokens=speculated_tokens,
        speculated_branches=speculated_branches,
        accepted_tokens=accepted_tokens,
        next_recovery_token=int(next_recovery_token),
        native_tree_request=native_tree_request,
        metadata=metadata,
    )


def save_sync_tree_step_payload(path: Any, payload: object) -> Any:
    resolved = sync_tree_step_like_to_payload(payload)
    from pathlib import Path

    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    write_json(path, resolved.to_dict())
    return path


def load_sync_tree_step_payload(path: Any) -> SyncTreeStepPayload:
    from pathlib import Path

    return sync_tree_step_like_to_payload(read_json(Path(path)))
