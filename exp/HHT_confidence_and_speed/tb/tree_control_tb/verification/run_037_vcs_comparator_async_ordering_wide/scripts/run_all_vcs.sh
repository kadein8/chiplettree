#!/usr/bin/env bash

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUN_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOG_DIR="${RUN_DIR}/logs"
SUMMARY_FILE="${LOG_DIR}/run_037_summary.txt"

mkdir -p "${LOG_DIR}"

TB_SCRIPT="${SCRIPT_DIR}/run_tb_comparator_async_ordering_wide.sh"
TB_RESULT_FILE="${LOG_DIR}/tb_comparator_async_ordering_wide_result.txt"

{
    echo "run_name=run_037_vcs_comparator_async_ordering_wide"
    echo "timestamp=$(date '+%Y-%m-%d %H:%M:%S')"
    echo "tb_count=1"
} > "${SUMMARY_FILE}"

if bash "${TB_SCRIPT}"; then
    TB_JUDGE="PASS"
else
    TB_JUDGE="FAIL"
fi

{
    echo "tb_0=tb_comparator_async_ordering_wide"
    echo "tb_0_result_file=${TB_RESULT_FILE}"
    echo "tb_0_judge=${TB_JUDGE}"
} >> "${SUMMARY_FILE}"

if [[ "${TB_JUDGE}" == "PASS" ]]; then
    echo "overall_judge=PASS" >> "${SUMMARY_FILE}"
    exit 0
fi

echo "overall_judge=FAIL" >> "${SUMMARY_FILE}"
exit 1
