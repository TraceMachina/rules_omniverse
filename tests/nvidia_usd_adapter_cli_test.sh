#!/usr/bin/env bash
set -euo pipefail

for adapter in "$@"; do
  "$adapter" --help >/dev/null
done
