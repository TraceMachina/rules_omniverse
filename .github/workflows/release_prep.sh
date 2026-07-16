#!/usr/bin/env bash

set -o errexit -o nounset -o pipefail

tag="${1:?release tag is required}"
if [[ ! "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
  echo "release tag must look like v1.2.3: $tag" >&2
  exit 1
fi

version="${tag#v}"
module_version="$(sed -n 's/^[[:space:]]*version = "\([^"]*\)",/\1/p' MODULE.bazel | head -1)"
if [[ "$module_version" != "$version" ]]; then
  echo "MODULE.bazel version $module_version does not match tag $tag" >&2
  exit 1
fi

archive="rules_omniverse-${tag}.tar.gz"
prefix="rules_omniverse-${version}/"
git archive --format=tar --prefix="$prefix" "$tag" | gzip -n > "$archive"

if ! grep -Fq "## [$version]" CHANGELOG.md; then
  echo "CHANGELOG.md has no section for $version" >&2
  exit 1
fi

cat <<EOF
## Bzlmod

Add the attested release to your \`MODULE.bazel\`:

\`\`\`starlark
bazel_dep(name = "rules_omniverse", version = "$version")
\`\`\`

The source archive was produced from the reviewed \`$tag\` tag by the
\`bazel-contrib/release_ruleset\` trusted builder. Its provenance is attached
to this release and is also carried into the Bazel Central Registry entry.
EOF

awk -v heading="## [$version]" '
  index($0, heading) == 1 { found = 1; next }
  found && /^## \[/ { exit }
  found { print }
' CHANGELOG.md
