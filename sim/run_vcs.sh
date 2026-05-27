#!/bin/bash
# VCS compile and run script for speculative decode e2e
# Run on VM: cd /tmp/vcs_sim && bash run_vcs.sh
#
# Prerequisites:
#   - Source files symlinked/copied from /home/ICer/first/code/
#   - Weight files in generated/ (sram_preload.memh, hbm_weights.memh)

set -e

# Source directories (relative to /tmp/vcs_sim)
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
  ${CODE_BY}/tree_control/tree_flatten.v \
  ${RTL}/transformer/tree_verify_dispatcher.sv \
  ${RTL}/transformer/tree_builder.sv \
  ${RTL}/transformer/feedback_controller.sv \
  ${RTL}/transformer/speculative_decode_e2e_top.sv \
  ${TB}/tb_speculative_decode_e2e.sv"

echo "=== VCS Compile ==="
eval vcs ${VCS_FLAGS} ${INC_DIRS} ${RTL_SRCS} -o simv 2>&1 | tee vcs_compile.log

echo ""
echo "=== VCS Run ==="
./simv 2>&1 | tee vcs_sim.log

echo ""
echo "=== Done ==="
grep -i "token\|PASS\|FAIL\|Error" vcs_sim.log || true
