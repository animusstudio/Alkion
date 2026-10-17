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

def read_json(path):
    require(path.is_file() and path.stat().st_size <= 16384, "receipt_not_regular_or_too_large")
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

def device_guard(args):
    require(adb(args, "get-state").stdout.strip() == "device", "target_not_online")
    names = [line.strip() for line in adb(args, "emu", "avd", "name").stdout.splitlines()
             if line.strip() and line.strip() != "OK"]
    require(names == [args.avd], "device_avd_mismatch")
    for key, expected in (("ro.kernel.qemu", "1"), ("ro.build.version.sdk", "36"),
                          ("ro.product.cpu.abi", "x86_64"), ("sys.boot_completed", "1")):
        require(adb(args, "shell", "getprop", key).stdout.strip() == expected,
                "device_platform_mismatch:" + key)
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
    match = re.search(r"^package: name='([^']+)'", badging, re.MULTILINE)
    require(match and match[1] == expected_package, "apk_package_mismatch")
    certs = command([Path(os.environ["JAVA_HOME"]) / "bin/java", "-jar",
                     tools / "lib/apksigner.jar", "verify", "--print-certs", apk]).stdout
    cert = re.search(r"^Signer #1 certificate SHA-256 digest: ([a-f0-9]{64})$", certs, re.MULTILINE)
    require(cert is not None, "apk_certificate_unverified")
    with apk.open("rb") as source:
        digest = hashlib.file_digest(source, "sha256").hexdigest()
    return {"package": expected_package, "apk_sha256": digest, "certificate_sha256": cert[1]}

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
        require(re.fullmatch(r"/data/app/[A-Za-z0-9_~+/.=-]+/base[.]apk", path),
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
             "source_commit": revision, "api": receipt["api"], "abi": receipt["abi"],
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

def self_test():
    # Execute the real pre-install guards against a private fake transport.
    with tempfile.TemporaryDirectory(prefix="alkion-android-guard-test-") as name:
        root = Path(name)
        sdk = root / "sdk"
        (sdk / "platform-tools").mkdir(parents=True)
        fake = sdk / "platform-tools/adb"
        fake.write_text("""#!/usr/bin/env python3
import os,sys
from pathlib import Path
args=sys.argv[1:]
with open(os.environ["FAKE_LOG"],"a") as f: f.write(repr(args)+chr(10))
assert args[:2]==["-s","emulator-5558"],args
cmd=args[2:]
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
else: raise SystemExit("unexpected transport mutation: "+repr(cmd))
""")
        fake.chmod(0o755)
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
        env = dict(os.environ, ANDROID_HOME=str(sdk), ANDROID_USER_HOME=str(user), FAKE_LOG=str(root / "adb.log"))
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
        print("PASS:",count,"real guard cases + 3 raw-report preservation + 3 eleven-case contract cases; fake transport only; zero install/start/clear/uninstall.")

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--action", choices=("check","driver","build-neighbor","self-test"), default="check")
parser.add_argument("--avd")
parser.add_argument("--serial")
parser.add_argument("--receipt")
parser.add_argument("--output")
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
        device_guard(args)
        if args.action == "check":
            print("Fresh named synthetic target verified; no install or launch performed.")
        else:
            run_driver(args,receipt,output)
except (Refusal, ValueError, KeyError, OSError, subprocess.TimeoutExpired) as error:
    print("REFUSED:",error,file=sys.stderr)
    raise SystemExit(2)
PY

