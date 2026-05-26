import argparse
import json
import math
import os
import struct
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence, Tuple, Union

import numpy as np


REPO_ROOT = Path(__file__).resolve().parents[3]
if str(REPO_ROOT / "code" / "script") not in sys.path:
    sys.path.insert(0, str(REPO_ROOT / "code" / "script"))

from rtl_backend.formats import fp16_to_hex  # noqa: E402

# =========================================================================
# Profile selection: MODEL_PROFILE env var or --profile CLI arg
# =========================================================================
_PROFILE = os.environ.get("MODEL_PROFILE", "toy").lower()

# Fixed hardware constants
DATA_WIDTH = 16
SRAM_DATA_BUS_W = 128
HBM_DATA_BUS_W = 256
FP16_TILE_LANES = 16
FP16_TILE_COLS = 128
ELEMS_PER_SRAM_BEAT = SRAM_DATA_BUS_W // DATA_WIDTH  # 8
ELEMS_PER_HBM_BEAT = HBM_DATA_BUS_W // DATA_WIDTH    # 16
WEIGHT_BEATS_PER_TILE = (FP16_TILE_LANES * FP16_TILE_COLS) // ELEMS_PER_SRAM_BEAT  # 256
HBM_TO_SRAM_RATIO = HBM_DATA_BUS_W // SRAM_DATA_BUS_W  # 2

# Profile-dependent model parameters
if _PROFILE == "qwen3":
    HIDDEN_DIM = 1024
    NUM_HEADS = 16
    HEAD_DIM = 64
    INTERMEDIATE_DIM = 3072
    N_LAYERS = 2
    VOCAB_SIZE = 1024
    MAX_SEQ_LEN = 32
    ROPE_THETA = 1_000_000.0
    # Address layout matching model_params.vh for Qwen3
    EMB_BASE = 256
    FINAL_GAMMA_BASE = 131584
    LM_HEAD_BASE = 140000
    HBM_WEIGHT_BASE = 1024
else:  # toy (default)
    HIDDEN_DIM = 128
    NUM_HEADS = 2
    HEAD_DIM = 64
    INTERMEDIATE_DIM = 256
    N_LAYERS = 2
    VOCAB_SIZE = 16
    MAX_SEQ_LEN = 8
    ROPE_THETA = 1_000_000.0
    # Address layout matching toy model
    EMB_BASE = 256
    FINAL_GAMMA_BASE = 2048
    LM_HEAD_BASE = 49664
    HBM_WEIGHT_BASE = 1024

# Derived constants (computed from profile parameters)
HIDDEN_BEATS = HIDDEN_DIM // ELEMS_PER_SRAM_BEAT
INTERMEDIATE_BEATS = INTERMEDIATE_DIM // ELEMS_PER_SRAM_BEAT
PROJ_MATRIX_BEATS = (
    ((HIDDEN_DIM + FP16_TILE_LANES - 1) // FP16_TILE_LANES)
    * ((HIDDEN_DIM + FP16_TILE_COLS - 1) // FP16_TILE_COLS)
    * WEIGHT_BEATS_PER_TILE
)
FFN_EXPAND_MATRIX_BEATS = (
    ((INTERMEDIATE_DIM + FP16_TILE_LANES - 1) // FP16_TILE_LANES)
    * ((HIDDEN_DIM + FP16_TILE_COLS - 1) // FP16_TILE_COLS)
    * WEIGHT_BEATS_PER_TILE
)
FFN_DOWN_MATRIX_BEATS = (
    ((HIDDEN_DIM + FP16_TILE_LANES - 1) // FP16_TILE_LANES)
    * ((INTERMEDIATE_DIM + FP16_TILE_COLS - 1) // FP16_TILE_COLS)
    * WEIGHT_BEATS_PER_TILE
)
WEIGHT_WINDOW_BEATS = 8 * max(PROJ_MATRIX_BEATS, FFN_EXPAND_MATRIX_BEATS, FFN_DOWN_MATRIX_BEATS)
LAYER_WEIGHT_STRIDE = ((2 * HIDDEN_BEATS) + WEIGHT_WINDOW_BEATS) // HBM_TO_SRAM_RATIO

OUTPUT_DIR_DEFAULT = REPO_ROOT / "code" / "sim" / "generated"
EPS = 1e-6
RMS_DIVISOR_RTL = 1024.0


def to_fp16(value: Union[np.ndarray, float]) -> Union[np.ndarray, np.float16]:
    return np.asarray(value, dtype=np.float16)


def fp16_hex_word(value: float) -> str:
    return fp16_to_hex(float(np.float16(value)))


def pack_sram_beat(values: Sequence[float]) -> str:
    vals = list(values)
    if len(vals) != ELEMS_PER_SRAM_BEAT:
        raise ValueError("SRAM beat width mismatch")
    return "".join(fp16_hex_word(v) for v in reversed(vals))


def pack_hbm_beat(values: Sequence[float]) -> str:
    vals = list(values)
    if len(vals) != ELEMS_PER_HBM_BEAT:
        raise ValueError("HBM beat width mismatch")
    return "".join(fp16_hex_word(v) for v in reversed(vals))


def unpack_memh_line_to_fp16(line: str, elems: int) -> np.ndarray:
    raw = line.strip()
    words = [raw[i : i + 4] for i in range(0, len(raw), 4)]
    words = list(reversed(words))
    if len(words) < elems:
        words.extend(["0000"] * (elems - len(words)))
    return np.asarray(
        [struct.unpack(">e", bytes.fromhex(word))[0] for word in words[:elems]],
        dtype=np.float16,
    )


def silu(x: np.ndarray) -> np.ndarray:
    x32 = x.astype(np.float32)
    return (x32 / (1.0 + np.exp(-x32))).astype(np.float16)


def rmsnorm_rtl_style(x: np.ndarray, gamma: np.ndarray) -> np.ndarray:
    x32 = x.astype(np.float32)
    gamma32 = gamma.astype(np.float32)
    mean_sq = np.sum(np.square(x32), dtype=np.float32) / RMS_DIVISOR_RTL
    inv_rms = 1.0 / np.sqrt(mean_sq + np.float32(EPS))
    return (x32 * inv_rms * gamma32).astype(np.float16)


def rope_rotate(vec: np.ndarray, position: int) -> np.ndarray:
    out = vec.astype(np.float32).copy()
    pair_count = HEAD_DIM // 2
    for pair_idx in range(pair_count):
        freq = 1.0 / (ROPE_THETA ** (2.0 * pair_idx / HEAD_DIM))
        angle = position * freq
        c = math.cos(angle)
        s = math.sin(angle)
        base = pair_idx * 2
        x0 = float(out[base])
        x1 = float(out[base + 1])
        out[base] = x0 * c - x1 * s
        out[base + 1] = x0 * s + x1 * c
    return out.astype(np.float16)


def tiled_matvec(weight: np.ndarray, vector: np.ndarray) -> np.ndarray:
    """Matrix-vector multiply matching RTL's FP16 sequential MAC behavior.

    RTL MAC: for each output group of 8 lanes, sequentially accumulate
    weight[lane, col] * vector[col] in FP16 for all cols.
    Each cycle: accum[lane] = fp16_add(fp16_mul(weight[lane,col], vector[col]), accum[lane])
    """
    rows, cols = weight.shape
    out = np.zeros((rows,), dtype=np.float16)
    w_fp16 = weight.astype(np.float16)
    v_fp16 = vector.astype(np.float16)
    # Process per output group of BEAT_ELEMS (8 lanes), matching RTL
    beat_elems = ELEMS_PER_SRAM_BEAT  # 8
    num_groups = (rows + beat_elems - 1) // beat_elems
    for grp in range(num_groups):
        lane_base = grp * beat_elems
        span = min(beat_elems, rows - lane_base)
        accum = np.zeros((span,), dtype=np.float16)
        for c in range(cols):
            # FP16 multiply (numpy does this natively for float16 arrays)
            prod = w_fp16[lane_base:lane_base+span, c] * v_fp16[c]
            # FP16 accumulate (numpy float16 addition)
            accum = accum + prod
        out[lane_base:lane_base+span] = accum
    return out


def build_weights() -> Dict[str, Any]:
    rng = np.random.default_rng(42)
    embed = (rng.standard_normal((VOCAB_SIZE, HIDDEN_DIM), dtype=np.float32) * 0.125).astype(np.float16)
    final_gamma = np.ones((HIDDEN_DIM,), dtype=np.float16)
    layers: List[Dict[str, np.ndarray]] = []
    for layer_idx in range(N_LAYERS):
        # Scale weights by 1/sqrt(dim) to keep activations in a reasonable range
        # For d=1024: scale ~ 0.031; for d=128: scale ~ 0.088
        base_scale = np.float32(1.0 / math.sqrt(HIDDEN_DIM))
        scale = base_scale * np.float32(1.0 + 0.1 * layer_idx)
        ffn_scale = np.float32(1.0 / math.sqrt(INTERMEDIATE_DIM))
        layer = {
            "pre_gamma": np.ones((HIDDEN_DIM,), dtype=np.float16),
            "post_gamma": np.ones((HIDDEN_DIM,), dtype=np.float16),
            "wq": (rng.standard_normal((HIDDEN_DIM, HIDDEN_DIM), dtype=np.float32) * scale).astype(np.float16),
            "wk": (rng.standard_normal((HIDDEN_DIM, HIDDEN_DIM), dtype=np.float32) * scale).astype(np.float16),
            "wv": (rng.standard_normal((HIDDEN_DIM, HIDDEN_DIM), dtype=np.float32) * scale).astype(np.float16),
            "wo": (rng.standard_normal((HIDDEN_DIM, HIDDEN_DIM), dtype=np.float32) * scale).astype(np.float16),
            "gate": (rng.standard_normal((INTERMEDIATE_DIM, HIDDEN_DIM), dtype=np.float32) * scale).astype(np.float16),
            "up": (rng.standard_normal((INTERMEDIATE_DIM, HIDDEN_DIM), dtype=np.float32) * scale).astype(np.float16),
            "down": (rng.standard_normal((HIDDEN_DIM, INTERMEDIATE_DIM), dtype=np.float32) * ffn_scale).astype(np.float16),
        }
        layers.append(layer)
    return {
        "embedding": embed,
        "final_gamma": final_gamma,
        "layers": layers,
    }


def _normalize_visible_positions(
    position: int,
    visible_mask: Optional[np.ndarray],
) -> List[int]:
    if visible_mask is None:
        return list(range(position + 1))
    if int(position) >= len(visible_mask):
        raise ValueError("visible_mask is shorter than position")
    indices = np.where(np.asarray(visible_mask, dtype=np.uint8) != 0)[0]
    return [int(index) for index in indices if int(index) <= int(position)]


def _run_reference_impl(
    weights: Dict[str, Any],
    token_id: int,
    position: int,
    kv_cache_k: Optional[np.ndarray] = None,
    kv_cache_v: Optional[np.ndarray] = None,
    visible_mask: Optional[np.ndarray] = None,
) -> Tuple[Dict[str, Any], np.ndarray, np.ndarray]:
    embed = weights["embedding"]  # type: ignore[assignment]
    final_gamma = weights["final_gamma"]  # type: ignore[assignment]
    layers: Sequence[Dict[str, np.ndarray]] = weights["layers"]  # type: ignore[assignment]
    hidden = np.array(embed[token_id], dtype=np.float16)
    if kv_cache_k is None:
        kv_cache_k = np.zeros((N_LAYERS, MAX_SEQ_LEN, NUM_HEADS, HEAD_DIM), dtype=np.float16)
    if kv_cache_v is None:
        kv_cache_v = np.zeros((N_LAYERS, MAX_SEQ_LEN, NUM_HEADS, HEAD_DIM), dtype=np.float16)
    dumps: Dict[str, Any] = {}
    visible_positions = _normalize_visible_positions(position, visible_mask)

    for layer_idx, layer in enumerate(layers):
        pre = rmsnorm_rtl_style(hidden, layer["pre_gamma"])
        q = tiled_matvec(layer["wq"], pre)
        k = tiled_matvec(layer["wk"], pre)
        v = tiled_matvec(layer["wv"], pre)

        attn_heads = []
        for head_idx in range(NUM_HEADS):
            hs = head_idx * HEAD_DIM
            he = hs + HEAD_DIM
            q_head = rope_rotate(q[hs:he], position)
            k_head = rope_rotate(k[hs:he], position)
            v_head = np.array(v[hs:he], dtype=np.float16)
            kv_cache_k[layer_idx, position, head_idx, :] = k_head
            kv_cache_v[layer_idx, position, head_idx, :] = v_head
            scores = []
            for hist_pos in visible_positions:
                score = np.dot(
                    q_head.astype(np.float32),
                    kv_cache_k[layer_idx, hist_pos, head_idx].astype(np.float32),
                ) / math.sqrt(float(HEAD_DIM))
                scores.append(score)
            scores_np = np.asarray(scores, dtype=np.float32)
            scores_np -= np.max(scores_np)
            probs = np.exp(scores_np)
            probs = probs / np.sum(probs)
            head_out = np.zeros((HEAD_DIM,), dtype=np.float32)
            for score_idx, hist_pos in enumerate(visible_positions):
                head_out += probs[score_idx] * kv_cache_v[layer_idx, hist_pos, head_idx].astype(np.float32)
            attn_heads.append(head_out.astype(np.float16))

        attn_cat = np.concatenate(attn_heads, axis=0).astype(np.float16)
        attn_proj = tiled_matvec(layer["wo"], attn_cat)
        hidden = (hidden.astype(np.float32) + attn_proj.astype(np.float32)).astype(np.float16)

        post = rmsnorm_rtl_style(hidden, layer["post_gamma"])
        gate = tiled_matvec(layer["gate"], post)
        up = tiled_matvec(layer["up"], post)
        ffn = tiled_matvec(layer["down"], (silu(gate).astype(np.float32) * up.astype(np.float32)).astype(np.float16))
        hidden = (hidden.astype(np.float32) + ffn.astype(np.float32)).astype(np.float16)
        dumps[f"hidden_after_layer{layer_idx}"] = hidden.copy()

    final_hidden = rmsnorm_rtl_style(hidden, final_gamma)
    logits = tiled_matvec(weights["embedding"], final_hidden)  # type: ignore[arg-type]
    token_out = int(np.argmax(logits.astype(np.float32)))
    dumps["final_hidden"] = final_hidden
    dumps["logits"] = logits
    dumps["token_id"] = token_out
    dumps["visible_positions"] = visible_positions
    return dumps, kv_cache_k, kv_cache_v


def build_visible_masks(
    tree_descriptor: Dict[str, Any],
    committed_len: int,
    visible_mask_len: int,
) -> Dict[int, np.ndarray]:
    draft_parent = {
        int(node_id): int(parent_id)
        for node_id, parent_id in dict(tree_descriptor.get("draft_parent", {})).items()
    }
    draft_position = {
        int(node_id): int(position_id)
        for node_id, position_id in dict(tree_descriptor.get("draft_position", {})).items()
    }
    query_node_ids = [int(node_id) for node_id in list(tree_descriptor.get("query_node_ids", []))]
    if not query_node_ids:
        query_node_ids = sorted(draft_parent)

    masks: Dict[int, np.ndarray] = {}
    for query_node_id in query_node_ids:
        mask = np.zeros((visible_mask_len,), dtype=np.uint8)
        mask[: max(int(committed_len), 0)] = 1
        cursor = int(query_node_id)
        visited = set()
        while cursor not in visited and cursor in draft_parent:
            visited.add(cursor)
            position = draft_position.get(cursor, cursor - 1)
            if 0 <= position < visible_mask_len:
                mask[position] = 1
            cursor = int(draft_parent.get(cursor, 0))
        masks[int(query_node_id)] = mask
    return masks


def run_reference(
    weights: Dict[str, Any],
    token_id: int = 0,
    position: int = 0,
    kv_cache_k: Optional[np.ndarray] = None,
    kv_cache_v: Optional[np.ndarray] = None,
) -> Tuple[Dict[str, Any], np.ndarray, np.ndarray]:
    return _run_reference_impl(
        weights=weights,
        token_id=token_id,
        position=position,
        kv_cache_k=kv_cache_k,
        kv_cache_v=kv_cache_v,
        visible_mask=None,
    )


def run_tree_masked_reference(
    weights: Dict[str, Any],
    token_ids: Sequence[int],
    positions: Sequence[int],
    kv_cache_k: np.ndarray,
    kv_cache_v: np.ndarray,
    visible_masks: Sequence[np.ndarray],
) -> Tuple[Dict[str, Any], np.ndarray, np.ndarray]:
    if not (
        len(token_ids) == len(positions) == len(visible_masks)
    ):
        raise ValueError("token_ids, positions and visible_masks must have the same length")

    kv_cache_k_work = np.array(kv_cache_k, copy=True)
    kv_cache_v_work = np.array(kv_cache_v, copy=True)
    final_hiddens: List[np.ndarray] = []
    logits_list: List[np.ndarray] = []
    token_out_ids: List[int] = []
    dumps_list: List[Dict[str, Any]] = []

    for token_id, position, visible_mask in zip(token_ids, positions, visible_masks):
        dumps, kv_cache_k_work, kv_cache_v_work = _run_reference_impl(
            weights=weights,
            token_id=int(token_id),
            position=int(position),
            kv_cache_k=kv_cache_k_work,
            kv_cache_v=kv_cache_v_work,
            visible_mask=np.asarray(visible_mask, dtype=np.uint8),
        )
        final_hiddens.append(np.array(dumps["final_hidden"], copy=True))
        logits_list.append(np.array(dumps["logits"], copy=True))
        token_out_ids.append(int(dumps["token_id"]))
        dumps_list.append(dumps)

    return (
        {
            "final_hiddens": final_hiddens,
            "logits": logits_list,
            "token_ids": token_out_ids,
            "dumps": dumps_list,
        },
        kv_cache_k_work,
        kv_cache_v_work,
    )


def run_autoregressive(
    weights: Dict[str, Any],
    bos_token_id: int = 0,
    num_steps: int = 4,
) -> Dict[str, Any]:
    if num_steps <= 0:
        raise ValueError("num_steps must be positive")
    if num_steps > MAX_SEQ_LEN:
        raise ValueError("num_steps exceeds MAX_SEQ_LEN")

    kv_cache_k = np.zeros((N_LAYERS, MAX_SEQ_LEN, NUM_HEADS, HEAD_DIM), dtype=np.float16)
    kv_cache_v = np.zeros((N_LAYERS, MAX_SEQ_LEN, NUM_HEADS, HEAD_DIM), dtype=np.float16)
    current_token = int(bos_token_id)
    token_sequence: List[int] = []
    step_results: List[Dict[str, Any]] = []

    for step_idx in range(num_steps):
        dumps, kv_cache_k, kv_cache_v = run_reference(
            weights,
            token_id=current_token,
            position=step_idx,
            kv_cache_k=kv_cache_k,
            kv_cache_v=kv_cache_v,
        )
        output_token = int(dumps["token_id"])
        token_sequence.append(output_token)
        step_results.append(
            {
                "step": step_idx,
                "input_token_id": current_token,
                "token_id": output_token,
                "dumps": dumps,
            }
        )
        current_token = output_token

    return {
        "steps": step_results,
        "token_sequence": token_sequence,
        "kv_cache_k": kv_cache_k,
        "kv_cache_v": kv_cache_v,
    }


def _write_sparse_memh(f, data: Dict[int, str]) -> None:
    """Write a sparse $readmemh file using @addr directives.

    Groups consecutive addresses to minimize @addr lines.
    """
    if not data:
        return
    sorted_addrs = sorted(data)
    prev_addr = sorted_addrs[0] - 2  # force first @addr
    for addr in sorted_addrs:
        if addr != prev_addr + 1:
            f.write("@%x\n" % addr)
        f.write("%s\n" % data[addr])
        prev_addr = addr


def emit_embedding_mem(weights: Dict[str, Any], out_dir: Path) -> None:
    embed: np.ndarray = weights["embedding"]  # type: ignore[assignment]
    final_gamma: np.ndarray = weights["final_gamma"]  # type: ignore[assignment]

    mem: Dict[int, str] = {}
    zero_beat = "00000000000000000000000000000000"

    for token_id in range(VOCAB_SIZE):
        for beat_idx in range(HIDDEN_BEATS):
            vals = embed[token_id, beat_idx * ELEMS_PER_SRAM_BEAT : (beat_idx + 1) * ELEMS_PER_SRAM_BEAT]
            packed = pack_sram_beat(vals)
            if packed != zero_beat:
                mem[EMB_BASE + token_id * HIDDEN_BEATS + beat_idx] = packed

    for beat_idx in range(HIDDEN_BEATS):
        vals = final_gamma[beat_idx * ELEMS_PER_SRAM_BEAT : (beat_idx + 1) * ELEMS_PER_SRAM_BEAT]
        packed = pack_sram_beat(vals)
        if packed != zero_beat:
            mem[FINAL_GAMMA_BASE + beat_idx] = packed

    lm_rows_total = (VOCAB_SIZE + FP16_TILE_LANES - 1) // FP16_TILE_LANES
    for tile_row in range(lm_rows_total):
        lane_base = tile_row * FP16_TILE_LANES
        for col_base in range(0, HIDDEN_DIM, FP16_TILE_COLS):
            tile = np.zeros((FP16_TILE_LANES, FP16_TILE_COLS), dtype=np.float16)
            span_rows = min(FP16_TILE_LANES, VOCAB_SIZE - lane_base)
            span_cols = min(FP16_TILE_COLS, HIDDEN_DIM - col_base)
            tile[:span_rows, :span_cols] = embed[lane_base : lane_base + span_rows, col_base : col_base + span_cols]
            flat = tile.T.reshape(-1)
            base_addr = LM_HEAD_BASE + (
                (tile_row * ((HIDDEN_DIM + FP16_TILE_COLS - 1) // FP16_TILE_COLS) + (col_base // FP16_TILE_COLS))
                * WEIGHT_BEATS_PER_TILE
            )
            for beat_idx in range(WEIGHT_BEATS_PER_TILE):
                vals = flat[beat_idx * ELEMS_PER_SRAM_BEAT : (beat_idx + 1) * ELEMS_PER_SRAM_BEAT]
                packed = pack_sram_beat(vals)
                if packed != zero_beat:
                    mem[base_addr + beat_idx] = packed

    # Write sparse memh with @addr directives (VCS-compatible)
    with open(out_dir / "sram_preload.memh", "w", encoding="ascii") as f:
        _write_sparse_memh(f, mem)


def matrix_to_weight_slot_beats(matrix: np.ndarray, slot_beats: int) -> List[str]:
    rows, cols = matrix.shape
    tile_rows_total = (rows + FP16_TILE_LANES - 1) // FP16_TILE_LANES
    tile_cols_total = (cols + FP16_TILE_COLS - 1) // FP16_TILE_COLS
    beats: List[str] = []
    for tile_row in range(tile_rows_total):
        lane_base = tile_row * FP16_TILE_LANES
        for tile_col in range(tile_cols_total):
            col_base = tile_col * FP16_TILE_COLS
            tile = np.zeros((FP16_TILE_LANES, FP16_TILE_COLS), dtype=np.float16)
            span_rows = min(FP16_TILE_LANES, rows - lane_base)
            span_cols = min(FP16_TILE_COLS, cols - col_base)
            tile[:span_rows, :span_cols] = matrix[lane_base : lane_base + span_rows, col_base : col_base + span_cols]
            flat = tile.T.reshape(-1)
            for beat_idx in range(WEIGHT_BEATS_PER_TILE):
                vals = flat[beat_idx * ELEMS_PER_SRAM_BEAT : (beat_idx + 1) * ELEMS_PER_SRAM_BEAT]
                beats.append(pack_sram_beat(vals))
    while len(beats) < slot_beats:
        beats.append("00000000000000000000000000000000")
    return beats[:slot_beats]


def vector_to_beats(vec: np.ndarray) -> List[str]:
    return [
        pack_sram_beat(vec[beat_idx * ELEMS_PER_SRAM_BEAT : (beat_idx + 1) * ELEMS_PER_SRAM_BEAT])
        for beat_idx in range(len(vec) // ELEMS_PER_SRAM_BEAT)
    ]


def emit_hbm_mem(weights: Dict[str, Any], out_dir: Path) -> None:
    layers: Sequence[Dict[str, np.ndarray]] = weights["layers"]  # type: ignore[assignment]
    hbm_lines: Dict[int, str] = {}
    zero_beat_hbm = "0" * 64
    for layer_idx, layer in enumerate(layers):
        sram_lines: List[str] = []
        sram_lines.extend(vector_to_beats(layer["pre_gamma"]))
        sram_lines.extend(vector_to_beats(layer["post_gamma"]))
        sram_lines.extend(matrix_to_weight_slot_beats(layer["wq"], WEIGHT_WINDOW_BEATS // 8))
        sram_lines.extend(matrix_to_weight_slot_beats(layer["wk"], WEIGHT_WINDOW_BEATS // 8))
        sram_lines.extend(matrix_to_weight_slot_beats(layer["wv"], WEIGHT_WINDOW_BEATS // 8))
        sram_lines.extend(matrix_to_weight_slot_beats(layer["wo"], WEIGHT_WINDOW_BEATS // 8))
        sram_lines.extend(matrix_to_weight_slot_beats(layer["gate"], WEIGHT_WINDOW_BEATS // 8))
        sram_lines.extend(matrix_to_weight_slot_beats(layer["up"], WEIGHT_WINDOW_BEATS // 8))
        sram_lines.extend(matrix_to_weight_slot_beats(layer["down"], WEIGHT_WINDOW_BEATS // 8))
        layer_base = HBM_WEIGHT_BASE + layer_idx * LAYER_WEIGHT_STRIDE
        for hbm_idx in range(0, len(sram_lines), HBM_TO_SRAM_RATIO):
            pair = sram_lines[hbm_idx : hbm_idx + HBM_TO_SRAM_RATIO]
            if len(pair) < HBM_TO_SRAM_RATIO:
                pair.extend(["00000000000000000000000000000000"] * (HBM_TO_SRAM_RATIO - len(pair)))
            lo_vals = unpack_memh_line_to_fp16(pair[0], ELEMS_PER_SRAM_BEAT)
            hi_vals = unpack_memh_line_to_fp16(pair[1], ELEMS_PER_SRAM_BEAT)
            beat_vals = np.concatenate([lo_vals, hi_vals]).astype(np.float16)
            packed = pack_hbm_beat(beat_vals)
            if packed != zero_beat_hbm:
                hbm_lines[layer_base + (hbm_idx // HBM_TO_SRAM_RATIO)] = packed

    # Write sparse memh with @addr directives (VCS-compatible)
    with open(out_dir / "hbm_weights.memh", "w", encoding="ascii") as f:
        _write_sparse_memh(f, hbm_lines)


def emit_reference_outputs(dumps: Dict[str, Any], out_dir: Path) -> None:
    for layer_idx in range(N_LAYERS):
        np.save(out_dir / f"ref_hidden_after_layer{layer_idx}.npy", dumps[f"hidden_after_layer{layer_idx}"])
    np.save(out_dir / "ref_final_hidden.npy", dumps["final_hidden"])
    np.save(out_dir / "ref_logits.npy", dumps["logits"])
    (out_dir / "ref_token_id.txt").write_text(str(dumps["token_id"]) + "\n", encoding="ascii")
    manifest = {
        "profile": _PROFILE,
        "dims": {
            "hidden_dim": HIDDEN_DIM,
            "intermediate_dim": INTERMEDIATE_DIM,
            "num_heads": NUM_HEADS,
            "head_dim": HEAD_DIM,
            "n_layers": N_LAYERS,
            "vocab_size": VOCAB_SIZE,
            "max_seq_len": MAX_SEQ_LEN,
        },
        "layout": {
            "emb_base": EMB_BASE,
            "final_gamma_base": FINAL_GAMMA_BASE,
            "lm_head_base": LM_HEAD_BASE,
            "weight_window_beats": WEIGHT_WINDOW_BEATS,
            "layer_weight_stride": LAYER_WEIGHT_STRIDE,
            "hbm_weight_base": HBM_WEIGHT_BASE,
        },
        "rtl_notes": {
            "rmsnorm_mean_divisor": RMS_DIVISOR_RTL,
            "lm_head_weight_layout": "token-major embedding duplicated as tile-major lm_head matrix",
        },
    }
    (out_dir / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")


def emit_autoregressive_outputs(autoregressive: Dict[str, Any], out_dir: Path) -> None:
    steps = autoregressive["steps"]
    token_sequence = autoregressive["token_sequence"]
    for step_info in steps:
        step_idx = int(step_info["step"])
        dumps = step_info["dumps"]
        np.save(out_dir / ("ref_step%d_final_hidden.npy" % step_idx), dumps["final_hidden"])
        (out_dir / ("ref_step%d_token.txt" % step_idx)).write_text(
            str(int(step_info["token_id"])) + "\n",
            encoding="ascii",
        )

    (out_dir / "ref_token_sequence.txt").write_text(
        "\n".join(str(int(tok)) for tok in token_sequence) + "\n",
        encoding="ascii",
    )
    # Also emit golden file used by testbench comparison
    (out_dir / "golden_spec_decode_tokens.txt").write_text(
        "\n".join(str(int(tok)) for tok in token_sequence) + "\n",
        encoding="ascii",
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate model weights/reference dumps for RTL verification")
    parser.add_argument("--out-dir", type=Path, default=OUTPUT_DIR_DEFAULT)
    parser.add_argument("--token-id", type=int, default=0)
    parser.add_argument("--position", type=int, default=0)
    parser.add_argument("--num-tokens", type=int, default=1)
    parser.add_argument("--profile", type=str, default=None,
                        help="Model profile: toy or qwen3 (overrides MODEL_PROFILE env)")
    args = parser.parse_args()

    # Allow CLI --profile to override env var (requires re-import for changed globals)
    if args.profile is not None and args.profile.lower() != _PROFILE:
        os.environ["MODEL_PROFILE"] = args.profile
        print(f"NOTE: --profile={args.profile} differs from startup profile '{_PROFILE}'.")
        print(f"      Please set MODEL_PROFILE={args.profile} env var and re-run.")
        return 1

    print(f"Profile: {_PROFILE} (d={HIDDEN_DIM}, vocab={VOCAB_SIZE}, "
          f"intermediate={INTERMEDIATE_DIM}, heads={NUM_HEADS})")

    out_dir = args.out_dir.resolve()
    out_dir.mkdir(parents=True, exist_ok=True)

    weights = build_weights()
    emit_embedding_mem(weights, out_dir)
    emit_hbm_mem(weights, out_dir)

    if args.num_tokens <= 1:
        dumps, _, _ = run_reference(weights, token_id=args.token_id, position=args.position)
        emit_reference_outputs(dumps, out_dir)
    else:
        autoregressive = run_autoregressive(
            weights,
            bos_token_id=args.token_id,
            num_steps=args.num_tokens,
        )
        first_step = autoregressive["steps"][0]["dumps"]
        emit_reference_outputs(first_step, out_dir)
        emit_autoregressive_outputs(autoregressive, out_dir)

    print(out_dir)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
