#!/usr/bin/env bash
set -euo pipefail

operation="gpu"
output=""
report=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --operation)
      operation="$2"
      shift 2
      ;;
    --output)
      output="$2"
      shift 2
      ;;
    --input)
      shift 2
      ;;
    --report)
      report="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

case "$operation" in
  validate)
    printf '{"operation": "validate", "valid": true}\n' > "$report"
    ;;
  profile)
    printf '{"operation": "profile", "prim_count": 1}\n' > "$report"
    ;;
  convert|optimize)
    printf '#usda 1.0\n# fake %s adapter\n' "$operation" > "$output"
    ;;
  gpu)
    printf '{"gpu": true}\n' > "$output"
    ;;
  *)
    echo "unsupported fake operation: $operation" >&2
    exit 2
    ;;
esac
