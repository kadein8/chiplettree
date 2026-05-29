"""
golden_speculative_decode.py

Simulates the full speculative decoding loop using the toy model reference,
producing a golden token sequence for RTL comparison.

The loop:
  1. Prefill: run prompt token through transformer → get first output token
  2. Predict: simulate HHT generating draft candidates (simple heuristic)
  3. Verify: run batch forward with tree mask
  4. Compare: find longest accepted prefix per branch
  5. Commit: emit accepted tokens + bonus token
  6. Repeat until max_gen_tokens reached
"""

import argparse
import sys
from pathlib import Path
from typing import Dict, List, Any, Optional, Tuple

import numpy as np

# Import the reference model
REPO_ROOT = Path(__file__).resolve().parents[3]
if str(REPO_ROOT / "code" / "script") not in sys.path:
    sys.path.insert(0, str(REPO_ROOT / "code" / "script"))

from toy_model.toy_model_reference import (
    build_weights,
    run_reference,
    run_tree_masked_reference,
    HIDDEN_DIM, NUM_HEADS, HEAD_DIM, N_LAYERS, VOCAB_SIZE, MAX_SEQ_LEN,
)

OUTPUT_DIR_DEFAULT = REPO_ROOT / "code" / "sim" / "generated"

BRANCH_NUM = 4
MAX_LEVELS = 4


def simple_hht_predict(
    history: List[int],
    vocab_size: int = VOCAB_SIZE,
    max_branches: int = BRANCH_NUM,
    max_depth: int = MAX_LEVELS,
) -> List[List[int]]:
    """
    Simple HHT prediction heuristic for the toy model.
    Generates draft branches based on token history patterns.

    Returns: list of branches, each branch is a list of draft token IDs.
    """
    if len(history) < 1:
        return []

    last_token = history[-1]
    branches: List[List[int]] = []

    # Generate up to max_branches, each with up to max_depth tokens
    # Simple strategy: predict sequential tokens with offsets
    for b in range(min(max_branches, vocab_size)):
        branch: List[int] = []
        for d in range(max_depth):
            # Simple prediction: (last_token + branch_offset + depth) % vocab_size
            draft = (last_token + b + d + 1) % vocab_size
            branch.append(draft)
        branches.append(branch)

    return branches


def build_tree_mask(
    num_slots: int,
    branches: List[List[int]],
    prefix_len: int,
) -> np.ndarray:
    """
    Build the tree attention mask for batch verification.

    Slot layout: [seed, branch0_level0, branch0_level1, ..., branch1_level0, ...]
    Each slot can see: all prefix positions + its own ancestor chain in the tree.
    """
    mask = np.zeros((num_slots, MAX_SEQ_LEN), dtype=np.uint8)

    # All slots can see the committed prefix
    for s in range(num_slots):
        for p in range(prefix_len):
            mask[s, p] = 1

    # Seed slot (index 0) sees only prefix
    # Branch slots see prefix + seed + their ancestors
    slot_idx = 1
    for branch in branches:
        for depth in range(len(branch)):
            if slot_idx >= num_slots:
                break
            # This slot sees: prefix + seed + all ancestors in same branch
            mask[slot_idx, prefix_len] = 1  # seed position
            for ancestor_depth in range(depth):
                ancestor_pos = prefix_len + 1 + ancestor_depth
                if ancestor_pos < MAX_SEQ_LEN:
                    mask[slot_idx, ancestor_pos] = 1
            # And itself
            self_pos = prefix_len + 1 + depth
            if self_pos < MAX_SEQ_LEN:
                mask[slot_idx, self_pos] = 1
            slot_idx += 1

    return mask


def compare_and_commit(
    branches: List[List[int]],
    model_predictions: List[int],
) -> Tuple[int, int, int]:
    """
    Compare draft tokens against model predictions.

    Returns: (winning_branch_idx, accepted_depth, bonus_token_id)

    For each branch, check how many consecutive draft tokens match
    the model's prediction at the parent position.
    """
    best_branch = 0
    best_depth = 0
    bonus_token = model_predictions[0] if model_predictions else 0

    slot_idx = 1  # skip seed
    for b_idx, branch in enumerate(branches):
        depth = 0
        for d in range(len(branch)):
            if slot_idx + d >= len(model_predictions):
                break
            # Model prediction at parent slot should match draft token
            parent_slot = 0 if d == 0 else (slot_idx + d - 1)
            if parent_slot < len(model_predictions):
                if branch[d] == model_predictions[parent_slot]:
                    depth += 1
                else:
                    break
            else:
                break

        if depth > best_depth:
            best_depth = depth
            best_branch = b_idx
            # Bonus token: model's prediction at the last accepted position
            last_accepted_slot = slot_idx + depth - 1 if depth > 0 else 0
            if last_accepted_slot < len(model_predictions):
                bonus_token = model_predictions[last_accepted_slot]

        slot_idx += len(branch)

    # If nothing accepted, bonus = model prediction at seed
    if best_depth == 0:
        bonus_token = model_predictions[0] if model_predictions else 0

    return best_branch, best_depth, bonus_token


def run_speculative_decode_loop(
    weights: Dict[str, Any],
    bos_token_id: int = 0,
    max_gen_tokens: int = 4,
) -> Dict[str, Any]:
    """
    Run the full speculative decoding loop.
    """
    kv_cache_k = np.zeros((N_LAYERS, MAX_SEQ_LEN, NUM_HEADS, HEAD_DIM), dtype=np.float16)
    kv_cache_v = np.zeros((N_LAYERS, MAX_SEQ_LEN, NUM_HEADS, HEAD_DIM), dtype=np.float16)

    # Step 1: Prefill
    dumps, kv_cache_k, kv_cache_v = run_reference(
        weights, token_id=bos_token_id, position=0,
        kv_cache_k=kv_cache_k, kv_cache_v=kv_cache_v,
    )
    first_token = int(dumps["token_id"])

    token_sequence: List[int] = [first_token]
    history: List[int] = [bos_token_id, first_token]
    current_position = 1
    iteration_log: List[Dict[str, Any]] = []

    print(f"Prefill: input={bos_token_id} → output={first_token}")

    # Step 2: Speculative decode loop
    while len(token_sequence) < max_gen_tokens:
        # Predict
        branches = simple_hht_predict(history, max_branches=BRANCH_NUM, max_depth=MAX_LEVELS)

        if not branches or current_position + 1 >= MAX_SEQ_LEN:
            # Fallback to single-token generation
            dumps, kv_cache_k, kv_cache_v = run_reference(
                weights, token_id=history[-1], position=current_position,
                kv_cache_k=kv_cache_k, kv_cache_v=kv_cache_v,
            )
            new_token = int(dumps["token_id"])
            token_sequence.append(new_token)
            history.append(new_token)
            current_position += 1
            iteration_log.append({
                "type": "fallback",
                "token": new_token,
                "position": current_position,
            })
            continue

        # Build batch for verification
        # Slot 0 = seed (last accepted token), slots 1+ = draft tokens
        total_slots = 1 + sum(len(b) for b in branches)
        total_slots = min(total_slots, 17)  # VERIFY_WINDOW_SIZE

        token_ids = [history[-1]]  # seed
        positions = [current_position]
        for branch in branches:
            for d, tok in enumerate(branch):
                if len(token_ids) >= total_slots:
                    break
                token_ids.append(tok)
                positions.append(current_position + 1 + d)

        # Build visibility masks
        visible_masks = []
        for s in range(len(token_ids)):
            mask = np.zeros((MAX_SEQ_LEN,), dtype=np.uint8)
            # Can see all committed prefix
            for p in range(current_position):
                mask[p] = 1
            # Seed sees prefix + itself
            if s == 0:
                mask[current_position] = 1
            else:
                # Draft slots see prefix + seed + ancestors
                mask[current_position] = 1
                # Find which branch and depth this slot belongs to
                slot_offset = s - 1
                for bi, branch in enumerate(branches):
                    if slot_offset < len(branch):
                        # This slot is in branch bi at depth slot_offset
                        for ancestor in range(slot_offset + 1):
                            pos = current_position + 1 + ancestor
                            if pos < MAX_SEQ_LEN:
                                mask[pos] = 1
                        break
                    slot_offset -= len(branch)
            visible_masks.append(mask)

        # Run batch forward
        batch_result, kv_k_tmp, kv_v_tmp = run_tree_masked_reference(
            weights,
            token_ids=token_ids,
            positions=positions,
            kv_cache_k=kv_cache_k.copy(),
            kv_cache_v=kv_cache_v.copy(),
            visible_masks=visible_masks,
        )
        model_predictions = batch_result["token_ids"]

        # Compare and commit
        win_branch, accepted_depth, bonus_token = compare_and_commit(
            branches, model_predictions
        )

        # Emit accepted tokens
        accepted_tokens: List[int] = []
        if accepted_depth > 0:
            accepted_tokens = branches[win_branch][:accepted_depth]

        # Emit bonus token
        all_new_tokens = accepted_tokens + [bonus_token]

        # Update state
        for tok in all_new_tokens:
            if len(token_sequence) >= max_gen_tokens:
                break
            token_sequence.append(tok)
            history.append(tok)
            current_position += 1

            # Update KV cache for accepted tokens
            dumps, kv_cache_k, kv_cache_v = run_reference(
                weights, token_id=tok, position=current_position - 1,
                kv_cache_k=kv_cache_k, kv_cache_v=kv_cache_v,
            )

        iteration_log.append({
            "type": "speculative",
            "branches": [[int(t) for t in b] for b in branches],
            "model_predictions": [int(t) for t in model_predictions],
            "win_branch": win_branch,
            "accepted_depth": accepted_depth,
            "bonus_token": int(bonus_token),
            "accepted_tokens": [int(t) for t in accepted_tokens],
            "new_tokens": [int(t) for t in all_new_tokens],
        })

        print(f"  Iteration: accepted={accepted_depth} from branch {win_branch}, "
              f"bonus={bonus_token}, total_gen={len(token_sequence)}")

    return {
        "token_sequence": token_sequence,
        "iterations": iteration_log,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Golden speculative decode reference for RTL comparison"
    )
    parser.add_argument("--out-dir", type=Path, default=OUTPUT_DIR_DEFAULT)
    parser.add_argument("--bos-token", type=int, default=0)
    parser.add_argument("--max-tokens", type=int, default=4)
    args = parser.parse_args()

    out_dir = args.out_dir.resolve()
    out_dir.mkdir(parents=True, exist_ok=True)

    weights = build_weights()
    result = run_speculative_decode_loop(
        weights,
        bos_token_id=args.bos_token,
        max_gen_tokens=args.max_tokens,
    )

    # Write golden token sequence
    token_seq = result["token_sequence"]
    (out_dir / "golden_spec_decode_tokens.txt").write_text(
        "\n".join(str(int(t)) for t in token_seq) + "\n",
        encoding="ascii",
    )

    print(f"\nGolden token sequence ({len(token_seq)} tokens): {token_seq}")
    print(f"Output written to {out_dir / 'golden_spec_decode_tokens.txt'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
