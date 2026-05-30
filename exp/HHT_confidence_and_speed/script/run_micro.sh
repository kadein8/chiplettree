#!/bin/bash
# Microbench: fp16_mha_controller seed-vs-draft equivalence (BUG 6)
set -e
SRC_ROOT=/home/ICer/first/code/exp/HHT_confidence_and_speed
BUILD_DIR=/tmp/vcs_hht_micro
LOG_DIR=${SRC_ROOT}/results
rm -rf ${BUILD_DIR}; mkdir -p ${BUILD_DIR}; cd ${BUILD_DIR}
ln -sf ${SRC_ROOT}/rtl rtl
ln -sf ${SRC_ROOT}/code_by code_by
ln -sf ${SRC_ROOT}/tb tb
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
  ${RTL}/transformer/fp16_inv_sqrt_nr.sv \
  ${RTL}/transformer/fp16_rope.sv \
  ${RTL}/transformer/fp16_mha_controller.sv \
  ${TB}/tb_mha_pathcmp.sv"
echo "=== Microbench compile ==="
eval vcs ${VCS_FLAGS} ${INC_DIRS} ${RTL_SRCS} -o simv_micro 2>&1 | tee ${LOG_DIR}/micro_compile.log
echo "=== Run ==="
./simv_micro 2>&1 | tee ${LOG_DIR}/micro_sim.log
