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
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch
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


# Separate captured states used by the host reissue simulation, not a captured
# app recovery: caller-only focus, settled shade title/action and their ancestors.
CAPTURED_CALLER_FOCUS = "  mCurrentFocus=Window{a74c3ba u0 dev.animusstudio.alkion.dev/dev.animusstudio.alkion.MainActivity}\n"
CAPTURED_SHADE_FOCUS = "  mCurrentFocus=Window{c4ee37 u0 NotificationShade}\n"
CAPTURED_SHADE = (
    (None, 'com.android.systemui:id/legacy_window_root', 'android.widget.FrameLayout', '[0,0][1080,2400]', '', '', 'false', 'true', 'true'),
    (0, 'com.android.systemui:id/shared_notification_container', 'android.view.ViewGroup', '[0,0][1080,2400]', '', '', 'false', 'true', 'true'),
    (1, 'com.android.systemui:id/notification_stack_scroller', 'android.widget.ScrollView', '[0,0][1080,2190]', '', '', 'false', 'true', 'true'),
    (2, 'com.android.systemui:id/expandableNotificationRow', 'android.widget.FrameLayout', '[42,716][1038,1180]', '', '', 'true', 'true', 'true'),
    (3, 'com.android.systemui:id/expanded', 'android.widget.FrameLayout', '[42,716][1038,1180]', '', '', 'false', 'true', 'true'),
    (4, 'android:id/status_bar_latest_event_content', 'android.widget.FrameLayout', '[42,716][1038,1180]', '', '', 'false', 'true', 'true'),
    (5, 'android:id/notification_action_list_margin_target', 'android.widget.LinearLayout', '[42,716][1038,1180]', '', '', 'false', 'true', 'true'),
    (6, '', 'android.widget.FrameLayout', '[42,716][1038,1022]', '', '', 'false', 'true', 'true'),
    (7, 'android:id/notification_main_column', 'android.widget.LinearLayout', '[179,847][996,1022]', '', '', 'false', 'true', 'true'),
    (8, 'android:id/title', 'android.widget.TextView', '[179,847][996,953]', 'Synthetic lifecycle $RUN dev.animusstudio.alkion.dev', '', 'false', 'true', 'true'),
    (6, 'android:id/actions_container', 'android.widget.FrameLayout', '[42,1022][1038,1180]', '', '', 'false', 'true', 'true'),
    (10, 'android:id/actions_container_layout', 'android.widget.LinearLayout', '[42,1022][1038,1180]', '', '', 'false', 'true', 'true'),
    (11, 'android:id/actions', 'android.widget.LinearLayout', '[42,1022][1006,1180]', '', '', 'false', 'true', 'true'),
    (12, 'android:id/action0', 'android.widget.Button', '[147,1038][294,1164]', '+30S', '+30s', 'true', 'true', 'true'),
)


def captured_shade():
    tree, nodes = ET.Element("hierarchy", rotation="0"), []
    for parent, resource, cls, bounds, text, desc, clickable, enabled, visible in CAPTURED_SHADE:
        node = ET.SubElement(tree if parent is None else nodes[parent], "node", {
            "package": "com.android.systemui", "resource-id": resource, "class": cls, "bounds": bounds,
            "text": text.replace("$RUN", RUN), "content-desc": desc, "clickable": clickable,
            "enabled": enabled, "visible-to-user": visible})
        nodes.append(node)
    return tree


ADB = r'''#!/usr/bin/env python3
import datetime,hashlib,json,os,shlex,subprocess,sys,time,xml.etree.ElementTree as ET
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
elif cmd==["dumpsys","package",package]: print("versionCode="+str(config.get("live_version",config["version"])))
elif cmd[:3]==["pm","list","packages"]: print("package:"+package+" uid:"+str(10223 if mode=="helper-uid" else 10222))
elif cmd==["dumpsys","activity","activities"] and config.get("focus_sequence") is not None:
 state=root/"focus-sequence"; index=int(state.read_text()) if state.exists() else 0
 state.write_text(str(index+1)); values=config["focus_sequence"]
 print(values[min(index,len(values)-1)])
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
 receipt={"format":"alkion-android-ui-observation/1","diagnostic_schema":"alkion-ui-window-facts/1",**values,"complete":True,"result":"PASS",
  "observer_package":package,"observer_version":config["version"],"observer_uid":10222,
  "root_package":config["package"],"display_id":0,"window_id":7,"window_type":3,
  "window_active":True,"window_focused":True,"rotation":0,"width":1080,"height":2400,
  "elapsed_ms":20,"node_count":raw.count(b"<node "),"xml_length":len(raw),
  "xml_sha256":hashlib.sha256(raw).hexdigest(),"captured_at":datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00","Z")}
 labels=sum(node.get("visible-to-user")=="true" and any(node.get(key,"").strip(" \t\r\n") for key in ("text","content-desc")) for node in ET.fromstring(raw).iter("node"))
 needs_labels=config["package"] in ("dev.animusstudio.alkion.dev","dev.animusstudio.alkion")
 receipt.update(readiness="visible-label" if needs_labels else "structural",visible_label_count=labels,sample_count=1,candidate_sample=1)
 sample={"index":1,"cache_cleared":mode!="cache-absent","root_available":True,"ready":not needs_labels or labels>0,"elapsed_ms":15,
  "candidate_complete":True,"outcome":"complete" if not needs_labels or labels>0 else "content_not_ready",
  **{key:receipt[key] for key in ("node_count","visible_label_count","window_id","xml_length","xml_sha256")}}
 receipt["samples"]=[sample]
 if mode=="delayed-readiness":
  empty=dict(sample,index=1,ready=False,outcome="content_not_ready",visible_label_count=0,node_count=5,xml_length=1165,xml_sha256="a"*64,elapsed_ms=5)
  absent=dict(sample,index=2,ready=False,root_available=False,candidate_complete=False,outcome="null_root",visible_label_count=0,node_count=0,xml_length=0,xml_sha256="",window_id=-1,elapsed_ms=10)
  receipt.update(samples=[empty,absent,dict(sample,index=3)],sample_count=3,candidate_sample=3)
 if mode=="native-not-ready": receipt.update(result="FAIL",error="readiness_sample_limit")
 if mode.startswith("mixed-") or mode.startswith("partial-"):
  absent=dict(sample,index=1,ready=False,root_available=False,candidate_complete=False,outcome="null_root",
   visible_label_count=0,node_count=0,xml_length=0,xml_sha256="",window_id=-1,elapsed_ms=2)
  empty=dict(sample,index=2,ready=False,outcome="content_not_ready",visible_label_count=0,node_count=5,
   xml_length=1165,xml_sha256="a"*64,elapsed_ms=5)
  incomplete=dict(sample,index=3,ready=False,candidate_complete=False,outcome="incomplete_child",
   visible_label_count=0,node_count=0,xml_length=0,xml_sha256="",elapsed_ms=10)
  receipt.update(samples=[absent,empty,incomplete,dict(sample,index=4)],sample_count=4,candidate_sample=4)
  if mode=="partial-final": receipt["samples"][-1].update(candidate_complete=False,outcome="incomplete_child")
  if mode=="partial-count": incomplete["node_count"]=1
  if mode=="partial-hash": incomplete.update(xml_length=1,xml_sha256="a"*64)
  if mode=="partial-window": incomplete["window_id"]=8
  if mode=="partial-complete": incomplete["candidate_complete"]=True
  if mode=="partial-ready": incomplete["ready"]=True
  if mode=="mixed-unknown": incomplete["outcome"]="pending"
  if mode=="mixed-stale": receipt["candidate_sample"]=2
  if mode=="mixed-final-hash": receipt["samples"][-1]["xml_sha256"]="a"*64
 if mode=="outcome-missing": del sample["outcome"]
 if mode=="candidate-complete-missing": del sample["candidate_complete"]
 if mode=="native-v2": receipt["observer_version"]=2
 if mode in ("native-incomplete-no-xml","native-fail-foreign","native-fail-malformed"):
  incomplete=dict(sample,ready=False,candidate_complete=False,outcome="incomplete_child",visible_label_count=0,
   node_count=0,xml_length=0,xml_sha256="")
  receipt.update(result="FAIL",error="java.lang.IllegalStateException: readiness_sample_limit",elapsed_ms=3901,
   samples=[dict(incomplete,index=i,elapsed_ms=(i-1)*100) for i in range(1,41)],sample_count=40)
  for key in ("candidate_sample","root_package","window_id","window_type","window_active","window_focused",
   "display_id","rotation","width","height","node_count","visible_label_count","xml_length","xml_sha256"):
   receipt.pop(key,None)
  if mode=="native-fail-foreign": receipt["source_commit"]="f"*40

 if mode=="sample-window": sample["window_id"]=99
 if mode=="sample-late": sample["elapsed_ms"]=5000
 if mode=="sample-counter": sample["node_count"]+=1
 if mode=="sample-cache-unknown": sample["cache_cleared"]="unknown"
 if mode=="sample-early-ready": receipt["samples"]=[dict(sample),dict(sample,index=2)];receipt.update(sample_count=2,candidate_sample=2)
 changes={"readiness":"foreign","visible_label_count":999,"sample_count":0,"candidate_sample":40,
  "observer_version":1,"run_id":"f"*32,"source_commit":"f"*40,"request_id":"f"*32,"root_package":"foreign.package",
  "xml_sha256":"0"*64,"node_count":999,"display_id":1,"window_active":False,
  "window_focused":False,"elapsed_ms":9000,"captured_at":"2000-01-01T00:00:00Z","result":"FAIL"}
 if mode in changes: receipt[mode]=changes[mode]
 if mode=="forty-samples":
  sample["window_id"]=2147483647;receipt["window_id"]=2147483647
  empty=dict(sample,ready=False,candidate_complete=True,outcome="content_not_ready",visible_label_count=0,
   node_count=4096,xml_length=1048576,xml_sha256="a"*64)
  receipt.update(samples=[dict(empty,index=i,elapsed_ms=(i-1)*100) for i in range(1,40)]+[dict(sample,index=40,elapsed_ms=3900)],
   sample_count=40,candidate_sample=40,elapsed_ms=3901)
 facts=("cache_cleared","root_available","root_package","node_window_id","window_present","window_id",
        "window_type","display_id","window_active","window_focused")
 for item in receipt["samples"]:
  outcome=item.get("outcome"); item.update(stage=outcome,observed=list(facts),exception=None,exception_class=None,
   root_package=config["package"],node_window_id=receipt.get("window_id",item.get("window_id")),window_present=True,window_type=3,display_id=0,
   window_active=True,window_focused=True)
  if outcome=="null_root":
   item.update(observed=list(facts[:2]),root_available=False)
   for key in facts[2:]: item[key]=None
 if mode=="native-v3": receipt["observer_version"]=3
 if mode=="live-v3": receipt["observer_version"]=3
 if mode=="window-readiness":
  final=receipt["samples"][-1]
  absent=dict(final,index=1,stage="window_absent",outcome="window_absent",observed=list(facts[:5]),
   window_present=False,window_id=None,window_type=None,display_id=None,window_active=None,window_focused=None,
   candidate_complete=False,ready=False,node_count=0,visible_label_count=0,xml_length=0,xml_sha256="",elapsed_ms=1)
  inactive=dict(final,index=2,stage="window_not_ready",outcome="window_not_ready",window_active=False,
   candidate_complete=False,ready=False,node_count=0,visible_label_count=0,xml_length=0,xml_sha256="",elapsed_ms=2)
  unfocused=dict(inactive,index=3,window_active=True,window_focused=False,elapsed_ms=3)
  receipt.update(samples=[absent,inactive,unfocused,dict(final,index=4)],sample_count=4,candidate_sample=4)
 if mode in ("diag-pinned-id","diag-pinned-type"):
  final=receipt["samples"][-1]
  prior=dict(final,index=1,ready=False,candidate_complete=False,node_count=0,visible_label_count=0,
   xml_length=0,xml_sha256="",elapsed_ms=1)
  if mode=="diag-pinned-id":
   prior.update(outcome="window_absent",stage="window_absent",observed=list(facts[:5]),node_window_id=8,
    window_present=False,window_id=None,window_type=None,display_id=None,window_active=None,window_focused=None)
  else: prior.update(outcome="window_not_ready",stage="window_not_ready",window_type=1,window_active=False)
  receipt.update(samples=[prior,dict(final,index=2)],sample_count=2,candidate_sample=2)
 if mode in ("native-getter-fail","fail-diag-missing","fail-diag-unobserved"):
  final=receipt["samples"][-1]
  final.update(outcome="fatal",stage="window_focused",observed=list(facts[:9]),window_focused=None,
   ready=False,candidate_complete=False,node_count=0,visible_label_count=0,xml_length=0,xml_sha256="",
   exception="java.lang.SecurityException: window_not_ready",exception_class="java.lang.SecurityException")
  receipt.update(result="FAIL",error=final["exception"])
  if mode=="fail-diag-missing": del final["stage"]
  if mode=="fail-diag-unobserved": final["window_focused"]=False
 if mode.startswith("diag-"):
  final=receipt["samples"][-1]
  if mode=="diag-schema": del receipt["diagnostic_schema"]
  elif mode=="diag-missing": del final["window_present"]
  elif mode=="diag-missing-stage": del final["stage"]
  elif mode=="diag-missing-observed": del final["observed"]
  elif mode=="diag-unobserved": final["observed"]=list(facts[:2])
  elif mode=="diag-stage": final["stage"]="window_absent"
  elif mode=="diag-flag": final["window_active"]=False
  elif mode=="diag-id": final["node_window_id"]=8
  elif mode=="diag-type": final["window_type"]=1
  elif mode=="diag-observed-order": final["observed"]=list(reversed(facts))
  elif mode=="diag-fake-null": final.update(stage="window_absent",outcome="window_absent",candidate_complete=False,ready=False)
  elif mode=="diag-fatal": final.update(outcome="fatal",stage="window_focused",candidate_complete=False,ready=False)
 if mode=="receipt-oversize-fail": receipt["result"]="FAIL"
 encoded=json.dumps(receipt,separators=(",",":"))
 if mode in ("receipt-oversize-pass","receipt-oversize-fail"): encoded+= " "*(65537-len(encoded))
 if mode=="receipt-partial": encoded="{"
 (target/"receipt.json").write_text("{" if mode=="native-fail-malformed" else encoded);(target/"hierarchy.xml").write_bytes(raw)
 if mode in ("native-incomplete-no-xml","native-fail-foreign","native-fail-malformed","native-getter-fail","fail-diag-missing","fail-diag-unobserved"): (target/"hierarchy.xml").unlink()
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


class ControlledClock:
    def __init__(self):
        self.elapsed = 0.0
        self.epoch = time.time()
        self.pauses = []

    def monotonic(self):
        return self.elapsed

    def time(self):
        return self.epoch + self.elapsed

    def sleep(self, seconds):
        if not 0 < seconds <= 0.1:
            raise AssertionError("pause outside focused sampling contract")
        self.pauses.append(seconds)
        self.advance(seconds)

    def advance(self, seconds):
        self.elapsed = round(self.elapsed + seconds, 12)


class Protocol(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="alkion-ui-host-")
        self.root = Path(self.temporary.name); (self.root / "device").mkdir()
        (self.root / "commands").touch()
        tools = self.root / "sdk/platform-tools"; tools.mkdir(parents=True)
        self.adb = tools / "adb"; self.adb.write_text(ADB); self.adb.chmod(0o755)
        self.mode = "valid"; self.package = "com.android.systemui"
        self.focus_sequence = None; self.clock = None; self.costs = {}; self.timed_calls = []
        self.facts = {"package": PACKAGE, "version_code": observer.VERSION, "apk_sha256": "d" * 64, "certificate_sha256": "e" * 64}
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
        (self.root / "config").write_text(json.dumps({"mode": self.mode, "package": self.package, "hash": self.facts["apk_sha256"],
            "version": observer.VERSION, "live_version": 1 if self.mode == "live-v1" else 2 if self.mode == "live-v2" else 3 if self.mode == "live-v3" else observer.VERSION,
            "focus_sequence": self.focus_sequence}))
        (self.root / "tree.xml").write_bytes(ET.tostring(self.tree, encoding="utf-8", xml_declaration=True))

    def command(self, argv, *, binary=False, check=True, timeout=30, **kwargs):
        self.configure()
        env = dict(os.environ, UI_TEST_ROOT=str(self.root))
        tail = list(map(str, argv[3:]))
        native = shlex.split(tail[1]) if tail[0] == "shell" else tail
        if ((self.mode == "instrument-timeout" and native[:2] == ["am", "instrument"]) or
                (self.mode == "screenshot-timeout" and native[:2] == ["exec-out", "screencap"])):
            timeout = min(timeout, 0.1)
        if self.clock is not None:
            self.timed_calls.append({"native": native, "started": self.clock.monotonic(), "timeout": timeout})
        try:
            result = subprocess.run([str(x) for x in argv], capture_output=True, text=not binary,
                                    timeout=timeout, env=env)
        except subprocess.TimeoutExpired:
            if self.clock is not None:
                self.clock.advance(timeout)
            raise
        if self.clock is not None:
            self.clock.advance(self.costs.get(tuple(native), 0))
        is_receipt = native[:2] == ["run-as", PACKAGE] and any(str(value).endswith("/receipt.json") for value in native)
        if self.mode == "receipt-late" and is_receipt:
            self.clock.advance(20)
        if self.mode == "receipt-overflow-transport" and is_receipt:
            result = subprocess.CompletedProcess(result.args, 0, b"x" * 65537, b"")
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

    def test_shade_reissue_host_simulation_replays_captured_caller_then_settled_shade(self):
        # Actual states from separate runs; this does not claim observed app recovery.
        self.args.ui_expected_package = "dev.animusstudio.alkion.dev"
        self.tree = captured_shade()
        self.focus_sequence = [CAPTURED_CALLER_FOCUS] * 18 + [CAPTURED_SHADE_FOCUS] * 2
        self.clock = ControlledClock(); self.costs[("dumpsys", "activity", "activities")] = 0.014
        title = "Synthetic lifecycle " + RUN + " dev.animusstudio.alkion.dev"
        with patch.object(observer, "time", self.clock):
            self.main["shade_tap"](self.args, self.output, "shade", title, action=True)
        self.assertEqual(sum(cmd == ["cmd", "statusbar", "expand-notifications"] for cmd in self.commands()), 2)
        self.assertEqual([cmd for cmd in self.commands() if cmd[:2] == ["input", "tap"]], [["input", "tap", "220", "1101"]])
        first = json.loads((self.output / "shade-0.observation/host-receipt.json").read_bytes())
        second = json.loads((self.output / "shade-reissue-0.observation/host-receipt.json").read_bytes())
        self.assertEqual((first["result"], len(first["focus_readiness"]["samples"])), ("FAIL", 18))
        self.assertFalse(any(cmd["label"] == "instrument" for cmd in first["commands"]))
        self.assertEqual((second["result"], second["focus_before"]["package"]), ("PASS", "com.android.systemui"))
        for index in range(2):
            path = self.output / ("shade-expand-" + str(index) + ".json")
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            value = json.loads(path.read_bytes())
            self.assertEqual(value["argv"], [str(self.adb), "-s", "emulator-5558", "shell", "cmd statusbar expand-notifications"])
            self.assertEqual((value["code"], value["stdout"], value["stderr"], value["stdout_length"], value["stderr_length"], value["timeout"]),
                             (0, "", "", 0, 0, False))

    def test_shade_persistent_captured_caller_refuses_after_one_reissue_without_tap(self):
        self.args.ui_expected_package = "dev.animusstudio.alkion.dev"
        self.focus_sequence = [CAPTURED_CALLER_FOCUS]
        self.clock = ControlledClock(); self.costs[("dumpsys", "activity", "activities")] = 0.014
        with patch.object(observer, "time", self.clock), self.assertRaisesRegex(self.main["Refusal"], "after_reissue"):
            self.main["shade_tap"](self.args, self.output, "persistent", TITLE, action=True)
        self.assertEqual(sum(cmd == ["cmd", "statusbar", "expand-notifications"] for cmd in self.commands()), 2)
        self.assertFalse(any(cmd[:1] == ["input"] or cmd[:2] == ["am", "instrument"] for cmd in self.commands()))
        self.assertTrue((self.output / "persistent-0.observation/host-receipt.json").is_file())
        self.assertTrue((self.output / "persistent-reissue-0.observation/host-receipt.json").is_file())

    def test_shade_reissues_only_exact_typed_nonempty_known_caller_focus(self):
        caller = "dev.animusstudio.alkion.dev"
        class DerivedFocus(observer.FocusNotReady): pass
        cases = [(observer.FocusNotReady("ui_observer_expected_focus_not_ready", owners), caller)
                 for owners in ((), (None,), (caller, None), (caller, "foreign.package"), ("foreign.package",))]
        cases += [(observer.FocusNotReady("other", (caller,)), caller),
                  (DerivedFocus("ui_observer_expected_focus_not_ready", (caller,)), caller),
                  (observer.Refusal("ui_observer_expected_focus_not_ready"), caller),
                  (observer.FocusNotReady("ui_observer_expected_focus_not_ready", (caller,)), None),
                  (observer.FocusNotReady("ui_observer_expected_focus_not_ready", (caller,)), "foreign.package"),
                  (observer.FocusNotReady("ui_observer_expected_focus_not_ready", (caller,)), "dev.animusstudio.alkion"),
                  (ValueError("malformed"), caller), (subprocess.TimeoutExpired("observer", 2), caller)]
        for index, (error, expected) in enumerate(cases):
            output = self.root / ("refused-" + str(index)); output.mkdir()
            self.args.ui_expected_package = expected
            def failed(*args, **kwargs): raise error
            before = len(self.commands())
            with self.subTest(index=index), patch.dict(self.main, ui_document=failed), self.assertRaises(type(error)):
                self.main["shade_tap"](self.args, output, "shade", TITLE, action=True)
            self.assertEqual(self.commands()[before:], [["cmd", "statusbar", "expand-notifications"]])

    def test_shade_expansion_failure_receipts_precede_refusal_and_bound_streams(self):
        caller = "dev.animusstudio.alkion.dev"; self.args.ui_expected_package = caller
        def unavailable(*args, **kwargs):
            raise observer.FocusNotReady("ui_observer_expected_focus_not_ready", (caller,) * 18)
        responses = [subprocess.CompletedProcess([], 0, "unexpected", ""),
                     subprocess.CompletedProcess([], 0, "", "diagnostic"),
                     subprocess.CompletedProcess([], 1, "", "failed"),
                     subprocess.CompletedProcess([], 0, "x" * 5000, ""),
                     subprocess.TimeoutExpired("native expand", 5, output=b"partial-stdout", stderr=b"first error\nstack tail")]
        for second in (False, True):
            for index, response in enumerate(responses):
                output = self.root / ("native-" + str(second) + "-" + str(index)); output.mkdir()
                calls = []
                def native(args, *tail, **kwargs):
                    calls.append(tail)
                    self.assertEqual(kwargs, {"check": False, "timeout": 5})
                    if second and len(calls) == 1: return subprocess.CompletedProcess([], 0, "", "")
                    if isinstance(response, Exception): raise response
                    return response
                with self.subTest(second=second, index=index), patch.dict(self.main, adb=native, ui_document=unavailable):
                    with self.assertRaises((self.main["Refusal"], subprocess.TimeoutExpired)):
                        self.main["shade_tap"](self.args, output, "shade", TITLE, action=True)
                self.assertEqual(len(calls), 2 if second else 1)
                receipt = json.loads((output / ("shade-expand-" + str(int(second)) + ".json")).read_bytes())
                self.assertEqual(receipt["argv"], [str(self.adb), "-s", "emulator-5558", "shell", "cmd statusbar expand-notifications"])
                self.assertLessEqual(len(receipt["stdout"]), 4096); self.assertLessEqual(len(receipt["stderr"]), 4096)
                if isinstance(response, subprocess.TimeoutExpired):
                    self.assertIsNone(receipt["code"]); self.assertTrue(receipt["timeout"])
                    self.assertEqual((receipt["stdout"], receipt["stderr"]), ("partial-stdout", "first error\nstack tail"))
                else:
                    self.assertEqual(receipt["code"], response.returncode)
                    self.assertEqual(receipt["stdout_length"], len(response.stdout))
                    self.assertEqual(receipt["stderr_length"], len(response.stderr))
                    self.assertEqual(receipt["stdout_truncated"], len(response.stdout) > 4096)

    def test_explicit_variant_and_three_argument_documents_capture(self):
        for index, package in enumerate(("dev.animusstudio.alkion.dev", "com.android.documentsui", "com.android.permissioncontroller")):
            self.package = package; self.tree = hierarchy(package)
            if package == "com.android.documentsui":
                document = self.main["ui_document"](self.args, self.output, "variant-" + str(index))
                trace = json.loads((self.output / ("variant-" + str(index) + ".observation/host-receipt.json")).read_bytes())
                self.assertIsNone(trace["focus_readiness"]["expected_package"])
                self.assertEqual(len(trace["focus_readiness"]["samples"]), 1)
            else:
                document = self.main["ui_document"](self.args, self.output, "variant-" + str(index), expected_package=package)
            self.assertEqual(document[0].get("package"), package)

    def test_explicit_wrong_focus_refuses(self):
        self.clock = ControlledClock()
        with patch.object(observer, "time", self.clock):
            self.refuses(lambda: observer.capture(self.host, self.args, self.output, "capture", "dev.animusstudio.alkion.dev"))
        self.assertFalse(any(cmd[:2] == ["am", "instrument"] for cmd in self.commands()))

    def focus_state(self, package="com.android.systemui", token="shade", user=0):
        label = "NotificationShade" if package == "com.android.systemui" else package + "/.MainActivity"
        return "  mCurrentFocus=Window{" + token + " u" + str(user) + " " + label + "}"

    def trace(self):
        return json.loads((self.output / "capture.observation/host-receipt.json").read_bytes())

    def slow_identity(self, seconds):
        self.costs = {tuple(call): seconds for call in (
            ["pm", "path", PACKAGE], ["sha256sum", "/data/app/fake/base.apk"],
            ["dumpsys", "package", PACKAGE], ["pm", "list", "packages", "-U", "--user", "0", PACKAGE])}

    def null_focus_state(self):
        return ("ACTIVITY MANAGER ACTIVITIES (dumpsys activity activities)\n"
                "  mCurrentFocus=null\n"
                "  mFocusedApp=ActivityRecord{previous u0 com.android.launcher3/.uioverrides.QuickstepLauncher t15}\n"
                "  mStartingProcessActivities=[ActivityRecord{starting u0 "
                "dev.animusstudio.alkion.dev/.MainActivity t18}]")

    def test_canonical_null_then_expected_app_keeps_nonadmitting_sample(self):
        self.package = "dev.animusstudio.alkion.dev"; self.tree = hierarchy(self.package)
        absent = self.null_focus_state(); app = self.focus_state(self.package, "cold-app")
        self.focus_sequence = [absent, app, app]; self.clock = ControlledClock()
        with patch.object(observer, "time", self.clock): document = self.observe()
        self.assertEqual(document[0].get("package"), self.package)
        trace = self.trace(); samples = trace["focus_readiness"]["samples"]
        self.assertEqual([value["ready"] for value in samples], [False, True])
        self.assertIsNone(samples[0]["owner"])
        self.assertEqual(trace["focus_before"], samples[1]["owner"])
        self.assertEqual(trace["focus_before"]["token"], "cold-app")
        self.assertEqual((self.output / "capture.observation/focus-before.stdout").read_text().strip(), absent)
        self.assertAlmostEqual(self.clock.elapsed, 0.1)
        self.assertEqual(sum(cmd[:2] == ["am", "instrument"] for cmd in self.commands()), 1)
        self.assertFalse(any(cmd[:1] == ["input"] or cmd[:2] in (["am", "start"], ["cmd", "statusbar"])
                             for cmd in self.commands()))

    def test_repeated_null_stops_at_twenty_samples_without_native_observation(self):
        self.focus_sequence = [self.null_focus_state()]; self.clock = ControlledClock()
        with patch.object(observer, "time", self.clock): self.refuses()
        samples = self.trace()["focus_readiness"]["samples"]
        self.assertEqual(len(samples), 20)
        self.assertTrue(all(value["owner"] is None and not value["ready"] for value in samples))
        self.assertLess(self.clock.elapsed, 2)
        self.assertEqual(len(self.clock.pauses), 19)
        self.assertEqual(len(list((self.output / "capture.observation").glob("focus-before*.stdout"))), 20)
        self.assertFalse(any(cmd[:2] == ["am", "instrument"] for cmd in self.commands()))
        self.assertEqual((self.output / "capture.observation/screenshot.stdout").read_bytes(), PNG)

    def test_null_then_expected_arriving_after_two_seconds_refuses(self):
        self.focus_sequence = [self.null_focus_state(), self.focus_state()]
        self.costs = {("dumpsys", "activity", "activities"): 1}; self.clock = ControlledClock()
        with patch.object(observer, "time", self.clock): self.refuses()
        samples = self.trace()["focus_readiness"]["samples"]
        self.assertEqual([value["ready"] for value in samples], [False, True])
        self.assertIsNone(samples[0]["owner"])
        self.assertNotIn("focus_before", self.trace())
        self.assertIn("expected_focus_not_ready", self.trace()["error"])
        queries = [call for call in self.timed_calls if call["native"] == ["dumpsys", "activity", "activities"]]
        self.assertEqual(len(queries), 2)
        self.assertAlmostEqual(queries[1]["timeout"], 0.9)
        self.assertFalse(any(cmd[:2] == ["am", "instrument"] for cmd in self.commands()))

    def test_null_wait_uses_remaining_global_budget_without_late_screenshot(self):
        self.focus_sequence = [self.null_focus_state()]
        self.slow_identity(4.975); self.costs[("dumpsys", "activity", "activities")] = 0.05
        self.clock = ControlledClock()
        with patch.object(observer, "time", self.clock): self.refuses()
        self.assertEqual(self.clock.elapsed, 20)
        self.assertEqual(len(self.trace()["focus_readiness"]["samples"]), 1)
        self.assertIsNone(self.trace()["focus_readiness"]["samples"][0]["owner"])
        self.assertEqual(self.trace()["screenshot_skipped"], "capture_deadline")
        self.assertFalse(any(cmd[:2] in (["am", "instrument"], ["exec-out", "screencap"]) for cmd in self.commands()))
        self.assertTrue(all(0 < value["timeout"] <= 20 - value["started"] for value in self.timed_calls))

    def test_unspecified_owner_null_still_refuses_without_wait(self):
        self.focus_sequence = [self.null_focus_state()]; self.clock = ControlledClock()
        with patch.object(observer, "time", self.clock):
            self.refuses(lambda: observer.capture(self.host, self.args, self.output, "capture"))
        self.assertIsNone(self.trace()["focus_readiness"]["expected_package"])
        self.assertEqual(self.trace()["focus_readiness"]["samples"], [])
        self.assertEqual(self.clock.pauses, [])
        self.assertFalse(any(cmd[:2] == ["am", "instrument"] for cmd in self.commands()))

    def test_post_capture_null_still_refuses_after_null_readiness(self):
        self.focus_sequence = [self.null_focus_state(), self.focus_state(), self.null_focus_state()]
        self.clock = ControlledClock()
        with patch.object(observer, "time", self.clock): self.refuses()
        self.assertEqual(self.trace()["focus_before"]["token"], "shade")
        self.assertIn("focus_ambiguous", self.trace()["error"])
        self.assertEqual(sum(cmd[:2] == ["am", "instrument"] for cmd in self.commands()), 1)
        self.assertAlmostEqual(self.clock.elapsed, 0.1)

    def test_fresh_expected_focus_after_transition_binds_final_token_and_keeps_raw_samples(self):
        app = self.focus_state("dev.animusstudio.alkion.dev", "app")
        shade = self.focus_state()
        self.focus_sequence = [app, app, shade, shade]
        self.clock = ControlledClock()
        with patch.object(observer, "time", self.clock):
            document = self.observe()
        self.assertEqual(document[0].get("package"), "com.android.systemui")
        trace = self.trace(); samples = trace["focus_readiness"]["samples"]
        self.assertEqual([value["ready"] for value in samples], [False, False, True])
        self.assertEqual(trace["focus_before"]["token"], "shade")
        self.assertAlmostEqual(self.clock.elapsed, 0.2)
        for index, raw in enumerate((app, app, shade)):
            label = "focus-before" if index == 0 else "focus-before-" + str(index)
            self.assertEqual((self.output / "capture.observation" / (label + ".stdout")).read_text().strip(), raw.strip())
        self.assertEqual(sum(cmd[:2] == ["am", "instrument"] for cmd in self.commands()), 1)
        self.assertFalse(any(cmd[:1] == ["input"] or cmd[:2] == ["cmd", "statusbar"] for cmd in self.commands()))

    def test_never_expected_focus_stops_at_twenty_samples_without_instrumentation(self):
        self.focus_sequence = [self.focus_state("dev.animusstudio.alkion.dev", "app")]
        self.clock = ControlledClock()
        with patch.object(observer, "time", self.clock): self.refuses()
        trace = self.trace()
        self.assertEqual(len(trace["focus_readiness"]["samples"]), 20)
        self.assertLess(self.clock.elapsed, 2)
        self.assertEqual(len(self.clock.pauses), 19)
        self.assertFalse(any(cmd[:2] == ["am", "instrument"] for cmd in self.commands()))
        self.assertEqual(len(list((self.output / "capture.observation").glob("focus-before*.stdout"))), 20)
        self.assertEqual((self.output / "capture.observation/screenshot.stdout").read_bytes(), PNG)

    def test_expected_focus_returned_at_deadline_refuses_before_instrumentation(self):
        self.focus_sequence = [self.focus_state()]
        self.costs = {("dumpsys", "activity", "activities"): 2}
        self.clock = ControlledClock()
        with patch.object(observer, "time", self.clock): self.refuses()
        self.assertIn("expected_focus_not_ready", self.trace()["error"])
        self.assertTrue(self.trace()["focus_readiness"]["samples"][0]["ready"])
        self.assertFalse(any(cmd[:2] == ["am", "instrument"] for cmd in self.commands()))
        focus = next(value for value in self.timed_calls if value["native"] == ["dumpsys", "activity", "activities"])
        self.assertEqual(focus["timeout"], 2)

    def test_invalid_focus_samples_refuse_immediately_without_wait_or_instrumentation(self):
        for index, raw in enumerate(("not a native focus line", self.focus_state(user=1),
                self.focus_state() + "\n" + self.focus_state(token="duplicate"),
                self.focus_state("foreign.package"), self.focus_state("com.android.launcher3"),
                "mCurrentFocus= null", "mCurrentFocus=NULL", "mCurrentFocus=null trailing",
                "mCurrentFocus", "mCurrentFocus=null\nmCurrentFocus=null",
                "mCurrentFocus=null\n" + self.focus_state(),
                self.focus_state() + "\nmCurrentFocus=null",
                self.focus_state() + "\nmCurrentFocus=malformed",
                "mCurrentFocus=malformed\n" + self.focus_state())):
            with self.subTest(raw=raw):
                self.focus_sequence = [raw]; (self.root / "focus-sequence").unlink(missing_ok=True)
                self.output = self.root / ("bad-focus-" + str(index)); self.output.mkdir()
                self.clock = ControlledClock()
                with patch.object(observer, "time", self.clock): self.refuses()
                self.assertEqual(self.clock.pauses, [])
                self.assertFalse(any(cmd[:2] == ["am", "instrument"] for cmd in self.commands()))

    def test_post_capture_token_drift_still_refuses_after_readiness(self):
        self.focus_sequence = [self.focus_state("dev.animusstudio.alkion.dev", "app"),
                               self.focus_state(), self.focus_state(token="different-shade")]
        self.clock = ControlledClock()
        with patch.object(observer, "time", self.clock): self.refuses()
        self.assertIn("focused_window_changed", self.trace()["error"])
        self.assertEqual(self.trace()["focus_before"]["token"], "shade")
        self.assertEqual(sum(cmd[:2] == ["am", "instrument"] for cmd in self.commands()), 1)

    def test_focus_wait_uses_remaining_global_budget_and_skips_late_failure_screenshot(self):
        self.focus_sequence = [self.focus_state("dev.animusstudio.alkion.dev", "app")]
        self.slow_identity(4.975); self.clock = ControlledClock()
        with patch.object(observer, "time", self.clock): self.refuses()
        self.assertLessEqual(self.clock.elapsed, 20)
        self.assertEqual(len(self.trace()["focus_readiness"]["samples"]), 1)
        self.assertEqual(self.trace()["screenshot_skipped"], "capture_deadline")
        self.assertFalse(any(cmd[:2] in (["am", "instrument"], ["exec-out", "screencap"]) for cmd in self.commands()))
        self.assertTrue(all(0 < value["timeout"] <= 20 - value["started"] for value in self.timed_calls))

    def test_expired_global_budget_never_starts_focus_or_failure_screenshot(self):
        self.slow_identity(5); self.clock = ControlledClock()
        with patch.object(observer, "time", self.clock): self.refuses()
        self.assertEqual(self.clock.elapsed, 20)
        self.assertEqual(self.trace()["screenshot_skipped"], "capture_deadline")
        self.assertFalse(any(cmd[:2] in (["dumpsys", "activity"], ["exec-out", "screencap"]) for cmd in self.commands()))
        self.assertEqual(len(self.timed_calls), 4)
        self.assertTrue((self.output / "capture.observation/helper-uid.stdout").exists())

    def test_global_deadline_timeout_retains_binary_streams_without_late_screenshot(self):
        self.mode = "instrument-timeout"; self.slow_identity(4.975); self.clock = ControlledClock()
        with patch.object(observer, "time", self.clock): self.refuses()
        target = self.output / "capture.observation"
        self.assertIn(b"\xff", (target / "instrument.stdout").read_bytes())
        self.assertIn(b"\xfe", (target / "instrument.stderr").read_bytes())
        self.assertEqual(self.clock.elapsed, 20)
        self.assertEqual(self.trace()["screenshot_skipped"], "capture_deadline")
        self.assertFalse(any(cmd[:2] == ["exec-out", "screencap"] for cmd in self.commands()))

    def test_receipt_identity_bounds_and_failure_controls(self):
        for mode in ("run_id", "source_commit", "request_id", "root_package", "xml_sha256", "node_count", "display_id",
                     "window_active", "window_focused", "elapsed_ms", "captured_at", "result", "helper-uid", "focus-drift",
                     "linked-output", "missing-receipt", "observer_version", "readiness", "visible_label_count",
                     "sample_count", "candidate_sample", "sample-window", "sample-late", "sample-counter",
                     "sample-cache-unknown", "sample-early-ready"):
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
                before = len(self.commands())
                with self.assertRaises((observer.Refusal, self.main["Refusal"])):
                    self.main["shade_tap"](self.args, self.output, "capture", TITLE, action=True)
                self.assertEqual(sum(cmd == ["cmd", "statusbar", "expand-notifications"] for cmd in self.commands()[before:]), 1)
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


    def test_v2_empty_captured_app_shape_blank_and_invisible_labels_refuse(self):
        # The V1 native preview returned this host-only shape while Flutter pixels
        # visibly contained Resume workout. Exercise the actual parser/transport.
        package = "dev.animusstudio.alkion.dev"
        self.package = package
        tree = ET.Element("hierarchy", rotation="0")
        root = ET.SubElement(tree, "node", {"text": "", "content-desc": "", "resource-id": "",
            "package": package, "class": "android.widget.FrameLayout", "clickable": "false",
            "enabled": "true", "visible-to-user": "true", "bounds": "[0,0][1080,2400]"})
        linear = ET.SubElement(root, "node", dict(root.attrib, **{"class": "android.widget.LinearLayout"}))
        content = ET.SubElement(linear, "node", dict(root.attrib, **{"resource-id": "android:id/content"}))
        ET.SubElement(content, "node", dict(root.attrib))
        ET.SubElement(root, "node", dict(root.attrib, **{"class": "android.view.View",
            "resource-id": "android:id/navigationBarBackground", "visible-to-user": "false",
            "bounds": "[0,2274][1080,2400]"}))
        self.assertEqual(len(list(tree.iter("node"))), 5)
        for mode in ("captured-empty", "blank-only", "invisible-only"):
            with self.subTest(mode=mode):
                self.tree = copy.deepcopy(tree)
                if mode == "blank-only": self.tree[0].set("text", " \t\r\n")
                if mode == "invisible-only": self.tree[0][-1].set("text", "Resume workout")
                self.output = self.root / mode; self.output.mkdir()
                self.refuses()
                attempt = self.output / "capture.observation"
                self.assertEqual((attempt / "hierarchy.xml.stdout").read_bytes(), (self.root / "tree.xml").read_bytes())
                self.assertEqual((attempt / "screenshot.stdout").read_bytes(), PNG)

    def test_v2_cache_absent_is_recorded_and_current_labeled_tree_is_accepted(self):
        self.mode = "cache-absent"; self.package = "dev.animusstudio.alkion.dev"; self.tree = hierarchy(self.package)
        self.assertEqual(self.observe()[0][0].get("text"), "Minimize")
        report = json.loads((self.output / "capture.observation/receipt.json.stdout").read_bytes())
        self.assertIs(report["samples"][0]["cache_cleared"], False)
        self.assertEqual(report["visible_label_count"], 2)

    def test_v2_complete_current_sample_after_empty_and_null_journal(self):
        self.mode = "delayed-readiness"; self.package = "dev.animusstudio.alkion.dev"; self.tree = hierarchy(self.package)
        self.assertEqual(self.observe()[0][0].get("text"), "Minimize")
        report = json.loads((self.output / "capture.observation/receipt.json.stdout").read_bytes())
        self.assertEqual(report["sample_count"], 3)
        self.assertEqual([sample["ready"] for sample in report["samples"]], [False, False, True])
        self.assertEqual(report["xml_sha256"], report["samples"][-1]["xml_sha256"])

    def test_v2_native_readiness_failure_keeps_candidate_receipt_and_screenshot(self):
        self.mode = "native-not-ready"; self.package = "dev.animusstudio.alkion.dev"; self.tree = hierarchy(self.package)
        for node in self.tree.iter("node"): node.set("text", "")
        self.refuses()
        attempt = self.output / "capture.observation"
        self.assertEqual((attempt / "hierarchy.xml.stdout").read_bytes(), (self.root / "tree.xml").read_bytes())
        self.assertEqual(json.loads((attempt / "receipt.json.stdout").read_bytes())["error"], "readiness_sample_limit")
        self.assertEqual((attempt / "screenshot.stdout").read_bytes(), PNG)

    def test_v1_rejected_by_normal_capture_and_build_binder(self):
        self.facts["version_code"] = 1
        self.refuses()
        self.assertEqual(self.commands(), [["exec-out", "screencap", "-p"]])
        self.facts["version_code"] = observer.VERSION
        self.mode = "live-v1"; self.output = self.root / "live-v1"; self.output.mkdir()
        self.refuses()
        self.assertFalse(any(cmd[:2] == ["am", "instrument"] for cmd in self.commands()))
        host, root, apk, record, receipt = self.retained()
        invalid = copy.deepcopy(record); invalid["apk"]["version_code"] = 1
        with self.assertRaises(observer.Refusal): observer.validate_build(host, self.args, root, invalid)

    def test_v3_mixed_null_empty_incomplete_then_complete_uses_only_final_tree(self):
        self.mode = "mixed-valid"; self.package = "dev.animusstudio.alkion.dev"; self.tree = hierarchy(self.package)
        self.assertEqual(len(list(self.observe().iter("node"))), 3)
        report = json.loads((self.output / "capture.observation/receipt.json.stdout").read_bytes())
        self.assertEqual([sample["outcome"] for sample in report["samples"]],
                         ["null_root", "content_not_ready", "incomplete_child", "complete"])
        self.assertEqual(report["candidate_sample"], 4)
        self.assertEqual(report["node_count"], 3)
        self.assertEqual(report["visible_label_count"], 2)
        self.assertEqual((self.output / "capture.xml.raw").read_bytes(), (self.root / "tree.xml").read_bytes())

    def test_v3_partial_mixed_and_stale_candidate_claims_refuse(self):
        self.package = "dev.animusstudio.alkion.dev"; self.tree = hierarchy(self.package)
        for mode in ("partial-final", "partial-count", "partial-hash", "partial-window", "partial-complete",
                     "partial-ready", "mixed-unknown", "mixed-stale", "mixed-final-hash", "outcome-missing",
                     "candidate-complete-missing"):
            with self.subTest(mode=mode):
                self.mode = mode; self.output = self.root / mode; self.output.mkdir()
                self.refuses()
                self.assertFalse((self.output / "capture.xml.raw").exists())

    def test_v3_bound_native_failure_without_xml_retains_reason_and_refuses_foreign_or_malformed(self):
        self.package = "dev.animusstudio.alkion.dev"; self.tree = hierarchy(self.package)
        for mode in ("native-incomplete-no-xml", "native-fail-foreign", "native-fail-malformed"):
            with self.subTest(mode=mode):
                self.mode = mode; self.output = self.root / mode; self.output.mkdir()
                self.refuses(); trace = self.trace(); target = self.output / "capture.observation"
                self.assertEqual((target / "screenshot.stdout").read_bytes(), PNG)
                self.assertEqual((target / "hierarchy.xml.stdout").read_bytes(), b"")
                self.assertFalse((self.output / "capture.xml.raw").exists())
                if mode == "native-incomplete-no-xml":
                    self.assertEqual(trace["native_failure"]["error"], "java.lang.IllegalStateException: readiness_sample_limit")
                    self.assertIn("native_capture_failed", trace["error"])
                    report = json.loads((target / "receipt.json.stdout").read_bytes())
                    self.assertEqual(len(report["samples"]), 40)
                else:
                    self.assertNotIn("native_failure", trace)
                    self.assertNotIn("native_capture_failed:", trace["error"])

    def test_v4_absent_inactive_and_unfocused_journal_then_complete(self):
        self.mode = "window-readiness"; self.package = "dev.animusstudio.alkion.dev"; self.tree = hierarchy(self.package)
        self.assertEqual(self.observe()[0][0].get("text"), "Minimize")
        report = json.loads((self.output / "capture.observation/receipt.json.stdout").read_bytes())
        samples = report["samples"]
        self.assertEqual([item["outcome"] for item in samples], ["window_absent", "window_not_ready", "window_not_ready", "complete"])
        self.assertIsNone(samples[0]["window_id"])
        self.assertFalse(samples[1]["window_active"]); self.assertTrue(samples[1]["window_focused"])
        self.assertTrue(samples[2]["window_active"]); self.assertFalse(samples[2]["window_focused"])
        self.assertTrue(all(not item["candidate_complete"] and item["xml_length"] == 0 for item in samples[:-1]))

    def test_v4_diagnostic_identity_stage_and_type_forgery_refuses(self):
        for mode in ("diag-schema", "diag-missing", "diag-missing-stage", "diag-missing-observed", "diag-unobserved",
                     "diag-stage", "diag-flag", "diag-id", "diag-type", "diag-observed-order", "diag-fake-null",
                     "diag-fatal", "diag-pinned-id", "diag-pinned-type"):
            with self.subTest(mode=mode):
                self.mode = mode; self.output = self.root / mode; self.output.mkdir()
                self.refuses()
                self.assertFalse((self.output / "capture.xml.raw").exists())

    def test_v4_getter_failure_preserves_stage_and_unobserved_fact_without_xml(self):
        for mode in ("native-getter-fail", "fail-diag-missing", "fail-diag-unobserved"):
            with self.subTest(mode=mode):
                self.mode = mode; self.output = self.root / mode; self.output.mkdir(); self.refuses()
                report = json.loads((self.output / "capture.observation/receipt.json.stdout").read_bytes())
                if mode == "native-getter-fail":
                    self.assertEqual(self.trace()["native_failure"]["error"], "java.lang.SecurityException: window_not_ready")
                    self.assertEqual(report["samples"][0]["stage"], "window_focused")
                    self.assertIsNone(report["samples"][0]["window_focused"])
                    self.assertTrue(report["samples"][0]["window_active"])
                else: self.assertNotIn("native_failure", self.trace())
                self.assertEqual((self.output / "capture.observation/hierarchy.xml.stdout").read_bytes(), b"")
                self.assertFalse((self.output / "capture.xml.raw").exists())

    def test_v4_forty_sample_fixture_passes_actual_bounded_reader(self):
        self.mode = "forty-samples"; self.package = "dev.animusstudio.alkion.dev"; self.tree = hierarchy(self.package)
        self.assertEqual(len(list(self.observe().iter("node"))), 3)
        raw = (self.output / "capture.observation/receipt.json.stdout").read_bytes(); report = json.loads(raw)
        self.assertEqual(report["sample_count"], 40)
        self.assertTrue(16384 < len(raw) <= observer.RECEIPT_LIMIT)
        self.assertEqual(report["samples"][-1]["outcome"], "complete")
        self.assertEqual(report["samples"][0]["window_id"], 2147483647)
        print("PASS forty_sample_receipt_bytes=" + str(len(raw)))

    def test_v4_receipt_oversized_partial_and_late_inputs_refuse_before_admission(self):
        for mode in ("receipt-oversize-pass", "receipt-oversize-fail", "receipt-overflow-transport", "receipt-partial", "receipt-late"):
            with self.subTest(mode=mode):
                self.mode = mode; self.output = self.root / mode; self.output.mkdir(); self.clock = ControlledClock()
                original = json.loads
                with patch.object(observer, "time", self.clock), patch.object(observer.json, "loads", wraps=original) as parse:
                    self.refuses()
                    calls = [call for call in parse.call_args_list if isinstance(call.args[0], bytes)]
                if mode != "receipt-partial": self.assertEqual(calls, [])
                self.assertFalse((self.output / "capture.xml.raw").exists())
                if mode == "receipt-late": self.assertEqual(self.trace()["screenshot_skipped"], "capture_deadline")
                if mode == "receipt-overflow-transport": self.assertIn("receipt_size_invalid", self.trace()["error"])

    def test_v4_normal_binding_live_identity_and_receipt_reject_v3(self):
        host, root, apk, record, receipt = self.retained()
        invalid = copy.deepcopy(record); invalid["apk"]["version_code"] = 3
        with self.assertRaises(observer.Refusal): observer.validate_build(host, self.args, root, invalid)
        self.facts["version_code"] = 3; self.refuses()
        self.assertFalse(any(cmd[:2] == ["am", "instrument"] for cmd in self.commands()))
        self.facts["version_code"] = observer.VERSION
        self.mode = "live-v3"; self.output = self.root / "live-v3"; self.output.mkdir(); self.refuses()
        self.assertFalse(any(cmd[:2] == ["am", "instrument"] for cmd in self.commands()))
        self.mode = "native-v3"; self.output = self.root / "native-v3"; self.output.mkdir(); self.refuses()
        self.assertIn("receipt_identity_changed", self.trace()["error"])

    def test_v3_normal_binding_live_identity_and_receipt_reject_v2(self):
        host, root, apk, record, receipt = self.retained()
        invalid = copy.deepcopy(record); invalid["apk"]["version_code"] = 2
        with self.assertRaises(observer.Refusal): observer.validate_build(host, self.args, root, invalid)
        self.facts["version_code"] = 2
        self.refuses()
        self.assertFalse(any(cmd[:2] == ["am", "instrument"] for cmd in self.commands()))
        self.facts["version_code"] = observer.VERSION
        self.mode = "live-v2"; self.output = self.root / "live-v2"; self.output.mkdir()
        self.refuses()
        self.assertFalse(any(cmd[:2] == ["am", "instrument"] for cmd in self.commands()))
        self.mode = "native-v2"; self.output = self.root / "native-v2"; self.output.mkdir()
        self.refuses()
        self.assertIn("receipt_identity_changed", self.trace()["error"])

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
            package_metadata=lambda args, package: {"version_code": observer.VERSION, "uid": 10222},
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


POLLING_JAVA = r"""
package dev.animusstudio.alkion.synthetic.uiobserver;

import dev.animusstudio.alkion.synthetic.uiobserver.HierarchyInstrumentation.Polling;

public final class PollingControl {
    static final class Clock implements Polling.Clock {
        long time;
        long largestPause;
        public long now() { return time; }
        public void pause(long milliseconds) {
            if (milliseconds <= 0 || milliseconds > 100) throw new AssertionError("invalid_pause");
            largestPause = Math.max(largestPause, milliseconds); time += milliseconds;
        }
    }
    static void check(boolean value) { if (!value) throw new AssertionError("control_failed"); }
    public static void main(String[] args) throws Exception {
        Clock clock = new Clock();
        int[] calls = {0};
        String mode = args[0];
        String expected = null;
        if (mode.equals("setup-deadline")) { clock.time = 5000; expected = "readiness_deadline"; }
        if (mode.equals("never-ready") || mode.equals("null-child-bound")) expected = "readiness_sample_limit";
        if (mode.equals("costly-never-ready") || mode.equals("late-ready") || mode.equals("short-pause")
                || mode.equals("null-child-deadline")) expected = "readiness_deadline";
        if (mode.equals("fatal-window")) expected = "changed_window";
        if (mode.equals("fatal-identity")) expected = "node_package_changed";
        if (mode.equals("fatal-size")) expected = "tree_limit";
        if (mode.equals("fatal-capture-time")) expected = "capture_deadline";
        if (mode.equals("same-message-fatal")) expected = "incomplete_child";
        if (mode.equals("fatal-security")) expected = "security";
        if (mode.equals("late-ready")) clock.time = 4800;
        if (mode.equals("near-deadline")) clock.time = 4400;
        if (mode.equals("short-pause")) clock.time = 4900;
        try {
            int count = Polling.run(clock, index -> {
                check(index == ++calls[0]);
                if (mode.equals("fatal-window")) throw new IllegalStateException("changed_window");
                if (mode.equals("fatal-identity")) throw new IllegalStateException("node_package_changed");
                if (mode.equals("fatal-size")) throw new IllegalStateException("tree_limit");
                if (mode.equals("fatal-capture-time")) throw new IllegalStateException("capture_deadline");
                if (mode.equals("same-message-fatal")) throw new IllegalStateException("incomplete_child");
                if (mode.equals("fatal-security")) throw new SecurityException("security");
                if (mode.equals("null-child-bound")) throw new Polling.IncompleteChild();
                if (mode.equals("null-child-deadline")) { clock.time += 5000; throw new Polling.IncompleteChild(); }
                if (mode.equals("child-then-complete")) {
                    if (index == 1) throw new Polling.IncompleteChild();
                    return true;
                }
                if (mode.equals("mixed-then-complete")) {
                    if (index == 3) throw new Polling.IncompleteChild();
                    return index == 4;
                }
                if (mode.equals("costly-never-ready")) clock.time += 400;
                if (mode.equals("late-ready")) { clock.time += 200; return true; }
                if (mode.equals("near-deadline")) { clock.time += index == 1 ? 250 : 200; return index == 2; }
                if (mode.equals("short-pause")) clock.time += 50;
                return mode.equals("empty-then-ready") && index == 3;
            }, 0);
            check(expected == null);
            if (mode.equals("empty-then-ready")) check(count == 3 && clock.time == 200);
            else if (mode.equals("near-deadline")) check(count == 2 && clock.time == 4950);
            else if (mode.equals("child-then-complete")) check(count == 2 && clock.time == 100);
            else if (mode.equals("mixed-then-complete")) check(count == 4 && clock.time == 300);
            else throw new AssertionError("unrecognized_positive");
        } catch (Exception failure) {
            check(failure.getMessage().equals(expected));
            if (mode.equals("same-message-fatal")) check(failure instanceof IllegalStateException);
            if (mode.equals("fatal-security")) check(failure instanceof SecurityException);
        }
        if (mode.equals("never-ready") || mode.equals("null-child-bound")) check(calls[0] == 40 && clock.time == 3900);
        if (mode.equals("costly-never-ready")) check(calls[0] == 10 && clock.time == 5000);
        if (mode.equals("late-ready") || mode.equals("null-child-deadline") || mode.startsWith("fatal-")
                || mode.equals("same-message-fatal")) check(calls[0] == 1);
        if (mode.equals("setup-deadline")) check(calls[0] == 0);
        if (mode.equals("short-pause")) check(calls[0] == 1 && clock.largestPause == 50 && clock.time == 5000);
        check(clock.time <= 5000);
        System.out.println("PASS " + mode + " calls=" + calls[0] + " elapsed_ms=" + clock.time);
    }
}
"""


WINDOW_JAVA = r"""
package dev.animusstudio.alkion.synthetic.uiobserver;
import java.util.LinkedHashMap;
import java.util.Map;
import dev.animusstudio.alkion.synthetic.uiobserver.HierarchyInstrumentation.Polling;
import dev.animusstudio.alkion.synthetic.uiobserver.HierarchyInstrumentation.WindowAdmission;
public final class WindowControl {
    static void check(boolean value) { if (!value) throw new AssertionError("window_control_failed"); }
    static final class Clock implements Polling.Clock {
        long time;
        public long now() { return time; }
        public void pause(long value) { check(value > 0 && value <= 100); time += value; }
    }
    static final class Journal implements WindowAdmission.Journal {
        String stage;
        final Map<String,Object> known = new LinkedHashMap<>();
        public void stage(String value) { stage = value; }
        public void fact(String key, Object value) { check(!known.containsKey(key)); known.put(key, value); }
    }
    static final class Source implements WindowAdmission.Source {
        String pkg = "expected", faultAt = "";
        int node = 7, window = 7, type = 3, display = 0;
        boolean present = true, active = true, focused = true;
        RuntimeException fault;
        final Map<String,Integer> calls = new LinkedHashMap<>();
        Object read(String key, Object value) {
            check(!calls.containsKey(key)); calls.put(key, 1);
            if (key.equals(faultAt)) throw fault;
            return value;
        }
        public String rootPackage() { return (String) read("root_package", pkg); }
        public int nodeWindowId() { return (Integer) read("node_window_id", node); }
        public boolean windowPresent() { return (Boolean) read("window_present", present); }
        public int windowId() { return (Integer) read("window_id", window); }
        public int windowType() { return (Integer) read("window_type", type); }
        public int displayId() { return (Integer) read("display_id", display); }
        public boolean active() { return (Boolean) read("window_active", active); }
        public boolean focused() { return (Boolean) read("window_focused", focused); }
    }
    public static void main(String[] args) throws Exception {
        String mode = args[0]; Clock clock = new Clock(); WindowAdmission admission = new WindowAdmission();
        int[] calls = {0}, completed = {0}; Journal[] last = {null}; Source[] probe = {null};
        RuntimeException injected = mode.equals("security") ? new SecurityException("window_absent")
            : new IllegalStateException(mode.equals("getter-window_present") ? "window_absent" : "window_not_ready");
        boolean positive = mode.equals("null-then-ready") || mode.equals("inactive-then-ready")
            || mode.equals("unfocused-then-ready") || mode.equals("both-then-ready") || mode.equals("getters-once");
        String expected = null;
        if (mode.equals("null-bound") || mode.equals("flags-bound")) expected = "readiness_sample_limit";
        if (mode.equals("null-deadline") || mode.equals("late-ready")) expected = "readiness_deadline";
        if (mode.equals("invalid-node")) expected = "node_window_id_invalid";
        if (mode.equals("wrong-id-flags")) expected = "window_id_mismatch";
        if (mode.equals("wrong-type")) expected = "window_type_invalid";
        if (mode.equals("wrong-display-flags")) expected = "window_display_changed";
        if (mode.equals("foreign-flags")) expected = "root_package_changed";
        if (mode.equals("id-after-null") || mode.equals("id-after-child")) expected = "sample_window_changed";
        if (mode.equals("type-after-flags")) expected = "sample_window_type_changed";
        if (mode.startsWith("getter-") || mode.equals("security")) expected = injected.getMessage();
        final String reason = expected;
        try {
            int count = Polling.run(clock, index -> {
                calls[0]++; Source source = new Source(); Journal journal = new Journal();
                probe[0] = source; last[0] = journal;
                if ((mode.equals("null-then-ready") || mode.equals("id-after-null")) && index == 1
                        || mode.equals("null-bound") || mode.equals("null-deadline")) source.present = false;
                if ((mode.equals("inactive-then-ready") || mode.equals("both-then-ready") || mode.equals("type-after-flags")) && index == 1
                        || mode.equals("flags-bound")) source.active = false;
                if ((mode.equals("unfocused-then-ready") || mode.equals("both-then-ready")) && index == 1
                        || mode.equals("flags-bound")) source.focused = false;
                if (mode.equals("invalid-node")) source.node = -1;
                if (mode.equals("wrong-id-flags")) { source.window = 8; source.active = false; }
                if (mode.equals("wrong-type")) source.type = 2;
                if (mode.equals("wrong-display-flags")) { source.display = 1; source.active = false; }
                if (mode.equals("foreign-flags")) { source.pkg = "foreign"; source.focused = false; }
                if ((mode.equals("id-after-null") || mode.equals("id-after-child")) && index == 2) source.node = source.window = 8;
                if (mode.equals("type-after-flags") && index == 2) source.type = 1;
                if (mode.startsWith("getter-")) { source.faultAt = mode.substring(7); source.fault = injected; }
                if (mode.equals("security")) { source.faultAt = "window_id"; source.fault = injected; }
                try {
                    WindowAdmission.Facts facts = admission.read(source, "expected", journal);
                    check(facts.rootPackage.equals("expected") && facts.nodeWindowId == 7 && facts.windowId == 7
                        && facts.windowType == 3 && facts.displayId == 0 && facts.active && facts.focused);
                    check(journal.stage.equals("admitted") && journal.known.size() == 8 && source.calls.size() == 8);
                    if (mode.equals("id-after-child") && index == 1) throw new Polling.IncompleteChild();
                    completed[0]++;
                    if (mode.equals("late-ready")) clock.time = 5000;
                    return true;
                } finally {
                    if (mode.equals("null-deadline")) clock.time = 5000;
                    if (source.present == false) {
                        check(source.calls.size() == 3 && journal.known.size() == 3 && admission.pinnedId == 7);
                        check(!journal.known.containsKey("window_id") && !journal.known.containsKey("window_active"));
                    }
                    if (journal.stage.equals("window_not_ready")) {
                        check(journal.known.size() == 8 && source.calls.containsKey("window_focused"));
                        check(admission.pinnedId == 7 && admission.pinnedType == 3);
                    }
                }
            }, 0);
            check(positive && reason == null && completed[0] == 1);
            check(count == (mode.equals("getters-once") ? 1 : 2));
        } catch (Exception failure) {
            check(!positive && reason != null && reason.equals(failure.getMessage()));
            if (mode.startsWith("getter-") || mode.equals("security")) {
                check(failure == injected && last[0].stage.equals(probe[0].faultAt));
                check(!last[0].known.containsKey(probe[0].faultAt));
                check(probe[0].calls.size() == last[0].known.size() + 1 && calls[0] == 1);
            }
            if (mode.equals("wrong-display-flags")) check(!last[0].known.containsKey("window_active"));
            if (mode.equals("id-after-null") || mode.equals("id-after-child")) {
                check(calls[0] == 2 && !last[0].known.containsKey("window_present"));
            }
            if (mode.equals("type-after-flags")) check(calls[0] == 2 && !last[0].known.containsKey("display_id"));
            if (mode.equals("null-bound") || mode.equals("flags-bound")) check(calls[0] == 40 && clock.time == 3900);
            check(completed[0] == (mode.equals("late-ready") ? 1 : 0));
        }
        System.out.println("PASS " + mode + " calls=" + calls[0] + " elapsed_ms=" + clock.time
            + " stage=" + last[0].stage + " known=" + last[0].known.keySet());
    }
}
"""

class ProductionPolling(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="alkion-ui-polling-")
        cls.root = Path(cls.temporary.name)
        cls.java = Path(os.environ.get("JAVA_HOME", "/usr/lib/jvm/java-21-openjdk")) / "bin"
        cls.jar = Path(os.environ.get("ANDROID_SDK_ROOT", os.environ.get("ANDROID_HOME", str(Path.home() / "Android/Sdk")))) / "platforms/android-36/android.jar"
        source = cls.root / "PollingControl.java"; source.write_text(POLLING_JAVA)
        window = cls.root / "WindowControl.java"; window.write_text(WINDOW_JAVA)
        result = subprocess.run([str(cls.java / "javac"), "--release", "17", "-classpath", str(cls.jar),
            "-d", str(cls.root), str(TOOL / "android_synthetic_ui/HierarchyInstrumentation.java"), str(source), str(window)],
            capture_output=True, text=True, timeout=30)
        if result.returncode:
            cls.temporary.cleanup()
            raise AssertionError(result.stdout + result.stderr)

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def test_actual_production_controller_with_scripted_samples_and_monotonic_clock(self):
        for mode in ("empty-then-ready", "near-deadline", "never-ready", "costly-never-ready", "late-ready",
                     "setup-deadline", "short-pause", "fatal-window", "child-then-complete", "mixed-then-complete",
                     "null-child-bound", "null-child-deadline", "same-message-fatal", "fatal-identity", "fatal-size",
                     "fatal-capture-time", "fatal-security"):
            with self.subTest(mode=mode):
                result = subprocess.run([str(self.java / "java"), "-cp", str(self.root) + os.pathsep + str(self.jar),
                    PACKAGE + ".PollingControl", mode], capture_output=True, text=True, timeout=5)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("PASS " + mode, result.stdout)


    def test_actual_window_classifier_getters_facts_and_typed_polling(self):
        modes = ("getters-once", "null-then-ready", "inactive-then-ready", "unfocused-then-ready", "both-then-ready",
                 "null-bound", "flags-bound", "null-deadline", "late-ready", "invalid-node", "wrong-id-flags",
                 "wrong-type", "wrong-display-flags", "foreign-flags", "id-after-null", "id-after-child", "type-after-flags",
                 "getter-root_package", "getter-node_window_id", "getter-window_present", "getter-window_id",
                 "getter-window_type", "getter-display_id", "getter-window_active", "getter-window_focused", "security")
        for mode in modes:
            with self.subTest(mode=mode):
                result = subprocess.run([str(self.java / "java"), "-cp", str(self.root) + os.pathsep + str(self.jar),
                    PACKAGE + ".WindowControl", mode], capture_output=True, text=True, timeout=5)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("PASS " + mode, result.stdout)
                print(result.stdout.strip())


if __name__ == "__main__":
    unittest.main(verbosity=2)
