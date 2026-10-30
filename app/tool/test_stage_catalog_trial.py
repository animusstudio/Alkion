import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location(
    'catalog_stager', Path(__file__).with_name('stage_catalog_trial.py'))
stager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stager)


def synthetic_catalog():
    # Independently authored evidence, never a candidate corpus excerpt.
    return {
        'format': 'alkion-exercise-catalog', 'schema_version': 1,
        'catalog_revision': 'synthetic.1', 'search_revision': 'synthetic-search.1',
        'equipment_kinds': ['dumbbell'],
        'facet_vocabulary': {'grip': ['neutral']},
        'families': [{'id': 'family-1', 'key': 'synthetic-curl',
                      'names': {'en': 'Synthetic curl'},
                      'source_path': '/private/synthetic-only'}],
        'variants': [{'id': 'variant-1', 'key': 'synthetic-neutral-curl',
                      'family_id': 'family-1', 'revision': 1,
                      'names': {'en': 'Synthetic neutral curl'},
                      'equipment_kind': 'dumbbell',
                      'facets': {'grip': 'neutral'},
                      'measurement_profile': 'load_reps',
                      'media': {'path': '/private/synthetic-image'}}],
        'collections': [{'id': 'collection-1', 'key': 'synthetic-neutral',
                         'names': {'en': 'Synthetic neutral'},
                         'selector': {'family_ids': ['family-1'],
                                      'facets': {'grip': ['neutral']},
                                      'source_path': '/private/synthetic'}}],
        'equipment_models': [],
        'measurement_profiles': [{'key': 'load_reps',
                                  'required_metrics': ['reported_load', 'repetitions'],
                                  'optional_metrics': [],
                                  'progression_policy': 'load_reps_only',
                                  'notes': 'Synthetic private note'}],
        'anatomy_nodes': [{'id': 'synthetic-elbow',
                          'names': {'en': 'Synthetic elbow flexors'},
                          'evidence_ids': ['private-synthetic-evidence']}],
        'muscle_profiles': [{'variant_id': 'variant-1', 'variant_revision': 1,
                             'coverage': 'partial', 'review': 'unadmitted',
                             'relationships': [{'anatomy_node_id': 'synthetic-elbow',
                                                'role': 'primary',
                                                'confidence': 'unadmitted',
                                                'evidence_ids': ['private-synthetic']}]}],
        'aliases': [{'id': 'term-1', 'text': 'Synthetic curl', 'locale': 'en',
                     'target': {'kind': 'family', 'id': 'family-1',
                                'evidence_path': '/private/synthetic'},
                     'qualifier': False, 'literal': True}],
        'scoped_terms': [], 'abbreviations': [],
        'evidence': [{'capture_path': '/private/synthetic-capture'}],
    }


def synthetic_browse(catalog, source_digest):
    return {
        'format': 'alkion-catalog-browse', 'schema_version': 1,
        'classification_revision': 'synthetic-browse.1',
        'catalog_revision': catalog['catalog_revision'], 'source_sha256': source_digest,
        'private_review': '/private/synthetic-review',
        'groups': [{'key': 'biceps', 'kind': 'muscle',
                    'names': {locale: 'Synthetic group' for locale in stager.LOCALES},
                    'synonyms': {locale: ['Synthetic synonym'] for locale in stager.LOCALES}},
                   {'key': 'mobility', 'kind': 'activity',
                    'names': {locale: 'Synthetic mobility' for locale in stager.LOCALES},
                    'synonyms': {locale: [] for locale in stager.LOCALES}}],
        'variants': [{'variant_id': row['id'], 'variant_revision': row['revision'],
                      'status': 'reviewed', 'target_groups': ['biceps'],
                      'secondary_groups': [], 'activity_groups': [],
                      'private_note': '/private/synthetic-exception'}
                     for row in catalog['variants']],
    }


class CatalogStagerTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='catalog-stage-synthetic-')
        self.root = Path(self.temp.name)
        self.original = stager.APP, stager.ASSETS, stager.ANDROID_ASSETS, stager.DEV_ANDROID_ASSETS
        stager.APP = self.root / 'app'
        stager.ASSETS = stager.APP / 'assets/catalog_trial'
        stager.ANDROID_ASSETS = stager.APP / 'build/private-catalog-trial/assets'
        stager.DEV_ANDROID_ASSETS = stager.APP / 'build/private-catalog-dev/assets'
        self.source = self.root / 'source.json'

    def tearDown(self):
        stager.APP, stager.ASSETS, stager.ANDROID_ASSETS, stager.DEV_ANDROID_ASSETS = self.original
        self.temp.cleanup()

    def write_source(self, catalog=None):
        data = stager.encode(catalog or synthetic_catalog())
        self.source.write_bytes(data)
        return stager.sha256(data)

    def test_development_admission_preserves_trial_and_exact_catalog_browse_bytes(self):
        digest = self.write_source()
        browse = self.root / 'browse.json'
        browse.write_bytes(stager.encode(synthetic_browse(synthetic_catalog(), digest)))
        stager.stage(self.source, digest, browse, stager.sha256(browse.read_bytes()))
        retained = {path: path.read_bytes() for root in (stager.ASSETS, stager.ANDROID_ASSETS)
                    for path in root.rglob('*') if path.is_file()}
        manifest = stager.stage_development()
        self.assertEqual(manifest['format'], 'alkion-catalog-development-manifest')
        self.assertEqual(manifest['schema_version'], 3)
        self.assertTrue(manifest['private_development_only'])
        self.assertNotIn('private_trial_only', manifest)
        self.assertFalse(manifest['redistribution_cleared'])
        mirror = stager.DEV_ANDROID_ASSETS / 'flutter_assets/assets/catalog_trial'
        for name in (stager.CATALOG_NAME, stager.BROWSE_NAME):
            self.assertEqual((mirror / name).read_bytes(), (stager.ASSETS / name).read_bytes())
        for path, data in retained.items():
            self.assertEqual(path.read_bytes(), data)
        self.assertEqual(stager.stage_development(), manifest)
        self.assertEqual(stager.verify(development=True), manifest)
        self.assertTrue(stager.verify()['private_trial_only'])

    def test_development_admission_refuses_corrupt_trial_or_changed_existing_mirror(self):
        stager.stage(self.source, self.write_source())
        stager.stage_development()
        mirror = stager.DEV_ANDROID_ASSETS / 'flutter_assets/assets/catalog_trial'
        (mirror / stager.CATALOG_NAME).write_bytes(b'preserve-existing-evidence')
        with self.assertRaisesRegex(ValueError, 'Existing staging differs'):
            stager.stage_development()
        self.assertEqual((mirror / stager.CATALOG_NAME).read_bytes(), b'preserve-existing-evidence')
        (stager.ASSETS / stager.CATALOG_NAME).write_bytes(b'corrupt-synthetic')
        with self.assertRaises(ValueError):
            stager.stage_development()

    def test_development_verifier_rejects_trial_scope_extra_files_and_redirected_paths(self):
        stager.stage(self.source, self.write_source())
        stager.stage_development()
        mirror = stager.DEV_ANDROID_ASSETS / 'flutter_assets/assets/catalog_trial'
        manifest = mirror / stager.MANIFEST_NAME
        admitted = manifest.read_bytes()
        manifest.write_bytes((stager.ASSETS / stager.MANIFEST_NAME).read_bytes())
        with self.assertRaisesRegex(ValueError, 'manifest'):
            stager.verify(development=True)
        manifest.write_bytes(admitted)
        extra = mirror / 'private-review.json'
        extra.write_bytes(b'{}')
        with self.assertRaisesRegex(ValueError, 'inventory'):
            stager.verify(development=True)
        extra.unlink()
        manifest.unlink()
        manifest.symlink_to(stager.ASSETS / stager.MANIFEST_NAME)
        with self.assertRaisesRegex(ValueError, 'redirected'):
            stager.verify(development=True)

    def test_projects_only_admitted_fields_and_verifies_exact_private_mirror(self):
        source_digest = self.write_source()
        original = self.source.read_bytes()
        manifest = stager.stage(self.source, source_digest)
        projected = stager.decode((stager.ASSETS / stager.CATALOG_NAME).read_bytes())
        self.assertEqual(projected['variants'][0]['id'], 'variant-1')
        self.assertEqual(projected['collections'][0]['selector'],
                         {'family_ids': ['family-1'], 'facets': {'grip': ['neutral']}})
        self.assertEqual(projected['muscle_profiles'][0]['relationships'],
                         [{'anatomy_node_id': 'synthetic-elbow', 'role': 'primary'}])
        combined = json.dumps(projected) + json.dumps(manifest)
        for excluded in ('/private/', 'capture_path', 'evidence_ids', 'confidence',
                         'source_path', 'media', 'notes', 'review'):
            if excluded == 'media':
                self.assertNotIn('"media"', json.dumps(projected))
            else:
                self.assertNotIn(excluded, combined)
        self.assertEqual(self.source.read_bytes(), original)
        self.assertTrue(manifest['private_trial_only'])
        self.assertFalse(manifest['redistribution_cleared'])
        self.assertFalse(manifest['media_included'])
        self.assertEqual(manifest['source_sha256'], source_digest)
        self.assertEqual(manifest['counts']['variants'], 1)
        self.assertEqual(stager.verify(), manifest)
        self.assertEqual(stager.stage(self.source, source_digest), manifest)

    def test_digest_mismatch_writes_nothing(self):
        self.write_source()
        with self.assertRaisesRegex(ValueError, 'reviewed SHA-256'):
            stager.stage(self.source, '0' * 64)
        self.assertFalse(stager.ASSETS.exists())
        self.assertFalse(stager.ANDROID_ASSETS.exists())

    def test_newer_schema_models_unknown_claims_and_bad_nested_values_are_refused(self):
        base = synthetic_catalog()
        mutations = [
            lambda c: c.update(schema_version=2),
            lambda c: c.update(equipment_models=[{'id': 'synthetic-model'}]),
            lambda c: c['muscle_profiles'][0].update(coverage='unknown'),
            lambda c: c['families'][0]['names'].update(en={'path': '/private/test'}),
            lambda c: c['aliases'][0].update(qualifier={'path': '/private/test'}),
            lambda c: c['aliases'][0]['target'].update(id={'path': '/private/test'}),
            lambda c: c['muscle_profiles'][0]['relationships'][0].update(
                emphasis={'path': '/private/test'}),
        ]
        for mutate in mutations:
            with self.subTest(mutate=mutate):
                catalog = copy.deepcopy(base)
                mutate(catalog)
                with self.assertRaises(ValueError):
                    stager.stage(self.source, self.write_source(catalog))
                self.assertFalse(stager.ASSETS.exists())

    def test_duplicate_keys_are_refused_even_when_digest_matches(self):
        data = b'{"format":"alkion-exercise-catalog","format":"other"}'
        self.source.write_bytes(data)
        with self.assertRaisesRegex(ValueError, 'Duplicate'):
            stager.stage(self.source, stager.sha256(data))
        self.assertFalse(stager.ASSETS.exists())

    def test_input_and_output_symlinks_are_refused_before_copy(self):
        digest = self.write_source()
        link = self.root / 'source-link.json'
        link.symlink_to(self.source)
        with self.assertRaisesRegex(ValueError, 'symlink'):
            stager.stage(link, digest)
        redirected = self.root / 'redirected'
        redirected.mkdir()
        stager.APP.mkdir()
        (stager.APP / 'assets').symlink_to(redirected, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, 'symlink'):
            stager.stage(self.source, digest)
        self.assertEqual(list(redirected.iterdir()), [])

    def test_tampered_projection_and_manifest_are_refused(self):
        digest = self.write_source()
        stager.stage(self.source, digest)
        path = stager.ASSETS / stager.CATALOG_NAME
        original = path.read_bytes()
        path.write_bytes(original + b' ')
        with self.assertRaises(ValueError):
            stager.verify()
        path.write_bytes(original)
        manifest_path = stager.ASSETS / stager.MANIFEST_NAME
        manifest = stager.decode(manifest_path.read_bytes())
        manifest['redistribution_cleared'] = True
        manifest_path.write_bytes(stager.encode(manifest))
        with self.assertRaisesRegex(ValueError, 'manifest'):
            stager.verify()

    def test_stale_staging_is_preserved_and_extra_android_assets_are_refused(self):
        digest = self.write_source()
        stager.stage(self.source, digest)
        original = (stager.ASSETS / stager.CATALOG_NAME).read_bytes()
        changed = synthetic_catalog()
        changed['catalog_revision'] = 'synthetic.2'
        with self.assertRaisesRegex(ValueError, 'Existing staging differs'):
            stager.stage(self.source, self.write_source(changed))
        self.assertEqual((stager.ASSETS / stager.CATALOG_NAME).read_bytes(), original)
        (stager.ANDROID_ASSETS / 'unadmitted-media.bin').write_bytes(b'synthetic')
        with self.assertRaisesRegex(ValueError, 'inventory'):
            stager.verify()

    def stage_browse(self, browse=None):
        digest = self.write_source()
        browse = browse if browse is not None else synthetic_browse(synthetic_catalog(), digest)
        path = self.root / 'browse.json'
        path.write_bytes(stager.encode(browse))
        return stager.stage(self.source, digest, path, stager.sha256(path.read_bytes()))

    def test_browse_is_separate_bound_allowlisted_and_original_anatomy_is_unchanged(self):
        manifest = self.stage_browse()
        self.assertEqual(manifest['schema_version'], 2)
        projected = stager.decode((stager.ASSETS / stager.BROWSE_NAME).read_bytes())
        self.assertEqual(projected['projection_sha256'], manifest['projection_sha256'])
        self.assertEqual(projected['variants'][0]['target_groups'], ['biceps'])
        self.assertNotIn('/private/', json.dumps(projected) + json.dumps(manifest))
        original = stager.project(synthetic_catalog())['muscle_profiles']
        actual = stager.decode((stager.ASSETS / stager.CATALOG_NAME).read_bytes())
        self.assertEqual(actual['muscle_profiles'], original)
        self.assertEqual(stager.verify(), manifest)

    def test_rejects_browse_missing_stale_duplicate_unsupported_or_conflicting_memberships(self):
        digest = self.write_source()
        base = synthetic_browse(synthetic_catalog(), digest)
        mutations = [
            lambda c: c.update(source_sha256='0' * 64),
            lambda c: c.update(schema_version=2),
            lambda c: c.update(schema_version=1.0),
            lambda c: c.update(catalog_revision='stale'),
            lambda c: c.update(variants=[]),
            lambda c: c['variants'].append(copy.deepcopy(c['variants'][0])),
            lambda c: c['groups'].append(copy.deepcopy(c['groups'][0])),
            lambda c: c['groups'][0].update(key='unsupported'),
            lambda c: c['variants'][0].update(variant_revision=2),
            lambda c: c['variants'][0].update(status='inferred'),
            lambda c: c['variants'][0].update(status='unresolved'),
            lambda c: c['variants'][0].update(target_groups=[]),
            lambda c: c['variants'][0].update(target_groups=[], secondary_groups=['biceps']),
            lambda c: c['variants'][0].update(secondary_groups=['biceps']),
            lambda c: c['variants'][0].update(target_groups=['biceps', 'biceps']),
            lambda c: c['variants'][0].update(activity_groups=['biceps']),
            lambda c: c['variants'][0].update(target_groups=['unknown']),
            lambda c: c['groups'][0]['names'].pop('de'),
            lambda c: c['groups'][0]['synonyms'].update(de=['same', 'same']),
        ]
        for mutate in mutations:
            with self.subTest(mutate=mutate):
                browse = copy.deepcopy(base)
                mutate(browse)
                with self.assertRaises(ValueError):
                    self.stage_browse(browse)
                self.assertFalse(stager.ASSETS.exists())

    def test_explicit_unresolved_and_activity_memberships_are_valid(self):
        digest = self.write_source()
        for membership in [dict(status='unresolved', target_groups=[]),
                           dict(target_groups=[], activity_groups=['mobility'])]:
            browse = synthetic_browse(synthetic_catalog(), digest)
            browse['variants'][0].update(membership)
            projected = stager.project_browse(browse, stager.project(synthetic_catalog()), digest, '1' * 64)
            self.assertEqual(projected['variants'][0]['status'], membership.get('status', 'reviewed'))

    def test_browse_digest_tampering_extra_assets_and_sidecar_symlink_are_rejected(self):
        digest = self.write_source()
        path = self.root / 'browse.json'
        path.write_bytes(stager.encode(synthetic_browse(synthetic_catalog(), digest)))
        with self.assertRaisesRegex(ValueError, 'reviewed SHA-256'):
            stager.stage(self.source, digest, path, '0' * 64)
        link = self.root / 'browse-link.json'
        link.symlink_to(path)
        with self.assertRaisesRegex(ValueError, 'regular file'):
            stager.stage(self.source, digest, link, stager.sha256(path.read_bytes()))
        self.stage_browse()
        output = stager.ASSETS / stager.BROWSE_NAME
        output.write_bytes(output.read_bytes() + b' ')
        with self.assertRaisesRegex(ValueError, 'Browse manifest'):
            stager.verify()


if __name__ == '__main__':
    unittest.main()
