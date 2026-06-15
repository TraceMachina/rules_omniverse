"""Rules for portable Omniverse app bundles."""

load("//omniverse:providers.bzl", "OmniAssetBundleInfo", "OmniExtensionInfo", "OmniKitAppInfo")
load("//omniverse/private:common.bzl", "collect_default_files", "package_relative_path", "package_tool_attrs", "run_package_tool", "write_package_spec")

def _omni_app_bundle_impl(ctx):
    app = ctx.attr.app[OmniKitAppInfo]
    extension_infos = [ext[OmniExtensionInfo] for ext in ctx.attr.extensions]
    asset_infos = [asset[OmniAssetBundleInfo] for asset in ctx.attr.assets]

    files = [
        {
            "dest": "apps/%s" % app.app_file.basename,
            "role": "kit_app",
            "src": app.app_file.path,
        },
    ]
    inputs = [app.app_file]
    dirs = []
    for ext in extension_infos:
        dirs.append({
            "dest": "exts/%s" % ext.name,
            "role": "extension",
            "src": ext.root.path,
        })
        inputs.append(ext.root)
    for asset in asset_infos:
        dirs.append({
            "dest": "assets/%s" % asset.name,
            "role": "asset_bundle",
            "src": asset.root.path,
        })
        inputs.append(asset.root)
    for file in collect_default_files(ctx.attr.extra_files):
        files.append({
            "dest": "extra/%s" % package_relative_path(ctx, file, ctx.attr.strip_prefix),
            "role": "extra",
            "src": file.path,
        })
        inputs.append(file)

    root = ctx.actions.declare_directory(ctx.label.name + ".bundle")
    archive = ctx.actions.declare_file(ctx.label.name + ".zip")
    metadata = ctx.actions.declare_file(ctx.label.name + ".omniverse_bundle.json")
    spec = write_package_spec(
        ctx,
        name = ctx.attr.bundle_name,
        kind = "app_bundle",
        dirs = dirs,
        files = files,
        metadata = {
            "app": app.name,
            "assets": [asset.name for asset in asset_infos],
            "bundle_name": ctx.attr.bundle_name,
            "extensions": [ext.name for ext in extension_infos],
        },
    )
    run_package_tool(
        ctx,
        spec = spec,
        root = root,
        archive = archive,
        metadata = metadata,
        inputs = inputs,
        mnemonic = "OmniPackageAppBundle",
        progress = "Packaging Omniverse app bundle %s" % ctx.attr.bundle_name,
    )

    return [
        DefaultInfo(
            files = depset([archive, root, metadata]),
            runfiles = ctx.runfiles(files = [archive, root, metadata]),
        ),
        OutputGroupInfo(
            archive = depset([archive]),
            metadata = depset([metadata]),
            root = depset([root]),
        ),
    ]

_attrs = {
    "app": attr.label(
        providers = [OmniKitAppInfo],
        mandatory = True,
        doc = "Kit app target.",
    ),
    "assets": attr.label_list(
        providers = [OmniAssetBundleInfo],
        doc = "Asset bundle targets to include.",
    ),
    "bundle_name": attr.string(
        mandatory = True,
        doc = "Logical bundle name.",
    ),
    "extensions": attr.label_list(
        providers = [OmniExtensionInfo],
        doc = "Extension targets to include.",
    ),
    "extra_files": attr.label_list(
        allow_files = True,
        doc = "Extra files copied under extra/.",
    ),
    "strip_prefix": attr.string(
        doc = "Optional prefix stripped from extra file destination paths.",
    ),
}
_attrs.update(package_tool_attrs())

omni_app_bundle = rule(
    implementation = _omni_app_bundle_impl,
    attrs = _attrs,
    doc = "Packages a portable Omniverse Kit application bundle.",
)
