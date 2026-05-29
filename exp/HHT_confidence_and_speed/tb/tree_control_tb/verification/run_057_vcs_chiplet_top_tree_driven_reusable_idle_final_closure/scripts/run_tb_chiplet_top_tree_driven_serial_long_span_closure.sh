#!/usr/bin/env bash

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common_vcs.sh"
SUMMARY_FILE="${RUN_DIR}/logs/run_056_summary.txt"

run_vcs_testbench \
    "tb_control_chip_tree_driven_serial_long_span_closure" \
    "tb_control_chip_tree_driven_serial_long_span_closure" \
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
    "code/tb/tb_control_chip_tree_driven_serial_long_span_closure.v"
rc=$?

{
    echo "run_name=run_056_vcs_control_chip_tree_driven_serial_long_span_closure"
    echo "timestamp=$(date '+%Y-%m-%d %H:%M:%S')"
    echo "running=run_tb_control_chip_tree_driven_serial_long_span_closure.sh"
    echo "exit_code_run_tb_control_chip_tree_driven_serial_long_span_closure.sh=${rc}"
    if [[ ${rc} -eq 0 ]]; then
        echo "judge=PASS"
    else
        echo "judge=FAIL"
    fi
} > "${SUMMARY_FILE}"

exit ${rc}
