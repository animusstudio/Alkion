"""Data-boundary tests for the offline review library, using synthetic catalogs."""
import copy
import json
import unittest
from pathlib import Path
from unittest.mock import patch

import prepare_artwork_library as library


class ArtworkLibraryTest(unittest.TestCase):
    def setUp(self):
        self.catalog = {"catalog_revision": 1, "variants": [
            {"key": "exercise_b", "revision": 1, "names": {"en": "Exercise B"}},
            {"key": "exercise_a", "revision": 2, "names": {"en": "Exercise A"}}]}
        self.registry = {"format": "alkion-exercise-library-numbers-v1", "next_number": 10,
                         "entries": [{"variant_key": "exercise_b", "number": 9},
                                     {"variant_key": "exercise_a", "number": 2},
                                     {"variant_key": "retired", "number": 6}]}
        self.manifests = {}
        for edition in ("male", "female"):
            self.manifests[edition] = {"edition": edition, "entries": [
                {"variant_key": key, "library_number": number, "review_status": "reviewed",
                 "quality_status": "agreed_defect" if edition == "female" else "pass",
                 "asset": f"assets/exercise_artwork/{edition}/{key}.webp",
                 "illustration": source, "source_sheet_sha256": "a" * 64,
                 "source_cell": 2, "sha256": "b" * 64}
                for key, number, source in (("exercise_b", 9, 800), ("exercise_a", 2, 41))]}
        # Image/identity checks belong to the shared validator. These tests exercise
        # the gallery's stricter full-coverage and stable-number boundary around it.
        self.validation = patch.object(library.artwork, "validate", return_value={"complete": True})
        self.validator = self.validation.start()
        self.addCleanup(self.validation.stop)

    def build(self):
        return library.build_data(self.catalog, self.registry, self.manifests, Path("synthetic"))

    def test_numbers_survive_catalog_order_rename_and_source_replacement(self):
        before = self.build()
        self.catalog["variants"].reverse()
        self.catalog["variants"][0]["names"]["en"] = "Renamed exercise"
        self.manifests["female"]["entries"][1]["illustration"] = 1201
        after = self.build()
        self.assertEqual([(x["key"], x["number"]) for x in before["items"]],
                         [(x["key"], x["number"]) for x in after["items"]])
        self.assertEqual(after["items"][0]["editions"]["female"]["illustration"], 1201)
        self.assertEqual(after["items"][0]["editions"]["female"]["quality_status"], "agreed_defect")
        self.assertEqual(self.validator.call_count, 4)

    def test_missing_edition_and_identity_do_not_substitute_male(self):
        original = copy.deepcopy(self.manifests)
        del self.manifests["female"]
        with self.assertRaisesRegex(ValueError, "Both male and female"):
            self.build()
        self.manifests = original
        self.manifests["female"]["entries"].pop()
        with self.assertRaisesRegex(ValueError, "selections differ"):
            self.build()

    def test_shared_validation_incomplete_coverage_is_fatal(self):
        self.validator.return_value = {"complete": False}
        with self.assertRaisesRegex(ValueError, "Incomplete exact"):
            self.build()

    def test_disagreement_with_number_registry_is_fatal(self):
        self.manifests["female"]["entries"][0]["library_number"] = 2
        with self.assertRaisesRegex(ValueError, "differs from registry"):
            self.build()

    def test_invalid_quality_flag_is_not_silently_removed(self):
        self.manifests["female"]["entries"][0]["quality_status"] = "unknown"
        with self.assertRaisesRegex(ValueError, "quality status"):
            self.build()

    def test_injected_catalog_text_stays_data(self):
        self.catalog["variants"][0]["names"]["en"] = '</script><script>alert("name")</script> &\u2028'
        output = library.javascript(self.build())
        self.assertNotIn("</script>", output)
        self.assertNotIn("<script>", output)
        self.assertNotIn("\u2028", output)
        encoded = output.split(" = ", 1)[1].rstrip(";\n")
        self.assertEqual(json.loads(encoded)["items"][1]["name"], self.catalog["variants"][0]["names"]["en"])

    def test_private_catalog_path_fails_before_generation(self):
        self.catalog["variants"][0]["names"]["en"] = "/home/synthetic/private"
        with self.assertRaisesRegex(ValueError, "private"):
            self.build()


if __name__ == "__main__":
    unittest.main()
