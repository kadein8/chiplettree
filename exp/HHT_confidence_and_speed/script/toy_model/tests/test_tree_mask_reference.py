import sys
import unittest
from pathlib import Path

import numpy as np


SCRIPT_ROOT = Path(__file__).resolve().parents[2]
if str(SCRIPT_ROOT) not in sys.path:
    sys.path.insert(0, str(SCRIPT_ROOT))


from toy_model.toy_model_reference import (  # type: ignore
    MAX_SEQ_LEN,
    NUM_HEADS,
    HEAD_DIM,
    N_LAYERS,
    build_visible_masks,
    build_weights,
    run_reference,
    run_tree_masked_reference,
)


class TreeMaskReferenceTest(unittest.TestCase):
    def test_build_visible_masks_follows_parent_chain(self) -> None:
        masks = build_visible_masks(
            tree_descriptor={
                "prefix_len": 2,
                "query_node_ids": [3, 4, 7],
                "draft_parent": {3: 2, 4: 2, 5: 3, 6: 4, 7: 5},
            },
            committed_len=2,
            visible_mask_len=MAX_SEQ_LEN,
        )

        self.assertEqual(masks[3][:6].tolist(), [1, 1, 1, 0, 0, 0])
        self.assertEqual(masks[4][:6].tolist(), [1, 1, 0, 1, 0, 0])
        self.assertEqual(masks[7][:8].tolist(), [1, 1, 1, 0, 1, 0, 1, 0])

    def test_build_visible_masks_prefers_explicit_position_ids(self) -> None:
        masks = build_visible_masks(
            tree_descriptor={
                "prefix_len": 2,
                "query_node_ids": [13],
                "draft_parent": {11: 2, 13: 11},
                "draft_position": {11: 4, 13: 6},
            },
            committed_len=2,
            visible_mask_len=MAX_SEQ_LEN,
        )

        self.assertEqual(masks[13][:8].tolist(), [1, 1, 0, 0, 1, 0, 1, 0])

    def test_tree_masked_reference_matches_causal_reference_for_full_visibility(self) -> None:
        weights = build_weights()
        kv_cache_k = np.zeros(
            (N_LAYERS, MAX_SEQ_LEN, NUM_HEADS, HEAD_DIM), dtype=np.float16
        )
        kv_cache_v = np.zeros(
            (N_LAYERS, MAX_SEQ_LEN, NUM_HEADS, HEAD_DIM), dtype=np.float16
        )

        _, kv_cache_k, kv_cache_v = run_reference(
            weights,
            token_id=0,
            position=0,
            kv_cache_k=kv_cache_k,
            kv_cache_v=kv_cache_v,
        )
        causal_step, _, _ = run_reference(
            weights,
            token_id=1,
            position=1,
            kv_cache_k=kv_cache_k.copy(),
            kv_cache_v=kv_cache_v.copy(),
        )

        full_mask = np.zeros((MAX_SEQ_LEN,), dtype=np.uint8)
        full_mask[:2] = 1
        masked_outputs, _, _ = run_tree_masked_reference(
            weights=weights,
            token_ids=[1],
            positions=[1],
            kv_cache_k=kv_cache_k.copy(),
            kv_cache_v=kv_cache_v.copy(),
            visible_masks=[full_mask],
        )

        np.testing.assert_allclose(
            masked_outputs["final_hiddens"][0].astype(np.float32),
            causal_step["final_hidden"].astype(np.float32),
            rtol=1e-3,
            atol=1e-3,
        )


if __name__ == "__main__":
    unittest.main()
