from pathlib import Path
from typing import Any, Dict, List

from rtl_backend.compat import dataclass, field
from rtl_backend.formats import (
    DEFAULT_DECODER_VECTOR_DIM,
    DEFAULT_DECODER_WEIGHT_ORDER,
    DEFAULT_DECODER_WEIGHT_BLOCK_SHAPE,
    build_default_toy_weight_manifest,
    fp16_from_hex,
    fp16_to_hex,
    read_json,
    write_json,
)


@dataclass
class ToyDecoderPackage:
    model_name: str
    decoder_weights: Dict[str, float]
    decoder_weight_blocks: Dict[str, List[float]]
    token_vocab: Dict[str, str]
    draft_table: Dict[str, List[Dict[str, int]]]
    recompute_table: Dict[str, Dict[str, Any]]
    result_decode_table: Dict[str, int]
    data_width_bits: int = 16
    draft_ports: int = 4
    decoder_vector_dim: int = DEFAULT_DECODER_VECTOR_DIM
    decoder_weight_block_shape: List[int] = field(
        default_factory=lambda: list(DEFAULT_DECODER_WEIGHT_BLOCK_SHAPE)
    )
    extra_metadata: Dict[str, Any] = field(default_factory=dict)

    def manifest(self) -> Dict[str, Any]:
        manifest = build_default_toy_weight_manifest(self.model_name)
        manifest["data_width_bits"] = self.data_width_bits
        manifest["draft_ports"] = self.draft_ports
        manifest["decoder_vector_dim"] = self.decoder_vector_dim
        manifest["decoder_weight_block_shape"] = list(self.decoder_weight_block_shape)
        if self.extra_metadata:
            manifest["metadata"] = self.extra_metadata
        return manifest

    def decoder_weight_block_elems(self) -> int:
        shape = list(self.decoder_weight_block_shape)
        return int(shape[0]) * int(shape[1])

    def _normalized_block(self, logical_name: str) -> List[float]:
        block_elems = self.decoder_weight_block_elems()
        raw_block = list(self.decoder_weight_blocks.get(logical_name, []))
        if not raw_block and logical_name in self.decoder_weights:
            raw_block = [float(self.decoder_weights[logical_name])]
        raw_block = [float(value) for value in raw_block[:block_elems]]
        while len(raw_block) < block_elems:
            raw_block.append(0.0)
        return raw_block

    def decoder_weight_hex_lines(self) -> List[str]:
        lines = []
        for name in DEFAULT_DECODER_WEIGHT_ORDER:
            for value in self._normalized_block(name):
                lines.append(fp16_to_hex(value))
        return lines

    def save(self, root: Path) -> None:
        root.mkdir(parents=True, exist_ok=True)
        weights_dir = root / "rtl_backend_weights"
        tables_dir = root / "python_frontend_tables"
        weights_dir.mkdir(parents=True, exist_ok=True)
        tables_dir.mkdir(parents=True, exist_ok=True)

        write_json(root / "manifest.json", self.manifest())
        (weights_dir / "decoder_weights.memh").write_text(
            "\n".join(self.decoder_weight_hex_lines()) + "\n",
            encoding="utf-8",
        )
        write_json(tables_dir / "token_vocab.json", self.token_vocab)
        write_json(tables_dir / "draft_table.json", self.draft_table)
        write_json(tables_dir / "recompute_table.json", self.recompute_table)
        write_json(tables_dir / "result_decode_table.json", self.result_decode_table)

    @classmethod
    def load(cls, root: Path) -> "ToyDecoderPackage":
        manifest = read_json(root / "manifest.json")
        weight_lines = (
            root / "rtl_backend_weights" / "decoder_weights.memh"
        ).read_text(encoding="utf-8").splitlines()
        normalized_weight_lines = [
            line.strip() for line in weight_lines if line.strip()
        ]
        vector_dim = int(
            manifest.get("decoder_vector_dim", DEFAULT_DECODER_VECTOR_DIM)
        )
        block_shape = list(
            manifest.get(
                "decoder_weight_block_shape",
                list(DEFAULT_DECODER_WEIGHT_BLOCK_SHAPE),
            )
        )
        block_elems = int(block_shape[0]) * int(block_shape[1])
        expected_lines = len(DEFAULT_DECODER_WEIGHT_ORDER) * block_elems
        legacy_scalar_lines = len(DEFAULT_DECODER_WEIGHT_ORDER)
        if len(normalized_weight_lines) != expected_lines:
            if len(normalized_weight_lines) == legacy_scalar_lines:
                expanded_weight_lines: List[str] = []
                zero_hex = fp16_to_hex(0.0)
                for encoded in normalized_weight_lines:
                    expanded_weight_lines.append(encoded)
                    for _ in range(block_elems - 1):
                        expanded_weight_lines.append(zero_hex)
                normalized_weight_lines = expanded_weight_lines
            else:
                raise ValueError(
                    "decoder_weights.memh line count does not match fixed decoder "
                    "weight order"
                )
        decoder_weight_blocks = {}
        decoder_weights = {}
        for block_idx, name in enumerate(DEFAULT_DECODER_WEIGHT_ORDER):
            start = block_idx * block_elems
            block_lines = normalized_weight_lines[start : start + block_elems]
            block_values = [fp16_from_hex(encoded) for encoded in block_lines]
            decoder_weight_blocks[name] = block_values
            decoder_weights[name] = block_values[0] if block_values else 0.0
        return cls(
            model_name=str(manifest["model_name"]),
            decoder_weights=decoder_weights,
            decoder_weight_blocks=decoder_weight_blocks,
            token_vocab={
                str(k): str(v)
                for k, v in read_json(
                    root / "python_frontend_tables" / "token_vocab.json"
                ).items()
            },
            draft_table={
                str(k): list(v)
                for k, v in read_json(
                    root / "python_frontend_tables" / "draft_table.json"
                ).items()
            },
            recompute_table={
                str(k): dict(v)
                for k, v in read_json(
                    root / "python_frontend_tables" / "recompute_table.json"
                ).items()
            },
            result_decode_table={
                str(k): int(v)
                for k, v in read_json(
                    root / "python_frontend_tables" / "result_decode_table.json"
                ).items()
            },
            data_width_bits=int(manifest["data_width_bits"]),
            draft_ports=int(manifest["draft_ports"]),
            decoder_vector_dim=vector_dim,
            decoder_weight_block_shape=block_shape,
            extra_metadata=dict(manifest.get("metadata", {})),
        )


def build_demo_toy_decoder_package() -> ToyDecoderPackage:
    return ToyDecoderPackage(
        model_name="stage2_demo_toy_decoder",
        decoder_weights={
            "q_proj": 1.0,
            "k_proj": 0.5,
            "v_proj": 0.75,
            "ffn_layer1": 1.25,
            "ffn_layer2": 1.5,
        },
        decoder_weight_blocks={
            "q_proj": [
                1.0, 0.0, 0.0, 0.0,
                0.0, 1.0, 0.0, 0.0,
                0.0, 0.0, 1.0, 0.0,
                0.0, 0.0, 0.0, 1.0,
            ],
            "k_proj": [
                0.5, 0.0, 0.0, 0.0,
                0.0, 0.5, 0.0, 0.0,
                0.0, 0.0, 0.5, 0.0,
                0.0, 0.0, 0.0, 0.5,
            ],
            "v_proj": [
                0.75, 0.0, 0.0, 0.0,
                0.0, 0.75, 0.0, 0.0,
                0.0, 0.0, 0.75, 0.0,
                0.0, 0.0, 0.0, 0.75,
            ],
            "ffn_layer1": [
                1.25, 0.0, 0.0, 0.0,
                0.0, 1.25, 0.0, 0.0,
                0.0, 0.0, 1.25, 0.0,
                0.0, 0.0, 0.0, 1.25,
            ],
            "ffn_layer2": [
                1.5, 0.0, 0.0, 0.0,
                0.0, 1.5, 0.0, 0.0,
                0.0, 0.0, 1.5, 0.0,
                0.0, 0.0, 0.0, 1.5,
            ],
        },
        token_vocab={
            "16": "<bos>",
            "17": "A",
            "18": "B",
            "19": "C",
            "20": "D",
        },
        draft_table={
            "16": [
                {
                    "parent_node_id": 5,
                    "token_id": 17,
                    "referenced_token_id": 16,
                    "referenced_position": 32,
                    "confidence": 200,
                }
            ],
            "16,17": [
                {
                    "parent_node_id": 5,
                    "token_id": 18,
                    "referenced_token_id": 17,
                    "referenced_position": 33,
                    "confidence": 180,
                }
            ],
        },
        recompute_table={
            "17@32": {
                "partial": False,
                "full": True,
                "req_id": 1,
                "kv_data_hex": "34" * 16,
                "last": True,
            }
        },
        result_decode_table={
            "4000": 17,
            "4200": 18,
            "4400": 19,
            "4600": 20,
        },
        extra_metadata={
            "source": "stage2_25_demo",
        },
    )
