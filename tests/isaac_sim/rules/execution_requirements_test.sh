#!/usr/bin/env bash
# The expanded isaac_sim_action rule carries the expected
# execution_requirements (no-sandbox, plus any the caller gave). $1 is the
# genquery --output=build dump of the target; the rest are KEY=VALUE pairs.
set -euo pipefail

query="$1"
shift
failures=0

line="$(grep -E '^[[:space:]]*execution_requirements = ' "$query" || true)"
for pair in "$@"; do
  expected="\"${pair%%=*}\": \"${pair#*=}\""
  if ! grep -F -- "$expected" <<<"$line" >/dev/null; then
    echo "FAIL: execution_requirements lacks $expected" >&2
    failures=$((failures + 1))
  fi
done

if ((failures)); then
  echo "--- execution_requirements as expanded by bazel query: ${line:-<not set>}" >&2
  exit 1
fi
echo "PASS"
