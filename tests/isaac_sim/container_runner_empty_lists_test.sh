#!/usr/bin/env bash
# container_gpu_runner.sh works when given no --forward-env (and no --env)
# flags. Under macOS's bash 3.2, `set -u` treats an empty array as unbound, so
# a runner that expands one unguarded aborts before calling docker. On bash
# >= 4.4 the bug does not show.
set -euo pipefail
source "$(dirname "$0")/container_runner_lib.sh"

echo "bash under test: $(bash -c 'echo $BASH_VERSION')"

base_argv=(run --rm --gpus 1 --network none --shm-size 64g --volume "$work:$work" --workdir "$work")

run_runner
check_argv "no --env, no --forward-env" \
  "$(printf '%s\n' "${base_argv[@]}" "$image" launcher.py)"

run_runner --env ACCEPT_EULA=Y
check_argv "--env only" \
  "$(printf '%s\n' "${base_argv[@]}" --env ACCEPT_EULA=Y "$image" launcher.py)"

finish
