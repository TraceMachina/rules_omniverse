#!/usr/bin/env python3
"""Test adapter for the rules_omniverse OpenUSD action contract."""

import argparse
import json
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--operation",
        choices=("convert", "optimize", "profile", "validate"),
        required=True,
    )
    parser.add_argument("--input", required=True)
    parser.add_argument("--output")
    parser.add_argument("--report")
    args = parser.parse_args()

    source = Path(args.input)
    content = source.read_text(encoding="utf-8")

    if args.operation in ("profile", "validate"):
        if not args.report:
            parser.error("--report is required for profile and validate")
        report = {
            "bytes": len(content.encode("utf-8")),
            "input": source.name,
            "operation": args.operation,
            "prim_count": content.count('def '),
            "valid": content.startswith("#usda"),
        }
        Path(args.report).write_text(
            json.dumps(report, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        return

    if not args.output:
        parser.error("--output is required for convert and optimize")
    Path(args.output).write_text(
        f"# fake {args.operation} adapter\n{content}",
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
