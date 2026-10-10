#!/usr/bin/env python3
"""Run the Hub's pinned Go rehearsal over the synthetic capture fixtures and
check what it found against what the Reps producer recorded.

Usage (from the repository root):

    python3 -I scripts/verify-capture-rehearsal.py HUB_SNAPSHOT OUTPUT_DIR

HUB_SNAPSHOT is a read-only source snapshot of the Hub (for example a
`git archive` of the pinned commit). A git working tree is refused: the
rehearsal is built from the snapshot into a temporary directory and nothing
is written into the Hub tree. OUTPUT_DIR is the directory
`make -C app capture-recovery` wrote: its `acceptance.json` lists each
fixture capture, its kind (certified or EXPLORATORY), the producer's digests
and the expected rehearsal result.

It requires every producer test of that run to have passed. For every
fixture capture it then checks:

* the rehearsal exits as expected: 0 for a valid capture, 2 for a blocked
  one, and every summary and report says `cutover_ready: false`;
* expected findings and item dispositions are visible (review, unavailable,
  blocking);
* the staged raw draft digest and every queue entry (client id, transaction
  id, SHA-256 of the exact `data` text) equal the producer's digests;
* staging and report bytes are identical across a rerun of the same work
  directory and a run into a separate work directory (deterministic);
* the capture directory is byte-for-byte what the producer wrote, before and
  after every run (the rehearsal never mutates it).

Work directories go under OUTPUT_DIR/rehearsal-verify/ (one kept per fixture,
reused on a later invocation as a resume) plus one fresh separate directory
per invocation. Prints a sanitized JSON result; exits 0 only if every check
passed.
"""

import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile

GO_PACKAGE = "./connectors/reps/cmd/reps-migration-rehearsal"

# Every producer test must have passed in the run that wrote the fixtures;
# a failed test leaves no "pass" entry.
REQUIRED_RESULTS = (
    "kill_each_boundary_and_restart_twice",
    "foreground_background_native_writer_races",
    "full_disk_permission_unreadable_and_limit_faults",
    "go_rehearsal_raw_digests_and_dispositions",
)


def sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


def sha256_file(path):
    with open(path, "rb") as f:
        return sha256_bytes(f.read())


def tree_state(root):
    """Every entry below root with type, mode, size, mtime and digest."""
    state = {}
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        for name in sorted(dirnames + filenames):
            path = os.path.join(dirpath, name)
            rel = os.path.relpath(path, root)
            st = os.lstat(path)
            if os.path.islink(path):
                state[rel] = ("link", os.readlink(path))
            elif os.path.isdir(path):
                state[rel] = ("dir", st.st_mode)
            else:
                state[rel] = ("file", st.st_mode, st.st_size, st.st_mtime_ns,
                              sha256_file(path))
    return state


def file_digests(root):
    return {rel: v[4] for rel, v in tree_state(root).items() if v[0] == "file"}


class Checks:
    def __init__(self):
        self.failures = []
        self.passed = 0

    def check(self, ok, what):
        if ok:
            self.passed += 1
        else:
            self.failures.append(what)
        return ok


def build_rehearsal(hub, out_dir):
    binary = os.path.join(out_dir, "reps-migration-rehearsal")
    env = dict(os.environ, GOFLAGS="-mod=readonly")
    r = subprocess.run(["go", "-C", hub, "build", "-o", binary, GO_PACKAGE],
                       capture_output=True, text=True, env=env)
    if r.returncode != 0:
        sys.exit("building the rehearsal failed:\n" + r.stderr)
    return binary


def run_rehearsal(binary, capture, work):
    r = subprocess.run([binary, "-capture", capture, "-work", work],
                       capture_output=True, text=True)
    try:
        summary = json.loads(r.stdout) if r.stdout.strip() else None
    except json.JSONDecodeError:
        summary = None
    outputs = {}
    for name in ("staging.json", "report.json"):
        path = os.path.join(work, name)
        if os.path.exists(path):
            with open(path, "rb") as f:
                outputs[name] = f.read()
    return r.returncode, summary, outputs, r.stderr.strip()


def queue_from_staging(staging):
    return [
        {"client_id": e["client_id"], "tx_id": e["tx_id"],
         "data_sha256": sha256_bytes(e["data"].encode("utf-8"))}
        for t in staging["upload_queue"]["transactions"]
        for e in t["entries"]
    ]


def queue_from_capture(capture):
    with open(os.path.join(capture, "stores", "upload_queue.json"), "rb") as f:
        store = json.loads(f.read())
    return [
        {"client_id": e["client_id"], "tx_id": e["tx_id"],
         "data_sha256": sha256_bytes(e["data"].encode("utf-8"))}
        for e in store["entries"]
    ]


def verify_capture(binary, output, work_root, entry, checks):
    name = entry["name"]
    capture = os.path.join(output, entry["path"])
    expected = entry["expected"]
    result = {"name": name, "kind": entry["kind"],
              "manifest_sha256": entry["manifest_sha256"]}

    checks.check(entry.get("cutover_ready") is False,
                 f"{name}: acceptance entry must say cutover_ready false")
    checks.check(file_digests(capture) == entry["tree_sha256"],
                 f"{name}: capture bytes differ from what the producer wrote")
    before = tree_state(capture)

    fixture_work = os.path.join(work_root, name)
    os.makedirs(fixture_work, exist_ok=True)
    kept = os.path.join(fixture_work, "run-1")
    separate = tempfile.mkdtemp(prefix="run-", dir=fixture_work)
    runs = [("first", kept), ("same_work_rerun", kept), ("separate_work", separate)]
    outputs = []
    exits = []
    for label, work in runs:
        code, summary, out, stderr = run_rehearsal(binary, capture, work)
        exits.append(code)
        checks.check(code == expected["exit"],
                     f"{name} {label}: exit {code}, expected {expected['exit']} ({stderr})")
        checks.check(summary is not None and summary.get("cutover_ready") is False,
                     f"{name} {label}: summary must say cutover_ready false")
        if summary is not None:
            checks.check(summary.get("staging_valid") == expected.get("staging_valid"),
                         f"{name} {label}: staging_valid {summary.get('staging_valid')}")
            if "exploratory" in expected:
                checks.check(summary.get("exploratory") == expected["exploratory"],
                             f"{name} {label}: exploratory {summary.get('exploratory')}")
            if "blocking" in expected:
                checks.check(summary["findings"].get("blocking") == expected["blocking"],
                             f"{name} {label}: blocking findings {summary['findings']}")
        outputs.append(out)
        checks.check(tree_state(capture) == before,
                     f"{name} {label}: the capture directory changed")
    shutil.rmtree(separate)

    first = outputs[0]
    for (label, _), out in zip(runs[1:], outputs[1:]):
        checks.check(out == first,
                     f"{name} {label}: staging/report bytes differ from the first run")
    report = json.loads(first["report.json"]) if "report.json" in first else None
    checks.check(report is not None, f"{name}: no report.json")
    if report is not None:
        checks.check(report.get("cutover_ready") is False,
                     f"{name}: report must say cutover_ready false")
        codes = sorted({f["code"] for f in report["findings"]})
        severities = {}
        for f in report["findings"]:
            severities.setdefault(f["severity"], set()).add(f["code"])
        for code in expected.get("findings_include", []):
            checks.check(code in codes, f"{name}: finding {code} not reported")
        for code in expected.get("blocking_include", []):
            checks.check(code in severities.get("blocking", set()),
                         f"{name}: blocking finding {code} not reported")
        items = {i["name"]: i["disposition"] for i in report["items"]}
        for item, disposition in expected.get("items", {}).items():
            checks.check(items.get(item) == disposition,
                         f"{name}: item {item} is {items.get(item)}, expected {disposition}")
        result["report_sha256"] = sha256_bytes(first["report.json"])
        result["findings"] = report["summary"]
        result["finding_codes"] = codes

    if expected["exit"] == 0:
        checks.check("staging.json" in first, f"{name}: no staging.json")
        if "staging.json" in first:
            staging = json.loads(first["staging.json"])
            result["staging_sha256"] = sha256_bytes(first["staging.json"])
            raw = entry.get("raw_files", {})
            if "active_draft" in raw:
                checks.check(
                    staging["active_draft"].get("original_sha256") == raw["active_draft"],
                    f"{name}: staged draft digest differs from the producer's")
            checks.check(queue_from_staging(staging) == entry["queue"],
                         f"{name}: staged queue differs from the producer's queue digests")
            result["raw_draft_matches"] = (
                "active_draft" not in raw
                or staging["active_draft"].get("original_sha256") == raw["active_draft"])
            result["queue_matches"] = queue_from_staging(staging) == entry["queue"]
    else:
        checks.check("staging.json" not in first,
                     f"{name}: a blocked capture must not be staged")
        checks.check(queue_from_capture(capture) == entry["queue"],
                     f"{name}: captured queue differs from the producer's queue digests")
        result["queue_matches"] = queue_from_capture(capture) == entry["queue"]

    result["exits"] = exits
    result["capture_unchanged"] = tree_state(capture) == before
    result["cutover_ready"] = False
    return result


def main(argv):
    if len(argv) != 3:
        sys.exit(__doc__)
    hub = os.path.realpath(argv[1])
    output = os.path.realpath(argv[2])
    if not os.path.isfile(os.path.join(hub, "go.mod")):
        sys.exit(f"{hub}: not a Hub source tree")
    if os.path.exists(os.path.join(hub, ".git")):
        sys.exit(f"{hub}: a git working tree; use a read-only snapshot (git archive)")
    with open(os.path.join(output, "acceptance.json"), "rb") as f:
        acceptance = json.loads(f.read())

    checks = Checks()
    checks.check(acceptance.get("cutover_ready") is False,
                 "acceptance.json must say cutover_ready false")
    results = acceptance.get("results", {})
    for test in REQUIRED_RESULTS:
        checks.check(results.get(test) == "pass",
                     f"acceptance result {test}: {results.get(test, 'missing')}")
    captures = acceptance.get("captures", [])
    checks.check(len(captures) > 0, "acceptance.json lists no captures")
    checks.check(any(c["expected"]["exit"] == 0 for c in captures),
                 "no valid fixture")
    checks.check(any(c["expected"]["exit"] == 2 for c in captures),
                 "no blocked fixture")
    for c in captures:
        if c["kind"] != "certified":
            checks.check(c["kind"] == "exploratory" and c["path"].startswith("exploratory-"),
                         f"{c['name']}: a non-certified capture must be named exploratory")

    work_root = os.path.join(output, "rehearsal-verify")
    os.makedirs(work_root, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="reps-rehearsal-bin-") as bin_dir:
        binary = build_rehearsal(hub, bin_dir)
        results = [verify_capture(binary, output, work_root, c, checks) for c in captures]

    summary = {
        "format": "reps-capture-rehearsal-verification",
        "version": 1,
        "cutover_ready": False,
        "checks_passed": checks.passed,
        "failures": checks.failures,
        "captures": results,
        "result": "pass" if not checks.failures else "fail",
    }
    text = json.dumps(summary, indent=2, sort_keys=True) + "\n"
    with open(os.path.join(work_root, "verification.json"), "w") as f:
        f.write(text)
    sys.stdout.write(text)
    return 0 if not checks.failures else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
