#!/usr/bin/env python3
"""Inventory the H200 demo host and optionally run scoped capability probes."""

import argparse
import importlib.util
import json
import os
import platform
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any


def _command(
    command: list[str],
    timeout: int = 15,
    environment: dict[str, str] | None = None,
) -> dict[str, Any]:
    executable = shutil.which(command[0])
    if not executable:
        return {"available": False, "command": command[0]}
    try:
        result = subprocess.run(
            [executable, *command[1:]],
            capture_output=True,
            check=False,
            env=environment,
            text=True,
            timeout=timeout,
        )
        return {
            "available": True,
            "exit_code": result.returncode,
            "stderr": result.stderr.strip()[-4000:],
            "stdout": result.stdout.strip()[-12000:],
        }
    except subprocess.TimeoutExpired:
        return {"available": True, "timed_out": True}


def _module(name: str) -> bool:
    return importlib.util.find_spec(name) is not None


def _configured_usd_runtime() -> dict[str, Any]:
    python = os.environ.get("RULES_OMNIVERSE_USD_PYTHON")
    if not python:
        return {"configured": False}
    environment = os.environ.copy()
    if os.environ.get("RULES_OMNIVERSE_USD_PYTHONPATH"):
        environment["PYTHONPATH"] = os.environ["RULES_OMNIVERSE_USD_PYTHONPATH"]
    if os.environ.get("RULES_OMNIVERSE_USD_LD_LIBRARY_PATH"):
        environment["LD_LIBRARY_PATH"] = os.environ[
            "RULES_OMNIVERSE_USD_LD_LIBRARY_PATH"
        ]
    script = """
import importlib.util
import json
import platform
modules = {
    name: importlib.util.find_spec(name) is not None
    for name in (
        "pxr",
        "usd_convert_asset",
        "usd_convert_gsplat",
        "usd_optimize",
        "usd_profiles_nvidia",
        "usd_validation_nvidia",
    )
}
print(json.dumps({"modules": modules, "python": platform.python_version()}))
"""
    result = _command([python, "-c", script], environment=environment)
    result["configured"] = True
    return result


def _filesystem(path: Path) -> dict[str, Any]:
    resolved = path.resolve()
    try:
        stats = os.statvfs(resolved)
    except OSError as error:
        return {"error": str(error), "path": str(resolved)}
    return {
        "available_bytes": stats.f_bavail * stats.f_frsize,
        "block_size": stats.f_frsize,
        "path": str(resolved),
        "total_bytes": stats.f_blocks * stats.f_frsize,
    }


def _active_probes() -> dict[str, Any]:
    probes = {
        "ovphysx_gpu": _command(
            [
                sys.executable,
                "-c",
                "from ovphysx import PhysX; instance=PhysX(device='gpu'); instance.release()",
            ],
            timeout=60,
        ),
        "ovrtx_renderer_init": _command(
            [
                sys.executable,
                "-c",
                "import ovrtx; renderer=ovrtx.Renderer(); print(type(renderer).__name__)",
            ],
            timeout=180,
        ),
    }
    if shutil.which("ffmpeg"):
        probes["nvenc_h264"] = _command(
            [
                "ffmpeg",
                "-hide_banner",
                "-loglevel",
                "error",
                "-f",
                "lavfi",
                "-i",
                "color=size=128x128:rate=1",
                "-frames:v",
                "1",
                "-c:v",
                "h264_nvenc",
                "-f",
                "null",
                "-",
            ],
            timeout=45,
        )
    return probes


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--nvme-root",
        default=os.environ.get("NL_NVME_ROOT", "/"),
    )
    parser.add_argument(
        "--output",
        help="Write the JSON report to this declared output instead of stdout.",
    )
    parser.add_argument(
        "--active",
        action="store_true",
        help="Initialize GPU SDKs and attempt a one-frame NVENC encode.",
    )
    args = parser.parse_args()

    nvidia_query = [
        "nvidia-smi",
        "--query-gpu=name,uuid,driver_version,memory.total,mig.mode.current",
        "--format=csv,noheader,nounits",
    ]
    inventory = {
        "active_probes": _active_probes() if args.active else "not requested",
        "configured_usd_runtime": _configured_usd_runtime(),
        "commands": {
            "docker": _command(["docker", "version", "--format", "{{json .}}"]),
            "ffmpeg_encoders": _command(["ffmpeg", "-hide_banner", "-encoders"]),
            "nvidia_container_cli": _command(["nvidia-container-cli", "info"]),
            "nvidia_smi": _command(nvidia_query),
            "nvcc": _command(["nvcc", "--version"]),
            "vulkan": _command(["vulkaninfo", "--summary"]),
        },
        "filesystem": _filesystem(Path(args.nvme_root)),
        "host": {
            "architecture": platform.machine(),
            "hostname": platform.node(),
            "kernel": platform.release(),
            "operating_system": platform.platform(),
            "python": platform.python_version(),
        },
        "python_modules": {
            "numpy": _module("numpy"),
            "ovpackage": _module("ovpackage"),
            "ovphysx": _module("ovphysx"),
            "ovrtx": _module("ovrtx"),
            "ovstorage": _module("ovstorage"),
            "ovstream": _module("ovstream"),
            "torch": _module("torch"),
            "usd_validation_nvidia": _module("usd_validation_nvidia"),
        },
        "read_only_inventory": not args.active,
    }
    report = json.dumps(inventory, indent=2, sort_keys=True) + "\n"
    if args.output:
        Path(args.output).write_text(report, encoding="utf-8")
    else:
        print(report, end="")


if __name__ == "__main__":
    main()
