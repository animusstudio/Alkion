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
import zipfile

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

def command(argv, *, timeout=30, check=True, env=None):
    result = subprocess.run([str(x) for x in argv], text=True, capture_output=True,
                            timeout=timeout, env=env)
    if check and result.returncode:
        raise Refusal("command_failed: " + str(argv[0]) + ": " + result.stderr.strip()[-400:])
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

def adb(args, *tail, check=True):
    # Every invocation, including emu/package queries, carries this exact serial.
    # ADB joins shell arguments without escaping; preserve argv through that
    # outer remote shell before any nested sh -c interprets its fixed program.
    if tail and tail[0] == "shell":
        tail = ("shell", shlex.join(str(value) for value in tail[1:]))
    return command([args.sdk / "platform-tools/adb", "-s", args.serial, *tail],
                   check=check, timeout=60)

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
                         "final_candidate": "UNRUN: final UI and installed-device gate"}}
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
    uid = re.findall(r"\buserId=([0-9]+)\b", value)
    require(len(set(version)) == 1 and len(set(uid)) == 1, "package_metadata_unavailable")
    return {"version_code": int(version[0]), "uid": int(uid[0])}

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
 print("userId="+str(10000+list(facts).index(cmd[-1])))
 print("versionCode="+str(facts[cmd[-1]]["version_code"]))
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
            for scenario,error in (("continuation",None),("continuation-hash","same_run_apk_changed"),
                                   ("continuation-profile","unexpected_existing_update_profile")):
                os.environ["FAKE_SCENARIO"]=scenario
                try: continuation_device_guard(target,original,base_run,local)
                except Refusal as refused:
                    require(error and error in str(refused),"continuation_guard_wrong_failure")
                else: require(error is None,"continuation_guard_missed_failure")
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

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--action", choices=("check","driver","updates-check","updates","build-neighbor","self-test"), default="check")
parser.add_argument("--avd")
parser.add_argument("--serial")
parser.add_argument("--receipt")
parser.add_argument("--output")
parser.add_argument("--base-run")
args = parser.parse_args(sys.argv[2:])
args.sdk = Path(os.environ.get("ANDROID_HOME",""))
try:
    if args.action == "self-test":
        self_test()
    elif args.action == "build-neighbor":
        require(args.output is not None,"fresh_output_required")
        apk, facts = build_neighbor(args,temporary_path(args.output))
        print("Synthetic neighbor built:",apk)
    else:
        receipt, output = receipt_guard(args)
        require((args.sdk / "platform-tools/adb").is_file(),"adb_required")
        if args.action in ("updates-check","updates"):
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
except (Refusal, ValueError, KeyError, OSError, subprocess.TimeoutExpired) as error:
    print("REFUSED:",error,file=sys.stderr)
    raise SystemExit(2)
PY

