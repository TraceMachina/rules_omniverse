#!/usr/bin/env python3
"""Optimize an OpenUSD stage with NVIDIA Usd Optimize."""

import argparse
import json
import os
from pathlib import Path
import sys
from typing import Any


_PIPELINES = {
    "load-time-reduction": [
        {"operation": "computeExtents"},
        {"operation": "pruneLeaves"},
        {"operation": "optimizeTimeSamples"},
        {"operation": "optimizeMaterials"},
    ],
    "memory-reduction": [
        {"operation": "deduplicateGeometry", "considerInstanceability": True},
        {"operation": "optimizeMaterials"},
        {"operation": "pruneLeaves"},
    ],
    "safe-cleanup": [
        {"operation": "computeExtents"},
        {"operation": "pruneLeaves"},
        {"operation": "deduplicateGeometry", "considerInstanceability": True},
        {"operation": "optimizeMaterials"},
        {"operation": "optimizeTimeSamples"},
    ],
}


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


def _set_stage(context: Any, stage: Any, usd_utils: Any) -> None:
    if hasattr(context, "set_stage"):
        context.set_stage(stage)
    else:
        context.usdStageId = usd_utils.StageCache().Get().Insert(stage).ToLongInt()


def _operations(args: argparse.Namespace) -> list[dict[str, Any]]:
    if args.operations_json:
        try:
            operations = json.loads(args.operations_json)
        except json.JSONDecodeError as error:
            raise SystemExit(f"--operations-json is invalid: {error}") from error
    else:
        operations = _PIPELINES[args.pipeline]
    if not isinstance(operations, list) or not operations:
        raise SystemExit("optimization configuration must be a non-empty JSON list")
    normalized = []
    for index, value in enumerate(operations):
        if not isinstance(value, dict) or not isinstance(value.get("operation"), str):
            raise SystemExit(f"optimization entry {index} must contain a string operation")
        normalized.append(dict(value))
    return normalized


def main() -> None:
    _reexec_configured_runtime()
    parser = argparse.ArgumentParser()
    parser.add_argument("--operation", choices=("optimize",), required=True)
    parser.add_argument("--input", required=True)
    parser.add_argument("--output", required=True)
    config = parser.add_mutually_exclusive_group()
    config.add_argument(
        "--pipeline",
        choices=tuple(sorted(_PIPELINES)),
        default="safe-cleanup",
        help="Named, lossless NVIDIA Usd Optimize operation chain.",
    )
    config.add_argument(
        "--operations-json",
        help="Explicit JSON list of Usd Optimize operation objects.",
    )
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()

    try:
        from pxr import Usd, UsdUtils
        from usd_optimize.core import ExecutionContext, UsdOptimizeCore
    except ImportError as error:
        raise SystemExit(
            "NVIDIA usd-optimize and a compatible OpenUSD Python runtime are "
            "required in this execution environment"
        ) from error

    stage = Usd.Stage.Open(args.input)
    if stage is None:
        raise SystemExit(f"failed to open OpenUSD stage: {args.input}")
    context = ExecutionContext()
    _set_stage(context, stage, UsdUtils)
    if hasattr(context, "generateReport"):
        context.generateReport = 1
    if hasattr(context, "captureStats"):
        context.captureStats = 1
    if hasattr(context, "verbose"):
        context.verbose = 1 if args.verbose else 0

    core = UsdOptimizeCore.getInstance()
    available = set(core.getOperations())
    failures = []
    for operation in _operations(args):
        operation_name = operation.pop("operation")
        if operation_name not in available:
            failures.append(f"{operation_name}: operation is unavailable")
            continue
        success, error, _ = core.executeOperation(operation_name, context, operation)
        if not success:
            failures.append(f"{operation_name}: {error}")
    if failures:
        raise SystemExit("usd-optimize failed:\n  " + "\n  ".join(failures))

    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    if not stage.GetRootLayer().Export(str(output)):
        raise SystemExit(f"failed to export optimized stage: {output}")
    if not output.is_file() or output.stat().st_size == 0:
        raise SystemExit(f"optimizer did not produce a non-empty output: {output}")


if __name__ == "__main__":
    main()
