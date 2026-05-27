#!/usr/bin/env bash

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common_vcs.sh"

run_vcs_testbench \
    "tb_comparator_accepted_path_longest_path" \
    "tb_comparator_accepted_path_longest_path" \
    "code/comparator.v" \
    "code/tb/tb_comparator_accepted_path_longest_path.v"
