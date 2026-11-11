#!/usr/bin/env python3
"""Generate/verify the offline numbered artwork review page's public data.

Consumes the app's exact validated selections; does not infer image mappings,
read source sheets, change artwork or download anything.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys

import prepare_exercise_artwork as artwork

APP = Path(__file__).resolve().parents[1]
ROOT = APP.parent
DATA_FORMAT = "alkion-artwork-library-v1"


def validate_cohort(cohort: dict, items: list) -> dict:
    """Bind the declared regeneration to current selections, never queue marks."""
    fields = {"id", "label", "source_illustration_min", "source_illustration_max", "expected_counts"}
    if not isinstance(cohort, dict) or set(cohort) != fields:
        raise ValueError("Invalid latest regeneration metadata fields")
    artwork.publishable(cohort)
    if any(not isinstance(cohort[field], str) or not cohort[field].strip() for field in ("id", "label")):
        raise ValueError("Latest regeneration requires an id and label")
    lower, upper = (cohort[field] for field in ("source_illustration_min", "source_illustration_max"))
    if type(lower) is not int or type(upper) is not int or not 0 < lower <= upper:
        raise ValueError("Invalid latest regeneration source illustration bounds")
    expected = cohort["expected_counts"]
    if not isinstance(expected, dict) or set(expected) != {"male", "female"}:
        raise ValueError("Latest regeneration requires both edition counts")
    for edition, count in expected.items():
        if type(count) is not int or count <= 0:
            raise ValueError("Invalid latest regeneration edition count")
        actual = sum(lower <= item["editions"][edition]["illustration"] <= upper for item in items)
        if actual != count:
            raise ValueError(f"Latest regeneration count mismatch: {edition}: expected {count}, selected {actual}")
    return cohort


def build_data(catalog: dict, registry: dict, manifests: dict, app: Path, cohort: dict) -> dict:
    """Fail closed unless both editions cover the exact current app identities."""
    artwork.publishable(catalog)
    numbers = artwork.validate_registry(registry)
    variants = catalog["variants"]
    keys = {variant["key"] for variant in variants}
    if len(keys) != len(variants) or not keys or not keys <= numbers.keys():
        raise ValueError("Catalog identities must be unique and reserved in the number registry")
    if set(manifests) != {"male", "female"}:
        raise ValueError("Both male and female manifests are required")
    editions = {}
    for edition, manifest in manifests.items():
        if manifest.get("edition", "male") != edition:
            raise ValueError(f"Manifest edition mismatch: {edition}")
        coverage = artwork.validate(manifest, app, catalog, registry)
        if not coverage["complete"]:
            raise ValueError(f"Incomplete exact catalog coverage: {edition}")
        entries = {entry["variant_key"]: entry for entry in manifest["entries"]
                   if entry["review_status"] == "reviewed"}
        if set(entries) != keys:
            raise ValueError(f"Edition selections differ from current catalog: {edition}")
        for key, entry in entries.items():
            if entry.get("library_number") != numbers[key]:
                raise ValueError(f"Manifest library number differs from registry: {edition}/{key}")
            if entry.get("quality_status") not in ("pass", "agreed_defect", "needs_manual_review", "secondary_cleared"):
                raise ValueError(f"Unknown/missing quality status: {edition}/{key}")
        editions[edition] = entries
    items = []
    for variant in sorted(variants, key=lambda value: numbers[value["key"]]):
        key = variant["key"]
        name = variant["names"].get("en")
        if not isinstance(name, str) or not name.strip():
            raise ValueError(f"Missing English catalog name: {key}")
        item = {"number": numbers[key], "key": key, "name": name,
                "revision": variant["revision"], "editions": {}}
        for edition, entries in editions.items():
            entry = entries[key]
            item["editions"][edition] = {
                "asset": "../../app/" + entry["asset"],
                "quality_status": entry["quality_status"],
                "illustration": entry["illustration"],
                "source_sheet_sha256": entry["source_sheet_sha256"],
                "source_cell": entry["source_cell"], "sha256": entry["sha256"],
            }
        items.append(item)
    return {"format": DATA_FORMAT, "catalog_revision": catalog.get("catalog_revision"),
            "latest_regeneration": validate_cohort(cohort, items), "items": items}


def javascript(data: dict) -> str:
    # Safe as a standalone classic script and if copied into an HTML script block.
    encoded = json.dumps(data, ensure_ascii=True, separators=(",", ":"))
    for char, escaped in (("<", "\\u003c"), (">", "\\u003e"), ("&", "\\u0026")):
        encoded = encoded.replace(char, escaped)
    return "// Generated by app/tool/prepare_artwork_library.py; do not edit.\nwindow.ALKION_ARTWORK_LIBRARY = " + encoded + ";\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--catalog", type=Path, default=APP / "assets/catalog_trial/catalog.dev.json")
    parser.add_argument("--male-manifest", type=Path, default=APP / "assets/exercise_artwork/manifest.json")
    parser.add_argument("--female-manifest", type=Path, default=APP / "assets/exercise_artwork/female-manifest.json")
    parser.add_argument("--registry", type=Path, default=APP / "assets/exercise_artwork/library-numbers.json")
    parser.add_argument("--latest-regeneration", type=Path,
                        default=ROOT / "tools/artwork-library/latest-regeneration.json")
    parser.add_argument("--write", action="store_true", help="Write data.js; default verifies")
    args = parser.parse_args()
    try:
        read = lambda path: json.loads(path.read_text(encoding="utf-8"))
        data = build_data(read(args.catalog), read(args.registry), {
            "male": read(args.male_manifest), "female": read(args.female_manifest)}, APP,
            read(args.latest_regeneration))
        destination = ROOT / "tools/artwork-library/data.js"
        expected = javascript(data)
        if args.write:
            destination.write_text(expected, encoding="utf-8")
        elif destination.read_text(encoding="utf-8") != expected:
            raise ValueError("Gallery data differs; run with --write")
        counts = {edition: {status: sum(item["editions"][edition]["quality_status"] == status
                                       for item in data["items"])
                            for status in ("pass", "agreed_defect", "needs_manual_review", "secondary_cleared")}
                  for edition in ("male", "female")}
        print(json.dumps({"format": DATA_FORMAT, "exercises": len(data["items"]),
                          "latest_regeneration": data["latest_regeneration"], "quality": counts}, sort_keys=True))
        return 0
    except (ValueError, KeyError, OSError, TypeError) as error:
        print(f"Artwork library verification failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
