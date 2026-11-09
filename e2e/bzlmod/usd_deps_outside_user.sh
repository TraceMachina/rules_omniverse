#!/usr/bin/env bash
# An outside user's `bazel run @rules_omniverse//tools:usd_deps`, in this module.
# A real `bazel run` cannot nest inside `bazel test`, so run this script directly:
#
#   e2e/bzlmod/usd_deps_outside_user.sh
#
# The python3 on PATH must be too old to run usd-core, which proves it is not
# the one running the tool. This module's default Python is not 3.11, which
# proves the tool pins its own.

set -euo pipefail

bazel="${BAZEL:-bazelisk}"
module_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$module_dir/../.." && pwd)"
cd "$module_dir"

export USE_BAZEL_VERSION="${USE_BAZEL_VERSION:-$(cat "$repo_root/.bazelversion")}"

if command -v python3 >/dev/null; then
    if ! python3 -c 'import sys; sys.exit(sys.version_info >= (3, 11))'; then
        echo "error: python3 on PATH is 3.11 or newer, so this check would prove nothing: $(python3 --version)" >&2
        exit 1
    fi
    echo "python3 on PATH: $(python3 --version)"
else
    echo "python3 on PATH: none"
fi

generated="usd_deps_scene/stage_deps.bzl"
rm -f "$generated"
trap 'rm -f "$module_dir/$generated"' EXIT

run_tool() {
    "$bazel" run --override_module=rules_omniverse="$repo_root" @rules_omniverse//tools:usd_deps -- "$@"
}

run_tool usd_deps_scene/stage.usda
if ! cmp "usd_deps_scene/stage_deps.expected" "$generated"; then
    echo "error: $generated is not the expected file" >&2
    diff "usd_deps_scene/stage_deps.expected" "$generated" >&2 || true
    exit 1
fi

run_tool --check usd_deps_scene/stage.usda

# A consumer gets one pip hub from rules_omniverse, holding only usd-core.
pip_repos="$("$bazel" mod show_extension --override_module=rules_omniverse="$repo_root" \
    @rules_python//python/extensions:pip.bzl%pip 2>/dev/null)"
hubs="$(grep "imported by rules_omniverse@" <<<"$pip_repos" || true)"
spokes="$(grep "^  - rules_omniverse_usd_deps_pip_" <<<"$pip_repos" || true)"
if ! grep -q "rules_omniverse_usd_deps_pip " <<<"$hubs" || [ "$(wc -l <<<"$hubs")" -ne 1 ] \
    || [ "$spokes" != "  - rules_omniverse_usd_deps_pip_311_usd_core" ]; then
    printf 'error: expected one pip hub holding only usd-core, got:\n%s\n%s\n' "$hubs" "$spokes" >&2
    exit 1
fi

echo "PASS: usd_deps ran from an outside module and --check passed"
