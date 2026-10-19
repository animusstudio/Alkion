"""Bounded SAF campaign, imported by the guarded android_synthetic.sh routes.

There is deliberately no executable device entry point. The harness supplies its
reviewed helpers as an object with APP, command, adb, receipt_guard,
temporary_path, read_json, toolchain, apk_facts, installed_matches,
package_metadata, device_platform_guard, driver_continuation_contract,
lifecycle_contract, driver_neighbor_bytes, closed_profile_fingerprint, app_pid,
ordinary_kill(args, package, uid, output), ui_document and click_node, and
args._publisher is the reviewed publisher artifact the harness binds after
preparation. Owned files are published by the shared no-replace publisher;
namespace directories keep their existing rename. No target/path/APK guard is
copied here.
prepare(host, args) is read-only on Android; run(host, prepared) is the separately
authorized mutation route. args names the driver_run, updates_run and base_run
(current lifecycle) receipts explicitly. All Flutter/Dart work remains via Make.
"""

from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shlex
import shutil
import subprocess
import time
import xml.etree.ElementTree as ET
import zipfile

import android_synthetic_publish as publish
import android_synthetic_ui as observer


PROVIDER = "dev.animusstudio.alkion.synthetic.documents"
AUTHORITY = PROVIDER + ".provider"
COMPONENT = PROVIDER + "/.SyntheticDocumentsProvider"
PROVIDER_CLASS = PROVIDER + ".SyntheticDocumentsProvider"
# PackageManagerShellCommand.runSetEnabledSetting prints the unflattened
# ComponentName.toShortString() (full class) and the resulting state.
PROVIDER_ENABLED = "Component {" + PROVIDER + "/" + PROVIDER_CLASS + "} new state: enabled\n"
TEST_ONLY = "A: http://schemas.android.com/apk/res/android:testOnly(0x01010272)=true"
EVIDENCE_TEXT = 1024 * 1024
PACKAGES = ("io.github.psychonaut0.reps", "dev.animusstudio.alkion.dev",
            "dev.animusstudio.alkion")
VARIANTS = {"dev": PACKAGES[1], "supported": PACKAGES[2]}
LIMIT = 8 * 1024 * 1024
JSON_LIMIT = 1024 * 1024
CASES = {
    "open-cancel": "cancelled", "open-good": "fully_verified",
    "open-denied": "document_permission_denied", "open-error": "document_io_failed",
    "open-short": "document_length_mismatch", "open-over-limit": "document_resource_limit",
    "open-corrupt": "backup_digest_mismatch", "save-cancel": "cancelled",
    "save-good": "provider_copy_fully_verified_on_this_device",
    "save-write-denied": "document_permission_denied",
    "save-write-interrupted": "document_io_failed",
    "save-readback-denied": "document_permission_denied",
    "save-readback-changed": "document_readback_mismatch",
}
OUTPUT_CASES = tuple(name for name in CASES if name.startswith("save-") and not name.endswith("cancel"))
UNRUN = ("transfer_import_semantics", "uri_grant_revocation", "physical_disk_full",
         "fresh_receiver_restore", "app_process_interruption", "provider_process_death",
         "provider_restart_reuse", "roots_cache_recovery", "physical_off_device_verification",
         "owner_data")
# Current schema.dart preservedTables, including its domainTables expansion.
# The receiving CLI verifies SQL/migration digests against the real registry;
# this consumer checks its structured report and complete inventory contract.
RECEIVING_TABLES = frozenset((
    "profile_state", "schema_migrations", "operations", "operation_dependencies", "reviews", "review_decisions",
    "operation_attempts", "attempt_outcomes", "record_revisions", "source_artifacts", "origin_mappings",
    "source_revisions", "source_projections", "corrections", "derived_results", "local_state", "catalog_pins",
    "import_generations", "import_journal", "correspondence", "replica_rows", "replica_checkpoints", "restore_journal",
    "exercises", "day_templates", "day_template_items", "sessions", "sets", "bodyweight_logs", "muscle_targets"))


class Refusal(ValueError):
    pass


def require(value, reason):
    if not value:
        raise Refusal(reason)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def encoded(value):
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def regular_relative(value):
    require(isinstance(value, str) and re.fullmatch(r"[A-Za-z0-9_./-]+", value) and
            not value.startswith("/") and all(part not in ("", ".", "..") for part in value.split("/")),
            "unrecognized_owned_relative_path")
    return value


def exclusive(path, data):
    with Path(path).open("xb") as stream:
        os.chmod(path, 0o600)
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())


def source(host):
    revision = host.command(["git", "-C", host.APP, "rev-parse", "HEAD"]).stdout.strip()
    require(re.fullmatch(r"[a-f0-9]{40}", revision), "source_revision_required")
    require(not host.command(["git", "-C", host.APP, "status", "--porcelain",
                              "--untracked-files=normal"]).stdout.strip(),
            "commit_reviewed_source_before_documents_proof")
    return revision


def documents_build_arguments(environment):
    flavor, run, revision, version = (environment.get(name, "") for name in
        ("ALKION_FLAVOR", "ALKION_PROOF_RUN", "ALKION_PROOF_SOURCE", "ALKION_PROOF_VERSION"))
    require(flavor in VARIANTS and re.fullmatch(r"[a-f0-9]{32}", run) and
            re.fullmatch(r"[a-f0-9]{40}", revision) and re.fullmatch(r"[0-9]{1,10}", version) and
            1 <= int(version) <= 2099999999, "explicit_documents_build_inputs_required")
    return ["fvm", "flutter", "build", "apk", "--debug", "--no-pub", "--flavor", flavor,
            "--target-platform", "android-x64", "--target", "integration_test/android_documents_test.dart",
            "--build-number", version, "--dart-define=ALKION_PROOF_RUN=" + run,
            "--dart-define=ALKION_PROOF_SOURCE=" + revision]


def lifecycle_floor(lifecycle, updates, driver, receipt):
    require(isinstance(lifecycle, dict) and lifecycle.get("format") == "alkion-android-run/1" and
            lifecycle.get("phase") == "lifecycle-initial" and lifecycle.get("initial_lifecycle_phase") == "PASS" and
            lifecycle.get("overall") == "IN_PROGRESS" and not lifecycle.get("error") and
            isinstance(lifecycle.get("pending"), dict) and
            all(lifecycle.get(key) == receipt[key] for key in ("run_id", "avd", "serial")) and
            lifecycle.get("base_source_commit") == updates.get("source_commit") and
            updates.get("base_source_commit") == driver.get("source_commit") and
            re.fullmatch(r"[a-f0-9]{40}", lifecycle.get("source_commit", "")),
            "accepted_current_lifecycle_required")
    installed = lifecycle.get("installed", {})
    require(isinstance(installed, dict) and set(installed) == set(PACKAGES), "lifecycle_installed_set_mismatch")
    require(set(lifecycle.get("lifecycle", {})) == set(VARIANTS.values()), "lifecycle_variants_incomplete")
    for package in VARIANTS.values():
        value = lifecycle["lifecycle"][package]
        require(isinstance(value, dict) and value.get("initial_lifecycle") == "PASS", "lifecycle_variant_not_pass")
        for phase in ("prepare", "rest", "finish"):
            report = value.get(phase, {})
            require(isinstance(report, dict) and report.get("format") == "alkion-android-lifecycle-checkpoint/1" and
                    report.get("run_id") == receipt["run_id"] and report.get("application_id") == package and
                    report.get("phase") == phase and report.get("complete") is True and report.get("closed") is True and
                    report.get("result") == "PASS" and not report.get("failures") and
                    re.fullmatch(r"[a-f0-9]{64}", report.get("state_digest", "")) and
                    all(report.get(key) == updates["updates"][package]["verify"].get(key) for key in
                        ("profile_id", "installation_id", "generation", "database_relative")),
                    "closed_lifecycle_checkpoint_required")
        require(value["finish"].get("draft") is None, "finished_lifecycle_draft_remains")
        require(isinstance(value.get("peer_covered_bytes"), dict) and
                set(value["peer_covered_bytes"]) == set(VARIANTS.values()) - {package} and
                all(isinstance(v, dict) and re.fullmatch(r"[a-f0-9]{64}", v.get("before", "")) and
                    v.get("before") == v.get("after") for v in value["peer_covered_bytes"].values()),
                "lifecycle_peer_preservation_missing")
    for package, facts in installed.items():
        require(isinstance(facts, dict) and facts.get("package") == package and
                type(facts.get("version_code")) is int and 1 <= facts["version_code"] < 2099999999 and
                all(re.fullmatch(r"[a-f0-9]{64}", facts.get(key, "")) for key in
                    ("apk_sha256", "certificate_sha256")) and
                facts["certificate_sha256"] == updates["installed"][package]["certificate_sha256"],
                "lifecycle_artifact_binding_missing")
        if package == PACKAGES[0]:
            require(facts == driver["installed"][package], "lifecycle_neighbor_apk_changed")
        else:
            require(facts["version_code"] > updates["installed"][package]["version_code"],
                    "lifecycle_floor_not_after_a2")
    return installed


@dataclass
class Prepared:
    args: object
    receipt: dict
    output: Path
    driver: dict
    updates: dict
    lifecycle: dict
    installed: dict
    metadata: dict
    revision: str
    receipt_paths: tuple


def prepare(host, args):
    receipt, output = host.receipt_guard(args)
    require((args.sdk / "platform-tools/adb").is_file(), "adb_required")
    paths = []
    for name in ("driver_run", "updates_run", "base_run"):
        require(getattr(args, name, None), "explicit_documents_receipt_chain_required")
        paths.append(host.temporary_path(getattr(args, name), must_exist=True))
    require(len(set(paths)) == 3, "distinct_documents_receipts_required")
    driver, updates, lifecycle = [host.read_json(path, JSON_LIMIT) for path in paths]
    driver_contract = host.driver_continuation_contract(driver, receipt)
    a2_metadata = host.lifecycle_contract(updates, receipt)
    require(updates.get("base_driver_contract") == driver_contract, "a2_driver_contract_changed")
    floor = lifecycle_floor(lifecycle, updates, driver, receipt)
    host.toolchain(args)
    revision = source(host)
    saved = {}
    for flavor, package in VARIANTS.items():
        for path, expected in ((paths[0].parent / ("driver-" + flavor + ".apk"), driver["installed"][package]),
                               (paths[1].parent / (flavor + "-verify.apk"), updates["installed"][package]),
                               (paths[2].parent / (flavor + "-finish.apk"), floor[package])):
            host.temporary_path(str(path), must_exist=True)
            require(host.apk_facts(args, path, package) == expected, "retained_campaign_apk_changed")
        saved[package] = dict(floor[package])
    neighbor = paths[0].parent / "neighbor-build/synthetic-neighbor.apk"
    host.temporary_path(str(neighbor), must_exist=True)
    saved[PACKAGES[0]] = host.apk_facts(args, neighbor, PACKAGES[0])
    require(saved == floor, "current_lifecycle_apk_mismatch")
    host.device_platform_guard(args)
    host.installed_matches(args, saved)
    metadata = {}
    for package in PACKAGES:
        metadata[package] = host.package_metadata(args, package)
        require(metadata[package]["version_code"] == saved[package]["version_code"] and
                type(metadata[package].get("uid")) is int and 10000 <= metadata[package]["uid"] < 100000,
                "live_campaign_metadata_mismatch")
        if package in VARIANTS.values():
            require(metadata[package]["uid"] == a2_metadata[package]["uid"], "lifecycle_uid_changed")
            absent(host, args, package, "files/android-documents-proof")
    require(len({v["uid"] for v in metadata.values()}) == 3, "campaign_uid_collision")
    query = host.adb(args, "shell", "pm", "path", PROVIDER, check=False)
    require(query.returncode in (0, 1) and not query.stderr.strip() and not query.stdout.strip(),
            "preexisting_documents_provider")
    return Prepared(args, receipt, output, driver, updates, lifecycle, saved, metadata, revision, tuple(paths))


# Fixed programs run as the exact debug package. Non-PTY shell-v2 preserves
# binary streams and remote exit status; exec-out loses that status.
def remote(host, args, package, program, *arguments, data=None):
    require(package in (*PACKAGES, PROVIDER), "unrecognized_documents_package")
    argv = ["run-as", package, "/system/bin/sh", "-c", program, "alkion-documents", *map(str, arguments)]
    return host.command([args.sdk / "platform-tools/adb", "-s", args.serial, "shell", "-T", shlex.join(argv)],
                        binary=True, input=data, check=False, timeout=60)


# A run-as refusal never runs the program. Programs that print nothing on
# success must therefore also have empty stdout, and printed content beginning
# with run-as's own diagnostic prefix is refused rather than parsed.
RUN_AS_DIAGNOSTIC = b"run-as: "


def quiet(result):
    return result.returncode == 0 and not result.stdout and not result.stderr


def bounded(value):
    """Evidence text that keeps both the head and the tail of a long stream."""
    text = value.decode(errors="replace") if isinstance(value, bytes) else value if isinstance(value, str) else ""
    if len(text) <= EVIDENCE_TEXT:
        return text
    half = EVIDENCE_TEXT // 2
    return text[:half] + "\n[... " + str(len(text) - 2 * half) + " characters omitted ...]\n" + text[-half:]


def summary(value, limit=1000):
    text = bounded(value).strip()
    return text if len(text) <= limit else text[:600] + " [...] " + text[-(limit - 607):]


# adb client (packages/modules/adb client/adb_install.cpp and incremental.cpp):
# a streamed install prints "Performing Streamed Install" and then the device's
# status line, which must start with "Success" (the shell prints exactly that).
# An incremental install prints "Performing Incremental Install", relays device
# output until "Success" or "Failure [", then "Install command complete in N ms".
# Line order and extra progress or timing lines are not pinned and stay in the
# evidence: require exit 0, no "Failure" in either stream, and exactly one
# stdout line equal to "Success". An incremental failure falling back to a
# streamed install prints a Failure line and is refused.
def install_succeeded(result):
    stdout = result.stdout.decode(errors="replace") if isinstance(result.stdout, bytes) else result.stdout or ""
    stderr = result.stderr.decode(errors="replace") if isinstance(result.stderr, bytes) else result.stderr or ""
    return (result.returncode == 0 and "Failure" not in stdout and "Failure" not in stderr and
            stdout.splitlines().count("Success") == 1)


def enabled_components(dump):
    """Components listed under dumpsys package enabledComponents/disabledComponents blocks."""
    blocks, current = {"enabled": [], "disabled": []}, None
    for line in dump.splitlines():
        stripped, indent = line.strip(), len(line) - len(line.lstrip())
        if stripped in ("enabledComponents:", "disabledComponents:"):
            current = (blocks[stripped[:-len("Components:")]], indent)
        elif current and stripped and indent > current[1] and re.fullmatch(r"[A-Za-z0-9_.$]+", stripped):
            current[0].append(stripped)
        else:
            current = None
    return blocks


def namespace_pin(control, flavor):
    return (control["run_id"] + "\n" + flavor + "\n" + str(control["length"]) + "\n" + control["sha256"]).encode()


def unfreeze_provider(evidence):
    """Keep the cached provider's FileObserver live for the next namespace.

    The cached-app freezer defers its inotify delivery, so DocumentsUI would keep
    stale roots. ActivityManagerShellCommand.runFreeze prints the process, pid
    and sticky flag; sticky keeps it unfrozen for the process lifetime.
    """
    pid = evidence.host.app_pid(evidence.prepared.args, PROVIDER)
    require(pid is not None and pid == evidence.provider_pid, "provider_process_changed_preserve_failed_campaign")
    result = evidence.native("shell", "am", "unfreeze", "--sticky", str(pid), check=False)
    expected = "Unfreezing process " + PROVIDER + " (" + str(pid) + ") sticky=true\n"
    require(result.returncode == 0 and result.stdout == expected and not result.stderr,
            "provider_unfreeze_refused:" + summary(result.stderr or result.stdout))
    evidence.provider_alive()
    return {"pid": pid, "argv": ["shell", "am", "unfreeze", "--sticky", str(pid)], "stdout": result.stdout,
            "intervention": "deliberate harness unfreeze of the synthetic provider process"}


def await_namespace(evidence, flavor, root, pin, timeout=15):
    """The provider's own load writes input.pin before announcing a new root."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        observed = evidence.read(PROVIDER, root + "/input.pin", 4096, flavor + "-discovered-pin", optional=True)
        if observed == pin:
            return
        # The pin is created, then written: only a strict prefix may still grow.
        require(observed is None or pin.startswith(observed), "provider_namespace_input_changed")
        time.sleep(0.1)
    raise Refusal("provider_namespace_not_observed")


def enable_provider(evidence):
    """Shell enable of the test-only provider with retained raw output and a readback."""
    result = evidence.native("shell", "pm", "enable", "--user", "0", COMPONENT, check=False)
    require(result.returncode == 0 and result.stdout == PROVIDER_ENABLED and not result.stderr,
            "provider_enable_refused:" + summary(result.stderr or result.stdout))
    dump = evidence.native("shell", "dumpsys", "package", PROVIDER, check=False)
    blocks = enabled_components(dump.stdout if dump.returncode == 0 and not dump.stderr.strip() else "")
    require(blocks["enabled"].count(PROVIDER_CLASS) == 1 and PROVIDER_CLASS not in blocks["disabled"],
            "provider_enable_not_observed")


NO_LINKS = 'p=""; oldIFS="$IFS"; IFS=/; for part in $1; do p="${p:+$p/}$part"; test ! -L "$p" || exit 4; done; IFS="$oldIFS"; '


def absent(host, args, package, path):
    regular_relative(path)
    result = remote(host, args, package, NO_LINKS + 'test ! -e "$1" && test ! -L "$1"', path)
    require(quiet(result), "documents_owned_path_already_present")


class Evidence:
    def __init__(self, host, prepared):
        self.host, self.prepared = host, prepared
        self.output = prepared.output
        self.counter = 0
        self.provider_pid = None
        self.publisher = publish.Session(host, prepared.args, getattr(prepared.args, "_publisher", None),
                                         prepared.receipt["run_id"], self.keep)

    def keep(self, name, data):
        self.counter += 1
        path = self.output / (str(self.counter).zfill(4) + "-" + name)
        exclusive(path, data if isinstance(data, bytes) else encoded(data))
        return path

    def read(self, package, path, bound, name, *, optional=False):
        regular_relative(path)
        require(type(bound) is int and 0 < bound <= LIMIT, "documents_read_bound_invalid")
        result = remote(self.host, self.prepared.args, package, NO_LINKS +
                        'test -e "$1" || exit 3; test -f "$1" || exit 4; '
                        'test "$(wc -c < "$1")" -le "$2" || exit 5; cat "$1"', path, bound)
        self.keep(name + ".stdout", result.stdout)
        self.keep(name + ".stderr", result.stderr)
        require(not result.stdout.startswith(RUN_AS_DIAGNOSTIC), "documents_run_as_diagnostic:" + path)
        require(len(result.stdout) <= bound, "documents_remote_read_exceeded_bound")
        if optional and result.returncode == 3 and not result.stdout and not result.stderr:
            return None
        require(result.returncode == 0 and not result.stderr, "documents_owned_read_failed:" + path)
        return result.stdout

    def native(self, *tail, check=True, **options):
        """Serial-scoped adb with argv, status and bounded streams retained before any check."""
        argv = list(map(str, tail))
        try:
            result = self.host.adb(self.prepared.args, *tail, check=False, **options)
        except subprocess.TimeoutExpired as error:
            self.keep("native-command.json", {"argv": argv, "code": None, "timeout_seconds": error.timeout,
                                              "stdout": bounded(error.stdout), "stderr": bounded(error.stderr),
                                              "completion": "UNKNOWN; no retry"})
            raise
        self.keep("native-command.json", {"argv": argv, "code": result.returncode, "stdout": bounded(result.stdout),
                                          "stderr": bounded(result.stderr), "stdout_length": len(result.stdout),
                                          "stderr_length": len(result.stderr)})
        require(not check or result.returncode == 0,
                "native_command_failed:" + " ".join(argv[:4]) + ":" + summary(result.stderr or result.stdout))
        return result

    def bind_publisher(self, package, uid=None):
        """Bootstrap once after the package's qualified install; later calls are free."""
        try:
            return self.publisher.ensure(package, uid)
        except publish.Refusal as error:
            raise Refusal("documents_exclusive_write_failed:" + str(error)) from error

    def write(self, package, path, data, name):
        regular_relative(path)
        require(len(data) <= LIMIT, "documents_write_exceeded_bound")
        self.keep(name, data)
        partial = path + ".partial-" + os.urandom(16).hex()
        try:
            publish.relative_pair(partial, path)
        except publish.Refusal as error:
            raise Refusal("documents_exclusive_write_failed:" + str(error)) from error
        self.bind_publisher(package, self.prepared.metadata.get(package, {}).get("uid"))
        result = remote(self.host, self.prepared.args, package, NO_LINKS +
                        'umask 077; set -C; cat > "$1"', partial, data=data)
        self.keep(name + ".transport", {"code": result.returncode, "stderr": result.stderr.decode(errors="replace"),
                                       "partial_relative": partial, "final_relative": path})
        require(quiet(result), "documents_exclusive_write_failed")
        require(self.read(package, partial, max(1, len(data)), name + "-closed-partial") == data,
                "documents_closed_partial_changed")
        # Same-directory kernel no-replace rename of the closed partial. Success
        # consumes it; a refused or uncertain publication keeps every remaining
        # name. The publisher retains context, raw reply and final readback.
        try:
            self.publisher.publish(package, partial, path, data, name, self.read)
        except publish.Refusal as error:
            raise Refusal("documents_exclusive_write_failed:" + str(error)) from error

    def json(self, package, path, name, *, optional=False, bound=32768):
        raw = self.read(package, path, bound, name, optional=optional)
        if raw is None:
            return None
        value = json.loads(raw)
        require(isinstance(value, dict), "documents_json_object_required")
        return value

    def provider_alive(self):
        pid = self.host.app_pid(self.prepared.args, PROVIDER)
        require(pid is not None and (self.provider_pid is None or pid == self.provider_pid),
                "provider_process_changed_preserve_failed_campaign")
        self.provider_pid = pid


def validate_phase(value, run, revision, flavor):
    package = VARIANTS[flavor]
    require(value.get("format") == "alkion-android-documents-phase/1" and
            value.get("run_id") == run and value.get("source_commit") == revision and
            value.get("application_id") == package and value.get("variant") == flavor and
            value.get("provider_package") == PROVIDER and value.get("provider_authority") == AUTHORITY and
            type(value.get("sequence")) is int and 0 <= value["sequence"] <= len(CASES),
            "documents_phase_identity_mismatch")
    require(value.get("state") != "failed", "adapter_failed_preserve_documents_evidence")
    return value


def wait_phase(evidence, flavor, sequence, case, state, previous=None, timeout=90):
    prepared = evidence.prepared
    run = prepared.receipt["run_id"]
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = evidence.json(VARIANTS[flavor], "files/android-documents-proof/" + run + "/phase.json",
                              flavor + "-phase", optional=True)
        if value is not None:
            validate_phase(value, run, prepared.revision, flavor)
            actual = (value.get("sequence"), value.get("case"), value.get("state"))
            if actual == (sequence, case, state):
                return value
            require(previous is not None and actual == previous, "documents_phase_reordered")
        time.sleep(0.1)
    raise Refusal("documents_phase_timeout:" + case + ":" + state)


def ack(evidence, flavor, phase, action, **detail):
    require(action in ("seeded", "armed", "observed"), "documents_ack_action_invalid")
    validate_phase(phase, evidence.prepared.receipt["run_id"], evidence.prepared.revision, flavor)
    require((phase["sequence"], phase.get("case")) == (0, "seed") if action == "seeded" else
            phase["sequence"] > 0 and phase.get("case") == list(CASES)[phase["sequence"] - 1],
            "documents_ack_case_sequence_mismatch")
    require(phase["state"] == {"seeded": "seed_provider", "armed": "awaiting_arm", "observed": "awaiting_observed"}[action],
            "documents_ack_before_adapter_phase")
    value = {key: phase[key] for key in ("run_id", "source_commit", "application_id", "variant", "sequence", "case")}
    value.update(format="alkion-android-documents-ack/1", action=action, **detail)
    path = "files/android-documents-proof/" + phase["run_id"] + "/ack-" + str(phase["sequence"]).zfill(3) + "-" + action + ".json"
    evidence.write(VARIANTS[flavor], path, encoded(value), flavor + "-ack-" + action + ".json")


def seed_provider(evidence, flavor, phase, *, first):
    run = evidence.prepared.receipt["run_id"]
    namespace = run + "-" + flavor
    root = "files/proof-runs/" + namespace
    expected = {"format": "alkion-synthetic-documents/1", "run_id": run, "variant": flavor,
                "length": phase.get("length"), "sha256": phase.get("sha256")}
    require(phase.get("provider_control") == expected and
            phase.get("provider_control_relative") == root + "/control.json" and
            phase.get("provider_input_relative") == root + "/input.alkionbackup" and
            type(expected["length"]) is int and 128 * 1024 < expected["length"] <= LIMIT and
            re.fullmatch(r"[a-f0-9]{64}", expected["sha256"] or ""), "unbound_provider_seed")
    relative = phase.get("source_relative", "")
    prefix = "android-documents-proof/" + run + "/backups/"
    require(relative.startswith(prefix) and re.fullmatch(r"alkion-backup-[a-f0-9]{8}-[0-9]{8}T[0-9]{6}Z-[a-f0-9]{6}[.]alkionbackup", relative[len(prefix):]),
            "provider_seed_source_escaped")
    data = evidence.read(VARIANTS[flavor], "files/" + relative, LIMIT, flavor + "-source-backup")
    require(len(data) == expected["length"] and digest(data) == expected["sha256"], "provider_seed_source_changed")
    stage = "files/proof-runs/.stage-" + namespace
    setup = remote(evidence.host, evidence.prepared.args, PROVIDER,
                   'umask 077; for p in files files/proof-runs; do test ! -L "$p" || exit 4; '
                   'if test ! -e "$p"; then mkdir -m 700 "$p" || exit 4; fi; '
                   'test -d "$p" && test "$(stat -c %a "$p")" = 700 && '
                   'test "$(stat -c %u "$p")" = "$(id -u)" || exit 4; done; '
                   'test ! -e "$2" && test ! -L "$2" || exit 4; mkdir -m 700 "$1"', stage, root)
    evidence.keep(flavor + "-namespace-stage", {"code": setup.returncode, "stderr": setup.stderr.decode(errors="replace")})
    require(quiet(setup), "provider_namespace_not_fresh_owned")
    evidence.write(PROVIDER, stage + "/control.json", encoded(expected), flavor + "-control.json")
    evidence.write(PROVIDER, stage + "/input.alkionbackup", data, flavor + "-provider-input")
    require(evidence.read(PROVIDER, stage + "/control.json", 4096, flavor + "-control-readback") == encoded(expected) and
            evidence.read(PROVIDER, stage + "/input.alkionbackup", LIMIT, flavor + "-input-readback") == data,
            "provider_staged_namespace_changed")
    # Only this serialized host writes namespaces. -n plus postconditions refuses
    # adoption/replacement; a leftover staging directory stays as failed evidence.
    publish = remote(evidence.host, evidence.prepared.args, PROVIDER, NO_LINKS +
                     'test -d "$1" && test ! -e "$2" && test ! -L "$2" || exit 4; '
                     'n=0; for p in files/proof-runs/*; do test -e "$p" || continue; '
                     'name="${p##*/}"; case "$name" in *-dev|*-supported) n=$((n+1));; *) exit 4;; esac; done; '
                     'test "$n" -lt 16 || exit 6; mv -n "$1" "$2" && test ! -e "$1" && test -d "$2"', stage, root)
    evidence.keep(flavor + "-namespace-publish", {"code": publish.returncode, "stderr": publish.stderr.decode(errors="replace")})
    require(quiet(publish), "provider_namespace_publication_refused")
    if first:
        evidence.native("shell", "cmd", "package", "unstop", "--user", "0", PROVIDER)
        enable_provider(evidence)
    else:
        await_namespace(evidence, flavor, root, namespace_pin(expected, flavor))
    ack(evidence, flavor, phase, "seeded", provider_input_sha256=expected["sha256"])
    return expected


def validate_picker_phase(value, run, flavor, case):
    namespace = run + "-" + flavor
    require(value.get("intent") == ("ACTION_OPEN_DOCUMENT" if case.startswith("open-") else "ACTION_CREATE_DOCUMENT") and
            value.get("root_label") == "Alkion synthetic " + namespace and
            value.get("document_label") == namespace + "-" + case + ".alkionbackup" and
            value.get("picker_action") == ("cancel" if case.endswith("-cancel") else "select") and
            value.get("mime_type") == "application/octet-stream" and
            value.get("provider_receipt_relative") == "files/proof-runs/" + namespace + "/receipts/" + case + ".json",
            "documents_picker_labels_unbound")


def nodes(document, label):
    return [node for node in document.iter("node") if node.get("package") == "com.android.documentsui" and
            (node.get("text") == label or node.get("content-desc") == label)]


def click_targets(document, label):
    parents = {child: parent for parent in document.iter() for child in parent}
    targets = []
    for node in nodes(document, label):
        while node.get("clickable") != "true" and node in parents:
            node = parents[node]
        if node.get("clickable") == "true" and node.get("package") == "com.android.documentsui":
            targets.append(node)
    return targets


def click_label(evidence, document, label):
    choices = click_targets(document, label)
    require(len(choices) == 1, "unique_native_documents_label_missing:" + label)
    evidence.host.click_node(evidence.prepared.args, choices[0])


def foreground(evidence, package, name):
    raw = evidence.host.adb(evidence.prepared.args, "shell", "dumpsys", "activity", "activities").stdout
    evidence.keep(name + "-activity.txt", raw.encode())
    require(len(raw.encode()) <= JSON_LIMIT, "documents_activity_dump_too_large")
    resumed = re.findall(r"(?:mResumedActivity|topResumedActivity)\s*[:=]\s*ActivityRecord\{[^\n}]*\bu0\s+([^\s/]+)/", raw)
    return bool(resumed) and set(resumed) == {package}


CASE_BUDGET = 50  # Seconds after the picker phase, inside the adapter's 60-second wait.
BREADCRUMB = "com.android.documentsui:id/breadcrumb_text"


def selected_root(document, label):
    """Drawer closed; the label shows once as the breadcrumb and at most once as the toolbar title."""
    labelled = nodes(document, label)
    breadcrumbs = [node for node in labelled if node.get("resource-id") == BREADCRUMB]
    titles = [node for node in labelled if node.get("resource-id", "") == "" and node.get("class") == "android.widget.TextView"]
    return (not click_targets(document, label) and len(breadcrumbs) == 1 and len(titles) <= 1 and
            len(labelled) == len(breadcrumbs) + len(titles) and
            all(node.get("visible-to-user") == "true" and node.get("clickable") == "false" for node in labelled))


def save_ready(document):
    labels = [label for label in ("SAVE", "Save") if nodes(document, label)]
    targets = click_targets(document, labels[0]) if len(labels) == 1 else []
    return (len(targets) == 1 and targets[0].get("enabled") == "true" and
            targets[0].get("visible-to-user") == "true")


def picker_document(evidence, name, ready=lambda document: True, *, caller=None, deadline=None):
    for attempt in range(12):
        require(deadline is None or time.monotonic() < deadline, "documentsui_case_budget_exceeded:" + name)
        unique = str(evidence.counter + 1).zfill(4) + "-" + name + "-" + str(attempt)
        try:
            # The observer's bounded readiness waits for DocumentsUI focus. Only a
            # wait that saw no focus or the still-focused calling app is retried.
            document = evidence.host.ui_document(evidence.prepared.args, evidence.output, unique,
                                                 expected_package="com.android.documentsui")
        except observer.FocusNotReady as error:
            if not (error.transient_null or
                    (caller is not None and error.owners and set(error.owners) <= {None, caller})):
                raise
            time.sleep(1)
            continue
        if foreground(evidence, "com.android.documentsui", unique) and any(
                node.get("package") == "com.android.documentsui" for node in document.iter("node")):
            if evidence.provider_pid is None and evidence.host.app_pid(evidence.prepared.args, PROVIDER) is None:
                time.sleep(1)
                continue
            evidence.provider_alive()
            if ready(document):
                return document
        time.sleep(1)
    raise Refusal("documentsui_checkpoint_unavailable:" + name)


def drive_picker(evidence, phase):
    case, flavor = phase["case"], phase["variant"]
    bounds = {"caller": VARIANTS[flavor], "deadline": time.monotonic() + CASE_BUDGET}
    document = picker_document(evidence, flavor + "-" + case + "-picker", **bounds)
    if not click_targets(document, phase["root_label"]):
        candidates = [node for node in document.iter("node") if node.get("package") == "com.android.documentsui" and
                      node.get("clickable") == "true" and node.get("content-desc") in
                      ("Show roots", "Open navigation drawer")]
        require(len(candidates) == 1, "documentsui_root_navigation_unavailable")
        evidence.host.click_node(evidence.prepared.args, candidates[0])
        document = picker_document(evidence, flavor + "-" + case + "-roots",
                                   lambda doc: bool(click_targets(doc, phase["root_label"])), **bounds)
    click_label(evidence, document, phase["root_label"])
    document = picker_document(evidence, flavor + "-" + case + "-exact-root", lambda doc:
                               selected_root(doc, phase["root_label"]) and
                               (case.endswith("-cancel") or bool(nodes(doc, phase["document_label"]))) and
                               (not case.startswith("save-") or save_ready(doc)), **bounds)
    require(selected_root(document, phase["root_label"]), "documentsui_selected_root_unproven")
    if case.endswith("-cancel"):
        evidence.host.adb(evidence.prepared.args, "shell", "input", "keyevent", "KEYCODE_BACK")
    elif case.startswith("open-"):
        click_label(evidence, document, phase["document_label"])
    else:
        titles = [node for node in nodes(document, phase["document_label"]) if node.get("class") == "android.widget.EditText"]
        require(len(titles) == 1, "documentsui_exact_create_filename_missing")
        save = [label for label in ("SAVE", "Save") if nodes(document, label)]
        require(len(save) == 1, "documentsui_save_action_ambiguous")
        click_label(evidence, document, save[0])


def validate_receipt(value, case, control):
    require(isinstance(value, dict) and value.get("format") == "alkion-synthetic-document-receipt/1" and
            all(value.get(key) == control[key] for key in ("run_id", "variant")) and value.get("case") == case and
            value.get("input_sha256") == control["sha256"] and value.get("input_length") == control["length"],
            "provider_receipt_identity_mismatch")
    events = value.get("events")
    require(isinstance(events, list) and 0 < len(events) <= 16 and all(isinstance(e, dict) and
            e.get("operation") in ("create", "read", "write") and type(e.get("length")) is int and
            0 <= e["length"] <= LIMIT for e in events), "provider_receipt_trace_invalid")
    def event(operation, state, *, pipe=False, exact=False, changed=False):
        return any(e.get("operation") == operation and e.get("state") == state and
                   (not pipe or e.get("reliable_pipe") is True) and
                   (not exact or (e.get("sha256") == control["sha256"] and e["length"] == control["length"])) and
                   (not changed or (re.fullmatch(r"[a-f0-9]{64}", e.get("sha256") or "") and
                                    e["sha256"] != control["sha256"] and e["length"] == control["length"])) for e in events)
    if case.startswith("save-"):
        require(value.get("output_retained") is True and type(value.get("output_length")) is int and
                0 <= value["output_length"] <= LIMIT, "provider_output_not_retained")
        created = event("create", "created")
    else:
        created = True
    valid = {
        "open-good": lambda: event("read", "complete", pipe=True, exact=True),
        "open-denied": lambda: event("read", "denied"),
        "open-error": lambda: event("read", "interrupted", pipe=True),
        "open-short": lambda: event("read", "complete", pipe=True) and any(e["length"] == control["length"] - 1 for e in events),
        "open-over-limit": lambda: event("read", "complete", pipe=True) or event("read", "peer_error", pipe=True),
        "open-corrupt": lambda: event("read", "complete", pipe=True, changed=True),
        "save-good": lambda: event("write", "complete", pipe=True, exact=True) and event("read", "complete", pipe=True, exact=True),
        "save-write-denied": lambda: event("write", "denied"),
        "save-write-interrupted": lambda: event("write", "interrupted", pipe=True),
        "save-readback-denied": lambda: event("write", "complete", pipe=True, exact=True) and event("read", "denied"),
        "save-readback-changed": lambda: event("write", "complete", pipe=True, exact=True) and event("read", "complete", pipe=True, changed=True),
    }
    require(case in valid and created and valid[case](), "provider_receipt_trace_incomplete")
    return value


def provider_observation(evidence, flavor, phase, control):
    root = "files/proof-runs/" + control["run_id"] + "-" + flavor
    evidence.provider_alive()
    pin = namespace_pin(control, flavor)
    require(evidence.read(PROVIDER, root + "/input.pin", 4096, flavor + "-input-pin") == pin and
            evidence.read(PROVIDER, root + "/control.json", 4096, flavor + "-immutable-control") == encoded(control) and
            digest(evidence.read(PROVIDER, root + "/input.alkionbackup", LIMIT, flavor + "-immutable-input")) == control["sha256"],
            "provider_namespace_input_changed")
    case = phase["case"]
    receipt_path = root + "/receipts/" + case + ".json"
    if case.endswith("-cancel"):
        require(evidence.json(PROVIDER, receipt_path, flavor + "-cancel-receipt", optional=True) is None,
                "cancelled_picker_has_provider_operation")
        deadline = time.monotonic() + 5
        while not foreground(evidence, VARIANTS[flavor], flavor + "-cancel-return"):
            require(time.monotonic() < deadline, "picker_cancellation_return_unproven")
            time.sleep(0.25)
        return {"provider_input_sha256": control["sha256"], "picker_cancelled": True, "provider_receipt": None}
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        receipt = evidence.json(PROVIDER, receipt_path, flavor + "-" + case + "-receipt", optional=True, bound=16384)
        if receipt is not None:
            try:
                validate_receipt(receipt, case, control)
                return {"provider_input_sha256": control["sha256"], "provider_receipt": receipt}
            except Refusal as error:
                if str(error) != "provider_receipt_trace_incomplete":
                    raise
        time.sleep(0.1)
    raise Refusal("provider_case_receipt_timeout:" + case)


def validate_report(value, run, revision, flavor, control, observed):
    require(isinstance(value, dict) and value.get("format") == "alkion-android-documents-proof/1" and
            value.get("phase") == "documents-provider" and value.get("run_id") == run and
            value.get("source_commit") == revision and value.get("application_id") == VARIANTS[flavor] and
            value.get("variant") == flavor and value.get("provider_package") == PROVIDER and
            value.get("provider_authority") == AUTHORITY and value.get("complete") is True and
            value.get("result") == "PASS" and not value.get("failures") and not value.get("error") and
            not value.get("failed_case"), "documents_terminal_report_failed")
    require(isinstance(value.get("cases"), dict) and set(value["cases"]) == set(CASES), "documents_terminal_cases_incomplete")
    for name, outcome in CASES.items():
        item = value["cases"][name]
        require(isinstance(item, dict) and item.get("result") == "PASS" and item.get("outcome") == outcome and
                item.get("originals_preserved") is True and item.get("selected_generation_unchanged") is True,
                "documents_terminal_case_object_failed:" + name)
    require(isinstance(value.get("provider_receipts"), dict) and value["provider_receipts"] == observed and
            set(observed) == set(CASES) - {"open-cancel", "save-cancel"}, "documents_terminal_receipts_mismatch")
    for name, receipt in observed.items():
        validate_receipt(receipt, name, control)
    require(isinstance(value.get("unrun"), list) and set(UNRUN) - {"provider_restart_reuse", "roots_cache_recovery"} <= set(value["unrun"]),
            "documents_terminal_unrun_claims_missing")
    return value


def collect_outputs(evidence, flavor):
    root = "files/proof-runs/" + evidence.prepared.receipt["run_id"] + "-" + flavor + "/outputs"
    result = remote(evidence.host, evidence.prepared.args, PROVIDER, NO_LINKS +
                    'test -e "$1" || exit 3; test -d "$1" || exit 4; ls -1A "$1"', root)
    evidence.keep(flavor + "-outputs-list.stdout", result.stdout)
    evidence.keep(flavor + "-outputs-list.stderr", result.stderr)
    require(not result.stdout.startswith(RUN_AS_DIAGNOSTIC), "documents_run_as_diagnostic:" + root)
    if result.returncode == 3 and not result.stdout and not result.stderr:
        return {}
    require(result.returncode == 0 and not result.stderr and len(result.stdout) <= 4096, "provider_outputs_listing_invalid")
    found = {}
    for name in result.stdout.decode().splitlines():
        match = re.fullmatch(r"(" + "|".join(OUTPUT_CASES) +
                             r")-([a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12})[.]partial", name)
        require(match is not None and match[1] not in found, "provider_output_name_or_replacement_invalid")
        data = evidence.read(PROVIDER, root + "/" + name, LIMIT, flavor + "-" + name)
        found[match[1]] = {"name": name, "length": len(data), "sha256": digest(data), "bytes": data}
    return found


def validate_outputs(outputs, control, observed):
    require(set(outputs) == set(OUTPUT_CASES), "provider_failed_outputs_missing")
    for case in OUTPUT_CASES:
        output = outputs[case]
        require(output["length"] == observed[case].get("output_length"), "provider_output_receipt_length_mismatch")
        if case == "save-write-denied":
            require(output["length"] == 0, "denied_provider_output_changed")
        elif case == "save-write-interrupted":
            require(output["length"] == 1, "interrupted_provider_output_changed")
        else:
            require(output["length"] == control["length"] and output["sha256"] == control["sha256"],
                    "completed_provider_output_changed")


def validate_receiving_report(report, control):
    def hash_value(value):
        return isinstance(value, str) and re.fullmatch(r"[a-f0-9]{64}", value)

    require(isinstance(report, dict), "host_receiving_report_mismatch")
    schema, inventory, container = (report.get(key) for key in ("schema", "inventory", "container"))
    # workflowSchemaRegistry registers the contiguous foundation/domain/workflow
    # versions 1..3; currentSchemaVersion alone names only the foundation.
    require(isinstance(schema, dict) and set(schema) == {"user_version", "application_id", "migrations", "sql_sha256"} and
            type(schema.get("user_version")) is int and 1 <= schema["user_version"] <= 3 and
            type(schema.get("application_id")) is int and schema["application_id"] == 0x414C4B31 and
            hash_value(schema.get("sql_sha256")) and isinstance(schema.get("migrations"), list) and
            len(schema["migrations"]) == schema["user_version"], "host_receiving_schema_mismatch")
    for version, migration in enumerate(schema["migrations"], 1):
        require(isinstance(migration, dict) and set(migration) == {"version", "digest"} and
                type(migration.get("version")) is int and migration["version"] == version and hash_value(migration.get("digest")),
                "host_receiving_schema_mismatch")
    require(isinstance(inventory, dict) and set(inventory) == {"tables", "rows", "sha256"} and
            type(inventory.get("rows")) is int and inventory["rows"] >= 0 and hash_value(inventory.get("sha256")) and
            isinstance(inventory.get("tables"), dict) and set(inventory["tables"]) == RECEIVING_TABLES,
            "host_receiving_inventory_mismatch")
    for table in inventory["tables"].values():
        require(isinstance(table, dict) and set(table) == {"rows", "sha256"} and
                type(table.get("rows")) is int and table["rows"] >= 0 and hash_value(table.get("sha256")),
                "host_receiving_inventory_mismatch")
    table_hashes = {name: value["sha256"] for name, value in inventory["tables"].items()}
    require(inventory["rows"] == sum(value["rows"] for value in inventory["tables"].values()) and
            inventory["sha256"] == digest(json.dumps(table_hashes, sort_keys=True, separators=(",", ":")).encode()),
            "host_receiving_inventory_mismatch")
    require(isinstance(container, dict) and set(container) == {"sha256", "length", "format", "version"} and
            container.get("sha256") == control["sha256"] and type(container.get("length")) is int and
            container["length"] == control["length"] and container.get("format") == "alkion-backup" and
            type(container.get("version")) is int and container["version"] == 1 and
            report.get("format") == "alkion-receiving-verification/1" and report.get("result") == "verified" and
            report.get("inventory_result") == "all_covered_rows_match" and
            report.get("storage_claim") == "receiving_file_verified; physically_off_device_location_requires_owner_evidence",
            "host_receiving_report_mismatch")
    return report


def receive_good(evidence, flavor, outputs, control):
    require(set(outputs) == set(OUTPUT_CASES), "provider_failed_outputs_missing")
    good = outputs["save-good"]
    require(good["length"] == control["length"] and good["sha256"] == control["sha256"], "received_provider_copy_changed")
    received = evidence.output / (flavor + "-received.alkionbackup")
    exclusive(received, good["bytes"])
    inspection = evidence.output / (flavor + "-receiving-inspection")
    result = evidence.host.command(["make", "-C", evidence.host.APP, "alkion-verify-backup",
                                    "ALKION_BACKUP=" + str(received), "ALKION_OUTPUT=" + str(inspection)], check=False, timeout=300)
    evidence.keep(flavor + "-receiving.stdout", result.stdout.encode())
    evidence.keep(flavor + "-receiving.stderr", result.stderr.encode())
    require(result.returncode == 0, "host_receiving_verifier_failed")
    report = evidence.host.read_json(inspection / "verification.json", JSON_LIMIT)
    return validate_receiving_report(report, control)


def validate_packaged_provider(tree):
    """Validate the expected component in the pinned SDK 36 aapt2 tree grammar."""
    reason = "packaged_provider_not_default_disabled"
    require(isinstance(tree, str) and 0 < len(tree) <= 65536, reason)
    elements, stack, namespaces = [], [], []
    for line in tree.splitlines():
        element = re.fullmatch(r"( *)E: ([A-Za-z][A-Za-z0-9_-]*) \(line=[0-9]+\)", line)
        if element:
            indent = len(element[1])
            while stack and stack[-1]["indent"] >= indent:
                stack.pop()
            node = {"name": element[2], "indent": indent, "parent": stack[-1] if stack else None, "attrs": []}
            elements.append(node)
            stack.append(node)
        elif line.lstrip().startswith("A: "):
            require(stack and len(line) - len(line.lstrip()) == stack[-1]["indent"] + 2, reason)
            stack[-1]["attrs"].append(line.strip())
        else:
            require(re.fullmatch(r"N: android=http://schemas[.]android[.]com/apk/res/android \(line=[0-9]+\)", line), reason)
            namespaces.append(line)
    roots = [node for node in elements if node["parent"] is None]
    providers = [node for node in elements if node["name"] == "provider"]
    applications = [node for node in elements if node["name"] == "application"]
    require(len(namespaces) == len(roots) == len(providers) == len(applications) == 1 and
            roots[0]["name"] == "manifest" and applications[0]["parent"] is roots[0] and
            providers[0]["parent"] is applications[0], reason)
    # Only a test-only package lets the shell enable the declared-disabled component.
    require([line for line in applications[0]["attrs"] if ":testOnly(" in line] == [TEST_ONLY],
            "packaged_provider_not_test_only")
    package = 'A: package="' + PROVIDER + '" (Raw: "' + PROVIDER + '")'
    require([line for line in roots[0]["attrs"] if line.startswith("A: package=")] == [package], reason)
    prefix = "A: http://schemas.android.com/apk/res/android:"
    expected = {
        prefix + 'name(0x01010003)=".SyntheticDocumentsProvider" (Raw: ".SyntheticDocumentsProvider")',
        prefix + 'permission(0x01010006)="android.permission.MANAGE_DOCUMENTS" (Raw: "android.permission.MANAGE_DOCUMENTS")',
        prefix + "enabled(0x0101000e)=false",
        prefix + "exported(0x01010010)=true",
        prefix + 'authorities(0x01010018)="' + AUTHORITY + '" (Raw: "' + AUTHORITY + '")',
        prefix + "grantUriPermissions(0x0101001b)=true",
    }
    require(len(providers[0]["attrs"]) == len(expected) and set(providers[0]["attrs"]) == expected, reason)


def build_provider(host, args, output):
    host.toolchain(args)
    require(not output.exists(), "provider_build_output_exists")
    fixture = host.APP / "tool/android_synthetic_documents"
    manifest = ET.parse(fixture / "AndroidManifest.xml").getroot()
    android = "{http://schemas.android.com/apk/res/android}"
    providers = manifest.findall("application/provider")
    applications = manifest.findall("application")
    require(len(applications) == 1 and applications[0].get(android + "testOnly") == "true",
            "provider_source_manifest_not_test_only")
    require(manifest.get("package") == PROVIDER and not manifest.findall("uses-permission") and len(providers) == 1 and
            providers[0].get(android + "enabled") == "false" and providers[0].get(android + "name") == ".SyntheticDocumentsProvider" and
            providers[0].get(android + "authorities") == AUTHORITY and
            providers[0].get(android + "permission") == "android.permission.MANAGE_DOCUMENTS" and
            providers[0].get(android + "exported") == "true" and providers[0].get(android + "grantUriPermissions") == "true",
            "provider_source_manifest_boundary_changed")
    user = host.temporary_path(os.environ.get("ANDROID_USER_HOME", ""), must_exist=True)
    key = user / "debug.keystore"
    require(key.is_file() and not key.is_symlink(), "disposable_debug_key_required")
    output.mkdir(mode=0o700)
    classes, dex = output / "classes", output / "dex"
    classes.mkdir(); dex.mkdir()
    tools = args.sdk / "build-tools/36.0.0"
    android_jar = args.sdk / "platforms/android-36/android.jar"
    java = Path(os.environ["JAVA_HOME"]) / "bin"
    commands = [
        [java / "javac", "--release", "8", "-classpath", android_jar, "-d", classes, fixture / "SyntheticDocumentsProvider.java"],
        [tools / "d8", "--min-api", "24", "--lib", android_jar, "--output", dex],
        [tools / "aapt2", "link", "-I", android_jar, "--manifest", fixture / "AndroidManifest.xml",
         "--min-sdk-version", "24", "--target-sdk-version", "36", "-o", output / "unsigned.apk"],
    ]
    for number, argv in enumerate(commands):
        if number == 1:
            argv += sorted(classes.rglob("*.class"))
        result = host.command(argv, check=False, timeout=120,
                              env=dict(os.environ, PATH=str(java) + os.pathsep + os.environ["PATH"]))
        exclusive(output / (str(number) + "-build.log"), (result.stdout + result.stderr).encode())
        require(result.returncode == 0, "provider_build_failed")
    with zipfile.ZipFile(output / "unsigned.apk", "a") as archive:
        archive.write(dex / "classes.dex", "classes.dex")
    host.command([tools / "zipalign", "-f", "4", output / "unsigned.apk", output / "aligned.apk"])
    apk = output / "synthetic-documents.apk"
    host.command([java / "java", "-jar", tools / "lib/apksigner.jar", "sign", "--ks", key,
                  "--ks-key-alias", "androiddebugkey", "--ks-pass", "pass:android", "--key-pass", "pass:android",
                  "--out", apk, output / "aligned.apk"])
    tree = host.command([tools / "aapt2", "dump", "xmltree", apk, "--file", "AndroidManifest.xml"]).stdout
    exclusive(output / "packaged-manifest.txt", tree.encode())
    validate_packaged_provider(tree)
    facts = host.apk_facts(args, apk, PROVIDER)
    require(facts["version_code"] == 1, "provider_fixture_version_changed")
    exclusive(output / "build.json", encoded(facts))
    return apk, facts


def provider_installed(evidence, facts, uid):
    host, args = evidence.host, evidence.prepared.args
    result = host.adb(args, "shell", "pm", "path", PROVIDER)
    lines = result.stdout.strip().splitlines()
    require(len(lines) == 1 and re.fullmatch(r"package:/data/app/[A-Za-z0-9_~+/.=-]+/base[.]apk", lines[0]) and
            ".." not in PurePosixPath(lines[0][8:]).parts, "provider_installed_apk_path_invalid")
    observed = host.adb(args, "shell", "sha256sum", lines[0][8:]).stdout.split()
    require(observed and observed[0] == facts["apk_sha256"] and
            host.package_metadata(args, PROVIDER) == {"uid": uid, "version_code": facts["version_code"]},
            "provider_installed_identity_changed")


def run(host, prepared):
    args, output, receipt = prepared.args, prepared.output, prepared.receipt
    require(source(host) == prepared.revision, "source_changed_before_documents_build")
    output.mkdir(mode=0o700)
    evidence = Evidence(host, prepared)
    state = {"format": "alkion-android-run/1", "phase": "documents-provider", "overall": "IN_PROGRESS",
             "run_id": receipt["run_id"], "avd": args.avd, "serial": args.serial,
             "source_commit": prepared.revision, "base_source_commit": prepared.lifecycle["source_commit"],
             "installed": dict(prepared.installed), "documents": {}, "documents_phase": "IN_PROGRESS",
             "pending": dict(prepared.lifecycle["pending"]), "unrun": list(UNRUN)}
    def save():
        data = encoded(state)
        evidence.keep("run-snapshot.json", data)
        partial = output / "run.partial"
        exclusive(partial, data)
        partial.replace(output / "run.json")
    save()
    for name, path in zip(("driver", "updates", "lifecycle"), prepared.receipt_paths):
        evidence.keep(name + "-base-run.json", path.read_bytes())
    evidence.keep("disposable-receipt.json", receipt)
    try:
        candidates = {}
        for flavor, package in VARIANTS.items():
            version = prepared.installed[package]["version_code"] + 1
            inputs = {"ALKION_FLAVOR": flavor, "ALKION_PROOF_RUN": receipt["run_id"],
                      "ALKION_PROOF_SOURCE": prepared.revision, "ALKION_PROOF_VERSION": str(version)}
            documents_build_arguments(inputs)
            built = host.command(["make", "-C", host.APP, "android-synthetic-documents-apk",
                                   *(key + "=" + value for key, value in inputs.items())], check=False, timeout=600)
            evidence.keep(flavor + "-build.log", (built.stdout + built.stderr).encode())
            require(built.returncode == 0, "documents_app_build_failed:" + flavor)
            apk = output / (flavor + "-documents.apk")
            shutil.copyfile(host.APP / "build/app/outputs/flutter-apk" / ("app-" + flavor + "-debug.apk"), apk)
            facts = host.apk_facts(args, apk, package)
            require(facts["version_code"] == version and
                    facts["certificate_sha256"] == prepared.installed[package]["certificate_sha256"],
                    "documents_candidate_version_or_signer_changed")
            candidates[package] = (apk, facts)
        provider_apk, provider_facts = build_provider(host, args, output / "provider-build")
        require(provider_facts["certificate_sha256"] == prepared.installed[PACKAGES[0]]["certificate_sha256"],
                "provider_disposable_signer_mismatch")
        require(source(host) == prepared.revision, "source_changed_during_documents_build")
        host.device_platform_guard(args)
        host.installed_matches(args, prepared.installed)
        for package in PACKAGES:
            require(host.package_metadata(args, package) == prepared.metadata[package], "campaign_metadata_changed_during_build")
        query = host.adb(args, "shell", "pm", "path", PROVIDER, check=False)
        require(query.returncode in (0, 1) and not query.stdout.strip() and not query.stderr.strip(), "provider_appeared_during_build")
        for package in VARIANTS.values():
            absent(host, args, package, "files/android-documents-proof")
            if host.app_pid(args, package) is not None:
                host.ordinary_kill(args, package, prepared.metadata[package]["uid"], output)
        originals = host.driver_neighbor_bytes(args, receipt, prepared.driver)
        baseline = {package: host.closed_profile_fingerprint(args, package, prepared.lifecycle["lifecycle"][package]["finish"])
                    for package in VARIANTS.values()}
        installed = evidence.native("install", "-t", provider_apk, check=False)
        require(install_succeeded(installed), "provider_install_failed:" + summary(installed.stderr or installed.stdout))
        provider_meta = host.package_metadata(args, PROVIDER)
        require(provider_meta["version_code"] == 1 and type(provider_meta.get("uid")) is int and
                10000 <= provider_meta["uid"] < 100000 and provider_meta["uid"] not in
                {v["uid"] for v in prepared.metadata.values()}, "provider_uid_or_version_invalid")
        state["provider"] = {**provider_facts, **provider_meta}; save()
        provider_installed(evidence, provider_facts, provider_meta["uid"])
        evidence.bind_publisher(PROVIDER, provider_meta["uid"])
        for index, (flavor, package) in enumerate(VARIANTS.items()):
            host.installed_matches(args, state["installed"])
            for peer in PACKAGES:
                require(host.package_metadata(args, peer) == {"uid": prepared.metadata[peer]["uid"],
                        "version_code": state["installed"][peer]["version_code"]}, "documents_peer_uid_or_version_changed")
            apk, facts = candidates[package]
            require(host.app_pid(args, package) is None, "documents_install_requires_absent_app_process")
            installed = evidence.native("install", "-r", apk, check=False)
            require(install_succeeded(installed), "documents_install_failed:" + summary(installed.stderr or installed.stdout))
            state["installed"][package] = facts; save()
            host.installed_matches(args, state["installed"])
            require(host.package_metadata(args, package) == {"uid": prepared.metadata[package]["uid"],
                    "version_code": facts["version_code"]}, "documents_update_changed_uid_or_version")
            evidence.bind_publisher(package, prepared.metadata[package]["uid"])
            if index > 0 and "provider_unfreeze" not in state:
                state["provider_unfreeze"] = unfreeze_provider(evidence); save()
            host.adb(args, "shell", "am", "start", "-W", "--user", "0", "-n", package + "/dev.animusstudio.alkion.MainActivity")
            phase = wait_phase(evidence, flavor, 0, "seed", "seed_provider")
            control = seed_provider(evidence, flavor, phase, first=index == 0)
            observed = {}
            previous = (0, "seed", "seed_provider")
            for sequence, case in enumerate(CASES, 1):
                phase = wait_phase(evidence, flavor, sequence, case, "awaiting_arm", previous)
                validate_picker_phase(phase, receipt["run_id"], flavor, case)
                ack(evidence, flavor, phase, "armed")
                phase = wait_phase(evidence, flavor, sequence, case, "picker", (sequence, case, "awaiting_arm"))
                validate_picker_phase(phase, receipt["run_id"], flavor, case)
                drive_picker(evidence, phase)
                phase = wait_phase(evidence, flavor, sequence, case, "awaiting_observed", (sequence, case, "picker"))
                require(phase.get("production_outcome") == CASES[case], "adapter_production_outcome_mismatch")
                detail = provider_observation(evidence, flavor, phase, control)
                ack(evidence, flavor, phase, "observed", **detail)
                if detail["provider_receipt"] is not None:
                    observed[case] = detail["provider_receipt"]
                previous = (sequence, case, "awaiting_observed")
            deadline = time.monotonic() + 30
            report = None
            while report is None and time.monotonic() < deadline:
                report = evidence.json(package, "files/android-documents-proof/" + receipt["run_id"] + "/documents-report.json",
                                       flavor + "-terminal-report", optional=True, bound=JSON_LIMIT)
                if report is None:
                    time.sleep(0.1)
            validate_report(report, receipt["run_id"], prepared.revision, flavor, control, observed)
            outputs = collect_outputs(evidence, flavor)
            validate_outputs(outputs, control, observed)
            receiving = receive_good(evidence, flavor, outputs, control)
            if host.app_pid(args, package) is not None:
                host.ordinary_kill(args, package, prepared.metadata[package]["uid"], output)
            require(host.driver_neighbor_bytes(args, receipt, prepared.driver) == originals, "documents_driver_or_neighbor_changed")
            for peer in VARIANTS.values():
                require(host.closed_profile_fingerprint(args, peer, prepared.lifecycle["lifecycle"][peer]["finish"]) == baseline[peer],
                        "documents_existing_profile_changed")
            provider_installed(evidence, provider_facts, provider_meta["uid"])
            evidence.provider_alive()
            state["documents"][flavor] = {"report": report, "receiving": receiving,
                "provider_outputs": {name: {key: item[key] for key in ("name", "length", "sha256")} for name, item in outputs.items()},
                "normal_profiles_unchanged": True, "provider_pid": evidence.provider_pid}
            save()
        host.installed_matches(args, state["installed"])
        for package in PACKAGES:
            require(host.package_metadata(args, package) == {"uid": prepared.metadata[package]["uid"],
                    "version_code": state["installed"][package]["version_code"]}, "documents_final_uid_or_version_changed")
        state["documents_phase"] = "PASS"
        state["pending"]["documents_provider_restore"] = "PARTIAL: 13 fresh-provider cases per variant and host receiving verification PASS; see unrun"
        save()
        return state
    except Exception as error:
        state["documents_phase"] = "FAIL"
        state["error"] = str(error)
        state["retention_errors"] = []
        # No cleanup, restart, new grant, replacement or completion ack on failure.
        for flavor in VARIANTS:
            try:
                collect_outputs(evidence, flavor)
            except Exception as retained_error:
                state["retention_errors"].append(str(retained_error))
            for name in ("phase.json", "phase.partial", "documents-report.json", "documents-report.partial"):
                try:
                    evidence.read(VARIANTS[flavor], "files/android-documents-proof/" + receipt["run_id"] + "/" + name,
                                  JSON_LIMIT, flavor + "-failed-" + name, optional=True)
                except Exception as retained_error:
                    state["retention_errors"].append(str(retained_error))
            root = "files/proof-runs/" + receipt["run_id"] + "-" + flavor
            for case in CASES:
                for suffix in (".json", ".partial"):
                    try:
                        evidence.read(PROVIDER, root + "/receipts/" + case + suffix, 16384,
                                      flavor + "-failed-provider-" + case + suffix, optional=True)
                    except Exception as retained_error:
                        state["retention_errors"].append(str(retained_error))
        save()
        raise
