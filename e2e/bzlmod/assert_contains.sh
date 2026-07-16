#!/usr/bin/env bash
set -euo pipefail

file="$1"
shift

for expected in "$@"; do
  grep -F -- "$expected" "$file" >/dev/null
done
