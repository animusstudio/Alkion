"""Check unchanged synthetic HTTP bodies and their public mapping contract."""
import hashlib
import json
from pathlib import Path
import unittest

FIXTURES = Path(__file__).resolve().parents[1] / "app/test/fixtures/animus_workout_upload"
MANIFEST = json.loads((FIXTURES / "manifest.json").read_text())
CASES = {case["case"]: case for case in MANIFEST["cases"]}


def body(case, part="response"):
    return json.loads((FIXTURES / CASES[case][part]["file"]).read_bytes())


class WorkoutUploadFixtureTest(unittest.TestCase):
    def test_captured_bytes_and_canonical_measurements(self):
        self.assertEqual(len(CASES), 42)
        for case in CASES.values():
            for part in ("request", "response"):
                if part not in case:
                    continue
                raw = (FIXTURES / case[part]["file"]).read_bytes()
                self.assertEqual(len(raw), case[part]["bytes"])
                self.assertEqual(hashlib.sha256(raw).hexdigest(), case[part]["sha256"])
                json.loads(raw)
            if "canonical" in case:
                self.assertEqual(case["canonical"]["wire_bytes"], case["request"]["bytes"])
                self.assertRegex(case["canonical"]["canonical_sha256"], r"^[0-9a-f]{64}$")
        for label in ("20-definition-canonical-budget", "21-workout-canonical-budget"):
            case = CASES[label]
            self.assertEqual(case["status"], 400)
            self.assertLess(case["request"]["bytes"], 1048576)
            self.assertGreater(case["canonical"]["canonical_bytes"], case["canonical"]["canonical_limit"])
        self.assertEqual(CASES["22-workout-wire-budget"]["status"], 413)
        self.assertGreater(CASES["22-workout-wire-budget"]["request"]["bytes"], 1048576)

    def test_selected_mapping_and_identical_replay(self):
        request = body("10-pinned-workout-finish", "request")
        result = body("10-pinned-workout-finish")
        workout = result["record"]["workout"]
        self.assertEqual(request, body("14-pinned-workout-identical-replay", "request"))
        replay = body("14-pinned-workout-identical-replay")
        self.assertTrue(replay["replayed"])
        self.assertEqual(replay["record"], result["record"])
        self.assertEqual(replay["position"], result["position"])
        self.assertEqual(body("11-workout-read"), result["record"])
        status = body("12-workout-operation-status")
        self.assertEqual(status["operation_id"], request["operation_id"])
        self.assertEqual(status["target"], request["target"])
        self.assertEqual(status["revision"], 1)
        self.assertEqual(request["workout"]["finished_at"], "2026-10-29T00:15:17+02:00")
        self.assertNotIn("started_at", request["workout"]["draft"])
        self.assertEqual(request["workout"]["draft"]["elapsed_seconds"], 601)
        self.assertEqual(workout["date"]["value"], "2026-10-29")
        self.assertEqual(workout["finished_at"]["value"], "2026-10-28T22:15:17Z")
        self.assertEqual(workout["duration_min"]["value"], 10)
        sets = workout["sets"]
        self.assertEqual([s["weight_kg"]["value"] for s in sets], ["20.125", "62.50", None, "0"])
        self.assertEqual([s["rir"]["value"] for s in sets], [None, 2, None, 0])
        self.assertEqual([s["set_number"]["value"] for s in sets], [1, 2, 3, 4])
        blocks = request["workout"]["draft"]["blocks"]
        self.assertEqual([s["id"]["value"] for s in sets],
                         [s["set"]["id"]["value"] for b in blocks for s in b["sets"]])
        bases = lambda rows: {(row["target"]["kind"], row["target"]["id"]): row["revision"] for row in rows}
        self.assertEqual(bases(workout["reference_bases"]), bases(request["workout"]["definition_bases"]))

    def test_denials_and_capability_scope(self):
        capability = MANIFEST["required_capability"]
        self.assertIn(capability, body("00-system-info")["training"]["implemented"])
        self.assertEqual(MANIFEST["missing_capability_zero_dependency_writes"],
                         "PENDING T2 production sender acceptance")
        expected = {"07-pinned-stale-conflict": 409, "08-conflict-has-no-workout": 404,
                    "09-conflict-has-no-operation": 404, "15-native-read-without-reader-legacy-allow": 200,
                    "15b-unknown-supplied-reader-denied": 403, "16-wrong-space": 403,
                    "17-epoch-without-client-context-parser-denied": 400,
                    "18-replay-without-write-grant": 403, "19-reserved-source-native-write-denied": 403}
        for case, status in expected.items():
            self.assertEqual(CASES[case]["status"], status)
        invalid = {"23-null-bases": 400, "24-empty-bases": 409, "25-zero-revision": 400,
                   "26-duplicate-bases": 400, "27-wrong-base-kind": 400, "28-over-100-bases": 400}
        for case, status in invalid.items():
            self.assertEqual(CASES[case]["status"], status)
            self.assertEqual(CASES[case + "-no-workout"]["status"], 404)
            self.assertEqual(CASES[case + "-no-operation"]["status"], 404)


if __name__ == "__main__":
    unittest.main()
