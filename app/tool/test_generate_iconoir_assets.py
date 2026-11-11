"""Provenance, geometry and effective-stroke checks for the entire subset."""
import json
from pathlib import Path
import re
import unittest
import xml.etree.ElementTree as ET

import generate_iconoir_assets as generator


class IconoirAssetsTest(unittest.TestCase):
    def setUp(self):
        self.manifest = json.loads((generator.INPUT / 'manifest.json').read_text())

    def test_reproducible_subset_and_pinned_source_hashes(self):
        self.assertEqual(len(self.manifest['assets']), 49)
        self.assertEqual(len(self.manifest['custom_assets']), 42)
        self.assertEqual(generator.generate(check=True), 182)
        self.assertEqual(generator.outputs(), generator.outputs())
        self.assertEqual(self.manifest['revision'], '39834e3f193bc0cca2c36bebb6a650471977433d')
        self.assertEqual(self.manifest['license']['spdx'], 'MIT')
        for asset in self.manifest['assets']:
            # The filled favourite is the only original from the solid set.
            name = asset['name']
            path = ('/icons/solid/' + name.removesuffix('-solid') if name.endswith('-solid')
                    else '/icons/regular/' + name)
            self.assertTrue(asset['url'].endswith(path + '.svg'))
            self.assertIn(self.manifest['revision'], asset['url'])
        self.assertEqual([a['name'] for a in self.manifest['assets'] if a['name'].endswith('-solid')],
                         ['star-solid'])
        notice = (generator.OUTPUT / 'NOTICE').read_text()
        self.assertIn('Copyright (c) 2021 Luca Burgio', notice)
        self.assertIn('Permission is hereby granted', notice)

    def test_custom_authorship_is_distinct_and_geometry_unique(self):
        assets = self.manifest['custom_assets']
        self.assertEqual(len({a['sha256'] for a in assets}), len(assets))
        for asset in assets:
            self.assertTrue(asset['source'].startswith('custom/alkion-'))
            self.assertEqual(asset['author'], 'Animus Studio')
            self.assertEqual(asset['spdx'], 'AGPL-3.0-only')
            self.assertIn('not an Iconoir derivative', asset['provenance'])
            self.assertNotIn('url', asset)
        notice = (generator.OUTPUT / 'NOTICE').read_text()
        self.assertIn('Original Alkion category outlines', notice)
        self.assertIn('AGPL-3.0-only', notice)

    def test_complete_semantic_api(self):
        adapter = (generator.APP / 'lib/theme/alkion_icon.dart').read_text()
        mapped = dict(re.findall(r"^  (\w+)\('([^']+)'", adapter, re.MULTILINE))
        self.assertEqual(mapped, self.manifest['roles'])
        mirrored = re.findall(r"^  (\w+)\('[^']+', mirrorsInRtl: true\)", adapter, re.MULTILINE)
        self.assertEqual(set(mirrored), set(self.manifest['rtl_roles']))
        self.assertNotIn('play', mirrored)
        self.assertNotIn('history', mirrored)
        pubspec = (generator.APP / 'pubspec.yaml').read_text()
        self.assertIn('    - assets/icons/NOTICE', pubspec)
        self.assertNotIn('    - tool/iconoir/', pubspec)
        for tier in generator.TIERS:
            self.assertIn(f'    - assets/icons/stroke-{tier}/', pubspec)

    def test_every_geometry_fill_cap_join_and_effective_stroke(self):
        for asset in [*self.manifest['assets'], *self.manifest['custom_assets']]:
            original = ET.fromstring((generator.INPUT / asset['source']).read_bytes())
            for tier in generator.TIERS:
                with self.subTest(asset=asset['name'], tier=tier):
                    result = ET.fromstring((generator.OUTPUT / f'stroke-{tier}' / (asset['name'] + '.svg')).read_bytes())
                    self.assertEqual(len(list(original.iter())), len(list(result.iter())))
                    for before, after in zip(original.iter(), result.iter()):
                        self.assertEqual(before.tag, after.tag)
                        self.assertEqual({k: v for k, v in before.attrib.items() if k != 'stroke-width'},
                                         {k: v for k, v in after.attrib.items() if k != 'stroke-width'})
                    self.assert_effective_strokes(result, tier)

    def assert_effective_strokes(self, node, tier, stroke='none', width=None):
        stroke = node.attrib.get('stroke', stroke)
        width = node.attrib.get('stroke-width', width)
        if node.tag.split('}')[-1] in generator.PAINT_ELEMENTS and stroke != 'none':
            self.assertEqual(width, tier)
        for child in node:
            self.assert_effective_strokes(child, tier, stroke, width)

    def test_pause_explicit_descendant_overrides_are_normalized(self):
        source = (generator.INPUT / 'sources/pause.svg').read_bytes()
        self.assertEqual(source.count(b'stroke-width="1.5"'), 3)
        for tier in generator.TIERS:
            data = generator.normalize(source, tier)
            self.assertNotIn(b'stroke-width="1.5"', data)
            for child in ET.fromstring(data):
                self.assertEqual(child.attrib['stroke-width'], tier)

    def test_nested_inherited_strokes_and_css_fail_closed(self):
        source = b'<svg viewBox="0 0 24 24"><g stroke="currentColor" stroke-width="7"><path d="M0 0L1 1" stroke-width="9"/><path d="M0 1L1 2"/></g></svg>'
        result = ET.fromstring(generator.normalize(source, '1.25'))
        self.assert_effective_strokes(result, '1.25')
        with self.assertRaises(ValueError):
            generator.normalize(b'<svg viewBox="0 0 24 24" style="stroke-width:7"/>', '1.25')


if __name__ == '__main__':
    unittest.main()
