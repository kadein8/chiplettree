#!/usr/bin/env bash
set -eu
export PYTHON_BIN='python3'
export SYNC_STEP_JSON='/mnt/hgfs/E/Paper/Chen/first/code/runtime_exchange/session_trace_000/step_000/worker_exec/sync_tree_step_request.json'
export VCS_WORK_ROOT='/mnt/hgfs/E/Paper/Chen/first/code/runtime_exchange/session_trace_000/step_000/worker_exec/vcs'
export REAL_MODEL_NAME='Qwen/Qwen3-0.6B'
export REAL_MODEL_PATH='/mnt/hgfs/E/Paper/Chen/first/code/model/models/Qwen/Qwen3-0___6B'
exec bash 'run_tb_control_chip_stage2_single_chiplet_real_ssd_sync_tree_step_payload_bringup.sh'
