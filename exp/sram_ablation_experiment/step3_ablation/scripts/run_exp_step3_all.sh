#!/usr/bin/env bash

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common_vcs.sh"

TB_FILE="exp/sram_ablation_experiment/step3_ablation/tb_exp_step3.v"
OVERALL_RC=0

RTL_FILES=(
    "code/rtl/tree_control/free_list.v"
    "code/rtl/tree_control/bank_state_table.v"
    "code/rtl/tree_control/request_controller.v"
    "code/rtl/tree_control/sram_bank.v"
    "code/rtl/tree_control/sram_subbank.v"
    "code/rtl/tree_control/sram_subsystem.v"
)

declare -A CONFIGS
CONFIGS[config_00_baseline]=""
CONFIGS[config_01_topology]="+define+EXP_ENABLE_TOPOLOGY"
CONFIGS[config_02_freeze_promote]="+define+EXP_ENABLE_FREEZE +define+EXP_ENABLE_PROMOTION"
CONFIGS[config_03_isolation]="+define+EXP_ENABLE_ISOLATION"
CONFIGS[config_04_all_enabled]="+define+EXP_ENABLE_TOPOLOGY +define+EXP_ENABLE_FREEZE +define+EXP_ENABLE_PROMOTION +define+EXP_ENABLE_ISOLATION"
CONFIGS[config_05_incremental]="+define+EXP_ENABLE_TOPOLOGY +define+EXP_ENABLE_FREEZE +define+EXP_ENABLE_PROMOTION +define+EXP_ENABLE_ISOLATION"

for config_name in config_00_baseline config_01_topology config_02_freeze_promote \
                   config_03_isolation config_04_all_enabled config_05_incremental; do
    CONFIG_LOG_DIR="${RUN_DIR}/logs/${config_name}"
    mkdir -p "${CONFIG_LOG_DIR}"
    SIMV_PATH="${LOCAL_RUN_WORKDIR}/${config_name}/tb_exp_step3.simv"
    CSRC_DIR="${LOCAL_RUN_WORKDIR}/${config_name}/tb_exp_step3_csrc"
    COMPILE_LOG="${CONFIG_LOG_DIR}/compile.log"
    RUN_LOG="${CONFIG_LOG_DIR}/run.log"
    SUMMARY_FILE="${CONFIG_LOG_DIR}/summary.txt"

    rm -f "${COMPILE_LOG}" "${RUN_LOG}" "${SIMV_PATH}"
    rm -rf "${CSRC_DIR}" "${SIMV_PATH}.daidir"
    mkdir -p "$(dirname "${SIMV_PATH}")"

    if ! command -v "${VCS_BIN}" >/dev/null 2>&1; then
        {
            echo "judge=FAIL"
            echo "reason=vcs_not_found"
        } > "${SUMMARY_FILE}"
        OVERALL_RC=1
        continue
    fi

    (
        cd "$(dirname "${SIMV_PATH}")" || exit 1
        "${VCS_BIN}" ${VCS_OPTS} \
            +incdir+"${REPO_ROOT}/code/rtl" \
            +incdir+"${REPO_ROOT}/code/rtl/config" \
            ${CONFIGS[${config_name}]} \
            -top tb_exp_step3 \
            -o "${SIMV_PATH}" \
            -Mdir="${CSRC_DIR}" \
            -kdb \
            "${RTL_FILES[@]/#/${REPO_ROOT}/}" \
            "${REPO_ROOT}/${TB_FILE}"
    ) > "${COMPILE_LOG}" 2>&1
    COMPILE_RC=$?

    if [[ ${COMPILE_RC} -ne 0 || ! -x "${SIMV_PATH}" ]]; then
        {
            echo "judge=FAIL"
            echo "reason=compile_failed"
            echo "compile_rc=${COMPILE_RC}"
        } > "${SUMMARY_FILE}"
        OVERALL_RC=1
        continue
    fi

    (
        cd "$(dirname "${SIMV_PATH}")" || exit 1
        "${SIMV_PATH}"
    ) > "${RUN_LOG}" 2>&1
    RUN_RC=$?

    if grep -Eq '\$fatal|Fatal|fatal' "${RUN_LOG}" || [[ ${RUN_RC} -ne 0 ]] || \
       ! grep -q "tb_exp_step3 PASS" "${RUN_LOG}"; then
        {
            echo "judge=FAIL"
            echo "reason=run_failed"
            echo "run_rc=${RUN_RC}"
        } > "${SUMMARY_FILE}"
        OVERALL_RC=1
    else
        {
            echo "judge=PASS"
            echo "reason=pass_banner_detected"
            echo "run_rc=${RUN_RC}"
        } > "${SUMMARY_FILE}"
    fi
done

exit ${OVERALL_RC}
