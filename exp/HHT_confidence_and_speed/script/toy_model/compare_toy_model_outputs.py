import argparse
import json
from pathlib import Path
from typing import Dict, Iterable, List, Tuple

import numpy as np


def load_memh_vector(path: Path) -> np.ndarray:
    values = []
    for line in path.read_text(encoding="ascii").splitlines():
        raw = line.strip()
        if not raw:
            continue
        words = [raw[i : i + 4] for i in range(0, len(raw), 4)]
        words = list(reversed(words))
        for word in words:
            values.append(np.frombuffer(bytes.fromhex(word), dtype=">f2")[0].astype(np.float16))
    return np.asarray(values, dtype=np.float16)


def cosine_similarity(a: np.ndarray, b: np.ndarray) -> float:
    a32 = a.astype(np.float32).reshape(-1)
    b32 = b.astype(np.float32).reshape(-1)
    na = float(np.linalg.norm(a32))
    nb = float(np.linalg.norm(b32))
    if na == 0.0 or nb == 0.0:
        return 1.0 if na == nb else 0.0
    return float(np.dot(a32, b32) / (na * nb))


def compare_pair(name: str, rtl: np.ndarray, ref: np.ndarray) -> Tuple[str, dict]:
    limit = min(len(rtl), len(ref))
    rtl_s = rtl[:limit]
    ref_s = ref[:limit]
    abs_err = np.abs(rtl_s.astype(np.float32) - ref_s.astype(np.float32))
    rel_den = np.maximum(np.abs(ref_s.astype(np.float32)), 1e-6)
    rel_err = abs_err / rel_den
    report = {
        "name": name,
        "rtl_len": int(len(rtl)),
        "ref_len": int(len(ref)),
        "compare_len": int(limit),
        "max_abs_err": float(np.max(abs_err)) if limit else 0.0,
        "mean_abs_err": float(np.mean(abs_err)) if limit else 0.0,
        "max_rel_err": float(np.max(rel_err)) if limit else 0.0,
        "cosine_similarity": cosine_similarity(rtl_s, ref_s) if limit else 1.0,
    }
    return name, report


def main() -> int:
    parser = argparse.ArgumentParser(description="Compare toy-model RTL dumps against Python reference")
    parser.add_argument("--rtl-dir", type=Path, required=True)
    parser.add_argument("--ref-dir", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--num-tokens", type=int, default=1)
    args = parser.parse_args()

    rtl_dir = args.rtl_dir.resolve()
    ref_dir = args.ref_dir.resolve()

    comparisons: Dict[str, dict] = {}
    summary: Dict[str, object]

    if args.num_tokens <= 1:
        pairs: Iterable[Tuple[str, Path, Path]] = (
            ("hidden_after_layer1", rtl_dir / "rtl_hidden_after_layer1.memh", ref_dir / "ref_hidden_after_layer1.npy"),
            ("final_hidden", rtl_dir / "rtl_final_hidden.memh", ref_dir / "ref_final_hidden.npy"),
        )

        for name, rtl_path, ref_path in pairs:
            rtl = load_memh_vector(rtl_path)
            ref = np.load(ref_path).astype(np.float16).reshape(-1)
            _, report = compare_pair(name, rtl, ref)
            comparisons[name] = report

        rtl_token = int((rtl_dir / "rtl_token.txt").read_text(encoding="ascii").strip())
        ref_token = int((ref_dir / "ref_token_id.txt").read_text(encoding="ascii").strip())
        summary = {
            "mode": "single_token",
            "token_match": rtl_token == ref_token,
            "rtl_token": rtl_token,
            "ref_token": ref_token,
            "comparisons": comparisons,
        }
    else:
        step_reports: List[dict] = []
        rtl_tokens: List[int] = []
        ref_tokens: List[int] = []
        for step in range(args.num_tokens):
            rtl_hidden_path = rtl_dir / ("rtl_step%d_final_hidden.memh" % step)
            ref_hidden_path = ref_dir / ("ref_step%d_final_hidden.npy" % step)
            rtl_hidden = load_memh_vector(rtl_hidden_path)
            ref_hidden = np.load(ref_hidden_path).astype(np.float16).reshape(-1)
            _, report = compare_pair("step%d_final_hidden" % step, rtl_hidden, ref_hidden)

            rtl_token = int((rtl_dir / ("rtl_step%d_token.txt" % step)).read_text(encoding="ascii").strip())
            ref_token = int((ref_dir / ("ref_step%d_token.txt" % step)).read_text(encoding="ascii").strip())
            rtl_tokens.append(rtl_token)
            ref_tokens.append(ref_token)
            step_reports.append(
                {
                    "step": step,
                    "token_match": rtl_token == ref_token,
                    "rtl_token": rtl_token,
                    "ref_token": ref_token,
                    "final_hidden": report,
                }
            )

        summary = {
            "mode": "autoregressive",
            "num_tokens": args.num_tokens,
            "token_sequence_match": rtl_tokens == ref_tokens,
            "rtl_tokens": rtl_tokens,
            "ref_tokens": ref_tokens,
            "steps": step_reports,
        }

    args.report.write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    print(args.report)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
