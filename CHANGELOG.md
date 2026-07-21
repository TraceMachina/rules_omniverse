# Changelog

All notable changes to `rules_omniverse` are documented here.

## [0.3.0] - 2026-07-16

### Added

- Parameterized host and OCI-container GPU actions, NVIDIA GPU execution
  platforms, worker-native scripts, and typed GPU action providers.
- Adapter-based OpenUSD validation, profiling, conversion, and optimization
  rules with typed stage metadata and built-in NVIDIA adapter entry points.
- Hermetic rule-contract tests plus a standalone Bzlmod consumer test for GPU,
  container, and USD workflows without requiring proprietary SDKs or hardware.
- A NativeLink 1.6.1 H200 reference configuration with explicit security,
  runtime-fingerprint, cache, and real-versus-fake hardware boundaries.

### Changed

- Packaging rules expose a configurable `packager` executable for
  worker-native remote execution while retaining the existing default.
- The old NativeLink Kit viewer example was replaced by terminal timing.
- Top-level documentation now separates portable prerequisites from optional
  Kit, NVIDIA SDK, GPU, and remote-execution requirements.
- Releases and BCR publication use the community trusted-builder workflows to
  generate provenance attestations for release archives and registry metadata.

## [0.2.0] - 2026-07-04

- Added `rules_python`-backed internal tools and repaired standalone Bzlmod
  consumption and Kit launcher behavior.

## [0.1.0] - 2026-06-15

- Initial public release of Kit application, extension, asset packaging,
  repository publishing, toolchain, and metadata-test rules.

[0.3.0]: https://github.com/TraceMachina/rules_omniverse/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/TraceMachina/rules_omniverse/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/TraceMachina/rules_omniverse/releases/tag/v0.1.0
