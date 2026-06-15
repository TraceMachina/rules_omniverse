"""Rules for Kit repo publish configuration."""

load("//omniverse:providers.bzl", "OmniExtensionInfo", "OmniRepoPublishInfo")

def _toml_string(value):
    return "\"" + value.replace("\\", "\\\\").replace("\"", "\\\"") + "\""

def _toml_array(values):
    return "[\n%s\n]" % "".join(["    %s,\n" % _toml_string(value) for value in values])

def _omni_repo_publish_config_impl(ctx):
    repo_toml = ctx.actions.declare_file(ctx.label.name + ".repo.toml")
    included = []
    included.extend([ext[OmniExtensionInfo].name for ext in ctx.attr.extensions])
    included.extend(ctx.attr.include)
    content = "\n".join([
        "[repo_publish_exts]",
        "exts.include = %s" % _toml_array(sorted(included)),
        "exts.exclude = %s" % _toml_array(sorted(ctx.attr.exclude)),
        "publish_verification = %s" % ("true" if ctx.attr.publish_verification else "false"),
        "",
    ])
    ctx.actions.write(repo_toml, content)
    return [
        DefaultInfo(files = depset([repo_toml])),
        OmniRepoPublishInfo(
            extensions = sorted(included),
            repo_toml = repo_toml,
        ),
    ]

omni_repo_publish_config = rule(
    implementation = _omni_repo_publish_config_impl,
    attrs = {
        "exclude": attr.string_list(
            doc = "Extension name patterns to exclude.",
        ),
        "extensions": attr.label_list(
            providers = [OmniExtensionInfo],
            doc = "Extension targets to publish.",
        ),
        "include": attr.string_list(
            doc = "Additional extension name patterns to include.",
        ),
        "publish_verification": attr.bool(
            default = True,
            doc = "Whether Kit publish verification should be enabled.",
        ),
    },
    doc = "Generates a Kit repo.toml publish_exts configuration.",
)
