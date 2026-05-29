import json
from pathlib import Path
from typing import Any, Dict, List, Optional

from rtl_backend.events import EventLog
from rtl_backend.hbm_image import HbmBeat, HbmImage
from rtl_backend.stimulus import (
    DraftCandidate,
    HbmResponse,
    NativeTreeRequest,
    RecomputeResponse,
    StimulusCycle,
    TreeVerifyBatchRequest,
    VERIFY_WINDOW_SIZE,
    build_tree_mask_from_parents,
    write_stimulus_bundle,
)
from rtl_backend.toy_decoder import (
    ToyDecoderPackage,
    build_demo_toy_decoder_package,
)


def _context_key(tokens: List[int]) -> str:
    return ",".join(str(token) for token in tokens)


def _build_draft_candidates(
    package: ToyDecoderPackage,
    context_tokens: List[int],
) -> List[DraftCandidate]:
    raw_entries = package.draft_table.get(_context_key(context_tokens), [])
    candidates = []
    for entry in raw_entries[: package.draft_ports]:
        candidates.append(
            DraftCandidate(
                valid=True,
                parent_node_id=int(entry["parent_node_id"]),
                token_id=int(entry["token_id"]),
                referenced_token_id=int(entry["referenced_token_id"]),
                referenced_position=int(entry["referenced_position"]),
                confidence=int(entry["confidence"]),
            )
        )
    return candidates


def _build_recompute_response(
    package: ToyDecoderPackage,
    candidates: List[DraftCandidate],
) -> RecomputeResponse:
    for candidate in candidates:
        entry = None
        for lookup_key in (
            f"{candidate.referenced_token_id}@{candidate.referenced_position}",
            f"{candidate.token_id}@{candidate.referenced_position}",
        ):
            if lookup_key in package.recompute_table:
                entry = package.recompute_table[lookup_key]
                break
        if entry is None:
            continue
        return RecomputeResponse(
            valid=True,
            partial=bool(entry.get("partial", False)),
            full=bool(entry.get("full", False)),
            req_id=int(entry.get("req_id", 0)),
            kv_data_hex=str(entry.get("kv_data_hex", "0" * 32)),
            last=bool(entry.get("last", True)),
        )
    return RecomputeResponse()


def _build_fallback_full_recompute_response(
    package: ToyDecoderPackage,
) -> RecomputeResponse:
    if package.recompute_table:
        first_key = sorted(package.recompute_table.keys())[0]
        entry = package.recompute_table[first_key]
        return RecomputeResponse(
            valid=True,
            partial=False,
            full=True,
            req_id=int(entry.get("req_id", 1)),
            kv_data_hex=str(entry.get("kv_data_hex", "34" * 16)),
            last=True,
        )
    return RecomputeResponse(
        valid=True,
        partial=False,
        full=True,
        req_id=1,
        kv_data_hex="34" * 16,
        last=True,
    )


def _build_explicit_context_prefill_candidate(
    committed_context_tokens: List[int],
    prefix_len: int,
) -> Optional[DraftCandidate]:
    if prefix_len <= 0 or prefix_len >= len(committed_context_tokens):
        return None
    return DraftCandidate(
        valid=True,
        parent_node_id=prefix_len,
        token_id=int(committed_context_tokens[prefix_len]),
        referenced_token_id=int(committed_context_tokens[prefix_len - 1]),
        referenced_position=prefix_len - 1,
        confidence=255,
    )


def _build_cycle_recompute_response(
    package: ToyDecoderPackage,
    candidates: List[DraftCandidate],
) -> RecomputeResponse:
    response = _build_recompute_response(package, candidates)
    if response.valid:
        return response
    if any(candidate.valid for candidate in candidates):
        return _build_fallback_full_recompute_response(package)
    return response


def _native_tree_frontier_candidates(
    native_tree_request: NativeTreeRequest,
) -> List[DraftCandidate]:
    candidates: List[DraftCandidate] = []

    prefix_token_by_node = {}
    prefix_position_by_node = {}
    for slot_idx, node_id in enumerate(native_tree_request.normalized_prefix_node_ids()):
        if ((native_tree_request.prefix_slot_valid >> slot_idx) & 0x1) == 0:
            continue
        prefix_token_by_node[int(node_id)] = int(
            native_tree_request.normalized_prefix_token_ids()[slot_idx]
        )
        prefix_position_by_node[int(node_id)] = int(
            native_tree_request.normalized_prefix_position_ids()[slot_idx]
        )

    frontier_slot_valid_by_level = (
        native_tree_request.normalized_frontier_slot_valid_by_level()
    )
    frontier_node_ids_by_level = (
        native_tree_request.normalized_frontier_node_ids_by_level()
    )
    frontier_parent_node_ids_by_level = (
        native_tree_request.normalized_frontier_parent_node_ids_by_level()
    )
    frontier_token_ids_by_level = (
        native_tree_request.normalized_frontier_token_ids_by_level()
    )
    frontier_referenced_token_ids_by_level = (
        native_tree_request.normalized_frontier_referenced_token_ids_by_level()
    )
    frontier_position_ids_by_level = (
        native_tree_request.normalized_frontier_position_ids_by_level()
    )
    frontier_referenced_position_ids_by_level = (
        native_tree_request.normalized_frontier_referenced_position_ids_by_level()
    )

    cached_token_by_node = dict(prefix_token_by_node)
    cached_position_by_node = dict(prefix_position_by_node)
    frontier_by_node = {}

    for level_idx, slot_valid in enumerate(frontier_slot_valid_by_level):
        if ((native_tree_request.frontier_level_valid >> level_idx) & 0x1) == 0:
            continue
        for slot_idx in range(len(frontier_node_ids_by_level[level_idx])):
            if ((slot_valid >> slot_idx) & 0x1) == 0:
                continue
            node_id = int(frontier_node_ids_by_level[level_idx][slot_idx])
            parent_node_id = int(
                frontier_parent_node_ids_by_level[level_idx][slot_idx]
            )
            token_id = int(frontier_token_ids_by_level[level_idx][slot_idx])
            position_id = int(frontier_position_ids_by_level[level_idx][slot_idx])
            referenced_token_id = int(
                frontier_referenced_token_ids_by_level[level_idx][slot_idx]
            )
            referenced_position_id = int(
                frontier_referenced_position_ids_by_level[level_idx][slot_idx]
            )
            frontier_by_node[node_id] = {
                "parent_node_id": parent_node_id,
                "token_id": token_id,
                "position_id": position_id,
                "referenced_token_id": referenced_token_id,
                "referenced_position_id": referenced_position_id,
            }
            cached_token_by_node[node_id] = token_id
            cached_position_by_node[node_id] = position_id

    for level_idx, slot_valid in enumerate(frontier_slot_valid_by_level):
        if ((native_tree_request.frontier_level_valid >> level_idx) & 0x1) == 0:
            continue
        for slot_idx in range(len(frontier_node_ids_by_level[level_idx])):
            if ((slot_valid >> slot_idx) & 0x1) == 0:
                continue
            node_id = int(frontier_node_ids_by_level[level_idx][slot_idx])
            entry = frontier_by_node[node_id]
            parent_node_id = int(entry["parent_node_id"])
            if parent_node_id in cached_token_by_node:
                referenced_token_id = int(cached_token_by_node[parent_node_id])
                referenced_position = int(cached_position_by_node[parent_node_id])
            else:
                referenced_token_id = int(entry["referenced_token_id"])
                referenced_position = int(entry["referenced_position_id"])
            candidates.append(
                DraftCandidate(
                    valid=True,
                    parent_node_id=parent_node_id,
                    token_id=int(entry["token_id"]),
                    referenced_token_id=referenced_token_id,
                    referenced_position=referenced_position,
                    confidence=200,
                )
            )
    return candidates


def _build_native_tree_recompute_tail_cycles(
    package: ToyDecoderPackage,
    native_tree_request: NativeTreeRequest,
) -> List[StimulusCycle]:
    candidates = _native_tree_frontier_candidates(native_tree_request)
    if not candidates:
        return []

    response = _build_recompute_response(
        package,
        candidates,
    )
    if not response.valid:
        response = _build_fallback_full_recompute_response(package)

    cycles: List[StimulusCycle] = []
    for _ in range(4):
        cycles.append(
            StimulusCycle(
                tree_window_ready=True,
                recompute_req_ready=True,
                wb_ready=True,
            )
        )
    for _ in range(3):
        cycles.append(
            StimulusCycle(
                tree_window_ready=True,
                recompute_req_ready=True,
                recompute_response=response,
                wb_ready=True,
            )
        )
    cycles.append(
        StimulusCycle(
            tree_window_ready=True,
            recompute_req_ready=True,
            wb_ready=True,
        )
    )
    return cycles


def _build_default_native_tree_request() -> NativeTreeRequest:
    return NativeTreeRequest(
        valid=True,
        req_id=0xD,
        prefix_slot_valid=0b0011,
        prefix_node_ids=[0x1, 0x2],
        prefix_token_ids=[0x10, 0x11],
        prefix_position_ids=[0x0, 0x1],
        frontier_level_valid=0b0011,
        frontier_slot_valid_by_level=[0b0011, 0b0011],
        frontier_tree_mask_en_by_level=[0b0011, 0b0011],
        frontier_node_ids_by_level=[
            [0x3, 0x4],
            [0x5, 0x6],
        ],
        frontier_parent_node_ids_by_level=[
            [0x2, 0x2],
            [0x3, 0x4],
        ],
        frontier_token_ids_by_level=[
            [0x21, 0x22],
            [0x31, 0x32],
        ],
        frontier_position_ids_by_level=[
            [0x2, 0x2],
            [0x3, 0x3],
        ],
    )


def _count_prefix_tokens(native_tree_request: NativeTreeRequest) -> int:
    return sum(
        1
        for slot_idx in range(len(native_tree_request.normalized_prefix_node_ids()))
        if native_tree_request.prefix_slot_valid & (1 << slot_idx)
    )


def _visible_mask_to_int(mask_bits: object) -> int:
    mask = 0
    if hasattr(mask_bits, "tolist"):
        mask_bits = mask_bits.tolist()
    for bit_idx, bit in enumerate(list(mask_bits)):
        if int(bit):
            mask |= 1 << bit_idx
    return mask


def _first_native_tree_visible_mask(
    native_tree_request: NativeTreeRequest,
) -> int:
    prefix_positions = {}
    node_parent = {}
    node_position = {}
    node_referenced_position = {}
    frontier_slot_valid_by_level = (
        native_tree_request.normalized_frontier_slot_valid_by_level()
    )
    frontier_node_ids_by_level = (
        native_tree_request.normalized_frontier_node_ids_by_level()
    )
    frontier_parent_node_ids_by_level = (
        native_tree_request.normalized_frontier_parent_node_ids_by_level()
    )
    frontier_position_ids_by_level = (
        native_tree_request.normalized_frontier_position_ids_by_level()
    )
    frontier_referenced_position_ids_by_level = (
        native_tree_request.normalized_frontier_referenced_position_ids_by_level()
    )

    for slot_idx, node_id in enumerate(native_tree_request.normalized_prefix_node_ids()):
        if ((native_tree_request.prefix_slot_valid >> slot_idx) & 0x1) == 0:
            continue
        prefix_positions[int(node_id)] = int(
            native_tree_request.normalized_prefix_position_ids()[slot_idx]
        )

    query_node_ids = []
    for level_idx, slot_valid in enumerate(frontier_slot_valid_by_level):
        if ((native_tree_request.frontier_level_valid >> level_idx) & 0x1) == 0:
            continue
        for slot_idx in range(len(frontier_node_ids_by_level[level_idx])):
            if ((slot_valid >> slot_idx) & 0x1) == 0:
                continue
            node_id = int(frontier_node_ids_by_level[level_idx][slot_idx])
            query_node_ids.append(node_id)
            node_parent[node_id] = int(
                frontier_parent_node_ids_by_level[level_idx][slot_idx]
            )
            node_position[node_id] = int(
                frontier_position_ids_by_level[level_idx][slot_idx]
            )
            node_referenced_position[node_id] = int(
                frontier_referenced_position_ids_by_level[level_idx][slot_idx]
            )

    if not query_node_ids:
        return 0

    query_node_id = query_node_ids[0]
    mask_bits = [0] * 8
    for position_id in prefix_positions.values():
        if 0 <= int(position_id) < len(mask_bits):
            mask_bits[int(position_id)] = 1

    cursor = query_node_id
    visited = set()
    while cursor not in visited and cursor in node_parent:
        visited.add(cursor)
        position_id = node_position.get(cursor)
        if position_id is not None and 0 <= int(position_id) < len(mask_bits):
            mask_bits[int(position_id)] = 1
        referenced_position_id = node_referenced_position.get(cursor)
        if (
            referenced_position_id is not None
            and 0 <= int(referenced_position_id) < len(mask_bits)
        ):
            mask_bits[int(referenced_position_id)] = 1
        cursor = int(node_parent.get(cursor, 0))

    return _visible_mask_to_int(mask_bits)


def _build_stimulus_cycles(
    prompt_tokens: List[int],
    package: ToyDecoderPackage,
    include_native_tree: bool,
    native_tree_request: Optional[NativeTreeRequest] = None,
    enable_demo_draft_candidates: bool = True,
    native_tree_launch_prefix_len: Optional[int] = None,
) -> List[StimulusCycle]:
    cycles = [
        StimulusCycle(
            cfg_valid=True,
            cfg_data=len(prompt_tokens),
            start=True,
            tree_window_ready=True,
            recompute_req_ready=True,
            wb_ready=True,
            hbm_response=HbmResponse(),
        )
    ]

    if include_native_tree and not prompt_tokens:
        resolved_native_tree_request = (
            native_tree_request
            if native_tree_request is not None
            else _build_default_native_tree_request()
        )
        cycles.append(
            StimulusCycle(
                tree_window_ready=True,
                recompute_req_ready=True,
                recompute_response=_build_recompute_response(package, []),
                wb_ready=True,
                hbm_response=HbmResponse(),
                native_tree_request=resolved_native_tree_request,
                visible_mask=_first_native_tree_visible_mask(
                    resolved_native_tree_request
                ),
            )
        )

    launch_prefix_len = native_tree_launch_prefix_len
    if launch_prefix_len is None:
        launch_prefix_len = 1
    launch_prefix_len = max(0, min(int(launch_prefix_len), len(prompt_tokens)))

    for prefix_len in range(1, len(prompt_tokens) + 1):
        context_tokens = prompt_tokens[:prefix_len]
        if enable_demo_draft_candidates:
            candidates = _build_draft_candidates(package, context_tokens)
        else:
            forced_candidate = _build_explicit_context_prefill_candidate(
                prompt_tokens,
                prefix_len,
            )
            candidates = [] if forced_candidate is None else [forced_candidate]
        resolved_native_tree_request = (
            native_tree_request
            if native_tree_request is not None
            else _build_default_native_tree_request()
        )
        emit_native_tree = include_native_tree and prefix_len == launch_prefix_len
        cycles.append(
            StimulusCycle(
                draft_candidates=candidates,
                tree_window_ready=True,
                recompute_req_ready=True,
                recompute_response=_build_cycle_recompute_response(package, candidates),
                wb_ready=True,
                hbm_response=HbmResponse(),
                native_tree_request=(
                    resolved_native_tree_request
                    if emit_native_tree
                    else NativeTreeRequest()
                ),
                visible_mask=(
                    _first_native_tree_visible_mask(resolved_native_tree_request)
                    if emit_native_tree
                    else 0
                ),
            )
        )

    if not enable_demo_draft_candidates and (
        include_native_tree or native_tree_request is not None
    ):
        resolved_native_tree_request = (
            native_tree_request
            if native_tree_request is not None
            else _build_default_native_tree_request()
        )
        cycles.extend(
            _build_native_tree_recompute_tail_cycles(
                package,
                resolved_native_tree_request,
            )
        )

    if len(cycles) == 1:
        cycles.append(
            StimulusCycle(
                tree_window_ready=True,
                recompute_req_ready=True,
                wb_ready=True,
            )
        )
    return cycles


def _write_weight_region(image: HbmImage, package: ToyDecoderPackage) -> None:
    weight_hex_words = package.decoder_weight_hex_lines()
    words_per_beat = image.layout.beat_bytes // 2
    for beat_idx in range(0, len(weight_hex_words), words_per_beat):
        beat_words = weight_hex_words[beat_idx : beat_idx + words_per_beat]
        beat_hex = "".join(beat_words)
        padded_beat_hex = beat_hex.ljust(image.layout.beat_bytes * 2, "0")
        image.write_region_hex(
            "WEIGHT",
            (beat_idx // words_per_beat) * image.layout.beat_bytes,
            padded_beat_hex,
            note="toy decoder vector weight block beat",
        )


def _clone_image(image: HbmImage) -> HbmImage:
    cloned = HbmImage(
        layout=image.layout,
        regions={region.name: {} for region in image.layout.regions},
    )
    for region_name, beats in image.regions.items():
        cloned.regions[region_name] = {
            addr: HbmBeat(addr=beat.addr, data_hex=beat.data_hex, note=beat.note)
            for addr, beat in beats.items()
        }
    return cloned


def _write_utf8_state(
    image: HbmImage,
    region_name: str,
    payload: Dict[str, Any],
) -> None:
    encoded = json.dumps(payload, ensure_ascii=False, sort_keys=True).encode("utf-8")
    beat_bytes = image.layout.beat_bytes
    chunks = [encoded[index : index + beat_bytes] for index in range(0, len(encoded), beat_bytes)]
    if not chunks:
        chunks = [b""]
    for index, chunk in enumerate(chunks):
        image.write_region_hex(
            region_name,
            index * beat_bytes,
            chunk.hex(),
            note=f"{region_name.lower()} utf8 state chunk",
        )


def _overlay_committed_kv_cache(
    weights: Dict[str, Any],
    out_dir: Path,
    committed_context_tokens: List[int],
) -> None:
    from toy_model.toy_model_reference import (
        ELEMS_PER_SRAM_BEAT,
        HEAD_DIM,
        MAX_SEQ_LEN,
        N_LAYERS,
        NUM_HEADS,
        pack_sram_beat,
        run_reference,
    )

    if not committed_context_tokens:
        return
    if len(committed_context_tokens) > MAX_SEQ_LEN:
        raise ValueError(
            "committed_context_tokens exceeds toy-model MAX_SEQ_LEN "
            f"({len(committed_context_tokens)} > {MAX_SEQ_LEN})"
        )

    kv_committed_base = 49152
    kv_layer_stride = 4096
    zero_line = "0" * 32
    head_beats = HEAD_DIM // ELEMS_PER_SRAM_BEAT

    preload_path = Path(out_dir) / "sram_preload.memh"
    preload_lines = preload_path.read_text(encoding="ascii").splitlines()

    kv_cache_k = None
    kv_cache_v = None
    for position, token_id in enumerate(committed_context_tokens):
        _, kv_cache_k, kv_cache_v = run_reference(
            weights=weights,
            token_id=int(token_id),
            position=position,
            kv_cache_k=kv_cache_k,
            kv_cache_v=kv_cache_v,
        )

    max_addr = kv_committed_base + ((N_LAYERS - 1) * kv_layer_stride)
    max_addr += (len(committed_context_tokens) * NUM_HEADS * head_beats * 2)
    max_addr += (NUM_HEADS * head_beats) - 1
    if len(preload_lines) <= max_addr:
        preload_lines.extend([zero_line] * ((max_addr + 1) - len(preload_lines)))

    for layer_idx in range(N_LAYERS):
        layer_base = kv_committed_base + (layer_idx * kv_layer_stride)
        for position in range(len(committed_context_tokens)):
            position_base = layer_base + (position * NUM_HEADS * head_beats * 2)
            for head_idx in range(NUM_HEADS):
                k_base = position_base + (head_idx * head_beats)
                v_base = position_base + (NUM_HEADS * head_beats) + (head_idx * head_beats)
                for beat_idx in range(head_beats):
                    beat_lo = beat_idx * ELEMS_PER_SRAM_BEAT
                    beat_hi = (beat_idx + 1) * ELEMS_PER_SRAM_BEAT
                    preload_lines[k_base + beat_idx] = pack_sram_beat(
                        kv_cache_k[layer_idx, position, head_idx, beat_lo:beat_hi]
                    )
                    preload_lines[v_base + beat_idx] = pack_sram_beat(
                        kv_cache_v[layer_idx, position, head_idx, beat_lo:beat_hi]
                    )

    preload_path.write_text("\n".join(preload_lines) + "\n", encoding="ascii")


def _emit_toy_model_fp16_assets(
    out_dir: Path,
    committed_context_tokens: Optional[List[int]] = None,
) -> None:
    from toy_model.toy_model_reference import (
        build_weights,
        emit_embedding_mem,
        emit_hbm_mem,
        emit_reference_outputs,
        run_reference,
    )

    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    weights = build_weights()
    emit_embedding_mem(weights, out_dir)
    emit_hbm_mem(weights, out_dir)
    _overlay_committed_kv_cache(
        weights=weights,
        out_dir=out_dir,
        committed_context_tokens=list(committed_context_tokens or []),
    )
    dumps, _, _ = run_reference(weights, token_id=0, position=0)
    emit_reference_outputs(dumps, out_dir)


def build_single_chiplet_demo_artifacts(
    workdir: Path,
    prompt_tokens: List[int],
    package: Optional[ToyDecoderPackage] = None,
    include_native_tree: bool = False,
    native_tree_request: Optional[NativeTreeRequest] = None,
    enable_demo_draft_candidates: bool = True,
    native_tree_launch_prefix_len: Optional[int] = None,
    committed_context_tokens: Optional[List[int]] = None,
) -> Path:
    workdir = Path(workdir)
    stimulus_dir = workdir / "stimulus"
    weights_dir = workdir / "weights" / "toy_decoder"
    toy_model_fp16_dir = workdir / "weights" / "toy_model_fp16"
    hbm_input_dir = workdir / "hbm_input"
    hbm_output_dir = workdir / "hbm_output"
    events_dir = workdir / "events"

    for directory in (
        stimulus_dir,
        weights_dir,
        toy_model_fp16_dir,
        hbm_input_dir,
        hbm_output_dir,
        events_dir,
    ):
        directory.mkdir(parents=True, exist_ok=True)

    resolved_package = package if package is not None else build_demo_toy_decoder_package()
    resolved_package.save(weights_dir)
    _emit_toy_model_fp16_assets(
        toy_model_fp16_dir,
        committed_context_tokens=committed_context_tokens,
    )

    hbm_input = HbmImage.default()
    hbm_input.write_meta_text(
        json.dumps(
            {
                "model_name": resolved_package.model_name,
                "prompt_tokens": prompt_tokens,
                "draft_ports": resolved_package.draft_ports,
            },
            ensure_ascii=False,
            sort_keys=True,
        )
    )
    _write_weight_region(hbm_input, resolved_package)
    hbm_input.save(hbm_input_dir)

    stimulus_cycles = _build_stimulus_cycles(
        prompt_tokens,
        resolved_package,
        include_native_tree=(include_native_tree or native_tree_request is not None),
        native_tree_request=native_tree_request,
        enable_demo_draft_candidates=enable_demo_draft_candidates,
        native_tree_launch_prefix_len=native_tree_launch_prefix_len,
    )
    write_stimulus_bundle(stimulus_dir, stimulus_cycles)
    return workdir


def materialize_hbm_output_from_events(
    workdir: Path,
    out_dir: Optional[Path] = None,
) -> Path:
    workdir = Path(workdir)
    output_dir = Path(out_dir) if out_dir is not None else (workdir / "hbm_output")

    input_image = HbmImage.load(workdir / "hbm_input")
    output_image = _clone_image(input_image)
    events = EventLog.load(workdir / "events" / "events.jsonl")

    state_shadow = {
        "wb_done_count": 0,
        "wb_done_tokens": [],
        "wb_payload_tokens": [],
        "finish_seen": False,
        "busy_final": None,
        "error_flag": None,
        "ignored_hbm_write_count": 0,
        "ignored_hbm_write_addrs": [],
    }

    for record in events.records:
        if record.event == "hbm_write":
            addr_hex = str(record.fields["addr_hex"])
            data_hex = str(record.fields["data_hex"])
            addr = int(addr_hex, 16)
            try:
                output_image.write_absolute_hex(
                    addr,
                    data_hex,
                    note="materialized from rtl hbm_write event",
                )
            except KeyError:
                ignored_addrs = list(state_shadow["ignored_hbm_write_addrs"])
                ignored_addrs.append(f"0x{addr:08x}")
                state_shadow["ignored_hbm_write_addrs"] = ignored_addrs
                state_shadow["ignored_hbm_write_count"] = (
                    int(state_shadow["ignored_hbm_write_count"]) + 1
                )
            continue

        if record.event == "wb":
            payload_tokens = list(state_shadow["wb_payload_tokens"])
            data_hex = record.fields.get("data_hex")
            if data_hex is not None:
                normalized = str(data_hex).strip().lower()
                if normalized.startswith("0x"):
                    normalized = normalized[2:]
                if normalized:
                    payload_tokens.append(int(normalized, 16) & 0xFFFF)
            state_shadow["wb_payload_tokens"] = payload_tokens
            continue

        if record.event == "wb_done":
            state_shadow["wb_done_count"] = int(state_shadow["wb_done_count"]) + 1
            wb_done_tokens = list(state_shadow["wb_done_tokens"])
            if "token_id" in record.fields:
                wb_done_tokens.append(int(record.fields["token_id"]))
            elif "token_id_hex" in record.fields:
                wb_done_tokens.append(int(str(record.fields["token_id_hex"]), 16))
            state_shadow["wb_done_tokens"] = wb_done_tokens
            continue

        if record.event == "finish":
            state_shadow["finish_seen"] = True
            state_shadow["busy_final"] = record.fields.get("busy_final")
            state_shadow["error_flag"] = record.fields.get("error_flag")

    _write_utf8_state(output_image, "STATE", state_shadow)
    output_image.save(output_dir)
    return output_dir


def build_tree_verify_batch(
    seed_token_id: int,
    seed_position: int,
    branch_draft_tokens: List[List[int]],
    branch_draft_positions: List[List[int]],
    branch_parent_slots: List[List[int]],
    branch_valid: List[bool],
    prefix_len: int,
) -> TreeVerifyBatchRequest:
    """Build a TreeVerifyBatchRequest by flattening a speculative tree.

    The tree is defined by a seed token (the last committed token) and
    multiple branches of draft tokens.  Shared nodes across branches are
    deduplicated so that each unique (token_id, position) pair occupies
    exactly one slot in the verify window.

    Parameters
    ----------
    seed_token_id : int
        Token ID of the seed (last committed token).
    seed_position : int
        Absolute position of the seed token.
    branch_draft_tokens : List[List[int]]
        Per-branch list of draft token IDs (excluding seed).
    branch_draft_positions : List[List[int]]
        Per-branch list of absolute positions for each draft token.
    branch_parent_slots : List[List[int]]
        Per-branch list indicating the parent slot index for each draft
        token within that branch.  Index 0 in each branch refers to the
        seed slot (slot 0).
    branch_valid : List[bool]
        Which branches are active.
    prefix_len : int
        Number of committed prefix tokens (KV already stored).

    Returns
    -------
    TreeVerifyBatchRequest
        The fully populated batch request with deduplicated slots,
        tree mask, and branch-to-slot mapping.
    """
    # Slot 0 is always the seed token
    slot_token_ids: List[int] = [seed_token_id]
    slot_positions: List[int] = [seed_position]
    slot_parent_slot: List[int] = [0]  # seed's parent is itself
    slot_is_seed: List[bool] = [True]

    # Map (token_id, position) -> slot index for deduplication
    node_key_to_slot: Dict[str, int] = {
        f"{seed_token_id}:{seed_position}": 0
    }

    branch_slot_map: List[List[int]] = []

    for branch_idx, valid in enumerate(branch_valid):
        branch_slots: List[int] = []
        if not valid:
            branch_slot_map.append(branch_slots)
            continue

        draft_tokens = branch_draft_tokens[branch_idx]
        draft_positions = branch_draft_positions[branch_idx]
        parent_slots_in_branch = branch_parent_slots[branch_idx]

        # Build a local mapping from branch-level index to global slot
        # index.  Branch-level index 0 is implicitly the seed (slot 0).
        local_to_global: List[int] = [0]  # index 0 -> seed slot

        for level_idx in range(len(draft_tokens)):
            token_id = draft_tokens[level_idx]
            position = draft_positions[level_idx]
            key = f"{token_id}:{position}"

            if key in node_key_to_slot:
                # Reuse existing slot (shared node)
                global_slot = node_key_to_slot[key]
            else:
                # Allocate a new slot
                global_slot = len(slot_token_ids)
                if global_slot >= VERIFY_WINDOW_SIZE:
                    # Window full; truncate remaining tokens in branch
                    break
                node_key_to_slot[key] = global_slot
                slot_token_ids.append(token_id)
                slot_positions.append(position)

                # Resolve parent: branch_parent_slots gives the
                # branch-local index of the parent
                parent_branch_idx = parent_slots_in_branch[level_idx]
                parent_global = local_to_global[parent_branch_idx]
                slot_parent_slot.append(parent_global)
                slot_is_seed.append(False)

            local_to_global.append(global_slot)
            branch_slots.append(global_slot)

        branch_slot_map.append(branch_slots)

    slot_count = len(slot_token_ids)

    # Determine if the seed KV is already in the committed region
    seed_kv_valid = seed_position < prefix_len

    # Build the tree mask from parent relationships
    tree_mask = build_tree_mask_from_parents(slot_parent_slot, slot_count)

    return TreeVerifyBatchRequest(
        slot_count=slot_count,
        slot_token_ids=slot_token_ids,
        slot_positions=slot_positions,
        tree_mask=tree_mask,
        prefix_len=prefix_len,
        seed_kv_valid=seed_kv_valid,
        slot_is_seed=slot_is_seed,
        branch_slot_map=branch_slot_map,
        slot_parent_slot=slot_parent_slot,
    )
