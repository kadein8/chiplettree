#!/bin/bash
# VCS compile and run script for speculative decode e2e
#
# Usage (on VM):
#   bash /home/ICer/first/code/sim/run_vcs_local.sh
#
# Source code is at /home/ICer/first (ln from host e:\Paper\Chen\first)
# Build artifacts go to /tmp/vcs_sim (VM local filesystem for speed)
# Logs go to /home/ICer/first/code/sim/

set -e

SRC_ROOT=/home/ICer/first/code
BUILD_DIR=/tmp/vcs_sim
LOG_DIR=${SRC_ROOT}/sim

# Create build directory
rm -rf ${BUILD_DIR}
mkdir -p ${BUILD_DIR}
cd ${BUILD_DIR}

# Symlink source trees and generated data into build dir
ln -sf ${SRC_ROOT}/rtl rtl
ln -sf ${SRC_ROOT}/code_by code_by
ln -sf ${SRC_ROOT}/tb tb
ln -sf ${SRC_ROOT}/sim/generated generated

# Paths
RTL=rtl
TB=tb/e2e
CODE_BY=code_by

VCS_FLAGS="-full64 -sverilog -timescale=1ns/1ps +v2k -debug_access+all"
INC_DIRS="+incdir+${RTL} +incdir+${RTL}/config +incdir+${RTL}/tree_control \
  +incdir+${RTL}/transformer +incdir+${RTL}/pe_operators \
  +incdir+${CODE_BY} +incdir+${CODE_BY}/tree_control +incdir+${CODE_BY}/transformer"

RTL_SRCS="\
  ${RTL}/transformer/floatMult16.v \
  ${RTL}/transformer/floatAdd16.v \
  ${RTL}/pe_operators/pe_rmsnorm_compute.v \
  ${RTL}/pe_operators/pe_silu_mul_compute.v \
  ${RTL}/pe_operators/pe_residual_add_compute.v \
  ${RTL}/pe_operators/pe_attn_compute.v \
  ${RTL}/tree_control/pe_mac_unit.v \
  ${RTL}/tree_control/pe_mac_unit_wide.v \
  ${RTL}/tree_control/PeArrayComputeOverlay.v \
  ${RTL}/tree_control/PeArrayNonlinearUnit.v \
  ${RTL}/tree_control/PeArrayLayerController.v \
  ${RTL}/tree_control/HHTContextPredictor.v \
  ${RTL}/tree_control/request_controller.v \
  ${RTL}/tree_control/multicast_network.v \
  ${RTL}/tree_control/issue_bundle_adapter.v \
  ${RTL}/tree_control/branch_parallel_controller.sv \
  ${RTL}/tree_control/draft_injection_interface.sv \
  ${RTL}/tree_control/longest_path_comparator.sv \
  ${RTL}/tree_control/kv_share_scheduler.sv \
  ${RTL}/tree_control/tree_to_native_bridge.sv \
  ${RTL}/tree_control/StrictTreeMaskPaperPath.v \
  ${RTL}/tree_control/branch_parallel_scheduler.sv \
  ${RTL}/tree_control/multi_token_emitter.sv \
  ${RTL}/transformer/speculative_decode_treecontrol_top.sv \
  ${RTL}/transformer/speculative_decode_final_top.sv \
  ${CODE_BY}/tree_control/tree_flatten.v \
  ${RTL}/transformer/tree_verify_dispatcher.sv \
  ${RTL}/transformer/tree_builder.sv \
  ${RTL}/transformer/feedback_controller.sv \
  ${RTL}/transformer/speculative_decode_e2e_top.sv \
  ${TB}/tb_speculative_decode_e2e.sv"

if [ -z "${1}" ]; then
echo "=== VCS Compile (build in ${BUILD_DIR}) ==="
echo "Source root: ${SRC_ROOT}"
eval vcs ${VCS_FLAGS} ${INC_DIRS} ${RTL_SRCS} -o simv 2>&1 | tee ${LOG_DIR}/vcs_compile.log

echo ""
echo "=== VCS Run ==="
./simv 2>&1 | tee ${LOG_DIR}/vcs_sim.log

echo ""
echo "=== Results ==="
grep -i "token\|PASS\|FAIL\|Error" ${LOG_DIR}/vcs_sim.log || true
echo ""
echo "Logs at:"
echo "  ${LOG_DIR}/vcs_compile.log"
echo "  ${LOG_DIR}/vcs_sim.log"
fi

# =========================================================================
# Optional: TreeControl path testbench (run with: bash run_vcs_local.sh tc)
# =========================================================================
if [ "${1}" = "tc" ]; then
    echo ""
    echo "=== VCS Compile (TreeControl TB) ==="
    TC_SRCS="${RTL_SRCS/${TB}/tb_speculative_decode_e2e.sv/${TB}/tb_speculative_decode_treecontrol.sv}"
    # Replace e2e tb with treecontrol tb
    TC_RTL_SRCS=$(echo "${RTL_SRCS}" | sed "s|${TB}/tb_speculative_decode_e2e.sv|${TB}/tb_speculative_decode_treecontrol.sv|")
    eval vcs ${VCS_FLAGS} ${INC_DIRS} ${TC_RTL_SRCS} -o simv_tc 2>&1 | tee ${LOG_DIR}/vcs_tc_compile.log

    echo ""
    echo "=== VCS Run (TreeControl) ==="
    ./simv_tc 2>&1 | tee ${LOG_DIR}/vcs_tc_sim.log

    echo ""
    echo "=== TreeControl Results ==="
    grep -i "token\|PASS\|FAIL\|Error\|TC_TOP\|BRIDGE" ${LOG_DIR}/vcs_tc_sim.log || true
fi

# =========================================================================
# Optional: Final architecture testbench (run with: bash run_vcs_local.sh final)
# =========================================================================
if [ "${1}" = "final" ]; then
    echo ""
    echo "=== VCS Compile (Final Architecture TB) ==="
    FINAL_RTL_SRCS=$(echo "${RTL_SRCS}" | sed "s|${TB}/tb_speculative_decode_e2e.sv|${TB}/tb_speculative_decode_final.sv|")
    eval vcs ${VCS_FLAGS} ${INC_DIRS} ${FINAL_RTL_SRCS} -o simv_final 2>&1 | tee ${LOG_DIR}/vcs_final_compile.log

    echo ""
    echo "=== VCS Run (Final Architecture) ==="
    ./simv_final 2>&1 | tee ${LOG_DIR}/vcs_final_sim.log

    echo ""
    echo "=== Final Architecture Results ==="
    grep -i "token\|PASS\|FAIL\|Error\|FINAL\|COMPARATOR\|EMITTER\|BR_SCHED" ${LOG_DIR}/vcs_final_sim.log || true
fi
