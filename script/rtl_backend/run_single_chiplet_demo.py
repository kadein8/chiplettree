import argparse
from pathlib import Path
from typing import List, Optional

from rtl_backend.rtl_driver import materialize_hbm_output_from_events
from rtl_backend.ssd_bridge import SequencePrompt, build_demo_artifacts_from_sequence
from rtl_backend.toy_decoder import ToyDecoderPackage


def parse_prompt_tokens(spec: str) -> List[int]:
    tokens = []
    for raw_part in spec.split(","):
        part = raw_part.strip()
        if not part:
            continue
        tokens.append(int(part, 0))
    return tokens


def build_argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Build a bounded single-chiplet RTL backend demo workdir."
    )
    parser.add_argument(
        "--workdir",
        required=True,
        help="Output workdir for stimulus/weights/hbm/events artifacts.",
    )
    parser.add_argument(
        "--prompt-tokens",
        default="0x10,0x11",
        help="Comma-separated prompt token ids. Supports decimal or 0x-prefixed hex.",
    )
    parser.add_argument(
        "--sequence-id",
        default="demo-seq-0",
        help="Sequence identifier recorded in the bridge request file.",
    )
    parser.add_argument(
        "--max-new-tokens",
        type=int,
        default=4,
        help="Bounded decode budget recorded in the bridge request file.",
    )
    parser.add_argument(
        "--weight-package-dir",
        help="Optional exported toy-decoder package directory to reuse instead of the demo package.",
    )
    parser.add_argument(
        "--materialize-output",
        action="store_true",
        help="Also post-process events.jsonl into hbm_output if events are available.",
    )
    parser.add_argument(
        "--include-native-tree",
        action="store_true",
        help="Inject the bounded native tree_analyze->AGU multibranch sidecar request.",
    )
    return parser


def main(argv: Optional[List[str]] = None) -> int:
    parser = build_argument_parser()
    args = parser.parse_args(argv)

    request = SequencePrompt(
        sequence_id=args.sequence_id,
        prompt_token_ids=parse_prompt_tokens(args.prompt_tokens),
        max_new_tokens=args.max_new_tokens,
    )

    workdir = Path(args.workdir)
    package = None
    if args.weight_package_dir:
        package = ToyDecoderPackage.load(Path(args.weight_package_dir))
    build_demo_artifacts_from_sequence(
        workdir,
        request,
        package=package,
        include_native_tree=args.include_native_tree,
    )

    if args.materialize_output:
        materialize_hbm_output_from_events(workdir)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
