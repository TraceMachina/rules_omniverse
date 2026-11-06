#!/usr/bin/env bash
# //examples/isaac_sim:scene_based_sdg passes its generated config with
# {input:NAME}, not with the {output}.yaml naming trick. $1 is the genquery
# --output=build dump of the example target.
set -euo pipefail

query="$1"
failures=0
fail() {
  echo "FAIL: $*" >&2
  failures=$((failures + 1))
}

args_line="$(grep -E '^ *arguments = ' "$query" || true)"
[[ -n "$args_line" ]] || fail "example has no arguments"

if grep -F -- '{output}.yaml' "$query" >/dev/null; then
  fail "example still passes {output}.yaml"
fi
if ! grep -E -- '"--config", "\{input:[^"{}]+\}"' <<<"$args_line" >/dev/null; then
  fail "example does not pass --config {input:NAME}"
fi

if ((failures)); then
  echo "--- arguments of the example as expanded by bazel query:" >&2
  echo "$args_line" >&2
  exit 1
fi
echo "PASS"
