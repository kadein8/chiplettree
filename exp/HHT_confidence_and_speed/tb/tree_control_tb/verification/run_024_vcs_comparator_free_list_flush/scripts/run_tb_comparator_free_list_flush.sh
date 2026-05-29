#!/usr/bin/env bash

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common_vcs.sh"

run_vcs_testbench \
    "tb_comparator_free_list_flush" \
    "tb_comparator_free_list_flush" \
    "code/comparator.v" \
    "code/agu.v" \
    "code/prefetch_queue.v" \
    "code/free_list.v" \
    "code/tb/tb_comparator_free_list_flush.v"
