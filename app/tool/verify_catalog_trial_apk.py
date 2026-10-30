#!/usr/bin/env python3
"""Verify the selected native ABI and fresh SQLite payloads of a trial APK.

This reads explicitly supplied build artifacts only, without extracting the APK
or invoking Android tools. Other ABI plugin libraries may legitimately coexist.
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
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
PINNED_NDK = '28.2.13676358'  # Flutter 3.44.0's pinned default.
DEBUG_CODE = ('kernel_blob.bin', 'isolate_snapshot_data', 'vm_snapshot_data')


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


def _verify_catalog_assets(archive, entries, assets_dir, *, development=False):
    """Bind the packaged private inventory to explicitly selected staged bytes."""
    spec = importlib.util.spec_from_file_location(
        'catalog_trial_stager', Path(__file__).with_name('stage_catalog_trial.py'))
    stager = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(stager)
    root = Path(assets_dir)
    if root.is_symlink() or not root.is_dir():
        raise ValueError('Missing or redirected staged catalog assets')
    prefix = 'flutter_assets/assets/catalog_trial/'
    directory = root / prefix
    for path in (directory, *directory.parents):
        if path.is_symlink():
            raise ValueError('Redirected staged catalog assets')
    if any(path.is_symlink() for path in root.rglob('*')):
        raise ValueError('Redirected staged catalog assets')
    manifest_path = directory / stager.MANIFEST_NAME
    manifest = stager.decode(manifest_path.read_bytes())
    names = {stager.CATALOG_NAME, stager.MANIFEST_NAME}
    metadata = manifest.get('browse')
    if metadata is not None:
        names.add(stager.BROWSE_NAME)
    allowed = {directory / name for name in names}
    if any(p.is_symlink() or (p.is_file() and p not in allowed) for p in root.rglob('*')):
        raise ValueError('Unexpected staged catalog asset inventory')
    data = {name: (directory / name).read_bytes() for name in names}
    catalog = stager.project(stager.decode(data[stager.CATALOG_NAME]))
    catalog_digest = stager.sha256(data[stager.CATALOG_NAME])
    if stager.encode(catalog) != data[stager.CATALOG_NAME]:
        raise ValueError('Unadmitted catalog APK projection')
    if metadata is not None:
        if (not isinstance(metadata, dict) or
                set(metadata) != {'source_sha256', 'projection_sha256', 'classification_revision'} or
                not isinstance(metadata.get('source_sha256'), str) or
                not stager.re.fullmatch(r'[0-9a-f]{64}', metadata['source_sha256'])):
            raise ValueError('Invalid browse APK manifest')
        browse = stager.project_browse(stager.decode(data[stager.BROWSE_NAME]), catalog,
                                      manifest.get('source_sha256'), catalog_digest)
        if (stager.encode(browse) != data[stager.BROWSE_NAME] or
                stager.sha256(data[stager.BROWSE_NAME]) != metadata.get('projection_sha256') or
                browse['classification_revision'] != metadata.get('classification_revision')):
            raise ValueError('Browse APK manifest mismatch')
    source_digest = manifest.get('source_sha256')
    if (not isinstance(source_digest, str) or not stager.re.fullmatch(r'[0-9a-f]{64}', source_digest) or
            manifest != stager.manifest_for(catalog, source_digest, catalog_digest, metadata,
                                           development=development)):
        raise ValueError('Invalid catalog APK manifest')
    packaged = {name for name in entries if name.startswith('assets/' + prefix) and
                not entries[name].is_dir()}
    # The ordinary pubspec's public README may coexist with the private mirror.
    packaged.discard('assets/' + prefix + 'README.md')
    if packaged != {'assets/' + prefix + name for name in names}:
        raise ValueError('Unexpected packaged catalog asset inventory')
    for name, expected in data.items():
        member = 'assets/' + prefix + name
        if entries[member].file_size != len(expected) or archive.read(entries[member]) != expected:
            raise ValueError('Packaged catalog asset differs from staged bytes')
    return {name: stager.sha256(value) for name, value in data.items()}


def verify_public_catalog_assets(apk):
    """A no-input/public APK may contain only the public catalog notice."""
    with ZipFile(apk) as archive:
        names = [entry.filename for entry in archive.infolist()]
        if len(names) != len(set(names)):
            raise ValueError('Duplicate APK ZIP member')
        prefix = 'assets/flutter_assets/assets/catalog_trial/'
        if any(name.startswith(prefix) and not name.endswith('/') and
               name != prefix + 'README.md' for name in names):
            raise ValueError('Private catalog assets in a public/no-input APK')
    return {'private_catalog_assets': 'absent'}


def _regular_file(path):
    path = Path(path)
    if any(item.is_symlink() for item in (path, *path.parents)) or not path.is_file():
        raise ValueError(f'Missing or redirected current build artifact: {path.name}')
    return path


def _file_elf_hash(path, machine):
    with _regular_file(path).open('rb') as stream:
        return _elf_hash(stream, machine, path.name)


def _stripped_hash(source, machine, ndk_dir):
    """Independently reproduce AGP's strip transform with the pinned NDK."""
    if ndk_dir is None:
        raise ValueError('Release verification requires the explicit pinned NDK directory')
    ndk = Path(ndk_dir)
    properties = _regular_file(ndk / 'source.properties').read_text()
    if not any(line.strip() == f'Pkg.Revision = {PINNED_NDK}'
               for line in properties.splitlines()):
        raise ValueError('Release verification requires the pinned Flutter NDK revision')
    bin_dir = ndk / 'toolchains/llvm/prebuilt/linux-x86_64/bin'
    tool = bin_dir / 'llvm-strip'
    # The official NDK llvm-strip is a same-directory llvm-objcopy symlink.
    if not tool.is_file() or tool.resolve().parent != bin_dir.resolve():
        raise ValueError('Missing or redirected pinned NDK llvm-strip')
    with tempfile.TemporaryDirectory(prefix='catalog-apk-strip-') as temp:
        output = Path(temp) / source.name
        subprocess.run([str(tool), '--strip-unneeded', '-o', str(output), str(source)],
                       check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        return _file_elf_hash(output, machine)


def _verify_code_chain(archive, entries, generated_jni, platform, build_mode,
                       intermediates_dir=None, ndk_dir=None):
    if build_mode not in ('debug', 'release'):
        raise ValueError('Unsupported catalog APK build mode')
    _, abi, machine = TARGETS[platform]
    generated_jni = Path(generated_jni)
    variant = 'devDebug' if build_mode == 'debug' else 'devRelease'
    capital = 'DevDebug' if build_mode == 'debug' else 'DevRelease'
    intermediates = (Path(intermediates_dir) if intermediates_dir is not None
                     else generated_jni.parents[2])
    libraries = [*SQLITE_LOADERS.values()]
    if build_mode == 'release':
        libraries.append('libapp.so')
    elif any(name.startswith('lib/') and name.endswith('/libapp.so') for name in entries):
        raise ValueError('Unexpected AOT library in a debug catalog APK')
    receipt = {}
    for library in libraries:
        source = (generated_jni.parent / abi / 'app.so' if library == 'libapp.so'
                  else generated_jni.parent / 'native_assets/jniLibs/lib' / abi / library)
        upstream = _file_elf_hash(source, machine)
        generated = _file_elf_hash(generated_jni / abi / library, machine)
        merged_jni = _file_elf_hash(
            intermediates / 'merged_jni_libs' / variant /
            f'merge{capital}JniLibFolders/out' / abi / library, machine)
        merged_native = _file_elf_hash(
            intermediates / 'merged_native_libs' / variant /
            f'merge{capital}NativeLibs/out/lib' / abi / library, machine)
        if len({upstream, generated, merged_jni, merged_native}) != 1:
            raise ValueError(f'Stale upstream/generated/merged JNI library: {library}')
        transformed = (_stripped_hash(source, machine, ndk_dir)
                       if build_mode == 'release' else generated)
        stripped = _file_elf_hash(
            intermediates / 'stripped_native_libs' / variant /
            f'strip{capital}DebugSymbols/out/lib' / abi / library, machine)
        member = f'lib/{abi}/{library}'
        if member not in entries:
            raise ValueError(f'Missing selected-ABI library: {library}')
        with archive.open(entries[member]) as stream:
            packaged = _elf_hash(stream, machine, f'APK {library}')
        if transformed != stripped or stripped != packaged:
            raise ValueError(f'Stale stripped/packaged library: {library}')
        receipt[library] = {'upstream_sha256': upstream, 'packaged_sha256': packaged}
    code = {}
    if build_mode == 'debug':
        generated_assets = generated_jni.parent / 'flutter_assets'
        merged_assets = intermediates / 'assets' / variant / f'merge{capital}Assets/flutter_assets'
        for name in DEBUG_CODE:
            source = _regular_file(generated_assets / name).read_bytes()
            merged = _regular_file(merged_assets / name).read_bytes()
            member = 'assets/flutter_assets/' + name
            if member not in entries or archive.read(entries[member]) != source or merged != source:
                raise ValueError(f'Stale or missing debug code asset: {name}')
            code[name] = hashlib.sha256(source).hexdigest()
    elif any('assets/flutter_assets/' + name in entries for name in DEBUG_CODE):
        raise ValueError('Unexpected debug code assets in a release catalog APK')
    return {'build_mode': build_mode, 'libraries': receipt, 'debug_code_sha256': code}


def verify(apk, platform, generated_jni_dir, catalog_assets_dir=None, *, development=False,
           build_mode=None, intermediates_dir=None, ndk_dir=None):
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
        catalog_assets = None
        if catalog_assets_dir is not None:
            catalog_assets = _verify_catalog_assets(archive, entries, catalog_assets_dir,
                                                    development=development)
        digests = {}
        for library in REQUIRED_LIBRARIES:
            member = f'lib/{abi}/{library}'
            if member not in entries:
                raise ValueError(f'Missing selected-ABI library: {library}')
            with archive.open(entries[member]) as stream:
                digests[library] = _elf_hash(stream, machine, f'APK {library}')
        for library in (() if build_mode == 'release' else SQLITE_LOADERS.values()):
            generated = generated_jni_dir / abi / library
            if not generated.is_file() or generated.is_symlink():
                raise ValueError(f'Missing current generated library: {library}')
            with generated.open('rb') as stream:
                current = _elf_hash(stream, machine, f'generated {library}')
            if current != digests[library]:
                raise ValueError(f'Stale packaged library differs from generated JNI: {library}')
        code_chain = None
        if development and build_mode is None:
            raise ValueError('Development APK verification requires an explicit build mode')
        if build_mode is not None:
            code_chain = _verify_code_chain(archive, entries, generated_jni_dir, platform,
                                           build_mode, intermediates_dir, ndk_dir)
    receipt = {'platform': platform, 'abi': abi, 'elf_machine': machine,
               'sha256': digests}
    if catalog_assets is not None:
        receipt['catalog_assets_sha256'] = catalog_assets
    if code_chain is not None:
        receipt['code_chain'] = code_chain
    return receipt


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apk', type=Path, required=True)
    parser.add_argument('--platform', choices=TARGETS)
    parser.add_argument('--generated-jni-dir', type=Path)
    parser.add_argument('--catalog-assets-dir', type=Path)
    parser.add_argument('--development', action='store_true')
    parser.add_argument('--public-catalog-assets-only', action='store_true')
    parser.add_argument('--build-mode', choices=('debug', 'release'))
    parser.add_argument('--intermediates-dir', type=Path)
    parser.add_argument('--ndk-dir', type=Path)
    args = parser.parse_args(argv)
    if not args.public_catalog_assets_only and not all((args.platform, args.generated_jni_dir,
                                                       args.catalog_assets_dir)):
        parser.error('Explicit platform, generated JNI and catalog assets are required')
    if args.public_catalog_assets_only and any((args.platform, args.generated_jni_dir,
            args.catalog_assets_dir, args.development, args.build_mode, args.intermediates_dir,
            args.ndk_dir)):
        parser.error('Public asset verification accepts only the explicit APK')
    try:
        receipt = (verify_public_catalog_assets(args.apk) if args.public_catalog_assets_only else
                   verify(args.apk, args.platform, args.generated_jni_dir, args.catalog_assets_dir,
                          development=args.development, build_mode=args.build_mode,
                          intermediates_dir=args.intermediates_dir, ndk_dir=args.ndk_dir))
    except (OSError, ValueError, BadZipFile, RuntimeError, subprocess.CalledProcessError) as error:
        print(f'Catalog trial APK verification failed: {error}', file=sys.stderr)
        return 1
    print(json.dumps(receipt, sort_keys=True))
    return 0


if __name__ == '__main__':
    sys.exit(main())
