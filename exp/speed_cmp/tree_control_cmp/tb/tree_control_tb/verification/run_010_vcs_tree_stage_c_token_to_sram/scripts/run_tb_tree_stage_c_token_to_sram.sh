#!/usr/bin/env bash

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common_vcs.sh"

run_vcs_testbench \
    "tb_tree_stage_c_token_to_sram" \
    "tb_tree_stage_c_token_to_sram" \
    "code/tree_analyze.v" \
    "code/agu.v" \
    "code/prefetch_queue.v" \
    "code/free_list.v" \
    "code/token_register.v" \
    "code/sram_subsystem.v" \
    "code/sram_bank.v" \
    "code/sram_subbank.v" \
    "code/tb/tb_tree_stage_c_token_to_sram.v"