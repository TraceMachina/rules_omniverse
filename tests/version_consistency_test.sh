#!/usr/bin/env bash
# The release version is the same in the module() call of MODULE.bazel, the
# newest versioned heading of CHANGELOG.md, the README's bazel_dep line and the
# bazel_dep line of the e2e consumer module.
# $1 is MODULE.bazel, $2 CHANGELOG.md, $3 README.md, $4 e2e/bzlmod/MODULE.bazel.
set -euo pipefail

module_file="$1"
changelog_file="$2"
readme_file="$3"
e2e_module_file="$4"
failures=0
fail() {
  echo "FAIL: $*" >&2
  failures=$((failures + 1))
}

module_version="$(sed -nE '/^module\(/,/^\)/s/^[[:space:]]*version[[:space:]]*=[[:space:]]*"([^"]*)".*/\1/p' "$module_file")"
changelog_version="$(sed -nE '/^## \[[0-9]/{s/^## \[([^]]*)\].*/\1/p;q;}' "$changelog_file")"
readme_versions="$(sed -nE 's/^[[:space:]]*bazel_dep\(name = "rules_omniverse", version = "([^"]*)".*/\1/p' "$readme_file")"
e2e_versions="$(sed -nE 's/^[[:space:]]*bazel_dep\(name = "rules_omniverse", version = "([^"]*)".*/\1/p' "$e2e_module_file")"

[[ -n "$module_version" ]] || fail "no version in the module() call of $module_file"
[[ -n "$changelog_version" ]] || fail "no '## [x.y.z]' heading in $changelog_file"
[[ -n "$readme_versions" ]] || fail "no bazel_dep(name = \"rules_omniverse\", version = ...) line in $readme_file"
[[ -n "$e2e_versions" ]] || fail "no bazel_dep(name = \"rules_omniverse\", version = ...) line in $e2e_module_file"

if ((failures == 0)); then
  if [[ "$changelog_version" != "$module_version" ]]; then
    fail "newest CHANGELOG.md heading is $changelog_version but MODULE.bazel has $module_version"
  fi
  while read -r readme_version; do
    if [[ "$readme_version" != "$module_version" ]]; then
      fail "README.md bazel_dep has $readme_version but MODULE.bazel has $module_version"
    fi
  done <<<"$readme_versions"
  while read -r e2e_version; do
    if [[ "$e2e_version" != "$module_version" ]]; then
      fail "e2e/bzlmod/MODULE.bazel bazel_dep has $e2e_version but MODULE.bazel has $module_version"
    fi
  done <<<"$e2e_versions"
fi

if ((failures)); then
  echo "--- versions found:" >&2
  echo "MODULE.bazel: ${module_version:-<none>}" >&2
  echo "CHANGELOG.md: ${changelog_version:-<none>}" >&2
  echo "README.md: ${readme_versions:-<none>}" >&2
  echo "e2e/bzlmod/MODULE.bazel: ${e2e_versions:-<none>}" >&2
  exit 1
fi
echo "PASS"
