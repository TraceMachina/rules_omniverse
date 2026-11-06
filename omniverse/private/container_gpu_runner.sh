#!/usr/bin/env bash
set -euo pipefail

runtime="docker"
image=""
gpu_count="1"
shm_size="64g"
network="none"
entrypoint=""
writable_output=""
nonempty_output=""
declare -a inputs=()
declare -a container_env=()
declare -a forward_env=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --runtime)
      runtime="$2"
      shift 2
      ;;
    --image)
      image="$2"
      shift 2
      ;;
    --gpu-count)
      gpu_count="$2"
      shift 2
      ;;
    --shm-size)
      shm_size="$2"
      shift 2
      ;;
    --network)
      network="$2"
      shift 2
      ;;
    --entrypoint)
      entrypoint="$2"
      shift 2
      ;;
    --env)
      container_env+=("$2")
      shift 2
      ;;
    --forward-env)
      forward_env+=("$2")
      shift 2
      ;;
    --writable-output)
      writable_output="$2"
      shift 2
      ;;
    --require-nonempty-output)
      nonempty_output="$2"
      shift 2
      ;;
    --input)
      inputs+=("$2")
      shift 2
      ;;
    --)
      shift
      break
      ;;
    *)
      echo "unknown container runner argument: $1" >&2
      exit 2
      ;;
  esac
done

if [[ -z "$image" ]]; then
  echo "container image is required" >&2
  exit 2
fi
if ! command -v "$runtime" >/dev/null 2>&1; then
  echo "container runtime '$runtime' is not installed on this execution worker" >&2
  exit 127
fi
if [[ ! "$gpu_count" =~ ^[1-9][0-9]*$ ]]; then
  echo "gpu count must be a positive integer" >&2
  exit 2
fi

declare -a cache_volumes=()
cache_mounts="${OMNI_CONTAINER_CACHE_MOUNTS:-}"
if [[ -n "$cache_mounts" ]]; then
  remaining="$cache_mounts,"
  while [[ -n "$remaining" ]]; do
    entry="${remaining%%,*}"
    remaining="${remaining#*,}"
    if [[ "$entry" != *:* || -z "${entry%%:*}" || -z "${entry#*:}" ]]; then
      echo "malformed OMNI_CONTAINER_CACHE_MOUNTS entry '$entry'; expected HOST:CONTAINER" >&2
      exit 2
    fi
    cache_volumes+=(--volume "$entry")
  done
fi

exec_root_token="__RULES_OMNIVERSE_EXEC_ROOT__"

# Input mounts. Without the sandbox, source inputs in the execution root are
# still symlinks: into the source tree, or external/<repo> into the output base
# and on to a local_path_override checkout. The container sees only what is
# mounted, so each input is looked up the way the kernel would, from the
# execution root, and every symlink met whose target lies outside it gets the
# target's real directory mounted read-only at the path the link names.
declare -a input_volumes=()
declare -a input_mount_dirs=()

# Removes empty, "." and ".." components from an absolute path, without
# touching the file system.
normalize_path() {
  local part
  local -a parts=() kept=()
  IFS=/ read -ra parts <<<"$1"
  for part in ${parts[@]+"${parts[@]}"}; do
    case "$part" in
      "" | .) ;;
      ..) ((${#kept[@]} == 0)) || unset "kept[$((${#kept[@]} - 1))]" ;;
      *) kept+=("$part") ;;
    esac
  done
  local IFS=/
  printf '/%s\n' "${kept[*]-}"
}

# Prints PATH relative to the execution root if one of its ancestors is the
# execution root (physically, so either spelling of it matches); fails otherwise.
relative_to_exec_root() {
  local path="$1" ancestor="$1"
  while [[ -n "$ancestor" ]]; do
    if [[ "$ancestor" -ef "$PWD" ]]; then
      path="${path#"$ancestor"}"
      printf '%s\n' "${path#/}"
      return 0
    fi
    ancestor="${ancestor%/*}"
  done
  return 1
}

add_input_mount() {
  local dir="$1" mounted
  for mounted in ${input_mount_dirs[@]+"${input_mount_dirs[@]}"}; do
    [[ "$mounted" != "$dir" ]] || return 0
  done
  local real
  # Callers run under `|| exit 2`, where set -e is off, so check explicitly.
  if ! real="$(cd -P "$dir" 2>/dev/null && pwd -P)"; then
    echo "--input: cannot resolve $dir to mount it read-only (cd -P failed)" >&2
    return 1
  fi
  input_mount_dirs+=("$dir")
  input_volumes+=(--volume "$real:$dir:ro")
}

# Looks up one --input value. The current directory is always a path the
# container can see without following links: the execution root, or below a
# directory mounted here.
mount_input() {
  local input="$1" path dir link target relative hops=0 i=0
  local -a parts=()
  path="${input//$exec_root_token/$PWD}"
  if [[ "$path" == /* ]] && relative="$(relative_to_exec_root "$(normalize_path "$path")")"; then
    path="$relative"
  fi
  if [[ "$path" == /* ]]; then
    dir=""
  else
    dir="$PWD"
  fi
  IFS=/ read -ra parts <<<"$path"
  while ((i < ${#parts[@]})); do
    local part="${parts[$i]}"
    i=$((i + 1))
    case "$part" in
      "" | .) continue ;;
      ..)
        dir="${dir%/*}"
        continue
        ;;
    esac
    link="$dir/$part"
    if [[ ! -L "$link" ]]; then
      if [[ ! -e "$link" ]]; then
        echo "--input $input: $link does not exist" >&2
        return 1
      fi
      dir="$link"
      continue
    fi
    hops=$((hops + 1))
    if ((hops > 40)); then
      echo "--input $input: too many levels of symbolic links at $link" >&2
      return 1
    fi
    target="$(readlink "$link")"
    [[ "$target" == /* ]] || target="$dir/$target"
    target="$(normalize_path "$target")"
    local -a rest=()
    if relative="$(relative_to_exec_root "$target")"; then
      # The container already sees the execution root: continue the lookup there.
      dir="$PWD"
      IFS=/ read -ra rest <<<"$relative"
    elif [[ ! -e "$target" ]]; then
      echo "--input $input: symlink $link points to $target, which does not exist" >&2
      return 1
    elif [[ -d "$target" ]]; then
      add_input_mount "$target" || return 1
      dir="$target"
    else
      add_input_mount "${target%/*}" || return 1
      dir="${target%/*}"
      rest=("${target##*/}")
    fi
    parts=(${rest[@]+"${rest[@]}"} ${parts[@]+"${parts[@]:$i}"})
    i=0
  done
}

for input in ${inputs[@]+"${inputs[@]}"}; do
  mount_input "$input" || exit 2
done

declare -a command=(
  "$runtime" run --rm
  --gpus "$gpu_count"
  --network "$network"
  --shm-size "$shm_size"
  --volume "$PWD:$PWD"
  --workdir "$PWD"
)
command+=(${input_volumes[@]+"${input_volumes[@]}"})
command+=(${cache_volumes[@]+"${cache_volumes[@]}"})
if [[ -n "$entrypoint" ]]; then
  command+=(--entrypoint "$entrypoint")
fi
for value in ${container_env[@]+"${container_env[@]}"}; do
  value="${value//$exec_root_token/$PWD}"
  command+=(--env "$value")
done
for name in ${forward_env[@]+"${forward_env[@]}"}; do
  if [[ ! "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    echo "invalid forwarded environment variable name" >&2
    exit 2
  fi
  if [[ -z "${!name+x}" ]]; then
    echo "required worker environment variable '$name' is unavailable" >&2
    exit 2
  fi
  command+=(--env "$name")
done

declare -a container_arguments=()
for value in "$@"; do
  container_arguments+=("${value//$exec_root_token/$PWD}")
done
if [[ -z "$writable_output" && -z "$nonempty_output" ]]; then
  exec "${command[@]}" "$image" ${container_arguments[@]+"${container_arguments[@]}"}
fi

# The runner has work to do after the container, so it runs it as a child and
# must stop the container itself when it is stopped. docker run writes the
# container's ID to a file that must not exist yet.
cid_dir="$(mktemp -d)"
trap 'rm -rf "$cid_dir"' EXIT
cidfile="$cid_dir/cid"
command+=(--cidfile "$cidfile" "$image")

# Output directory flags take a path relative to the execution root, an absolute
# path, or one prefixed with the execroot token.
absolute_dir() {
  local dir="${1//$exec_root_token/$PWD}"
  [[ "$dir" == /* ]] || dir="$PWD/$dir"
  printf '%s\n' "$dir"
}

# The image may run as its own user (Isaac Sim: uid 1234), so open the output to
# every user for the run, then give what the container wrote back to the worker
# user from a root container of the same image.
if [[ -n "$writable_output" ]]; then
  writable_dir="$(absolute_dir "$writable_output")"
  mkdir -p "$writable_dir"
  find "$writable_dir" -type d -exec chmod a+rwx {} +
fi

# Kills the main container at once. A cancelled run's output is discarded, so
# there is nothing to gain from `docker stop`, whose wait can use up Bazel's
# grace period before the hand-back below runs.
kill_container() {
  local cid=""
  # docker run writes the ID once it has created the container.
  while [[ -z "$cid" ]] && kill -0 "$container_pid" 2>/dev/null; do
    cid="$(cat "$cidfile" 2>/dev/null || true)"
    [[ -n "$cid" ]] || sleep 0.1
  done
  [[ -n "$cid" ]] || cid="$(cat "$cidfile" 2>/dev/null || true)"
  if [[ -n "$cid" ]]; then
    "$runtime" kill "$cid" >/dev/null || echo "could not kill container $cid" >&2
  fi
}

# A trap runs only after the foreground command ends, so the container runs in
# the background and a trapped signal ends the wait for it at once.
stopped_by=""
trap 'stopped_by=15' TERM
trap 'stopped_by=2' INT
status=0
"${command[@]}" ${container_arguments[@]+"${container_arguments[@]}"} &
container_pid=$!
[[ -n "$stopped_by" ]] || wait "$container_pid" || status=$?
if [[ -n "$stopped_by" ]]; then
  kill_container
  # A second signal ends a wait early too; the hand-back must not start
  # before docker run has ended.
  until wait "$container_pid"; do
    kill -0 "$container_pid" 2>/dev/null || break
  done
fi

if [[ -n "$writable_output" ]]; then
  owner="$(id -u):$(id -g)"
  if ! "$runtime" run --rm --user 0:0 --network none \
    --volume "$writable_dir:$writable_dir" --entrypoint find "$image" \
    "$writable_dir" -not -user "$(id -u)" -exec chown -h "$owner" {} +; then
    echo "could not give ownership of $writable_output back to $owner" >&2
    ((status != 0)) || status=1
  fi
  find "$writable_dir" -type d -exec chmod go-w {} + ||
    echo "could not remove group and other write permission from $writable_output" >&2
fi

if [[ -n "$stopped_by" ]]; then
  exit $((128 + stopped_by))
fi

# Some programs (Kit, when its Python script raises) exit 0 after failing; an
# output without a single file is treated as such a failure.
if ((status == 0)) && [[ -n "$nonempty_output" ]]; then
  nonempty_dir="$(absolute_dir "$nonempty_output")"
  if [[ ! -d "$nonempty_dir" ]] || [[ -z "$(find "$nonempty_dir" ! -type d -print -quit)" ]]; then
    echo "container exited 0 but its output $nonempty_output is empty; treating the run as failed" >&2
    status=1
  fi
fi
exit "$status"
