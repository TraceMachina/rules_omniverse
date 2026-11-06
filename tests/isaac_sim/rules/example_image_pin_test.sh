#!/usr/bin/env bash
# //examples/isaac_sim:scene_based_sdg uses exactly the image recorded in
# examples/isaac_sim/isaac_sim.pin (Isaac Sim 6.2.0.1). $1 is the genquery
# --output=build dump of the example target, $2 the pin file.
set -euo pipefail

query="$1"
pin_file="$2"
failures=0
fail() {
  echo "FAIL: $*" >&2
  failures=$((failures + 1))
}

if [[ "$(wc -l <"$pin_file" | tr -d ' ')" != 1 ]]; then
  fail "$pin_file must hold exactly one line"
fi
pin="$(head -n 1 "$pin_file")"
[[ "$pin" == *:6.2.0.1@sha256:* ]] || fail "pin '$pin' is not an Isaac Sim 6.2.0.1 image pinned by digest"

if ! grep -F -- "image = \"$pin\"" "$query" >/dev/null; then
  fail "example image is not the pinned $pin"
  echo "--- image line of the example as expanded by bazel query:" >&2
  grep -F 'image = ' "$query" >&2 || cat "$query" >&2
fi

if ((failures)); then
  exit 1
fi
echo "PASS"
