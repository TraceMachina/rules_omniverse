# rules_omniverse

Bazel rules for NVIDIA Omniverse Kit applications, extensions, USD assets, and
extension publishing workflows.

The ruleset is designed for repositories that want Bazel to own the reproducible
parts of an Omniverse delivery pipeline while still allowing NVIDIA Kit and
registry tools to remain externally supplied SDK tools.

## Install

```starlark
bazel_dep(name = "rules_omniverse", version = "0.1.0")
```

If Kit is installed outside Bazel, register it with the module extension:

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

## Why this is useful

Users get Bazel-native dependency tracking, cached packaging, repeatable outputs,
CI-friendly tests, and a clean path to remote execution with systems like
Nativelink or BuildFarm. For example, a Nativelink Omniverse extension can declare its UI
code, assets, and Kit app wrapper once, then Bazel can build the extension
package, app bundle, metadata tests, and publish config consistently on every
machine.

## Rules

- `omni_extension`: validates and packages an Omniverse extension folder.
- `omni_kit_app`: writes a `.kit` app file and a `bazel run` launcher.
- `omni_app_bundle`: creates a portable app bundle containing apps, extensions,
  and asset bundles.
- `omni_asset_bundle`: validates and packages USD, MDL, texture, and data assets.
- `omni_repo_publish_config`: writes `repo.toml` publish configuration for Kit's
  `repo publish_exts` workflow.
- `omni_extension_test`: runs a Kit extension startup/test invocation.
- `omni_manifest_test`: validates rule metadata without requiring Kit.
- `omni_kit_toolchain`: exposes locally installed Kit and `repo` executables.

## Nativelink Example

```starlark
load("@rules_omniverse//omniverse:defs.bzl", "omni_extension", "omni_kit_app")

omni_extension(
    name = "nativelink_build_viewer_ext",
    extension_name = "com.nativelink.build.viewer",
    manifest = "config/extension.toml",
    srcs = glob([
        "config/**",
        "com/**",
        "data/**",
    ]),
)

omni_kit_app(
    name = "nativelink_build_viewer",
    title = "Nativelink Build Viewer",
    version = "0.1.0",
    extensions = [":nativelink_build_viewer_ext"],
    settings = """
app.window.title = "Nativelink Build Viewer"
app.exts.folders."++" = ["${app}/../exts"]
""",
)
```

Run the app with:

```bash
OMNI_KIT=/path/to/kit bazel run //examples/nativelink:nativelink_build_viewer
```

Build a portable bundle:

```starlark
load("@rules_omniverse//omniverse:defs.bzl", "omni_app_bundle")

omni_app_bundle(
    name = "nativelink_bundle",
    app = ":nativelink_build_viewer",
    extensions = [":nativelink_build_viewer_ext"],
)
```

## Omniverse Notes

Kit extensions are folders with an `extension.toml` config. A `.kit` file is the
recommended application config format and can define extension dependencies and
settings. Kit extension tests commonly run through `omni.kit.test`, while
publishing uses Kit's `repo publish_exts` flow.
