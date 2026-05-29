#!/usr/bin/env bash

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${RUN_DIR}/../.." && pwd)"
LOG_DIR="${RUN_DIR}/logs"
RUN_NAME="$(basename "${RUN_DIR}")"

VCS_BIN="${VCS_BIN:-vcs}"
VCS_OPTS="${VCS_OPTS:--full64 -sverilog -lca}"
VCS_WORK_ROOT="${VCS_WORK_ROOT:-/tmp/codex_vcs_work}"
LOCAL_RUN_WORKDIR="${VCS_WORK_ROOT}/${RUN_NAME}"

mkdir -p "${LOG_DIR}" "${LOCAL_RUN_WORKDIR}"

timestamp_now() {
    date "+%Y-%m-%d %H:%M:%S"
}

write_result_header() {
    local result_file="$1"
    local tb_name="$2"

    {
        echo "tb_name=${tb_name}"
        echo "timestamp=$(timestamp_now)"
        echo "repo_root=${REPO_ROOT}"
        echo "run_dir=${RUN_DIR}"
        echo "log_dir=${LOG_DIR}"
        echo "local_run_workdir=${LOCAL_RUN_WORKDIR}"
    } > "${result_file}"
}

append_result_kv() {
    local result_file="$1"
    local key="$2"
    local value="$3"
    echo "${key}=${value}" >> "${result_file}"
}

run_vcs_testbench() {
    local tb_name="$1"
    local top_module="$2"
    shift 2
    local source_files=("$@")

    local compile_log="${LOG_DIR}/${tb_name}_compile.log"
    local run_log="${LOG_DIR}/${tb_name}_run.log"
    local result_file="${LOG_DIR}/${tb_name}_result.txt"
    local tb_workdir="${LOCAL_RUN_WORKDIR}/${tb_name}"
    local simv_path="${tb_workdir}/${tb_name}.simv"
    local csrc_dir="${tb_workdir}/${tb_name}_csrc"

    mkdir -p "${tb_workdir}"
    write_result_header "${result_file}" "${tb_name}"
    append_result_kv "${result_file}" "top_module" "${top_module}"
    append_result_kv "${result_file}" "compile_log" "${compile_log}"
    append_result_kv "${result_file}" "run_log" "${run_log}"
    append_result_kv "${result_file}" "local_tb_workdir" "${tb_workdir}"
    append_result_kv "${result_file}" "simv_path" "${simv_path}"

    rm -f "${compile_log}" "${run_log}" "${simv_path}"
    rm -rf "${csrc_dir}" "${simv_path}.daidir"

    if ! command -v "${VCS_BIN}" >/dev/null 2>&1; then
        {
            echo "[ERROR] VCS binary not found: ${VCS_BIN}"
            echo "[ERROR] Please load the simulator environment first."
        } > "${compile_log}"
        append_result_kv "${result_file}" "compile_status" "FAIL"
        append_result_kv "${result_file}" "run_status" "SKIP"
        append_result_kv "${result_file}" "judge" "FAIL"
        append_result_kv "${result_file}" "reason" "vcs_not_found"
        return 1
    fi

    (
        cd "${tb_workdir}" || exit 1
        "${VCS_BIN}" ${VCS_OPTS} \
            +incdir+"${REPO_ROOT}/code" \
            +incdir+"${REPO_ROOT}/code/config" \
            -top "${top_module}" \
            -o "${simv_path}" \
            -Mdir="${csrc_dir}" \
            -kdb \
            "${source_files[@]/#/${REPO_ROOT}/}"
    ) > "${compile_log}" 2>&1
    local compile_rc=$?

    append_result_kv "${result_file}" "compile_rc" "${compile_rc}"

    if [[ ${compile_rc} -ne 0 || ! -x "${simv_path}" ]]; then
        append_result_kv "${result_file}" "compile_status" "FAIL"
        append_result_kv "${result_file}" "run_status" "SKIP"
        append_result_kv "${result_file}" "judge" "FAIL"
        append_result_kv "${result_file}" "reason" "compile_failed"
        return 1
    fi

    append_result_kv "${result_file}" "compile_status" "PASS"

    (
        cd "${tb_workdir}" || exit 1
        "${simv_path}"
    ) > "${run_log}" 2>&1
    local run_rc=$?

    append_result_kv "${result_file}" "run_rc" "${run_rc}"

    if grep -Eq '\\$fatal|Fatal|fatal' "${run_log}"; then
        append_result_kv "${result_file}" "run_status" "FAIL"
        append_result_kv "${result_file}" "judge" "FAIL"
        append_result_kv "${result_file}" "reason" "fatal_detected"
        return 1
    fi

    if [[ ${run_rc} -ne 0 ]]; then
        append_result_kv "${result_file}" "run_status" "FAIL"
        append_result_kv "${result_file}" "judge" "FAIL"
        append_result_kv "${result_file}" "reason" "nonzero_exit"
        return 1
    fi

    if ! grep -q "${tb_name} PASS" "${run_log}"; then
        append_result_kv "${result_file}" "run_status" "FAIL"
        append_result_kv "${result_file}" "judge" "FAIL"
        append_result_kv "${result_file}" "reason" "pass_banner_missing"
        return 1
    fi

    append_result_kv "${result_file}" "run_status" "PASS"
    append_result_kv "${result_file}" "judge" "PASS"
    append_result_kv "${result_file}" "reason" "pass_banner_detected"
    return 0
}
