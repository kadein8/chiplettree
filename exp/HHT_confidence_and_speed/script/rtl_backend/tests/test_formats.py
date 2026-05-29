import sys
import unittest
from pathlib import Path


SCRIPT_ROOT = Path(__file__).resolve().parents[2]
if str(SCRIPT_ROOT) not in sys.path:
    sys.path.insert(0, str(SCRIPT_ROOT))


from rtl_backend.formats import (  # type: ignore
    DEFAULT_DECODER_WEIGHT_ORDER,
    DEFAULT_HBM_REGION_NAMES,
    build_default_hbm_layout,
    build_default_toy_weight_manifest,
    fp16_to_hex,
)


class FormatsTest(unittest.TestCase):
    def test_default_hbm_layout_regions_are_stable(self) -> None:
        layout = build_default_hbm_layout()
        self.assertEqual([region.name for region in layout.regions], DEFAULT_HBM_REGION_NAMES)
        self.assertEqual(layout.beat_bytes, 32)
        for region in layout.regions:
            self.assertEqual(region.base % layout.beat_bytes, 0)
            self.assertEqual(region.size % layout.beat_bytes, 0)

    def test_default_toy_weight_manifest_matches_fixed_order(self) -> None:
        manifest = build_default_toy_weight_manifest(model_name="unit-test-toy")
        self.assertEqual(manifest["format"], "toy_decoder_package")
        self.assertEqual(manifest["version"], 1)
        self.assertEqual(manifest["model_name"], "unit-test-toy")
        self.assertEqual(manifest["decoder_weight_order"], DEFAULT_DECODER_WEIGHT_ORDER)
        self.assertEqual(manifest["weight_encoding"], "fp16_hex")

    def test_fp16_to_hex_returns_four_hex_digits(self) -> None:
        encoded = fp16_to_hex(1.0)
        self.assertEqual(encoded, "3c00")


if __name__ == "__main__":
    unittest.main()
