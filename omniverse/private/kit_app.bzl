"""Rules for Omniverse Kit applications."""

load("//omniverse:providers.bzl", "OmniExtensionInfo", "OmniKitAppInfo")
load("//omniverse/private:common.bzl", "workspace_runfiles_path")

_KIT_TOOLCHAIN_TYPE = "//omniverse:toolchain_type"

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
    target_label = "//%s:%s" % (ctx.label.package, ctx.label.name)
    kit_toolchain = ctx.toolchains[_KIT_TOOLCHAIN_TYPE]
    kit_file = kit_toolchain.omniverse.kit if kit_toolchain else None
    toolchain_kit = ""
    if kit_file:
        toolchain_kit = "$RUNFILES/%s" % workspace_runfiles_path(ctx, kit_file)
    script = """#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${{RUNFILES_DIR:-}}" ]]; then
  RUNFILES="$RUNFILES_DIR"
else
  RUNFILES="$0.runfiles"
fi
TOOLCHAIN_KIT="{toolchain_kit}"
if [[ -n "${{OMNI_KIT:-}}" ]]; then
  KIT="$OMNI_KIT"
elif [[ -n "$TOOLCHAIN_KIT" ]]; then
  KIT="$TOOLCHAIN_KIT"
elif command -v kit >/dev/null 2>&1; then
  KIT="$(command -v kit)"
else
  cat >&2 <<'EOF'
rules_omniverse: NVIDIA Omniverse Kit is required to run {target}.

Kit is an external NVIDIA SDK and is not downloaded by rules_omniverse.
Install Kit, then use one of these options:
  1. Register the local Kit install with the rules_omniverse module extension.
  2. Set OMNI_KIT=/absolute/path/to/kit for this invocation.
  3. Add the Kit executable to PATH.

Generating .kit files, bundles, and metadata does not require Kit; launching an
omni_kit_app does. See the rules_omniverse README for configuration examples.
EOF
  exit 127
fi
if [[ "$KIT" == */* ]]; then
  if [[ ! -x "$KIT" ]]; then
    echo "rules_omniverse: Kit executable is missing or not executable: $KIT" >&2
    exit 126
  fi
elif ! command -v "$KIT" >/dev/null 2>&1; then
  echo "rules_omniverse: Kit command was not found on PATH: $KIT" >&2
  exit 127
fi
exec "$KIT" "$RUNFILES/{app}" "$@"
""".format(
        app = app_runfile,
        target = target_label,
        toolchain_kit = toolchain_kit,
    )
    ctx.actions.write(launcher, script, is_executable = True)

    runfiles_files = [app_file, metadata] + [ext.root for ext in extension_infos]
    if kit_file:
        runfiles_files.append(kit_file)
    runfiles = ctx.runfiles(files = runfiles_files)
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
    toolchains = [
        config_common.toolchain_type(_KIT_TOOLCHAIN_TYPE, mandatory = False),
    ],
)
