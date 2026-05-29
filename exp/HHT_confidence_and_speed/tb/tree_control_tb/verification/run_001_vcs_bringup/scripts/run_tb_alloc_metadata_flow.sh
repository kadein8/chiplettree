#!/usr/bin/env bash

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/common_vcs.sh"

run_vcs_testbench \
    "tb_alloc_metadata_flow" \
    "tb_alloc_metadata_flow" \
    "code/free_list.v" \
    "code/bank_state_table.v" \
    "code/token_register.v" \
    "code/tb/tb_alloc_metadata_flow.v"
