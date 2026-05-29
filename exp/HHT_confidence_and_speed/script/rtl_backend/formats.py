import json
import struct
from pathlib import Path
from typing import Any, Dict, Tuple, Union

from rtl_backend.compat import dataclass

DEFAULT_DECODER_WEIGHT_ORDER = [
    "q_proj",
    "k_proj",
    "v_proj",
    "ffn_layer1",
    "ffn_layer2",
]
DEFAULT_DECODER_VECTOR_DIM = 4
DEFAULT_DECODER_WEIGHT_BLOCK_SHAPE = (4, 4)

DEFAULT_HBM_REGION_NAMES = [
    "META",
    "WEIGHT",
    "KV",
    "OUTPUT",
    "STATE",
]

HBM_BEAT_BYTES = 32
HBM_DATA_WIDTH_BITS = 256


@dataclass(frozen=True)
class HbmRegion:
    name: str
    base: int
    size: int

    def to_dict(self) -> Dict[str, Union[int, str]]:
        return {
            "name": self.name,
            "base": self.base,
            "size": self.size,
        }

    @classmethod
    def from_dict(cls, data: Dict[str, Union[int, str]]) -> "HbmRegion":
        return cls(
            name=str(data["name"]),
            base=int(data["base"]),
            size=int(data["size"]),
        )


@dataclass(frozen=True)
class HbmLayout:
    beat_bytes: int
    data_width_bits: int
    regions: Tuple[HbmRegion, ...]
    format_name: str = "stage2_hbm_image"
    version: int = 1
    addr_unit: str = "byte"

    def to_dict(self) -> Dict[str, Any]:
        return {
            "format": self.format_name,
            "version": self.version,
            "addr_unit": self.addr_unit,
            "beat_bytes": self.beat_bytes,
            "data_width_bits": self.data_width_bits,
            "regions": [region.to_dict() for region in self.regions],
        }

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "HbmLayout":
        return cls(
            format_name=str(data["format"]),
            version=int(data["version"]),
            addr_unit=str(data["addr_unit"]),
            beat_bytes=int(data["beat_bytes"]),
            data_width_bits=int(data["data_width_bits"]),
            regions=tuple(
                HbmRegion.from_dict(region) for region in list(data["regions"])
            ),
        )

    def region_by_name(self, name: str) -> HbmRegion:
        for region in self.regions:
            if region.name == name:
                return region
        raise KeyError(f"unknown HBM region: {name}")


def build_default_hbm_layout() -> HbmLayout:
    return HbmLayout(
        beat_bytes=HBM_BEAT_BYTES,
        data_width_bits=HBM_DATA_WIDTH_BITS,
        regions=(
            HbmRegion("META", 0x0000_0000, 0x0001_0000),
            HbmRegion("WEIGHT", 0x0010_0000, 0x0010_0000),
            HbmRegion("KV", 0x1000_0000, 0x0100_0000),
            HbmRegion("OUTPUT", 0x2000_0000, 0x0010_0000),
            HbmRegion("STATE", 0x2100_0000, 0x0010_0000),
        ),
    )


def build_default_toy_weight_manifest(model_name: str) -> Dict[str, Any]:
    return {
        "format": "toy_decoder_package",
        "version": 1,
        "model_name": model_name,
        "data_width_bits": 16,
        "weight_encoding": "fp16_hex",
        "decoder_weight_order": list(DEFAULT_DECODER_WEIGHT_ORDER),
        "decoder_vector_dim": DEFAULT_DECODER_VECTOR_DIM,
        "decoder_weight_block_shape": list(DEFAULT_DECODER_WEIGHT_BLOCK_SHAPE),
        "draft_ports": 4,
        "files": {
            "decoder_weights": "rtl_backend_weights/decoder_weights.memh",
            "token_vocab": "python_frontend_tables/token_vocab.json",
            "draft_table": "python_frontend_tables/draft_table.json",
            "recompute_table": "python_frontend_tables/recompute_table.json",
            "result_decode_table": "python_frontend_tables/result_decode_table.json",
        },
    }


def fp16_to_hex(value: float) -> str:
    packed = struct.pack(">e", value)
    return packed.hex()


def fp16_from_hex(value: str) -> float:
    raw = strip_hex_prefix(value)
    if len(raw) != 4:
        raise ValueError(f"fp16 hex must be exactly 4 hex digits, got {value!r}")
    return struct.unpack(">e", bytes.fromhex(raw))[0]


def strip_hex_prefix(value: str) -> str:
    return value[2:] if value.lower().startswith("0x") else value


def normalize_hex(value: str, width_bytes: int) -> str:
    raw = strip_hex_prefix(value).lower()
    expected_nibbles = width_bytes * 2
    if len(raw) > expected_nibbles:
        raise ValueError(
            f"hex string too wide: got {len(raw)} nibbles, expected <= {expected_nibbles}"
        )
    return raw.rjust(expected_nibbles, "0")


def int_to_hex(value: int, width_bytes: int, prefix: bool = False) -> str:
    encoded = f"{value:0{width_bytes * 2}x}"
    return f"0x{encoded}" if prefix else encoded


def write_json(path: Path, payload: Dict[str, Any]) -> None:
    path.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )


def read_json(path: Path) -> Dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))
