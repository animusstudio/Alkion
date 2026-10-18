"""Focused host controls: real parser/read shell/ADB argv, no device or native PASS."""
import base64
import copy
import datetime
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
import xml.etree.ElementTree as ET

sys.dont_write_bytecode = True
import android_synthetic_ui as observer

TOOL = Path(__file__).resolve().parent
PACKAGE = observer.PACKAGE
RUN = "1" * 32
SOURCE = "a" * 40
TITLE = "Synthetic observed run"
PNG = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jE1sAAAAASUVORK5CYII=")


def hierarchy(package="com.android.systemui"):
    tree = ET.Element("hierarchy", rotation="0")
    def node(parent, text, resource, clickable, bounds):
        return ET.SubElement(parent, "node", {"text": text, "content-desc": "", "resource-id": resource,
            "package": package, "class": "android.view.View", "clickable": str(clickable).lower(),
            "enabled": "true", "visible-to-user": "true", "bounds": bounds})
    root = node(tree, "", package + ":id/status_bar_latest_event_content", False, "[0,0][1080,2400]")
    node(root, TITLE if package == "com.android.systemui" else "Minimize", package + ":id/title", True, "[20,20][180,80]")
    node(root, "+30s", package + ":id/action", True, "[200,20][320,80]")
    return tree


ADB = r'''#!/usr/bin/env python3
import datetime,hashlib,json,os,shlex,subprocess,sys,time
from pathlib import Path
root=Path(os.environ["UI_TEST_ROOT"]); config=json.loads((root/"config").read_text())
args=sys.argv[1:]; assert args[:2]==["-s","emulator-5558"],args
tail=args[2:]; cmd=shlex.split(tail[1]) if tail[0]=="shell" else tail
with (root/"commands").open("a") as log: log.write(json.dumps(cmd)+chr(10))
package="dev.animusstudio.alkion.synthetic.uiobserver"; mode=config["mode"]
if cmd==["pm","path",package]:
 if mode=="fresh" and not (root/"installed").exists(): raise SystemExit(1)
 print("package:/data/app/fake/base.apk")
elif cmd[:1]==["sha256sum"]: print(config["hash"]+"  "+cmd[1])
elif cmd==["dumpsys","package",package]: print("versionCode=1")
elif cmd[:3]==["pm","list","packages"]: print("package:"+package+" uid:"+str(10223 if mode=="helper-uid" else 10222))
elif cmd==["dumpsys","activity","activities"]:
 state=root/("focused-"+mode); token="abc" if not state.exists() or mode!="focus-drift" else "changed"
 state.write_text("read")
 label="NotificationShade" if config["package"]=="com.android.systemui" else config["package"]+"/.MainActivity"
 print("  mCurrentFocus=Window{"+token+" u0 "+label+"}")
elif cmd[:2]==["am","instrument"]:
 if mode=="instrument-timeout":
  os.write(1,b"partial-native-\xff");os.write(2,b"native-error-\xfe");time.sleep(5)
 values={cmd[i+1]:cmd[i+2] for i,value in enumerate(cmd) if value=="-e"}
 assert cmd[-1]==package+"/.HierarchyInstrumentation"
 target=root/"device"/"files/observations"/values["run_id"]/values["request_id"]
 target.mkdir(parents=True)
 raw=(root/"tree.xml").read_bytes()
 receipt={"format":"alkion-android-ui-observation/1",**values,"complete":True,"result":"PASS",
  "observer_package":package,"observer_version":1,"observer_uid":10222,
  "root_package":config["package"],"display_id":0,"window_id":7,"window_type":3,
  "window_active":True,"window_focused":True,"rotation":0,"width":1080,"height":2400,
  "elapsed_ms":20,"node_count":raw.count(b"<node "),"xml_length":len(raw),
  "xml_sha256":hashlib.sha256(raw).hexdigest(),"captured_at":datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00","Z")}
 changes={"run_id":"f"*32,"source_commit":"f"*40,"request_id":"f"*32,"root_package":"foreign.package",
  "xml_sha256":"0"*64,"node_count":999,"display_id":1,"window_active":False,
  "window_focused":False,"elapsed_ms":9000,"captured_at":"2000-01-01T00:00:00Z","result":"FAIL"}
 if mode in changes: receipt[mode]=changes[mode]
 (target/"receipt.json").write_text(json.dumps(receipt));(target/"hierarchy.xml").write_bytes(raw)
 if mode=="linked-output":
  (target/"hierarchy.xml").unlink();(target/"hierarchy.xml").symlink_to(root/"tree.xml")
 if mode=="missing-receipt": (target/"receipt.json").unlink()
 print("INSTRUMENTATION_CODE: -1")
elif cmd[:2]==["run-as",package]:
 assert cmd[2:4]==["/system/bin/sh","-c"]
 raise SystemExit(subprocess.run(["/bin/sh","-c",*cmd[4:]],cwd=root/"device").returncode)
elif cmd==["exec-out","screencap","-p"]:
 if mode=="screenshot-timeout":
  os.write(1,b"\x89PNG-partial-\xff");os.write(2,b"screenshot-error-\xfe");time.sleep(5)
 os.write(1,(root/"shot.png").read_bytes())
elif cmd==["cmd","statusbar","expand-notifications"]: pass
elif cmd[0]=="install":
 assert len(cmd)==2 and Path(cmd[1]).is_file();(root/"installed").write_text(cmd[1])
elif cmd[:2]==["input","tap"]: pass
else: raise SystemExit("unexpected native command:"+repr(cmd))
'''


class Protocol(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="alkion-ui-host-")
        self.root = Path(self.temporary.name); (self.root / "device").mkdir()
        (self.root / "commands").touch()
        tools = self.root / "sdk/platform-tools"; tools.mkdir(parents=True)
        self.adb = tools / "adb"; self.adb.write_text(ADB); self.adb.chmod(0o755)
        self.mode = "valid"; self.package = "com.android.systemui"
        self.facts = {"package": PACKAGE, "version_code": 1, "apk_sha256": "d" * 64, "certificate_sha256": "e" * 64}
        self.binding = {"format": "alkion-android-ui-binding/1", "run_id": RUN, "serial": "emulator-5558",
            "avd": "ui-host", "uid": 10222, "build": {"format": "alkion-android-ui-build/1",
            "source_commit": SOURCE, "native_source_sha256": observer.native_digest(SimpleNamespace(APP=TOOL.parent)), "apk": self.facts}}
        self.args = SimpleNamespace(sdk=self.root / "sdk", serial="emulator-5558", avd="ui-host",
                                    _ui_observer=(self.binding, SOURCE))
        self.output = self.root / "output"; self.output.mkdir()
        self.tree = hierarchy(); (self.root / "shot.png").write_bytes(PNG)
        self.host = SimpleNamespace(command=self.command, adb=self.transport)
        script = TOOL / "android_synthetic.sh"
        body = script.read_text().split("<<'PY'\n", 1)[1].rsplit("\nPY", 1)[0]
        old = sys.argv; sys.argv = [str(script), str(script)]
        try:
            self.main = {}; exec(compile(body.split("parser = argparse.ArgumentParser(description=__doc__)")[0], str(script), "exec"), self.main)
        finally:
            sys.argv = old
        self.main["ui_module"] = lambda: observer
        self.main["ui_host"] = lambda: self.host
        self.main["adb"] = self.transport

    def tearDown(self):
        self.temporary.cleanup()

    def configure(self):
        (self.root / "config").write_text(json.dumps({"mode": self.mode, "package": self.package, "hash": self.facts["apk_sha256"]}))
        (self.root / "tree.xml").write_bytes(ET.tostring(self.tree, encoding="utf-8", xml_declaration=True))

    def command(self, argv, *, binary=False, check=True, timeout=30, **kwargs):
        self.configure()
        env = dict(os.environ, UI_TEST_ROOT=str(self.root))
        if self.mode in ("screenshot-timeout", "instrument-timeout"):
            timeout = min(timeout, 0.1)
        result = subprocess.run([str(x) for x in argv], capture_output=True, text=not binary,
                                timeout=timeout, env=env)
        if check and result.returncode:
            raise ValueError(result.stderr)
        return result

    def transport(self, args, *tail, **kwargs):
        if tail[0] == "shell": tail = ("shell", shlex.join(str(x) for x in tail[1:]))
        return self.command([self.adb, "-s", args.serial, *tail], **kwargs)

    def commands(self):
        return [json.loads(line) for line in (self.root / "commands").read_text().splitlines()]

    def observe(self):
        return observer.capture(self.host, self.args, self.output, "capture", self.package)

    def refuses(self, operation=None):
        with self.assertRaises((observer.Refusal, ET.ParseError, ValueError, subprocess.TimeoutExpired)):
            (operation or self.observe)()
        self.assertFalse(any(command[:1] == ["input"] for command in self.commands()))
        receipt = json.loads((self.output / "capture.observation/host-receipt.json").read_text())
        self.assertEqual(receipt["result"], "FAIL")

    def test_actual_transport_tree_screenshot_and_semantic_tap(self):
        document = self.observe()
        self.assertEqual(len(list(document.iter("node"))), 3)
        self.assertEqual((self.output / "capture.png").read_bytes(), PNG)
        self.assertEqual((self.output / "capture.xml.raw").read_bytes(), (self.root / "tree.xml").read_bytes())
        self.main["shade_tap"](self.args, self.output, "shade", TITLE, action=True)
        self.assertEqual([command for command in self.commands() if command[:2] == ["input", "tap"]], [["input", "tap", "260", "50"]])

    def test_explicit_variant_and_three_argument_documents_capture(self):
        for index, package in enumerate(("dev.animusstudio.alkion.dev", "com.android.documentsui", "com.android.permissioncontroller")):
            self.package = package; self.tree = hierarchy(package)
            document = self.main["ui_document"](self.args, self.output, "variant-" + str(index), expected_package=package)
            self.assertEqual(document[0].get("package"), package)

    def test_explicit_wrong_focus_refuses(self):
        self.refuses(lambda: observer.capture(self.host, self.args, self.output, "capture", "dev.animusstudio.alkion.dev"))

    def test_receipt_identity_bounds_and_failure_controls(self):
        for mode in ("run_id", "source_commit", "request_id", "root_package", "xml_sha256", "node_count", "display_id",
                     "window_active", "window_focused", "elapsed_ms", "captured_at", "result", "helper-uid", "focus-drift",
                     "linked-output", "missing-receipt"):
            with self.subTest(mode=mode):
                self.mode = mode
                self.output = self.root / ("output-" + mode); self.output.mkdir()
                self.refuses()

    def test_missing_duplicate_semantics_never_tap(self):
        for mode in ("missing-title", "duplicate-title", "missing-row", "missing-action", "duplicate-action"):
            with self.subTest(mode=mode):
                self.tree = hierarchy(); root = self.tree[0]
                if mode == "missing-title": root.remove(root[0])
                if mode == "duplicate-title": root.append(copy.deepcopy(root[0]))
                if mode == "missing-row": root.set("resource-id", "com.android.systemui:id/foreign")
                if mode == "missing-action": root.remove(root[1])
                if mode == "duplicate-action": root.append(copy.deepcopy(root[1]))
                self.output = self.root / mode; self.output.mkdir()
                with self.assertRaises((observer.Refusal, self.main["Refusal"])):
                    self.main["shade_tap"](self.args, self.output, "capture", TITLE, action=True)
                self.assertFalse(any(cmd[:1] == ["input"] for cmd in self.commands()))

    def test_malformed_foreign_oversize_and_bounds_tree(self):
        for mode in ("foreign-node", "oversize", "missing-attribute"):
            with self.subTest(mode=mode):
                self.tree = hierarchy()
                if mode == "foreign-node": self.tree[0][0].set("package", "foreign.package")
                if mode == "oversize": self.tree[0][0].set("text", "x" * (observer.LIMIT + 1))
                if mode == "missing-attribute": del self.tree[0][0].attrib["bounds"]
                self.output = self.root / mode; self.output.mkdir()
                self.refuses()

    def test_native_offscreen_nodes_retained_but_selected_offscreen_target_never_taps(self):
        self.tree[0][1].set("bounds", "[200,2300][320,2450]")
        self.assertEqual(self.observe()[0][1].get("bounds"), "[200,2300][320,2450]")
        with self.assertRaises(self.main["Refusal"]):
            self.main["shade_tap"](self.args, self.output, "offscreen", TITLE, action=True)
        self.assertFalse(any(cmd[:1] == ["input"] for cmd in self.commands()))

    def test_binary_timeout_retains_bytes_and_attempts_failure_screenshot(self):
        for mode in ("instrument-timeout", "screenshot-timeout"):
            with self.subTest(mode=mode):
                self.mode = mode; self.output = self.root / mode; self.output.mkdir()
                self.refuses()
                target = self.output / "capture.observation"
                label = "instrument" if mode.startswith("instrument") else "screenshot"
                self.assertIn(b"\xff", (target / (label + ".stdout")).read_bytes())
                self.assertIn(b"\xfe", (target / (label + ".stderr")).read_bytes())
                self.assertTrue((target / "screenshot.stdout").exists())

    def test_capture_requires_explicit_phase_binding_and_fresh_output(self):
        del self.args._ui_observer
        with self.assertRaises(observer.Refusal): self.observe()
        self.args._ui_observer = (self.binding, SOURCE)
        self.observe()
        with self.assertRaises(FileExistsError): self.observe()

    def test_manifest_and_binding_controls(self):
        manifest = ET.parse(TOOL / "android_synthetic_ui/AndroidManifest.xml").getroot()
        observer.audit_manifest(manifest)
        for mutate in (lambda m: ET.SubElement(m, "uses-permission"),
                       lambda m: m.find("instrumentation").set(observer.ANDROID + "targetPackage", "dev.animusstudio.alkion.dev"),
                       lambda m: ET.SubElement(m.find("application"), "activity")):
            invalid = copy.deepcopy(manifest); mutate(invalid)
            with self.assertRaises(observer.Refusal): observer.audit_manifest(invalid)
        receipt = {key: self.binding[key] for key in ("run_id", "serial", "avd")}
        observer.binding_identity(self.binding, receipt)
        for key in receipt:
            with self.assertRaises(observer.Refusal): observer.binding_identity(self.binding, {**receipt, key: "foreign"})

    def retained(self):
        prior_root = self.root / "prior"; directory = prior_root / "ui-observer"; directory.mkdir(parents=True)
        apk = directory / "synthetic-ui-observer.apk"; apk.write_bytes(b"owned synthetic APK bytes")
        self.facts["apk_sha256"] = observer.digest(apk.read_bytes())
        record = self.binding["build"]
        (directory / "build.json").write_bytes(observer.encoded(record))
        def temporary(value, **unused):
            path = Path(value)
            self.assertTrue(path.is_relative_to(self.root)); self.assertFalse(path.is_symlink())
            return path
        def command(argv, **kwargs):
            if str(argv[0]) == "git":
                return SimpleNamespace(stdout=SOURCE + "\n" if "rev-parse" in argv else "")
            return self.command(argv, **kwargs)
        host = SimpleNamespace(APP=TOOL.parent, command=command, adb=self.transport,
            temporary_path=temporary, read_json=lambda path: json.loads(path.read_bytes()),
            apk_facts=lambda args, path, package: {**self.facts, "apk_sha256": observer.digest(path.read_bytes())},
            package_metadata=lambda args, package: {"version_code": 1, "uid": 10222},
            device_platform_guard=lambda args: None)
        receipt = {key: self.binding[key] for key in ("run_id", "serial", "avd")}
        return host, prior_root, apk, record, receipt

    def test_prior_phase_requires_accepted_facts_and_real_retained_bytes(self):
        host, root, apk, record, receipt = self.retained()
        prior = {**receipt, "format": "alkion-android-run/1", "phase": "lifecycle-initial", "overall": "IN_PROGRESS",
            "initial_lifecycle_phase": "PASS", "source_commit": SOURCE, "ui_observer": self.binding}
        observer.bind_previous(host, self.args, receipt, prior, root, SOURCE)
        self.assertEqual(self.args._ui_observer, (self.binding, SOURCE))
        for change in ({"initial_lifecycle_phase": "FAIL"}, {"source_commit": "b" * 40}, {"run_id": "f" * 32}):
            with self.assertRaises(observer.Refusal): observer.bind_previous(host, self.args, receipt, {**prior, **change}, root, SOURCE)
        apk.write_bytes(b"changed retained APK")
        with self.assertRaises(observer.Refusal): observer.bind_previous(host, self.args, receipt, prior, root, SOURCE)
        self.assertFalse(any(cmd[:1] in (["install"], ["input"]) for cmd in self.commands()))

    def test_fresh_read_only_validation_then_one_install_and_no_adoption(self):
        host, root, apk, record, receipt = self.retained(); self.mode = "fresh"
        self.assertEqual(observer.validate_fresh(host, self.args, receipt, root, record, SOURCE), apk)
        self.assertFalse(any(cmd[:1] == ["install"] for cmd in self.commands()))
        binding = observer.install_fresh(host, self.args, receipt, root, record, SOURCE)
        self.assertEqual(binding, self.binding)
        with self.assertRaises(observer.Refusal): observer.install_fresh(host, self.args, receipt, root, record, SOURCE)
        self.assertEqual(sum(cmd[:1] == ["install"] for cmd in self.commands()), 1)

    def test_fresh_source_zero_or_mismatch_refuses_before_any_transport(self):
        host, root, apk, record, receipt = self.retained(); self.mode = "fresh"
        original = apk.read_bytes()
        for built, current in (("0" * 40, SOURCE), ("b" * 40, SOURCE), ("0" * 40, "0" * 40)):
            with self.subTest(built=built, current=current):
                invalid = {**record, "source_commit": built}
                (root / "ui-observer/build.json").write_bytes(observer.encoded(invalid))
                with self.assertRaisesRegex(observer.Refusal, "fresh_build_source_mismatch"):
                    observer.install_fresh(host, self.args, receipt, root, invalid, current)
                self.assertEqual(self.commands(), [])
                self.assertEqual(apk.read_bytes(), original)


if __name__ == "__main__":
    unittest.main(verbosity=2)
