#!/usr/bin/env bash

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common_vcs.sh"
SUMMARY_FILE="${RUN_DIR}/logs/step1_summary.txt"

run_vcs_testbench \
    "tb_exp_step1" \
    "tb_exp_step1" \
    "code/rtl/tree_control/KVLocationTable.v" \
    "code/rtl/tree_control/KVStateTable.v" \
    "code/rtl/tree_control/RecomputeControl.v" \
    "code/rtl/tree_control/HHTStateTable.v" \
    "code/rtl/tree_control/HHTContextPredictor.v" \
    "code/rtl/tree_control/IntegrationPredictionPart.v" \
    "code/rtl/tree_control/PredictionWindowSerialDispatcher.v" \
    "code/rtl/tree_control/PredictionWindowAguBridge.v" \
    "code/rtl/tree_control/PredictionWindowOwnershipClosureSidecar.v" \
    "code/rtl/tree_control/NativeTreeOwnershipClosureSidecar.v" \
    "code/rtl/tree_control/Stage2TopWritebackHbmShim.v" \
    "code/rtl/tree_control/IntegrationTreeControlPart.v" \
    "code/rtl/tree_control/IntegrationWritebackPart.v" \
    "code/rtl/tree_control/tree_analyze.v" \
    "code/rtl/tree_control/agu.v" \
    "code/rtl/tree_control/prefetch_queue.v" \
    "code/rtl/tree_control/free_list.v" \
    "code/rtl/tree_control/bank_state_table.v" \
    "code/rtl/tree_control/token_register.v" \
    "code/rtl/tree_control/request_controller.v" \
    "code/rtl/tree_control/sram_bank.v" \
    "code/rtl/tree_control/sram_subbank.v" \
    "code/rtl/tree_control/sram_subsystem.v" \
    "code/rtl/tree_control/control_chip_stage2_single_chiplet.v" \
    "code/rtl/transformer/floatAdd16.v" \
    "code/rtl/transformer/floatMult16.v" \
    "code/rtl/transformer/processingElement16.v" \
    "code/rtl/transformer/transformUnit1x1.v" \
    "code/rtl/transformer/transformLayerSingle1x1.v" \
    "code/rtl/transformer/transformLayerMulti1x1.v" \
    "code/rtl/transformer/ToyDecoderWeightBank.v" \
    "code/rtl/transformer/decoderAttentionScore.v" \
    "code/rtl/transformer/decoderSoftmaxWindow.v" \
    "code/rtl/transformer/decoderAttentionValue.v" \
    "code/rtl/transformer/decoderFfnUnit.v" \
    "code/rtl/transformer/decoderOnlyTransformerChain.v" \
    "code/rtl/transformer/IntegrationTransformPart.v" \
    "exp/sram_ablation_experiment/step1_functional_verification/tb_exp_step1.v"
rc=$?

{
    echo "run_name=exp_step1_functional_verification"
    echo "timestamp=$(date '+%Y-%m-%d %H:%M:%S')"
    echo "running=run_exp_step1.sh"
    echo "scope=control_chip_stage2_single_chiplet_two_round_functional"
    echo "exit_code_run_exp_step1.sh=${rc}"
    if [[ ${rc} -eq 0 ]]; then
        echo "judge=PASS"
    else
        echo "judge=FAIL"
    fi
} > "${SUMMARY_FILE}"

exit ${rc}
