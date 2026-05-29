import json
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT_ROOT = Path(__file__).resolve().parents[2]
if str(SCRIPT_ROOT) not in sys.path:
    sys.path.insert(0, str(SCRIPT_ROOT))


from rtl_backend.toy_decoder import build_demo_toy_decoder_package  # type: ignore


class ToyDecoderTest(unittest.TestCase):
    def test_export_layout_is_stable(self) -> None:
        package = build_demo_toy_decoder_package()

        with tempfile.TemporaryDirectory() as tmpdir:
            out_dir = Path(tmpdir) / "toy_decoder"
            package.save(out_dir)

            manifest = json.loads((out_dir / "manifest.json").read_text(encoding="utf-8"))
            self.assertEqual(manifest["format"], "toy_decoder_package")
            self.assertTrue((out_dir / "rtl_backend_weights" / "decoder_weights.memh").exists())
            self.assertTrue((out_dir / "python_frontend_tables" / "draft_table.json").exists())
            self.assertTrue((out_dir / "python_frontend_tables" / "result_decode_table.json").exists())
            self.assertEqual(manifest["decoder_vector_dim"], 4)
            self.assertEqual(manifest["decoder_weight_block_shape"], [4, 4])

            lines = (
                out_dir / "rtl_backend_weights" / "decoder_weights.memh"
            ).read_text(encoding="utf-8").strip().splitlines()
            self.assertEqual(len(lines), 80)

    def test_load_round_trip_preserves_decoder_weights_and_tables(self) -> None:
        package = build_demo_toy_decoder_package()

        with tempfile.TemporaryDirectory() as tmpdir:
            out_dir = Path(tmpdir) / "toy_decoder"
            package.save(out_dir)
            restored = package.load(out_dir)

            self.assertEqual(restored.model_name, package.model_name)
            self.assertEqual(
                restored.decoder_weight_blocks["q_proj"],
                package.decoder_weight_blocks["q_proj"],
            )
            self.assertEqual(
                restored.decoder_weight_blocks["ffn_layer2"],
                package.decoder_weight_blocks["ffn_layer2"],
            )
            self.assertEqual(restored.draft_table, package.draft_table)
            self.assertEqual(restored.recompute_table, package.recompute_table)
            self.assertEqual(
                restored.result_decode_table,
                package.result_decode_table,
            )
            self.assertEqual(restored.decoder_vector_dim, 4)

    def test_load_supports_legacy_scalar_weight_export_package(self) -> None:
        repo_root = Path(__file__).resolve().parents[4]
        legacy_dir = (
            repo_root / "tmp" / "real_weight_export_qwen_bf16_nondeps_verify"
        )

        restored = build_demo_toy_decoder_package().load(legacy_dir)

        self.assertEqual(restored.model_name, "Qwen/Qwen3-0.6B")
        self.assertEqual(restored.decoder_vector_dim, 4)
        self.assertEqual(restored.decoder_weight_block_shape, [4, 4])
        self.assertEqual(len(restored.decoder_weight_blocks["q_proj"]), 16)
        self.assertAlmostEqual(
            restored.decoder_weight_blocks["q_proj"][0],
            restored.decoder_weights["q_proj"],
        )
        self.assertEqual(
            restored.decoder_weight_blocks["q_proj"][1:],
            [0.0] * 15,
        )


if __name__ == "__main__":
    unittest.main()
