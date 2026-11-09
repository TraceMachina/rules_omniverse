# Changelog

All notable changes to `rules_omniverse` are documented here.

## [0.4.0] - Unreleased

### Added

- `isaac_sim_action` runs a headless Isaac Sim script in an image pinned by
  digest, as one cacheable GPU container action with a `<name>_out` output
  directory. With a scene, it fails before the script starts when the scene
  depends on undeclared local files. The action fails when the script raises,
  even though Kit exits 0.
- `isaac_sim_platform` adds the container runtime constraint and a
  `worker_runtime` of `nvidia-driver-<driver>`, so results built for different
  declared drivers never share a cache entry. Local runs do not check the
  worker's actual driver.
- `examples/isaac_sim` runs NVIDIA's `scene_based_sdg` Replicator sample from
  the pinned Isaac Sim 6.2.0.1 image. Its README covers prerequisites, worker
  setup with NativeLink, local and remote runs, driver updates,
  troubleshooting, and limits.
- Opt-in container runner options: `OMNI_CONTAINER_CACHE_MOUNTS` on the worker
  for caches shared between actions, `--writable-output` to open an output
  directory to the image's user and hand its files back afterward,
  `--require-nonempty-output` to fail when a successful container leaves an
  output directory empty, and `--input` to mount the out-of-tree targets of
  input symlinks read-only. With an output option, SIGTERM or SIGINT kills the
  container, or removes it if it has not started, and still hands the output
  back.

### Changed

- The code that registers a container GPU action moved out of
  `omni_container_gpu_action` into a shared internal helper,
  `run_container_gpu_action`, so other container rules can register the same
  kind of action. The move itself does not change the
  `omni_container_gpu_action` action.

### Fixed

- A local cancel of an `isaac_sim_action` build now stops the container and
  hands the output back, within Bazel's grace period. Fixes #13 (#19). The
  runner script changed, so each Isaac Sim action reruns once on first use
  after upgrading.

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

[0.4.0]: https://github.com/TraceMachina/rules_omniverse/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/TraceMachina/rules_omniverse/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/TraceMachina/rules_omniverse/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/TraceMachina/rules_omniverse/releases/tag/v0.1.0
