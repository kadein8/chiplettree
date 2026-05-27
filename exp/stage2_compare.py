import re
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Sequence, Tuple


def _read_kv_file(path: Path) -> Dict[str, str]:
    values = {}  # type: Dict[str, str]
    if not path.exists():
        return values
    for line in path.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if not stripped or "=" not in stripped:
            continue
        key, value = stripped.split("=", 1)
        values[str(key)] = str(value)
    return values


def _extract_sim_time_ps(run_log_path: Path) -> Optional[int]:
    if not run_log_path.exists():
        return None
    content = run_log_path.read_text(encoding="utf-8", errors="ignore")
    match = re.search(r"Time:\s+([0-9]+)\s+ps", content)
    if match is None:
        return None
    return int(match.group(1))


def build_metric_rows(configs: Sequence[Dict[str, Any]]) -> List[Dict[str, Any]]:
    rows = []  # type: List[Dict[str, Any]]
    for config in configs:
        run_dir = Path(str(config["run_dir"]))
        logs_dir = run_dir / "logs"
        summary = _read_kv_file(logs_dir / str(config["summary_name"]))
        run_log_path = logs_dir / str(config["run_log_name"])
        rows.append(
            {
                "label": str(config["label"]),
                "judge": str(summary.get("judge", "")),
                "scope": str(summary.get("scope", "")),
                "sim_time_ps": _extract_sim_time_ps(run_log_path),
                "accepted_tokens": int(config.get("accepted_tokens", 0)),
                "slot_count": int(config.get("slot_count", 0)),
                "semantic_flags": list(config.get("semantic_flags", [])),
                "run_dir": str(run_dir),
                "run_log_path": str(run_log_path),
            }
        )
    return rows


def _find_row(rows: Sequence[Dict[str, Any]], flag: str) -> Dict[str, Any]:
    for row in rows:
        if flag in list(row.get("semantic_flags", [])):
            return row
    raise KeyError("missing row flag: {0}".format(flag))


def _format_optional_int(value: Optional[int]) -> str:
    if value is None:
        return "N/A"
    return str(int(value))


def compare_task_a_rows(rows: Sequence[Dict[str, Any]]) -> List[Dict[str, str]]:
    serial_row = _find_row(rows, "serial_frontend")
    tree_row = _find_row(rows, "tree_frontend")
    return [
        {
            "指标": "前端形态",
            "串行前端": str(serial_row["label"]),
            "树前端": str(tree_row["label"]),
        },
        {
            "指标": "accepted_tokens",
            "串行前端": str(serial_row["accepted_tokens"]),
            "树前端": str(tree_row["accepted_tokens"]),
        },
        {
            "指标": "窗口有效槽位数",
            "串行前端": str(serial_row["slot_count"]),
            "树前端": str(tree_row["slot_count"]),
        },
        {
            "指标": "仿真结束时间(ps)",
            "串行前端": _format_optional_int(serial_row["sim_time_ps"]),
            "树前端": _format_optional_int(tree_row["sim_time_ps"]),
        },
    ]


def compare_task_b_rows(rows: Sequence[Dict[str, Any]]) -> List[Dict[str, str]]:
    task_rows = []  # type: List[Dict[str, str]]
    semantic_to_label = {
        "multibranch": "multibranch",
        "partial/full": "partial/full",
        "reuse": "reuse",
        "hht": "HHT",
    }
    for semantic_flag, semantic_label in semantic_to_label.items():
        matched = [
            row for row in rows if semantic_flag in list(row.get("semantic_flags", []))
        ]
        if not matched:
            continue
        best = matched[-1]
        task_rows.append(
            {
                "论文语义": semantic_label,
                "样本run": str(best["label"]),
                "accepted_tokens": str(best["accepted_tokens"]),
                "窗口槽位数": str(best["slot_count"]),
                "仿真结束时间(ps)": _format_optional_int(best["sim_time_ps"]),
                "直观结论": _semantic_conclusion(semantic_flag, best),
            }
        )
    return task_rows


def _semantic_conclusion(semantic_flag: str, row: Dict[str, Any]) -> str:
    if semantic_flag == "multibranch":
        return "同一窗口内多个槽位进入后端并闭环到写回"
    if semantic_flag == "partial/full":
        return "同一 token 存在分阶段供数与补齐语义"
    if semantic_flag == "reuse":
        return "后续 token 复用已有 full_ready 结果，避免重复路径"
    if semantic_flag == "hht":
        return "HHT 命中与顶层写回反馈进入同一 bounded run"
    return str(row["label"])


def render_markdown_report(
    title: str,
    intro: str,
    metric_notes: Iterable[Tuple[str, str]],
    rows: Sequence[Dict[str, str]],
) -> str:
    lines = [
        "# {0}".format(title),
        "",
        intro,
        "",
        "## 指标含义",
        "",
    ]
    for key, note in metric_notes:
        lines.append("- `{0}`: {1}".format(str(key), str(note)))

    lines.extend(["", "## 数据对比", ""])
    if not rows:
        lines.append("当前仓库样本不足，尚未生成对比表。")
        lines.append("")
        return "\n".join(lines)

    headers = list(rows[0].keys())
    lines.append("| " + " | ".join(headers) + " |")
    lines.append("| " + " | ".join(["---"] * len(headers)) + " |")
    for row in rows:
        lines.append("| " + " | ".join(str(row.get(header, "")) for header in headers) + " |")
    lines.append("")
    return "\n".join(lines)


def write_report(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")

