#!/usr/bin/env python3
"""Validate local owner artwork and generate immutable exact Dart registrations.

No source lookup, name inference, image modification or network access. Pillow is
used only by this preparation/check tool; the app has no new runtime dependency.
An explicit catalog can additionally reconcile identity and emit coverage.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import sys

from PIL import Image

APP = Path(__file__).resolve().parents[1]
FORMAT = "alkion-owner-exercise-artwork-v1"
KEY = re.compile(r"[a-z0-9_]+\Z")
SHA = re.compile(r"[0-9a-f]{64}\Z")


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def lossless_webp(path: Path) -> bool:
    data, offset, found = path.read_bytes(), 12, False
    while offset + 8 <= len(data):
        tag = data[offset:offset + 4]
        size = int.from_bytes(data[offset + 4:offset + 8], "little")
        if tag == b"VP8 ":
            return False
        found |= tag == b"VP8L"
        offset += 8 + size + (size & 1)
    return found


def publishable(value):
    if isinstance(value, dict):
        for key, child in value.items():
            publishable(key)
            publishable(child)
    elif isinstance(value, list):
        for child in value:
            publishable(child)
    elif isinstance(value, str):
        if (re.search(r"(?:/home/|/Users/|/tmp/|file://|[A-Za-z]:[\\/])", value)
                or ".." in value.split("/")):
            raise ValueError("Manifest contains a private or traversing path")


def validate(manifest: dict, app: Path, catalog: dict | None = None) -> dict:
    if (not isinstance(manifest, dict) or manifest.get("format") != FORMAT
            or not isinstance(manifest.get("entries"), list)):
        raise ValueError("Unsupported artwork manifest format/entries")
    publishable(manifest)
    variants = None if catalog is None else {v["key"]: v for v in catalog["variants"]}
    admitted, seen, assets = [], set(), set()
    total_bytes, max_width, max_height = 0, 0, 0
    for entry in manifest["entries"]:
        if not isinstance(entry, dict):
            raise ValueError("Expected artwork entry object")
        key = entry.get("variant_key", "")
        if not isinstance(key, str) or not KEY.fullmatch(key) or key in seen:
            raise ValueError(f"Invalid/duplicate variant key: {key}")
        seen.add(key)
        revision, equipment, facets = (entry.get("variant_revision"),
                                      entry.get("equipment_kind"), entry.get("facets"))
        if (type(revision) is not int or revision < 1 or not isinstance(equipment, str)
                or not KEY.fullmatch(equipment) or not isinstance(facets, dict)
                or any(not isinstance(k, str) or not KEY.fullmatch(k)
                       or not isinstance(v, str) or not KEY.fullmatch(v)
                       for k, v in facets.items())):
            raise ValueError(f"Invalid semantic identity: {key}")
        if variants is not None:
            variant = variants.get(key)
            if variant is None or any((variant.get(field) != expected) for field, expected in
                                     (("revision", revision), ("equipment_kind", equipment),
                                      ("facets", facets))):
                raise ValueError(f"Catalog identity mismatch: {key}")
        asset = entry.get("asset")
        if asset != f"assets/exercise_artwork/images/{key}.webp" or asset in assets:
            raise ValueError(f"Invalid/duplicate asset: {key}")
        assets.add(asset)
        for field in ("sha256", "source_sheet_sha256"):
            if not isinstance(entry.get(field), str) or not SHA.fullmatch(entry[field]):
                raise ValueError(f"Invalid {field}: {key}")
        if (type(entry.get("illustration")) is not int or entry["illustration"] < 1
                or type(entry.get("source_cell")) is not int or not 1 <= entry["source_cell"] <= 4
                or not isinstance(entry.get("extraction"), dict) or not entry["extraction"]):
            raise ValueError(f"Missing extraction provenance: {key}")
        extraction = entry["extraction"]
        if (not isinstance(extraction.get("method"), str) or not extraction["method"]
                or extraction.get("encoding") != "lossless-webp"
                or not isinstance(extraction.get("output_size"), list)
                or len(extraction["output_size"]) != 2
                or any(type(size) is not int or size < 1 for size in extraction["output_size"])):
            raise ValueError(f"Invalid extraction metadata: {key}")
        path = app / asset
        component = app
        linked = app.is_symlink()
        for part in Path(asset).parts:
            component /= part
            linked |= component.is_symlink()
        if not path.is_file() or linked or not path.resolve().is_relative_to(app.resolve()):
            raise ValueError(f"Missing/unsafe asset: {key}")
        if digest(path) != entry["sha256"]:
            raise ValueError(f"Asset hash mismatch: {key}")
        try:
            with Image.open(path) as image:
                image.load()
                if image.format != "WEBP" or image.width < 1 or image.height < 1:
                    raise ValueError("Not a WebP image")
                if not lossless_webp(path):
                    raise ValueError("Declared lossless encoding differs from image")
                if list(image.size) != extraction["output_size"]:
                    raise ValueError("Declared output size differs from image")
                if image.mode in ("RGBA", "LA") and image.getchannel("A").getextrema() != (255, 255):
                    raise ValueError("Owner artwork must have an opaque background")
                if getattr(image, "n_frames", 1) != 1:
                    raise ValueError("Owner recognition artwork must be a single still")
                max_width, max_height = max(max_width, image.width), max(max_height, image.height)
        except Exception as error:
            raise ValueError(f"Invalid image: {key}: {error}") from error
        total_bytes += path.stat().st_size
        if entry.get("review_status") == "reviewed":
            admitted.append(key)
        elif entry.get("review_status") not in ("pending", "excluded"):
            raise ValueError(f"Unknown review status: {key}")
    actual = {p.relative_to(app).as_posix() for p in (app / "assets/exercise_artwork/images").glob("*") if p.is_file()}
    if actual != assets:
        raise ValueError("Declared image files differ from bundled image directory")
    return {"format": "alkion-owner-exercise-artwork-coverage-v1",
            "catalog_variants": None if variants is None else len(variants),
            "reviewed": len(admitted), "bundled_files": len(assets),
            "image_bytes": total_bytes, "max_width": max_width, "max_height": max_height,
            "unresolved_variant_keys": [] if variants is None else sorted(set(variants) - set(admitted)),
            "complete": variants is not None and set(variants) == set(admitted)}


def quote(value: str) -> str:
    return "'" + value.replace("\\", "\\\\").replace("'", "\\'").replace("$", "\\$") + "'"


def registrations(manifest: dict) -> str:
    lines = ["// Generated by tool/prepare_exercise_artwork.py. Reviewed entries only.",
             "part of 'catalog_artwork.dart';", "", "const _artwork = <String, _ArtworkRegistration>{"]
    for entry in sorted(manifest["entries"], key=lambda e: e["variant_key"]):
        if entry["review_status"] != "reviewed":
            continue
        lines += [f"  {quote(entry['variant_key'])}: _ArtworkRegistration(",
                  f"    revision: {entry['variant_revision']},",
                  f"    equipmentKind: {quote(entry['equipment_kind'])},", "    facets: {"]
        lines += [f"      {quote(k)}: {quote(v)}," for k, v in sorted(entry["facets"].items())]
        lines += ["    },", "    artwork: CatalogExerciseArtwork(",
                  f"      asset: {quote(entry['asset'])},", f"      sha256: {quote(entry['sha256'])},",
                  "    ),", "  ),"]
    return "\n".join(lines + ["};", ""])


def normalized_registrations(value: str) -> str:
    # dart format compacts short facet maps and drops their trailing comma.
    # Generated strings contain only validated tokens, paths and hex digests.
    return re.sub(r",(?=[}\]])", "", re.sub(r"\s+", "", value))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, default=APP / "assets/exercise_artwork/manifest.json")
    parser.add_argument("--catalog", type=Path)
    parser.add_argument("--receipt", type=Path)
    parser.add_argument("--write", action="store_true", help="Write generated Dart; default verifies")
    args = parser.parse_args()
    try:
        manifest = json.loads(args.manifest.read_text())
        catalog = None if args.catalog is None else json.loads(args.catalog.read_text())
        receipt = validate(manifest, APP, catalog)
        receipt["manifest_sha256"] = digest(args.manifest)
        if args.catalog:
            receipt["catalog_sha256"] = digest(args.catalog)
        destination = APP / "lib/catalog/catalog_artwork_data.dart"
        expected = registrations(manifest)
        if args.write:
            destination.write_text(expected)
        elif normalized_registrations(destination.read_text()) != normalized_registrations(expected):
            raise ValueError("Generated registrations differ; run with --write")
        if args.receipt:
            args.receipt.write_text(json.dumps(receipt, indent=2) + "\n")
        print(json.dumps(receipt, sort_keys=True))
        return 0
    except (ValueError, KeyError, OSError) as error:
        print(f"Artwork verification failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
