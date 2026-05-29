import argparse
import math
import struct
from pathlib import Path
from typing import Any, Dict, Iterable, List, Mapping, Optional, Sequence, Tuple

from rtl_backend.formats import read_json, write_json
from rtl_backend.toy_decoder import ToyDecoderPackage, build_demo_toy_decoder_package


REAL_WEIGHT_KEY_CANDIDATES = {
    "q_proj": (
        "model.layers.0.self_attn.q_proj.weight",
        "layers.0.self_attn.q_proj.weight",
        "model.decoder.layers.0.self_attn.q_proj.weight",
    ),
    "k_proj": (
        "model.layers.0.self_attn.k_proj.weight",
        "layers.0.self_attn.k_proj.weight",
        "model.decoder.layers.0.self_attn.k_proj.weight",
    ),
    "v_proj": (
        "model.layers.0.self_attn.v_proj.weight",
        "layers.0.self_attn.v_proj.weight",
        "model.decoder.layers.0.self_attn.v_proj.weight",
    ),
    "ffn_layer1": (
        "model.layers.0.mlp.up_proj.weight",
        "layers.0.mlp.up_proj.weight",
        "model.decoder.layers.0.mlp.up_proj.weight",
        "model.layers.0.mlp.gate_proj.weight",
        "layers.0.mlp.gate_proj.weight",
        "model.decoder.layers.0.mlp.gate_proj.weight",
        "transformer.h.0.mlp.c_fc.weight",
    ),
    "ffn_layer2": (
        "model.layers.0.mlp.down_proj.weight",
        "layers.0.mlp.down_proj.weight",
        "model.decoder.layers.0.mlp.down_proj.weight",
        "transformer.h.0.mlp.c_proj.weight",
    ),
}


class SafeTensorTensorView(object):
    def __init__(
        self,
        file_path: Path,
        data_start: int,
        data_offsets: Sequence[int],
        dtype: str,
        shape: Sequence[int],
    ):
        self.file_path = Path(file_path)
        self.data_start = int(data_start)
        self.data_offsets = (int(data_offsets[0]), int(data_offsets[1]))
        self.dtype = str(dtype)
        self.shape = tuple(int(dim) for dim in shape)


def _iter_safetensor_values(view: "SafeTensorTensorView") -> Iterable[float]:
    if view.dtype == "F16":
        width_bytes = 2
        unpack_fmt = "<e"
        use_bf16_decode = False
    elif view.dtype == "BF16":
        width_bytes = 2
        unpack_fmt = ""
        use_bf16_decode = True
    elif view.dtype == "F32":
        width_bytes = 4
        unpack_fmt = "<f"
        use_bf16_decode = False
    else:
        raise TypeError(
            "unsupported safetensors dtype for bounded export: {0}".format(view.dtype)
        )

    start_offset = view.data_start + view.data_offsets[0]
    end_offset = view.data_start + view.data_offsets[1]
    byte_count = end_offset - start_offset
    if byte_count < 0 or (byte_count % width_bytes) != 0:
        raise ValueError("invalid safetensors byte span for {0}".format(view.file_path))

    with view.file_path.open("rb") as handle:
        handle.seek(start_offset)
        raw = handle.read(byte_count)

    for index in range(0, len(raw), width_bytes):
        chunk = raw[index : index + width_bytes]
        if use_bf16_decode:
            bits16 = struct.unpack("<H", chunk)[0]
            bits32 = bits16 << 16
            yield float(struct.unpack("<f", struct.pack("<I", bits32))[0])
            continue
        yield float(struct.unpack(unpack_fmt, chunk)[0])


def _flatten_tensor_like(value: Any) -> Iterable[float]:
    if value is None:
        return

    if isinstance(value, (int, float)):
        yield float(value)
        return

    if isinstance(value, SafeTensorTensorView):
        for item in _iter_safetensor_values(value):
            yield item
        return

    if hasattr(value, "detach") and hasattr(value, "reshape"):
        flattened = value.detach().cpu().reshape(-1).tolist()
        for item in flattened:
            yield float(item)
        return

    if isinstance(value, (list, tuple)):
        for item in value:
            for nested in _flatten_tensor_like(item):
                yield nested
        return

    raise TypeError("unsupported tensor-like value for real weight export")


def _select_scalar_from_tensor_like(value: Any) -> float:
    first_finite: Optional[float] = None
    for item in _flatten_tensor_like(value):
        if not math.isfinite(item):
            continue
        if first_finite is None:
            first_finite = item
        if abs(item) > 1e-12:
            return item

    if first_finite is not None:
        return first_finite
    return 0.0


def _select_block_from_tensor_like(
    value: Any,
    block_elems: int,
) -> List[float]:
    selected: List[float] = []
    for item in _flatten_tensor_like(value):
        if not math.isfinite(item):
            continue
        selected.append(float(item))
        if len(selected) >= block_elems:
            break

    while len(selected) < block_elems:
        selected.append(0.0)
    return selected


def _select_weight_key(
    state_dict: Mapping[str, Any],
    logical_name: str,
) -> Tuple[str, float, List[float]]:
    for candidate in REAL_WEIGHT_KEY_CANDIDATES[logical_name]:
        if candidate in state_dict:
            block = _select_block_from_tensor_like(
                state_dict[candidate],
                16,
            )
            scalar_value = block[0] if block else 0.0
            return candidate, scalar_value, block
    raise KeyError(
        "missing required logical weight {0}; checked keys: {1}".format(
            logical_name,
            ", ".join(REAL_WEIGHT_KEY_CANDIDATES[logical_name]),
        )
    )


def _load_state_dict_fixture_json(path: Path) -> Tuple[str, Dict[str, Any]]:
    payload = read_json(Path(path))
    state_dict = dict(payload["state_dict"])
    model_name = str(payload.get("model_name", Path(path).stem))
    return model_name, state_dict


def _load_state_dict_from_model_path(path: Path) -> Tuple[str, Dict[str, Any]]:
    resolved = Path(path)
    if not resolved.exists():
        raise FileNotFoundError("model path does not exist: {0}".format(resolved))

    safetensor_files: List[Path] = []
    if resolved.is_dir():
        safetensor_files = sorted(resolved.glob("*.safetensors"))
    elif resolved.suffix == ".safetensors":
        safetensor_files = [resolved]

    if safetensor_files:
        try:
            from safetensors import safe_open  # type: ignore
        except ImportError as exc:
            return _load_state_dict_from_safetensors_files_no_deps(
                resolved.name,
                safetensor_files,
            )

        state_dict: Dict[str, Any] = {}
        try:
            for file_path in safetensor_files:
                with safe_open(str(file_path), framework="pt", device="cpu") as handle:
                    for key in handle.keys():
                        state_dict[key] = handle.get_tensor(key)
        except ModuleNotFoundError as exc:
            if getattr(exc, "name", None) != "torch" and "torch" not in str(exc):
                raise
            return _load_state_dict_from_safetensors_files_no_deps(
                resolved.name,
                safetensor_files,
            )
        return resolved.name, state_dict

    bin_files: List[Path] = []
    if resolved.is_dir():
        bin_files = sorted(resolved.glob("pytorch_model*.bin"))
    elif resolved.suffix in (".bin", ".pt", ".pth"):
        bin_files = [resolved]

    if bin_files:
        try:
            import torch  # type: ignore
        except ImportError as exc:
            raise ImportError("loading torch checkpoints requires torch") from exc

        merged_state_dict: Dict[str, Any] = {}
        for file_path in bin_files:
            loaded = torch.load(str(file_path), map_location="cpu")
            if isinstance(loaded, dict) and "state_dict" in loaded and isinstance(
                loaded["state_dict"], dict
            ):
                loaded = loaded["state_dict"]
            if not isinstance(loaded, dict):
                raise TypeError(
                    "unsupported checkpoint payload in {0}".format(file_path)
                )
            for key, value in loaded.items():
                merged_state_dict[str(key)] = value
        return resolved.name, merged_state_dict

    raise FileNotFoundError(
        "no supported checkpoint files found under {0}".format(resolved)
    )


def _load_state_dict_from_safetensors_files_no_deps(
    model_name: str,
    safetensor_files: Sequence[Path],
) -> Tuple[str, Dict[str, Any]]:
    state_dict: Dict[str, Any] = {}
    for file_path in safetensor_files:
        with Path(file_path).open("rb") as handle:
            header_len = int.from_bytes(handle.read(8), byteorder="little")
            header = read_json_bytes(handle.read(header_len))
        data_start = 8 + header_len
        for key, meta in header.items():
            if key == "__metadata__":
                continue
            state_dict[str(key)] = SafeTensorTensorView(
                file_path=Path(file_path),
                data_start=data_start,
                data_offsets=meta["data_offsets"],
                dtype=meta["dtype"],
                shape=meta["shape"],
            )
    return model_name, state_dict


def read_json_bytes(raw: bytes) -> Dict[str, Any]:
    return read_json_from_text(raw.decode("utf-8"))


def read_json_from_text(raw: str) -> Dict[str, Any]:
    import json

    return json.loads(raw)


def _clone_package_with_overrides(
    base_package: ToyDecoderPackage,
    model_name: str,
    decoder_weights: Dict[str, float],
    decoder_weight_blocks: Dict[str, List[float]],
    extra_metadata: Dict[str, Any],
) -> ToyDecoderPackage:
    merged_metadata = dict(base_package.extra_metadata)
    merged_metadata.update(extra_metadata)
    return ToyDecoderPackage(
        model_name=model_name,
        decoder_weights=dict(decoder_weights),
        decoder_weight_blocks={
            str(k): list(v) for k, v in decoder_weight_blocks.items()
        },
        token_vocab=dict(base_package.token_vocab),
        draft_table=dict(base_package.draft_table),
        recompute_table=dict(base_package.recompute_table),
        result_decode_table=dict(base_package.result_decode_table),
        data_width_bits=base_package.data_width_bits,
        draft_ports=base_package.draft_ports,
        decoder_vector_dim=base_package.decoder_vector_dim,
        decoder_weight_block_shape=list(base_package.decoder_weight_block_shape),
        extra_metadata=merged_metadata,
    )


def build_real_weight_package_from_state_dict(
    model_name: str,
    state_dict: Mapping[str, Any],
    base_package: Optional[ToyDecoderPackage] = None,
    source_kind: str = "model_path",
) -> ToyDecoderPackage:
    selected_keys: Dict[str, str] = {}
    decoder_weights: Dict[str, float] = {}
    decoder_weight_blocks: Dict[str, List[float]] = {}

    for logical_name in (
        "q_proj",
        "k_proj",
        "v_proj",
        "ffn_layer1",
        "ffn_layer2",
    ):
        selected_key, scalar_value, block_values = _select_weight_key(
            state_dict, logical_name
        )
        selected_keys[logical_name] = selected_key
        decoder_weights[logical_name] = float(scalar_value)
        decoder_weight_blocks[logical_name] = list(block_values)

    template = base_package if base_package is not None else build_demo_toy_decoder_package()
    return _clone_package_with_overrides(
        base_package=template,
        model_name=model_name,
        decoder_weights=decoder_weights,
        decoder_weight_blocks=decoder_weight_blocks,
        extra_metadata={
            "source": "real_weight_export",
            "source_kind": source_kind,
            "selected_weight_keys": selected_keys,
        },
    )


def build_real_weight_package_from_fixture_json(
    path: Path,
    base_package: Optional[ToyDecoderPackage] = None,
) -> ToyDecoderPackage:
    model_name, state_dict = _load_state_dict_fixture_json(path)
    return build_real_weight_package_from_state_dict(
        model_name=model_name,
        state_dict=state_dict,
        base_package=base_package,
        source_kind="fixture_json",
    )


def _load_table_override(path: Optional[str]) -> Optional[Dict[str, Any]]:
    if path is None:
        return None
    return read_json(Path(path))


def _apply_table_overrides(
    package: ToyDecoderPackage,
    token_vocab: Optional[Dict[str, Any]],
    draft_table: Optional[Dict[str, Any]],
    recompute_table: Optional[Dict[str, Any]],
    result_decode_table: Optional[Dict[str, Any]],
) -> ToyDecoderPackage:
    return ToyDecoderPackage(
        model_name=package.model_name,
        decoder_weights=dict(package.decoder_weights),
        decoder_weight_blocks={
            str(k): list(v) for k, v in package.decoder_weight_blocks.items()
        },
        token_vocab=(
            dict(package.token_vocab)
            if token_vocab is None
            else {str(k): str(v) for k, v in token_vocab.items()}
        ),
        draft_table=(
            dict(package.draft_table)
            if draft_table is None
            else {str(k): list(v) for k, v in draft_table.items()}
        ),
        recompute_table=(
            dict(package.recompute_table)
            if recompute_table is None
            else {str(k): dict(v) for k, v in recompute_table.items()}
        ),
        result_decode_table=(
            dict(package.result_decode_table)
            if result_decode_table is None
            else {str(k): int(v) for k, v in result_decode_table.items()}
        ),
        data_width_bits=package.data_width_bits,
        draft_ports=package.draft_ports,
        decoder_vector_dim=package.decoder_vector_dim,
        decoder_weight_block_shape=list(package.decoder_weight_block_shape),
        extra_metadata=dict(package.extra_metadata),
    )


def build_argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Export a bounded toy-decoder package from a real checkpoint or fixture "
            "for the stage2 single-chiplet RTL backend."
        )
    )
    source_group = parser.add_mutually_exclusive_group(required=True)
    source_group.add_argument(
        "--fixture-json",
        help="Local JSON fixture with model_name and state_dict for offline tests.",
    )
    source_group.add_argument(
        "--model-path",
        help="HF-style checkpoint directory or model file (.safetensors/.bin/.pt/.pth).",
    )
    parser.add_argument(
        "--out-dir",
        required=True,
        help="Output directory for the exported toy-decoder package.",
    )
    parser.add_argument(
        "--model-name",
        help="Override model name recorded into manifest.json.",
    )
    parser.add_argument(
        "--token-vocab-json",
        help="Optional token vocab override JSON.",
    )
    parser.add_argument(
        "--draft-table-json",
        help="Optional draft table override JSON.",
    )
    parser.add_argument(
        "--recompute-table-json",
        help="Optional recompute table override JSON.",
    )
    parser.add_argument(
        "--result-decode-table-json",
        help="Optional result decode table override JSON.",
    )
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = build_argument_parser()
    args = parser.parse_args(argv)

    if args.fixture_json is not None:
        package = build_real_weight_package_from_fixture_json(Path(args.fixture_json))
    else:
        detected_model_name, state_dict = _load_state_dict_from_model_path(
            Path(args.model_path)
        )
        package = build_real_weight_package_from_state_dict(
            model_name=detected_model_name,
            state_dict=state_dict,
            source_kind="model_path",
        )

    if args.model_name:
        package = ToyDecoderPackage(
            model_name=str(args.model_name),
            decoder_weights=dict(package.decoder_weights),
            decoder_weight_blocks={
                str(k): list(v) for k, v in package.decoder_weight_blocks.items()
            },
            token_vocab=dict(package.token_vocab),
            draft_table=dict(package.draft_table),
            recompute_table=dict(package.recompute_table),
            result_decode_table=dict(package.result_decode_table),
            data_width_bits=package.data_width_bits,
            draft_ports=package.draft_ports,
            decoder_vector_dim=package.decoder_vector_dim,
            decoder_weight_block_shape=list(package.decoder_weight_block_shape),
            extra_metadata=dict(package.extra_metadata),
        )

    package = _apply_table_overrides(
        package=package,
        token_vocab=_load_table_override(args.token_vocab_json),
        draft_table=_load_table_override(args.draft_table_json),
        recompute_table=_load_table_override(args.recompute_table_json),
        result_decode_table=_load_table_override(args.result_decode_table_json),
    )

    out_dir = Path(args.out_dir)
    package.save(out_dir)
    write_json(
        out_dir / "export_summary.json",
        {
            "model_name": package.model_name,
            "out_dir": str(out_dir),
            "decoder_weights": dict(package.decoder_weights),
            "decoder_weight_blocks": {
                str(k): list(v) for k, v in package.decoder_weight_blocks.items()
            },
            "metadata": dict(package.extra_metadata),
        },
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
