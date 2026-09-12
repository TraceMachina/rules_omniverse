"""Rules for Omniverse Kit extensions."""

load("//omniverse:providers.bzl", "OmniExtensionInfo")
load("//omniverse/private:common.bzl", "collect_default_files", "package_relative_path", "package_tool_attrs", "run_package_tool", "write_package_spec")

_MANIFEST_DIR = "config"

def _extension_root(manifest):
    """Returns the source directory Kit would treat as the extension root.

    Kit discovers an extension through `<root>/config/extension.toml`, so the
    manifest's grandparent directory is the only root that produces a loadable
    package. An empty string means the workspace root.
    """
    segments = manifest.short_path.split("/")
    if len(segments) < 2 or segments[-2] != _MANIFEST_DIR:
        fail(
            "omni_extension manifest %s must live at <extension root>/%s/%s; " % (manifest.short_path, _MANIFEST_DIR, manifest.basename) +
            "set strip_prefix or manifest_path to package a different layout",
        )
    return "/".join(segments[:-2])

def _root_relative_path(file, root):
    if not root:
        return file.short_path
    prefix = root + "/"
    if not file.short_path.startswith(prefix):
        fail("omni_extension src %s is outside the extension root %s" % (file.short_path, root))
    return file.short_path[len(prefix):]

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

    if ctx.attr.strip_prefix or ctx.attr.manifest_path:
        def destination(file):
            return package_relative_path(ctx, file, ctx.attr.strip_prefix)
    else:
        root = _extension_root(manifest)

        def destination(file):
            return _root_relative_path(file, root)

    add_file(manifest, ctx.attr.manifest_path or destination(manifest), "manifest")

    for file in collect_default_files(ctx.attr.srcs):
        if file.path == manifest.path:
            continue
        add_file(file, destination(file))

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
        doc = "extension.toml manifest file. Unless strip_prefix or manifest_path is set, its parent config/ directory's parent becomes the extension root.",
    ),
    "manifest_path": attr.string(
        doc = "Destination path for the manifest inside the extension package. Setting it disables extension root inference.",
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
        doc = "Optional prefix stripped from src destination paths. Defaults to the directory containing the manifest's config/ directory.",
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
