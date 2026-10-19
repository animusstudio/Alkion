"""Fresh receiving restore campaign; imported later by the guarded harness.

No CLI, build, device discovery or cleanup is provided here. prepare(host,args)
only reads the explicitly named receipts, retained APKs and fresh receiver. run
performs the authorized installs, fixed private ingress, real DocumentsUI Open,
six owned-PID SIGKILLs and twelve distinct-process adapter launches. The host is
the reviewed android_synthetic.sh helper namespace (including its native process
identity parser); documents supplies the reviewed SAF transport and validators.
Later wiring also supplies ui_observer_validate_build and
ui_observer_install_fresh facades from the independently frozen UI helper.

args: receipt/output/sdk/serial/avd, source_manifest, receiver_driver,
version_ledger, source_review, candidate_manifest, dev_apk, supported_apk,
provider_apk, ui_observer_build (the fixed ui-observer/build.json). The manifest
and review schemas are deliberately explicit: missing provenance is a refusal,
never selection of a recent run. A prepared object owns no device mutation.
"""

import base64
from dataclasses import dataclass
from functools import wraps
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import time

import android_synthetic_documents as documents


Refusal = documents.Refusal
require = documents.require
digest = documents.digest
encoded = documents.encoded
exclusive = documents.exclusive
PACKAGES = documents.PACKAGES
VARIANTS = documents.VARIANTS
PROVIDER = documents.PROVIDER
OBSERVER = "dev.animusstudio.alkion.synthetic.uiobserver"
LIMIT = documents.LIMIT
JSON_LIMIT = documents.JSON_LIMIT
MAX_VERSION = 2099999999
STEPS = ("preflight", "refusals", "fresh-preparation", "restore-staged-bytes",
         "restore-staged", "restore-intent", "restore-selected", "restore-before-identity",
         "complete", "completed-refusal", "cold-1", "cold-2")
CHAIN = ("disposable", "driver", "updates", "lifecycle", "documents", "provider_save_good", "receiving")
SOURCE_KEYS = ("disposable", "driver", "updates", "lifecycle", "documents")
VARIANT_KEYS = ("report", "receiving", "provider_save_good", "received", "apk")
UNRUN = ("same_profile_replacement", "keep_current", "actual_old_notification_payload",
         "owner_device", "physical_power_loss", "physical_off_device_verification")
REFUSALS = {"foreign-variant": "backup_foreign_variant", "corrupt": "backup_digest_mismatch",
            "newer": "backup_newer_schema", "nonempty": "restore_target_not_empty",
            "linked": "linked_path", "foreign-profile": "foreign_profile"}
ALLOWED_CHANGES = frozenset((
    "app/Makefile", "app/tool/android_synthetic.sh", "app/tool/android_synthetic_documents.py",
    "app/tool/android_synthetic_documents_self_test.py", "app/tool/android_synthetic_restore.py",
    "app/tool/android_synthetic_restore_self_test.py", "app/integration_test/android_documents_test.dart",
    "app/tool/android_synthetic_ui.py", "app/tool/android_synthetic_ui_self_test.py",
    "app/tool/android_synthetic_ui/AndroidManifest.xml", "app/tool/android_synthetic_ui/HierarchyInstrumentation.java",
    "app/integration_test/android_restore_test.dart", "app/integration_test/android_driver_test.dart",
    "app/test/alkion/acceptance/android_documents_fixture_test.dart",
    "app/test/alkion/acceptance/android_restore_protocol_test.dart",
    "app/test/alkion/driver_qualification_test.dart",
    "docs/superpowers/plans/2026-10-17-android-owner-readiness.md",
    "docs/alkion/acceptance.md", "docs/alkion/owner-gates.md"))


def keys(value, expected, reason):
    require(isinstance(value, dict) and set(value) == set(expected), reason)


def hexadecimal(value, size=64):
    return isinstance(value, str) and re.fullmatch(r"[a-f0-9]{" + str(size) + "}", value) is not None


def parse(raw):
    def pairs(items):
        value = {}
        for key, item in items:
            require(key not in value, "duplicate_json_key")
            value[key] = item
        return value
    value = json.loads(raw, object_pairs_hook=pairs,
                       parse_constant=lambda _: (_ for _ in ()).throw(Refusal("nonfinite_json")))
    require(isinstance(value, dict), "restore_json_object_required")
    return value


def local(host, value, pins, *, bound=JSON_LIMIT, json_value=True):
    path = host.temporary_path(value, must_exist=True)
    require(path.is_file() and not path.is_symlink() and path.stat().st_size <= bound and
            not stat.S_IMODE(path.stat().st_mode) & 0o022,
            "bounded_regular_restore_input_required")
    raw = path.read_bytes()
    require(len(raw) <= bound, "restore_local_input_too_large")
    pins[path] = raw
    return (parse(raw) if json_value else raw), path


def check_pins(pins):
    for path, raw in pins.items():
        require(path.is_file() and all(not ancestor.is_symlink() for ancestor in (path, *path.parents)) and
                path.stat().st_uid == os.getuid() and not stat.S_IMODE(path.stat().st_mode) & 0o022 and
                path.read_bytes() == raw,
                "pinned_restore_host_input_changed:" + str(path))


def timeout_context(phase):
    def decorate(function):
        @wraps(function)
        def wrapped(host, args_or_prepared, *more):
            try:
                return function(host, args_or_prepared, *more)
            except subprocess.TimeoutExpired as error:
                def raw(value):
                    return value if isinstance(value, bytes) else value.encode() if isinstance(value, str) else b""
                error.restore_partial_stdout = raw(error.stdout)
                error.restore_partial_stderr = raw(error.stderr)
                error.restore_timeout_receipt = {"format": "alkion-restore-transport-timeout/1", "phase": phase,
                    "argv": list(map(str, error.cmd)) if isinstance(error.cmd, (tuple, list)) else str(error.cmd),
                    "timeout_seconds": error.timeout, "completion": "UNKNOWN; no retry or repair",
                    "stdout": {"length": len(error.restore_partial_stdout), "sha256": digest(error.restore_partial_stdout)},
                    "stderr": {"length": len(error.restore_partial_stderr), "sha256": digest(error.restore_partial_stderr)}}
                raise
        return wrapped
    return decorate


def recorded_codes(value, package=None):
    result = set()
    if isinstance(value, dict):
        package = value.get("application_id", value.get("package", package))
        if package in PACKAGES and type(value.get("version_code")) is int:
            result.add((package, value["version_code"]))
        for key, child in value.items():
            result.update(recorded_codes(child, key if key in PACKAGES else package))
    elif isinstance(value, list):
        for child in value:
            result.update(recorded_codes(child, package))
    return result


def validate_ledger(value, receipt, manifests, installed, observed, candidates, revision):
    require(value.get("format") == "alkion-android-version-ledger/1" and value.get("complete") is True and
            value.get("coverage") == "all-attempted-and-reserved-in-disposable-run" and
            all(value.get(key) == receipt[key] for key in ("run_id", "serial", "avd")) and
            value.get("manifest_sha256") == manifests and isinstance(value.get("entries"), list),
            "complete_restore_version_ledger_required")
    seen, matched, floor = set(), set(), 44
    for entry in value["entries"]:
        require(isinstance(entry, dict) and entry.get("application_id") in PACKAGES and
                type(entry.get("version_code")) is int and 0 < entry["version_code"] <= MAX_VERSION and
                entry.get("state") in ("reserved", "attempted", "built", "installed", "failed") and
                hexadecimal(entry.get("source_commit"), 40) and isinstance(entry.get("role"), str) and
                bool(entry["role"].strip()), "restore_version_ledger_entry_invalid")
        identity = (entry["application_id"], entry["version_code"])
        require(identity not in seen, "restore_version_ledger_reused_code")
        seen.add(identity)
        candidate = candidates.get(entry["application_id"])
        if candidate and entry["version_code"] == candidate[1]["version_code"]:
            require(entry["state"] == "built" and entry["role"] == "fresh-receiving-restore" and
                    entry["source_commit"] == revision and entry.get("apk_sha256") == candidate[1]["apk_sha256"],
                    "restore_candidate_ledger_reservation_mismatch")
            matched.add(entry["application_id"])
        else:
            floor = max(floor, entry["version_code"])
    require(recorded_codes(installed) | observed <= seen, "restore_ledger_omits_recorded_version")
    require(matched == set(VARIANTS.values()) and len({facts["version_code"] for _, facts in candidates.values()}) == 1 and
            all(facts["version_code"] > floor for _, facts in candidates.values()),
            "restore_candidate_not_after_complete_version_floor")
    return floor


def restore_build_arguments(environment):
    flavor, run, revision, version = (environment.get(key, "") for key in
        ("ALKION_FLAVOR", "ALKION_PROOF_RUN", "ALKION_PROOF_SOURCE", "ALKION_PROOF_VERSION"))
    require(flavor in VARIANTS and hexadecimal(run, 32) and hexadecimal(revision, 40) and
            isinstance(version, str) and re.fullmatch(r"[0-9]{1,10}", version) and 0 < int(version) <= MAX_VERSION,
            "explicit_restore_build_inputs_required")
    return ["fvm", "flutter", "build", "apk", "--debug", "--no-pub", "--flavor", flavor,
            "--target-platform", "android-x64", "--target", "integration_test/android_restore_test.dart",
            "--build-number", version, "--dart-define=ALKION_PROOF_RUN=" + run,
            "--dart-define=ALKION_PROOF_SOURCE=" + revision]


@dataclass
class BuildPrepared:
    args: object
    receipt: dict
    output: Path
    revision: str
    version: int
    floor: int
    ledger_path: Path
    pins: dict
    driver: dict
    argv: dict


@timeout_context("prepare-build")
def prepare_pair_build(host, args, environment):
    """Validate the immutable reserved pair; allocate no versions or device work."""
    receipt, output = host.receipt_guard(args)
    require(all(getattr(args, name, None) for name in
                ("source_manifest", "receiver_driver", "source_review", "version_ledger")),
            "explicit_restore_pair_build_inputs_required")
    revision = environment.get("ALKION_PROOF_SOURCE", "")
    argv = {flavor: restore_build_arguments({**environment, "ALKION_FLAVOR": flavor}) for flavor in VARIANTS}
    require(environment.get("ALKION_PROOF_RUN") == receipt["run_id"] and revision != "0" * 40 and
            documents.source(host) == revision, "restore_build_source_or_run_mismatch")
    version = int(environment["ALKION_PROOF_VERSION"])
    require(environment["ALKION_PROOF_VERSION"] == str(version), "canonical_restore_build_version_required")
    pins = {}
    source, paths, _, source_attempts = source_inputs(host, args, args.source_manifest, pins)
    driver, driver_path = local(host, args.receiver_driver, pins)
    require(host.driver_continuation_contract(driver, receipt) == "alkion-driver/2" and
            source["disposable"]["run_id"] != receipt["run_id"] and source["disposable"]["avd"] != receipt["avd"],
            "separate_fresh_receiver_build_chain_required")
    source_review(host, args, {source["documents"]["source_commit"], driver["source_commit"]}, revision, pins)
    manifests = {str(path): digest(pins[path]) for path in (*paths.values(), driver_path)}
    observed = recorded_codes(source) | recorded_codes(source_attempts) | recorded_codes(driver)
    require(isinstance(args.attempt_manifests, (list, tuple)), "explicit_receiver_attempt_manifest_list_required")
    for value in args.attempt_manifests:
        attempted, path = local(host, value, pins)
        require(all(attempted.get(key) == receipt[key] for key in ("run_id", "serial", "avd")) and
                str(path) not in manifests, "receiver_build_attempt_identity_or_duplicate")
        manifests[str(path)] = digest(pins[path])
        observed |= recorded_codes(attempted)
    ledger, ledger_path = local(host, args.version_ledger, pins)
    require(ledger.get("format") == "alkion-android-version-ledger/1" and ledger.get("complete") is True and
            ledger.get("coverage") == "all-attempted-and-reserved-in-disposable-run" and
            all(ledger.get(key) == receipt[key] for key in ("run_id", "serial", "avd")) and
            ledger.get("manifest_sha256") == manifests and isinstance(ledger.get("entries"), list),
            "complete_restore_allocation_ledger_required")
    seen, matched, floor = set(), set(), 44
    for entry in ledger["entries"]:
        require(isinstance(entry, dict) and entry.get("application_id") in PACKAGES and
                type(entry.get("version_code")) is int and 0 < entry["version_code"] <= MAX_VERSION and
                entry.get("state") in ("reserved", "attempted", "built", "installed", "failed") and
                hexadecimal(entry.get("source_commit"), 40) and isinstance(entry.get("role"), str) and
                bool(entry["role"].strip()), "restore_allocation_entry_invalid")
        pair = entry["application_id"], entry["version_code"]
        require(pair not in seen, "restore_allocation_reused_code")
        seen.add(pair)
        if pair[0] in VARIANTS.values() and pair[1] == version:
            require(entry["state"] == "reserved" and entry["role"] == "fresh-receiving-restore" and
                    entry["source_commit"] == revision and "apk_sha256" not in entry,
                    "restore_exact_unbuilt_reservations_required")
            matched.add(pair[0])
        else:
            floor = max(floor, pair[1])
    require(observed <= seen and matched == set(VARIANTS.values()) and version > floor and
            not any((package, version) in observed for package in VARIANTS.values()),
            "restore_reserved_pair_not_new_or_ledger_incomplete")
    # Retained bootstrap facts bind the expected signer without querying Android.
    for flavor, package in {"neighbor": PACKAGES[0], **VARIANTS}.items():
        path = driver_path.parent / ("neighbor-build/synthetic-neighbor.apk" if flavor == "neighbor" else "driver-" + flavor + ".apk")
        _, path = local(host, str(path), pins, bound=128 * LIMIT, json_value=False)
        require(host.apk_facts(args, path, package) == driver["installed"][package], "restore_build_bootstrap_apk_changed")
    host.toolchain(args)
    check_pins(pins)
    return BuildPrepared(args, receipt, output, revision, version, floor, ledger_path, pins, driver, argv)


@timeout_context("build")
def build_pair(host, prepared):
    """Produce the exact paired manifest; never rewrite the allocation ledger."""
    check_pins(prepared.pins)
    require(documents.source(host) == prepared.revision, "restore_source_changed_before_pair_build")
    output = prepared.output
    output.mkdir(mode=0o700)
    context = {"format": "alkion-restore-build-attempt/1", **{key: prepared.receipt[key] for key in ("run_id", "serial", "avd")},
               "source_commit": prepared.revision, "allocation_floor": prepared.floor,
               "reservation_ledger": str(prepared.ledger_path),
               "reservation_ledger_sha256": digest(prepared.pins[prepared.ledger_path])}
    exclusive(output / "original-reservation-ledger.json", prepared.pins[prepared.ledger_path])
    exclusive(output / "input-pins.json", encoded({str(path): digest(raw) for path, raw in prepared.pins.items()}))
    manifest = {"format": "alkion-restore-build/1", "run_id": prepared.receipt["run_id"],
                "source_commit": prepared.revision, "steps": list(STEPS), "variants": {}}
    attempted = []
    try:
        for flavor, package in VARIANTS.items():
            check_pins(prepared.pins)
            require(documents.source(host) == prepared.revision, "restore_source_changed_before_variant_build")
            source = host.APP / "build/app/outputs/flutter-apk" / ("app-" + flavor + "-debug.apk")
            previous = None
            if source.exists() or source.is_symlink():
                require(source.is_file() and all(not path.is_symlink() for path in (source, *source.parents)) and
                        source.stat().st_uid == os.getuid() and 0 < source.stat().st_size <= 128 * LIMIT,
                        "restore_previous_build_output_not_bounded_regular")
                previous = digest(source.read_bytes())
            header = {**context, "variant": flavor, "application_id": package, "version_code": prepared.version,
                      "role": "fresh-receiving-restore", "state": "attempted", "argv": prepared.argv[flavor],
                      "working_apk_sha256_before": previous}
            exclusive(output / (flavor + "-build-attempt.json"), encoded(header))
            attempted.append(header)
            built = host.command(prepared.argv[flavor], check=False, timeout=600, binary=True)
            exclusive(output / (flavor + "-build.stdout"), built.stdout)
            exclusive(output / (flavor + "-build.stderr"), built.stderr)
            require(built.returncode == 0, "restore_fvm_build_failed:" + flavor)
            check_pins(prepared.pins)
            require(documents.source(host) == prepared.revision, "restore_source_changed_during_variant_build")
            require(source.is_file() and all(not path.is_symlink() for path in (source, *source.parents)) and
                    source.stat().st_uid == os.getuid() and 0 < source.stat().st_size <= 128 * LIMIT,
                    "restore_fvm_artifact_not_bounded_regular")
            apk = output / (flavor + "-restore.apk")
            raw = source.read_bytes()
            require(0 < len(raw) <= 128 * LIMIT and digest(raw) != previous, "restore_fvm_output_missing_or_stale")
            exclusive(apk, raw)
            facts = host.apk_facts(prepared.args, apk, package)
            require(facts["version_code"] == prepared.version and facts["certificate_sha256"] ==
                    prepared.driver["installed"][package]["certificate_sha256"] and
                    digest(apk.read_bytes()) == facts["apk_sha256"], "restore_built_artifact_binding_mismatch")
            manifest["variants"][flavor] = {"apk": str(apk), "facts": facts, "argv": prepared.argv[flavor]}
        check_pins(prepared.pins)
        require(documents.source(host) == prepared.revision, "restore_source_changed_before_build_manifest")
        exclusive(output / "build.json", encoded(manifest))
        return manifest
    except Exception as error:
        if isinstance(error, subprocess.TimeoutExpired):
            for name, raw in (("stdout", error.stdout), ("stderr", error.stderr)):
                exclusive(output / ("build-timeout." + name),
                          raw if isinstance(raw, bytes) else raw.encode() if isinstance(raw, str) else b"")
        exclusive(output / "build-failure.json", encoded({**context, "result": "FAIL", "error": str(error),
            "attempted": attempted, "retained_variants": manifest["variants"], "completion": "No retry or ledger rewrite"}))
        raise


def source_review(host, args, bases, revision, pins):
    value, _ = local(host, args.source_review, pins)
    keys(value, ("format", "result", "source_commit", "transitions"), "restore_source_review_fields_invalid")
    require(value["format"] == "alkion-restore-source-review/1" and value["result"] == "PASS" and
            value["source_commit"] == revision and isinstance(value["transitions"], list),
            "restore_source_review_required")
    seen = set()
    for transition in value["transitions"]:
        keys(transition, ("base_source_commit", "source_commit", "changed_paths", "diff_sha256",
                          "review_receipt", "review_receipt_sha256"), "restore_source_transition_fields_invalid")
        base = transition["base_source_commit"]
        require(base in bases - {revision} and base not in seen and transition["source_commit"] == revision,
                "restore_source_transition_range_mismatch")
        seen.add(base)
        require(host.command(["git", "-C", host.APP, "merge-base", "--is-ancestor", base, revision],
                             check=False).returncode == 0, "restore_source_not_descendant")
        changed = host.command(["git", "-C", host.APP, "diff", "--name-only", base, revision]).stdout.splitlines()
        delta = host.command(["git", "-C", host.APP, "diff", "--binary", base, revision], binary=True).stdout
        require(changed == transition["changed_paths"] and len(set(changed)) == len(changed) and
                set(changed) <= ALLOWED_CHANGES and digest(delta) == transition["diff_sha256"],
                "restore_source_diff_unreviewed_or_runtime_change")
        review, path = local(host, transition["review_receipt"], pins)
        keys(review, ("format", "result", "reviewer", "base_source_commit", "source_commit", "changed_paths", "diff_sha256"),
             "restore_range_review_fields_invalid")
        require(digest(pins[path]) == transition["review_receipt_sha256"] and
                review["format"] == "alkion-independent-range-review/1" and review["result"] == "PASS" and
                isinstance(review["reviewer"], str) and bool(review["reviewer"].strip()) and
                all(review[key] == transition[key] for key in
                    ("base_source_commit", "source_commit", "changed_paths", "diff_sha256")),
                "independent_restore_range_review_required")
    require(seen == bases - {revision}, "restore_source_transition_missing")


def source_inputs(host, args, path, pins):
    manifest, _ = local(host, path, pins)
    keys(manifest, ("format", *SOURCE_KEYS, "variants", "attempt_manifests"), "restore_source_manifest_fields_invalid")
    require(manifest["format"] == "alkion-restore-source-inputs/1", "restore_source_manifest_format_invalid")
    keys(manifest["variants"], VARIANTS, "restore_source_variants_incomplete")
    values, paths = {}, {}
    for key in SOURCE_KEYS:
        values[key], paths[key] = local(host, manifest[key], pins)
    receipt, driver, updates, lifecycle, campaign = (values[key] for key in SOURCE_KEYS)
    require(receipt.get("format") == "alkion-android-disposable/1" and receipt.get("purpose") == "synthetic-only" and
            receipt.get("fresh") is True and hexadecimal(receipt.get("run_id"), 32) and receipt.get("api") == 36 and
            receipt.get("abi") == "x86_64" and receipt.get("system_image") == "system-images;android-36;default;x86_64",
            "source_disposable_identity_invalid")
    require(host.driver_continuation_contract(driver, receipt) == "alkion-driver/2", "source_current_driver_required")
    metadata = host.lifecycle_contract(updates, receipt)
    require(updates.get("base_driver_contract") == "alkion-driver/2", "source_a2_driver_changed")
    floor = documents.lifecycle_floor(lifecycle, updates, driver, receipt)
    require(campaign.get("format") == "alkion-android-run/1" and campaign.get("phase") == "documents-provider" and
            campaign.get("documents_phase") == "PASS" and campaign.get("overall") == "IN_PROGRESS" and
            not campaign.get("error") and campaign.get("base_source_commit") == lifecycle["source_commit"] and
            hexadecimal(campaign.get("source_commit"), 40) and
            all(campaign.get(key) == receipt[key] for key in ("run_id", "avd", "serial")),
            "actual_documents_campaign_required")
    keys(campaign.get("documents"), VARIANTS, "actual_documents_variants_required")
    keys(campaign.get("installed"), PACKAGES, "source_installed_set_invalid")
    provider = campaign.get("provider", {})
    require(provider.get("package") == PROVIDER and provider.get("version_code") == 1 and
            hexadecimal(provider.get("apk_sha256")) and provider.get("certificate_sha256") ==
            driver["installed"][PACKAGES[0]]["certificate_sha256"] and type(provider.get("uid")) is int and
            10000 <= provider["uid"] < 100000 and provider["uid"] not in {m["uid"] for m in metadata.values()},
            "source_provider_identity_missing")
    produced = {}
    for flavor, package in VARIANTS.items():
        item = manifest["variants"][flavor]
        keys(item, VARIANT_KEYS, "restore_source_variant_fields_invalid")
        report, report_path = local(host, item["report"], pins)
        receiving, receiving_path = local(host, item["receiving"], pins)
        saved, saved_path = local(host, item["provider_save_good"], pins)
        data, data_path = local(host, item["received"], pins, bound=LIMIT, json_value=False)
        control = {"format": "alkion-synthetic-documents/1", "run_id": receipt["run_id"], "variant": flavor,
                   "length": len(data), "sha256": digest(data)}
        require(128 * 1024 < len(data) <= LIMIT, "rich_source_backup_size_invalid")
        observed = report.get("provider_receipts", {})
        documents.validate_report(report, receipt["run_id"], campaign["source_commit"], flavor, control, observed)
        documents.validate_receiving_report(receiving, control)
        documents.validate_receipt(saved, "save-good", control)
        require(saved == observed.get("save-good"), "save_good_raw_receipt_changed")
        fixture = report.get("fixture", {})
        require(fixture.get("format") == "alkion-android-documents-fixture/1" and
                fixture.get("inventory") == receiving["inventory"] and
                hexadecimal(fixture.get("original", {}).get("sha256")) and
                fixture.get("original", {}).get("length") == 256 * 1024 and
                type(fixture.get("source_generation")) is int and fixture["source_generation"] > 0 and
                all(isinstance(fixture.get(key), str) and fixture[key] for key in
                    ("source_profile_id", "source_installation_id")) and
                set(fixture.get("ids", {})) == {"exercise", "day", "slot", "workout", "draft", "imported_day",
                                               "correction", "review", "import_artifact", "original"} and
                receiving.get("tool", {}).get("application_id") == package,
                "source_rich_fixture_binding_missing")
        current = campaign["documents"][flavor]
        output = current.get("provider_outputs", {}).get("save-good", {})
        require(current.get("report") == report and current.get("receiving") == receiving and
                current.get("normal_profiles_unchanged") is True and type(current.get("provider_pid")) is int and
                current["provider_pid"] > 0 and output.get("length") == len(data) and output.get("sha256") == digest(data) and
                re.fullmatch(r"save-good-[a-f0-9-]{36}[.]partial", output.get("name", "")),
                "source_save_good_campaign_binding_missing")
        _, apk_path = local(host, item["apk"], pins, bound=128 * LIMIT, json_value=False)
        facts = host.apk_facts(args, apk_path, package)
        require(facts == campaign["installed"][package] and facts["version_code"] > floor[package]["version_code"] and
                facts["certificate_sha256"] == floor[package]["certificate_sha256"], "source_documents_apk_changed")
        chain = {key: digest(pins[paths[key]]) for key in SOURCE_KEYS[:4]}
        chain.update(documents=digest(pins[report_path]), provider_save_good=digest(pins[saved_path]),
                     receiving=digest(pins[receiving_path]))
        produced[flavor] = {"data": data, "report": report, "receiving": receiving, "report_raw": pins[report_path],
                            "receiving_raw": pins[receiving_path], "chain": chain, "facts": facts,
                            "uid": metadata[package]["uid"], "received_path": data_path}
    require(campaign["installed"][PACKAGES[0]] == driver["installed"][PACKAGES[0]], "source_neighbor_changed")
    for flavor, package in VARIANTS.items():
        for relative, expected in ((paths["driver"].parent / ("driver-" + flavor + ".apk"), driver["installed"][package]),
                                   (paths["updates"].parent / (flavor + "-verify.apk"), updates["installed"][package]),
                                   (paths["lifecycle"].parent / (flavor + "-finish.apk"), floor[package])):
            _, retained = local(host, str(relative), pins, bound=128 * LIMIT, json_value=False)
            require(host.apk_facts(args, retained, package) == expected, "source_retained_campaign_apk_changed")
    _, neighbor = local(host, str(paths["driver"].parent / "neighbor-build/synthetic-neighbor.apk"),
                        pins, bound=LIMIT, json_value=False)
    require(host.apk_facts(args, neighbor, PACKAGES[0]) == driver["installed"][PACKAGES[0]], "source_retained_neighbor_changed")
    attempts = []
    require(isinstance(manifest["attempt_manifests"], list), "source_attempt_manifests_required")
    for value in manifest["attempt_manifests"]:
        attempted, attempted_path = local(host, value, pins)
        require(all(attempted.get(key) == receipt[key] for key in ("run_id", "serial", "avd")),
                "source_attempt_manifest_identity_mismatch")
        paths["attempt-" + str(len(attempts))] = attempted_path
        attempts.append(attempted)
    return values, paths, produced, attempts


@dataclass
class Prepared:
    args: object
    receipt: dict
    output: Path
    revision: str
    driver: dict
    installed: dict
    metadata: dict
    candidates: dict
    provider: tuple
    observer: tuple
    inputs: dict
    source: dict
    pins: dict
    ledger: dict
    floor: int


def native_identity(host, args, package, uid):
    value = documents.remote(host, args, package, 'id -u; pwd -P')
    require(value.returncode == 0 and not value.stderr and
            value.stdout.decode().splitlines() in ([str(uid), "/data/user/0/" + package],
                                                   [str(uid), "/data/data/" + package]),
            "receiver_run_as_identity_or_canonical_root_unknown")
    return {"uid": uid, "data_directory": value.stdout.decode().splitlines()[1],
            "support_root_relative": "files/" + package}


@timeout_context("prepare")
def prepare(host, args):
    receipt, output = host.receipt_guard(args)
    require((args.sdk / "platform-tools/adb").is_file(), "adb_required")
    for name in ("source_manifest", "receiver_driver", "version_ledger", "source_review", "candidate_manifest", "ui_observer_build",
                 "dev_apk", "supported_apk", "provider_apk"):
        require(getattr(args, name, None), "explicit_restore_inputs_required:" + name)
    pins = {}
    source, source_paths, inputs, attempts = source_inputs(host, args, args.source_manifest, pins)
    driver, driver_path = local(host, args.receiver_driver, pins)
    require(host.driver_continuation_contract(driver, receipt) == "alkion-driver/2", "fresh_receiver_current_driver_required")
    require(source["disposable"]["run_id"] != receipt["run_id"] and
            source["disposable"]["avd"] != receipt["avd"], "separate_fresh_receiver_required")
    revision = documents.source(host)
    source_review(host, args, {source["documents"]["source_commit"], driver["source_commit"]}, revision, pins)
    candidates = {}
    for flavor, package in VARIANTS.items():
        _, path = local(host, getattr(args, flavor + "_apk"), pins, bound=128 * LIMIT, json_value=False)
        facts = host.apk_facts(args, path, package)
        require(type(facts["version_code"]) is int and 44 < facts["version_code"] <= MAX_VERSION and
                facts["certificate_sha256"] == driver["installed"][package]["certificate_sha256"],
                "restore_candidate_version_or_signer_invalid")
        candidates[package] = (path, facts)
    build, build_path = local(host, args.candidate_manifest, pins)
    keys(build, ("format", "run_id", "source_commit", "steps", "variants"), "restore_build_manifest_fields_invalid")
    keys(build["variants"], VARIANTS, "restore_build_variants_required")
    require(build["format"] == "alkion-restore-build/1" and build["run_id"] == receipt["run_id"] and
            build["source_commit"] == revision and build["steps"] == list(STEPS), "restore_build_binding_invalid")
    for flavor, package in VARIANTS.items():
        item = build["variants"][flavor]
        keys(item, ("apk", "facts", "argv"), "restore_build_variant_fields_invalid")
        path, facts = candidates[package]
        expected = restore_build_arguments({"ALKION_FLAVOR": flavor, "ALKION_PROOF_RUN": receipt["run_id"],
            "ALKION_PROOF_SOURCE": revision, "ALKION_PROOF_VERSION": str(facts["version_code"])})
        require(item["apk"] == str(path) and item["facts"] == facts and item["argv"] == expected,
                "restore_retained_build_contract_changed")
    ledger, _ = local(host, args.version_ledger, pins)
    manifests = {str(path): digest(pins[path]) for path in (*source_paths.values(), driver_path, build_path)}
    receiver_attempts = getattr(args, "attempt_manifests", ())
    require(isinstance(receiver_attempts, (list, tuple)), "explicit_receiver_attempt_manifest_list_required")
    attempted_codes = set()
    for value in receiver_attempts:
        attempted, path = local(host, value, pins)
        require(all(attempted.get(key) == receipt[key] for key in ("run_id", "serial", "avd")),
                "receiver_attempt_manifest_identity_mismatch")
        require(str(path) not in manifests, "duplicate_restore_attempt_manifest")
        manifests[str(path)] = digest(pins[path])
        attempted_codes |= recorded_codes(attempted)
    floor = validate_ledger(ledger, receipt, manifests, driver["installed"],
                            recorded_codes(source) | recorded_codes(attempts) | attempted_codes, candidates, revision)
    _, provider_path = local(host, args.provider_apk, pins, bound=LIMIT, json_value=False)
    provider_facts = host.apk_facts(args, provider_path, PROVIDER)
    require(provider_facts["version_code"] == 1 and provider_facts["certificate_sha256"] ==
            driver["installed"][PACKAGES[0]]["certificate_sha256"] and
            provider_facts["apk_sha256"] == source["documents"]["provider"]["apk_sha256"],
            "receiver_provider_not_exact_source_artifact")
    tree = host.command([args.sdk / "build-tools/36.0.0/aapt2", "dump", "xmltree", provider_path,
                         "--file", "AndroidManifest.xml"]).stdout
    try:
        documents.validate_packaged_provider(tree)
    except documents.Refusal as error:
        raise Refusal("receiver_provider_not_default_disabled") from error
    observer, observer_path = local(host, args.ui_observer_build, pins)
    require(observer_path.name == "build.json" and observer_path.parent.name == "ui-observer" and
            callable(getattr(host, "ui_observer_validate_build", None)) and
            callable(getattr(host, "ui_observer_install_fresh", None)), "fresh_ui_observer_facade_required")
    keys(observer, ("format", "source_commit", "native_source_sha256", "apk"), "restore_observer_build_fields_invalid")
    require(observer["format"] == "alkion-android-ui-build/1" and observer["source_commit"] == revision and
            hexadecimal(observer["native_source_sha256"]), "restore_observer_source_binding_invalid")
    _, observer_apk = local(host, str(observer_path.parent / "synthetic-ui-observer.apk"), pins, bound=LIMIT, json_value=False)
    observer_root = observer_path.parent.parent
    require(host.ui_observer_validate_build(host, args, observer_root, observer) == observer_apk and
            observer["apk"]["certificate_sha256"] == driver["installed"][PACKAGES[0]]["certificate_sha256"],
            "restore_observer_artifact_changed")
    host.toolchain(args)
    host.device_platform_guard(args)
    host.installed_matches(args, driver["installed"])
    metadata = {}
    for package in PACKAGES:
        metadata[package] = host.package_metadata(args, package)
        require(metadata[package]["version_code"] == driver["installed"][package]["version_code"] and
                type(metadata[package]["uid"]) is int and 10000 <= metadata[package]["uid"] < 100000,
                "receiver_bootstrap_metadata_invalid")
        require(host.app_pid(args, package) is None, "receiver_bootstrap_requires_absent_processes")
        native_identity(host, args, package, metadata[package]["uid"])
        if package in VARIANTS.values():
            for relative in ("files/" + package, "files/." + package + "-fresh-restore", "files/android-restore-proof"):
                documents.absent(host, args, package, relative)
    require(len({v["uid"] for v in metadata.values()}) == 3, "receiver_uid_collision")
    for package in (PROVIDER, OBSERVER):
        query = host.adb(args, "shell", "pm", "path", package, check=False)
        require(query.returncode in (0, 1) and not query.stdout.strip() and not query.stderr.strip(),
                "fresh_receiver_helper_already_present:" + package)
    # Bind retained receiver driver/neighbor APK bytes as well as live digests.
    for flavor, package in {"neighbor": PACKAGES[0], **VARIANTS}.items():
        path = driver_path.parent / ("neighbor-build/synthetic-neighbor.apk" if flavor == "neighbor" else "driver-" + flavor + ".apk")
        _, path = local(host, str(path), pins, bound=128 * LIMIT, json_value=False)
        require(host.apk_facts(args, path, package) == driver["installed"][package], "receiver_retained_bootstrap_apk_changed")
    host.driver_neighbor_bytes(args, receipt, driver)
    check_pins(pins)
    return Prepared(args, receipt, output, revision, driver, dict(driver["installed"]), metadata,
                    candidates, (provider_path, provider_facts, tree), (observer_root, observer),
                    inputs, source, pins, ledger, floor)


class Evidence(documents.Evidence):
    def __init__(self, host, prepared):
        super().__init__(host, prepared)
        self.history = {flavor: [] for flavor in VARIANTS}

    def json(self, package, path, name, *, optional=False, bound=32768):
        raw = self.read(package, path, bound, name, optional=optional)
        return None if raw is None else parse(raw)

    def pointer(self, package, path, data):
        # Every pointer value also has an exclusive numbered archive. Only the
        # fixed current.json name is replaced; its previous bytes are checked.
        partial = path + ".partial-" + os.urandom(16).hex()
        self.write(package, partial, data, "current-pointer.json")
        result = documents.remote(self.host, self.prepared.args, package, documents.NO_LINKS +
                                  'test -f "$1" && test ! -L "$2" && '
                                  '(test ! -e "$2" || test -f "$2") || exit 4; mv -T "$1" "$2"', partial, path)
        self.keep("pointer-publication.json", {"code": result.returncode, "stderr": result.stderr.decode(errors="replace")})
        require(documents.quiet(result), "restore_pointer_publication_failed")
        require(self.read(package, path, 1024, "pointer-readback") == data, "restore_pointer_changed")


def protocol_root(prepared):
    return "files/android-restore-proof/" + prepared.receipt["run_id"]


def create_directory(evidence, package, path):
    documents.regular_relative(path)
    result = documents.remote(evidence.host, evidence.prepared.args, package, documents.NO_LINKS +
                              'umask 077; test ! -e "$1" && test ! -L "$1" || exit 4; mkdir -p -m 700 "$1"', path)
    evidence.keep("directory-publication.json", {"path": path, "code": result.returncode,
                                                "stderr": result.stderr.decode(errors="replace")})
    require(documents.quiet(result), "restore_fresh_directory_refused")


def tree_pin(evidence, package, root):
    documents.regular_relative(root)
    result = documents.remote(evidence.host, evidence.prepared.args, package, documents.NO_LINKS +
                              'test -e "$1" || exit 3; test -d "$1" || exit 4; '
                              'test -z "$(find "$1" -type l -print)" || exit 4; find "$1" -mindepth 1 -print', root)
    evidence.keep("tree-list.stdout", result.stdout)
    evidence.keep("tree-list.stderr", result.stderr)
    require(not result.stdout.startswith(documents.RUN_AS_DIAGNOSTIC), "restore_run_as_diagnostic:" + root)
    if result.returncode == 3 and not result.stdout and not result.stderr:
        return None
    require(result.returncode == 0 and not result.stderr and len(result.stdout) <= 65536, "restore_tree_inventory_failed")
    files = result.stdout.decode().splitlines()
    require(len(files) <= 512 and len(set(files)) == len(files), "restore_tree_inventory_bound")
    pins = {}
    for path in sorted(files):
        documents.regular_relative(path)
        require(path.startswith(root + "/"), "restore_tree_path_escaped")
        kind = documents.remote(evidence.host, evidence.prepared.args, package, documents.NO_LINKS +
                                'if test -d "$1"; then printf directory; elif test -f "$1"; then printf file; else exit 4; fi', path)
        evidence.keep("tree-kind.json", {"path": path, "code": kind.returncode,
                                        "stdout": kind.stdout.decode(errors="replace"), "stderr": kind.stderr.decode(errors="replace")})
        require(kind.returncode == 0 and not kind.stderr and kind.stdout in (b"directory", b"file"), "restore_tree_type_invalid")
        pins[path[len(root) + 1:]] = "directory" if kind.stdout == b"directory" else digest(
            evidence.read(package, path, LIMIT, "retained-tree-file"))
    return pins


def input_descriptor(prepared, flavor):
    item = prepared.inputs[flavor]
    other_flavor = next(name for name in VARIANTS if name != flavor)
    other = prepared.inputs[other_flavor]
    run, revision = prepared.receipt["run_id"], prepared.revision
    return {"format": "alkion-android-restore-input/1", "run_id": run, "source_commit": revision,
            "application_id": VARIANTS[flavor], "variant": flavor,
            "producer_run_id": prepared.source["disposable"]["run_id"],
            "producer_source_commit": prepared.source["documents"]["source_commit"],
            "length": len(item["data"]), "sha256": digest(item["data"]), "documents": item["report"],
            "receiving": item["receiving"], "proof_chain": item["chain"],
            "opposite": {"format": "alkion-android-opposite-input/1", "application_id": VARIANTS[other_flavor],
                "variant": other_flavor, "producer_run_id": prepared.source["disposable"]["run_id"],
                "producer_source_commit": prepared.source["documents"]["source_commit"],
                "length": len(other["data"]), "sha256": digest(other["data"]),
                "documents_sha256": digest(other["report_raw"]), "receiving_sha256": digest(other["receiving_raw"]),
                "proof_chain": other["chain"]}}


def ingress(evidence, flavor):
    prepared, package = evidence.prepared, VARIANTS[flavor]
    root = protocol_root(prepared)
    create_directory(evidence, package, root)
    other = prepared.inputs[next(name for name in VARIANTS if name != flavor)]
    files = {"input.json": encoded(input_descriptor(prepared, flavor)), "received.alkionbackup": prepared.inputs[flavor]["data"],
             "opposite.alkionbackup": other["data"], "opposite-documents.json": other["report_raw"],
             "opposite-receiving.json": other["receiving_raw"]}
    for name, raw in files.items():
        evidence.write(package, root + "/" + name, raw, flavor + "-" + name)
    return files


def immutable(evidence, flavor, files):
    for name, raw in files.items():
        require(evidence.read(VARIANTS[flavor], protocol_root(evidence.prepared) + "/" + name,
                              LIMIT, "immutable-ingress") == raw, "restore_ingress_changed")


def seed_provider(evidence, flavor, *, first):
    prepared = evidence.prepared
    run = prepared.receipt["run_id"]
    control = {"format": "alkion-synthetic-documents/1", "run_id": run, "variant": flavor,
               "length": len(prepared.inputs[flavor]["data"]), "sha256": digest(prepared.inputs[flavor]["data"])}
    root = "files/proof-runs/" + run + "-" + flavor
    stage = "files/proof-runs/.stage-" + run + "-" + flavor
    documents.absent(evidence.host, prepared.args, PROVIDER, root)
    create_directory(evidence, PROVIDER, stage)
    evidence.write(PROVIDER, stage + "/control.json", encoded(control), "receiver-provider-control.json")
    evidence.write(PROVIDER, stage + "/input.alkionbackup", prepared.inputs[flavor]["data"], "receiver-provider-input")
    require(evidence.read(PROVIDER, stage + "/control.json", 4096, "staged-provider-control") == encoded(control) and
            evidence.read(PROVIDER, stage + "/input.alkionbackup", LIMIT, "staged-provider-input") ==
            prepared.inputs[flavor]["data"], "receiver_provider_staged_bytes_changed")
    # The running provider watches only matching run-variant names. Publish the
    # complete namespace with one rename; failed staging/partials stay retained.
    published = documents.remote(evidence.host, prepared.args, PROVIDER, documents.NO_LINKS +
        'test -d "$1" && test ! -e "$2" && test ! -L "$2" || exit 4; '
        'n=0; for p in files/proof-runs/*; do test -e "$p" || continue; '
        'name="${p##*/}"; case "$name" in *-dev|*-supported) n=$((n+1));; *) exit 4;; esac; done; '
        'test "$n" -lt 16 || exit 6; mv -n "$1" "$2" && test ! -e "$1" && test -d "$2"', stage, root)
    evidence.keep("receiver-provider-publication.json", {"code": published.returncode,
        "stderr": published.stderr.decode(errors="replace"), "stage_relative": stage, "final_relative": root})
    require(documents.quiet(published), "receiver_provider_publication_refused")
    if first:
        evidence.native("shell", "cmd", "package", "unstop", "--user", "0", PROVIDER)
        documents.enable_provider(evidence)
    return control


def provider_pins(evidence, flavor, control, *, discovered):
    root = "files/proof-runs/" + control["run_id"] + "-" + flavor
    require(evidence.read(PROVIDER, root + "/control.json", 4096, "provider-control") == encoded(control) and
            digest(evidence.read(PROVIDER, root + "/input.alkionbackup", LIMIT, "provider-input")) == control["sha256"],
            "receiver_provider_input_changed")
    if discovered:
        evidence.provider_alive()
        expected = (control["run_id"] + "\n" + flavor + "\n" + str(control["length"]) + "\n" + control["sha256"]).encode()
        require(evidence.read(PROVIDER, root + "/input.pin", 4096, "provider-pin") == expected,
                "receiver_provider_namespace_pin_changed")


def request(evidence, flavor, sequence, files):
    history = evidence.history[flavor]
    require(sequence == len(history) + 1 and 1 <= sequence <= len(STEPS), "restore_host_sequence_invalid")
    root = protocol_root(evidence.prepared)
    package = VARIANTS[flavor]
    if sequence > 1:
        require(evidence.read(package, root + "/current.json", 1024, "prior-pointer") == history[-1]["pointer"],
                "restore_prior_pointer_changed")
    for index, prior in enumerate(history, 1):
        for kind in ("request", "receipt"):
            require(evidence.read(package, root + "/" + kind + "-" + str(index).zfill(3) + ".json", LIMIT,
                                  "prior-" + kind) == prior[kind], "restore_prior_hash_chain_changed")
        documents.absent(evidence.host, evidence.prepared.args, package, root + "/failure-" + str(index).zfill(3) + ".json")
    value = {"format": "alkion-android-restore-request/1", "run_id": evidence.prepared.receipt["run_id"],
             "source_commit": evidence.prepared.revision, "application_id": package, "variant": flavor,
             "sequence": sequence, "action": STEPS[sequence - 1], "input_sha256": digest(files["input.json"]),
             "prior_receipt_sha256": digest(history[-1]["receipt"]) if history else None}
    raw = encoded(value)
    label = str(sequence).zfill(3)
    evidence.write(package, root + "/request-" + label + ".json", raw, flavor + "-request-" + label + ".json")
    pointer = encoded({"format": "alkion-android-restore-pointer/1", "sequence": sequence, "request_sha256": digest(raw)})
    evidence.pointer(package, root + "/current.json", pointer)
    return value, raw, pointer


def envelope(value, prepared, flavor, sequence, request_raw, files, pid, *, picker=False):
    require(all(value.get(key) == expected for key, expected in {
        "run_id": prepared.receipt["run_id"], "source_commit": prepared.revision,
        "application_id": VARIANTS[flavor], "variant": flavor, "sequence": sequence,
        "action": STEPS[sequence - 1], "request_sha256": digest(request_raw),
        "input_sha256": digest(files["received.alkionbackup"] if picker else files["input.json"]), "pid": pid}.items()),
        "restore_native_adapter_identity_or_compile_binding_mismatch")
    require(type(value.get("pid")) is int and pid > 1, "restore_native_pid_invalid")


def covered_inventory(snapshot):
    keys(snapshot, ("tables", "keys"), "restore_complete_baseline_missing")
    require(isinstance(snapshot["tables"], dict) and set(snapshot["tables"]) == documents.RECEIVING_TABLES and
            isinstance(snapshot["keys"], dict) and set(snapshot["keys"]) == documents.RECEIVING_TABLES,
            "restore_complete_covered_tables_missing")
    tables = {}
    for name, rows in snapshot["tables"].items():
        require(isinstance(rows, list) and all(isinstance(row, dict) for row in rows) and
                isinstance(snapshot["keys"][name], list) and all(isinstance(key, str) for key in snapshot["keys"][name]),
                "restore_covered_rows_or_keys_invalid")
        raw = json.dumps(rows, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False).encode()
        tables[name] = {"rows": len(rows), "sha256": digest(raw)}
    hashes = {name: value["sha256"] for name, value in tables.items()}
    return {"tables": tables, "rows": sum(value["rows"] for value in tables.values()),
            "sha256": digest(json.dumps(hashes, sort_keys=True, separators=(",", ":")).encode())}


def validate_fresh(evidence, flavor, value, sequence):
    keys(value, ("preparation_base64", "stages", "pending_id", "can_complete", *( ("intent",) if sequence >= 5 else ())),
         "restore_fresh_snapshot_fields_invalid")
    try:
        preparation = base64.b64decode(value["preparation_base64"], validate=True)
    except (ValueError, TypeError):
        raise Refusal("restore_preparation_base64_invalid") from None
    require(0 < len(preparation) <= 16384 and isinstance(value["stages"], dict) and
            isinstance(value["pending_id"], str) and value["pending_id"] and
            value["can_complete"] is (sequence >= 5), "restore_fresh_snapshot_invalid")
    package, root = VARIANTS[flavor], "files/" + VARIANTS[flavor]
    actual = evidence.read(package, "files/." + package + "-fresh-restore/preparation.json", 16384, "immutable-preparation")
    require(actual == preparation, "restore_preparation_bytes_changed")
    native = tree_pin(evidence, package, root) or {}
    stages = {path: sha for path, sha in native.items() if path.split("/")[-1] in ("alkion.sqlite", "intent.json")}
    require(stages == value["stages"] and "local-profile.json" not in native, "restore_stage_or_early_identity_changed")
    prior = evidence.history[flavor]
    if len(prior) >= 3:
        previous = prior[-1]["value"]["evidence"]["fresh"]
        require(previous["preparation_base64"] == value["preparation_base64"] and
                all(value["stages"].get(path) == sha for path, sha in previous["stages"].items()),
                "restore_preparation_or_prior_stage_not_preserved")
        if sequence >= 6:
            require(previous["pending_id"] == value["pending_id"], "restore_completed_pending_id_changed")
    if sequence >= 5:
        require(isinstance(value["intent"], dict) and value["intent"].get("restore_id") == value["pending_id"],
                "restore_pending_intent_id_changed")


def retained_after_adoption(evidence, flavor, fresh):
    """Keep every preparation/intent/orphan pin; only the selected DB may write."""
    package = VARIANTS[flavor]
    preparation = base64.b64decode(fresh["preparation_base64"], validate=True)
    require(evidence.read(package, "files/." + package + "-fresh-restore/preparation.json", 16384,
                          "retained-preparation-after-adoption", optional=True) == preparation,
            "restore_retained_preparation_changed_after_adoption")
    intent = fresh["intent"]
    profile, restore_id = intent.get("profile_id"), intent.get("restore_id")
    require(isinstance(profile, str) and re.fullmatch(r"[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}", profile) and
            isinstance(restore_id, str) and re.fullmatch(r"rs-[a-f0-9]{32}", restore_id) and
            fresh["pending_id"] == restore_id and
            isinstance(intent.get("staged"), dict) and
            intent["staged"].get("database") == "generations/" + restore_id + "/alkion.sqlite",
            "restore_selected_database_pin_unbound")
    selected = "profiles/" + profile + "/" + intent["staged"]["database"]
    require(selected in fresh["stages"] and hexadecimal(fresh["stages"][selected]),
            "restore_selected_database_not_in_retained_stages")
    root = "files/" + package
    marker = evidence.read(package, root + "/profiles/" + profile + "/selected-generation.json", 4096,
                           "retained-selected-generation")
    require(parse(marker) == {"format": "alkion-selected-generation", "version": 1, "restore_id": restore_id},
            "restore_actual_selected_generation_changed")
    native = tree_pin(evidence, package, root) or {}
    stages = {path: sha for path, sha in native.items() if path.split("/")[-1] in ("alkion.sqlite", "intent.json")}
    require(set(stages) == set(fresh["stages"]) and hexadecimal(stages.get(selected)) and
            all(stages[path] == sha for path, sha in fresh["stages"].items() if path != selected),
            "restore_retained_intent_or_orphan_changed_after_adoption")
    return {"preparation_sha256": digest(preparation), "selected_database_relative": selected,
            "selected_database_sha256": stages[selected], "selection_sha256": digest(marker),
            "immutable_stages": {path: sha for path, sha in stages.items() if path != selected}}


def validate_terminal(value, sequence, history):
    require(value.get("format") == "alkion-android-restore-proof/1" and value.get("complete") is True and
            value.get("closed") is True and value.get("result") == "PASS" and not value.get("error") and
            not value.get("failures") and isinstance(value.get("evidence"), dict) and
            set(UNRUN) - {"physical_off_device_verification"} <= set(value.get("unrun", [])),
            "restore_terminal_not_closed_pass")
    detail = value["evidence"]
    if sequence == 1:
        require(detail.get("input_verified") is True, "restore_preflight_not_verified")
    elif sequence == 2:
        keys(detail.get("cases"), REFUSALS, "restore_refusal_cases_missing")
        for case, expected in REFUSALS.items():
            item = detail["cases"][case]
            require(isinstance(item, dict) and item.get("result") == "PASS" and item.get("outcome") == expected and
                    item.get("preserved") is True, "restore_refusal_not_preserved:" + case)
    elif sequence >= 9:
        baseline = detail.get("baseline")
        require(covered_inventory(baseline) == detail.get("inventory"), "restore_covered_inventory_mismatch")
        if sequence == 9:
            prior = history[-1]["value"]["evidence"]["fresh"]
            require(detail.get("fresh") == prior and detail.get("observed_pins_before_first_store_open") ==
                    {key: prior[key] for key in ("preparation_base64", "stages")} and
                    isinstance(detail.get("closed_restore"), dict), "restore_final_retained_pins_not_observed")
            covered_inventory(detail["closed_restore"])
        else:
            require(baseline == history[-1]["value"]["evidence"]["baseline"], "restore_cold_baseline_changed")
            if sequence == 10:
                require(detail.get("outcome") == "restore_not_pending" and detail.get("unchanged") is True and
                        detail.get("resolved_id") == history[-1]["value"]["evidence"]["fresh"]["pending_id"],
                        "restore_completed_callback_not_refused")
            else:
                require(detail.get("cold_process") is True and detail.get("previous_pid") == history[-1]["value"]["pid"],
                        "restore_two_cold_processes_not_proven")


def await_receipt(evidence, flavor, sequence, request_raw, files, pid, control):
    root, package = protocol_root(evidence.prepared), VARIANTS[flavor]
    label, deadline, picked = str(sequence).zfill(3), time.monotonic() + 150, False
    provider_events = None
    if sequence in (3, 4, 5):
        previous = evidence.json(PROVIDER, "files/proof-runs/" + control["run_id"] + "-" + flavor + "/receipts/open-good.json",
                                 "prior-open-good", optional=True, bound=16384)
        provider_events = [] if previous is None else previous["events"]
    while time.monotonic() < deadline:
        failure = evidence.read(package, root + "/failure-" + label + ".json", JSON_LIMIT, "framework-failure", optional=True)
        require(failure is None, "restore_framework_failure_preserved")
        raw = evidence.read(package, root + "/receipt-" + label + ".json", LIMIT, "adapter-receipt", optional=True)
        if raw is not None:
            value = parse(raw)
            envelope(value, evidence.prepared, flavor, sequence, request_raw, files, pid)
            if 3 <= sequence <= 8:
                require(value.get("format") == "alkion-android-restore-checkpoint/1" and value.get("result") == "BARRIER" and
                        value.get("complete") is False and value.get("closed") is False and value.get("death_proven") is False,
                        "restore_barrier_is_not_death_proof")
                require(sequence not in (3, 4, 5) or picked, "restore_barrier_before_actual_picker")
                validate_fresh(evidence, flavor, value.get("evidence", {}).get("fresh"), sequence)
            else:
                validate_terminal(value, sequence, evidence.history[flavor])
            return raw, value
        if sequence in (3, 4, 5) and not picked:
            picker = evidence.json(package, root + "/picker-" + label + ".json", "adapter-picker", optional=True)
            if picker is not None:
                envelope(picker, evidence.prepared, flavor, sequence, request_raw, files, pid, picker=True)
                require(picker.get("format") == "alkion-android-restore-picker/1", "restore_picker_format_invalid")
                phase = {"variant": flavor, "case": "open-good", "root_label": "Alkion synthetic " + control["run_id"] + "-" + flavor,
                         "document_label": control["run_id"] + "-" + flavor + "-open-good.alkionbackup"}
                documents.drive_picker(evidence, phase)
                deadline_read = time.monotonic() + 15
                while True:
                    observed = documents.provider_observation(evidence, flavor, phase, control)["provider_receipt"]
                    events = observed["events"]
                    if events != provider_events:
                        break
                    require(time.monotonic() < deadline_read, "restore_picker_fresh_read_timeout")
                    time.sleep(0.1)
                require(events[:len(provider_events)] == provider_events and len(events) == len(provider_events) + 1 and
                        events[-1].get("operation") == "read" and events[-1].get("state") == "complete" and
                        events[-1].get("reliable_pipe") is True and events[-1].get("length") == control["length"] and
                        events[-1].get("sha256") == control["sha256"], "restore_picker_fresh_read_not_proven")
                picked = True
        time.sleep(0.1)
    raise Refusal("restore_adapter_receipt_timeout:" + STEPS[sequence - 1])


def process_identity(evidence, package, pid, uid, *, timeout=60):
    result = evidence.native("shell", "sh", "-c", evidence.host.PROCESS_IDENTITY_SCRIPT,
                             "alkion-restore-process", str(pid), check=False, timeout=timeout)
    require(result.returncode == 0 and not result.stderr, "restore_native_process_read_failed")
    return evidence.host.parse_process_identity(result.stdout, pid, uid)


def interrupt(evidence, flavor, value, launched_identity):
    started = time.monotonic()
    deadline = started + 30
    package, pid = VARIANTS[flavor], value["pid"]
    uid = evidence.prepared.metadata[package]["uid"]
    before, observations, kill_requested = None, [], False
    def remaining():
        seconds = deadline - time.monotonic()
        require(seconds > 0, "restore_exact_sigkill_death_timeout")
        return seconds
    def package_pid():
        observed = evidence.host.app_pid(evidence.prepared.args, package, timeout=remaining())
        remaining()
        return observed
    def identity():
        observed = process_identity(evidence, package, pid, uid, timeout=remaining())
        remaining()
        return observed
    try:
        require(package_pid() == pid, "restore_cut_package_pid_changed")
        before = identity()
        require(before is not None and before == launched_identity, "restore_cut_requires_same_launched_owned_process")
        # All gates and the exact kill consume the same entry-time budget.
        require(package_pid() == pid and identity() == before, "restore_cut_identity_changed")
        kill_requested = True
        killed = evidence.native("shell", "run-as", package, "/system/bin/kill", "-9", str(pid),
                                 check=False, timeout=remaining())
        remaining()
        require(killed.returncode == 0 and not killed.stdout.strip() and not killed.stderr.strip(), "restore_exact_sigkill_failed")
        while True:
            observed_pid = package_pid()
            observed_identity = identity()
            after = package_pid()
            observations.append({"package_pid_before": observed_pid, "identity": observed_identity, "package_pid_after": after})
            require(observed_pid in (None, pid) and after in (None, pid) and observed_identity in (None, before),
                    "restore_cut_replacement_or_pid_reuse")
            if observed_identity is None and after is None:
                elapsed = time.monotonic() - started
                require(elapsed < 30, "restore_exact_sigkill_death_timeout")
                result = {"format": "alkion-restore-process-death/1", "method": "run-as-owned-pid-SIGKILL",
                    "application_id": package, "sequence": value["sequence"], "request_sha256": value["request_sha256"],
                    "identity": before, "observations": observations, "elapsed_seconds": elapsed,
                    "budget_seconds": 30, "death_proven": True}
                evidence.keep(flavor + "-death.json", result)
                return result
            time.sleep(min(0.1, remaining()))
    except Exception as error:
        evidence.keep(flavor + "-death-uncertain.json", {"format": "alkion-restore-process-death/1",
            "application_id": package, "sequence": value["sequence"], "request_sha256": value["request_sha256"],
            "identity": before, "observations": observations, "elapsed_seconds": time.monotonic() - started,
            "budget_seconds": 30, "kill_requested": kill_requested, "death_proven": False, "error": str(error)})
        if isinstance(error, subprocess.TimeoutExpired):
            for name, raw in (("stdout", error.stdout), ("stderr", error.stderr)):
                evidence.keep(flavor + "-cut-timeout." + name,
                              raw if isinstance(raw, bytes) else raw.encode() if isinstance(raw, str) else b"")
        raise


@timeout_context("run")
def run(host, prepared):
    args, output = prepared.args, prepared.output
    check_pins(prepared.pins)  # Before allocation, mkdir, install or any mutation.
    require(documents.source(host) == prepared.revision, "restore_source_changed_after_prepare")
    host.device_platform_guard(args)
    host.installed_matches(args, prepared.installed)
    for package in PACKAGES:
        require(host.package_metadata(args, package) == prepared.metadata[package] and host.app_pid(args, package) is None,
                "restore_receiver_changed_after_prepare")
    output.mkdir(mode=0o700)
    evidence = Evidence(host, prepared)
    state = {"format": "alkion-android-run/1", "phase": "fresh-receiving-restore", "overall": "IN_PROGRESS",
             "restore_phase": "IN_PROGRESS", "run_id": prepared.receipt["run_id"], "serial": args.serial, "avd": args.avd,
             "source_commit": prepared.revision, "source_producer_commit": prepared.source["documents"]["source_commit"],
             "installed": dict(prepared.installed), "variants": {}, "unrun": list(UNRUN),
             "allocation_floor": prepared.floor,
             "installed_floor": max(facts["version_code"] for facts in prepared.installed.values())}
    def save():
        raw = encoded(state)
        evidence.keep("run-snapshot.json", raw)
        partial = output / "run.partial"
        exclusive(partial, raw)
        partial.replace(output / "run.json")
    def identities():
        check_pins(prepared.pins)
        host.device_platform_guard(args)
        host.installed_matches(args, state["installed"])
        for package in PACKAGES:
            expected = {"uid": prepared.metadata[package]["uid"], "version_code": state["installed"][package]["version_code"]}
            require(host.package_metadata(args, package) == expected, "restore_receiver_uid_or_version_changed")
            evidence.keep("run-as-root.json", native_identity(host, args, package, expected["uid"]))
    save()
    try:
        for index, (path, raw) in enumerate(prepared.pins.items()):
            evidence.keep("pinned-" + str(index).zfill(3) + "-" + path.name, raw)
        evidence.keep("receiver-disposable.json", prepared.receipt)
        evidence.keep("provider-packaged-manifest.txt", prepared.provider[2].encode())
        reservations = [entry for entry in prepared.ledger["entries"] if entry["application_id"] in prepared.candidates and
                        entry["version_code"] == prepared.candidates[entry["application_id"]][1]["version_code"]]
        evidence.keep("candidate-ledger-bindings.json", {"format": "alkion-restore-candidate-ledger-bindings/1",
            "base_ledger_sha256": digest(next(raw for path, raw in prepared.pins.items() if str(path) == str(Path(args.version_ledger)))),
            "allocation_floor": prepared.floor, "entries": reservations})
        originals = host.driver_neighbor_bytes(args, prepared.receipt, prepared.driver)
        driver_pins = {package: tree_pin(evidence, package, "files/android-proof/" + prepared.receipt["run_id"])
                       for package in VARIANTS.values()}
        completed, retained = {}, {}
        provider_path, provider_facts, _ = prepared.provider
        identities()
        observer_root, observer_build = prepared.observer
        binding = host.ui_observer_install_fresh(host, args, prepared.receipt, observer_root,
                                                 observer_build, prepared.revision)
        require(isinstance(binding, dict) and binding.get("format") == "alkion-android-ui-binding/1" and
                binding.get("build") == observer_build and
                all(binding.get(key) == prepared.receipt[key] for key in ("run_id", "serial", "avd")) and
                type(binding.get("uid")) is int and 10000 <= binding["uid"] < 100000 and
                binding["uid"] not in {value["uid"] for value in prepared.metadata.values()} and
                getattr(args, "_ui_observer", None) == (binding, prepared.revision),
                "fresh_receiver_observer_binding_invalid")
        state["ui_observer"] = binding
        save()
        query = evidence.native("shell", "pm", "path", PROVIDER, check=False)
        require(query.returncode in (0, 1) and not query.stdout.strip() and not query.stderr.strip(), "receiver_provider_appeared")
        installed = evidence.native("install", "-t", provider_path, check=False)
        require(installed.returncode == 0 and installed.stdout.strip() == "Success" and not installed.stderr.strip(), "restore_provider_install_failed")
        provider_meta = host.package_metadata(args, PROVIDER)
        require(provider_meta["version_code"] == 1 and type(provider_meta["uid"]) is int and
                10000 <= provider_meta["uid"] < 100000 and provider_meta["uid"] not in
                {v["uid"] for v in prepared.metadata.values()} | {binding["uid"]},
                "receiver_provider_uid_invalid")
        native_identity(host, args, PROVIDER, provider_meta["uid"])
        documents.provider_installed(evidence, provider_facts, provider_meta["uid"])
        for index, (flavor, package) in enumerate(VARIANTS.items()):
            identities()
            require(host.app_pid(args, package) is None, "restore_install_requires_absent_process")
            for root in ("files/" + package, "files/." + package + "-fresh-restore", "files/android-restore-proof"):
                documents.absent(host, args, package, root)
            candidate, facts = prepared.candidates[package]
            result = evidence.native("install", "-r", candidate, check=False)
            require(result.returncode == 0 and result.stdout.strip() == "Success" and not result.stderr.strip(), "restore_adapter_install_failed")
            state["installed"][package] = facts
            save()
            identities()
            files = ingress(evidence, flavor)
            control = seed_provider(evidence, flavor, first=index == 0)
            state["variants"][flavor] = {"steps": [], "cuts": [], "build_contract": restore_build_arguments({
                "ALKION_FLAVOR": flavor, "ALKION_PROOF_RUN": prepared.receipt["run_id"],
                "ALKION_PROOF_SOURCE": prepared.revision, "ALKION_PROOF_VERSION": str(facts["version_code"])})}
            for sequence, action in enumerate(STEPS, 1):
                identities()
                documents.provider_installed(evidence, provider_facts, provider_meta["uid"])
                provider_pins(evidence, flavor, control, discovered=sequence >= 4)
                immutable(evidence, flavor, files)
                require(host.app_pid(args, package) is None, "restore_cold_launch_requires_absent_prior_process")
                _, raw_request, pointer = request(evidence, flavor, sequence, files)
                started = evidence.native("shell", "am", "start", "-W", "--user", "0", "-n", package + "/dev.animusstudio.alkion.MainActivity", check=False)
                require(started.returncode == 0 and not started.stderr.strip() and "Status: ok" in started.stdout,
                        "restore_native_launch_failed")
                pid = host.app_pid(args, package)
                require(type(pid) is int and pid not in {item["value"]["pid"] for item in evidence.history[flavor]},
                        "restore_distinct_cold_pid_required")
                identity = process_identity(evidence, package, pid, prepared.metadata[package]["uid"])
                require(identity is not None, "restore_launch_owned_process_missing")
                raw, value = await_receipt(evidence, flavor, sequence, raw_request, files, pid, control)
                immutable(evidence, flavor, files)
                evidence.history[flavor].append({"request": raw_request, "receipt": raw, "pointer": pointer, "value": value})
                state["variants"][flavor]["steps"].append(value)
                save()
                if 3 <= sequence <= 8:
                    state["variants"][flavor]["cuts"].append(interrupt(evidence, flavor, value, identity))
                elif host.app_pid(args, package) is not None:
                    require(host.app_pid(args, package) == pid and
                            process_identity(evidence, package, pid, prepared.metadata[package]["uid"]) == identity,
                            "restore_terminal_process_changed")
                    host.ordinary_kill(args, package, prepared.metadata[package]["uid"], output)
                require(host.app_pid(args, package) is None, "restore_prior_process_remains")
                if sequence >= 9:
                    retained[package] = evidence.history[flavor][7]["value"]["evidence"]["fresh"]
                require(host.driver_neighbor_bytes(args, prepared.receipt, prepared.driver) == originals,
                        "restore_driver_or_neighbor_changed")
                for peer in VARIANTS.values():
                    require(tree_pin(evidence, peer, "files/android-proof/" + prepared.receipt["run_id"]) == driver_pins[peer],
                            "restore_driver_tree_changed")
                    if peer != package:
                        require(tree_pin(evidence, peer, "files/" + peer) == completed.get(peer), "restore_peer_root_changed")
                    if peer in retained:
                        peer_flavor = next(name for name, identity in VARIANTS.items() if identity == peer)
                        pins = retained_after_adoption(evidence, peer_flavor, retained[peer])
                        evidence.keep(peer_flavor + "-retained-after-" + flavor + "-" + str(sequence) + ".json", pins)
                save()
            require(len(state["variants"][flavor]["cuts"]) == 6, "restore_six_actual_cuts_required")
            completed[package] = tree_pin(evidence, package, "files/" + package)
            state["variants"][flavor]["result"] = "PASS"
            save()
        state["restore_phase"] = "PASS"
        state["pending"] = {"same_profile_replacement_and_keep": "UNRUN", "actual_old_notification_payload": "UNRUN"}
        save()
        return state
    except Exception as error:
        state["restore_phase"] = "FAIL"
        state["error"] = str(error)
        state["retention_errors"] = []
        if isinstance(error, subprocess.TimeoutExpired):
            for name, raw in (("stdout", error.stdout), ("stderr", error.stderr)):
                data = raw if isinstance(raw, bytes) else raw.encode() if isinstance(raw, str) else b""
                evidence.keep("timeout-partial-" + name, data)
            evidence.keep("transport-timeout.json", {"format": "alkion-restore-transport-timeout/1",
                "argv": list(map(str, error.cmd)) if isinstance(error.cmd, (list, tuple)) else str(error.cmd),
                "timeout_seconds": error.timeout, "completion": "UNKNOWN; no retry or repair"})
        # Retain bounded owned protocol trees, including malformed receipts and
        # closed partials. No cleanup, pointer advance, kill or restart on failure.
        for package in VARIANTS.values():
            try:
                tree_pin(evidence, package, protocol_root(prepared))
            except Exception as retained:
                state["retention_errors"].append(str(retained))
        try:
            tree_pin(evidence, PROVIDER, "files/proof-runs")
        except Exception as retained:
            state["retention_errors"].append(str(retained))
        save()
        raise
