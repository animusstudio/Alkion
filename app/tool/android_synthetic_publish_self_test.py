"""Host-only publisher controls. No compiler, Android tool, Git, build or device runs.

The fixed bootstrap, helper readback and publication programs execute for real
under the host /bin/sh in private /tmp package roots. Two PATH shims map only
the numeric owner to the synthetic package UID: `id -u` prints it and `stat`
rewrites its leading %u field (every other field is the real host value). The
read-only preflight is answered by an exact-program fake because `pwd -P` is a
shell builtin and the host has no app SELinux context; it still evaluates the
cache and namespace checks against the fake package root. The one helper exec
is redirected to a Python model of the reviewed CLI that uses the host kernel's
renameat2(RENAME_NOREPLACE), so collisions and concurrent winners are real.
The fake artifact is a synthetic ELF header, never an executable.
"""

import concurrent.futures
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import stat
import struct
import subprocess
import sys
import tempfile
import threading
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
import android_synthetic_publish as publish


HERE = Path(__file__).resolve().parent
REVISION = "a" * 40
RUN = "1" * 32
PACKAGE = "dev.animusstudio.alkion.dev"
CONTEXT = "u:r:runas_app:s0:c1,c256,c512,c768"

FAKE_CLI = r'''
import ctypes, json, os, stat, sys
FAKE = int(os.environ["ALKION_FAKE_UID"]); REAL = os.getuid()
KNOBS = set(filter(None, os.environ.get("ALKION_FAKE_CLI_KNOBS", "").split(",")))
LIBC = ctypes.CDLL(None, use_errno=True)
EPERM, ENOENT, EIO, EAGAIN, EINVAL = 1, 2, 5, 11, 22
UNOBSERVED = {"errno": None}
def owner(value): return FAKE if value == REAL else value
def observe(parent, name):
    try: s = os.stat(name, dir_fd=parent, follow_symlinks=False)
    except OSError as error: return {"errno": error.errno}
    return {"errno": 0, "dev": s.st_dev, "ino": s.st_ino, "uid": owner(s.st_uid), "gid": s.st_gid,
            "mode": s.st_mode, "nlink": s.st_nlink, "length": s.st_size,
            "mtime_sec": s.st_mtime_ns // 10**9, "mtime_nsec": s.st_mtime_ns % 10**9,
            "ctime_sec": s.st_ctime_ns // 10**9, "ctime_nsec": s.st_ctime_ns % 10**9}
def valid_relative(value):
    if not value or len(value) > 768 or value[0] == "/" or value[-1] == "/": return False
    for part in value.split("/"):
        if part in ("", ".", "..") or any(not (c.isascii() and (c.isalnum() or c in "._-")) for c in part): return False
    return True
def same(a, b):
    return all(a[key] == b[key] for key in ("dev", "ino", "uid", "gid", "mode", "nlink", "length"))
def owned_parent(relative, uid):
    fd = os.open(".", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    parts = relative.split("/")
    while True:
        info = os.fstat(fd)
        if not stat.S_ISDIR(info.st_mode) or owner(info.st_uid) != uid or info.st_mode & 0o002:
            os.close(fd); raise OSError(EPERM, "parent")
        if not parts:
            if info.st_mode & 0o077: os.close(fd); raise OSError(EPERM, "private")
            return fd
        part = parts.pop(0)
        try: nxt = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
        finally: os.close(fd)
        fd = nxt
def main(argv):
    r = {"format": "alkion-test-noreplace/1", "nonce": "", "expected_uid": 0, "uid": owner(os.getuid()),
         "euid": owner(os.geteuid()), "from": "", "to": "", "stage": "invocation", "precondition_errno": EINVAL,
         "pre_fsync_errno": None, "rename_errno": None, "post_fsync_errno": None, "published": False,
         "source_consumed": False, "source_before": UNOBSERVED, "source_after": UNOBSERVED,
         "final_before": UNOBSERVED, "final_after": UNOBSERVED, "exit_code": 2}
    def done():
        r["published"] = r["rename_errno"] == 0
        return r
    if len(argv) != 5 or len(argv[1]) != 5 or not argv[1].isdigit(): return done()
    expected = int(argv[1])
    if not (10000 <= expected < 100000 and len(argv[2]) == 32 and all(c in "0123456789abcdef" for c in argv[2])
            and valid_relative(argv[3]) and valid_relative(argv[4])): return done()
    r["expected_uid"] = expected; r["nonce"], r["from"], r["to"] = argv[2], argv[3], argv[4]
    if r["uid"] != expected or r["euid"] != expected: r["precondition_errno"] = EPERM; return done()
    if argv[3] == argv[4] or "/" not in argv[3] or "/" not in argv[4]: return done()
    source_parent, source_leaf = argv[3].rsplit("/", 1); final_parent, final_leaf = argv[4].rsplit("/", 1)
    if source_parent != final_parent: return done()
    r["stage"] = "parent"
    try: parent = owned_parent(source_parent, expected)
    except OSError as error: r["precondition_errno"] = error.errno; return done()
    r["stage"] = "source"
    r["source_before"] = before = observe(parent, source_leaf); r["final_before"] = observe(parent, final_leaf)
    if before["errno"]: r["precondition_errno"] = before["errno"]; return done()
    if r["final_before"]["errno"] not in (0, ENOENT): r["precondition_errno"] = r["final_before"]["errno"]; return done()
    if (not stat.S_ISREG(before["mode"]) or before["uid"] != expected or before["nlink"] != 1 or
            stat.S_IMODE(before["mode"]) != 0o600 or before["length"] > 8 * 1024 * 1024):
        r["precondition_errno"] = EPERM; return done()
    try: source = os.open(source_leaf, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=parent)
    except OSError as error: r["precondition_errno"] = error.errno; return done()
    opened = os.fstat(source)
    if (opened.st_dev, opened.st_ino, opened.st_size) != (before["dev"], before["ino"], before["length"]):
        r["precondition_errno"] = EAGAIN; return done()
    r["precondition_errno"] = 0; r["stage"] = "source-fsync"
    os.fsync(source); r["pre_fsync_errno"] = EIO if "fail-source-fsync" in KNOBS else 0
    if r["pre_fsync_errno"]: r["exit_code"] = 1; return done()
    os.fchdir(parent); r["stage"] = "native"
    result = LIBC.renameat2(-100, source_leaf.encode(), -100, final_leaf.encode(), 1)
    r["rename_errno"] = 0 if result == 0 else (ctypes.get_errno() or EIO)
    r["exit_code"] = 1
    if r["rename_errno"] == 0:
        r["source_consumed"] = True; r["stage"] = "directory-fsync"
        os.fsync(parent); r["post_fsync_errno"] = EIO if "fail-dir-fsync" in KNOBS else 0
    r["source_after"] = observe(parent, source_leaf); r["final_after"] = observe(parent, final_leaf)
    if (r["rename_errno"] == 0 and r["post_fsync_errno"] == 0 and r["source_after"]["errno"] == ENOENT and
            r["final_after"]["errno"] == 0 and same(before, r["final_after"])):
        r["stage"] = "complete"; r["exit_code"] = 0
    return done()
reply = main(sys.argv)
text = json.dumps(reply, separators=(",", ":"))
code = reply["exit_code"]
if "wrong-nonce" in KNOBS: text = text.replace(reply["nonce"], "f" * 32) if reply["nonce"] else text
if "duplicate-key" in KNOBS: text = text[:-1] + ',"exit_code":' + str(code) + "}"
if "extra-key" in KNOBS: text = text[:-1] + ',"extra":true}'
if "truncate-reply" in KNOBS: text = text[:len(text) // 2]
if "exit-mismatch" in KNOBS: code = 2 if code != 2 else 0
if "drop-reply" not in KNOBS:
    sys.stdout.write(text + ("" if "truncate-reply" in KNOBS else "\n"))
if "stderr-noise" in KNOBS: sys.stderr.write("synthetic diagnostic\n")
sys.stdout.flush()
sys.exit(code)
'''

ID_SHIM = '#!/bin/sh\nif [ "$1" = "-u" ] && [ "$#" = 1 ]; then printf "%s\\n" "$ALKION_FAKE_UID"; exit 0; fi\nexec /usr/bin/id "$@"\n'
STAT_SHIM = ('#!/usr/bin/env python3\nimport os, subprocess, sys\n'
             'out = subprocess.run(["/usr/bin/stat", *sys.argv[1:]], capture_output=True)\n'
             'foreign = os.environ.get("ALKION_FAKE_FOREIGN_INODE", "")\n'
             'target = os.lstat(sys.argv[-1]).st_ino if out.returncode == 0 else None\n'
             'owner = "10999" if foreign and str(target) == foreign else os.environ["ALKION_FAKE_UID"]\n'
             'lines = []\n'
             'for line in out.stdout.decode().splitlines():\n'
             '    head, sep, tail = line.partition(" ")\n'
             '    lines.append((owner if head == str(os.getuid()) else head) + sep + tail)\n'
             'sys.stdout.write("".join(line + "\\n" for line in lines)); sys.stderr.buffer.write(out.stderr)\n'
             'raise SystemExit(out.returncode)\n')


class FakeRunAs:
    """Fake run-as for the fixed publisher programs only; everything else is the caller's."""

    def __init__(self, root):
        self.root = Path(root) / "publisher-fake"
        (self.root / "bin").mkdir(parents=True, mode=0o700)
        for name, text in (("bin/id", ID_SHIM), ("bin/stat", STAT_SHIM), ("cli.py", FAKE_CLI)):
            (self.root / name).write_text(text)
            (self.root / name).chmod(0o700)
        self.knobs = set()
        self.timeout_after = False
        self.programs = []
        self.uid_override = {}
        self.foreign_inode = None

    @staticmethod
    def handles(rest):
        return rest[:2] == ["/system/bin/sh", "-c"] and len(rest) > 2 and rest[2] in publish.PROGRAMS

    def run(self, package, uid, directory, rest, data):
        assert self.handles(rest) and rest[3] == "alkion-publish", rest
        program, values = rest[2], rest[4:]
        uid = self.uid_override.get(package, uid)
        self.programs.append((package, publish.PROGRAMS.index(program), list(values)))
        directory = Path(directory)
        # Fixture: Android creates every app data directory with its cache root.
        if not (directory / "cache").exists() and not (directory / "cache").is_symlink():
            (directory / "cache").mkdir(mode=0o771)
        if program == publish.PREFLIGHT:
            return self.preflight(package, uid, directory, values)
        text = program
        if program == publish.PUBLISH:
            assert program.count('exec "$h"') == 1
            text = program.replace('exec "$h"', 'exec "$ALKION_FAKE_PYTHON" "$ALKION_FAKE_CLI"')
        env = {"PATH": str(self.root / "bin") + ":/usr/bin:/bin", "LANG": "C", "ALKION_FAKE_UID": str(uid),
               "ALKION_FAKE_CLI_KNOBS": ",".join(sorted(self.knobs)), "ALKION_FAKE_PYTHON": sys.executable,
               "ALKION_FAKE_CLI": str(self.root / "cli.py"), "PYTHONDONTWRITEBYTECODE": "1",
               "ALKION_FAKE_FOREIGN_INODE": str(self.foreign_inode or "")}
        completed = subprocess.run(["/bin/sh", "-c", text, *rest[3:]], cwd=directory, env=env,
                                   input=data, stdin=None if data is not None else subprocess.DEVNULL,
                                   capture_output=True, timeout=20)
        if program == publish.PUBLISH and self.timeout_after:
            raise subprocess.TimeoutExpired(["adb"], publish.PUBLISH_TIMEOUT,
                                            output=completed.stdout[:7], stderr=b"\x00partial\xff")
        return completed.stdout, completed.stderr, completed.returncode

    def preflight(self, package, uid, directory, values):
        stdout = (str(uid) + "\n/data/user/0/" + package + "\n" + CONTEXT + "\n").encode()
        cache = directory / "cache"
        if not cache.is_dir() or cache.is_symlink():
            return stdout, b"", 3
        info = cache.lstat()
        owner = uid if info.st_uid == os.getuid() else info.st_uid
        stdout += (str(owner) + " " + format(stat.S_IMODE(info.st_mode), "o") + " " + str(info.st_nlink) + " directory\n").encode()
        namespace = directory / values[0]
        if namespace.exists() or namespace.is_symlink():
            return stdout, b"", 4
        return stdout, b"", 0


def synthetic_elf(interpreter=b"/system/bin/linker64\0", machine=62, e_type=3):
    header = b"\x7fELF" + bytes((2, 1, 1, 0)) + bytes(8)
    header += struct.pack("<HHIQQQIHHHHHH", e_type, machine, 1, 0, 64, 0, 0, 64, 56, 1, 64, 0, 0)
    program = struct.pack("<IIQQQQQQ", 3, 4, 120, 0, 0, len(interpreter), len(interpreter), 1)
    return header + program + interpreter + b"synthetic host-only artifact, never executed\n"


def copy_sources(app):
    """Give a fake checkout the real committed CLI and shared native source."""
    for name in (publish.CLI_SOURCE, publish.SHARED_SOURCE):
        target = Path(app) / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(HERE.parent / name, target)


def fake_build(directory, app, revision=REVISION, data=None):
    """Write a synthetic receipt + artifact pair in the build route's layout."""
    directory = Path(directory)
    directory.mkdir(mode=0o700, parents=True)
    data = synthetic_elf() if data is None else data
    artifact = directory / publish.ARTIFACT_NAME
    artifact.write_bytes(data)
    artifact.chmod(0o700)
    receipt = {"format": publish.BUILD_FORMAT, "source_commit": revision, "target": publish.TARGET, "api": 24,
               "abi": "x86_64", "ndk_revision": publish.NDK_REVISION,
               "compiler": {"path": "synthetic", "sha256": "0" * 64, "resolved_path": "synthetic", "resolved_sha256": "0" * 64},
               "cli_sha256": publish.digest((Path(app) / publish.CLI_SOURCE).read_bytes()),
               "shared_c_sha256": publish.digest((Path(app) / publish.SHARED_SOURCE).read_bytes()),
               "argv": [], "env": {}, "syntax_checks": [], "exit_code": 0, "stdout": "", "stderr": "",
               "artifact": {"name": publish.ARTIFACT_NAME, "sha256": publish.digest(data), "length": len(data),
                            "mode": "0700", "elf": publish.elf_facts(data)}}
    path = directory / "build.json"
    path.write_bytes(publish._encoded(receipt))
    path.chmod(0o600)
    return path


def load_harness():
    script = HERE / "android_synthetic.sh"
    body = script.read_text().split("<<'PY'\n", 1)[1].rsplit("\nPY", 1)[0]
    body = body[:body.index("\nparser = argparse.ArgumentParser")]
    namespace = {"__name__": "publisher_host_control"}
    with patch.object(sys, "argv", [str(script), str(script)]):
        exec(compile(body, str(script), "exec"), namespace)
    return namespace


class Host:
    """Minimal fake transport: the real harness path guards plus a run-as route."""

    def __init__(self, root):
        self.root = Path(root)
        self.APP = self.root / "checkout/app"
        copy_sources(self.APP)
        self.sdk = self.root / "sdk"
        (self.sdk / "platform-tools").mkdir(parents=True)
        harness = load_harness()
        harness["APP"] = self.APP
        self.temporary_path, self.read_json = harness["temporary_path"], harness["read_json"]
        self.args = SimpleNamespace(sdk=self.sdk, serial="emulator-5560", avd="publisher-proof")
        self.uids = {PACKAGE: 10001}
        self.runas = FakeRunAs(self.root)
        self.calls = []
        self.metadata_calls = 0

    def package_root(self, package):
        directory = self.root / "packages" / package
        directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        return directory

    def package_metadata(self, args, package):
        self.metadata_calls += 1
        return {"uid": self.uids[package], "version_code": 45}

    def command(self, argv, *, binary=False, input=None, check=True, timeout=30, env=None):
        argv = list(map(str, argv))
        self.calls.append(argv)
        assert argv[0].endswith("/adb") and argv[1:3] == ["-s", self.args.serial] and argv[3:5] == ["shell", "-T"], argv
        assert binary and not check and timeout == publish.PUBLISH_TIMEOUT
        remote = shlex.split(argv[5])
        assert remote[0] == "run-as" and len(argv) == 6
        stdout, stderr, code = self.runas.run(remote[1], self.uids[remote[1]], self.package_root(remote[1]), remote[2:], input)
        return SimpleNamespace(returncode=code, stdout=stdout, stderr=stderr)


class PublisherControls(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="alkion-publisher-host-")
        self.root = Path(self.temp.name)
        self.host = Host(self.root)
        self.build = fake_build(self.root / "publisher-build", self.host.APP)
        self.artifact = publish.load_build(self.host, self.host.args, str(self.build), REVISION)
        self.output = self.root / "output"
        self.output.mkdir(mode=0o700)
        self.records = []
        self.lock = threading.Lock()
        self.session = publish.Session(self.host, self.host.args, self.artifact, RUN, self.keep)
        self.base = self.host.package_root(PACKAGE)
        (self.base / "files/proof").mkdir(parents=True, mode=0o700)

    def tearDown(self):
        self.temp.cleanup()

    def keep(self, name, value):
        with self.lock:
            path = self.output / (str(len(self.records) + 1).zfill(4) + "-" + name)
            with path.open("xb") as stream:
                os.chmod(path, 0o600)
                stream.write(value if isinstance(value, bytes) else publish._encoded(value))
            self.records.append(name)
            return path

    def record(self, suffix):
        return json.loads(sorted(self.output.glob("*" + suffix))[-1].read_bytes())

    def stage(self, name, data, mode=0o600):
        path = self.base / "files/proof" / name
        path.write_bytes(data)
        path.chmod(mode)
        return "files/proof/" + name

    def readback(self, package, path, bound, name):
        return (self.host.package_root(package) / path).read_bytes()

    def publish_item(self, source, final, data, name="item"):
        return self.session.publish(PACKAGE, source, final, data, name, self.readback)

    def bootstrapped(self):
        self.session.ensure(PACKAGE, 10001)
        self.host.calls.clear()

    # Reply grammar and source binding.
    def test_fake_cli_reply_grammar_matches_reviewed_c_source(self):
        source = (HERE / "android_synthetic_publish.c").read_text()
        report = source[source.index("report:"):]
        keys = re.findall(r'\\"([a-z_]+)\\":', report)
        self.assertEqual(tuple(keys), publish.REPLY_KEYS)
        observed = source[source.index("static void print_observed"):source.index("static int valid_relative")]
        self.assertEqual(tuple(re.findall(r'\\"([a-z_]+)\\":', observed))[2:], publish.STAT_KEYS)
        self.assertIn("extern int32_t alkion_publish_noreplace(const char *from, const char *to);", source)
        shared = (HERE.parent / publish.SHARED_SOURCE).read_text()
        self.assertIn("int32_t alkion_publish_noreplace(const char *from, const char *to)", shared)
        self.assertIn("RENAME_NOREPLACE", shared)
        self.bootstrapped()
        source_path = self.stage("grammar.partial-1", b"x")
        self.publish_item(source_path, "files/proof/grammar", b"x")
        raw = sorted(self.output.glob("*item.publication.stdout"))[-1].read_bytes()
        self.assertEqual(tuple(publish.parse_reply(raw)), publish.REPLY_KEYS)

    def test_success_consumes_closed_source_and_requires_final_readback(self):
        self.bootstrapped()
        data = b"\x00\r\n\xffpayload"
        source = self.stage("a.json.partial-1", data)
        result = self.publish_item(source, "files/proof/a.json", data)
        self.assertEqual(result["state"], "PUBLISHED")
        self.assertEqual(result["basis"], "clean_reply+final_readback")
        self.assertEqual(result["final_sha256"], publish.digest(data))
        self.assertFalse((self.base / source).exists())
        self.assertEqual((self.base / "files/proof/a.json").read_bytes(), data)
        outcome = self.record("item.publication.json")
        self.assertEqual((outcome["state"], outcome["claimed"], outcome["partial_consumed"]), ("UNKNOWN", "PUBLISHED", True))
        request = self.record("item.publication-request.json")
        self.assertEqual((request["avd"], request["serial"], request["run_id"]), ("publisher-proof", "emulator-5560", RUN))
        self.assertEqual(len(self.host.calls), 1)
        self.assertEqual(self.host.metadata_calls, 1)  # Only the bootstrap reads package metadata.

    def test_existing_final_file_is_eexist_and_both_names_survive(self):
        self.bootstrapped()
        source = self.stage("b.partial-1", b"new")
        (self.base / "files/proof/b").write_bytes(b"existing")
        with self.assertRaisesRegex(publish.Refusal, "publication:NOT_PUBLISHED:rename_errno_17"):
            self.publish_item(source, "files/proof/b", b"new")
        self.assertEqual((self.base / source).read_bytes(), b"new")
        self.assertEqual((self.base / "files/proof/b").read_bytes(), b"existing")
        outcome = self.record("item.publication.json")
        self.assertEqual((outcome["partial_consumed"], outcome["final_published"]), (False, False))
        self.assertFalse(list(self.output.glob("*publication-final.json")))

    def test_existing_final_directory_refuses_without_mutation(self):
        self.bootstrapped()
        source = self.stage("c.partial-1", b"new")
        (self.base / "files/proof/c").mkdir()
        with self.assertRaisesRegex(publish.Refusal, "NOT_PUBLISHED:rename_errno_17"):
            self.publish_item(source, "files/proof/c", b"new")
        self.assertTrue((self.base / "files/proof/c").is_dir())
        self.assertEqual((self.base / source).read_bytes(), b"new")

    def test_existing_final_symlink_is_not_followed_and_survives(self):
        self.bootstrapped()
        source = self.stage("d.partial-1", b"new")
        outside = self.root / "outside"
        outside.write_bytes(b"outside")
        (self.base / "files/proof/d").symlink_to(outside)
        with self.assertRaisesRegex(publish.Refusal, "NOT_PUBLISHED:rename_errno_17"):
            self.publish_item(source, "files/proof/d", b"new")
        self.assertTrue((self.base / "files/proof/d").is_symlink())
        self.assertEqual(outside.read_bytes(), b"outside")

    def test_concurrent_same_target_has_one_winner_and_loser_keeps_partial(self):
        self.bootstrapped()
        first, second = self.stage("e.partial-1", b"first"), self.stage("e.partial-2", b"second")
        def attempt(item):
            try:
                return self.publish_item(item[0], "files/proof/e", item[1], name="race-" + item[1].decode())["state"]
            except publish.Refusal as error:
                return str(error)
        with concurrent.futures.ThreadPoolExecutor(2) as pool:
            results = list(pool.map(attempt, ((first, b"first"), (second, b"second"))))
        self.assertEqual(sum(value == "PUBLISHED" for value in results), 1, results)
        self.assertEqual(sum("NOT_PUBLISHED:rename_errno_17" in value for value in results), 1, results)
        winner = (self.base / "files/proof/e").read_bytes()
        loser = first if winner == b"second" else second
        self.assertEqual((self.base / loser).read_bytes(), b"first" if winner == b"second" else b"second")

    def test_missing_source_is_not_attempted_precondition(self):
        self.bootstrapped()
        with self.assertRaisesRegex(publish.Refusal, "publication:NOT_ATTEMPTED:precondition_errno_2"):
            self.publish_item("files/proof/absent.partial-1", "files/proof/absent", b"x")
        self.assertFalse((self.base / "files/proof/absent").exists())

    def test_linked_source_or_parent_refuses_precondition(self):
        self.bootstrapped()
        real = self.stage("real", b"x")
        (self.base / "files/proof/link.partial-1").symlink_to(self.base / real)
        with self.assertRaisesRegex(publish.Refusal, "NOT_ATTEMPTED:precondition_errno_1"):
            self.publish_item("files/proof/link.partial-1", "files/proof/link", b"x")
        (self.base / "files/linked").symlink_to(self.base / "files/proof")
        # The host kernel reports ENOTDIR or ELOOP for a linked directory component.
        with self.assertRaisesRegex(publish.Refusal, "NOT_ATTEMPTED:precondition_errno_(?:20|40)"):
            self.publish_item("files/linked/real", "files/linked/final", b"x")
        self.assertEqual((self.base / real).read_bytes(), b"x")
        self.assertFalse((self.base / "files/proof/final").exists())

    def test_foreign_mode_or_multilink_source_refuses_precondition(self):
        self.bootstrapped()
        loose = self.stage("loose.partial-1", b"x", mode=0o640)
        with self.assertRaisesRegex(publish.Refusal, "NOT_ATTEMPTED:precondition_errno_1"):
            self.publish_item(loose, "files/proof/loose", b"x")
        linked = self.stage("multi.partial-1", b"x")
        os.link(self.base / linked, self.base / "files/proof/multi.extra")
        with self.assertRaisesRegex(publish.Refusal, "NOT_ATTEMPTED:precondition_errno_1"):
            self.publish_item(linked, "files/proof/multi", b"x")
        self.assertFalse((self.base / "files/proof/loose").exists() or (self.base / "files/proof/multi").exists())

    def test_group_accessible_parent_refuses_before_rename(self):
        self.bootstrapped()
        (self.base / "files/proof").chmod(0o750)
        source = self.stage("f.partial-1", b"x")
        with self.assertRaisesRegex(publish.Refusal, "NOT_ATTEMPTED:precondition_errno_1:stage_parent"):
            self.publish_item(source, "files/proof/f", b"x")
        self.assertTrue((self.base / source).exists())

    # Helper and UID binding.
    def test_missing_helper_stops_with_guard_exit_and_no_recopy(self):
        self.bootstrapped()
        namespace = self.session.packages[PACKAGE]["namespace"]
        (self.base / namespace / "publisher").unlink()
        source = self.stage("g.partial-1", b"x")
        with self.assertRaisesRegex(publish.Refusal, "NOT_ATTEMPTED:guard_exit_74"):
            self.publish_item(source, "files/proof/g", b"x")
        self.assertEqual(self.session.ensure(PACKAGE), 10001)
        self.assertFalse((self.base / namespace / "publisher").exists())
        self.assertEqual([index for _, index, _ in self.host.runas.programs[-1:]], [publish.PROGRAMS.index(publish.PUBLISH)])

    def test_replaced_helper_inode_bytes_mode_or_owner_stops(self):
        cases = ("inode", "bytes", "mode", "owner")
        for case in cases:
            with self.subTest(case=case):
                self.session = publish.Session(self.host, self.host.args, self.artifact, RUN, self.keep)
                shutil.rmtree(self.base / "cache", ignore_errors=True)
                self.bootstrapped()
                helper = self.base / self.session.packages[PACKAGE]["namespace"] / "publisher"
                original = helper.read_bytes()
                if case == "inode":
                    replacement = helper.with_name("replacement")
                    replacement.write_bytes(original); replacement.chmod(0o700)
                    os.replace(replacement, helper)
                elif case == "bytes":
                    helper.write_bytes(original[:-1] + b"?")
                elif case == "mode":
                    helper.chmod(0o750)
                else:
                    self.host.runas.foreign_inode = helper.stat().st_ino
                source = self.stage("h-" + case + ".partial-1", b"x")
                expected = {"inode": 75, "bytes": 76, "mode": 75, "owner": 75}[case]
                with self.assertRaisesRegex(publish.Refusal, "NOT_ATTEMPTED:guard_exit_" + str(expected)):
                    self.publish_item(source, "files/proof/h-" + case, b"x")
                self.assertTrue((self.base / source).exists())
                self.host.runas.foreign_inode = None

    def test_linked_helper_or_namespace_stops(self):
        self.bootstrapped()
        namespace = self.base / self.session.packages[PACKAGE]["namespace"]
        helper = namespace / "publisher"
        moved = self.root / "moved-helper"
        helper.rename(moved); helper.symlink_to(moved)
        source = self.stage("i.partial-1", b"x")
        with self.assertRaisesRegex(publish.Refusal, "guard_exit_74"):
            self.publish_item(source, "files/proof/i", b"x")
        helper.unlink(); moved.rename(helper)
        aside = self.root / "namespace-aside"
        namespace.rename(aside); namespace.symlink_to(aside)
        with self.assertRaisesRegex(publish.Refusal, "guard_exit_73"):
            self.publish_item(source, "files/proof/i", b"x")
        self.assertTrue((self.base / source).exists())

    def test_runtime_uid_change_after_bootstrap_is_guard_exit_not_attempted(self):
        self.bootstrapped()
        self.host.uids[PACKAGE] = 10007  # An APK update changed the run-as identity.
        source = self.stage("j.partial-1", b"x")
        with self.assertRaisesRegex(publish.Refusal, "NOT_ATTEMPTED:guard_exit_71"):
            self.publish_item(source, "files/proof/j", b"x")
        with self.assertRaisesRegex(publish.Refusal, "bound_uid_mismatch"):
            self.session.ensure(PACKAGE, 10007)
        self.assertTrue((self.base / source).exists())

    # Bootstrap states.
    def test_bound_package_ensure_issues_zero_device_commands(self):
        self.assertEqual(self.session.ensure(PACKAGE, 10001), 10001)
        self.assertEqual([index for _, index, _ in self.host.runas.programs], [0, 1, 2])
        calls, metadata = len(self.host.calls), self.host.metadata_calls
        for _ in range(3):
            self.assertEqual(self.session.ensure(PACKAGE), 10001)
            self.assertEqual(self.session.ensure(PACKAGE, 10001), 10001)
        self.assertEqual((len(self.host.calls), self.host.metadata_calls), (calls, metadata))
        namespace = self.session.packages[PACKAGE]["namespace"]
        self.assertTrue(re.fullmatch(r"cache/alkion-publish-[a-f0-9]{32}", namespace))
        helper = self.base / namespace / "publisher"
        self.assertEqual((helper.read_bytes(), stat.S_IMODE(helper.stat().st_mode)), (self.artifact.data, 0o700))
        self.assertEqual(stat.S_IMODE((self.base / namespace).stat().st_mode), 0o700)
        bound = self.record(PACKAGE + ".bound.json")
        self.assertEqual(bound["preflight"][1], "/data/user/0/" + PACKAGE)

    def test_failed_bootstrap_is_refused_and_never_reissued(self):
        (self.base / "cache").mkdir(mode=0o771)
        (self.base / "cache").chmod(0o777)
        with self.assertRaisesRegex(publish.Refusal, "publisher_cache_root_invalid"):
            self.session.ensure(PACKAGE)
        commands = list(self.host.runas.programs)
        for _ in range(2):
            with self.assertRaisesRegex(publish.Refusal, "publisher_bootstrap_failed_not_repeatable"):
                self.session.ensure(PACKAGE)
        self.assertEqual(self.host.runas.programs, commands)
        self.assertFalse(self.session.bound(PACKAGE))
        source = self.stage("k.partial-1", b"x")
        with self.assertRaisesRegex(publish.Refusal, "publisher_not_bootstrapped"):
            self.publish_item(source, "files/proof/k", b"x")
        self.assertEqual(self.host.runas.programs, commands)

    def test_never_attempted_package_bootstraps_exactly_once(self):
        self.assertFalse(self.session.bound(PACKAGE))
        self.session.ensure(PACKAGE)
        self.session.ensure(PACKAGE)
        self.assertEqual([index for _, index, _ in self.host.runas.programs], [0, 1, 2])
        self.assertEqual(len(list((self.base / "cache").iterdir())), 1)

    def test_bootstrap_preflight_refusals_leave_no_namespace(self):
        for case in ("linked-cache", "expected-uid", "binding"):
            with self.subTest(case=case):
                base = self.host.package_root(PACKAGE)
                if (base / "cache").is_symlink():
                    (base / "cache").unlink()
                shutil.rmtree(base / "cache", ignore_errors=True)
                session = publish.Session(self.host, self.host.args, None if case == "binding" else self.artifact, RUN, self.keep)
                if case == "linked-cache":
                    (self.root / "elsewhere").mkdir(exist_ok=True)
                    (base / "cache").symlink_to(self.root / "elsewhere")
                    reason = "publisher_run_as_context_or_cache_invalid"
                elif case == "expected-uid":
                    reason = "publisher_package_uid_mismatch"
                else:
                    reason = "publisher_binding_required"
                before = list(self.host.runas.programs)
                with self.assertRaisesRegex(publish.Refusal, reason):
                    session.ensure(PACKAGE, 10002 if case == "expected-uid" else None)
                self.assertEqual([index for _, index, _ in self.host.runas.programs[len(before):]],
                                 [0] if case == "linked-cache" else [])
                self.assertFalse(list((self.root / "elsewhere").iterdir()) if (self.root / "elsewhere").exists() else [])

    # Reply and transport classification.
    def knob_failure(self, knob, expected, *, consumed="UNKNOWN"):
        self.bootstrapped()
        source = self.stage(knob + ".partial-1", b"payload")
        self.host.runas.knobs = {knob}
        with self.assertRaisesRegex(publish.Refusal, expected):
            self.publish_item(source, "files/proof/" + knob, b"payload")
        outcome = self.record("item.publication.json")
        self.assertEqual(outcome["partial_consumed"], consumed)
        self.assertFalse(list(self.output.glob("*publication-final.json")))
        self.assertTrue(list(self.output.glob("*item.publication.stdout")))
        return outcome, source

    def test_malformed_or_extra_or_duplicate_key_reply_is_unknown(self):
        for knob in ("extra-key", "duplicate-key"):
            with self.subTest(knob=knob):
                outcome, _ = self.knob_failure(knob, "publication:UNKNOWN:publication_reply_")
                self.assertIsNone(outcome["reply"])
        with self.assertRaisesRegex(publish.Refusal, "malformed"):
            publish.parse_reply(b"{not json}\n")

    def test_truncated_or_oversized_reply_is_unknown(self):
        self.knob_failure("truncate-reply", "publication:UNKNOWN:publication_reply_framing_invalid")
        with self.assertRaisesRegex(publish.Refusal, "framing"):
            publish.parse_reply(b"{}" + b" " * publish.REPLY_BOUND + b"\n")
        with self.assertRaisesRegex(publish.Refusal, "framing"):
            publish.parse_reply(b"{}\n{}\n")

    def test_unbound_reply_nonce_path_or_uid_is_unknown(self):
        self.knob_failure("wrong-nonce", "publication:UNKNOWN:publication_reply_unbound")

    def test_returncode_reply_exit_mismatch_is_unknown_even_after_rename(self):
        outcome, source = self.knob_failure("exit-mismatch", "publication:UNKNOWN:publication_transport_not_clean")
        self.assertEqual(outcome["basis"], "cli_self_report_over_failed_transport")
        self.assertFalse((self.base / source).exists())  # Renamed, but never claimed PUBLISHED.

    def test_stderr_after_complete_reply_is_unknown(self):
        outcome, _ = self.knob_failure("stderr-noise", "publication:UNKNOWN:publication_transport_not_clean")
        self.assertEqual(outcome["reply"]["exit_code"], 0)
        self.assertEqual(sorted(self.output.glob("*item.publication.stderr"))[-1].read_bytes(), b"synthetic diagnostic\n")

    def test_dir_fsync_failure_is_renamed_not_durable_with_partial_consumed(self):
        outcome, source = self.knob_failure("fail-dir-fsync", "publication:RENAMED_NOT_DURABLE:post_fsync_errno_5", consumed=True)
        self.assertEqual(outcome["final_published"], True)
        self.assertFalse((self.base / source).exists())
        self.assertEqual((self.base / "files/proof/fail-dir-fsync").read_bytes(), b"payload")

    def test_source_fsync_failure_is_not_attempted(self):
        self.knob_failure("fail-source-fsync", "publication:NOT_ATTEMPTED:precondition_errno_0:stage_source-fsync", consumed=False)

    def test_exec_failure_without_reply_is_unknown(self):
        self.knob_failure("drop-reply", "publication:UNKNOWN:publication_reply_framing_invalid")

    def test_timeout_after_rename_is_unknown_keeps_binary_partials_and_reraises(self):
        self.bootstrapped()
        source = self.stage("t.partial-1", b"payload")
        self.host.runas.timeout_after = True
        with self.assertRaises(subprocess.TimeoutExpired):
            self.publish_item(source, "files/proof/t", b"payload")
        outcome = self.record("item.publication.json")
        self.assertEqual((outcome["state"], outcome["partial_consumed"], outcome["detail"]),
                         ("UNKNOWN", "UNKNOWN", "publication_timeout"))
        self.assertEqual(sorted(self.output.glob("*publication.timeout-stderr"))[-1].read_bytes(), b"\x00partial\xff")
        self.assertEqual(len(sorted(self.output.glob("*publication.timeout-stdout"))[-1].read_bytes()), 7)
        self.assertFalse((self.base / source).exists())  # Device state stays as it is: no copy-back.
        self.assertEqual(len(self.host.calls), 1)  # No readback or retry after an uncertain call.

    def test_readback_mismatch_after_success_is_unknown(self):
        self.bootstrapped()
        source = self.stage("m.partial-1", b"payload")
        with self.assertRaisesRegex(publish.Refusal, "publication:UNKNOWN:final_readback_mismatch"):
            self.session.publish(PACKAGE, source, "files/proof/m", b"payload", "item", lambda *_: b"changed")
        final = self.record("item.publication-final.json")
        self.assertEqual((final["state"], final["partial_consumed"], final["final_sha256"]),
                         ("UNKNOWN", True, publish.digest(b"changed")))
        with self.assertRaisesRegex(publish.Refusal, "final_readback_failed"):
            self.session.publish(PACKAGE, self.stage("n.partial-1", b"p"), "files/proof/n", b"p", "other",
                                 lambda *_: (_ for _ in ()).throw(ValueError("unreadable")))

    def test_pair_size_unbound_and_binding_refusals_issue_no_device_command(self):
        before = sorted(str(path) for path in self.base.rglob("*"))
        unbound = [("files/a.partial", "files/b/a"), ("files/../a", "files/a"), ("/files/a", "files/b"),
                   ("files/a b", "files/c"), ("a", "b"), ("files/a", "files/a"), ("files/a", "other/a"),
                   ("files/" + "x" * 800, "files/y")]
        for source, final in unbound:
            with self.assertRaisesRegex(publish.Refusal, "publication_p(?:ath|air)_invalid"):
                self.publish_item(source, final, b"x")
        with self.assertRaisesRegex(publish.Refusal, "publisher_not_bootstrapped"):
            self.publish_item("files/proof/a.partial", "files/proof/a", b"x")
        with self.assertRaisesRegex(publish.Refusal, "payload_invalid"):
            self.publish_item("files/proof/a.partial", "files/proof/a", b"x" * (publish.PAYLOAD_BOUND + 1))
        with self.assertRaisesRegex(publish.Refusal, "package_invalid"):
            self.session.ensure("Not.A package")
        self.assertEqual(self.host.calls, [])
        self.assertEqual(self.host.metadata_calls, 0)
        self.assertEqual(sorted(str(path) for path in self.base.rglob("*")), before)

    # Build receipt binding.
    def test_load_build_refuses_changed_cli_or_shared_source(self):
        for name in (publish.CLI_SOURCE, publish.SHARED_SOURCE):
            with self.subTest(name=name):
                path = self.host.APP / name
                original = path.read_bytes()
                path.write_bytes(original + b"\n")
                with self.assertRaisesRegex(publish.Refusal, "source_bytes_mismatch"):
                    publish.load_build(self.host, self.host.args, str(self.build), REVISION)
                path.write_bytes(original)

    def test_load_build_requires_receipt_source_commit_equal_to_head(self):
        with self.assertRaisesRegex(publish.Refusal, "publisher_build_source_commit_mismatch"):
            publish.load_build(self.host, self.host.args, str(self.build), "b" * 40)
        with self.assertRaisesRegex(publish.Refusal, "binding_source_required"):
            publish.load_build(self.host, self.host.args, str(self.build), "HEAD")
        with self.assertRaisesRegex(publish.Refusal, "explicit_publisher_build_required"):
            publish.load_build(self.host, self.host.args, "", REVISION)

    def test_load_build_refuses_changed_artifact_mode_owner_link_or_size(self):
        artifact = self.build.parent / publish.ARTIFACT_NAME
        original = artifact.read_bytes()
        for case in ("mode", "bytes", "link", "size"):
            with self.subTest(case=case):
                if case == "mode":
                    artifact.chmod(0o755)
                elif case == "bytes":
                    artifact.write_bytes(original[:-1] + b"?")
                elif case == "link":
                    shutil.copyfile(artifact, self.root / "real-artifact")
                    artifact.unlink(); artifact.symlink_to(self.root / "real-artifact")
                else:
                    artifact.write_bytes(original + b"x")
                with self.assertRaisesRegex(publish.Refusal, "publisher_artifact_"):
                    publish.load_build(self.host, self.host.args, str(self.build), REVISION)
                if artifact.is_symlink():
                    artifact.unlink()
                artifact.write_bytes(original); artifact.chmod(0o700)
        self.assertEqual(publish.load_build(self.host, self.host.args, str(self.build), REVISION).sha256, publish.digest(original))

    def test_load_build_refuses_hash_elf_format_or_revision_drift(self):
        for case, data in (("machine", synthetic_elf(machine=183)), ("interpreter", synthetic_elf(b"/system/bin/linker\0")),
                           ("type", synthetic_elf(e_type=2))):
            with self.subTest(case=case):
                build = fake_build(self.root / ("bad-" + case), self.host.APP, data=data)
                with self.assertRaisesRegex(publish.Refusal, "publisher_artifact_target_invalid"):
                    publish.load_build(self.host, self.host.args, str(build), REVISION)
        receipt = json.loads(self.build.read_bytes())
        for key, value in (("format", "other/1"), ("ndk_revision", "27"), ("stderr", "warning")):
            with self.subTest(key=key):
                build = fake_build(self.root / ("receipt-" + key), self.host.APP)
                changed = dict(receipt, **{key: value})
                build.chmod(0o600); build.write_bytes(publish._encoded(changed))
                with self.assertRaisesRegex(publish.Refusal, "publisher_build_receipt_invalid"):
                    publish.load_build(self.host, self.host.args, str(build), REVISION)
        build = fake_build(self.root / "receipt-sha", self.host.APP)
        changed = json.loads(build.read_bytes()); changed["artifact"]["sha256"] = "0" * 64
        build.write_bytes(publish._encoded(changed))
        with self.assertRaisesRegex(publish.Refusal, "publisher_artifact_bytes_changed"):
            publish.load_build(self.host, self.host.args, str(build), REVISION)
        with self.assertRaises(publish.Refusal):
            publish.elf_facts(b"not an elf" * 10)

    # Build route (fake compiler only).
    def fake_ndk(self, revision=publish.NDK_REVISION, rc=0):
        ndk = self.host.sdk / "ndk" / publish.NDK_REVISION
        tools = ndk / "toolchains/llvm/prebuilt/linux-x86_64/bin"
        tools.mkdir(parents=True, exist_ok=True)
        (ndk / "source.properties").write_text("Pkg.Desc = Android NDK\nPkg.Revision = " + revision + "\n")
        (tools / "clang").write_text("synthetic resolved compiler\n")
        log = self.root / "compiler.json"
        compiler = tools / (publish.TARGET + "-clang")
        compiler.write_text("#!/usr/bin/env python3\n")
        return compiler, log, rc

    def fake_command(self, log, rc, data):
        def command(argv, *, check=True, timeout=30, env=None, input=None, binary=False):
            argv = list(map(str, argv))
            with log.open("a") as stream:
                stream.write(json.dumps({"argv": argv, "env": env, "timeout": timeout}) + "\n")
            if "-o" in argv and rc == 0:
                Path(argv[argv.index("-o") + 1]).write_bytes(data)
            failed = "-o" in argv and rc != 0
            return SimpleNamespace(returncode=rc if "-o" in argv else 0, stdout="", stderr="error" if failed else "")
        return command

    def test_build_uses_literal_ndk_argv_env_and_records_per_tu_checks(self):
        compiler, log, _ = self.fake_ndk()
        host = SimpleNamespace(APP=self.host.APP, command=self.fake_command(log, 0, synthetic_elf()))
        with patch.dict(os.environ, HOME="/synthetic-home"):
            receipt = publish.build(host, self.host.args, self.root / "built", REVISION)
        calls = [json.loads(line) for line in log.read_text().splitlines()]
        self.assertEqual(len(calls), 3)
        self.assertEqual(calls[2]["argv"], [str(compiler), "-std=c11", "-fPIE", "-pie", "-O2", "-Wall", "-Wextra", "-Werror",
            str(self.host.APP / publish.SHARED_SOURCE), str(self.host.APP / publish.CLI_SOURCE), "-o",
            str(self.root / "built" / publish.ARTIFACT_NAME)])
        self.assertTrue(all(call["argv"][1:6] == list(publish.SYNTAX_FLAGS) for call in calls[:2]))
        self.assertTrue(all(call["env"] == {"PATH": "/usr/bin:/bin", "LANG": "C.UTF-8", "HOME": "/synthetic-home"} for call in calls))
        self.assertNotIn("-D_GNU_SOURCE", calls[2]["argv"])
        self.assertEqual([check["argv"] for check in receipt["syntax_checks"]], [call["argv"] for call in calls[:2]])
        self.assertEqual(stat.S_IMODE((self.root / "built/build.json").stat().st_mode), 0o600)
        bound = publish.load_build(self.host, self.host.args, str(self.root / "built/build.json"), REVISION)
        self.assertEqual(bound.data, synthetic_elf())

    def test_build_refuses_existing_output_wrong_ndk_failure_or_bad_revision(self):
        compiler, log, _ = self.fake_ndk()
        host = SimpleNamespace(APP=self.host.APP, command=self.fake_command(log, 0, synthetic_elf()))
        (self.root / "exists").mkdir()
        with self.assertRaisesRegex(publish.Refusal, "output_exists"):
            publish.build(host, self.host.args, self.root / "exists", REVISION)
        with self.assertRaisesRegex(publish.Refusal, "build_source_required"):
            publish.build(host, self.host.args, self.root / "fresh", "$(touch canary)")
        self.fake_ndk(revision="27.0.1")
        with self.assertRaisesRegex(publish.Refusal, "pinned_ndk_required"):
            publish.build(host, self.host.args, self.root / "fresh", REVISION)
        self.fake_ndk()
        failing = SimpleNamespace(APP=self.host.APP, command=self.fake_command(log, 1, b""))
        with self.assertRaisesRegex(publish.Refusal, "publisher_build_failed"):
            publish.build(failing, self.host.args, self.root / "failed", REVISION)
        self.assertTrue((self.root / "failed/build-failure.json").is_file())
        wrong = SimpleNamespace(APP=self.host.APP, command=self.fake_command(log, 0, synthetic_elf(machine=183)))
        with self.assertRaisesRegex(publish.Refusal, "target_invalid"):
            publish.build(wrong, self.host.args, self.root / "wrong", REVISION)
        self.assertFalse((self.root / "wrong/build.json").exists())
        self.assertFalse(Path("canary").exists())

    # Make boundary and public hygiene.
    def test_make_publisher_build_inputs_stay_literal(self):
        tools = self.root / "literal-tools"
        tools.mkdir()
        log = self.root / "literal-route.json"
        fake = tools / "bash"
        fake.write_text('#!/usr/bin/env python3\nimport json,os,sys\nfrom pathlib import Path\n'
                        'Path(os.environ["FAKE_ROUTE_LOG"]).write_text(json.dumps({"argv": sys.argv[1:], '
                        '"source": os.environ.get("ALKION_PROOF_SOURCE")}))\n')
        fake.chmod(0o700)
        canaries = [self.root / ("canary-" + str(index)) for index in range(4)]
        output = '/tmp/out "q" `touch ' + str(canaries[0]) + '` $(touch ' + str(canaries[1]) + ') $(shell touch ' + str(canaries[2]) + ') ${ALKION_CANARY_VAR}'
        source = "a$(touch " + str(canaries[3]) + ")"
        env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ["PATH"], FAKE_ROUTE_LOG=str(log),
                   ALKION_CANARY_VAR="must-stay-literal")
        app = HERE.parent
        for origin in ("command-line", "environment"):
            with self.subTest(origin=origin):
                values = {"ALKION_OUTPUT": output, "ALKION_PROOF_SOURCE": source}
                argv = ["make", "-C", str(app), "android-synthetic-publisher"]
                variables = dict(env)
                if origin == "command-line":
                    argv += [key + "=" + value for key, value in values.items()]
                else:
                    variables.update(values)
                completed = subprocess.run(argv, env=variables, capture_output=True, text=True, timeout=10)
                self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
                self.assertEqual(json.loads(log.read_text()), {"argv": ["tool/android_synthetic.sh", "--action", "build-publisher",
                                                                        "--output", output], "source": source})
                self.assertFalse(any(path.exists() for path in canaries))

    def test_new_publisher_files_contain_no_private_identifiers(self):
        # Pattern scan only; modified files are scanned on their diff before review.
        names = ["tool/android_synthetic_publish.py", "tool/android_synthetic_publish_self_test.py",
                 "tool/android_synthetic_publish.c"]
        # Built by concatenation so this file does not match its own patterns.
        forbidden = [re.compile(pattern) for pattern in (
            "/" + "home/", r"\." + "data/", "/tmp/" + "alkion-", r"\bemulator-55(?!60\b|62\b)[0-9]{2}\b",
            r"\b" + "p" + r"sy\b", "@users" + r"\.noreply")]
        def synthetic(token):
            return len(set(token)) == 1
        for name in names:
            text = (HERE.parent / name).read_text()
            with self.subTest(name=name):
                for pattern in forbidden:
                    self.assertIsNone(pattern.search(text), pattern.pattern)
                for token in re.findall(r"(?<![A-Za-z0-9])[a-f0-9]{32}(?:[a-f0-9]{32})?(?![A-Za-z0-9])", text):
                    self.assertTrue(synthetic(token), "non-synthetic hex literal in " + name)


if __name__ == "__main__":
    print("Host-only publisher controls: fake transport, real host renameat2 and synthetic artifacts; no Android qualification.", flush=True)
    unittest.main(verbosity=2)
