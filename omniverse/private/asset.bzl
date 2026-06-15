"""Rules for Omniverse asset bundles."""

load("//omniverse:providers.bzl", "OmniAssetBundleInfo")
load("//omniverse/private:common.bzl", "collect_default_files", "package_relative_path", "package_tool_attrs", "run_package_tool", "write_package_spec")

_DEFAULT_ALLOWED_SUFFIXES = [
    ".usd",
    ".usda",
    ".usdc",
    ".usdz",
    ".mdl",
    ".png",
    ".jpg",
    ".jpeg",
    ".exr",
    ".hdr",
    ".json",
    ".txt",
]

def _omni_asset_bundle_impl(ctx):
    files = []
    inputs = []
    for file in collect_default_files(ctx.attr.srcs):
        files.append({
            "dest": package_relative_path(ctx, file, ctx.attr.strip_prefix),
            "role": "asset",
            "src": file.path,
        })
        inputs.append(file)

    root = ctx.actions.declare_directory(ctx.label.name + ".assets")
    archive = ctx.actions.declare_file(ctx.label.name + ".zip")
    metadata = ctx.actions.declare_file(ctx.label.name + ".omniverse_assets.json")
    spec = write_package_spec(
        ctx,
        name = ctx.attr.bundle_name,
        kind = "asset_bundle",
        files = files,
        metadata = {
            "allowed_suffixes": ctx.attr.allowed_suffixes,
            "bundle_name": ctx.attr.bundle_name,
            "strict": ctx.attr.strict,
        },
    )

    run_package_tool(
        ctx,
        spec = spec,
        root = root,
        archive = archive,
        metadata = metadata,
        inputs = inputs,
        mnemonic = "OmniPackageAssets",
        progress = "Packaging Omniverse asset bundle %s" % ctx.attr.bundle_name,
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
        OmniAssetBundleInfo(
            archive = archive,
            metadata = metadata,
            name = ctx.attr.bundle_name,
            root = root,
        ),
    ]

_attrs = {
    "allowed_suffixes": attr.string_list(
        default = _DEFAULT_ALLOWED_SUFFIXES,
        doc = "Allowed file suffixes when strict validation is enabled.",
    ),
    "bundle_name": attr.string(
        mandatory = True,
        doc = "Logical name for the asset bundle.",
    ),
    "srcs": attr.label_list(
        allow_files = True,
        mandatory = True,
        doc = "Asset files.",
    ),
    "strict": attr.bool(
        default = True,
        doc = "Validate asset file suffixes.",
    ),
    "strip_prefix": attr.string(
        doc = "Optional prefix stripped from asset destination paths.",
    ),
}
_attrs.update(package_tool_attrs())

omni_asset_bundle = rule(
    implementation = _omni_asset_bundle_impl,
    attrs = _attrs,
    doc = "Packages USD, MDL, texture, and data assets for Omniverse apps.",
)
