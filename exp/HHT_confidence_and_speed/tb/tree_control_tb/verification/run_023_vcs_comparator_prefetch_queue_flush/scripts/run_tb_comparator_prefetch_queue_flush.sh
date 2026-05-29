#!/usr/bin/env bash

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common_vcs.sh"

run_vcs_testbench \
    "tb_comparator_prefetch_queue_flush" \
    "tb_comparator_prefetch_queue_flush" \
    "code/comparator.v" \
    "code/agu.v" \
    "code/prefetch_queue.v" \
    "code/tb/tb_comparator_prefetch_queue_flush.v"
