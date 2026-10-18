"""Notification capability campaign imported by the guarded harness routes.

The harness supplies its existing receipt/path/toolchain/APK/UID/platform/A2,
process, ordinary_kill(args, package, uid, output), UI and native-mirror helpers.
prepare(host, args) is read-only. run(host, prepared) performs only the separately
authorized synthetic permission/appop, update, launch and precise logging cases.
Unknown native formats stop the case and retain evidence. Appops and the plugin
preference mirror never substitute for the real plugin capability query.

args explicitly names driver_run, updates_run, base_run (initial lifecycle),
version_ledger and, for changed sources, source_review. The ledger is an owned
coordinator receipt covering every attempted/reserved version in the disposable
run; this module adds every subsequent reservation before invoking a builder.
"""

from dataclasses import dataclass
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import time
import xml.etree.ElementTree as ET


PACKAGES = ("io.github.psychonaut0.reps", "dev.animusstudio.alkion.dev", "dev.animusstudio.alkion")
VARIANTS = {"dev": PACKAGES[1], "supported": PACKAGES[2]}
CASES = ("denied", "revoked", "exact", "inexact")
FORMAT = "alkion-android-capability-checkpoint/1"
PLUGIN_FORMAT = "alkion-android-plugin-capabilities/1"
LIMIT = 1048576
MAX_VERSION = 2099999999
MUTABLE = {("draft", "active"), ("timer", "active"), ("timer", "notification-action")}
RECEIVER = "com.dexterous.flutterlocalnotifications.ScheduledNotificationReceiver"
HELPER = "integration_test/android_notification_capability_test.dart"
DEFINES = ("ALKION_PROOF_RUN", "ALKION_PROOF_SOURCE", "ALKION_PRIOR_SOURCE", "ALKION_PROOF_VARIANT",
           "ALKION_CAPABILITY_CASE", "ALKION_CAPABILITY_PHASE", "ALKION_PROOF_VERSION", "ALKION_PRIOR_VERSION",
           "ALKION_CONSUMED_VERSION_FLOOR", "ALKION_PROOF_PROFILE", "ALKION_PROOF_GENERATION",
           "ALKION_PRIOR_REPORT_SHA256", "ALKION_PRIOR_STATE_SHA256")
ALLOWED_CODE_CHANGES = {"app/Makefile", "app/tool/android_synthetic.sh", "app/" + HELPER,
    "app/test/alkion/acceptance/android_notification_capability_protocol_test.dart",
    "app/tool/android_synthetic_capabilities.py", "app/tool/android_synthetic_capabilities_self_test.py",
    "app/tool/android_synthetic_ui.py", "app/tool/android_synthetic_ui_self_test.py",
    "app/tool/android_synthetic_ui/AndroidManifest.xml", "app/tool/android_synthetic_ui/HierarchyInstrumentation.java"}
DENIED_MESSAGE = "Notifications are off. Workout logging and your saved rest deadline still work. You can enable notifications in Android settings."
INEXACT_MESSAGE = "Background rest notifications may be delayed. Your saved deadline is unchanged and reconciles when you reopen Alkion."
UNRUN = ("force_stop", "recents_dismissal", "natural_expiry_delivery", "expired_payload_replay",
         "pre_restore_payload", "receiving_restore", "owner_device", "owner_data")


class Refusal(ValueError):
    pass


class Blocked(Refusal):
    pass


def require(value, reason):
    if not value:
        raise Refusal(reason)


def native(value, reason):
    if not value:
        raise Blocked(reason)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False).encode()


def state_sha(value):
    return sha(canonical(value))


def instant(value):
    require(isinstance(value, str) and re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:[.][0-9]{1,9})?Z", value),
            "explicit_utc_instant_required")
    return datetime.fromisoformat(value[:-1] + "+00:00").timestamp()


def local_rows(snapshot):
    rows = snapshot["inventory"]["local_state"]
    require(isinstance(rows, list), "closed_local_state_list_required")
    result = {(row["state_kind"], row["state_key"]): row for row in rows}
    require(len(result) == len(rows) and MUTABLE <= set(result), "closed_local_state_keys_invalid")
    return result


def payload(snapshot, kind, key="active"):
    row = local_rows(snapshot)[(kind, key)]
    raw = row["payload_bytes"]
    require(isinstance(raw, list) and all(type(item) is int and 0 <= item <= 255 for item in raw), "closed_payload_bytes_required")
    value = json.loads(bytes(raw))
    require(isinstance(value, dict), "closed_payload_object_required")
    return value


def rest(snapshot):
    draft = payload(snapshot, "draft")
    timer = payload(snapshot, "timer")
    require(draft.get("restTotal") == 600 and timer.get("restTotal") == 600 and
            timer.get("restStart") == draft.get("restStart"), "exact_600_second_rest_required")
    return draft, instant(draft["restStart"]) + 600


def current_source(host):
    revision = host.command(["git", "-C", host.APP, "rev-parse", "HEAD"]).stdout.strip()
    require(re.fullmatch(r"[a-f0-9]{40}", revision), "source_commit_required")
    require(not host.command(["git", "-C", host.APP, "status", "--porcelain", "--untracked-files=normal"]).stdout.strip(),
            "commit_reviewed_source_before_capability_proof")
    return revision


def capability_build_arguments(environment):
    flavor, version, phase = (environment.get(key, "") for key in ("ALKION_FLAVOR", "ALKION_PROOF_VERSION", "ALKION_CAPABILITY_PHASE"))
    require(flavor in VARIANTS and re.fullmatch(r"[0-9]{1,10}", version) and 0 < int(version) <= MAX_VERSION,
            "explicit_capability_build_identity_required")
    base = ["fvm", "flutter", "build", "apk", "--debug", "--no-pub", "--flavor", flavor,
            "--target-platform", "android-x64", "--build-number", version]
    if phase == "main":
        return [*base, "--target", "lib/main.dart"]  # Literal main has no proof defines.
    require(all(key in environment for key in DEFINES), "complete_capability_compile_binding_required")
    text = {key: environment[key] for key in DEFINES}
    require(phase in ("prepare", "preserve", "logged") and text["ALKION_CAPABILITY_CASE"] in CASES and
            (phase != "logged" or text["ALKION_CAPABILITY_CASE"] in CASES[:2]) and
            text["ALKION_PROOF_VARIANT"] == flavor and re.fullmatch(r"[a-f0-9]{32}", text["ALKION_PROOF_RUN"]) and
            all(re.fullmatch(r"[a-f0-9]{40}", text[key]) for key in ("ALKION_PROOF_SOURCE", "ALKION_PRIOR_SOURCE")) and
            all(re.fullmatch(r"[a-f0-9]{64}", text[key]) for key in ("ALKION_PRIOR_REPORT_SHA256", "ALKION_PRIOR_STATE_SHA256")) and
            re.fullmatch(r"[a-f0-9-]{36}", text["ALKION_PROOF_PROFILE"]) and
            all(re.fullmatch(r"[0-9]{1,10}", text[key]) for key in ("ALKION_PROOF_GENERATION", "ALKION_PRIOR_VERSION", "ALKION_CONSUMED_VERSION_FLOOR")) and
            int(text["ALKION_PROOF_GENERATION"]) > 0 and
            0 < int(text["ALKION_PRIOR_VERSION"]) <= int(text["ALKION_CONSUMED_VERSION_FLOOR"]) < int(version),
            "invalid_capability_compile_binding")
    return [*base, "--target", HELPER, *("--dart-define=" + key + "=" + text[key] for key in DEFINES)]


def validate_lifecycle(lifecycle, updates, driver, receipt):
    require(isinstance(lifecycle, dict) and lifecycle.get("format") == "alkion-android-run/1" and
            lifecycle.get("phase") == "lifecycle-initial" and lifecycle.get("initial_lifecycle_phase") == "PASS" and
            lifecycle.get("overall") == "IN_PROGRESS" and not lifecycle.get("error") and
            isinstance(lifecycle.get("pending"), dict) and
            all(lifecycle.get(key) == receipt[key] for key in ("run_id", "serial", "avd")) and
            lifecycle.get("base_source_commit") == updates.get("source_commit") and
            updates.get("base_source_commit") == driver.get("source_commit") and
            re.fullmatch(r"[a-f0-9]{40}", lifecycle.get("source_commit", "")) and
            set(lifecycle.get("installed", {})) == set(PACKAGES) and
            set(lifecycle.get("lifecycle", {})) == set(VARIANTS.values()), "accepted_initial_lifecycle_chain_required")
    for package in VARIANTS.values():
        value = lifecycle["lifecycle"][package]
        require(value.get("initial_lifecycle") == "PASS", "both_initial_lifecycle_variants_required")
        for phase in ("prepare", "rest", "finish"):
            checkpoint = value.get(phase, {})
            require(checkpoint.get("format") == "alkion-android-lifecycle-checkpoint/1" and
                    checkpoint.get("phase") == phase and checkpoint.get("application_id") == package and
                    checkpoint.get("run_id") == receipt["run_id"] and checkpoint.get("complete") is True and
                    checkpoint.get("closed") is True and checkpoint.get("result") == "PASS" and not checkpoint.get("failures") and
                    re.fullmatch(r"[a-f0-9]{64}", checkpoint.get("state_digest", "")) and
                    all(checkpoint.get(key) == updates["updates"][package]["verify"].get(key) for key in
                        ("profile_id", "installation_id", "generation", "database_relative")), "closed_initial_checkpoint_required")
        require(value["finish"].get("draft") is None, "initial_lifecycle_must_be_finished")
        peers = value.get("peer_covered_bytes", {})
        require(set(peers) == set(VARIANTS.values()) - {package} and all(isinstance(item, dict) and
                re.fullmatch(r"[a-f0-9]{64}", item.get("before", "")) and item.get("before") == item.get("after")
                for item in peers.values()), "initial_lifecycle_peer_preservation_missing")
    for package, facts in lifecycle["installed"].items():
        require(facts.get("package") == package and type(facts.get("version_code")) is int and 0 < facts["version_code"] < MAX_VERSION and
                all(re.fullmatch(r"[a-f0-9]{64}", facts.get(key, "")) for key in ("apk_sha256", "certificate_sha256")) and
                facts["certificate_sha256"] == updates["installed"][package]["certificate_sha256"], "initial_apk_binding_invalid")
        require(facts == driver["installed"][package] if package == PACKAGES[0] else
                facts["version_code"] > updates["installed"][package]["version_code"], "initial_version_floor_invalid")
    return lifecycle["installed"]


def recorded_codes(value, package=None):
    """Collect actual producer version_code fields with their explicit package."""
    codes = set()
    if isinstance(value, dict):
        package = value.get("application_id", value.get("package", package))
        if package in PACKAGES and type(value.get("version_code")) is int:
            codes.add((package, value["version_code"]))
        for key, child in value.items():
            codes.update(recorded_codes(child, key if key in PACKAGES else package))
    elif isinstance(value, list):
        for child in value:
            codes.update(recorded_codes(child, package))
    return codes


def validate_ledger(ledger, receipt, manifests, installed, observed_codes=()):
    require(ledger.get("format") == "alkion-android-version-ledger/1" and ledger.get("complete") is True and
            ledger.get("coverage") == "all-attempted-and-reserved-in-disposable-run" and
            all(ledger.get(key) == receipt[key] for key in ("run_id", "serial", "avd")) and
            ledger.get("manifest_sha256") == manifests and isinstance(ledger.get("entries"), list), "complete_version_ledger_required")
    floor = max(facts["version_code"] for facts in installed.values())
    seen = set()
    for entry in ledger["entries"]:
        require(isinstance(entry, dict) and entry.get("application_id") in PACKAGES and
                type(entry.get("version_code")) is int and 0 < entry["version_code"] < MAX_VERSION and
                entry.get("state") in ("reserved", "attempted", "built", "installed", "failed") and
                re.fullmatch(r"[a-f0-9]{40}", entry.get("source_commit", "")) and bool(entry.get("role")) and isinstance(entry["role"], str),
                "version_ledger_entry_invalid")
        key = (entry["application_id"], entry["version_code"])
        require(key not in seen, "version_ledger_reused_code")
        seen.add(key); floor = max(floor, entry["version_code"])
    require(all((package, facts["version_code"]) in seen for package, facts in installed.items()), "ledger_omits_installed_version")
    require(set(observed_codes) <= seen, "ledger_omits_recorded_attempted_or_reserved_version")
    return floor


def provenance(host, args, base_source, revision):
    if base_source == revision:
        return
    review_path = getattr(args, "source_review", None)
    require(review_path, "reviewed_helper_only_source_transition_required")
    review = host.read_json(host.temporary_path(review_path, must_exist=True), LIMIT)
    require(review.get("format") == "alkion-capability-source-review/1" and review.get("result") == "PASS" and
            review.get("base_source_commit") == base_source and review.get("source_commit") == revision,
            "source_transition_review_mismatch")
    require(host.command(["git", "-C", host.APP, "merge-base", "--is-ancestor", base_source, revision], check=False).returncode == 0,
            "capability_source_not_descendant")
    paths = host.command(["git", "-C", host.APP, "diff", "--name-only", base_source, revision]).stdout.splitlines()
    require(paths == review.get("changed_paths") and all(path in ALLOWED_CODE_CHANGES or path.startswith("docs/") for path in paths),
            "unreviewed_or_runtime_source_change")


def timeout_receipt(error, context):
    def raw(value):
        return value if isinstance(value, bytes) else value.encode() if isinstance(value, str) else b""
    error.capability_partial_stdout = raw(error.stdout)
    error.capability_partial_stderr = raw(error.stderr)
    error.capability_timeout_receipt = {
        "format": "alkion-capability-transport-timeout/1", "context": context,
        "argv": list(map(str, error.cmd)) if isinstance(error.cmd, (list, tuple)) else str(error.cmd),
        "timeout_seconds": error.timeout, "completion": "UNKNOWN; stop without retry or repair",
        "stdout": {"length": len(error.capability_partial_stdout), "sha256": sha(error.capability_partial_stdout)},
        "stderr": {"length": len(error.capability_partial_stderr), "sha256": sha(error.capability_partial_stderr)}}
    return error.capability_timeout_receipt


def owned_read(host, args, package, path, bound=LIMIT):
    require(package in PACKAGES and re.fullmatch(r"[A-Za-z0-9_./-]+", path) and not path.startswith("/") and
            all(part not in ("", ".", "..") for part in path.split("/")) and 0 < bound <= LIMIT, "owned_capability_path_invalid")
    program = ('p=""; oldIFS="$IFS"; IFS=/; for part in $1; do p="${p:+$p/}$part"; test ! -L "$p" || exit 4; done; IFS="$oldIFS"; '
               'test -e "$1" || exit 3; test -f "$1" || exit 4; test "$(wc -c < "$1")" -le "$2" || exit 5; cat "$1"')
    argv = shlex.join(["run-as", package, "/system/bin/sh", "-c", program, "alkion-capability-read", path, str(bound)])
    try:
        result = host.command([args.sdk / "platform-tools/adb", "-s", args.serial, "exec-out", argv], binary=True, check=False, timeout=30)
    except subprocess.TimeoutExpired as error:
        # Read-only preflight has no claimed output directory. Preserve a typed
        # receipt and original bytes on the exception for its caller; Evidence
        # persists these when the guarded campaign owns an output directory.
        timeout_receipt(error, {"operation": "owned-read", "serial": args.serial, "avd": args.avd,
                                "package": package, "path": path, "bound": bound, "mutation_requested": False})
        raise
    require(len(result.stdout) <= bound, "owned_capability_read_exceeded_bound")
    return result


@dataclass
class Prepared:
    args: object
    receipt: dict
    output: Path
    driver: dict
    updates: dict
    lifecycle: dict
    lifecycle_raw: bytes
    snapshots: dict
    baselines: dict
    installed: dict
    metadata: dict
    revision: str
    ledger: dict
    ledger_path: Path
    ledger_raw: bytes
    ledger_sha256: str
    floor: int


def prepare(host, args):
    receipt, output = host.receipt_guard(args)
    require((args.sdk / "platform-tools/adb").is_file(), "adb_required")
    paths = []
    for key in ("driver_run", "updates_run", "base_run", "version_ledger"):
        require(getattr(args, key, None), "explicit_capability_receipts_required")
        paths.append(host.temporary_path(getattr(args, key), must_exist=True))
    require(len(set(paths)) == 4, "distinct_capability_receipts_required")
    driver, updates, lifecycle, ledger = [host.read_json(path, LIMIT) for path in paths]
    ledger_raw = paths[3].read_bytes()
    require(len(ledger_raw) <= LIMIT and json.loads(ledger_raw) == ledger, "version_ledger_changed_during_preflight")
    contract = host.driver_continuation_contract(driver, receipt)
    metadata = host.lifecycle_contract(updates, receipt)
    require(updates.get("base_driver_contract") == contract, "driver_contract_changed")
    installed = validate_lifecycle(lifecycle, updates, driver, receipt)
    manifests = {str(path): sha(path.read_bytes()) for path in paths[:3]}
    observed_codes = recorded_codes(driver) | recorded_codes(updates) | recorded_codes(lifecycle)
    extra = getattr(args, "attempt_manifests", ())
    require(isinstance(extra, (tuple, list)), "explicit_attempt_manifest_list_required")
    for value in extra:
        path = host.temporary_path(value, must_exist=True)
        attempted = host.read_json(path, LIMIT)
        require(isinstance(attempted, dict) and all(attempted.get(key) == receipt[key] for key in
                ("run_id", "serial", "avd")), "foreign_attempt_manifest")
        require(str(path) not in manifests, "duplicate_attempt_manifest")
        manifests[str(path)] = sha(path.read_bytes())
        observed_codes.update(recorded_codes(attempted))
    floor = validate_ledger(ledger, receipt, manifests, installed, observed_codes)
    host.toolchain(args)
    revision = current_source(host)
    provenance(host, args, lifecycle["source_commit"], revision)
    producer = (host.APP / HELPER).read_text()
    native(PLUGIN_FORMAT in producer and "plugin_capabilities" in producer,
           "BLOCKED:reviewed_real_plugin_query_producer_not_integrated")
    for flavor, package in VARIANTS.items():
        for path, expected in ((paths[0].parent / ("driver-" + flavor + ".apk"), driver["installed"][package]),
                               (paths[1].parent / (flavor + "-verify.apk"), updates["installed"][package]),
                               (paths[2].parent / (flavor + "-finish.apk"), installed[package])):
            host.temporary_path(str(path), must_exist=True)
            require(host.apk_facts(args, path, package) == expected, "retained_capability_predecessor_apk_changed")
    neighbor = paths[0].parent / "neighbor-build/synthetic-neighbor.apk"
    require(host.apk_facts(args, neighbor, PACKAGES[0]) == installed[PACKAGES[0]], "retained_neighbor_apk_changed")
    host.device_platform_guard(args); host.installed_matches(args, installed)
    snapshots, baselines = {}, {}
    for package in PACKAGES:
        observed = host.package_metadata(args, package)
        require(observed["version_code"] == installed[package]["version_code"] and type(observed.get("uid")) is int and
                10000 <= observed["uid"] < 100000, "current_capability_package_metadata_changed")
        if package in metadata:
            require(observed["uid"] == metadata[package]["uid"], "current_capability_full_uid_changed")
        metadata[package] = observed
        if package in VARIANTS.values():
            raw = owned_read(host, args, package, "files/android-lifecycle/" + receipt["run_id"] + "/finish-snapshot.json")
            require(raw.returncode == 0 and not raw.stderr, "closed_finish_snapshot_missing")
            snapshot = json.loads(raw.stdout)
            report = lifecycle["lifecycle"][package]["finish"]
            require(state_sha(snapshot) == report["state_digest"] and snapshot.get("application_id") == package and
                    all(snapshot.get(key) == report.get(key) for key in ("profile_id", "installation_id", "generation", "database_relative")),
                    "closed_finish_snapshot_binding_changed")
            snapshots[package] = snapshot
            baselines[package] = host.closed_profile_fingerprint(args, package, report)
    require(len({value["uid"] for value in metadata.values()}) == len(PACKAGES), "capability_uid_collision")
    help_package = host.adb(args, "shell", "cmd", "package", "help").stdout
    help_appops = host.adb(args, "shell", "cmd", "appops", "help").stdout
    native(all(value in help_package for value in ("grant", "revoke", "clear-permission-flags")) and
           "set [--user" in help_appops and "get [--user" in help_appops, "BLOCKED:unrecognized_permission_command_help")
    raw = paths[2].read_bytes()
    require(json.loads(raw) == lifecycle, "initial_lifecycle_receipt_changed_during_preflight")
    return Prepared(args, receipt, output, driver, updates, lifecycle, raw, snapshots, baselines,
                    installed, metadata, revision, ledger, paths[3], ledger_raw, sha(ledger_raw), floor)


def plugin_query(report, launch_utc=None, received_utc=None):
    query = report.get("plugin_capabilities", {})
    native(isinstance(query, dict) and query.get("format") == PLUGIN_FORMAT and
           type(query.get("notifications_enabled")) is bool and type(query.get("can_schedule_exact_notifications")) is bool,
           "BLOCKED:missing_actual_plugin_capability_query")
    when = instant(query.get("queried_at"))
    # The accepted producer closes SQL first, then performs the two real plugin
    # queries. Its query receipt therefore follows the closed checkpoint time.
    native(when >= instant(report["checkpoint_time"]) and
           (launch_utc is None or instant(report["checkpoint_time"]) >= launch_utc) and
           (received_utc is None or when <= received_utc),
           "BLOCKED:plugin_capability_query_time_unbound")
    return query


def predecessor_contract(step, raw, snapshot):
    prior = json.loads(raw)
    require(prior.get("run_id") == step["run_id"] and prior.get("source_commit") == step["prior_source_commit"] and
            sha(raw) == step["prior_report_sha256"] and state_sha(snapshot) == step["prior_state_digest"],
            "capability_predecessor_hash_or_source_changed")
    if prior.get("format") == "alkion-android-run/1":
        require(step["case_id"] == "denied" and step["phase"] == "prepare" and
                prior.get("phase") == "lifecycle-initial" and prior.get("initial_lifecycle_phase") == "PASS" and
                prior.get("overall") == "IN_PROGRESS" and not prior.get("error") and
                prior["installed"][step["application_id"]]["version_code"] == step["prior_version_code"] and
                all(prior["lifecycle"][package].get("initial_lifecycle") == "PASS" and
                    prior["lifecycle"][package]["finish"].get("complete") is True and
                    prior["lifecycle"][package]["finish"].get("closed") is True and
                    prior["lifecycle"][package]["finish"].get("result") == "PASS" for package in VARIANTS.values()) and
                prior["lifecycle"][step["application_id"]]["finish"]["state_digest"] == state_sha(snapshot),
                "accepted_both_variant_initial_predecessor_required")
        return
    require(prior.get("format") == FORMAT and prior.get("complete") is True and prior.get("closed") is True and
            prior.get("result") == "PASS" and prior.get("application_id") == step["application_id"] and
            prior.get("variant") == step["variant"] and prior.get("version_code") == step["prior_version_code"] and
            prior.get("state_digest") == state_sha(snapshot) and prior.get("snapshot") == snapshot and
            all(prior.get(key) == step[key] for key in ("profile_id", "generation")), "accepted_capability_predecessor_required")
    if step["phase"] == "prepare":
        index = CASES.index(step["case_id"])
        require(index > 0 and prior.get("case_id") == CASES[index - 1] and
                prior.get("phase") == ("preserve" if step["case_id"] == "inexact" else "logged"), "capability_case_sequence_changed")
    else:
        require(prior.get("case_id") == step["case_id"] and prior.get("phase") ==
                ("preserve" if step["phase"] == "logged" else "prepare"), "capability_phase_sequence_changed")


def validate_checkpoint(report, step, prior_raw, prior_snapshot, launch_utc=None, received_utc=None):
    predecessor_contract(step, prior_raw, prior_snapshot)
    require(isinstance(report, dict) and all(report.get(key) == value for key, value in step.items()) and
            report.get("format") == FORMAT and report.get("complete") is True and report.get("closed") is True and
            report.get("result") == "PASS" and not report.get("failures") and
            report.get("prior_report_sha256") == sha(prior_raw) and report.get("prior_state_digest") == state_sha(prior_snapshot),
            "closed_capability_checkpoint_binding_failed")
    snapshot = report.get("snapshot")
    require(isinstance(snapshot, dict) and state_sha(snapshot) == report.get("state_digest") and
            {key: value for key, value in snapshot.items() if key != "inventory"} ==
            {key: value for key, value in prior_snapshot.items() if key != "inventory"}, "closed_snapshot_identity_or_original_bytes_changed")
    require(snapshot["inventory"].keys() == prior_snapshot["inventory"].keys(), "closed_inventory_table_set_changed")
    for table, values in prior_snapshot["inventory"].items():
        if table != "local_state":
            require(snapshot["inventory"][table] == values, "immutable_capability_inventory_changed:" + table)
    old, new = local_rows(prior_snapshot), local_rows(snapshot)
    require(old.keys() == new.keys() and all(old[key] == new[key] for key in old if key not in MUTABLE), "other_local_rows_changed")
    delta = {kind + "/" + key: {"before_sha256": state_sha(old[(kind, key)]), "after_sha256": state_sha(new[(kind, key)]),
             "revision_delta": new[(kind, key)]["revision"] - old[(kind, key)]["revision"]}
             for kind, key in MUTABLE if old[(kind, key)] != new[(kind, key)]}
    phase = step["phase"]
    require(report.get("fixture_delta") == (delta if phase == "prepare" else {}) and
            report.get("observed_delta") == ({} if phase == "prepare" else delta), "closed_delta_receipt_mismatch")
    if phase == "preserve":
        require(not delta and report["state_digest"] == state_sha(prior_snapshot), "preserve_changed_original_deadline_or_state")
    else:
        require(set(delta) == {kind + "/" + key for kind, key in MUTABLE}, "precise_fixture_or_logging_delta_missing")
        counts = {key: value["revision_delta"] for key, value in delta.items()}
        require(counts["timer/notification-action"] == 1 and counts["draft/active"] == counts["timer/active"] and
                counts["draft/active"] >= 1 and (phase != "prepare" or counts["draft/active"] == 1), "precise_capability_revision_delta_changed")
        draft, _ = rest(snapshot)
        if phase == "prepare":
            prefix = "capability-" + step["run_id"] + "-" + step["case_id"]
            require(draft.get("draftId") == prefix and draft.get("name") ==
                    "Synthetic capability " + step["run_id"] + " " + step["case_id"] + " " + step["application_id"] and
                    draft.get("focusedSetId") == prefix + "-workflow-planned", "capability_fixture_case_identity_changed")
        else:
            expected = json.loads(canonical(payload(prior_snapshot, "draft")))
            planned = expected["blocks"][0]["workingSets"][-1]
            require(planned.get("done") is False and expected.get("focusedSetId") == planned["id"], "logging_predecessor_not_one_planned_set")
            planned["done"] = True
            require(instant(draft["restStart"]) > instant(expected["restStart"]) and
                    instant(draft["restStart"]) >= instant(json.loads(prior_raw)["checkpoint_time"]) and
                    instant(draft["restStart"]) <= instant(report["checkpoint_time"]), "logging_intentional_rest_reset_unbound")
            expected.update(focusedSetId=None, rirPromptSetId=planned["id"], restStart=draft["restStart"], restTotal=600, restEndedAt=None)
            timer = dict(payload(prior_snapshot, "timer"), restStart=draft["restStart"], restTotal=600, restEndedAt=None)
            require(draft == expected and payload(snapshot, "timer") == timer, "logging_exceeded_precise_payload_delta")
        action = payload(snapshot, "timer", "notification-action").get("action", {})
        require(action.get("application_id") == snapshot["application_id"] and action.get("profile_id") == snapshot["profile_id"] and
                action.get("generation") == snapshot["generation"] and action.get("draft_id") == draft["draftId"] and
                action.get("rest_start") == draft["restStart"] and action.get("timer_revision") == new[("timer", "active")]["revision"] and
                re.fullmatch(r"[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}", action.get("token", "")) and
                action.get("token") != payload(prior_snapshot, "timer", "notification-action").get("action", {}).get("token"),
                "issued_capability_action_binding_changed")
    rest(snapshot)
    plugin_query(report, launch_utc, received_utc)
    return snapshot


def permission_state(raw):
    native(len(raw.encode()) <= LIMIT, "BLOCKED:permission_dump_too_large")
    permissions = re.findall(r"^\s+android[.]permission[.]POST_NOTIFICATIONS: granted=(true|false), flags=\[([^\]\n]*)\]\s*$", raw, re.MULTILINE)
    stopped = re.findall(r"^\s+User 0: [^\n]*\bstopped=(true|false)\b[^\n]*$", raw, re.MULTILINE)
    native(len(permissions) == 1 and len(stopped) == 1, "BLOCKED:unrecognized_or_ambiguous_permission_dump")
    flags = [item.strip() for item in permissions[0][1].split("|") if item.strip()]
    native(all(re.fullmatch(r"[A-Z_]+", flag) for flag in flags), "BLOCKED:unknown_permission_flags")
    return {"granted": permissions[0][0] == "true", "stopped": stopped[0] == "true", "flags": flags}


def appop_mode(raw, operation):
    native(len(raw.encode()) <= 65536, "BLOCKED:appop_dump_too_large")
    if raw.strip() == "No operations.\nDefault mode: default":
        return None  # Explicit unknown, never effective capability false/true.
    matches = re.findall(r"^(?:Uid mode: )?" + re.escape(operation) + r": (allow|ignore|deny|default)(?:;[^\n]*)?\s*$", raw, re.MULTILINE)
    native(len(matches) == 1, "BLOCKED:unrecognized_or_ambiguous_appop")
    return matches[0]


def scheduled_mode(raw, snapshot, mode):
    native(len(raw.encode()) <= 131072 and "<!DOCTYPE" not in raw and "<!ENTITY" not in raw, "BLOCKED:unsafe_native_mirror")
    root = ET.fromstring(raw)
    fields = [node for node in root if node.tag == "string" and node.get("name") == "scheduled_notifications"]
    native(root.tag == "map" and len(fields) == 1, "BLOCKED:scheduled_mirror_format_unknown")
    entries = json.loads(fields[0].text or "null")
    native(isinstance(entries, list) and len(entries) <= 16 and all(isinstance(entry, dict) for entry in entries), "BLOCKED:scheduled_mirror_list_unknown")
    selected = [entry for entry in entries if entry.get("id") == 4101]
    if mode is None:
        native(not selected, "BLOCKED:denied_schedule_still_present")
        return None
    native(len(selected) == 1, "BLOCKED:scheduled_notification_missing_or_ambiguous")
    value = selected[0]
    draft, end = rest(snapshot)
    native(value.get("title") == draft["name"] and value.get("scheduleMode") == mode and value.get("timeZoneName") == "UTC" and
           json.loads(value.get("payload", "null")) == payload(snapshot, "timer", "notification-action")["action"],
           "BLOCKED:scheduled_mirror_case_or_mode_mismatch")
    when = value.get("scheduledDateTime", "")
    native(isinstance(when, str) and re.fullmatch(r"[0-9T:.-]+", when) and abs(instant(when + "Z") - end) < 0.001,
           "BLOCKED:scheduled_mirror_deadline_mismatch")
    return value


def alarm_headers(alarms):
    native(len(alarms.encode()) <= 4 * LIMIT and alarms.startswith("Current Alarm Manager state:\n"),
           "BLOCKED:alarm_dump_format_unknown")
    count = re.findall(r"^  ([0-9]+) pending alarms:\s*$", alarms, re.MULTILINE)
    headers = list(re.finditer(r"^    [A-Z_]+ #[0-9]+: Alarm\{[^\n]+\}\s*$", alarms, re.MULTILINE))
    native(len(count) == 1 and int(count[0]) == len(headers), "BLOCKED:pending_alarm_inventory_unknown_or_incomplete")
    return headers


def alarm_binding(alarms, intents, package, uid, deadline_ms, exact):
    # API36 native sample: Current Alarm Manager state / N pending alarms,
    # Alarm{token type 0 origWhen <epoch> whenElapsed <elapsed> <package>}.
    # PendingIntent details must separately bind creator full UID/receiver/4101.
    native(len(intents.encode()) <= 4 * LIMIT, "BLOCKED:pending_intents_dump_too_large")
    headers = alarm_headers(alarms)
    selected = []
    for index, header in enumerate(headers):
        match = re.fullmatch(r"    RTC_WAKEUP #[0-9]+: Alarm\{[a-f0-9]+ type 0 origWhen ([0-9]+) whenElapsed [0-9]+ " + re.escape(package) + r"\}\s*", header[0])
        if match:
            selected.append((match, alarms[header.end():headers[index + 1].start() if index + 1 < len(headers) else len(alarms)]))
    native(len(selected) == 1, "BLOCKED:target_alarm_missing_or_ambiguous")
    header, block = selected[0]
    native(int(header[1]) == deadline_ms, "BLOCKED:alarm_absolute_deadline_mismatch")
    attributes = re.findall(r"^      type=RTC_WAKEUP origWhen=[^\n]+ window=(\S+)(?: exactAllowReason=(\S+))? repeatInterval=0 count=0 flags=0x([a-f0-9]+)\s*$", block, re.MULTILINE)
    operations = re.findall(r"^      operation=PendingIntent\{[a-f0-9]+: PendingIntentRecord\{([a-f0-9]+) " + re.escape(package) + r" broadcastIntent\}\}\s*$", block, re.MULTILINE)
    native(len(attributes) == len(operations) == 1, "BLOCKED:alarm_attributes_or_operation_unknown")
    window, reason, flags = attributes[0]
    native((window == "0" and bool(reason)) if exact else (bool(re.fullmatch(r"\+(?:[0-9]+[dhms])+[0-9]*ms", window)) and not reason),
           "BLOCKED:alarm_exactness_mismatch")
    native(int(flags, 16) & 12, "BLOCKED:allow_while_idle_alarm_binding_missing")
    token = operations[0]
    records = list(re.finditer(r"^\s*\* PendingIntentRecord\{([a-f0-9]+) ([^\s}]+) broadcastIntent\}\s*$", intents, re.MULTILINE))
    found = [(record, intents[record.end():records[index + 1].start() if index + 1 < len(records) else len(intents)])
             for index, record in enumerate(records) if record[1] == token and record[2] == package]
    native(len(found) == 1, "BLOCKED:alarm_pending_intent_details_missing")
    details = found[0][1]
    native(len(re.findall(r"\buid=" + str(uid) + r"\b", details)) == 1 and
           len(re.findall(r"\bpackageName=" + re.escape(package) + r"\b", details)) == 1 and
           len(re.findall(r"\brequestCode=4101\b", details)) == 1 and
           len(re.findall(r"\bcmp=" + re.escape(package + "/" + RECEIVER) + r"(?:\s|\})", details)) == 1,
           "BLOCKED:alarm_pending_intent_uid_receiver_or_id_mismatch")
    return {"pending_intent_token": token, "orig_when": deadline_ms, "exact": exact, "window": window, "flags": int(flags, 16)}


class Evidence:
    def __init__(self, host, prepared):
        self.host, self.prepared = host, prepared
        self.count = 0

    def keep(self, name, data):
        self.count += 1
        path = self.prepared.output / (str(self.count).zfill(5) + "-" + name)
        with path.open("xb") as stream:
            os.chmod(path, 0o600); stream.write(data if isinstance(data, bytes) else canonical(data) + b"\n")
            stream.flush(); os.fsync(stream.fileno())
        return path

    def adb(self, *tail, check=True):
        try:
            result = self.host.adb(self.prepared.args, *tail, check=False)
        except subprocess.TimeoutExpired as error:
            self.retain_timeout(error, {"operation": "adb", "serial": self.prepared.args.serial,
                "avd": self.prepared.args.avd, "run_id": self.prepared.receipt["run_id"], "tail": list(map(str, tail)),
                "effects": "UNKNOWN; a requested mutation may already have occurred"})
            raise
        self.keep("native-command.json", {"argv": list(map(str, tail)), "returncode": result.returncode,
                                         "stdout": result.stdout, "stderr": result.stderr})
        require(not check or result.returncode == 0, "capability_native_command_failed")
        return result

    def read(self, package, path, *, optional=False):
        try:
            result = owned_read(self.host, self.prepared.args, package, path)
        except subprocess.TimeoutExpired as error:
            self.retain_timeout(error, error.capability_timeout_receipt["context"])
            raise
        self.keep("owned-read.stdout", result.stdout); self.keep("owned-read.stderr", result.stderr)
        if optional and result.returncode == 3 and not result.stdout and not result.stderr:
            return None
        require(result.returncode == 0 and not result.stderr, "capability_owned_read_failed")
        return result.stdout

    def retain_timeout(self, error, context):
        receipt = timeout_receipt(error, context)
        receipt["run_id"] = self.prepared.receipt["run_id"]
        receipt["stdout"]["file"] = self.keep("timeout-stdout.partial", error.capability_partial_stdout).name
        receipt["stderr"]["file"] = self.keep("timeout-stderr.partial", error.capability_partial_stderr).name
        self.keep("transport-timeout.json", receipt)

    def device_now(self):
        result = self.adb("shell", "date", "-u", "+%Y-%m-%dT%H:%M:%S.%NZ")
        return instant(result.stdout.strip())

    def stage(self, package, root, files):
        require(re.fullmatch(r"files/android-capability/[a-f0-9]{32}/(?:denied|revoked|exact|inexact)/v[0-9]+", root), "capability_stage_root_unbound")
        result = self.adb("shell", "run-as", package, "/system/bin/sh", "-c",
            'umask 077; p=""; oldIFS="$IFS"; IFS=/; for part in $1; do p="${p:+$p/}$part"; test ! -L "$p" || exit 4; '
            'if test "$p" != "$1" && test ! -e "$p"; then mkdir -m 700 "$p" || exit 4; fi; done; IFS="$oldIFS"; '
            'mkdir -m 700 "$1"', "alkion-capability-stage", root)
        for name, raw in files.items():
            require(name in ("prior-report.json", "prior-snapshot.json") and len(raw) <= LIMIT, "capability_input_unbounded")
            path = root + "/" + name
            partial = path + ".partial-" + os.urandom(16).hex()
            script = 'umask 077; set -C; cat > "$1"'
            argv = shlex.join(["run-as", package, "/system/bin/sh", "-c", script, "alkion-capability-input", partial])
            try:
                written = self.host.command([self.prepared.args.sdk / "platform-tools/adb", "-s", self.prepared.args.serial,
                                             "exec-out", argv], binary=True, input=raw, check=False, timeout=30)
            except subprocess.TimeoutExpired as error:
                self.retain_timeout(error, {"operation": "stage-input", "serial": self.prepared.args.serial,
                    "avd": self.prepared.args.avd, "package": package, "path": partial,
                    "input_length": len(raw), "input_sha256": sha(raw), "effects": "UNKNOWN; partial input retained, not published"})
                raise
            self.keep("staged-input.transport", {"path": partial, "returncode": written.returncode,
                                                 "stderr": written.stderr.decode(errors="replace")})
            require(written.returncode == 0 and not written.stderr and self.read(package, partial) == raw,
                    "capability_closed_input_changed")
            self.adb("shell", "run-as", package, "/system/bin/sh", "-c", 'ln -T "$1" "$2"',
                     "alkion-capability-input-publish", partial, path)


class LiveBudget:
    def __init__(self, evidence, snapshot):
        self.evidence = evidence
        _, self.deadline = rest(snapshot)
        self.start_device = evidence.device_now(); self.start_host = time.monotonic()
        require(self.deadline > self.start_device, "capability_timer_already_expired")

    def require(self, seconds, operation):
        now = self.evidence.device_now()
        elapsed = time.monotonic() - self.start_host
        native(abs((now - self.start_device) - elapsed) <= 2.5, "BLOCKED:capability_clock_disagreement")
        remaining = self.deadline - now
        self.evidence.keep("remaining-budget.json", {"operation": operation, "remaining_seconds": remaining,
                                                    "required_seconds": seconds, "original_deadline": self.deadline})
        if remaining <= seconds:
            raise Blocked("BLOCKED:insufficient_original_600s_budget:" + operation)
        return remaining


def reserve_version(state, package, role, revision):
    floor = state["allocation_floor"]
    require(type(floor) is int and 0 < floor < MAX_VERSION and package in VARIANTS.values() and
            re.fullmatch(r"(?:denied|revoked|exact|inexact)/(?:prepare|main|preserve|logged)", role) and
            re.fullmatch(r"[a-f0-9]{40}", revision), "capability_version_reservation_invalid")
    version = floor + 1
    require(all(entry["version_code"] < version for entry in state["builds"]), "attempted_or_reserved_version_would_be_reused")
    entry = {"application_id": package, "role": role, "version_code": version,
             "allocation_floor": floor, "source_commit": revision, "state": "reserved"}
    state["allocation_floor"] = version; state["builds"].append(entry)
    return entry


def permission_observation(evidence, package):
    state = permission_state(evidence.adb("shell", "dumpsys", "package", package).stdout)
    post = appop_mode(evidence.adb("shell", "cmd", "appops", "get", "--user", "0", package, "POST_NOTIFICATION").stdout, "POST_NOTIFICATION")
    exact = appop_mode(evidence.adb("shell", "cmd", "appops", "get", "--user", "0", package, "SCHEDULE_EXACT_ALARM").stdout, "SCHEDULE_EXACT_ALARM")
    return {**state, "post_appop": post, "exact_appop": exact}


def deny_dialog(evidence, package, document, activity):
    controller = "com.android.permissioncontroller"
    label = "Alkion Dev" if package.endswith(".dev") else "Alkion"
    expected = "Allow " + label + " to send you notifications?"
    messages = [node for node in document.iter("node") if node.get("package") == controller and
                node.get("resource-id") == controller + ":id/permission_message" and node.get("text") == expected]
    buttons = [node for node in document.iter("node") if node.get("package") == controller and
               node.get("resource-id") == controller + ":id/permission_deny_button" and node.get("clickable") == "true" and
               node.get("text") in ("Don’t allow", "Don't allow")]
    uid = evidence.prepared.metadata[package]["uid"]
    native(len(messages) == len(buttons) == 1 and "android.content.pm.action.REQUEST_PERMISSIONS" in activity and
           len(re.findall(r"\blaunchedFromUid=" + str(uid) + r"\s+launchedFromPackage=" + re.escape(package) + r"\b", activity)) == 1 and
           evidence.host.resumed_component(activity) == ("0", controller + "/.permission.ui.GrantPermissionsActivity"),
           "BLOCKED:permission_dialog_request_uid_or_ui_unbound")
    evidence.host.click_node(evidence.prepared.args, buttons[0])


def limitation_ui(evidence, package, message, *, require_dialog):
    deadline = time.monotonic() + 7.5
    denied = False
    while time.monotonic() < deadline:
        name = str(evidence.count + 1).zfill(5) + "-limitation"
        activity = evidence.adb("shell", "dumpsys", "activity", "activities").stdout
        owner = evidence.host.resumed_component(activity)
        native(owner is not None and owner[0] == "0" and owner[1].split("/", 1)[0] in
               (package, "com.android.permissioncontroller"), "BLOCKED:limitation_native_owner_unbound")
        document = evidence.host.ui_document(evidence.prepared.args, evidence.prepared.output, name,
                                            expected_package=owner[1].split("/", 1)[0])
        activity = evidence.adb("shell", "dumpsys", "activity", "activities").stdout
        if any(node.get("package") == "com.android.permissioncontroller" for node in document.iter("node")):
            native(not denied, "BLOCKED:repeated_permission_dialog")
            deny_dialog(evidence, package, document, activity); denied = True
        elif any(node.get("package") == package and (node.get("text") == message or node.get("content-desc") == message)
                 for node in document.iter("node")):
            native(not require_dialog or denied, "BLOCKED:actual_permission_denial_not_observed")
            return {"actual_dialog_denied": denied, "message": message}
        time.sleep(0.1)
    raise Blocked("BLOCKED:honest_limitation_snackbar_not_observed_within_8s")


def native_schedule(evidence, package, snapshot, expected_mode):
    before = permission_observation(evidence, package)
    native(not before["stopped"], "BLOCKED:unexpected_stopped_package")
    try:
        raw = evidence.host.read_native_mirror(evidence.prepared.args, package)
    except subprocess.TimeoutExpired as error:
        evidence.retain_timeout(error, {"operation": "native-mirror-read", "serial": evidence.prepared.args.serial,
            "avd": evidence.prepared.args.avd, "package": package,
            "path": "shared_prefs/scheduled_notifications.xml", "mutation_requested": False})
        raise
    evidence.keep("native-plugin-mirror.xml", (raw.stdout + raw.stderr).encode())
    native(raw.returncode == 0, "BLOCKED:native_plugin_mirror_unavailable")
    scheduled_mode(raw.stdout, snapshot, expected_mode)
    key = "0|" + package + "|4101|null|" + str(evidence.prepared.metadata[package]["uid"])
    record = evidence.adb("shell", "cmd", "notification", "get", key, check=False)
    alarms = evidence.adb("shell", "dumpsys", "alarm").stdout
    intents = evidence.adb("shell", "dumpsys", "activity", "intents").stdout
    if expected_mode is None:
        native(before["granted"] is False and before["post_appop"] in ("ignore", "deny") and
               record.returncode != 0 and "no active notification matching key:" in record.stdout,
               "BLOCKED:denied_notification_absence_not_native")
        # Do not accept a historical package mention as an active alarm.
        headers = alarm_headers(alarms)
        native(not any(re.search(r" " + re.escape(package) + r"\}\s*$", header[0]) for header in headers),
               "BLOCKED:denied_native_alarm_remains")
        return {"permission": before, "scheduled": False}
    native(before["granted"] and before["post_appop"] == "allow" and record.returncode == 0,
           "BLOCKED:enabled_notification_state_unbound")
    draft, deadline = rest(snapshot)
    oracle = {"profile_id": snapshot["profile_id"], "generation": snapshot["generation"], "draft": draft}
    action = evidence.host.parse_native_mirror(raw.stdout, record.stdout, package,
                                              evidence.prepared.metadata[package]["uid"], oracle)
    native(action == payload(snapshot, "timer", "notification-action")["action"], "BLOCKED:native_action_changed")
    alarm = alarm_binding(alarms, intents, package, evidence.prepared.metadata[package]["uid"], int(deadline * 1000),
                          expected_mode == "exactAllowWhileIdle")
    return {"permission": before, "scheduled": True, "mode": expected_mode, "alarm": alarm}


def run(host, prepared):
    args, receipt, output = prepared.args, prepared.receipt, prepared.output
    require(current_source(host) == prepared.revision, "capability_source_changed_after_preflight")
    output.mkdir(mode=0o700)
    evidence = Evidence(host, prepared)
    state = {"format": "alkion-android-native-capabilities/1", "overall": "IN_PROGRESS", "phase": "notification-capabilities",
        "run_id": receipt["run_id"], "avd": args.avd, "serial": args.serial, "api": 36, "abi": "x86_64",
        "source_commit": prepared.revision, "base_source_commit": prepared.lifecycle["source_commit"],
        "receipt_sha256": dict(prepared.ledger["manifest_sha256"]),
        "version_ledger": {"path": str(prepared.ledger_path), "sha256": prepared.ledger_sha256},
        "package_uids": {package: value["uid"] for package, value in prepared.metadata.items()},
        "closed_baselines": dict(prepared.baselines),
        "ui_observer": getattr(args, "_ui_observer", (None,))[0],
        "producer_sha256": sha((host.APP / HELPER).read_bytes()),
        "installed": dict(prepared.installed), "allocation_floor": prepared.floor, "builds": [], "cases": {},
        "unrun": list(UNRUN), "native_evidence_role": "capability/routing only; closed helper owns SQL conclusions"}
    def save():
        evidence.keep("run-snapshot.json", state)
        temporary = output / "run.partial"
        with temporary.open("xb") as stream:
            os.chmod(temporary, 0o600); stream.write(canonical(state) + b"\n"); stream.flush(); os.fsync(stream.fileno())
        temporary.replace(output / "run.json")
    save(); evidence.keep("disposable-receipt.json", receipt); evidence.keep("initial-lifecycle-run.json", prepared.lifecycle_raw)
    evidence.keep("prior-version-ledger.json", prepared.ledger_raw)
    originals = None
    jit_seconds = getattr(args, "jit_build_budget", 120)

    def ledger_guard():
        path = host.temporary_path(args.version_ledger, must_exist=True)
        require(path == prepared.ledger_path and sha(path.read_bytes()) == prepared.ledger_sha256,
                "capability_version_ledger_changed_after_preflight")

    def stable():
        host.device_platform_guard(args); host.installed_matches(args, state["installed"])
        for peer in PACKAGES:
            require(host.package_metadata(args, peer) == {"uid": prepared.metadata[peer]["uid"],
                    "version_code": state["installed"][peer]["version_code"]}, "capability_uid_or_version_drift")
        require(host.driver_neighbor_bytes(args, receipt, prepared.driver) == originals, "capability_original_driver_or_neighbor_changed")

    def kill(package, budget=None):
        if host.app_pid(args, package) is not None:
            if budget: budget.require(30 + 125, "ordinary-kill-and-checkpoint")
            host.ordinary_kill(args, package, prepared.metadata[package]["uid"], output)
        require(host.app_pid(args, package) is None, "capability_update_requires_absent_exact_main_process")

    def build(flavor, case, phase, predecessor, snapshot, budget=None):
        if budget: budget.require(jit_seconds + 30 + 125 + 15, "jit-build-" + phase)
        ledger_guard()
        package = VARIANTS[flavor]
        entry = reserve_version(state, package, case + "/" + phase, prepared.revision)
        floor, version = entry["allocation_floor"], entry["version_code"]
        save()
        identity = {"format": FORMAT, "run_id": receipt["run_id"], "source_commit": prepared.revision,
            "prior_source_commit": json.loads(predecessor)["source_commit"], "application_id": package,
            "variant": flavor, "case_id": case, "phase": phase, "version_code": version,
            "prior_version_code": json.loads(predecessor).get("version_code", prepared.lifecycle["installed"][package]["version_code"]),
            "consumed_version_floor": floor, "profile_id": snapshot["profile_id"], "generation": snapshot["generation"],
            "prior_report_sha256": sha(predecessor), "prior_state_digest": state_sha(snapshot)}
        if phase != "main":
            predecessor_contract(identity, predecessor, snapshot)
        inputs = dict(zip(DEFINES, map(str, (identity[key] for key in
            ("run_id", "source_commit", "prior_source_commit", "variant", "case_id", "phase", "version_code", "prior_version_code",
             "consumed_version_floor", "profile_id", "generation", "prior_report_sha256", "prior_state_digest")))))
        inputs["ALKION_FLAVOR"] = flavor
        flutter_argv = capability_build_arguments(inputs)
        entry["compile_binding"] = identity
        build_argv = ["make", "-C", str(host.APP), "android-synthetic-capability-apk", *(key + "=" + value for key, value in inputs.items())]
        evidence.keep("build-arguments.json", {"argv": build_argv, "flutter_argv": flutter_argv})
        require(current_source(host) == prepared.revision, "capability_source_changed_before_build")
        entry["state"] = "attempted"; save()
        try:
            built = host.command(build_argv, check=False, timeout=jit_seconds if budget else 600)
        except Exception as error:
            entry["state"] = "failed"; entry["error"] = str(error)
            for name in ("stdout", "stderr"):
                raw = getattr(error, name, None)
                if isinstance(raw, (str, bytes)):
                    evidence.keep("interrupted-build-" + name + ".log", raw.encode() if isinstance(raw, str) else raw)
            save(); raise
        evidence.keep("build-" + flavor + "-" + case + "-" + phase + ".log", (built.stdout + built.stderr).encode())
        if built.returncode != 0:
            entry["state"] = "failed"; save(); raise Refusal("capability_candidate_build_failed")
        require(current_source(host) == prepared.revision, "capability_source_changed_during_build")
        if budget: budget.require(30 + 125 + 15, "post-jit-build-" + phase)
        apk = output / (flavor + "-" + case + "-" + phase + "-v" + str(version) + ".apk")
        shutil.copyfile(host.APP / "build/app/outputs/flutter-apk" / ("app-" + flavor + "-debug.apk"), apk)
        facts = host.apk_facts(args, apk, package)
        require(facts["version_code"] == version and facts["certificate_sha256"] == prepared.installed[package]["certificate_sha256"],
                "capability_candidate_version_or_signer_changed")
        entry.update(state="built", **facts); save()
        return {"apk": apk, "facts": facts, "identity": identity, "entry": entry}

    def install(candidate, predecessor, snapshot, budget=None):
        package = candidate["facts"]["package"]
        if budget: budget.require(60 + 15, "install-" + candidate["identity"]["phase"])
        kill(package, budget); stable()
        require(candidate["facts"]["version_code"] > state["installed"][package]["version_code"], "capability_install_version_not_monotonic")
        if candidate["identity"]["phase"] != "main":
            root = "files/android-capability/" + receipt["run_id"] + "/" + candidate["identity"]["case_id"] + "/v" + str(candidate["facts"]["version_code"])
            evidence.stage(package, root, {"prior-report.json": predecessor, "prior-snapshot.json": canonical(snapshot)})
        before = permission_observation(evidence, package)
        require(current_source(host) == prepared.revision and host.apk_facts(args, candidate["apk"], package) == candidate["facts"],
                "capability_candidate_or_source_changed_before_install")
        evidence.adb("install", "-r", candidate["apk"])
        state["installed"][package] = candidate["facts"]; candidate["entry"]["state"] = "installed"; save(); stable()
        after = permission_observation(evidence, package)
        native(before == after, "BLOCKED:package_update_changed_permission_or_appop_condition")
        started = evidence.device_now()
        evidence.adb("shell", "am", "start", "-W", "--user", "0", "-n", package + "/dev.animusstudio.alkion.MainActivity")
        return started

    def checkpoint(candidate, predecessor, snapshot, budget=None):
        if budget: budget.require(30 + 125, "closed-checkpoint")
        started = install(candidate, predecessor, snapshot, budget)
        identity = candidate["identity"]; package = identity["application_id"]
        path = "files/android-capability/" + receipt["run_id"] + "/" + identity["case_id"] + "/v" + str(identity["version_code"]) + "/output/report.json"
        end = time.monotonic() + 120
        while time.monotonic() < end:
            raw = evidence.read(package, path, optional=True)
            if raw is not None:
                report = json.loads(raw)
                current = validate_checkpoint(report, identity, predecessor, snapshot, started, evidence.device_now())
                return raw, current, report
            if budget: budget.require(5, "awaiting-closed-checkpoint")
            time.sleep(0.2)
        raise Refusal("capability_closed_checkpoint_timeout")

    def policy(package, case):
        evidence.keep("policy-before.json", permission_observation(evidence, package))
        evidence.adb("shell", "pm", "grant", "--user", "0", package, "android.permission.POST_NOTIFICATIONS")
        if case in ("exact", "inexact"):
            evidence.adb("shell", "cmd", "appops", "set", "--user", "0", package, "SCHEDULE_EXACT_ALARM", "allow" if case == "exact" else "deny")
        observed = permission_observation(evidence, package)
        native(observed["granted"] and observed["post_appop"] == "allow" and
               (case not in ("exact", "inexact") or observed["exact_appop"] == ("allow" if case == "exact" else "deny")),
               "BLOCKED:requested_capability_policy_not_effective")

    try:
        require(type(jit_seconds) is int and 30 <= jit_seconds <= 180, "bounded_jit_build_budget_required")
        ledger_guard()
        for path, digest in prepared.ledger["manifest_sha256"].items():
            retained = host.temporary_path(path, must_exist=True).read_bytes()
            require(sha(retained) == digest, "capability_predecessor_receipt_changed_after_preflight")
            evidence.keep("predecessor-manifest.json", retained)
        originals = host.driver_neighbor_bytes(args, receipt, prepared.driver)
        state["original_receipt_bytes_sha256"] = {package: sha(raw.encode()) for package, raw in originals.items()}
        stable()
        for package, before in prepared.baselines.items():
            require(host.closed_profile_fingerprint(args, package, prepared.lifecycle["lifecycle"][package]["finish"]) == before,
                    "capability_closed_baseline_changed_after_preflight")
        for flavor, package in VARIANTS.items():
            args.ui_expected_package = package
            predecessor, snapshot = prepared.lifecycle_raw, prepared.snapshots[package]
            for case in CASES:
                key = flavor + "/" + case
                result = {"result": "IN_PROGRESS"}; state["cases"][key] = result; save()
                stable(); kill(package)
                peer_before = {peer: host.closed_profile_fingerprint(args, peer, prepared.lifecycle["lifecycle"][peer]["finish"])
                               for peer in VARIANTS.values() if peer != package}
                result["peer_covered_bytes"] = {peer: {"before": before} for peer, before in peer_before.items()}; save()
                policy(package, case)
                fixture = build(flavor, case, "prepare", predecessor, snapshot)
                main = build(flavor, case, "main", predecessor, snapshot)
                prior_raw, current, report = checkpoint(fixture, predecessor, snapshot)
                result["prepare"] = report; save()
                query = plugin_query(report)
                native(query["notifications_enabled"] and (case not in ("exact", "inexact") or
                       query["can_schedule_exact_notifications"] == (case == "exact")), "BLOCKED:actual_prepare_plugin_query_disagrees")
                budget = LiveBudget(evidence, current)
                kill(package, budget)
                if case == "denied":
                    evidence.adb("shell", "pm", "revoke", "--user", "0", package, "android.permission.POST_NOTIFICATIONS")
                    evidence.adb("shell", "pm", "clear-permission-flags", "--user", "0", package,
                                 "android.permission.POST_NOTIFICATIONS", "user-set", "user-fixed")
                install(main, prior_raw, current, budget)
                mode = ("exactAllowWhileIdle" if query["can_schedule_exact_notifications"] else "inexactAllowWhileIdle")
                if case == "denied":
                    result["limitation"] = limitation_ui(evidence, package, DENIED_MESSAGE, require_dialog=True)
                    result["native"] = native_schedule(evidence, package, current, None)
                elif case == "revoked":
                    result["before_revocation"] = native_schedule(evidence, package, current, mode)
                    result["revocation_pid_before"] = host.app_pid(args, package)
                    evidence.adb("shell", "pm", "revoke", "--user", "0", package, "android.permission.POST_NOTIFICATIONS")
                    result["revocation_pid_after"] = host.app_pid(args, package)
                    result["revocation_is_ordinary_kill_proof"] = False
                    evidence.keep("post-revocation-permission.json", permission_observation(evidence, package))
                    evidence.adb("shell", "am", "start", "-W", "--user", "0", "-n", package + "/dev.animusstudio.alkion.MainActivity")
                    result["limitation"] = limitation_ui(evidence, package, DENIED_MESSAGE, require_dialog=False)
                    result["native"] = native_schedule(evidence, package, current, None)
                else:
                    if case == "inexact":
                        result["limitation"] = limitation_ui(evidence, package, INEXACT_MESSAGE, require_dialog=False)
                    result["native"] = native_schedule(evidence, package, current, mode)
                budget.require(jit_seconds + 30 + 125 + 15, "preserve-helper-build-ingress")
                verifier = build(flavor, case, "preserve", prior_raw, current, budget)
                prior_raw, current, report = checkpoint(verifier, prior_raw, current, budget)
                query = plugin_query(report)
                native(query["notifications_enabled"] == (case in ("exact", "inexact")) and
                       (case not in ("exact", "inexact") or query["can_schedule_exact_notifications"] == (case == "exact")),
                       "BLOCKED:actual_preserve_plugin_query_disagrees")
                result["preserve"] = report; save()
                if case in CASES[:2]:
                    logging_main = build(flavor, case, "main", prior_raw, current, budget)
                    logged = build(flavor, case, "logged", prior_raw, current, budget)
                    install(logging_main, prior_raw, current, budget)
                    result["logging_limitation"] = limitation_ui(evidence, package, DENIED_MESSAGE, require_dialog=False)
                    host.wait_ui_label(args, output, key.replace("/", "-") + "-resume", "Resume workout")
                    host.ui_tap(args, output, key.replace("/", "-") + "-open", "Resume workout")
                    host.wait_session_ui(args, output, key.replace("/", "-") + "-session")
                    budget.require(30 + 125 + 15, "intentional-logging-with-original-deadline-live")
                    host.ui_tap(args, output, key.replace("/", "-") + "-log", "Log set 2 · 82.5kg × 5")
                    host.ui_tap(args, output, key.replace("/", "-") + "-minimize", "Minimize")
                    prior_raw, current, report = checkpoint(logged, prior_raw, current, budget)
                    native(plugin_query(report)["notifications_enabled"] is False, "BLOCKED:logging_denial_condition_changed")
                    result["logging_native"] = native_schedule(evidence, package, current, None)
                    result["logged"] = report; save()
                kill(package, budget); stable()
                for peer, before in peer_before.items():
                    after = host.closed_profile_fingerprint(args, peer, prepared.lifecycle["lifecycle"][peer]["finish"])
                    result["peer_covered_bytes"][peer]["after"] = after; save()
                    require(after == before, "capability_peer_profile_changed")
                result["peer_and_neighbor_preserved"] = True; result["result"] = "PASS"; save()
                predecessor, snapshot = prior_raw, current
        state["capability_phase"] = "PASS"; save(); return state
    except Exception as error:
        state["capability_phase"] = "BLOCKED" if isinstance(error, Blocked) else "FAIL"
        state["error"] = str(error)
        if "result" in locals():
            result["result"] = state["capability_phase"]
        # Never finish a failed case, repair permissions, clear data, or reset a
        # timer. Retain every known terminal/partial checkpoint without parsing.
        state["retention_errors"] = []
        for candidate in state["builds"]:
            if candidate["role"].endswith("/main"): continue
            case = candidate["role"].split("/")[0]
            root = "files/android-capability/" + receipt["run_id"] + "/" + case + "/v" + str(candidate["version_code"]) + "/output/"
            for name in ("report.json", "report.partial"):
                try: evidence.read(candidate["application_id"], root + name, optional=True)
                except Exception as retained_error: state["retention_errors"].append(str(retained_error))
        save(); raise
