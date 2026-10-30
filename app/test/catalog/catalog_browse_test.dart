import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/catalog/catalog.dart';

import 'catalog_fixture.dart';

void main() {
  late List<int> catalogBytes;
  late CatalogBundle original;
  late Map<String, dynamic> browse;
  const sourceDigest =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  setUp(() {
    catalogBytes = utf8.encode(jsonEncode(syntheticCatalog()));
    original = CatalogBundle.fromBytes(catalogBytes);
    browse = {
      'format': 'alkion-catalog-browse',
      'schema_version': 1,
      'classification_revision': 'synthetic.1',
      'source_sha256': sourceDigest,
      'catalog_revision': original.catalogRevision,
      'projection_sha256': original.digest,
      'groups': [
        {
          'key': 'biceps',
          'kind': 'muscle',
          'names': {
            for (final locale in CatalogBrowse.locales)
              locale: 'Synthetic group',
          },
          'synonyms': {
            for (final locale in CatalogBrowse.locales)
              locale: ['Synthetic synonym'],
          },
        },
        {
          'key': 'mobility',
          'kind': 'activity',
          'names': {
            for (final locale in CatalogBrowse.locales)
              locale: 'Synthetic mobility',
          },
          'synonyms': {
            for (final locale in CatalogBrowse.locales) locale: <String>[],
          },
        },
      ],
      'variants': [
        for (final v in original.variants.values)
          {
            'variant_id': v.id,
            'variant_revision': v.revision,
            'status': 'reviewed',
            'target_groups': ['biceps'],
            'secondary_groups': <String>[],
            'activity_groups': <String>[],
          },
      ],
    };
  });
  CatalogBundle load({String? expectedDigest}) {
    final text = jsonEncode(browse);
    return CatalogBundle.fromBytes(
      catalogBytes,
      browseBytes: utf8.encode(text),
      browseSha256: expectedDigest ?? catalogHash(text),
      browseRevision: 'synthetic.1',
      sourceSha256: sourceDigest,
    );
  }

  test('old bundles remain readable with explicit missing browse state', () {
    expect(original.browse, isNull);
    expect(original.browseUnavailableReason, 'missing');
    expect(original.terms, isNotEmpty);
  });
  test('reviewed memberships are separate, digest bound and immutable', () {
    final bundle = load();
    expect(bundle.browseUnavailableReason, isNull);
    expect(bundle.browse!.variants.length, original.variants.length);
    expect(bundle.browse!.variants.values.first.targetGroups, {'biceps'});
    expect(bundle.digest, original.digest);
    expect(bundle.browse!.groups['biceps']!.synonyms['de'], [
      'Synthetic synonym',
    ]);
    for (final v in bundle.variants.values) {
      expect(v.muscleCoverage, original.variants[v.id]!.muscleCoverage);
      expect(
        v.muscleRelationships.map((r) => '${r.anatomyNodeId}:${r.role}'),
        original.variants[v.id]!.muscleRelationships.map(
          (r) => '${r.anatomyNodeId}:${r.role}',
        ),
      );
    }
    expect(
      () => bundle.browse!.variants.values.first.targetGroups.add('chest'),
      throwsUnsupportedError,
    );
  });
  test(
    'invalid optional browse degrades while core digest remains enforced',
    () {
      final bundle = load(expectedDigest: 'bad');
      expect(bundle.browse, isNull);
      expect(bundle.browseUnavailableReason, 'invalid');
      expect(bundle.variants.length, original.variants.length);
      expect(
        () => CatalogBundle.fromBytes(catalogBytes, expectedSha256: 'bad'),
        throwsA(isA<CatalogFormatException>()),
      );
    },
  );
  test(
    'stale, incomplete, duplicate and unsupported classifications reject only browse',
    () {
      final mutations = <void Function(Map<String, dynamic>)>[
        (b) => b['source_sha256'] = 'bad',
        (b) => b['projection_sha256'] = 'bad',
        (b) => b['schema_version'] = 2,
        (b) => b['schema_version'] = 1.0,
        (b) => b['classification_revision'] = 'stale',
        (b) => b['variants'][0]['variant_revision'] = 2,
        (b) => b['variants'][0]['variant_id'] = 'unknown',
        (b) => b['variants'].removeLast(),
        (b) => b['variants'].add(b['variants'][0]),
        (b) => b['groups'].add(b['groups'][0]),
        (b) => b['groups'][0]['key'] = 'unsupported',
        (b) => b['variants'][0]['target_groups'] = ['unknown'],
        (b) => b['variants'][0]['target_groups'] = ['biceps', 'biceps'],
        (b) => b['variants'][0]['secondary_groups'] = ['biceps'],
        (b) => b['variants'][0]['status'] = 'unresolved',
        (b) => b['variants'][0]['target_groups'] = <String>[],
        (b) {
          b['variants'][0]['target_groups'] = <String>[];
          b['variants'][0]['secondary_groups'] = ['biceps'];
        },
        (b) => b['variants'][0]['activity_groups'] = ['biceps'],
        (b) => b['groups'][0]['names'].remove('de'),
        (b) => b['groups'][0]['synonyms']['de'] = ['same', 'same'],
        (b) => b['private_note'] = '/synthetic/private-note',
      ];
      final base = jsonEncode(browse);
      for (final mutate in mutations) {
        browse = jsonDecode(base) as Map<String, dynamic>;
        mutate(browse);
        final bundle = load();
        expect(bundle.browse, isNull);
        expect(bundle.browseUnavailableReason, 'invalid');
        expect(bundle.variants.length, original.variants.length);
      }
    },
  );
  test('unresolved is explicit and activities do not become muscle roles', () {
    browse['variants'][0]['status'] = 'unresolved';
    browse['variants'][0]['target_groups'] = <String>[];
    browse['variants'][1]['target_groups'] = <String>[];
    browse['variants'][1]['activity_groups'] = ['mobility'];
    final memberships = load().browse!.variants.values.toList();
    expect(memberships[0].status, 'unresolved');
    expect(memberships[1].activityGroups, {'mobility'});
    expect(memberships[1].targetGroups, isEmpty);
  });
  test('malformed optional JSON does not invalidate name catalog', () {
    final bundle = CatalogBundle.fromBytes(
      catalogBytes,
      browseBytes: utf8.encode('{bad json'),
    );
    expect(bundle.browseUnavailableReason, 'invalid');
    expect(bundle.terms, isNotEmpty);
  });
}
