#!/usr/bin/env bash

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/common_vcs.sh"

run_vcs_testbench \
    "tb_tree_parallel_verify" \
    "tb_tree_parallel_verify" \
    "code/rtl/tree_control/tree_flatten.v" \
    "code/rtl/tree_control/comparator.v" \
    "code/rtl/tree_control/kv_commit_copier.v" \
    "code/rtl/transformer/fp16_mha_tree_attention.sv" \
    "code/rtl/transformer/fp16_inference_top.sv" \
    "code/rtl/transformer/tree_verify_dispatcher.sv" \
    "code/code_by/tb/tb_tree_parallel_verify.sv"
