#!/bin/bash
set -e

SRC_ROOT=/home/ICer/first/code
BUILD_DIR=/tmp/vcs_batch_test

rm -rf ${BUILD_DIR}
mkdir -p ${BUILD_DIR}
cd ${BUILD_DIR}

ln -sf ${SRC_ROOT}/rtl rtl
ln -sf ${SRC_ROOT}/code_by code_by
ln -sf ${SRC_ROOT}/tb tb
ln -sf ${SRC_ROOT}/sim/generated generated
cp ${SRC_ROOT}/sim/tb_batch_test.sv .

RTL=rtl
CODE_BY=code_by

VCS_FLAGS="-full64 -sverilog -timescale=1ns/1ps +v2k -debug_access+all"
INC_DIRS="+incdir+${RTL} +incdir+${RTL}/config +incdir+${RTL}/tree_control +incdir+${RTL}/transformer +incdir+${RTL}/pe_operators +incdir+${CODE_BY} +incdir+${CODE_BY}/tree_control +incdir+${CODE_BY}/transformer"

RTL_SRCS="${RTL}/transformer/floatMult16.v \
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
  tb_batch_test.sv"

echo "=== Compiling ==="
eval vcs ${VCS_FLAGS} ${INC_DIRS} ${RTL_SRCS} -o simv_batch_test 2>&1 | tail -5

echo ""
echo "=== Running ==="
./simv_batch_test 2>&1 | grep -E "===|token|output|DONE|TIMEOUT|Loaded"
