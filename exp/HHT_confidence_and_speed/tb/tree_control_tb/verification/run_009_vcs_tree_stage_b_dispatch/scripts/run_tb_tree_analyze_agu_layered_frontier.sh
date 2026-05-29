#!/usr/bin/env bash

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common_vcs.sh"

run_vcs_testbench \
    "tb_tree_analyze_agu_layered_frontier" \
    "tb_tree_analyze_agu_layered_frontier" \
    "code/tree_analyze.v" \
    "code/agu.v" \
    "code/tb/tb_tree_analyze_agu_layered_frontier.v"
