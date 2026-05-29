import json
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT_ROOT = Path(__file__).resolve().parents[2]
if str(SCRIPT_ROOT) not in sys.path:
    sys.path.insert(0, str(SCRIPT_ROOT))


from rtl_backend.run_single_chiplet_demo import main  # type: ignore
from rtl_backend.toy_decoder import build_demo_toy_decoder_package  # type: ignore


class RunSingleChipletDemoTest(unittest.TestCase):
    def test_cli_native_tree_demo_emits_nonzero_visible_mask(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            workdir = Path(tmpdir) / "cli_tree_demo"
            status = main(
                [
                    "--workdir",
                    str(workdir),
                    "--prompt-tokens",
                    "0x10,0x11",
                    "--sequence-id",
                    "cli-tree-seq-0",
                    "--include-native-tree",
                ]
            )

            self.assertEqual(status, 0)
            from rtl_backend.stimulus import StimulusCycle  # type: ignore

            stimulus_lines = (
                workdir / "stimulus" / "stimulus.memh"
            ).read_text(encoding="utf-8").splitlines()
            decoded_cycles = [StimulusCycle.from_memh_word(line) for line in stimulus_lines]
            native_cycles = [
                cycle for cycle in decoded_cycles if cycle.native_tree_request.valid
            ]
            self.assertTrue(native_cycles)
            self.assertNotEqual(native_cycles[0].visible_mask, 0)

    def test_cli_builds_demo_workdir(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            workdir = Path(tmpdir) / "cli_demo"
            status = main(
                [
                    "--workdir",
                    str(workdir),
                    "--prompt-tokens",
                    "0x10,0x11",
                    "--sequence-id",
                    "cli-seq-0",
                ]
            )

            self.assertEqual(status, 0)
            request_json = json.loads(
                (workdir / "sequence_request.json").read_text(encoding="utf-8")
            )
            self.assertEqual(request_json["sequence_id"], "cli-seq-0")
            self.assertTrue((workdir / "hbm_input" / "manifest.json").exists())

    def test_cli_can_consume_external_weight_package_dir(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            package_dir = Path(tmpdir) / "external_package"
            workdir = Path(tmpdir) / "cli_real_package"
            package = build_demo_toy_decoder_package()
            package.model_name = "external-demo-package"
            package.save(package_dir)

            status = main(
                [
                    "--workdir",
                    str(workdir),
                    "--prompt-tokens",
                    "0x10,0x11",
                    "--weight-package-dir",
                    str(package_dir),
                ]
            )

            self.assertEqual(status, 0)
            exported_manifest = json.loads(
                (
                    workdir / "weights" / "toy_decoder" / "manifest.json"
                ).read_text(encoding="utf-8")
            )
            self.assertEqual(exported_manifest["model_name"], "external-demo-package")


if __name__ == "__main__":
    unittest.main()
