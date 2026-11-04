#!/usr/bin/env python3
"""Guard formatter-tolerant comparison against changes to reviewed media semantics."""
import contextlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

import prepare_workout_guide_media as media


class ResolverTokenTest(unittest.TestCase):
    def test_dart_formatting_comments_and_optional_trailing_commas(self):
        generated = """
// Generated resolver
const registry = {
  'key': Registration(
    facets: {'ergometer_action': 'hand_foot_cycle',},
    revision: 1,
    assets: ['frame.webp',],
  ),
};
"""
        formatted = """
/* Different comment /* nested Dart comment */ */
const registry = {'key': Registration(
  facets: {'ergometer_action': 'hand_foot_cycle'}, // formatter inlined this
  revision: 1, assets: ['frame.webp'])}; // EOF comment
"""
        self.assertEqual(media.dart_resolver_tokens(generated), media.dart_resolver_tokens(formatted))

    def test_mapping_changes_remain_distinct(self):
        original = "Registration(facets: {'angle': 'flat'}, revision: 1, sourceUrl: 'https://source.test/a b',)"
        changes = {
            'facet': original.replace("'flat'", "'incline'"),
            'revision': original.replace('revision: 1', 'revision: 2'),
            'source': original.replace('source.test', 'different.test'),
            'literal whitespace': original.replace('/a b', '/a  b'),
            'removed literal whitespace': original.replace('/a b', '/ab'),
        }
        for label, changed in changes.items():
            with self.subTest(label=label):
                self.assertNotEqual(media.dart_resolver_tokens(original), media.dart_resolver_tokens(changed))

    def test_comments_and_comma_syntax_inside_literals_are_preserved(self):
        literal = "const text = 'https://example.test/a // literal /* keep */, }';"
        self.assertEqual(media.dart_resolver_tokens(literal), (
            'const', 'text', '=', "'https://example.test/a // literal /* keep */, }'", ';',
        ))
        self.assertNotEqual(media.dart_resolver_tokens(literal), media.dart_resolver_tokens(literal.replace(', }', '}')))

    def test_escaped_raw_and_multiline_literals_keep_exact_contents(self):
        examples = [
            r"const text = 'Bryl \' Lim // literal';",
            r"const text = r'back\slash // literal, }';",
            'const text = """line one\nline two // literal, }""";',
            r"const text = '\$literal /* keep */';",
        ]
        for original in examples:
            with self.subTest(source=original):
                # Only the whitespace outside the literal differs.
                formatted = original.replace('const text = ', 'const\ntext=')
                self.assertEqual(media.dart_resolver_tokens(original), media.dart_resolver_tokens(formatted))
                changed = original.replace('literal', 'different')
                self.assertNotEqual(media.dart_resolver_tokens(original), media.dart_resolver_tokens(changed))

    def test_token_boundaries_and_operators_are_not_whitespace_stripped(self):
        self.assertNotEqual(media.dart_resolver_tokens('final value;'), media.dart_resolver_tokens('finalvalue;'))
        self.assertNotEqual(media.dart_resolver_tokens('a != b'), media.dart_resolver_tokens('a ! = b'))

    def test_malformed_or_unsupported_source_fails_closed(self):
        for source in ["'unterminated", '/* unterminated', "'unescaped\nnewline'", "'${expression}'"]:
            with self.subTest(source=source), self.assertRaises(ValueError):
                media.dart_resolver_tokens(source)


class ActualResolverTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.manifest = json.loads(media.MANIFEST.read_text())
        cls.current = media.RESOLVER.read_text()

    def test_current_formatted_resolver_and_actual_bundle_verify(self):
        with contextlib.redirect_stdout(io.StringIO()):
            media.verify(self.manifest)

    def test_actual_resolver_semantic_changes_are_rejected(self):
        changes = {
            'facet': self.current.replace("'hand_foot_cycle'", "'different_cycle'", 1),
            'revision': self.current.replace('revision: 1', 'revision: 2', 1),
            'source': self.current.replace('https://github.com/bryllim/workout-guide/tree/', 'https://different.test/tree/', 1),
            'literal whitespace': self.current.replace('Bryl Lim', 'Bryl  Lim', 1),
        }
        with tempfile.TemporaryDirectory(prefix='workout-guide-resolver-test-') as temporary:
            resolver = Path(temporary) / 'catalog_media.dart'
            for label, changed in changes.items():
                with self.subTest(label=label):
                    self.assertNotEqual(self.current, changed)
                    resolver.write_text(changed)
                    with mock.patch.object(media, 'RESOLVER', resolver):
                        with self.assertRaisesRegex(ValueError, 'Resolver no longer matches reviewed manifest'):
                            media.verify(self.manifest)


if __name__ == '__main__':
    unittest.main()
