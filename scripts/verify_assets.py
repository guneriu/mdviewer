#!/usr/bin/env python3
"""Verify vendored build inputs without Node, npm, or network access."""
import argparse
import hashlib
import json
from pathlib import Path


def require(condition, message):
    if not condition:
        raise SystemExit(message)


def verify(root):
    expected = {"Resources/Web/renderer.js", "Resources/Web/styles.css", "Resources/Web/shell.html", "Resources/Notices/THIRD_PARTY_NOTICES.md"}
    manifest = json.loads((root / "vendor-manifest.json").read_text())
    require({asset["path"] for asset in manifest["assets"]} == expected, "Unexpected asset inventory")
    require(len(manifest["assets"]) == len(expected), "Duplicate asset inventory")
    for asset in manifest["assets"]:
        data = (root / asset["path"]).read_bytes()
        require(len(data) == asset["bytes"], f'Size mismatch: {asset["path"]}')
        require(hashlib.sha256(data).hexdigest() == asset["sha256"], f'Checksum mismatch: {asset["path"]}')
    actual = {str(path.relative_to(root)) for folder in ("Web", "Notices") for path in (root / "Resources" / folder).rglob("*") if path.is_file()}
    require(actual == expected, "Unlisted resource files")
    require((root / "THIRD_PARTY_NOTICES.md").read_bytes() == (root / "Resources/Notices/THIRD_PARTY_NOTICES.md").read_bytes(), "Notice mismatch")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", nargs="?", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--bundle", type=Path)
    args = parser.parse_args()
    verify(args.root)
    if args.bundle:
        resources = args.bundle / "Contents/Resources"
        manifest_bytes = (args.root / "vendor-manifest.json").read_bytes()
        require((resources / "vendor-manifest.json").read_bytes() == manifest_bytes, "Packaged manifest mismatch")
        manifest = json.loads(manifest_bytes)
        for asset in manifest["assets"]:
            relative = Path(asset["path"]).relative_to("Resources")
            require((resources / relative).read_bytes() == (args.root / asset["path"]).read_bytes(), f"Packaged asset mismatch: {relative}")
        expected = {str(Path(asset["path"]).relative_to("Resources")) for asset in manifest["assets"]} | {"vendor-manifest.json"}
        require({str(path.relative_to(resources)) for path in resources.rglob("*") if path.is_file()} == expected, "Unlisted packaged resources")
    print("PASS node-free vendored/packaged asset SHA-256/size/allowlist/notices verification")
