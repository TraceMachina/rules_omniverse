#!/usr/bin/env python3
"""Test executable used to prove GPU execution-platform selection."""

import argparse
import json
import os
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True)
    parser.add_argument("--exec-root")
    parser.add_argument("--output")
    parser.add_argument("--output-dir", default=os.environ.get("FAKE_OUTPUT_DIR"))
    args = parser.parse_args()
    if not args.output and not args.output_dir:
        parser.error("one of --output or --output-dir is required")

    source = Path(args.input)
    result = {
        "gpu_action": True,
        "input": source.name,
        "input_bytes": source.stat().st_size,
        "exec_root": args.exec_root,
        "exec_root_test": f"exec_root_is_dot={str(args.exec_root == '.').lower()}",
    }
    report = json.dumps(result, indent=2, sort_keys=True) + "\n"
    if args.output:
        Path(args.output).write_text(report, encoding="utf-8")
    if args.output_dir:
        output_dir = Path(args.output_dir)
        output_dir.mkdir(parents=True, exist_ok=True)
        (output_dir / "result.json").write_text(report, encoding="utf-8")


if __name__ == "__main__":
    main()
