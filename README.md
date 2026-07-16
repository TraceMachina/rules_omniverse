# Omniverse rules for [Bazel](https://bazel.build)

This repository contains [Starlark](https://github.com/bazelbuild/starlark)
rules and macros for NVIDIA Omniverse Kit applications, OpenUSD assets, GPU
actions, packaging, validation, and remote execution.

The rules let Bazel own declared inputs, outputs, caching, and execution
placement while NVIDIA SDKs, Kit, container images, GPU models, and versions
remain selected by the user.

> **Prerequisites:** Bazel 8 or newer. Packaging and metadata tests need no Kit,
> CUDA toolkit, or GPU. Kit targets need an installed Kit SDK; NVIDIA USD rules
> need their selected adapter runtime. GPU actions and `gpu = True` targets need
> a registered NVIDIA GPU execution platform. Remote execution is optional.

> **Licensing:** `rules_omniverse` is Apache-2.0 and does not download or bundle
> NVIDIA software. Packaging, metadata, and fake-adapter tests do not require
> accepting an NVIDIA license. Targets that launch Kit or standalone NVIDIA
> SDKs require a user-supplied installation and remain subject to that
> software's current terms. See [NVIDIA Omniverse Licensing](https://docs.omniverse.nvidia.com/ov/latest/common/NVIDIA_Omniverse_License_Agreement.html).

## Getting Started

### Bzlmod

Add the ruleset to `MODULE.bazel`:

```starlark
bazel_dep(name = "rules_omniverse", version = "0.3.0")
```

The module brings its internal `rules_shell` and `platforms` dependencies.
Consumers do not need to repeat them unless they use those rule sets directly.

Build an asset bundle without installing Kit:

```starlark
load("@rules_omniverse//omniverse:defs.bzl", "omni_asset_bundle")

omni_asset_bundle(
    name = "factory_assets",
    srcs = glob(["assets/**"]),
    bundle_name = "factory_assets",
)
```

```bash
bazel build //:factory_assets
```

### Kit toolchain

`rules_omniverse` does not download or bundle NVIDIA Omniverse Kit. Register an
installed SDK only when targets must start Kit or use its `repo` publisher:

```starlark
kit = use_extension("@rules_omniverse//omniverse:extensions.bzl", "kit")
kit.local(
    name = "local_kit",
    path = "/opt/nvidia/omniverse/kit",
    kit_executable = "kit",
    repo_executable = "repo",
)
use_repo(kit, "local_kit")
register_toolchains("@local_kit//:toolchain")
```

For a one-off invocation, set `OMNI_KIT` or put `kit` on `PATH`:

```bash
OMNI_KIT=/opt/nvidia/omniverse/kit/kit bazel run //path/to:my_app
```

Without a registered toolchain, `OMNI_KIT`, or `kit` command, a Kit launcher
exits with configuration instructions. Bundle generation, metadata validation,
and standalone OpenUSD actions remain independent of Kit.

### Standalone NVIDIA USD adapters

USD rules take an explicit executable adapter. This keeps SDK installation and
version selection at the execution-environment boundary:

```starlark
load("@rules_omniverse//omniverse:defs.bzl", "omni_usd_optimize", "omni_usd_profile")

omni_usd_profile(
    name = "profile",
    src = "factory.usdc",
    tool = "@rules_omniverse//tools:nvidia_usd_profile_adapter",
)

omni_usd_optimize(
    name = "optimized",
    src = "factory.usdc",
    output = "factory.optimized.usdc",
    tool = "@rules_omniverse//tools:nvidia_usd_optimize_adapter",
    arguments = [
        "--input", "{src}",
        "--output", "{out}",
        "--pipeline", "safe-cleanup",
    ],
)
```

The included real adapters are:

- `nvidia_usd_validate_adapter`: `usd-validation-nvidia` JSON validation.
- `nvidia_usd_profile_adapter`: NVIDIA Usd Optimize `printStats` reporting.
- `nvidia_usd_optimize_adapter`: parameterized Usd Optimize operation chains.
- `nvidia_usd_convert_adapter`: OpenUSD format conversion plus optional
  `usd-convert-asset` and `usd-convert-gsplat` backends.

The profile rule measures a stage with Usd Optimize. It is distinct from
`usd-profiles-nvidia`, which defines asset capabilities and requirements rather
than measuring prims, vertices, layers, and time samples.

## GPU execution

GPU model, count, execution properties, adapter, image, and runtime remain
caller-controlled. The ruleset does not require an H200, fixed SDK version, or
container digest.

```starlark
load("@rules_omniverse//omniverse:defs.bzl", "omni_gpu_action", "omni_gpu_platform")

omni_gpu_platform(
    name = "gpu_linux_x86_64",
    constraint_values = [
        "@platforms//cpu:x86_64",
        "@platforms//os:linux",
    ],
    gpu_count = 1,
    gpu_model = "L40S",  # H200, A100, a workstation GPU, or empty.
)

omni_gpu_action(
    name = "simulation",
    srcs = ["scene.usda"],
    outs = ["result.json"],
    tool = ":runner",
    arguments = ["--input", "{input}", "--output", "{output}"],
    gpu_count = 1,
    gpu_model = "L40S",
)
```

Passing `gpu = True` to a USD rule constrains that action to an NVIDIA GPU
execution platform. It guarantees worker placement, not that the selected
upstream operation uses CUDA. USD conversion, validation, and several Usd
Optimize operations are CPU implementations even when they execute on a GPU
host.

Container actions additionally require
`//omniverse/constraints:oci_container_runtime`. Image tags or digests, runtime
command, network mode, shared memory, declared files/directories, and named
worker environment forwarding are all configurable. Digest pinning is
recommended for deployments that require stronger provenance, but it is not a
ruleset requirement.

## Rules

### Omniverse and packaging

- `omni_extension`: validate and package a Kit extension folder.
- `omni_kit_app`: generate a `.kit` app and Bazel launcher.
- `omni_app_bundle`: package apps, extensions, and assets together.
- `omni_asset_bundle`: package USD, MDL, textures, reports, and other assets.
- `omni_repo_publish_config`: generate Kit `repo publish_exts` configuration.
- `omni_extension_test`: start or test an extension inside Kit.
- `omni_manifest_test`: validate metadata without Kit.
- `omni_kit_toolchain`: expose installed Kit and `repo` executables.

Packaging rules accept a configurable `packager` executable. Their default
uses a `rules_shell` launcher; `//tools:package_omniverse_worker` is a
worker-native alternative for cross-platform remote execution.

### OpenUSD and GPU

- `omni_usd_validate`: validate a USD stage and emit JSON.
- `omni_usd_profile`: profile a USD stage and emit JSON.
- `omni_usd_convert`: convert an adapter-supported asset to USD.
- `omni_usd_optimize`: transform a USD stage with a selected optimizer.
- `omni_gpu_action`: execute a declared tool on an NVIDIA GPU platform.
- `omni_container_gpu_action`: execute a declared OCI GPU workload.
- `omni_gpu_platform`: declare GPU constraints and scheduler properties.
- `omni_worker_script`: upload a worker-side script without embedding the
  Bazel client's interpreter.

USD arguments support `{src}`, `{out}`, and `{report}` placeholders. Additional
files such as referenced layers, textures, profiles, or configuration must be
declared through `data` so they participate in the action key.

## SDK runtime selection

Adapters use the interpreter that launches them by default. A remote worker may
select a separate compatible SDK interpreter without putting host paths in a
BUILD file:

```text
RULES_OMNIVERSE_USD_PYTHON
RULES_OMNIVERSE_USD_PYTHONPATH
RULES_OMNIVERSE_USD_LD_LIBRARY_PATH
```

These values belong in private worker configuration. Pair changes with a
truthful `worker_runtime` execution property so actions built with incompatible
SDK stacks cannot share a cache identity. The public NativeLink configuration
contains environment-variable names only.

## NativeLink remote execution

NativeLink is the reference backend for the GPU demos because it exposes a
controllable REAPI scheduler, CAS, action cache, worker properties, and runtime
environment. Other REAPI backends may work, but this repository does not claim
equivalent worker provenance, customization, scheduling predictability, cache
behavior, or GPU performance for them.

## Examples

- [`examples/nativelink/gpu`](examples/nativelink/gpu/README.md): worker
  configuration, platforms, and real-versus-fake hardware preflight.

## Testing

The `fake_gpu` fixtures under `//tests` and `//e2e/bzlmod` verify Starlark
analysis, constraints, arguments, declared artifacts, and external-module use
without reserving a GPU. They do not claim CUDA or SDK execution.

Real-hardware coverage is separate. The primary reference bench is the H200
series, currently exercised with NativeLink 1.6.1, CUDA-enabled PyTorch,
`ovphysx`, and standalone NVIDIA USD tooling. H200 is a tested bench, not a
ruleset requirement.

```bash
bazel test //...
```

The standalone Bzlmod consumer is under `e2e/bzlmod`.

## `rules_cuda`

[`rules_cuda`](https://github.com/bazel-contrib/rules_cuda) is an optional
companion, not a dependency. Use it when a target must compile or link CUDA
sources with NVCC or Clang. `rules_omniverse` schedules prebuilt SDK tools and
containers, so requiring CUDA compilation toolchains would burden users who
only package Kit/OpenUSD content. A `rules_cuda` binary can be the `tool` of an
`omni_gpu_action`.

## Repository layout

Consumers should load public rules from `//omniverse:defs.bzl`:

- `omniverse/private/gpu.bzl`: GPU actions, containers, platforms, and workers.
- `omniverse/private/usd.bzl`: adapter-based USD actions.
- `omniverse/providers.bzl`: typed providers returned by public rules.
- `tools/`: built-in packaging and real NVIDIA adapter entry points.
- `examples/`: public, reproducible rule demonstrations.

The private implementation follows established Bazel rule-set conventions:
declared inputs and outputs, `cfg = "exec"` tools, providers, constraints,
execution properties, and `ctx.actions.run`.

## Known boundaries

- Kit execution and Kit `repo` publishing require an installed Kit SDK.
- Standalone NVIDIA libraries must be installed in the selected worker runtime.
- Referenced USD dependencies must be declared explicitly for correct caching.
- Streaming services and mutable search endpoints are runtime orchestration,
  not hermetic cacheable transformations.
