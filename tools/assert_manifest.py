#!/usr/bin/env python3
"""Assert generated rules_omniverse metadata."""

import argparse
import json
import sys


def main(argv):
    parser = argparse.ArgumentParser()
    parser.add_argument("--metadata", required=True)
    parser.add_argument("--kind")
    parser.add_argument("--name")
    parser.add_argument("--version")
    args = parser.parse_args(argv)

    with open(args.metadata, encoding="utf-8") as f:
        metadata = json.load(f)

    checks = {
        "kind": args.kind,
        "name": args.name,
        "version": args.version,
    }
    for key, expected in checks.items():
        if expected and str(metadata.get(key, "")) != expected:
            raise AssertionError(
                f"{key}: expected {expected!r}, got {metadata.get(key)!r}"
            )
    if "files" in metadata and len(metadata["files"]) != len(
        {item["dest"] for item in metadata["files"]}
    ):
        raise AssertionError("metadata contains duplicate file destinations")


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except Exception as exc:  # noqa: BLE001
        print(f"assert_manifest.py: error: {exc}", file=sys.stderr)
        sys.exit(1)

