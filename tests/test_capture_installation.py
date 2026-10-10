"""Installation matrix checks for the capture bridge.

Run from the repository root:

    python3 -m unittest discover -s tests -p test_capture_installation.py

Every value here is synthetic public metadata (package ids, certificate
digests, build numbers). No key, keystore, signing property or app data is
ever read.
"""

import copy
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(ROOT, "scripts", "check-capture-installation.py")

_spec = importlib.util.spec_from_file_location("check_capture_installation", SCRIPT)
checker = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(checker)
check_capture_installation = checker.check_capture_installation
evidence_from_acceptance = checker.evidence_from_acceptance

PACKAGE = "io.github.psychonaut0.reps"
OLDER_PACKAGE = "org.example.older_workout_tracker"
LINUX_PACKAGE = "io.github.psychonaut0.workout_tracker"
RELEASE_SIGNER = "1a" * 32
DEBUG_SIGNER = "2b" * 32
APK_SHA256 = "3c" * 32
MANIFEST_SHA256 = "4d" * 32
OTHER_SHA256 = "5e" * 32
REVISION = "6f" * 20
PROFILE = {
    "sdk_version": "2.2.0",
    "core_version": "0.4.13/670c312e",
    "schema": "physical=" + "70" * 32 + ";public=" + "81" * 32,
}
RETAINED = ["sql", "upload_queue", "pre_flush", "malformed", "recovery", "preferences"]


def original(**over):
    row = {
        "platform": "android",
        "package": PACKAGE,
        "channel": "release",
        "version_name": "0.18.1",
        "version_code": 37,
        "signer_sha256": RELEASE_SIGNER,
        "android_api": 34,
        "abi": "arm64-v8a",
        "profile": dict(PROFILE),
    }
    row.update(over)
    return row


def bridge(**over):
    row = {
        "platform": "android",
        "package": PACKAGE,
        "channel": "capture_bridge",
        "version_name": "0.19.0",
        "version_code": 38,
        "signer_sha256": RELEASE_SIGNER,
        "min_sdk": 24,
        "apk_sha256": APK_SHA256,
        "source_revision": REVISION,
        "profile": dict(PROFILE),
    }
    row.update(over)
    return row


def full_evidence(**over):
    evidence = {
        "upgrade": {"result": "pass", "reference": "synthetic disposable in-place upgrade"},
        "storage": {
            "result": "pass",
            "reference": "synthetic store retention after upgrade",
            "retained": list(RETAINED),
        },
        "capture": {
            "result": "pass",
            "reference": "first bridge launch capture",
            "first_launch": True,
            "before_destructive_loaders": True,
            "manifest_sha256": MANIFEST_SHA256,
        },
        "rollback": {"result": "pass", "reference": "refused bridge leaves original operational"},
        "receiving": {
            "result": "pass",
            "reference": "receiving verification of the exported capture",
            "manifest_sha256": MANIFEST_SHA256,
        },
    }
    evidence.update(over)
    return evidence


def status(o, b, e):
    return check_capture_installation(o, b, e)["status"]


class MatchingMetadataWithoutUpgradeProofPending(unittest.TestCase):
    def test_matching_metadata_without_upgrade_proof_pending(self):
        result = check_capture_installation(original(), bridge(), {})
        self.assertEqual(result["status"], "pending")
        self.assertEqual(
            sorted(result["missing_evidence"]),
            ["capture", "receiving", "rollback", "storage", "upgrade"],
        )
        self.assertFalse(result["cutover_ready"])

    def test_each_missing_or_unrun_entry_keeps_it_pending(self):
        for key in ("upgrade", "storage", "capture", "rollback", "receiving"):
            evidence = full_evidence()
            del evidence[key]
            self.assertEqual(status(original(), bridge(), evidence), "pending", key)
            evidence = full_evidence()
            evidence[key] = dict(evidence[key], result="unrun")
            self.assertEqual(status(original(), bridge(), evidence), "pending", key)
            evidence = full_evidence()
            evidence[key] = dict(evidence[key], reference="")
            self.assertEqual(status(original(), bridge(), evidence), "pending", key)

    def test_capture_attestations_must_be_present(self):
        for field in ("first_launch", "before_destructive_loaders", "manifest_sha256"):
            capture = dict(full_evidence()["capture"])
            del capture[field]
            self.assertEqual(
                status(original(), bridge(), full_evidence(capture=capture)),
                "pending",
                field,
            )

    def test_inputs_are_not_mutated(self):
        o, b, e = original(), bridge(), full_evidence()
        before = copy.deepcopy((o, b, e))
        check_capture_installation(o, b, e)
        self.assertEqual((o, b, e), before)


class DebugSignerMismatchUnsupported(unittest.TestCase):
    def test_debug_signer_mismatch_unsupported(self):
        debug_signer = original(channel="debug", signer_sha256=DEBUG_SIGNER)
        release_signer = bridge()
        result = check_capture_installation(debug_signer, release_signer, full_evidence())
        self.assertEqual(result["status"], "unsupported")
        self.assertIn("signer_mismatch", result["reasons"])

    def test_release_original_with_differently_signed_bridge_unsupported(self):
        result = check_capture_installation(
            original(), bridge(signer_sha256=DEBUG_SIGNER), full_evidence()
        )
        self.assertEqual(result["status"], "unsupported")
        self.assertIn("signer_mismatch", result["reasons"])

    def test_debug_original_with_matching_bridge_signer_follows_evidence(self):
        o = original(channel="debug", signer_sha256=DEBUG_SIGNER)
        b = bridge(signer_sha256=DEBUG_SIGNER)
        self.assertEqual(status(o, b, {}), "pending")
        self.assertEqual(status(o, b, full_evidence()), "qualified")


class PreviewHigherBuildUnsupported(unittest.TestCase):
    def test_preview_higher_build_unsupported(self):
        preview_build_500 = original(channel="preview", version_code=500)
        bridge_build_38 = bridge(version_code=38)
        evidence = full_evidence(
            release_ordering={"result": "pass", "reference": "next release run number"}
        )
        result = check_capture_installation(preview_build_500, bridge_build_38, evidence)
        self.assertEqual(result["status"], "unsupported")
        self.assertIn("version_code_not_admissible", result["reasons"])
        self.assertEqual(result["row"]["original_signer_sha256"], RELEASE_SIGNER)
        self.assertEqual(result["row"]["bridge_signer_sha256"], RELEASE_SIGNER)

    def test_equal_or_lower_build_never_admissible(self):
        for code in (38, 39):
            result = check_capture_installation(
                original(version_code=code), bridge(version_code=38), full_evidence()
            )
            self.assertEqual(result["status"], "unsupported", code)
            self.assertIn("version_code_not_admissible", result["reasons"])

    def test_lower_preview_needs_release_ordering(self):
        preview = original(channel="preview", version_code=36)
        result = check_capture_installation(preview, bridge(), full_evidence())
        self.assertEqual(result["status"], "pending")
        self.assertIn("release_ordering", result["missing_evidence"])
        ordered = full_evidence(
            release_ordering={"result": "pass", "reference": "next release run number"}
        )
        self.assertEqual(status(preview, bridge(), ordered), "qualified")


class OlderPackageNoAccessPath(unittest.TestCase):
    def transfer(self, **over):
        entry = {
            "result": "pass",
            "reference": "separately proven old-producer capture and transfer",
            "source_package": OLDER_PACKAGE,
            "manifest_sha256": MANIFEST_SHA256,
        }
        entry.update(over)
        return entry

    def test_older_package_no_access_path(self):
        older = original(package=OLDER_PACKAGE, version_code=12)
        result = check_capture_installation(older, bridge(), full_evidence())
        self.assertEqual(result["status"], "unsupported")
        self.assertIn("package_mismatch_no_access_path", result["reasons"])
        self.assertIsNone(result["access_path"])

    def test_unproven_or_unrelated_transfer_is_no_access_path(self):
        older = original(package=OLDER_PACKAGE, version_code=12)
        for transfer in (
            self.transfer(result="unrun"),
            self.transfer(reference=""),
            self.transfer(source_package=PACKAGE),
            self.transfer(manifest_sha256=None),
        ):
            result = check_capture_installation(
                older, bridge(), full_evidence(transfer=transfer)
            )
            self.assertEqual(result["status"], "unsupported", transfer)
            self.assertIn("package_mismatch_no_access_path", result["reasons"])

    def test_independently_proven_transfer_is_the_only_path(self):
        older = original(package=OLDER_PACKAGE, version_code=12)
        evidence = full_evidence(transfer=self.transfer())
        del evidence["upgrade"]
        result = check_capture_installation(older, bridge(), evidence)
        self.assertEqual(result["status"], "qualified")
        self.assertEqual(result["access_path"], "transfer")
        # The transferred capture names the older producer's runtime, not the bridge's.
        evidence["capture"] = dict(
            evidence["capture"],
            runtime={"app_version": "0.9.0+12", "sdk_version": "1.0.0", "core_version": "0.3.0"},
        )
        self.assertEqual(status(older, bridge(), evidence), "qualified")
        evidence["transfer"] = self.transfer(manifest_sha256=OTHER_SHA256)
        result = check_capture_installation(older, bridge(), evidence)
        self.assertEqual(result["status"], "unsupported")
        self.assertIn("transfer_digest_mismatch", result["reasons"])


class SignedUpgradeRetainsStoresFirstLaunch(unittest.TestCase):
    def test_signed_upgrade_retains_stores_first_launch(self):
        result = check_capture_installation(original(), bridge(), full_evidence())
        self.assertEqual(result["status"], "qualified")
        self.assertEqual(result["access_path"], "in_place_upgrade")
        self.assertEqual(result["reasons"], [])
        self.assertEqual(result["missing_evidence"], [])
        self.assertFalse(result["cutover_ready"])
        row = result["row"]
        self.assertEqual(row["status"], "qualified")
        self.assertEqual(row["original_package"], PACKAGE)
        self.assertEqual(row["original_channel"], "release")
        self.assertEqual(row["original_version_name"], "0.18.1")
        self.assertEqual(row["original_version_code"], 37)
        self.assertEqual(row["original_android_api"], 34)
        self.assertEqual(row["original_abi"], "arm64-v8a")
        self.assertEqual(row["profile"], PROFILE)
        self.assertEqual(row["bridge_apk_sha256"], APK_SHA256)
        self.assertEqual(row["bridge_version_code"], 38)
        self.assertEqual(row["bridge_source_revision"], REVISION)
        self.assertEqual(row["capture_manifest_sha256"], MANIFEST_SHA256)
        self.assertEqual(
            row["evidence"]["receiving"], "receiving verification of the exported capture"
        )

    def test_every_store_kind_must_survive(self):
        for kind in RETAINED:
            storage = dict(full_evidence()["storage"])
            storage["retained"] = [k for k in RETAINED if k != kind]
            result = check_capture_installation(
                original(), bridge(), full_evidence(storage=storage)
            )
            self.assertEqual(result["status"], "pending", kind)
            self.assertIn("storage_incomplete", result["reasons"])

    def test_capture_after_destructive_loaders_or_later_launch_unsupported(self):
        for field in ("first_launch", "before_destructive_loaders"):
            capture = dict(full_evidence()["capture"], **{field: False})
            result = check_capture_installation(
                original(), bridge(), full_evidence(capture=capture)
            )
            self.assertEqual(result["status"], "unsupported", field)

    def test_receiving_must_verify_the_same_digest(self):
        receiving = dict(full_evidence()["receiving"], manifest_sha256=OTHER_SHA256)
        result = check_capture_installation(
            original(), bridge(), full_evidence(receiving=receiving)
        )
        self.assertEqual(result["status"], "unsupported")
        self.assertIn("receiving_digest_mismatch", result["reasons"])

    def test_failed_evidence_is_unsupported(self):
        for key in ("upgrade", "storage", "capture", "rollback", "receiving"):
            evidence = full_evidence()
            evidence[key] = dict(evidence[key], result="fail")
            result = check_capture_installation(original(), bridge(), evidence)
            self.assertEqual(result["status"], "unsupported", key)
            self.assertIn(key + "_failed", result["reasons"])

    def test_capture_runtime_must_be_the_bridge(self):
        runtime = {"app_version": "0.19.0+38", "sdk_version": "2.2.0", "core_version": "0.4.13/670c312e"}
        capture = dict(full_evidence()["capture"], runtime=runtime)
        self.assertEqual(
            status(original(), bridge(), full_evidence(capture=capture)), "qualified"
        )
        capture["runtime"] = dict(runtime, app_version="0.18.1+37")
        result = check_capture_installation(original(), bridge(), full_evidence(capture=capture))
        self.assertEqual(result["status"], "unsupported")
        self.assertIn("capture_runtime_mismatch", result["reasons"])


class UnknownMetadataUnsupported(unittest.TestCase):
    def assert_unsupported(self, o, b, reason):
        result = check_capture_installation(o, b, full_evidence())
        self.assertEqual(result["status"], "unsupported", (o, b))
        self.assertIn(reason, result["reasons"])

    def test_unknown_or_malformed_identity(self):
        self.assert_unsupported(original(signer_sha256=None), bridge(), "original_signer_sha256_invalid")
        self.assert_unsupported(original(signer_sha256="AB" * 32), bridge(), "original_signer_sha256_invalid")
        self.assert_unsupported(original(package=""), bridge(), "original_package_invalid")
        self.assert_unsupported(original(channel="sideload"), bridge(), "original_channel_invalid")
        self.assert_unsupported(original(platform="ios"), bridge(), "original_platform_invalid")
        self.assert_unsupported(original(version_code="37"), bridge(), "original_version_code_invalid")
        self.assert_unsupported(original(version_code=True), bridge(), "original_version_code_invalid")
        self.assert_unsupported(original(android_api=None), bridge(), "original_android_api_invalid")
        self.assert_unsupported(original(abi=""), bridge(), "original_abi_invalid")
        self.assert_unsupported(original(profile=None), bridge(), "original_profile_invalid")
        self.assert_unsupported(original(), bridge(apk_sha256="x"), "bridge_apk_sha256_invalid")
        self.assert_unsupported(original(), bridge(source_revision="main"), "bridge_source_revision_invalid")

    def test_profile_must_match_exactly(self):
        self.assert_unsupported(
            original(profile=dict(PROFILE, core_version="0.4.14/aaaaaaaa")),
            bridge(),
            "profile_mismatch",
        )

    def test_existing_channels_are_never_a_bridge(self):
        for channel in ("release", "preview", "debug", "local_release"):
            self.assert_unsupported(original(), bridge(channel=channel), "bridge_channel_invalid")

    def test_platform_and_api(self):
        self.assert_unsupported(original(android_api=23), bridge(), "android_api_below_bridge_min_sdk")
        self.assert_unsupported(
            original(),
            bridge(platform="linux", signer_sha256=None, apk_sha256=None, linux_build="x"),
            "platform_mismatch",
        )

    def test_non_dict_inputs(self):
        result = check_capture_installation(None, bridge(), "x")
        self.assertEqual(result["status"], "unsupported")
        self.assertIn("original_invalid", result["reasons"])
        self.assertIn("evidence_invalid", result["reasons"])


class PrivateMaterialRejected(unittest.TestCase):
    def test_signing_or_credential_fields_are_refused_without_echo(self):
        secret = "do-not-echo-this-value"
        for where, key in (
            ("original", "storePassword"),
            ("bridge", "keystore"),
            ("bridge", "key_alias"),
            ("evidence", "access_token"),
        ):
            o, b, e = original(), bridge(), full_evidence()
            target = {"original": o, "bridge": b, "evidence": e}[where]
            target[key] = secret
            result = check_capture_installation(o, b, e)
            self.assertEqual(result["status"], "unsupported", key)
            self.assertIn("private_material_rejected", result["reasons"])
            self.assertNotIn(secret, json.dumps(result))
            self.assertIsNone(result["row"])

    def test_nested_private_field_is_refused(self):
        e = full_evidence()
        e["upgrade"] = dict(e["upgrade"], signing={"key_password": "x"})
        result = check_capture_installation(original(), bridge(), e)
        self.assertIn("private_material_rejected", result["reasons"])


def acceptance(**over):
    doc = {
        "format": "reps-capture-acceptance",
        "version": 1,
        "cutover_ready": False,
        "runtime": {
            "platform": "linux",
            "app_version": "0.18.1+37",
            "sdk_version": "2.2.0",
            "core_version": "0.4.13/670c312e",
            "producer_revision": "reps-capture/1",
            "build_mode": "debug",
        },
        "results": {
            "kill_each_boundary_and_restart_twice": "pass",
            "foreground_background_native_writer_races": "pass",
            "full_disk_permission_unreadable_and_limit_faults": "pass",
            "go_rehearsal_raw_digests_and_dispositions": "pass",
        },
        "captures": [
            {
                "name": "synthetic-capture",
                "kind": "certified",
                "manifest_sha256": MANIFEST_SHA256,
                "tree_sha256": {"manifest.json": MANIFEST_SHA256},
                "cutover_ready": False,
            },
            {
                "name": "exploratory-queue-blocked",
                "kind": "exploratory",
                "manifest_sha256": OTHER_SHA256,
                "tree_sha256": {"manifest.json": OTHER_SHA256},
                "cutover_ready": False,
            },
        ],
        "interruptions": [
            {"boundary": "read", "died_by_sigkill": True, "result": "pass"},
            {"boundary": "staged", "died_by_sigkill": True, "result": "pass"},
        ],
        "faults": [{"fault": "insufficient_space", "result": "pass"}],
        "races": {"result": "pass"},
    }
    doc.update(over)
    return doc


def linux_row(**over):
    row = {
        "platform": "linux",
        "package": LINUX_PACKAGE,
        "channel": "development",
        "version_name": "0.18.1",
        "version_code": 37,
        "linux_build": "debug bundle x86_64",
        "profile": dict(PROFILE),
    }
    row.update(over)
    return row


def linux_bridge(**over):
    row = linux_row(source_revision=REVISION)
    row.update(over)
    return row


class LinuxDevelopmentLoop(unittest.TestCase):
    def test_acceptance_evidence_qualifies_development_loop_only(self):
        evidence = evidence_from_acceptance(acceptance())
        self.assertEqual(sorted(evidence), ["capture", "receiving", "recovery", "storage"])
        result = check_capture_installation(linux_row(), linux_bridge(), evidence)
        self.assertEqual(result["status"], "qualified")
        self.assertEqual(result["access_path"], "development_loop")
        self.assertEqual(result["row"]["capture_manifest_sha256"], MANIFEST_SHA256)
        self.assertFalse(result["cutover_ready"])

    def test_linux_without_recovery_or_capture_is_pending(self):
        for key in ("recovery", "capture", "receiving", "storage"):
            evidence = evidence_from_acceptance(acceptance())
            del evidence[key]
            self.assertEqual(status(linux_row(), linux_bridge(), evidence), "pending", key)

    def test_linux_is_never_a_public_distribution(self):
        evidence = evidence_from_acceptance(acceptance())
        for o, b, reason in (
            (linux_row(channel="release"), linux_bridge(), "original_channel_invalid"),
            (linux_row(), linux_bridge(channel="capture_bridge"), "bridge_channel_invalid"),
            (linux_row(signer_sha256=RELEASE_SIGNER), linux_bridge(), "original_signer_sha256_invalid"),
            (linux_row(), linux_bridge(apk_sha256=APK_SHA256), "bridge_apk_sha256_invalid"),
            (linux_row(version_code=40), linux_bridge(), "version_code_not_admissible"),
        ):
            result = check_capture_installation(o, b, evidence)
            self.assertEqual(result["status"], "unsupported", reason)
            self.assertIn(reason, result["reasons"])

    def test_failed_producer_test_fails_its_evidence(self):
        results = dict(acceptance()["results"], kill_each_boundary_and_restart_twice="fail")
        evidence = evidence_from_acceptance(acceptance(results=results))
        self.assertEqual(evidence["recovery"]["result"], "fail")
        self.assertEqual(
            status(linux_row(), linux_bridge(), evidence), "unsupported"
        )

    def test_unkilled_interruption_fails_recovery(self):
        doc = acceptance(
            interruptions=[{"boundary": "read", "died_by_sigkill": False, "result": "pass"}]
        )
        self.assertEqual(evidence_from_acceptance(doc)["recovery"]["result"], "fail")
        self.assertEqual(
            evidence_from_acceptance(acceptance(interruptions=[]))["recovery"]["result"],
            "fail",
        )

    def test_acceptance_from_another_build_does_not_qualify(self):
        runtime = dict(acceptance()["runtime"], app_version="0.18.0+30")
        evidence = evidence_from_acceptance(acceptance(runtime=runtime))
        result = check_capture_installation(linux_row(), linux_bridge(), evidence)
        self.assertEqual(result["status"], "unsupported")
        self.assertIn("capture_runtime_mismatch", result["reasons"])

    def test_invalid_acceptance_is_refused(self):
        for doc in (
            acceptance(cutover_ready=True),
            acceptance(format="other"),
            acceptance(version=2),
            [],
        ):
            with self.assertRaises(ValueError):
                evidence_from_acceptance(doc)

    def test_non_linux_acceptance_gives_no_evidence(self):
        doc = acceptance(runtime={"platform": "android"})
        self.assertEqual(evidence_from_acceptance(doc), {})

    def test_no_certified_capture_means_no_capture_evidence(self):
        doc = acceptance(captures=[acceptance()["captures"][1]])
        evidence = evidence_from_acceptance(doc)
        self.assertNotIn("capture", evidence)
        self.assertNotIn("receiving", evidence)


class CommandLine(unittest.TestCase):
    def run_cli(self, *args):
        return subprocess.run(
            [sys.executable, "-I", SCRIPT, *args],
            capture_output=True,
            text=True,
            check=False,
        )

    def test_exit_codes_follow_status(self):
        with tempfile.TemporaryDirectory() as tmp:
            cases = (
                ({"original": original(), "bridge": bridge(), "evidence": full_evidence()}, 0, "qualified"),
                ({"original": original(), "bridge": bridge(), "evidence": {}}, 3, "pending"),
                (
                    {"original": original(version_code=500), "bridge": bridge(), "evidence": full_evidence()},
                    4,
                    "unsupported",
                ),
            )
            for i, (row, code, expected) in enumerate(cases):
                path = os.path.join(tmp, "row%d.json" % i)
                with open(path, "w", encoding="utf-8") as f:
                    json.dump(row, f)
                proc = self.run_cli(path)
                self.assertEqual(proc.returncode, code, proc.stderr)
                self.assertEqual(json.loads(proc.stdout)["status"], expected)

    def test_acceptance_option_supplies_linux_evidence(self):
        with tempfile.TemporaryDirectory() as tmp:
            row_path = os.path.join(tmp, "row.json")
            acc_path = os.path.join(tmp, "acceptance.json")
            with open(row_path, "w", encoding="utf-8") as f:
                json.dump({"original": linux_row(), "bridge": linux_bridge(), "evidence": {}}, f)
            with open(acc_path, "w", encoding="utf-8") as f:
                json.dump(acceptance(), f)
            proc = self.run_cli("--acceptance", acc_path, row_path)
            self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
            out = json.loads(proc.stdout)
            self.assertEqual(out["status"], "qualified")
            self.assertEqual(out["access_path"], "development_loop")

    def test_unreadable_input_is_a_usage_error(self):
        proc = self.run_cli(os.path.join(ROOT, "does-not-exist.json"))
        self.assertEqual(proc.returncode, 2)


if __name__ == "__main__":
    unittest.main()
