#!/usr/bin/env bash
# isaac_sim_platform adds the container runtime constraint and the
# container-runtime / worker_runtime exec properties while keeping the
# omni_gpu_platform ones and the caller's own values. $1 is the genquery
# --output=build dump of //tests/isaac_sim/rules:h200_platform.
set -euo pipefail

query="$1"
failures=0

expect() {
  if ! grep -F -- "$1" "$query" >/dev/null; then
    echo "FAIL: expected $1" >&2
    failures=$((failures + 1))
  fi
}

expect '"worker_runtime": "nvidia-driver-580.65.06"'
expect '"container-runtime": "docker"'
expect '"gpu_count": "8"'
expect '"gpu_model": "H200"'
expect '"OSFamily": "Linux"'
expect '"//omniverse/constraints:oci_container_runtime"'
expect '"//omniverse/constraints:nvidia_gpu"'
expect 'platforms//os:linux"'

if ((failures)); then
  echo "--- platform as expanded by bazel query:" >&2
  cat "$query" >&2
  exit 1
fi
echo "PASS"
