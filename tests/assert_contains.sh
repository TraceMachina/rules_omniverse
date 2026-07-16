#!/usr/bin/env bash
set -euo pipefail

file="$1"
shift

for expected in "$@"; do
  if ! grep -F -- "$expected" "$file" >/dev/null; then
    echo "missing expected text in $file: $expected" >&2
    exit 1
  fi
done
