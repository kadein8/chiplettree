import json
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT_ROOT = Path(__file__).resolve().parents[2]
if str(SCRIPT_ROOT) not in sys.path:
    sys.path.insert(0, str(SCRIPT_ROOT))


from rtl_backend.ssd_bridge import (  # type: ignore
    SequencePrompt,
    build_demo_artifacts_from_sequence,
)
from rtl_backend.stimulus import StimulusCycle  # type: ignore


class SsdBridgeTest(unittest.TestCase):
    def test_sequence_bridge_writes_request_and_artifacts(self) -> None:
        request = SequencePrompt(
            sequence_id="seq-demo-0",
            prompt_token_ids=[0x10, 0x11],
            max_new_tokens=4,
        )

        with tempfile.TemporaryDirectory() as tmpdir:
            workdir = Path(tmpdir) / "sequence_demo"
            build_demo_artifacts_from_sequence(
                workdir,
                request,
                include_native_tree=True,
            )

            request_json = json.loads(
                (workdir / "sequence_request.json").read_text(encoding="utf-8")
            )
            self.assertEqual(request_json["sequence_id"], "seq-demo-0")
            self.assertEqual(request_json["prompt_token_ids"], [16, 17])
            self.assertTrue((workdir / "stimulus" / "stimulus.memh").exists())
            self.assertTrue((workdir / "weights" / "toy_decoder" / "manifest.json").exists())

            stimulus_lines = (
                workdir / "stimulus" / "stimulus.memh"
            ).read_text(encoding="utf-8").splitlines()
            native_cycles = [
                StimulusCycle.from_memh_word(line)
                for line in stimulus_lines
                if StimulusCycle.from_memh_word(line).native_tree_request.valid
            ]
            self.assertTrue(native_cycles)
            self.assertEqual(native_cycles[0].native_tree_request.prefix_node_ids[:2], [0x1, 0x2])
            self.assertEqual(
                native_cycles[0].native_tree_request.prefix_token_ids[:2],
                [0x10, 0x11],
            )


if __name__ == "__main__":
    unittest.main()
