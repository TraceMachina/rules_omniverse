"""Repository rules for Omniverse Kit installs, local or downloaded."""

# NVIDIA publishes the closed Kit binaries on the packman CDN, addressed as
# "<name>@<version>.zip". This is the remote declared by Kit's own
# tools/packman/config.packman.xml.
PACKMAN_CDN = "https://d4i3qtqj3r0z5.cloudfront.net"

# Archive digests for Kit kernel versions this ruleset has been tested against,
# so that the common case needs no `sha256` from the caller. Keyed
# "<version>/<abi>/<config>".
KNOWN_KIT_KERNEL_SHA256 = {
    "110.1.1+production/manylinux_2_35_x86_64/release": "59c139b0229c189661fa653b60a9f604b27465c23f872be1bdc2b57ea589e78b",
    "110.1.1+production/manylinux_2_35_aarch64/release": "ec7c16673f8aca23a9628c3b85f532c264d8541de24ff856e0617b0d9adf1d09",
}

def packman_url(name, version):
    """URL of a packman package archive.

    Args:
        name: Package name, e.g. "kit-kernel".
        version: Full package version including platform/config suffixes.

    Returns:
        The download URL. '@' stays literal; '+' must be percent-encoded.
    """
    return "{cdn}/{name}@{version}.zip".format(
        cdn = PACKMAN_CDN,
        name = name,
        version = version.replace("+", "%2B"),
    )

def target_abi(repository_ctx):
    """packman platform_target_abi for the host, as Kit spells it."""
    os_name = repository_ctx.os.name.lower()
    arch = repository_ctx.os.arch.lower()

    if os_name.startswith("linux"):
        if arch in ("amd64", "x86_64", "x64"):
            return "manylinux_2_35_x86_64"
        if arch in ("aarch64", "arm64"):
            return "manylinux_2_35_aarch64"
    elif os_name.startswith("windows"):
        if arch in ("amd64", "x86_64", "x64"):
            return "windows-x86_64"

    fail(
        "no Kit kernel package for os={os} arch={arch}; ".format(os = os_name, arch = arch) +
        "pass abi = \"...\" to select one explicitly",
    )

def _kit_build_file(kit_executable, repo_executable, platform):
    """BUILD file exposing a Kit tree, identical for local and downloaded installs."""
    repo_line = ""
    repo_attr = ""
    if repo_executable:
        repo_line = "exports_files([\"kit/%s\"])\n" % repo_executable
        repo_attr = "    repo = \"kit/%s\",\n" % repo_executable

    return """load("@rules_omniverse//omniverse:toolchains.bzl", "omni_kit_toolchain")

package(default_visibility = ["//visibility:public"])

exports_files(["kit/{kit_executable}"])
{repo_line}
# Kit resolves its plugins and shared libraries relative to the executable, so
# anything that runs Kit must carry the whole tree in its runfiles.
filegroup(
    name = "dist",
    srcs = glob(["kit/**"], allow_empty = True),
)

omni_kit_toolchain(
    name = "toolchain_impl",
    kit = "kit/{kit_executable}",
{repo_attr}    platform = "{platform}",
)

toolchain(
    name = "toolchain",
    toolchain = ":toolchain_impl",
    toolchain_type = "@rules_omniverse//omniverse:toolchain_type",
)
""".format(
        kit_executable = kit_executable,
        platform = platform,
        repo_attr = repo_attr,
        repo_line = repo_line,
    )

def _omniverse_kit_repository_impl(ctx):
    kit_root = ctx.path(ctx.attr.path)
    ctx.symlink(kit_root, "kit")
    ctx.file(
        "BUILD.bazel",
        _kit_build_file(
            ctx.attr.kit_executable,
            ctx.attr.repo_executable,
            ctx.attr.platform,
        ),
    )

omniverse_kit_repository = repository_rule(
    implementation = _omniverse_kit_repository_impl,
    attrs = {
        "kit_executable": attr.string(default = "kit"),
        "path": attr.string(mandatory = True),
        "platform": attr.string(default = ""),
        "repo_executable": attr.string(default = "repo"),
    },
    doc = "Exposes a local NVIDIA Omniverse Kit install as a Bazel repository.",
    local = True,
)

def _omniverse_kit_download_repository_impl(ctx):
    abi = ctx.attr.abi or target_abi(ctx)
    version = "{version}.{abi}.{config}".format(
        version = ctx.attr.version,
        abi = abi,
        config = ctx.attr.config,
    )

    sha256 = ctx.attr.sha256.get(abi, "")
    if not sha256:
        sha256 = KNOWN_KIT_KERNEL_SHA256.get(
            "{v}/{abi}/{cfg}".format(v = ctx.attr.version, abi = abi, cfg = ctx.attr.config),
            "",
        )
    if not sha256:
        fail(
            "no sha256 known for kit-kernel {v} on {abi} ({cfg}). ".format(
                v = ctx.attr.version,
                abi = abi,
                cfg = ctx.attr.config,
            ) +
            "Pass it explicitly, e.g. sha256 = {\"%s\": \"<digest>\"}." % abi,
        )

    # Extract under kit/ so that downloaded and local installs expose the same
    # labels; the archive itself has the runtime at its root.
    ctx.download_and_extract(
        url = packman_url("kit-kernel", version),
        sha256 = sha256,
        output = "kit",
        type = "zip",
    )

    ctx.file(
        "BUILD.bazel",
        _kit_build_file(
            ctx.attr.kit_executable,
            ctx.attr.repo_executable,
            ctx.attr.platform or "{abi}/{cfg}".format(abi = abi, cfg = ctx.attr.config),
        ),
    )

omniverse_kit_download_repository = repository_rule(
    implementation = _omniverse_kit_download_repository_impl,
    attrs = {
        "abi": attr.string(
            doc = "Override the detected packman platform_target_abi.",
        ),
        "config": attr.string(
            default = "release",
            doc = "Kit build config: release or debug.",
        ),
        "kit_executable": attr.string(
            default = "kit",
            doc = "Kit executable name inside the archive.",
        ),
        "platform": attr.string(
            doc = "Platform identifier reported by the toolchain; derived if unset.",
        ),
        "repo_executable": attr.string(
            doc = "repo executable name; the kit-kernel package does not ship one.",
        ),
        "sha256": attr.string_dict(
            doc = "Archive digests keyed by platform_target_abi. Optional for " +
                  "versions listed in KNOWN_KIT_KERNEL_SHA256.",
        ),
        "version": attr.string(
            mandatory = True,
            doc = "kit-kernel package version, e.g. \"110.1.1+production\".",
        ),
    },
    doc = "Downloads a prebuilt NVIDIA Omniverse Kit kernel for the host platform.",
)

_EXT_BUILD = """\
package(default_visibility = ["//visibility:public"])

filegroup(
    name = "ext",
    srcs = glob(
        ["**"],
        exclude = ["BUILD.bazel", "WORKSPACE", "MODULE.bazel", "*.bzl", "kit_package_id"],
    ),
)

# This package's registry id. Kit identifies an extension partly by the name of
# the directory holding it, so a launcher assembling an --ext-folder needs the id
# rather than the Bazel repository name.
exports_files(["config/extension.toml", "kit_package_id"])
"""

def _omniverse_kit_extension_repository_impl(ctx):
    ctx.download_and_extract(url = ctx.attr.url, sha256 = ctx.attr.sha256, type = "zip")
    ctx.file("kit_package_id", ctx.attr.package_id, executable = False)
    ctx.file("BUILD.bazel", _EXT_BUILD)

omniverse_kit_extension_repository = repository_rule(
    implementation = _omniverse_kit_extension_repository_impl,
    attrs = {
        "package_id": attr.string(
            mandatory = True,
            doc = "Registry packageId, e.g. \"omni.replicator.core-1.13.27+...\".",
        ),
        "sha256": attr.string(mandatory = True),
        "url": attr.string(mandatory = True, doc = "Extension archive URL."),
    },
    doc = "Downloads one prebuilt Omniverse Kit extension package.",
)

def _omniverse_kit_extension_hub_repository_impl(ctx):
    # The manifest pairs each extension's registry id with the runfiles path of
    # its extension.toml. Both are only knowable once the spoke repos exist, and
    # a repository rule cannot resolve sibling repos of its own module extension,
    # so it is assembled by an action instead: every spoke ships a
    # `kit_package_id` file, and the path is derived from where that file lands.
    ext_srcs = []
    id_srcs = []
    for repo in sorted(ctx.attr.packages.values()):
        ext_srcs.append('        "@{repo}//:ext",'.format(repo = repo))
        id_srcs.append('        "@{repo}//:kit_package_id",'.format(repo = repo))

    ctx.file(
        "BUILD.bazel",
        """\
package(default_visibility = ["//visibility:public"])

# Every pinned extension, for use in a target's `data`.
filegroup(
    name = "exts",
    srcs = [
{ext_srcs}
    ],
)

filegroup(
    name = "package_ids",
    srcs = [
{id_srcs}
    ],
)

# One "<packageId>\\t<runfiles path of config/extension.toml>" line per extension,
# so a launcher can assemble a directory Kit accepts as --ext-folder.
genrule(
    name = "manifest",
    srcs = [":package_ids"],
    outs = ["manifest.txt"],
    cmd = '''
for f in $(SRCS); do
  dir=$${{f%/kit_package_id}}
  echo "$$(cat $$f)\t$${{dir#external/}}/config/extension.toml"
done > $@
''',
)
""".format(ext_srcs = "\n".join(ext_srcs), id_srcs = "\n".join(id_srcs)),
    )

omniverse_kit_extension_hub_repository = repository_rule(
    implementation = _omniverse_kit_extension_hub_repository_impl,
    attrs = {
        "packages": attr.string_dict(
            mandatory = True,
            doc = "Registry packageId -> extension repository name.",
        ),
    },
    doc = "Aggregates downloaded Kit extensions and emits their runfiles manifest.",
)
