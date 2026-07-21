# Publish to BCR templates

This folder contains the template files consumed by
`bazel-contrib/publish-to-bcr` when publishing `rules_omniverse` to the Bazel
Central Registry.

The publish workflow substitutes the release owner, repository, tag, version,
and integrity values into these templates when it opens the registry pull
request.

Required repository setup:

1. Fork `bazelbuild/bazel-central-registry` as `TraceMachina/bazel-central-registry`.
2. Create a classic GitHub PAT with `repo` and `workflow` scopes.
3. Save the PAT as the `BCR_PUBLISH_TOKEN` Actions secret.
4. Create and push a signed release tag such as `v0.3.0`.
5. Let the `Release` workflow build and attest the archive, call the `Publish
   to BCR` workflow, and finalize the GitHub release.

Both reusable workflows are referenced by semantic version because BCR's SLSA
verification recognizes their trusted-builder identities. The publish job adds
the archive, `MODULE.bazel`, and `source.json` attestations to the release and
the generated BCR entry. The registry badge appears for that version after its
BCR pull request merges; earlier versions are unchanged.
