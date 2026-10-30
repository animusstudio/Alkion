import 'dart:convert';

import 'package:alkion/catalog/catalog.dart';
import 'package:flutter_test/flutter_test.dart';

import 'catalog_fixture.dart';

Map<String, Object?> _snapshot(CatalogSearchResult r) {
  List<Object?> hits(List<CatalogHit> values) => [
    for (final h in values)
      [
        h.kind,
        h.id,
        h.key,
        h.tier,
        h.label,
        h.recognizedQuery,
        h.admittedVariantIds,
      ],
  ];
  return {
    'status': r.status,
    'identity': r.identity,
    'strict': hits(r.strict),
    'suggested': hits(r.suggested),
    'secondary': hits(r.secondaryStrict),
    'secondarySuggested': hits(r.secondarySuggested),
    'corrections': r.corrections,
    'unresolved': r.unresolvedTokens,
    'groups': [
      for (final g in r.groupActions) [g.groupKey, g.label, g.kind],
    ],
    'unavailable': r.scopeUnavailableReason,
  };
}

void main() {
  CatalogBundle bundle() =>
      CatalogBundle.fromJsonString(jsonEncode(syntheticCatalog()));

  test(
    'cached and evicted results retain ordered search semantics in every locale',
    () {
      final b = bundle();
      final filters = [
        const CatalogFilter(),
        const CatalogFilter(equipmentKinds: ['dumbbell']),
        CatalogFilter(familyIds: [b.variants.values.first.familyId]),
        const CatalogFilter(
          facets: {
            'grip': ['neutral'],
          },
        ),
        const CatalogFilter(
          excludedFacets: {
            'grip': ['neutral'],
          },
        ),
        const CatalogFilter(groupKey: 'missing', includeSecondary: true),
      ];
      for (final locale in ['en', 'it', 'de', 'es']) {
        final index = CatalogIndex(b, locale: locale);
        for (final filter in filters) {
          for (final query in [
            '',
            'c',
            'cu',
            'curl',
            'curl dumbbell',
            'curl dumbbe',
            'curll',
            'unknown',
            'Curl café',
            'Scott',
          ]) {
            final cold = CatalogIndex(
              b,
              locale: locale,
            ).search(query, filter: filter);
            final first = index.search(query, filter: filter);
            expect(_snapshot(first), _snapshot(cold), reason: '$locale $query');
            expect(index.search(query, filter: filter), same(first));
            // Exercise bounded retention without changing order or admissions.
            for (var n = 0; n < 33; n++) {
              index.search('eviction-$n');
            }
            final after = index.search(query, filter: filter);
            expect(after, isNot(same(first)));
            expect(_snapshot(after), _snapshot(cold));
          }
        }
      }
    },
  );

  test('mutable caller filters are keyed by their current values', () {
    final b = bundle(), equipment = ['dumbbell'];
    final index = CatalogIndex(b);
    final filter = CatalogFilter(equipmentKinds: equipment);
    final dumbbells = index.search('', filter: filter);
    equipment[0] = 'cable';
    final cable = index.search('', filter: filter);
    expect(cable, isNot(same(dumbbells)));
    expect(cable.variantIds, isNot(dumbbells.variantIds));
    expect(
      cable.variantIds.every((id) => b.variants[id]!.equipmentKind == 'cable'),
      isTrue,
    );
    equipment[0] = 'dumbbell';
    expect(index.search('', filter: filter), same(dumbbells));
    final all = index.search('curl');
    final available = index.availableEquipment('curl');
    expect(index.search('curl'), same(all));
    expect(index.availableEquipment('curl', filter: filter), same(available));
    expect(() => available.clear(), throwsUnsupportedError);
  });

  test(
    'result membership is immutable and retains navigation and suggestions',
    () {
      final index = CatalogIndex(bundle());
      final browse = index.search('');
      expect(browse.variantIds, {
        for (final row in browse.rows) ...?row.admittedVariantIds,
      });
      expect(browse.variantIds, same(browse.variantIds));
      expect(browse.rows, same(browse.rows));
      expect(() => browse.variantIds.clear(), throwsUnsupportedError);
      final typo = index.search('curll');
      expect(typo.suggested, isNotEmpty);
      for (final hit in typo.suggested) {
        for (final id in [
          if (hit.variantId != null)
            hit.variantId!
          else
            ...?hit.admittedVariantIds,
        ]) {
          expect(typo.admitsVariant(id, includeSuggestions: true), isTrue);
        }
      }
    },
  );

  test(
    'sort keys retain normalization, displayed text and id ties per vocabulary',
    () {
      final b = bundle(), ids = bundle().variants.keys.take(3).toList();
      final names = ['café', 'Cafe', 'Cafe'];
      CatalogIndex index(String profile, int generation) => CatalogIndex(
        b,
        profileId: profile,
        generation: generation,
        personalAliases: [
          for (var n = 0; n < ids.length; n++)
            CatalogPersonalAlias(
              id: 'alias-$n',
              profileId: 'one',
              locale: 'en',
              text: names[n],
              kind: 'variant',
              targetId: ids[n],
            ),
        ],
      );
      final one = index('one', 1);
      final sorted = List<String>.of(ids)..sort(one.compareVariants);
      expect(sorted, [ids[1], ids[2], ids[0]]);
      final two = index('two', 1), next = index('one', 2);
      expect(two.identity, isNot(one.identity));
      expect(next.identity, isNot(one.identity));
      expect(two.variantLabel(ids.first), isNot('café'));
      expect(one.search('café'), isNot(same(two.search('café'))));
    },
  );
}
