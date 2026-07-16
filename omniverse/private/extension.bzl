"""Rules for Omniverse Kit extensions."""

load("//omniverse:providers.bzl", "OmniExtensionInfo")
load("//omniverse/private:common.bzl", "collect_default_files", "package_relative_path", "package_tool_attrs", "run_package_tool", "write_package_spec")

def _omni_extension_impl(ctx):
    manifest = ctx.file.manifest
    files = []
    inputs = []
    seen_paths = {}

    def add_file(file, dest, role = "content"):
        if dest in seen_paths and seen_paths[dest] != file.path:
            fail("Duplicate extension destination %s from %s and %s" % (dest, seen_paths[dest], file.path))
        seen_paths[dest] = file.path
        files.append({
            "dest": dest,
            "role": role,
            "src": file.path,
        })
        inputs.append(file)

    manifest_dest = ctx.attr.manifest_path
    if not manifest_dest:
        manifest_dest = package_relative_path(ctx, manifest, ctx.attr.strip_prefix)
    add_file(manifest, manifest_dest, "manifest")

    for file in collect_default_files(ctx.attr.srcs):
        if file.path == manifest.path:
            continue
        add_file(file, package_relative_path(ctx, file, ctx.attr.strip_prefix))

    native_dest_prefix = "bin/%s/%s" % (ctx.attr.target_platform, ctx.attr.build_config)
    for file in collect_default_files(ctx.attr.native_plugins):
        add_file(file, "%s/%s" % (native_dest_prefix, file.basename), "native_plugin")

    dep_infos = [dep[OmniExtensionInfo] for dep in ctx.attr.deps]
    root = ctx.actions.declare_directory(ctx.label.name + ".extension")
    archive = ctx.actions.declare_file(ctx.label.name + ".zip")
    metadata = ctx.actions.declare_file(ctx.label.name + ".omniverse_extension.json")
    version = ctx.attr.version
    extension_id = ctx.attr.extension_id
    if not extension_id:
        extension_id = ctx.attr.extension_name if not version else "%s-%s" % (ctx.attr.extension_name, version)

    spec = write_package_spec(
        ctx,
        name = ctx.attr.extension_name,
        kind = "extension",
        files = files,
        metadata = {
            "build_config": ctx.attr.build_config,
            "dependencies": [dep.name for dep in dep_infos],
            "extension_id": extension_id,
            "extension_name": ctx.attr.extension_name,
            "strict": ctx.attr.strict,
            "target_platform": ctx.attr.target_platform,
            "version": version,
        },
        manifest = manifest,
    )

    run_package_tool(
        ctx,
        spec = spec,
        root = root,
        archive = archive,
        metadata = metadata,
        inputs = inputs,
        mnemonic = "OmniPackageExtension",
        progress = "Packaging Omniverse extension %s" % ctx.attr.extension_name,
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
        OmniExtensionInfo(
            archive = archive,
            deps = dep_infos,
            extension_id = extension_id,
            manifest = manifest,
            metadata = metadata,
            name = ctx.attr.extension_name,
            root = root,
            version = version,
        ),
    ]

_attrs = {
    "build_config": attr.string(
        default = "release",
        doc = "Build config used for native plugin destination paths.",
    ),
    "deps": attr.label_list(
        providers = [OmniExtensionInfo],
        doc = "Direct Omniverse extension dependencies.",
    ),
    "extension_id": attr.string(
        doc = "Optional explicit extension id. Defaults to extension_name or extension_name-version.",
    ),
    "extension_name": attr.string(
        mandatory = True,
        doc = "Omniverse extension name, for example com.example.asset.viewer.",
    ),
    "manifest": attr.label(
        allow_single_file = True,
        mandatory = True,
        doc = "extension.toml manifest file.",
    ),
    "manifest_path": attr.string(
        doc = "Destination path for the manifest inside the extension package.",
    ),
    "native_plugins": attr.label_list(
        allow_files = True,
        doc = "Native shared libraries copied to bin/<target_platform>/<build_config>/.",
    ),
    "srcs": attr.label_list(
        allow_files = True,
        doc = "Files copied into the extension root.",
    ),
    "strict": attr.bool(
        default = True,
        doc = "Enable stricter manifest validation.",
    ),
    "strip_prefix": attr.string(
        doc = "Optional prefix stripped from src destination paths.",
    ),
    "target_platform": attr.string(
        default = "linux-x86_64",
        doc = "Kit target platform used for native plugin destination paths.",
    ),
    "version": attr.string(
        doc = "Optional expected extension version. If set, it must match the manifest.",
    ),
}
_attrs.update(package_tool_attrs())

omni_extension = rule(
    implementation = _omni_extension_impl,
    attrs = _attrs,
    doc = "Packages and validates an NVIDIA Omniverse Kit extension.",
)
