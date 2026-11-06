#!/usr/bin/env bash
# Stopping a run stops its container. With --writable-output or
# --require-nonempty-output, container_gpu_runner.sh runs the container as a
# child instead of exec'ing it, so a SIGTERM or SIGINT sent to the runner must
# make it kill the container itself at once with `docker kill` (never `docker
# stop`, which waits), hand the output back right after, exit 128 + the
# signal number, and leave no container running.
set -euo pipefail
# Job control: the runner runs in its own process group, and a background job
# does not start with SIGINT ignored, as it would without job control.
set -m

source "$(dirname "$0")/container_runner_lib.sh"

# Ends every fake container and runner this test left behind, so that a
# failing run does not leave processes holding the test's output open.
runner_pid=""
clean_up() {
  local file
  [[ -z "$runner_pid" ]] || kill -KILL "$runner_pid" 2>/dev/null || true
  for file in "$state"/containers/*; do
    [[ -e "$file" ]] && kill -KILL "$(cat "$file")" 2>/dev/null || true
  done
  return 0
}
trap clean_up EXIT

# Waits up to $1 tenths of a second for the command in the remaining
# arguments to succeed.
wait_until() {
  local tenths="$1"
  shift
  while ! "$@"; do
    ((tenths-- > 0)) || return 1
    sleep 0.1
  done
}

# Prints the signal a recorded `docker kill` call sends (KILL by default),
# without SIG and in upper case.
kill_signal() {
  local arg previous="" sent=KILL
  while IFS= read -r arg; do
    case "$previous" in -s | --signal) sent="$arg" ;; esac
    case "$arg" in --signal=*) sent="${arg#--signal=}" ;; esac
    previous="$arg"
  done < <(tail -n +2 "$1")
  sent="$(tr '[:lower:]' '[:upper:]' <<<"$sent")"
  echo "${sent#SIG}"
}

container_started() { [[ -n "$(ls "$state/containers")" ]]; }
pid_gone() { ! kill -0 "$1" 2>/dev/null; }

# Precondition: a job started like the runner gets SIGINT. If this fails, the
# test's shell is the problem, not the runner.
bash -c 'trap "exit 42" INT; while :; do sleep 0.1; done' &
probe=$!
sleep 0.5
kill -INT "$probe"
probe_status=0
wait "$probe" || probe_status=$?
if ((probe_status != 42)); then
  echo "FAIL: precondition: a background job did not get SIGINT (exit $probe_status)" >&2
  exit 1
fi

# $1: TERM or INT; $2: 128 + its number; remaining arguments: runner flags.
# Starts the runner, sends it the signal once the main container runs, and
# checks what it left behind.
check_signal() {
  local signal="$1" expected="$2" label="SIG$1 with ${*:3}"
  shift 2
  rm -rf "$work"
  mkdir -p "$out_abs"
  start_runner FAKE_MAIN_SLEEP=300 "$@" --env ACCEPT_EULA=Y

  if ! wait_until 100 container_started; then
    fail "$label: the main container did not start"
    sed 's/^/  runner stderr: /' "$stderr_file" >&2
    clean_up
    return
  fi
  local id
  id="$(ls "$state/containers")"
  local signalled_at
  signalled_at="$(date +%s)"
  kill -"$signal" "$runner_pid" || fail "$label: the runner had already exited"

  local status=0
  if wait_until 100 pid_gone "$runner_pid"; then
    wait "$runner_pid" || status=$?
  else
    fail "$label: the runner was still running 10 s after SIG$signal"
    kill -KILL "$runner_pid"
    wait "$runner_pid" || true
    status=""
  fi
  runner_pid=""

  [[ -z "$status" || "$status" == "$expected" ]] ||
    fail "$label: the runner exited $status, expected $expected (128 + SIG$signal)"

  # The runner killed its container by name or ID with `docker kill` and
  # SIGKILL, and never used `docker stop`.
  local call kill_call=""
  for call in $(ls "$state/calls" | sort -n); do
    case "$(head -n 1 "$state/calls/$call")" in
      stop) fail "$label: the runner called 'docker stop', which waits; use 'docker kill'" ;;
      kill)
        if grep -qxF -- "$id" "$state/calls/$call"; then
          [[ -n "$kill_call" ]] || kill_call="$call"
          local sent
          sent="$(kill_signal "$state/calls/$call")"
          [[ "$sent" =~ ^(KILL|9)$ ]] || fail "$label: 'docker kill' sent SIG$sent, not SIGKILL"
        fi
        ;;
    esac
  done
  [[ -n "$kill_call" ]] || fail "$label: no 'docker kill' named the container $id"

  local pid
  pid="$(cat "$state/containers/$id")"
  wait_until 20 pid_gone "$pid" ||
    fail "$label: the container $id was still running after the runner exited"

  # With --writable-output, the hand-back still runs, right after the
  # container has been killed.
  if [[ " $* " == *" --writable-output "* ]]; then
    local handback=""
    for call in $(ls "$state/calls" | sort -n); do
      grep -qxF -- 0:0 "$state/calls/$call" && handback="$call"
    done
    if [[ -z "$handback" ]]; then
      fail "$label: no ownership hand-back after the signal"
    else
      [[ -z "$kill_call" ]] || ((handback > kill_call)) ||
        fail "$label: the hand-back ran before the container was killed"
      [[ -z "$(cat "$state/handback_saw")" ]] ||
        fail "$label: the hand-back ran while the container was still running"
      # No waiting between the signal and the hand-back. Whole seconds, so
      # this allows up to just under 3 s.
      local waited=$(($(cat "$state/handback_time") - signalled_at))
      ((waited <= 2)) ||
        fail "$label: the hand-back started ${waited} s after SIG$signal; it must start right after the kill"
    fi
  fi
  clean_up
}

# As isaac_sim_action calls it.
check_signal TERM 143 --writable-output "$out_rel" --require-nonempty-output "$out_rel"
check_signal INT 130 --writable-output "$out_rel" --require-nonempty-output "$out_rel"
# Each output flag alone also runs the container as a child.
check_signal TERM 143 --writable-output "$out_rel"
check_signal TERM 143 --require-nonempty-output "$out_rel"

finish
