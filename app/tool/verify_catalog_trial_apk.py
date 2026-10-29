#!/usr/bin/env python3
"""Verify the selected native ABI and fresh SQLite payloads of a trial APK.

This reads explicitly supplied build artifacts only, without extracting the APK
or invoking Android tools. Other ABI plugin libraries may legitimately coexist.
"""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import sys
from zipfile import BadZipFile, ZipFile

TARGETS = {
    'android-arm64': ('android_arm64', 'arm64-v8a', 183),
    'android-x64': ('android_x64', 'x86_64', 62),
}
MANIFEST = 'assets/flutter_assets/NativeAssetsManifest.json'
MAX_MANIFEST_BYTES = 64 * 1024
SQLITE_LOADERS = {
    'package:sqlite3/src/ffi/libsqlite3.g.dart': 'libsqlite3.so',
    'package:sqlite3_connection_pool/sqlite3_connection_pool.dart':
        'libsqlite3_connection_pool.so',
}
REQUIRED_LIBRARIES = ('libflutter.so', *SQLITE_LOADERS.values())


def _object_pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('Duplicate native manifest JSON key')
        result[key] = value
    return result


def _invalid_constant(_):
    raise ValueError('Non-JSON numeric constant in native manifest')


def _verify_manifest(archive, entry, target):
    if entry.file_size > MAX_MANIFEST_BYTES:
        raise ValueError('Native manifest exceeds size limit')
    with archive.open(entry) as stream:
        data = stream.read(MAX_MANIFEST_BYTES + 1)
    if len(data) > MAX_MANIFEST_BYTES:
        raise ValueError('Native manifest exceeds size limit')
    manifest = json.loads(data.decode('utf-8'),
                          object_pairs_hook=_object_pairs,
                          parse_constant=_invalid_constant)
    if not isinstance(manifest, dict) or manifest.get('format-version') != [1, 0, 0]:
        raise ValueError('Unsupported native manifest format')
    platforms = manifest.get('native-assets')
    if not isinstance(platforms, dict) or not isinstance(platforms.get(target), dict):
        raise ValueError('Missing selected native manifest target')
    loaders = platforms[target]
    for loader, library in SQLITE_LOADERS.items():
        if loaders.get(loader) != ['absolute', library]:
            raise ValueError(f'Incorrect native loader mapping for {library}')


def _elf_hash(stream, machine, label):
    # ELF64's fixed header is 64 bytes. e_machine is the uint16 at offset 18;
    # byte order must be established before interpreting that value.
    header = stream.read(64)
    if len(header) != 64:
        raise ValueError(f'Truncated ELF header: {label}')
    if header[:4] != b'\x7fELF' or header[4] != 2 or header[5] != 1 or header[6] != 1:
        raise ValueError(f'Expected ELF64 little-endian version 1: {label}')
    if struct.unpack_from('<H', header, 18)[0] != machine:
        raise ValueError(f'Wrong ELF machine: {label}')
    if struct.unpack_from('<I', header, 20)[0] != 1:
        raise ValueError(f'Unsupported ELF header version: {label}')
    digest = hashlib.sha256(header)
    while chunk := stream.read(1024 * 1024):
        digest.update(chunk)
    return digest.hexdigest()


def verify(apk, platform, generated_jni_dir):
    """Return verified selected-ABI library digests, or fail closed."""
    if platform not in TARGETS:
        raise ValueError('Unsupported Android platform')
    target, abi, machine = TARGETS[platform]
    apk = Path(apk)
    generated_jni_dir = Path(generated_jni_dir)
    with ZipFile(apk) as archive:
        entries = {}
        for entry in archive.infolist():
            if entry.filename in entries:
                raise ValueError('Duplicate APK ZIP member')
            entries[entry.filename] = entry
        if MANIFEST not in entries:
            raise ValueError('Missing NativeAssetsManifest.json')
        _verify_manifest(archive, entries[MANIFEST], target)
        digests = {}
        for library in REQUIRED_LIBRARIES:
            member = f'lib/{abi}/{library}'
            if member not in entries:
                raise ValueError(f'Missing selected-ABI library: {library}')
            with archive.open(entries[member]) as stream:
                digests[library] = _elf_hash(stream, machine, f'APK {library}')
        for library in SQLITE_LOADERS.values():
            generated = generated_jni_dir / abi / library
            if not generated.is_file() or generated.is_symlink():
                raise ValueError(f'Missing current generated library: {library}')
            with generated.open('rb') as stream:
                current = _elf_hash(stream, machine, f'generated {library}')
            if current != digests[library]:
                raise ValueError(f'Stale packaged library differs from generated JNI: {library}')
    return {'platform': platform, 'abi': abi, 'elf_machine': machine,
            'sha256': digests}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apk', type=Path, required=True)
    parser.add_argument('--platform', choices=TARGETS, required=True)
    parser.add_argument('--generated-jni-dir', type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        receipt = verify(args.apk, args.platform, args.generated_jni_dir)
    except (OSError, ValueError, BadZipFile, RuntimeError) as error:
        print(f'Catalog trial APK verification failed: {error}', file=sys.stderr)
        return 1
    print(json.dumps(receipt, sort_keys=True))
    return 0


if __name__ == '__main__':
    sys.exit(main())
