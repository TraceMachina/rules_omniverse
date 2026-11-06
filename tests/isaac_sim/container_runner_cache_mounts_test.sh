#!/usr/bin/env bash
# container_gpu_runner.sh adds one --volume per OMNI_CONTAINER_CACHE_MOUNTS
# entry, and leaves the docker command line unchanged when the variable is
# unset or empty.
set -euo pipefail
source "$(dirname "$0")/container_runner_lib.sh"

container_args=(launcher.py --scene scene.usda)

# Runs the runner with a fixed set of runner flags. Extra leading arguments
# are environment assignments. One --forward-env is always passed because the
# runner once aborted on macOS bash 3.2 when that list was empty.
run_with_mounts() {
  run_runner WORKER_TOKEN=dummy "$@" \
    --runtime docker \
    --shm-size 1g \
    --network host \
    --entrypoint /isaac-sim/python.sh \
    --env ACCEPT_EULA=Y \
    --forward-env WORKER_TOKEN
}

# The command line the runner produces today. Unset/empty must match exactly.
expected_unset="$(printf '%s\n' \
  run --rm \
  --gpus 1 \
  --network host \
  --shm-size 1g \
  --volume "$work:$work" \
  --workdir "$work" \
  --entrypoint /isaac-sim/python.sh \
  --env ACCEPT_EULA=Y \
  --env WORKER_TOKEN \
  "$image" \
  launcher.py --scene scene.usda)"

run_with_mounts
check_argv "unset" "$expected_unset"

run_with_mounts OMNI_CONTAINER_CACHE_MOUNTS=
check_argv "empty" "$expected_unset"

# Checks a run with mounts set: the --volume flags added are exactly the given
# mounts, in the given order, each before the image; removing them gives back
# exactly the unchanged argv; and the variable itself is not forwarded into
# the container.
check_mounts() {
  local label="$1"
  shift
  check_invoked "$label" || return 0
  split_volumes "$label"
  if [[ "$added" != "$(printf '%s\n' "$@")" ]]; then
    fail "$label: cache --volume flags differ from the entries, in order"
    diff <(printf '%s\n' "$@") <(echo "$added") | sed 's/^/  /' >&2 || true
  fi
  if [[ "$remaining" != "$expected_unset" ]]; then
    fail "$label: argv differs beyond the added cache volumes"
    diff <(echo "$expected_unset") <(echo "$remaining") | sed 's/^/  /' >&2 || true
  fi
  if grep -q OMNI_CONTAINER_CACHE_MOUNTS "$argv_file"; then
    fail "$label: OMNI_CONTAINER_CACHE_MOUNTS was forwarded into the container"
  fi
}

run_with_mounts OMNI_CONTAINER_CACHE_MOUNTS=/var/cache/ov:/root/.cache/ov
check_mounts "one mount" /var/cache/ov:/root/.cache/ov

run_with_mounts OMNI_CONTAINER_CACHE_MOUNTS=/var/cache/ov:/root/.cache/ov,/var/cache/kit:/isaac-sim/kit/cache
check_mounts "two mounts" /var/cache/ov:/root/.cache/ov /var/cache/kit:/isaac-sim/kit/cache

finish
