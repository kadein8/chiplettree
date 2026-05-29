import argparse
import time
from pathlib import Path
from typing import Dict, List, Optional

from shared_runtime_bridge.bridge import SharedFolderVmBackendPoller


def build_argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Poll a shared folder and execute the bounded RTL backend per step."
    )
    subparsers = parser.add_subparsers(dest="command")

    serve_parser = subparsers.add_parser("serve")
    serve_parser.add_argument("--session-root", required=True)
    serve_parser.add_argument("--backend-script", required=True)
    serve_parser.add_argument("--run-name", required=True)
    serve_parser.add_argument("--python-bin", default="python3")
    serve_parser.add_argument("--worker-name", default="vm_poller")
    serve_parser.add_argument("--poll-interval-ms", type=int, default=200)
    serve_parser.add_argument("--idle-timeout-seconds", type=float, default=None)
    serve_parser.add_argument("--local-exec-root")
    serve_parser.add_argument("--real-model-path")
    serve_parser.add_argument("--real-draft-model-path")
    serve_parser.add_argument("--real-weight-fixture-json")
    serve_parser.add_argument("--real-model-name")
    serve_parser.add_argument("--token-vocab-json")
    serve_parser.add_argument("--draft-table-json")
    serve_parser.add_argument("--recompute-table-json")
    serve_parser.add_argument("--result-decode-table-json")
    return parser


def _build_executor(args: argparse.Namespace) -> object:
    from rtl_runtime.runtime_loop import ShellSyncRuntimeBackendRunner  # type: ignore

    extra_env = {}  # type: Dict[str, str]
    for key, value in (
        ("REAL_MODEL_PATH", args.real_model_path),
        ("REAL_DRAFT_MODEL_PATH", args.real_draft_model_path),
        ("REAL_WEIGHT_FIXTURE_JSON", args.real_weight_fixture_json),
        ("REAL_MODEL_NAME", args.real_model_name),
        ("TOKEN_VOCAB_JSON", args.token_vocab_json),
        ("DRAFT_TABLE_JSON", args.draft_table_json),
        ("RECOMPUTE_TABLE_JSON", args.recompute_table_json),
        ("RESULT_DECODE_TABLE_JSON", args.result_decode_table_json),
    ):
        if value:
            extra_env[key] = str(value)

    return ShellSyncRuntimeBackendRunner(
        backend_script=Path(args.backend_script),
        run_name=str(args.run_name),
        extra_env=extra_env,
        python_bin=str(args.python_bin),
    )


def main(argv: Optional[List[str]] = None) -> int:
    parser = build_argument_parser()
    args = parser.parse_args(argv)

    if getattr(args, "command", None) != "serve":
        parser.print_usage()
        return 2

    executor = _build_executor(args)
    poller = SharedFolderVmBackendPoller(
        session_root=Path(args.session_root),
        backend_executor=executor,
        worker_name=str(args.worker_name),
        local_exec_root=(
            None
            if not args.local_exec_root
            else Path(args.local_exec_root)
        ),
    )

    idle_timeout_seconds = (
        None
        if args.idle_timeout_seconds is None
        else float(args.idle_timeout_seconds)
    )
    idle_deadline = None  # type: Optional[float]
    poll_sleep = float(int(args.poll_interval_ms)) / 1000.0

    while True:
        handled = poller.process_next_request()
        if handled:
            idle_deadline = None
        else:
            if idle_timeout_seconds is not None:
                if idle_deadline is None:
                    idle_deadline = time.time() + idle_timeout_seconds
                elif time.time() >= idle_deadline:
                    break
            time.sleep(poll_sleep)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
