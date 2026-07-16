# Releasing `rules_omniverse`

Releases use a signed annotated tag and the community trusted-builder workflows
for the source archive, GitHub provenance attestations, and BCR publication.
Never move an existing release tag as part of a normal release.

## Prepare and verify

Set the same version in `MODULE.bazel`, `e2e/bzlmod/MODULE.bazel`, the README
consumer snippet, and `CHANGELOG.md`. From the repository root, run:

```bash
buildifier -mode=check -r .
bazel test //...
(cd e2e/bzlmod && bazel test //... \
  --override_module=rules_omniverse=../..)
git diff --check
```

Review `git status --short`, the complete diff from the previous release tag,
and the candidate commit signature.

## Tag and publish through the trusted builders

Replace `VERSION` below, then run these commands only from the reviewed release
commit on `main`:

```bash
VERSION=0.3.0
git tag -s "v${VERSION}" -m "Release v${VERSION}"
git verify-tag "v${VERSION}"
git push origin main
git push origin "refs/tags/v${VERSION}"
```

Pushing the tag starts `.github/workflows/release.yaml`. It:

1. calls `bazel-contrib/release_ruleset@v7.7.0` on a GitHub-hosted runner;
2. tests the tagged source and runs `release_prep.sh` to create the archive;
3. attests the archive and opens the GitHub release as a draft;
4. calls `publish-to-bcr@v1.4.2` with attestations enabled; and
5. publishes the GitHub release after the BCR publish job succeeds.

Do not hand-upload or replace the generated archive. Confirm that the release
asset is named
`rules_omniverse-v${VERSION}.tar.gz` and expands beneath
`rules_omniverse-${VERSION}/`. The `.bcr/source.template.json` URL and
`strip_prefix` depend on those exact names.

Download and verify the archive provenance:

```bash
archive="/tmp/rules_omniverse-v${VERSION}.tar.gz"
gh release download "v${VERSION}" \
  --repo TraceMachina/rules_omniverse \
  --pattern "rules_omniverse-v${VERSION}.tar.gz" \
  --output "$archive"
gh attestation verify "$archive" --owner TraceMachina
```

## Bazel Central Registry

The release workflow opens a draft pull request against
`TraceMachina/bazel-central-registry`. Use the standalone `Publish to BCR`
workflow only to retry a failed publish; for a retry, provide the original
`Release` workflow run ID so it can reuse the attested archive. In the registry
checkout, run:

```bash
bazel run -- //tools:bcr_validation \
  --check="rules_omniverse@${VERSION}"
bazel test //:test_metadata.modules/rules_omniverse
```

Before merging the registry pull request, verify that its `source.json`
downloads the GitHub release asset, its integrity matches that asset, and its
generated test module exercises both Bazel 8 and Bazel 9 lanes from
`.bcr/presubmit.yml`. Confirm that the entry contains `attestations.json`. The
blue provenance indicator is per version and appears after that BCR pull
request merges; previous releases remain badge-less.
