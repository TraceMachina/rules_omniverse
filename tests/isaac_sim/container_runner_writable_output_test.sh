#!/usr/bin/env bash
# With --writable-output DIR, container_gpu_runner.sh opens DIR to every
# user before the container runs (the Isaac Sim image runs as uid 1234), then
# runs a root container of the same image that gives ownership back to the
# worker user, then closes DIR again.
set -euo pipefail
source "$(dirname "$0")/container_runner_lib.sh"

# Fresh work dir with Bazel's parent directories; $1 = "existing" also creates
# DIR with the mode Bazel gives it, $1 = "missing" leaves it to the runner.
setup() {
  rm -rf "$work"
  mkdir -p "$work/$(dirname "$out_rel")"
  if [[ "$1" == existing ]]; then
    mkdir "$out_abs"
    chmod 0755 "$out_abs"
  fi
}

# Runs the runner; arguments are env assignments for the fake docker, whose
# main container writes a frame into DIR. Sets $status.
run_with_output() {
  run_runner FAKE_WRITE=file "$@" --writable-output "$out_rel" --env ACCEPT_EULA=Y
}

# Checks the second docker call is the ownership restore: run --rm as root,
# no network, same image, DIR mounted at the same path, chown to our uid:gid.
check_restore() {
  local label="$1" restore="$state/calls/2"
  if [[ ! -e "$restore" ]]; then
    fail "$label: no second docker call to restore ownership"
    return
  fi
  local -a argv=()
  while IFS= read -r line; do argv+=("$line"); done <"$restore"
  local joined
  joined="$(printf '%s\n' "${argv[@]}")"

  [[ "${argv[0]}" == run ]] || fail "$label: restore call is not 'docker run'"
  grep -qx -- --rm <<<"$joined" || fail "$label: restore call has no --rm"

  local i image_index=-1 user="" network="" mounted=0
  for i in "${!argv[@]}"; do
    [[ "${argv[$i]}" == "$image" && $image_index -lt 0 ]] && image_index=$i
  done
  if ((image_index < 0)); then
    fail "$label: restore call does not use the image $image"
    sed 's/^/  argv: /' "$restore" >&2
    return
  fi
  # Options before the image.
  for ((i = 0; i < image_index; i++)); do
    case "${argv[$i]}" in
      --user) user="${argv[$((i + 1))]}" ;;
      --network) network="${argv[$((i + 1))]}" ;;
      --volume)
        local volume="${argv[$((i + 1))]}"
        local host="${volume%%:*}" container="${volume#*:}"
        if [[ "$host" == "$container" && ("$out_abs" == "$host" || "$out_abs" == "$host"/*) ]]; then
          mounted=1
        fi
        ;;
    esac
  done
  [[ "$user" == 0:0 ]] || fail "$label: restore call runs as '$user', expected --user 0:0"
  [[ "$network" == none ]] || fail "$label: restore call has --network '$network', expected none"
  ((mounted)) || fail "$label: restore call does not mount $out_abs at the same path"

  # The command after the image must name DIR and our uid:gid.
  local command
  command="$(printf '%s\n' "${argv[@]:$((image_index + 1))}")"
  grep -qF -- "$out_abs" <<<"$command" || fail "$label: restore command does not name $out_abs"
  grep -qF -- "$(id -u):$(id -g)" <<<"$command" || fail "$label: restore command does not chown to $(id -u):$(id -g)"
}

# DIR and its subdirectories must not be group/other writable afterwards.
check_closed() {
  local label="$1" open
  [[ -d "$out_abs" ]] || return 0
  open="$(find "$out_abs" -type d -perm -0020 -o -type d -perm -0002)"
  [[ -z "$open" ]] || fail "$label: directories still group/other writable after the run: $open"
}

for case in existing missing; do
  label="DIR $case before the run"
  setup "$case"
  run_with_output
  ((status == 0)) || fail "$label: runner exited $status"
  check_invoked "$label" || continue
  [[ "$(cat "$state/main_saw")" == open ]] ||
    fail "$label: container saw DIR as '$(cat "$state/main_saw")', expected it to exist with mode a+rwx"
  check_restore "$label"
  [[ ! -e "$state/calls/3" ]] || fail "$label: expected exactly two docker calls, got more"
  check_closed "$label"
done

# A failing container still gets its ownership restored, and its status wins.
label="container exits 3"
setup existing
run_with_output FAKE_MAIN_STATUS=3
((status == 3)) || fail "$label: runner exited $status, expected 3"
check_restore "$label"

# A failed restore must not be reported as success.
label="restore fails"
setup existing
run_with_output FAKE_HANDBACK_STATUS=1
if [[ -e "$state/calls/2" ]]; then
  ((status != 0)) || fail "$label: runner exited 0"
else
  fail "$label: no second docker call to restore ownership"
fi

finish
