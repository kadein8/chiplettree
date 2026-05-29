#!/usr/bin/env python3
"""
HHT Confidence vs Generation Speed -- summary figure.

Combines measured RTL data points (0%, 25%) with the projected
probabilistic-acceptance model (50%, 75%, 100%) and renders a
two-panel figure in the same style as hht_confidence_vs_speed.png.

tokens/round model (probabilistic acceptance, alpha = ACC/100):
    E[accepted] = 1 + alpha + alpha^2 + alpha^3   (4-deep chain)
which gives ~ {1.0, 1.33, 1.88, 2.73, 4.0} for {0,25,50,75,100}%.

cycles/token = ROUND_COST / (tokens/round), where ROUND_COST is the
measured cost of one verification round (~492,280 cycles at 0%).
"""

import json
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

OUT_DIR = Path(__file__).resolve().parent / "results"
OUT_DIR.mkdir(exist_ok=True)

# One verification round cost (cycles), from measured 0% RTL run.
ROUND_COST = 492280.0

# accuracy(%) -> tokens per verification round
#   0%, 25% : measured in RTL
#   50/75/100% : projected probabilistic-acceptance model
DATA = [
    {"acc": 0,   "tpr": 1.00, "kind": "measured"},
    {"acc": 25,  "tpr": 1.33, "kind": "measured"},
    {"acc": 50,  "tpr": 1.88, "kind": "projected"},
    {"acc": 75,  "tpr": 2.73, "kind": "projected"},
    {"acc": 100, "tpr": 4.00, "kind": "projected"},
]

accuracies = [d["acc"] for d in DATA]
tok_per_round = [d["tpr"] for d in DATA]
cyc_per_tok = [ROUND_COST / d["tpr"] for d in DATA]
is_measured = [d["kind"] == "measured" for d in DATA]

# Save the combined dataset for reference.
with open(OUT_DIR / "confidence_vs_speed_data.json", "w") as f:
    json.dump(
        [
            {
                "accuracy_pct": d["acc"],
                "tokens_per_round": d["tpr"],
                "cycles_per_token": round(ROUND_COST / d["tpr"], 1),
                "speedup_vs_serial": round(d["tpr"] / DATA[0]["tpr"], 2),
                "kind": d["kind"],
            }
            for d in DATA
        ],
        f,
        indent=2,
    )

fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(12, 5))

# --- Panel 1: cycles per token vs accuracy ---
ax1.plot(accuracies, cyc_per_tok, "b-", linewidth=2, zorder=1)
for acc, cyc, meas in zip(accuracies, cyc_per_tok, is_measured):
    if meas:
        ax1.plot(acc, cyc, "o", color="b", markersize=9,
                 zorder=2)
    else:
        ax1.plot(acc, cyc, "o", color="white", markeredgecolor="b",
                 markeredgewidth=1.8, markersize=9, zorder=2)
ax1.set_xlabel("HHT Prediction Accuracy (%)", fontsize=12)
ax1.set_ylabel("Average Cycles per Token", fontsize=12)
ax1.set_title("Generation Latency vs Prediction Accuracy", fontsize=13)
ax1.grid(True, alpha=0.3)
ax1.set_xticks(accuracies)

serial_cyc = cyc_per_tok[0]
ax1.axhline(y=serial_cyc, color="r", linestyle="--", alpha=0.5,
            label=f"Serial baseline ({serial_cyc:.0f})")
# legend proxies for measured vs projected
ax1.plot([], [], "o", color="b", markersize=9, label="Measured (RTL)")
ax1.plot([], [], "o", color="white", markeredgecolor="b",
         markeredgewidth=1.8, markersize=9, label="Projected (model)")
ax1.legend()

# --- Panel 2: tokens per round vs accuracy ---
ax2.plot(accuracies, tok_per_round, "g-", linewidth=2, zorder=1)
for acc, tpr, meas in zip(accuracies, tok_per_round, is_measured):
    if meas:
        ax2.plot(acc, tpr, "s", color="g", markersize=9, zorder=2)
    else:
        ax2.plot(acc, tpr, "s", color="white", markeredgecolor="g",
                 markeredgewidth=1.8, markersize=9, zorder=2)
    ax2.annotate(f"{tpr:.2f}", (acc, tpr), textcoords="offset points",
                 xytext=(0, 10), ha="center", fontsize=9)
ax2.set_xlabel("HHT Prediction Accuracy (%)", fontsize=12)
ax2.set_ylabel("Tokens per Verification Round", fontsize=12)
ax2.set_title("Speculation Efficiency vs Prediction Accuracy", fontsize=13)
ax2.grid(True, alpha=0.3)
ax2.set_xticks(accuracies)
ax2.set_ylim(bottom=0.8)
ax2.plot([], [], "s", color="g", markersize=9, label="Measured (RTL)")
ax2.plot([], [], "s", color="white", markeredgecolor="g",
         markeredgewidth=1.8, markersize=9, label="Projected (model)")
ax2.legend(loc="upper left")

plt.tight_layout()
plt.savefig(str(OUT_DIR / "hht_confidence_vs_speed_v2.png"), dpi=150,
            bbox_inches="tight")
plt.savefig(str(OUT_DIR / "hht_confidence_vs_speed_v2.pdf"),
            bbox_inches="tight")
print("Saved:")
print(" ", OUT_DIR / "hht_confidence_vs_speed_v2.png")
print(" ", OUT_DIR / "hht_confidence_vs_speed_v2.pdf")
print(" ", OUT_DIR / "confidence_vs_speed_data.json")
print()
print(f"{'Acc%':<6}{'tok/round':<12}{'cyc/token':<12}{'speedup':<10}{'kind'}")
for d in DATA:
    print(f"{d['acc']:<6}{d['tpr']:<12.2f}"
          f"{ROUND_COST / d['tpr']:<12.0f}"
          f"{d['tpr'] / DATA[0]['tpr']:<10.2f}{d['kind']}")
