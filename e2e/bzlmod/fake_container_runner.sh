#!/usr/bin/env bash
set -euo pipefail

while [[ $# -gt 0 ]]; do
  case "$1" in
    --runtime|--image|--gpu-count|--shm-size|--network|--entrypoint|--env|--forward-env)
      shift 2
      ;;
    --)
      shift
      break
      ;;
    *)
      echo "unexpected fake container runner argument: $1" >&2
      exit 2
      ;;
  esac
done

token="__RULES_OMNIVERSE_EXEC_ROOT__"
declare -a command=()
for value in "$@"; do
  command+=("${value//$token/$PWD}")
done
exec "${command[@]}"
