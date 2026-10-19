"""Reviewed no-replace publisher for the synthetic host proof writers.

Imported by the guarded harness routes and the Documents/capability modules.
It owns only four things: building the test-only CLI from committed source with
a literal NDK argv, binding that build receipt and artifact, bootstrapping the
artifact once per package into a fresh private cache namespace, and publishing
one closed owned file through the kernel no-replace rename of the shared native
primitive. Callers keep every receipt, APK, installed-identity and source
admission. Only the fixed programs below run on Android, always through the
exact serial with non-PTY binary `adb shell -T`, and every host value is a
separate argv item. There is no cleanup, copy-back, retry, overwrite or
alternate publisher; uncertain completion stays UNKNOWN.
"""

from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import stat
import struct
import subprocess
import time


BUILD_FORMAT = "alkion-android-publisher-build/1"
REPLY_FORMAT = "alkion-test-noreplace/1"
NDK_REVISION = "28.2.13676358"
TARGET = "x86_64-linux-android24"
CLI_SOURCE = "tool/android_synthetic_publish.c"
SHARED_SOURCE = "android/app/src/main/cpp/alkion_fileops.c"
ARTIFACT_NAME = "alkion-test-publish"
FLAGS = ("-std=c11", "-fPIE", "-pie", "-O2", "-Wall", "-Wextra", "-Werror")
SYNTAX_FLAGS = ("-std=c11", "-Wall", "-Wextra", "-Werror", "-fsyntax-only")
INTERPRETER = "/system/bin/linker64"
ARTIFACT_BOUND = 1048576
REPLY_BOUND = 4096
STDERR_BOUND = 65536
PAYLOAD_BOUND = 8 * 1024 * 1024
PATH_BOUND = 768
PUBLISH_TIMEOUT = 30
BUILD_TIMEOUT = 120
NAMESPACE_PREFIX = "cache/alkion-publish-"
REPLY_KEYS = ("format", "nonce", "expected_uid", "uid", "euid", "from", "to", "stage",
              "precondition_errno", "pre_fsync_errno", "rename_errno", "post_fsync_errno",
              "published", "source_consumed", "source_before", "source_after",
              "final_before", "final_after", "exit_code")
STAT_KEYS = ("errno", "dev", "ino", "uid", "gid", "mode", "nlink", "length",
             "mtime_sec", "mtime_nsec", "ctime_sec", "ctime_nsec")
IDENTITY_KEYS = ("dev", "ino", "uid", "gid", "mode", "nlink", "length")
STATES = ("NOT_ATTEMPTED", "PUBLISHED", "RENAMED_NOT_DURABLE", "NOT_PUBLISHED", "UNKNOWN")
GUARDS = {71: "runtime_uid_mismatch", 73: "namespace_missing_or_linked", 74: "helper_missing_or_linked",
          75: "helper_owner_mode_links_size_or_inode_changed", 76: "helper_bytes_changed"}
RECEIPT_KEYS = frozenset(("format", "source_commit", "target", "api", "abi", "ndk_revision", "compiler",
                          "cli_sha256", "shared_c_sha256", "argv", "env", "syntax_checks", "exit_code",
                          "stdout", "stderr", "artifact"))
PACKAGE = re.compile(r"[a-z][a-z0-9_]*(?:[.][a-z][a-z0-9_]*)+")
SEGMENT = re.compile(r"[A-Za-z0-9._-]+")

# Read-only facts for the exact run-as context, the cache root and the absent
# namespace. $1 is the new namespace.
PREFLIGHT = ('set -u; id -u; pwd -P; tr -d "\\000" < /proc/self/attr/current; printf "\\n"; '
             'if test ! -d cache || test -L cache; then exit 3; fi; stat -c "%u %a %h %F" cache; '
             'if test -e "$1" || test -L "$1"; then exit 4; fi')
# One exclusive copy of the reviewed artifact into a new private namespace.
# $1 uid, $2 namespace; stdin is the artifact.
BOOTSTRAP = ('set -eu; umask 077; if test "$(id -u)" != "$1"; then exit 71; fi; '
             'if test ! -d cache || test -L cache; then exit 73; fi; '
             'if test -e "$2" || test -L "$2"; then exit 74; fi; '
             'mkdir -m 700 "$2"; set -C; cat > "$2/publisher"; chmod 700 "$2/publisher"')
# Independent helper readback. $1 uid, $2 namespace.
READBACK = ('set -u; if test "$(id -u)" != "$1"; then exit 71; fi; h="$2/publisher"; '
            'if test ! -d "$2" || test -L "$2"; then exit 73; fi; '
            'if test ! -f "$h" || test -L "$h"; then exit 74; fi; '
            'stat -c "%u %a" "$2"; stat -c "%u %a %h %s %i" "$h"; sha256sum "$h"')
# The single publication. $1 uid, $2 namespace, $3 artifact length, $4 artifact
# sha256, $5 helper inode, $6 request nonce, $7 closed source, $8 final name.
PUBLISH = ('set -u; if test "$(id -u)" != "$1"; then exit 71; fi; '
           'if test ! -d "$2" || test -L "$2"; then exit 73; fi; h="$2/publisher"; '
           'if test ! -f "$h" || test -L "$h"; then exit 74; fi; '
           'if test "$(stat -c "%u %a %h %s %i" "$h")" != "$1 700 1 $3 $5"; then exit 75; fi; '
           'if test "$(sha256sum "$h")" != "$4  $h"; then exit 76; fi; '
           'exec "$h" "$1" "$6" "$7" "$8"')
PROGRAMS = (PREFLIGHT, BOOTSTRAP, READBACK, PUBLISH)


class Refusal(ValueError):
    pass


def require(value, reason):
    if not value:
        raise Refusal(reason)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def raw(value):
    return value if isinstance(value, bytes) else value.encode() if isinstance(value, str) else b""


def _relative(value):
    require(isinstance(value, str) and 0 < len(value.encode()) <= PATH_BOUND and
            not value.startswith("/") and not value.endswith("/") and
            all(SEGMENT.fullmatch(part) and part not in (".", "..") for part in value.split("/")),
            "publication_path_invalid")


def relative_pair(source, final):
    """Host mirror of the CLI argument contract, so a bad pair never reaches Android."""
    _relative(source)
    _relative(final)
    require("/" in source and "/" in final and source != final and
            source.rsplit("/", 1)[0] == final.rsplit("/", 1)[0], "publication_pair_invalid")


def package_name(value):
    require(isinstance(value, str) and len(value) <= 255 and PACKAGE.fullmatch(value), "publisher_package_invalid")
    return value


def elf_facts(data):
    """Header facts of a 64-bit little-endian ELF with one program interpreter."""
    require(len(data) >= 64 and data[:4] == b"\x7fELF" and data[4] == 2 and data[5] == 1, "publisher_artifact_not_elf64")
    e_type, machine = struct.unpack_from("<HH", data, 16)
    phoff = struct.unpack_from("<Q", data, 32)[0]
    phentsize, phnum = struct.unpack_from("<HH", data, 54)
    require(phentsize == 56 and 0 < phnum <= 64 and phoff + phnum * phentsize <= len(data), "publisher_artifact_headers_invalid")
    interpreters = []
    for index in range(phnum):
        entry = phoff + index * phentsize
        if struct.unpack_from("<I", data, entry)[0] == 3:
            offset, size = struct.unpack_from("<Q", data, entry + 8)[0], struct.unpack_from("<Q", data, entry + 32)[0]
            require(0 < size <= 256 and offset + size <= len(data), "publisher_artifact_interpreter_invalid")
            interpreters.append(data[offset:offset + size].rstrip(b"\0").decode("ascii", errors="replace"))
    require(len(interpreters) == 1, "publisher_artifact_interpreter_invalid")
    return {"class": 64, "machine": machine, "e_type": e_type, "interpreter": interpreters[0]}


def _expected_elf(facts):
    require(facts == {"class": 64, "machine": 62, "e_type": 3, "interpreter": INTERPRETER},
            "publisher_artifact_target_invalid")


def compiler_path(sdk):
    return Path(sdk) / "ndk" / NDK_REVISION / "toolchains/llvm/prebuilt/linux-x86_64/bin" / (TARGET + "-clang")


def build_arguments(sdk, app, output):
    return [str(compiler_path(sdk)), *FLAGS, str(Path(app) / SHARED_SOURCE), str(Path(app) / CLI_SOURCE),
            "-o", str(Path(output) / ARTIFACT_NAME)]


def _exclusive(path, data):
    with Path(path).open("xb") as stream:
        os.chmod(path, 0o600)
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())


def _encoded(value):
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def build(host, args, output, revision):
    """Host-only literal build; the caller supplies a fresh owned output path."""
    require(isinstance(revision, str) and re.fullmatch(r"[a-f0-9]{40}", revision), "publisher_build_source_required")
    output = Path(output)
    require(not output.exists() and not output.is_symlink(), "publisher_build_output_exists")
    ndk = Path(args.sdk) / "ndk" / NDK_REVISION
    properties = {}
    if (ndk / "source.properties").is_file():
        for line in (ndk / "source.properties").read_text().splitlines():
            if "=" in line:
                key, value = line.split("=", 1)
                properties[key.strip()] = value.strip()
    require(properties.get("Pkg.Revision") == NDK_REVISION, "pinned_ndk_required")
    compiler = compiler_path(args.sdk)
    require(compiler.is_file(), "pinned_ndk_compiler_required")
    resolved = (compiler.parent / "clang").resolve()
    require(resolved.is_file(), "pinned_ndk_clang_required")
    home = os.environ.get("HOME", "")
    require(home.startswith("/"), "absolute_home_required")
    environment = {"PATH": "/usr/bin:/bin", "LANG": "C.UTF-8", "HOME": home}
    sources = {name: Path(host.APP) / name for name in (SHARED_SOURCE, CLI_SOURCE)}
    require(all(path.is_file() and not path.is_symlink() for path in sources.values()), "publisher_sources_required")
    before = {name: digest(path.read_bytes()) for name, path in sources.items()}
    output.mkdir(mode=0o700)
    checks = []
    for name, path in sources.items():
        argv = [str(compiler), *SYNTAX_FLAGS, str(path)]
        result = host.command(argv, check=False, timeout=BUILD_TIMEOUT, env=environment)
        checks.append({"source": name, "argv": argv, "returncode": result.returncode,
                       "stdout": result.stdout, "stderr": result.stderr})
        require(result.returncode == 0 and not result.stdout and not result.stderr, "publisher_strict_syntax_check_failed")
    argv = build_arguments(args.sdk, host.APP, output)
    result = host.command(argv, check=False, timeout=BUILD_TIMEOUT, env=environment)
    receipt = {"format": BUILD_FORMAT, "source_commit": revision, "target": TARGET, "api": 24, "abi": "x86_64",
               "ndk_revision": NDK_REVISION,
               "compiler": {"path": str(compiler), "sha256": digest(compiler.read_bytes()),
                            "resolved_path": str(resolved), "resolved_sha256": digest(resolved.read_bytes())},
               "cli_sha256": before[CLI_SOURCE], "shared_c_sha256": before[SHARED_SOURCE], "argv": argv,
               "env": environment, "syntax_checks": checks, "exit_code": result.returncode,
               "stdout": result.stdout, "stderr": result.stderr, "artifact": None}
    if result.returncode != 0 or result.stdout or result.stderr:
        _exclusive(output / "build-failure.json", _encoded(receipt))
        raise Refusal("publisher_build_failed")
    require({name: digest(path.read_bytes()) for name, path in sources.items()} == before, "publisher_source_changed_during_build")
    artifact = output / ARTIFACT_NAME
    os.chmod(artifact, 0o700)
    facts = os.lstat(artifact)
    require(stat.S_ISREG(facts.st_mode) and facts.st_nlink == 1 and facts.st_uid == os.getuid() and
            0 < facts.st_size <= ARTIFACT_BOUND, "publisher_artifact_facts_invalid")
    data = artifact.read_bytes()
    elf = elf_facts(data)
    _expected_elf(elf)
    receipt["artifact"] = {"name": ARTIFACT_NAME, "sha256": digest(data), "length": len(data), "mode": "0700", "elf": elf}
    _exclusive(output / "build.json", _encoded(receipt))
    return receipt


@dataclass(frozen=True)
class Artifact:
    data: bytes
    sha256: str
    length: int
    receipt_sha256: str
    source_commit: str


def load_build(host, args, path, revision):
    """Bind an existing receipt to the clean source revision the caller runs at."""
    require(isinstance(path, str) and path, "explicit_publisher_build_required")
    require(isinstance(revision, str) and re.fullmatch(r"[a-f0-9]{40}", revision), "publisher_binding_source_required")
    receipt_path = host.temporary_path(path, must_exist=True)
    require(receipt_path.name == "build.json", "publisher_build_receipt_name_invalid")
    receipt = host.read_json(receipt_path, 65536)
    receipt_raw = receipt_path.read_bytes()
    require(isinstance(receipt, dict) and set(receipt) == RECEIPT_KEYS and receipt["format"] == BUILD_FORMAT and
            receipt["target"] == TARGET and receipt["api"] == 24 and receipt["abi"] == "x86_64" and
            receipt["ndk_revision"] == NDK_REVISION and receipt["exit_code"] == 0 and
            receipt["stdout"] == "" and receipt["stderr"] == "", "publisher_build_receipt_invalid")
    require(receipt["source_commit"] == revision, "publisher_build_source_commit_mismatch")
    require(receipt["cli_sha256"] == digest((Path(host.APP) / CLI_SOURCE).read_bytes()) and
            receipt["shared_c_sha256"] == digest((Path(host.APP) / SHARED_SOURCE).read_bytes()),
            "publisher_build_source_bytes_mismatch")
    facts = receipt["artifact"]
    require(isinstance(facts, dict) and set(facts) == {"name", "sha256", "length", "mode", "elf"} and
            facts["name"] == ARTIFACT_NAME and facts["mode"] == "0700" and type(facts["length"]) is int and
            isinstance(facts["sha256"], str) and re.fullmatch(r"[a-f0-9]{64}", facts["sha256"]),
            "publisher_build_receipt_invalid")
    artifact = receipt_path.parent / ARTIFACT_NAME
    observed = os.lstat(artifact)
    require(stat.S_ISREG(observed.st_mode) and observed.st_uid == os.getuid() and observed.st_nlink == 1 and
            stat.S_IMODE(observed.st_mode) == 0o700 and 0 < observed.st_size <= ARTIFACT_BOUND,
            "publisher_artifact_facts_changed")
    data = artifact.read_bytes()
    require(len(data) == facts["length"] and digest(data) == facts["sha256"], "publisher_artifact_bytes_changed")
    elf = elf_facts(data)
    require(elf == facts["elf"], "publisher_artifact_headers_changed")
    _expected_elf(elf)
    return Artifact(data, facts["sha256"], len(data), digest(receipt_raw), revision)


def _pairs(items):
    value = {}
    for key, item in items:
        require(key not in value, "publication_reply_duplicate_key")
        value[key] = item
    return value


def parse_reply(stdout):
    """Exactly one newline-terminated alkion-test-noreplace/1 object, or Refusal."""
    require(isinstance(stdout, bytes) and 0 < len(stdout) <= REPLY_BOUND and stdout.endswith(b"\n") and
            stdout.count(b"\n") == 1, "publication_reply_framing_invalid")
    try:
        value = json.loads(stdout[:-1].decode("ascii"), object_pairs_hook=_pairs,
                           parse_constant=lambda _: (_ for _ in ()).throw(Refusal("publication_reply_nonfinite")))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise Refusal("publication_reply_malformed") from error
    require(isinstance(value, dict) and tuple(value) == REPLY_KEYS and value["format"] == REPLY_FORMAT,
            "publication_reply_shape_invalid")
    return value


def _record(value):
    return (isinstance(value, dict) and tuple(value) == STAT_KEYS and value["errno"] == 0 and
            all(type(value[key]) is int for key in STAT_KEYS))


def _identity(value):
    return tuple(value[key] for key in IDENTITY_KEYS)


def _absent(value):
    return value == {"errno": 2}


def classify(returncode, stdout, stderr, *, nonce, uid, source, final, length):
    """Strict per-call state. Defaults are UNKNOWN unless an exact rule holds."""
    outcome = {"returncode": returncode, "stdout_length": len(raw(stdout)), "stderr_length": len(raw(stderr)),
               "reply": None, "state": "UNKNOWN", "claimed": None, "partial_consumed": "UNKNOWN",
               "final_published": "UNKNOWN", "basis": "none", "detail": None}
    stdout, stderr = raw(stdout), raw(stderr)
    if returncode in GUARDS and not stdout and not stderr:
        outcome.update(state="NOT_ATTEMPTED", partial_consumed=False, final_published=False, basis="guard_exit",
                       detail="guard_exit_" + str(returncode) + ":" + GUARDS[returncode])
        return outcome
    try:
        value = parse_reply(stdout)
    except Refusal as error:
        outcome["detail"] = str(error)
        return outcome
    outcome["reply"] = value
    bound = (value["nonce"] == nonce and value["from"] == source and value["to"] == final and
             all(type(value[key]) is int and value[key] == uid for key in ("expected_uid", "uid", "euid")) and
             type(value["exit_code"]) is int and type(value["published"]) is bool and
             type(value["source_consumed"]) is bool)
    if not bound:
        outcome["detail"] = "publication_reply_unbound"
        return outcome
    if stderr or len(stderr) > STDERR_BOUND or returncode != value["exit_code"] or returncode not in (0, 1, 2):
        outcome.update(basis="cli_self_report_over_failed_transport", detail="publication_transport_not_clean")
        return outcome
    before, after = value["source_before"], value["source_after"]
    final_before, final_after = value["final_before"], value["final_after"]
    rename, code, stage = value["rename_errno"], value["exit_code"], value["stage"]
    source_valid = (_record(before) and stat.S_ISREG(before["mode"]) and stat.S_IMODE(before["mode"]) == 0o600 and
                    before["uid"] == uid and before["nlink"] == 1 and before["length"] == length)
    if (code == 0 and stage == "complete" and rename == 0 and value["precondition_errno"] == 0 and
            value["pre_fsync_errno"] == 0 and value["post_fsync_errno"] == 0 and value["published"] and
            value["source_consumed"] and source_valid and _absent(after) and _absent(final_before) and
            _record(final_after) and _identity(final_after) == _identity(before)):
        outcome.update(claimed="PUBLISHED", partial_consumed=True, final_published=True,
                       basis="clean_reply_pending_final_readback", detail="complete")
    elif (code == 1 and stage == "native" and type(rename) is int and rename > 0 and value["post_fsync_errno"] is None and
            not value["published"] and not value["source_consumed"] and source_valid and after == before and
            final_before == final_after):
        outcome.update(state="NOT_PUBLISHED", partial_consumed=False, final_published=False, basis="clean_reply",
                       detail="rename_errno_" + str(rename))
    elif (code == 1 and rename == 0 and stage != "complete" and value["published"] and value["source_consumed"] and
            source_valid and _absent(after)):
        outcome.update(state="RENAMED_NOT_DURABLE", partial_consumed=True, final_published=True, basis="clean_reply",
                       detail="post_fsync_errno_" + str(value["post_fsync_errno"]))
    elif (rename is None and not value["published"] and not value["source_consumed"] and
            ((code == 2 and type(value["precondition_errno"]) is int and value["precondition_errno"] > 0) or
             (code == 1 and stage == "source-fsync" and type(value["pre_fsync_errno"]) is int and value["pre_fsync_errno"] > 0))):
        outcome.update(state="NOT_ATTEMPTED", partial_consumed=False, final_published=False, basis="clean_reply",
                       detail="precondition_errno_" + str(value["precondition_errno"]) + ":stage_" + str(stage))
    else:
        outcome["detail"] = "publication_reply_inconsistent"
    return outcome


class Session:
    """Per-campaign binding. Package states: bound, failed or never attempted."""

    def __init__(self, host, args, artifact, run_id, keep):
        self.host, self.args, self.artifact, self.run_id, self.keep = host, args, artifact, run_id, keep
        self.packages = {}

    def bound(self, package):
        return self.packages.get(package, {}).get("state") == "bound"

    def _remote(self, package, program, values, data=None):
        require(program in PROGRAMS, "publisher_program_not_fixed")
        argv = shlex.join(["run-as", package_name(package), "/system/bin/sh", "-c", program, "alkion-publish",
                           *map(str, values)])
        return self.host.command([Path(self.args.sdk) / "platform-tools/adb", "-s", self.args.serial, "shell", "-T", argv],
                                 binary=True, input=data, check=False, timeout=PUBLISH_TIMEOUT)

    def _context(self, package):
        return {"run_id": self.run_id, "serial": self.args.serial, "avd": getattr(self.args, "avd", None),
                "package": package, "artifact_sha256": self.artifact.sha256, "artifact_length": self.artifact.length,
                "receipt_sha256": self.artifact.receipt_sha256, "source_commit": self.artifact.source_commit}

    def _command(self, label, package, program, values, data=None):
        try:
            result = self._remote(package, program, values, data)
        except subprocess.TimeoutExpired as error:
            self.keep(label + ".timeout-stdout", raw(error.stdout))
            self.keep(label + ".timeout-stderr", raw(error.stderr))
            self.keep(label + ".json", {"completion": "UNKNOWN; no retry", "timeout_seconds": error.timeout})
            raise
        self.keep(label + ".stdout", raw(result.stdout))
        self.keep(label + ".stderr", raw(result.stderr))
        self.keep(label + ".json", {"returncode": result.returncode})
        return result

    def ensure(self, package, expected_uid=None):
        """Bound: no command. Failed: refuse. Never attempted: bootstrap exactly once."""
        package_name(package)
        current = self.packages.get(package)
        if current is not None:
            require(current["state"] == "bound", "publisher_bootstrap_failed_not_repeatable")
            require(expected_uid is None or expected_uid == current["uid"], "publisher_bound_uid_mismatch")
            return current["uid"]
        require(self.artifact is not None, "publisher_binding_required")
        self.packages[package] = {"state": "failed"}
        label = "publisher-bootstrap-" + package
        uid = self.host.package_metadata(self.args, package)["uid"]
        require(type(uid) is int and 10000 <= uid < 100000 and (expected_uid is None or uid == expected_uid),
                "publisher_package_uid_mismatch")
        namespace = NAMESPACE_PREFIX + os.urandom(16).hex()
        self.keep(label + ".request.json", {**self._context(package), "uid": uid, "namespace": namespace})
        facts = self._command(label + "-preflight", package, PREFLIGHT, [namespace])
        lines = raw(facts.stdout).decode(errors="replace").split("\n")
        require(facts.returncode == 0 and not facts.stderr and len(lines) == 5 and lines[4] == "" and
                lines[0] == str(uid) and lines[1] in ("/data/user/0/" + package, "/data/data/" + package) and
                re.fullmatch(r"u:r:[a-z_]+:s0(?::c[0-9]+(?:,c[0-9]+)*)?", lines[2]) is not None,
                "publisher_run_as_context_or_cache_invalid")
        cache = lines[3].split(" ")
        require(len(cache) == 4 and cache[0] == str(uid) and re.fullmatch(r"[0-7]{3,4}", cache[1]) and
                not int(cache[1], 8) & 0o002 and cache[3] == "directory", "publisher_cache_root_invalid")
        installed = self._command(label + "-install", package, BOOTSTRAP, [uid, namespace], self.artifact.data)
        require(installed.returncode == 0 and not installed.stdout and not installed.stderr, "publisher_bootstrap_failed")
        readback = self._command(label + "-readback", package, READBACK, [uid, namespace])
        rows = raw(readback.stdout).decode(errors="replace").split("\n")
        require(readback.returncode == 0 and not readback.stderr and len(rows) == 4 and rows[3] == "" and
                rows[0] == str(uid) + " 700" and rows[2] == self.artifact.sha256 + "  " + namespace + "/publisher",
                "publisher_helper_readback_invalid")
        helper = rows[1].split(" ")
        require(len(helper) == 5 and helper[:4] == [str(uid), "700", "1", str(self.artifact.length)] and
                helper[4].isdigit(), "publisher_helper_readback_invalid")
        self.packages[package] = {"state": "bound", "uid": uid, "namespace": namespace, "inode": int(helper[4])}
        self.keep(label + ".bound.json", {**self._context(package), "uid": uid, "namespace": namespace,
                                          "helper_inode": int(helper[4]), "preflight": lines[:4]})
        return uid

    def publish(self, package, source, final, data, name, readback):
        """Publish one closed owned file; return the verified record or raise Refusal."""
        package_name(package)
        relative_pair(source, final)
        require(isinstance(data, bytes) and len(data) <= PAYLOAD_BOUND, "publication_payload_invalid")
        require(self.bound(package), "publisher_not_bootstrapped")
        binding = self.packages[package]
        nonce = os.urandom(16).hex()
        request = {**self._context(package), "uid": binding["uid"], "namespace": binding["namespace"],
                   "helper_inode": binding["inode"], "nonce": nonce, "source_relative": source,
                   "final_relative": final, "length": len(data), "sha256": digest(data),
                   "timeout_seconds": PUBLISH_TIMEOUT, "program": "publish"}
        self.keep(name + ".publication-request.json", request)
        started = time.monotonic()
        values = [binding["uid"], binding["namespace"], self.artifact.length, self.artifact.sha256,
                  binding["inode"], nonce, source, final]
        try:
            result = self._remote(package, PUBLISH, values)
        except subprocess.TimeoutExpired as error:
            stdout, stderr = raw(error.stdout), raw(error.stderr)
            self.keep(name + ".publication.timeout-stdout", stdout)
            self.keep(name + ".publication.timeout-stderr", stderr)
            self.keep(name + ".publication.json", {"state": "UNKNOWN", "partial_consumed": "UNKNOWN",
                "final_published": "UNKNOWN", "basis": "none", "detail": "publication_timeout",
                "completion": "UNKNOWN; no retry or readback", "timeout_seconds": error.timeout,
                "elapsed_seconds": time.monotonic() - started})
            raise
        stdout, stderr = raw(result.stdout), raw(result.stderr)
        self.keep(name + ".publication.stdout", stdout)
        self.keep(name + ".publication.stderr", stderr)
        outcome = classify(result.returncode, stdout, stderr, nonce=nonce, uid=binding["uid"],
                           source=source, final=final, length=len(data))
        outcome["elapsed_seconds"] = time.monotonic() - started
        self.keep(name + ".publication.json", outcome)
        if outcome["claimed"] != "PUBLISHED":
            raise Refusal("publication:" + outcome["state"] + ":" + str(outcome["detail"]))
        final_record = {"state": "UNKNOWN", "partial_consumed": True, "final_published": True,
                        "basis": "clean_reply", "final_relative": final, "length": len(data), "sha256": digest(data)}
        try:
            observed = readback(package, final, max(1, len(data)), name + "-final")
        except Exception as error:
            final_record.update(detail="final_readback_failed:" + str(error))
            self.keep(name + ".publication-final.json", final_record)
            raise Refusal("publication:UNKNOWN:final_readback_failed") from error
        verified = isinstance(observed, bytes) and observed == data
        final_record.update(state="PUBLISHED" if verified else "UNKNOWN",
                            basis="clean_reply+final_readback" if verified else "clean_reply",
                            final_length=len(observed) if isinstance(observed, bytes) else None,
                            final_sha256=digest(observed) if isinstance(observed, bytes) else None,
                            detail="complete" if verified else "final_readback_mismatch")
        self.keep(name + ".publication-final.json", final_record)
        require(verified, "publication:UNKNOWN:final_readback_mismatch")
        return final_record
