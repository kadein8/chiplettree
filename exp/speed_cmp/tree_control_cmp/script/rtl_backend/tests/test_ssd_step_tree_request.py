import sys
import unittest
from pathlib import Path


SCRIPT_ROOT = Path(__file__).resolve().parents[2]
if str(SCRIPT_ROOT) not in sys.path:
    sys.path.insert(0, str(SCRIPT_ROOT))


from rtl_backend.ssd_step import sync_tree_step_like_to_payload  # type: ignore


class SyncTreeStepTreeRequestTest(unittest.TestCase):
    def test_single_step_tree_request_does_not_count_recovery_token_as_prefix_slot(self) -> None:
        empty_prompt_payload = sync_tree_step_like_to_payload(
            {
                "sequence_id": "tree-seq-empty-0",
                "prompt_token_ids": [],
                "step_index": 0,
                "recovery_token": 0x00,
                "speculated_tokens": [[0x0E]],
                "accepted_tokens": [0x00, 0x0E],
                "next_recovery_token": 0x0E,
                "tree_mask_en": False,
            }
        )
        self.assertEqual(empty_prompt_payload.native_tree_request.prefix_slot_valid, 0)
        self.assertEqual(
            empty_prompt_payload.native_tree_request.frontier_parent_node_ids_by_level[0][0],
            0,
        )
        self.assertEqual(
            empty_prompt_payload.native_tree_request.frontier_referenced_token_ids_by_level[0][0],
            0x00,
        )
        self.assertEqual(
            empty_prompt_payload.native_tree_request.frontier_referenced_position_ids_by_level[0][0],
            0,
        )

        one_prompt_payload = sync_tree_step_like_to_payload(
            {
                "sequence_id": "tree-seq-one-prompt-0",
                "prompt_token_ids": [0x10],
                "step_index": 1,
                "recovery_token": 0x12,
                "speculated_tokens": [[0x21]],
                "accepted_tokens": [0x12, 0x21],
                "next_recovery_token": 0x21,
                "tree_mask_en": False,
            }
        )
        self.assertEqual(one_prompt_payload.native_tree_request.prefix_slot_valid, 0b0001)
        self.assertEqual(one_prompt_payload.native_tree_request.prefix_node_ids[:1], [1])
        self.assertEqual(one_prompt_payload.native_tree_request.prefix_token_ids[:1], [0x10])
        self.assertEqual(
            one_prompt_payload.native_tree_request.prefix_position_ids[:1],
            [0],
        )
        self.assertEqual(
            one_prompt_payload.native_tree_request.frontier_parent_node_ids_by_level[0][0],
            1,
        )
        self.assertEqual(
            one_prompt_payload.native_tree_request.frontier_referenced_token_ids_by_level[0][0],
            0x12,
        )
        self.assertEqual(
            one_prompt_payload.native_tree_request.frontier_referenced_position_ids_by_level[0][0],
            1,
        )

    def test_nested_branch_tree_request_is_materialized_into_multi_level_native_tree(self) -> None:
        payload = sync_tree_step_like_to_payload(
            {
                "sequence_id": "tree-seq-0",
                "prompt_token_ids": [0x10, 0x11],
                "step_index": 2,
                "recovery_token": 0x12,
                "speculated_tokens": [
                    [0x21, 0x31, 0x41, 0x51],
                    [0x22, 0x32],
                    [0x23],
                    [0x24, 0x34, 0x44],
                ],
                "accepted_tokens": [0x12, 0x21],
                "next_recovery_token": 0x30,
                "tree_parent_map": {
                    "3": 2,
                    "4": 2,
                    "5": 2,
                    "6": 2,
                    "7": 3,
                    "8": 4,
                    "9": 6,
                    "10": 7,
                    "11": 9,
                    "12": 10,
                },
                "shared_prefix_nodes": [2],
            }
        )

        self.assertEqual(payload.native_tree_request.prefix_slot_valid, 0b0011)
        self.assertEqual(payload.native_tree_request.committed_len, 3)
        self.assertEqual(payload.native_tree_request.draft_count, 10)
        self.assertEqual(payload.native_tree_request.branch_count, 4)
        self.assertEqual(payload.native_tree_request.prefix_node_ids[:2], [1, 2])
        self.assertEqual(
            payload.native_tree_request.prefix_token_ids[:2],
            [0x10, 0x11],
        )
        self.assertEqual(
            payload.native_tree_request.prefix_position_ids[:2],
            [0, 1],
        )
        self.assertEqual(payload.native_tree_request.frontier_level_valid, 0b00_1111)
        self.assertEqual(
            payload.native_tree_request.frontier_slot_valid_by_level[:4],
            [0b1111, 0b1011, 0b1001, 0b0001],
        )
        self.assertEqual(
            payload.native_tree_request.frontier_tree_mask_en_by_level[:4],
            [0b1111, 0b1011, 0b1001, 0b0001],
        )
        self.assertEqual(
            payload.native_tree_request.frontier_node_ids_by_level[0][:4],
            [3, 4, 5, 6],
        )
        self.assertEqual(
            payload.native_tree_request.frontier_parent_node_ids_by_level[1][:4],
            [3, 4, 0, 6],
        )
        self.assertEqual(
            payload.native_tree_request.frontier_parent_node_ids_by_level[3][0],
            10,
        )
        self.assertEqual(
            payload.native_tree_request.frontier_token_ids_by_level[0][:4],
            [0x21, 0x22, 0x23, 0x24],
        )
        self.assertEqual(
            payload.native_tree_request.frontier_referenced_token_ids_by_level[0][:4],
            [0x12, 0x12, 0x12, 0x12],
        )
        self.assertEqual(
            payload.native_tree_request.frontier_token_ids_by_level[1][:4],
            [0x31, 0x32, 0x00, 0x34],
        )
        self.assertEqual(
            payload.native_tree_request.frontier_referenced_token_ids_by_level[1][:4],
            [0x21, 0x22, 0x00, 0x24],
        )
        self.assertEqual(
            payload.native_tree_request.frontier_position_ids_by_level[0][:4],
            [3, 3, 3, 3],
        )
        self.assertEqual(
            payload.native_tree_request.frontier_referenced_position_ids_by_level[0][:4],
            [2, 2, 2, 2],
        )
        self.assertEqual(
            payload.native_tree_request.frontier_position_ids_by_level[3][0],
            6,
        )
        self.assertEqual(
            payload.native_tree_request.frontier_referenced_position_ids_by_level[3][0],
            5,
        )
        self.assertEqual(
            payload.native_tree_request.frontier_branch_ids_by_level[1][:4],
            [0, 1, 0, 3],
        )
        self.assertEqual(
            payload.native_tree_request.frontier_level_ids_by_level[2][:4],
            [2, 0, 0, 2],
        )

    def test_tree_request_can_explicitly_disable_tree_mask_for_single_step_slots(self) -> None:
        payload = sync_tree_step_like_to_payload(
            {
                "sequence_id": "tree-seq-single-step-0",
                "prompt_token_ids": [0x10, 0x11],
                "step_index": 3,
                "recovery_token": 0x12,
                "speculated_tokens": [[0x21]],
                "accepted_tokens": [0x12, 0x21],
                "next_recovery_token": 0x30,
                "tree_mask_en": False,
            }
        )

        self.assertEqual(
            payload.native_tree_request.frontier_slot_valid_by_level[:1],
            [0b0001],
        )
        self.assertEqual(
            payload.native_tree_request.frontier_tree_mask_en_by_level[:1],
            [0b0000],
        )

    def test_branch_parallel_verify_group_request_preserves_real_referenced_positions(self) -> None:
        payload = sync_tree_step_like_to_payload(
            {
                "sequence_id": "tree-seq-verify-group-0",
                "prompt_token_ids": [0x10, 0x11],
                "step_index": 2,
                "recovery_token": 0x12,
                "speculated_tokens": [
                    [0x21, 0x31, 0x41, 0x51],
                    [0x22, 0x32, 0x42, 0x52],
                    [0x23, 0x33, 0x43, 0x53],
                    [0x24, 0x34, 0x44, 0x54],
                ],
            }
        )

        self.assertEqual(payload.native_tree_request.committed_len, 3)
        self.assertEqual(payload.native_tree_request.draft_count, 16)
        self.assertEqual(payload.native_tree_request.branch_count, 4)
        self.assertEqual(payload.native_tree_request.frontier_level_valid, 0b00_1111)
        self.assertEqual(
            payload.native_tree_request.frontier_branch_ids_by_level[0][:4],
            [0, 1, 2, 3],
        )
        self.assertEqual(
            payload.native_tree_request.frontier_level_ids_by_level[3][:4],
            [3, 3, 3, 3],
        )
        self.assertEqual(
            payload.native_tree_request.frontier_position_ids_by_level[0][:4],
            [3, 3, 3, 3],
        )
        self.assertEqual(
            payload.native_tree_request.frontier_position_ids_by_level[3][:4],
            [6, 6, 6, 6],
        )
        self.assertEqual(
            payload.native_tree_request.frontier_referenced_position_ids_by_level[0][:4],
            [2, 2, 2, 2],
        )
        self.assertEqual(
            payload.native_tree_request.frontier_referenced_position_ids_by_level[1][:4],
            [3, 3, 3, 3],
        )
        self.assertEqual(
            payload.native_tree_request.frontier_referenced_position_ids_by_level[3][:4],
            [5, 5, 5, 5],
        )

    def test_branch_parallel_verify_group_request_uses_per_branch_parent_chains(self) -> None:
        payload = sync_tree_step_like_to_payload(
            {
                "sequence_id": "tree-seq-verify-group-1",
                "prompt_token_ids": [0x10, 0x11],
                "step_index": 2,
                "recovery_token": 0x12,
                "speculated_tokens": [
                    [0x21, 0x31, 0x41, 0x51],
                    [0x22, 0x32, 0x42, 0x52],
                    [0x23, 0x33, 0x43, 0x53],
                    [0x24, 0x34, 0x44, 0x54],
                ],
            }
        )

        self.assertEqual(
            payload.native_tree_request.frontier_node_ids_by_level[0][:4],
            [3, 4, 5, 6],
        )
        self.assertEqual(
            payload.native_tree_request.frontier_parent_node_ids_by_level[0][:4],
            [2, 2, 2, 2],
        )
        self.assertEqual(
            payload.native_tree_request.frontier_node_ids_by_level[1][:4],
            [7, 8, 9, 10],
        )
        self.assertEqual(
            payload.native_tree_request.frontier_parent_node_ids_by_level[1][:4],
            [3, 4, 5, 6],
        )
        self.assertEqual(
            payload.native_tree_request.frontier_node_ids_by_level[2][:4],
            [11, 12, 13, 14],
        )
        self.assertEqual(
            payload.native_tree_request.frontier_parent_node_ids_by_level[2][:4],
            [7, 8, 9, 10],
        )
        self.assertEqual(
            payload.native_tree_request.frontier_node_ids_by_level[3][:4],
            [15, 16, 17, 18],
        )
        self.assertEqual(
            payload.native_tree_request.frontier_parent_node_ids_by_level[3][:4],
            [11, 12, 13, 14],
        )


if __name__ == "__main__":
    unittest.main()
