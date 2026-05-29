import json
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT_ROOT = Path(__file__).resolve().parents[2]
if str(SCRIPT_ROOT) not in sys.path:
    sys.path.insert(0, str(SCRIPT_ROOT))


from rtl_backend.hbm_image import HbmImage  # type: ignore


class HbmImageTest(unittest.TestCase):
    def test_sparse_image_round_trip(self) -> None:
        image = HbmImage.default()
        image.write_region_hex("WEIGHT", 0, "11" * 32, note="weight beat")
        image.write_region_hex("KV", 32, "22" * 32, note="kv beat")

        with tempfile.TemporaryDirectory() as tmpdir:
            out_dir = Path(tmpdir) / "image"
            image.save(out_dir)

            manifest = json.loads((out_dir / "manifest.json").read_text(encoding="utf-8"))
            self.assertEqual(manifest["format"], "stage2_hbm_image")
            self.assertTrue((out_dir / "regions" / "WEIGHT.jsonl").exists())
            self.assertTrue((out_dir / "regions" / "KV.jsonl").exists())

            restored = HbmImage.load(out_dir)
            self.assertEqual(restored.read_hex("WEIGHT", 0), "11" * 32)
            self.assertEqual(restored.read_hex("KV", 32), "22" * 32)


if __name__ == "__main__":
    unittest.main()
