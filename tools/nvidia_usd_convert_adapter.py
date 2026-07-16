#!/usr/bin/env python3
"""Convert assets to OpenUSD with NVIDIA's standalone conversion libraries."""

import argparse
import os
import subprocess
import sys
from pathlib import Path


_USD_EXTENSIONS = {".usd", ".usda", ".usdc", ".usdz"}


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


def _run_gsplat(source: Path, output: Path, extra_args: list[str]) -> None:
    command = [
        sys.executable,
        "-m",
        "usd_convert_gsplat",
        "--input",
        str(source),
        "--output",
        str(output),
        *extra_args,
    ]
    try:
        subprocess.run(command, check=True)
    except ModuleNotFoundError as error:
        raise SystemExit(
            "usd-convert-gsplat is not installed in this execution environment"
        ) from error
    except subprocess.CalledProcessError as error:
        raise SystemExit(f"usd-convert-gsplat failed with exit code {error.returncode}") from error


def _run_asset_converter(source: Path, output: Path, extra_args: list[str]) -> None:
    try:
        from usd_convert_asset.cli import main as convert_asset
    except ImportError as error:
        raise SystemExit(
            "usd-convert-asset is not installed in this execution environment"
        ) from error
    status = convert_asset(
        ["--input", str(source), "--output", str(output), *extra_args]
    )
    if status:
        raise SystemExit(f"usd-convert-asset failed with exit code {status}")


def _run_openusd(source: Path, output: Path) -> None:
    try:
        from pxr import Sdf, UsdUtils
    except ImportError as error:
        raise SystemExit(
            "a compatible OpenUSD Python runtime is not installed in this execution environment"
        ) from error

    if output.suffix.lower() == ".usdz":
        if not UsdUtils.CreateNewUsdzPackage(Sdf.AssetPath(str(source)), str(output)):
            raise SystemExit(f"failed to package {source} as {output}")
        return

    layer = Sdf.Layer.FindOrOpen(str(source))
    if layer is None:
        raise SystemExit(f"failed to open OpenUSD layer: {source}")
    if not layer.Export(str(output)):
        raise SystemExit(f"failed to export OpenUSD layer: {output}")


def main() -> None:
    _reexec_configured_runtime()
    parser = argparse.ArgumentParser()
    parser.add_argument("--operation", choices=("convert",), required=True)
    parser.add_argument("--input", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument(
        "--backend",
        choices=("auto", "asset", "gsplat", "openusd"),
        default="auto",
        help="Select an NVIDIA converter or infer it from the source extension.",
    )
    parser.add_argument(
        "--converter-arg",
        action="append",
        default=[],
        help="Forward one argument to the selected converter; use --converter-arg=--flag.",
    )
    args = parser.parse_args()

    source = Path(args.input)
    output = Path(args.output)
    if not source.is_file():
        raise SystemExit(f"input asset does not exist: {source}")
    if output.suffix.lower() not in _USD_EXTENSIONS:
        raise SystemExit("output must use .usd, .usda, .usdc, or .usdz")
    output.parent.mkdir(parents=True, exist_ok=True)

    backend = args.backend
    if backend == "auto":
        if source.suffix.lower() in {".ply", ".spz"}:
            backend = "gsplat"
        elif source.suffix.lower() in _USD_EXTENSIONS:
            backend = "openusd"
        else:
            backend = "asset"

    if backend == "gsplat":
        _run_gsplat(source, output, args.converter_arg)
    elif backend == "asset":
        _run_asset_converter(source, output, args.converter_arg)
    else:
        if args.converter_arg:
            raise SystemExit("--converter-arg is not supported by the openusd backend")
        _run_openusd(source, output)

    if not output.is_file() or output.stat().st_size == 0:
        raise SystemExit(f"converter did not produce a non-empty output: {output}")


if __name__ == "__main__":
    main()
