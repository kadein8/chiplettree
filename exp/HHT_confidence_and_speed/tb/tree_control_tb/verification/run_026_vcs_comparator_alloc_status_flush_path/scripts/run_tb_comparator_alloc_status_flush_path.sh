#!/usr/bin/env bash

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common_vcs.sh"

run_vcs_testbench \
    "tb_comparator_alloc_status_flush_path" \
    "tb_comparator_alloc_status_flush_path" \
    "code/comparator.v" \
    "code/agu.v" \
    "code/prefetch_queue.v" \
    "code/free_list.v" \
    "code/bank_state_table.v" \
    "code/tb/tb_comparator_alloc_status_flush_path.v"
