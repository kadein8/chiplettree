import sys
import unittest
from pathlib import Path


SCRIPT_ROOT = Path(__file__).resolve().parents[2]
if str(SCRIPT_ROOT) not in sys.path:
    sys.path.insert(0, str(SCRIPT_ROOT))


from rtl_backend.stimulus import (  # type: ignore
    DraftCandidate,
    HbmResponse,
    NativeTreeRequest,
    RecomputeResponse,
    StimulusCycle,
)


class StimulusTest(unittest.TestCase):
    def test_stimulus_cycle_pack_round_trip(self) -> None:
        cycle = StimulusCycle(
            cfg_valid=True,
            cfg_data=0x0000_0001,
            start=True,
            draft_candidates=[
                DraftCandidate(
                    valid=True,
                    parent_node_id=5,
                    token_id=0x1001,
                    referenced_token_id=0x1000,
                    referenced_position=0x020,
                    confidence=200,
                )
            ],
            tree_window_ready=True,
            recompute_req_ready=True,
            recompute_response=RecomputeResponse(
                valid=True,
                partial=False,
                full=True,
                req_id=3,
                kv_data_hex="34" * 16,
                last=True,
            ),
            wb_ready=True,
            hbm_response=HbmResponse(
                valid=True,
                req_id=2,
                data_hex="56" * 32,
            ),
        )

        packed = cycle.to_memh_word()
        restored = StimulusCycle.from_memh_word(packed)

        self.assertEqual(restored.cfg_data, 0x0000_0001)
        self.assertTrue(restored.start)
        self.assertEqual(restored.draft_candidates[0].token_id, 0x1001)
        self.assertTrue(restored.recompute_response.full)
        self.assertEqual(restored.hbm_response.data_hex, "56" * 32)

    def test_stimulus_cycle_round_trip_with_native_tree_request(self) -> None:
        request = NativeTreeRequest(
            valid=True,
            req_id=0xD,
            prefix_slot_valid=0b0011,
            committed_len=3,
            draft_count=11,
            branch_count=4,
            prefix_node_ids=[0x1, 0x2],
            prefix_token_ids=[0x101, 0x102],
            prefix_position_ids=[0x011, 0x012],
            frontier_level_valid=0b11_1111,
            frontier_slot_valid_by_level=[
                0b0011,
                0b0011,
                0b0101,
                0b1001,
                0b0001,
                0b0001,
            ],
            frontier_tree_mask_en_by_level=[
                0b0011,
                0b0011,
                0b0101,
                0b1001,
                0b0000,
                0b0000,
            ],
            frontier_node_ids_by_level=[
                [0x3, 0x4],
                [0x5, 0x6],
                [0x7, 0x8, 0x9],
                [0xA, 0xB],
                [0xC],
                [0xD],
            ],
            frontier_parent_node_ids_by_level=[
                [0x2, 0x2],
                [0x3, 0x4],
                [0x5, 0x6, 0x6],
                [0x7, 0x8],
                [0xA],
                [0xC],
            ],
            frontier_token_ids_by_level=[
                [0x201, 0x202],
                [0x203, 0x204],
                [0x205, 0x206, 0x207],
                [0x208, 0x209],
                [0x20A],
                [0x20B],
            ],
            frontier_referenced_token_ids_by_level=[
                [0x102, 0x102],
                [0x201, 0x202],
                [0x203, 0x204, 0x204],
                [0x205, 0x206],
                [0x208],
                [0x20A],
            ],
            frontier_position_ids_by_level=[
                [0x021, 0x022],
                [0x023, 0x024],
                [0x025, 0x026, 0x027],
                [0x028, 0x029],
                [0x02A],
                [0x02B],
            ],
            frontier_referenced_position_ids_by_level=[
                [0x012, 0x012],
                [0x021, 0x022],
                [0x023, 0x024, 0x024],
                [0x025, 0x026],
                [0x028],
                [0x02A],
            ],
            frontier_branch_ids_by_level=[
                [0x0, 0x1],
                [0x0, 0x1],
                [0x0, 0x1, 0x2],
                [0x0, 0x1],
                [0x0],
                [0x0],
            ],
            frontier_level_ids_by_level=[
                [0x0, 0x0],
                [0x1, 0x1],
                [0x2, 0x2, 0x2],
                [0x3, 0x3],
                [0x4],
                [0x5],
            ],
        )
        cycle = StimulusCycle(
            cfg_valid=True,
            cfg_data=0x0000_0002,
            start=True,
            draft_candidates=[],
            tree_window_ready=True,
            recompute_req_ready=True,
            wb_ready=True,
            native_tree_request=request,
        )

        restored = StimulusCycle.from_memh_word(cycle.to_memh_word())

        self.assertTrue(restored.native_tree_request.valid)
        self.assertEqual(restored.native_tree_request.req_id, 0xD)
        self.assertEqual(restored.native_tree_request.committed_len, 3)
        self.assertEqual(restored.native_tree_request.draft_count, 11)
        self.assertEqual(restored.native_tree_request.branch_count, 4)
        self.assertEqual(restored.native_tree_request.prefix_slot_valid & 0b0011, 0b0011)
        self.assertEqual(restored.native_tree_request.prefix_node_ids[:2], [0x1, 0x2])
        self.assertEqual(
            restored.native_tree_request.prefix_token_ids[:2],
            [0x101, 0x102],
        )
        self.assertEqual(
            restored.native_tree_request.prefix_position_ids[:2],
            [0x011, 0x012],
        )
        self.assertEqual(
            restored.native_tree_request.frontier_slot_valid_by_level[:6],
            [0b0011, 0b0011, 0b0101, 0b1001, 0b0001, 0b0001],
        )
        self.assertEqual(
            restored.native_tree_request.frontier_tree_mask_en_by_level[:6],
            [0b0011, 0b0011, 0b0101, 0b1001, 0b0000, 0b0000],
        )
        self.assertEqual(
            restored.native_tree_request.frontier_node_ids_by_level[0][:2],
            [0x3, 0x4],
        )
        self.assertEqual(
            restored.native_tree_request.frontier_parent_node_ids_by_level[1][:2],
            [0x3, 0x4],
        )
        self.assertEqual(
            restored.native_tree_request.frontier_node_ids_by_level[4][:1],
            [0xC],
        )
        self.assertEqual(
            restored.native_tree_request.frontier_parent_node_ids_by_level[5][:1],
            [0xC],
        )
        self.assertEqual(
            restored.native_tree_request.frontier_token_ids_by_level[2][:3],
            [0x205, 0x206, 0x207],
        )
        self.assertEqual(
            restored.native_tree_request.frontier_referenced_token_ids_by_level[2][:3],
            [0x203, 0x204, 0x204],
        )
        self.assertEqual(
            restored.native_tree_request.frontier_position_ids_by_level[4][:1],
            [0x02A],
        )
        self.assertEqual(
            restored.native_tree_request.frontier_referenced_position_ids_by_level[4][:1],
            [0x028],
        )
        self.assertEqual(
            restored.native_tree_request.frontier_branch_ids_by_level[2][:3],
            [0x0, 0x1, 0x2],
        )
        self.assertEqual(
            restored.native_tree_request.frontier_level_ids_by_level[3][:2],
            [0x3, 0x3],
        )

    def test_stimulus_cycle_round_trip_with_full_4x4_verify_group_node_ids(self) -> None:
        request = NativeTreeRequest(
            valid=True,
            req_id=0x2,
            prefix_slot_valid=0b0011,
            committed_len=3,
            draft_count=16,
            branch_count=4,
            prefix_node_ids=[0x1, 0x2],
            prefix_token_ids=[0x10, 0x11],
            prefix_position_ids=[0x0, 0x1],
            frontier_level_valid=0b00_1111,
            frontier_slot_valid_by_level=[0b1111, 0b1111, 0b1111, 0b1111],
            frontier_tree_mask_en_by_level=[0b1111, 0b1111, 0b1111, 0b1111],
            frontier_node_ids_by_level=[
                [0x3, 0x4, 0x5, 0x6],
                [0x7, 0x8, 0x9, 0xA],
                [0xB, 0xC, 0xD, 0xE],
                [0xF, 0x10, 0x11, 0x12],
            ],
            frontier_parent_node_ids_by_level=[
                [0x2, 0x2, 0x2, 0x2],
                [0x3, 0x4, 0x5, 0x6],
                [0x7, 0x8, 0x9, 0xA],
                [0xB, 0xC, 0xD, 0xE],
            ],
            frontier_token_ids_by_level=[
                [0x21, 0x22, 0x23, 0x24],
                [0x31, 0x32, 0x33, 0x34],
                [0x41, 0x42, 0x43, 0x44],
                [0x51, 0x52, 0x53, 0x54],
            ],
            frontier_referenced_token_ids_by_level=[
                [0x12, 0x12, 0x12, 0x12],
                [0x21, 0x22, 0x23, 0x24],
                [0x31, 0x32, 0x33, 0x34],
                [0x41, 0x42, 0x43, 0x44],
            ],
            frontier_position_ids_by_level=[
                [0x3, 0x3, 0x3, 0x3],
                [0x4, 0x4, 0x4, 0x4],
                [0x5, 0x5, 0x5, 0x5],
                [0x6, 0x6, 0x6, 0x6],
            ],
            frontier_referenced_position_ids_by_level=[
                [0x2, 0x2, 0x2, 0x2],
                [0x3, 0x3, 0x3, 0x3],
                [0x4, 0x4, 0x4, 0x4],
                [0x5, 0x5, 0x5, 0x5],
            ],
            frontier_branch_ids_by_level=[
                [0x0, 0x1, 0x2, 0x3],
                [0x0, 0x1, 0x2, 0x3],
                [0x0, 0x1, 0x2, 0x3],
                [0x0, 0x1, 0x2, 0x3],
            ],
            frontier_level_ids_by_level=[
                [0x0, 0x0, 0x0, 0x0],
                [0x1, 0x1, 0x1, 0x1],
                [0x2, 0x2, 0x2, 0x2],
                [0x3, 0x3, 0x3, 0x3],
            ],
        )
        cycle = StimulusCycle(
            cfg_valid=True,
            cfg_data=0x0000_0002,
            start=True,
            draft_candidates=[],
            tree_window_ready=True,
            recompute_req_ready=True,
            wb_ready=True,
            native_tree_request=request,
        )

        restored = StimulusCycle.from_memh_word(cycle.to_memh_word())

        self.assertEqual(
            restored.native_tree_request.frontier_node_ids_by_level[3][:4],
            [0xF, 0x10, 0x11, 0x12],
        )
        self.assertEqual(
            restored.native_tree_request.frontier_parent_node_ids_by_level[3][:4],
            [0xB, 0xC, 0xD, 0xE],
        )


if __name__ == "__main__":
    unittest.main()
