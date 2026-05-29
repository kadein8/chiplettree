#!/usr/bin/env bash

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common_vcs.sh"
SUMMARY_FILE="${RUN_DIR}/logs/run_054_summary.txt"

run_vcs_testbench \
    "tb_control_chip_serial_free_running_surrogate" \
    "tb_control_chip_serial_free_running_surrogate" \
    "code/prediction_unit_bounded_stub.v" \
    "code/compute_module_bounded_stub.v" \
    "code/commit_writeback_bounded_shim.v" \
    "code/comparator.v" \
    "code/tree_analyze.v" \
    "code/agu.v" \
    "code/prefetch_queue.v" \
    "code/free_list.v" \
    "code/bank_state_table.v" \
    "code/token_register.v" \
    "code/request_controller.v" \
    "code/sram_subsystem.v" \
    "code/sram_bank.v" \
    "code/sram_subbank.v" \
    "code/control_chip.v" \
    "code/tb/tb_control_chip_serial_free_running_surrogate.v"
rc=$?

{
    echo "run_name=run_054_vcs_control_chip_serial_free_running_surrogate"
    echo "timestamp=$(date '+%Y-%m-%d %H:%M:%S')"
    echo "running=run_tb_control_chip_serial_free_running_surrogate.sh"
    echo "exit_code_run_tb_control_chip_serial_free_running_surrogate.sh=${rc}"
    if [[ ${rc} -eq 0 ]]; then
        echo "judge=PASS"
    else
        echo "judge=FAIL"
    fi
} > "${SUMMARY_FILE}"

exit ${rc}
