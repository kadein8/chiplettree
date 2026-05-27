import re
import sys
from pathlib import Path


METRIC_RE = re.compile(r"^PERF_METRIC,([^,]+),([0-9]+)$")


def parse_metrics(run_log: Path):
    metrics = {}
    for raw_line in run_log.read_text(encoding="utf-8", errors="ignore").splitlines():
        match = METRIC_RE.match(raw_line.strip())
        if match:
            metrics[match.group(1)] = int(match.group(2))
    return metrics


def percent_improve(baseline, current, inverse=False):
    if baseline == 0:
        return "n/a"
    if inverse:
        return f"{((baseline - current) * 100.0 / baseline):.2f}"
    return f"{((current - baseline) * 100.0 / baseline):.2f}"


def main():
    if len(sys.argv) != 3:
        print("usage: analyze_ablation.py <logs_dir> <report_md>")
        sys.exit(1)

    logs_dir = Path(sys.argv[1])
    report_path = Path(sys.argv[2])

    config_order = [
        "config_00_baseline",
        "config_01_topology",
        "config_02_freeze_promote",
        "config_03_isolation",
        "config_04_all_enabled",
        "config_05_incremental",
    ]

    metrics_by_config = {}
    for config in config_order:
        run_log = logs_dir / config / "run.log"
        metrics_by_config[config] = parse_metrics(run_log) if run_log.exists() else {}

    baseline = metrics_by_config["config_00_baseline"]

    lines = [
        "# SRAM Advanced Features Ablation Report",
        "",
        "## Configurations",
        "",
        "| Config | Topology | Freeze | Promotion | Isolation |",
        "|--------|----------|--------|-----------|-----------|",
        "| config_00_baseline | OFF | OFF | OFF | OFF |",
        "| config_01_topology | ON | OFF | OFF | OFF |",
        "| config_02_freeze_promote | OFF | ON | ON | OFF |",
        "| config_03_isolation | OFF | OFF | OFF | ON |",
        "| config_04_all_enabled | ON | ON | ON | ON |",
        "| config_05_incremental | ON | ON | ON | ON |",
        "",
        "## Core Metrics",
        "",
        "| Config | total_cycles | physical_reads | physical_writes | shared_reuse_hits | promotion_hits | isolation_guard_hits |",
        "|--------|--------------|----------------|-----------------|-------------------|----------------|----------------------|",
    ]

    for config in config_order:
        metric = metrics_by_config[config]
        lines.append(
            f"| {config} | {metric.get('total_cycles', 0)} | "
            f"{metric.get('physical_reads', 0)} | {metric.get('physical_writes', 0)} | "
            f"{metric.get('shared_reuse_hits', 0)} | {metric.get('promotion_hits', 0)} | "
            f"{metric.get('isolation_guard_hits', 0)} |"
        )

    lines.extend(
        [
            "",
            "## Relative Improvement vs Baseline",
            "",
            "| Config | cycle_improve_pct | read_reduce_pct | shared_reuse_growth_pct |",
            "|--------|-------------------|-----------------|-------------------------|",
        ]
    )

    for config in config_order:
        if config == "config_00_baseline":
            lines.append("| config_00_baseline | baseline | baseline | baseline |")
            continue
        metric = metrics_by_config[config]
        lines.append(
            f"| {config} | "
            f"{percent_improve(baseline.get('total_cycles', 0), metric.get('total_cycles', 0), inverse=True)} | "
            f"{percent_improve(baseline.get('physical_reads', 0), metric.get('physical_reads', 0), inverse=True)} | "
            f"{percent_improve(max(baseline.get('shared_reuse_hits', 0), 1), max(metric.get('shared_reuse_hits', 0), 1))} |"
        )

    lines.extend(
        [
            "",
            "## Notes",
            "",
            "- Read `summary.txt` and `run.log` for each config before drawing conclusions.",
            "- High `shared_reuse_hits` and `promotion_hits` indicate freeze/promotion paths are active.",
            "- Non-zero `isolation_guard_hits` indicates branch isolation was actually exercised.",
            "- Improvements in private placement or physical access count indicate topology-aware mapping is active.",
            "",
        ]
    )

    report_path.write_text("\n".join(lines), encoding="utf-8")


if __name__ == "__main__":
    main()
