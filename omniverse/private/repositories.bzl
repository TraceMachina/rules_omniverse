"""Repository rules for local Omniverse Kit installs."""

def _omniverse_kit_repository_impl(ctx):
    kit_root = ctx.path(ctx.attr.path)
    ctx.symlink(kit_root, "kit")

    repo_line = ""
    repo_attr = ""
    if ctx.attr.repo_executable:
        repo_line = "exports_files([\"kit/%s\"])\n" % ctx.attr.repo_executable
        repo_attr = "    repo = \"kit/%s\",\n" % ctx.attr.repo_executable

    ctx.file(
        "BUILD.bazel",
        """load("@rules_omniverse//omniverse:toolchains.bzl", "omni_kit_toolchain")

package(default_visibility = ["//visibility:public"])

exports_files(["kit/{kit_executable}"])
{repo_line}
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
            kit_executable = ctx.attr.kit_executable,
            platform = ctx.attr.platform,
            repo_attr = repo_attr,
            repo_line = repo_line,
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
