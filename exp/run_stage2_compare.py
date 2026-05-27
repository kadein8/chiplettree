from pathlib import Path

from stage2_compare import (
    build_metric_rows,
    compare_task_a_rows,
    compare_task_b_rows,
    render_markdown_report,
    write_report,
)


REPO_ROOT = Path(__file__).resolve().parents[2]
VERIFY_ROOT = REPO_ROOT / "verification" / "stage2"
RESULT_ROOT = Path(__file__).resolve().parent / "results"


def build_task_a_report() -> str:
    rows = build_metric_rows(
        [
            {
                "label": "25_platform_serial_frontend",
                "run_dir": str(
                    VERIFY_ROOT
                    / "25_vcs_control_chip_stage2_single_chiplet_platform_driver_bringup"
                ),
                "summary_name": "25_summary.txt",
                "run_log_name": "tb_control_chip_stage2_single_chiplet_platform_driver_run.log",
                "accepted_tokens": 1,
                "slot_count": 1,
                "semantic_flags": ["serial_frontend"],
            },
            {
                "label": "18_tree_window_multibranch",
                "run_dir": str(
                    VERIFY_ROOT
                    / "18_vcs_control_chip_stage2_single_chiplet_tree_window_multibranch_lifecycle_top_min_bringup"
                ),
                "summary_name": "18_summary.txt",
                "run_log_name": "tb_control_chip_stage2_single_chiplet_tree_window_multibranch_lifecycle_top_min_run.log",
                "accepted_tokens": 3,
                "slot_count": 3,
                "semantic_flags": ["tree_frontend", "multibranch", "partial/full", "reuse"],
            },
        ]
    )
    return render_markdown_report(
        title="实验A：树结构前端是否改变后端工作量分布",
        intro=(
            "本实验把 `25_` 的串行平台样本与 `18_` 的正式多分支窗口样本并列。"
            "对比目标不是宣称绝对性能，而是回答：同样进入单芯粒后端时，"
            "树结构前端是否把更多有效 branch 工作压进同一个窗口，从而改变后端每轮承载的工作量。"
        ),
        metric_notes=[
            ("accepted_tokens", "最终被系统接受并闭环到写回的 token 数。"),
            ("窗口有效槽位数", "一次前端输入中被正式消费的 branch/slot 数。"),
            ("仿真结束时间(ps)", "run.log 里记录的 VCS 仿真结束时间，可作为 bounded 工作量粗指标。"),
        ],
        rows=compare_task_a_rows(rows),
    )


def build_task_b_report() -> str:
    rows = build_metric_rows(
        [
            {
                "label": "18_tree_window_multibranch",
                "run_dir": str(
                    VERIFY_ROOT
                    / "18_vcs_control_chip_stage2_single_chiplet_tree_window_multibranch_lifecycle_top_min_bringup"
                ),
                "summary_name": "18_summary.txt",
                "run_log_name": "tb_control_chip_stage2_single_chiplet_tree_window_multibranch_lifecycle_top_min_run.log",
                "accepted_tokens": 3,
                "slot_count": 3,
                "semantic_flags": ["multibranch", "partial/full", "reuse"],
            },
            {
                "label": "19_strongest_bounded_window_hht_feedback",
                "run_dir": str(
                    VERIFY_ROOT
                    / "19_vcs_control_chip_stage2_single_chiplet_strongest_bounded_window_hht_feedback_top_min_bringup"
                ),
                "summary_name": "19_summary.txt",
                "run_log_name": "tb_control_chip_stage2_single_chiplet_strongest_bounded_window_hht_feedback_top_min_run.log",
                "accepted_tokens": 4,
                "slot_count": 4,
                "semantic_flags": ["hht", "multibranch", "partial/full", "reuse"],
            },
        ]
    )
    return render_markdown_report(
        title="实验B：论文语义到硬指标的最小映射证据",
        intro=(
            "本实验不伪造缺失事件，而是先用 `18_` 与 `19_` 的正式 PASS 样本建立"
            "“论文语义 -> 可量化指标”的最小证据表。当前第一版主要落到"
            "`accepted_tokens / 槽位数 / 仿真结束时间(ps)` 三类硬指标，"
            "后续若补跑事件样本，可再继续细化到 `event_counts / hbm_write / cycle-to-wb_done`。"
        ),
        metric_notes=[
            ("accepted_tokens", "最终闭环到写回的 token 数，体现该语义是否转化为真实完成工作。"),
            ("窗口槽位数", "窗口中可被正式消费的 branch 数，体现 multibranch/HHT 是否真的进入后端。"),
            ("仿真结束时间(ps)", "bounded run 的粗粒度工作量指标，时间越长通常意味着后端路径更复杂。"),
        ],
        rows=compare_task_b_rows(rows),
    )


def main() -> int:
    task_a_path = RESULT_ROOT / "task_a_tree_frontend_workload_compare.md"
    task_b_path = RESULT_ROOT / "task_b_semantic_metric_mapping_compare.md"
    write_report(task_a_path, build_task_a_report())
    write_report(task_b_path, build_task_b_report())
    print(str(task_a_path))
    print(str(task_b_path))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
