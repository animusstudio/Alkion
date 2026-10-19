"""Host-only capability protocol controls. No actual Git/FVM/ADB/build runs.

Native examples below are synthetic parser inputs following the local API36
read-only diagnostics and pinned plugin21 contracts, not installed proof. The
accepted Dart suite owns real SQLite oracle coverage. Existing harness guards
are loaded without its entry point and exercised against private fake transport.
"""

import copy
import base64
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

sys.dont_write_bytecode = True
import android_synthetic_capabilities as capability
import android_synthetic_publish as publish
import android_synthetic_publish_self_test as publisher_fake
import android_synthetic_ui as observer


RUN = "1" * 32
SOURCE = "a" * 40
CERT = "b" * 64
UTC = "2026-10-18T12:00:00.000Z"
PNG = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jE1sAAAAASUVORK5CYII=")


def response(stdout="", stderr="", code=0):
    return SimpleNamespace(stdout=stdout, stderr=stderr, returncode=code)


def utc(seconds):
    return datetime.fromtimestamp(seconds, timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def row(profile, kind, key, value, revision=1):
    return {"profile_id": profile, "generation": 1, "state_kind": kind, "state_key": key,
            "revision": revision, "status": "issued" if key == "notification-action" else "active",
            "updated_at": UTC, "payload_bytes": list(capability.canonical(value))}


def snapshot(flavor="dev"):
    package = capability.VARIANTS[flavor]
    profile = "12345678-1234-4234-8234-" + ("1" if flavor == "dev" else "2") * 12
    draft = {"draftId": "old-draft", "name": "Old synthetic rest", "restStart": UTC, "restTotal": 600,
             "restEndedAt": None, "focusedSetId": "planned", "rirPromptSetId": None,
             "blocks": [{"workingSets": [{"id": "planned", "done": False, "weight": "82.5", "reps": 5}]}]}
    timer = {"restStart": UTC, "restTotal": 600, "restEndedAt": None}
    action = {"format": "alkion-notification-action/1", "application_id": package, "profile_id": profile,
              "generation": 1, "draft_id": draft["draftId"], "rest_start": UTC, "timer_revision": 1,
              "token": "00000000-0000-4000-8000-000000000001"}
    return {"application_id": package, "profile_id": profile, "installation_id": "installation-" + flavor,
            "generation": 1, "database_relative": "profiles/" + profile + "/alkion.sqlite",
            "identity_bytes": [0, 255, 9], "original_bytes": [255, 0, 7],
            "inventory": {"data_operations": [{"id": "old-op", "bytes": [0, 255]}],
                          "source_artifacts": [{"id": "old-source", "bytes": [17, 0, 250]}],
                          "local_state": [row(profile, "draft", "active", draft), row(profile, "timer", "active", timer),
                                          row(profile, "timer", "notification-action", {"action": action})]}}


def initial_report(states):
    return {"format": "alkion-android-run/1", "phase": "lifecycle-initial", "initial_lifecycle_phase": "PASS",
            "overall": "IN_PROGRESS", "source_commit": SOURCE, "base_source_commit": SOURCE,
            "run_id": RUN, "avd": "capability-proof", "serial": "emulator-5560", "pending": {},
            "installed": {package: {"version_code": 44} for package in capability.VARIANTS.values()},
            "lifecycle": {package: {"initial_lifecycle": "PASS", "finish": {
                "format": "alkion-android-lifecycle-checkpoint/1", "phase": "finish", "run_id": RUN,
                "application_id": package, "complete": True, "closed": True, "result": "PASS", "draft": None,
                "profile_id": state["profile_id"], "installation_id": state["installation_id"], "generation": 1,
                "database_relative": state["database_relative"], "state_digest": capability.state_sha(state)}}
                for package, state in states.items()}}


def step(prior_raw, before, flavor, case, phase, version):
    prior = json.loads(prior_raw)
    return {"format": capability.FORMAT, "run_id": RUN, "source_commit": SOURCE, "prior_source_commit": prior["source_commit"],
            "application_id": capability.VARIANTS[flavor], "variant": flavor, "case_id": case, "phase": phase,
            "version_code": version, "prior_version_code": prior.get("version_code", 44), "consumed_version_floor": version - 1,
            "profile_id": before["profile_id"], "generation": 1, "prior_report_sha256": capability.sha(prior_raw),
            "prior_state_digest": capability.state_sha(before)}


def report_for(identity, before, now):
    after = copy.deepcopy(before)
    phase, case = identity["phase"], identity["case_id"]
    old = capability.local_rows(before)
    if phase != "preserve":
        draft = capability.payload(after, "draft")
        timer = capability.payload(after, "timer")
        if phase == "prepare":
            prefix = "capability-" + RUN + "-" + case
            draft.update(draftId=prefix, name="Synthetic capability " + RUN + " " + case + " " + identity["application_id"],
                         focusedSetId=prefix + "-workflow-planned", rirPromptSetId=None)
            draft["blocks"][0]["workingSets"][-1].update(id=prefix + "-workflow-planned", done=False)
        else:
            planned = draft["blocks"][0]["workingSets"][-1]
            planned["done"] = True
            draft.update(focusedSetId=None, rirPromptSetId=planned["id"])
        draft.update(restStart=utc(now), restTotal=600, restEndedAt=None)
        timer.update(restStart=draft["restStart"], restTotal=600, restEndedAt=None)
        action = {"format": "alkion-notification-action/1", "application_id": identity["application_id"],
            "profile_id": before["profile_id"], "generation": 1, "draft_id": draft["draftId"], "rest_start": draft["restStart"],
            "timer_revision": old[("timer", "active")]["revision"] + 1,
            "token": "00000000-0000-4000-8000-" + format(identity["version_code"], "012x")}
        replacements = {("draft", "active"): draft, ("timer", "active"): timer, ("timer", "notification-action"): {"action": action}}
        after["inventory"]["local_state"] = [dict(row(before["profile_id"], kind, key, replacements[(kind, key)], old[(kind, key)]["revision"] + 1),
                                                 updated_at=utc(now)) for kind, key in replacements]
    new = capability.local_rows(after)
    delta = {kind + "/" + key: {"before_sha256": capability.state_sha(old[(kind, key)]),
             "after_sha256": capability.state_sha(new[(kind, key)]),
             "revision_delta": new[(kind, key)]["revision"] - old[(kind, key)]["revision"]}
             for kind, key in capability.MUTABLE if old[(kind, key)] != new[(kind, key)]}
    result = {**identity, "complete": True, "closed": True, "result": "PASS", "failures": [],
        "scope": "closed synthetic SQL fixture/checkpoint only", "native_proof": "UNRUN: host routing is separate",
        "installation_id": before["installation_id"], "snapshot": after, "state_digest": capability.state_sha(after),
        "checkpoint_time": utc(now + 1), "fixture_delta": delta if phase == "prepare" else {},
        "observed_delta": {} if phase == "prepare" else delta,
        "plugin_capabilities": {"format": capability.PLUGIN_FORMAT, "notifications_enabled": phase == "prepare" or case in ("exact", "inexact"),
                                "can_schedule_exact_notifications": case != "inexact", "queried_at": utc(now + 2)}}
    return result


def load_harness():
    path = Path(__file__).with_name("android_synthetic.sh")
    text = path.read_text().split("<<'PY'\n", 1)[1].rsplit("\nPY", 1)[0]
    text = text[:text.index("\nparser = argparse.ArgumentParser")]
    namespace = {"__name__": "capability_fake_harness"}
    with patch.object(sys, "argv", [str(path), str(path)]):
        exec(compile(text, str(path), "exec"), namespace)
    return namespace


class Host:
    def __init__(self, root):
        self.root = root; self.calls = []; self.mutations = []; self.unknown_after_grant = False
        self.grant_becomes_unknown = True; self.fail_build = False; self.publish_collision = False
        self.APP = root / "checkout/app"
        (self.APP / "integration_test").mkdir(parents=True)
        producer = Path(__file__).parent.parent / capability.HELPER
        (self.APP / capability.HELPER).write_bytes(producer.read_bytes())
        self.user = root / "user"; self.user.mkdir()
        self.sdk = root / "sdk"
        (self.sdk / "platform-tools").mkdir(parents=True)
        (self.sdk / "platform-tools/adb").touch()
        (self.sdk / "platforms/android-36").mkdir(parents=True)
        (self.sdk / "platforms/android-36/android.jar").touch()
        avd = root / "avds/capability-proof.avd"; avd.mkdir(parents=True)
        (avd.parent / "capability-proof.ini").write_text("path=" + str(avd) + "\n")
        (avd / "config.ini").write_text("abi.type=x86_64\ntag.id=default\nimage.sysdir.1=system-images/android-36/default/x86_64/\n")
        self.receipt = {"format": "alkion-android-disposable/1", "purpose": "synthetic-only", "fresh": True, "run_id": RUN,
            "serial": "emulator-5560", "avd": "capability-proof", "api": 36, "abi": "x86_64",
            "system_image": "system-images;android-36;default;x86_64", "avd_home": str(avd.parent), "android_user_home": str(self.user)}
        self.args = SimpleNamespace(serial="emulator-5560", avd="capability-proof", sdk=self.sdk, receipt=str(root / "disposable.json"),
            output=str(root / "output"), driver_run=str(root / "driver/run.json"), updates_run=str(root / "updates/run.json"),
            base_run=str(root / "lifecycle/run.json"), version_ledger=str(root / "versions.json"), attempt_manifests=())
        self.states = {package: snapshot(flavor) for flavor, package in capability.VARIANTS.items()}
        self.installed = {}; self.metadata = {}
        namespace = load_harness(); namespace.update(APP=self.APP, command=self.command)
        for name, value in namespace.items():
            if callable(value) and name != "command": setattr(self, name, value)
        self.namespace = namespace
        self.make_chain()
        # Synthetic reviewed-publisher receipt; the real binder admits it.
        publisher_fake.copy_sources(self.APP)
        self.runas = publisher_fake.FakeRunAs(root)
        self.args.publisher_build = str(publisher_fake.fake_build(root / "publisher-build", self.APP, SOURCE))
        self.args._publisher = publish.load_build(self, self.args, self.args.publisher_build, SOURCE)

    @staticmethod
    def write(path, value):
        path.parent.mkdir(parents=True, mode=0o700, exist_ok=True)
        path.write_bytes(value if isinstance(value, bytes) else capability.canonical(value) + b"\n")
        path.chmod(0o600)

    def package(self, package):
        directory = self.root / "packages" / package
        directory.mkdir(parents=True, mode=0o700, exist_ok=True)
        return directory

    def artifact(self, path, package, version):
        self.write(path, {"package": package, "version": version})
        return {"package": package, "version_code": version, "apk_sha256": capability.sha(path.read_bytes()), "certificate_sha256": CERT}

    def add_observer(self):
        fixture = self.APP / "tool/android_synthetic_ui"; fixture.mkdir(parents=True)
        for name in ("AndroidManifest.xml", "HierarchyInstrumentation.java"):
            (fixture / name).write_bytes((Path(__file__).parent / "android_synthetic_ui" / name).read_bytes())
        root = Path(self.args.base_run).parent / "ui-observer"
        facts = self.artifact(root / "synthetic-ui-observer.apk", observer.PACKAGE, observer.VERSION)
        self.installed[observer.PACKAGE] = facts
        self.metadata[observer.PACKAGE] = {"uid": 10004, "version_code": observer.VERSION}
        record = {"format": "alkion-android-ui-build/1", "source_commit": SOURCE,
                  "native_source_sha256": observer.native_digest(self), "apk": facts}
        self.write(root / "build.json", record)
        self.lifecycle["ui_observer"] = {"format": "alkion-android-ui-binding/1", "run_id": RUN,
            "serial": self.args.serial, "avd": self.args.avd, "uid": 10004, "build": record}
        self.write(Path(self.args.base_run), self.lifecycle)
        self.ledger["manifest_sha256"][self.args.base_run] = capability.sha(Path(self.args.base_run).read_bytes())
        self.write(Path(self.args.version_ledger), self.ledger)
        self.args.attempt_manifests_json = "[]"; self.args.jit_build_budget = 120

    def transport(self, argv, **options):
        result = self.command(argv, **options)
        if options.get("binary"):
            result.stdout = result.stdout.encode() if isinstance(result.stdout, str) else result.stdout
            result.stderr = result.stderr.encode() if isinstance(result.stderr, str) else result.stderr
        return result

    def make_chain(self):
        driver = {"format": "alkion-android-run/1", "phase": "driver", "driver_phase": "PASS", "overall": "IN_PROGRESS",
            "pending": {}, "run_id": RUN, "serial": self.args.serial, "avd": self.args.avd, "api": 36, "abi": "x86_64",
            "source_commit": SOURCE, "driver_contract": "alkion-driver/2", "installed": {}, "driver": {}}
        updates = {"format": "alkion-android-run/1", "phase": "updates", "updates_phase": "PASS", "overall": "IN_PROGRESS", "pending": {},
            "run_id": RUN, "serial": self.args.serial, "avd": self.args.avd, "source_commit": SOURCE, "base_source_commit": SOURCE,
            "base_driver_contract": "alkion-driver/2", "installed": {}, "updates": {}}
        lifecycle = initial_report(self.states)
        for index, package in enumerate(capability.PACKAGES):
            flavor = "neighbor" if not index else "dev" if index == 1 else "supported"
            path = self.root / "driver" / ("neighbor-build/synthetic-neighbor.apk" if not index else "driver-" + flavor + ".apk")
            facts = self.artifact(path, package, 1 if not index else 37)
            driver["installed"][package] = facts
            self.metadata[package] = {"uid": 10000 + index, "version_code": 1 if not index else 44}
            if index:
                driver["driver"][flavor] = {"format": "alkion-android-driver-proof/1", "run_id": RUN, "application_id": package,
                    "complete": True, "result": "PASS", "cases": {case: "PASS" for case in self.namespace["CASES"]}}
                verified = self.artifact(self.root / "updates" / (flavor + "-verify.apk"), package, 39)
                updates["installed"][package] = verified
                prior = dict(lifecycle["lifecycle"][package]["finish"], format="alkion-android-update-proof/1")
                meta = {"uid": 10000 + index, "version_code": 39}
                updates["updates"][package] = {"seed": dict(prior, phase="seed"), "verify": dict(prior, phase="verify"),
                    "seed_metadata": dict(meta, version_code=38), "verify_metadata": meta, "verify_apk": verified,
                    "driver_and_neighbor_bytes_unchanged": True, "wrong_signer": {"exit_code": 1, "stderr": "INSTALL_FAILED_UPDATE_INCOMPATIBLE",
                        "metadata_before": meta, "metadata_after": meta, "covered_bytes_before": "c" * 64, "covered_bytes_after": "c" * 64,
                        "candidate": dict(verified, version_code=40, certificate_sha256="d" * 64)}}
                current = self.artifact(self.root / "lifecycle" / (flavor + "-finish.apk"), package, 44)
                lifecycle["installed"][package] = current
                life = lifecycle["lifecycle"][package]
                life.update(prepare=dict(life["finish"], phase="prepare"), rest=dict(life["finish"], phase="rest"),
                            peer_covered_bytes={peer: {"before": "e" * 64, "after": "e" * 64}
                                                for peer in capability.VARIANTS.values() if peer != package})
                self.write(self.package(package) / ("files/android-lifecycle/" + RUN + "/finish-snapshot.json"), self.states[package])
                self.write(self.package(package) / ("files/android-proof/" + RUN + "/driver-report.json"), driver["driver"][flavor])
                normal = self.package(package) / ("files/" + package)
                for relative in (self.states[package]["database_relative"], "local-profile.json", "original-source.bin"):
                    self.write(normal / relative, b"synthetic immutable bytes\x00\xff")
                self.installed[package] = current
            else:
                lifecycle["installed"][package] = updates["installed"][package] = self.installed[package] = facts
                self.write(self.package(package) / "files/synthetic-neighbor.json", {"format": "alkion-synthetic-neighbor/1", "run_id": RUN,
                           "sentinel": "synthetic-only-keep-exact"})
        self.driver, self.updates, self.lifecycle = driver, updates, lifecycle
        self.write(Path(self.args.receipt), self.receipt)
        for key, value in (("driver_run", driver), ("updates_run", updates), ("base_run", lifecycle)):
            self.write(Path(getattr(self.args, key)), value)
        self.ledger = {"format": "alkion-android-version-ledger/1", "complete": True, "coverage": "all-attempted-and-reserved-in-disposable-run",
            "run_id": RUN, "serial": self.args.serial, "avd": self.args.avd,
            "manifest_sha256": {getattr(self.args, key): capability.sha(Path(getattr(self.args, key)).read_bytes()) for key in ("driver_run", "updates_run", "base_run")},
            "entries": [{"application_id": package, "version_code": version, "state": "installed", "source_commit": SOURCE,
                         "role": "retained-initial-chain"} for package, version in sorted(
                             capability.recorded_codes(driver) | capability.recorded_codes(updates) | capability.recorded_codes(lifecycle))]}
        self.write(Path(self.args.version_ledger), self.ledger)

    def command(self, argv, *, binary=False, input=None, check=True, timeout=30, env=None):
        argv = list(map(str, argv)); self.calls.append(argv)
        if argv[0] == "git":
            if argv[-1] == "HEAD": return response(SOURCE + "\n")
            if "status" in argv: return response("")
            if "merge-base" in argv: return response("")
            if "diff" in argv: return response("app/tool/android_synthetic_capabilities.py\n")
        if argv[0].endswith("/aapt2"):
            value = json.loads(Path(argv[-1]).read_bytes())
            return response("package: name='" + value["package"] + "' versionCode='" + str(value["version"]) + "'\n")
        if argv[0].endswith("/java"):
            return response("Signer #1 certificate SHA-256 digest: " + CERT + "\n")
        if argv[0] == "make" and self.fail_build:
            return response("retained partial fake build output\n", "injected host-only builder failure\n", 2)
        if argv[0].endswith("/adb"):
            assert argv[1:3] == ["-s", self.args.serial]
            tail = argv[3:]
            if tail == ["get-state"]: return response("device\n")
            if tail == ["emu", "avd", "name"]: return response(self.args.avd + "\nOK\n")
            if tail[:2] == ["shell", "-T"]:
                assert len(tail) == 3, tail
                tail = ["shell", tail[2]]
            elif tail[0] == "exec-out":
                # Raw exec-out never forwards host stdin and merges stderr into
                # stdout with exit status 0. A blocked input write times out.
                value = self.command([*argv[:3], "shell", tail[1]], binary=True, input=b"", check=False, timeout=timeout)
                if input:
                    raise subprocess.TimeoutExpired(argv, timeout, output=value.stdout + value.stderr, stderr=b"")
                merged = value.stdout + value.stderr
                return response(merged if binary else merged.decode(), b"" if binary else "", 0)
            if tail[0] == "shell":
                remote = shlex.split(tail[1])
                if remote[0] == "getprop":
                    return response({"ro.kernel.qemu": "1", "ro.build.version.sdk": "36", "ro.product.cpu.abi": "x86_64", "sys.boot_completed": "1"}[remote[1]] + "\n")
                if remote[:2] == ["pm", "path"]: return response("package:/data/app/fake/" + remote[2] + "/base.apk\n")
                if remote[:1] == ["sha256sum"]:
                    package = remote[1].split("/")[-2]
                    return response(self.installed[package]["apk_sha256"] + "  " + remote[1] + "\n")
                if remote[:2] == ["pm", "list"]:
                    return response("package:" + remote[-1] + " uid:" + str(self.metadata[remote[-1]]["uid"]) + "\n")
                if remote[:2] == ["dumpsys", "package"]:
                    return response("versionCode=" + str(self.metadata[remote[-1]]["version_code"]) +
                        "\n  User 0: installed=true stopped=false\n    android.permission.POST_NOTIFICATIONS: granted=true, flags=[ USER_SET ]\n")
                if remote == ["cmd", "package", "help"]: return response("grant revoke clear-permission-flags\n")
                if remote == ["cmd", "appops", "help"]: return response("set [--user USER] get [--user USER]\n")
                if remote[:3] == ["cmd", "appops", "get"]:
                    operation = remote[-1]
                    return response("No operations.\nDefault mode: default\n" if self.unknown_after_grant else "Uid mode: " + operation + ": allow\n")
                if remote[:2] == ["pm", "grant"]:
                    self.mutations.append(remote); self.unknown_after_grant = self.grant_becomes_unknown; return response()
                if remote[:1] == ["pidof"]: return response("", code=1)
                if remote[:1] == ["run-as"]:
                    directory = self.package(remote[1]); program = remote[2:]
                    assert not any(re.search(r"(?:^|[;&|(\s])ln\s", word) for word in program), program
                    if self.runas.handles(program):
                        if self.publish_collision and program[2] == publish.PUBLISH:
                            self.write(directory / program[-1], b"existing final must survive")
                        stdout, stderr, code = self.runas.run(remote[1], self.metadata[remote[1]]["uid"], directory, program, input)
                        return response(stdout if binary else stdout.decode(), stderr if binary else stderr.decode(), code)
                    if program[:2] == ["/system/bin/sh", "-c"]:
                        completed = subprocess.run(["/bin/sh", *program[1:]], cwd=directory, input=input, capture_output=True)
                    else:
                        completed = subprocess.run(program, cwd=directory, input=input, capture_output=True)
                    return response(completed.stdout if binary else completed.stdout.decode(), completed.stderr if binary else completed.stderr.decode(), completed.returncode)
            raise AssertionError("unexpected fake Android command: " + repr(tail))
        raise AssertionError("unexpected fake host command: " + repr(argv))


class CampaignHost(Host):
    """Fake native protocol, exercising the actual complete host route.

    Reports are synthetic producer-shaped inputs, never evidence of Dart/SQL or
    Android execution. Native command order, update floors and staged raw input
    hashes are checked here; native format binding has separate refusal tests.
    """
    def __init__(self, root):
        super().__init__(root)
        self.clock = 0.0; self.grant_becomes_unknown = False
        self.build_seconds = 2; self.intent_uid_delta = 0
        self.permission = {package: True for package in capability.VARIANTS.values()}
        self.exact = {package: True for package in capability.VARIANTS.values()}
        self.flags = {package: True for package in capability.VARIANTS.values()}
        self.active = {}; self.dialog = set(); self.current_apks = {}; self.logging = set(); self.logged_clicks = []
        self.kill_calls = []; self.query_reports = []; self.session_open = set(); self.observer_wrong_nonce = False
        self.observer_missing_readiness = False
        self.app_pid = lambda args, package: self.active.get(package)
        self.ordinary_kill = self.kill
        self.ui_document = self.attested_document
        self.ui_tap = self.tap
        self.wait_ui_label = lambda *args: None
        self.wait_session_ui = lambda *args: None

    def kill(self, args, package, uid, output):
        assert uid == self.metadata[package]["uid"] and output == Path(self.args.output)
        self.kill_calls.append((package, uid)); self.active.pop(package, None); self.clock += 1

    def tap(self, args, output, name, label):
        if label.startswith("Log set"):
            assert label == "Log set 2 · 82.5kg × 5"
            package, = self.active
            self.logging.add(package); self.logged_clicks.append(package)
        else:
            assert label in ("Resume workout", "Minimize")
            package, = self.active
            if label == "Resume workout": self.session_open.add(package)
            else: self.session_open.discard(package)
        self.clock += 0.1

    def document(self, args, output, name, *, expected_package=None):
        package, = self.active
        owner = "com.android.permissioncontroller" if package in self.dialog else package
        assert expected_package in (None, owner)
        tree = ET.Element("hierarchy", rotation="0")
        frame = ET.SubElement(tree, "node", {"package": owner, "bounds": "[0,0][1080,2400]"})
        def node(text, resource, bounds, clickable=False):
            ET.SubElement(frame, "node", {"package": owner, "text": text, "resource-id": resource,
                                         "clickable": str(clickable).lower(), "bounds": bounds})
        if package in self.dialog:
            label = "Alkion Dev" if package.endswith(".dev") else "Alkion"
            node('Allow ' + label + ' to send you notifications?', owner + ':id/permission_message', '[0,0][200,100]')
            node('Don’t allow', owner + ':id/permission_deny_button', '[0,100][200,200]', True)
        else:
            node(capability.INEXACT_MESSAGE if self.permission[package] else capability.DENIED_MESSAGE, '', '[0,400][1080,500]')
            if package in self.session_open:
                node('Log set 2 · 82.5kg × 5', '', '[0,100][200,200]', True)
                node('Minimize', '', '[0,200][200,300]', True)
            else:
                node('Resume workout', '', '[0,0][200,100]', True)
        for element in tree.iter('node'):
            for key, value in {'text': '', 'content-desc': '', 'resource-id': '', 'class': 'android.view.View',
                               'clickable': 'false', 'enabled': 'true', 'visible-to-user': 'true'}.items():
                element.attrib.setdefault(key, value)
        return tree

    def attested_document(self, *args, **kwargs):
        # Legacy direct-module controls use an already-parsed fake observation;
        # facade controls above still obtain these attributes from the real
        # observer parser, never from this convenience wrapper.
        tree = self.document(*args, **kwargs)
        for node in tree.iter('node'):
            node.set('observer-display-width','1080');node.set('observer-display-height','2400')
        return tree

    def mirror(self, package):
        entries = []
        if self.permission[package]:
            state = self.states[package]; draft, end = capability.rest(state)
            entries = [{"id": 4101, "title": draft["name"], "payload": json.dumps(capability.payload(state, "timer", "notification-action")["action"]),
                        "scheduleMode": "exactAllowWhileIdle" if self.exact[package] else "inexactAllowWhileIdle",
                        "timeZoneName": "UTC", "scheduledDateTime": utc(end)[:-1]}]
        root = ET.Element("map"); ET.SubElement(root, "string", name="scheduled_notifications").text = json.dumps(entries)
        self.write(self.package(package) / "shared_prefs/scheduled_notifications.xml", ET.tostring(root))

    def command(self, argv, **options):
        words = list(map(str, argv))
        if words[0] == "make":
            self.calls.append(words)
            assert words[3] == "android-synthetic-capability-apk"
            inputs = dict(item.split("=", 1) for item in words[4:])
            args = capability.capability_build_arguments(inputs)
            assert args[:4] == ["fvm", "flutter", "build", "apk"]
            package = capability.VARIANTS[inputs["ALKION_FLAVOR"]]
            target = self.APP / ("build/app/outputs/flutter-apk/app-" + inputs["ALKION_FLAVOR"] + "-debug.apk")
            self.write(target, {"package": package, "version": int(inputs["ALKION_PROOF_VERSION"]), "inputs": inputs})
            self.clock += self.build_seconds
            return response("host-only fake build\n")
        if words[0].endswith("/adb"):
            tail = words[3:]
            remote = shlex.split(tail[1]) if tail[0] in ("shell", "exec-out") else []
            if tail == ["exec-out", "screencap", "-p"]:
                self.calls.append(words); return response(PNG, b"")
            if remote[:2] == ["am", "instrument"]:
                self.calls.append(words)
                values = {remote[index + 1]: remote[index + 2] for index, value in enumerate(remote) if value == "-e"}
                tree = self.document(self.args, None, None, expected_package=values["expected_package"])
                raw = ET.tostring(tree)
                receipt = {"format": "alkion-android-ui-observation/1", "diagnostic_schema": "alkion-ui-window-facts/1", **values, "complete": True, "result": "PASS",
                    "observer_package": observer.PACKAGE, "observer_uid": 10004, "observer_version": observer.VERSION,
                    "root_package": values["expected_package"], "display_id": 0, "window_id": 7, "window_type": 3,
                    "window_active": True, "window_focused": True, "rotation": 0, "width": 1080, "height": 2400,
                    "elapsed_ms": 20, "node_count": len(list(tree.iter('node'))), "xml_length": len(raw),
                    "xml_sha256": observer.digest(raw), "captured_at": datetime.now(timezone.utc).isoformat().replace('+00:00','Z')}
                labels = sum(node.get("visible-to-user") == "true" and any(node.get(key, "").strip(" \t\r\n")
                    for key in ("text", "content-desc")) for node in tree.iter('node'))
                receipt.update(readiness="visible-label" if values["expected_package"] in capability.VARIANTS.values()
                    else "structural", visible_label_count=labels, sample_count=1, candidate_sample=1)
                receipt["samples"] = [{"index": 1, "cache_cleared": True, "root_available": True, "ready": True,
                "candidate_complete": True, "outcome": "complete", "stage": "complete", "exception": None, "exception_class": None,
                "observed": ["cache_cleared", "root_available", "root_package", "node_window_id", "window_present",
                    "window_id", "window_type", "display_id", "window_active", "window_focused"],
                "root_package": values["expected_package"], "node_window_id": 7, "window_present": True, "window_type": 3,
                "display_id": 0, "window_active": True, "window_focused": True,
                    "elapsed_ms": 15, **{key: receipt[key] for key in
                        ("node_count", "visible_label_count", "window_id", "xml_length", "xml_sha256")}}]
                if self.observer_missing_readiness: del receipt["readiness"]
                if self.observer_wrong_nonce: receipt["request_id"] = "f" * 32
                target = self.package(observer.PACKAGE) / ('files/observations/' + RUN + '/' + values['request_id'])
                self.write(target / 'receipt.json', receipt); self.write(target / 'hierarchy.xml', raw)
                return response('INSTRUMENTATION_CODE: -1\n')
            if tail[:2] == ["install", "-r"]:
                self.calls.append(words); self.mutations.append(tail)
                path = Path(tail[2]); value = json.loads(path.read_bytes()); package = value["package"]
                assert package not in self.active and value["version"] > self.metadata[package]["version_code"]
                self.current_apks[package] = value
                self.installed[package] = {"package": package, "version_code": value["version"], "apk_sha256": capability.sha(path.read_bytes()), "certificate_sha256": CERT}
                self.metadata[package]["version_code"] = value["version"]
                return response("Success\n")
            if remote[:2] == ["dumpsys", "package"] and remote[-1] in self.permission:
                self.calls.append(words); package = remote[-1]
                return response("versionCode=" + str(self.metadata[package]["version_code"]) + "\n  User 0: installed=true stopped=false\n    android.permission.POST_NOTIFICATIONS: granted=" + str(self.permission[package]).lower() + ", flags=[" + (" USER_SET " if self.flags[package] else "") + "]\n")
            if remote[:3] == ["cmd", "appops", "get"]:
                self.calls.append(words); package, operation = remote[-2:]
                return response("Uid mode: " + operation + ": " + ("allow" if (self.permission[package] if operation == "POST_NOTIFICATION" else self.exact[package]) else "ignore" if operation == "POST_NOTIFICATION" else "deny") + "\n")
            if remote[:2] == ["pm", "grant"]:
                self.calls.append(words); self.mutations.append(remote); self.permission[remote[-2]] = True; return response()
            if remote[:2] == ["pm", "revoke"]:
                self.calls.append(words); self.mutations.append(remote); package = remote[-2]
                self.permission[package] = False; self.active.pop(package, None); self.mirror(package); return response()
            if remote[:2] == ["pm", "clear-permission-flags"]:
                self.calls.append(words); self.mutations.append(remote); self.flags[remote[4]] = False; return response()
            if remote[:3] == ["cmd", "appops", "set"]:
                self.calls.append(words); self.mutations.append(remote); self.exact[remote[-3]] = remote[-1] == "allow"; return response()
            if remote[:2] == ["am", "start"]:
                self.calls.append(words); self.mutations.append(remote); package = remote[-1].split("/")[0]
                self.active[package] = 123
                inputs = self.current_apks[package]["inputs"]; phase = inputs["ALKION_CAPABILITY_PHASE"]
                if phase == "main":
                    if not self.permission[package] and not self.flags[package]: self.dialog.add(package)
                    self.mirror(package)
                else:
                    root = self.package(package) / ("files/android-capability/" + RUN + "/" + inputs["ALKION_CAPABILITY_CASE"] + "/v" + inputs["ALKION_PROOF_VERSION"])
                    prior = (root / "prior-report.json").read_bytes(); before = json.loads((root / "prior-snapshot.json").read_bytes())
                    identity = step(prior, before, inputs["ALKION_FLAVOR"], inputs["ALKION_CAPABILITY_CASE"], phase, int(inputs["ALKION_PROOF_VERSION"]))
                    assert identity["prior_report_sha256"] == inputs["ALKION_PRIOR_REPORT_SHA256"]
                    assert identity["prior_state_digest"] == inputs["ALKION_PRIOR_STATE_SHA256"]
                    if phase == "logged": assert package in self.logging; self.logging.remove(package)
                    report = report_for(identity, before, capability.instant(UTC) + self.clock)
                    report["plugin_capabilities"]["notifications_enabled"] = self.permission[package]
                    report["plugin_capabilities"]["can_schedule_exact_notifications"] = self.exact[package]
                    self.states[package] = report["snapshot"]; self.query_reports.append(report)
                    self.write(root / "output/report.json", report); self.clock += 2.1
                return response("Status: ok\n")
            if remote[:2] == ["date", "-u"]:
                self.calls.append(words); return response(utc(capability.instant(UTC) + self.clock) + "\n")
            if remote[:2] == ["input", "tap"]:
                self.calls.append(words); self.mutations.append(remote)
                if self.dialog:
                    package, = self.dialog
                    self.dialog.remove(package); self.permission[package] = False; self.flags[package] = True; self.mirror(package)
                else:
                    self.tap(self.args, None, None, {50:'Resume workout',150:'Log set 2 · 82.5kg × 5',250:'Minimize'}[int(remote[-1])])
                return response()
            if remote == ["dumpsys", "activity", "activities"]:
                self.calls.append(words); package, = self.active
                component = 'com.android.permissioncontroller/.permission.ui.GrantPermissionsActivity' if package in self.dialog else package + '/dev.animusstudio.alkion.MainActivity'
                return response('mResumedActivity: ActivityRecord{abc u0 ' + component + ' t1}\n mCurrentFocus=Window{abc u0 ' + component + '}\n Intent { act=android.content.pm.action.REQUEST_PERMISSIONS }\n launchedFromUid=' + str(self.metadata[package]["uid"]) + ' launchedFromPackage=' + package + '\n')
            if remote[:3] == ["cmd", "notification", "get"]:
                self.calls.append(words); package = remote[-1].split("|")[1]
                if not self.permission[package]: return response("no active notification matching key: " + remote[-1], code=1)
                return response(remote[-1] + " pkg=" + package + " id=4101 " + capability.payload(self.states[package], "draft")["name"] + " +30s PendingIntent")
            if remote == ["dumpsys", "alarm"]:
                self.calls.append(words); package, = self.active
                if not self.permission[package]: return response("Current Alarm Manager state:\n  0 pending alarms:\n")
                end = int(capability.rest(self.states[package])[1] * 1000)
                window = "0 exactAllowReason=permission" if self.exact[package] else "+10m0s0ms"
                return response("Current Alarm Manager state:\n  1 pending alarms:\n    RTC_WAKEUP #1: Alarm{abc type 0 origWhen " + str(end) + " whenElapsed 123 " + package + "}\n      type=RTC_WAKEUP origWhen=2026-10-18 12:10:00.000 window=" + window + " repeatInterval=0 count=0 flags=0x5\n      operation=PendingIntent{abc: PendingIntentRecord{def " + package + " broadcastIntent}}\n")
            if remote == ["dumpsys", "activity", "intents"]:
                self.calls.append(words); package, = self.active
                return response("  * PendingIntentRecord{def " + package + " broadcastIntent}\n    uid=" + str(self.metadata[package]["uid"] + self.intent_uid_delta) + " packageName=" + package + "\n    requestCode=4101\n    requestIntent=Intent { cmp=" + package + "/" + capability.RECEIVER + " (has extras) }\n")
        return super().command(argv, **options)


class Controls(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="alkion-capability-host-")
        self.root = Path(self.temp.name)
        self.host = Host(self.root)
        self.environment = patch.dict(os.environ, JAVA_HOME="/usr/lib/jvm/java-21-openjdk", ANDROID_USER_HOME=str(self.host.user))
        self.environment.start()

    def tearDown(self):
        self.environment.stop(); self.temp.cleanup()

    def test_prepare_reuses_real_guards_and_is_read_only(self):
        prepared = capability.prepare(self.host, self.host.args)
        self.assertEqual(prepared.floor, 44)
        self.assertEqual(prepared.snapshots, self.host.states)
        self.assertFalse(self.host.mutations)
        self.assertFalse(prepared.output.exists())

    def test_failed_receipt_and_missing_plugin_producer_refuse_before_mutation(self):
        original = Path(self.host.args.base_run).read_bytes()
        changed = copy.deepcopy(self.host.lifecycle); changed["initial_lifecycle_phase"] = "FAIL"
        self.host.write(Path(self.host.args.base_run), changed)
        with self.assertRaises(capability.Refusal): capability.prepare(self.host, self.host.args)
        self.host.write(Path(self.host.args.base_run), original)
        (self.host.APP / capability.HELPER).write_text("// Original SQL-only producer has no native query\n")
        with self.assertRaisesRegex(capability.Blocked, "real_plugin_query_producer"):
            capability.prepare(self.host, self.host.args)
        self.assertFalse(self.host.mutations)

    def test_uid_and_apk_drift_refuse_before_policy(self):
        package = capability.PACKAGES[1]
        self.host.metadata[package]["uid"] = 11001
        with self.assertRaisesRegex(capability.Refusal, "full_uid_changed"):
            capability.prepare(self.host, self.host.args)
        self.host.metadata[package]["uid"] = 10001
        (self.root / "lifecycle/dev-finish.apk").write_bytes(b'changed')
        with self.assertRaises((capability.Refusal, json.JSONDecodeError)):
            capability.prepare(self.host, self.host.args)
        self.assertFalse(self.host.mutations)

    def test_profile_drift_after_prepare_refuses_before_policy(self):
        prepared = capability.prepare(self.host, self.host.args)
        package = capability.PACKAGES[1]
        source = self.host.package(package) / ("files/" + package + "/original-source.bin")
        source.write_bytes(b"unexpected changed closed original")
        with self.assertRaisesRegex(capability.Refusal, "closed_baseline_changed_after_preflight"):
            capability.run(self.host, prepared)
        self.assertFalse(self.host.mutations)
        self.assertEqual(source.read_bytes(), b"unexpected changed closed original")
        self.assertEqual(json.loads((prepared.output / "run.json").read_bytes())["capability_phase"], "FAIL")

    def test_receipt_drift_after_prepare_refuses_before_policy(self):
        prepared = capability.prepare(self.host, self.host.args)
        path = Path(self.host.args.updates_run)
        path.write_bytes(path.read_bytes() + b"\n")
        with self.assertRaisesRegex(capability.Refusal, "receipt_changed_after_preflight"):
            capability.run(self.host, prepared)
        self.assertFalse(self.host.mutations)

    def test_exact_version_ledger_drift_refuses_before_mutation_or_allocation(self):
        prepared = capability.prepare(self.host, self.host.args)
        path = Path(self.host.args.version_ledger); original = path.read_bytes()
        self.assertEqual(prepared.ledger_path, path)
        self.assertEqual(prepared.ledger_sha256, capability.sha(original))
        path.write_bytes(original + b"\n")  # Same parsed object; different exact receipt.
        with self.assertRaisesRegex(capability.Refusal, "version_ledger_changed_after_preflight"):
            capability.run(self.host, prepared)
        result = json.loads((prepared.output / "run.json").read_bytes())
        self.assertEqual(result["builds"], [])
        self.assertEqual(result["allocation_floor"], prepared.floor)
        self.assertEqual(result["version_ledger"], {"path": str(path), "sha256": capability.sha(original)})
        self.assertFalse(self.host.mutations)
        self.assertEqual(path.read_bytes(), original + b"\n")
        self.assertEqual(next(prepared.output.glob("*prior-version-ledger.json")).read_bytes(), original)

    def test_content_description_only_limitation_keeps_exact_package_binding(self):
        clock = SimpleNamespace(now=0.0)
        host = SimpleNamespace()
        package = capability.PACKAGES[1]
        def document(owner):
            root = ET.Element("hierarchy")
            ET.SubElement(root, "node", {"package": owner, "text": "", "content-desc": capability.DENIED_MESSAGE})
            return root
        host.ui_document = lambda *args, **kwargs: document(package)
        host.resumed_component = self.host.resumed_component
        evidence = SimpleNamespace(count=0, host=host, prepared=SimpleNamespace(args=self.host.args, output=self.root),
                                   adb=lambda *args: response('mResumedActivity: ActivityRecord{abc u0 ' + package + '/dev.animusstudio.alkion.MainActivity t1}\n'))
        timer = SimpleNamespace(monotonic=lambda: clock.now, sleep=lambda duration: setattr(clock, "now", clock.now + duration))
        with patch.object(capability, "time", timer):
            self.assertEqual(capability.limitation_ui(evidence, package, capability.DENIED_MESSAGE, require_dialog=False)["message"], capability.DENIED_MESSAGE)
            host.ui_document = lambda *args, **kwargs: document(capability.PACKAGES[2])
            with self.assertRaisesRegex(capability.Blocked, "snackbar_not_observed"):
                capability.limitation_ui(evidence, package, capability.DENIED_MESSAGE, require_dialog=False)

    def test_owned_read_timeout_retains_binary_receipt_then_evidence_files(self):
        prepared = capability.prepare(self.host, self.host.args)
        package = capability.PACKAGES[1]; relative = "files/partial-report.json"
        def interrupted(argv, **options):
            self.assertTrue(options["binary"])
            raise subprocess.TimeoutExpired(argv, options["timeout"], output=b"partial\x00\xff", stderr=b"error\xfe\x00")
        with patch.object(self.host, "command", interrupted):
            with self.assertRaises(subprocess.TimeoutExpired) as caught:
                capability.owned_read(self.host, self.host.args, package, relative)
            self.assertEqual(caught.exception.capability_partial_stdout, b"partial\x00\xff")
            self.assertEqual(caught.exception.capability_timeout_receipt["context"]["path"], relative)
            self.assertFalse(prepared.output.exists())  # Preflight remains read-only.
            prepared.output.mkdir(mode=0o700); evidence = capability.Evidence(self.host, prepared)
            with self.assertRaises(subprocess.TimeoutExpired): evidence.read(package, relative, optional=True)
        receipt = json.loads(next(prepared.output.glob("*transport-timeout.json")).read_bytes())
        self.assertEqual(receipt["context"]["package"], package)
        self.assertEqual(receipt["context"]["serial"], self.host.args.serial)
        self.assertEqual((prepared.output / receipt["stdout"]["file"]).read_bytes(), b"partial\x00\xff")
        self.assertEqual((prepared.output / receipt["stderr"]["file"]).read_bytes(), b"error\xfe\x00")
        self.assertEqual(receipt["stdout"]["sha256"], capability.sha(b"partial\x00\xff"))

    def test_adb_timeout_after_uncertain_mutation_stops_and_retains_partial_bytes(self):
        prepared = capability.prepare(self.host, self.host.args)
        original = self.host.adb
        def interrupted(args, *tail, **options):
            result = original(args, *tail, **options)
            if tail[:3] == ("shell", "pm", "grant"):
                raise subprocess.TimeoutExpired(["adb", "-s", args.serial, *tail], 60, output=b"applied?\x00\xff", stderr=b"transport\xfe")
            return result
        with patch.object(self.host, "adb", interrupted), self.assertRaises(subprocess.TimeoutExpired):
            capability.run(self.host, prepared)
        result = json.loads((prepared.output / "run.json").read_bytes())
        self.assertEqual(result["capability_phase"], "FAIL")
        self.assertEqual(result["builds"], [])
        self.assertEqual(len(self.host.mutations), 1)  # No retry/repair of uncertain grant.
        receipt = json.loads(next(prepared.output.glob("*transport-timeout.json")).read_bytes())
        self.assertEqual(receipt["context"]["tail"][:3], ["shell", "pm", "grant"])
        self.assertEqual(receipt["context"]["serial"], self.host.args.serial)
        self.assertEqual((prepared.output / receipt["stdout"]["file"]).read_bytes(), b"applied?\x00\xff")
        self.assertEqual((prepared.output / receipt["stderr"]["file"]).read_bytes(), b"transport\xfe")

    def test_binary_stage_timeout_keeps_uncertain_partial_and_never_publishes(self):
        prepared = capability.prepare(self.host, self.host.args); prepared.output.mkdir(mode=0o700)
        evidence = capability.Evidence(self.host, prepared); original = self.host.command
        package = capability.PACKAGES[1]; root = "files/android-capability/" + RUN + "/denied/v81"
        raw = b"input\x00\xff"
        evidence.publisher.ensure(package)  # Before the timed case, as the route does.
        def interrupted(argv, **options):
            result = original(argv, **options)
            if options.get("input") is not None:
                raise subprocess.TimeoutExpired(argv, options["timeout"], output=b"ack?\xff", stderr=b"lost\x00")
            return result
        with patch.object(self.host, "command", interrupted), self.assertRaises(subprocess.TimeoutExpired):
            evidence.stage(package, root, {"prior-report.json": raw})
        directory = self.host.package(package) / root
        self.assertFalse((directory / "prior-report.json").exists())
        self.assertEqual(next(directory.glob("prior-report.json.partial-*")).read_bytes(), raw)
        receipt = json.loads(next(prepared.output.glob("*transport-timeout.json")).read_bytes())
        self.assertEqual(receipt["context"]["input_sha256"], capability.sha(raw))
        self.assertEqual((prepared.output / receipt["stdout"]["file"]).read_bytes(), b"ack?\xff")

    def test_native_mirror_timeout_retains_package_path_and_binary_partials(self):
        prepared = capability.prepare(self.host, self.host.args); prepared.output.mkdir(mode=0o700)
        evidence = capability.Evidence(self.host, prepared); package = capability.PACKAGES[1]
        def interrupted(args, target):
            self.assertEqual(target, package)
            raise subprocess.TimeoutExpired(["adb", "-s", args.serial, "shell", "run-as", target,
                "cat", "shared_prefs/scheduled_notifications.xml"], 60, output=b"<map>\x00\xff", stderr=b"lost\xfe")
        with patch.object(self.host, "read_native_mirror", interrupted), self.assertRaises(subprocess.TimeoutExpired):
            capability.native_schedule(evidence, package, prepared.snapshots[package], "exactAllowWhileIdle")
        receipt = json.loads(next(prepared.output.glob("*transport-timeout.json")).read_bytes())
        self.assertEqual(receipt["context"]["operation"], "native-mirror-read")
        self.assertEqual(receipt["context"]["package"], package)
        self.assertEqual(receipt["context"]["path"], "shared_prefs/scheduled_notifications.xml")
        self.assertEqual(receipt["context"]["serial"], self.host.args.serial)
        self.assertEqual((prepared.output / receipt["stdout"]["file"]).read_bytes(), b"<map>\x00\xff")
        self.assertEqual((prepared.output / receipt["stderr"]["file"]).read_bytes(), b"lost\xfe")
        self.assertFalse(self.host.mutations)

    def test_ledger_cannot_omit_known_wrong_signer_or_failed_attempt(self):
        ledger = copy.deepcopy(self.host.ledger)
        ledger["entries"] = [entry for entry in ledger["entries"] if entry["version_code"] != 40]
        self.host.write(Path(self.host.args.version_ledger), ledger)
        with self.assertRaisesRegex(capability.Refusal, "omits_recorded_attempted"):
            capability.prepare(self.host, self.host.args)
        self.assertFalse(self.host.mutations)

    def test_foreign_attempt_manifest_refuses_before_mutation(self):
        path = self.root / "failed-attempt/run.json"
        self.host.write(path, dict(self.host.lifecycle, run_id="2" * 32))
        self.host.args.attempt_manifests = (str(path),)
        ledger = copy.deepcopy(self.host.ledger)
        ledger["manifest_sha256"][str(path)] = capability.sha(path.read_bytes())
        self.host.write(Path(self.host.args.version_ledger), ledger)
        with self.assertRaisesRegex(capability.Refusal, "foreign_attempt_manifest"):
            capability.prepare(self.host, self.host.args)
        self.assertFalse(self.host.mutations)

    def test_ledger_includes_reserved_and_failed_codes_without_reuse(self):
        ledger = copy.deepcopy(self.host.ledger)
        ledger["entries"].append({"application_id": capability.PACKAGES[1], "version_code": 81, "state": "failed", "role": "failed-literal-main", "source_commit": SOURCE})
        floor = capability.validate_ledger(ledger, self.host.receipt, ledger["manifest_sha256"], self.host.installed)
        self.assertEqual(floor, 81)
        state = {"allocation_floor": floor, "builds": []}
        prepare = capability.reserve_version(state, capability.PACKAGES[1], "denied/prepare", SOURCE)
        main = capability.reserve_version(state, capability.PACKAGES[1], "denied/main", SOURCE)
        prepare["state"] = "installed"; main["state"] = "failed"
        preserve = capability.reserve_version(state, capability.PACKAGES[1], "denied/preserve", SOURCE)
        self.assertEqual([entry["version_code"] for entry in state["builds"]], [82, 83, 84])
        self.assertEqual(preserve["allocation_floor"], 83)
        state["allocation_floor"] = 82
        with self.assertRaisesRegex(capability.Refusal, "reused"):
            capability.reserve_version(state, capability.PACKAGES[1], "denied/main", SOURCE)
        ledger["entries"].append(copy.deepcopy(ledger["entries"][-1]))
        with self.assertRaisesRegex(capability.Refusal, "reused"):
            capability.validate_ledger(ledger, self.host.receipt, ledger["manifest_sha256"], self.host.installed)

    def test_literal_main_has_no_proof_defines_and_helper_has_complete_binding(self):
        main = capability.capability_build_arguments({"ALKION_FLAVOR": "dev", "ALKION_PROOF_VERSION": "81", "ALKION_CAPABILITY_PHASE": "main", "ALKION_PROOF_RUN": RUN})
        self.assertEqual(main[main.index("--target") + 1], "lib/main.dart")
        self.assertFalse(any("dart-define" in value for value in main))
        before = snapshot(); raw = capability.canonical(self.host.lifecycle) + b"\n"
        identity = step(raw, before, "dev", "denied", "prepare", 82)
        values = dict(zip(capability.DEFINES, map(str, (identity[key] for key in ("run_id", "source_commit", "prior_source_commit", "variant", "case_id", "phase", "version_code", "prior_version_code", "consumed_version_floor", "profile_id", "generation", "prior_report_sha256", "prior_state_digest")))))
        values["ALKION_FLAVOR"] = "dev"
        helper = capability.capability_build_arguments(values)
        self.assertEqual(helper[helper.index("--target") + 1], capability.HELPER)
        for key, value in (("ALKION_PRIOR_REPORT_SHA256", "bad"), ("ALKION_PROOF_VARIANT", "supported"),
                           ("ALKION_CONSUMED_VERSION_FLOOR", "82"), ("ALKION_PROOF_VERSION", "82; touch /tmp/canary")):
            with self.assertRaises(capability.Refusal): capability.capability_build_arguments(dict(values, **{key: value}))

    def test_actual_report_shape_chain_all_four_cases_both_variants(self):
        version = 81
        for flavor in capability.VARIANTS:
            before = snapshot(flavor); raw = capability.canonical(self.host.lifecycle) + b"\n"
            now = capability.instant(UTC) + 5
            for case in capability.CASES:
                for phase in ("prepare", "preserve", "logged") if case in capability.CASES[:2] else ("prepare", "preserve"):
                    identity = step(raw, before, flavor, case, phase, version)
                    report = report_for(identity, before, now)
                    after = capability.validate_checkpoint(report, identity, raw, before)
                    self.assertEqual(after, report["snapshot"])
                    self.assertEqual(report["native_proof"], "UNRUN: host routing is separate")
                    raw = capability.canonical(report) + b"\n"; before = after; now += 5; version += 2

    def test_hash_phase_source_originals_and_precise_logging_refusals(self):
        before = snapshot(); raw = capability.canonical(self.host.lifecycle) + b"\n"
        identity = step(raw, before, "dev", "denied", "prepare", 81)
        prepared = report_for(identity, before, capability.instant(UTC) + 5)
        for changed in (dict(identity, prior_report_sha256="0" * 64), dict(identity, prior_source_commit="0" * 40),
                        dict(identity, case_id="revoked")):
            with self.assertRaises(capability.Refusal): capability.predecessor_contract(changed, raw, before)
        corrupt = copy.deepcopy(prepared); corrupt["snapshot"]["original_bytes"][0] = 0
        corrupt["state_digest"] = capability.state_sha(corrupt["snapshot"])
        with self.assertRaisesRegex(capability.Refusal, "original_bytes_changed"):
            capability.validate_checkpoint(corrupt, identity, raw, before)
        raw = capability.canonical(prepared) + b"\n"; before = prepared["snapshot"]
        identity = step(raw, before, "dev", "denied", "preserve", 83)
        preserved = report_for(identity, before, capability.instant(UTC) + 10)
        capability.validate_checkpoint(preserved, identity, raw, before)
        raw = capability.canonical(preserved) + b"\n"
        identity = step(raw, before, "dev", "denied", "logged", 85)
        logged = report_for(identity, before, capability.instant(UTC) + 15)
        capability.validate_checkpoint(logged, identity, raw, before)
        logged["observed_delta"]["timer/active"]["revision_delta"] = 2
        with self.assertRaisesRegex(capability.Refusal, "delta_receipt_mismatch"):
            capability.validate_checkpoint(logged, identity, raw, before)

    def test_plugin_query_is_actual_boolean_not_appop_default(self):
        self.assertIsNone(capability.appop_mode("No operations.\nDefault mode: default\n", "SCHEDULE_EXACT_ALARM"))
        for value in ({}, {"plugin_capabilities": {"format": capability.PLUGIN_FORMAT, "notifications_enabled": "true", "can_schedule_exact_notifications": False}}):
            with self.assertRaises(capability.Blocked): capability.plugin_query(value)
        report = {"checkpoint_time": UTC, "plugin_capabilities": {"format": capability.PLUGIN_FORMAT,
            "notifications_enabled": True, "can_schedule_exact_notifications": False, "queried_at": UTC}}
        self.assertIs(capability.plugin_query(report)["can_schedule_exact_notifications"], False)
        start = capability.instant(UTC)
        report["plugin_capabilities"]["queried_at"] = utc(start + 2)
        self.assertTrue(capability.plugin_query(report, start, start + 3)["notifications_enabled"])
        for lower, upper, queried in ((start + 1, start + 3, start + 2), (start, start + 1, start + 2),
                                      (start - 2, start + 3, start - 1)):
            report["plugin_capabilities"]["queried_at"] = utc(queried)
            with self.assertRaisesRegex(capability.Blocked, "query_time_unbound"):
                capability.plugin_query(report, lower, upper)

    def test_permission_and_appop_unknown_or_duplicate_are_blocked(self):
        raw = "  User 0: installed=true stopped=false\n    android.permission.POST_NOTIFICATIONS: granted=false, flags=[ USER_SET|USER_FIXED ]\n"
        self.assertFalse(capability.permission_state(raw)["granted"])
        self.assertEqual(capability.appop_mode("Uid mode: POST_NOTIFICATION: ignore\n", "POST_NOTIFICATION"), "ignore")
        for value in ("", raw + raw, raw.replace("granted=false", "granted=unknown")):
            with self.assertRaises(capability.Blocked): capability.permission_state(value)
        with self.assertRaises(capability.Blocked): capability.appop_mode("POST_NOTIFICATION: allow\nPOST_NOTIFICATION: ignore\n", "POST_NOTIFICATION")

    def test_alarm_exact_inexact_uid_receiver_and_deadline_binding(self):
        package = capability.PACKAGES[1]; deadline = 1792324480000
        def alarm(window, reason=""):
            return ('Current Alarm Manager state:\n  1 pending alarms:\n    RTC_WAKEUP #1: Alarm{abc type 0 origWhen ' + str(deadline) +
                    ' whenElapsed 123456 ' + package + '}\n      type=RTC_WAKEUP origWhen=2026-10-18 13:54:40.000 window=' + window + reason +
                    ' repeatInterval=0 count=0 flags=0x5\n      operation=PendingIntent{abc: PendingIntentRecord{def ' + package + ' broadcastIntent}}\n')
        intents = ('  * PendingIntentRecord{def ' + package + ' broadcastIntent}\n    uid=10001 packageName=' + package +
                   ' type=broadcastIntent flags=0x4000000\n    requestCode=4101 requestResolvedType=null\n    requestIntent=Intent { cmp=' + package + '/' + capability.RECEIVER + ' (has extras) }\n')
        self.assertTrue(capability.alarm_binding(alarm("0", " exactAllowReason=permission"), intents, package, 10001, deadline, True)["exact"])
        self.assertFalse(capability.alarm_binding(alarm("+10m0s0ms"), intents, package, 10001, deadline, False)["exact"])
        for text, sender, when in ((alarm("0", " exactAllowReason=permission"), intents.replace("10001", "10002"), deadline),
                                   (alarm("0", " exactAllowReason=permission"), intents.replace(capability.RECEIVER, "ForeignReceiver"), deadline),
                                   (alarm("0", " exactAllowReason=permission"), intents, deadline + 1),
                                   ("Current Alarm Manager state:\n Exempted bucket packages:\n " + package, intents, deadline)):
            with self.assertRaises(capability.Blocked): capability.alarm_binding(text, sender, package, 10001, when, True)
        self.assertEqual(capability.alarm_headers("Current Alarm Manager state:\n  0 pending alarms:\n"), [])
        for raw in ("", "Current Alarm Manager state:\n", "Current Alarm Manager state:\n  1 pending alarms:\n"):
            with self.assertRaises(capability.Blocked): capability.alarm_headers(raw)

    def test_binary_input_publication_preserves_existing_final_and_partials(self):
        prepared = capability.prepare(self.host, self.host.args); prepared.output.mkdir(mode=0o700)
        evidence = capability.Evidence(self.host, prepared)
        package = capability.PACKAGES[1]
        root = "files/android-capability/" + RUN + "/denied/v81"
        raw = b'original\x00\xff\n`literal` $(literal) "quoted"'
        evidence.publisher.ensure(package)
        evidence.stage(package, root, {"prior-report.json": raw})
        directory = self.host.package(package) / root
        self.assertEqual((directory / "prior-report.json").read_bytes(), raw)
        self.assertFalse(list(directory.glob("prior-report.json.partial-*")))  # Consumed by the no-replace rename.
        final = json.loads(next(prepared.output.glob("*capability-input-prior-report.json.publication-final.json")).read_bytes())
        self.assertEqual((final["state"], final["partial_consumed"], final["final_sha256"]), ("PUBLISHED", True, capability.sha(raw)))
        self.assertTrue(all(call[1:3] == ["-s", self.host.args.serial] for call in self.host.calls if call[0].endswith("/adb")))
        self.host.publish_collision = True
        other = "files/android-capability/" + RUN + "/denied/v82"
        with self.assertRaisesRegex(capability.Refusal, "capability_input_publication_refused:publication:NOT_PUBLISHED:rename_errno_17"):
            evidence.stage(package, other, {"prior-report.json": raw})
        directory = self.host.package(package) / other
        self.assertEqual((directory / "prior-report.json").read_bytes(), b"existing final must survive")
        self.assertEqual(next(directory.glob("prior-report.json.partial-*")).read_bytes(), raw)

    def test_owned_read_uses_shell_T_and_distinguishes_missing_empty_and_diagnostics(self):
        prepared = capability.prepare(self.host, self.host.args); prepared.output.mkdir(mode=0o700)
        evidence = capability.Evidence(self.host, prepared); package = capability.PACKAGES[1]
        directory = self.host.package(package) / "files/reads"; directory.mkdir(parents=True)
        (directory / "empty.json").write_bytes(b"")
        self.host.calls.clear()
        self.assertIsNone(evidence.read(package, "files/reads/absent.json", optional=True))
        self.assertEqual(evidence.read(package, "files/reads/empty.json", optional=True), b"")
        argv = self.host.calls[-1]
        self.assertEqual(argv[3:5], ["shell", "-T"])
        self.assertEqual(shlex.split(argv[5])[:4], ["run-as", package, "/system/bin/sh", "-c"])
        (directory / "linked.json").symlink_to(directory / "empty.json")
        with self.assertRaisesRegex(capability.Refusal, "capability_owned_read_failed"):
            evidence.read(package, "files/reads/linked.json", optional=True)
        with self.assertRaisesRegex(capability.Refusal, "capability_owned_read_failed"):
            evidence.read(package, "files/reads/absent.json")
        with patch.object(self.host, "command", return_value=response(b"", b"diagnostic", 3)):
            with self.assertRaisesRegex(capability.Refusal, "capability_owned_read_failed"):
                evidence.read(package, "files/reads/absent.json", optional=True)
        # The replaced raw exec-out transport could not tell absence from an empty file.
        raw = self.host.command([self.host.sdk / "platform-tools/adb", "-s", self.host.args.serial, "exec-out", argv[5]],
                                binary=True, check=False, timeout=30)
        self.assertEqual((raw.returncode, raw.stdout, raw.stderr), (0, b"", b""))

    def test_stage_input_uses_shell_T_stdin_and_strict_status(self):
        prepared = capability.prepare(self.host, self.host.args); prepared.output.mkdir(mode=0o700)
        evidence = capability.Evidence(self.host, prepared); package = capability.PACKAGES[1]
        evidence.publisher.ensure(package)
        raw = bytes(range(256)) * 5
        root = "files/android-capability/" + RUN + "/denied/v83"
        self.host.calls.clear()
        evidence.stage(package, root, {"prior-snapshot.json": raw})
        writes = [call for call in self.host.calls if call[0].endswith("/adb") and "alkion-capability-input" in call[-1]]
        self.assertEqual(len(writes), 1)
        self.assertEqual(writes[0][3:5], ["shell", "-T"])
        self.assertEqual((self.host.package(package) / root / "prior-snapshot.json").read_bytes(), raw)
        # Raw exec-out never delivers host stdin: the old write could only time out.
        with self.assertRaises(subprocess.TimeoutExpired):
            self.host.command([*writes[0][:3], "exec-out", writes[0][-1]], binary=True, input=raw, check=False, timeout=30)
        original = self.host.command
        def failing(argv, **options):
            if options.get("input") is not None and "alkion-capability-input" in str(argv[-1]):
                original(argv, **options)
                return response(b"", b"synthetic write diagnostic", 1)
            return original(argv, **options)
        other = "files/android-capability/" + RUN + "/denied/v84"
        before = len(self.host.runas.programs)
        with patch.object(self.host, "command", failing), self.assertRaisesRegex(capability.Refusal, "capability_closed_input_changed"):
            evidence.stage(package, other, {"prior-report.json": raw})
        self.assertEqual(len(self.host.runas.programs), before)  # No publication after a failed write.
        self.assertFalse((self.host.package(package) / other / "prior-report.json").exists())

    def test_no_owned_capability_path_uses_exec_out(self):
        host = CampaignHost(self.root / "transport")
        with patch.dict(os.environ, ANDROID_USER_HOME=str(host.user)):
            prepared = capability.prepare(host, host.args)
            clock = SimpleNamespace(monotonic=lambda: host.clock, sleep=lambda duration: setattr(host, "clock", host.clock + duration))
            calls = []
            original = host.command
            def record(argv, **options):
                calls.append(list(map(str, argv)))
                return original(argv, **options)
            with patch.object(host, "command", record), patch.object(capability, "time", clock):
                capability.run(host, prepared)
        exec_out = [call for call in calls if call[0].endswith("/adb") and call[3] == "exec-out"]
        self.assertTrue(all(call[4:] == ["screencap", "-p"] for call in exec_out), exec_out)
        self.assertTrue(any(call[3:5] == ["shell", "-T"] for call in calls))

    def test_stage_requires_bootstrapped_publisher_with_zero_commands(self):
        prepared = capability.prepare(self.host, self.host.args); prepared.output.mkdir(mode=0o700)
        evidence = capability.Evidence(self.host, prepared); package = capability.PACKAGES[1]
        self.host.calls.clear()
        with self.assertRaisesRegex(capability.Refusal, "capability_publisher_not_bootstrapped"):
            evidence.stage(package, "files/android-capability/" + RUN + "/denied/v85", {"prior-report.json": b"x"})
        self.assertEqual(self.host.calls, [])
        self.assertFalse((self.host.package(package) / "files/android-capability").exists())

    def test_helper_replaced_after_update_stops_without_recopy(self):
        prepared = capability.prepare(self.host, self.host.args); prepared.output.mkdir(mode=0o700)
        evidence = capability.Evidence(self.host, prepared); package = capability.PACKAGES[1]
        evidence.publisher.ensure(package)
        helper = self.host.package(package) / evidence.publisher.packages[package]["namespace"] / "publisher"
        helper.write_bytes(helper.read_bytes()[:-1] + b"?")
        root = "files/android-capability/" + RUN + "/denied/v86"
        with self.assertRaisesRegex(capability.Refusal, "publication:NOT_ATTEMPTED:guard_exit_76"):
            evidence.stage(package, root, {"prior-report.json": b"payload"})
        self.assertEqual(next((self.host.package(package) / root).glob("prior-report.json.partial-*")).read_bytes(), b"payload")
        self.assertEqual([index for _, index, _ in self.host.runas.programs].count(1), 1)  # Never recopied.

    def test_failed_builder_keeps_attempted_code_and_output_without_install(self):
        self.host.grant_becomes_unknown = False; self.host.fail_build = True
        prepared = capability.prepare(self.host, self.host.args)
        with self.assertRaisesRegex(capability.Refusal, "candidate_build_failed"):
            capability.run(self.host, prepared)
        report = json.loads((prepared.output / "run.json").read_bytes())
        entry, = report["builds"]
        self.assertEqual((entry["version_code"], entry["allocation_floor"], entry["state"]), (45, 44, "failed"))
        command, = [call for call in self.host.calls if call[0] == "make"]
        self.assertIn("ALKION_PRIOR_REPORT_SHA256=" + capability.sha(prepared.lifecycle_raw), command)
        self.assertIn("ALKION_CONSUMED_VERSION_FLOOR=44", command)
        self.assertTrue(any(b"partial fake build output" in path.read_bytes() for path in prepared.output.glob("*build-*.log")))
        self.assertEqual(report["installed"], prepared.installed)
        self.assertFalse(any("install" in call for call in self.host.calls))

    def test_route_calls_shared_ordinary_kill_with_full_uid_and_output(self):
        prepared = capability.prepare(self.host, self.host.args)
        active = {capability.PACKAGES[1]: 123}; calls = []
        self.host.app_pid = lambda args, package: active.get(package)
        def ordinary_kill(args, package, uid, output):
            calls.append((args, package, uid, output)); active.pop(package)
        self.host.ordinary_kill = ordinary_kill
        with self.assertRaises(capability.Blocked): capability.run(self.host, prepared)
        self.assertEqual(calls, [(prepared.args, capability.PACKAGES[1], 10001, prepared.output)])

    def test_interrupted_builder_retains_partial_streams_and_consumed_version(self):
        self.host.grant_becomes_unknown = False
        prepared = capability.prepare(self.host, self.host.args)
        command = self.host.command
        def interrupted(argv, **options):
            if argv[0] == "make":
                raise subprocess.TimeoutExpired(argv, options["timeout"], output=b"partial compiler stdout\x00", stderr=b"partial stderr\xff")
            return command(argv, **options)
        with patch.object(self.host, "command", interrupted), self.assertRaises(subprocess.TimeoutExpired):
            capability.run(self.host, prepared)
        result = json.loads((prepared.output / "run.json").read_bytes())
        self.assertEqual(result["builds"][0]["version_code"], 45)
        self.assertEqual(result["builds"][0]["state"], "failed")
        self.assertEqual(next(prepared.output.glob("*interrupted-build-stdout.log")).read_bytes(), b"partial compiler stdout\x00")
        self.assertEqual(next(prepared.output.glob("*interrupted-build-stderr.log")).read_bytes(), b"partial stderr\xff")

    def test_permission_dialog_binds_real_request_uid_and_exact_native_node(self):
        clicks = []
        evidence = SimpleNamespace(prepared=SimpleNamespace(args=self.host.args, metadata=self.host.metadata),
                                   host=SimpleNamespace(resumed_component=self.host.resumed_component, click_node=lambda args, node: clicks.append(node)))
        package = capability.PACKAGES[1]
        document = ET.fromstring('<hierarchy><node package="com.android.permissioncontroller" resource-id="com.android.permissioncontroller:id/permission_message" text="Allow Alkion Dev to send you notifications?"/><node package="com.android.permissioncontroller" resource-id="com.android.permissioncontroller:id/permission_deny_button" text="Don’t allow" clickable="true" bounds="[0,0][100,100]"/></hierarchy>')
        activity = ('mResumedActivity: ActivityRecord{abc u0 com.android.permissioncontroller/.permission.ui.GrantPermissionsActivity t1}\n'
                    ' Intent { act=android.content.pm.action.REQUEST_PERMISSIONS }\n launchedFromUid=10001 launchedFromPackage=' + package + '\n')
        capability.deny_dialog(evidence, package, document, activity)
        self.assertEqual(len(clicks), 1)
        for raw in (activity.replace("10001", "10002"), activity.replace("REQUEST_PERMISSIONS", "VIEW")):
            with self.assertRaises(capability.Blocked): capability.deny_dialog(evidence, package, document, raw)
        self.assertEqual(len(clicks), 1)

    def test_jit_remaining_budget_blocks_instead_of_extending_timer(self):
        clock = SimpleNamespace(value=0.0)
        records = []
        evidence = SimpleNamespace(device_now=lambda: capability.instant(UTC) + clock.value,
                                   keep=lambda name, value: records.append((name, value)))
        with patch.object(capability, "time", SimpleNamespace(monotonic=lambda: clock.value)):
            budget = capability.LiveBudget(evidence, snapshot())
            self.assertEqual(budget.require(300, "jit-build"), 600)
            clock.value = 350
            with self.assertRaisesRegex(capability.Blocked, "insufficient_original_600s_budget"):
                budget.require(300, "jit-build")
            self.assertEqual(budget.deadline, capability.instant(UTC) + 600)
            clock.value = 601
            with self.assertRaises(capability.Blocked): budget.require(1, "late-report")
        self.assertTrue(records)

    def test_unknown_native_after_authorized_policy_stops_and_retains(self):
        prepared = capability.prepare(self.host, self.host.args)
        originals = {package: copy.deepcopy(state) for package, state in self.host.states.items()}
        with self.assertRaisesRegex(capability.Blocked, "requested_capability_policy_not_effective"):
            capability.run(self.host, prepared)
        report = json.loads((self.root / "output/run.json").read_bytes())
        self.assertEqual(report["capability_phase"], "BLOCKED")
        self.assertEqual(report["overall"], "IN_PROGRESS")
        self.assertEqual(report["cases"]["dev/denied"]["result"], "BLOCKED")
        self.assertEqual(report["builds"], [])
        self.assertEqual(len(self.host.mutations), 1)
        self.assertEqual(self.host.states, originals)
        self.assertTrue(list((self.root / "output").glob("*native-command.json")))
        self.assertFalse(any(word in command for command in self.host.calls for word in ("force-stop", "clear", "uninstall", "kill-all", "set-time", "set-timezone")))

    def test_complete_fake_campaign_runs_real_module_with_twenty_bound_reports(self):
        host = CampaignHost(self.root / "complete")
        with patch.dict(os.environ, ANDROID_USER_HOME=str(host.user)):
            prepared = capability.prepare(host, host.args)
            clock = SimpleNamespace(monotonic=lambda: host.clock, sleep=lambda duration: setattr(host, "clock", host.clock + duration))
            with patch.object(capability, "time", clock):
                result = capability.run(host, prepared)
        self.assertEqual(result["capability_phase"], "PASS")  # Host-only synthetic protocol, never Android PASS.
        self.assertEqual(result["overall"], "IN_PROGRESS")
        self.assertEqual(len(result["cases"]), 8)
        self.assertEqual(len(host.query_reports), 20)
        self.assertEqual(len(host.logged_clicks), 4)
        versions = [entry["version_code"] for entry in result["builds"]]
        self.assertEqual(versions, list(range(45, 45 + len(versions))))
        self.assertTrue(all(entry["state"] == "installed" for entry in result["builds"]))
        self.assertTrue(host.kill_calls)
        self.assertTrue(all(case["peer_and_neighbor_preserved"] for case in result["cases"].values()))
        self.assertEqual(result["cases"]["dev/inexact"]["native"]["mode"], "inexactAllowWhileIdle")
        self.assertTrue(all(call[1:3] == ["-s", host.args.serial] for call in host.calls if call[0].endswith("/adb")))
        # One bootstrap per variant, before the first live budget record.
        self.assertEqual([package for package, index, _ in host.runas.programs if index == 1], list(capability.VARIANTS.values()))
        names = sorted(path.name for path in prepared.output.iterdir())
        bound = [name for name in names if name.endswith(".bound.json")]
        budgets = [name for name in names if name.endswith("-remaining-budget.json")]
        self.assertEqual(len(bound), 2)
        self.assertLess(max(bound), min(budgets))
        finals = [json.loads(path.read_bytes()) for path in prepared.output.glob("*.publication-final.json")]
        self.assertTrue(finals and all(item["state"] == "PUBLISHED" for item in finals))
        self.assertEqual(len(finals), 2 * len([entry for entry in result["builds"] if not entry["role"].endswith("/main")]))

    def test_real_route_refuses_foreign_alarm_uid_and_keeps_closed_predecessor(self):
        host = CampaignHost(self.root / "foreign-native"); host.intent_uid_delta = 1
        # Denied has no alarm; enter its accepted fake predecessor so revoked
        # must refuse the real route's first enabled native schedule observation.
        with patch.dict(os.environ, ANDROID_USER_HOME=str(host.user)):
            prepared = capability.prepare(host, host.args)
            clock = SimpleNamespace(monotonic=lambda: host.clock, sleep=lambda duration: setattr(host, "clock", host.clock + duration))
            with patch.object(capability, "time", clock), self.assertRaisesRegex(capability.Blocked, "uid_receiver_or_id_mismatch"):
                capability.run(host, prepared)
        result = json.loads((prepared.output / "run.json").read_bytes())
        self.assertEqual(result["cases"]["dev/denied"]["result"], "PASS")
        self.assertEqual(result["cases"]["dev/revoked"]["result"], "BLOCKED")
        self.assertEqual(result["cases"]["dev/revoked"]["prepare"]["result"], "PASS")
        self.assertNotIn("preserve", result["cases"]["dev/revoked"])
        self.assertTrue(list(prepared.output.glob("*owned-read.stdout")))
        self.assertEqual(result["overall"], "IN_PROGRESS")

    def test_stage_inputs_reservation_is_recorded_and_blocks_staging_when_short(self):
        required = 60 + 15 + 2 * publish.PUBLISH_TIMEOUT
        host = CampaignHost(self.root / "stage-budget")
        with patch.dict(os.environ, ANDROID_USER_HOME=str(host.user)):
            prepared = capability.prepare(host, host.args)
            clock = SimpleNamespace(monotonic=lambda: host.clock, sleep=lambda duration: setattr(host, "clock", host.clock + duration))
            with patch.object(capability, "time", clock):
                capability.run(host, prepared)
        records = [json.loads(path.read_bytes()) for path in sorted(prepared.output.glob("*-remaining-budget.json"))]
        stage = [item for item in records if item["operation"].startswith("stage-inputs-")]
        self.assertEqual({item["operation"] for item in stage}, {"stage-inputs-preserve", "stage-inputs-logged"})
        self.assertTrue(all(item["required_seconds"] == required for item in stage))
        operations = [item["operation"] for item in records]
        first = operations.index("stage-inputs-preserve")
        # After the unchanged install (and kill) reservations, immediately before staging.
        self.assertIn(operations[first - 1], ("install-preserve", "ordinary-kill-and-checkpoint"))
        self.assertLess(operations.index("install-preserve"), first)
        self.assertTrue(any(item["operation"] == "install-preserve" and item["required_seconds"] == 75 for item in records))
        # Short of only the new reservation: the real budget refuses before any staging command.
        host = CampaignHost(self.root / "stage-budget-short")
        original = capability.LiveBudget.require
        def short(budget, seconds, operation):
            if operation.startswith("stage-inputs-"):
                host.clock = budget.deadline - capability.instant(UTC) - (required - 20)
            return original(budget, seconds, operation)
        with patch.dict(os.environ, ANDROID_USER_HOME=str(host.user)):
            prepared = capability.prepare(host, host.args)
            clock = SimpleNamespace(monotonic=lambda: host.clock, sleep=lambda duration: setattr(host, "clock", host.clock + duration))
            with patch.object(capability, "time", clock), patch.object(capability.LiveBudget, "require", short):
                with self.assertRaisesRegex(capability.Blocked, "insufficient_original_600s_budget:stage-inputs-preserve"):
                    capability.run(host, prepared)
        result = json.loads((prepared.output / "run.json").read_bytes())
        self.assertEqual(result["cases"]["dev/denied"]["result"], "BLOCKED")
        preserve = next(entry for entry in result["builds"] if entry["role"] == "denied/preserve")
        self.assertEqual(preserve["state"], "built")  # Never installed.
        root = host.package(capability.PACKAGES[1]) / ("files/android-capability/" + RUN + "/denied/v" + str(preserve["version_code"]))
        self.assertFalse(root.exists())
        self.assertEqual(len(list(prepared.output.glob("*.publication-request.json"))), 2)  # Only the prepare inputs.

    def test_real_route_stops_before_jit_allocation_when_original_budget_is_insufficient(self):
        host = CampaignHost(self.root / "slow-jit"); host.build_seconds = 180; host.args.jit_build_budget = 180
        with patch.dict(os.environ, ANDROID_USER_HOME=str(host.user)):
            prepared = capability.prepare(host, host.args)
            clock = SimpleNamespace(monotonic=lambda: host.clock, sleep=lambda duration: setattr(host, "clock", host.clock + duration))
            with patch.object(capability, "time", clock), self.assertRaisesRegex(capability.Blocked, "insufficient_original_600s_budget"):
                capability.run(host, prepared)
        result = json.loads((prepared.output / "run.json").read_bytes())
        self.assertEqual(result["cases"]["dev/denied"]["result"], "BLOCKED")
        self.assertEqual([entry["role"] for entry in result["builds"]], ["denied/prepare", "denied/main", "denied/preserve", "denied/main"])
        self.assertEqual(result["builds"][-1]["state"], "built")
        self.assertEqual(host.logged_clicks, [])
        closed = result["cases"]["dev/denied"]
        self.assertEqual(closed["prepare"]["state_digest"], closed["preserve"]["state_digest"])
        budgets = [json.loads(path.read_bytes()) for path in prepared.output.glob("*remaining-budget.json")]
        self.assertEqual(len({item["original_deadline"] for item in budgets}), 1)

    def facade_campaign(self, name):
        host = CampaignHost(self.root / name); host.add_observer()
        host.namespace.update(command=host.transport, app_pid=host.app_pid, ordinary_kill=host.kill)
        return host

    def test_actual_facade_check_and_complete_fake_observer_campaign(self):
        host = self.facade_campaign('facade-positive')
        with patch.dict(os.environ, ANDROID_USER_HOME=str(host.user)):
            host.args.action = 'capabilities-check'
            host.capabilities_action(host.args)
            self.assertEqual(host.args._ui_observer[0], host.lifecycle['ui_observer'])
            self.assertFalse(host.mutations); self.assertFalse(Path(host.args.output).exists())
            host.args.action = 'capabilities'
            timer = SimpleNamespace(monotonic=lambda: host.clock, sleep=lambda duration: setattr(host,'clock',host.clock+duration))
            with patch.object(capability, 'time', timer):
                result = host.capabilities_action(host.args)
        self.assertEqual(result['capability_phase'],'PASS')  # Host-only protocol input, never Android PASS.
        self.assertEqual(len(result['cases']),8); self.assertEqual(len(host.query_reports),20)
        receipts=[json.loads(path.read_bytes()) for path in Path(host.args.output).glob('*.observation/receipt.json.stdout')]
        self.assertTrue(receipts)
        self.assertEqual({item['root_package'] for item in receipts},set(capability.VARIANTS.values())|{'com.android.permissioncontroller'})
        self.assertEqual(result['ui_observer'],host.lifecycle['ui_observer'])
        self.assertTrue(all(item['peer_and_neighbor_preserved'] for item in result['cases'].values()))

    def test_actual_facade_refuses_foreign_observer_before_actions(self):
        for failure in ('uid','native-source','missing-retained-apk'):
            with self.subTest(failure=failure):
                host=self.facade_campaign('foreign-'+failure); host.args.action='capabilities'
                if failure=='uid': host.metadata[observer.PACKAGE]['uid']+=1
                elif failure=='native-source':
                    path=host.APP/'tool/android_synthetic_ui/HierarchyInstrumentation.java';path.write_bytes(path.read_bytes()+b'\n')
                else: (Path(host.args.base_run).parent/'ui-observer/synthetic-ui-observer.apk').unlink()
                with patch.dict(os.environ,ANDROID_USER_HOME=str(host.user)), self.assertRaises((ValueError,host.namespace['Refusal'])):
                    host.capabilities_action(host.args)
                self.assertFalse(host.mutations);self.assertFalse(Path(host.args.output).exists())

    def test_actual_facade_bad_observer_nonce_retains_failed_first_capture(self):
        host=self.facade_campaign('bad-observer-nonce');host.observer_wrong_nonce=True;host.args.action='capabilities'
        timer=SimpleNamespace(monotonic=lambda:host.clock,sleep=lambda duration:setattr(host,'clock',host.clock+duration))
        with patch.dict(os.environ,ANDROID_USER_HOME=str(host.user)),patch.object(capability,'time',timer),self.assertRaises(ValueError):
            host.capabilities_action(host.args)
        result=json.loads((Path(host.args.output)/'run.json').read_bytes())
        self.assertEqual(result['capability_phase'],'FAIL')
        self.assertEqual(set(result['cases']),{'dev/denied'})
        self.assertNotIn('preserve',result['cases']['dev/denied'])
        traces=[json.loads(path.read_bytes()) for path in Path(host.args.output).glob('*.observation/host-receipt.json')]
        self.assertEqual(traces[0]['result'],'FAIL')

    def test_actual_facade_missing_observer_readiness_retains_failed_first_capture(self):
        host=self.facade_campaign('missing-observer-readiness');host.observer_missing_readiness=True;host.args.action='capabilities'
        timer=SimpleNamespace(monotonic=lambda:host.clock,sleep=lambda duration:setattr(host,'clock',host.clock+duration))
        with patch.dict(os.environ,ANDROID_USER_HOME=str(host.user)),patch.object(capability,'time',timer),self.assertRaisesRegex(ValueError,'ui_observer_content_not_ready'):
            host.capabilities_action(host.args)
        result=json.loads((Path(host.args.output)/'run.json').read_bytes())
        self.assertEqual(result['capability_phase'],'FAIL')
        self.assertEqual(set(result['cases']),{'dev/denied'})
        self.assertNotIn('preserve',result['cases']['dev/denied'])
        self.assertEqual(host.logged_clicks,[])
        traces=[json.loads(path.read_bytes()) for path in Path(host.args.output).glob('*.observation/host-receipt.json')]
        self.assertEqual(len(traces),1);self.assertEqual(traces[0]['result'],'FAIL')
        receipts=[json.loads(path.read_bytes()) for path in Path(host.args.output).glob('*.observation/receipt.json.stdout')]
        self.assertEqual(len(receipts),1);self.assertNotIn('readiness',receipts[0])

    def test_make_literal_capability_inputs_and_receiving_paths(self):
        tools=self.root/'make-tools';tools.mkdir();log=self.root/'make-argv.json'
        shim='#!/usr/bin/env python3\nimport json,os,sys\nfrom pathlib import Path\nPath(os.environ["FAKE_ARGV_LOG"]).write_text(json.dumps({"argv":sys.argv[1:],"env":{k:v for k,v in os.environ.items() if k.startswith("ALKION_")}}))\n'
        for name in ('bash','fvm'):
            path=tools/name;path.write_text(shim);path.chmod(0o700)
        canary=self.root/'must-not-execute'
        literal='space "double" \'single\' `touch '+str(canary)+'` $(touch '+str(canary)+') $(shell touch '+str(canary)+') ${HOME}'
        app=Path(__file__).parent.parent
        values={'ALKION_SYNTHETIC_ACTION':'capabilities-check','ALKION_AVD':literal,'ALKION_SERIAL':literal,
                'ALKION_RECEIPT':literal,'ALKION_OUTPUT':literal,'ALKION_BASE_RUN':literal,'ALKION_DRIVER_RUN':literal,
                'ALKION_UPDATES_RUN':literal,'ALKION_VERSION_LEDGER':literal,'ALKION_SOURCE_REVIEW':literal,
                'ALKION_ATTEMPT_MANIFESTS_JSON':json.dumps([literal]),'ALKION_JIT_BUILD_BUDGET':'120','ALKION_PUBLISHER_BUILD':literal}
        flags=('--action','--avd','--serial','--receipt','--output','--base-run','--driver-run','--updates-run',
               '--version-ledger','--source-review','--attempt-manifests-json','--jit-build-budget','--publisher-build')
        expected=['tool/android_synthetic.sh',*(part for flag,value in zip(flags,values.values()) for part in (flag,value))]
        env=dict(os.environ,PATH=str(tools)+os.pathsep+os.environ['PATH'],FAKE_ARGV_LOG=str(log))
        for origin in ('command-line','environment'):
            def invoke(target,inputs):
                command=['make','-C',str(app),target];variables=dict(env)
                if origin=='command-line':command += [key+'='+value for key,value in inputs.items()]
                else:variables.update(inputs)
                completed=subprocess.run(command,env=variables,capture_output=True,text=True,timeout=10)
                self.assertEqual(completed.returncode,0,completed.stderr)
                self.assertFalse(canary.exists())
                return json.loads(log.read_bytes())
            self.assertEqual(invoke('android-synthetic',values)['argv'],expected)
            inputs={key:literal for key in (*capability.DEFINES,'ALKION_FLAVOR')}
            built=invoke('android-synthetic-capability-apk',inputs)
            self.assertEqual(built['argv'],['tool/android_synthetic.sh','--action','build-capability'])
            self.assertTrue(all(built['env'][key]==literal for key in inputs))
            receiving=invoke('alkion-verify-backup',{'ALKION_BACKUP':literal,'ALKION_OUTPUT':literal})
            self.assertEqual(receiving['argv'],['dart','run','tool/alkion_verify_backup.dart','--backup',literal,'--output',literal])

    def test_actual_make_build_route_validates_helper_and_literal_main_without_build(self):
        tools=self.root/'build-tools';tools.mkdir();log=self.root/'fake-fvm.json'
        git=tools/'git';git.write_text('#!/usr/bin/env python3\nimport os,sys\nif sys.argv[3:]==["rev-parse","HEAD"]:print(os.environ["FAKE_SOURCE"])\nelif sys.argv[3:]==["status","--porcelain","--untracked-files=normal"]:print(os.environ.get("FAKE_DIRTY",""),end="")\nelse:raise SystemExit("unexpected fake git command")\n');git.chmod(0o700)
        fvm=tools/'fvm';fvm.write_text('#!/usr/bin/env python3\nimport os,json,sys\nfrom pathlib import Path\nPath(os.environ["FAKE_FVM_LOG"]).write_text(json.dumps(sys.argv[1:]))\n');fvm.chmod(0o700)
        before=snapshot();raw=capability.canonical(self.host.lifecycle)+b'\n';identity=step(raw,before,'dev','denied','prepare',81)
        inputs=dict(zip(capability.DEFINES,map(str,(identity[key] for key in ('run_id','source_commit','prior_source_commit','variant','case_id','phase','version_code','prior_version_code','consumed_version_floor','profile_id','generation','prior_report_sha256','prior_state_digest')))))
        inputs['ALKION_FLAVOR']='dev'
        env=dict(os.environ,PATH=str(tools)+os.pathsep+os.environ['PATH'],ANDROID_HOME=str(self.host.sdk),FAKE_SOURCE=SOURCE,FAKE_FVM_LOG=str(log),PYTHONDONTWRITEBYTECODE='1')
        base=['make','-C',str(Path(__file__).parent.parent),'android-synthetic-capability-apk']
        for phase in ('prepare','main'):
            values=dict(inputs,ALKION_CAPABILITY_PHASE=phase)
            completed=subprocess.run(base+[key+'='+value for key,value in values.items()],env=env,capture_output=True,text=True,timeout=10)
            self.assertEqual(completed.returncode,0,completed.stderr)
            self.assertEqual(json.loads(log.read_bytes()),capability.capability_build_arguments(values)[1:])
        saved=log.read_bytes()
        for overrides,environment in (({'ALKION_PRIOR_REPORT_SHA256':'bad'},{}),({}, {'FAKE_DIRTY':' M source'}),({}, {'FAKE_SOURCE':'0'*40})):
            values=dict(inputs,**overrides)
            completed=subprocess.run(base+[key+'='+value for key,value in values.items()],env=dict(env,**environment),capture_output=True,text=True,timeout=10)
            self.assertNotEqual(completed.returncode,0)
            self.assertEqual(log.read_bytes(),saved)

    def test_capability_cli_missing_identity_refuses_before_device(self):
        for action in ('capabilities-check','capabilities'):
            completed=subprocess.run(['bash',str(Path(__file__).with_name('android_synthetic.sh')),'--action',action],capture_output=True,text=True,timeout=10)
            self.assertNotEqual(completed.returncode,0)
            self.assertIn('explicit_emulator_serial_required',completed.stderr)

    def test_reviewed_source_delta_allows_only_exact_new_observer_paths(self):
        paths=sorted(('app/tool/android_synthetic_ui.py','app/tool/android_synthetic_ui_self_test.py',
                      'app/tool/android_synthetic_ui/AndroidManifest.xml','app/tool/android_synthetic_ui/HierarchyInstrumentation.java'))
        review=self.root/'source-review.json';self.host.args.source_review=str(review)
        self.host.write(review,{'format':'alkion-capability-source-review/1','result':'PASS','base_source_commit':'b'*40,'source_commit':SOURCE,'changed_paths':paths})
        original=self.host.command
        def command(argv,**options):
            if 'diff' in argv:return response('\n'.join(paths)+'\n')
            return original(argv,**options)
        with patch.object(self.host,'command',command):
            capability.provenance(self.host,self.host.args,'b'*40,SOURCE)
            paths.append('app/lib/unreviewed.dart')
            self.host.write(review,{'format':'alkion-capability-source-review/1','result':'PASS','base_source_commit':'b'*40,'source_commit':SOURCE,'changed_paths':paths})
            with self.assertRaisesRegex(capability.Refusal,'unreviewed_or_runtime_source_change'):
                capability.provenance(self.host,self.host.args,'b'*40,SOURCE)


if __name__ == "__main__":
    print("Capability host controls only: fake commands and synthetic parser/report inputs; Android proof UNRUN.", flush=True)
    unittest.main(verbosity=2)
