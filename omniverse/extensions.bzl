"""Bzlmod extensions for rules_omniverse."""

load("//omniverse/private:repositories.bzl", "omniverse_kit_repository")

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

kit = module_extension(
    implementation = _kit_impl,
    tag_classes = {
        "local": tag_class(
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
        ),
    },
)
