#!/usr/bin/env bash

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common_vcs.sh"

run_vcs_testbench \
    "tb_control_chip_serial_three_tree_final_closure" \
    "tb_control_chip_serial_three_tree_final_closure" \
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
    "code/tb/tb_control_chip_serial_three_tree_final_closure.v"
