import json
import struct
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock


SCRIPT_ROOT = Path(__file__).resolve().parents[2]
if str(SCRIPT_ROOT) not in sys.path:
    sys.path.insert(0, str(SCRIPT_ROOT))


from rtl_backend.formats import fp16_to_hex  # type: ignore
from rtl_backend.real_weight_export import (  # type: ignore
    build_real_weight_package_from_fixture_json,
    main,
)


class RealWeightExportTest(unittest.TestCase):
    @staticmethod
    def _encode_bf16(value: float) -> bytes:
        bits32 = struct.unpack("<I", struct.pack("<f", value))[0]
        bits16 = (bits32 >> 16) & 0xFFFF
        return struct.pack("<H", bits16)

    @staticmethod
    def _padded_block_lines(values):
        padded = list(values[:16])
        while len(padded) < 16:
            padded.append(0.0)
        return [fp16_to_hex(value) for value in padded]

    def test_cli_exports_package_from_bf16_safetensors_without_optional_deps(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            model_dir = Path(tmpdir) / "tiny_qwen_model"
            model_dir.mkdir(parents=True, exist_ok=True)
            safetensors_path = model_dir / "model.safetensors"

            header = {
                "model.layers.0.self_attn.q_proj.weight": {
                    "dtype": "BF16",
                    "shape": [1, 1],
                    "data_offsets": [0, 2],
                },
                "model.layers.0.self_attn.k_proj.weight": {
                    "dtype": "BF16",
                    "shape": [1, 1],
                    "data_offsets": [2, 4],
                },
                "model.layers.0.self_attn.v_proj.weight": {
                    "dtype": "BF16",
                    "shape": [1, 1],
                    "data_offsets": [4, 6],
                },
                "model.layers.0.mlp.up_proj.weight": {
                    "dtype": "BF16",
                    "shape": [1, 1],
                    "data_offsets": [6, 8],
                },
                "model.layers.0.mlp.down_proj.weight": {
                    "dtype": "BF16",
                    "shape": [1, 1],
                    "data_offsets": [8, 10],
                },
            }
            header_bytes = json.dumps(header, separators=(",", ":")).encode("utf-8")
            data_bytes = b"".join(
                [
                    self._encode_bf16(0.5),
                    self._encode_bf16(-1.0),
                    self._encode_bf16(1.5),
                    self._encode_bf16(2.0),
                    self._encode_bf16(-2.5),
                ]
            )
            safetensors_path.write_bytes(
                len(header_bytes).to_bytes(8, byteorder="little")
                + header_bytes
                + data_bytes
            )

            out_dir = Path(tmpdir) / "bf16_safetensors_package"
            with mock.patch.dict(sys.modules, {"safetensors": None}):
                status = main(
                    [
                        "--model-path",
                        str(model_dir),
                        "--out-dir",
                        str(out_dir),
                    ]
                )

            self.assertEqual(status, 0)
            weight_lines = (
                out_dir / "rtl_backend_weights" / "decoder_weights.memh"
            ).read_text(encoding="utf-8").splitlines()
            self.assertEqual(
                weight_lines,
                self._padded_block_lines([0.5])
                + self._padded_block_lines([-1.0])
                + self._padded_block_lines([1.5])
                + self._padded_block_lines([2.0])
                + self._padded_block_lines([-2.5]),
            )
            manifest = json.loads((out_dir / "manifest.json").read_text(encoding="utf-8"))
            self.assertEqual(manifest["decoder_vector_dim"], 4)
            self.assertEqual(manifest["decoder_weight_block_shape"], [4, 4])

    def test_cli_exports_package_from_safetensors_without_optional_deps(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            model_dir = Path(tmpdir) / "tiny_llama_model"
            model_dir.mkdir(parents=True, exist_ok=True)
            safetensors_path = model_dir / "model.safetensors"

            header = {
                "model.layers.0.self_attn.q_proj.weight": {
                    "dtype": "F16",
                    "shape": [1, 1],
                    "data_offsets": [0, 2],
                },
                "model.layers.0.self_attn.k_proj.weight": {
                    "dtype": "F16",
                    "shape": [1, 1],
                    "data_offsets": [2, 4],
                },
                "model.layers.0.self_attn.v_proj.weight": {
                    "dtype": "F16",
                    "shape": [1, 1],
                    "data_offsets": [4, 6],
                },
                "model.layers.0.mlp.up_proj.weight": {
                    "dtype": "F16",
                    "shape": [1, 1],
                    "data_offsets": [6, 8],
                },
                "model.layers.0.mlp.down_proj.weight": {
                    "dtype": "F16",
                    "shape": [1, 1],
                    "data_offsets": [8, 10],
                },
            }
            header_bytes = json.dumps(header, separators=(",", ":")).encode("utf-8")
            data_bytes = b"".join(
                [
                    struct.pack("<e", 0.3125),
                    struct.pack("<e", -0.625),
                    struct.pack("<e", 0.875),
                    struct.pack("<e", 1.5),
                    struct.pack("<e", -2.0),
                ]
            )
            safetensors_path.write_bytes(
                len(header_bytes).to_bytes(8, byteorder="little")
                + header_bytes
                + data_bytes
            )

            out_dir = Path(tmpdir) / "safetensors_package"
            status = main(
                [
                    "--model-path",
                    str(model_dir),
                    "--out-dir",
                    str(out_dir),
                ]
            )

            self.assertEqual(status, 0)
            weight_lines = (
                out_dir / "rtl_backend_weights" / "decoder_weights.memh"
            ).read_text(encoding="utf-8").splitlines()
            self.assertEqual(
                weight_lines,
                self._padded_block_lines([0.3125])
                + self._padded_block_lines([-0.625])
                + self._padded_block_lines([0.875])
                + self._padded_block_lines([1.5])
                + self._padded_block_lines([-2.0]),
            )
            manifest = json.loads((out_dir / "manifest.json").read_text(encoding="utf-8"))
            self.assertEqual(manifest["metadata"]["source_kind"], "model_path")
            self.assertEqual(manifest["decoder_vector_dim"], 4)
            self.assertEqual(manifest["decoder_weight_block_shape"], [4, 4])

    def test_cli_exports_package_when_safetensors_imports_but_torch_is_missing(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            model_dir = Path(tmpdir) / "tiny_llama_model"
            model_dir.mkdir(parents=True, exist_ok=True)
            safetensors_path = model_dir / "model.safetensors"

            header = {
                "model.layers.0.self_attn.q_proj.weight": {
                    "dtype": "F16",
                    "shape": [1, 1],
                    "data_offsets": [0, 2],
                },
                "model.layers.0.self_attn.k_proj.weight": {
                    "dtype": "F16",
                    "shape": [1, 1],
                    "data_offsets": [2, 4],
                },
                "model.layers.0.self_attn.v_proj.weight": {
                    "dtype": "F16",
                    "shape": [1, 1],
                    "data_offsets": [4, 6],
                },
                "model.layers.0.mlp.up_proj.weight": {
                    "dtype": "F16",
                    "shape": [1, 1],
                    "data_offsets": [6, 8],
                },
                "model.layers.0.mlp.down_proj.weight": {
                    "dtype": "F16",
                    "shape": [1, 1],
                    "data_offsets": [8, 10],
                },
            }
            header_bytes = json.dumps(header, separators=(",", ":")).encode("utf-8")
            data_bytes = b"".join(
                [
                    struct.pack("<e", 0.3125),
                    struct.pack("<e", -0.625),
                    struct.pack("<e", 0.875),
                    struct.pack("<e", 1.5),
                    struct.pack("<e", -2.0),
                ]
            )
            safetensors_path.write_bytes(
                len(header_bytes).to_bytes(8, byteorder="little")
                + header_bytes
                + data_bytes
            )

            fake_safetensors = types.ModuleType("safetensors")

            def fake_safe_open(*args, **kwargs):
                raise ModuleNotFoundError("No module named 'torch'")

            fake_safetensors.safe_open = fake_safe_open
            out_dir = Path(tmpdir) / "safetensors_package"

            with mock.patch.dict(sys.modules, {"safetensors": fake_safetensors}):
                status = main(
                    [
                        "--model-path",
                        str(model_dir),
                        "--out-dir",
                        str(out_dir),
                    ]
                )

            self.assertEqual(status, 0)
            weight_lines = (
                out_dir / "rtl_backend_weights" / "decoder_weights.memh"
            ).read_text(encoding="utf-8").splitlines()
            self.assertEqual(
                weight_lines,
                self._padded_block_lines([0.3125])
                + self._padded_block_lines([-0.625])
                + self._padded_block_lines([0.875])
                + self._padded_block_lines([1.5])
                + self._padded_block_lines([-2.0]),
            )

    def test_fixture_json_exports_real_weight_package(self) -> None:
        fixture = {
            "model_name": "tiny-real-llama-fixture",
            "state_dict": {
                "model.layers.0.self_attn.q_proj.weight": [
                    [0.25, 0.5, 0.75, 1.0],
                    [1.25, 1.5, 1.75, 2.0],
                    [2.25, 2.5, 2.75, 3.0],
                    [3.25, 3.5, 3.75, 4.0],
                ],
                "model.layers.0.self_attn.k_proj.weight": [
                    [-0.5, -0.75, -1.0, -1.25],
                    [-1.5, -1.75, -2.0, -2.25],
                    [-2.5, -2.75, -3.0, -3.25],
                    [-3.5, -3.75, -4.0, -4.25],
                ],
                "model.layers.0.self_attn.v_proj.weight": [
                    [0.75, 1.0, 1.25, 1.5],
                    [1.75, 2.0, 2.25, 2.5],
                    [2.75, 3.0, 3.25, 3.5],
                    [3.75, 4.0, 4.25, 4.5],
                ],
                "model.layers.0.mlp.up_proj.weight": [
                    [1.25, 1.5, 1.75, 2.0],
                    [2.25, 2.5, 2.75, 3.0],
                    [3.25, 3.5, 3.75, 4.0],
                    [4.25, 4.5, 4.75, 5.0],
                ],
                "model.layers.0.mlp.down_proj.weight": [
                    [-1.5, -1.75, -2.0, -2.25],
                    [-2.5, -2.75, -3.0, -3.25],
                    [-3.5, -3.75, -4.0, -4.25],
                    [-4.5, -4.75, -5.0, -5.25],
                ],
            },
        }

        with tempfile.TemporaryDirectory() as tmpdir:
            fixture_path = Path(tmpdir) / "state_dict_fixture.json"
            fixture_path.write_text(
                json.dumps(fixture, ensure_ascii=False, indent=2) + "\n",
                encoding="utf-8",
            )

            package = build_real_weight_package_from_fixture_json(fixture_path)
            self.assertEqual(package.model_name, "tiny-real-llama-fixture")
            self.assertEqual(package.decoder_weight_blocks["q_proj"][:4], [0.25, 0.5, 0.75, 1.0])
            self.assertEqual(package.decoder_weight_blocks["k_proj"][:4], [-0.5, -0.75, -1.0, -1.25])
            self.assertEqual(package.decoder_weight_blocks["v_proj"][:4], [0.75, 1.0, 1.25, 1.5])
            self.assertEqual(package.decoder_weight_blocks["ffn_layer1"][:4], [1.25, 1.5, 1.75, 2.0])
            self.assertEqual(package.decoder_weight_blocks["ffn_layer2"][:4], [-1.5, -1.75, -2.0, -2.25])
            self.assertEqual(package.decoder_vector_dim, 4)

            out_dir = Path(tmpdir) / "exported_package"
            package.save(out_dir)
            weight_lines = (
                out_dir / "rtl_backend_weights" / "decoder_weights.memh"
            ).read_text(encoding="utf-8").splitlines()
            self.assertEqual(
                weight_lines[:16],
                [fp16_to_hex(value) for value in package.decoder_weight_blocks["q_proj"]],
            )
            self.assertEqual(len(weight_lines), 80)

    def test_cli_exports_package_from_fixture_json(self) -> None:
        fixture = {
            "model_name": "tiny-real-cli-fixture",
            "state_dict": {
                "model.layers.0.self_attn.q_proj.weight": [[0.125]],
                "model.layers.0.self_attn.k_proj.weight": [[0.25]],
                "model.layers.0.self_attn.v_proj.weight": [[0.5]],
                "model.layers.0.mlp.up_proj.weight": [[1.0]],
                "model.layers.0.mlp.down_proj.weight": [[2.0]],
            },
        }

        with tempfile.TemporaryDirectory() as tmpdir:
            fixture_path = Path(tmpdir) / "fixture.json"
            out_dir = Path(tmpdir) / "package"
            fixture_path.write_text(
                json.dumps(fixture, ensure_ascii=False, indent=2) + "\n",
                encoding="utf-8",
            )

            status = main(
                [
                    "--fixture-json",
                    str(fixture_path),
                    "--out-dir",
                    str(out_dir),
                ]
            )

            self.assertEqual(status, 0)
            manifest = json.loads((out_dir / "manifest.json").read_text(encoding="utf-8"))
            self.assertEqual(manifest["model_name"], "tiny-real-cli-fixture")
            self.assertEqual(
                manifest["metadata"]["source_kind"],
                "fixture_json",
            )
            self.assertEqual(manifest["decoder_vector_dim"], 4)
            self.assertEqual(manifest["decoder_weight_block_shape"], [4, 4])


if __name__ == "__main__":
    unittest.main()
