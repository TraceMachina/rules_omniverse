#!/usr/bin/env bash
# If the runner cannot resolve the directory behind a symlinked --input
# (cd -P fails), it prints an error naming that directory, exits non-zero and
# does not invoke the container runtime, instead of mounting an empty path.
set -euo pipefail
source "$(dirname "$0")/container_runner_lib.sh"

if [[ "$(id -u)" == 0 ]]; then
  echo "SKIP: root can enter a directory with mode 000"
  exit 0
fi

locked="$base/locked"
mkdir -p "$locked"
ln -s "$locked" "$work/data"
chmod 000 "$locked"
trap 'chmod 755 "$locked"' EXIT

run_runner --input data
check_refused "--input data" "$locked"

finish
