import 'dart:convert';

import 'package:alkion/catalog/catalog.dart';
import 'package:flutter_test/flutter_test.dart';

import 'catalog_fixture.dart';

void main() {
  CatalogBundle load(Map<String, dynamic> source) =>
      CatalogBundle.fromJsonString(jsonEncode(source));
  Map<String, dynamic> alias(
    String id,
    String text,
    String kind,
    String target, {
    String locale = 'en',
  }) => {
    'id': id,
    'text': text,
    'locale': locale,
    'target': {'kind': kind, 'id': target},
  };

  test('retrieval aliases never turn into incidental execution names', () {
    final source = syntheticCatalog();
    final bundle = load(source);
    final index = CatalogIndex(bundle);
    final v = bundle.variants.values.first;
    final label = index.variantLabel(v.id);
    for (final query in [
      'Hammer curl',
      'Scott curl',
      'Curl café',
      'curl dumbbe',
    ]) {
      expect(index.variantLabel(v.id, query: query), label);
      for (final hit
          in index.search(query).strict.where((h) => !h.isNavigation)) {
        expect(hit.label, index.variantLabel(hit.id));
      }
    }
    expect(index.search('Hammer curl').rows.single.kind, 'collection');
    expect(index.search('Curl café').rows.single.label, 'Curl');
    expect(index.variantLabel(v.id), 'Neutral dumbbell curl');
  });

  test(
    'shared retrieval aliases keep each localized canonical execution name',
    () {
      final source = syntheticCatalog();
      final first = source['variants'][0], supported = source['variants'][1];
      for (final v in [first, supported]) {
        source['aliases'].add(
          alias(
            'familiar-${v['key']}',
            'Curl a martello',
            'variant',
            v['id'],
            locale: 'it',
          ),
        );
      }
      final index = CatalogIndex(load(source), locale: 'it');
      for (final v in [first, supported]) {
        expect(index.variantLabel(v['id']), v['names']['it']);
        expect(index.variantLabel(v['id'], query: 'Scott'), v['names']['it']);
        expect(index.identifyingVariantLabel(v['id']), v['names']['it']);
      }
      final rows = index
          .search('Curl a martello')
          .strict
          .where((h) => h.kind == 'variant');
      expect(rows.length, 2);
      expect(rows.map((h) => h.label).toSet(), {
        first['names']['it'],
        supported['names']['it'],
      });
      final v = index.bundle.variants[supported['id']]!;
      expect(CatalogLabels('it').distinction(v, [v]), '');
    },
  );

  test('acronyms remain retrieval-only in every interface locale', () {
    final source = syntheticCatalog();
    final family = source['families'][0]['id'];
    source['abbreviations'].add(alias('familiar-rdl', 'RDL', 'family', family));
    source['abbreviations'].add(
      alias('unfamiliar-acronym', 'ZZZ', 'family', family),
    );
    final bundle = load(source);
    for (final locale in ['en', 'it', 'de', 'es']) {
      final index = CatalogIndex(bundle, locale: locale);
      final machine = bundle.variants.values.firstWhere(
        (v) => v.equipmentKind == 'machine',
      );
      final canonical = machine.names[locale] ?? machine.names['en'];
      expect(index.variantLabel(machine.id), canonical);
      expect(index.identifyingVariantLabel(machine.id), canonical);
      expect(index.search('RDL').strict.any((h) => h.id == machine.id), isTrue);
      expect(index.variantLabel(machine.id, query: 'ZZZ'), canonical);
    }
  });

  test('equal canonical titles retain standalone execution distinctions', () {
    final source = syntheticCatalog();
    for (final v in source['variants'].take(2)) {
      v['names']['it'] = 'Curl di prova';
    }
    final index = CatalogIndex(load(source), locale: 'it');
    final first = source['variants'][0], supported = source['variants'][1];
    // Missing support is unknown, not an invented unsupported execution.
    expect(index.identifyingVariantLabel(first['id']), 'Curl di prova');
    expect(
      index.identifyingVariantLabel(supported['id']),
      'Curl di prova · Panca Scott',
    );
  });

  test(
    'browse families and admitted children sort by localized displayed names',
    () {
      final bundle = load(syntheticCatalog());
      for (final locale in ['en', 'it', 'de', 'es']) {
        final index = CatalogIndex(bundle, locale: locale);
        final rows = index.search('').rows;
        final labels = rows.map((h) => catalogNormalize(h.label)).toList();
        expect(labels, List.of(labels)..sort(), reason: locale);
        for (final row in rows) {
          final children = index.variantsFor(row);
          final names = children
              .map((v) => catalogNormalize(index.variantLabel(v.id)))
              .toList();
          expect(names, List.of(names)..sort(), reason: '$locale ${row.key}');
        }
      }
      final en = CatalogIndex(bundle), it = CatalogIndex(bundle, locale: 'it');
      expect(en.search('').rows.first.key, 'curl');
      expect(it.search('').rows.first.key, 'running');
    },
  );

  test(
    'equal browse labels break ties deterministically across input ordering',
    () {
      final source = syntheticCatalog();
      for (final family in source['families']) {
        family['names']['en'] = 'Same';
      }
      final forward = CatalogIndex(
        load(source),
      ).search('').rows.map((h) => h.id).toList();
      source['families'] = source['families'].reversed.toList();
      source['variants'] = source['variants'].reversed.toList();
      expect(
        CatalogIndex(load(source)).search('').rows.map((h) => h.id),
        forward,
      );
      expect(forward, List.of(forward)..sort());
    },
  );
}
