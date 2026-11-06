#!/usr/bin/env bash
# A malformed OMNI_CONTAINER_CACHE_MOUNTS entry makes container_gpu_runner.sh
# exit non-zero, name the bad entry on stderr, and not invoke docker.
set -euo pipefail
source "$(dirname "$0")/container_runner_lib.sh"

# $1: the full variable value, $2: the entry that must be reported.
check_malformed() {
  # One --forward-env is passed so the bash 3.2 empty-array bug does not
  # mask this check.
  run_runner WORKER_TOKEN=dummy OMNI_CONTAINER_CACHE_MOUNTS="$1" \
    --env ACCEPT_EULA=Y \
    --forward-env WORKER_TOKEN
  check_refused "'$1'" "$2"
}

good="/var/cache/kit:/isaac-sim/kit/cache"
check_malformed "$good,/var/cache/ov" "/var/cache/ov"       # no ':'
check_malformed ":/root/.cache/ov,$good" ":/root/.cache/ov" # empty host
check_malformed "$good,/var/cache/ov:" "/var/cache/ov:"     # empty container

finish
