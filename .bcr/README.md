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
4. Create and push a release tag such as `v0.1.0`.
5. Run the `Publish to BCR` workflow with that tag.

Attestations are disabled in this repository's workflow until releases are
created with `bazel-contrib`'s reusable `release_ruleset` workflow.

