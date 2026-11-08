#!/usr/bin/env python3
"""Retained Workout Guide source verifies, and the app never bundles it."""
import contextlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

import prepare_workout_guide_media as media


class SourceOnlyMediaTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.manifest = json.loads(media.MANIFEST.read_text())

    def test_actual_source_verifies_and_is_not_bundled(self):
        with contextlib.redirect_stdout(io.StringIO()) as output:
            media.verify(self.manifest)
        self.assertIn('not bundled', output.getvalue())
        self.assertNotIn('assets/workout_guide', media.PUBSPEC.read_text())
        self.assertFalse((media.APP / 'lib/catalog/catalog_media.dart').exists())

    def test_any_bundle_declaration_is_rejected(self):
        current = media.PUBSPEC.read_text()
        declarations = [
            '    - assets/workout_guide/LICENSE-ASSETS.txt\n',
            '    - assets/workout_guide/frames/bench-press/\n',
            '    - assets/workout_guide/\n',
        ]
        with tempfile.TemporaryDirectory(prefix='workout-guide-pubspec-test-') as temporary:
            pubspec = Path(temporary) / 'pubspec.yaml'
            for declaration in declarations:
                with self.subTest(declaration=declaration.strip()):
                    pubspec.write_text(current.replace('  assets:\n', '  assets:\n' + declaration, 1))
                    with mock.patch.object(media, 'PUBSPEC', pubspec):
                        with self.assertRaisesRegex(ValueError, 'source-only'):
                            media.verify(self.manifest)

    def test_changed_source_bytes_are_rejected(self):
        entry = self.manifest['entries'][0]
        frame = dict(entry['frames'][0], asset_sha256='0' * 64)
        changed = dict(self.manifest, entries=[dict(entry, frames=[frame])])
        with self.assertRaisesRegex(ValueError, 'Asset integrity mismatch'):
            media.verify(changed)


if __name__ == '__main__':
    unittest.main()
