import copy
import contextlib
import io
import json
from unittest.mock import patch
from pathlib import Path
import tempfile
import unittest

from PIL import Image

import prepare_exercise_artwork as tool


class ArtworkPreparationTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.app = Path(self.temp.name)
        self.asset = self.app / "assets/exercise_artwork/images/synthetic_press.webp"
        self.asset.parent.mkdir(parents=True)
        Image.new("RGB", (32, 48), "black").save(self.asset, lossless=True)
        self.entry = {"variant_key": "synthetic_press", "variant_revision": 2,
                      "equipment_kind": "barbell", "facets": {"angle": "flat"},
                      "asset": "assets/exercise_artwork/images/synthetic_press.webp",
                      "sha256": tool.digest(self.asset), "illustration": 1,
                      "source_sheet_sha256": "a" * 64, "source_cell": 1,
                      "extraction": {"method": "synthetic_fixture", "output_size": [32, 48],
                                     "encoding": "lossless-webp"}, "review_status": "reviewed"}
        self.manifest = {"format": tool.FORMAT, "entries": [self.entry]}
        self.catalog = {"variants": [{"key": "synthetic_press", "revision": 2,
                                      "equipment_kind": "barbell", "facets": {"angle": "flat"}}]}

    def test_real_hash_decode_coverage_and_review_admission(self):
        receipt = tool.validate(self.manifest, self.app, self.catalog)
        self.assertTrue(receipt["complete"])
        self.assertEqual(receipt["image_bytes"], self.asset.stat().st_size)
        self.assertEqual((receipt["max_width"], receipt["max_height"]), (32, 48))
        self.assertIn("revision: 2", tool.registrations(self.manifest))
        self.entry["review_status"] = "pending"
        self.assertNotIn("synthetic_press", tool.registrations(self.manifest))
        receipt = tool.validate(self.manifest, self.app, self.catalog)
        self.assertFalse(receipt["complete"])
        self.assertEqual(receipt["unresolved_variant_keys"], ["synthetic_press"])

    def test_identity_changes_fail_closed(self):
        for field, value in (("variant_revision", 3), ("equipment_kind", "dumbbell"),
                             ("facets", {}), ("facets", {"angle": "incline"}),
                             ("facets", {"angle": "flat", "grip": "neutral"})):
            with self.subTest(field=field, value=value):
                changed = copy.deepcopy(self.manifest)
                changed["entries"][0][field] = value
                with self.assertRaisesRegex(ValueError, "identity mismatch"):
                    tool.validate(changed, self.app, self.catalog)

    def test_hash_missing_corrupt_and_undeclared_assets_rejected(self):
        self.asset.write_bytes(b"not an image")
        with self.assertRaisesRegex(ValueError, "hash mismatch"):
            tool.validate(self.manifest, self.app)
        self.entry["sha256"] = tool.digest(self.asset)
        with self.assertRaisesRegex(ValueError, "Invalid image"):
            tool.validate(self.manifest, self.app)
        self.asset.unlink()
        with self.assertRaisesRegex(ValueError, "Missing/unsafe"):
            tool.validate(self.manifest, self.app)
        Image.new("RGB", (8, 8)).save(self.asset, lossless=True)
        self.entry["sha256"] = tool.digest(self.asset)
        self.entry["extraction"]["output_size"] = [8, 8]
        self.asset.with_name("undeclared.webp").write_bytes(self.asset.read_bytes())
        with self.assertRaisesRegex(ValueError, "Declared image files differ"):
            tool.validate(self.manifest, self.app)

    def test_duplicate_private_path_and_transparency_rejected(self):
        self.manifest["entries"].append(copy.deepcopy(self.entry))
        with self.assertRaisesRegex(ValueError, "duplicate variant"):
            tool.validate(self.manifest, self.app)
        self.manifest["entries"].pop()
        self.entry["extraction"]["source"] = "file://synthetic.invalid/private.png"
        with self.assertRaisesRegex(ValueError, "private"):
            tool.validate(self.manifest, self.app)
        self.entry["extraction"].pop("source")
        Image.new("RGBA", (8, 8), (0, 0, 0, 0)).save(self.asset, lossless=True)
        self.entry["sha256"] = tool.digest(self.asset)
        self.entry["extraction"]["output_size"] = [8, 8]
        with self.assertRaisesRegex(ValueError, "opaque"):
            tool.validate(self.manifest, self.app)

    def test_declared_dimensions_and_encoding_match_actual_image(self):
        self.entry["extraction"]["output_size"] = [48, 32]
        with self.assertRaisesRegex(ValueError, "output size"):
            tool.validate(self.manifest, self.app)
        self.entry["extraction"]["output_size"] = [32, 48]
        Image.new("RGB", (32, 48), "black").save(self.asset, lossless=False)
        self.entry["sha256"] = tool.digest(self.asset)
        with self.assertRaisesRegex(ValueError, "lossless"):
            tool.validate(self.manifest, self.app)

    def test_formatted_registrations_compare_without_losing_semantic_changes(self):
        generated = tool.registrations(self.manifest)
        compact = generated.replace("facets: {\n      'angle': 'flat',\n    }", "facets: {'angle': 'flat'}")
        self.assertEqual(tool.normalized_registrations(generated), tool.normalized_registrations(compact))
        self.assertNotEqual(tool.normalized_registrations(generated),
                            tool.normalized_registrations(compact.replace("revision: 2", "revision: 3")))

    def test_explicit_female_edition_and_quality_flags(self):
        target = self.app / "assets/exercise_artwork/female/synthetic_press.webp"
        target.parent.mkdir()
        target.write_bytes(self.asset.read_bytes())
        self.entry["asset"] = "assets/exercise_artwork/female/synthetic_press.webp"
        with self.assertRaisesRegex(ValueError, "Invalid/duplicate asset"):
            tool.validate(self.manifest, self.app)
        self.manifest["edition"] = "female"
        self.entry["quality_status"] = "agreed_defect"
        receipt = tool.validate(self.manifest, self.app, self.catalog)
        self.assertEqual(receipt["edition"], "female")
        self.assertEqual(receipt["quality_status_counts"], {"agreed_defect": 1})
        self.entry["quality_status"] = "invented_approval"
        with self.assertRaisesRegex(ValueError, "Unknown quality"):
            tool.validate(self.manifest, self.app)

    def test_manifest_numbers_match_registry_for_both_editions(self):
        registry = {"format": tool.REGISTRY_FORMAT, "next_number": 43,
                    "entries": [{"variant_key": "synthetic_press", "number": 42}]}
        self.entry["library_number"] = 42
        tool.validate(self.manifest, self.app, self.catalog, registry)
        self.entry["library_number"] = 1
        with self.assertRaisesRegex(ValueError, "library number"):
            tool.validate(self.manifest, self.app, self.catalog, registry)

    def _dual_manifests(self):
        self.entry["library_number"] = 42
        female = copy.deepcopy(self.manifest)
        female["edition"] = "female"
        female["entries"][0]["asset"] = "assets/exercise_artwork/female/synthetic_press.webp"
        target = self.app / female["entries"][0]["asset"]
        target.parent.mkdir()
        target.write_bytes(self.asset.read_bytes())
        root = self.app / "assets/exercise_artwork"
        (root / "manifest.json").write_text(json.dumps(self.manifest))
        (root / "female-manifest.json").write_text(json.dumps(female))
        (root / "library-numbers.json").write_text(json.dumps({
            "format": tool.REGISTRY_FORMAT, "next_number": 43,
            "entries": [{"variant_key": "synthetic_press", "number": 42}]}))
        generated = self.app / "lib/catalog"
        generated.mkdir(parents=True)
        return female, generated

    def test_default_cli_validates_and_generates_both_edition_tables(self):
        female, generated = self._dual_manifests()
        with patch.object(tool, "APP", self.app), patch("sys.argv", ["prepare", "--write"]):
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                self.assertEqual(tool.main(), 0)
        receipt = json.loads(output.getvalue())
        self.assertEqual([r["edition"] for r in receipt["editions"]], ["male", "female"])
        self.assertEqual((generated / "catalog_artwork_data.dart").read_text(),
                         tool.registrations(self.manifest))
        female_dart = (generated / "catalog_artwork_female_data.dart").read_text()
        self.assertEqual(female_dart, tool.registrations(female))
        self.assertIn("const _femaleArtwork", female_dart)
        self.assertIn("assets/exercise_artwork/female/synthetic_press.webp", female_dart)
        with patch.object(tool, "APP", self.app), patch("sys.argv", ["prepare"]):
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(tool.main(), 0)

    def test_bad_female_asset_prevents_either_generated_table_write(self):
        female, generated = self._dual_manifests()
        male_dart = generated / "catalog_artwork_data.dart"
        male_dart.write_text("unchanged")
        (self.app / female["entries"][0]["asset"]).write_bytes(b"corrupt")
        with patch.object(tool, "APP", self.app), patch("sys.argv", ["prepare", "--write"]):
            with contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(tool.main(), 1)
        self.assertEqual(male_dart.read_text(), "unchanged")
        self.assertFalse((generated / "catalog_artwork_female_data.dart").exists())

    def test_unreviewed_female_has_no_male_fallback_registration(self):
        female, _ = self._dual_manifests()
        female["entries"][0]["review_status"] = "pending"
        self.assertIn("synthetic_press", tool.registrations(self.manifest))
        self.assertNotIn("synthetic_press", tool.registrations(female))
        self.assertEqual(tool.registrations(female), tool.registrations(copy.deepcopy(female)))


class PublishablePathsTest(unittest.TestCase):
    def test_http_sources_and_embedded_links_are_publishable(self):
        tool.publishable({"sources": [
            {"url": "https://example.invalid/exercise?variant=synthetic"},
            {"url": "http://example.invalid/guide#exercise"},
            {"evidence": "Source: https://example.invalid/guide (reviewed)."},
        ]})

    def test_windows_absolute_drives_are_rejected_at_token_boundaries(self):
        for drive in ("C:/private/source.png", r"D:\private\source.png"):
            for prefix in ("", "source=", "Source: ", "(", '\"', "["):
                with self.subTest(path=prefix + drive):
                    with self.assertRaisesRegex(ValueError, "private or traversing"):
                        tool.publishable({"source": prefix + drive})

    def test_existing_private_and_traversing_paths_stay_rejected(self):
        # "/" + "home/..." keeps the public-push leak scan off this synthetic path.
        for value in ("/" + "home/synthetic/source.png", "/Users/synthetic/source.png",
                      "/tmp/source.png", "file://synthetic.invalid/private.png",
                      "../source.png", "assets/../source.png"):
            with self.subTest(value=value):
                with self.assertRaisesRegex(ValueError, "private or traversing"):
                    tool.publishable({"nested": [{"source": value}]})


class LibraryNumberRegistryTest(unittest.TestCase):
    def setUp(self):
        self.registry = {"format": tool.REGISTRY_FORMAT, "next_number": 793,
                         "entries": [{"variant_key": "first", "number": 1},
                                     {"variant_key": "retired", "number": 792}]}

    def test_reorder_removal_revision_and_reintroduction_keep_reservations(self):
        removed = tool.reconcile_registry(self.registry, ["first"])
        self.assertEqual(removed, self.registry)
        reintroduced = tool.reconcile_registry(removed, ["retired", "first"])
        self.assertEqual(reintroduced, self.registry)
        # Only variant identity participates: revisions, names and source IDs do not.
        self.assertEqual(tool.validate_registry(reintroduced), {"first": 1, "retired": 792})

    def test_new_keys_append_after_reserved_gaps_independent_of_catalog_order(self):
        updated = tool.reconcile_registry(self.registry, ["new_z", "first", "new_a"])
        self.assertEqual(tool.validate_registry(updated, self.registry),
                         {"first": 1, "retired": 792, "new_a": 793, "new_z": 794})
        self.assertEqual(updated["next_number"], 795)
        self.assertEqual(updated, tool.reconcile_registry(self.registry, ["new_a", "new_z", "first"]))

    def test_previous_registry_rejects_removal_reassignment_compaction_and_gap_reuse(self):
        for mutation in ("remove", "swap", "compact", "reuse_gap"):
            changed = copy.deepcopy(self.registry)
            if mutation == "remove":
                changed["entries"].pop()
            elif mutation == "swap":
                changed["entries"][0]["number"], changed["entries"][1]["number"] = 792, 1
            elif mutation == "compact":
                changed["next_number"] = 792
            else:
                changed["entries"].append({"variant_key": "new", "number": 2})
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                tool.validate_registry(changed, self.registry)

    def test_duplicate_keys_numbers_and_bool_numbers_are_rejected(self):
        for entry in ({"variant_key": "first", "number": 2},
                      {"variant_key": "new", "number": 1},
                      {"variant_key": "new", "number": True}):
            changed = copy.deepcopy(self.registry)
            changed["entries"].append(entry)
            with self.assertRaises(ValueError):
                tool.validate_registry(changed)


if __name__ == "__main__":
    unittest.main()
