"""Rules for Omniverse Kit applications."""

load("//omniverse:providers.bzl", "OmniExtensionInfo", "OmniKitAppInfo")
load("//omniverse/private:common.bzl", "workspace_runfiles_path")

def _toml_quote(value):
    return "\"" + value.replace("\\", "\\\\").replace("\"", "\\\"") + "\""

def _dependency_value(value):
    if not value:
        return "{}"
    stripped = value.strip()
    if stripped.startswith("{"):
        return stripped
    return "{ version = %s }" % _toml_quote(stripped)

def _omni_kit_app_impl(ctx):
    app_file = ctx.actions.declare_file(ctx.label.name + ".kit")
    metadata = ctx.actions.declare_file(ctx.label.name + ".omniverse_app.json")
    launcher = ctx.actions.declare_file(ctx.label.name + "_launcher.sh")

    extension_infos = [ext[OmniExtensionInfo] for ext in ctx.attr.extensions]
    dependencies = {}
    for ext in extension_infos:
        dependencies[ext.name] = ext.version
    for key, value in ctx.attr.dependencies.items():
        dependencies[key] = value

    lines = [
        "[package]",
        "title = %s" % _toml_quote(ctx.attr.title),
        "version = %s" % _toml_quote(ctx.attr.version),
        "keywords = [\"app\"]",
        "",
        "[dependencies]",
    ]
    for dep_name in sorted(dependencies.keys()):
        lines.append("%s = %s" % (_toml_quote(dep_name), _dependency_value(dependencies[dep_name])))
    if ctx.attr.settings.strip():
        lines.extend(["", "[settings]", ctx.attr.settings.strip(), ""])
    else:
        lines.append("")

    ctx.actions.write(app_file, "\n".join(lines))
    ctx.actions.write(
        metadata,
        json.encode({
            "dependencies": sorted(dependencies.keys()),
            "kind": "kit_app",
            "name": ctx.label.name,
            "title": ctx.attr.title,
            "version": ctx.attr.version,
        }),
    )

    app_runfile = workspace_runfiles_path(ctx, app_file)
    script = """#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${{RUNFILES_DIR:-}}" ]]; then
  RUNFILES="$RUNFILES_DIR"
else
  RUNFILES="$0.runfiles"
fi
KIT="${{OMNI_KIT:-kit}}"
exec "$KIT" "$RUNFILES/{app}" "$@"
""".format(app = app_runfile)
    ctx.actions.write(launcher, script, is_executable = True)

    runfiles = ctx.runfiles(files = [app_file, metadata] + [ext.root for ext in extension_infos])
    return [
        DefaultInfo(
            executable = launcher,
            files = depset([app_file, launcher, metadata]),
            runfiles = runfiles,
        ),
        OutputGroupInfo(metadata = depset([metadata])),
        OmniKitAppInfo(
            app_file = app_file,
            extensions = extension_infos,
            launcher = launcher,
            metadata = metadata,
            name = ctx.label.name,
            version = ctx.attr.version,
        ),
    ]

omni_kit_app = rule(
    implementation = _omni_kit_app_impl,
    executable = True,
    attrs = {
        "dependencies": attr.string_dict(
            doc = "Additional Kit extension dependencies. Values may be versions or raw TOML inline tables.",
        ),
        "extensions": attr.label_list(
            providers = [OmniExtensionInfo],
            doc = "Extension targets to enable as app dependencies.",
        ),
        "settings": attr.string(
            doc = "Raw TOML settings body appended under [settings].",
        ),
        "title": attr.string(
            mandatory = True,
            doc = "Application title.",
        ),
        "version": attr.string(
            mandatory = True,
            doc = "Application version.",
        ),
    },
    doc = "Generates a Kit .kit application config and bazel run launcher.",
)
