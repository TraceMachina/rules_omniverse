#!/usr/bin/env bash
# container_gpu_runner.sh passes the GPUs named in RULES_OMNIVERSE_GPU_DEVICES
# to docker as --gpus device=..., and leaves --gpus N unchanged when the
# variable is unset or empty. A list whose length differs from --gpu-count, or
# a malformed list, fails without invoking docker.
set -euo pipefail
source "$(dirname "$0")/container_runner_lib.sh"

# The command line for GPU selection GPUS; only --gpus differs between runs.
expected_argv() {
  printf '%s\n' \
    run --rm \
    --gpus "$1" \
    --network none \
    --shm-size 64g \
    --volume "$work:$work" \
    --workdir "$work" \
    --env ACCEPT_EULA=Y \
    "$image" \
    launcher.py
}

# Runs the runner with RULES_OMNIVERSE_GPU_DEVICES as given (if any) and any
# further runner flags.
run_with_devices() {
  run_runner "$@" --env ACCEPT_EULA=Y
}

run_with_devices
check_argv "unset" "$(expected_argv 1)"

run_with_devices RULES_OMNIVERSE_GPU_DEVICES=
check_argv "empty" "$(expected_argv 1)"

run_with_devices --gpu-count 2
check_argv "unset, two GPUs" "$(expected_argv 2)"

run_with_devices RULES_OMNIVERSE_GPU_DEVICES=3
check_argv "one index" "$(expected_argv device=3)"

run_with_devices RULES_OMNIVERSE_GPU_DEVICES=GPU-6f1c2a0e-7d3b-4c58-9a51-0e2b8d4f3c10
check_argv "one UUID" "$(expected_argv device=GPU-6f1c2a0e-7d3b-4c58-9a51-0e2b8d4f3c10)"

# Docker parses --gpus as CSV: the list must reach it as one quoted field.
run_with_devices RULES_OMNIVERSE_GPU_DEVICES=0,1 --gpu-count 2
check_argv "two indices" "$(expected_argv '"device=0,1"')"

run_with_devices RULES_OMNIVERSE_GPU_DEVICES=4,7,2 --gpu-count 3
check_argv "three indices" "$(expected_argv '"device=4,7,2"')"

# The selection belongs to the worker; it is not forwarded into the container.
run_with_devices RULES_OMNIVERSE_GPU_DEVICES=3
if grep -q RULES_OMNIVERSE_GPU_DEVICES "$argv_file"; then
  fail "RULES_OMNIVERSE_GPU_DEVICES was forwarded into the container"
fi

# Count mismatches.
run_with_devices RULES_OMNIVERSE_GPU_DEVICES=0,1
check_refused "two GPUs for gpu_count 1" "lists 2 GPU(s), but the action requests gpu_count 1"

run_with_devices RULES_OMNIVERSE_GPU_DEVICES=3 --gpu-count 2
check_refused "one GPU for gpu_count 2" "lists 1 GPU(s), but the action requests gpu_count 2"

# Malformed lists name the bad entry.
run_with_devices RULES_OMNIVERSE_GPU_DEVICES=0,,1 --gpu-count 2
check_refused "empty entry" "malformed RULES_OMNIVERSE_GPU_DEVICES entry ''"

run_with_devices RULES_OMNIVERSE_GPU_DEVICES=0,
check_refused "trailing comma" "malformed RULES_OMNIVERSE_GPU_DEVICES entry ''"

run_with_devices "RULES_OMNIVERSE_GPU_DEVICES=0, 1" --gpu-count 2
check_refused "space" "malformed RULES_OMNIVERSE_GPU_DEVICES entry ' 1'"

run_with_devices RULES_OMNIVERSE_GPU_DEVICES=all
check_refused "all" "malformed RULES_OMNIVERSE_GPU_DEVICES entry 'all'"

run_with_devices RULES_OMNIVERSE_GPU_DEVICES=device=0
check_refused "device= prefix" "malformed RULES_OMNIVERSE_GPU_DEVICES entry 'device=0'"

run_with_devices RULES_OMNIVERSE_GPU_DEVICES=1,1 --gpu-count 2
check_refused "duplicate" "lists GPU 1 twice"

finish
