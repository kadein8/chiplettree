import re
import sys
from pathlib import Path


METRIC_RE = re.compile(r"^PERF_METRIC,([^,]+),([0-9]+)$")
ROUND_RE = re.compile(r"^PERF_ROUND,([0-9]+),([0-9]+),([0-9]+),([0-9]+),([0-9]+)$")


def parse_log(log_path: Path):
    metrics = {}
    rounds = []
    for raw_line in log_path.read_text(encoding="utf-8", errors="ignore").splitlines():
        line = raw_line.strip()
        metric_match = METRIC_RE.match(line)
        if metric_match:
            metrics[metric_match.group(1)] = int(metric_match.group(2))
            continue
        round_match = ROUND_RE.match(line)
        if round_match:
            rounds.append(
                {
                    "round_id": int(round_match.group(1)),
                    "start_cycle": int(round_match.group(2)),
                    "wb_done_cycle": int(round_match.group(3)),
                    "busy_drop_cycle": int(round_match.group(4)),
                    "round_cycles": int(round_match.group(5)),
                }
            )
    return metrics, rounds


def build_report(metrics, rounds):
    total_access = metrics.get("total_sram_reads", 0) + metrics.get("total_sram_writes", 0)
    lines = [
        "# Step 2 Throughput Report",
        "",
        "## Summary",
        "",
        "| Metric | Value |",
        "|--------|-------|",
        f"| global_cycles | {metrics.get('global_cycles', 0)} |",
        f"| total_rounds | {metrics.get('total_rounds', 0)} |",
        f"| total_wb_tokens | {metrics.get('total_wb_tokens', 0)} |",
        f"| avg_cycles_per_round | {metrics.get('avg_cycles_per_round', 0)} |",
        f"| tokens_per_cycle_x1000 | {metrics.get('tokens_per_cycle_x1000', 0)} |",
        "",
        "## SRAM Access",
        "",
        "| Metric | Value |",
        "|--------|-------|",
        f"| total_sram_reads | {metrics.get('total_sram_reads', 0)} |",
        f"| total_sram_writes | {metrics.get('total_sram_writes', 0)} |",
        f"| total_access | {total_access} |",
        f"| total_flush_events | {metrics.get('total_flush_events', 0)} |",
        f"| total_error_events | {metrics.get('total_error_events', 0)} |",
        "",
        "## Per-Round Detail",
        "",
        "| round_id | start_cycle | wb_done_cycle | busy_drop_cycle | round_cycles |",
        "|----------|-------------|---------------|-----------------|--------------|",
    ]
    for item in rounds:
        lines.append(
            f"| {item['round_id']} | {item['start_cycle']} | {item['wb_done_cycle']} | "
            f"{item['busy_drop_cycle']} | {item['round_cycles']} |"
        )
    lines.append("")
    return "\n".join(lines)


def main():
    if len(sys.argv) != 3:
        print("usage: analyze_throughput.py <run_log> <report_md>")
        sys.exit(1)

    log_path = Path(sys.argv[1])
    report_path = Path(sys.argv[2])
    metrics, rounds = parse_log(log_path)
    report_path.write_text(build_report(metrics, rounds), encoding="utf-8")


if __name__ == "__main__":
    main()
