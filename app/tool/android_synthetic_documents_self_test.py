"""Host-only controls; no FVM, Android tools, Git, build or device is executed.

The existing harness definitions are loaded without its entry point. Its actual
receipt, platform, installed-byte, UID, A2 and source command paths run against
the fake command transport below. Owned-file programs execute in private /tmp
directories, including exclusive writes and namespace publication.
"""

import copy
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET
import zipfile

sys.dont_write_bytecode = True
import android_synthetic_documents as documents


RUN = "1" * 32
REVISION = "a" * 40
CERT = "b" * 64
RAW = bytes(range(256)) * 1025
SOURCE_NAME = "alkion-backup-12345678-20261018T121314Z-abcdef.alkionbackup"


def result(stdout="", stderr="", code=0):
    return SimpleNamespace(returncode=code, stdout=stdout, stderr=stderr)


def load_harness():
    script = Path(__file__).with_name("android_synthetic.sh")
    body = script.read_text().split("<<'PY'\n", 1)[1].rsplit("\nPY", 1)[0]
    body = body[:body.index("\nparser = argparse.ArgumentParser")]
    namespace = {"__name__": "documents_host_control"}
    with patch.object(sys, "argv", [str(script), str(script)]):
        exec(compile(body, str(script), "exec"), namespace)
    return namespace


class Clock:
    def __init__(self):
        self.now = 0

    def monotonic(self):
        return self.now

    def sleep(self, seconds):
        self.now += max(seconds, 1)


class FakeHost:
    def __init__(self, root):
        self.root = root
        self.APP = root / "checkout/app"
        self.APP.mkdir(parents=True)
        fixture = self.APP / "tool/android_synthetic_documents"
        fixture.mkdir(parents=True)
        original = Path(__file__).parent / "android_synthetic_documents"
        for name in ("AndroidManifest.xml", "SyntheticDocumentsProvider.java"):
            shutil.copyfile(original / name, fixture / name)
        self.sdk = root / "sdk"
        (self.sdk / "platform-tools").mkdir(parents=True)
        (self.sdk / "platform-tools/adb").touch()
        (self.sdk / "platforms/android-36").mkdir(parents=True)
        (self.sdk / "platforms/android-36/android.jar").touch()
        self.user = root / "user"
        self.user.mkdir()
        (self.user / "debug.keystore").write_bytes(b"synthetic test placeholder, not a key")
        avds = root / "avds"
        avd = avds / "documents-proof.avd"
        avd.mkdir(parents=True)
        (avds / "documents-proof.ini").write_text("path=" + str(avd) + "\n")
        (avd / "config.ini").write_text("abi.type=x86_64\ntag.id=default\nimage.sysdir.1=system-images/android-36/default/x86_64/\n")
        self.receipt = {"format": "alkion-android-disposable/1", "purpose": "synthetic-only", "fresh": True,
            "serial": "emulator-5560", "avd": "documents-proof", "run_id": RUN, "api": 36,
            "abi": "x86_64", "system_image": "system-images;android-36;default;x86_64",
            "avd_home": str(avds), "android_user_home": str(self.user)}
        receipt_path = root / "disposable.json"
        self.write(receipt_path, self.receipt)
        self.installed = {}
        self.facts = {}
        self.metadata = {}
        self.pids = {}
        self.calls = []
        self.mutations = []
        self.current = None
        self.front = documents.PACKAGES[1]
        self.drawer = False
        self.selected = False
        self.scenario = "valid"
        self.ack_objects = []
        self.delayed_ack_checks = []
        self.driver, self.updates, self.lifecycle = self.make_receipts()
        self.args = SimpleNamespace(sdk=self.sdk, serial="emulator-5560", avd="documents-proof",
            receipt=str(receipt_path), output=str(root / "output"), driver_run=str(root / "driver/run.json"),
            updates_run=str(root / "updates/run.json"), base_run=str(root / "lifecycle/run.json"))
        self.save_receipts()
        namespace = load_harness()
        namespace.update(APP=self.APP, command=self.command)
        # Functions retain the same globals as the reviewed harness functions.
        for name, value in namespace.items():
            if callable(value) and name not in ("command",):
                setattr(self, name, value)
        self.namespace = namespace
        self.apk_facts = self.fake_apk_facts
        self.namespace["apk_facts"] = self.fake_apk_facts

    @staticmethod
    def write(path, value):
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        path.write_bytes(documents.encoded(value) if not isinstance(value, bytes) else value)
        path.chmod(0o600)

    def package_root(self, package):
        directory = self.root / "packages" / package
        directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        return directory

    def artifact(self, path, package, version):
        self.write(path, {"package": package, "version": version})
        facts = {"package": package, "version_code": version,
                 "certificate_sha256": CERT, "apk_sha256": documents.digest(path.read_bytes())}
        self.facts[str(path)] = facts
        return facts

    def fake_apk_facts(self, args, path, package):
        facts = copy.deepcopy(self.facts_for_file(Path(path)))
        documents.require(facts["package"] == package, "apk_package_mismatch")
        facts["apk_sha256"] = documents.digest(Path(path).read_bytes())
        return facts

    def make_receipts(self):
        driver = {"format": "alkion-android-run/1", "phase": "driver", "driver_phase": "PASS",
            "overall": "IN_PROGRESS", "pending": {}, "source_commit": REVISION, "driver_contract": "alkion-driver/2",
            **{key: self.receipt[key] for key in ("run_id", "serial", "avd", "api", "abi")}, "installed": {}, "driver": {}}
        updates = {"format": "alkion-android-run/1", "phase": "updates", "updates_phase": "PASS",
            "overall": "IN_PROGRESS", "pending": {}, "source_commit": REVISION, "base_source_commit": REVISION,
            "base_driver_contract": "alkion-driver/2", **{key: self.receipt[key] for key in ("run_id", "serial", "avd")},
            "installed": {}, "updates": {}}
        lifecycle = {"format": "alkion-android-run/1", "phase": "lifecycle-initial", "initial_lifecycle_phase": "PASS",
            "overall": "IN_PROGRESS", "pending": {"documents_provider_restore": "UNRUN"},
            "source_commit": REVISION, "base_source_commit": REVISION,
            **{key: self.receipt[key] for key in ("run_id", "serial", "avd")}, "installed": {}, "lifecycle": {}}
        for index, package in enumerate(documents.PACKAGES):
            flavor = "neighbor" if index == 0 else "dev" if index == 1 else "supported"
            path = self.root / "driver" / ("neighbor-build/synthetic-neighbor.apk" if not index else "driver-" + flavor + ".apk")
            driver["installed"][package] = self.artifact(path, package, 1 if not index else 37)
            self.metadata[package] = {"uid": 10000 + index, "version_code": 1 if not index else 44}
            self.installed[package] = driver["installed"][package]
            if index:
                driver["driver"][flavor] = {"format": "alkion-android-driver-proof/1", "run_id": RUN,
                    "application_id": package, "complete": True, "result": "PASS",
                    "cases": {name: "PASS" for name in load_harness()["CASES"]}}
                normal = self.package_root(package) / ("files/" + package)
                normal.mkdir(parents=True, mode=0o700)
                profile = "12345678-1234-4234-8234-123456789abc"
                relative = "profiles/" + profile + "/alkion.sqlite"
                for name in (relative, "local-profile.json", "original-source.bin"):
                    self.write(normal / name, b"exact synthetic existing bytes\x00\xff")
                report = {"format": "alkion-android-update-proof/1", "run_id": RUN, "application_id": package,
                    "complete": True, "closed": True, "result": "PASS", "state_digest": "c" * 64,
                    "installation_id": "installation-" + flavor, "profile_id": profile, "generation": 1,
                    "database_relative": relative}
                verified = self.artifact(self.root / "updates" / (flavor + "-verify.apk"), package, 39)
                meta = {"version_code": 39, "uid": 10000 + index}
                updates["installed"][package] = verified
                updates["updates"][package] = {"seed": dict(report, phase="seed"), "verify": dict(report, phase="verify"),
                    "seed_metadata": dict(meta, version_code=38), "verify_metadata": meta, "verify_apk": verified,
                    "driver_and_neighbor_bytes_unchanged": True,
                    "wrong_signer": {"exit_code": 1, "stderr": "INSTALL_FAILED_UPDATE_INCOMPATIBLE",
                        "metadata_before": meta, "metadata_after": meta, "covered_bytes_before": "d" * 64, "covered_bytes_after": "d" * 64,
                        "candidate": dict(verified, version_code=40, certificate_sha256="e" * 64)}}
                finished = self.artifact(self.root / "lifecycle" / (flavor + "-finish.apk"), package, 44)
                lifecycle["installed"][package] = finished
                checkpoints = {phase: dict(report, format="alkion-android-lifecycle-checkpoint/1", phase=phase, draft=None)
                               for phase in ("prepare", "rest", "finish")}
                lifecycle["lifecycle"][package] = dict(checkpoints, initial_lifecycle="PASS", peer_covered_bytes={
                    peer: {"before": "f" * 64, "after": "f" * 64} for peer in documents.VARIANTS.values() if peer != package})
                self.installed[package] = finished
                self.write(self.package_root(package) / ("files/android-proof/" + RUN + "/driver-report.json"), driver["driver"][flavor])
            else:
                updates["installed"][package] = driver["installed"][package]
                lifecycle["installed"][package] = driver["installed"][package]
                self.write(self.package_root(package) / "files/synthetic-neighbor.json",
                    {"format": "alkion-synthetic-neighbor/1", "run_id": RUN, "sentinel": "synthetic-only-keep-exact"})
        return driver, updates, lifecycle

    def save_receipts(self):
        for name in ("driver", "updates", "lifecycle"):
            self.write(self.root / name / "run.json", getattr(self, name))

    def command(self, argv, *, binary=False, input=None, check=True, timeout=30, env=None):
        argv = list(map(str, argv))
        self.calls.append(argv)
        if argv[0] == "git":
            return result(REVISION + "\n" if argv[-1] == "HEAD" else "")
        if argv[0] == "make":
            if "alkion-verify-backup" in argv:
                options = dict(value.split("=", 1) for value in argv if value.startswith("ALKION_"))
                if self.scenario == "receiving-failure":
                    self.write(Path(options["ALKION_OUTPUT"]) / "failure.json", {"result": "failed"})
                    return result(stderr="synthetic verifier refusal", code=1)
                data = Path(options["ALKION_BACKUP"]).read_bytes()
                report = {"format": "alkion-receiving-verification/1", "result": "verified", "schema": 1,
                    "container": {"sha256": documents.digest(data), "length": len(data), "format": "alkion-backup/1", "version": 1},
                    "inventory": {"sha256": "c" * 64, "rows": 1, "tables": {}}, "inventory_result": "all_covered_rows_match",
                    "storage_claim": "receiving_file_verified; physically_off_device_location_requires_owner_evidence"}
                if self.scenario == "receiving-digest":
                    report["container"]["sha256"] = "0" * 64
                self.write(Path(options["ALKION_OUTPUT"]) / "verification.json", report)
                return result(json.dumps(report))
            options = dict(value.split("=", 1) for value in argv if value.startswith("ALKION_"))
            flavor = options["ALKION_FLAVOR"]
            path = self.APP / ("build/app/outputs/flutter-apk/app-" + flavor + "-debug.apk")
            self.artifact(path, documents.VARIANTS[flavor], int(options["ALKION_PROOF_VERSION"]))
            return result("fake Make only\n")
        if argv[0].endswith("/javac"):
            directory = Path(argv[argv.index("-d") + 1])
            (directory / "Fixture.class").write_bytes(b"not bytecode")
            return result()
        if argv[0].endswith("/d8"):
            (Path(argv[argv.index("--output") + 1]) / "classes.dex").write_bytes(b"not dex")
            return result()
        if argv[0].endswith("/aapt2"):
            if argv[1] == "link":
                with zipfile.ZipFile(argv[argv.index("-o") + 1], "w"):
                    pass
                return result()
            return result(documents.PROVIDER + " " + documents.AUTHORITY +
                          ' android.permission.MANAGE_DOCUMENTS\n A: android:enabled(0x0101000e)=(type 0x12)0x0\n')
        if argv[0].endswith("/zipalign"):
            shutil.copyfile(argv[-2], argv[-1]); return result()
        if argv[0].endswith("/java"):
            target = Path(argv[argv.index("--out") + 1])
            shutil.copyfile(argv[-1], target)
            self.facts[str(target)] = {"package": documents.PROVIDER, "version_code": 1,
                "certificate_sha256": CERT, "apk_sha256": documents.digest(target.read_bytes())}
            return result()
        if argv[0].endswith("/adb"):
            assert argv[1:3] == ["-s", "emulator-5560"], argv
            tail = argv[3:]
            if tail[0] == "shell":
                value = self.android(shlex.split(tail[1]), binary)
            elif tail[0] == "exec-out":
                value = self.android(shlex.split(tail[1]) if len(tail) == 2 else tail[1:], binary, input)
            elif tail[0] == "install":
                facts = self.fake_apk_facts(None, Path(tail[-1]), self.facts_for_file(Path(tail[-1]))["package"])
                self.installed[facts["package"]] = facts
                self.metadata.setdefault(facts["package"], {"uid": 10003})["version_code"] = facts["version_code"]
                self.mutations.append(("install", facts["package"])); value = result("Success\n")
            elif tail == ["get-state"]:
                value = result("device\n")
            elif tail == ["emu", "avd", "name"]:
                value = result("documents-proof\nOK\n")
            else:
                raise AssertionError(tail)
            if check and value.returncode:
                raise documents.Refusal("fake_transport_failed:" + repr(tail))
            return value
        raise AssertionError("Unexpected command: " + repr(argv))

    def facts_for_file(self, path):
        if str(path) not in self.facts:
            value = json.loads(path.read_bytes())
            self.facts[str(path)] = {"package": value["package"], "version_code": value["version"],
                "certificate_sha256": CERT, "apk_sha256": documents.digest(path.read_bytes())}
        return self.facts[str(path)]

    def android(self, argv, binary=False, data=None):
        if argv[:1] == ["getprop"]:
            return result({"ro.kernel.qemu": "1", "ro.build.version.sdk": "36", "ro.product.cpu.abi": "x86_64", "sys.boot_completed": "1"}[argv[1]] + "\n")
        if argv[:2] == ["pm", "path"]:
            return result("package:/data/app/fake/" + argv[2] + "/base.apk\n" if argv[2] in self.installed else "")
        if argv[:2] == ["pm", "list"]:
            package = argv[-1]
            if "-s" in argv:
                assert package in ("com.android.settings", "com.android.launcher3")
                return result("package:" + package + " uid:" + str(1000 if package == "com.android.settings" else 10120) + "\n")
            return result("package:" + package + " uid:" + str(self.metadata[package]["uid"]) + "\n")
        if argv[:2] == ["dumpsys", "package"]:
            return result("versionCode=" + str(self.metadata[argv[2]]["version_code"]) + "\n")
        if argv[:3] == ["dumpsys", "activity", "processes"]:
            package = argv[3]; uid = self.metadata[package]["uid"]; pid = self.pids[package]
            assert self.front == "com.android.launcher3"
            return result("  *APP* UID " + str(uid) + " ProcessRecord{123 " + str(pid) + ":" + package + "/u0a" + str(uid - 10000) + "}\n"
                "    user #0 uid=" + str(uid) + " gids={50000}\n    pid=" + str(pid) + "\n"
                "    oom adj: max=1001 curRaw=900 setRaw=900 cur=900 set=900\n"
                "    curProcState=15 mRepProcState=15 setProcState=15 lastStateTime=-1s\n"
                "    cached=true empty=false\n")
        if argv[:2] == ["dumpsys", "activity"]:
            component = {"com.android.settings": "/.Settings", "com.android.launcher3": "/.Launcher"}.get(self.front, "/.picker.PickActivity")
            return result("mResumedActivity: ActivityRecord{123 u0 " + self.front + component + " t1}\n")
        if argv[:1] == ["sha256sum"]:
            package = argv[1].split("/")[-2]
            return result(self.installed[package]["apk_sha256"] + "  " + argv[1] + "\n")
        if argv[:1] == ["pidof"]:
            return result(str(self.pids[argv[1]]) + "\n" if self.pids.get(argv[1]) else "", code=0 if self.pids.get(argv[1]) else 1)
        if argv[:2] == ["sh", "-c"]:
            assert argv[2] == self.namespace["PROCESS_IDENTITY_SCRIPT"]
            pid = int(argv[-1])
            owners = [package for package, observed in self.pids.items() if observed == pid]
            if not owners:
                return result("absent\n")
            assert len(owners) == 1
            uid = self.metadata[owners[0]]["uid"]
            fields = ["0"] * 49; fields[18] = "100"
            return result("Name: alkion\nPid: " + str(pid) + "\nUid: " + " ".join([str(uid)] * 4) +
                          "\n\nalkion-proc-stat\n" + str(pid) + " (alkion (dev)) S " + " ".join(fields) + "\n")
        if argv[:3] == ["cmd", "package", "resolve-activity"]:
            return result("com.android.settings/.Settings\n" if "android.settings.SETTINGS" in argv else "com.android.launcher3/.Launcher\n")
        if argv[:3] == ["cmd", "package", "unstop"]:
            assert argv == ["cmd", "package", "unstop", "--user", "0", documents.PROVIDER]
            assert list((self.package_root(documents.PROVIDER) / "files/proof-runs").glob("*-dev/control.json"))
            self.mutations.append(("unstop", argv[-1])); return result()
        if argv[:2] == ["pm", "enable"]:
            assert argv[-1] == documents.COMPONENT
            self.pids[documents.PROVIDER] = 501
            self.mutations.append(("enable", argv[-1])); return result()
        if argv[:2] == ["am", "start"]:
            package = argv[-1].split("/")[0]
            if package == "com.android.settings":
                self.front = package
                return result("Status: ok\n")
            self.pids[package] = 601
            self.start_adapter(package)
            self.mutations.append(("start", package)); return result()
        if argv[:2] == ["am", "kill"]:
            self.pids[argv[-1]] = None
            self.mutations.append(("kill", argv[-1])); return result()
        if argv == ["am", "get-current-user"]:
            return result("0\n")
        if argv[:2] == ["input", "keyevent"]:
            if argv[-1] == "KEYCODE_BACK":
                self.complete_picker()
            elif argv[-1] == "KEYCODE_HOME":
                self.front = "com.android.launcher3"
            return result()
        if argv[:2] == ["input", "tap"]:
            y = int(argv[-1]); self.mutations.append(("tap", y))
            if y < 100:
                self.selected = True; self.drawer = False
            elif y >= 300:
                self.drawer = True
            else:
                self.complete_picker()
            return result()
        if argv[:1] == ["uiautomator"]:
            return result('<?xml version="1.0" encoding="UTF-8"?>' + self.ui_xml())
        if argv[:1] == ["screencap"]:
            return result(b"\x89PNG\r\n\x1a\nsynthetic host image" if binary else "")
        if argv[:1] == ["run-as"]:
            package = argv[1]; directory = self.package_root(package)
            rest = argv[2:]
            if rest[:2] == ["/system/bin/sh", "-c"]:
                if data is not None and "ack-" in rest[-1] and ".json.partial-" in rest[-1] and self.scenario == "delayed-ack":
                    process = subprocess.Popen(["/bin/sh", *rest[1:]], cwd=directory,
                                               stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                    split = len(data) // 2
                    process.stdin.write(data[:split]); process.stdin.flush()
                    partial = directory / rest[-1]
                    final = Path(str(partial).rsplit(".partial-", 1)[0])
                    deadline = time.monotonic() + 2
                    while (not partial.exists() or partial.stat().st_size < split) and time.monotonic() < deadline:
                        time.sleep(0.001)
                    assert partial.read_bytes() == data[:split]
                    assert not final.exists(), "Final ack visible while payload is incomplete"
                    time.sleep(0.02)  # Give the exists/read/parse consumer several polls.
                    assert not final.exists(), "Final ack appeared before the writer closed"
                    self.delayed_ack_checks.append((str(partial), bytes(data)))
                    stdout, stderr = process.communicate(data[split:], timeout=2)
                    completed = subprocess.CompletedProcess(rest, process.returncode, stdout, stderr)
                    assert partial.read_bytes() == data and not final.exists()
                else:
                    completed = subprocess.run(["/bin/sh", *rest[1:]], cwd=directory, input=data, capture_output=True)
                if completed.returncode == 0 and data is not None and "ack-" in rest[-1] and self.scenario == "changed-ack-partial":
                    partial = directory / rest[-1]
                    partial.write_bytes(data[:-1] + b"x")
            else:
                completed = subprocess.run(rest, cwd=directory, capture_output=True)
            if completed.returncode == 0 and rest[:2] == ["/system/bin/sh", "-c"] and 'ln -T "$1" "$2"' in rest[2] and "ack-" in rest[-1]:
                self.consume_ack(json.loads((directory / rest[-1]).read_bytes()))
            return result(completed.stdout if binary else completed.stdout.decode(),
                          completed.stderr if binary else completed.stderr.decode(), completed.returncode)
        raise AssertionError("Unexpected Android command: " + repr(argv))

    def phase(self, state, sequence, case, **detail):
        value = {"format": "alkion-android-documents-phase/1", "run_id": RUN, "source_commit": REVISION,
            "application_id": self.current, "variant": self.flavor, "provider_package": documents.PROVIDER,
            "provider_authority": documents.AUTHORITY, "sequence": sequence, "case": case, "state": state, **detail}
        self.current_phase = value
        self.write(self.package_root(self.current) / ("files/android-documents-proof/" + RUN + "/phase.json"), value)
        return value

    def start_adapter(self, package):
        self.current = self.front = package
        self.flavor = next(flavor for flavor, candidate in documents.VARIANTS.items() if candidate == package)
        self.control = {"format": "alkion-synthetic-documents/1", "run_id": RUN, "variant": self.flavor,
                        "length": len(RAW), "sha256": documents.digest(RAW)}
        self.observed = {}
        relative = "android-documents-proof/" + RUN + "/backups/" + SOURCE_NAME
        self.write(self.package_root(package) / ("files/" + relative), RAW)
        namespace = RUN + "-" + self.flavor
        self.phase("seed_provider", 0, "seed", source_relative=relative, length=len(RAW), sha256=documents.digest(RAW),
            provider_control_relative="files/proof-runs/" + namespace + "/control.json",
            provider_input_relative="files/proof-runs/" + namespace + "/input.alkionbackup", provider_control=self.control)

    def next_case(self, sequence):
        case = list(documents.CASES)[sequence - 1]
        namespace = RUN + "-" + self.flavor
        self.selected = False; self.drawer = False
        self.phase("awaiting_arm", sequence, case,
            intent="ACTION_OPEN_DOCUMENT" if case.startswith("open-") else "ACTION_CREATE_DOCUMENT",
            root_label="Alkion synthetic " + namespace, document_label=namespace + "-" + case + ".alkionbackup",
            picker_action="cancel" if case.endswith("-cancel") else "select", mime_type="application/octet-stream",
            provider_receipt_relative="files/proof-runs/" + namespace + "/receipts/" + case + ".json")

    def consume_ack(self, value):
        self.ack_objects.append(value)
        if value["action"] == "seeded":
            self.next_case(1)
        elif value["action"] == "armed":
            phase = dict(self.current_phase)
            phase.pop("state"); phase.pop("sequence"); phase.pop("case")
            self.phase("picker", value["sequence"], value["case"], **{key: item for key, item in phase.items() if key not in
                ("format", "run_id", "source_commit", "application_id", "variant", "provider_package", "provider_authority")})
            self.front = "com.android.documentsui"
        else:
            if value["provider_receipt"] is not None:
                self.observed[value["case"]] = value["provider_receipt"]
            if value["sequence"] == len(documents.CASES):
                report = terminal(self.flavor, self.observed)
                if self.scenario == "flat-terminal":
                    report["cases"]["open-good"] = "PASS"
                self.write(self.package_root(self.current) / ("files/android-documents-proof/" + RUN + "/documents-report.json"), report)
            else:
                self.next_case(value["sequence"] + 1)

    def ui_xml(self):
        if self.front != "com.android.documentsui":
            return '<hierarchy><node package="' + self.front + '"/></hierarchy>'
        namespace = RUN + "-" + self.flavor
        prefix = self.package_root(documents.PROVIDER) / ("files/proof-runs/" + namespace)
        pin = (RUN + "\n" + self.flavor + "\n" + str(len(RAW)) + "\n" + documents.digest(RAW)).encode()
        if not (prefix / "input.pin").exists():
            self.write(prefix / "input.pin", pin)
        root = ET.Element("hierarchy")
        label = "Alkion synthetic " + namespace
        if self.scenario == "wrong-root":
            label = "Alkion synthetic " + "2" * 32 + "-" + self.flavor
        def node(text, y, clickable=True, cls="android.widget.TextView", desc=""):
            ET.SubElement(root, "node", {"package": "com.android.documentsui", "text": text, "content-desc": desc,
                "class": cls, "clickable": str(clickable).lower(), "bounds": "[0," + str(y) + "][100," + str(y + 100) + "]"})
        node(label, 0, self.drawer)
        if self.scenario == "duplicate-root" and self.drawer:
            node(label, 0)
        node("", 300, desc="Show roots")
        if self.selected:
            name = self.current_phase["document_label"]
            if self.scenario == "wrong-file":
                name = "foreign.alkionbackup"
            node(name, 100, not self.current_phase["case"].startswith("save-"),
                 "android.widget.EditText" if self.current_phase["case"].startswith("save-") else "android.widget.TextView")
            if self.current_phase["case"].startswith("save-"):
                node("SAVE", 200)
        return ET.tostring(root, encoding="unicode")

    def complete_picker(self):
        case, sequence = self.current_phase["case"], self.current_phase["sequence"]
        if not case.endswith("-cancel"):
            receipt = provider_receipt(case, self.control)
            prefix = self.package_root(documents.PROVIDER) / ("files/proof-runs/" + RUN + "-" + self.flavor)
            if case.startswith("save-"):
                data = b"" if case == "save-write-denied" else b"\x00" if case == "save-write-interrupted" else RAW
                self.write(prefix / ("outputs/" + case + "-12345678-1234-4234-8234-123456789abc.partial"), data)
            self.write(prefix / ("receipts/" + case + ".json"), receipt)
        self.front = self.current
        self.phase("awaiting_observed", sequence, case, production_outcome=documents.CASES[case])


def provider_receipt(case, control):
    events = []
    def event(operation, state, length=0, sha=None):
        events.append({"operation": operation, "state": state, "length": length, "sha256": sha,
                       "error": None, "reliable_pipe": operation in ("read", "write") and state != "denied"})
    if case.startswith("save-"):
        event("create", "created", sha=documents.digest(b""))
        if case == "save-write-denied": event("write", "denied")
        elif case == "save-write-interrupted": event("write", "interrupted", 1)
        else:
            event("write", "complete", control["length"], control["sha256"])
            if case == "save-readback-denied": event("read", "denied")
            else: event("read", "complete", control["length"], "0" * 64 if case == "save-readback-changed" else control["sha256"])
    elif case == "open-denied": event("read", "denied")
    elif case == "open-error": event("read", "interrupted", 4096)
    elif case == "open-short": event("read", "complete", control["length"] - 1, "0" * 64)
    else: event("read", "complete", control["length"], "0" * 64 if case == "open-corrupt" else control["sha256"])
    value = {"format": "alkion-synthetic-document-receipt/1", "run_id": RUN, "variant": control["variant"],
             "case": case, "input_sha256": control["sha256"], "input_length": control["length"], "events": events}
    if case.startswith("save-"):
        value.update(output_retained=True, output_length=0 if case == "save-write-denied" else 1 if case == "save-write-interrupted" else len(RAW))
    return value


def terminal(flavor, observed):
    return {"format": "alkion-android-documents-proof/1", "phase": "documents-provider", "run_id": RUN,
        "source_commit": REVISION, "application_id": documents.VARIANTS[flavor], "variant": flavor,
        "provider_package": documents.PROVIDER, "provider_authority": documents.AUTHORITY, "complete": True, "result": "PASS",
        "cases": {name: {"result": "PASS", "outcome": outcome, "originals_preserved": True,
                         "selected_generation_unchanged": True} for name, outcome in documents.CASES.items()},
        "provider_receipts": observed, "unrun": list(documents.UNRUN)}


class DocumentsControls(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="alkion-documents-host-")
        self.root = Path(self.temp.name)
        self.host = FakeHost(self.root)
        self.environment = patch.dict(os.environ, JAVA_HOME="/usr/lib/jvm/java-21-openjdk", ANDROID_USER_HOME=str(self.host.user))
        self.environment.start()
        self.clock = patch.object(documents, "time", Clock())
        self.clock.start()

    def tearDown(self):
        self.clock.stop(); self.environment.stop(); self.temp.cleanup()

    def prepared(self):
        return documents.prepare(self.host, self.host.args)

    def test_complete_actual_module_with_fake_transport_both_variants(self):
        self.host.args.action = "documents"
        self.host.pids[documents.PACKAGES[1]] = 600  # Exercise the pre-install kill call too.
        state = self.host.documents_action(self.host.args)
        self.assertEqual(state["documents_phase"], "PASS")
        self.assertEqual(state["overall"], "IN_PROGRESS")
        self.assertEqual(set(state["documents"]), {"dev", "supported"})
        self.assertEqual([value["version_code"] for package, value in state["installed"].items() if package in documents.VARIANTS.values()], [45, 45])
        self.assertEqual(len(self.host.ack_objects), 54)
        self.assertEqual([item[0] for item in self.host.mutations].count("enable"), 1)
        self.assertEqual([item[0] for item in self.host.mutations].count("unstop"), 1)
        self.assertEqual((self.root / "output/dev-received.alkionbackup").read_bytes(), RAW)
        self.assertIn("fresh_receiver_restore", state["unrun"])
        for flavor in documents.VARIANTS:
            self.assertTrue((self.host.package_root(documents.PROVIDER) / ("files/proof-runs/" + RUN + "-" + flavor + "/input.pin")).is_file())
        kills = [json.loads(path.read_bytes()) for path in (self.root / "output").glob("*-ordinary-kill-*.json")]
        self.assertEqual(len(kills), 3)
        self.assertEqual({item["uid"] for item in kills}, {10001, 10002})
        self.assertTrue(all(item["result"] == "PASS" and item["exact_pid_absent"] for item in kills))

    def test_real_guard_refusals_never_reach_mutation(self):
        changes = (("driver", "driver_phase", "FAIL"), ("updates", "updates_phase", "FAIL"),
                   ("lifecycle", "initial_lifecycle_phase", "FAIL"), ("lifecycle", "serial", "emulator-5562"),
                   ("lifecycle", "base_source_commit", "0" * 40))
        for name, key, value in changes:
            with self.subTest(name=name, key=key):
                original = getattr(self.host, name)[key]
                getattr(self.host, name)[key] = value; self.host.save_receipts()
                with self.assertRaises((documents.Refusal, self.host.Refusal)):
                    self.prepared()
                self.assertFalse(self.host.mutations)
                getattr(self.host, name)[key] = original; self.host.save_receipts()

    def test_live_uid_and_saved_apk_change_are_refused(self):
        package = documents.PACKAGES[1]
        self.host.metadata[package]["uid"] += 20
        with self.assertRaisesRegex(documents.Refusal, "uid_changed"):
            self.prepared()
        self.host.metadata[package]["uid"] -= 20
        (self.root / "lifecycle/dev-finish.apk").write_bytes(b"changed")
        with self.assertRaisesRegex(documents.Refusal, "retained_campaign_apk_changed"):
            self.prepared()
        self.assertFalse(self.host.mutations)

    def test_build_arguments_reject_injection_and_missing_binding(self):
        base = {"ALKION_FLAVOR": "dev", "ALKION_PROOF_RUN": RUN, "ALKION_PROOF_SOURCE": REVISION, "ALKION_PROOF_VERSION": "82"}
        argv = documents.documents_build_arguments(base)
        self.assertEqual(argv[argv.index("--build-number") + 1], "82")
        for key, value in (("ALKION_FLAVOR", "foreign"), ("ALKION_PROOF_RUN", ""), ("ALKION_PROOF_SOURCE", "bad"),
                           ("ALKION_PROOF_VERSION", "0"), ("ALKION_PROOF_VERSION", "2100000000"),
                           ("ALKION_PROOF_VERSION", "45; touch /tmp/canary")):
            with self.assertRaises(documents.Refusal):
                documents.documents_build_arguments(dict(base, **{key: value}))

    def test_actual_producer_case_objects_and_receipts(self):
        control = {"run_id": RUN, "variant": "dev", "length": len(RAW), "sha256": documents.digest(RAW)}
        observed = {case: provider_receipt(case, control) for case in documents.CASES if not case.endswith("-cancel")}
        value = terminal("dev", observed)
        documents.validate_report(value, RUN, REVISION, "dev", control, observed)
        for change in (lambda v: v["cases"].__setitem__("open-good", "PASS"),
                       lambda v: v["cases"]["open-good"].__setitem__("originals_preserved", False),
                       lambda v: v["cases"]["open-good"].__setitem__("outcome", "cancelled"),
                       lambda v: v["provider_receipts"].pop("open-denied"),
                       lambda v: v.__setitem__("complete", False)):
            changed = copy.deepcopy(value); change(changed)
            with self.assertRaises(documents.Refusal):
                documents.validate_report(changed, RUN, REVISION, "dev", control, observed)
        for field, changed in (("input_sha256", "0" * 64), ("variant", "supported"), ("case", "open-good")):
            receipt = provider_receipt("save-good", control); receipt[field] = changed
            with self.assertRaisesRegex(documents.Refusal, "identity_mismatch"):
                documents.validate_receipt(receipt, "save-good", control)

    def test_picker_negative_preserves_raw_and_never_observes_case(self):
        self.host.scenario = "wrong-root"
        with self.assertRaisesRegex(documents.Refusal, "documentsui_checkpoint_unavailable"):
            documents.run(self.host, self.prepared())
        self.assertEqual([value["action"] for value in self.host.ack_objects], ["seeded", "armed"])
        self.assertTrue(list((self.root / "output").glob("*.xml.raw")))
        self.assertEqual(json.loads((self.root / "output/run.json").read_bytes())["documents_phase"], "FAIL")

    def test_receiving_failure_retains_every_provider_output(self):
        self.host.scenario = "receiving-failure"
        with self.assertRaisesRegex(documents.Refusal, "host_receiving_verifier_failed"):
            documents.run(self.host, self.prepared())
        outputs = self.host.package_root(documents.PROVIDER) / ("files/proof-runs/" + RUN + "-dev/outputs")
        self.assertEqual(len(list(outputs.iterdir())), 5)
        self.assertEqual((self.root / "output/dev-received.alkionbackup").read_bytes(), RAW)
        self.assertTrue((self.root / "output/dev-receiving-inspection/failure.json").is_file())
        self.assertFalse(any("clear" in str(call) or "uninstall" in str(call) for call in self.host.calls))

    def evidence_after_seed(self):
        prepared = self.prepared()
        prepared.output.mkdir(mode=0o700)
        evidence = documents.Evidence(self.host, prepared)
        self.host.start_adapter(documents.PACKAGES[1])
        phase = self.host.current_phase
        return evidence, phase

    def test_exclusive_ack_and_stale_phase_refusal(self):
        evidence, phase = self.evidence_after_seed()
        documents.ack(evidence, "dev", phase, "seeded", provider_input_sha256=documents.digest(RAW))
        directory = self.host.package_root(documents.PACKAGES[1]) / ("files/android-documents-proof/" + RUN)
        final = directory / "ack-000-seeded.json"
        original = final.read_bytes()
        prior_partials = list(directory.glob("ack-000-seeded.json.partial-*"))
        with self.assertRaisesRegex(documents.Refusal, "exclusive_write_failed"):
            documents.ack(evidence, "dev", phase, "seeded", provider_input_sha256=documents.digest(RAW))
        self.assertEqual(final.read_bytes(), original)
        self.assertEqual(len(self.host.ack_objects), 1)
        partials = list(directory.glob("ack-000-seeded.json.partial-*"))
        self.assertEqual(len(partials), len(prior_partials) + 1)
        self.assertTrue(all(path.read_bytes() == original for path in partials))
        with self.assertRaisesRegex(documents.Refusal, "phase_reordered"):
            documents.wait_phase(evidence, "dev", 2, "open-good", "awaiting_arm")
        phase["source_commit"] = "0" * 40
        with self.assertRaisesRegex(documents.Refusal, "identity_mismatch"):
            documents.validate_phase(phase, RUN, REVISION, "dev")
        before = len(self.host.ack_objects)
        with self.assertRaisesRegex(documents.Refusal, "identity_mismatch"):
            documents.ack(evidence, "dev", phase, "seeded")
        self.assertEqual(len(self.host.ack_objects), before)

    def test_delayed_ack_is_invisible_until_complete_publication(self):
        evidence, phase = self.evidence_after_seed()
        self.host.scenario = "delayed-ack"
        final = self.host.package_root(documents.PACKAGES[1]) / ("files/android-documents-proof/" + RUN + "/ack-000-seeded.json")
        stop = threading.Event()
        seen, errors, absent_polls = [], [], []
        def consumer():
            while not stop.is_set():
                if final.exists():
                    try:
                        seen.append(json.loads(final.read_bytes()))
                    except Exception as error:
                        errors.append(str(error))
                else:
                    absent_polls.append(True)
                time.sleep(0.001)
        reader = threading.Thread(target=consumer)
        reader.start()
        try:
            documents.ack(evidence, "dev", phase, "seeded", provider_input_sha256=documents.digest(RAW))
            deadline = time.monotonic() + 2
            while not seen and time.monotonic() < deadline:
                time.sleep(0.001)
        finally:
            stop.set(); reader.join(timeout=2)
        self.assertFalse(reader.is_alive())
        self.assertFalse(errors)
        self.assertTrue(seen)
        self.assertGreater(len(absent_polls), 2)
        self.assertEqual(len(self.host.delayed_ack_checks), 1)
        partial, expected = self.host.delayed_ack_checks[0]
        self.assertEqual(Path(partial).read_bytes(), expected)
        self.assertEqual(final.read_bytes(), expected)
        self.assertTrue(all(value == json.loads(expected) for value in seen))

    def test_changed_closed_ack_partial_retained_without_publication(self):
        evidence, phase = self.evidence_after_seed()
        self.host.scenario = "changed-ack-partial"
        with self.assertRaisesRegex(documents.Refusal, "closed_partial_changed"):
            documents.ack(evidence, "dev", phase, "seeded", provider_input_sha256=documents.digest(RAW))
        directory = self.host.package_root(documents.PACKAGES[1]) / ("files/android-documents-proof/" + RUN)
        self.assertFalse((directory / "ack-000-seeded.json").exists())
        partials = list(directory.glob("ack-000-seeded.json.partial-*"))
        self.assertEqual(len(partials), 1)
        self.assertTrue(partials[0].read_bytes().endswith(b"x"))
        self.assertFalse(self.host.ack_objects)

    def test_namespace_refuses_replacement_links_and_seventeenth(self):
        evidence, phase = self.evidence_after_seed()
        documents.seed_provider(evidence, "dev", phase, first=False)
        namespace = self.host.package_root(documents.PROVIDER) / ("files/proof-runs/" + RUN + "-dev")
        before = (namespace / "input.alkionbackup").read_bytes()
        with self.assertRaisesRegex(documents.Refusal, "namespace_not_fresh_owned"):
            documents.seed_provider(evidence, "dev", phase, first=False)
        self.assertEqual((namespace / "input.alkionbackup").read_bytes(), before)
        # A separate append-only run at the same immutable provider parent.
        stage = namespace.parent / (".stage-" + RUN + "-dev")
        self.assertFalse(stage.exists())
        namespace.rename(namespace.parent / ("2" * 32 + "-dev"))
        for number in range(3, 18):
            (namespace.parent / (format(number, "032x") + "-dev")).mkdir(mode=0o700)
        with self.assertRaisesRegex(documents.Refusal, "publication_refused"):
            documents.seed_provider(evidence, "dev", phase, first=False)
        self.assertTrue(stage.is_dir())
        self.assertTrue((stage / "input.alkionbackup").is_file())

    def test_linked_input_and_changed_pin_refuse_without_cleanup(self):
        evidence, phase = self.evidence_after_seed()
        source = self.host.package_root(documents.PACKAGES[1]) / ("files/" + phase["source_relative"])
        target = source.with_name("retained-original")
        source.rename(target); source.symlink_to(target)
        with self.assertRaisesRegex(documents.Refusal, "owned_read_failed"):
            documents.seed_provider(evidence, "dev", phase, first=False)
        self.assertTrue(source.is_symlink()); self.assertEqual(target.read_bytes(), RAW)

    def test_provider_restart_and_missing_output_are_not_repaired(self):
        evidence, phase = self.evidence_after_seed()
        evidence.provider_pid = 501
        self.host.pids[documents.PROVIDER] = 502
        with self.assertRaisesRegex(documents.Refusal, "provider_process_changed"):
            evidence.provider_alive()
        with self.assertRaisesRegex(documents.Refusal, "failed_outputs_missing"):
            documents.receive_good(evidence, "dev", {}, {"length": len(RAW), "sha256": documents.digest(RAW)})
        self.assertFalse(self.host.mutations)

    def test_dynamic_floor_uses_accepted_artifacts_and_rejects_exhaustion(self):
        package = documents.PACKAGES[1]
        facts = self.host.artifact(self.root / "lifecycle/dev-finish.apk", package, 81)
        self.host.lifecycle["installed"][package] = facts
        self.host.installed[package] = facts
        self.host.metadata[package]["version_code"] = 81
        self.host.save_receipts()
        prepared = self.prepared()
        self.assertEqual(prepared.installed[package]["version_code"] + 1, 82)
        self.host.lifecycle["installed"][package]["version_code"] = 2099999999
        self.host.save_receipts()
        with self.assertRaisesRegex(documents.Refusal, "artifact_binding_missing"):
            self.prepared()
        self.assertFalse(self.host.mutations)

    def test_changed_input_pin_cannot_ack_observed(self):
        evidence, phase = self.evidence_after_seed()
        control = documents.seed_provider(evidence, "dev", phase, first=False)
        root = self.host.package_root(documents.PROVIDER) / ("files/proof-runs/" + RUN + "-dev")
        self.host.write(root / "input.pin", b"interrupted or changed pin")
        self.host.pids[documents.PROVIDER] = 501
        before = len(self.host.ack_objects)
        with self.assertRaisesRegex(documents.Refusal, "namespace_input_changed"):
            documents.provider_observation(evidence, "dev", {"case": "open-good"}, control)
        self.assertEqual(len(self.host.ack_objects), before)
        self.assertEqual((root / "input.pin").read_bytes(), b"interrupted or changed pin")

    def test_changed_receiving_report_is_retained_and_refused(self):
        evidence, phase = self.evidence_after_seed()
        control = phase["provider_control"]
        outputs = {case: {"name": case, "length": len(RAW), "sha256": documents.digest(RAW), "bytes": RAW}
                   for case in documents.OUTPUT_CASES}
        self.host.scenario = "receiving-digest"
        with self.assertRaisesRegex(documents.Refusal, "host_receiving_report_mismatch"):
            documents.receive_good(evidence, "dev", outputs, control)
        self.assertEqual((self.root / "output/dev-received.alkionbackup").read_bytes(), RAW)
        self.assertTrue((self.root / "output/dev-receiving-inspection/verification.json").is_file())

    def test_incomplete_receipt_cannot_satisfy_failed_stream_case(self):
        control = {"run_id": RUN, "variant": "dev", "length": len(RAW), "sha256": documents.digest(RAW)}
        for case in ("open-error", "save-write-interrupted", "save-readback-changed"):
            receipt = provider_receipt(case, control)
            for event in receipt["events"]:
                if event["operation"] in ("read", "write"):
                    event["reliable_pipe"] = False
            with self.assertRaisesRegex(documents.Refusal, "trace_incomplete"):
                documents.validate_receipt(receipt, case, control)

    def test_case_names_match_the_real_dart_producer(self):
        text = (Path(__file__).parent.parent / "integration_test/android_documents_test.dart").read_text()
        body = text.split("const _caseNames = [", 1)[1].split("];", 1)[0]
        import re
        self.assertEqual(tuple(re.findall(r"'([^']+)'", body)), tuple(documents.CASES))
        self.assertIn("'cases': <String, Object?>{}", text)
        self.assertIn("'originals_preserved': true", text)
        self.assertIn("'selected_generation_unchanged': true", text)

    def test_output_files_must_match_actual_provider_receipts(self):
        control = {"run_id": RUN, "variant": "dev", "length": len(RAW), "sha256": documents.digest(RAW)}
        observed = {case: provider_receipt(case, control) for case in documents.OUTPUT_CASES}
        outputs = {case: {"length": observed[case]["output_length"], "sha256": control["sha256"]}
                   for case in documents.OUTPUT_CASES}
        documents.validate_outputs(outputs, control, observed)
        outputs["save-write-interrupted"]["length"] = 0
        with self.assertRaisesRegex(documents.Refusal, "output_receipt_length_mismatch"):
            documents.validate_outputs(outputs, control, observed)
        outputs["save-write-interrupted"]["length"] = 1
        outputs["save-readback-changed"]["sha256"] = "0" * 64
        with self.assertRaisesRegex(documents.Refusal, "completed_provider_output_changed"):
            documents.validate_outputs(outputs, control, observed)

    def test_integrated_check_is_read_only_and_requires_explicit_receipts(self):
        self.host.args.action = "documents-check"
        self.host.documents_action(self.host.args)
        self.assertFalse(self.host.mutations)
        self.assertFalse((self.root / "output").exists())
        for field in ("driver_run", "updates_run", "base_run"):
            original = getattr(self.host.args, field)
            setattr(self.host.args, field, "")
            with self.assertRaisesRegex(documents.Refusal, "explicit_documents_receipt_chain_required"):
                self.host.documents_action(self.host.args)
            setattr(self.host.args, field, original)
        self.assertFalse(self.host.mutations)

    def test_provider_build_dispatch_uses_existing_guards_and_fake_builders(self):
        self.host.args.action = "build-documents-provider"
        self.host.args.output = str(self.root / "provider-route")
        with patch.dict(os.environ, ALKION_PROOF_SOURCE=REVISION):
            self.host.documents_action(self.host.args)
        report = json.loads((self.root / "provider-route/build.json").read_bytes())
        self.assertEqual(report["package"], documents.PROVIDER)
        self.assertEqual(report["version_code"], 1)
        self.assertFalse(self.host.mutations)
        self.assertTrue(any(argv[0].endswith("/javac") for argv in self.host.calls))

    def test_make_documents_apk_route_uses_pinned_fvm_and_source_guards(self):
        tools = self.root / "fake-build-tools"
        tools.mkdir()
        log = self.root / "fake-fvm.json"
        (tools / "fvm").write_text('#!/usr/bin/env python3\nimport json,os,sys\nfrom pathlib import Path\nPath(os.environ["FAKE_FVM_LOG"]).write_text(json.dumps(sys.argv[1:]))\n')
        (tools / "git").write_text('#!/usr/bin/env python3\nimport os,sys\nassert sys.argv[1]=="-C"\nif sys.argv[3:]==["rev-parse","HEAD"]: print(os.environ["FAKE_SOURCE"])\nelif sys.argv[3:]==["status","--porcelain","--untracked-files=normal"]: print(os.environ.get("FAKE_DIRTY",""),end="")\nelse: raise SystemExit("unexpected fake git arguments")\n')
        for path in tools.iterdir():
            path.chmod(0o700)
        app = Path(__file__).parent.parent
        env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ["PATH"], ANDROID_HOME=str(self.host.sdk),
                   FAKE_SOURCE=REVISION, FAKE_FVM_LOG=str(log), PYTHONDONTWRITEBYTECODE="1")
        common = ["make", "-C", str(app), "android-synthetic-documents-apk", "ALKION_FLAVOR=dev",
                  "ALKION_PROOF_RUN=" + RUN, "ALKION_PROOF_SOURCE=" + REVISION, "ALKION_PROOF_VERSION=82"]
        completed = subprocess.run(common, env=env, capture_output=True, text=True, timeout=10)
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
        argv = json.loads(log.read_text())
        self.assertEqual(argv[:4], ["flutter", "build", "apk", "--debug"])
        self.assertIn("--no-pub", argv)
        self.assertEqual(argv[argv.index("--target") + 1], "integration_test/android_documents_test.dart")
        self.assertEqual(argv[argv.index("--target-platform") + 1], "android-x64")
        self.assertEqual(argv[argv.index("--build-number") + 1], "82")
        self.assertIn("--dart-define=ALKION_PROOF_SOURCE=" + REVISION, argv)
        before = log.read_bytes()
        invalid = ("ALKION_FLAVOR=foreign", "ALKION_PROOF_RUN=bad", "ALKION_PROOF_SOURCE=", "ALKION_PROOF_VERSION=0",
                   "ALKION_PROOF_VERSION=82; touch " + str(self.root / "canary"))
        for value in invalid:
            completed = subprocess.run(common + [value], env=env, capture_output=True, text=True, timeout=10)
            self.assertNotEqual(completed.returncode, 0)
            self.assertEqual(log.read_bytes(), before)
        for extra in ({"FAKE_SOURCE": "0" * 40}, {"FAKE_DIRTY": " M unreviewed-source"}):
            completed = subprocess.run(common, env=dict(env, **extra), capture_output=True, text=True, timeout=10)
            self.assertNotEqual(completed.returncode, 0)
            self.assertEqual(log.read_bytes(), before)
        self.assertFalse((self.root / "canary").exists())
        self.assertFalse((Path(__file__).parent / "__pycache__").exists())

    def test_make_forwards_explicit_document_receipts_and_provider_output(self):
        tools = self.root / "fake-route-tools"
        tools.mkdir()
        fake = tools / "bash"
        log = self.root / "make-route.json"
        fake.write_text('#!/usr/bin/env python3\nimport json,os,sys\nfrom pathlib import Path\nPath(os.environ["FAKE_ROUTE_LOG"]).write_text(json.dumps(sys.argv[1:]))\n')
        fake.chmod(0o700)
        env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ["PATH"], FAKE_ROUTE_LOG=str(log))
        app = Path(__file__).parent.parent
        values = {"ALKION_SYNTHETIC_ACTION": "documents-check", "ALKION_AVD": "documents-proof",
                  "ALKION_SERIAL": "emulator-5560", "ALKION_RECEIPT": str(self.root / "disposable.json"),
                  "ALKION_OUTPUT": str(self.root / "fresh output"), "ALKION_BASE_RUN": self.host.args.base_run,
                  "ALKION_DRIVER_RUN": self.host.args.driver_run, "ALKION_UPDATES_RUN": self.host.args.updates_run}
        completed = subprocess.run(["make", "-C", str(app), "android-synthetic", *(key + "=" + value for key, value in values.items())],
                                   env=env, capture_output=True, text=True, timeout=10)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        argv = json.loads(log.read_text())
        expected = {"--action": values["ALKION_SYNTHETIC_ACTION"], "--avd": values["ALKION_AVD"], "--serial": values["ALKION_SERIAL"],
                    "--receipt": values["ALKION_RECEIPT"], "--output": values["ALKION_OUTPUT"], "--base-run": values["ALKION_BASE_RUN"],
                    "--driver-run": values["ALKION_DRIVER_RUN"], "--updates-run": values["ALKION_UPDATES_RUN"]}
        self.assertEqual(dict(zip(argv[1::2], argv[2::2])), expected)
        completed = subprocess.run(["make", "-C", str(app), "android-synthetic-documents-provider", "ALKION_OUTPUT=" + values["ALKION_OUTPUT"]],
                                   env=env, capture_output=True, text=True, timeout=10)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(json.loads(log.read_text()), ["tool/android_synthetic.sh", "--action", "build-documents-provider", "--output", values["ALKION_OUTPUT"]])

    def test_documents_cli_actions_refuse_implicit_targets(self):
        script = Path(__file__).with_name("android_synthetic.sh")
        for action in ("documents-check", "documents"):
            completed = subprocess.run(["bash", str(script), "--action", action],
                                       capture_output=True, text=True, timeout=10)
            self.assertNotEqual(completed.returncode, 0)
            self.assertIn("explicit_emulator_serial_required", completed.stderr)
        self.assertFalse(self.host.mutations)

    def test_make_literal_transport_never_executes_quotes_backticks_or_dollars(self):
        tools = self.root / "literal-route-tools"
        tools.mkdir()
        log = self.root / "literal-route.json"
        fake = tools / "bash"
        fake.write_text('#!/usr/bin/env python3\nimport json,os,sys\nfrom pathlib import Path\nPath(os.environ["FAKE_ROUTE_LOG"]).write_text(json.dumps(sys.argv[1:]))\n')
        fake.chmod(0o700)
        canaries = {name: self.root / ("canary-" + name) for name in ("quote", "backtick", "dollar", "make", "single", "driver", "provider")}
        values = {
            "ALKION_SYNTHETIC_ACTION": 'documents-check"; touch ' + str(canaries["quote"]) + '; echo "',
            "ALKION_AVD": 'avd with spaces "double" and \'single\' \\ slash',
            "ALKION_SERIAL": 'emulator-`touch ' + str(canaries["backtick"]) + '`',
            "ALKION_RECEIPT": '/tmp/$(touch ' + str(canaries["dollar"]) + ')/receipt.json',
            "ALKION_OUTPUT": '/tmp/$(shell touch ' + str(canaries["make"]) + ')/output',
            "ALKION_BASE_RUN": "/tmp/lifecycle'; touch " + str(canaries["single"]) + "; echo '",
            "ALKION_DRIVER_RUN": '/tmp/driver"; touch ' + str(canaries["driver"]) + '; echo "',
            "ALKION_UPDATES_RUN": '/tmp/${ALKION_CANARY_VAR}/$(printf literal)/updates.json',
        }
        flags = ("--action", "--avd", "--serial", "--receipt", "--output", "--base-run", "--driver-run", "--updates-run")
        expected = ["tool/android_synthetic.sh", *(part for flag, value in zip(flags, values.values()) for part in (flag, value))]
        env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ["PATH"], FAKE_ROUTE_LOG=str(log), ALKION_CANARY_VAR="must-stay-literal")
        app = Path(__file__).parent.parent
        for origin in ("command-line", "environment"):
            with self.subTest(origin=origin):
                argv = ["make", "-C", str(app), "android-synthetic"]
                variables = dict(env)
                if origin == "command-line":
                    argv += [key + "=" + value for key, value in values.items()]
                else:
                    variables.update(values)
                completed = subprocess.run(argv, env=variables, capture_output=True, text=True, timeout=10)
                self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
                self.assertEqual(json.loads(log.read_text()), expected)
                self.assertFalse(any(path.exists() for path in canaries.values()))
        provider = '/tmp/provider "quote" `touch ' + str(canaries["provider"]) + '` $(touch ' + str(canaries["dollar"]) + ') $(shell touch ' + str(canaries["make"]) + ') ${ALKION_CANARY_VAR}'
        for origin in ("command-line", "environment"):
            with self.subTest(provider_origin=origin):
                argv = ["make", "-C", str(app), "android-synthetic-documents-provider"]
                variables = dict(env)
                if origin == "command-line":
                    argv.append("ALKION_OUTPUT=" + provider)
                else:
                    variables["ALKION_OUTPUT"] = provider
                completed = subprocess.run(argv, env=variables, capture_output=True, text=True, timeout=10)
                self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
                self.assertEqual(json.loads(log.read_text()), ["tool/android_synthetic.sh", "--action", "build-documents-provider", "--output", provider])
                self.assertFalse(any(path.exists() for path in canaries.values()))


if __name__ == "__main__":
    print("Host-only SAF controls: fake command transport and synthetic /tmp files; no Android qualification.", flush=True)
    unittest.main(verbosity=2)
