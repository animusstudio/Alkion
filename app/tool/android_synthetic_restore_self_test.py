"""Host controls for the real restore module and real private /tmp file ingress.

No Android, real Git/FVM, build or device command is executed. Focused Make
controls use fake shell/FVM executables. The reviewed
harness parsers and file publication programs run through a fake ADB transport.
Synthetic report/container bytes here establish host orchestration only; they do
not qualify the installed adapter's SQL/backup oracle or an Android interruption.
"""

import copy
import io
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
import android_synthetic_documents as documents
import android_synthetic_publish as publish
import android_synthetic_documents_self_test as saf
import android_synthetic_restore as restore
import android_synthetic_ui as observer


SOURCE_RUN = "2" * 32
PROFILE = "12345678-1234-4234-8234-123456789abc"
RAW_RESTORE = "rs-" + "3" * 32
SELECTED_RESTORE = "rs-" + "4" * 32
RAW_DATABASE = "profiles/" + PROFILE + "/generations/" + RAW_RESTORE + "/alkion.sqlite"
SELECTED_DATABASE = "profiles/" + PROFILE + "/generations/" + SELECTED_RESTORE + "/alkion.sqlite"


class FakeHost(saf.FakeHost):
    def __init__(self, root):
        super().__init__(root)
        self.PROCESS_IDENTITY_SCRIPT = self.namespace["PROCESS_IDENTITY_SCRIPT"]
        self.step = 0
        self.pid_counter = 700
        self.starts = []
        self.exact_cuts = []
        self.kernel_reads = {}
        self.builds = []
        self.external_fvm = None
        self.scenario = "valid"
        self.arguments = self.args
        self.installed.pop(restore.OBSERVER, None)
        self.metadata.pop(restore.OBSERVER, None)
        self.pids.pop(restore.OBSERVER, None)
        # Fresh driver bootstrap has nested proof files only. These are private
        # fixture setup operations, never Android repair performed by the module.
        for package in documents.VARIANTS.values():
            shutil.rmtree(self.package_root(package) / ("files/" + package))
            self.installed[package] = self.driver["installed"][package]
            self.metadata[package]["version_code"] = self.installed[package]["version_code"]
        self.source_host = saf.FakeHost(root / "producer")
        self.source_manifest = self.make_source()
        self.write(root / "source-inputs.json", self.source_manifest)
        self.args.source_manifest = str(root / "source-inputs.json")
        self.args.receiver_driver = str(root / "driver/run.json")
        self.args.source_review = str(root / "source-review.json")
        self.write(Path(self.args.source_review), {"format": "alkion-restore-source-review/1", "result": "PASS",
                                                "source_commit": saf.REVISION, "transitions": []})
        build = {"format": "alkion-restore-build/1", "run_id": saf.RUN, "source_commit": saf.REVISION,
                 "steps": list(restore.STEPS), "variants": {}}
        for flavor, package in documents.VARIANTS.items():
            path = root / (flavor + "-restore.apk")
            facts = self.artifact(path, package, 90)
            setattr(self.args, flavor + "_apk", str(path))
            build["variants"][flavor] = {"apk": str(path), "facts": facts,
                "argv": restore.restore_build_arguments({"ALKION_FLAVOR": flavor, "ALKION_PROOF_RUN": saf.RUN,
                    "ALKION_PROOF_SOURCE": saf.REVISION, "ALKION_PROOF_VERSION": "90"})}
        self.args.candidate_manifest = str(root / "build.json")
        self.write(Path(self.args.candidate_manifest), build)
        provider_path = root / "provider.apk"
        self.artifact(provider_path, documents.PROVIDER, 1)
        self.args.provider_apk = str(provider_path)
        observer = root / "retained-ui/ui-observer"
        observer_apk = self.artifact(observer / "synthetic-ui-observer.apk", restore.OBSERVER, saf.observer.VERSION)
        self.native_source = self.APP / "tool/android_synthetic_ui/HierarchyInstrumentation.java"
        self.args.ui_observer_build = str(observer / "build.json")
        self.write(Path(self.args.ui_observer_build), {"format": "alkion-android-ui-build/1", "source_commit": saf.REVISION,
            "native_source_sha256": saf.observer.native_digest(self), "apk": observer_apk})
        self.args.version_ledger = str(root / "ledger.json")
        self.refresh_ledger()

    @staticmethod
    def ui_observer_validate_build(host, args, root, record):
        path = root / "ui-observer/synthetic-ui-observer.apk"
        documents.require(record["native_source_sha256"] == observer.native_digest(host) and
                          host.fake_apk_facts(args, path, restore.OBSERVER) == record["apk"], "fake_observer_artifact_changed")
        return path

    @staticmethod
    def ui_observer_install_fresh(host, args, receipt, root, record, revision):
        path = host.ui_observer_validate_build(host, args, root, record)
        documents.require(restore.OBSERVER not in host.installed, "fake_observer_already_present")
        host.adb(args, "install", path)
        host.metadata[restore.OBSERVER]["uid"] = 10004
        binding = {"format": "alkion-android-ui-binding/1", "build": record, "uid": 10004,
                   **{key: receipt[key] for key in ("run_id", "serial", "avd")}}
        args._ui_observer = (binding, revision)
        return binding

    def fake_apk_facts(self, args, path, package):
        if hasattr(self, "source_host") and str(path).startswith(str(self.source_host.root)):
            return self.source_host.fake_apk_facts(args, path, package)
        return super().fake_apk_facts(args, path, package)

    def make_source(self):
        producer = self.source_host
        for name in ("receipt", "driver", "updates", "lifecycle"):
            value = json.loads(json.dumps(getattr(producer, name)).replace(saf.RUN, SOURCE_RUN))
            value["avd"] = "producer-proof"
            setattr(producer, name, value)
        producer.write(producer.root / "disposable.json", producer.receipt)
        producer.save_receipts()
        manifest = {"format": "alkion-restore-source-inputs/1", "disposable": str(producer.root / "disposable.json"),
            **{name: str(producer.root / name / "run.json") for name in ("driver", "updates", "lifecycle")},
            "documents": str(producer.root / "documents/run.json"), "variants": {},
            "attempt_manifests": [str(producer.root / "failed-attempt.json")]}
        campaign = {"format": "alkion-android-run/1", "phase": "documents-provider", "documents_phase": "PASS",
            "overall": "IN_PROGRESS", "source_commit": saf.REVISION, "base_source_commit": saf.REVISION,
            **{key: producer.receipt[key] for key in ("run_id", "serial", "avd")},
            "installed": {documents.PACKAGES[0]: producer.driver["installed"][documents.PACKAGES[0]]}, "documents": {}}
        provider = producer.artifact(producer.root / "provider.apk", documents.PROVIDER, 1)
        campaign["provider"] = {**provider, "uid": 10003}
        for flavor, package in documents.VARIANTS.items():
            # Different immutable bytes per actual variant; no foreign manifest
            # substitution is made by the module under test.
            data = saf.RAW + flavor.encode()
            control = {"run_id": SOURCE_RUN, "variant": flavor, "length": len(data), "sha256": documents.digest(data)}
            observed = {name: saf.provider_receipt(name, control) for name in documents.CASES if not name.endswith("-cancel")}
            for value in observed.values():
                value["run_id"] = SOURCE_RUN
                if "output_length" in value and value["case"] not in ("save-write-denied", "save-write-interrupted"):
                    value["output_length"] = len(data)
            report = saf.terminal(flavor, observed)
            report["run_id"] = SOURCE_RUN
            receiving = saf.receiving_report(data)
            receiving["tool"]["application_id"] = package
            report["fixture"] = {"format": "alkion-android-documents-fixture/1", "source_profile_id": PROFILE,
                "source_installation_id": "87654321-1234-4234-8234-123456789abc", "source_generation": 1,
                "ids": {name: "synthetic-" + name for name in ("exercise", "day", "slot", "workout", "draft",
                        "imported_day", "correction", "review", "import_artifact", "original")},
                "original": {"length": 256 * 1024, "sha256": "d" * 64}, "inventory": receiving["inventory"]}
            base = producer.root / "documents" / flavor
            paths = {"report": str(base / "documents.json"), "receiving": str(base / "receiving.json"),
                "provider_save_good": str(base / "save-good.json"), "received": str(base / "received.alkionbackup"),
                "apk": str(base / "documents.apk")}
            for key, value in (("report", report), ("receiving", receiving), ("provider_save_good", observed["save-good"]),
                               ("received", data)):
                producer.write(Path(paths[key]), value)
            facts = producer.artifact(Path(paths["apk"]), package, 45)
            campaign["installed"][package] = facts
            campaign["documents"][flavor] = {"report": report, "receiving": receiving, "normal_profiles_unchanged": True,
                "provider_pid": 501, "provider_outputs": {"save-good": {"name": "save-good-" + PROFILE + ".partial",
                    "length": len(data), "sha256": documents.digest(data)}}}
            manifest["variants"][flavor] = paths
        producer.write(Path(manifest["documents"]), campaign)
        producer.write(Path(manifest["attempt_manifests"][0]), {"run_id": SOURCE_RUN, "serial": producer.receipt["serial"],
            "avd": producer.receipt["avd"], "attempted": {"application_id": documents.PACKAGES[1], "version_code": 80}})
        return manifest

    def refresh_ledger(self):
        values = [Path(self.source_manifest[name]) for name in restore.SOURCE_KEYS]
        values += list(map(Path, self.source_manifest["attempt_manifests"]))
        values += [Path(self.args.receiver_driver), Path(self.args.candidate_manifest)]
        manifests = {str(path): documents.digest(path.read_bytes()) for path in values}
        observed = set()
        for path in values[:-1]:
            observed |= restore.recorded_codes(json.loads(path.read_bytes()))
        entries = [{"application_id": package, "version_code": code, "state": "failed", "role": "historical-proof",
                    "source_commit": saf.REVISION} for package, code in sorted(observed)]
        for flavor, package in documents.VARIANTS.items():
            facts = self.fake_apk_facts(None, Path(getattr(self.args, flavor + "_apk")), package)
            entries.append({"application_id": package, "version_code": facts["version_code"], "state": "built",
                "role": "fresh-receiving-restore", "source_commit": saf.REVISION, "apk_sha256": facts["apk_sha256"]})
        self.write(Path(self.args.version_ledger), {"format": "alkion-android-version-ledger/1", "complete": True,
            "coverage": "all-attempted-and-reserved-in-disposable-run", "run_id": saf.RUN,
            "serial": self.args.serial, "avd": self.args.avd, "manifest_sha256": manifests, "entries": entries})

    def command(self, argv, **options):
        text = list(map(str, argv))
        if text[0] == "fvm":
            flavor = text[text.index("--flavor") + 1]
            self.calls.append(text)
            header = Path(self.args.output) / (flavor + "-build-attempt.json")
            assert header.is_file(), "FVM reached before durable attempted-version header"
            self.builds.append(text)
            if self.scenario == "build-timeout":
                raise subprocess.TimeoutExpired(text, 600, output=b"partial FVM stdout\x00", stderr=b"partial FVM stderr\xff")
            if self.scenario == "build-supported-fail" and flavor == "supported":
                return saf.result(b"failed supported FVM stdout", b"failed supported FVM stderr", 1)
            if self.scenario == "build-stale-output":
                return saf.result(b"fake FVM returned success without publishing new bytes", b"")
            if self.scenario == "build-ledger-drift":
                Path(self.args.version_ledger).write_bytes(b"changed allocation ledger after FVM")
            if self.external_fvm is not None:
                return subprocess.run([str(self.external_fvm), *text[1:]], cwd=self.APP,
                                      capture_output=True, timeout=10)
            self.artifact(self.APP / ("build/app/outputs/flutter-apk/app-" + flavor + "-debug.apk"),
                          documents.VARIANTS[flavor], int(text[text.index("--build-number") + 1]))
            return saf.result(b"fake FVM completed\n", b"")
        if text[0] == "git" and self.scenario == "build-source-drift" and self.builds and text[-1] == "HEAD":
            return saf.result("0" * 40 + "\n")
        if text[0] == "git" and "merge-base" in text:
            self.calls.append(text)
            return saf.result(code=0 if self.scenario != "not-descendant" else 1)
        if text[0] == "git" and "diff" in text:
            self.calls.append(text)
            if "--binary" in text:
                return saf.result(stdout=b"synthetic exact reviewed range\n")
            return saf.result("app/integration_test/android_restore_test.dart\n" if self.scenario != "runtime-diff" else "app/lib/main.dart\n")
        if text[0].endswith("/aapt2"):
            tree = saf.PACKAGED_PROVIDER_TREE
            if self.scenario == "provider-enabled":
                tree = tree.replace("enabled(0x0101000e)=false", "enabled(0x0101000e)=true")
            return saf.result(tree)
        if text[0].endswith("/adb") and text[3] == "install" and self.scenario == "install-timeout":
            raise subprocess.TimeoutExpired(text, 60, output=b"partial native stdout\x00", stderr=b"partial stderr\xff")
        if text[0].endswith("/adb") and text[3:] == ["get-state"] and self.scenario == "preflight-timeout":
            raise subprocess.TimeoutExpired(text, 30, output=b"partial preflight\x00", stderr=b"partial preflight stderr")
        result = super().command(argv, **options)
        if text[0].endswith("/adb") and text[3] == "install" and result.returncode == 0:
            facts = self.facts_for_file(Path(text[-1]))
            if facts["package"] == restore.OBSERVER:
                self.metadata[restore.OBSERVER]["uid"] = 10004
        return result

    def android(self, argv, binary=False, data=None):
        if argv[:1] == ["run-as"]:
            if argv[2:] == ["/system/bin/kill", "-9", str(self.pids.get(argv[1]))]:
                package, pid = argv[1], self.pids[argv[1]]
                self.exact_cuts.append((package, pid))
                if self.scenario == "replacement" and len(self.exact_cuts) == 1:
                    self.pids[package] = pid + 1000
                elif self.scenario != "kill-stuck":
                    self.pids[package] = None
                return saf.result()
            if argv[2:5] == ["/system/bin/sh", "-c", "id -u; pwd -P"]:
                package = argv[1]
                value = str(self.metadata[package]["uid"]) + "\n/data/user/0/" + package + "\n"
                if self.scenario == "bad-root":
                    value = value.replace("/data/user/0/", "/data/user/10/")
                return saf.result(value.encode() if binary else value, b"" if binary else "")
        if argv[:2] == ["am", "start"]:
            package = argv[-1].split("/")[0]
            if package in documents.VARIANTS.values():
                self.pid_counter += 1
                self.pids[package] = 701 if self.scenario == "pid-reuse" else self.pid_counter
                self.start_restore(package)
                self.mutations.append(("start", package))
                return saf.result("Status: ok\n")
        if argv[:2] == ["am", "kill"] and self.scenario == "terminal-left-alive":
            return saf.result()
        if argv[:2] == ["am", "kill"] and self.step == 2 and self.scenario == "prior-receipt-change":
            outcome = super().android(argv, binary, data)
            path = self.protocol_path / "receipt-001.json"
            path.write_bytes(path.read_bytes() + b" ")
            return outcome
        if argv[:2] == ["am", "kill"] and self.step == 1 and self.scenario == "ingress-change":
            outcome = super().android(argv, binary, data)
            path = self.protocol_path / "received.alkionbackup"
            path.write_bytes(path.read_bytes() + b"changed")
            return outcome
        if argv[:2] == ["sh", "-c"] and self.step == 3 and self.scenario == "kernel-start-change":
            outcome = super().android(argv, binary, data)
            pid = int(argv[-1])
            self.kernel_reads[pid] = self.kernel_reads.get(pid, 0) + 1
            if self.kernel_reads[pid] >= 2:
                outcome.stdout = outcome.stdout.replace(" 100 ", " 101 ")
            return outcome
        return super().android(argv, binary, data)

    def start_restore(self, package):
        self.current = self.front = package
        self.flavor = next(name for name, value in documents.VARIANTS.items() if value == package)
        root = self.package_root(package) / restore.protocol_root(type("P", (), {"receipt": self.receipt})())
        pointer = json.loads((root / "current.json").read_bytes())
        self.request = json.loads((root / ("request-" + str(pointer["sequence"]).zfill(3) + ".json")).read_bytes())
        self.step = self.request["sequence"]
        self.starts.append((package, self.step, self.pids[package]))
        self.envelope = {key: self.request[key] for key in ("run_id", "source_commit", "application_id", "variant", "sequence", "action", "input_sha256")}
        self.envelope.update(request_sha256=pointer["request_sha256"], pid=self.pids[package])
        self.protocol_path = root
        self.write(root / ("claim-" + str(self.step).zfill(3) + ".json"), self.envelope)
        if self.scenario == "adapter-timeout":
            self.write(root / "receipt-001.json.partial-1", b"{incomplete")
            return
        if self.step in (3, 4, 5):
            self.control = {"format": "alkion-synthetic-documents/1", "run_id": saf.RUN, "variant": self.flavor,
                "length": len(self.source_bytes()), "sha256": documents.digest(self.source_bytes())}
            self.selected = self.drawer = False
            self.current_phase = {"case": "open-good", "document_label": saf.RUN + "-" + self.flavor + "-open-good.alkionbackup"}
            self.write(root / ("picker-" + str(self.step).zfill(3) + ".json"), {**self.envelope,
                "format": "alkion-android-restore-picker/1", "input_sha256": documents.digest(self.source_bytes())})
            self.front = "com.android.documentsui"
        else:
            self.publish_receipt()

    def source_bytes(self):
        return Path(self.source_manifest["variants"][self.flavor]["received"]).read_bytes()

    def ui_xml(self):
        raw = super().ui_xml()
        # The SAF fixture helper uses RAW. The receiver pins the selected actual
        # variant bytes instead, matching its real provider input format.
        if self.front == "com.android.documentsui":
            root = self.package_root(documents.PROVIDER) / ("files/proof-runs/" + saf.RUN + "-" + self.flavor)
            pin = (saf.RUN + "\n" + self.flavor + "\n" + str(len(self.source_bytes())) + "\n" + documents.digest(self.source_bytes())).encode()
            self.write(root / "input.pin", pin)
        return raw

    def complete_picker(self):
        root = self.package_root(documents.PROVIDER) / ("files/proof-runs/" + saf.RUN + "-" + self.flavor)
        path = root / "receipts/open-good.json"
        receipt = saf.provider_receipt("open-good", self.control)
        if path.exists():
            receipt["events"] = json.loads(path.read_bytes())["events"] + receipt["events"]
        self.write(path, receipt)
        self.front = self.current
        self.publish_receipt()

    def fresh(self):
        package = self.current
        canonical = self.package_root(package) / ("files/" + package)
        prep = self.package_root(package) / ("files/." + package + "-fresh-restore/preparation.json")
        if not prep.exists():
            self.write(prep, b'{"request_id":"prep-id","installation_id":"receiving-new"}\n')
        if self.step >= 4:
            self.write(canonical / RAW_DATABASE, b"retained orphan raw bytes")
        if self.step >= 5:
            self.write(canonical / SELECTED_DATABASE, b"same completed selected bytes")
            self.write(canonical / Path(SELECTED_DATABASE).with_name("intent.json"),
                       documents.encoded({"restore_id": SELECTED_RESTORE}))
        files = {str(path.relative_to(canonical)): documents.digest(path.read_bytes()) for path in canonical.rglob("*") if path.is_file()}
        pending = SELECTED_RESTORE if self.step >= 5 else "prep-id"
        value = {"preparation_base64": restore.base64.b64encode(prep.read_bytes()).decode(), "stages": files,
                 "pending_id": pending, "can_complete": self.step >= 5}
        if self.step >= 5:
            value["intent"] = {"restore_id": pending, "profile_id": PROFILE,
                               "staged": {"database": "generations/" + SELECTED_RESTORE + "/alkion.sqlite"}}
        if self.scenario == "changed-preparation" and self.step == 4:
            prep.write_bytes(b"changed actual preparation")
        if self.scenario == "missing-stage" and self.step == 6:
            (canonical / RAW_DATABASE).unlink()
        if self.scenario == "new-pending" and self.step == 6:
            value["pending_id"] = value["intent"]["restore_id"] = "other-pending"
        return value

    def baseline(self):
        return {"tables": {table: [] for table in documents.RECEIVING_TABLES},
                "keys": {table: ["synthetic_key"] for table in documents.RECEIVING_TABLES}}

    def publish_receipt(self):
        value = {**self.envelope, "format": "alkion-android-restore-proof/1", "complete": True,
                 "closed": True, "result": "PASS", "unrun": list(restore.UNRUN), "evidence": {}}
        if self.step == 1:
            value["evidence"] = {"input_verified": True}
        elif self.step == 2:
            value["evidence"] = {"cases": {name: {"result": "PASS", "outcome": outcome, "preserved": True}
                                             for name, outcome in restore.REFUSALS.items()}}
        elif 3 <= self.step <= 8:
            value.update(format="alkion-android-restore-checkpoint/1", complete=False, closed=False,
                         result="BARRIER", death_proven=False, evidence={"fresh": self.fresh()})
        else:
            prior = json.loads((self.protocol_path / ("receipt-" + str(self.step - 1).zfill(3) + ".json")).read_bytes())
            baseline = self.baseline()
            value["evidence"] = {"baseline": baseline, "inventory": restore.covered_inventory(baseline)}
            if self.step == 9:
                fresh = prior["evidence"]["fresh"]
                value["evidence"].update(fresh=fresh, closed_restore=baseline,
                    observed_pins_before_first_store_open={key: fresh[key] for key in ("preparation_base64", "stages")})
                canonical = self.package_root(self.current) / ("files/" + self.current)
                self.write(canonical / "local-profile.json", b"restored identity")
                self.write(canonical / ("profiles/" + PROFILE + "/selected-generation.json"),
                           {"format": "alkion-selected-generation", "version": 1, "restore_id": SELECTED_RESTORE})
            elif self.step == 10:
                value["evidence"].update(fresh=prior["evidence"]["fresh"], outcome="restore_not_pending", unchanged=True,
                                          resolved_id=prior["evidence"]["fresh"]["pending_id"])
            else:
                value["evidence"].update(cold_process=True, previous_pid=prior["pid"])
                if self.scenario == "cold-mutated" and self.step == 12:
                    baseline["tables"]["sets"] = [{"new": "unexpected"}]
                    value["evidence"]["inventory"] = restore.covered_inventory(baseline)
            # Real runtime opens may write this exact selected SQLite file. The
            # host must still re-read every other retained file after each open.
            canonical = self.package_root(self.current) / ("files/" + self.current)
            self.write(canonical / SELECTED_DATABASE, b"selected runtime bytes " + str(self.step).encode())
            faults = {"post-complete-prep-alter": (9, "prep", "alter"),
                      "post-refusal-orphan-delete": (10, "orphan", "delete"),
                      "post-cold1-prep-delete": (11, "prep", "delete"),
                      "post-cold2-orphan-alter": (12, "orphan", "alter")}
            if self.scenario in faults and self.step == faults[self.scenario][0]:
                _, target, mutation = faults[self.scenario]
                path = (self.package_root(self.current) / ("files/." + self.current + "-fresh-restore/preparation.json")
                        if target == "prep" else canonical / RAW_DATABASE)
                if mutation == "delete":
                    path.unlink()
                else:
                    path.write_bytes(b"changed retained bytes after runtime adoption")
        if self.scenario == "wrong-native-source":
            value["source_commit"] = "0" * 40
        if self.scenario == "barrier-pass" and self.step == 3:
            value.update(result="PASS", complete=True, closed=True, death_proven=True)
        if self.scenario == "refusal-mutated" and self.step == 2:
            value["evidence"]["cases"]["nonempty"]["preserved"] = False
        if self.scenario == "same-completed-id" and self.step == 10:
            value["evidence"]["resolved_id"] = "foreign-id"
        if self.scenario == "post-peer-prep-alter" and self.flavor == "supported" and self.step == 1:
            package = documents.PACKAGES[1]
            path = self.package_root(package) / ("files/." + package + "-fresh-restore/preparation.json")
            path.write_bytes(b"changed finished peer preparation")
        self.write(self.protocol_path / ("receipt-" + str(self.step).zfill(3) + ".json"), value)
        if self.scenario == "framework-failure" and self.step == 3:
            self.write(self.protocol_path / "failure-003.json", {"result": "FAIL"})


class RestoreControls(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="alkion-restore-host-")
        self.root = Path(self.temporary.name)
        self.host = FakeHost(self.root)
        self.environment = patch.dict(os.environ, JAVA_HOME="/usr/lib/jvm/java-21-openjdk", ANDROID_USER_HOME=str(self.host.user))
        self.environment.start()
        self.clock = saf.Clock()
        self.clock_patch = patch.object(restore, "time", self.clock)
        self.documents_clock_patch = patch.object(documents, "time", self.clock)
        self.clock_patch.start()
        self.documents_clock_patch.start()

    def tearDown(self):
        self.documents_clock_patch.stop()
        self.clock_patch.stop()
        self.environment.stop()
        self.temporary.cleanup()

    def prepare(self):
        return restore.prepare(self.host, self.host.args)

    def mutate_json(self, path, mutation):
        value = json.loads(Path(path).read_bytes())
        mutation(value)
        self.host.write(Path(path), value)

    def reservation(self, host=None):
        host = host or self.host
        ledger = json.loads(Path(host.args.version_ledger).read_bytes())
        ledger["manifest_sha256"].pop(host.args.candidate_manifest)
        for entry in ledger["entries"]:
            if entry["version_code"] == 90:
                entry["state"] = "reserved"
                entry.pop("apk_sha256")
        path = host.root / "allocation-ledger.json"
        host.write(path, ledger)
        host.args.version_ledger = str(path)
        host.args.attempt_manifests = []
        host.args.attempt_manifests_json = "[]"
        return path

    def build_environment(self):
        return {"ALKION_PROOF_RUN": saf.RUN, "ALKION_PROOF_SOURCE": saf.REVISION, "ALKION_PROOF_VERSION": "90"}

    def test_pair_builder_preserves_reserved_ledger_and_emits_exact_manifest(self):
        ledger = self.reservation()
        raw = ledger.read_bytes()
        prepared = restore.prepare_pair_build(self.host, self.host.args, self.build_environment())
        self.assertFalse(prepared.output.exists())
        self.assertEqual(prepared.floor, 80)
        manifest = restore.build_pair(self.host, prepared)
        self.assertEqual(ledger.read_bytes(), raw)
        self.assertEqual((prepared.output / "original-reservation-ledger.json").read_bytes(), raw)
        self.assertEqual(set(manifest), {"format", "run_id", "source_commit", "steps", "variants"})
        self.assertEqual(manifest["steps"], list(restore.STEPS))
        self.assertEqual([value[value.index("--flavor") + 1] for value in self.host.builds], ["dev", "supported"])
        for flavor, item in manifest["variants"].items():
            self.assertEqual(item["argv"], restore.restore_build_arguments({**self.build_environment(), "ALKION_FLAVOR": flavor}))
            self.assertEqual(item["facts"]["apk_sha256"], documents.digest(Path(item["apk"]).read_bytes()))
            header = json.loads((prepared.output / (flavor + "-build-attempt.json")).read_bytes())
            self.assertEqual((header["state"], header["reservation_ledger_sha256"]), ("attempted", documents.digest(raw)))
        self.assertFalse(self.host.mutations)
        self.assertFalse(any(call[0].endswith("/adb") for call in self.host.calls))

    def test_pair_build_refuses_reservation_identity_floor_and_raw_drift(self):
        path = self.reservation()
        original = path.read_bytes()
        mutations = (
            lambda value: value["entries"][-1].__setitem__("state", "built"),
            lambda value: value["entries"][-1].__setitem__("source_commit", "0" * 40),
            lambda value: value["entries"][-1].__setitem__("role", "other"),
            lambda value: value["entries"].append(copy.deepcopy(value["entries"][-1])),
            lambda value: value["entries"].append({"application_id": documents.PACKAGES[1], "version_code": 91,
                "state": "reserved", "role": "unrelated-future", "source_commit": saf.REVISION}),
            lambda value: value["manifest_sha256"].clear())
        for change in mutations:
            path.write_bytes(original)
            self.mutate_json(path, change)
            with self.assertRaises(restore.Refusal):
                restore.prepare_pair_build(self.host, self.host.args, self.build_environment())
            self.assertFalse(self.host.builds)
        path.write_bytes(original)
        prepared = restore.prepare_pair_build(self.host, self.host.args, self.build_environment())
        path.write_bytes(original + b" ")
        with self.assertRaisesRegex(restore.Refusal, "host_input_changed"):
            restore.build_pair(self.host, prepared)
        self.assertFalse(self.host.builds)
        self.assertFalse(prepared.output.exists())

    def test_pair_build_failure_and_timeout_keep_attempted_versions_and_bytes(self):
        for scenario in ("build-supported-fail", "build-timeout", "build-source-drift", "build-ledger-drift"):
            with self.subTest(scenario=scenario), tempfile.TemporaryDirectory(prefix="alkion-restore-build-negative-") as directory:
                host = FakeHost(Path(directory))
                with patch.dict(os.environ, ANDROID_USER_HOME=str(host.user)):
                    ledger = self.reservation(host)
                    original = ledger.read_bytes()
                    prepared = restore.prepare_pair_build(host, host.args, self.build_environment())
                    host.scenario = scenario
                    with self.assertRaises((restore.Refusal, subprocess.TimeoutExpired)):
                        restore.build_pair(host, prepared)
                    self.assertTrue((prepared.output / "dev-build-attempt.json").is_file())
                    self.assertTrue((prepared.output / "build-failure.json").is_file())
                    self.assertFalse((prepared.output / "build.json").exists())
                    self.assertEqual((prepared.output / "original-reservation-ledger.json").read_bytes(), original)
                    if scenario == "build-supported-fail":
                        self.assertTrue((prepared.output / "dev-restore.apk").is_file())
                        self.assertTrue((prepared.output / "supported-build-attempt.json").is_file())
                        self.assertEqual((prepared.output / "supported-build.stderr").read_bytes(), b"failed supported FVM stderr")
                        self.assertEqual(ledger.read_bytes(), original)
                    if scenario == "build-timeout":
                        self.assertEqual((prepared.output / "build-timeout.stdout").read_bytes(), b"partial FVM stdout\x00")
                        self.assertEqual((prepared.output / "build-timeout.stderr").read_bytes(), b"partial FVM stderr\xff")
                    self.assertFalse(host.mutations)

    def test_actual_restore_facade_check_and_full_fake_observer_route(self):
        self.host.args.attempt_manifests_json = "[]"
        self.host.args.action = "restore-check"
        self.host.restore_action(self.host.args)
        self.assertFalse(self.host.mutations)
        self.assertFalse(Path(self.host.args.output).exists())
        self.assertFalse(hasattr(self.host.args, "_ui_observer"))
        self.host.args.action = "restore"
        state = self.host.restore_action(self.host.args)
        self.assertEqual(state["restore_phase"], "PASS")
        self.assertEqual(len(self.host.exact_cuts), 12)
        self.assertEqual(len(self.host.starts), 24)
        observations = list(Path(self.host.args.output).glob("*.observation/host-receipt.json"))
        self.assertTrue(observations)
        self.assertTrue(all(json.loads(path.read_bytes())["result"] == "PASS" for path in observations))
        self.assertEqual(state["ui_observer"]["build"]["source_commit"], saf.REVISION)

    def test_restore_facade_invalid_json_source_and_preflight_timeout_do_not_mutate(self):
        self.host.args.action = "restore-check"
        for raw in ("{}", "[1]", "not-json"):
            self.host.args.attempt_manifests_json = raw
            with self.assertRaises((ValueError, self.host.Refusal)):
                self.host.restore_action(self.host.args)
            self.assertFalse(self.host.mutations)
        self.host.args.attempt_manifests_json = "[]"
        self.host.scenario = "preflight-timeout"
        with patch("sys.stderr", new_callable=io.StringIO) as capture, self.assertRaises(subprocess.TimeoutExpired):
            self.host.restore_action(self.host.args)
        record = json.loads(capture.getvalue())
        self.assertEqual(restore.base64.b64decode(record["stdout_base64"]), b"partial preflight\x00")
        self.assertFalse(Path(self.host.args.output).exists())
        self.assertFalse(self.host.mutations)

    def make_capture(self, target, values, *, origin="command-line"):
        tools = self.root / "make-transport"
        tools.mkdir(exist_ok=True)
        log = self.root / "make-transport.json"
        shell = tools / "bash"
        shell.write_text('#!/usr/bin/env python3\nimport os,json,sys\nfrom pathlib import Path\nPath(os.environ["RESTORE_MAKE_LOG"]).write_text(json.dumps({"argv":sys.argv[1:],"env":{k:v for k,v in os.environ.items() if k.startswith("ALKION_")}}))\n')
        shell.chmod(0o700)
        environment = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ["PATH"], RESTORE_MAKE_LOG=str(log))
        argv = ["make", "-C", str(Path(__file__).parent.parent), target]
        if origin == "command-line":
            argv += [key + "=" + value for key, value in values.items()]
        else:
            environment.update(values)
        completed = subprocess.run(argv, env=environment, capture_output=True, text=True, timeout=10)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        return json.loads(log.read_bytes())

    def restore_make_inputs(self):
        args = self.host.args
        return {"ALKION_AVD": args.avd, "ALKION_SERIAL": args.serial, "ALKION_RECEIPT": args.receipt,
            "ALKION_OUTPUT": args.output, "ALKION_BASE_RUN": args.base_run, "ALKION_DRIVER_RUN": args.driver_run,
            "ALKION_UPDATES_RUN": args.updates_run, "ALKION_RESTORE_SOURCE_MANIFEST": args.source_manifest,
            "ALKION_RESTORE_RECEIVER_DRIVER": args.receiver_driver, "ALKION_VERSION_LEDGER": args.version_ledger,
            "ALKION_SOURCE_REVIEW": args.source_review, "ALKION_ATTEMPT_MANIFESTS_JSON": "[]",
            "ALKION_RESTORE_CANDIDATE_MANIFEST": args.candidate_manifest, "ALKION_RESTORE_DEV_APK": args.dev_apk,
            "ALKION_RESTORE_SUPPORTED_APK": args.supported_apk, "ALKION_RESTORE_PROVIDER_APK": args.provider_apk,
            "ALKION_UI_OBSERVER_BUILD": args.ui_observer_build, "ALKION_PUBLISHER_BUILD": args.publisher_build,
            **self.build_environment()}

    def parse_captured_cli(self, captured):
        body = Path(__file__).with_name("android_synthetic.sh").read_text().split("<<'PY'\n", 1)[1].rsplit("\nPY", 1)[0]
        start = body.index("\nparser = argparse.ArgumentParser")
        parser_source = body[start:body.index("\ntry:\n", start)]
        with patch.object(sys, "argv", ["-", *captured["argv"]]):
            exec(compile(parser_source, "actual restore CLI parser", "exec"), self.host.namespace)
        self.host.args = self.host.namespace["args"]
        return self.host.args

    def test_actual_make_preserves_literal_restore_paths_json_and_build_inputs(self):
        canary = self.root / "must-not-execute"
        literal = 'space "double" \'single\' `touch ' + str(canary) + '` $(touch ' + str(canary) + ') $(shell touch ' + str(canary) + ') ${HOME}'
        values = {key: literal for key in self.restore_make_inputs()}
        values["ALKION_ATTEMPT_MANIFESTS_JSON"] = json.dumps([literal])
        flags = {"--avd": "ALKION_AVD", "--serial": "ALKION_SERIAL", "--receipt": "ALKION_RECEIPT", "--output": "ALKION_OUTPUT",
            "--source-manifest": "ALKION_RESTORE_SOURCE_MANIFEST", "--receiver-driver": "ALKION_RESTORE_RECEIVER_DRIVER",
            "--version-ledger": "ALKION_VERSION_LEDGER", "--source-review": "ALKION_SOURCE_REVIEW",
            "--attempt-manifests-json": "ALKION_ATTEMPT_MANIFESTS_JSON", "--candidate-manifest": "ALKION_RESTORE_CANDIDATE_MANIFEST",
            "--dev-apk": "ALKION_RESTORE_DEV_APK", "--supported-apk": "ALKION_RESTORE_SUPPORTED_APK",
            "--provider-apk": "ALKION_RESTORE_PROVIDER_APK", "--ui-observer-build": "ALKION_UI_OBSERVER_BUILD",
            "--publisher-build": "ALKION_PUBLISHER_BUILD"}
        for origin in ("command-line", "environment"):
            for target, action in (("android-synthetic-restore-apks", "build-restore"),
                                   ("android-synthetic-restore-check", "restore-check"), ("android-synthetic-restore-run", "restore")):
                captured = self.make_capture(target, values, origin=origin)
                argv = captured["argv"]
                self.assertEqual(argv[argv.index("--action") + 1], action)
                for flag, key in flags.items():
                    self.assertEqual(argv[argv.index(flag) + 1], values[key])
                for key in ("ALKION_PROOF_RUN", "ALKION_PROOF_SOURCE", "ALKION_PROOF_VERSION"):
                    self.assertEqual(captured["env"][key], literal)
                self.assertFalse(canary.exists())

    def test_actual_make_parser_facade_and_fake_fvm_produce_pair(self):
        self.reservation()
        captured = self.make_capture("android-synthetic-restore-apks", self.restore_make_inputs())
        fvm = self.root / "fake-fvm"
        log = self.root / "fake-fvm.jsonl"
        fvm.write_text('''#!/usr/bin/env python3
import json,os,sys
from pathlib import Path
args=sys.argv[1:]; flavor=args[args.index("--flavor")+1]; version=int(args[args.index("--build-number")+1])
assert (Path(os.environ["RESTORE_BUILD_OUTPUT"])/(flavor+"-build-attempt.json")).is_file()
with Path(os.environ["RESTORE_FVM_LOG"]).open("a") as stream: stream.write(json.dumps(args)+"\\n")
path=Path.cwd()/"build/app/outputs/flutter-apk"/("app-"+flavor+"-debug.apk"); path.parent.mkdir(parents=True,exist_ok=True)
path.write_text(json.dumps({"package":"dev.animusstudio.alkion.dev" if flavor=="dev" else "dev.animusstudio.alkion","version":version}))
print("fake compiler only")
''')
        fvm.chmod(0o700)
        self.host.external_fvm = fvm
        with patch.dict(os.environ, **captured["env"], ANDROID_HOME=str(self.host.sdk),
                        RESTORE_BUILD_OUTPUT=self.host.args.output, RESTORE_FVM_LOG=str(log)):
            args = self.parse_captured_cli(captured)
            result = self.host.restore_action(args)
        actual = [json.loads(line) for line in log.read_text().splitlines()]
        self.assertEqual(actual, [restore.restore_build_arguments({**self.build_environment(), "ALKION_FLAVOR": flavor})[1:]
                                  for flavor in documents.VARIANTS])
        self.assertEqual(set(result["variants"]), set(documents.VARIANTS))
        self.assertFalse(self.host.mutations)

    def test_paired_manifest_and_new_built_ledger_feed_unchanged_receiver_check(self):
        original_ledger = self.reservation()
        reserved_raw = original_ledger.read_bytes()
        built = restore.build_pair(self.host, restore.prepare_pair_build(self.host, self.host.args, self.build_environment()))
        build_path = Path(self.host.args.output) / "build.json"
        ledger = json.loads(reserved_raw)
        ledger["manifest_sha256"][str(build_path)] = documents.digest(build_path.read_bytes())
        attempts = [original_ledger, *(build_path.parent / (flavor + "-build-attempt.json") for flavor in documents.VARIANTS)]
        for path in attempts:
            ledger["manifest_sha256"][str(path)] = documents.digest(path.read_bytes())
        for entry in ledger["entries"]:
            if entry["version_code"] == 90:
                flavor = next(name for name, package in documents.VARIANTS.items() if package == entry["application_id"])
                entry.update(state="built", apk_sha256=built["variants"][flavor]["facts"]["apk_sha256"])
        # The coordinator creates this separate synthetic receipt; the builder
        # never changes either ledger or allocates another code.
        new_ledger = self.root / "built-ledger.json"
        self.host.write(new_ledger, ledger)
        self.host.args.version_ledger = str(new_ledger)
        self.host.args.candidate_manifest = str(build_path)
        self.host.args.attempt_manifests_json = json.dumps(list(map(str, attempts)))
        self.host.args.output = str(self.root / "receiver-run")
        self.host.args.action = "restore-check"
        for flavor in documents.VARIANTS:
            setattr(self.host.args, flavor + "_apk", built["variants"][flavor]["apk"])
        self.host.restore_action(self.host.args)
        self.assertEqual(original_ledger.read_bytes(), reserved_raw)
        self.assertFalse(self.host.mutations)
        self.assertFalse(Path(self.host.args.output).exists())

    def test_cli_missing_restore_identity_and_literal_main_stay_guarded(self):
        for action in ("build-restore", "restore-check", "restore"):
            completed = subprocess.run(["bash", str(Path(__file__).with_name("android_synthetic.sh")), "--action", action],
                                       capture_output=True, text=True, timeout=10)
            self.assertNotEqual(completed.returncode, 0)
            self.assertIn("explicit_emulator_serial_required", completed.stderr)
        argv = self.host.lifecycle_build_arguments({"ALKION_FLAVOR": "dev", "ALKION_PROOF_RUN": saf.RUN,
                                                   "ALKION_PROOF_VERSION": "91", "ALKION_LIFECYCLE_PHASE": "main"})
        self.assertEqual(argv[argv.index("--target") + 1], "lib/main.dart")
        self.assertFalse(any(value.startswith("--dart-define") for value in argv))

    def test_actual_make_build_source_and_compile_refusals_never_reach_fvm(self):
        self.reservation()
        tools = self.root / "source-guard-tools"
        tools.mkdir()
        git = tools / "git"
        git.write_text('#!/usr/bin/env python3\nimport os,sys\nif sys.argv[3:]==["rev-parse","HEAD"]:print(os.environ["RESTORE_FAKE_SOURCE"])\nelif sys.argv[3:]==["status","--porcelain","--untracked-files=normal"]:print(os.environ.get("RESTORE_FAKE_DIRTY",""),end="")\nelse:raise SystemExit("unexpected fake Git")\n')
        git.chmod(0o700)
        log = self.root / "must-not-reach-fvm"
        fvm = tools / "fvm"
        fvm.write_text('#!/usr/bin/env python3\nimport os\nfrom pathlib import Path\nPath(os.environ["RESTORE_FVM_CANARY"]).write_text("unexpected compiler")\n')
        fvm.chmod(0o700)
        environment = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ["PATH"], ANDROID_HOME=str(self.host.sdk),
                           RESTORE_FAKE_SOURCE=saf.REVISION, RESTORE_FVM_CANARY=str(log))
        cases = (({"ALKION_PROOF_SOURCE": "0" * 40}, {}, "source_or_run_mismatch"),
                 ({"ALKION_PROOF_SOURCE": "c" * 40}, {}, "source_or_run_mismatch"),
                 ({"ALKION_PROOF_VERSION": "90; arbitrary"}, {}, "explicit_restore_build_inputs"),
                 ({"ALKION_PROOF_VERSION": "00090"}, {}, "canonical_restore_build_version"),
                 ({}, {"RESTORE_FAKE_DIRTY": " M helper.py\n"}, "commit_reviewed_source"))
        for changes, overrides, reason in cases:
            values = {**self.restore_make_inputs(), **changes}
            completed = subprocess.run(["make", "-C", str(Path(__file__).parent.parent), "android-synthetic-restore-apks",
                                        *(key + "=" + value for key, value in values.items())],
                                       env={**environment, **overrides}, capture_output=True, text=True, timeout=10)
            self.assertNotEqual(completed.returncode, 0)
            self.assertIn(reason, completed.stderr)
            self.assertFalse(log.exists())
            self.assertFalse(Path(self.host.args.output).exists())

    def test_reservation_cannot_reuse_a_recorded_failed_attempt_code(self):
        path = self.reservation()
        attempt = self.root / "prior-failed-build.json"
        self.host.write(attempt, {"format": "alkion-restore-build-attempt/1", "run_id": saf.RUN,
            "serial": self.host.args.serial, "avd": self.host.args.avd, "source_commit": saf.REVISION,
            "application_id": documents.PACKAGES[1], "version_code": 90, "state": "attempted"})
        self.host.args.attempt_manifests = [str(attempt)]
        self.mutate_json(path, lambda value: value["manifest_sha256"].__setitem__(str(attempt), documents.digest(attempt.read_bytes())))
        with self.assertRaisesRegex(restore.Refusal, "reserved_pair_not_new"):
            restore.prepare_pair_build(self.host, self.host.args, self.build_environment())
        self.assertFalse(self.host.builds)
        self.assertFalse(Path(self.host.args.output).exists())

    def test_successful_fvm_cannot_adopt_stale_working_apk(self):
        self.reservation()
        prepared = restore.prepare_pair_build(self.host, self.host.args, self.build_environment())
        self.host.artifact(self.host.APP / "build/app/outputs/flutter-apk/app-dev-debug.apk", documents.PACKAGES[1], 90)
        self.host.scenario = "build-stale-output"
        with self.assertRaisesRegex(restore.Refusal, "output_missing_or_stale"):
            restore.build_pair(self.host, prepared)
        self.assertTrue((prepared.output / "dev-build-attempt.json").is_file())
        self.assertTrue((prepared.output / "build-failure.json").is_file())
        self.assertFalse((prepared.output / "build.json").exists())

    def test_actual_restore_facade_refuses_foreign_observer_before_actions(self):
        for scenario in ("foreign-source", "changed-native-source", "preexisting-helper"):
            with self.subTest(scenario=scenario), tempfile.TemporaryDirectory(prefix="alkion-restore-observer-guard-") as directory:
                host = FakeHost(Path(directory))
                host.args.action = "restore"
                host.args.attempt_manifests_json = "[]"
                if scenario == "foreign-source":
                    value = json.loads(Path(host.args.ui_observer_build).read_bytes())
                    value["source_commit"] = "0" * 40
                    host.write(Path(host.args.ui_observer_build), value)
                elif scenario == "changed-native-source":
                    host.native_source.write_bytes(host.native_source.read_bytes() + b"\nchanged synthetic native input")
                else:
                    build = json.loads(Path(host.args.ui_observer_build).read_bytes())
                    host.installed[observer.PACKAGE] = build["apk"]
                    host.metadata[observer.PACKAGE] = {"uid": 10004, "version_code": observer.VERSION}
                with patch.dict(os.environ, ANDROID_USER_HOME=str(host.user)), self.assertRaises((ValueError, host.Refusal)):
                    host.restore_action(host.args)
                self.assertFalse(host.mutations)
                self.assertFalse(Path(host.args.output).exists())

    def test_actual_restore_facade_wrong_observer_nonce_retains_failed_capture(self):
        self.host.args.action = "restore"
        self.host.args.attempt_manifests_json = "[]"
        self.host.scenario = "observer-wrong-nonce"
        with self.assertRaises(ValueError):
            self.host.restore_action(self.host.args)
        state = json.loads((Path(self.host.args.output) / "run.json").read_bytes())
        self.assertEqual(state["restore_phase"], "FAIL")
        self.assertEqual(len(self.host.exact_cuts), 0)
        receipts = list(Path(self.host.args.output).glob("*.observation/host-receipt.json"))
        self.assertEqual(json.loads(receipts[0].read_bytes())["result"], "FAIL")
        self.assertTrue(list(Path(self.host.args.output).glob("*.observation/receipt.json.stdout")))

    def test_full_real_module_fake_adb_and_real_private_files(self):
        prepared = self.prepare()
        self.assertFalse(self.host.mutations)
        state = restore.run(self.host, prepared)
        self.assertEqual(state["restore_phase"], "PASS")
        self.assertEqual(state["overall"], "IN_PROGRESS")
        self.assertEqual((state["installed_floor"], state["allocation_floor"]), (37, 80))
        bindings = json.loads(next(prepared.output.glob("*-candidate-ledger-bindings.json")).read_bytes())
        self.assertEqual([value["state"] for value in bindings["entries"]], ["built", "built"])
        self.assertEqual(len(self.host.exact_cuts), 12)
        self.assertEqual(len(self.host.starts), 24)
        self.assertEqual(len({pid for _, _, pid in self.host.starts}), 24)
        for flavor in restore.VARIANTS:
            result = state["variants"][flavor]
            self.assertEqual([value["action"] for value in result["steps"]], list(restore.STEPS))
            self.assertEqual(len(result["cuts"]), 6)
            self.assertTrue(all(value["death_proven"] for value in result["cuts"]))
            fresh = [value["evidence"]["fresh"] for value in result["steps"][2:8]]
            self.assertEqual(len({value["preparation_base64"] for value in fresh}), 1)
            self.assertEqual(len({value["pending_id"] for value in fresh[2:]}), 1)
        for call in self.host.calls:
            if call[0].endswith("/adb"):
                self.assertEqual(call[1:3], ["-s", self.host.args.serial])
            self.assertFalse(any(token in ("force-stop", "clear", "uninstall", "kill-all", "reboot") for token in call))
        self.assertIn("same_profile_replacement", state["unrun"])
        # Every inherited write went through the no-replace publisher: one
        # bootstrap per package after its install and before its first launch.
        self.assertEqual([package for package, index, _ in self.host.runas.programs if index == 1],
                         [documents.PACKAGES[1], documents.PROVIDER, documents.PACKAGES[2]])
        def first(predicate):
            return next(index for index, call in enumerate(self.host.calls) if predicate(call))
        for package in documents.VARIANTS.values():
            installed = first(lambda call: call[3:5] == ["install", "-r"] and
                              self.host.facts_for_file(Path(call[-1]))["package"] == package)
            bootstrap = first(lambda call: len(call) == 6 and shlex.split(call[5])[:2] == ["run-as", package] and
                              publish.BOOTSTRAP in shlex.split(call[5]))
            started = first(lambda call: call[3] == "shell" and "am start" in call[-1] and package + "/" in call[-1])
            self.assertLess(installed, bootstrap)
            self.assertLess(bootstrap, started)
        finals = [json.loads(path.read_bytes()) for path in prepared.output.glob("*.publication-final.json")]
        # Per variant: five ingress files, two provider stage files, twelve requests and twelve pointer values.
        self.assertEqual(len(finals), 2 * (5 + 2 + 12 + 12))
        self.assertTrue(all(item["state"] == "PUBLISHED" and item["partial_consumed"] is True and
                            item["basis"] == "clean_reply+final_readback" for item in finals))
        self.assertFalse(list(prepared.output.glob("*.publication.timeout-stdout")))
        for package in documents.VARIANTS.values():
            root = self.host.package_root(package) / restore.protocol_root(prepared)
            self.assertFalse([path.name for path in root.iterdir() if ".partial-" in path.name and
                              not path.name.startswith(("receipt-", "claim-", "picker-"))])
            self.assertEqual(len(list(root.glob("request-*.json"))), len(restore.STEPS))
        provider = self.host.package_root(documents.PROVIDER) / "files/proof-runs"
        self.assertFalse(list(provider.rglob("*.partial-*")))
        self.assertFalse(any(len(call) == 6 and "ln" in shlex.split(shlex.split(call[5])[4])
                             for call in self.host.calls if call[0].endswith("/adb") and call[3:5] == ["shell", "-T"] and
                             shlex.split(call[5])[2:4] == ["/system/bin/sh", "-c"]))

    def test_actual_make_restore_check_binds_the_literal_publisher_build(self):
        captured = self.make_capture("android-synthetic-restore-check", self.restore_make_inputs())
        argv = captured["argv"]
        self.assertEqual(argv[argv.index("--publisher-build") + 1], self.host.args.publisher_build)
        with patch.dict(os.environ, ANDROID_HOME=str(self.host.sdk)):
            args = self.parse_captured_cli(captured)
        self.host.restore_action(args)
        self.assertEqual(args._publisher.source_commit, saf.REVISION)
        self.assertFalse(self.host.mutations)
        self.assertFalse(self.host.runas.programs)
        self.assertFalse(Path(args.output).exists())
        args.publisher_build = ""
        with self.assertRaisesRegex(self.host.Refusal, "explicit_publisher_build_required"):
            self.host.restore_action(args)
        self.assertFalse(self.host.mutations)

    def test_flat_documents_case_refused_before_mutation(self):
        path = self.host.source_manifest["variants"]["dev"]["report"]
        self.mutate_json(path, lambda value: value["cases"].__setitem__("open-good", "PASS"))
        with self.assertRaisesRegex(restore.Refusal, "case_object"):
            self.prepare()
        self.assertFalse(self.host.mutations)

    def test_changed_received_copy_cannot_borrow_save_good_receipt(self):
        path = Path(self.host.source_manifest["variants"]["dev"]["received"])
        path.write_bytes(path.read_bytes() + b"changed")
        with self.assertRaises(restore.Refusal):
            self.prepare()
        self.assertFalse(self.host.mutations)

    def test_receiving_schema_is_structured_not_old_integer(self):
        path = self.host.source_manifest["variants"]["dev"]["receiving"]
        self.mutate_json(path, lambda value: value.__setitem__("schema", 3))
        with self.assertRaisesRegex(restore.Refusal, "schema_mismatch"):
            self.prepare()

    def test_exact_candidate_reservations_and_all_higher_attempts(self):
        path = self.host.args.version_ledger
        original = Path(path).read_bytes()
        mutations = (
            lambda value: value["entries"][-1].__setitem__("apk_sha256", "0" * 64),
            lambda value: value["entries"][-1].__setitem__("source_commit", "0" * 40),
            lambda value: value["entries"][-1].__setitem__("role", "other"),
            lambda value: value["entries"].append(copy.deepcopy(value["entries"][-1])),
            lambda value: value["entries"].append({"application_id": documents.PACKAGES[1], "version_code": 91,
                "state": "reserved", "role": "future-other-proof", "source_commit": saf.REVISION}),
            lambda value: value["entries"].__setitem__(slice(None), [entry for entry in value["entries"] if entry["version_code"] != 80]),
            lambda value: value["manifest_sha256"].pop(self.host.args.candidate_manifest))
        for change in mutations:
            Path(path).write_bytes(original)
            self.mutate_json(path, change)
            with self.assertRaises(restore.Refusal):
                self.prepare()
            self.assertFalse(self.host.mutations)
        Path(path).write_bytes(original)
        self.assertEqual(self.prepare().floor, 80)

    def test_raw_ledger_and_received_file_pins_rechecked_before_output_or_install(self):
        prepared = self.prepare()
        Path(self.host.args.version_ledger).write_bytes(b"changed after preflight")
        with self.assertRaisesRegex(restore.Refusal, "host_input_changed"):
            restore.run(self.host, prepared)
        self.assertFalse(prepared.output.exists())
        self.assertFalse(self.host.mutations)

    def test_receiver_bootstrap_root_provider_and_uid_guards(self):
        for scenario in ("bad-root", "provider-enabled"):
            self.host.scenario = scenario
            with self.assertRaises(restore.Refusal):
                self.prepare()
            self.assertFalse(self.host.mutations)
        self.host.scenario = "valid"
        package = documents.PACKAGES[1]
        self.host.write(self.host.package_root(package) / ("files/" + package + "/retained"), b"no repair")
        with self.assertRaisesRegex(restore.Refusal, "already_present"):
            self.prepare()
        self.assertEqual((self.host.package_root(package) / ("files/" + package + "/retained")).read_bytes(), b"no repair")

    def test_receiver_provider_uses_real_sdk36_scoped_audit_and_preserves_error(self):
        self.assertIsNotNone(self.prepare())
        original = self.host.command
        enabled = next(line for line in saf.PACKAGED_PROVIDER_TREE.splitlines() if ":enabled(" in line)
        trees = (
            saf.PACKAGED_PROVIDER_TREE.replace(enabled, enabled.replace("=false", "=true")),
            saf.PACKAGED_PROVIDER_TREE.replace(enabled + "\n", ""),
            saf.PACKAGED_PROVIDER_TREE.replace(enabled, enabled + "\n" + enabled),
            saf.PACKAGED_PROVIDER_TREE.replace(documents.AUTHORITY, documents.AUTHORITY + ".foreign"),
            saf.PACKAGED_PROVIDER_TREE.replace("          E: provider", enabled[4:] + "\n          E: provider")
                .replace(enabled + "\n", enabled.replace("=false", "=true") + "\n"),
        )
        for tree in trees:
            self.assertNotEqual(tree, saf.PACKAGED_PROVIDER_TREE)

            def command(argv, **options):
                if str(argv[0]).endswith("/aapt2"):
                    return saf.result(tree)
                return original(argv, **options)

            with self.subTest(tree=tree), patch.object(self.host, "command", side_effect=command):
                with self.assertRaisesRegex(restore.Refusal, "^receiver_provider_not_default_disabled$"):
                    self.prepare()
            self.assertFalse(self.host.mutations)
            self.assertFalse(Path(self.host.args.output).exists())

    def test_receiver_observer_needs_exact_build_and_fresh_binding(self):
        path = Path(self.host.args.ui_observer_build)
        original = path.read_bytes()
        self.mutate_json(path, lambda value: value.__setitem__("source_commit", "0" * 40))
        with self.assertRaisesRegex(restore.Refusal, "observer_source_binding"):
            self.prepare()
        path.write_bytes(original)
        prepared = self.prepare()
        self.host.ui_observer_install_fresh = lambda *args: {"format": "alkion-android-ui-binding/1", "run_id": SOURCE_RUN}
        with self.assertRaisesRegex(restore.Refusal, "observer_binding_invalid"):
            restore.run(self.host, prepared)
        self.assertFalse(any(value[0] == "install" for value in self.host.mutations))

    def test_provider_only_observes_complete_atomic_namespace_publications(self):
        prepared = self.prepare()
        prepared.output.mkdir(mode=0o700)
        evidence = restore.Evidence(self.host, prepared)
        self.host.pids[documents.PROVIDER] = 501  # Already running for variant 2.
        observed = []
        command = self.host.command
        parent = self.host.package_root(documents.PROVIDER) / "files/proof-runs"
        def observe(argv, **options):
            result = command(argv, **options)
            matching = sorted(root for root in parent.iterdir() if root.name in
                              (saf.RUN + "-dev", saf.RUN + "-supported")) if parent.is_dir() else []
            for root in matching:
                control = json.loads((root / "control.json").read_bytes())
                data = (root / "input.alkionbackup").read_bytes()
                self.assertEqual((control["length"], control["sha256"]), (len(data), documents.digest(data)))
            observed.append([root.name for root in matching])
            return result
        self.host.command = observe
        restore.seed_provider(evidence, "dev", first=False)
        restore.seed_provider(evidence, "supported", first=False)
        self.assertIn([], observed)
        self.assertIn([saf.RUN + "-dev"], observed)
        self.assertEqual(set(observed[-1]), {saf.RUN + "-dev", saf.RUN + "-supported"})
        self.assertFalse(list(parent.glob(".stage-*")))
        self.assertEqual(self.host.pids[documents.PROVIDER], 501)

    def test_failed_provider_input_retains_nonmatching_stage_and_partial(self):
        prepared = self.prepare()
        prepared.output.mkdir(mode=0o700)
        evidence = restore.Evidence(self.host, prepared)
        self.host.pids[documents.PROVIDER] = 501
        restore.seed_provider(evidence, "dev", first=False)
        command = self.host.command
        def fail_input(argv, **options):
            if options.get("input") is not None and "input.alkionbackup.partial-" in str(argv[-1]):
                command(argv, **{**options, "input": options["input"][:1]})
                return saf.result(b"", b"synthetic interrupted input", 1)
            return command(argv, **options)
        self.host.command = fail_input
        with self.assertRaisesRegex(restore.Refusal, "exclusive_write_failed"):
            restore.seed_provider(evidence, "supported", first=False)
        parent = self.host.package_root(documents.PROVIDER) / "files/proof-runs"
        self.assertFalse((parent / (saf.RUN + "-supported")).exists())
        stage = parent / (".stage-" + saf.RUN + "-supported")
        self.assertTrue((stage / "control.json").is_file())
        self.assertEqual(len(next(stage.glob("input.alkionbackup.partial-*")).read_bytes()), 1)
        self.assertTrue((parent / (saf.RUN + "-dev/input.alkionbackup")).is_file())
        self.assertEqual(self.host.pids[documents.PROVIDER], 501)

    def test_interrupt_budget_covers_all_native_gates_and_rejects_late_absence(self):
        for scenario in ("slow-gates", "late-absence", "deadline-absence", "native-timeout"):
            with self.subTest(scenario=scenario), tempfile.TemporaryDirectory(prefix="alkion-restore-budget-") as directory:
                host = FakeHost(Path(directory))
                with patch.dict(os.environ, ANDROID_USER_HOME=str(host.user)):
                    prepared = restore.prepare(host, host.args)
                    prepared.output.mkdir(mode=0o700)
                    evidence = restore.Evidence(host, prepared)
                    host.pids[documents.PACKAGES[1]] = 701
                    host.step = 3
                    command, timeouts, calls = host.command, [], []
                    started = self.clock.now
                    def delayed(argv, **options):
                        calls.append(list(map(str, argv)))
                        timeouts.append(options["timeout"])
                        index = len(calls)
                        if scenario == "native-timeout" and index == 5:
                            raise subprocess.TimeoutExpired(argv, options["timeout"], output=b"unknown kill stdout\x00", stderr=b"unknown kill stderr\xff")
                        result = command(argv, **options)
                        if scenario == "slow-gates":
                            self.clock.now += 8
                        elif scenario in ("late-absence", "deadline-absence") and index == 8:
                            self.clock.now += 31 if scenario == "late-absence" else 30
                        return result
                    host.command = delayed
                    host.namespace["command"] = delayed
                    value = {"pid": 701, "sequence": 3, "request_sha256": "a" * 64}
                    identity = {"pid": 701, "uid": prepared.metadata[documents.PACKAGES[1]]["uid"], "start_ticks": 100}
                    error = subprocess.TimeoutExpired if scenario == "native-timeout" else restore.Refusal
                    with self.assertRaises(error):
                        restore.interrupt(evidence, "dev", value, identity)
                    uncertain = json.loads(next(prepared.output.glob("*-death-uncertain.json")).read_bytes())
                    self.assertFalse(uncertain["death_proven"])
                    self.assertFalse(list(prepared.output.glob("*-death.json")))
                    self.assertTrue(all(0 < timeout <= 30 for timeout in timeouts))
                    if scenario == "slow-gates":
                        self.assertEqual(timeouts, [30, 22, 14, 6])
                        self.assertFalse(host.exact_cuts)
                    elif scenario == "native-timeout":
                        self.assertEqual(next(prepared.output.glob("*-cut-timeout.stdout")).read_bytes(), b"unknown kill stdout\x00")
                        self.assertEqual(next(prepared.output.glob("*-cut-timeout.stderr")).read_bytes(), b"unknown kill stderr\xff")
                        self.assertTrue(uncertain["kill_requested"])
                    else:
                        self.assertEqual(len(host.exact_cuts), 1)
                        self.assertGreaterEqual(self.clock.now - started, 30)

    def test_post_adoption_pins_are_checked_after_each_terminal_route(self):
        scenarios = {"post-complete-prep-alter": (9, "retained_preparation_changed"),
            "post-refusal-orphan-delete": (10, "retained_intent_or_orphan_changed"),
            "post-cold1-prep-delete": (11, "retained_preparation_changed"),
            "post-cold2-orphan-alter": (12, "retained_intent_or_orphan_changed")}
        for scenario, (sequence, reason) in scenarios.items():
            with self.subTest(scenario=scenario), tempfile.TemporaryDirectory(prefix="alkion-restore-post-adoption-") as directory:
                host = FakeHost(Path(directory))
                with patch.dict(os.environ, ANDROID_USER_HOME=str(host.user)):
                    prepared = restore.prepare(host, host.args)
                    host.scenario = scenario
                    with self.assertRaisesRegex(restore.Refusal, reason):
                        restore.run(host, prepared)
                    self.assertEqual(host.starts[-1][1], sequence)
                    state = json.loads((prepared.output / "run.json").read_bytes())
                    self.assertEqual(state["restore_phase"], "FAIL")
                    self.assertFalse(any(value[0] in ("clear", "uninstall", "force-stop") for value in host.mutations))

    def test_retained_pins_exempt_only_actual_bound_selected_database(self):
        prepared = self.prepare()
        prepared.output.mkdir(mode=0o700)
        evidence = restore.Evidence(self.host, prepared)
        self.host.current = documents.PACKAGES[1]
        self.host.flavor = "dev"
        self.host.step = 8
        fresh = self.host.fresh()
        canonical = self.host.package_root(self.host.current) / ("files/" + self.host.current)
        marker = canonical / ("profiles/" + PROFILE + "/selected-generation.json")
        self.host.write(marker, {"format": "alkion-selected-generation", "version": 1, "restore_id": SELECTED_RESTORE})
        (canonical / SELECTED_DATABASE).write_bytes(b"permitted selected runtime write")
        observed = restore.retained_after_adoption(evidence, "dev", fresh)
        self.assertEqual(observed["selected_database_relative"], SELECTED_DATABASE)
        intent = canonical / Path(SELECTED_DATABASE).with_name("intent.json")
        original = intent.read_bytes()
        for mutation in ("alter", "delete"):
            if mutation == "alter":
                intent.write_bytes(b"changed selected intent is never exempt")
            else:
                intent.unlink()
            with self.assertRaisesRegex(restore.Refusal, "retained_intent_or_orphan_changed"):
                restore.retained_after_adoption(evidence, "dev", fresh)
            self.host.write(intent, original)  # Independent synthetic fault setup.
        self.host.write(marker, {"format": "alkion-selected-generation", "version": 1, "restore_id": RAW_RESTORE})
        with self.assertRaisesRegex(restore.Refusal, "actual_selected_generation_changed"):
            restore.retained_after_adoption(evidence, "dev", fresh)

    def test_finished_peer_preparation_remains_pinned_during_other_variant(self):
        prepared = self.prepare()
        self.host.scenario = "post-peer-prep-alter"
        with self.assertRaisesRegex(restore.Refusal, "retained_preparation_changed"):
            restore.run(self.host, prepared)
        self.assertEqual(self.host.starts[-1][:2], (documents.PACKAGES[2], 1))
        state = json.loads((prepared.output / "run.json").read_bytes())
        self.assertEqual(state["restore_phase"], "FAIL")

    def test_source_range_needs_exact_independent_review_and_ancestry(self):
        base = "c" * 40
        self.host.driver["source_commit"] = base
        self.host.write(Path(self.host.args.receiver_driver), self.host.driver)
        changed = ["app/integration_test/android_restore_test.dart"]
        delta_sha = documents.digest(b"synthetic exact reviewed range\n")
        review = {"format": "alkion-independent-range-review/1", "result": "PASS", "reviewer": "independent-test-reviewer",
                  "base_source_commit": base, "source_commit": saf.REVISION, "changed_paths": changed, "diff_sha256": delta_sha}
        review_path = self.root / "range-review.json"
        self.host.write(review_path, review)
        transition = {key: review[key] for key in ("base_source_commit", "source_commit", "changed_paths", "diff_sha256")}
        transition.update(review_receipt=str(review_path), review_receipt_sha256=documents.digest(review_path.read_bytes()))
        self.host.write(Path(self.host.args.source_review), {"format": "alkion-restore-source-review/1", "result": "PASS",
            "source_commit": saf.REVISION, "transitions": [transition]})
        self.host.refresh_ledger()
        self.prepare()
        for scenario in ("not-descendant", "runtime-diff"):
            self.host.scenario = scenario
            with self.assertRaises(restore.Refusal):
                self.prepare()
        self.host.scenario = "valid"
        review_path.write_bytes(review_path.read_bytes() + b" ")
        with self.assertRaisesRegex(restore.Refusal, "range_review"):
            self.prepare()

    def test_exact_process_death_and_barrier_negatives_preserve_failure(self):
        # Each scenario runs a new complete temp receiver, without changing or
        # repairing a failed campaign to make the next control pass.
        scenarios = {"replacement": "replacement_or_pid_reuse", "kill-stuck": "death_timeout",
            "barrier-pass": "barrier_is_not_death_proof", "framework-failure": "framework_failure_preserved",
            "wrong-native-source": "compile_binding_mismatch", "changed-preparation": "preparation_bytes_changed",
            "missing-stage": "stage_or_early_identity_changed", "new-pending": "pending_id_changed",
            "refusal-mutated": "refusal_not_preserved:nonempty", "same-completed-id": "completed_callback_not_refused",
            "cold-mutated": "cold_baseline_changed", "pid-reuse": "distinct_cold_pid_required",
            "prior-receipt-change": "prior_hash_chain_changed", "ingress-change": "ingress_changed",
            "kernel-start-change": "same_launched_owned_process"}
        for scenario, refusal in scenarios.items():
            with self.subTest(scenario=scenario), tempfile.TemporaryDirectory(prefix="alkion-restore-negative-") as directory:
                host = FakeHost(Path(directory))
                with patch.dict(os.environ, ANDROID_USER_HOME=str(host.user)):
                    prepared = restore.prepare(host, host.args)
                    host.scenario = scenario
                    with self.assertRaisesRegex((restore.Refusal, host.Refusal), refusal):
                        restore.run(host, prepared)
                    state = json.loads((prepared.output / "run.json").read_bytes())
                    self.assertEqual(state["restore_phase"], "FAIL")
                    self.assertTrue(list(prepared.output.glob("*-run-snapshot.json")))
                    self.assertFalse(any(call[0] in ("clear", "uninstall", "force-stop") for call in host.mutations))

    def test_timeout_keeps_binary_partial_transport_and_private_files(self):
        prepared = self.prepare()
        self.host.scenario = "install-timeout"
        with self.assertRaises(subprocess.TimeoutExpired):
            restore.run(self.host, prepared)
        self.assertEqual(next(prepared.output.glob("*-timeout-partial-stdout")).read_bytes(), b"partial native stdout\x00")
        self.assertEqual(next(prepared.output.glob("*-timeout-partial-stderr")).read_bytes(), b"partial stderr\xff")
        self.assertEqual(json.loads((prepared.output / "run.json").read_bytes())["restore_phase"], "FAIL")

    def test_timeout_retains_unfinished_adapter_partial(self):
        prepared = self.prepare()
        self.host.scenario = "adapter-timeout"
        with self.assertRaisesRegex(restore.Refusal, "receipt_timeout"):
            restore.run(self.host, prepared)
        path = self.host.package_root(documents.PACKAGES[1]) / (restore.protocol_root(prepared) + "/receipt-001.json.partial-1")
        self.assertEqual(path.read_bytes(), b"{incomplete")
        self.assertTrue(any(path.read_bytes() == b"{incomplete" for path in prepared.output.glob("*-retained-tree-file.stdout")))

    def test_preflight_timeout_carries_raw_bytes_without_owning_output(self):
        self.host.scenario = "preflight-timeout"
        with self.assertRaises(subprocess.TimeoutExpired) as caught:
            self.prepare()
        self.assertEqual(caught.exception.restore_partial_stdout, b"partial preflight\x00")
        self.assertEqual(caught.exception.restore_timeout_receipt["phase"], "prepare")
        self.assertFalse(Path(self.host.args.output).exists())
        self.assertFalse(self.host.mutations)

    def test_exclusive_real_files_refuse_replay_and_link(self):
        prepared = self.prepare()
        prepared.output.mkdir(mode=0o700)
        evidence = restore.Evidence(self.host, prepared)
        files = restore.ingress(evidence, "dev")
        _, request, _ = restore.request(evidence, "dev", 1, files)
        with self.assertRaisesRegex(restore.Refusal, "exclusive_write_failed"):
            restore.request(evidence, "dev", 1, files)
        root = self.host.package_root(documents.PACKAGES[1]) / restore.protocol_root(prepared)
        self.assertEqual((root / "request-001.json").read_bytes(), request)
        (root / "outside-link").symlink_to(self.root / "source-inputs.json")
        with self.assertRaisesRegex(restore.Refusal, "tree_inventory_failed"):
            restore.tree_pin(evidence, documents.PACKAGES[1], restore.protocol_root(prepared))

    def test_build_contract_has_only_fixed_entry_and_valid_defines(self):
        values = {"ALKION_FLAVOR": "dev", "ALKION_PROOF_RUN": saf.RUN, "ALKION_PROOF_SOURCE": saf.REVISION, "ALKION_PROOF_VERSION": "90"}
        argv = restore.restore_build_arguments(values)
        self.assertEqual(argv[argv.index("--target") + 1], "integration_test/android_restore_test.dart")
        for key, value in (("ALKION_FLAVOR", "foreign"), ("ALKION_PROOF_RUN", ""), ("ALKION_PROOF_SOURCE", "bad"),
                           ("ALKION_PROOF_VERSION", "90; arbitrary")):
            with self.assertRaises(restore.Refusal):
                restore.restore_build_arguments({**values, key: value})


if __name__ == "__main__":
    unittest.main(verbosity=2)
