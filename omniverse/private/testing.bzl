"""Testing rules for Omniverse targets."""

load("//omniverse:providers.bzl", "OmniAssetBundleInfo", "OmniExtensionInfo", "OmniKitAppInfo")
load("//omniverse/private:common.bzl", "workspace_runfiles_path")

def _metadata_from_target(target):
    if OmniExtensionInfo in target:
        return target[OmniExtensionInfo].metadata
    if OmniKitAppInfo in target:
        return target[OmniKitAppInfo].metadata
    if OmniAssetBundleInfo in target:
        return target[OmniAssetBundleInfo].metadata
    fail("target must provide OmniExtensionInfo, OmniKitAppInfo, or OmniAssetBundleInfo")

def _omni_manifest_test_impl(ctx):
    metadata = _metadata_from_target(ctx.attr.target)
    script = ctx.actions.declare_file(ctx.label.name + "_test.sh")
    checker_info = ctx.attr._checker[DefaultInfo]
    checker = checker_info.files_to_run.executable
    checker_path = workspace_runfiles_path(ctx, checker)
    metadata_path = workspace_runfiles_path(ctx, metadata)
    args = []
    if ctx.attr.kind:
        args.extend(["--kind", ctx.attr.kind])
    if ctx.attr.expected_name:
        args.extend(["--name", ctx.attr.expected_name])
    if ctx.attr.version:
        args.extend(["--version", ctx.attr.version])
    arg_text = " ".join(["'%s'" % arg.replace("'", "'\\''") for arg in args])
    content = """#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${{RUNFILES_DIR:-}}" ]]; then
  RUNFILES="$RUNFILES_DIR"
else
  RUNFILES="$0.runfiles"
fi
exec "$RUNFILES/{checker}" --metadata "$RUNFILES/{metadata}" {args}
""".format(
        args = arg_text,
        checker = checker_path,
        metadata = metadata_path,
    )
    ctx.actions.write(script, content, is_executable = True)
    runfiles = ctx.runfiles(files = [checker, metadata])
    runfiles = runfiles.merge(checker_info.default_runfiles)
    return [
        DefaultInfo(
            executable = script,
            runfiles = runfiles,
        ),
    ]

omni_manifest_test = rule(
    implementation = _omni_manifest_test_impl,
    test = True,
    attrs = {
        "kind": attr.string(doc = "Expected metadata kind."),
        "expected_name": attr.string(doc = "Expected metadata name."),
        "target": attr.label(mandatory = True, doc = "Target with Omniverse metadata."),
        "version": attr.string(doc = "Expected version, when present."),
        "_checker": attr.label(
            default = Label("//tools:assert_manifest"),
            executable = True,
            cfg = "exec",
        ),
    },
    doc = "Validates generated Omniverse metadata.",
)

def _omni_extension_test_impl(ctx):
    ext = ctx.attr.extension[OmniExtensionInfo]
    script = ctx.actions.declare_file(ctx.label.name + "_test.sh")
    ext_path = workspace_runfiles_path(ctx, ext.root)
    kit_file = ctx.executable.kit if ctx.attr.kit else None
    kit_expr = "${OMNI_KIT:-kit}"
    runfiles = [ext.root]
    if kit_file:
        kit_expr = "$RUNFILES/%s" % workspace_runfiles_path(ctx, kit_file)
        runfiles.append(kit_file)
    extra_args = " ".join(["'%s'" % arg.replace("'", "'\\''") for arg in ctx.attr.kit_args])
    content = """#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${{RUNFILES_DIR:-}}" ]]; then
  RUNFILES="$RUNFILES_DIR"
else
  RUNFILES="$0.runfiles"
fi
KIT="{kit}"
exec "$KIT" --ext-path "$RUNFILES/{ext_path}" --enable omni.kit.test --enable "{ext_name}" {extra_args} "$@"
""".format(
        ext_name = ext.name,
        ext_path = ext_path,
        extra_args = extra_args,
        kit = kit_expr,
    )
    ctx.actions.write(script, content, is_executable = True)
    return [
        DefaultInfo(
            executable = script,
            runfiles = ctx.runfiles(files = runfiles),
        ),
    ]

omni_extension_test = rule(
    implementation = _omni_extension_test_impl,
    test = True,
    attrs = {
        "extension": attr.label(
            providers = [OmniExtensionInfo],
            mandatory = True,
            doc = "Extension target under test.",
        ),
        "kit_args": attr.string_list(doc = "Additional arguments passed to Kit."),
        "kit": attr.label(
            allow_single_file = True,
            executable = True,
            cfg = "exec",
            doc = "Optional Kit executable. Defaults to OMNI_KIT or kit.",
        ),
    },
    doc = "Runs an Omniverse Kit extension test invocation.",
)
