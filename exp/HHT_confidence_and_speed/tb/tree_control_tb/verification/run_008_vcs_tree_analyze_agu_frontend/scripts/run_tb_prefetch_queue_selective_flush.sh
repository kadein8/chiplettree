#!/usr/bin/env bash

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common_vcs.sh"

run_vcs_testbench \
    "tb_prefetch_queue_selective_flush" \
    "tb_prefetch_queue_selective_flush" \
    "code/prefetch_queue.v" \
    "code/tb/tb_prefetch_queue_selective_flush.v"
