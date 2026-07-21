"""Shared helpers for rules_omniverse implementation."""

load("//omniverse:providers.bzl", "OmniAssetBundleInfo", "OmniExtensionInfo", "OmniKitAppInfo")

def collect_default_files(targets):
    files = []
    for target in targets:
        files.extend(target[DefaultInfo].files.to_list())
    return files

def package_relative_path(ctx, file, strip_prefix = ""):
    short_path = file.short_path
    if strip_prefix:
        prefix = strip_prefix.rstrip("/") + "/"
        if short_path == strip_prefix:
            return file.basename
        if short_path.startswith(prefix):
            return short_path[len(prefix):]
        fail("File %s does not start with strip_prefix %s" % (short_path, strip_prefix))

    package = ctx.label.package
    if package and short_path.startswith(package + "/"):
        return short_path[len(package) + 1:]

    return file.basename

def package_tool_attrs():
    return {
        "packager": attr.label(
            default = Label("//tools:package_omniverse"),
            executable = True,
            cfg = "exec",
            doc = "Packaging executable. Override with a worker-native script for cross-platform remote execution.",
        ),
    }

def write_package_spec(ctx, *, name, kind, files = [], dirs = [], metadata = {}, manifest = None):
    spec = ctx.actions.declare_file(ctx.label.name + ".package_spec.json")
    ctx.actions.write(
        output = spec,
        content = json.encode({
            "dirs": dirs,
            "files": files,
            "kind": kind,
            "manifest": manifest.path if manifest else "",
            "metadata": metadata,
            "name": name,
        }),
    )
    return spec

def run_package_tool(ctx, *, spec, root, archive, metadata, inputs, mnemonic, progress):
    packager = ctx.attr.packager[DefaultInfo].files_to_run
    args = ctx.actions.args()
    args.add("--spec", spec)
    args.add("--root-out", root.path)
    args.add("--archive-out", archive.path)
    args.add("--metadata-out", metadata.path)

    ctx.actions.run(
        executable = packager,
        arguments = [args],
        inputs = depset(inputs + [spec]),
        outputs = [root, archive, metadata],
        tools = [packager],
        mnemonic = mnemonic,
        progress_message = progress,
    )

def direct_omni_files(targets):
    files = []
    for target in targets:
        if OmniExtensionInfo in target:
            files.append(target[OmniExtensionInfo].metadata)
        elif OmniKitAppInfo in target:
            files.append(target[OmniKitAppInfo].metadata)
        elif OmniAssetBundleInfo in target:
            files.append(target[OmniAssetBundleInfo].metadata)
        else:
            files.extend(target[DefaultInfo].files.to_list())
    return files

def workspace_runfiles_path(ctx, file):
    workspace = ctx.workspace_name
    if not workspace:
        workspace = "_main"
    return "%s/%s" % (workspace, file.short_path)
