import 'dart:convert';

import 'package:alkion/catalog/catalog.dart';
import 'package:flutter_test/flutter_test.dart';

import 'catalog_fixture.dart';

void main() {
  CatalogBundle bundle() =>
      CatalogBundle.fromJsonString(jsonEncode(syntheticCatalog()));
  Set<String> variants(CatalogSearchResult r, {bool suggested = false}) =>
      (suggested ? r.suggested : r.strict)
          .where((h) => h.kind == 'variant')
          .map((h) => h.key)
          .toSet();

  test(
    'indexed composition intersects explicit qualifiers and absent facets fail closed',
    () {
      final i = CatalogIndex(bundle());
      expect(variants(i.search('hammer curl preacher DB')), {
        'preacher_neutral_curl',
      });
      expect(variants(i.search('curl neutral machine')), isEmpty);
      expect(i.search('curl magical').strict, isEmpty);
      expect(i.search('curl magical').suggested, isEmpty);
      expect(i.search('curl unknown words overflow').strict, isEmpty);
      expect(i.search('curl').rows.single.kind, 'family');
      expect(i.search('Hammer curl').rows.single.kind, 'collection');
      expect(
        i.search('hammer curl preacher DB').rows.single.variantId,
        isNotNull,
      );
    },
  );
  test(
    'exact, prefix and visible bounded typo lanes protect literals and digits',
    () {
      final i = CatalogIndex(bundle());
      expect(
        i.search('Standing barbell shoulder press').strict.first.key,
        'standing_press',
      );
      expect(variants(i.search('curl dumbbe')), contains('neutral_curl'));
      final typo = i.search('hamemr curl preacher');
      expect(variants(typo, suggested: true), {'preacher_neutral_curl'});
      expect(typo.corrections, contains('hammer curl preacher'));
      expect(typo.strict, isEmpty);
      expect(i.search('hamemr2 curl').suggested, isEmpty);
      expect(i.search('dbx curl').suggested, isEmpty);
      expect(i.search('x ' * 13).status, 'input_limit');
      expect(i.search('x' * 201).status, 'input_limit');
    },
  );
  test(
    'Latin accents combining forms fullwidth case and punctuation lookup preserve labels',
    () {
      final i = CatalogIndex(bundle());
      expect(
        i.search('ＣＵＲＬ—ＣＡＦＥ́').strict.any((h) => h.kind == 'family'),
        isTrue,
      );
      expect(
        catalogNormalize('Straße ÇURL café e\u0301'),
        'strasse curl cafe e',
      );
      expect(catalogNormalize('Hammer™ curl'), 'hammer curl');
      expect(
        i.labelFor(
          'family',
          bundle().families.values.first.id,
          query: 'curl café',
        ),
        'Curl café',
      );
    },
  );
  test('EN IT DE ES policy separates retrieval and visible naming', () {
    final b = bundle();
    final en = CatalogIndex(b), it = CatalogIndex(b, locale: 'it');
    expect(en.search('Lento avanti').strict, isEmpty);
    expect(it.search('Lento avanti').rows.single.label, 'Lento avanti');
    expect(it.search('RDL').strict.first.label, 'RDL');
    for (final locale in ['de', 'es']) {
      final i = CatalogIndex(b, locale: locale);
      expect(i.search('Lento avanti').strict, isEmpty);
      expect(i.search('Shoulder press').rows.single.label, 'Shoulder press');
      expect(
        i.variantLabel(b.variants.values.first.id),
        'Neutral dumbbell curl',
      );
    }
    expect(
      it.variantLabel(b.variants.values.first.id),
      'Curl con manubri a presa neutra',
    );
  });
  test('available DE and ES names are retrieved and displayed locally', () {
    final source = syntheticCatalog();
    source['variants'][0]['names']['de'] = 'Synthetische Kurzhantelübung';
    source['variants'][0]['names']['es'] = 'Ejercicio sintético con mancuernas';
    final b = CatalogBundle.fromJsonString(jsonEncode(source));
    for (final entry in {
      'de': 'Synthetische Kurzhantelübung',
      'es': 'Ejercicio sintético con mancuernas',
    }.entries) {
      final index = CatalogIndex(b, locale: entry.key);
      expect(index.variantLabel(b.variants.values.first.id), entry.value);
      expect(index.search(entry.value).strict.first.key, 'neutral_curl');
      expect(
        index.search('Neutral dumbbell curl').strict.first.key,
        'neutral_curl',
      );
    }
  });

  test(
    'effective profile and locale vocabulary fence identity and personal labels verbatim',
    () {
      final b = bundle(), id = b.variants.values.first.id;
      final a = CatalogPersonalAlias(
        id: 'a',
        profileId: 'one',
        locale: 'en',
        text: 'My café 💪',
        kind: 'variant',
        targetId: id,
      );
      final foreign = CatalogPersonalAlias(
        id: 'b',
        profileId: 'two',
        locale: 'en',
        text: 'Forbidden word',
        kind: 'variant',
        targetId: id,
      );
      final active = CatalogIndex(
        b,
        profileId: 'one',
        personalAliases: [a, foreign],
      );
      final same = CatalogIndex(b, profileId: 'one', personalAliases: [a]);
      expect(active.identity, same.identity);
      expect(active.variantLabel(id), 'My café 💪');
      expect(active.search('Forbidden word').strict, isEmpty);
      expect(
        CatalogIndex(
          b,
          profileId: 'one',
          locale: 'it',
          personalAliases: [a],
        ).search('My café').strict,
        isEmpty,
      );
      expect(
        CatalogIndex(b, profileId: 'two', personalAliases: [a]).identity,
        isNot(active.identity),
      );
      final changed = syntheticCatalog();
      changed['aliases'][0]['text'] = 'Another familiar name';
      final second = CatalogBundle.fromJsonString(jsonEncode(changed));
      expect(CatalogIndex(second).identity, isNot(CatalogIndex(b).identity));
      expect(
        CatalogIndex(second).search('Hammer curl').identity,
        isNot(CatalogIndex(b).search('Hammer curl').identity),
      );
    },
  );
  test(
    'read-only details preserve all eight profiles and explicit unknown muscle coverage',
    () {
      final b = bundle();
      expect(b.measurementProfiles.length, 8);
      expect(b.measurementProfiles['duration_load_optional']!.requiredMetrics, [
        'duration',
      ]);
      expect(b.measurementProfiles['duration_load_optional']!.optionalMetrics, [
        'reported_load',
      ]);
      expect(b.variants.values.first.muscleCoverage, 'partial');
      expect(b.variants.values.last.muscleCoverage, 'unknown');
      expect(b.variants.values.last.muscleRelationships, isEmpty);
      expect(() => b.variants.clear(), throwsUnsupportedError);
      expect(
        () => b.variants.values.first.facets.clear(),
        throwsUnsupportedError,
      );
      expect(
        () => b.measurementProfiles['load_reps']!.requiredMetrics.clear(),
        throwsUnsupportedError,
      );
    },
  );
  test(
    'malformed newer tampered invalid stable/referential and metric data fail visibly',
    () {
      expect(
        () => CatalogBundle.fromJsonString('{'),
        throwsA(isA<CatalogFormatException>()),
      );
      final json = jsonEncode(syntheticCatalog());
      expect(
        () => CatalogBundle.fromJsonString(json, expectedSha256: '0' * 64),
        throwsA(isA<CatalogFormatException>()),
      );
      expect(
        CatalogBundle.fromJsonString(
          json,
          expectedSha256: bundle().digest,
        ).variants.length,
        13,
      );
      for (final mutate in <void Function(Map<String, dynamic>)>[
        (j) => j['schema_version'] = 2,
        (j) => j['families'][0]['id'] = 'temporary-name',
        (j) => j['variants'][0]['family_id'] = 'missing',
        (j) => j['variants'][0]['measurement_profile'] = 'bogus',
        (j) => j['variants'][0]['facets']['grip'] = 'assumed',
        (j) => j['muscle_profiles'].removeLast(),
        (j) => j['muscle_profiles'][0]['variant_revision'] = 2,
        (j) => j['muscle_profiles'][0]['relationships'][0]['anatomy_node_id'] =
            'missing',
        (j) => j['muscle_profiles'][0]['relationships'].add(
          j['muscle_profiles'][0]['relationships'][0],
        ),
        (j) => j['muscle_profiles'][1]['relationships'].add({
          'anatomy_node_id': 'elbow_flexors',
          'role': 'primary',
        }),
        (j) => j['measurement_profiles'][0]['required_metrics'] = ['duration'],
        (j) => j['aliases'][0]['target']['id'] = 'missing',
        (j) => j['equipment_models'].add({
          'id': 'bogus',
          'verification_status': 'candidate',
        }),
      ]) {
        final j = syntheticCatalog();
        mutate(j);
        expect(
          () => CatalogBundle.fromJsonString(jsonEncode(j)),
          throwsA(isA<CatalogFormatException>()),
        );
      }
    },
  );
  test(
    'localized distinctions use only dimensions needed among current siblings',
    () {
      final b = bundle(), rows = b.variants.values.toList();
      expect(CatalogLabels('it').distinction(rows[0], [rows[0]]), '');
      expect(
        CatalogLabels('en').distinction(rows[0], [rows[0], rows[1]]),
        '',
      ); // Missing support remains unspecified.
      expect(
        CatalogLabels('it').distinction(rows[1], [rows[0], rows[1]]),
        'Panca Scott',
      );
      expect(CatalogLabels('de').equipment('dumbbell'), 'Kurzhanteln');
      expect(CatalogLabels('es').facet('grip', 'neutral'), 'Agarre neutro');
      expect(
        CatalogLabels('it').facet('unknown', 'raw_internal_value'),
        'Configurazione non specificata',
      );
    },
  );
}
