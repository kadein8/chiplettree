#!/usr/bin/env bash

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common_vcs.sh"

run_vcs_testbench \
    "tb_agu_stage_b_flow" \
    "tb_agu_stage_b_flow" \
    "code/agu.v" \
    "code/prefetch_queue.v" \
    "code/free_list.v" \
    "code/bank_state_table.v" \
    "code/tb/tb_agu_stage_b_flow.v"
