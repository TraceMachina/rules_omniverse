"""Bzlmod extensions for rules_omniverse.

The Kit SDK can be supplied two ways, and both are first class:

  * `kit.local()` points at a Kit or Isaac Sim install already on the machine.
  * `kit.download()` fetches the prebuilt Kit kernel for the host platform, so a
    build needs no preinstalled SDK. Kit itself is closed source; only its
    published binaries are downloaded, and they are pinned by sha256.

`kit.extensions()` does the same for the Kit extensions that ship only as
prebuilts (`omni.replicator.core`, the RTX renderer, `omni.graph`, ...). Those are
listed in a JSON lock so the set stays reproducible.
"""

load(
    "//omniverse/private:repositories.bzl",
    "omniverse_kit_download_repository",
    "omniverse_kit_extension_hub_repository",
    "omniverse_kit_extension_repository",
    "omniverse_kit_repository",
)

def _ext_repo_name(hub_name, extension_name):
    return "{hub}_{ext}".format(
        hub = hub_name,
        ext = extension_name.replace(".", "_").replace("-", "_"),
    )

def _kit_impl(module_ctx):
    for mod in module_ctx.modules:
        for tag in mod.tags.local:
            omniverse_kit_repository(
                name = tag.name,
                kit_executable = tag.kit_executable,
                path = tag.path,
                platform = tag.platform,
                repo_executable = tag.repo_executable,
            )

        for tag in mod.tags.download:
            omniverse_kit_download_repository(
                name = tag.name,
                abi = tag.abi,
                config = tag.config,
                kit_executable = tag.kit_executable,
                platform = tag.platform,
                sha256 = tag.sha256,
                version = tag.version,
            )

        for tag in mod.tags.extensions:
            lock = json.decode(module_ctx.read(tag.lock))
            packages = {}
            for package_id, spec in lock.items():
                repo = _ext_repo_name(tag.name, spec["name"])
                omniverse_kit_extension_repository(
                    name = repo,
                    package_id = package_id,
                    sha256 = spec["sha256"],
                    url = spec["url"],
                )
                packages[package_id] = repo

            omniverse_kit_extension_hub_repository(
                name = tag.name,
                packages = packages,
            )

    return module_ctx.extension_metadata(reproducible = True)

_local = tag_class(
    attrs = {
        "kit_executable": attr.string(
            default = "kit",
            doc = "Path to the Kit executable relative to path.",
        ),
        "name": attr.string(
            default = "omniverse_kit",
            doc = "Generated repository name.",
        ),
        "path": attr.string(
            mandatory = True,
            doc = "Local Kit SDK/install root.",
        ),
        "platform": attr.string(
            default = "",
            doc = "Optional platform/config identifier.",
        ),
        "repo_executable": attr.string(
            default = "repo",
            doc = "Path to the repo executable relative to path.",
        ),
    },
    doc = "Registers a local NVIDIA Omniverse Kit install.",
)

_download = tag_class(
    attrs = {
        "abi": attr.string(
            doc = "Override the detected packman platform_target_abi, e.g. " +
                  "\"manylinux_2_35_x86_64\".",
        ),
        "config": attr.string(
            default = "release",
            doc = "Kit build config: release or debug.",
        ),
        "kit_executable": attr.string(
            default = "kit",
            doc = "Kit executable name inside the archive.",
        ),
        "name": attr.string(
            default = "omniverse_kit",
            doc = "Generated repository name.",
        ),
        "platform": attr.string(
            doc = "Platform identifier reported by the toolchain; derived if unset.",
        ),
        "sha256": attr.string_dict(
            doc = "Archive digests keyed by platform_target_abi. May be omitted " +
                  "for kernel versions this ruleset already knows.",
        ),
        "version": attr.string(
            mandatory = True,
            doc = "kit-kernel package version, e.g. \"110.1.1+production\" -- what " +
                  "an Isaac Sim release pins in deps/kit-sdk.packman.xml.",
        ),
    },
    doc = "Downloads a prebuilt Kit kernel for the host platform (no install needed).",
)

_extensions = tag_class(
    attrs = {
        "lock": attr.label(
            mandatory = True,
            allow_single_file = True,
            doc = "JSON lock mapping registry packageId -> {name, url, sha256}.",
        ),
        "name": attr.string(
            default = "omniverse_kit_exts",
            doc = "Name of the generated hub repository.",
        ),
    },
    doc = "Downloads the prebuilt-only Kit extensions listed in a JSON lock.",
)

kit = module_extension(
    implementation = _kit_impl,
    tag_classes = {
        "download": _download,
        "extensions": _extensions,
        "local": _local,
    },
)
