#!/bin/bash
# Real-weight prefill-vs-decode test (BUG 6)
set -e
SRC_ROOT=/home/ICer/first/code/exp/HHT_confidence_and_speed
BUILD_DIR=/tmp/vcs_hht_pvd
LOG_DIR=${SRC_ROOT}/results
rm -rf ${BUILD_DIR}; mkdir -p ${BUILD_DIR}; cd ${BUILD_DIR}
ln -sf ${SRC_ROOT}/rtl rtl
ln -sf ${SRC_ROOT}/code_by code_by
ln -sf ${SRC_ROOT}/tb tb
ln -sf /home/ICer/first/code/sim/generated generated
RTL=rtl; TB=tb/e2e; CODE_BY=code_by
VCS_FLAGS="-full64 -sverilog -timescale=1ns/1ps +v2k -debug_access+all"
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
  ${TB}/tb_prefill_vs_decode.sv"
echo "=== PVD compile ==="
eval vcs ${VCS_FLAGS} ${INC_DIRS} ${RTL_SRCS} -o simv_pvd 2>&1 | tee ${LOG_DIR}/pvd_compile.log
echo "=== Run ==="
./simv_pvd 2>&1 | tee ${LOG_DIR}/pvd_sim.log
