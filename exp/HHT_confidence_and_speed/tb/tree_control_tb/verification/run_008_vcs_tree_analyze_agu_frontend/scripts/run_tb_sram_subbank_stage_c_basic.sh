#!/usr/bin/env bash

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common_vcs.sh"

run_vcs_testbench \
    "tb_sram_subbank_stage_c_basic" \
    "tb_sram_subbank_stage_c_basic" \
    "code/sram_subbank.v" \
    "code/tb/tb_sram_subbank_stage_c_basic.v"
