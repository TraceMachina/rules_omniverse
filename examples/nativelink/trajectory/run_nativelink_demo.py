#!/usr/bin/env python3
"""Prove remote execution, remote cache reuse, and declared-input invalidation."""

from pathlib import Path
import json
import os
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

    endpoint = os.environ.get("NATIVELINK_ENDPOINT", "grpc://127.0.0.1:50051")
    original = scenario.read_bytes()
    if original.count(ORIGINAL_Y) != 1:
        print("scenario.usda is not the expected unchanged demo input", file=sys.stderr)
        return 2

    exit_code = 0
    with tempfile.TemporaryDirectory(prefix="rules-omniverse-nativelink-demo-") as temporary:
        root = Path(temporary)
        output_bases = []

        def build(label: str, expected_collisions: List[int], expect_cache_hit: bool) -> bool:
            nonlocal exit_code
            output_base = root / label.replace(" ", "-")
            output_bases.append(output_base)
            execution_log = root / (label.replace(" ", "-") + ".execlog")
            command = [
                bazel,
                f"--output_base={output_base}",
                "--ignore_all_rc_files",
                "build",
                "--enable_bzlmod",
                f"--remote_cache={endpoint}",
                f"--remote_executor={endpoint}",
                "--remote_default_exec_properties=cpu_count=1",
                "--remote_local_fallback=false",
                f"--execution_log_json_file={execution_log}",
                TARGET,
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
            expected_report = {
                "collision_indices": expected_collisions,
                "obstacle_radius": 0.25,
                "valid": not expected_collisions,
                "waypoint_count": 3,
            }
            if report != expected_report:
                print(
                    f"unexpected report: {report}",
                    file=sys.stderr,
                )
                exit_code = 1
                return False

            action_log = json.loads(execution_log.read_text(encoding="utf-8"))
            print(
                "Action evidence: "
                f"runner={action_log.get('runner')}, "
                f"cacheHit={action_log.get('cacheHit')}, "
                f"exitCode={action_log.get('exitCode')}",
                flush=True,
            )
            expected_runner = "remote cache hit" if expect_cache_hit else "remote"
            if (
                action_log.get("runner") != expected_runner
                or action_log.get("cacheHit") is not expect_cache_hit
                or action_log.get("exitCode") != 0
                or action_log.get("mnemonic") != "OmniUsdValidate"
                or action_log.get("targetLabel") != TARGET
            ):
                expected = "a NativeLink action-cache hit" if expect_cache_hit else "remote execution"
                print(f"expected {expected}, got {action_log.get('runner')}", file=sys.stderr)
                exit_code = 1
                return False
            return True

        try:
            if build("original scenario first run", [], False) and build(
                "unchanged scenario cache replay", [], True
            ):
                scenario.write_bytes(original.replace(ORIGINAL_Y, CHANGED_Y))
                if build("changed declared input", [1], False):
                    scenario.write_bytes(original)
                    build("restored scenario cache replay", [], True)
        finally:
            scenario.write_bytes(original)
            for output_base in output_bases:
                subprocess.run(
                    [bazel, f"--output_base={output_base}", "shutdown"],
                    cwd=workspace,
                    check=False,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )

    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
