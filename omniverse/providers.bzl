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
