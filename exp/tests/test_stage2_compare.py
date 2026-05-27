import sys
import tempfile
import unittest
from pathlib import Path


EXP_ROOT = Path(__file__).resolve().parents[1]
if str(EXP_ROOT) not in sys.path:
    sys.path.insert(0, str(EXP_ROOT))


from stage2_compare import (  # type: ignore
    build_metric_rows,
    compare_task_a_rows,
    compare_task_b_rows,
    render_markdown_report,
)


class Stage2CompareTest(unittest.TestCase):
    def test_build_metric_rows_collects_run_time_and_scope(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            run_dir = root / "18_vcs_demo"
            logs_dir = run_dir / "logs"
            logs_dir.mkdir(parents=True, exist_ok=True)
            (logs_dir / "18_summary.txt").write_text(
                "\n".join(
                    [
                        "judge=PASS",
                        "scope=multibranch_window",
                    ]
                )
                + "\n",
                encoding="utf-8",
            )
            (logs_dir / "tb_demo_run.log").write_text(
                "\n".join(
                    [
                        "tb_demo PASS",
                        "Time: 1466000 ps",
                    ]
                )
                + "\n",
                encoding="utf-8",
            )

            rows = build_metric_rows(
                [
                    {
                        "label": "18_demo",
                        "run_dir": str(run_dir),
                        "summary_name": "18_summary.txt",
                        "run_log_name": "tb_demo_run.log",
                        "accepted_tokens": 3,
                        "slot_count": 3,
                        "semantic_flags": ["multibranch", "partial/full", "reuse"],
                    }
                ]
            )

        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["label"], "18_demo")
        self.assertEqual(rows[0]["judge"], "PASS")
        self.assertEqual(rows[0]["scope"], "multibranch_window")
        self.assertEqual(rows[0]["sim_time_ps"], 1466000)
        self.assertEqual(rows[0]["accepted_tokens"], 3)

    def test_compare_task_a_rows_reports_tree_frontend_gain(self) -> None:
        rows = compare_task_a_rows(
            [
                {
                    "label": "serial",
                    "accepted_tokens": 1,
                    "slot_count": 1,
                    "sim_time_ps": 700000,
                    "semantic_flags": ["serial_frontend"],
                },
                {
                    "label": "tree",
                    "accepted_tokens": 3,
                    "slot_count": 3,
                    "sim_time_ps": 1466000,
                    "semantic_flags": ["multibranch", "tree_frontend"],
                },
            ]
        )

        self.assertEqual(len(rows), 4)
        self.assertEqual(rows[0]["指标"], "前端形态")
        self.assertEqual(rows[1]["串行前端"], "1")
        self.assertEqual(rows[1]["树前端"], "3")

    def test_compare_task_b_rows_reports_semantic_to_metric_mapping(self) -> None:
        rows = compare_task_b_rows(
            [
                {
                    "label": "18_demo",
                    "accepted_tokens": 3,
                    "slot_count": 3,
                    "sim_time_ps": 1466000,
                    "semantic_flags": ["multibranch", "partial/full", "reuse"],
                },
                {
                    "label": "19_demo",
                    "accepted_tokens": 4,
                    "slot_count": 4,
                    "sim_time_ps": 2436000,
                    "semantic_flags": ["hht", "multibranch", "partial/full", "reuse"],
                },
            ]
        )

        semantics = [row["论文语义"] for row in rows]
        self.assertIn("multibranch", semantics)
        self.assertIn("partial/full", semantics)
        self.assertIn("reuse", semantics)
        self.assertIn("HHT", semantics)

    def test_render_markdown_report_includes_metric_meanings(self) -> None:
        markdown = render_markdown_report(
            title="实验标题",
            intro="实验说明",
            metric_notes=[
                ("accepted_tokens", "最终被系统接受并完成写回的 token 数"),
                ("sim_time_ps", "VCS run.log 记录的仿真结束时间"),
            ],
            rows=[
                {"指标": "accepted_tokens", "样本A": "1", "样本B": "3"},
            ],
        )

        self.assertIn("# 实验标题", markdown)
        self.assertIn("最终被系统接受并完成写回的 token 数", markdown)
        self.assertIn("| 指标 | 样本A | 样本B |", markdown)


if __name__ == "__main__":
    unittest.main()
