import copy
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


if __name__ == "__main__":
    unittest.main()
