#!/usr/bin/env python3
"""Verify the retained Workout Guide source, or reproduce it from the pinned checkout.

Since 2026-11-08 the frames are kept in source only: nothing in the app shows
them, so the app bundle must not declare them. Default verification needs only
Python's standard library. Preparation additionally needs Pillow/libwebp, whose
versions and lossless encoder options are recorded. No download, catalog
lookup, name matching or repository mutation is performed.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET

APP = Path(__file__).resolve().parents[1]
BUNDLE = APP / "assets/workout_guide"
MANIFEST = BUNDLE / "manifest.json"
PUBSPEC = APP / "pubspec.yaml"
PIN = "aac599224bb9780305239607ef98540b7e0ce389"
NOTICES = {
    "LICENSE-ASSETS": "LICENSE-ASSETS.txt",
    "LICENSE": "LICENSE-CODE.txt",
    "LICENSES.md": "LICENSES.md",
    "ATTRIBUTION.md": "ATTRIBUTION.md",
}


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def local_path(relative: str) -> Path:
    path = (BUNDLE / relative).resolve()
    if not path.is_relative_to(BUNDLE.resolve()):
        raise ValueError(f"Out-of-bundle path: {relative}")
    return path


def check_manifest(manifest: dict) -> None:
    if manifest.get("format") != "alkion-workout-guide-media-v1":
        raise ValueError("Unknown manifest format")
    if manifest["upstream"]["commit"] != PIN:
        raise ValueError("Unexpected upstream pin")
    keys, slugs = set(), set()
    for entry in manifest["entries"]:
        key, slug = entry["variant_key"], entry["slug"]
        if key in keys or slug in slugs:
            raise ValueError(f"Duplicate reviewed mapping: {key}/{slug}")
        keys.add(key)
        slugs.add(slug)
        if not entry["frames"] or len(entry["frames"]) > 3:
            raise ValueError(f"Invalid reviewed frame count: {key}")
        indexes = [frame["index"] for frame in entry["frames"]]
        if indexes != sorted(set(indexes)) or not set(indexes) <= {1, 2, 3}:
            raise ValueError(f"Invalid source frame indexes: {key}")
        for frame in entry["frames"]:
            index = frame["index"]
            expected = {
                "master_path": f"masters/{slug}/frame-{index}.svg",
                "asset_path": f"frames/{slug}/frame-{index}.webp",
                "upstream_svg_path": f"assets/{slug}/frame-{index}.svg",
                "upstream_png_path": f"assets/{slug}/frame-{index}.png",
            }
            if any(frame[k] != value for k, value in expected.items()):
                raise ValueError(f"Unexpected frame paths: {key}")
            if (frame["width"], frame["height"]) != (512, 512):
                raise ValueError(f"Unexpected source dimensions: {key}")
            if frame["attribution"]["license"] != "CC BY-SA 4.0":
                raise ValueError(f"Unexpected visual license: {key}")


def prepare(manifest: dict, source: Path) -> None:
    from PIL import Image, __version__ as pillow_version, features

    source = source.resolve()
    commit = subprocess.check_output(
        ["git", "-C", str(source), "rev-parse", "HEAD"], text=True
    ).strip()
    if commit != PIN:
        raise ValueError(f"Expected public source at {PIN}, got {commit}")
    package = source / "packages/workout-guide"
    if digest(package / "manifest.json") != manifest["upstream"]["manifest_sha256"]:
        raise ValueError("Pinned upstream manifest differs")
    upstream = {e["slug"]: e for e in json.loads((package / "manifest.json").read_text())}
    conversion = manifest["conversion"]
    actual_versions = {"pillow_version": pillow_version, "libwebp_version": features.version("webp")}
    for field, value in actual_versions.items():
        if conversion.get(field, value) != value:
            raise ValueError(f"Reproduction needs {field}={conversion[field]}, got {value}")
        conversion[field] = value
    for entry in manifest["entries"]:
        original = upstream[entry["slug"]]
        if entry["upstream_attribution"] != original["attribution"]:
            raise ValueError(f"Changed exercise attribution: {entry['slug']}")
        for frame in entry["frames"]:
            original_frame = next(f for f in original["frames"] if f["index"] == frame["index"])
            if frame["attribution"] != original_frame["attribution"]:
                raise ValueError(f"Changed frame attribution: {entry['slug']}")
            svg, png = package / frame["upstream_svg_path"], package / frame["upstream_png_path"]
            if digest(svg) != frame["svg_sha256"] or digest(png) != frame["png_sha256"]:
                raise ValueError(f"Changed pinned source frame: {png}")
            master, asset = local_path(frame["master_path"]), local_path(frame["asset_path"])
            master.parent.mkdir(parents=True, exist_ok=True)
            asset.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(svg, master)
            with Image.open(png) as image:
                rgba = image.convert("RGBA")
                if rgba.size != (512, 512) or rgba.getextrema()[3][0] != 0:
                    raise ValueError(f"Expected transparent 512px source: {png}")
                rgba.save(asset, format="WEBP", lossless=True, exact=True, method=6)
                with Image.open(asset) as converted:
                    if converted.convert("RGBA").tobytes() != rgba.tobytes():
                        raise ValueError(f"Lossless pixel roundtrip failed: {asset}")
            frame["asset_sha256"] = digest(asset)
            frame["asset_bytes"] = asset.stat().st_size
            frame["svg_bytes"] = master.stat().st_size
    manifest["notices"] = []
    for original, target in NOTICES.items():
        shutil.copyfile(source / original, BUNDLE / target)
        manifest["notices"].append({"path": target, "upstream_path": original, "sha256": digest(BUNDLE / target)})
    MANIFEST.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")


def verify(manifest: dict) -> None:
    paths = set()
    total_bytes = 0
    for entry in manifest["entries"]:
        for frame in entry["frames"]:
            master, asset = local_path(frame["master_path"]), local_path(frame["asset_path"])
            for path, expected_hash, expected_bytes in [
                (master, frame["svg_sha256"], frame["svg_bytes"]),
                (asset, frame["asset_sha256"], frame["asset_bytes"]),
            ]:
                if digest(path) != expected_hash or path.stat().st_size != expected_bytes:
                    raise ValueError(f"Asset integrity mismatch: {path}")
                paths.add(path)
                total_bytes += path.stat().st_size
            svg = ET.parse(master).getroot()
            if svg.attrib.get("viewBox") != "0 0 512 512":
                raise ValueError(f"Unexpected SVG canvas: {master}")
            if [n.tag.rsplit("}", 1)[-1] for n in svg.iter()] != ["svg", "path"]:
                raise ValueError(f"Unexpected SVG complexity: {master}")
            data = asset.read_bytes()
            if data[:4] != b"RIFF" or data[8:12] != b"WEBP" or data[12:16] != b"VP8L":
                raise ValueError(f"Expected lossless WebP frame: {asset}")
    if "assets/workout_guide" in PUBSPEC.read_text():
        raise ValueError("Workout Guide media is source-only; the app must not bundle it")
    actual = {p.resolve() for folder in (BUNDLE / "frames", BUNDLE / "masters") for p in folder.rglob("*") if p.is_file()}
    if actual != paths:
        raise ValueError("Missing or unmanifested media assets")
    for notice in manifest["notices"]:
        if digest(local_path(notice["path"])) != notice["sha256"]:
            raise ValueError(f"Notice integrity mismatch: {notice['path']}")
    print(f"PASS: {len(manifest['entries'])} exact mappings, {sum(len(e['frames']) for e in manifest['entries'])} frames, {total_bytes:,} source bytes; hashes and notices agree, not bundled")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, help="Reproduce from an existing pinned Workout Guide checkout")
    args = parser.parse_args()
    try:
        manifest = json.loads(MANIFEST.read_text())
        check_manifest(manifest)
        if args.source:
            prepare(manifest, args.source)
        verify(manifest)
    except (OSError, ValueError, KeyError, StopIteration, subprocess.CalledProcessError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
