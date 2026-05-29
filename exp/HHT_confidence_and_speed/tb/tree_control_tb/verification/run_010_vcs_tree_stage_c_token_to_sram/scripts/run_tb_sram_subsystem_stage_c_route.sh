#!/usr/bin/env bash

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common_vcs.sh"

run_vcs_testbench \
    "tb_sram_subsystem_stage_c_route" \
    "tb_sram_subsystem_stage_c_route" \
    "code/sram_subbank.v" \
    "code/sram_bank.v" \
    "code/sram_subsystem.v" \
    "code/tb/tb_sram_subsystem_stage_c_route.v"
