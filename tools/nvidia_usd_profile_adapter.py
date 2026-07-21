#!/usr/bin/env python3
"""Profile an OpenUSD stage with NVIDIA Usd Optimize's Stats operation."""

import argparse
import importlib.metadata
import json
import os
from pathlib import Path
import sys
from typing import Any


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


def _distribution_version(name: str) -> str:
    try:
        return importlib.metadata.version(name)
    except importlib.metadata.PackageNotFoundError:
        return "source checkout"


def _set_stage(context: Any, stage: Any, usd_utils: Any) -> None:
    """Support both current and older Usd Optimize ExecutionContext APIs."""
    if hasattr(context, "set_stage"):
        context.set_stage(stage)
    else:
        context.usdStageId = usd_utils.StageCache().Get().Insert(stage).ToLongInt()


def _decode_stats(payload: Any) -> dict[str, Any]:
    if payload is None:
        return {}
    if isinstance(payload, str):
        payload = json.loads(payload)
    if not isinstance(payload, dict):
        raise TypeError("Usd Optimize Stats returned a non-object payload")
    analysis = payload.get("analysis", payload)
    if not isinstance(analysis, dict):
        raise TypeError("Usd Optimize Stats returned a non-object analysis")
    return analysis


def main() -> None:
    _reexec_configured_runtime()
    parser = argparse.ArgumentParser()
    parser.add_argument("--operation", choices=("profile",), required=True)
    parser.add_argument("--input", required=True)
    parser.add_argument("--report", required=True)
    parser.add_argument(
        "--sample-prim-limit",
        default=32,
        type=int,
        help="Maximum number of representative prim paths written to the report.",
    )
    parser.add_argument(
        "--count-primvars",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Ask the NVIDIA Stats operation to include primvar counts.",
    )
    args = parser.parse_args()

    try:
        from pxr import Usd, UsdGeom, UsdUtils
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

    core = UsdOptimizeCore.getInstance()
    available_operations = set(core.getOperations())
    if "printStats" not in available_operations:
        raise SystemExit("the installed usd-optimize runtime does not expose printStats")

    success, error, payload = core.executeOperation(
        "printStats",
        context,
        {"countPrimvars": args.count_primvars},
    )
    if not success:
        raise SystemExit(f"usd-optimize printStats failed: {error}")

    default_prim = stage.GetDefaultPrim()
    prim_paths = []
    if args.sample_prim_limit > 0:
        for prim in stage.Traverse():
            prim_paths.append(str(prim.GetPath()))
            if len(prim_paths) >= args.sample_prim_limit:
                break

    source = Path(args.input)
    report = {
        "input": source.name,
        "operation": "profile",
        "profiler": "NVIDIA usd-optimize",
        "runtime": {
            "openusd": ".".join(str(part) for part in Usd.GetVersion()),
            "usd_optimize": _distribution_version("usd-optimize"),
        },
        "source_bytes": source.stat().st_size,
        "stage": {
            "default_prim": str(default_prim.GetPath()) if default_prim else None,
            "end_time_code": stage.GetEndTimeCode(),
            "frames_per_second": stage.GetFramesPerSecond(),
            "layer_count": len(stage.GetUsedLayers()),
            "meters_per_unit": UsdGeom.GetStageMetersPerUnit(stage),
            "sample_prim_paths": prim_paths,
            "start_time_code": stage.GetStartTimeCode(),
            "time_codes_per_second": stage.GetTimeCodesPerSecond(),
            "up_axis": str(UsdGeom.GetStageUpAxis(stage)),
            "used_layers": sorted(layer.identifier for layer in stage.GetUsedLayers()),
        },
        "statistics": _decode_stats(payload),
    }
    output = Path(args.report)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
