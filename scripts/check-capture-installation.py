#!/usr/bin/env python3
"""Decide whether one installation can reach the capture bridge.

Usage (from the repository root):

    python3 -I scripts/check-capture-installation.py [--acceptance ACCEPTANCE] ROW

ROW is a JSON file `{"original": {...}, "bridge": {...}, "evidence": {...}}`
holding public metadata only: package id, channel, versionName/versionCode,
the SHA-256 of the public signing certificate (as `apksigner verify
--print-certs` or `dumpsys package` print it), Android API/ABI or the Linux
build, the exact SDK/core/schema profile, the bridge APK digest and source
revision, and references to the upgrade, storage, capture, rollback and
receiving evidence. `--acceptance` names the sanitized `acceptance.json` that
`make -C app capture-recovery` wrote; on Linux it supplies the evidence
entries that run supports (see `evidence_from_acceptance`).

Prints one JSON result and exits 0 for `qualified`, 3 for `pending` and 4
for `unsupported`; 2 means the input could not be read.

This never reads a key, keystore, signing property, secure storage, app
data or configuration file. An input that names signing or credential
fields is refused without echoing them.

Rules:

* Matching metadata alone never qualifies: every evidence entry the access
  path needs must be present, `pass` and referenced.
* Same package on Android is an in-place upgrade. It needs the same
  certificate digest, a strictly higher bridge versionCode (a preview build
  above the bridge stays unsupported even with a matching signer), an API
  level the bridge supports and the exact same profile. A preview original
  also needs evidence that the next release orders above the bridge.
* A different package (for example an older app id) has no access path
  unless an independently proven transfer of that package's capture is
  referenced; the bridge's own metadata never proves one.
* Linux is the development loop only (channel `development`, no signer, no
  APK); it is never a public distribution.
* A failed entry, a capture after destructive loaders or not on first
  launch, a receiving digest that differs from the capture, and capture
  evidence from another build are unsupported. Missing, unrun or incomplete
  entries are pending.
* `cutover_ready` is always false.
"""

import argparse
import hashlib
import json
import re
import sys

QUALIFIED = "qualified"
PENDING = "pending"
UNSUPPORTED = "unsupported"

ORIGINAL_CHANNELS = {
    "android": {"release", "preview", "debug", "local_release"},
    "linux": {"development"},
}
# A bridge is only ever built by `make -C app build-capture-apk-release`
# (release signing required, no debug fallback). Existing channels never
# become a bridge.
BRIDGE_CHANNELS = {"android": {"capture_bridge"}, "linux": {"development"}}

# Store kinds that must survive the upgrade (or, on Linux, interruption and
# restart) unchanged before a capture may be trusted.
RETAINED_STORES = ("sql", "upload_queue", "pre_flush", "malformed", "recovery", "preferences")

REQUIRED_EVIDENCE = {
    "in_place_upgrade": ("upgrade", "storage", "capture", "rollback", "receiving"),
    "transfer": ("transfer", "storage", "capture", "rollback", "receiving"),
    "development_loop": ("capture", "storage", "recovery", "receiving"),
}
EVIDENCE_KEYS = (
    "upgrade",
    "storage",
    "capture",
    "rollback",
    "receiving",
    "transfer",
    "release_ordering",
    "recovery",
)

# Field names that would carry private signing material or credentials.
# Compared after lower-casing and dropping everything but letters/digits.
PRIVATE_FIELD_MARKERS = (
    "password",
    "keystore",
    "storefile",
    "keyalias",
    "privatekey",
    "secret",
    "token",
    "credential",
)

_HEX64 = re.compile(r"[0-9a-f]{64}")
_REVISION = re.compile(r"[0-9a-f]{40}|[0-9a-f]{64}")
_PACKAGE = re.compile(r"[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+")
PROFILE_FIELDS = ("sdk_version", "core_version", "schema")

ACCEPTANCE_FORMAT = "reps-capture-acceptance"
KILL_TEST = "kill_each_boundary_and_restart_twice"
RACE_TEST = "foreground_background_native_writer_races"
FAULT_TEST = "full_disk_permission_unreadable_and_limit_faults"
GO_TEST = "go_rehearsal_raw_digests_and_dispositions"
CERTIFIED_FIXTURE = "synthetic-capture"


def _names_private_field(value):
    if isinstance(value, dict):
        for key, item in value.items():
            folded = re.sub(r"[^a-z0-9]", "", str(key).lower())
            if any(marker in folded for marker in PRIVATE_FIELD_MARKERS):
                return True
            if _names_private_field(item):
                return True
    elif isinstance(value, list):
        return any(_names_private_field(item) for item in value)
    return False


def _text(value):
    return isinstance(value, str) and value.strip() != ""


def _positive_int(value):
    return isinstance(value, int) and not isinstance(value, bool) and value > 0


def _hex64(value):
    return isinstance(value, str) and _HEX64.fullmatch(value) is not None


def _profile(value):
    if not isinstance(value, dict) or set(value) != set(PROFILE_FIELDS):
        return None
    if not all(_text(value[field]) for field in PROFILE_FIELDS):
        return None
    return {field: value[field] for field in PROFILE_FIELDS}


def _validate(side, row, bad):
    """Check one side's public metadata; returns the validated fields."""
    if not isinstance(row, dict):
        bad.add(side + "_invalid")
        return None
    platform = row.get("platform")
    if platform not in ORIGINAL_CHANNELS:
        bad.add(side + "_platform_invalid")
        return None
    out = {"platform": platform}
    channels = (ORIGINAL_CHANNELS if side == "original" else BRIDGE_CHANNELS)[platform]

    def check(field, ok):
        if ok(row.get(field)):
            out[field] = row.get(field)
        else:
            bad.add("%s_%s_invalid" % (side, field))

    check("package", lambda v: isinstance(v, str) and _PACKAGE.fullmatch(v) is not None)
    check("channel", lambda v: v in channels)
    check("version_name", _text)
    check("version_code", _positive_int)
    if platform == "android":
        check("signer_sha256", _hex64)
        if side == "original":
            check("android_api", _positive_int)
            check("abi", _text)
        else:
            check("min_sdk", _positive_int)
            check("apk_sha256", _hex64)
    else:
        # The Linux development loop has no package signer and no APK.
        check("signer_sha256", lambda v: v is None)
        check("linux_build", _text)
        if side == "bridge":
            check("apk_sha256", lambda v: v is None)
        out.pop("signer_sha256", None)
        out.pop("apk_sha256", None)
    if side == "bridge":
        check("source_revision", lambda v: isinstance(v, str) and _REVISION.fullmatch(v) is not None)
    profile = _profile(row.get("profile"))
    if profile is None:
        bad.add(side + "_profile_invalid")
    else:
        out["profile"] = profile
    return out


def _entry(evidence, key, pending, bad):
    """A required evidence entry: returns it when it is a referenced pass."""
    entry = evidence.get(key)
    if not isinstance(entry, dict):
        pending.add(key + "_incomplete")
        return None
    result = entry.get("result")
    if result == "fail":
        bad.add(key + "_failed")
        return None
    if result != "pass" or not _text(entry.get("reference")):
        pending.add(key + "_incomplete")
        return None
    return entry


def _transfer_proven(evidence, original):
    entry = evidence.get("transfer")
    return (
        isinstance(entry, dict)
        and entry.get("result") == "pass"
        and _text(entry.get("reference"))
        and entry.get("source_package") == original.get("package")
        and _hex64(entry.get("manifest_sha256"))
    )


def _row(original, bridge, evidence, status):
    o = original or {}
    b = bridge or {}
    capture = evidence.get("capture") if isinstance(evidence.get("capture"), dict) else {}
    refs = {}
    for key in EVIDENCE_KEYS:
        entry = evidence.get(key)
        ref = entry.get("reference") if isinstance(entry, dict) else None
        refs[key] = ref if _text(ref) else None
    return {
        "original_platform": o.get("platform"),
        "original_package": o.get("package"),
        "original_channel": o.get("channel"),
        "original_version_name": o.get("version_name"),
        "original_version_code": o.get("version_code"),
        "original_signer_sha256": o.get("signer_sha256"),
        "original_android_api": o.get("android_api"),
        "original_abi": o.get("abi"),
        "original_linux_build": o.get("linux_build"),
        "profile": o.get("profile"),
        "bridge_package": b.get("package"),
        "bridge_channel": b.get("channel"),
        "bridge_version_name": b.get("version_name"),
        "bridge_version_code": b.get("version_code"),
        "bridge_signer_sha256": b.get("signer_sha256"),
        "bridge_min_sdk": b.get("min_sdk"),
        "bridge_apk_sha256": b.get("apk_sha256"),
        "bridge_linux_build": b.get("linux_build"),
        "bridge_source_revision": b.get("source_revision"),
        "bridge_profile": b.get("profile"),
        "capture_manifest_sha256": (
            capture.get("manifest_sha256") if _hex64(capture.get("manifest_sha256")) else None
        ),
        "evidence": refs,
        "status": status,
    }


def check_capture_installation(original, bridge, evidence):
    """Classify one original installation against one capture bridge.

    Returns `{"status", "access_path", "reasons", "missing_evidence",
    "row", "cutover_ready"}`. `status` is `qualified`, `pending` or
    `unsupported`; `row` holds only validated public metadata and evidence
    references (None when the input named private material).
    """
    bad = set()
    pending = set()
    missing = []

    if _names_private_field([original, bridge, evidence]):
        return {
            "status": UNSUPPORTED,
            "access_path": None,
            "reasons": ["private_material_rejected"],
            "missing_evidence": [],
            "row": None,
            "cutover_ready": False,
        }

    if not isinstance(evidence, dict):
        bad.add("evidence_invalid")
        evidence = {}
    o = _validate("original", original, bad)
    b = _validate("bridge", bridge, bad)

    path = None
    if o is not None and b is not None:
        if o["platform"] != b["platform"]:
            bad.add("platform_mismatch")
        elif "package" in o and "package" in b:
            same_package = o["package"] == b["package"]
            if o["platform"] == "linux":
                path = "development_loop"
                if not same_package:
                    bad.add("package_mismatch_no_access_path")
            elif same_package:
                path = "in_place_upgrade"
            elif _transfer_proven(evidence, o):
                path = "transfer"
            else:
                bad.add("package_mismatch_no_access_path")

        if path in ("in_place_upgrade", "development_loop"):
            if "profile" in o and "profile" in b and o["profile"] != b["profile"]:
                bad.add("profile_mismatch")
            if "version_code" in o and "version_code" in b:
                if path == "in_place_upgrade":
                    admissible = b["version_code"] > o["version_code"]
                else:
                    admissible = b["version_code"] >= o["version_code"]
                if not admissible:
                    bad.add("version_code_not_admissible")
        if path == "in_place_upgrade":
            if "signer_sha256" in o and "signer_sha256" in b and o["signer_sha256"] != b["signer_sha256"]:
                bad.add("signer_mismatch")
            if "android_api" in o and "min_sdk" in b and o["android_api"] < b["min_sdk"]:
                bad.add("android_api_below_bridge_min_sdk")

    if path is not None:
        required = list(REQUIRED_EVIDENCE[path])
        if path == "in_place_upgrade" and o.get("channel") == "preview":
            required.append("release_ordering")
        entries = {}
        for key in required:
            if key not in evidence:
                missing.append(key)
                continue
            entries[key] = _entry(evidence, key, pending, bad)

        storage = entries.get("storage")
        if storage is not None:
            retained = storage.get("retained")
            if not isinstance(retained, list) or not set(RETAINED_STORES) <= set(retained):
                pending.add("storage_incomplete")

        capture = entries.get("capture")
        capture_digest = None
        if capture is not None:
            if _hex64(capture.get("manifest_sha256")):
                capture_digest = capture["manifest_sha256"]
            else:
                pending.add("capture_incomplete")
            if path == "in_place_upgrade":
                for field, reason in (
                    ("first_launch", "capture_not_first_launch"),
                    ("before_destructive_loaders", "capture_after_destructive_loaders"),
                ):
                    value = capture.get(field)
                    if value is False:
                        bad.add(reason)
                    elif value is not True:
                        pending.add("capture_incomplete")
            # A transferred capture comes from the older package's own
            # producer, so only bridge-produced captures name its runtime.
            runtime = capture.get("runtime")
            if runtime is not None and path != "transfer":
                expected = {
                    "app_version": "%s+%s" % (b.get("version_name"), b.get("version_code")),
                    "sdk_version": (b.get("profile") or {}).get("sdk_version"),
                    "core_version": (b.get("profile") or {}).get("core_version"),
                }
                if not isinstance(runtime, dict) or any(
                    runtime.get(k) != v for k, v in expected.items()
                ):
                    bad.add("capture_runtime_mismatch")

        receiving = entries.get("receiving")
        if receiving is not None:
            if not _hex64(receiving.get("manifest_sha256")):
                pending.add("receiving_incomplete")
            elif capture_digest is not None and receiving["manifest_sha256"] != capture_digest:
                bad.add("receiving_digest_mismatch")

        if path == "transfer":
            moved = evidence["transfer"]["manifest_sha256"]
            for entry in (capture, receiving):
                if entry is not None and _hex64(entry.get("manifest_sha256")) and entry["manifest_sha256"] != moved:
                    bad.add("transfer_digest_mismatch")

    if bad:
        status = UNSUPPORTED
    elif pending or missing:
        status = PENDING
    else:
        status = QUALIFIED
    return {
        "status": status,
        "access_path": None if status == UNSUPPORTED else path,
        "reasons": sorted(bad | pending),
        "missing_evidence": sorted(missing),
        "row": _row(o, b, evidence, status),
        "cutover_ready": False,
    }


def evidence_from_acceptance(acceptance, source="acceptance.json"):
    """Evidence entries a sanitized Linux capture-recovery run supports.

    Maps the four producer tests onto `recovery` (every interruption
    SIGKILLed and recovered), `storage` (sources unchanged through kills,
    faults and writer races), `capture` (the certified synthetic fixture,
    with the run's runtime so another build cannot reuse it) and
    `receiving` (the exported tree's manifest digest). A test that did not
    pass makes its entries `fail`. Nothing here is upgrade or rollback
    evidence, and a non-Linux run supplies nothing.
    """
    if (
        not isinstance(acceptance, dict)
        or acceptance.get("format") != ACCEPTANCE_FORMAT
        or acceptance.get("version") != 1
        or acceptance.get("cutover_ready") is not False
    ):
        raise ValueError("not a sanitized %s v1 document" % ACCEPTANCE_FORMAT)
    runtime = acceptance.get("runtime")
    if not isinstance(runtime, dict) or runtime.get("platform") != "linux":
        return {}
    results = acceptance.get("results") if isinstance(acceptance.get("results"), dict) else {}

    def passed(name):
        return results.get(name) == "pass"

    def verdict(ok):
        return "pass" if ok else "fail"

    def all_pass(items, extra=lambda item: True):
        return (
            isinstance(items, list)
            and len(items) > 0
            and all(isinstance(i, dict) and i.get("result") == "pass" and extra(i) for i in items)
        )

    interruptions = acceptance.get("interruptions")
    evidence = {
        "recovery": {
            "result": verdict(
                passed(KILL_TEST)
                and all_pass(interruptions, lambda i: i.get("died_by_sigkill") is True)
            ),
            "reference": "%s: %s (%d SIGKILLed boundaries, recovered twice)"
            % (source, KILL_TEST, len(interruptions) if isinstance(interruptions, list) else 0),
        }
    }
    races = acceptance.get("races")
    storage_ok = (
        passed(KILL_TEST)
        and passed(FAULT_TEST)
        and passed(RACE_TEST)
        and all_pass(acceptance.get("faults"))
        and isinstance(races, dict)
        and races.get("result") == "pass"
    )
    evidence["storage"] = {
        "result": verdict(storage_ok),
        "reference": "%s: %s, %s, %s" % (source, KILL_TEST, FAULT_TEST, RACE_TEST),
        "retained": list(RETAINED_STORES) if storage_ok else [],
    }

    captures = acceptance.get("captures") if isinstance(acceptance.get("captures"), list) else []
    certified = [
        c
        for c in captures
        if isinstance(c, dict) and c.get("name") == CERTIFIED_FIXTURE and c.get("kind") == "certified"
    ]
    if len(certified) == 1:
        fixture = certified[0]
        ok = passed(GO_TEST) and fixture.get("cutover_ready") is False
        evidence["capture"] = {
            "result": verdict(ok),
            "reference": "%s: captures[%s] (certified), %s" % (source, CERTIFIED_FIXTURE, GO_TEST),
            "manifest_sha256": fixture.get("manifest_sha256"),
            "runtime": {k: runtime.get(k) for k in ("app_version", "sdk_version", "core_version")},
        }
        tree = fixture.get("tree_sha256") if isinstance(fixture.get("tree_sha256"), dict) else {}
        evidence["receiving"] = {
            "result": verdict(ok),
            "reference": "%s: captures[%s] exported with receiving verification" % (source, CERTIFIED_FIXTURE),
            "manifest_sha256": tree.get("manifest.json"),
        }
    return evidence


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--acceptance", help="sanitized acceptance.json from capture-recovery")
    parser.add_argument("row", help='JSON file {"original", "bridge", "evidence"}')
    args = parser.parse_args(argv)
    try:
        with open(args.row, "r", encoding="utf-8") as f:
            row = json.load(f)
        if not isinstance(row, dict):
            raise ValueError("row must be a JSON object")
        evidence = row.get("evidence", {})
        if args.acceptance:
            with open(args.acceptance, "rb") as f:
                raw = f.read()
            digest = hashlib.sha256(raw).hexdigest()
            derived = evidence_from_acceptance(
                json.loads(raw.decode("utf-8")), source="acceptance.json@sha256:" + digest
            )
            if isinstance(evidence, dict):
                evidence = dict(derived, **evidence)
    except (OSError, ValueError) as error:
        print("check-capture-installation: %s" % error, file=sys.stderr)
        return 2
    result = check_capture_installation(row.get("original"), row.get("bridge"), evidence)
    print(json.dumps(result, indent=2, sort_keys=True))
    return {QUALIFIED: 0, PENDING: 3, UNSUPPORTED: 4}[result["status"]]


if __name__ == "__main__":
    sys.exit(main())
