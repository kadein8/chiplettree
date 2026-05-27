#!/usr/bin/env bash

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/common_vcs.sh"

run_vcs_testbench \
    "tb_commit_flush_lifecycle" \
    "tb_commit_flush_lifecycle" \
    "code/bank_state_table.v" \
    "code/token_register.v" \
    "code/tb/tb_commit_flush_lifecycle.v"
