"""Independently authored ELF-header/ZIP fixtures, never real binary assets."""
import copy
import hashlib
from contextlib import redirect_stderr, redirect_stdout
import io
import importlib.util
import json
from pathlib import Path
import struct
import tempfile
import unittest
from unittest import mock
import warnings
from zipfile import ZipFile

spec = importlib.util.spec_from_file_location(
    'catalog_apk_verifier', Path(__file__).with_name('verify_catalog_trial_apk.py'))
verifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verifier)


def synthetic_elf(machine, suffix=b'synthetic-current-library'):
    header = bytearray(64)
    header[:7] = b'\x7fELF\x02\x01\x01'
    struct.pack_into('<H', header, 16, 3)  # Shared object; not a usable binary.
    struct.pack_into('<H', header, 18, machine)
    struct.pack_into('<I', header, 20, 1)
    struct.pack_into('<H', header, 52, 64)
    return bytes(header) + suffix


def synthetic_manifest(target):
    return {'format-version': [1, 0, 0], 'native-assets': {
        target: {key: ['absolute', library]
                 for key, library in verifier.SQLITE_LOADERS.items()}}}


class CatalogTrialApkTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='catalog-apk-synthetic-')
        self.root = Path(self.temp.name)
        self.apk = self.root / 'synthetic.apk'
        self.generated = self.root / 'generated-jni'

    def tearDown(self):
        self.temp.cleanup()

    def fixture(self, platform='android-arm64'):
        target, abi, machine = verifier.TARGETS[platform]
        entries = {verifier.MANIFEST: json.dumps(synthetic_manifest(target)).encode()}
        for library in verifier.REQUIRED_LIBRARIES:
            data = synthetic_elf(machine, f'synthetic-current-{library}'.encode())
            entries[f'lib/{abi}/{library}'] = data
            if library in verifier.SQLITE_LOADERS.values():
                output = self.generated / abi / library
                output.parent.mkdir(parents=True, exist_ok=True)
                output.write_bytes(data)
        return entries

    def write(self, entries):
        with ZipFile(self.apk, 'w') as archive:
            for name, data in entries.items():
                archive.writestr(name, data)

    def verify(self, platform='android-arm64'):
        return verifier.verify(self.apk, platform, self.generated)

    def test_accepts_both_selected_abis_and_unrelated_foreign_abi_plugins(self):
        for platform, (_, abi, machine) in verifier.TARGETS.items():
            with self.subTest(platform=platform):
                entries = self.fixture(platform)
                # Debug APKs legitimately retain other-ABI plugin outputs.
                entries['lib/armeabi-v7a/libsynthetic_plugin.so'] = b'synthetic-plugin'
                self.write(entries)
                receipt = self.verify(platform)
                self.assertEqual(receipt['abi'], abi)
                self.assertEqual(receipt['elf_machine'], machine)
                self.assertEqual(set(receipt['sha256']), set(verifier.REQUIRED_LIBRARIES))

    def test_rejects_observed_arm_manifest_with_only_x64_sqlite_payloads(self):
        entries = self.fixture()
        for library in verifier.SQLITE_LOADERS.values():
            del entries[f'lib/arm64-v8a/{library}']
            entries[f'lib/x86_64/{library}'] = synthetic_elf(62)
        self.write(entries)
        with self.assertRaisesRegex(ValueError, 'Missing selected-ABI'):
            self.verify()

    def test_rejects_stale_same_abi_bytes_for_either_sqlite_library(self):
        for library in verifier.SQLITE_LOADERS.values():
            with self.subTest(library=library):
                entries = self.fixture()
                entries[f'lib/arm64-v8a/{library}'] = synthetic_elf(183, b'synthetic-old-library')
                self.write(entries)
                with self.assertRaisesRegex(ValueError, 'Stale packaged library'):
                    self.verify()

    def test_rejects_wrong_machine_in_any_selected_library(self):
        for library in verifier.REQUIRED_LIBRARIES:
            with self.subTest(library=library):
                entries = self.fixture()
                entries[f'lib/arm64-v8a/{library}'] = synthetic_elf(62)
                self.write(entries)
                with self.assertRaisesRegex(ValueError, 'Wrong ELF machine'):
                    self.verify()

    def test_rejects_missing_required_member_including_manifest(self):
        for member in [verifier.MANIFEST, *(f'lib/arm64-v8a/{name}'
                                           for name in verifier.REQUIRED_LIBRARIES)]:
            with self.subTest(member=member):
                entries = self.fixture()
                del entries[member]
                self.write(entries)
                with self.assertRaisesRegex(ValueError, 'Missing'):
                    self.verify()

    def test_rejects_missing_or_wrong_loader_mapping_and_wrong_target(self):
        base = synthetic_manifest('android_arm64')
        loader = next(iter(verifier.SQLITE_LOADERS))
        missing = copy.deepcopy(base)
        del missing['native-assets']['android_arm64'][loader]
        wrong = copy.deepcopy(base)
        wrong['native-assets']['android_arm64'][loader] = ['absolute', 'libwrong.so']
        for manifest in [missing, wrong, synthetic_manifest('android_x64')]:
            with self.subTest(manifest=manifest):
                entries = self.fixture()
                entries[verifier.MANIFEST] = json.dumps(manifest).encode()
                self.write(entries)
                with self.assertRaisesRegex(ValueError, 'mapping|target'):
                    self.verify()

    def test_rejects_non_elf_truncated_32bit_big_endian_or_versioned_headers(self):
        valid = synthetic_elf(183)
        cases = [b'not-an-elf' * 8, valid[:24],
                 valid[:4] + b'\x01' + valid[5:],
                 valid[:5] + b'\x02' + valid[6:],
                 valid[:6] + b'\x02' + valid[7:],
                 valid[:20] + b'\x02\x00\x00\x00' + valid[24:]]
        for data in cases:
            with self.subTest(header=data[:24]):
                entries = self.fixture()
                entries['lib/arm64-v8a/libflutter.so'] = data
                self.write(entries)
                with self.assertRaisesRegex(ValueError, 'ELF'):
                    self.verify()

    def test_rejects_duplicate_zip_names_and_duplicate_json_keys(self):
        self.write(self.fixture())
        with warnings.catch_warnings():
            warnings.simplefilter('ignore', UserWarning)
            with ZipFile(self.apk, 'a') as archive:
                archive.writestr(verifier.MANIFEST, b'{}')
        with self.assertRaisesRegex(ValueError, 'Duplicate APK'):
            self.verify()
        entries = self.fixture()
        entries[verifier.MANIFEST] = b'{"format-version": [1,0,0], "format-version": [1,0,0]}'
        self.write(entries)
        with self.assertRaisesRegex(ValueError, 'Duplicate native manifest'):
            self.verify()

    def test_bounds_native_manifest_and_rejects_non_json(self):
        for data in [b' ' * (verifier.MAX_MANIFEST_BYTES + 1), b'{not-json}', b'\xff']:
            with self.subTest(length=len(data)):
                entries = self.fixture()
                entries[verifier.MANIFEST] = data
                self.write(entries)
                with self.assertRaises((ValueError, UnicodeError)):
                    self.verify()

    def test_cli_returns_failure_before_an_invalid_artifact_can_be_named(self):
        entries, assets = self.catalog_fixture()
        entries['lib/arm64-v8a/libsqlite3.so'] = synthetic_elf(183, b'synthetic-old')
        self.write(entries)
        stdout, stderr = io.StringIO(), io.StringIO()
        with redirect_stdout(stdout), redirect_stderr(stderr):
            status = verifier.main(['--apk', str(self.apk), '--platform', 'android-arm64',
                                    '--generated-jni-dir', str(self.generated),
                                    '--catalog-assets-dir', str(assets)])
        self.assertEqual(status, 1)
        self.assertEqual(stdout.getvalue(), '')
        self.assertIn('Stale packaged library', stderr.getvalue())

    def test_rejects_missing_or_wrong_machine_current_generated_library(self):
        library = 'libsqlite3.so'
        for data in [None, synthetic_elf(62)]:
            with self.subTest(missing=data is None):
                self.write(self.fixture())
                current = self.generated / 'arm64-v8a' / library
                if data is None:
                    current.unlink()
                else:
                    current.write_bytes(data)
                with self.assertRaisesRegex(ValueError, 'Missing current|Wrong ELF machine'):
                    self.verify()

    def test_cli_requires_explicit_catalog_assets_for_full_apk_qualification(self):
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as error:
            verifier.main(['--apk', str(self.apk), '--platform', 'android-arm64',
                           '--generated-jni-dir', str(self.generated)])
        self.assertEqual(error.exception.code, 2)

    def catalog_fixture(self, browse=True, development=False):
        from test_stage_catalog_trial import stager, synthetic_catalog, synthetic_browse
        catalog = synthetic_catalog()
        source_digest = stager.sha256(stager.encode(catalog))
        projected = stager.encode(stager.project(catalog))
        projection_digest = stager.sha256(projected)
        files = {stager.CATALOG_NAME: projected}
        metadata = None
        if browse:
            source_browse = synthetic_browse(catalog, source_digest)
            projected_browse = stager.encode(stager.project_browse(
                source_browse, catalog, source_digest, projection_digest))
            metadata = {'source_sha256': stager.sha256(stager.encode(source_browse)),
                        'projection_sha256': stager.sha256(projected_browse),
                        'classification_revision': source_browse['classification_revision']}
            files[stager.BROWSE_NAME] = projected_browse
        files[stager.MANIFEST_NAME] = stager.encode(stager.manifest_for(
            catalog, source_digest, projection_digest, metadata, development=development))
        assets = self.root / 'catalog-assets'
        prefix = 'flutter_assets/assets/catalog_trial/'
        directory = assets / prefix
        directory.mkdir(parents=True, exist_ok=True)
        entries = self.fixture()
        for name, data in files.items():
            (directory / name).write_bytes(data)
            entries['assets/' + prefix + name] = data
        return entries, assets

    def test_catalog_assets_bind_exact_packaged_bytes_with_old_and_browse_manifests(self):
        for browse in [True, False]:
            with self.subTest(browse=browse):
                # Separate root inventories for old and new bundles.
                if (self.root / 'catalog-assets').exists():
                    import shutil
                    shutil.rmtree(self.root / 'catalog-assets')
                entries, assets = self.catalog_fixture(browse)
                entries['assets/flutter_assets/assets/catalog_trial/README.md'] = b'Public notice'
                self.write(entries)
                receipt = verifier.verify(self.apk, 'android-arm64', self.generated, assets)
                self.assertEqual(len(receipt['catalog_assets_sha256']), 3 if browse else 2)

    def test_rejects_staged_asset_parent_symlink_before_reading(self):
        entries, assets = self.catalog_fixture()
        self.write(entries)
        link = self.root / 'synthetic-root-link'
        link.symlink_to(self.root, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, 'Redirected staged catalog assets'):
            verifier.verify(self.apk, 'android-arm64', self.generated, link / assets.name)

    def test_rejects_staged_manifest_symlink_before_reading_redirected_bytes(self):
        entries, assets = self.catalog_fixture()
        self.write(entries)
        target = self.root / 'synthetic-redirected-manifest.json'
        target.write_bytes(b'not-json-must-not-be-decoded')
        manifest = assets / 'flutter_assets/assets/catalog_trial/manifest.dev.json'
        manifest.unlink()
        manifest.symlink_to(target)
        with self.assertRaisesRegex(ValueError, 'Redirected staged catalog assets'):
            verifier.verify(self.apk, 'android-arm64', self.generated, assets)

    def test_rejects_missing_changed_or_extra_packaged_private_assets(self):
        base, assets = self.catalog_fixture()
        key = 'assets/flutter_assets/assets/catalog_trial/browse.dev.json'
        cases = [dict(base), dict(base), dict(base)]
        del cases[0][key]
        cases[1][key] += b' '
        cases[2]['assets/flutter_assets/assets/catalog_trial/private-review.json'] = b'{}'
        for entries in cases:
            with self.subTest(entries=len(entries)):
                self.write(entries)
                with self.assertRaisesRegex(ValueError, 'catalog asset'):
                    verifier.verify(self.apk, 'android-arm64', self.generated, assets)

    def code_fixture(self, mode='debug'):
        entries, assets = self.catalog_fixture(development=True)
        variant = 'devDebug' if mode == 'debug' else 'devRelease'
        capital = 'DevDebug' if mode == 'debug' else 'DevRelease'
        intermediates = self.root / 'intermediates'
        libraries = [*verifier.SQLITE_LOADERS.values()]
        if mode == 'release':
            libraries.append('libapp.so')
        transformed = {}
        for library in libraries:
            data = synthetic_elf(183, ('current-unstripped-' + library).encode())
            generated = self.generated / 'arm64-v8a' / library
            generated.parent.mkdir(parents=True, exist_ok=True)
            generated.write_bytes(data)
            source = (self.generated.parent / 'arm64-v8a/app.so' if library == 'libapp.so'
                      else self.generated.parent / 'native_assets/jniLibs/lib/arm64-v8a' / library)
            source.parent.mkdir(parents=True, exist_ok=True)
            source.write_bytes(data)
            for directory in (
                    intermediates / 'merged_jni_libs' / variant /
                    f'merge{capital}JniLibFolders/out/arm64-v8a',
                    intermediates / 'merged_native_libs' / variant /
                    f'merge{capital}NativeLibs/out/lib/arm64-v8a'):
                directory.mkdir(parents=True, exist_ok=True)
                (directory / library).write_bytes(data)
            output = (synthetic_elf(183, ('independently-stripped-' + library).encode())
                      if mode == 'release' else data)
            directory = (intermediates / 'stripped_native_libs' / variant /
                         f'strip{capital}DebugSymbols/out/lib/arm64-v8a')
            directory.mkdir(parents=True, exist_ok=True)
            (directory / library).write_bytes(output)
            entries['lib/arm64-v8a/' + library] = output
            transformed['app.so' if library == 'libapp.so' else library] = hashlib.sha256(output).hexdigest()
        if mode == 'debug':
            for name in verifier.DEBUG_CODE:
                data = ('current-code-' + name).encode()
                for directory in (self.generated.parent / 'flutter_assets',
                                  intermediates / 'assets/devDebug/mergeDevDebugAssets/flutter_assets'):
                    directory.mkdir(parents=True, exist_ok=True)
                    (directory / name).write_bytes(data)
                entries['assets/flutter_assets/' + name] = data
        self.write(entries)
        return entries, assets, intermediates, transformed

    def verify_code(self, assets, intermediates, mode='debug'):
        return verifier.verify(self.apk, 'android-arm64', self.generated, assets,
                               development=True, build_mode=mode, intermediates_dir=intermediates)

    def test_debug_dev_binds_all_jit_code_and_native_merge_layers(self):
        entries, assets, intermediates, _ = self.code_fixture()
        receipt = self.verify_code(assets, intermediates)
        self.assertEqual(set(receipt['code_chain']['debug_code_sha256']), set(verifier.DEBUG_CODE))
        entries['assets/flutter_assets/kernel_blob.bin'] = b'stale-code'
        self.write(entries)
        with self.assertRaisesRegex(ValueError, 'debug code asset'):
            self.verify_code(assets, intermediates)

    def test_release_dev_binds_current_aot_and_independent_strip_transform(self):
        _, assets, intermediates, transformed = self.code_fixture('release')
        with mock.patch.object(verifier, '_stripped_hash', side_effect=lambda source, *_: transformed[source.name]):
            receipt = self.verify_code(assets, intermediates, 'release')
            self.assertIn('libapp.so', receipt['code_chain']['libraries'])
            upstream = self.generated.parent / 'arm64-v8a/app.so'
            upstream.write_bytes(synthetic_elf(183, b'fresh-aot-but-stale-jni'))
            with self.assertRaisesRegex(ValueError, 'upstream/generated/merged'):
                self.verify_code(assets, intermediates, 'release')

    def test_rejects_stale_each_merge_layer_and_stripped_aot(self):
        for layer, suffix in (
                ('merged_jni_libs', 'mergeDevReleaseJniLibFolders/out/arm64-v8a'),
                ('merged_native_libs', 'mergeDevReleaseNativeLibs/out/lib/arm64-v8a'),
                ('stripped_native_libs', 'stripDevReleaseDebugSymbols/out/lib/arm64-v8a')):
            with self.subTest(layer=layer):
                if (self.root / 'catalog-assets').exists():
                    import shutil
                    shutil.rmtree(self.root / 'catalog-assets')
                _, assets, intermediates, transformed = self.code_fixture('release')
                (intermediates / layer / 'devRelease' / suffix / 'libapp.so').write_bytes(
                    synthetic_elf(183, b'stale-aot'))
                with mock.patch.object(verifier, '_stripped_hash', side_effect=lambda source, *_: transformed[source.name]):
                    with self.assertRaisesRegex(ValueError, 'Stale'):
                        self.verify_code(assets, intermediates, 'release')

    def test_rejects_missing_or_foreign_machine_aot(self):
        entries, assets, intermediates, transformed = self.code_fixture('release')
        for data in (None, synthetic_elf(62)):
            changed = dict(entries)
            member = 'lib/arm64-v8a/libapp.so'
            if data is None:
                del changed[member]
            else:
                changed[member] = data
            self.write(changed)
            with mock.patch.object(verifier, '_stripped_hash', side_effect=lambda source, *_: transformed[source.name]):
                with self.assertRaisesRegex(ValueError, 'Missing selected-ABI|Wrong ELF machine'):
                    self.verify_code(assets, intermediates, 'release')

    def test_dev_requires_schema3_and_explicit_code_mode(self):
        _, assets = self.catalog_fixture()
        with ZipFile(self.apk, 'w'):
            pass
        entries = self.fixture()
        self.write(entries)
        with self.assertRaisesRegex(ValueError, 'explicit build mode'):
            verifier.verify(self.apk, 'android-arm64', self.generated, development=True)
        with ZipFile(self.apk) as archive:
            with self.assertRaisesRegex(ValueError, 'Invalid catalog APK manifest'):
                verifier._verify_catalog_assets(archive, {}, assets, development=True)

    def test_public_no_input_inventory_rejects_any_private_payload(self):
        prefix = 'assets/flutter_assets/assets/catalog_trial/'
        self.write({prefix + 'README.md': b'public notice', 'assets/icon.png': b'public'})
        self.assertEqual(verifier.verify_public_catalog_assets(self.apk), {'private_catalog_assets': 'absent'})
        for name in ('catalog.dev.json', 'manifest.dev.json', 'browse.dev.json', 'review.json'):
            self.write({prefix + name: b'private-synthetic'})
            with self.assertRaisesRegex(ValueError, 'public/no-input'):
                verifier.verify_public_catalog_assets(self.apk)

    def test_strip_requires_explicit_pinned_ndk_before_invoking_tool(self):
        source = self.root / 'synthetic.so'
        source.write_bytes(synthetic_elf(183))
        with self.assertRaisesRegex(ValueError, 'explicit pinned NDK'):
            verifier._stripped_hash(source, 183, None)
        ndk = self.root / 'wrong-ndk'
        ndk.mkdir()
        (ndk / 'source.properties').write_text('Pkg.Revision = 0.0.0\n')
        with self.assertRaisesRegex(ValueError, 'pinned Flutter NDK'):
            verifier._stripped_hash(source, 183, ndk)

    def test_strip_uses_pinned_tool_and_independent_output_not_gradle_stripped_copy(self):
        source = self.root / 'current.so'
        source.write_bytes(synthetic_elf(183, b'current-unstripped'))
        expected = synthetic_elf(183, b'independent-stripped-output')
        ndk = self.root / 'pinned-ndk'
        bin_dir = ndk / 'toolchains/llvm/prebuilt/linux-x86_64/bin'
        bin_dir.mkdir(parents=True)
        (ndk / 'source.properties').write_text(f'Pkg.Revision = {verifier.PINNED_NDK}\n')
        (bin_dir / 'llvm-objcopy').write_bytes(b'synthetic-not-executable')
        (bin_dir / 'llvm-strip').symlink_to('llvm-objcopy')

        def transform(command, **kwargs):
            self.assertEqual(command[0], str(bin_dir / 'llvm-strip'))
            self.assertEqual(command[1:3], ['--strip-unneeded', '-o'])
            self.assertEqual(command[4], str(source))
            self.assertTrue(kwargs['check'])
            Path(command[3]).write_bytes(expected)

        with mock.patch.object(verifier.subprocess, 'run', side_effect=transform) as strip:
            digest = verifier._stripped_hash(source, 183, ndk)
        self.assertEqual(digest, hashlib.sha256(expected).hexdigest())
        self.assertEqual(strip.call_count, 1)
        self.assertEqual(source.read_bytes(), synthetic_elf(183, b'current-unstripped'))


if __name__ == '__main__':
    unittest.main()
