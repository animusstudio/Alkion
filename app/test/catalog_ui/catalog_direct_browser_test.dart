import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:ui' show SemanticsAction;

import 'package:alkion/catalog/catalog.dart';
import 'package:alkion/catalog_ui/catalog_picker.dart';
import 'package:alkion/catalog_ui/catalog_trial_scope.dart';
import 'package:alkion/data/exercise_repository.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/main.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:alkion/ui/exercise_library_tab.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../catalog/catalog_fixture.dart';
import '../support/app_fonts.dart';
import '../support/layout_expect.dart';
import 'package:alkion/l10n/app_localizations.dart';
import '../support/screen_harness.dart';
import 'catalog_discovery_picker_test.dart'
    show discoveryApp, discoveryState, fixtureId;

Finder browserScroll() => find
    .descendant(
      of: find.byType(CatalogBrowser),
      matching: find.byType(Scrollable),
    )
    .first;
Future<void> showRow(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(
    finder,
    120,
    scrollable: browserScroll(),
    maxScrolls: 500,
  );
  await settleReal(tester, ticks: 4);
}

Future<void> browserTop(WidgetTester tester) async {
  tester.state<ScrollableState>(browserScroll()).position.jumpTo(0);
  await settleReal(tester, ticks: 4);
}

Widget browser(
  CatalogTrialState state, {
  CatalogBrowserController? controller,
  List<Exercise> owned = const [],
  void Function(String)? onEdit,
  Future<void> Function(CatalogChoice)? onCreate,
}) => discoveryApp(
  CatalogBrowser(
    state: state,
    ownedExercises: owned,
    controller: controller,
    onEditOwned: onEdit ?? (_) {},
    onCreateChoice: onCreate ?? (_) async {},
  ),
);

Future<({AlkionRuntime runtime, RealZoneDatabase database})> openDurableBrowser(
  WidgetTester tester,
) async {
  late Directory temporary;
  late AlkionRuntime runtime;
  late RealZoneDatabase database;
  await tester.runAsync(() async {
    await initializeDateFormatting();
    temporary = await Directory.systemTemp.createTemp('alkion-direct-browser-');
    final fixture = discoveryState();
    runtime = await AlkionRuntime.open(
      Directory('${temporary.path}/dev.animusstudio.alkion.dev'),
      catalogBundle: fixture.bundle,
    );
    fixture.dispose();
    database = RealZoneDatabase(runtime.store, Zone.current);
  });
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      await runtime.close();
      await temporary.delete(recursive: true);
    });
  });
  return (runtime: runtime, database: database);
}

CatalogTrialState largeBrowserState() {
  final source = syntheticCatalog();
  for (var i = 200; i < 700; i++) {
    source['families'].add({
      'id': fixtureId(i),
      'key': 'synthetic_$i',
      'names': {'en': 'Synthetic $i'},
    });
    source['variants'].add({
      'id': fixtureId(i + 1000),
      'key': 'synthetic_$i',
      'family_id': fixtureId(i),
      'revision': 1,
      'names': {'en': 'Synthetic $i'},
      'equipment_kind': 'dumbbell',
      'facets': <String, String>{},
      'measurement_profile': 'load_reps',
    });
    source['muscle_profiles'].add({
      'id': 'muscle-$i',
      'variant_id': fixtureId(i + 1000),
      'variant_revision': 1,
      'coverage': 'unknown',
      'relationships': <Map<String, String>>[],
    });
  }
  return CatalogTrialState(CatalogBundle.fromJsonString(jsonEncode(source)));
}

void main() {
  setUpAll(preloadAppFonts);

  testWidgets(
    'direct browser inspects full catalog without creating bindings or recents; favorite refreshes stable index',
    (tester) async {
      final state = discoveryState();
      addTearDown(state.dispose);
      final index = state.index('en');
      await tester.pumpWidget(browser(state));
      expect(find.byKey(const Key('catalog-close')), findsNothing);
      expect(find.text('Browse exercises'), findsNothing);
      final family = find.byKey(
        ValueKey('catalog-navigation-family-${fixtureId(1)}'),
      );
      await showRow(tester, family);
      await tester.tap(family);
      await tester.pumpAndSettle();
      final row = find.byKey(ValueKey('variant:${fixtureId(10)}@default'));
      await showRow(tester, row);
      final before = tester
          .state<ScrollableState>(browserScroll())
          .position
          .pixels;
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(find.text('Load (kg)'), findsOneWidget);
      expect(
        find.text(
          state.bundle.variants[fixtureId(10)]!.muscleCoverage == 'partial'
              ? CatalogLabels('en').partialMuscles
              : CatalogLabels('en').unknownMuscles,
        ),
        findsOneWidget,
      );
      expect(state.exercises, isEmpty);
      expect(state.recents, isEmpty);
      expect(state.choices, isEmpty);
      await tester.ensureVisible(find.text('Favorite / unfavorite'));
      await tester.tap(find.text('Favorite / unfavorite'));
      await tester.pumpAndSettle();
      expect(identical(state.index('en'), index), isTrue);
      expect(state.favorites, {'variant:${fixtureId(10)}@default'});
      expect(
        tester.state<ScrollableState>(browserScroll()).position.pixels,
        before,
      );
      await browserTop(tester);
      await tester.tap(find.byKey(const Key('catalog-back')));
      await tester.pumpAndSettle();
      await browserTop(tester);
      await tester.tap(find.widgetWithText(FilterChip, 'Favorites'));
      await tester.pumpAndSettle();
      await showRow(tester, row);
      expect(row, findsOneWidget);
      expect(state.recents, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'snapshot restores query, family, equipment and scroll and resets on locale/runtime',
    (tester) async {
      final state = discoveryState();
      final controller = CatalogBrowserController();
      addTearDown(state.dispose);
      await tester.pumpWidget(browser(state, controller: controller));
      await tester.enterText(find.byKey(const Key('catalog-search')), 'curl');
      await tester.pumpAndSettle();
      final family = find.byKey(
        ValueKey('catalog-navigation-family-${fixtureId(1)}'),
      );
      await showRow(tester, family);
      await tester.tap(family);
      await tester.pumpAndSettle();
      await browserTop(tester);
      final dumbbell = find.widgetWithText(FilterChip, 'Dumbbells');
      await tester.ensureVisible(dumbbell);
      await tester.tap(dumbbell);
      await tester.pumpAndSettle();
      await tester.drag(browserScroll(), const Offset(0, -150));
      await tester.pumpAndSettle();
      final offset = tester
          .state<ScrollableState>(browserScroll())
          .position
          .pixels;
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(browser(state, controller: controller));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('catalog-search')))
            .controller!
            .text,
        'curl',
      );
      expect(find.byKey(const Key('catalog-back')), findsOneWidget);
      expect(tester.widget<FilterChip>(dumbbell).selected, isTrue);
      expect(
        tester.state<ScrollableState>(browserScroll()).position.pixels,
        closeTo(offset, 1),
      );
      await tester.pumpWidget(
        discoveryApp(
          CatalogBrowser(
            state: state,
            ownedExercises: const [],
            controller: controller,
            onEditOwned: (_) {},
            onCreateChoice: (_) async {},
          ),
          locale: 'it',
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('catalog-search')))
            .controller!
            .text,
        isEmpty,
      );
      expect(find.byKey(const Key('catalog-back')), findsNothing);
      final other = discoveryState();
      addTearDown(other.dispose);
      await tester.enterText(find.byKey(const Key('catalog-search')), 'Panca');
      await tester.pumpAndSettle();
      await tester.pumpWidget(browser(other, controller: controller));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('catalog-search')))
            .controller!
            .text,
        isEmpty,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('full default results build rows lazily', (tester) async {
    final state = largeBrowserState();
    addTearDown(state.dispose);
    await tester.pumpWidget(browser(state));
    expect(find.byType(CatalogPickerRow).evaluate().length, lessThan(30));
    final last = find.byKey(
      ValueKey('catalog-navigation-family-${fixtureId(699)}'),
    );
    await showRow(tester, last);
    expect(last, findsOneWidget);
    final semantics = tester.ensureSemantics();
    final node = tester.getSemantics(
      find
          .descendant(
            of: last,
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is Semantics && widget.properties.button == true,
            ),
          )
          .first,
    );
    expect(node.label, contains('Synthetic 699'));
    expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
    semantics.dispose();
    expect(find.byType(CatalogPickerRow).evaluate().length, lessThan(30));
    expect(state.exercises, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'deep family drilldown restores parent anchor and offset after details and remount',
    (tester) async {
      final state = largeBrowserState();
      final controller = CatalogBrowserController();
      addTearDown(state.dispose);
      await tester.pumpWidget(browser(state, controller: controller));
      final family = find.byKey(
        ValueKey('catalog-navigation-family-${fixtureId(650)}'),
      );
      await showRow(tester, family);
      final parentOffset = tester
          .state<ScrollableState>(browserScroll())
          .position
          .pixels;
      final anchor = tester.getTopLeft(family).dy;
      expect(parentOffset, greaterThan(10000));
      await tester.tap(family);
      await tester.pumpAndSettle();
      final variant = find.byKey(
        ValueKey('variant:${fixtureId(1650)}@default'),
      );
      await showRow(tester, variant);
      await tester.tap(variant);
      await tester.pumpAndSettle();
      Navigator.of(tester.element(find.text('Favorite / unfavorite'))).pop();
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(browser(state, controller: controller));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('catalog-back')));
      await tester.pumpAndSettle();
      expect(
        tester.state<ScrollableState>(browserScroll()).position.pixels,
        closeTo(parentOffset, 1),
      );
      expect(family, findsOneWidget);
      expect(tester.getTopLeft(family).dy, closeTo(anchor, 1));
      expect(state.exercises, isEmpty);
      expect(state.recents, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final width in [320.0, 412.0]) {
    for (final locale in ['en', 'it', 'de', 'es']) {
      for (final brightness in Brightness.values) {
        testWidgets(
          'embedded browse and details ${width}dp 2x $locale ${brightness.name}',
          (tester) async {
            setPhone(tester, width: width, textScale: 2);
            tester.platformDispatcher.accessibilityFeaturesTestValue =
                FakeAccessibilityFeatures.allOn;
            addTearDown(
              tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
            );
            final state = discoveryState();
            addTearDown(state.dispose);
            await tester.pumpWidget(
              discoveryApp(
                CatalogBrowser(
                  state: state,
                  ownedExercises: const [],
                  onEditOwned: (_) {},
                  onCreateChoice: (_) async {},
                ),
                locale: locale,
                brightness: brightness,
              ),
            );
            final family = find.byKey(
              ValueKey('catalog-navigation-family-${fixtureId(1)}'),
            );
            await showRow(tester, family);
            await tester.tap(family);
            await tester.pumpAndSettle();
            final row = find.byKey(
              ValueKey('variant:${fixtureId(10)}@default'),
            );
            await showRow(tester, row);
            final l = AppLocalizations.of(tester.element(row));
            final menu = find.descendant(
              of: row,
              matching: find.byType(IconButton),
            );
            expect(tester.getSize(menu).width, greaterThanOrEqualTo(48));
            expect(tester.getSize(menu).height, greaterThanOrEqualTo(48));
            expectNoSplitWords(tester);
            await tester.tap(row);
            await tester.pumpAndSettle();
            expect(find.text(l.catalogFavorite), findsOneWidget);
            expectNoSplitWords(tester);
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox());
          },
        );
      }
    }
  }

  testWidgets(
    'Plan retains direct browsing between sub-tabs; typed custom duration saves and edit preserves definition',
    (tester) async {
      final fixture = await openDurableBrowser(tester);
      final database = fixture.database;
      final state = fixture.runtime.catalog!;
      await tester.pumpWidget(
        AlkionApp(runtime: fixture.runtime, databaseOverride: database),
      );
      await settleReal(tester, ticks: 8);
      await tester.runAsync(
        () => tester.tap(find.byKey(const ValueKey('destination-3'))),
      );
      await settleReal(tester, ticks: 8);
      await tester.runAsync(() => tester.tap(find.text('Exercises')));
      await settleReal(tester, ticks: 8);
      expect(find.byType(CatalogBrowser), findsOneWidget);
      late List<Map<String, dynamic>> beforeBrowsing;
      await tester.runAsync(() async {
        beforeBrowsing = await database.getAll(
          'SELECT * FROM operations ORDER BY operation_id',
        );
      });
      await tester.ensureVisible(
        find.byKey(const Key('catalog-browse-muscles')),
      );
      await tester.runAsync(
        () => tester.tap(find.byKey(const Key('catalog-browse-muscles'))),
      );
      await settleReal(tester, ticks: 4);
      await tester.ensureVisible(find.text('Biceps'));
      await tester.runAsync(() => tester.tap(find.text('Biceps')));
      await settleReal(tester, ticks: 4);
      final family = find.byKey(
        ValueKey('catalog-navigation-family-${fixtureId(1)}'),
      );
      await showRow(tester, family);
      await tester.runAsync(() => tester.tap(family));
      await settleReal(tester, ticks: 4);
      final variantRow = find.byKey(
        ValueKey('variant:${fixtureId(10)}@default'),
      );
      await showRow(tester, variantRow);
      await tester.runAsync(() => tester.tap(variantRow));
      await settleReal(tester, ticks: 6);
      Navigator.of(tester.element(find.text('Favorite / unfavorite'))).pop();
      await settleReal(tester, ticks: 6);
      await tester.runAsync(() async {
        expect(
          await database.getAll(
            'SELECT * FROM operations ORDER BY operation_id',
          ),
          beforeBrowsing,
        );
        for (final table in [
          'exercises',
          'exercise_catalog_bindings',
          'day_template_items',
          'sets',
        ]) {
          expect(await database.getAll('SELECT * FROM $table'), isEmpty);
        }
      });
      await browserTop(tester);
      await tester.enterText(find.byKey(const Key('catalog-search')), 'curl');
      await tester.showKeyboard(find.byKey(const Key('catalog-search')));
      await settleReal(tester, ticks: 4);
      await tester.binding.handlePopRoute();
      await settleReal(tester, ticks: 4);
      expect(find.byType(CatalogBrowser), findsOneWidget);
      expect(find.byKey(const Key('catalog-family-scope')), findsOneWidget);
      expect(find.byKey(const Key('catalog-group-scope')), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('catalog-search')))
            .focusNode!
            .hasFocus,
        isFalse,
      );
      await tester.binding.handlePopRoute();
      await settleReal(tester, ticks: 4);
      expect(find.byType(CatalogBrowser), findsOneWidget);
      expect(find.byKey(const Key('catalog-family-scope')), findsNothing);
      expect(find.byKey(const Key('catalog-group-scope')), findsOneWidget);
      await tester.binding.handlePopRoute();
      await settleReal(tester, ticks: 4);
      expect(find.byType(CatalogBrowser), findsOneWidget);
      expect(find.byKey(const Key('catalog-group-scope')), findsNothing);
      await tester.binding.handlePopRoute();
      await settleReal(tester, ticks: 4);
      expect(find.byType(CatalogBrowser), findsNothing);
      await tester.runAsync(
        () => tester.tap(find.byKey(const ValueKey('destination-3'))),
      );
      await settleReal(tester, ticks: 4);
      await browserTop(tester);
      await tester.enterText(
        find.byKey(const Key('catalog-search')),
        'Synthetic timed hold',
      );
      await settleReal(tester, ticks: 4);
      await tester.runAsync(() => tester.tap(find.text('Split')));
      await settleReal(tester, ticks: 6);
      await tester.runAsync(() => tester.tap(find.text('Exercises')));
      await settleReal(tester, ticks: 6);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('catalog-search')))
            .controller!
            .text,
        'Synthetic timed hold',
      );
      await tester.runAsync(
        () => tester.tap(find.byKey(const Key('catalog-create'))),
      );
      await settleReal(tester, ticks: 4);
      await tester.runAsync(
        () => tester.tap(find.byType(DropdownButtonFormField<String>)),
      );
      await settleReal(tester, ticks: 6);
      final durationOption = find
          .text('Duration (seconds) · Optional: Load (kg)')
          .last;
      await tester.ensureVisible(durationOption);
      await tester.runAsync(() => tester.tap(durationOption));
      await settleReal(tester, ticks: 6);
      await tester.ensureVisible(
        find.widgetWithText(FilledButton, 'Save exercise'),
      );
      await tester.runAsync(
        () => tester.tap(find.widgetWithText(FilledButton, 'Save exercise')),
      );
      await settleReal(tester, ticks: 12);
      late Exercise saved;
      await tester.runAsync(() async {
        saved = (await ExerciseRepository.local(database).all()).single;
        expect(saved.executionDefinition!.profile.requiredMetrics, [
          'duration',
        ]);
      });
      final choice = state.choiceForOwned(saved);
      await showRow(tester, find.byKey(ValueKey(choice.key)));
      await tester.runAsync(() => tester.tap(find.byKey(ValueKey(choice.key))));
      await settleReal(tester, ticks: 6);
      await tester.ensureVisible(find.text('Edit exercise'));
      await tester.runAsync(() => tester.tap(find.text('Edit exercise')));
      await settleReal(tester, ticks: 8);
      await tester.scrollUntilVisible(
        find.text('Save exercise'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.runAsync(() => tester.tap(find.text('Save exercise')));
      await settleReal(tester, ticks: 12);
      await tester.runAsync(() async {
        final after = await ExerciseRepository.local(database).byId(saved.id);
        expect(
          after!.executionDefinition!.toJson(),
          saved.executionDefinition!.toJson(),
        );
      });
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await settleReal(tester, ticks: 5);
    },
  );

  testWidgets(
    'custom and legacy stay distinct and searchable; mapped catalog owned row is not duplicated',
    (tester) async {
      final fixture = await openDurableBrowser(tester);
      final database = fixture.database;
      final state = fixture.runtime.catalog!;
      late Exercise legacy, custom, catalogOwned;
      await tester.runAsync(() async {
        final repo = ExerciseRepository.local(database);
        final intent = repo.prepareExercise(
          ExerciseDraft(
            name: 'Shared synthetic name',
            muscleGroup: '',
            compound: false,
            plateStepKg: 2.5,
            defaultWarmupSets: 0,
            defaultWorkingSets: 1,
            defaultRepLow: 8,
            defaultRepHigh: 8,
          ),
        );
        await repo.commitPrepared(intent);
        legacy = (await repo.byId(intent.action.target.id))!;
        custom = await state.materialize(
          CatalogChoice.custom(
            'Shared synthetic name',
            'duration_load_optional',
          ),
          repo,
          locale: 'en',
        );
        catalogOwned = await state.materialize(
          CatalogChoice.variant(fixtureId(10)),
          repo,
          locale: 'en',
        );
      });
      final owned = await tester.runAsync(
        () => ExerciseRepository.local(database).all(),
      );
      String? edited;
      await tester.pumpWidget(
        browser(state, owned: owned!, onEdit: (id) => edited = id),
      );
      await tester.enterText(
        find.byKey(const Key('catalog-search')),
        'Shared synthetic',
      );
      await tester.pumpAndSettle();
      final legacyRow = find.byKey(ValueKey(CatalogChoice.owned(legacy).key));
      await showRow(tester, legacyRow);
      expect(find.text('Legacy exercise'), findsOneWidget);
      expect(find.text('Custom exercise'), findsOneWidget);
      await tester.tap(legacyRow);
      expect(edited, legacy.id);
      final customRow = find.byKey(ValueKey(state.choiceForOwned(custom).key));
      await tester.tap(customRow);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Edit exercise'));
      await tester.tap(find.text('Edit exercise'));
      expect(edited, custom.id);
      await browserTop(tester);
      await tester.enterText(
        find.byKey(const Key('catalog-search')),
        'Neutral dumbbell curl',
      );
      await tester.pumpAndSettle();
      await showRow(
        tester,
        find.byKey(ValueKey('variant:${fixtureId(10)}@default')),
      );
      expect(
        find.byKey(ValueKey('variant:${fixtureId(10)}@default')),
        findsOneWidget,
      );
      expect(
        find.byKey(ValueKey(CatalogChoice.owned(catalogOwned).key)),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox());
      await settleReal(tester, ticks: 5);
    },
  );

  testWidgets(
    'modal legacy details never persist unsupported favorite and catalog reopens',
    (tester) async {
      late Directory temporary;
      AlkionRuntime? runtime;
      late CatalogBundle bundle;
      late Exercise legacy;
      await tester.runAsync(() async {
        temporary = await Directory.systemTemp.createTemp(
          'alkion-legacy-browser-',
        );
        final source = discoveryState();
        bundle = source.bundle;
        source.dispose();
        final root = Directory('${temporary.path}/dev.animusstudio.alkion.dev');
        runtime = await AlkionRuntime.open(root, catalogBundle: bundle);
        final repo = ExerciseRepository.local(runtime!.store);
        final intent = repo.prepareExercise(
          ExerciseDraft(
            name: 'Synthetic legacy favorite',
            muscleGroup: '',
            compound: false,
            plateStepKg: 2.5,
            defaultWarmupSets: 0,
            defaultWorkingSets: 1,
            defaultRepLow: 8,
            defaultRepHigh: 8,
          ),
        );
        await repo.commitPrepared(intent);
        legacy = (await repo.byId(intent.action.target.id))!;
        await runtime!.close();
        runtime = await AlkionRuntime.open(root, catalogBundle: bundle);
      });
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() async {
          await runtime?.close();
          await temporary.delete(recursive: true);
        });
      });
      final state = runtime!.catalog!;
      await tester.pumpWidget(
        discoveryApp(CatalogPicker(state: state, multiple: true)),
      );
      await tester.enterText(
        find.byKey(const Key('catalog-search')),
        legacy.name,
      );
      await tester.pumpAndSettle();
      final row = find.byKey(ValueKey(CatalogChoice.owned(legacy).key));
      await tester.scrollUntilVisible(
        row,
        100,
        scrollable: find
            .descendant(
              of: find.byType(CatalogPicker),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.tap(
        find.descendant(of: row, matching: find.byTooltip('Details')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Favorite / unfavorite'), findsNothing);
      Navigator.of(tester.element(find.text('Muscle evidence'))).pop();
      await tester.pumpAndSettle();
      state.toggleFavorite(CatalogChoice.owned(legacy));
      expect(state.favorites, isEmpty);
      final supported = CatalogChoice.variant(fixtureId(10));
      await tester.runAsync(() async {
        state.toggleFavorite(supported);
      });
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        final root = runtime!.supportRoot;
        await state.flushPersistence();
        await runtime!.close();
        runtime = await AlkionRuntime.open(root, catalogBundle: bundle);
        expect(runtime!.catalogUnavailable, isFalse);
        expect(runtime!.catalog, isNotNull);
        expect(runtime!.catalog!.favorites, {supported.key});
        expect(
          runtime!.catalog!.ownedExercises.map((e) => e.id),
          contains(legacy.id),
        );
      });
    },
  );

  testWidgets('without bundle owned library still searches creates and edits', (
    tester,
  ) async {
    final h = ScreenHarness();
    await h.open(tester);
    addTearDown(h.close);
    String? edited;
    var created = false;
    await tester.pumpWidget(
      h.wrap(
        Scaffold(
          body: LibraryTab(
            onOpenEditor: (id) {
              edited = id;
              created = id == null;
            },
          ),
        ),
      ),
    );
    await settleReal(tester, ticks: 8);
    await tester.tap(find.text('New exercise'));
    expect(created, isTrue);
    await tester.enterText(
      find.byKey(const Key('library-search')),
      longExercise,
    );
    await settleReal(tester, ticks: 4);
    await tester.scrollUntilVisible(
      find.text(longExercise).last,
      100,
      scrollable: find
          .descendant(
            of: find.byType(LibraryTab),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.tap(find.text(longExercise).last);
    expect(edited, isNotNull);
    expect(find.text(longExercise2), findsNothing);
    await h.unmount(tester);
  });
}
