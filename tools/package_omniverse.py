#!/usr/bin/env python3
"""Packaging and validation tool for rules_omniverse."""

import argparse
import json
import os
import re
import shutil
import sys
import zipfile
from pathlib import Path

try:
    import tomllib
except ModuleNotFoundError:  # pragma: no cover - old Python fallback
    tomllib = None

SEMVER_RE = re.compile(
    r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)"
    r"(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?"
    r"(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$"
)


def _load_toml(path):
    if tomllib is not None:
        with open(path, "rb") as f:
            return tomllib.load(f)
    return _load_minimal_toml(path)


def _load_minimal_toml(path):
    result = {}
    current = result
    with open(path, encoding="utf-8") as f:
        for raw in f:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith("[") and line.endswith("]"):
                current = result
                for part in line.strip("[]").split("."):
                    current = current.setdefault(part.strip('"'), {})
                continue
            if "=" not in line:
                continue
            key, value = [part.strip() for part in line.split("=", 1)]
            key = key.strip('"')
            if value.startswith('"') and value.endswith('"'):
                value = value[1:-1]
            current[key] = value
    return result


def _safe_dest(dest):
    dest = dest.replace("\\", "/")
    if dest.startswith("/") or dest == ".." or dest.startswith("../") or "/../" in dest:
        raise ValueError(f"unsafe package destination: {dest}")
    if not dest or dest == ".":
        raise ValueError("empty package destination")
    return dest


def _copy_file(src, root, dest):
    dest_path = root / _safe_dest(dest)
    dest_path.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dest_path)


def _copy_dir(src, root, dest):
    src_path = Path(src)
    dest_path = root / _safe_dest(dest)
    if dest_path.exists():
        shutil.rmtree(dest_path)
    dest_path.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(src_path, dest_path, symlinks=True)


def _zip_tree(root, archive):
    archive_path = Path(archive)
    archive_path.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(archive_path, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        for path in sorted(root.rglob("*")):
            if path.is_file():
                zf.write(path, path.relative_to(root).as_posix())


def _validate_extension(spec, metadata):
    manifest = spec.get("manifest")
    if not manifest:
        raise ValueError("omni_extension requires a manifest")
    parsed = _load_toml(manifest)
    package = parsed.get("package", {})
    version = package.get("version")
    expected_version = metadata.get("version")
    if expected_version and version != expected_version:
        raise ValueError(
            f"manifest version {version!r} does not match expected {expected_version!r}"
        )
    if not expected_version and version:
        metadata["version"] = version
        metadata["extension_id"] = f"{metadata['extension_name']}-{version}"
    if metadata.get("strict"):
        if not version:
            raise ValueError("extension manifest is missing [package].version")
        if not SEMVER_RE.match(str(version)):
            raise ValueError(f"extension version is not semver-compatible: {version}")
        if not package.get("title"):
            raise ValueError("extension manifest is missing [package].title")
    metadata["package"] = package
    metadata["manifest_dependencies"] = sorted(parsed.get("dependencies", {}).keys())


def _validate_assets(spec, metadata):
    if not metadata.get("strict"):
        return
    allowed = tuple(metadata.get("allowed_suffixes") or [])
    bad = []
    for item in spec.get("files", []):
        dest = item["dest"].lower()
        if allowed and not dest.endswith(allowed):
            bad.append(item["dest"])
    if bad:
        raise ValueError(
            "asset bundle contains files with unsupported suffixes: " + ", ".join(bad)
        )


def _write_metadata(path, spec, metadata):
    payload = dict(metadata)
    payload["files"] = [
        {
            "dest": item["dest"],
            "role": item.get("role", "content"),
        }
        for item in spec.get("files", [])
    ]
    payload["dirs"] = [
        {
            "dest": item["dest"],
            "role": item.get("role", "content"),
        }
        for item in spec.get("dirs", [])
    ]
    payload["kind"] = spec["kind"]
    payload["name"] = spec["name"]
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(payload, f, indent=2, sort_keys=True)
        f.write("\n")


def main(argv):
    parser = argparse.ArgumentParser()
    parser.add_argument("--spec", required=True)
    parser.add_argument("--root-out", required=True)
    parser.add_argument("--archive-out", required=True)
    parser.add_argument("--metadata-out", required=True)
    args = parser.parse_args(argv)

    with open(args.spec, encoding="utf-8") as f:
        spec = json.load(f)

    root = Path(args.root_out)
    if root.exists():
        shutil.rmtree(root)
    root.mkdir(parents=True)

    metadata = dict(spec.get("metadata") or {})
    if spec["kind"] == "extension":
        _validate_extension(spec, metadata)
    elif spec["kind"] == "asset_bundle":
        _validate_assets(spec, metadata)

    seen = set()
    for item in spec.get("files", []):
        dest = _safe_dest(item["dest"])
        if dest in seen:
            raise ValueError(f"duplicate package destination: {dest}")
        seen.add(dest)
        _copy_file(item["src"], root, dest)
    for item in spec.get("dirs", []):
        dest = _safe_dest(item["dest"])
        if dest in seen:
            raise ValueError(f"duplicate package destination: {dest}")
        seen.add(dest)
        _copy_dir(item["src"], root, dest)

    _zip_tree(root, args.archive_out)
    _write_metadata(args.metadata_out, spec, metadata)


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except Exception as exc:  # noqa: BLE001 - command-line tool should print concise errors.
        print(f"package_omniverse.py: error: {exc}", file=sys.stderr)
        sys.exit(1)

