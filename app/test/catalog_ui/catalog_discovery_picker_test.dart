import 'dart:convert';
import 'dart:ui' show Tristate;

import 'package:alkion/catalog/catalog.dart';
import 'package:alkion/catalog_ui/catalog_picker.dart';
import 'package:alkion/catalog_ui/catalog_trial_scope.dart';
import 'package:alkion/l10n/app_localizations.dart';
import 'package:alkion/theme/app_theme.dart';
import 'package:alkion/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import '../catalog/catalog_fixture.dart';
import '../support/app_fonts.dart';

String fixtureId(int n) =>
    '10000000-0000-4000-8000-${n.toString().padLeft(12, '0')}';

/// Authored navigation fixtures. These artificial memberships exercise role
/// partitions; they are not imported candidate IDs or biomechanical evidence.
CatalogTrialState discoveryState({
  bool browse = true,
  bool sharedFamiliar = false,
}) {
  final source = syntheticCatalog();
  if (sharedFamiliar) {
    (source['aliases'] as List).add({
      'id': 'synthetic-seated-familiar-ui',
      'text': 'Lento avanti',
      'locale': 'it',
      'target': {'kind': 'variant', 'id': fixtureId(15)},
    });
  }
  void add(int family, int variant, String key, String name, String equipment) {
    (source['families'] as List).add({
      'id': fixtureId(family),
      'key': key,
      'names': {'en': name, 'it': name},
    });
    (source['muscle_profiles'] as List).add({
      'id': 'muscle-$key',
      'variant_id': fixtureId(variant),
      'variant_revision': 1,
      'coverage': 'unknown',
      'relationships': <Map<String, String>>[],
    });
    (source['variants'] as List).add({
      'id': fixtureId(variant),
      'key': key,
      'family_id': fixtureId(family),
      'revision': 1,
      'names': {'en': name, 'it': name},
      'equipment_kind': equipment,
      'facets': <String, String>{},
      'measurement_profile': 'load_reps',
    });
  }

  add(90, 100, 'synthetic_chest', 'Synthetic chest press', 'dumbbell');
  add(91, 101, 'synthetic_back', 'Synthetic back row', 'cable');
  add(92, 102, 'synthetic_legs', 'Synthetic leg extension', 'machine');
  add(93, 103, 'synthetic_triceps', 'Synthetic triceps press', 'cable');
  final bytes = utf8.encode(jsonEncode(source));
  final original = CatalogBundle.fromBytes(bytes);
  if (!browse) return CatalogTrialState(original);
  final groupNames = <String, List<String>>{
    'chest': ['Chest', 'Petto', 'Brust', 'Pecho'],
    'back': ['Back', 'Schiena', 'Rücken', 'Espalda'],
    'biceps': ['Biceps', 'Bicipiti', 'Bizeps', 'Bíceps'],
    'triceps': ['Triceps', 'Tricipiti', 'Trizeps', 'Tríceps'],
    'shoulders': ['Shoulders', 'Spalle', 'Schultern', 'Hombros'],
    'quads': ['Quadriceps', 'Quadricipiti', 'Quadrizeps', 'Cuádriceps'],
    'conditioning': [
      'Conditioning',
      'Condizionamento',
      'Ausdauer',
      'Acondicionamiento',
    ],
  };
  final targets = <String, String>{
    'neutral_curl': 'biceps',
    'preacher_neutral_curl': 'biceps',
    'preacher_cable_curl': 'biceps',
    'unknown_machine_curl': 'biceps',
    'standing_press': 'shoulders',
    'seated_press': 'shoulders',
    'synthetic_chest': 'chest',
    'synthetic_back': 'back',
    'synthetic_legs': 'quads',
    'synthetic_triceps': 'triceps',
  };
  const fakeDigest =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  final sidecar = {
    'format': 'alkion-catalog-browse',
    'schema_version': 1,
    'classification_revision': 'synthetic-ui.1',
    'source_sha256': fakeDigest,
    'catalog_revision': original.catalogRevision,
    'projection_sha256': original.digest,
    'groups': [
      for (final e in groupNames.entries)
        {
          'key': e.key,
          'kind': e.key == 'conditioning' ? 'activity' : 'muscle',
          'names': {
            for (var i = 0; i < 4; i++) ['en', 'it', 'de', 'es'][i]: e.value[i],
          },
          'synonyms': {
            for (final locale in ['en', 'it', 'de', 'es']) locale: <String>[],
          },
        },
    ],
    'variants': [
      for (final v in original.variants.values)
        {
          'variant_id': v.id,
          'variant_revision': v.revision,
          'status': targets.containsKey(v.key) ? 'reviewed' : 'unresolved',
          'target_groups': targets.containsKey(v.key)
              ? [targets[v.key]]
              : <String>[],
          'secondary_groups':
              [
                'standing_press',
                'seated_press',
                'synthetic_chest',
              ].contains(v.key)
              ? ['triceps']
              : <String>[],
          'activity_groups': <String>[],
        },
    ],
  };
  final text = jsonEncode(sidecar);
  return CatalogTrialState(
    CatalogBundle.fromBytes(
      bytes,
      browseBytes: utf8.encode(text),
      browseSha256: catalogHash(text),
      browseRevision: 'synthetic-ui.1',
      sourceSha256: fakeDigest,
    ),
  );
}

Widget discoveryApp(
  Widget child, {
  String locale = 'en',
  Brightness brightness = Brightness.dark,
}) => MaterialApp(
  theme: buildTheme(brightness, accents[0]),
  locale: Locale(locale),
  supportedLocales: AppLocalizations.supportedLocales,
  localizationsDelegates: const [
    AppLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  home: Scaffold(body: child),
);

Finder choice(String id) => find.byKey(ValueKey('variant:$id@default'));
Finder pickerScroll() => find
    .descendant(
      of: find.byType(CatalogPicker),
      matching: find.byType(Scrollable),
    )
    .first;
Future<void> tapVisible(WidgetTester tester, Finder finder) async {
  await revealTop(tester);
  await tester.scrollUntilVisible(finder, 120, scrollable: pickerScroll());
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> revealTop(WidgetTester tester) async {
  tester.state<ScrollableState>(pickerScroll()).position.jumpTo(0);
  await tester.pumpAndSettle();
}

Future<void> groupQuery(WidgetTester tester, String query, String key) async {
  await revealTop(tester);
  await tester.enterText(find.byKey(const Key('catalog-search')), query);
  await tester.pump();
  await tapVisible(tester, find.byKey(ValueKey('catalog-group-action-$key')));
}

Future<void> openChoice(
  WidgetTester tester,
  CatalogTrialState state,
  String id,
) async {
  if (choice(id).evaluate().isEmpty) {
    final family = state.bundle.variants[id]!.familyId;
    await tapVisible(
      tester,
      find.byKey(ValueKey('catalog-navigation-family-$family')),
    );
  }
  await tapVisible(tester, choice(id));
}

void main() {
  setUpAll(preloadAppFonts);

  testWidgets(
    'actual route builds mixed day with ordered occurrences and direct basket removal',
    (tester) async {
      final state = discoveryState();
      addTearDown(state.dispose);
      List<CatalogChoice>? picked;
      await tester.pumpWidget(
        discoveryApp(
          Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                picked = await showCatalogPicker(
                  context,
                  state: state,
                  multiple: true,
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(tester.testTextInput.isVisible, isFalse);
      await groupQuery(tester, 'Chest', 'chest');
      await openChoice(tester, state, fixtureId(100));
      expect(
        choice(fixtureId(100)),
        findsOneWidget,
      ); // First pick retains family children.
      await groupQuery(tester, 'Back', 'back');
      await openChoice(tester, state, fixtureId(101));
      await groupQuery(tester, 'Biceps', 'biceps');
      await openChoice(tester, state, fixtureId(10));
      await groupQuery(tester, 'Quadriceps', 'quads');
      await openChoice(tester, state, fixtureId(102));
      expect(find.text('Add selected · 4'), findsOneWidget);
      await tester.tap(find.byKey(const Key('catalog-basket-toggle')));
      await tester.pumpAndSettle();
      final names =
          [fixtureId(100), fixtureId(101), fixtureId(10), fixtureId(102)]
              .map(
                (id) => state.identifyingLabel(CatalogChoice.variant(id), 'en'),
              )
              .toList();
      for (var i = 0; i < 4; i++) {
        await tester.scrollUntilVisible(
          find.byKey(ValueKey('catalog-basket-$i')),
          60,
          scrollable: find
              .descendant(
                of: find.byKey(const Key('catalog-basket-list')),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await tester.pumpAndSettle();
        expect(
          find.descendant(
            of: find.byKey(ValueKey('catalog-basket-$i')),
            matching: find.text(names[i]),
          ),
          findsOneWidget,
        );
      }
      tester
          .state<ScrollableState>(
            find
                .descendant(
                  of: find.byKey(const Key('catalog-basket-list')),
                  matching: find.byType(Scrollable),
                )
                .first,
          )
          .position
          .jumpTo(0);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('catalog-basket-remove-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('catalog-add-selected')));
      await tester.pumpAndSettle();
      expect(picked!.map((c) => c.variantId), [
        fixtureId(100),
        fixtureId(10),
        fixtureId(102),
      ]);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'selected tap removes last, Add again repeats, Close keep/discard protects actual modal',
    (tester) async {
      final state = discoveryState();
      addTearDown(state.dispose);
      await tester.pumpWidget(
        discoveryApp(
          Builder(
            builder: (context) => TextButton(
              onPressed: () =>
                  showCatalogPicker(context, state: state, multiple: true),
              child: const Text('Open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await groupQuery(tester, 'Biceps', 'biceps');
      await openChoice(tester, state, fixtureId(10));
      await tester.tap(choice(fixtureId(10)));
      await tester.pumpAndSettle();
      expect(find.text('Add selected · 0'), findsOneWidget);
      await tester.tap(choice(fixtureId(10)));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: choice(fixtureId(10)),
          matching: find.byTooltip('Details'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add again'));
      await tester.pumpAndSettle();
      expect(find.text('Add selected · 2'), findsOneWidget);
      // Barrier and downward swipe cannot bypass the pending-selection decision.
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(find.byType(CatalogPicker), findsOneWidget);
      await tester.drag(
        find.byKey(const Key('catalog-close')),
        const Offset(0, 400),
      );
      await tester.pumpAndSettle();
      expect(find.byType(CatalogPicker), findsOneWidget);
      await tester.tap(find.byKey(const Key('catalog-close')));
      await tester.pumpAndSettle();
      expect(find.text('Discard selected exercises?'), findsOneWidget);
      await tester.tap(find.text('Keep selection'));
      await tester.pumpAndSettle();
      expect(find.text('Add selected · 2'), findsOneWidget);
      await tester.tap(find.byKey(const Key('catalog-back')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('catalog-group-scope')), findsOneWidget);
      expect(find.text('Discard selected exercises?'), findsNothing);
      await tester.tap(find.byKey(const Key('catalog-back')));
      await tester.pumpAndSettle();
      await tapVisible(
        tester,
        find.byKey(const Key('catalog-group-conditioning')),
      );
      expect(find.byKey(const Key('catalog-group-scope')), findsOneWidget);
      expect(find.text('Add selected · 2'), findsOneWidget);
      await tester.tap(find.byKey(const Key('catalog-close')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Discard selection'));
      await tester.pumpAndSettle();
      expect(find.byType(CatalogPicker), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'scope query equipment basket survive All favorites and recents; secondary stays separate',
    (tester) async {
      final state = discoveryState();
      addTearDown(state.dispose);
      final target = CatalogChoice.variant(fixtureId(103)),
          secondary = CatalogChoice.variant(fixtureId(15));
      final personal = CatalogChoice.custom(
        'Personal press',
        'load_reps',
        personalGroups: {'triceps'},
      );
      for (final c in [target, secondary, personal]) {
        state.remember(c);
        state.toggleFavorite(c);
      }
      await tester.pumpWidget(
        discoveryApp(CatalogPicker(state: state, multiple: true)),
      );
      await tester.pumpAndSettle();
      await groupQuery(tester, 'Triceps', 'triceps');
      expect(find.text('Secondary muscles only'), findsNothing);
      await tapVisible(tester, find.byKey(const Key('catalog-secondary')));
      await tapVisible(tester, find.widgetWithText(FilterChip, 'Favorites'));
      await revealTop(tester);
      await tester.enterText(find.byKey(const Key('catalog-search')), 'press');
      await tester.pumpAndSettle();
      await tapVisible(tester, choice(fixtureId(103)));
      expect(find.text('Add selected · 1'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Secondary muscles only'),
        120,
        scrollable: pickerScroll(),
      );
      await tester.pumpAndSettle();
      expect(choice(fixtureId(15)), findsOneWidget);
      expect(find.byKey(ValueKey(personal.key)), findsOneWidget);
      expect(
        tester.getTopLeft(find.byKey(ValueKey(personal.key))).dy,
        lessThan(tester.getTopLeft(find.text('Secondary muscles only')).dy),
      );
      await tapVisible(
        tester,
        find.widgetWithText(FilterChip, 'Recent choices'),
      );
      await tester.scrollUntilVisible(
        find.text('Secondary muscles only'),
        120,
        scrollable: pickerScroll(),
      );
      await tester.pumpAndSettle();
      expect(choice(fixtureId(15)), findsOneWidget);
      await tapVisible(tester, find.byKey(const Key('catalog-all')));
      expect(find.byKey(const Key('catalog-group-scope')), findsOneWidget);
      await revealTop(tester);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('catalog-search')))
            .controller!
            .text,
        'press',
      );
      await tapVisible(tester, find.widgetWithText(FilterChip, 'Cable'));
      await tapVisible(tester, find.widgetWithText(FilterChip, 'Favorites'));
      await tapVisible(tester, find.byKey(const Key('catalog-all')));
      expect(
        tester
            .widget<FilterChip>(find.widgetWithText(FilterChip, 'Cable'))
            .selected,
        isTrue,
      );
      expect(find.byKey(const Key('catalog-group-scope')), findsOneWidget);
      expect(find.text('Add selected · 1'), findsOneWidget);
      expect(
        state
            .index('en')
            .search(
              'press',
              filter: const CatalogFilter(
                groupKey: 'triceps',
                includeSecondary: true,
                equipmentKinds: ['cable'],
              ),
            )
            .admitsVariant(fixtureId(15)),
        isFalse,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('collection typo suggestions cannot escape its selector', (
    tester,
  ) async {
    final state = discoveryState();
    addTearDown(state.dispose);
    await tester.pumpWidget(
      discoveryApp(CatalogPicker(state: state, multiple: true)),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('catalog-search')),
      'Hammer curl',
    );
    await tester.pumpAndSettle();
    final collection = state.bundle.collections.values.first;
    await tapVisible(
      tester,
      find.byKey(ValueKey('catalog-navigation-collection-${collection.id}')),
    );
    await tester.ensureVisible(find.byKey(const Key('catalog-search')));
    await tester.enterText(find.byKey(const Key('catalog-search')), 'precher');
    await tester.pumpAndSettle();
    expect(choice(fixtureId(12)), findsNothing);
    final rows = tester.widgetList<CatalogPickerRow>(
      find.byType(CatalogPickerRow),
    );
    expect(rows.any((r) => r.label == 'Preacher cable curl'), isFalse);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'family-open typo suggestions retain shared familiar-name distinctions',
    (tester) async {
      final state = discoveryState(sharedFamiliar: true);
      addTearDown(state.dispose);
      await tester.pumpWidget(
        discoveryApp(
          CatalogPicker(state: state, multiple: true, familyId: fixtureId(2)),
          locale: 'it',
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('catalog-search')),
        'Lento avnti',
      );
      await tester.pumpAndSettle();
      final result = state
          .index('it')
          .search(
            'Lento avnti',
            filter: CatalogFilter(familyIds: [fixtureId(2)]),
          );
      expect(result.strict, isEmpty);
      expect(result.suggested, isNotEmpty);
      await tester.scrollUntilVisible(
        choice(fixtureId(15)),
        120,
        scrollable: pickerScroll(),
      );
      await tester.pumpAndSettle();
      final standing = tester.widget<CatalogPickerRow>(choice(fixtureId(14)));
      final seated = tester.widget<CatalogPickerRow>(choice(fixtureId(15)));
      expect(standing.label, 'Lento avanti');
      expect(seated.label, 'Lento avanti');
      expect(standing.subtitle, contains('Bilanciere'));
      expect(seated.subtitle, contains('Manubri'));
      expect(standing.subtitle, isNot(seated.subtitle));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('selection semantics announce exact count and in-day state', (
    tester,
  ) async {
    final state = discoveryState();
    addTearDown(state.dispose);
    final selected = CatalogChoice.variant(fixtureId(10));
    state.remember(selected);
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      discoveryApp(
        CatalogPicker(
          state: state,
          multiple: true,
          inDayChoiceKeys: {selected.key},
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tapVisible(tester, choice(fixtureId(10)));
    final semanticWidget = find
        .descendant(of: choice(fixtureId(10)), matching: find.byType(Semantics))
        .first;
    final data = tester.getSemantics(semanticWidget).getSemanticsData();
    expect(data.flagsCollection.isSelected, Tristate.isTrue);
    expect(data.flagsCollection.isButton, isTrue);
    expect(data.value, 'Selected occurrences: 1');
    expect(data.label, contains('In this day'));
    semantics.dispose();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'custom groups start unset and custom form return retains query and pending choices',
    (tester) async {
      final state = discoveryState();
      addTearDown(state.dispose);
      state.remember(CatalogChoice.variant(fixtureId(10)));
      await tester.pumpWidget(
        discoveryApp(CatalogPicker(state: state, multiple: true)),
      );
      await tester.pumpAndSettle();
      await tapVisible(tester, choice(fixtureId(10)));
      await revealTop(tester);
      await tester.enterText(
        find.byKey(const Key('catalog-search')),
        'My travel hold',
      );
      await tester.pumpAndSettle();
      await tapVisible(tester, find.byKey(const Key('catalog-create')));
      expect(find.text('Unclassified'), findsOneWidget);
      await tester.tap(find.byKey(const Key('catalog-custom-groups')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const Key('catalog-custom-group-biceps')),
      );
      await tester.tap(find.byKey(const Key('catalog-custom-group-biceps')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.widgetWithText(FilledButton, 'Add'));
      await tester.tap(find.widgetWithText(FilledButton, 'Add'));
      await tester.pumpAndSettle();
      expect(find.text('Add selected · 2'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('catalog-search')))
            .controller!
            .text,
        'My travel hold',
      );
      final custom = state.choices.values.singleWhere(
        (c) => c.customName == 'My travel hold',
      );
      expect(custom.personalGroups, {'biceps'});
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'missing browse explains fallback; name search and unknown Details still work',
    (tester) async {
      final state = discoveryState(browse: false);
      addTearDown(state.dispose);
      await tester.pumpWidget(
        discoveryApp(CatalogPicker(state: state, multiple: true)),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('catalog-browse-unavailable')),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const Key('catalog-search')),
        'Machine curl',
      );
      await tester.pumpAndSettle();
      await tapVisible(tester, choice(fixtureId(13)));
      await tester.tap(
        find.descendant(
          of: choice(fixtureId(13)),
          matching: find.byTooltip('Details'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Muscle evidence'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Detailed muscle evidence may be incomplete'),
        findsOneWidget,
      );
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(find.text('Add selected · 1'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final locale in ['en', 'it', 'de', 'es']) {
    for (final size in [320.0, 412.0]) {
      for (final scale in [1.0, 2.0]) {
        for (final brightness in [Brightness.dark, Brightness.light]) {
          testWidgets(
            'picker controls and expanded basket ${locale}_${size}_${scale}_${brightness.name}',
            (tester) async {
              final state = discoveryState();
              addTearDown(state.dispose);
              state.remember(CatalogChoice.variant(fixtureId(10)));
              tester.view.physicalSize = Size(size, 640);
              tester.view.devicePixelRatio = 1;
              addTearDown(tester.view.resetPhysicalSize);
              addTearDown(tester.view.resetDevicePixelRatio);
              tester.platformDispatcher.textScaleFactorTestValue = scale;
              addTearDown(
                tester.platformDispatcher.clearTextScaleFactorTestValue,
              );
              await tester.pumpWidget(
                discoveryApp(
                  CatalogPicker(state: state, multiple: true),
                  locale: locale,
                  brightness: brightness,
                ),
              );
              await tester.pumpAndSettle();
              await tapVisible(tester, choice(fixtureId(10)));
              await tester.tap(find.byKey(const Key('catalog-basket-toggle')));
              await tester.pumpAndSettle();
              // Reproduce the constrained IME state without a native device claim.
              tester.view.viewInsets = const FakeViewPadding(bottom: 220);
              addTearDown(tester.view.resetViewInsets);
              await tester.pumpAndSettle();
              expect(
                find.byKey(const Key('catalog-add-selected')),
                findsOneWidget,
              );
              expect(tester.takeException(), isNull);
              final semantics = tester.ensureSemantics();
              expect(find.byKey(const Key('catalog-close')), findsOneWidget);
              expect(
                tester
                    .getSize(find.byKey(const Key('catalog-close')))
                    .shortestSide,
                greaterThanOrEqualTo(48),
              );
              expect(
                tester
                    .getSize(find.byKey(const Key('catalog-basket-remove-0')))
                    .shortestSide,
                greaterThanOrEqualTo(48),
              );
              semantics.dispose();
              await tester.pumpWidget(const SizedBox());
            },
          );
        }
      }
    }
  }
}
