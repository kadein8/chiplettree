#!/usr/bin/env bash

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUN_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOG_DIR="${RUN_DIR}/logs"
SUMMARY_FILE="${LOG_DIR}/run_020_summary.txt"

mkdir -p "${LOG_DIR}"

declare -a SCRIPT_LIST=(
    "run_tb_request_controller_bootstrap.sh"
    "run_tb_request_controller_read_merge.sh"
    "run_tb_tree_stage_abcd_integration.sh"
    "run_tb_request_controller_multilane_issue.sh"
    "run_tb_request_controller_four_lane_issue.sh"
    "run_tb_request_controller_multi_merge.sh"
    "run_tb_request_controller_sram_scope_conflict.sh"
    "run_tb_request_controller_priority_order.sh"
    "run_tb_request_controller_mixed_read_write.sh"
)

overall_rc=0

{
    echo "run_name=run_020_vcs_request_controller_mixed_read_write"
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