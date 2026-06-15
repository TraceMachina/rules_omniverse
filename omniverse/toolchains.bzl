"""Toolchain definitions for locally supplied NVIDIA Omniverse Kit tools."""

load("//omniverse:providers.bzl", "OmniKitToolchainInfo")

def _omni_kit_toolchain_impl(ctx):
    info = OmniKitToolchainInfo(
        kit = ctx.file.kit,
        repo = ctx.file.repo,
        platform = ctx.attr.platform,
    )
    return [
        info,
        platform_common.ToolchainInfo(omniverse = info),
    ]

omni_kit_toolchain = rule(
    implementation = _omni_kit_toolchain_impl,
    attrs = {
        "kit": attr.label(
            allow_single_file = True,
            executable = True,
            cfg = "exec",
            mandatory = True,
            doc = "Kit executable.",
        ),
        "platform": attr.string(
            doc = "Optional platform/config name such as linux-x86_64/release.",
        ),
        "repo": attr.label(
            allow_single_file = True,
            executable = True,
            cfg = "exec",
            doc = "Kit repo executable.",
        ),
    },
    doc = "Declares an Omniverse Kit toolchain implementation.",
)
