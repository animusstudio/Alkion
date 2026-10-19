#!/usr/bin/env bash
set -euo pipefail
exec python3 - "$0" "$@" <<'PY'
"""Explicit disposable-emulator proof. No discovery, clearing or uninstall."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import shlex
import stat
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace
import zipfile
import xml.etree.ElementTree as ET

SCRIPT = Path(sys.argv[1]).resolve()
APP = SCRIPT.parent.parent
PACKAGES = ("io.github.psychonaut0.reps", "dev.animusstudio.alkion.dev", "dev.animusstudio.alkion")
CASES = {"directory_durability", "atomic_outbox_replay", "deferred_commit_recovery",
         "watch_relisten", "snapshot", "wal_backup", "native_owner_handle",
         "native_owner_isolate", "native_owner_process", "two_reopens", "generation_fence"}

class Refusal(Exception):
    pass

def require(value, reason):
    if not value:
        raise Refusal(reason)

def command(argv, *, timeout=30, check=True, env=None, input=None, binary=False):
    result = subprocess.run([str(x) for x in argv], text=not binary, capture_output=True,
                            timeout=timeout, env=env, input=input)
    if check and result.returncode:
        detail = result.stderr.decode(errors="replace") if binary else result.stderr
        raise Refusal("command_failed: " + str(argv[0]) + ": " + detail.strip()[-400:])
    return result

def temporary_path(value, *, must_exist=False):
    path = Path(value)
    require(path.is_absolute() and ".." not in path.parts and str(path).startswith("/tmp/"),
            "temporary_path_required")
    require(not path.is_relative_to(APP.parent), "output_inside_checkout")
    for ancestor in (path, *path.parents):
        require(not ancestor.is_symlink(), "linked_temporary_path")
    if must_exist:
        require(path.exists() and path.stat().st_uid == os.getuid(), "owned_path_required")
    return path

def read_json(path, limit=16384):
    require(path.is_file() and path.stat().st_size <= limit, "receipt_not_regular_or_too_large")
    require(path.stat().st_uid == os.getuid() and not stat.S_IMODE(path.stat().st_mode) & 0o022,
            "receipt_must_be_coordinator_owned")
    return json.loads(path.read_text())

def ini(path):
    require(path.is_file() and not path.is_symlink(), "avd_config_missing_or_linked")
    values = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if "=" not in line or line.startswith("#"):
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip()
    return values

def adb(args, *tail, check=True, input=None, timeout=60):
    # Every invocation, including emu/package queries, carries this exact serial.
    # ADB joins shell arguments without escaping; preserve argv through that
    # outer remote shell before any nested sh -c interprets its fixed program.
    if tail and tail[0] == "shell":
        tail = ("shell", shlex.join(str(value) for value in tail[1:]))
    return command([args.sdk / "platform-tools/adb", "-s", args.serial, *tail],
                   check=check, timeout=timeout, input=input)

def receipt_guard(args):
    require(args.serial is not None and re.fullmatch(r"emulator-[0-9]{4,5}", args.serial),
            "explicit_emulator_serial_required")
    port = int(args.serial.split("-")[1])
    require(5554 <= port <= 5682 and port % 2 == 0, "invalid_emulator_port")
    require(args.avd is not None and re.fullmatch(r"[A-Za-z0-9_.-]+", args.avd),
            "explicit_avd_required")
    require(args.receipt is not None, "disposable_receipt_required")
    receipt = read_json(temporary_path(args.receipt, must_exist=True))
    require(receipt.get("format") == "alkion-android-disposable/1" and
            receipt.get("purpose") == "synthetic-only" and receipt.get("fresh") is True,
            "fresh_disposable_attestation_required")
    require(receipt.get("serial") == args.serial and receipt.get("avd") == args.avd,
            "receipt_target_mismatch")
    require(re.fullmatch(r"[a-f0-9]{32}", receipt.get("run_id", "")), "invalid_run_id")
    require(receipt.get("api") == 36 and receipt.get("abi") == "x86_64" and
            receipt.get("system_image") == "system-images;android-36;default;x86_64",
            "unsupported_receipt_platform")
    avd_home = temporary_path(receipt["avd_home"], must_exist=True)
    user_home = temporary_path(receipt["android_user_home"], must_exist=True)
    require(os.environ.get("ANDROID_USER_HOME") == str(user_home), "android_user_home_mismatch")
    directory = avd_home / (args.avd + ".avd")
    temporary_path(str(directory), must_exist=True)
    require(ini(avd_home / (args.avd + ".ini")).get("path") == str(directory),
            "avd_directory_mismatch")
    config = ini(directory / "config.ini")
    require(config.get("abi.type") == "x86_64" and config.get("tag.id") == "default" and
            config.get("image.sysdir.1", "").rstrip("/") ==
            "system-images/android-36/default/x86_64", "avd_image_mismatch")
    require(args.output is not None, "fresh_output_required")
    output = temporary_path(args.output)
    require(not output.exists(), "output_exists_do_not_adopt_prior_run")
    return receipt, output

def device_platform_guard(args):
    require(adb(args, "get-state").stdout.strip() == "device", "target_not_online")
    names = [line.strip() for line in adb(args, "emu", "avd", "name").stdout.splitlines()
             if line.strip() and line.strip() != "OK"]
    require(names == [args.avd], "device_avd_mismatch")
    for key, expected in (("ro.kernel.qemu", "1"), ("ro.build.version.sdk", "36"),
                          ("ro.product.cpu.abi", "x86_64"), ("sys.boot_completed", "1")):
        require(adb(args, "shell", "getprop", key).stdout.strip() == expected,
                "device_platform_mismatch:" + key)

def device_guard(args):
    device_platform_guard(args)
    for package in PACKAGES:
        query = adb(args, "shell", "pm", "path", package, check=False)
        require(query.returncode in (0, 1) and not query.stderr.strip(), "package_query_failed")
        require(not query.stdout.strip(),
                "preexisting_package:" + package)

def toolchain(args):
    require(os.environ.get("JAVA_HOME") == "/usr/lib/jvm/java-21-openjdk", "jdk21_required")
    require((args.sdk / "platforms/android-36/android.jar").is_file(), "api36_sdk_required")
    user_home = temporary_path(os.environ.get("ANDROID_USER_HOME", ""), must_exist=True)
    return user_home

def apk_facts(args, apk, expected_package):
    tools = args.sdk / "build-tools/36.0.0"
    badging = command([tools / "aapt2", "dump", "badging", apk]).stdout
    match = re.search(r"^package: name='([^']+)' versionCode='([0-9]+)'", badging, re.MULTILINE)
    require(match and match[1] == expected_package, "apk_package_mismatch")
    certs = command([Path(os.environ["JAVA_HOME"]) / "bin/java", "-jar",
                     tools / "lib/apksigner.jar", "verify", "--print-certs", apk]).stdout
    cert = re.search(r"^Signer #1 certificate SHA-256 digest: ([a-f0-9]{64})$", certs, re.MULTILINE)
    require(cert is not None, "apk_certificate_unverified")
    with apk.open("rb") as source:
        digest = hashlib.file_digest(source, "sha256").hexdigest()
    return {"package": expected_package, "version_code": int(match[2]),
            "apk_sha256": digest, "certificate_sha256": cert[1]}

def build_neighbor(args, output):
    user_home = toolchain(args)
    key = user_home / "debug.keystore"
    require(key.is_file() and not key.is_symlink(), "disposable_debug_key_required")
    require(not output.exists(), "neighbor_output_exists")
    output.mkdir(parents=True)
    classes = output / "classes"
    dex = output / "dex"
    classes.mkdir()
    dex.mkdir()
    tools = args.sdk / "build-tools/36.0.0"
    android = args.sdk / "platforms/android-36/android.jar"
    env = dict(os.environ, PATH=os.environ["JAVA_HOME"] + "/bin:" + os.environ["PATH"])
    fixture = SCRIPT.parent / "android_synthetic_neighbor"
    command([Path(os.environ["JAVA_HOME"]) / "bin/javac", "--release", "8", "-classpath",
             android, "-d", classes, fixture / "SyntheticNeighbor.java"])
    command([tools / "d8", "--min-api", "24", "--lib", android, "--output", dex,
             *sorted(classes.rglob("*.class"))], env=env)
    unsigned = output / "unsigned.apk"
    command([tools / "aapt2", "link", "-I", android, "--manifest",
             fixture / "AndroidManifest.xml", "--min-sdk-version", "24",
             "--target-sdk-version", "36", "-o", unsigned])
    with zipfile.ZipFile(unsigned, "a") as archive:
        archive.write(dex / "classes.dex", "classes.dex")
    aligned = output / "aligned.apk"
    command([tools / "zipalign", "-f", "4", unsigned, aligned])
    apk = output / "synthetic-neighbor.apk"
    command([Path(os.environ["JAVA_HOME"]) / "bin/java", "-jar", tools / "lib/apksigner.jar",
             "sign", "--ks", key, "--ks-key-alias", "androiddebugkey",
             "--ks-pass", "pass:android", "--key-pass", "pass:android",
             "--out", apk, aligned])
    facts = apk_facts(args, apk, PACKAGES[0])
    (output / "build.json").write_text(json.dumps(facts, indent=2) + chr(10))
    return apk, facts

def installed_matches(args, installed):
    # Only APKs installed by this invocation may be seen between its phases.
    for package in PACKAGES:
        query = adb(args, "shell", "pm", "path", package, check=False)
        require(query.returncode in (0, 1) and not query.stderr.strip(), "package_query_failed")
        lines = query.stdout.strip().splitlines()
        if package not in installed:
            require(not lines, "unexpected_package_between_phases:" + package)
            continue
        require(len(lines) == 1 and lines[0].startswith("package:"), "installed_apk_path_missing")
        path = lines[0][len("package:"):]
        require(re.fullmatch(r"/data/app/[A-Za-z0-9_~+/.=-]+/base[.]apk", path) and
                ".." not in Path(path).parts,
                "unexpected_installed_apk_path")
        digest = adb(args, "shell", "sha256sum", path).stdout.split()
        require(digest and digest[0] == installed[package]["apk_sha256"],
                "same_run_apk_changed:" + package)

def receive_driver_report(output, flavor, raw):
    # Preserve even FAIL, malformed or foreign receipts before interpreting them.
    (output / ("driver-" + flavor + "-report.json")).write_text(raw)
    return json.loads(raw)

def validate_driver_report(result, run_id, package):
    require(isinstance(result, dict) and
            result.get("format") == "alkion-android-driver-proof/1" and
            result.get("run_id") == run_id and
            result.get("application_id") == package and result.get("complete") is True,
            "driver_result_identity_mismatch")
    require(result.get("result") == "PASS" and set(result.get("cases", {})) == CASES and
            all(value == "PASS" for value in result["cases"].values()),
            "driver_assertions_incomplete_or_failed:" + package)

def run_driver(args, receipt, output):
    toolchain(args)
    revision = command(["git", "-C", APP, "rev-parse", "HEAD"]).stdout.strip()
    require(re.fullmatch(r"[a-f0-9]{40}", revision), "source_revision_required")
    require(not command(["git", "-C", APP, "status", "--porcelain",
                         "--untracked-files=normal"]).stdout.strip(),
            "commit_reviewed_source_before_device_proof")
    output.mkdir(parents=True)
    (output / "disposable-receipt.json").write_text(json.dumps(receipt, indent=2) + chr(10))
    state = {"format": "alkion-android-run/1", "run_id": receipt["run_id"],
             "serial": args.serial, "avd": args.avd, "phase": "driver",
             "source_commit": revision, "driver_contract": "alkion-driver/2",
             "api": receipt["api"], "abi": receipt["abi"],
             "overall": "IN_PROGRESS", "installed": {}, "driver": {},
             "pending": {"cross_process_ownership": "UNRUN: OS-process case has not passed on both variants",
                         "process_kill_recovery": "UNRUN: lifecycle handoff",
                         "updates_and_wrong_signer": "UNRUN: later same-run update cases",
                         "lifecycle_notifications": "UNRUN: T3/T4 handoff",
                         "documents_provider_restore": "UNRUN: T3/provider handoff",
                         "final_candidate": "UNRUN: final functional and installed-device gate"}}
    def save():
        (output / "run.json").write_text(json.dumps(state, indent=2) + chr(10))
    save()
    try:
        candidates = {}
        for flavor, package in (("dev", PACKAGES[1]), ("supported", PACKAGES[2])):
            print("Building driver:", flavor, flush=True)
            built = command(["make", "-C", APP, "android-synthetic-driver-apk",
                     "ALKION_FLAVOR=" + flavor, "ALKION_PROOF_RUN=" + receipt["run_id"]],
                    timeout=600, check=False)
            (output / ("build-" + flavor + ".log")).write_text(built.stdout + built.stderr)
            require(built.returncode == 0, "driver_build_failed:" + flavor + ":see_build_log")
            apk = output / ("driver-" + flavor + ".apk")
            shutil.copyfile(APP / "build/app/outputs/flutter-apk" /
                            ("app-" + flavor + "-debug.apk"), apk)
            candidates[flavor] = (apk, apk_facts(args, apk, package))
        neighbor, neighbor_facts = build_neighbor(args, output / "neighbor-build")
        require(len({facts["certificate_sha256"] for _, facts in candidates.values()} |
                    {neighbor_facts["certificate_sha256"]}) == 1, "debug_signer_mismatch")
        # A build can take time. Recheck the exact target and empty packages now.
        device_guard(args)
        installed = state["installed"]
        adb(args, "install", neighbor)
        installed[PACKAGES[0]] = neighbor_facts
        save()
        adb(args, "shell", "am", "start", "-W", "-n",
            PACKAGES[0] + "/.SyntheticNeighbor", "--es", "run_id", receipt["run_id"])
        relative_neighbor = "files/synthetic-neighbor.json"
        neighbor_before = adb(args, "shell", "run-as", PACKAGES[0], "cat", relative_neighbor).stdout
        require(json.loads(neighbor_before)["run_id"] == receipt["run_id"], "neighbor_run_mismatch")
        for flavor, (apk, facts) in candidates.items():
            package = facts["package"]
            installed_matches(args, installed)
            adb(args, "install", apk)
            installed[package] = facts
            save()
            adb(args, "shell", "am", "start", "-W", "-n",
                package + "/dev.animusstudio.alkion.MainActivity")
            relative = "files/android-proof/" + receipt["run_id"] + "/driver-report.json"
            deadline = time.monotonic() + 150
            result = None
            while time.monotonic() < deadline:
                read = adb(args, "shell", "run-as", package, "cat", relative, check=False)
                if read.returncode == 0:
                    result = receive_driver_report(output, flavor, read.stdout)
                    break
                time.sleep(1)
            require(result is not None, "driver_result_timeout:" + flavor)
            state["driver"][flavor] = result
            save()
            validate_driver_report(result, receipt["run_id"], package)
            require(adb(args, "shell", "run-as", PACKAGES[0], "cat",
                        relative_neighbor).stdout == neighbor_before, "synthetic_neighbor_changed")
        installed_matches(args, installed)
        state["pending"].pop("cross_process_ownership")
        state["driver_phase"] = "PASS"
        save()
        print("Driver phase PASS. T5 remains IN_PROGRESS; see pending cases in run.json.", flush=True)
    except Exception as error:
        state["driver_phase"] = "FAIL"
        state["error"] = str(error)
        save()
        raise

def driver_continuation_contract(base, receipt):
    require(isinstance(base,dict) and base.get("format") == "alkion-android-run/1" and base.get("phase") == "driver" and
            base.get("driver_phase") == "PASS" and base.get("overall") == "IN_PROGRESS" and
            not base.get("error") and isinstance(base.get("pending"),dict),
            "successful_driver_run_required")
    require(all(base.get(key) == receipt[key] for key in ("run_id", "avd", "serial", "api", "abi")),
            "continuation_target_mismatch")
    require(re.fullmatch(r"[a-f0-9]{40}", base.get("source_commit", "")), "base_source_required")
    require(set(base.get("installed", {})) == set(PACKAGES), "recognized_packages_required")
    contracts = {"alkion-driver/1": CASES - {"native_owner_process"}, "alkion-driver/2": CASES}
    observed = []
    for flavor, package in (("dev", PACKAGES[1]), ("supported", PACKAGES[2])):
        result = base.get("driver", {}).get(flavor, {})
        require(result.get("format") == "alkion-android-driver-proof/1" and
                result.get("application_id") == package and result.get("run_id") == receipt["run_id"] and
                result.get("complete") is True and result.get("result") == "PASS" and not result.get("failures"),
                "complete_variant_driver_required")
        matched = [name for name, cases in contracts.items() if set(result.get("cases", {})) == cases]
        require(len(matched) == 1 and all(value == "PASS" for value in result["cases"].values()),
                "recognized_driver_contract_required")
        observed.extend(matched)
    require(len(set(observed)) == 1 and base.get("driver_contract", observed[0]) == observed[0],
            "driver_contract_mismatch")
    for package, facts in base["installed"].items():
        require(facts.get("package") == package and all(re.fullmatch(r"[a-f0-9]{64}", facts.get(key, ""))
                for key in ("apk_sha256", "certificate_sha256")), "base_artifact_binding_required")
    require(len({facts["certificate_sha256"] for facts in base["installed"].values()}) == 1,
            "base_debug_signer_mismatch")
    return observed[0]

def package_metadata(args, package):
    value = adb(args, "shell", "dumpsys", "package", package).stdout
    version = re.findall(r"\bversionCode=([0-9]+)\b", value)
    listing = adb(args, "shell", "pm", "list", "packages", "-U", package).stdout
    # The filter can also return substring peers. Only the exact package binds
    # its full UID; dumpsys appId is not a UID and userId is absent on API 36.
    prefix = "package:" + re.escape(package)
    exact = [line.strip() for line in listing.splitlines()
             if re.match(prefix + r"(?:\s|$)", line.strip())]
    uid = re.fullmatch(prefix + r" uid:([0-9]+)", exact[0]) if len(exact) == 1 else None
    require(len(set(version)) == 1 and uid is not None, "package_metadata_unavailable")
    return {"version_code": int(version[0]), "uid": int(uid[1])}

def continuation_device_guard(args, receipt, base, local_facts):
    driver_continuation_contract(base, receipt)
    device_platform_guard(args)
    installed_matches(args, base["installed"])
    metadata = {}
    for package in PACKAGES:
        facts = local_facts[package]
        require(all(facts[key] == base["installed"][package][key] for key in
                    ("package", "apk_sha256", "certificate_sha256")), "saved_apk_binding_mismatch")
        metadata[package] = package_metadata(args, package)
        require(metadata[package]["version_code"] == facts["version_code"], "installed_version_mismatch")
    for package in PACKAGES[1:]:
        for relative in ("files/" + package, "files/android-update/" + receipt["run_id"]):
            query = adb(args, "shell", "run-as", package, "/system/bin/sh", "-c",
                        'test ! -e "$1" && test ! -L "$1"', "alkion-absent-root", relative, check=False)
            require(query.returncode == 0 and not query.stderr.strip(), "unexpected_existing_update_profile")
    return metadata

def audit_update_candidate(facts, package, before, version, *, wrong_signer=False):
    require(facts["package"] == package and facts["version_code"] == version and
            version > before["version_code"], "update_package_or_version_mismatch")
    same = facts["certificate_sha256"] == before["certificate_sha256"]
    require(same != wrong_signer, "update_signer_mismatch")

def read_update_report(args, package, run_id, phase, output):
    relative = "files/android-update/" + run_id + "/" + phase + "-report.json"
    deadline = time.monotonic() + 150
    while time.monotonic() < deadline:
        result = adb(args, "shell", "run-as", package, "cat", relative, check=False)
        if result.returncode == 0:
            (output / (package + "-" + phase + "-report.json")).write_text(result.stdout)
            value = json.loads(result.stdout)
            require(value.get("format") == "alkion-android-update-proof/1" and
                    value.get("application_id") == package and value.get("run_id") == run_id and
                    value.get("phase") == phase and value.get("complete") is True and
                    value.get("closed") is True and value.get("result") == "PASS" and
                    re.fullmatch(r"[a-f0-9]{64}", value.get("state_digest", "")), "update_report_failed")
            return value
        time.sleep(1)
    raise Refusal("update_report_timeout:" + phase)

def closed_profile_fingerprint(args, package, report):
    relative = report["database_relative"]
    require(re.fullmatch(r"profiles/[a-f0-9-]{36}/alkion[.]sqlite", relative) and
            relative.split("/")[1] == report["profile_id"], "unrecognized_profile_path")
    root = "files/" + package + "/"
    database = root + relative
    # Reports attest awaited close. Between these captures nothing reopens the
    # peer store: include sidecar presence/bytes rather than assuming absence.
    covered = []
    for path in (database, database+"-wal", database+"-shm", database+"-journal",
                 root + "local-profile.json", root + "original-source.bin"):
        kind = adb(args, "shell", "run-as", package, "/system/bin/sh", "-c",
            'if test -L "$1"; then exit 2; elif test ! -e "$1"; then printf absent; '
            'elif test -f "$1"; then printf file; else exit 2; fi',
            "alkion-covered-file", path).stdout.strip()
        require(kind in ("file","absent"), "covered_file_type_unavailable")
        optional = path in (database+"-wal",database+"-shm",database+"-journal")
        require(kind == "file" or optional, "covered_file_missing")
        digest = None
        if kind == "file":
            observed = adb(args, "shell", "run-as", package, "sha256sum", path).stdout.split()
            require(observed and re.fullmatch(r"[a-f0-9]{64}", observed[0]), "covered_bytes_unreadable")
            digest = observed[0]
        covered.append((path,kind,digest))
    return hashlib.sha256(json.dumps(covered,separators=(",",":")).encode()).hexdigest()

def driver_neighbor_bytes(args, receipt, base):
    result = {}
    for flavor, package in (("dev", PACKAGES[1]), ("supported", PACKAGES[2])):
        raw = adb(args, "shell", "run-as", package, "cat",
                  "files/android-proof/" + receipt["run_id"] + "/driver-report.json").stdout
        require(json.loads(raw) == base["driver"][flavor], "original_driver_receipt_changed")
        result[package] = raw
    raw = adb(args, "shell", "run-as", PACKAGES[0], "cat", "files/synthetic-neighbor.json").stdout
    require(json.loads(raw) == {"format":"alkion-synthetic-neighbor/1", "run_id":receipt["run_id"],
                               "sentinel":"synthetic-only-keep-exact"}, "synthetic_neighbor_mismatch")
    result[PACKAGES[0]] = raw
    return result

def prepare_updates(args, receipt, output):
    require(args.base_run, "successful_base_run_receipt_required")
    path = temporary_path(args.base_run, must_exist=True)
    base = read_json(path, limit=131072)
    contract = driver_continuation_contract(base, receipt)
    original = read_json(temporary_path(str(path.parent / "disposable-receipt.json"), must_exist=True))
    require(original == receipt, "original_disposable_receipt_mismatch")
    toolchain(args)
    local = {}
    for flavor, package in (("dev", PACKAGES[1]), ("supported", PACKAGES[2]), ("neighbor", PACKAGES[0])):
        apk = path.parent / ("driver-" + flavor + ".apk") if flavor != "neighbor" else path.parent / "neighbor-build/synthetic-neighbor.apk"
        temporary_path(str(apk), must_exist=True)
        local[package] = apk_facts(args, apk, package)
    metadata = continuation_device_guard(args, receipt, base, local)
    return base, local, metadata, contract

def run_updates(args, receipt, output, base, local, metadata, contract):
    # This route is explicit; the ordinary fresh-driver guard still refuses these packages.
    revision = command(["git", "-C", APP, "rev-parse", "HEAD"]).stdout.strip()
    require(not command(["git", "-C", APP, "status", "--porcelain", "--untracked-files=normal"]).stdout.strip(),
            "commit_reviewed_source_before_device_proof")
    output.mkdir(parents=True)
    state = {"format":"alkion-android-run/1", "phase":"updates", "overall":"IN_PROGRESS",
             "run_id":receipt["run_id"], "avd":args.avd, "serial":args.serial,
             "source_commit":revision, "base_source_commit":base["source_commit"],
             "base_driver_contract":contract, "updates":{}, "pending":dict(base["pending"])}
    def save():
        (output / "run.json").write_text(json.dumps(state,indent=2) + chr(10))
    save()
    try:
        key = output / "wrong-signer.jks"
        java = Path(os.environ["JAVA_HOME"]) / "bin"
        command([java / "keytool", "-genkeypair", "-noprompt", "-storetype", "JKS", "-keystore", key,
                 "-storepass", "android", "-keypass", "android", "-alias", "synthetic-negative",
                 "-keyalg", "RSA", "-keysize", "2048", "-validity", "2", "-dname", "CN=Synthetic Wrong Signer"])
        candidates = {}
        for flavor, package in (("dev", PACKAGES[1]), ("supported", PACKAGES[2])):
            require(local[package]["version_code"] < 2099999997, "version_space_exhausted")
            candidates[package] = {}
            for offset, phase in ((1,"seed"),(2,"verify"),(3,"wrong")):
                version = local[package]["version_code"] + offset
                built = command(["make", "-C", APP, "android-synthetic-update-apk", "ALKION_FLAVOR="+flavor,
                    "ALKION_PROOF_RUN="+receipt["run_id"], "ALKION_UPDATE_PHASE="+("verify" if phase=="wrong" else phase),
                    "ALKION_PROOF_VERSION="+str(version)], timeout=600,check=False)
                (output / (flavor+"-"+phase+"-build.log")).write_text(built.stdout+built.stderr)
                require(built.returncode == 0, "update_build_failed:"+phase)
                apk = output / (flavor+"-"+phase+".apk")
                source = APP / "build/app/outputs/flutter-apk" / ("app-"+flavor+"-debug.apk")
                if phase == "wrong":
                    command([java / "java", "-jar", args.sdk / "build-tools/36.0.0/lib/apksigner.jar", "sign",
                             "--ks", key, "--ks-key-alias", "synthetic-negative", "--ks-pass", "pass:android",
                             "--key-pass", "pass:android", "--out", apk, source])
                else:
                    shutil.copyfile(source,apk)
                facts = apk_facts(args,apk,package)
                audit_update_candidate(facts,package,local[package],version,wrong_signer=phase=="wrong")
                candidates[package][phase] = (apk,facts)
        require(command(["git","-C",APP,"rev-parse","HEAD"]).stdout.strip() == revision and
                not command(["git","-C",APP,"status","--porcelain","--untracked-files=normal"]).stdout.strip(),
                "source_changed_during_update_build")
        require(continuation_device_guard(args,receipt,base,local) == metadata, "base_metadata_changed_during_build")
        originals = driver_neighbor_bytes(args,receipt,base)
        installed = {package:dict(facts) for package,facts in local.items()}
        state["installed"] = installed
        completed = {}
        for package in PACKAGES[1:]:
            peer_before = {peer:closed_profile_fingerprint(args,peer,value) for peer,value in completed.items()}
            result = {}
            state["updates"][package] = result
            save()
            for phase in ("seed","verify"):
                apk,facts = candidates[package][phase]
                installed_matches(args,installed)
                adb(args,"install","-r",apk)
                installed[package] = facts
                installed_matches(args,installed)
                observed = package_metadata(args,package)
                require(observed == {"uid":metadata[package]["uid"],"version_code":facts["version_code"]},
                        "update_changed_uid_or_version")
                result[phase+"_apk"] = facts
                result[phase+"_metadata"] = observed
                adb(args,"shell","am","start","-W","-n",package+"/dev.animusstudio.alkion.MainActivity")
                result[phase] = read_update_report(args,package,receipt["run_id"],phase,output)
                save()
                if phase == "verify":
                    require(all(result[phase][field] == result["seed"][field] for field in
                        ("state_digest","installation_id","profile_id","generation","database_relative")),
                        "update_did_not_preserve_seed_state")
            before = closed_profile_fingerprint(args,package,result["verify"])
            wrong,wrong_facts = candidates[package]["wrong"]
            rejected = adb(args,"install","-r",wrong,check=False)
            result["wrong_signer"] = {"candidate":wrong_facts,"exit_code":rejected.returncode,
                                     "stdout":rejected.stdout,"stderr":rejected.stderr}
            require(rejected.returncode != 0 and "INSTALL_FAILED_UPDATE_INCOMPATIBLE" in rejected.stdout+rejected.stderr,
                    "wrong_signer_not_rejected_as_incompatible")
            installed_matches(args,installed)
            after_metadata = package_metadata(args,package)
            after = closed_profile_fingerprint(args,package,result["verify"])
            result["wrong_signer"].update({"metadata_before":observed,"metadata_after":after_metadata,
                "covered_bytes_before":before,"covered_bytes_after":after})
            save()
            require(after_metadata == observed and after == before,
                    "wrong_signer_changed_installed_identity_or_data")
            require(driver_neighbor_bytes(args,receipt,base) == originals, "driver_or_neighbor_bytes_changed")
            result["driver_and_neighbor_bytes_unchanged"] = True
            result["peer_covered_bytes"] = {}
            for peer,value in completed.items():
                after_peer = closed_profile_fingerprint(args,peer,value)
                result["peer_covered_bytes"][peer] = {"before":peer_before[peer],"after":after_peer}
                require(after_peer == peer_before[peer], "peer_variant_data_changed")
            for peer in PACKAGES:
                if peer == package: continue
                require(package_metadata(args,peer) == {"uid":metadata[peer]["uid"],
                    "version_code":installed[peer]["version_code"]}, "peer_variant_metadata_changed")
            completed[package] = result["verify"]
            state["updates"][package] = result
            save()
        state["pending"].pop("updates_and_wrong_signer",None)
        state["updates_phase"] = "PASS"
        save()
    except Exception as error:
        state["updates_phase"] = "FAIL"
        state["error"] = str(error)
        save()
        raise

def lifecycle_build_arguments(environment):
    flavor = environment.get("ALKION_FLAVOR", "")
    run = environment.get("ALKION_PROOF_RUN", "")
    version = environment.get("ALKION_PROOF_VERSION", "")
    phase = environment.get("ALKION_LIFECYCLE_PHASE", "")
    require(flavor in ("dev", "supported") and re.fullmatch(r"[a-f0-9]{32}", run) and
            re.fullmatch(r"[0-9]{1,10}", version) and 40 <= int(version) <= 2099999999 and
            phase in ("main", "prepare", "rest", "finish"), "explicit_lifecycle_build_inputs_required")
    target = "lib/main.dart" if phase == "main" else "integration_test/android_lifecycle_test.dart"
    argv = ["fvm", "flutter", "build", "apk", "--debug", "--no-pub", "--flavor", flavor,
            "--target-platform", "android-x64", "--target", target, "--build-number", version]
    if phase != "main":
        argv += ["--dart-define=ALKION_PROOF_RUN="+run, "--dart-define=ALKION_LIFECYCLE_PHASE="+phase]
    return argv

def lifecycle_contract(base, receipt):
    require(isinstance(base,dict) and base.get("format") == "alkion-android-run/1" and base.get("phase") == "updates" and
            base.get("updates_phase") == "PASS" and base.get("overall") == "IN_PROGRESS" and
            not base.get("error") and isinstance(base.get("pending"), dict), "successful_a2_receipt_required")
    require(all(base.get(key) == receipt[key] for key in ("run_id", "avd", "serial")) and
            isinstance(base.get("source_commit"),str) and re.fullmatch(r"[a-f0-9]{40}", base["source_commit"]) and
            base.get("base_driver_contract") in ("alkion-driver/1", "alkion-driver/2") and
            isinstance(base.get("installed"),dict) and set(base["installed"]) == set(PACKAGES) and
            isinstance(base.get("updates"),dict) and set(base["updates"]) == set(PACKAGES[1:]) and
            all(isinstance(value,dict) for value in base["installed"].values()), "a2_identity_mismatch")
    metadata = {}
    for package in PACKAGES[1:]:
        value = base["updates"][package]
        require(isinstance(value,dict) and isinstance(value.get("wrong_signer"),dict) and
                isinstance(value.get("seed_metadata"),dict) and isinstance(value.get("verify_metadata"),dict),
                "a2_variant_incomplete")
        for phase in ("seed", "verify"):
            report = value.get(phase, {})
            require(isinstance(report,dict) and report.get("format") == "alkion-android-update-proof/1" and
                    report.get("run_id") == receipt["run_id"] and report.get("application_id") == package and
                    report.get("phase") == phase and report.get("complete") is True and
                    report.get("closed") is True and report.get("result") == "PASS" and
                    isinstance(report.get("state_digest"),str) and
                    re.fullmatch(r"[a-f0-9]{64}", report["state_digest"]), "a2_variant_incomplete")
        require(all(value["seed"][key] == value["verify"][key] for key in
                    ("state_digest", "installation_id", "profile_id", "generation", "database_relative")),
                "a2_preservation_mismatch")
        require(value.get("driver_and_neighbor_bytes_unchanged") is True and
                value.get("wrong_signer", {}).get("exit_code") not in (None, 0) and
                isinstance(value["wrong_signer"].get("stdout",""),str) and
                isinstance(value["wrong_signer"].get("stderr",""),str) and
                "INSTALL_FAILED_UPDATE_INCOMPATIBLE" in value["wrong_signer"].get("stdout", "")+
                value["wrong_signer"].get("stderr", "") and
                value["wrong_signer"].get("metadata_before") == value["wrong_signer"].get("metadata_after") and
                value["wrong_signer"].get("metadata_before") == value["verify_metadata"] and
                isinstance(value["wrong_signer"].get("covered_bytes_before"),str) and
                re.fullmatch(r"[a-f0-9]{64}",value["wrong_signer"]["covered_bytes_before"]) and
                value["wrong_signer"].get("covered_bytes_before") == value["wrong_signer"].get("covered_bytes_after"),
                "a2_rejection_or_neighbor_incomplete")
        facts = base["installed"][package]
        wrong=value["wrong_signer"].get("candidate",{})
        require(isinstance(wrong,dict) and wrong.get("package")==package and wrong.get("version_code")==40 and
                isinstance(wrong.get("certificate_sha256"),str) and
                re.fullmatch(r"[a-f0-9]{64}",wrong["certificate_sha256"]) and
                wrong["certificate_sha256"] != facts.get("certificate_sha256"), "a2_wrong_candidate_mismatch")
        require(facts == value.get("verify_apk") and facts.get("package") == package and
                facts.get("version_code") == 39 and
                value.get("seed_metadata", {}).get("version_code") == 38 and
                value.get("verify_metadata", {}).get("version_code") == 39 and
                value["seed_metadata"].get("uid") == value["verify_metadata"].get("uid") and
                type(value["verify_metadata"].get("uid")) is int,
                "a2_installed_binding_mismatch")
        require(10000 <= value["verify_metadata"]["uid"] < 100000,"explicit_primary_user_required")
        metadata[package] = value["verify_metadata"]
    require(all(re.fullmatch(r"[a-f0-9]{64}",facts.get(key,"")) for facts in base["installed"].values()
                for key in ("apk_sha256","certificate_sha256")) and
            len({facts["certificate_sha256"] for facts in base["installed"].values()})==1,
            "a2_artifact_or_signer_mismatch")
    return metadata

def prepare_lifecycle(args, receipt, output):
    require(args.base_run, "successful_a2_receipt_required")
    path = temporary_path(args.base_run, must_exist=True)
    base = read_json(path, 1048576)
    metadata = lifecycle_contract(base, receipt)
    toolchain(args)
    original_path = temporary_path(str(Path(args.receipt).parent / "run/run.json"), must_exist=True)
    original = read_json(original_path, 1048576)
    driver_continuation_contract(original, receipt)
    require(base.get("base_source_commit") == original["source_commit"], "a2_original_driver_mismatch")
    local = {PACKAGES[0]: apk_facts(args, original_path.parent / "neighbor-build/synthetic-neighbor.apk", PACKAGES[0])}
    for flavor, package in (("dev", PACKAGES[1]), ("supported", PACKAGES[2])):
        local[package] = apk_facts(args, path.parent / (flavor+"-verify.apk"), package)
    require(local == base["installed"], "a2_saved_apk_changed")
    device_platform_guard(args)
    installed_matches(args, local)
    for package in PACKAGES:
        observed = package_metadata(args, package)
        if package in metadata:
            require(observed == metadata[package], "a2_live_metadata_changed")
        else:
            require(observed["version_code"] == local[package]["version_code"], "neighbor_version_changed")
            metadata[package] = observed
    for package in PACKAGES[1:]:
        query = adb(args, "shell", "run-as", package, "/system/bin/sh", "-c",
                    'test ! -e "$1" && test ! -L "$1"', "alkion-absent-root",
                    "files/android-lifecycle/"+receipt["run_id"], check=False)
        require(query.returncode == 0, "lifecycle_run_already_present")
    return base, original, local, metadata

def app_pid(args, package, *, timeout=60):
    result = adb(args, "shell", "pidof", package, check=False, timeout=timeout)
    require(result.returncode in (0, 1) and not result.stderr.strip(), "scoped_pid_query_failed")
    values = result.stdout.split()
    require(len(values) <= 1 and all(re.fullmatch(r"[0-9]+", value) for value in values),
            "unexpected_package_processes")
    return int(values[0]) if values else None

PROCESS_IDENTITY_SCRIPT = '''if [ ! -d "/proc/$1" ]; then printf 'absent\\n'; exit 0; fi
if ! status=$(cat "/proc/$1/status" 2>/dev/null) ||
   ! native_stat=$(cat "/proc/$1/stat" 2>/dev/null); then
  if [ ! -d "/proc/$1" ]; then printf 'absent\\n'; exit 0; fi
  exit 1
fi
printf '%s\\n\\nalkion-proc-stat\\n%s\\n' "$status" "$native_stat"
'''

def parse_process_identity(raw, pid, uid):
    if raw == "absent\n":
        return None
    require(len(raw.encode()) <= 65536 and raw.count("\nalkion-proc-stat\n") == 1,
            "ordinary_kill_malformed_proc_identity")
    status, native_stat = raw.split("\nalkion-proc-stat\n")
    require(re.findall(r"^Pid:\s*([0-9]+)$", status, re.MULTILINE) == [str(pid)] and
            re.findall(r"^Uid:\s*([0-9]+)\s+([0-9]+)\s+([0-9]+)\s+([0-9]+)$", status,
                       re.MULTILINE) == [(str(uid),)*4], "ordinary_kill_proc_pid_or_uid_changed")
    # comm may contain spaces/parentheses; field 22 is the kernel start time.
    fields = re.fullmatch(r"([0-9]+) \(.*\) [A-Za-z] (.+)\n?", native_stat)
    values = fields[2].split() if fields else []
    require(fields and fields[1] == str(pid) and len(values) >= 19 and
            re.fullmatch(r"[0-9]+", values[18]), "ordinary_kill_malformed_proc_stat")
    return {"pid":pid, "uid":uid, "start_ticks":int(values[18])}

def parse_ordinary_kill_process(raw, package, pid, uid):
    require(len(raw.encode()) <= 1048576, "ordinary_kill_process_dump_too_large")
    headers = list(re.finditer(r"^( *)\*APP\* UID[^\n]*$", raw, re.MULTILINE))
    selected = [index for index, header in enumerate(headers)
                if re.search(r":"+re.escape(package)+r"(?:[/:}\s]|$)", header[0])]
    require(len(selected) == 1, "ordinary_kill_process_record_ambiguous")
    index = selected[0]; header = headers[index]
    expected = (r" *\*APP\* UID "+str(uid)+r" (ProcessRecord\{[^{}\s]+ "+str(pid)+":"+
                re.escape(package)+r"/u0a"+str(uid-10000)+r"\})")
    record = re.fullmatch(expected, header[0])
    require(record, "ordinary_kill_native_pid_or_uid_changed")
    block = raw[header.end():headers[index+1].start() if index+1 < len(headers) else len(raw)]
    prefix = re.escape(header[1]+"  ")
    def one(pattern):
        values = re.findall("^"+prefix+pattern, block, re.MULTILINE)
        require(len(values) == 1, "ordinary_kill_process_state_ambiguous")
        return values[0]
    require(one(r"pid=([0-9]+)\s*$") == str(pid) and
            one(r"user #([0-9]+) uid=([0-9]+)\b[^\n]*$") == ("0",str(uid)),
            "ordinary_kill_native_pid_or_uid_changed")
    adj = tuple(map(int,one(r"oom adj: max=-?[0-9]+ curRaw=(-?[0-9]+) setRaw=(-?[0-9]+) cur=(-?[0-9]+) set=(-?[0-9]+)\s*$")))
    states = tuple(map(int,one(r"curProcState=([0-9]+) mRepProcState=([0-9]+) setProcState=([0-9]+)\b[^\n]*$")))
    cached, empty = one(r"cached=(true|false) empty=(true|false)\s*$")
    # API 36 omits this line when both activity flags are false. An observed
    # true/reported-true flag still excludes the process; malformed input refuses.
    flags = re.findall("^"+prefix+r"(foregroundActivities[^\n]*)$",block,re.MULTILINE)
    require(len(flags) <= 1, "ordinary_kill_foreground_flags_ambiguous")
    foreground = re.fullmatch(r"foregroundActivities=(true|false) \(rep=(true|false)\)\s*",flags[0]) if flags else None
    require(not flags or foreground, "ordinary_kill_malformed_foreground_flags")
    activity_flags = foreground.groups() if foreground else None
    own_lines = [line for line in block.splitlines() if line.startswith(header[1]+"  ") and
                 not line.startswith(header[1]+"   ")]
    protected = [flag for line in own_lines for flag in re.findall(
        r"\b(persistent|mPersistent|hasForegroundServices|foregroundServices)=(\S+)",line)]
    require(len({key for key,value in protected}) == len(protected) and
            all(value in ("true","false") for key,value in protected),
            "ordinary_kill_protected_flags_ambiguous")
    background = activity_flags in (None,("false","false")) and all(value == "false" for key,value in protected)
    branch = None; previous = []
    if background and cached == "true" and all(900 <= value <= 999 for value in adj) and all(15 <= value <= 19 for value in states):
        branch = "cached"
    elif background and adj == (700,)*4 and states == (15,)*3 and cached == "false" and empty == "false":
        previous = re.findall(r"^\s*mPreviousProcess:\s*([^\n]*)$",raw,re.MULTILINE)
        require(previous and all(value == record[1] for value in previous),
                "ordinary_kill_previous_process_mismatch")
        branch = "previous"
    return {"eligible":branch is not None, "branch":branch, "process_record":record[1],
            "previous_references":previous, "adj":adj, "states":states, "cached":cached,
            "empty":empty, "foreground":activity_flags, "protected":dict(protected)}

def parse_stopped_activity(raw, package, process_record):
    require(len(raw.encode()) <= 1048576, "ordinary_kill_activity_dump_too_large")
    headers = list(re.finditer(r"^( *)\* Hist\s+#[0-9]+: ([^\n]+)$",raw,re.MULTILINE))
    selected = [index for index,header in enumerate(headers)
                if re.search(r" u[0-9]+ "+re.escape(package)+r"/",header[2])]
    require(len(selected) == 1, "ordinary_kill_target_activity_ambiguous")
    index = selected[0]; header = headers[index]
    main = "dev.animusstudio.alkion.MainActivity"
    classes = re.escape(main)+(r"|\.MainActivity" if package == PACKAGES[2] else "")
    require(re.fullmatch(r"ActivityRecord\{[^{}\s]+ u0 "+re.escape(package)+r"/(?:"+classes+r") t[0-9]+\}",header[2]),
            "ordinary_kill_target_activity_mismatch")
    block = raw[header.end():headers[index+1].start() if index+1 < len(headers) else len(raw)]
    prefix = re.escape(header[1]+"  ")
    def one(pattern):
        values = re.findall("^"+prefix+pattern,block,re.MULTILINE)
        require(len(values) == 1, "ordinary_kill_target_activity_state_ambiguous")
        return values[0]
    require(one(r"packageName=(\S+) processName=(\S+)\s*$") == (package,package) and
            one(r"app=([^\n]+)$") == process_record, "ordinary_kill_target_activity_process_mismatch")
    state = one(r"state=([A-Z_]+)\b[^\n]*$")
    visible = one(r"mVisibleRequested=(true|false) mVisible=(true|false) mClientVisible=(true|false) reportedDrawn=(true|false) reportedVisible=(true|false)\s*$")
    now_visible = one(r"nowVisible=(true|false)\b[^\n]*$")
    return {"stopped":state == "STOPPED" and all(value == "false" for value in visible) and now_visible == "false",
            "state":state, "visibility":visible, "now_visible":now_visible, "process_record":process_record}

def resumed_component(raw):
    require(len(raw.encode()) <= 1048576, "ordinary_kill_activity_dump_too_large")
    values = re.findall(r"^\s*(?:topResumedActivity=|mResumedActivity: |ResumedActivity: |Resumed: )([^\n]+)$",
                        raw, re.MULTILINE)
    records = []
    for value in values:
        if value == "null":
            continue
        record = re.fullmatch(r"ActivityRecord\{[^{}\s]+ u([0-9]+) ([A-Za-z0-9_.$]+/[A-Za-z0-9_.$]+) t[0-9]+[^{}]*\}", value)
        require(record, "ordinary_kill_malformed_resumed_activity")
        records.append((record[1],record[2]))
    require(len(set(records)) <= 1, "ordinary_kill_resumed_activity_ambiguous")
    return records[0] if records else None

def ordinary_kill(args, package, uid, output):
    require(package in PACKAGES[1:] and type(uid) is int and 10000 <= uid < 100000,
            "ordinary_kill_primary_variant_required")
    # One total budget includes displacement, eligibility, transport and death.
    # The real 600-second rest continues running throughout; never extend it here.
    started = time.monotonic(); deadline = started+30
    evidence = {"format":"alkion-android-ordinary-kill/1", "package":package, "uid":uid,
                "budget_seconds":30, "result":"IN_PROGRESS", "eligibility":[]}
    index = len(list(output.glob(package+"-ordinary-kill-*.json")))
    path = output/(package+"-ordinary-kill-"+str(index)+".json")
    require(not path.exists(), "ordinary_kill_evidence_exists")
    def remaining():
        value = deadline-time.monotonic()
        require(value > 0, "ordinary_kill_total_budget_exhausted")
        return min(5,value)
    def native(*tail, check=True):
        return adb(args,"shell",*tail,check=check,timeout=remaining())
    def owner():
        observed = app_pid(args,package,timeout=remaining())
        require(observed == evidence["pid"], "ordinary_kill_package_pid_changed")
        raw = native("sh","-c",PROCESS_IDENTITY_SCRIPT,"alkion-process-identity",str(observed)).stdout
        identity = parse_process_identity(raw,observed,uid)
        require(identity is not None and identity == evidence["identity"], "ordinary_kill_process_identity_changed")
    def resolve(expected, action, *category):
        raw = native("cmd","package","resolve-activity","--brief","--user","0","-a",action,*category).stdout
        evidence[expected+"_resolution"] = raw
        lines = [line.strip() for line in raw.splitlines() if line.strip()]
        require(len(lines) in (1,2) and re.fullmatch(re.escape(expected)+r"/[A-Za-z0-9_.$]+",lines[-1]) and
                (len(lines) == 1 or re.fullmatch(r"priority=-?[0-9]+ preferredOrder=[0-9]+ match=0x[0-9a-f]+ specificIndex=-?[0-9]+ isDefault=(?:true|false)",lines[0])),
                "ordinary_kill_system_activity_unresolved")
        installed = native("pm","list","packages","-s","-U","--user","0",expected).stdout
        evidence[expected+"_system_package"] = installed
        exact = re.findall(r"^package:"+re.escape(expected)+r" uid:([0-9]+)$",installed,re.MULTILINE)
        require(len(exact) == 1 and (int(exact[0]) == 1000 if expected == "com.android.settings" else
                10000 <= int(exact[0]) < 100000), "ordinary_kill_native_system_package_required")
        return lines[-1]
    def wait_resumed(component, label):
        limit = min(deadline,time.monotonic()+5)
        while time.monotonic() < limit:
            raw = native("dumpsys","activity","activities").stdout
            evidence[label] = raw
            owner()
            if resumed_component(raw) == ("0",component):
                return
            time.sleep(min(0.25,max(0,limit-time.monotonic())))
        raise Refusal("ordinary_kill_expected_system_activity_not_resumed:"+label)
    try:
        before = app_pid(args,package,timeout=remaining())
        require(before is not None, "ordinary_kill_requires_live_process")
        evidence["pid"] = before
        raw = native("sh","-c",PROCESS_IDENTITY_SCRIPT,"alkion-process-identity",str(before)).stdout
        evidence["identity"] = parse_process_identity(raw,before,uid)
        require(evidence["identity"] is not None, "ordinary_kill_requires_live_process")
        require(native("am","get-current-user").stdout.strip() == "0", "ordinary_kill_primary_user_required")
        settings = resolve("com.android.settings","android.settings.SETTINGS")
        home = resolve("com.android.launcher3","android.intent.action.MAIN","-c","android.intent.category.HOME")
        # Observe native foreground displacement; the previous slot may remain 700.
        evidence["settings_start"] = native("am","start","-W","--user","0","-n",settings).stdout
        wait_resumed(settings,"settings_resumed")
        native("input","keyevent","KEYCODE_HOME")
        wait_resumed(home,"home_resumed")
        eligible_deadline = min(deadline,time.monotonic()+14)
        while True:
            owner()
            raw = native("dumpsys","activity","processes",package).stdout
            sample = {"elapsed_seconds":time.monotonic()-started,"dump":raw}
            evidence["eligibility"].append(sample)
            state = parse_ordinary_kill_process(raw,package,before,uid)
            sample["state"] = state; sample["eligible"] = state["eligible"]
            if state["branch"] == "previous":
                activities = native("dumpsys","activity","activities").stdout
                sample["activities"] = activities
                require(resumed_component(activities) == ("0",home), "ordinary_kill_home_no_longer_resumed")
                sample["activity"] = parse_stopped_activity(activities,package,state["process_record"])
                sample["eligible"] = sample["activity"]["stopped"]
            if sample["eligible"]:
                break
            require(time.monotonic() < eligible_deadline, "ordinary_kill_never_became_eligible")
            time.sleep(min(0.25,max(0,eligible_deadline-time.monotonic())))
        # Refresh process, activity, Home and kernel identity before the one command.
        raw = native("dumpsys","activity","processes",package).stdout
        evidence["before_kill_process_dump"] = raw
        state = parse_ordinary_kill_process(raw,package,before,uid)
        evidence["before_kill_state"] = state
        require(state["eligible"], "ordinary_kill_process_no_longer_eligible")
        require(state["process_record"] == sample["state"]["process_record"], "ordinary_kill_native_process_record_changed")
        raw = native("dumpsys","activity","activities").stdout
        evidence["before_kill_resumed"] = raw
        require(resumed_component(raw) == ("0",home), "ordinary_kill_home_no_longer_resumed")
        if state["branch"] == "previous":
            evidence["before_kill_activity"] = parse_stopped_activity(raw,package,state["process_record"])
            require(evidence["before_kill_activity"]["stopped"], "ordinary_kill_activity_no_longer_stopped")
        evidence["eligibility_branch"] = state["branch"]
        owner()
        path.write_text(json.dumps(evidence,indent=2)+chr(10))
        evidence["kill_command"] = native("am","kill","--user","0",package).stdout
        death_deadline = min(deadline,time.monotonic()+15)
        evidence["death_observations"] = []
        while time.monotonic() < death_deadline:
            observed = app_pid(args,package,timeout=remaining())
            sample = {"elapsed_seconds":time.monotonic()-started,"package_pid_before":observed}
            evidence["death_observations"].append(sample)
            raw = native("sh","-c",PROCESS_IDENTITY_SCRIPT,"alkion-process-identity",str(before)).stdout
            identity = parse_process_identity(raw,before,uid)
            sample["identity"] = identity
            require(observed in (None,before), "ordinary_kill_package_restarted")
            if identity is None:
                # The original PID can exit between pidof and the proc reads.
                # Only a fresh package query after exact PID absence qualifies.
                fresh = app_pid(args,package,timeout=remaining())
                sample["package_pid_after_absence"] = fresh
                require(fresh is None, "ordinary_kill_package_restarted")
                evidence["exact_pid_absent"] = True; evidence["result"] = "PASS"
                return before
            # pidof can omit a terminating process whose unchanged /proc record
            # is still present. Poll it; never mistake this for confirmed death.
            require(identity == evidence["identity"], "ordinary_kill_process_changed_after_kill")
            time.sleep(min(0.25,max(0,death_deadline-time.monotonic())))
        raise Refusal("ordinary_kill_did_not_exit_no_force_stop_fallback")
    except Exception as error:
        evidence["result"] = "FAIL"; evidence["error"] = str(error)
        raise
    finally:
        evidence["elapsed_seconds"] = time.monotonic()-started
        path.write_text(json.dumps(evidence,indent=2)+chr(10))

def parse_native_mirror(raw, record, package, uid, prepared):
    require(len(raw.encode()) <= 131072 and "<!DOCTYPE" not in raw and "<!ENTITY" not in raw,
            "native_mirror_not_bounded_xml")
    document = ET.fromstring(raw)
    entries = [node for node in document if node.tag == "string" and node.get("name") == "scheduled_notifications"]
    require(document.tag == "map" and len(entries) == 1, "native_mirror_entry_missing")
    notifications = json.loads(entries[0].text or "null")
    require(isinstance(notifications, list) and len(notifications) <= 16 and
            all(isinstance(value,dict) for value in notifications), "native_mirror_not_bounded_list")
    selected = [value for value in notifications if value.get("id") == 4101]
    require(len(selected) == 1, "native_mirror_notification_ambiguous")
    value = selected[0]
    action = json.loads(value.get("payload", "null"))
    draft = prepared["draft"]
    require(isinstance(action, dict) and set(action) == {"format", "application_id", "profile_id", "generation",
                "draft_id", "rest_start", "timer_revision", "token"} and
            action["format"] == "alkion-notification-action/1" and action["application_id"] == package and
            action["profile_id"] == prepared["profile_id"] and action["generation"] == prepared["generation"] and
            action["draft_id"] == draft["draftId"] and action["rest_start"] == draft["restStart"] and
            type(action["timer_revision"]) is int and action["timer_revision"] > 0 and
            isinstance(action["token"], str) and re.fullmatch(r"[a-f0-9-]{36}", action["token"]) and
            value.get("title") == draft["name"], "native_mirror_action_binding_mismatch")
    key = "0|"+package+"|4101|null|"+str(uid)
    require(len(record.encode()) <= 1048576 and key in record and ("pkg="+package) in record and "id=4101" in record and
            draft["name"] in record and "+30s" in record and "PendingIntent" in record,
            "native_notification_record_binding_unavailable")
    return action

def ui_document(args, output, name, *, expected_package=None):
    return ui_module().capture(ui_host(),args,output,name,
        expected_package or getattr(args,"ui_expected_package",None))

def click_node(args, node):
    match = re.fullmatch(r"\[([0-9]+),([0-9]+)\]\[([0-9]+),([0-9]+)\]", node.get("bounds", ""))
    require(match is not None, "ui_node_bounds_missing")
    x1, y1, x2, y2 = map(int, match.groups())
    require(x2 > x1 >= 0 and y2 > y1 >= 0, "ui_node_bounds_invalid")
    require(node.get("enabled") == "true" and node.get("visible-to-user") == "true" and
            x2 <= int(node.get("observer-display-width","0")) and
            y2 <= int(node.get("observer-display-height","0")),"ui_node_outside_attested_display")
    adb(args, "shell", "input", "tap", str((x1+x2)//2), str((y1+y2)//2))

def semantic_nodes(document, label):
    return [node for node in document.iter("node") if
            node.get("content-desc") == label or node.get("text") == label]

def ui_tap(args, output, name, label):
    document = ui_document(args, output, name)
    matches = [node for node in semantic_nodes(document, label) if node.get("clickable") == "true"]
    require(len(matches) == 1, "unique_ui_action_missing:"+label)
    click_node(args, matches[0])

def wait_session_ui(args, output, name):
    for attempt in range(12):
        document = ui_document(args, output, name+"-"+str(attempt))
        if semantic_nodes(document, "Minimize"):
            return document
        time.sleep(1)
    raise Refusal("real_session_route_not_visible")

def shade_tap(args, output, name, title, *, action):
    adb(args, "shell", "cmd", "statusbar", "expand-notifications")
    for attempt in range(2):
        document = ui_document(args, output, name+"-"+str(attempt),expected_package="com.android.systemui")
        titles = semantic_nodes(document, title)
        require(len(titles) == 1, "run_specific_notification_title_missing")
        parents = {child: parent for parent in document.iter() for child in parent}
        row = titles[0]
        while row in parents and not row.get("resource-id", "").endswith("/status_bar_latest_event_content"):
            row = parents[row]
        require(row is not document, "notification_row_scope_unavailable")
        if not action:
            click_node(args, titles[0]); return
        choices = semantic_nodes(row, "+30s")
        if len(choices) == 1:
            click_node(args, choices[0]); return
        expand = [node for node in row.iter("node") if node.get("resource-id", "").endswith("/expand_button")]
        require(attempt == 0 and len(expand) == 1, "notification_action_unavailable")
        click_node(args, expand[0])
    raise Refusal("notification_action_unavailable")

def read_native_mirror(args, package):
    return adb(args, "shell", "run-as", package, "/system/bin/sh", "-c",
                  'test ! -L shared_prefs && test ! -L "$1" && test -f "$1" && '
                  'test "$(wc -c < "$1")" -le 131072 && cat "$1"',
                  "alkion-native-mirror", "shared_prefs/scheduled_notifications.xml", check=False)

def capture_native_action(args, package, uid, prepared, output, name, previous=None):
    key = "0|"+package+"|4101|null|"+str(uid)
    for attempt in range(12):
        raw = read_native_mirror(args, package)
        record = adb(args, "shell", "cmd", "notification", "get", key, check=False)
        prefix = name+"-"+str(attempt)
        (output / (prefix+"-mirror.xml")).write_text(raw.stdout+raw.stderr)
        (output / (prefix+"-notification.txt")).write_text(record.stdout+record.stderr)
        if raw.returncode == 0 and record.returncode == 0:
            try:
                action = parse_native_mirror(raw.stdout, record.stdout, package, uid, prepared)
                if action["token"] != previous:
                    return action
            except (Refusal, ValueError, ET.ParseError, TypeError, AttributeError):
                pass
        time.sleep(1)
    raise Refusal("UNRUN:native_mirror_or_posted_notification_binding_unavailable")

def replay_native_action(args, package, action):
    adb(args, "shell", "am", "start", "-W", "--user", "0", "-n",
        package+"/dev.animusstudio.alkion.MainActivity", "-a", "SELECT_FOREGROUND_NOTIFICATION",
        "--ei", "notificationId", "4101", "--es", "actionId",
        ("alkion.dev." if package.endswith(".dev") else "alkion.")+"add_30s",
        "--es", "payload", json.dumps(action, separators=(",", ":")), "--ez", "cancelNotification", "false")

def read_lifecycle_report(args, package, run, phase, output):
    path = "files/android-lifecycle/"+run+"/"+phase+"-report.json"
    deadline = time.monotonic()+150
    while time.monotonic() < deadline:
        raw = adb(args, "shell", "run-as", package, "cat", path, check=False)
        if raw.returncode == 0:
            (output / (package+"-"+phase+"-report.json")).write_text(raw.stdout)
            value = json.loads(raw.stdout)
            require(value.get("format") == "alkion-android-lifecycle-checkpoint/1" and
                    value.get("run_id") == run and value.get("application_id") == package and
                    value.get("phase") == phase and value.get("complete") is True and
                    value.get("closed") is True and value.get("result") == "PASS" and
                    re.fullmatch(r"[a-f0-9]{64}", value.get("state_digest", "")),
                    "lifecycle_checkpoint_failed:"+phase)
            return value
        time.sleep(1)
    raise Refusal("lifecycle_checkpoint_timeout:"+phase)

def main_start(args, package):
    adb(args, "shell", "am", "start", "-W", "--user", "0", "-n",
        package+"/dev.animusstudio.alkion.MainActivity")

def wait_ui_label(args, output, name, label):
    for attempt in range(12):
        document = ui_document(args, output, name+"-"+str(attempt))
        if semantic_nodes(document, label):
            return document
        time.sleep(1)
    raise Refusal("ui_checkpoint_label_missing:"+label)

def summary_ui_ready(document, package, title):
    # Flutter may expose the heading and its rows as one multiline label.
    # This read-only checkpoint never changes whole-label action selection.
    if package not in PACKAGES[1:]:
        return False
    def unique_line(label):
        matches = [node for node in document.iter("node") for key in ("text", "content-desc")
                   for line in node.get(key, "").split("\n") if line == label]
        return matches[0] if len(matches) == 1 else None
    def visible(node):
        if node is None or node.get("package") != package or node.get("visible-to-user") != "true":
            return False
        bounds = re.fullmatch(r"\[([0-9]+),([0-9]+)\]\[([0-9]+),([0-9]+)\]", node.get("bounds", ""))
        width, height = node.get("observer-display-width", ""), node.get("observer-display-height", "")
        if bounds is None or not width.isdigit() or not height.isdigit():
            return False
        x1, y1, x2, y2 = map(int, bounds.groups())
        return 0 <= x1 < x2 <= int(width) and 0 <= y1 < y2 <= int(height)
    heading, named = unique_line("TOP SETS"), unique_line(title)
    done = semantic_nodes(document, "Done")
    return (visible(heading) and visible(named) and len(done) == 1 and visible(done[0]) and
            done[0].get("enabled") == "true" and done[0].get("clickable") == "true" and
            not semantic_nodes(document, "Minimize") and not semantic_nodes(document, "Finish workout"))

def wait_summary_ui(args, output, name, package, run, prepared):
    draft = prepared.get("draft", {})
    expected_name = "Synthetic lifecycle "+run+" "+package
    require(package in PACKAGES[1:] and re.fullmatch(r"[a-f0-9]{32}", run) and
            prepared.get("run_id") == run and prepared.get("application_id") == package and
            draft.get("name") == expected_name and draft.get("focus") == "legs", "summary_fixture_binding_changed")
    title = expected_name+" · legs"
    for attempt in range(12):
        document = ui_document(args, output, name+"-"+str(attempt))
        if summary_ui_ready(document, package, title):
            return document
        time.sleep(1)
    raise Refusal("ui_checkpoint_summary_missing")

def stage_native_evidence(args, package, run, value):
    raw = json.dumps(value, separators=(",", ":"))
    require(len(raw) <= 65536, "native_evidence_too_large")
    adb(args, "shell", "run-as", package, "/system/bin/sh", "-c",
        'umask 077; set -C; cat > "$1"', "alkion-native-evidence",
        "files/android-lifecycle/"+run+"/native-evidence.json", input=raw)

def wait_notification_absent(args, package, uid, output):
    key="0|"+package+"|4101|null|"+str(uid)
    for attempt in range(12):
        result=adb(args,"shell","cmd","notification","get",key,check=False)
        (output/(package+"-finished-notification-"+str(attempt)+".txt")).write_text(result.stdout+result.stderr)
        if result.returncode != 0 and "no active notification matching key:" in result.stdout:
            return
        time.sleep(1)
    raise Refusal("finished_workout_notification_still_present")

def run_lifecycle(args, receipt, output, base, original, local, metadata):
    revision = command(["git", "-C", APP, "rev-parse", "HEAD"]).stdout.strip()
    require(not command(["git", "-C", APP, "status", "--porcelain", "--untracked-files=normal"]).stdout.strip(),
            "commit_reviewed_source_before_device_proof")
    output.mkdir(parents=True)
    state = {"format":"alkion-android-run/1", "phase":"lifecycle-initial", "overall":"IN_PROGRESS",
             "run_id":receipt["run_id"], "avd":args.avd, "serial":args.serial,
             "source_commit":revision, "base_source_commit":base["source_commit"],
             "lifecycle":{}, "installed":dict(local), "pending":dict(base["pending"])}
    def save(): (output / "run.json").write_text(json.dumps(state,indent=2)+chr(10))
    save()
    try:
        candidates = {}
        phases = ((40,"prepare"),(41,"main-actions"),(42,"rest"),(43,"main-log"),(44,"finish"))
        for flavor, package in (("dev",PACKAGES[1]),("supported",PACKAGES[2])):
            candidates[package] = {}
            for version, phase in phases:
                target = "main" if phase.startswith("main-") else phase
                built = command(["make", "-C", APP, "android-synthetic-lifecycle-apk",
                    "ALKION_FLAVOR="+flavor,"ALKION_PROOF_RUN="+receipt["run_id"],
                    "ALKION_PROOF_VERSION="+str(version),"ALKION_LIFECYCLE_PHASE="+target],
                    check=False,timeout=600)
                (output/(flavor+"-"+phase+"-build.log")).write_text(built.stdout+built.stderr)
                require(built.returncode == 0,"lifecycle_build_failed:"+phase)
                apk=output/(flavor+"-"+phase+".apk")
                shutil.copyfile(APP/"build/app/outputs/flutter-apk"/("app-"+flavor+"-debug.apk"),apk)
                facts=apk_facts(args,apk,package)
                audit_update_candidate(facts,package,local[package],version)
                candidates[package][phase]=(apk,facts)
        require(command(["git","-C",APP,"rev-parse","HEAD"]).stdout.strip()==revision and
                not command(["git","-C",APP,"status","--porcelain","--untracked-files=normal"]).stdout.strip(),
                "source_changed_during_lifecycle_build")
        device_platform_guard(args); installed_matches(args,local)
        originals=driver_neighbor_bytes(args,receipt,original)
        state["ui_observer"]=ui_module().prepare(ui_host(),args,receipt,output,revision); save()
        installed=state["installed"]
        def install(package,phase):
            require(app_pid(args,package) is None,"main_process_must_exit_before_checkpoint_install")
            apk,facts=candidates[package][phase]
            require(facts["version_code"]>installed[package]["version_code"],"lifecycle_version_not_increasing")
            installed_matches(args,installed)
            adb(args,"install","-r",apk)
            installed[package]=facts
            installed_matches(args,installed)
            require(package_metadata(args,package)=={"version_code":facts["version_code"],"uid":metadata[package]["uid"]},
                    "lifecycle_installed_uid_or_version_changed")
            save()
        for package in PACKAGES[1:]:
            args.ui_expected_package=package
            result={}; state["lifecycle"][package]=result; save()
            peer_before={peer:closed_profile_fingerprint(args,peer,base["updates"][peer]["verify"])
                         for peer in PACKAGES[1:] if peer != package}
            if app_pid(args,package) is not None: ordinary_kill(args,package,metadata[package]["uid"],output)
            install(package,"prepare"); main_start(args,package)
            prepared=read_lifecycle_report(args,package,receipt["run_id"],"prepare",output)
            result["prepare"]=prepared; save()
            ordinary_kill(args,package,metadata[package]["uid"],output); install(package,"main-actions")
            # Positive fixture setup only; denial/revocation qualification is a later stage.
            adb(args,"shell","pm","grant","--user","0",package,"android.permission.POST_NOTIFICATIONS")
            main_start(args,package)
            first=capture_native_action(args,package,metadata[package]["uid"],prepared,output,package+"-first")
            shade_tap(args,output,package+"-body",prepared["draft"]["name"],action=False)
            wait_session_ui(args,output,package+"-body-resume")
            visible_pid=app_pid(args,package)
            shade_tap(args,output,package+"-visible-action",prepared["draft"]["name"],action=True)
            wait_session_ui(args,output,package+"-visible-resume")
            second=capture_native_action(args,package,metadata[package]["uid"],prepared,output,
                                         package+"-refreshed",previous=first["token"])
            injections=[first,first]
            for field,value in (("application_id",PACKAGES[2] if package==PACKAGES[1] else PACKAGES[1]),
                    ("profile_id","foreign-profile"),("generation",prepared["generation"]+1),
                    ("draft_id","stale-draft"),("rest_start","2000-01-01T00:00:00Z"),
                    ("timer_revision",second["timer_revision"]+1),("token","not-issued")):
                injections.append(dict(second,**{field:value}))
            for index,action in enumerate(injections):
                replay_native_action(args,package,action)
                require(app_pid(args,package)==visible_pid,"native_injection_changed_owner_process")
                wait_session_ui(args,output,package+"-native-injection-"+str(index))
            (output/(package+"-native-injections.json")).write_text(json.dumps(injections,indent=2)+chr(10))
            killed=ordinary_kill(args,package,metadata[package]["uid"],output)
            shade_tap(args,output,package+"-cold-action",prepared["draft"]["name"],action=True)
            wait_session_ui(args,output,package+"-cold-resume")
            cold_pid=app_pid(args,package)
            require(cold_pid is not None and cold_pid != killed,"notification_did_not_cold_start")
            capture_native_action(args,package,metadata[package]["uid"],prepared,output,
                                  package+"-cold-committed-mirror",previous=second["token"])
            ui_tap(args,output,package+"-minimize","Minimize")
            wait_ui_label(args,output,package+"-minimized","Resume workout")
            shade_tap(args,output,package+"-minimized-body",prepared["draft"]["name"],action=False)
            wait_session_ui(args,output,package+"-minimized-resume")
            ordinary_kill(args,package,metadata[package]["uid"],output)
            native={"actual_actions":[first,second],"visible_tap":True,"cold_tap":True,
                    "native_replay_and_fences":True,"ordinary_kill_pid_changed":True,
                    "visible_pid":visible_pid,"ordinary_killed_pid":killed,"cold_pid":cold_pid,
                    "routing_evidence_only":True,"sql_oracle":"closed rest checkpoint"}
            (output/(package+"-native-evidence.json")).write_text(json.dumps(native,indent=2)+chr(10))
            stage_native_evidence(args,package,receipt["run_id"],native)
            install(package,"rest"); main_start(args,package)
            result["rest"]=read_lifecycle_report(args,package,receipt["run_id"],"rest",output); save()
            ordinary_kill(args,package,metadata[package]["uid"],output); install(package,"main-log"); main_start(args,package)
            wait_ui_label(args,output,package+"-resume-before-log","Resume workout")
            ui_tap(args,output,package+"-open-before-log","Resume workout")
            wait_session_ui(args,output,package+"-ready-to-log")
            ui_tap(args,output,package+"-actual-log","Log set 2 · 82.5kg × 5")
            ui_tap(args,output,package+"-log-minimize","Minimize")
            wait_ui_label(args,output,package+"-log-minimized","Resume workout")
            log_pid=ordinary_kill(args,package,metadata[package]["uid"],output); main_start(args,package)
            wait_ui_label(args,output,package+"-log-reopened","Resume workout")
            ui_tap(args,output,package+"-log-resume","Resume workout")
            document=wait_session_ui(args,output,package+"-logged-restored")
            require(not semantic_nodes(document,"Log set 2 · 82.5kg × 5") and
                    semantic_nodes(document,"Finish workout"),"logged_set_did_not_resume")
            require(app_pid(args,package) not in (None,log_pid),"logging_reopen_did_not_change_pid")
            ui_tap(args,output,package+"-actual-finish","Finish workout")
            wait_summary_ui(args,output,package+"-finished-summary",package,receipt["run_id"],prepared)
            wait_notification_absent(args,package,metadata[package]["uid"],output)
            ordinary_kill(args,package,metadata[package]["uid"],output); main_start(args,package)
            wait_ui_label(args,output,package+"-finished-reopen","Today")
            replay_native_action(args,package,first)
            ui_document(args,output,package+"-finished-stale-action")
            ordinary_kill(args,package,metadata[package]["uid"],output)
            install(package,"finish"); main_start(args,package)
            result["finish"]=read_lifecycle_report(args,package,receipt["run_id"],"finish",output)
            require(driver_neighbor_bytes(args,receipt,original)==originals,"lifecycle_neighbor_or_driver_changed")
            result["peer_covered_bytes"]={}
            for peer,before in peer_before.items():
                after=closed_profile_fingerprint(args,peer,base["updates"][peer]["verify"])
                result["peer_covered_bytes"][peer]={"before":before,"after":after}
                require(before==after,"lifecycle_peer_profile_changed")
            installed_matches(args,installed)
            for peer in PACKAGES:
                require(package_metadata(args,peer)=={"uid":metadata[peer]["uid"],
                    "version_code":installed[peer]["version_code"]},"lifecycle_peer_metadata_changed")
            result["initial_lifecycle"]="PASS"; save()
        state["initial_lifecycle_phase"]="PASS"
        state["pending"]["process_kill_recovery"]="PARTIAL: initial normal-main ordinary-kill cases PASS; final candidate pending"
        state["pending"]["lifecycle_notifications"]="PARTIAL: visible/cold taps and replay controls PASS; permissions/exact/force-stop UNRUN"
        state["pending"]["recents_swipe"]="UNRUN: separate task-dismissal case"
        state["pending"]["expired_notification"]="UNRUN: natural expiry and pre-restore action cases"
        save()
    except Exception as error:
        state["initial_lifecycle_phase"]="FAIL"; state["error"]=str(error); save(); raise

def process_identity_self_test():
    # Run the exact production shell program over real owned /proc children.
    # The cat transport pauses a read so the parent can gracefully exit/reap
    # that child, or returns a controlled unreadable/changed native response.
    with tempfile.TemporaryDirectory(prefix="alkion-process-identity-host-") as name:
        root = Path(name); shim = root/"cat"
        native_cat = shutil.which("cat")
        require(native_cat, "process_identity_host_cat_missing")
        shim.write_text('''#!/usr/bin/env python3
import os,subprocess,sys,time
from pathlib import Path
root=Path(os.environ["IDENTITY_CASE"]); mode=os.environ["IDENTITY_MODE"]
path=Path(sys.argv[1]); part=path.name
with (root/"reads").open("a") as log: log.write(part+chr(10))
if mode=="exit-before-"+part:
 (root/"blocked").write_text(part)
 end=time.monotonic()+5
 while not (root/"released").exists():
  if time.monotonic()>=end: raise SystemExit("controlled_read_release_timeout")
  time.sleep(0.005)
if mode=="unreadable-status" and part=="status":
 print("controlled unreadable status",file=sys.stderr); raise SystemExit(1)
if mode=="partial-stat" and part=="stat":
 print("partial native stat"); print("controlled partial read",file=sys.stderr); raise SystemExit(1)
if mode=="changed-start" and part=="stat":
 # Another owned child's real native stat supplies changed start ticks. Only
 # its PID prefix is translated: this is not a claim of real kernel PID reuse.
 value=Path("/proc/"+os.environ["IDENTITY_REPLACEMENT"]+"/stat").read_text()
 print(path.parent.name+value[value.index(" "):],end=""); raise SystemExit(0)
raise SystemExit(subprocess.run([os.environ["IDENTITY_NATIVE_CAT"],str(path)]).returncode)
''')
        shim.chmod(0o755); count = 0
        for mode in ("normal", "absent-before-sample", "exit-before-status", "exit-before-stat",
                     "unreadable-status", "partial-stat", "changed-start"):
            directory = root/mode; directory.mkdir()
            child = subprocess.Popen([sys.executable,"-c","import sys; sys.stdin.buffer.read()"],
                                     stdin=subprocess.PIPE,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            replacement = runner = None
            try:
                ticks = int(Path(f"/proc/{child.pid}/stat").read_text().rsplit(") ",1)[1].split()[19])
                expected = {"pid":child.pid,"uid":os.getuid(),"start_ticks":ticks}
                env = dict(os.environ,PATH=str(root)+os.pathsep+os.environ["PATH"],
                           IDENTITY_CASE=str(directory),IDENTITY_MODE=mode,IDENTITY_NATIVE_CAT=native_cat)
                if mode == "changed-start":
                    time.sleep(1/os.sysconf("SC_CLK_TCK")+0.01)
                    replacement = subprocess.Popen([sys.executable,"-c","import sys; sys.stdin.buffer.read()"],
                        stdin=subprocess.PIPE,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
                    env["IDENTITY_REPLACEMENT"] = str(replacement.pid)
                if mode == "absent-before-sample":
                    child.stdin.close(); child.wait(timeout=5)
                runner = subprocess.Popen(["/bin/sh","-c",PROCESS_IDENTITY_SCRIPT,
                    "alkion-process-identity",str(child.pid)],env=env,text=True,
                    stdout=subprocess.PIPE,stderr=subprocess.PIPE)
                if mode.startswith("exit-before-"):
                    limit = time.monotonic()+5
                    while not (directory/"blocked").exists():
                        require(runner.poll() is None and time.monotonic()<limit,
                                "process_identity_host_read_not_blocked:"+mode)
                        time.sleep(0.005)
                    child.stdin.close(); child.wait(timeout=5)
                    require(not Path(f"/proc/{child.pid}").exists(),"process_identity_host_child_not_reaped")
                    (directory/"released").write_text("reaped")
                stdout,stderr = runner.communicate(timeout=5)
                require(not stderr,"process_identity_host_stderr:"+mode)
                reads = (directory/"reads").read_text().splitlines() if (directory/"reads").exists() else []
                if mode in ("unreadable-status","partial-stat"):
                    require(runner.returncode != 0 and stdout == "" and child.poll() is None and
                            Path(f"/proc/{child.pid}").is_dir(),"process_identity_host_live_read_failure_accepted:"+mode)
                else:
                    require(runner.returncode == 0,"process_identity_host_sample_failed:"+mode)
                    identity = parse_process_identity(stdout,child.pid,os.getuid())
                    if mode in ("absent-before-sample","exit-before-status","exit-before-stat"):
                        require(stdout == "absent\n" and identity is None,"process_identity_host_partial_absence:"+mode)
                    elif mode == "changed-start":
                        try: require(identity == expected,"ordinary_kill_process_identity_changed")
                        except Refusal: pass
                        else: raise Refusal("process_identity_host_changed_start_accepted")
                    else:
                        require(identity == expected,"process_identity_host_normal_identity_changed")
                expected_reads = [] if mode == "absent-before-sample" else ["status"] if mode in (
                    "exit-before-status","unreadable-status") else ["status","stat"]
                require(reads == expected_reads,"process_identity_host_read_order_changed:"+mode)
                print("PASS: real-process identity control",mode); count += 1
            finally:
                for owned in (child,replacement):
                    if owned is not None:
                        if not owned.stdin.closed: owned.stdin.close()
                        owned.wait(timeout=5)
                if runner is not None and runner.poll() is None:
                    (directory/"released").write_text("cleanup")
                    runner.communicate(timeout=5)
        print("PASS:",count,"real-process shell identity controls; no device transport or actual kernel PID reuse.")

def ordinary_kill_self_test():
    # Exercise real argv -> ADB shell joining -> remote shell -> native shims.
    # Only the clock and synthetic /proc mount are substituted; no real ADB runs.
    global time, command
    original_time = time; original_command = command
    class Clock:
        value = 0
        def monotonic(self):
            return self.value
        def sleep(self, seconds):
            self.value += seconds
    with tempfile.TemporaryDirectory(prefix="alkion-ordinary-kill-host-") as name:
        root = Path(name); sdk = root/"sdk"; tools = sdk/"platform-tools"; tools.mkdir(parents=True)
        fake = tools/"adb"
        fake.write_text('''#!/usr/bin/env python3
import json,os,subprocess,sys
from pathlib import Path
tool=Path(sys.argv[0]).name; args=sys.argv[1:]
if tool=="adb":
 assert args[:2]==["-s","emulator-5558"] and len(args)==4 and args[2]=="shell",args
 with open(os.environ["FAKE_ADB_LOG"],"a") as f: f.write(json.dumps(args)+chr(10))
 env=dict(os.environ,PATH=str(Path(sys.argv[0]).parent)+os.pathsep+os.environ["PATH"])
 raise SystemExit(subprocess.run(["/bin/sh","-c"," ".join(args[3:])],env=env).returncode)
command=[tool,*args]
with open(os.environ["FAKE_REMOTE_LOG"],"a") as f: f.write(json.dumps(command)+chr(10))
state_path=Path(os.environ["FAKE_STATE"]); state=json.loads(state_path.read_text())
scenario=state["scenario"]; package="dev.animusstudio.alkion.dev"; pid=4220; uid=10151
previous=scenario.startswith("previous-") and scenario!="previous-to-cached"
settings="com.android.settings/.homepage.SettingsHomepageActivity"
home="com.android.launcher3/.uioverrides.QuickstepLauncher"
def save(): state_path.write_text(json.dumps(state))
if command==["am","get-current-user"]: print(10 if scenario=="foreign-user" else 0)
elif command[:3]==["cmd","package","resolve-activity"]:
 assert args[2:5]==["--brief","--user","0"] and args[5]=="-a",args
 print("priority=1 preferredOrder=0 match=0x108000 specificIndex=-1 isDefault=true")
 component=settings if args[6]=="android.settings.SETTINGS" else home
 print("foreign.package/.Settings" if scenario=="foreign-settings" and component==settings else component)
elif command[:5]==["pm","list","packages","-s","-U"]:
 assert args[4:6]==["--user","0"],args
 if scenario!="non-system": print("package:"+args[-1]+" uid:"+str(1000 if args[-1]=="com.android.settings" else 10120))
elif command==["am","start","-W","--user","0","-n",settings]:
 state["foreground"]="settings"; save(); print("Status: ok")
elif command==["input","keyevent","KEYCODE_HOME"]:
 assert state["foreground"]=="settings"
 state["foreground"]="home"; state["home_started"]=float(os.environ.get("FAKE_CLOCK","0")); save()
elif command==["dumpsys","activity","activities"]:
 component=settings if state["foreground"]=="settings" else home
 if scenario=="settings-not-resumed" and state["foreground"]=="settings": component=package+"/.MainActivity"
 if state["foreground"]=="home":
  state["home_reads"]=state.get("home_reads",0)+1; save()
  if scenario=="home-lost" and state["home_reads"]>1: component=package+"/.MainActivity"
 print("      topResumedActivity=ActivityRecord{223442197 u0 "+component+" t7}")
 if scenario=="ambiguous-resumed" and state["foreground"]=="home": component=package+"/.MainActivity"
 print("  ResumedActivity: "+("malformed" if scenario=="malformed-resumed" else "ActivityRecord{223442197 u0 "+component+" t7}"))
 status="STOPPED" if previous or state.get("eligible") else "STOPPING"
 if scenario=="previous-settles" and state.get("probes",0)<2: status="STOPPING"
 if scenario=="previous-late-stop" and state["foreground"]=="home" and float(os.environ["FAKE_CLOCK"])-state["home_started"]<10.5: status="STOPPING"
 if scenario=="previous-never-stopped" or (scenario=="previous-activity-drift" and state.get("probes",0)>1): status="STOPPING"
 if scenario=="previous-resumed-target": status="RESUMED"
 activity_package="other.package" if scenario=="previous-foreign-activity" else package
 activity_user=10 if scenario=="previous-activity-user" else 0
 record="otherrecord" if scenario=="previous-activity-process" else "7333d1f"
 visibility=["false"]*5
 for index,label in enumerate(("requested","visible","client","drawn","reported")):
  if scenario=="previous-"+label: visibility[index]="true"
 target="    * Hist  #0: ActivityRecord{aa222 u"+str(activity_user)+" "+activity_package+"/dev.animusstudio.alkion.MainActivity t8}"+chr(10)
 target+="      packageName="+package+" processName="+package+chr(10)
 target+="      app=ProcessRecord{"+record+" "+str(pid)+":"+package+"/u0a151}"+chr(10)
 target+="      state="+("malformed" if scenario=="previous-malformed-activity" else status)+" delayedResume=false finishing=false"+chr(10)
 target+="      mVisibleRequested="+visibility[0]+" mVisible="+visibility[1]+" mClientVisible="+visibility[2]+" reportedDrawn="+visibility[3]+" reportedVisible="+visibility[4]+chr(10)
 target+="      nowVisible="+("true" if scenario=="previous-now-visible" else "false")+" lastVisibleTime=-1s"+chr(10)
 print(target)
 if scenario=="previous-duplicate-activity": print(target)
elif command==["dumpsys","activity","processes",package]:
 assert state["foreground"]=="home"
 state["probes"]=state.get("probes",0)+1
 eligible=scenario=="already-cached" or state["probes"]>1
 if scenario=="never-cached": eligible=False
 if previous: eligible=False
 state["eligible"]=eligible or previous; save()
 observed_uid=uid+1 if scenario=="native-uid-change" else uid
 observed_pid=pid+1 if scenario=="native-pid-change" else pid
 adj=900 if eligible else 700; proc_state=16 if scenario=="already-cached" else 15
 if scenario in ("previous-adj-500","previous-adj-600","previous-adj-800"): adj=int(scenario.rsplit("-",1)[1])
 if scenario=="previous-cached-false-900": adj=900
 if scenario=="previous-state-drift" and state["probes"]>1: proc_state=14
 if scenario=="protected-state": proc_state=14
 header="  *APP* UID "+str(observed_uid)+" ProcessRecord{7333d1f "+str(observed_pid)+":"+package+"/u0a"+str(observed_uid-10000)+"}"
 block=header+chr(10)+"    user #0 uid="+str(observed_uid)+" gids={50151}"+chr(10)+"    pid="+str(observed_pid)+chr(10)
 block+="    oom adj: max=1001 curRaw="+str(adj)+" setRaw="+str(adj)+" cur="+str(adj)+" set="+str(adj)+chr(10)
 block+="    curProcState="+str(proc_state)+" mRepProcState="+str(proc_state)+" setProcState="+str(proc_state)+" lastStateTime=-1s395ms"+chr(10)
 block+="    cached="+("true" if eligible else "false")+" empty=false"+chr(10)
 if scenario=="previous-mixed-adj": block=block.replace("setRaw=700","setRaw=900")
 if scenario=="previous-mixed-state": block=block.replace("mRepProcState=15","mRepProcState=16")
 if scenario=="previous-empty": block=block.replace("empty=false","empty=true")
 if scenario=="previous-record-drift" and state["probes"]>1: block=block.replace("7333d1f","newrecord")
 if scenario=="previous-persistent": block+="    persistent=true"+chr(10)
 if scenario=="previous-foreground-service": block+="    hasForegroundServices=true"+chr(10)
 if scenario=="previous-malformed-protected": block+="    persistent=malformed"+chr(10)
 if scenario=="previous-foreground" or (scenario=="previous-foreground-drift" and state["probes"]>1): block+="    foregroundActivities=true (rep=false)"+chr(10)
 if scenario=="already-cached": block+="    foregroundActivities=false (rep=false)"+chr(10)
 if scenario=="foreground-cached": block+="    foregroundActivities=true (rep=false)"+chr(10)
 if scenario=="reported-foreground": block+="    foregroundActivities=false (rep=true)"+chr(10)
 if scenario=="malformed-foreground": block+="    foregroundActivities=malformed"+chr(10)
 if scenario=="duplicate-foreground": block+=("    foregroundActivities=false (rep=false)"+chr(10))*2
 if scenario=="missing-state": block=block.replace("    cached=","    missing=")
 if scenario=="duplicate-state": block+="    cached=true empty=false"+chr(10)
 if scenario=="malformed-header": block=block.replace("*APP* UID ","*APP* UID malformed ")
 print(block)
 if scenario=="duplicate-process": print(block)
 reference="ProcessRecord{7333d1f "+str(pid)+":"+package+"/u0a151}"
 if scenario in ("previous-foreign-reference","previous-conflicting-reference") or (scenario=="previous-reference-drift" and state["probes"]>1): reference="ProcessRecord{7333d1f 4221:other.package/u0a151}"
 if scenario=="previous-record-drift" and state["probes"]>1: reference=reference.replace("7333d1f","newrecord")
 if scenario=="previous-malformed-reference": reference="malformed"
 if scenario!="previous-missing-reference": print("  mPreviousProcess: "+reference)
 if scenario=="previous-exact": print("  mPreviousProcess: "+reference)
 if scenario=="previous-conflicting-reference": print("  mPreviousProcess: ProcessRecord{7333d1f "+str(pid)+":"+package+"/u0a151}")
 # A real dump repeats cached flags in its later OOM summary, at deeper indent.
 print("  OOM levels:"+chr(10)+"        cached=false empty=false hasAboveClient=false")
elif command==["pidof",package]:
 if state.get("killed"):
  state["death_reads"]=state.get("death_reads",0)+1; save()
  gone=scenario!="no-death" and (scenario!="delayed-death" or state["death_reads"]>=3)
  if scenario=="pidof-only-absence": raise SystemExit(1)
  if scenario=="death-between-reads" and state["death_reads"]==1: print(pid); raise SystemExit(0)
  if scenario=="death-omitted-terminating": raise SystemExit(1)
  if scenario=="death-fresh-replacement": print(pid if state["death_reads"]==1 else pid+1); raise SystemExit(0)
  if scenario=="death-restart": print(pid+1)
  elif gone and scenario not in ("pid-reuse","death-uid-reuse"): raise SystemExit(1)
  else: print(pid)
 elif state["foreground"]=="home" and scenario=="pid-change": print(pid+1)
 elif state["foreground"]=="home" and scenario=="spontaneous-death": raise SystemExit(1)
 else: print(pid)
elif command[:2]==["sh","-c"]:
 assert args==["-c",os.environ["FAKE_PROC_SCRIPT"],"alkion-process-identity",str(pid)],args
 proc=Path(os.environ["FAKE_PROC"]); directory=proc/str(pid)
 gone=state.get("killed") and scenario not in ("no-death","pid-reuse","death-uid-reuse","pidof-only-absence") and (scenario!="delayed-death" or state.get("death_reads",0)>=3)
 if scenario=="death-omitted-terminating" and state.get("death_reads",0)<2: gone=False
 if gone:
  for item in directory.iterdir(): item.unlink()
  directory.rmdir()
 else:
  directory.mkdir(exist_ok=True)
  observed_uid=uid+1 if (scenario=="uid-change" and state["foreground"]=="home") or (scenario=="death-uid-reuse" and state.get("killed")) else uid
  ticks=101 if (scenario=="start-changed" and state["foreground"]=="home") or (scenario=="pid-reuse" and state.get("killed")) else 100
  if scenario=="previous-late-start-change" and state.get("probes",0)>1: ticks=101
  (directory/"status").write_text("Name: alkion"+chr(10)+"Pid: "+str(pid)+chr(10)+"Uid: "+" ".join([str(observed_uid)]*4)+chr(10))
  fields=["0"]*49; fields[18]=str(ticks)
  (directory/"stat").write_text(str(pid)+" (alkion (dev)) S "+" ".join(fields)+chr(10))
 script=args[1].replace("/proc/",str(proc)+"/")
 raise SystemExit(subprocess.run(["/bin/sh","-c",script,*args[2:]]).returncode)
elif command==["am","kill","--user","0",package]:
 assert state.get("eligible") and not state.get("killed"),state
 state["killed"]=True; save()
else: raise SystemExit("unexpected remote command: "+repr(command))
''')
        fake.chmod(0o755)
        for remote in ("am","cmd","pm","input","dumpsys","pidof","sh"):
            (tools/remote).symlink_to(fake)
        target = argparse.Namespace(sdk=sdk,serial="emulator-5558")
        previous = dict(os.environ); count = 0
        scenarios = (("previous-to-cached",None,1),("already-cached",None,1),("delayed-death",None,1),
            ("death-between-reads",None,1),("death-omitted-terminating",None,1),
            ("death-fresh-replacement","ordinary_kill_package_restarted",1),
            ("death-uid-reuse","ordinary_kill_proc_pid_or_uid_changed",1),
            ("previous-late-stop",None,1),
            ("never-cached","ordinary_kill_never_became_eligible",0),
            ("protected-state","ordinary_kill_never_became_eligible",0),
            ("foreground-cached","ordinary_kill_never_became_eligible",0),
            ("reported-foreground","ordinary_kill_never_became_eligible",0),
            ("malformed-foreground","ordinary_kill_malformed_foreground_flags",0),
            ("duplicate-foreground","ordinary_kill_foreground_flags_ambiguous",0),
            ("pid-change","ordinary_kill_package_pid_changed",0),
            ("uid-change","ordinary_kill_proc_pid_or_uid_changed",0),
            ("start-changed","ordinary_kill_process_identity_changed",0),
            ("spontaneous-death","ordinary_kill_package_pid_changed",0),
            ("native-uid-change","ordinary_kill_native_pid_or_uid_changed",0),
            ("native-pid-change","ordinary_kill_native_pid_or_uid_changed",0),
            ("duplicate-process","ordinary_kill_process_record_ambiguous",0),
            ("malformed-header","ordinary_kill_native_pid_or_uid_changed",0),
            ("missing-state","ordinary_kill_process_state_ambiguous",0),
            ("duplicate-state","ordinary_kill_process_state_ambiguous",0),
            ("foreign-user","ordinary_kill_primary_user_required",0),
            ("foreign-settings","ordinary_kill_system_activity_unresolved",0),
            ("non-system","ordinary_kill_native_system_package_required",0),
            ("settings-not-resumed","ordinary_kill_expected_system_activity_not_resumed",0),
            ("ambiguous-resumed","ordinary_kill_resumed_activity_ambiguous",0),
            ("malformed-resumed","ordinary_kill_malformed_resumed_activity",0),
            ("home-lost","ordinary_kill_home_no_longer_resumed",0),
            ("total-budget","ordinary_kill_total_budget_exhausted",0),
            ("no-death","ordinary_kill_did_not_exit_no_force_stop_fallback",1),
            ("death-restart","ordinary_kill_package_restarted",1),
            ("pid-reuse","ordinary_kill_process_changed_after_kill",1),
            ("pidof-only-absence","ordinary_kill_did_not_exit_no_force_stop_fallback",1),
            ("previous-exact",None,1),("previous-settles",None,1),
            *((scenario,"ordinary_kill_never_became_eligible",0) for scenario in
                ("previous-never-stopped","previous-resumed-target","previous-visible","previous-requested",
                 "previous-client","previous-drawn","previous-reported","previous-now-visible","previous-mixed-adj",
                 "previous-mixed-state","previous-adj-500","previous-adj-600","previous-adj-800",
                 "previous-cached-false-900","previous-empty","previous-persistent",
                 "previous-foreground-service","previous-foreground")),
            *((scenario,"ordinary_kill_previous_process_mismatch",0) for scenario in
                ("previous-missing-reference","previous-foreign-reference","previous-conflicting-reference",
                 "previous-malformed-reference","previous-reference-drift")),
            ("previous-malformed-protected","ordinary_kill_protected_flags_ambiguous",0),
            ("previous-activity-process","ordinary_kill_target_activity_process_mismatch",0),
            ("previous-foreign-activity","ordinary_kill_target_activity_ambiguous",0),
            ("previous-duplicate-activity","ordinary_kill_target_activity_ambiguous",0),
            ("previous-activity-user","ordinary_kill_target_activity_mismatch",0),
            ("previous-malformed-activity","ordinary_kill_target_activity_state_ambiguous",0),
            ("previous-state-drift","ordinary_kill_process_no_longer_eligible",0),
            ("previous-foreground-drift","ordinary_kill_process_no_longer_eligible",0),
            ("previous-activity-drift","ordinary_kill_activity_no_longer_stopped",0),
            ("previous-record-drift","ordinary_kill_native_process_record_changed",0),
            ("previous-late-start-change","ordinary_kill_process_identity_changed",0))
        try:
            for scenario, expected, kills in scenarios:
                directory = root/scenario; directory.mkdir(); (directory/"proc").mkdir()
                state = directory/"state.json"
                state.write_text(json.dumps({"scenario":scenario,"foreground":"app"}))
                os.environ.update(FAKE_STATE=str(state),FAKE_ADB_LOG=str(directory/"adb.jsonl"),
                    FAKE_REMOTE_LOG=str(directory/"remote.jsonl"),FAKE_PROC=str(directory/"proc"),
                    FAKE_PROC_SCRIPT=PROCESS_IDENTITY_SCRIPT)
                time = Clock()
                def timed_command(argv, **options):
                    require(argv[0] == tools/"adb" and 0 < options["timeout"] <= min(5,30-time.value),
                            "ordinary_kill_host_transport_exceeded_remaining_budget")
                    os.environ["FAKE_CLOCK"] = str(time.value)
                    result = original_command(argv,**options)
                    time.value += min(options["timeout"],5 if scenario == "total-budget" else 0.03)
                    return result
                command = timed_command
                try: killed = ordinary_kill(target,PACKAGES[1],10151,directory)
                except Refusal as error:
                    require(expected and expected in str(error),"ordinary_kill_host_wrong_refusal:"+scenario+":"+str(error))
                else:
                    require(expected is None and killed == 4220,"ordinary_kill_host_missed_refusal:"+scenario)
                record = json.loads(next(directory.glob("*-ordinary-kill-*.json")).read_text())
                require(record["elapsed_seconds"] <= 30.1 and record["result"] == ("FAIL" if expected else "PASS"),
                        "ordinary_kill_host_budget_or_receipt_changed:"+scenario)
                deaths = record.get("death_observations",[])
                if scenario == "death-between-reads":
                    require(len(deaths) == 1 and deaths[0]["package_pid_before"] == 4220 and
                            deaths[0]["identity"] is None and deaths[0]["package_pid_after_absence"] is None,
                            "ordinary_kill_host_between_reads_not_observed")
                if scenario == "death-omitted-terminating":
                    require(len(deaths) >= 2 and deaths[0]["package_pid_before"] is None and
                            deaths[0]["identity"] == record["identity"] and
                            deaths[-1]["identity"] is None and deaths[-1]["package_pid_after_absence"] is None,
                            "ordinary_kill_host_terminating_omission_not_observed")
                if scenario == "death-fresh-replacement":
                    require(deaths[-1]["package_pid_before"] == 4220 and deaths[-1]["identity"] is None and
                            deaths[-1]["package_pid_after_absence"] == 4221 and
                            not record.get("exact_pid_absent"),"ordinary_kill_host_replacement_not_observed")
                commands = [json.loads(line) for line in (directory/"remote.jsonl").read_text().splitlines()]
                require(commands.count(["am","kill","--user","0",PACKAGES[1]]) == kills and
                        not any(word in command for command in commands for word in
                            ("force-stop","kill-all","clear","uninstall","install","rm","su","SIGKILL")),
                        "ordinary_kill_host_forbidden_fallback:"+scenario)
                if expected is None:
                    require(record.get("exact_pid_absent") is True and record["eligibility"][-1]["eligible"] and
                            record.get("eligibility_branch") == ("previous" if scenario.startswith("previous-") and
                            scenario != "previous-to-cached" else "cached"),
                            "ordinary_kill_host_missing_native_proof")
                    if scenario in ("previous-to-cached","previous-settles"):
                        require(not record["eligibility"][0]["eligible"] and len(record["eligibility"]) >= 2,
                                "ordinary_kill_host_previous_app_not_observed")
                    if scenario == "previous-late-stop":
                        require(not record["eligibility"][0]["eligible"] and
                                8 < record["eligibility"][-1]["elapsed_seconds"] < 14,
                                "ordinary_kill_host_late_stop_not_observed")
                count += 1
        finally:
            time = original_time; command = original_command
            os.environ.clear(); os.environ.update(previous)
        print("PASS:",count,"ordinary-kill faithful ADB/remote-shell protocol cases; fake native state/clock only.")

def summary_ui_self_test():
    global ui_document, click_node, time
    count=0; run="1"*32
    def fixture(package=PACKAGES[1]):
        document=ET.Element("hierarchy")
        title="Synthetic lifecycle "+run+" "+package+" · legs"
        def node(label, **changes):
            return ET.SubElement(document,"node",{"text":"","content-desc":label,"package":package,
                "visible-to-user":"true","enabled":"true","clickable":"false",
                "bounds":"[42,199][1038,714]","observer-display-width":"1080",
                "observer-display-height":"2400",**changes})
        named=node(title+"\n2026-10-18")
        heading=node("TOP SETS\nSynthetic exercise\n82.5kg × 5\nPR")
        done=node("Done",clickable="true")
        return document,title,named,heading,done
    for package in PACKAGES[1:]:
        document,title,*_=fixture(package)
        require(summary_ui_ready(document,package,title),"merged_summary_refused"); count+=1
    cases=("missing-heading","duplicate-heading","substring-heading","repeated-heading","hidden-heading",
           "clipped-heading","foreign-heading","missing-title","duplicate-title","substring-title",
           "foreign-run-title","foreign-package-title","partial-title","hidden-title","repeated-title",
           "missing-done","hidden-done","disabled-done","unclickable-done","duplicate-done",
           "substring-done","foreign-done","active-screen","error-screen","transition")
    for case in cases:
        document,title,named,heading,done=fixture()
        if case.startswith("missing-"):
            document.remove({"heading":heading,"title":named,"done":done}[case[8:]])
        elif case.startswith("duplicate-"):
            document.append(ET.fromstring(ET.tostring({"heading":heading,"title":named,"done":done}[case[10:]])))
        elif case.startswith("substring-"):
            node={"heading":heading,"title":named,"done":done}[case[10:]]
            node.set("content-desc","Not "+node.get("content-desc"))
        elif case.startswith("repeated-"):
            node=heading if case=="repeated-heading" else named
            node.set("content-desc",node.get("content-desc")+"\n"+("TOP SETS" if node is heading else title))
        elif case.startswith("hidden-"):
            {"heading":heading,"title":named,"done":done}[case[7:]].set("visible-to-user","false")
        elif case=="clipped-heading": heading.set("bounds","[42,199][1038,2401]")
        elif case in ("foreign-heading","foreign-done"):
            (heading if case=="foreign-heading" else done).set("package",PACKAGES[2])
        elif case=="foreign-run-title": named.set("content-desc",named.get("content-desc").replace(run,"2"*32))
        elif case=="foreign-package-title": named.set("content-desc",named.get("content-desc").replace(PACKAGES[1],PACKAGES[2]))
        elif case=="partial-title": named.set("content-desc",title.removesuffix(" · legs"))
        elif case=="disabled-done": done.set("enabled","false")
        elif case=="unclickable-done": done.set("clickable","false")
        elif case=="active-screen": ET.SubElement(document,"node",{"content-desc":"Minimize"})
        else:
            document.remove(named); document.remove(heading)
            ET.SubElement(document,"node",{"content-desc":"Save failed" if case=="error-screen" else "Notifications delayed"})
        require(not summary_ui_ready(document,PACKAGES[1],title),"invalid_summary_accepted:"+case); count+=1
    original_document,original_click,original_time=ui_document,click_node,time
    try:
        taps=[]; document,title,named,heading,done=fixture()
        ui_document=lambda *args: document
        click_node=lambda args,node: taps.append(node)
        ui_tap(None,None,"exact-done","Done")
        require(taps==[done],"exact_done_action_changed"); count+=1
        heading.set("clickable","true")
        for label in ("TOP SETS","Not Done"):
            try: ui_tap(None,None,"no-line-action",label)
            except Refusal: pass
            else: raise Refusal("summary_line_matching_leaked_into_action_selection")
            require(taps==[done],"nonexact_action_tapped"); count+=1
        prepared={"run_id":run,"application_id":PACKAGES[1],
            "draft":{"name":"Synthetic lifecycle "+run+" "+PACKAGES[1],"focus":"legs"}}
        good=fixture()[0]; transition=ET.Element("hierarchy")
        def poll(pages):
            calls=[]; sleeps=[]
            def capture(args,output,name):
                calls.append(name)
                value=pages[min(len(calls)-1,len(pages)-1)]
                if isinstance(value,Exception): raise value
                return value
            return capture,calls,sleeps
        capture,calls,sleeps=poll([transition,good]); ui_document=capture
        time=SimpleNamespace(sleep=sleeps.append)
        require(wait_summary_ui(None,None,"summary",PACKAGES[1],run,prepared) is good and
                calls==["summary-0","summary-1"] and sleeps==[1],"summary_poll_transition_changed"); count+=1
        capture,calls,sleeps=poll([transition]); ui_document=capture
        time=SimpleNamespace(sleep=sleeps.append)
        try: wait_summary_ui(None,None,"summary",PACKAGES[1],run,prepared)
        except Refusal as error: require(str(error)=="ui_checkpoint_summary_missing","wrong_summary_timeout")
        else: raise Refusal("missing_summary_accepted")
        require(calls==["summary-"+str(i) for i in range(12)] and sleeps==[1]*12,
                "summary_poll_budget_changed"); count+=1
        capture,calls,sleeps=poll([Refusal("capture_failed")]); ui_document=capture
        time=SimpleNamespace(sleep=sleeps.append)
        try: wait_summary_ui(None,None,"summary",PACKAGES[1],run,prepared)
        except Refusal as error: require(str(error)=="capture_failed","capture_failure_reclassified")
        else: raise Refusal("capture_failure_accepted")
        require(calls==["summary-0"] and not sleeps,"capture_failure_retried"); count+=1
        capture,calls,sleeps=poll([good]); ui_document=capture
        time=SimpleNamespace(sleep=sleeps.append)
        try: wait_summary_ui(None,None,"summary",PACKAGES[2],run,prepared)
        except Refusal as error: require(str(error)=="summary_fixture_binding_changed","wrong_summary_binding_failure")
        else: raise Refusal("foreign_summary_fixture_accepted")
        require(not calls and not sleeps,"foreign_summary_binding_observed_before_refusal"); count+=1
    finally:
        ui_document=original_document; click_node=original_click; time=original_time
    print("PASS:",count,"summary-only semantic/action/polling host controls; no device transport.")

def lifecycle_self_test():
    count=0
    environment={"ALKION_FLAVOR":"dev","ALKION_PROOF_RUN":"1"*32,
                 "ALKION_PROOF_VERSION":"41","ALKION_LIFECYCLE_PHASE":"main"}
    main=lifecycle_build_arguments(environment)
    require(main[main.index("--target")+1]=="lib/main.dart" and
            not any("dart-define" in value for value in main),"normal_main_target_changed")
    count+=1
    for phase in ("prepare","rest","finish"):
        argv=lifecycle_build_arguments(dict(environment,ALKION_LIFECYCLE_PHASE=phase))
        require(argv[argv.index("--target")+1]=="integration_test/android_lifecycle_test.dart" and
                "--dart-define=ALKION_LIFECYCLE_PHASE="+phase in argv,"helper_target_changed")
        count+=1
    for field,value in (("ALKION_FLAVOR","foreign"),("ALKION_PROOF_RUN","missing"),
            ("ALKION_PROOF_VERSION","39"),("ALKION_PROOF_VERSION","2100000000"),
            ("ALKION_PROOF_VERSION","40; touch /tmp/not-executed"),
            ("ALKION_LIFECYCLE_PHASE","force-stop")):
        try: lifecycle_build_arguments(dict(environment,**{field:value}))
        except Refusal: count+=1
        else: raise Refusal("unsafe_lifecycle_build_input_accepted")
    receipt={"run_id":"1"*32,"avd":"guard-proof","serial":"emulator-5558"}
    base={"format":"alkion-android-run/1","phase":"updates","updates_phase":"PASS",
          "overall":"IN_PROGRESS","pending":{},"source_commit":"a"*40,
          "base_driver_contract":"alkion-driver/1",**receipt,"installed":{},"updates":{}}
    for index,package in enumerate(PACKAGES):
        facts={"package":package,"version_code":1 if index==0 else 39,
               "apk_sha256":str(index+1)*64,"certificate_sha256":"a"*64}
        base["installed"][package]=facts
        if not index: continue
        report={"format":"alkion-android-update-proof/1","application_id":package,"run_id":"1"*32,
                "complete":True,"closed":True,"result":"PASS","state_digest":"b"*64,
                "installation_id":"installation","profile_id":"profile","generation":1,
                "database_relative":"profiles/profile/alkion.sqlite"}
        meta={"uid":10000+index,"version_code":39}
        base["updates"][package]={"seed":dict(report,phase="seed"),"verify":dict(report,phase="verify"),
            "seed_metadata":dict(meta,version_code=38),"verify_metadata":meta,"verify_apk":facts,
            "driver_and_neighbor_bytes_unchanged":True,"wrong_signer":{"exit_code":1,
              "stderr":"INSTALL_FAILED_UPDATE_INCOMPATIBLE","metadata_before":meta,"metadata_after":meta,
              "candidate":dict(facts,version_code=40,certificate_sha256="b"*64),
              "covered_bytes_before":"c"*64,"covered_bytes_after":"c"*64}}
    require(set(lifecycle_contract(base,receipt))==set(PACKAGES[1:]),"complete_a2_contract_refused"); count+=1
    changes=[("updates_phase","FAIL"),("serial","emulator-5560"),("pending",None),("installed",{})]
    for field,value in changes:
        try: lifecycle_contract(dict(base,**{field:value}),receipt)
        except Refusal: count+=1
        else: raise Refusal("foreign_or_failed_a2_contract_accepted")
    for field,value in (("closed",False),("state_digest","foreign"),("profile_id","foreign")):
        changed=json.loads(json.dumps(base)); changed["updates"][PACKAGES[1]]["verify"][field]=value
        try: lifecycle_contract(changed,receipt)
        except Refusal: count+=1
        else: raise Refusal("incomplete_a2_variant_accepted")
    for field,value in (("candidate",{"package":PACKAGES[2],"version_code":40}),("metadata_before",None)):
        changed=json.loads(json.dumps(base)); changed["updates"][PACKAGES[1]]["wrong_signer"][field]=value
        try: lifecycle_contract(changed,receipt)
        except Refusal: count+=1
        else: raise Refusal("unbound_a2_rejection_accepted")
    package=PACKAGES[1]; uid=10001
    prepared={"profile_id":"profile","generation":1,"draft":{"draftId":"draft",
              "restStart":"2026-10-18T00:00:00Z","name":"Synthetic lifecycle "+"1"*32+" "+package}}
    action={"format":"alkion-notification-action/1","application_id":package,"profile_id":"profile",
            "generation":1,"draft_id":"draft","rest_start":prepared["draft"]["restStart"],
            "timer_revision":7,"token":"11111111-1111-4111-8111-111111111111"}
    def mirror(payload,duplicate=False):
        document=ET.Element("map"); node=ET.SubElement(document,"string",name="scheduled_notifications")
        values=[{"id":4101,"title":prepared["draft"]["name"],"payload":json.dumps(payload)}]
        node.text=json.dumps(values*2 if duplicate else values)
        return ET.tostring(document,encoding="unicode")
    record="pkg="+package+" id=4101 key=0|"+package+"|4101|null|"+str(uid)+" "+prepared["draft"]["name"]+" +30s PendingIntent"
    require(parse_native_mirror(mirror(action),record,package,uid,prepared)==action,"native_mirror_valid_fixture_refused"); count+=1
    for raw,notification in [(mirror(action,True),record),(mirror(action),record.replace(str(uid),"99999")),
            (mirror(dict(action,application_id=PACKAGES[2])),record),
            (mirror(dict(action,rest_start="expired")),record),
            (mirror(dict(action,token="foreign")),record),(mirror(action),"missing"),
            ('<!DOCTYPE map><map/>',record)]:
        try: parse_native_mirror(raw,notification,package,uid,prepared)
        except (Refusal,ValueError,ET.ParseError): count+=1
        else: raise Refusal("unbound_native_mirror_accepted")
    with tempfile.TemporaryDirectory(prefix="alkion-lifecycle-host-") as name:
        root=Path(name); fake=root/"fvm"
        fake.write_text('#!/usr/bin/env python3\nimport json,os,sys\nfrom pathlib import Path\nPath(os.environ["FAKE_FVM_LOG"]).write_text(json.dumps(sys.argv[1:]))\n')
        fake.chmod(0o755)
        env=dict(os.environ,PATH=str(root)+os.pathsep+os.environ["PATH"],FAKE_FVM_LOG=str(root/"fvm.json"))
        common=["make","-C",APP,"android-synthetic-ui-apk","ALKION_FLAVOR=dev",
                "ALKION_PROOF_RUN="+"1"*32,"ALKION_PROOF_SOURCE="+"a"*40,"ALKION_PROOF_VERSION=45"]
        for case in ("en-dark","de-light-reduced","es-light","it-dark"):
            result=command(common+["ALKION_UI_CASE="+case],env=env,check=False)
            require(result.returncode==0,"ui_build_route_valid_input_refused")
            argv=json.loads((root/"fvm.json").read_text())
            require("--dart-define=ALKION_PROOF_VERSION=45" in argv and
                    "--dart-define=ALKION_UI_CASE="+case in argv and
                    argv[argv.index("--target")+1]=="integration_test/android_ui_visual_test.dart",
                    "ui_build_route_arguments_changed"); count+=1
        for variable in ("ALKION_PROOF_SOURCE=bad","ALKION_PROOF_RUN=bad","ALKION_PROOF_VERSION=0",
                         "ALKION_UI_CASE=foreign","ALKION_PROOF_VERSION=45; touch "+str(root/"canary")):
            before=(root/"fvm.json").read_bytes()
            result=command(common+["ALKION_UI_CASE=en-dark",variable],env=env,check=False)
            require(result.returncode!=0 and (root/"fvm.json").read_bytes()==before and not (root/"canary").exists(),
                    "invalid_ui_build_input_reached_fvm"); count+=1
    print("PASS:",count,"lifecycle/build/native-mirror host controls; no real FVM build or device transport.")

def self_test():
    # Execute the real pre-install guards against a private fake transport.
    with tempfile.TemporaryDirectory(prefix="alkion-android-guard-test-") as name:
        root = Path(name)
        sdk = root / "sdk"
        (sdk / "platform-tools").mkdir(parents=True)
        fake = sdk / "platform-tools/adb"
        fake.write_text("""#!/usr/bin/env python3
import hashlib,json,os,subprocess,sys
from pathlib import Path
args=sys.argv[1:]
tool=Path(sys.argv[0]).name
if tool=="adb":
 with open(os.environ["FAKE_LOG"],"a") as f: f.write(repr(args)+chr(10))
 assert args[:2]==["-s","emulator-5558"],args
 cmd=args[2:]
 if cmd and cmd[0]=="shell":
  # AOSP client joins shell argv with spaces, then the remote shell parses it.
  env=dict(os.environ,PATH=str(Path(sys.argv[0]).parent)+os.pathsep+os.environ["PATH"])
  raise SystemExit(subprocess.run(["/bin/sh","-c"," ".join(cmd[1:])],env=env).returncode)
else: cmd=["shell",tool,*args]
scenario=os.environ.get("FAKE_SCENARIO","valid")
if cmd==["get-state"]: print("device")
elif cmd==["emu","avd","name"]: print("wrong" if scenario=="avd" else "guard-proof"); print("OK")
elif cmd[:2]==["shell","getprop"]:
 values={"ro.kernel.qemu":"1","ro.build.version.sdk":"36","ro.product.cpu.abi":"x86_64","sys.boot_completed":"1"}
 print("0" if scenario=="physical" and cmd[2]=="ro.kernel.qemu" else "35" if scenario=="api" and cmd[2]=="ro.build.version.sdk" else values[cmd[2]])
elif cmd[:3]==["shell","pm","path"]:
 packages={"existing":"dev.animusstudio.alkion","existing-dev":"dev.animusstudio.alkion.dev","existing-legacy":"io.github.psychonaut0.reps"}
 if cmd[-1]==packages.get(scenario): print("package:/data/app/unexpected/base.apk")
 if scenario=="transport": print("transport failure",file=sys.stderr); raise SystemExit(1)
 if scenario.startswith("continuation"): print("package:/data/app/fake/"+cmd[-1]+"/base.apk")
elif scenario.startswith("continuation") and cmd[:2]==["shell","sha256sum"]:
 package=cmd[-1].split("/")[-2]
 facts=json.loads(os.environ["FAKE_FACTS"])
 print(("0"*64 if scenario=="continuation-hash" else facts[package]["apk_sha256"])+"  "+cmd[-1])
elif scenario.startswith("continuation") and cmd[:3]==["shell","dumpsys","package"]:
 facts=json.loads(os.environ["FAKE_FACTS"])
 field="userId=" if scenario=="continuation-old-schema" else "appId="
 print(field+str(10000+list(facts).index(cmd[-1])))
 print("versionCode="+str(facts[cmd[-1]]["version_code"]))
elif scenario.startswith("continuation") and cmd[:5]==["shell","pm","list","packages","-U"]:
 facts=json.loads(os.environ["FAKE_FACTS"])
 package=cmd[-1]
 uid=10000+list(facts).index(package)
 exact="package:"+package+" uid:"+str(uid)
 foreign="package:"+("dev.animusstudio.alkion.dev" if package=="dev.animusstudio.alkion" else package+".peer")+" uid:99999"
 if scenario=="continuation-uid-missing": pass
 elif scenario=="continuation-uid-foreign-only": print(foreign)
 elif scenario=="continuation-uid-malformed": print("package:"+package+" uid:not-numeric")
 elif scenario=="continuation-uid-duplicate": print(exact); print(exact)
 elif scenario=="continuation-uid-conflicting": print(exact); print("package:"+package+" uid:"+str(uid+1))
 else:
  if scenario=="continuation-uid-exact-and-foreign": print(foreign)
  print(exact)
elif scenario.startswith("continuation") and cmd[:2]==["shell","run-as"]:
 app=Path(os.environ["FAKE_APP_ROOT"])/cmd[2]
 app.mkdir(parents=True,exist_ok=True)
 if cmd[3]=="/system/bin/sh" and cmd[4]=="-c":
  path=app/cmd[-1]
  if cmd[-2]=="alkion-absent-root":
   if scenario=="continuation-profile": path.mkdir(parents=True,exist_ok=True)
  elif cmd[-2]=="alkion-covered-file":
   path.parent.mkdir(parents=True,exist_ok=True)
   optional=str(path).endswith(("-wal","-shm","-journal"))
   if not optional and not path.exists(): path.write_bytes(b"covered")
   if str(path).endswith("-wal") and scenario in ("continuation-wal","continuation-wal-changed"):
    path.write_bytes(b"old WAL" if scenario=="continuation-wal" else b"changed WAL")
   if scenario=="continuation-linked":
    if path.exists(): path.unlink()
    path.symlink_to(app/"linked-target")
  elif cmd[-2] in ("alkion-native-evidence","alkion-native-mirror"): pass
  else: raise SystemExit("unexpected nested shell argv: "+repr(cmd))
  raise SystemExit(subprocess.run(["/bin/sh",*cmd[4:]],cwd=app).returncode)
 elif cmd[3]=="sha256sum":
  path=app/cmd[-1]
  print(hashlib.sha256(path.read_bytes()).hexdigest()+"  "+cmd[-1])
 else: raise SystemExit("unexpected scoped read: "+repr(cmd))
else: raise SystemExit("unexpected transport mutation: "+repr(cmd))
""")
        fake.chmod(0o755)
        for remote_tool in ("getprop","pm","dumpsys","sha256sum","run-as"):
            (fake.parent / remote_tool).symlink_to(fake)
        avds = root / "avd"
        directory = avds / "guard-proof.avd"
        directory.mkdir(parents=True)
        (avds / "guard-proof.ini").write_text("path=" + str(directory) + chr(10))
        (directory / "config.ini").write_text("abi.type=x86_64" + chr(10) +
            "tag.id=default" + chr(10) + "image.sysdir.1=system-images/android-36/default/x86_64/" + chr(10))
        user = root / "user"
        user.mkdir()
        receipt = root / "disposable.json"
        receipt.write_text(json.dumps({"format":"alkion-android-disposable/1","purpose":"synthetic-only",
            "fresh":True,"run_id":"1"*32,"avd":"guard-proof","serial":"emulator-5558",
            "api":36,"abi":"x86_64","system_image":"system-images;android-36;default;x86_64",
            "avd_home":str(avds),"android_user_home":str(user)}))
        env = dict(os.environ, ANDROID_HOME=str(sdk), ANDROID_USER_HOME=str(user), FAKE_LOG=str(root / "adb.log"), FAKE_APP_ROOT=str(root / "app-data"))
        base = ["bash", SCRIPT, "--action", "check", "--avd", "guard-proof", "--serial",
                "emulator-5558", "--receipt", receipt, "--output", root / "fresh-output"]
        count = 0
        def expect(argv, expected, scenario="valid", variables=None):
            nonlocal count
            result = command(argv, env=dict(env,FAKE_SCENARIO=scenario,**(variables or {})), check=False)
            require((result.returncode == 0) if expected is None else
                    (result.returncode != 0 and expected in result.stderr),
                    "guard_self_test:" + scenario + ":" + str(expected))
            count += 1
        def option(name, value):
            changed = list(base)
            changed[changed.index(name) + 1] = value
            return changed
        for scenario, expected in (("valid",None),("avd","device_avd_mismatch"),
                                   ("physical","device_platform_mismatch"),
                                   ("api","device_platform_mismatch"),
                                   ("existing","preexisting_package"),
                                   ("existing-dev","preexisting_package"),
                                   ("existing-legacy","preexisting_package"),
                                   ("transport","package_query_failed")):
            expect(base, expected, scenario)
        expect(["bash",SCRIPT,"--action","check"], "explicit_emulator_serial_required")
        expect(option("--serial","phone-serial"), "explicit_emulator_serial_required")
        expect(option("--serial","emulator-5559"), "invalid_emulator_port")
        expect(option("--receipt",root / "absent.json"), "owned_path_required")
        linked = root / "linked.json"
        linked.symlink_to(receipt)
        expect(option("--receipt",linked), "linked_temporary_path")
        existing = root / "existing-output"
        existing.mkdir()
        expect(option("--output",existing), "output_exists_do_not_adopt_prior_run")
        original = json.loads(receipt.read_text())
        for field, value, expected in (("fresh",False,"fresh_disposable_attestation_required"),
                ("serial","emulator-5560","receipt_target_mismatch"),
                ("run_id","not-a-run","invalid_run_id"),
                ("api",35,"unsupported_receipt_platform")):
            receipt.write_text(json.dumps(dict(original,**{field:value})))
            expect(base, expected)
        receipt.write_text(json.dumps(original))
        expect(base, "android_user_home_mismatch", variables={"ANDROID_USER_HOME":str(root / "other")})
        receipt.chmod(0o666)
        expect(base, "receipt_must_be_coordinator_owned")
        receipt.chmod(0o600)
        config = directory / "config.ini"
        original_config = config.read_text()
        spaced_config = "  # ignored = comment" + chr(10) + " abi.type = x86_64 " + chr(10) + \
            " tag.id = default " + chr(10) + " image.sysdir.1 = system-images/android-36/default/x86_64/ " + chr(10)
        config.write_text(spaced_config)
        avd_ini = avds / "guard-proof.ini"
        avd_ini.write_text(" path = " + str(directory) + " " + chr(10))
        expect(base, None)
        for changed in (spaced_config.replace("android-36", "android-37"),
                        spaced_config.replace("abi.type = x86_64", "abi.type = arm64-v8a"),
                        spaced_config.replace("tag.id = default", "tag.id = google_apis")):
            config.write_text(changed)
            expect(base, "avd_image_mismatch")
        config.write_text(spaced_config)
        avd_ini.write_text(" path = " + str(directory) + "-other " + chr(10))
        expect(base, "avd_directory_mismatch")
        config.write_text(original_config)
        avd_ini.write_text("path=" + str(directory) + chr(10))
        config.rename(directory / "real-config.ini")
        config.symlink_to(directory / "real-config.ini")
        expect(base, "avd_config_missing_or_linked")
        config.unlink()
        (directory / "real-config.ini").rename(config)
        transport = (root / "adb.log").read_text()
        require(all(word not in transport for word in ("install", "start", "clear", "uninstall")),
                "self_test_reached_mutation")
        for raw in ('{"result":"FAIL","error":"synthetic failure"}',
                    '{"result":"PASS","run_id":"wrong"}', 'malformed terminal receipt'):
            try:
                receive_driver_report(root, "dev", raw)
            except ValueError:
                pass
            require((root / "driver-dev-report.json").read_text() == raw,
                    "terminal_report_not_preserved")
        result = {"format":"alkion-android-driver-proof/1", "run_id":"1"*32,
                  "application_id":PACKAGES[1], "complete":True, "result":"PASS",
                  "cases":{name:"PASS" for name in CASES}}
        validate_driver_report(result, "1"*32, PACKAGES[1])
        for cases in ({name:"PASS" for name in CASES if name != "native_owner_process"},
                      dict(result["cases"], native_owner_process="FAIL")):
            try:
                validate_driver_report(dict(result,cases=cases), "1"*32, PACKAGES[1])
            except Refusal as error:
                require("driver_assertions_incomplete_or_failed" in str(error), "wrong_case_contract_error")
            else:
                raise Refusal("missing_or_failed_process_case_was_accepted")
        continuation_count = 0
        for action_args,expected in ((("updates-check", ""),"successful_base_run_receipt_required"),
                (("updates-check", str(root / "missing-run.json")),"owned_path_required")):
            argv=option("--action",action_args[0])+["--base-run",action_args[1]]
            result_check=command(argv,env=env,check=False)
            require(result_check.returncode != 0 and expected in result_check.stderr, "missing_base_run_accepted")
            continuation_count += 1
        local = {package:{"package":package,"apk_sha256":str(index+1)*64,
                 "certificate_sha256":"a"*64,"version_code":37} for index,package in enumerate(PACKAGES)}
        base_run = {"format":"alkion-android-run/1","phase":"driver","driver_phase":"PASS",
                    "overall":"IN_PROGRESS","source_commit":"a"*40,"installed":local,
                    "pending":{"updates_and_wrong_signer":"UNRUN"},
                    **{key:original[key] for key in ("run_id","avd","serial","api","abi")},
                    "driver":{flavor:dict(result,application_id=package)
                              for flavor,package in (("dev",PACKAGES[1]),("supported",PACKAGES[2]))}}
        require(driver_continuation_contract(base_run,original)=="alkion-driver/2", "new_contract_refused")
        legacy = json.loads(json.dumps(base_run))
        for value in legacy["driver"].values(): value["cases"].pop("native_owner_process")
        require(driver_continuation_contract(legacy,original)=="alkion-driver/1", "old_contract_refused")
        continuation_count += 2
        for field,value in (("driver_phase","FAIL"),("serial","emulator-5560"),("api",35),
                            ("source_commit","unknown"),("installed",{})):
            try: driver_continuation_contract(dict(base_run,**{field:value}),original)
            except Refusal: continuation_count += 1
            else: raise Refusal("foreign_or_failed_run_accepted:"+field)
        incomplete=json.loads(json.dumps(base_run)); incomplete["driver"]["supported"]["complete"]=False
        try: driver_continuation_contract(incomplete,original)
        except Refusal: continuation_count += 1
        else: raise Refusal("incomplete_run_accepted")
        previous=dict(os.environ)
        os.environ.update(env,FAKE_FACTS=json.dumps(local))
        target=argparse.Namespace(sdk=sdk,serial="emulator-5558",avd="guard-proof")
        try:
            for scenario,error in (("continuation",None),("continuation-old-schema",None),
                    ("continuation-uid-exact-and-foreign",None),
                    ("continuation-uid-missing","package_metadata_unavailable"),
                    ("continuation-uid-duplicate","package_metadata_unavailable"),
                    ("continuation-uid-conflicting","package_metadata_unavailable"),
                    ("continuation-uid-malformed","package_metadata_unavailable"),
                    ("continuation-uid-foreign-only","package_metadata_unavailable"),
                    ("continuation-hash","same_run_apk_changed"),
                    ("continuation-profile","unexpected_existing_update_profile")):
                os.environ["FAKE_SCENARIO"]=scenario
                try: metadata=continuation_device_guard(target,original,base_run,local)
                except Refusal as refused:
                    require(error and error in str(refused),"continuation_guard_wrong_failure")
                else:
                    require(error is None,"continuation_guard_missed_failure")
                    require(metadata=={package:{"version_code":37,"uid":10000+index}
                            for index,package in enumerate(PACKAGES)},"exact_package_uid_changed")
                continuation_count += 1
            os.environ["FAKE_SCENARIO"]="continuation"
            nested=adb(target,"shell","/bin/sh","-c",
                       'test "$1" = expected && printf matched',"alkion-probe","expected")
            require(nested.stdout=="matched", "nested_shell_program_or_positional_argument_changed")
            canary=root / "literal-must-not-execute"
            literals=["", "space value", "single' and double\"", "$HOME",
                      "$(printf SUBSTITUTED)", "`printf SUBSTITUTED`", "line"+chr(10)+"break",
                      "; : > "+str(canary)+"; #", "| & < > ( )", "--leading", "è"]
            echoed=adb(target,"shell",sys.executable,"-c",
                       "import json,sys;print(json.dumps(sys.argv[1:]))",*literals)
            require(json.loads(echoed.stdout)==literals and not canary.exists(),
                    "remote_shell_literal_substitution_or_operator_execution")
            for field,value,expected in (("certificate_sha256","b"*64,"saved_apk_binding_mismatch"),
                                         ("version_code",38,"installed_version_mismatch")):
                changed=json.loads(json.dumps(local)); changed[PACKAGES[1]][field]=value
                try: continuation_device_guard(target,original,base_run,changed)
                except Refusal as refused:
                    require(expected in str(refused),"wrong_saved_binding_failure")
                else: raise Refusal("saved_binding_change_accepted")
                continuation_count += 1
            covered={"profile_id":"11111111-1111-4111-8111-111111111111",
                     "database_relative":"profiles/11111111-1111-4111-8111-111111111111/alkion.sqlite"}
            os.environ["FAKE_SCENARIO"]="continuation"
            absent=closed_profile_fingerprint(target,PACKAGES[1],covered)
            require(closed_profile_fingerprint(target,PACKAGES[1],covered)==absent,"stable_covered_bytes_changed")
            os.environ["FAKE_SCENARIO"]="continuation-wal"
            present=closed_profile_fingerprint(target,PACKAGES[1],covered)
            require(present != absent,"sidecar_presence_omitted")
            os.environ["FAKE_SCENARIO"]="continuation-wal-changed"
            require(closed_profile_fingerprint(target,PACKAGES[1],covered)!=present,"wal_bytes_omitted")
            os.environ["FAKE_SCENARIO"]="continuation-linked"
            try: closed_profile_fingerprint(target,PACKAGES[1],covered)
            except Refusal: pass
            else: raise Refusal("linked_covered_file_accepted")
            continuation_count += 4
            os.environ["FAKE_SCENARIO"]="continuation"
            app=root/"app-data"/PACKAGES[1]
            marker=app/"files/android-lifecycle"/original["run_id"]/"native-evidence.json"
            marker.parent.mkdir(parents=True)
            payload={"literal":"$HOME $(touch never) `touch never` ; | &"+chr(10)+"quote'\""}
            stage_native_evidence(target,PACKAGES[1],original["run_id"],payload)
            expected=marker.read_bytes()
            require(json.loads(expected)==payload,"native_marker_shell_payload_changed")
            try: stage_native_evidence(target,PACKAGES[1],original["run_id"],{"replacement":True})
            except Refusal: pass
            else: raise Refusal("native_marker_overwrite_accepted")
            require(marker.read_bytes()==expected and not (app/"never").exists(),"native_marker_changed_or_executed")
            prefs=app/"shared_prefs/scheduled_notifications.xml"
            prefs.parent.mkdir(); prefs.write_text("<map/>")
            require(read_native_mirror(target,PACKAGES[1]).stdout=="<map/>","bounded_mirror_read_changed")
            prefs.write_text("x"*131073)
            require(read_native_mirror(target,PACKAGES[1]).returncode!=0,"oversize_mirror_was_read")
            prefs.unlink(); prefs.symlink_to(marker)
            require(read_native_mirror(target,PACKAGES[1]).returncode!=0,"linked_mirror_was_read")
            continuation_count += 5
        finally:
            os.environ.clear(); os.environ.update(previous)
        package=PACKAGES[1]; before=local[package]
        positive=dict(before,version_code=38)
        audit_update_candidate(positive,package,before,38)
        audit_update_candidate(dict(positive,certificate_sha256="b"*64),package,before,38,wrong_signer=True)
        try: audit_update_candidate(positive,package,before,38,wrong_signer=True)
        except Refusal: continuation_count += 1
        else: raise Refusal("same_signer_negative_candidate_accepted")
        for candidate in (dict(positive,package=PACKAGES[2]),dict(positive,version_code=37),
                          dict(positive,certificate_sha256="b"*64)):
            try: audit_update_candidate(candidate,package,before,38)
            except Refusal: continuation_count += 1
            else: raise Refusal("unsafe_candidate_audit_accepted")
        continuation_count += 2
        transport=(root / "adb.log").read_text()
        require(all(word not in transport for word in ("install","start","clear","uninstall")),
                "continuation_self_test_reached_mutation")
        print("PASS:",count,"fresh guards +3 raw-report +3 driver-contract +2 faithful shell-quoting +",continuation_count,
              "continuation/candidate cases; fake transport only; zero install/start/clear/uninstall.")

def documents_module():
    # The source candidate must remain clean; never cache imports in the checkout.
    sys.dont_write_bytecode = True
    sys.path.insert(0, str(SCRIPT.parent))
    import android_synthetic_documents
    return android_synthetic_documents

def ui_module():
    sys.dont_write_bytecode = True
    sys.path.insert(0,str(SCRIPT.parent))
    import android_synthetic_ui
    return android_synthetic_ui

def ui_host():
    names=("APP","command","adb","temporary_path","read_json","toolchain","apk_facts",
           "package_metadata","device_platform_guard")
    return SimpleNamespace(**{name:globals()[name] for name in names})

def documents_host():
    names = ("APP", "command", "adb", "receipt_guard", "temporary_path", "read_json", "toolchain",
             "apk_facts", "installed_matches", "package_metadata", "device_platform_guard",
             "driver_continuation_contract", "lifecycle_contract", "driver_neighbor_bytes",
             "closed_profile_fingerprint", "app_pid", "ordinary_kill", "ui_document", "click_node")
    return SimpleNamespace(**{name: globals()[name] for name in names})

def publish_module():
    sys.dont_write_bytecode = True
    sys.path.insert(0, str(SCRIPT.parent))
    import android_synthetic_publish
    return android_synthetic_publish

def publish_host():
    names = ("APP", "command", "temporary_path", "read_json", "package_metadata")
    return SimpleNamespace(**{name: globals()[name] for name in names})

def publisher_binding(args, revision):
    # After the read-only preparation and before any device mutation: bind the
    # explicit receipt to the clean HEAD that preparation just attested.
    require(getattr(args, "publisher_build", None), "explicit_publisher_build_required")
    require(documents_module().source(documents_host()) == revision, "publisher_binding_source_changed")
    args._publisher = publish_module().load_build(publish_host(), args, args.publisher_build, revision)
    return args._publisher

def capabilities_module():
    sys.dont_write_bytecode = True
    sys.path.insert(0, str(SCRIPT.parent))
    import android_synthetic_capabilities
    return android_synthetic_capabilities

def capabilities_host():
    names = ("resumed_component", "read_native_mirror", "parse_native_mirror", "ui_tap", "wait_ui_label", "wait_session_ui")
    return SimpleNamespace(**vars(documents_host()), **{name: globals()[name] for name in names})

def capabilities_action(args):
    module = capabilities_module(); host = capabilities_host()
    if args.action == "build-capability":
        argv = module.capability_build_arguments(os.environ)
        revision = os.environ.get("ALKION_PROOF_SOURCE", "")
        require(re.fullmatch(r"[a-f0-9]{40}", revision), "explicit_capability_build_source_required")
        toolchain(args)
        require(module.current_source(host) == revision, "capability_build_source_mismatch")
        built = command(argv, check=False, timeout=600)
        print(built.stdout, end=""); print(built.stderr, end="", file=sys.stderr)
        require(module.current_source(host) == revision, "source_changed_during_capability_build")
        raise SystemExit(built.returncode)
    args.attempt_manifests = json.loads(args.attempt_manifests_json)
    require(isinstance(args.attempt_manifests, list) and all(isinstance(value, str) for value in args.attempt_manifests),
            "explicit_attempt_manifest_list_required")
    prepared = module.prepare(host, args)
    publisher_binding(args, prepared.revision)
    ui_module().bind_previous(ui_host(), args, prepared.receipt, prepared.lifecycle, Path(args.base_run).parent, prepared.revision)
    if args.action == "capabilities-check":
        print("Recognized driver/A2/current lifecycle, version ledger and accepted UI observer verified; no mutation or allocation.")
    else:
        return module.run(host, prepared)

def documents_action(args):
    module = documents_module(); host = documents_host()
    if args.action == "build-documents":
        argv = module.documents_build_arguments(os.environ)
        toolchain(args)
        revision = os.environ["ALKION_PROOF_SOURCE"]
        require(module.source(host) == revision, "documents_build_source_mismatch")
        built = command(argv, check=False, timeout=600)
        print(built.stdout, end=""); print(built.stderr, end="", file=sys.stderr)
        require(module.source(host) == revision, "source_changed_during_documents_build")
        raise SystemExit(built.returncode)
    if args.action == "build-documents-provider":
        revision = os.environ.get("ALKION_PROOF_SOURCE", "")
        require(re.fullmatch(r"[a-f0-9]{40}", revision), "explicit_provider_build_source_required")
        require(args.output is not None, "fresh_output_required")
        require(module.source(host) == revision, "provider_build_source_mismatch")
        apk, facts = module.build_provider(host, args, temporary_path(args.output))
        require(module.source(host) == revision, "source_changed_during_provider_build")
        print("Synthetic documents provider built:", apk)
        return
    prepared = module.prepare(host, args)
    publisher_binding(args, prepared.revision)
    if args.action == "documents-check":
        print("Recognized driver/A2/current-lifecycle installation verified; no install, enable, launch or picker action.")
    else:
        ui_module().bind_previous(ui_host(),args,prepared.receipt,prepared.lifecycle,
            Path(args.base_run).parent,prepared.revision)
        return module.run(host, prepared)

def restore_module():
    sys.dont_write_bytecode = True
    sys.path.insert(0, str(SCRIPT.parent))
    import android_synthetic_restore
    return android_synthetic_restore

def restore_ui_validate_build(host, args, root, record):
    return ui_module().validate_build(ui_host(), args, root, record)

def restore_ui_install_fresh(host, args, receipt, root, record, revision):
    return ui_module().install_fresh(ui_host(), args, receipt, root, record, revision)

def restore_host():
    names = ("APP", "command", "adb", "receipt_guard", "temporary_path", "read_json", "toolchain",
             "apk_facts", "installed_matches", "package_metadata", "device_platform_guard",
             "driver_continuation_contract", "lifecycle_contract", "driver_neighbor_bytes", "app_pid",
             "ordinary_kill", "ui_document", "click_node", "PROCESS_IDENTITY_SCRIPT", "parse_process_identity")
    return SimpleNamespace(**{name: globals()[name] for name in names},
        ui_observer_validate_build=restore_ui_validate_build, ui_observer_install_fresh=restore_ui_install_fresh)

def restore_action(args):
    module, host = restore_module(), restore_host()
    require(len(args.attempt_manifests_json.encode()) <= module.JSON_LIMIT, "restore_attempt_list_too_large")
    args.attempt_manifests = json.loads(args.attempt_manifests_json)
    require(isinstance(args.attempt_manifests, list) and len(args.attempt_manifests) <= 64 and
            all(isinstance(value, str) and len(value) <= 4096 for value in args.attempt_manifests),
            "explicit_restore_attempt_manifest_list_required")
    try:
        if args.action == "build-restore":
            built = module.build_pair(host, module.prepare_pair_build(host, args, os.environ))
            print("Retained paired restore APKs and exact build manifest:", Path(built["variants"]["dev"]["apk"]).parent / "build.json")
            return built
        prepared = module.prepare(host, args)
        publisher_binding(args, prepared.revision)
        if args.action == "restore-check":
            print("Explicit fresh receiver, source chain, paired artifacts, ledger and fresh observer verified; no install or launch.")
            return
        return module.run(host, prepared)
    except subprocess.TimeoutExpired as error:
        # Read-only preflight has no output directory to claim. Preserve exact
        # partial bytes in a typed stderr record for the coordinator's CLI log.
        receipt = getattr(error, "restore_timeout_receipt", None)
        if receipt is not None:
            print(json.dumps({**receipt,
                "stdout_base64": module.base64.b64encode(error.restore_partial_stdout).decode(),
                "stderr_base64": module.base64.b64encode(error.restore_partial_stderr).decode()}, sort_keys=True), file=sys.stderr)
        raise

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--action", choices=("check","driver","updates-check","updates","lifecycle-check","lifecycle","build-lifecycle","build-neighbor","build-ui-observer","self-test","documents-check","documents","build-documents","build-documents-provider","capabilities-check","capabilities","build-capability","build-restore","restore-check","restore","build-publisher"), default="check")
parser.add_argument("--avd")
parser.add_argument("--serial")
parser.add_argument("--receipt")
parser.add_argument("--output")
parser.add_argument("--base-run")
parser.add_argument("--driver-run")
parser.add_argument("--updates-run")
parser.add_argument("--version-ledger")
parser.add_argument("--source-review")
parser.add_argument("--attempt-manifests-json", default="[]")
parser.add_argument("--jit-build-budget", type=int, default=120)
parser.add_argument("--source-manifest")
parser.add_argument("--receiver-driver")
parser.add_argument("--candidate-manifest")
parser.add_argument("--dev-apk")
parser.add_argument("--supported-apk")
parser.add_argument("--provider-apk")
parser.add_argument("--ui-observer-build")
parser.add_argument("--publisher-build")
args = parser.parse_args(sys.argv[2:])
args.sdk = Path(os.environ.get("ANDROID_HOME",""))
try:
    if args.action == "self-test":
        self_test()
        summary_ui_self_test()
        lifecycle_self_test()
        ordinary_kill_self_test()
        process_identity_self_test()
    elif args.action == "build-lifecycle":
        argv = lifecycle_build_arguments(os.environ)
        toolchain(args)
        built = command(argv, check=False, timeout=600)
        print(built.stdout, end=""); print(built.stderr, end="", file=sys.stderr)
        raise SystemExit(built.returncode)
    elif args.action == "build-neighbor":
        require(args.output is not None,"fresh_output_required")
        apk, facts = build_neighbor(args,temporary_path(args.output))
        print("Synthetic neighbor built:",apk)
    elif args.action == "build-ui-observer":
        revision=os.environ.get("ALKION_PROOF_SOURCE","")
        require(args.output is not None and ui_module().source(ui_host()) == revision,"explicit_ui_build_source_required")
        apk,facts=ui_module().build(ui_host(),args,temporary_path(args.output),revision)
        require(ui_module().source(ui_host()) == revision,"source_changed_during_ui_build")
        print("Synthetic UI observer built:",apk)
    elif args.action == "build-publisher":
        revision = os.environ.get("ALKION_PROOF_SOURCE", "")
        require(re.fullmatch(r"[a-f0-9]{40}", revision), "explicit_publisher_build_source_required")
        require(args.output is not None, "fresh_output_required")
        require(documents_module().source(documents_host()) == revision, "publisher_build_source_mismatch")
        publish_module().build(publish_host(), args, temporary_path(args.output), revision)
        require(documents_module().source(documents_host()) == revision, "source_changed_during_publisher_build")
        print("Test publisher built:", temporary_path(args.output) / "build.json")
    elif args.action in ("capabilities-check", "capabilities", "build-capability"):
        capabilities_action(args)
    elif args.action in ("build-restore", "restore-check", "restore"):
        restore_action(args)
    elif args.action in ("documents-check", "documents", "build-documents", "build-documents-provider"):
        documents_action(args)
    else:
        receipt, output = receipt_guard(args)
        require((args.sdk / "platform-tools/adb").is_file(),"adb_required")
        if args.action in ("lifecycle-check","lifecycle"):
            base,original,local,metadata=prepare_lifecycle(args,receipt,output)
            if args.action == "lifecycle-check":
                print("Recognized A2 installation verified; no install, permission change or launch.")
            else:
                run_lifecycle(args,receipt,output,base,original,local,metadata)
        elif args.action in ("updates-check","updates"):
            base,local,metadata,contract=prepare_updates(args,receipt,output)
            if args.action == "updates-check":
                print("Recognized successful synthetic run verified; no install, key creation or launch.")
            else:
                run_updates(args,receipt,output,base,local,metadata,contract)
        elif args.action == "check":
            device_guard(args)
            print("Fresh named synthetic target verified; no install or launch performed.")
        else:
            device_guard(args)
            run_driver(args,receipt,output)
except (Refusal, ValueError, KeyError, OSError, ET.ParseError, subprocess.TimeoutExpired) as error:
    print("REFUSED:",error,file=sys.stderr)
    raise SystemExit(2)
PY

