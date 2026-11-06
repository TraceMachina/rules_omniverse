#!/usr/bin/env bash
# With --require-nonempty-output DIR, container_gpu_runner.sh fails when the
# container exits 0 but left DIR empty (Kit exits 0 even when the script
# raises), and names DIR. Without the flag nothing changes.
set -euo pipefail
source "$(dirname "$0")/container_runner_lib.sh"

# $1: "flag" to pass --require-nonempty-output DIR, "no_flag" otherwise;
# $2: "existing" to create DIR first (as Bazel does locally), "missing" not to.
# Remaining arguments are env assignments for the fake docker. Sets $status.
run_with_output() {
  local flag="$1" dir="$2"
  shift 2
  rm -rf "$work"
  mkdir -p "$work/$(dirname "$out_rel")"
  [[ "$dir" == existing ]] && mkdir "$out_abs"
  local -a flags=()
  [[ "$flag" == flag ]] && flags=(--require-nonempty-output "$out_rel")
  run_runner "$@" ${flags[@]+"${flags[@]}"} --env ACCEPT_EULA=Y
}

# Exit 0 from the container with nothing usable in DIR must fail, naming DIR.
check_empty_fails() {
  local label="$1"
  check_invoked "$label" || return 0
  ((status != 0)) || fail "$label: runner exited 0"
  if ! grep -qF -- "$out_rel" "$stderr_file" || ! grep -qi empty "$stderr_file"; then
    fail "$label: stderr does not name $out_rel and say it is empty"
    show_stderr
  fi
}

run_with_output flag existing FAKE_WRITE=nothing
check_empty_fails "writes nothing"

run_with_output flag existing FAKE_WRITE=empty_dir
check_empty_fails "writes only an empty subdirectory"

run_with_output flag missing FAKE_WRITE=nothing
check_empty_fails "DIR never created"

label="writes a frame"
run_with_output flag existing FAKE_WRITE=file
if check_invoked "$label" && ((status != 0)); then
  fail "$label: runner exited $status"
  show_stderr
fi

# A failing container keeps its own exit status.
label="container exits 4"
run_with_output flag existing FAKE_WRITE=nothing FAKE_MAIN_STATUS=4
if check_invoked "$label"; then
  ((status == 4)) || fail "$label: runner exited $status, expected 4"
fi

# Without the flag (every existing omni_container_gpu_action), empty is fine.
label="no flag, writes nothing"
run_with_output no_flag existing FAKE_WRITE=nothing
if check_invoked "$label"; then
  ((status == 0)) || fail "$label: runner exited $status, expected 0"
fi

finish
