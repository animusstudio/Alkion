"""Disposable no-idle UI observation. All device access comes from guarded host.

prepare installs once before lifecycle prepare; bind_previous only recognizes
that exact retained helper in later phases. capture never installs or taps.
"""
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import shlex
import stat
import subprocess
import time
import xml.etree.ElementTree as ET
import zipfile

PACKAGE = "dev.animusstudio.alkion.synthetic.uiobserver"
COMPONENT = PACKAGE + "/.HierarchyInstrumentation"
VERSION = 3
LIMIT = 1048576
ROOTS = frozenset(("com.android.systemui", "com.android.documentsui", "com.android.permissioncontroller",
                   "dev.animusstudio.alkion.dev", "dev.animusstudio.alkion"))
ANDROID = "{http://schemas.android.com/apk/res/android}"


class Refusal(ValueError):
    pass


def require(value, reason):
    if not value:
        raise Refusal("ui_observer_" + reason)


def encoded(value):
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def digest(value):
    return hashlib.sha256(value).hexdigest()


def keep(path, data):
    with Path(path).open("xb") as stream:
        os.chmod(path, 0o600)
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())


def source(host):
    value = host.command(["git", "-C", host.APP, "rev-parse", "HEAD"]).stdout.strip()
    require(re.fullmatch(r"[a-f0-9]{40}", value), "source_required")
    require(not host.command(["git", "-C", host.APP, "status", "--porcelain",
                              "--untracked-files=normal"]).stdout.strip(), "reviewed_clean_source_required")
    return value


def native_digest(host):
    root = host.APP / "tool/android_synthetic_ui"
    return digest(encoded({name: digest((root / name).read_bytes()) for name in
                           ("AndroidManifest.xml", "HierarchyInstrumentation.java")}))


def audit_manifest(root):
    require(root.tag == "manifest" and root.get("package") == PACKAGE and
            root.get(ANDROID + "versionCode") == str(VERSION) and
            set(child.tag for child in root) == {"application", "instrumentation"} and
            len(root.findall("application")) == len(root.findall("instrumentation")) == 1 and
            root.get(ANDROID + "sharedUserId") is None, "manifest_boundary_changed")
    app = root.find("application"); runner = root.find("instrumentation")
    require(len(app) == 0 and app.get(ANDROID + "debuggable") == "true" and
            app.get(ANDROID + "allowBackup") == "false" and app.get(ANDROID + "usesCleartextTraffic") == "false" and
            runner.get(ANDROID + "name") == ".HierarchyInstrumentation" and
            runner.get(ANDROID + "targetPackage") == PACKAGE, "self_target_required")


def build(host, args, output, revision):
    user = host.toolchain(args)
    require(re.fullmatch(r"[a-f0-9]{40}", revision), "source_required")
    require(not output.exists(), "build_output_exists")
    fixture = host.APP / "tool/android_synthetic_ui"
    audit_manifest(ET.parse(fixture / "AndroidManifest.xml").getroot())
    key = user / "debug.keystore"
    require(key.is_file() and not key.is_symlink() and key.stat().st_uid == os.getuid() and
            not stat.S_IMODE(key.stat().st_mode) & 0o077, "private_disposable_debug_key_required")
    output.mkdir(mode=0o700); classes = output / "classes"; dex = output / "dex"
    classes.mkdir(); dex.mkdir()
    tools = args.sdk / "build-tools/36.0.0"; jar = args.sdk / "platforms/android-36/android.jar"
    java = Path(os.environ["JAVA_HOME"]) / "bin"
    env = dict(os.environ, PATH=str(java) + os.pathsep + os.environ["PATH"])
    calls = [
        [java / "javac", "--release", "17", "-classpath", jar, "-d", classes, fixture / "HierarchyInstrumentation.java"],
        [tools / "d8", "--min-api", "36", "--lib", jar, "--output", dex],
        [tools / "aapt2", "link", "-I", jar, "--manifest", fixture / "AndroidManifest.xml",
         "--min-sdk-version", "36", "--target-sdk-version", "36", "-o", output / "unsigned.apk"],
    ]
    for index, argv in enumerate(calls):
        if index == 1:
            argv += sorted(classes.rglob("*.class"))
        result = host.command(argv, env=env, check=False, timeout=120)
        keep(output / (str(index) + "-build.stdout"), result.stdout.encode())
        keep(output / (str(index) + "-build.stderr"), result.stderr.encode())
        require(result.returncode == 0, "sdk_build_failed:" + str(index))
    with zipfile.ZipFile(output / "unsigned.apk", "a") as archive:
        archive.write(dex / "classes.dex", "classes.dex")
    host.command([tools / "zipalign", "-f", "4", output / "unsigned.apk", output / "aligned.apk"])
    apk = output / "synthetic-ui-observer.apk"
    host.command([java / "java", "-jar", tools / "lib/apksigner.jar", "sign", "--ks", key,
                  "--ks-key-alias", "androiddebugkey", "--ks-pass", "pass:android", "--key-pass", "pass:android",
                  "--out", apk, output / "aligned.apk"])
    # Parse the actual packaged manifest, not just the input template.
    manifest = host.command([tools / "aapt2", "dump", "xmltree", apk, "--file", "AndroidManifest.xml"]).stdout
    keep(output / "packaged-manifest.txt", manifest.encode())
    require(re.findall(r"E: ([A-Za-z-]+)\b", manifest) == ["manifest", "uses-sdk", "application", "instrumentation"] and
            re.findall(r'android:targetPackage\([^)]*\)="([^"]+)"', manifest) == [PACKAGE] and
            re.findall(r'android:name\([^)]*\)="([^"]+)"', manifest) == [".HierarchyInstrumentation"],
            "packaged_manifest_boundary_changed")
    facts = host.apk_facts(args, apk, PACKAGE)
    require(facts["version_code"] == VERSION, "fixture_version_changed")
    result = {"format": "alkion-android-ui-build/1", "source_commit": revision,
              "native_source_sha256": native_digest(host), "apk": facts}
    keep(output / "build.json", encoded(result))
    return apk, result


def validate_build(host, args, root, record):
    require(isinstance(record, dict) and record.get("format") == "alkion-android-ui-build/1" and
            re.fullmatch(r"[a-f0-9]{40}", record.get("source_commit", "")) and
            record.get("native_source_sha256") == native_digest(host), "native_source_changed")
    apk = host.temporary_path(str(root / "ui-observer/synthetic-ui-observer.apk"), must_exist=True)
    require(host.apk_facts(args, apk, PACKAGE) == record["apk"] and
            record["apk"].get("version_code") == VERSION, "retained_apk_changed")
    return apk


def installed(host, args, binding, execute=None):
    facts = binding["build"]["apk"]
    require(facts.get("package") == PACKAGE and facts.get("version_code") == VERSION,
            "binding_version_changed")
    def read(label, *tail):
        result = execute(label, ["shell", *tail]) if execute else host.adb(args, "shell", *tail)
        require(result.returncode == 0 and not result.stderr, "identity_query_failed")
        value = result.stdout.decode("utf-8") if isinstance(result.stdout, bytes) else result.stdout
        require(len(value) <= LIMIT, "identity_query_too_large")
        return value
    lines = read("helper-path", "pm", "path", PACKAGE).splitlines()
    require(len(lines) == 1 and re.fullmatch(r"package:/data/app/[A-Za-z0-9_~+/.=-]+/base.apk", lines[0]) and
            ".." not in Path(lines[0][8:]).parts, "installed_path_invalid")
    hashes = read("helper-hash", "sha256sum", lines[0][8:]).split()
    versions = re.findall(r"\bversionCode=([0-9]+)\b", read("helper-version", "dumpsys", "package", PACKAGE))
    uids = re.findall(r"^package:" + re.escape(PACKAGE) + r" uid:([0-9]+)$",
                     read("helper-uid", "pm", "list", "packages", "-U", "--user", "0", PACKAGE), re.MULTILINE)
    require(hashes and hashes[0] == facts["apk_sha256"] and set(versions) == {str(VERSION)} and
            uids == [str(binding["uid"])],
            "installed_identity_changed")


def binding_identity(binding, receipt):
    require(isinstance(binding, dict) and binding.get("format") == "alkion-android-ui-binding/1" and
            all(binding.get(key) == receipt[key] for key in ("run_id", "serial", "avd")) and
            re.fullmatch(r"[a-f0-9]{32}", binding.get("run_id", "")) and
            type(binding.get("uid")) is int and 10000 <= binding["uid"] < 100000, "binding_changed")


def validate_fresh(host, args, receipt, artifact_root, record, revision):
    """Read-only validation; caller has admitted this explicit disposable receipt/build."""
    require(isinstance(record, dict) and re.fullmatch(r"[a-f0-9]{40}", revision) and
            revision != "0" * 40 and record.get("source_commit") == revision,
            "fresh_build_source_mismatch")
    require(re.fullmatch(r"[a-f0-9]{32}", receipt.get("run_id", "")) and
            re.fullmatch(r"emulator-[0-9]{4,5}", receipt.get("serial", "")) and
            re.fullmatch(r"[A-Za-z0-9_.-]{1,80}", receipt.get("avd", "")), "explicit_target_required")
    host.device_platform_guard(args)
    existing = host.adb(args, "shell", "pm", "path", PACKAGE, check=False)
    require(existing.returncode in (0, 1) and not existing.stdout.strip() and not existing.stderr.strip(),
            "preexisting_helper")
    retained = host.temporary_path(str(artifact_root / "ui-observer/build.json"), must_exist=True)
    require(host.read_json(retained) == record, "build_record_changed")
    apk = validate_build(host, args, artifact_root, record)
    require(source(host) == revision and all(receipt[k] == getattr(args, k) for k in ("serial", "avd")),
            "phase_source_or_target_changed")
    return apk


def install_fresh(host, args, receipt, artifact_root, record, revision):
    apk = validate_fresh(host, args, receipt, artifact_root, record, revision)
    host.adb(args, "install", apk)
    metadata = host.package_metadata(args, PACKAGE)
    binding = {"format": "alkion-android-ui-binding/1", **{k: receipt[k] for k in ("run_id", "serial", "avd")},
               "build": record, "uid": metadata["uid"]}
    binding_identity(binding, receipt); installed(host, args, binding)
    args._ui_observer = (binding, revision)
    return binding


def prepare(host, args, receipt, output, revision):
    _, record = build(host, args, output / "ui-observer", revision)
    return install_fresh(host, args, receipt, output, record, revision)


def bind_previous(host, args, receipt, prior, prior_root, revision):
    binding = prior.get("ui_observer")
    binding_identity(binding, receipt)
    require(all(prior.get(key) == receipt[key] for key in ("run_id", "serial", "avd")) and
            prior.get("format") == "alkion-android-run/1" and prior.get("phase") == "lifecycle-initial" and
            prior.get("overall") == "IN_PROGRESS" and
            prior.get("initial_lifecycle_phase") == "PASS" and not prior.get("error") and
            prior.get("source_commit") == binding["build"]["source_commit"], "accepted_lifecycle_required")
    require(host.read_json(prior_root / "ui-observer/build.json") == binding["build"], "build_record_changed")
    validate_build(host, args, prior_root, binding["build"])
    installed(host, args, binding)
    require(source(host) == revision, "phase_source_changed")
    args._ui_observer = (binding, revision)
    return binding


def focus(raw, *, allow_null=False):
    require(len(raw) <= LIMIT, "focus_dump_too_large")
    fields = re.findall(r"^[ \t]*mCurrentFocus[^\r\n]*", raw, re.MULTILINE)
    require(len(fields) == 1, "focus_ambiguous")
    if allow_null and fields[0].strip(" \t") == "mCurrentFocus=null":
        return None
    selected = re.fullmatch(r"[ \t]*mCurrentFocus=Window\{([^{}\s]+) u([0-9]+) ([^{}\r\n]+)\}[ \t]*", fields[0])
    require(selected is not None and selected[2] == "0", "focus_ambiguous")
    token, user, label = selected.groups()
    package = "com.android.systemui" if label == "NotificationShade" else label.split("/", 1)[0]
    require(package in ROOTS and (label == "NotificationShade" or "/" in label), "focus_package_unrecognized")
    return {"token": token, "user": int(user), "label": label, "package": package}


def receipt_header(receipt, request, binding, expected, started, ended):
    require(isinstance(receipt, dict) and receipt.get("format") == "alkion-android-ui-observation/1" and
            receipt.get("complete") is True and receipt.get("result") in ("PASS", "FAIL"), "native_capture_failed")
    wanted = {"run_id": binding["run_id"], "serial": binding["serial"], "avd": binding["avd"],
              "source_commit": request["source_commit"], "request_id": request["request_id"],
              "observer_package": PACKAGE, "observer_uid": binding["uid"], "observer_version": VERSION,
              "expected_package": expected}
    require(all(type(receipt.get(key)) is type(value) and receipt[key] == value for key, value in wanted.items()),
            "receipt_identity_changed")
    require(type(receipt.get("elapsed_ms")) is int and 0 <= receipt["elapsed_ms"] <= 8500,
            "receipt_bounds_invalid")
    stamp = receipt.get("captured_at", "")
    require(isinstance(stamp, str) and stamp.endswith("Z"), "timestamp_not_utc")
    captured = datetime.datetime.fromisoformat(stamp.replace("Z", "+00:00")).timestamp()
    require(started - 5 <= captured <= ended + 5, "stale_capture")


def parse_observation(raw, receipt, request, binding, expected, started, ended):
    receipt_header(receipt, request, binding, expected, started, ended)
    require(isinstance(receipt, dict) and receipt.get("format") == "alkion-android-ui-observation/1" and
            receipt.get("complete") is True and receipt.get("result") == "PASS", "native_capture_failed")
    wanted = {"run_id": binding["run_id"], "serial": binding["serial"], "avd": binding["avd"],
              "source_commit": request["source_commit"], "request_id": request["request_id"],
              "observer_package": PACKAGE, "observer_uid": binding["uid"], "observer_version": VERSION,
              "expected_package": expected, "root_package": expected, "display_id": 0,
              "window_active": True, "window_focused": True}
    require(all(type(receipt.get(k)) is type(v) and receipt[k] == v for k, v in wanted.items()), "receipt_identity_changed")
    require(type(receipt.get("elapsed_ms")) is int and 0 <= receipt["elapsed_ms"] < 6000 and
            type(receipt.get("window_id")) is int and receipt["window_id"] >= 0 and
            type(receipt.get("window_type")) is int and receipt["window_type"] in (1, 3) and
            type(receipt.get("node_count")) is int and 1 <= receipt["node_count"] <= 4096 and
            type(receipt.get("rotation")) is int and receipt["rotation"] in range(4) and
            all(type(receipt.get(k)) is int and 1 <= receipt[k] <= 16384 for k in ("width", "height")),
            "receipt_bounds_invalid")
    stamp = receipt.get("captured_at", "")
    require(isinstance(stamp, str) and stamp.endswith("Z"), "timestamp_not_utc")
    captured = datetime.datetime.fromisoformat(stamp.replace("Z", "+00:00")).timestamp()
    require(started - 5 <= captured <= ended + 5, "stale_capture")
    require(0 < len(raw) <= LIMIT and receipt.get("xml_length") == len(raw) and
            receipt.get("xml_sha256") == digest(raw) and b"<!DOCTYPE" not in raw and b"<!ENTITY" not in raw,
            "xml_digest_or_size_changed")
    document = ET.fromstring(raw)
    require(document.tag == "hierarchy" and len(document) == 1 and
            document.get("rotation") == str(receipt["rotation"]), "hierarchy_invalid")
    count = 0
    labels = 0
    def walk(node, depth):
        nonlocal count, labels
        count += 1
        require(node.tag == "node" and depth <= 64 and count <= 4096 and all(k in node.attrib for k in
                ("text", "content-desc", "resource-id", "package", "class", "clickable", "enabled", "visible-to-user", "bounds")),
                "node_incomplete")
        require(node.get("package") == expected and all(node.get(k) in ("true", "false") for k in
                ("clickable", "enabled", "visible-to-user")), "node_package_or_flags_changed")
        if node.get("visible-to-user") == "true" and any(node.get(key).strip(" \t\r\n") for key in
                                                       ("text", "content-desc")):
            labels += 1
        match = re.fullmatch(r"\[(-?[0-9]+),(-?[0-9]+)\]\[(-?[0-9]+),(-?[0-9]+)\]", node.get("bounds", ""))
        require(match is not None, "node_bounds_invalid")
        x1, y1, x2, y2 = map(int, match.groups())
        require(x1 <= x2 and y1 <= y2, "node_bounds_invalid")
        for child in node:
            walk(child, depth + 1)
    walk(document[0], 0)
    require(count == receipt["node_count"], "node_count_changed")
    needs_labels = expected in ("dev.animusstudio.alkion.dev", "dev.animusstudio.alkion")
    require(receipt.get("readiness") == ("visible-label" if needs_labels else "structural") and
            type(receipt.get("visible_label_count")) is int and receipt["visible_label_count"] == labels and
            (not needs_labels or labels > 0), "content_not_ready")
    samples = receipt.get("samples")
    require(type(receipt.get("sample_count")) is int and 1 <= receipt["sample_count"] <= 40 and
            isinstance(samples, list) and len(samples) == receipt["sample_count"] and
            type(receipt.get("candidate_sample")) is int and receipt["candidate_sample"] == len(samples),
            "sample_count_invalid")
    elapsed = 0
    for index, sample in enumerate(samples, 1):
        require(isinstance(sample, dict) and type(sample.get("index")) is int and sample["index"] == index and
                all(type(sample.get(key)) is bool for key in ("cache_cleared", "root_available", "candidate_complete", "ready")) and
                type(sample.get("elapsed_ms")) is int and elapsed <= sample["elapsed_ms"] < 5000 and
                sample["elapsed_ms"] <= receipt["elapsed_ms"] and
                all(type(sample.get(key)) is int for key in
                    ("node_count", "visible_label_count", "window_id", "xml_length")), "sample_invalid")
        elapsed = sample["elapsed_ms"]
        outcome = sample.get("outcome")
        require(outcome in ("null_root", "incomplete_child", "content_not_ready", "complete"), "sample_outcome_invalid")
        if sample["candidate_complete"]:
            require(sample["root_available"] and outcome in ("content_not_ready", "complete") and
                    sample["ready"] == (outcome == "complete") and 1 <= sample["node_count"] <= 4096 and
                    0 <= sample["visible_label_count"] <= sample["node_count"] and
                    sample["window_id"] == receipt["window_id"] and 0 < sample["xml_length"] <= LIMIT and
                    isinstance(sample.get("xml_sha256"), str) and re.fullmatch(r"[a-f0-9]{64}", sample["xml_sha256"]) and
                    sample["ready"] == (not needs_labels or sample["visible_label_count"] > 0),
                    "sample_tree_invalid")
        else:
            require(outcome in ("null_root", "incomplete_child") and not sample["ready"] and
                    sample["node_count"] == sample["visible_label_count"] == sample["xml_length"] == 0 and
                    sample.get("xml_sha256") == "" and
                    sample["root_available"] == (outcome == "incomplete_child") and
                    sample["window_id"] == (receipt["window_id"] if outcome == "incomplete_child" else -1),
                    "discarded_sample_invalid")
        require(sample["ready"] == (index == len(samples)), "readiness_sequence_invalid")
    require(all(samples[-1].get(key) == receipt[key] for key in
                ("node_count", "visible_label_count", "window_id", "xml_length", "xml_sha256")),
            "final_sample_changed")
    # Keep native off-screen/partly clipped bounds intact. The dispatcher must
    # validate only its selected semantic target against this attested display.
    for node in document.iter("node"):
        node.set("observer-display-width", str(receipt["width"]))
        node.set("observer-display-height", str(receipt["height"]))
    return document


def capture(host, args, output, name, expected_package=None):
    require(re.fullmatch(r"[A-Za-z0-9_.-]{1,180}", name), "capture_name_invalid")
    require(getattr(args, "_ui_observer", None) is not None, "explicit_phase_binding_required")
    binding, revision = args._ui_observer
    require(binding["serial"] == args.serial and binding["avd"] == args.avd, "target_changed")
    target = output / (name + ".observation")
    target.mkdir(mode=0o700)
    deadline = time.monotonic() + 20; started = time.time()
    request = {"request_id": secrets.token_hex(16), "source_commit": revision}
    trace = {"request": request, "binding": binding, "commands": [], "started_at": started}
    def execute(label, tail, *, binary=True, timeout=5):
        remaining = deadline - time.monotonic()
        require(remaining > 0, "capture_deadline")
        budget = min(timeout, remaining)
        require(budget > 0, "capture_deadline")
        try:
            if binary:
                transport = ["shell", shlex.join(str(x) for x in tail[1:])] if tail[0] == "shell" else tail
                result = host.command([args.sdk / "platform-tools/adb", "-s", args.serial, *transport],
                                      check=False, binary=True, timeout=budget)
            else:
                result = host.adb(args, *tail, check=False, timeout=budget)
        except subprocess.TimeoutExpired as failure:
            def data(value):
                return value if isinstance(value, bytes) else (value or "").encode()
            keep(target / (label + ".stdout"), data(failure.stdout))
            keep(target / (label + ".stderr"), data(failure.stderr))
            trace["commands"].append({"label": label, "timeout": True, "args": tail})
            raise
        keep(target / (label + ".stdout"), result.stdout if binary else result.stdout.encode())
        keep(target / (label + ".stderr"), result.stderr if binary else result.stderr.encode())
        trace["commands"].append({"label": label, "returncode": result.returncode, "args": tail})
        require(time.monotonic() < deadline, "capture_deadline")
        return result
    try:
        installed(host, args, binding, execute)
        require(expected_package is None or expected_package in ROOTS, "expected_focus_mismatch")
        focus_started = time.monotonic()
        focus_deadline = min(deadline, focus_started + 2) if expected_package is not None else deadline
        focus_trace = {"expected_package": expected_package, "samples": []}
        trace["focus_readiness"] = focus_trace
        for attempt in range(20 if expected_package is not None else 1):
            remaining = focus_deadline - time.monotonic()
            require(remaining > 0, "expected_focus_not_ready")
            label = "focus-before" if attempt == 0 else "focus-before-" + str(attempt)
            before = execute(label, ["shell", "dumpsys", "activity", "activities"], timeout=min(5, remaining))
            require(before.returncode == 0, "focus_query_failed")
            owner = focus(before.stdout.decode("utf-8"), allow_null=expected_package is not None)
            ready = owner is not None and (expected_package is None or owner["package"] == expected_package)
            focus_trace["samples"].append({"label": label, "owner": owner, "ready": ready,
                                            "elapsed_seconds": time.monotonic() - focus_started})
            require(time.monotonic() < focus_deadline, "expected_focus_not_ready")
            if ready:
                trace["focus_before"] = owner
                expected = expected_package or owner["package"]
                break
            require(attempt < 19, "expected_focus_not_ready")
            remaining = focus_deadline - time.monotonic()
            require(remaining > 0, "expected_focus_not_ready")
            time.sleep(min(0.1, remaining))
        else:
            raise Refusal("ui_observer_expected_focus_not_ready")
        arguments = {**request, **{k: binding[k] for k in ("run_id", "serial", "avd")}, "expected_package": expected}
        tail = ["shell", "am", "instrument", "-w", "-r", "--user", "0"]
        for key, value in arguments.items():
            tail += ["-e", key, value]
        tail += [COMPONENT]
        native = execute("instrument", tail, timeout=10)
        relative = "files/observations/" + binding["run_id"] + "/" + request["request_id"]
        def receive(file, limit):
            return execute(file, ["shell", "run-as", PACKAGE, "/system/bin/sh", "-c",
                'test ! -L files && test ! -L files/observations && test ! -L "$1" && '
                'test ! -L "$2" && test ! -L "$3" && test -f "$3" && '
                'test "$(wc -c < "$3")" -le "$4" && cat "$3"', "alkion-ui-read",
                "files/observations/" + binding["run_id"], relative, relative + "/" + file, str(limit)])
        report = receive("receipt.json", 16384)
        tree = receive("hierarchy.xml", LIMIT)
        # Preserve screenshot even when instrumentation or its receipt failed.
        shot = execute("screenshot", ["exec-out", "screencap", "-p"], binary=True)
        after = execute("focus-after", ["shell", "dumpsys", "activity", "activities"])
        observed_receipt = json.loads(report.stdout) if report.returncode == 0 else None
        if isinstance(observed_receipt, dict) and observed_receipt.get("result") == "FAIL":
            receipt_header(observed_receipt, request, binding, expected, started, time.time())
            error = observed_receipt.get("error")
            require(isinstance(error, str) and 0 < len(error) <= 4096, "native_failure_error_invalid")
            trace["native_failure"] = {"error": error, "elapsed_ms": observed_receipt["elapsed_ms"]}
            raise Refusal("ui_observer_native_capture_failed:" + error)
        require(native.returncode == report.returncode == tree.returncode == shot.returncode == after.returncode == 0,
                "capture_transport_failed")
        require(shot.stdout.startswith(b"\x89PNG\r\n\x1a\n"), "screenshot_invalid")
        keep(output / (name + ".png"), shot.stdout)
        trace["screenshot_sha256"] = digest(shot.stdout)
        require(focus(after.stdout.decode("utf-8")) == owner, "focused_window_changed")
        document = parse_observation(tree.stdout, observed_receipt, request, binding,
                                     expected, started, time.time())
        keep(output / (name + ".xml.raw"), tree.stdout)
        trace["result"] = "PASS"
        return document
    except Exception as failure:
        trace["result"] = "FAIL"; trace["error"] = str(failure)
        # Even binary TimeoutExpired output remains raw in the attempt directory.
        if not (target / "screenshot.stdout").exists() and time.monotonic() >= deadline:
            trace["screenshot_skipped"] = "capture_deadline"
        elif not (target / "screenshot.stdout").exists():
            try:
                execute("screenshot", ["exec-out", "screencap", "-p"], binary=True, timeout=2)
            except Exception as screenshot_failure:
                trace["screenshot_error"] = str(screenshot_failure)
        raise
    finally:
        trace["elapsed_seconds"] = time.monotonic() - (deadline - 20)
        keep(target / "host-receipt.json", encoded(trace))
