# Sourced by the container_runner_*_test.sh tests, with the runner's path as
# $1: puts a fake docker first on PATH
# and runs the runner from a fake execution root with it.
#
# The fake docker. Call N writes its argv, one argument per line, to
# $state/calls/N.
# - `run` with --user 0:0 is the ownership hand-back: it writes the
#   containers running at that moment to $state/handback_saw and the time, in
#   seconds, to $state/handback_time, and exits $FAKE_HANDBACK_STATUS (0).
# - Any other `run` is the main container. It writes to $state/main_saw
#   whether $FAKE_OUTPUT was "open" (a directory with mode a+rwx), "closed" or
#   "missing", then writes into it as $FAKE_WRITE says: nothing (the
#   default), empty_dir (an empty rgb/), or file (rgb/frame_0.png, with rgb/
#   mode 0777 as the container's user would leave it). It writes its ID, its
#   --name or else cN, to its --cidfile, which must not exist yet. It exits
#   $FAKE_MAIN_STATUS (0), unless $FAKE_MAIN_SLEEP is set, for the tests of
#   stopping a run: then the container is a `sleep` of that many seconds in
#   a process of its own, which ignores SIGTERM and SIGINT, as a program that
#   is slow to shut down would, and outlives this client if the client is
#   killed, as with docker. Its PID is in $state/containers/ID.
# - `kill ID...` sends the containers SIGKILL, or the --signal given, and
#   returns. `stop ID...` sends SIGTERM, waits up to --time seconds (default
#   10) for them to end, then sends SIGKILL, as docker does. An unknown ID
#   fails.

runner="$PWD/$1"
# Physical paths, so expected paths match whatever the runner resolves.
base="$(cd "$TEST_TMPDIR" && pwd -P)"
work="$base/execroot"
fake_bin="$base/bin"
state="$base/docker"
stderr_file="$base/stderr"
# The first docker call's argv, one argument per line.
argv_file="$state/calls/1"
image="registry.example/isaac-sim@sha256:0123"
out_rel="bazel-out/k8-fastbuild/bin/pkg/gen_out"
out_abs="$work/$out_rel"
# What the runner passes the container after --.
container_args=(launcher.py)
mkdir -p "$work" "$fake_bin"

cat >"$fake_bin/docker" <<'EOF'
#!/usr/bin/env bash
state="$FAKE_DOCKER_STATE"
n=$(($(ls "$state/calls" | wc -l) + 1))
printf '%s\n' "$@" >"$state/calls/$n"

running() {
  local file
  for file in "$state"/containers/*; do
    [[ -e "$file" ]] && kill -0 "$(cat "$file")" 2>/dev/null && echo "${file##*/}"
  done
  return 0
}

command="$1"
shift
case "$command" in
  run)
    if [[ " $* " == *" --user 0:0 "* ]]; then
      running >"$state/handback_saw"
      date +%s >"$state/handback_time"
      exit "${FAKE_HANDBACK_STATUS:-0}"
    fi
    id="c$n"
    cidfile=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --name) id="$2" && shift ;;
        --name=*) id="${1#--name=}" ;;
        --cidfile) cidfile="$2" && shift ;;
        --cidfile=*) cidfile="${1#--cidfile=}" ;;
      esac
      shift
    done
    if [[ -n "$cidfile" ]]; then
      if [[ -e "$cidfile" ]]; then
        echo "docker: Container ID file found, make sure the other container isn't running or delete $cidfile" >&2
        exit 125
      fi
      printf '%s' "$id" >"$cidfile"
    fi
    out="$FAKE_OUTPUT"
    if [[ ! -d "$out" ]]; then
      echo missing >"$state/main_saw"
    elif find "$out" -maxdepth 0 -perm -0777 | grep -q .; then
      echo open >"$state/main_saw"
    else
      echo closed >"$state/main_saw"
    fi
    case "${FAKE_WRITE:-nothing}" in
      empty_dir) mkdir -p "$out/rgb" ;;
      file) mkdir -p "$out/rgb" && chmod 0777 "$out/rgb" && echo frame >"$out/rgb/frame_0.png" ;;
    esac
    [[ -n "${FAKE_MAIN_SLEEP:-}" ]] || exit "${FAKE_MAIN_STATUS:-0}"
    (
      trap '' TERM INT
      exec sleep "$FAKE_MAIN_SLEEP"
    ) </dev/null >/dev/null 2>&1 &
    echo "$!" >"$state/containers/$id"
    status=0
    wait "$!" || status=$?
    exit "$status"
    ;;
  kill)
    signal=KILL
    ids=()
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -s | --signal) signal="${2#SIG}" && shift ;;
        --signal=*) signal="${1#--signal=}" && signal="${signal#SIG}" ;;
        -*) ;;
        *) ids+=("$1") ;;
      esac
      shift
    done
    status=0
    for id in ${ids[@]+"${ids[@]}"}; do
      if [[ -f "$state/containers/$id" ]]; then
        kill -"$signal" "$(cat "$state/containers/$id")" 2>/dev/null || true
        echo "$id"
      else
        echo "Error response from daemon: No such container: $id" >&2
        status=1
      fi
    done
    exit "$status"
    ;;
  stop)
    grace=10
    ids=()
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -t | --time | --timeout) grace="$2" && shift ;;
        -s | --signal) shift ;;
        -*) ;;
        *) ids+=("$1") ;;
      esac
      shift
    done
    status=0
    for id in ${ids[@]+"${ids[@]}"}; do
      if [[ -f "$state/containers/$id" ]]; then
        pid="$(cat "$state/containers/$id")"
        kill -TERM "$pid" 2>/dev/null || true
        for _ in $(seq $((grace * 10))); do
          kill -0 "$pid" 2>/dev/null || break
          sleep 0.1
        done
        kill -KILL "$pid" 2>/dev/null || true
        echo "$id"
      else
        echo "Error response from daemon: No such container: $id" >&2
        status=1
      fi
    done
    exit "$status"
    ;;
esac
exit 0
EOF
chmod +x "$fake_bin/docker"

failures=0
fail() {
  echo "FAIL: $*" >&2
  failures=$((failures + 1))
}

show_stderr() {
  sed 's/^/  stderr: /' "$stderr_file" >&2
}

finish() {
  if ((failures)); then
    echo "$failures check(s) failed" >&2
    exit 1
  fi
  echo "PASS"
}

# start_runner [NAME=VALUE...] [FLAG...]: starts the runner in the background
# from $work, with a fresh fake docker record, as
#   runner --image $image --gpu-count 1 FLAG... -- ${container_args[@]}
# with OMNI_CONTAINER_CACHE_MOUNTS unset and each NAME=VALUE in its
# environment. Sets $runner_pid; the runner's stderr goes to $stderr_file.
start_runner() {
  local -a assignments=()
  while [[ $# -gt 0 && "$1" =~ ^[A-Z_][A-Z0-9_]*= ]]; do
    assignments+=("$1")
    shift
  done
  rm -rf "$state"
  mkdir -p "$state/calls" "$state/containers"
  (
    cd "$work"
    exec env -u OMNI_CONTAINER_CACHE_MOUNTS PATH="$fake_bin:$PATH" \
      FAKE_DOCKER_STATE="$state" FAKE_OUTPUT="$out_abs" ${assignments[@]+"${assignments[@]}"} \
      bash "$runner" --image "$image" --gpu-count 1 ${1+"$@"} -- "${container_args[@]}"
  ) 2>"$stderr_file" &
  runner_pid=$!
}

# run_runner: as start_runner, then waits for the runner. Sets $status.
run_runner() {
  start_runner "$@"
  status=0
  wait "$runner_pid" || status=$?
}

# check_invoked LABEL: the runner called docker; otherwise there is nothing to
# check.
check_invoked() {
  if [[ ! -e "$argv_file" ]]; then
    fail "$1: runner exited $status without a docker call"
    show_stderr
    return 1
  fi
}

# check_argv LABEL EXPECTED: the runner exited 0 after calling docker once,
# with exactly EXPECTED (one argument per line).
check_argv() {
  check_invoked "$1" || return 0
  ((status == 0)) || fail "$1: runner exited $status"
  if [[ "$(cat "$argv_file")" != "$2" ]]; then
    fail "$1: unexpected docker argv"
    diff <(echo "$2") "$argv_file" | sed 's/^/  /' >&2 || true
  fi
  [[ ! -e "$state/calls/2" ]] || fail "$1: docker was called more than once"
}

# check_refused LABEL TEXT: the runner exited non-zero without calling docker,
# naming TEXT on stderr.
check_refused() {
  ((status != 0)) || fail "$1: runner exited 0"
  [[ ! -e "$argv_file" ]] || fail "$1: docker was invoked: $(tr '\n' ' ' <"$argv_file")"
  if ! grep -qF -- "$2" "$stderr_file"; then
    fail "$1: stderr does not name $2"
    show_stderr
  fi
}

# split_volumes LABEL: splits the first docker call's argv into $added, the
# values of its --volume flags other than $work:$work (one per line, in
# order), and $remaining, the rest of it (one argument per line). Fails LABEL
# for each such --volume after the image.
split_volumes() {
  local label="$1" line i image_index=-1
  local -a lines=() rest=() volumes=()
  while IFS= read -r line; do lines+=("$line"); done <"$argv_file"
  for i in "${!lines[@]}"; do
    [[ "${lines[$i]}" == "$image" && $image_index -lt 0 ]] && image_index=$i
  done
  for ((i = 0; i < ${#lines[@]}; i++)); do
    if [[ "${lines[$i]}" == --volume && $((i + 1)) -lt ${#lines[@]} && "${lines[$((i + 1))]}" != "$work:$work" ]]; then
      volumes+=("${lines[$((i + 1))]}")
      ((image_index < 0 || i < image_index)) || fail "$label: --volume ${lines[$((i + 1))]} comes after the image"
      i=$((i + 1))
    else
      rest+=("${lines[$i]}")
    fi
  done
  added="$(printf '%s\n' ${volumes[@]+"${volumes[@]}"} | sed '/^$/d')"
  remaining="$(printf '%s\n' ${rest[@]+"${rest[@]}"})"
}
