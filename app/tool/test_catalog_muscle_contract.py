import copy
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import catalog_muscle_contract as contract
import stage_catalog_trial as stager


class MuscleStageTest(unittest.TestCase):
    def fixture(self):
        return json.loads((Path(__file__).parents[1] / 'test/fixtures/catalog_muscle_v2/synthetic.json').read_text())

    def admit(self, f):
        scope = f['scopes']['scopes'][0]
        for p in f['bundle']['profiles']:
            p['scope_ref']['sha256'] = contract.digest(scope)
            a = next(a for a in f['bundle']['assessments'] if a['id'] == p['assessment_id'])
            a['scope_ref'] = copy.deepcopy(p['scope_ref'])
            a['profile_sha256'] = contract.digest(p)
        f['bundle']['scope_registry_ref']['sha256'] = contract.digest(f['scopes'])
        raw = stager.encode(f['bundle'])
        f['catalog']['muscle_bundle_ref']['sha256'] = stager.sha256(raw)
        contract.validate_inputs(f['catalog'], f['bundle'], f['scopes'], raw)

    def high_fixture(self):
        f = self.fixture()
        f['bundle']['sources'].append({**f['bundle']['sources'][0], 'id': 'synthetic_source_two',
                                       'publisher_id': 'synthetic_publisher_two', 'url': 'https://second-publisher.example/execution'})
        f['bundle']['claims'].append({**f['bundle']['claims'][0], 'id': 'synthetic_claim_two',
                                      'source_id': 'synthetic_source_two', 'url': 'https://second-publisher.example/execution'})
        r = f['bundle']['profiles'][0]['relationships'][0]
        r['confidence'] = 'high'
        r['claim_ids'] = ['synthetic_claim', 'synthetic_claim_two']
        r['confidence_criteria']['independent_source_ids'] = ['synthetic_source', 'synthetic_source_two']
        f['bundle']['assessments'][0]['dispositions'][0]['claim_ids'] = list(r['claim_ids'])
        return f

    def test_complete_scope_search_timing_and_strict_calendar_formats(self):
        for searched, admitted in [
            ('2026-11-03T00:00:00Z', True), ('2026-11-03T00:00:01Z', True),
            ('2026-11-02T23:59:59Z', False), ('2026-11-03', False),
            ('2026-11-04', True), ('2026-11-02', False),
            ('2026-11-31', False), ('2026-11-03T24:00:00Z', False),
        ]:
            with self.subTest(searched=searched):
                f = self.fixture()
                f['bundle']['assessments'][0]['searched_on'] = searched
                if admitted:
                    self.admit(f)
                else:
                    with self.assertRaises(ValueError):
                        self.admit(f)

    def test_confidence_requires_matching_sources_and_independent_publishers(self):
        self.admit(self.high_fixture())
        for mutate in [
            lambda f: f['bundle']['sources'][-1].update(publisher_id='synthetic_publisher'),
            lambda f: f['bundle']['sources'][-1].update(publication_status='retracted'),
            lambda f: f['bundle']['profiles'][0]['relationships'][0]['confidence_criteria'].update(exact_execution_supported=False),
            lambda f: f['bundle']['profiles'][0]['relationships'][0]['confidence_criteria'].update(material_conflict=True),
            lambda f: f['bundle']['profiles'][0]['relationships'][0]['confidence_criteria'].update(independent_source_ids=['synthetic_source']),
        ]:
            f = self.high_fixture()
            mutate(f)
            with self.assertRaises(ValueError):
                self.admit(f)
        f = self.fixture()
        f['bundle']['profiles'][0]['relationships'][0]['confidence'] = 'low'
        self.admit(f)
        f['bundle']['profiles'][0]['relationships'][0]['confidence_criteria']['limitations'] = []
        with self.assertRaises(ValueError):
            self.admit(f)

    def test_supported_cells_gaps_and_precise_source_links(self):
        for mutate in [
            lambda f: f['bundle']['assessments'][0]['dispositions'][0].update(claim_ids=[]),
            lambda f: f['bundle']['claims'][0].update(url='https://other.example/unsupported'),
            lambda f: f['bundle']['profiles'][0].update(coverage='partial'),
            lambda f: f['bundle']['assessments'][0].update(assessment_status='pending'),
        ]:
            f = self.fixture()
            mutate(f)
            with self.assertRaises(ValueError):
                self.admit(f)
        f = self.fixture()
        f['bundle']['profiles'][0]['coverage'] = 'partial'
        f['bundle']['assessments'][0]['unresolved'] = [{'reason': 'Synthetic unresolved evidence.', 'next_evidence_needed': 'Independent source.'}]
        self.admit(f)

    def test_portable_schema_dart_mirror_is_exact(self):
        source = (Path(__file__).parents[1] / 'lib/catalog/muscle_schema.dart').read_text()
        self.assertEqual(json.loads(source.split("r'''", 1)[1].rsplit("'''", 1)[0]), contract.SCHEMA)

    def test_raw_bundle_and_independent_scopes_are_retained_and_verified(self):
        f = self.fixture()
        # Whitespace is deliberately non-canonical: the exact raw artifact is pinned.
        muscle = json.dumps(f['bundle'], ensure_ascii=False, indent=3).encode() + b'\n'
        f['catalog']['muscle_bundle_ref']['sha256'] = stager.sha256(muscle)
        scopes = stager.encode(f['scopes'])
        source = stager.encode(f['catalog'])
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            paths = [root / name for name in ['catalog.json', 'muscles.json', 'scopes.json']]
            for path, data in zip(paths, [source, muscle, scopes]):
                path.write_bytes(data)
            with patch.object(stager, 'APP', root), patch.object(stager, 'ASSETS', root/'assets'), patch.object(stager, 'ANDROID_ASSETS', root/'trial'), patch.object(stager, 'DEV_ANDROID_ASSETS', root/'dev'):
                m = stager.stage(paths[0], stager.sha256(source), muscle_path=paths[1], muscle_sha256=stager.sha256(muscle), scopes_path=paths[2], scopes_sha256=stager.sha256(scopes))
                self.assertEqual(m['schema_version'], 4)
                self.assertEqual((stager.ASSETS/stager.MUSCLE_NAME).read_bytes(), muscle)
                self.assertEqual(m['source_sha256'], stager.sha256(source))
                self.assertEqual(m['projection_sha256'], stager.sha256(stager.encode(f['catalog'])))
                dev = stager.stage_development()
                self.assertTrue(dev['private_development_only'])
                self.assertEqual(dev['muscle_bundle'], m['muscle_bundle'])
                (stager.ASSETS/stager.MUSCLE_NAME).write_bytes(muscle+b' ')
                with self.assertRaises(ValueError):
                    stager.verify()

    def test_version_pointer_scope_and_assessment_hash_fail_closed(self):
        for mutate in [
            lambda f: f['bundle'].update(schema_version=3),
            lambda f: f['catalog']['muscle_bundle_ref'].update(namespace='other'),
            lambda f: f['scopes'].update(revision='other'),
            lambda f: f['bundle']['assessments'][0].update(profile_sha256='f'*64),
        ]:
            f = copy.deepcopy(self.fixture())
            mutate(f)
            raw = json.dumps(f['bundle']).encode()
            f['catalog']['muscle_bundle_ref']['sha256'] = stager.sha256(raw)
            with self.assertRaises(ValueError):
                contract.validate_inputs(f['catalog'], f['bundle'], f['scopes'], raw)


if __name__ == '__main__':
    unittest.main()
