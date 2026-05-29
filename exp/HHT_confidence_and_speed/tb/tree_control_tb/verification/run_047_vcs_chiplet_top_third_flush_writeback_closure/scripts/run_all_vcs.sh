#!/usr/bin/env bash

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUN_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOG_DIR="${RUN_DIR}/logs"
SUMMARY_FILE="${LOG_DIR}/run_047_summary.txt"

mkdir -p "${LOG_DIR}"

declare -a SCRIPT_LIST=(
    "run_tb_control_chip_third_flush_writeback_closure.sh"
    "run_tb_control_chip_third_flush_reclosure.sh"
    "run_tb_control_chip_post_second_flush_reentry.sh"
    "run_tb_control_chip_second_flush_writeback_closure.sh"
    "run_tb_control_chip_second_flush_reclosure.sh"
    "run_tb_control_chip_post_flush_reentry.sh"
    "run_tb_control_chip_bounded_orchestration.sh"
    "run_tb_top_level_bounded_memory_integration.sh"
    "run_tb_request_controller_wide_concurrency.sh"
)

overall_rc=0

{
    echo "run_name=run_047_vcs_control_chip_third_flush_writeback_closure"
    echo "timestamp=$(date '+%Y-%m-%d %H:%M:%S')"
} > "${SUMMARY_FILE}"

for script_name in "${SCRIPT_LIST[@]}"; do
    script_path="${SCRIPT_DIR}/${script_name}"
    echo "running=${script_name}" >> "${SUMMARY_FILE}"

    bash "${script_path}"
    rc=$?

    echo "exit_code_${script_name}=${rc}" >> "${SUMMARY_FILE}"
    if [[ ${rc} -ne 0 ]]; then
        overall_rc=1
    fi
done

if [[ ${overall_rc} -eq 0 ]]; then
    echo "judge=PASS" >> "${SUMMARY_FILE}"
else
    echo "judge=FAIL" >> "${SUMMARY_FILE}"
fi

exit ${overall_rc}
