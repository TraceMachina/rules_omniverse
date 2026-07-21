"""Small analysis probes for public provider contract tests."""

load("//omniverse:providers.bzl", "OmniUsdInfo")

def _omni_usd_info_probe_impl(ctx):
    info = ctx.attr.target[OmniUsdInfo]
    output = ctx.actions.declare_file(ctx.label.name + ".txt")
    ctx.actions.write(
        output,
        "\n".join([
            "operation=%s" % info.operation,
            "source=%s" % info.source.short_path,
            "stage=%s" % info.stage.short_path,
            "",
        ]),
    )
    return [DefaultInfo(files = depset([output]))]

omni_usd_info_probe = rule(
    implementation = _omni_usd_info_probe_impl,
    attrs = {
        "target": attr.label(
            mandatory = True,
            providers = [OmniUsdInfo],
        ),
    },
)
