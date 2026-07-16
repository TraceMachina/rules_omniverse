#!/usr/bin/env bash
set -euo pipefail

runtime="docker"
image=""
gpu_count="1"
shm_size="64g"
network="none"
entrypoint=""
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

declare -a command=(
  "$runtime" run --rm
  --gpus "$gpu_count"
  --network "$network"
  --shm-size "$shm_size"
  --volume "$PWD:$PWD"
  --workdir "$PWD"
)
if [[ -n "$entrypoint" ]]; then
  command+=(--entrypoint "$entrypoint")
fi
exec_root_token="__RULES_OMNIVERSE_EXEC_ROOT__"
for value in "${container_env[@]}"; do
  value="${value//$exec_root_token/$PWD}"
  command+=(--env "$value")
done
for name in "${forward_env[@]}"; do
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

command+=("$image")
declare -a container_arguments=()
for value in "$@"; do
  container_arguments+=("${value//$exec_root_token/$PWD}")
done
exec "${command[@]}" "${container_arguments[@]}"
