import 'dart:convert';

import 'package:alkion/catalog/catalog.dart';
import 'package:flutter_test/flutter_test.dart';

import 'catalog_fixture.dart';

void main() {
  late List<int> catalogBytes;
  late CatalogBundle original;
  late Map<String, dynamic> browsing;
  const sourceDigest =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  Map<String, dynamic> group(
    String key,
    String kind,
    List<String> names,
    List<String> synonyms,
  ) => {
    'key': key,
    'kind': kind,
    'names': Map.fromIterables(['en', 'it', 'de', 'es'], names),
    'synonyms': Map.fromIterables([
      'en',
      'it',
      'de',
      'es',
    ], synonyms.map((s) => [s])),
  };
  setUp(() {
    catalogBytes = utf8.encode(jsonEncode(syntheticCatalog()));
    original = CatalogBundle.fromBytes(catalogBytes);
    browsing = {
      'format': 'alkion-catalog-browse',
      'schema_version': 1,
      'classification_revision': 'synthetic-index.1',
      'source_sha256': sourceDigest,
      'catalog_revision': original.catalogRevision,
      'projection_sha256': original.digest,
      'groups': [
        group(
          'biceps',
          'muscle',
          ['Biceps', 'Bicipiti', 'Bizeps', 'Bíceps'],
          [
            'Elbow flexors',
            'Flessori del gomito',
            'Armbeuger',
            'Flexores del codo',
          ],
        ),
        group(
          'shoulders',
          'muscle',
          ['Shoulders', 'Spalle', 'Schultern', 'Hombros'],
          ['Delts', 'Deltoidi', 'Deltamuskeln', 'Deltoides'],
        ),
        group(
          'back',
          'muscle',
          ['Back', 'Dorso', 'Rücken', 'Espalda'],
          [
            'Upper back',
            'Schiena',
            'Oberer Rücken',
            'Parte superior de espalda',
          ],
        ),
        group(
          'mobility',
          'activity',
          ['Mobility', 'Mobilità', 'Mobilität', 'Movilidad'],
          ['Stretching', 'Allungamento', 'Dehnen', 'Estiramientos'],
        ),
      ],
      'variants': [
        for (final v in original.variants.values)
          {
            'variant_id': v.id,
            'variant_revision': v.revision,
            'status': 'unresolved',
            'target_groups': <String>[],
            'secondary_groups': <String>[],
            'activity_groups': <String>[],
          },
      ],
    };
    void reviewed(
      int n,
      List<String> targets,
      List<String> secondary, {
      List<String> activity = const [],
    }) {
      final row = browsing['variants'][n];
      row['status'] = 'reviewed';
      row['target_groups'] = targets;
      row['secondary_groups'] = secondary;
      row['activity_groups'] = activity;
    }

    reviewed(0, ['biceps', 'back'], ['shoulders']);
    reviewed(1, ['shoulders'], ['biceps']);
    reviewed(2, ['biceps'], ['shoulders']);
    reviewed(4, ['shoulders'], ['biceps']);
    reviewed(5, [], [], activity: ['mobility']);
  });
  CatalogBundle load({String? digest, String? revision}) {
    final text = jsonEncode(browsing);
    return CatalogBundle.fromBytes(
      catalogBytes,
      browseBytes: utf8.encode(text),
      browseSha256: digest ?? catalogHash(text),
      browseRevision: revision ?? 'synthetic-index.1',
      sourceSha256: sourceDigest,
    );
  }

  Set<String> keys(CatalogIndex index, Iterable<String> ids) =>
      ids.map((id) => index.bundle.variants[id]!.key).toSet();

  test(
    'target default and secondary-only partitions admit role-changing siblings once',
    () {
      final i = CatalogIndex(load());
      const target = CatalogFilter(groupKey: 'biceps');
      final primary = i.search('', filter: target);
      expect(keys(i, primary.variantIds), {
        'neutral_curl',
        'preacher_cable_curl',
      });
      expect(primary.secondaryStrict, isEmpty);
      final both = i.search(
        '',
        filter: target.copyWith(includeSecondary: true),
      );
      expect(keys(i, both.variantIds), {'neutral_curl', 'preacher_cable_curl'});
      expect(keys(i, both.secondaryVariantIds), {
        'preacher_neutral_curl',
        'standing_press',
      });
      expect(both.variantIds.intersection(both.secondaryVariantIds), isEmpty);
      expect(both.rows.single.admittedVariantIds!.length, 2);
      final secondaryCurl = both.secondaryRows.firstWhere(
        (h) => h.key == 'curl',
      );
      expect(
        i
            .variantsFor(
              secondaryCurl,
              filter: target.copyWith(includeSecondary: true),
            )
            .map((v) => v.key),
        ['preacher_neutral_curl'],
      );
      final compound = i.bundle.variants.values.first.id;
      expect(
        i.search('', filter: const CatalogFilter(groupKey: 'back')).variantIds,
        {compound},
      );
    },
  );

  test(
    'query family equipment and facets intersect both partitions without relaxation',
    () {
      final i = CatalogIndex(load());
      final curl = i.bundle.families.values.first.id;
      final filter = CatalogFilter(
        groupKey: 'biceps',
        includeSecondary: true,
        familyIds: [curl],
        equipmentKinds: ['dumbbell'],
      );
      final result = i.search('neutral', filter: filter);
      expect(keys(i, result.variantIds), {'neutral_curl'});
      expect(keys(i, result.secondaryVariantIds), {'preacher_neutral_curl'});
      expect(result.admitsVariant(i.bundle.variants.values.first.id), isTrue);
      expect(i.search('neutral machine', filter: filter).variantIds, isEmpty);
      expect(i.search('unknownword', filter: filter).variantIds, isEmpty);
      final supported = i.search(
        '',
        filter: filter.copyWith(
          facets: const {
            'support': ['preacher_bench'],
          },
        ),
      );
      expect(supported.variantIds, isEmpty);
      expect(keys(i, supported.secondaryVariantIds), {'preacher_neutral_curl'});
      expect(i.availableEquipment('', filter: filter).toSet(), {
        'dumbbell',
        'cable',
      });
      expect(i.availableEquipment('neutral', filter: filter), ['dumbbell']);
      final clearEquipment = filter.copyWith(equipmentKinds: []);
      expect(clearEquipment.groupKey, 'biceps');
      expect(clearEquipment.familyIds, [curl]);
      expect(keys(i, i.search('', filter: clearEquipment).variantIds), {
        'neutral_curl',
        'preacher_cable_curl',
      });
      final clearGroup = filter.copyWith(clearGroup: true);
      expect(clearGroup.groupKey, isNull);
      expect(clearGroup.equipmentKinds, ['dumbbell']);
      expect(clearGroup.familyIds, [curl]);
      expect(keys(i, i.search('', filter: clearGroup).variantIds), {
        'neutral_curl',
        'preacher_neutral_curl',
      });
    },
  );

  test(
    'visible spelling suggestions preserve membership and role partition',
    () {
      final i = CatalogIndex(load());
      const scope = CatalogFilter(groupKey: 'biceps', includeSecondary: true);
      final result = i.search('neutal', filter: scope);
      expect(result.strict, isEmpty);
      expect(keys(i, result.suggested.map((h) => h.id)), {'neutral_curl'});
      expect(keys(i, result.secondarySuggested.map((h) => h.id)), {
        'preacher_neutral_curl',
      });
      expect(result.corrections, contains('neutral'));
      final secondary = result.secondarySuggested.single.id;
      expect(result.admitsVariant(secondary), isFalse);
      expect(result.admitsVariant(secondary, includeSuggestions: true), isTrue);
      expect(
        i
            .search(
              'neutal',
              filter: scope.copyWith(equipmentKinds: ['machine']),
            )
            .secondarySuggested,
        isEmpty,
      );
    },
  );

  test('localized whole-query group actions do not hijack exercise names', () {
    final bundle = load();
    for (final locale in ['en', 'it', 'de', 'es']) {
      final i = CatalogIndex(bundle, locale: locale);
      final group = bundle.browse!.groups['biceps']!;
      for (final query in [
        group.names[locale]!,
        group.synonyms[locale]!.single,
      ]) {
        final result = i.search('  ${query.toUpperCase()}! ');
        expect(result.groupActions.single.groupKey, 'biceps');
        expect(result.groupActions.single.label, group.names[locale]);
        expect(
          result.variantIds,
          CatalogIndex(
            original,
            locale: locale,
          ).search('  ${query.toUpperCase()}! ').variantIds,
        );
        // Group actions coexist with legitimate name matches; they never apply a scope.
      }
      expect(i.groupActions('${group.names[locale]} curl'), isEmpty);
      expect(i.groupActions(group.names[locale]!.substring(0, 2)), isEmpty);
      expect(i.groupActions(''), isEmpty);
      expect(i.search('curl').variantIds, isNotEmpty);
    }
    final i = CatalogIndex(bundle, locale: 'it');
    expect(i.groupActions('Biceps'), isEmpty);
    expect(i.groupActions('MOBILITA').single.kind, 'activity');
  });

  test('activities and unresolved rows remain separate from muscle roles', () {
    final i = CatalogIndex(load());
    final activity = i.search(
      '',
      filter: const CatalogFilter(groupKey: 'mobility', includeSecondary: true),
    );
    expect(keys(i, activity.variantIds), {'seated_press'});
    expect(activity.secondaryRows, isEmpty);
    final unclassified = i.search(
      '',
      filter: const CatalogFilter(groupKey: CatalogFilter.unclassified),
    );
    expect(keys(i, unclassified.variantIds), contains('unknown_machine_curl'));
    expect(keys(i, unclassified.variantIds), isNot(contains('seated_press')));
    final all = i.search('');
    expect(all.variantIds.length, i.bundle.variants.length);
    expect(all.variantIds.containsAll(unclassified.variantIds), isTrue);
  });

  test(
    'favorites recents and explicit personal custom groups use exact intersection',
    () {
      final i = CatalogIndex(load());
      final secondary = i.bundle.variants.values.toList()[1].id;
      expect(
        i.matchesVariant(
          secondary,
          query: 'neutral',
          filter: const CatalogFilter(groupKey: 'biceps'),
        ),
        isFalse,
      );
      expect(
        i.matchesVariant(
          secondary,
          query: 'neutral',
          filter: const CatalogFilter(
            groupKey: 'biceps',
            includeSecondary: true,
          ),
        ),
        isTrue,
      );
      expect(
        i.matchesVariant(
          secondary,
          query: 'neutral',
          filter: const CatalogFilter(
            groupKey: 'biceps',
            includeSecondary: true,
            equipmentKinds: ['cable'],
          ),
        ),
        isFalse,
      );
      expect(i.matchesCustomName('My curl', query: 'curl'), isTrue);
      expect(
        i.matchesCustomName(
          'My curl',
          filter: const CatalogFilter(groupKey: 'biceps'),
        ),
        isFalse,
      );
      expect(
        i.matchesCustomName(
          'My curl',
          filter: const CatalogFilter(groupKey: 'biceps'),
          personalGroups: {'biceps'},
        ),
        isTrue,
      );
      expect(
        i.matchesCustomName(
          'My curl',
          filter: const CatalogFilter(groupKey: CatalogFilter.unclassified),
        ),
        isTrue,
      );
      expect(
        i.matchesCustomName(
          'My curl',
          filter: const CatalogFilter(groupKey: CatalogFilter.unclassified),
          personalGroups: {'biceps'},
        ),
        isFalse,
      );
      expect(
        i.matchesCustomName(
          'My curl',
          filter: const CatalogFilter(equipmentKinds: ['cable']),
          personalGroups: {'biceps'},
        ),
        isFalse,
      );
    },
  );

  test(
    'missing invalid and unsupported scopes fail closed but names stay usable',
    () {
      for (final bundle in [original, load(digest: 'bad')]) {
        final i = CatalogIndex(bundle);
        expect(i.search('curl').variantIds, isNotEmpty);
        const scoped = CatalogFilter(groupKey: 'biceps');
        final result = i.search('curl', filter: scoped);
        expect(result.scopeUnavailableReason, bundle.browseUnavailableReason);
        expect(result.status, 'browse_unavailable');
        expect(result.variantIds, isEmpty);
        expect(result.secondaryVariantIds, isEmpty);
        expect(i.availableEquipment('curl', filter: scoped), isEmpty);
        expect(scoped.matches(bundle.variants.values.first), isFalse);
        expect(i.groupActions('Biceps'), isEmpty);
      }
      final i = CatalogIndex(load());
      const unsupported = CatalogFilter(groupKey: 'unsupported');
      expect(
        i.search('', filter: unsupported).scopeUnavailableReason,
        'unsupported_group',
      );
      expect(i.search('', filter: unsupported).variantIds, isEmpty);
      expect(
        i.matchesCustomName(
          'name',
          filter: unsupported,
          personalGroups: {'unsupported'},
        ),
        isFalse,
      );
      expect(
        unsupported.matches(
          i.bundle.variants.values.first,
          browse: i.bundle.browse,
        ),
        isFalse,
      );
    },
  );

  test(
    'browse digest revision availability and scope fence cache identities',
    () {
      final first = load();
      final a = CatalogIndex(first);
      final missing = CatalogIndex(original);
      final invalid = CatalogIndex(load(digest: 'bad'));
      expect({a.identity, missing.identity, invalid.identity}.length, 3);
      browsing['variants'][0]['secondary_groups'] = <String>[];
      expect(CatalogIndex(load()).identity, isNot(a.identity));
      browsing['classification_revision'] = 'synthetic-index.2';
      expect(
        CatalogIndex(load(revision: 'synthetic-index.2')).identity,
        isNot(a.identity),
      );
      expect(
        a.search('curl').identity,
        isNot(
          a
              .search('curl', filter: const CatalogFilter(groupKey: 'biceps'))
              .identity,
        ),
      );
      expect(
        a
            .search('curl', filter: const CatalogFilter(groupKey: 'biceps'))
            .identity,
        isNot(
          a
              .search(
                'curl',
                filter: const CatalogFilter(
                  groupKey: 'biceps',
                  includeSecondary: true,
                ),
              )
              .identity,
        ),
      );
    },
  );
}
