#!/usr/bin/env bash
# docker kill refuses a created container. Cancellation must remove that same
# ID with rm -f and still finish ownership hand-back within a bounded wait.
set -euo pipefail
set -m
source "$(dirname "$0")/container_runner_lib.sh"

runner_pid=""
cleanup() {
  [[ -z "$runner_pid" ]] || kill -KILL "$runner_pid" 2>/dev/null || true
  local file
  for file in "$state"/containers/*; do
    [[ -e "$file" ]] && kill -KILL "$(cat "$file")" 2>/dev/null || true
  done
  return 0
}
trap cleanup EXIT

wait_until() {
  local attempts=100
  while ! "$@"; do
    ((attempts-- > 0)) || return 1
    sleep 0.05
  done
}
created() { [[ -n "$(ls "$state/containers")" ]]; }
gone() { ! kill -0 "$1" 2>/dev/null; }

mkdir -p "$out_abs"
start_runner FAKE_MAIN_SLEEP=300 FAKE_CREATED_ONLY=1 --writable-output "$out_rel"
wait_until created || { fail "container was not created"; finish; }
id="$(ls "$state/containers")"
kill -TERM "$runner_pid"
if ! wait_until gone "$runner_pid"; then
  fail "runner did not finish after kill refused the created container"
  finish
fi
status=0
wait "$runner_pid" || status=$?
runner_pid=""
[[ "$status" == 143 ]] || fail "expected cancelled exit 143, got $status"

kill_call=""
remove_call=""
for call in $(ls "$state/calls" | sort -n); do
  case "$(head -n 1 "$state/calls/$call")" in
    kill)
      grep -qxF -- "$id" "$state/calls/$call" && kill_call="$call"
      ;;
    rm)
      grep -qxF -- -f "$state/calls/$call" || fail "remove did not use -f"
      grep -qxF -- "$id" "$state/calls/$call" || fail "remove named a different container"
      remove_call="$call"
      ;;
  esac
done
[[ -n "$kill_call" ]] || fail "runner did not first try kill"
[[ -n "$remove_call" ]] || fail "runner did not remove the created container"
if [[ -n "$kill_call" && -n "$remove_call" ]]; then
  ((remove_call > kill_call)) || fail "remove did not follow failed kill"
fi
[[ -f "$state/handback_saw" ]] || fail "ownership hand-back did not run"
[[ ! -s "$state/handback_saw" ]] || fail "hand-back ran before removal completed"
finish
