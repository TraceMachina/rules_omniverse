#!/usr/bin/env python3
"""Run a local cache-hit and declared-input-change demo with a fresh output base."""

from pathlib import Path
import json
import shutil
import subprocess
import sys
import tempfile
from typing import List


TARGET = "//examples/nativelink/trajectory:trajectory_report"
ORIGINAL_Y = b"custom double[] waypointY = [0.0, 0.0, 0.0]"
CHANGED_Y = b"custom double[] waypointY = [1.0, 1.0, 1.0]"


def main() -> int:
    workspace = Path(__file__).resolve().parents[3]
    scenario = Path(__file__).resolve().with_name("scenario.usda")
    bazel = shutil.which("bazel")
    if not bazel:
        print("bazel was not found on PATH; install Bazelisk first", file=sys.stderr)
        return 2

    original = scenario.read_bytes()
    if original.count(ORIGINAL_Y) != 1:
        print("scenario.usda is not the expected unchanged demo input", file=sys.stderr)
        return 2

    exit_code = 0
    with tempfile.TemporaryDirectory(prefix="rules-omniverse-cache-demo-") as temporary:
        output_base = Path(temporary) / "bazel-output-base"
        startup_options = [
            f"--output_base={output_base}",
            "--ignore_all_rc_files",
        ]

        def build(label: str, expected_collisions: List[int]) -> bool:
            nonlocal exit_code
            command = [
                bazel,
                *startup_options,
                "build",
                TARGET,
                "--enable_bzlmod",
                "--remote_cache=",
                "--remote_executor=",
            ]
            print(f"\n===== {label} =====", flush=True)
            print("$ " + " ".join(command), flush=True)
            result = subprocess.run(command, cwd=workspace, check=False)
            if result.returncode:
                exit_code = result.returncode
                return False
            report_path = (
                workspace
                / "bazel-bin/examples/nativelink/trajectory/trajectory_report.validation.json"
            )
            report = json.loads(report_path.read_text(encoding="utf-8"))
            print("Report:")
            print(json.dumps(report, indent=2, sort_keys=True), flush=True)
            if report["collision_indices"] != expected_collisions:
                print(
                    f"unexpected collision indices: {report['collision_indices']}",
                    file=sys.stderr,
                )
                exit_code = 1
                return False
            return True

        try:
            if build("original scenario (first build)", []) and build(
                "same scenario (should be cached)", []
            ):
                scenario.write_bytes(original.replace(ORIGINAL_Y, CHANGED_Y))
                if build("changed declared waypoint input (should execute again)", [1]):
                    scenario.write_bytes(original)
                    build("restored original scenario (may execute again locally)", [])
        finally:
            scenario.write_bytes(original)
            shutdown = subprocess.run(
                [bazel, *startup_options, "shutdown"],
                cwd=workspace,
                check=False,
            )
            if shutdown.returncode and not exit_code:
                exit_code = shutdown.returncode

    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
