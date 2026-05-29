#!/usr/bin/env bash

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common_vcs.sh"

run_vcs_testbench \
    "tb_comparator_agu_freeze" \
    "tb_comparator_agu_freeze" \
    "code/comparator.v" \
    "code/agu.v" \
    "code/tb/tb_comparator_agu_freeze.v"
