#!/usr/bin/env python3
"""Adapter from omni_usd_validate to usd-validation-nvidia."""

import argparse
import json
import os
from pathlib import Path
import sys


def _reexec_configured_runtime() -> None:
    python = os.environ.get("RULES_OMNIVERSE_USD_PYTHON")
    if not python or os.environ.get("RULES_OMNIVERSE_USD_REEXEC") == "1":
        return
    environment = os.environ.copy()
    environment["RULES_OMNIVERSE_USD_REEXEC"] = "1"
    for source, destination in (
        ("RULES_OMNIVERSE_USD_PYTHONPATH", "PYTHONPATH"),
        ("RULES_OMNIVERSE_USD_LD_LIBRARY_PATH", "LD_LIBRARY_PATH"),
    ):
        if environment.get(source):
            environment[destination] = environment[source]
    os.execve(python, [python, __file__, *sys.argv[1:]], environment)


def main() -> None:
    _reexec_configured_runtime()
    parser = argparse.ArgumentParser()
    parser.add_argument("--operation", choices=("validate",), required=True)
    parser.add_argument("--input", required=True)
    parser.add_argument("--report", required=True)
    args = parser.parse_args()

    try:
        from usd_validation_nvidia import ValidationEngine
    except ImportError as error:
        raise SystemExit(
            "usd-validation-nvidia is not installed in this execution environment"
        ) from error

    results = ValidationEngine().validate(args.input)
    issues = []
    for issue in results.issues():
        issues.append(
            {
                "message": str(issue.message),
                "rule": str(getattr(issue, "rule", "")),
                "severity": str(issue.severity),
            }
        )

    report = {
        "input": Path(args.input).name,
        "issue_count": len(issues),
        "issues": issues,
        "operation": "validate",
        "validator": "usd-validation-nvidia",
    }
    Path(args.report).write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
