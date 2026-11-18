import 'dart:convert';

import 'package:alkion/catalog/catalog.dart';
import 'package:flutter_test/flutter_test.dart';

import 'catalog_fixture.dart';

// Independently authored vocabulary over artificial executions, never corpus
// records. Equipment and neighboring movements deliberately conflict.
Map<String, dynamic> bilingualCatalog() {
  final source = syntheticCatalog();
  final curl = source['families'][0]['id'];
  final cable = source['variants'][2]['id'];
  Map<String, dynamic> term(
    String id,
    String text,
    String locale,
    String kind,
    String target,
  ) => {
    'id': id,
    'text': text,
    'locale': locale,
    'target': {'kind': kind, 'id': target},
  };
  source['aliases'].addAll([
    term('bend-en', 'Forearm bend', 'en', 'family', curl),
    term('bend-it', "Flessione dell'avambraccio", 'it', 'family', curl),
    term('old-en', 'Old pulley curl', 'en', 'variant', cable),
    term('old-it', 'Vecchia flessione al cavo', 'it', 'variant', cable),
  ]);
  for (final entry in {
    'manubri': 'dumbbell',
    'bilanciere': 'barbell',
    'cavo': 'cable',
    'macchina': 'machine',
  }.entries) {
    source['scoped_terms'].add({
      ...term(
        'equipment-${entry.key}',
        entry.key,
        'it',
        'family',
        entry.value == 'barbell' ? source['families'][1]['id'] : curl,
      ),
      'selector': {
        'equipment_kinds': [entry.value],
      },
      'qualifier': true,
    });
  }
  source['scoped_terms'].add({
    ...term('scoped-it', 'Tirata di prova', 'it', 'family', curl),
    'selector': {
      'equipment_kinds': ['cable'],
    },
  });
  return source;
}

void main() {
  CatalogBundle load(Map<String, dynamic> source) =>
      CatalogBundle.fromJsonString(jsonEncode(source));

  test('English and Italian phrases admit identical execution identities', () {
    final source = bilingualCatalog();
    final bundle = load(source);
    final ids = [for (final v in source['variants'] as List) v['id'] as String];
    final probes = <String, Set<String>>{
      'Forearm bend with dumbbell': {ids[0], ids[1]},
      "Flessione dell'avambraccio con manubri": {ids[0], ids[1]},
      'Flessione dell’avambraccio al cavo': {ids[2]},
      'Flessione dell’avambraccio alla macchina': {ids[3]},
      'Forearm bend cable': {ids[2]},
      'Tirata di prova': {ids[2]},
      'Old pulley curl': {ids[2]},
      'Vecchia flessione al cavo': {ids[2]},
      'Distensioni in piedi con bilanciere': {ids[4]},
      'Shoulder press in piedi': {ids[4]},
      'Curl a martello al cavo': {},
      'Flessione dell’avambraccio con bilanciere': {},
      'Shoulder press al cavo': {},
    };
    for (final locale in ['en', 'it', 'de', 'es']) {
      final index = CatalogIndex(bundle, locale: locale);
      for (final probe in probes.entries) {
        final result = index.search(probe.key);
        expect(result.variantIds, probe.value, reason: '$locale ${probe.key}');
        for (final hit in result.strict) {
          expect(
            hit.label,
            index.labelFor(hit.kind, hit.id),
            reason: '$locale ${probe.key}',
          );
        }
      }
      final canonical = bundle.variants[ids[2]]!.names;
      final expected = canonical[locale] ?? canonical['en'];
      for (final query in probes.keys) {
        expect(index.variantLabel(ids[2], query: query), expected);
        expect(index.identifyingVariantLabel(ids[2]), expected);
      }
    }
  });

  test(
    'interface language ranks equally exact aliases without changing titles',
    () {
      final source = bilingualCatalog();
      final first = source['variants'][0], second = source['variants'][1];
      for (final entry in {'en': first, 'it': second}.entries) {
        source['aliases'].add({
          'id': 'shared-${entry.key}',
          'text': 'Shared lookup',
          'locale': entry.key,
          'target': {'kind': 'variant', 'id': entry.value['id']},
        });
      }
      final bundle = load(source);
      for (final entry in {'en': first, 'it': second}.entries) {
        final index = CatalogIndex(bundle, locale: entry.key);
        final hits = index.search('Shared lookup').strict;
        expect(hits.first.id, entry.value['id']);
        expect(hits.first.label, entry.value['names'][entry.key]);
        expect(hits.map((h) => h.id).toSet(), {first['id'], second['id']});
      }
    },
  );

  test(
    'bilingual builtins do not admit hidden or foreign personal vocabulary',
    () {
      final bundle = load(bilingualCatalog());
      final id = bundle.variants.values.first.id;
      CatalogPersonalAlias personal(
        String profile,
        String locale, {
        bool hidden = false,
      }) => CatalogPersonalAlias(
        id: '$profile-$locale-$hidden',
        profileId: profile,
        locale: locale,
        text: '$profile $locale private lookup',
        kind: 'variant',
        targetId: id,
        hidden: hidden,
      );
      final active = personal('active', 'it');
      final index = CatalogIndex(
        bundle,
        profileId: 'active',
        personalAliases: [
          active,
          personal('foreign', 'en'),
          personal('active', 'en', hidden: true),
        ],
      );
      expect(index.variantLabel(id), active.text);
      expect(index.search(active.text).strict, isEmpty);
      expect(index.search('foreign en private lookup').strict, isEmpty);
      expect(index.search('active en private lookup').strict, isEmpty);
      expect(index.search('Flessione dell’avambraccio').strict, isNotEmpty);
      final italian = CatalogIndex(
        bundle,
        locale: 'it',
        profileId: 'active',
        personalAliases: [active],
      );
      expect(italian.search(active.text).variantIds, {id});
      expect(italian.variantLabel(id), active.text);
    },
  );
}
