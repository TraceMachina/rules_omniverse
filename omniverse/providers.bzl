"""Public providers for rules_omniverse."""

OmniExtensionInfo = provider(
    doc = "Metadata and packaged outputs for an Omniverse extension.",
    fields = {
        "archive": "Zip archive containing the extension.",
        "deps": "Direct Omniverse extension dependencies.",
        "extension_id": "Extension id, normally name-version.",
        "manifest": "Source extension.toml file.",
        "metadata": "Generated JSON metadata file.",
        "name": "Omniverse extension name.",
        "root": "Tree artifact containing the packaged extension root.",
        "version": "Extension version from the manifest or rule attribute.",
    },
)

OmniKitAppInfo = provider(
    doc = "Metadata and generated outputs for a Kit application.",
    fields = {
        "app_file": "Generated .kit application config.",
        "extensions": "Omniverse extensions referenced by the app.",
        "launcher": "Executable launcher generated for bazel run.",
        "metadata": "Generated JSON metadata file.",
        "name": "Kit application name.",
        "version": "Kit application version.",
    },
)

OmniAssetBundleInfo = provider(
    doc = "Metadata and packaged outputs for an Omniverse asset bundle.",
    fields = {
        "archive": "Zip archive containing the assets.",
        "metadata": "Generated JSON metadata file.",
        "name": "Asset bundle name.",
        "root": "Tree artifact containing the packaged assets.",
    },
)

OmniRepoPublishInfo = provider(
    doc = "Generated Kit repo publish configuration.",
    fields = {
        "extensions": "Extension names included in the publish config.",
        "repo_toml": "Generated repo.toml file.",
    },
)

OmniKitToolchainInfo = provider(
    doc = "Kit executables exposed to Omniverse rules.",
    fields = {
        "kit": "Kit executable file.",
        "platform": "Optional Kit platform/config identifier.",
        "repo": "Kit repo executable file, if available.",
    },
)

OmniUsdInfo = provider(
    doc = "An OpenUSD stage and metadata produced by a rules_omniverse action.",
    fields = {
        "operation": "Operation that produced the stage or report.",
        "report": "Optional machine-readable report file.",
        "source": "Original input OpenUSD stage.",
        "stage": "Current OpenUSD stage after the operation.",
    },
)

OmniGpuActionInfo = provider(
    doc = "Outputs produced by an action selected for a GPU execution platform.",
    fields = {
        "container_image": "Image reference used by a container action, or an empty string for a host tool action.",
        "outputs": "Depset of files produced by the GPU action.",
        "tree_outputs": "Depset of declared directory artifacts produced by the GPU action.",
    },
)
