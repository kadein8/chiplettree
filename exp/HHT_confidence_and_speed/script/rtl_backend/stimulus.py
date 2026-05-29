import json
from pathlib import Path
from typing import List

from rtl_backend.compat import dataclass, field

CFG_W = 32
DRAFT_PORTS = 4
NODE_ID_W = 5
TOKEN_ID_W = 16
POSITION_ID_W = 12
CONF_W = 8
REQ_ID_W = 5
SRAM_WDATA_W = 128
HBM_DATA_W = 256
TREE_MAX_PREFIX_NODES = 2
TREE_MAX_FRONTIER_LEVELS = 6
TREE_FRONTIER_SLOTS = 4
VISIBLE_MASK_W = 8
BRANCH_ID_W = 2
TREE_LEVEL_ID_W = 3
VERIFY_WINDOW_SIZE = 17


def _mask(width: int) -> int:
    return (1 << width) - 1


def _bool_bit(value: bool) -> int:
    return 1 if value else 0


def _coerce_visible_mask(value: object) -> int:
    if value is None:
        return 0
    if isinstance(value, int):
        return value
    if hasattr(value, "tolist"):
        value = value.tolist()
    if isinstance(value, (list, tuple)):
        mask = 0
        for index, bit in enumerate(list(value)[:VISIBLE_MASK_W]):
            if int(bit):
                mask |= 1 << index
        return mask
    return int(value)


@dataclass
class DraftCandidate:
    valid: bool = False
    parent_node_id: int = 0
    token_id: int = 0
    referenced_token_id: int = 0
    referenced_position: int = 0
    confidence: int = 0


@dataclass
class RecomputeResponse:
    valid: bool = False
    partial: bool = False
    full: bool = False
    req_id: int = 0
    kv_data_hex: str = "0" * (SRAM_WDATA_W // 4)
    last: bool = False


@dataclass
class HbmResponse:
    valid: bool = False
    req_id: int = 0
    data_hex: str = "0" * (HBM_DATA_W // 4)


@dataclass
class NativeTreeRequest:
    valid: bool = False
    req_id: int = 0
    prefix_slot_valid: int = 0
    committed_len: int = 0
    draft_count: int = 0
    branch_count: int = 0
    prefix_node_ids: List[int] = field(default_factory=list)
    prefix_token_ids: List[int] = field(default_factory=list)
    prefix_position_ids: List[int] = field(default_factory=list)
    frontier_level_valid: int = 0
    frontier_slot_valid_by_level: List[int] = field(default_factory=list)
    frontier_tree_mask_en_by_level: List[int] = field(default_factory=list)
    frontier_node_ids_by_level: List[List[int]] = field(default_factory=list)
    frontier_parent_node_ids_by_level: List[List[int]] = field(default_factory=list)
    frontier_token_ids_by_level: List[List[int]] = field(default_factory=list)
    frontier_referenced_token_ids_by_level: List[List[int]] = field(default_factory=list)
    frontier_position_ids_by_level: List[List[int]] = field(default_factory=list)
    frontier_referenced_position_ids_by_level: List[List[int]] = field(default_factory=list)
    frontier_branch_ids_by_level: List[List[int]] = field(default_factory=list)
    frontier_level_ids_by_level: List[List[int]] = field(default_factory=list)

    def to_dict(self) -> dict:
        return {
            "valid": self.valid,
            "req_id": self.req_id,
            "prefix_slot_valid": self.prefix_slot_valid,
            "committed_len": self.committed_len,
            "draft_count": self.draft_count,
            "branch_count": self.branch_count,
            "prefix_node_ids": list(self.prefix_node_ids),
            "prefix_token_ids": list(self.prefix_token_ids),
            "prefix_position_ids": list(self.prefix_position_ids),
            "frontier_level_valid": self.frontier_level_valid,
            "frontier_slot_valid_by_level": list(self.frontier_slot_valid_by_level),
            "frontier_tree_mask_en_by_level": list(
                self.frontier_tree_mask_en_by_level
            ),
            "frontier_node_ids_by_level": [
                list(level_nodes) for level_nodes in self.frontier_node_ids_by_level
            ],
            "frontier_parent_node_ids_by_level": [
                list(level_nodes) for level_nodes in self.frontier_parent_node_ids_by_level
            ],
            "frontier_token_ids_by_level": [
                list(level_nodes) for level_nodes in self.frontier_token_ids_by_level
            ],
            "frontier_referenced_token_ids_by_level": [
                list(level_nodes)
                for level_nodes in self.frontier_referenced_token_ids_by_level
            ],
            "frontier_position_ids_by_level": [
                list(level_nodes)
                for level_nodes in self.frontier_position_ids_by_level
            ],
            "frontier_referenced_position_ids_by_level": [
                list(level_nodes)
                for level_nodes in self.frontier_referenced_position_ids_by_level
            ],
            "frontier_branch_ids_by_level": [
                list(level_nodes) for level_nodes in self.frontier_branch_ids_by_level
            ],
            "frontier_level_ids_by_level": [
                list(level_nodes) for level_nodes in self.frontier_level_ids_by_level
            ],
        }

    @classmethod
    def from_dict(cls, data: dict) -> "NativeTreeRequest":
        return cls(
            valid=bool(data.get("valid", False)),
            req_id=int(data.get("req_id", 0)),
            prefix_slot_valid=int(data.get("prefix_slot_valid", 0)),
            committed_len=int(data.get("committed_len", 0)),
            draft_count=int(data.get("draft_count", 0)),
            branch_count=int(data.get("branch_count", 0)),
            prefix_node_ids=[
                int(node_id) for node_id in list(data.get("prefix_node_ids", []))
            ],
            prefix_token_ids=[
                int(token_id) for token_id in list(data.get("prefix_token_ids", []))
            ],
            prefix_position_ids=[
                int(position_id)
                for position_id in list(data.get("prefix_position_ids", []))
            ],
            frontier_level_valid=int(data.get("frontier_level_valid", 0)),
            frontier_slot_valid_by_level=[
                int(slot_valid)
                for slot_valid in list(data.get("frontier_slot_valid_by_level", []))
            ],
            frontier_tree_mask_en_by_level=[
                int(slot_valid)
                for slot_valid in list(
                    data.get("frontier_tree_mask_en_by_level", [])
                )
            ],
            frontier_node_ids_by_level=[
                [int(node_id) for node_id in list(level_nodes)]
                for level_nodes in list(data.get("frontier_node_ids_by_level", []))
            ],
            frontier_parent_node_ids_by_level=[
                [int(node_id) for node_id in list(level_nodes)]
                for level_nodes in list(
                    data.get("frontier_parent_node_ids_by_level", [])
                )
            ],
            frontier_token_ids_by_level=[
                [int(token_id) for token_id in list(level_nodes)]
                for level_nodes in list(data.get("frontier_token_ids_by_level", []))
            ],
            frontier_referenced_token_ids_by_level=[
                [int(token_id) for token_id in list(level_nodes)]
                for level_nodes in list(
                    data.get("frontier_referenced_token_ids_by_level", [])
                )
            ],
            frontier_position_ids_by_level=[
                [int(position_id) for position_id in list(level_nodes)]
                for level_nodes in list(
                    data.get("frontier_position_ids_by_level", [])
                )
            ],
            frontier_referenced_position_ids_by_level=[
                [int(position_id) for position_id in list(level_nodes)]
                for level_nodes in list(
                    data.get("frontier_referenced_position_ids_by_level", [])
                )
            ],
            frontier_branch_ids_by_level=[
                [int(branch_id) for branch_id in list(level_nodes)]
                for level_nodes in list(data.get("frontier_branch_ids_by_level", []))
            ],
            frontier_level_ids_by_level=[
                [int(level_id) for level_id in list(level_nodes)]
                for level_nodes in list(data.get("frontier_level_ids_by_level", []))
            ],
        )

    def normalized_prefix_node_ids(self) -> List[int]:
        padded = list(self.prefix_node_ids[:TREE_MAX_PREFIX_NODES])
        while len(padded) < TREE_MAX_PREFIX_NODES:
            padded.append(0)
        return padded

    def normalized_prefix_token_ids(self) -> List[int]:
        padded = list(self.prefix_token_ids[:TREE_MAX_PREFIX_NODES])
        while len(padded) < TREE_MAX_PREFIX_NODES:
            padded.append(0)
        return padded

    def normalized_prefix_position_ids(self) -> List[int]:
        padded = list(self.prefix_position_ids[:TREE_MAX_PREFIX_NODES])
        while len(padded) < TREE_MAX_PREFIX_NODES:
            padded.append(0)
        return padded

    def normalized_frontier_slot_valid_by_level(self) -> List[int]:
        padded = list(self.frontier_slot_valid_by_level[:TREE_MAX_FRONTIER_LEVELS])
        while len(padded) < TREE_MAX_FRONTIER_LEVELS:
            padded.append(0)
        return padded

    def normalized_frontier_tree_mask_en_by_level(self) -> List[int]:
        padded = list(
            self.frontier_tree_mask_en_by_level[:TREE_MAX_FRONTIER_LEVELS]
        )
        while len(padded) < TREE_MAX_FRONTIER_LEVELS:
            padded.append(0)
        return padded

    def _normalize_node_matrix(self, raw: List[List[int]]) -> List[List[int]]:
        padded_levels = []
        for level_nodes in list(raw[:TREE_MAX_FRONTIER_LEVELS]):
            padded_slots = list(level_nodes[:TREE_FRONTIER_SLOTS])
            while len(padded_slots) < TREE_FRONTIER_SLOTS:
                padded_slots.append(0)
            padded_levels.append(padded_slots)
        while len(padded_levels) < TREE_MAX_FRONTIER_LEVELS:
            padded_levels.append([0] * TREE_FRONTIER_SLOTS)
        return padded_levels

    def normalized_frontier_node_ids_by_level(self) -> List[List[int]]:
        return self._normalize_node_matrix(self.frontier_node_ids_by_level)

    def normalized_frontier_parent_node_ids_by_level(self) -> List[List[int]]:
        return self._normalize_node_matrix(self.frontier_parent_node_ids_by_level)

    def normalized_frontier_token_ids_by_level(self) -> List[List[int]]:
        return self._normalize_node_matrix(self.frontier_token_ids_by_level)

    def normalized_frontier_referenced_token_ids_by_level(self) -> List[List[int]]:
        return self._normalize_node_matrix(
            self.frontier_referenced_token_ids_by_level
        )

    def normalized_frontier_position_ids_by_level(self) -> List[List[int]]:
        return self._normalize_node_matrix(self.frontier_position_ids_by_level)

    def normalized_frontier_referenced_position_ids_by_level(self) -> List[List[int]]:
        return self._normalize_node_matrix(
            self.frontier_referenced_position_ids_by_level
        )

    def normalized_frontier_branch_ids_by_level(self) -> List[List[int]]:
        return self._normalize_node_matrix(self.frontier_branch_ids_by_level)

    def normalized_frontier_level_ids_by_level(self) -> List[List[int]]:
        return self._normalize_node_matrix(self.frontier_level_ids_by_level)


@dataclass
class StimulusCycle:
    cfg_valid: bool = False
    cfg_data: int = 0
    start: bool = False
    draft_candidates: List[DraftCandidate] = field(default_factory=list)
    tree_window_ready: bool = False
    recompute_req_ready: bool = False
    recompute_response: RecomputeResponse = field(default_factory=RecomputeResponse)
    wb_ready: bool = False
    hbm_response: HbmResponse = field(default_factory=HbmResponse)
    native_tree_request: NativeTreeRequest = field(default_factory=NativeTreeRequest)
    visible_mask: int = 0

    STIMULUS_BITS = (
        1 + CFG_W + 1 + 1 + 1 + 1 +
        DRAFT_PORTS * (1 + NODE_ID_W + TOKEN_ID_W + TOKEN_ID_W + POSITION_ID_W + CONF_W) +
        (1 + 1 + 1 + REQ_ID_W + SRAM_WDATA_W + 1) +
        (1 + REQ_ID_W + HBM_DATA_W) +
        (
            1 + REQ_ID_W + TREE_MAX_PREFIX_NODES + POSITION_ID_W + 5 + (BRANCH_ID_W + 1) +
            (TREE_MAX_PREFIX_NODES * NODE_ID_W) +
            (TREE_MAX_PREFIX_NODES * TOKEN_ID_W) +
            (TREE_MAX_PREFIX_NODES * POSITION_ID_W) +
            TREE_MAX_FRONTIER_LEVELS +
            (TREE_MAX_FRONTIER_LEVELS * TREE_FRONTIER_SLOTS) +
            (TREE_MAX_FRONTIER_LEVELS * TREE_FRONTIER_SLOTS) +
            (TREE_MAX_FRONTIER_LEVELS * TREE_FRONTIER_SLOTS * NODE_ID_W) +
            (TREE_MAX_FRONTIER_LEVELS * TREE_FRONTIER_SLOTS * NODE_ID_W) +
            (TREE_MAX_FRONTIER_LEVELS * TREE_FRONTIER_SLOTS * TOKEN_ID_W) +
            (TREE_MAX_FRONTIER_LEVELS * TREE_FRONTIER_SLOTS * TOKEN_ID_W) +
            (TREE_MAX_FRONTIER_LEVELS * TREE_FRONTIER_SLOTS * POSITION_ID_W) +
            (TREE_MAX_FRONTIER_LEVELS * TREE_FRONTIER_SLOTS * POSITION_ID_W) +
            (TREE_MAX_FRONTIER_LEVELS * TREE_FRONTIER_SLOTS * BRANCH_ID_W) +
            (TREE_MAX_FRONTIER_LEVELS * TREE_FRONTIER_SLOTS * TREE_LEVEL_ID_W)
        ) +
        VISIBLE_MASK_W
    )

    def _normalized_candidates(self) -> List[DraftCandidate]:
        padded = list(self.draft_candidates[:DRAFT_PORTS])
        while len(padded) < DRAFT_PORTS:
            padded.append(DraftCandidate())
        return padded

    def to_memh_word(self) -> str:
        payload = 0
        offset = 0

        def push(value: int, width: int) -> None:
            nonlocal payload, offset
            payload |= (value & _mask(width)) << offset
            offset += width

        push(_bool_bit(self.cfg_valid), 1)
        push(self.cfg_data, CFG_W)
        push(_bool_bit(self.start), 1)
        push(_bool_bit(self.tree_window_ready), 1)
        push(_bool_bit(self.recompute_req_ready), 1)
        push(_bool_bit(self.wb_ready), 1)

        candidates = self._normalized_candidates()
        for candidate in candidates:
            push(_bool_bit(candidate.valid), 1)
        for candidate in candidates:
            push(candidate.parent_node_id, NODE_ID_W)
        for candidate in candidates:
            push(candidate.token_id, TOKEN_ID_W)
        for candidate in candidates:
            push(candidate.referenced_token_id, TOKEN_ID_W)
        for candidate in candidates:
            push(candidate.referenced_position, POSITION_ID_W)
        for candidate in candidates:
            push(candidate.confidence, CONF_W)

        push(_bool_bit(self.recompute_response.valid), 1)
        push(_bool_bit(self.recompute_response.partial), 1)
        push(_bool_bit(self.recompute_response.full), 1)
        push(self.recompute_response.req_id, REQ_ID_W)
        push(int(self.recompute_response.kv_data_hex, 16), SRAM_WDATA_W)
        push(_bool_bit(self.recompute_response.last), 1)

        push(_bool_bit(self.hbm_response.valid), 1)
        push(self.hbm_response.req_id, REQ_ID_W)
        push(int(self.hbm_response.data_hex, 16), HBM_DATA_W)

        push(_bool_bit(self.native_tree_request.valid), 1)
        push(self.native_tree_request.req_id, REQ_ID_W)
        push(self.native_tree_request.prefix_slot_valid, TREE_MAX_PREFIX_NODES)
        push(self.native_tree_request.committed_len, POSITION_ID_W)
        push(self.native_tree_request.draft_count, 5)
        push(self.native_tree_request.branch_count, BRANCH_ID_W + 1)
        for node_id in self.native_tree_request.normalized_prefix_node_ids():
            push(node_id, NODE_ID_W)
        for token_id in self.native_tree_request.normalized_prefix_token_ids():
            push(token_id, TOKEN_ID_W)
        for position_id in self.native_tree_request.normalized_prefix_position_ids():
            push(position_id, POSITION_ID_W)
        push(
            self.native_tree_request.frontier_level_valid,
            TREE_MAX_FRONTIER_LEVELS,
        )
        for slot_valid in (
            self.native_tree_request.normalized_frontier_slot_valid_by_level()
        ):
            push(slot_valid, TREE_FRONTIER_SLOTS)
        for slot_valid in (
            self.native_tree_request.normalized_frontier_tree_mask_en_by_level()
        ):
            push(slot_valid, TREE_FRONTIER_SLOTS)
        for level_nodes in (
            self.native_tree_request.normalized_frontier_node_ids_by_level()
        ):
            for node_id in level_nodes:
                push(node_id, NODE_ID_W)
        for level_nodes in (
            self.native_tree_request.normalized_frontier_parent_node_ids_by_level()
        ):
            for node_id in level_nodes:
                push(node_id, NODE_ID_W)
        for level_nodes in (
            self.native_tree_request.normalized_frontier_token_ids_by_level()
        ):
            for token_id in level_nodes:
                push(token_id, TOKEN_ID_W)
        for level_nodes in (
            self.native_tree_request.normalized_frontier_referenced_token_ids_by_level()
        ):
            for token_id in level_nodes:
                push(token_id, TOKEN_ID_W)
        for level_nodes in (
            self.native_tree_request.normalized_frontier_position_ids_by_level()
        ):
            for position_id in level_nodes:
                push(position_id, POSITION_ID_W)
        for level_nodes in (
            self.native_tree_request.normalized_frontier_referenced_position_ids_by_level()
        ):
            for position_id in level_nodes:
                push(position_id, POSITION_ID_W)
        for level_nodes in (
            self.native_tree_request.normalized_frontier_branch_ids_by_level()
        ):
            for branch_id in level_nodes:
                push(branch_id, BRANCH_ID_W)
        for level_nodes in (
            self.native_tree_request.normalized_frontier_level_ids_by_level()
        ):
            for level_id in level_nodes:
                push(level_id, TREE_LEVEL_ID_W)
        push(_coerce_visible_mask(self.visible_mask), VISIBLE_MASK_W)

        if offset != self.STIMULUS_BITS:
            raise RuntimeError(f"stimulus width mismatch: packed {offset} bits")
        return f"{payload:0{(self.STIMULUS_BITS + 3) // 4}x}"

    @classmethod
    def from_memh_word(cls, word: str) -> "StimulusCycle":
        payload = int(word, 16)
        offset = 0

        def pull(width: int) -> int:
            nonlocal payload, offset
            value = (payload >> offset) & _mask(width)
            offset += width
            return value

        cfg_valid = bool(pull(1))
        cfg_data = pull(CFG_W)
        start = bool(pull(1))
        tree_window_ready = bool(pull(1))
        recompute_req_ready = bool(pull(1))
        wb_ready = bool(pull(1))

        draft_valids = [bool(pull(1)) for _ in range(DRAFT_PORTS)]
        draft_parents = [pull(NODE_ID_W) for _ in range(DRAFT_PORTS)]
        draft_tokens = [pull(TOKEN_ID_W) for _ in range(DRAFT_PORTS)]
        draft_ref_tokens = [pull(TOKEN_ID_W) for _ in range(DRAFT_PORTS)]
        draft_ref_positions = [pull(POSITION_ID_W) for _ in range(DRAFT_PORTS)]
        draft_confidences = [pull(CONF_W) for _ in range(DRAFT_PORTS)]

        candidates = [
            DraftCandidate(
                valid=draft_valids[index],
                parent_node_id=draft_parents[index],
                token_id=draft_tokens[index],
                referenced_token_id=draft_ref_tokens[index],
                referenced_position=draft_ref_positions[index],
                confidence=draft_confidences[index],
            )
            for index in range(DRAFT_PORTS)
        ]

        recompute_response = RecomputeResponse(
            valid=bool(pull(1)),
            partial=bool(pull(1)),
            full=bool(pull(1)),
            req_id=pull(REQ_ID_W),
            kv_data_hex=f"{pull(SRAM_WDATA_W):0{SRAM_WDATA_W // 4}x}",
            last=bool(pull(1)),
        )

        hbm_response = HbmResponse(
            valid=bool(pull(1)),
            req_id=pull(REQ_ID_W),
            data_hex=f"{pull(HBM_DATA_W):0{HBM_DATA_W // 4}x}",
        )

        native_tree_request = NativeTreeRequest(
            valid=bool(pull(1)),
            req_id=pull(REQ_ID_W),
            prefix_slot_valid=pull(TREE_MAX_PREFIX_NODES),
            committed_len=pull(POSITION_ID_W),
            draft_count=pull(5),
            branch_count=pull(BRANCH_ID_W + 1),
            prefix_node_ids=[pull(NODE_ID_W) for _ in range(TREE_MAX_PREFIX_NODES)],
            prefix_token_ids=[pull(TOKEN_ID_W) for _ in range(TREE_MAX_PREFIX_NODES)],
            prefix_position_ids=[
                pull(POSITION_ID_W) for _ in range(TREE_MAX_PREFIX_NODES)
            ],
            frontier_level_valid=pull(TREE_MAX_FRONTIER_LEVELS),
            frontier_slot_valid_by_level=[
                pull(TREE_FRONTIER_SLOTS)
                for _ in range(TREE_MAX_FRONTIER_LEVELS)
            ],
            frontier_tree_mask_en_by_level=[
                pull(TREE_FRONTIER_SLOTS)
                for _ in range(TREE_MAX_FRONTIER_LEVELS)
            ],
            frontier_node_ids_by_level=[
                [pull(NODE_ID_W) for _ in range(TREE_FRONTIER_SLOTS)]
                for _ in range(TREE_MAX_FRONTIER_LEVELS)
            ],
            frontier_parent_node_ids_by_level=[
                [pull(NODE_ID_W) for _ in range(TREE_FRONTIER_SLOTS)]
                for _ in range(TREE_MAX_FRONTIER_LEVELS)
            ],
            frontier_token_ids_by_level=[
                [pull(TOKEN_ID_W) for _ in range(TREE_FRONTIER_SLOTS)]
                for _ in range(TREE_MAX_FRONTIER_LEVELS)
            ],
            frontier_referenced_token_ids_by_level=[
                [pull(TOKEN_ID_W) for _ in range(TREE_FRONTIER_SLOTS)]
                for _ in range(TREE_MAX_FRONTIER_LEVELS)
            ],
            frontier_position_ids_by_level=[
                [pull(POSITION_ID_W) for _ in range(TREE_FRONTIER_SLOTS)]
                for _ in range(TREE_MAX_FRONTIER_LEVELS)
            ],
            frontier_referenced_position_ids_by_level=[
                [pull(POSITION_ID_W) for _ in range(TREE_FRONTIER_SLOTS)]
                for _ in range(TREE_MAX_FRONTIER_LEVELS)
            ],
            frontier_branch_ids_by_level=[
                [pull(BRANCH_ID_W) for _ in range(TREE_FRONTIER_SLOTS)]
                for _ in range(TREE_MAX_FRONTIER_LEVELS)
            ],
            frontier_level_ids_by_level=[
                [pull(TREE_LEVEL_ID_W) for _ in range(TREE_FRONTIER_SLOTS)]
                for _ in range(TREE_MAX_FRONTIER_LEVELS)
            ],
        )
        visible_mask = pull(VISIBLE_MASK_W)

        if offset != cls.STIMULUS_BITS:
            raise RuntimeError(f"stimulus width mismatch: unpacked {offset} bits")

        return cls(
            cfg_valid=cfg_valid,
            cfg_data=cfg_data,
            start=start,
            draft_candidates=candidates,
            tree_window_ready=tree_window_ready,
            recompute_req_ready=recompute_req_ready,
            recompute_response=recompute_response,
            wb_ready=wb_ready,
            hbm_response=hbm_response,
            native_tree_request=native_tree_request,
            visible_mask=visible_mask,
        )


@dataclass
class TreeVerifyBatchRequest:
    """Represents a batch tree-attention verify request with W slots."""

    slot_count: int = 0
    slot_token_ids: List[int] = field(default_factory=list)
    slot_positions: List[int] = field(default_factory=list)
    tree_mask: List[List[bool]] = field(default_factory=list)
    prefix_len: int = 0
    seed_kv_valid: bool = False
    slot_is_seed: List[bool] = field(default_factory=list)
    branch_slot_map: List[List[int]] = field(default_factory=list)
    slot_parent_slot: List[int] = field(default_factory=list)

    def to_dict(self) -> dict:
        return {
            "slot_count": self.slot_count,
            "slot_token_ids": list(self.slot_token_ids),
            "slot_positions": list(self.slot_positions),
            "tree_mask": [list(row) for row in self.tree_mask],
            "prefix_len": self.prefix_len,
            "seed_kv_valid": self.seed_kv_valid,
            "slot_is_seed": list(self.slot_is_seed),
            "branch_slot_map": [list(branch) for branch in self.branch_slot_map],
            "slot_parent_slot": list(self.slot_parent_slot),
        }


def build_tree_mask_from_parents(
    slot_parent_slot: List[int], slot_count: int
) -> List[List[bool]]:
    """Generate a W x W tree-mask visibility matrix by walking parent chains.

    For each slot i, the mask row i has True at column j if slot j is an
    ancestor of slot i (including slot i itself).  The matrix is sized
    VERIFY_WINDOW_SIZE x VERIFY_WINDOW_SIZE and padded with False for
    unused slots.
    """
    w = VERIFY_WINDOW_SIZE
    mask = [[False] * w for _ in range(w)]
    for slot_idx in range(slot_count):
        # Each slot can see itself
        mask[slot_idx][slot_idx] = True
        # Walk up the parent chain
        cursor = slot_idx
        visited = set()
        visited.add(cursor)
        while True:
            parent = slot_parent_slot[cursor]
            if parent == cursor:
                # Root points to itself; stop
                break
            if parent in visited:
                # Avoid infinite loops on malformed input
                break
            if parent < 0 or parent >= slot_count:
                break
            visited.add(parent)
            mask[slot_idx][parent] = True
            cursor = parent
    return mask


def write_stimulus_bundle(output_dir: Path, cycles: List[StimulusCycle]) -> Path:
    output_dir.mkdir(parents=True, exist_ok=True)
    memh_path = output_dir / "stimulus.memh"
    manifest_path = output_dir / "manifest.json"
    memh_lines = [cycle.to_memh_word() for cycle in cycles]
    memh_path.write_text(
        ("\n".join(memh_lines) + ("\n" if memh_lines else "")),
        encoding="utf-8",
    )
    manifest_path.write_text(
        json.dumps(
            {
                "format": "stage2_single_chiplet_stimulus",
                "version": 2,
                "stimulus_bits": StimulusCycle.STIMULUS_BITS,
                "num_cycles": len(cycles),
            },
            ensure_ascii=False,
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    return memh_path
