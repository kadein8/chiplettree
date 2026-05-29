#!/usr/bin/env bash

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common_vcs.sh"

run_vcs_testbench \
    "tb_stage_e_lifecycle_closure" \
    "tb_stage_e_lifecycle_closure" \
    "code/comparator.v" \
    "code/agu.v" \
    "code/prefetch_queue.v" \
    "code/free_list.v" \
    "code/bank_state_table.v" \
    "code/token_register.v" \
    "code/tb/tb_stage_e_lifecycle_closure.v"
