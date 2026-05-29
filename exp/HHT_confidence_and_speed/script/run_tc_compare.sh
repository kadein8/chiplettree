#!/bin/bash
# Run TreeControl comparison experiment (NUM_GEN_TOKENS=8)
# Usage: bash run_tc_compare.sh
# Source: code/exp/tree_control_cmp/

set -e

SRC_ROOT=/home/ICer/first/code/exp/HHT_confidence_and_speed
BUILD_DIR=/tmp/vcs_hht_exp
LOG_DIR=${SRC_ROOT}/results

rm -rf ${BUILD_DIR}
mkdir -p ${BUILD_DIR}
cd ${BUILD_DIR}

ln -sf ${SRC_ROOT}/rtl rtl
ln -sf ${SRC_ROOT}/code_by code_by
ln -sf ${SRC_ROOT}/tb tb
ln -sf /home/ICer/first/code/sim/generated generated

RTL=rtl
TB=tb/e2e
CODE_BY=code_by

VCS_FLAGS="-full64 -sverilog -timescale=1ns/1ps +v2k -debug_access+all"
# Accept PREDICT_ACCURACY from environment (default 100)
ACCURACY=${PREDICT_ACCURACY:-100}
VCS_FLAGS="${VCS_FLAGS} +define+PREDICT_ACCURACY=${ACCURACY}"
INC_DIRS="+incdir+${RTL} +incdir+${RTL}/config +incdir+${RTL}/tree_control \
  +incdir+${RTL}/transformer +incdir+${RTL}/pe_operators \
  +incdir+${CODE_BY} +incdir+${CODE_BY}/tree_control +incdir+${CODE_BY}/transformer"

RTL_SRCS="\
  ${RTL}/transformer/floatMult16.v \
  ${RTL}/transformer/floatAdd16.v \
  ${RTL}/transformer/exponent.v \
  ${RTL}/transformer/floatReciprocal.v \
  ${RTL}/transformer/systolic_matvec16_tile.sv \
  ${RTL}/transformer/fp16_matvec_tile.sv \
  ${RTL}/transformer/fp16_matvec_tile_acc.sv \
  ${RTL}/transformer/fp16_tiled_matvec.sv \
  ${RTL}/transformer/fp16_compute_module.sv \
  ${RTL}/transformer/fp16_inv_sqrt_nr.sv \
  ${RTL}/transformer/fp16_rope.sv \
  ${RTL}/transformer/fp16_silu.sv \
  ${RTL}/transformer/fp16_embedding.sv \
  ${RTL}/transformer/fp16_sampler.sv \
  ${RTL}/transformer/fp16_lm_head.sv \
  ${RTL}/transformer/fp16_transformer_layer.sv \
  ${RTL}/transformer/fp16_layer_scheduler.sv \
  ${RTL}/transformer/fp16_inference_top.sv \
  ${RTL}/transformer/fp16_inference_lc_wrapper.sv \
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
  ${RTL}/transformer/speculative_decode_e2e_top.sv \
  ${CODE_BY}/tree_control/tree_flatten.v \
  ${RTL}/transformer/tree_verify_dispatcher.sv \
  ${RTL}/transformer/tree_builder.sv \
  ${RTL}/transformer/feedback_controller.sv \
  ${TB}/tb_speculative_decode_treecontrol.sv"

echo "=== TreeControl Comparison Experiment (8 tokens) ==="
echo "Source: ${SRC_ROOT}"
eval vcs ${VCS_FLAGS} ${INC_DIRS} ${RTL_SRCS} -o simv_tc_cmp 2>&1 | tee ${LOG_DIR}/vcs_tc_cmp_compile.log

echo ""
echo "=== Running ==="
./simv_tc_cmp 2>&1 | tee ${LOG_DIR}/vcs_tc_cmp_sim.log

echo ""
echo "=== Results ==="
grep -i "token\|PASS\|FAIL\|completed\|cycles" ${LOG_DIR}/vcs_tc_cmp_sim.log || true
