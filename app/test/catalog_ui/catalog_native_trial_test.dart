import 'dart:convert';

import 'package:alkion/catalog/catalog.dart';
import 'package:alkion/catalog_ui/catalog_measurement_form.dart';
import 'package:alkion/catalog_ui/catalog_picker.dart';
import 'package:alkion/catalog_ui/catalog_trial_scope.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/ui/day_editor.dart';
import 'package:alkion/ui/plan_screen.dart';
import 'package:alkion/ui/exercise_library_tab.dart';
import 'package:alkion/data/day_template_repository.dart';
import 'package:alkion/data/exercise_repository.dart';
import 'package:alkion/data/session_repository.dart';
import '../support/screen_harness.dart' as real;
import 'package:alkion/l10n/app_localizations.dart';
import 'package:alkion/session/active_session_controller.dart';
import 'package:alkion/session/active_session_screen.dart';
import 'package:alkion/session/session_manager.dart';
import 'package:alkion/session/session_header.dart';
import 'package:alkion/settings/settings_service.dart';
import 'package:alkion/theme/app_theme.dart';
import 'package:alkion/theme/tokens.dart';
import 'package:alkion/units/unit_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../catalog/catalog_fixture.dart';
import '../support/app_fonts.dart';

CatalogTrialState trial() => CatalogTrialState(
  CatalogBundle.fromJsonString(jsonEncode(syntheticCatalog())),
);
Widget app(
  Widget child, {
  Locale locale = const Locale('en'),
  Brightness brightness = Brightness.dark,
}) => MaterialApp(
  theme: buildTheme(brightness, accents[0]),
  locale: locale,
  localizationsDelegates: const [
    AppLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: child),
);

void main() {
  setUpAll(preloadAppFonts);
  testWidgets(
    'two machines and explicit repeat retain one owned identity and exact routine origins',
    (tester) async {
      final h = real.ScreenHarness();
      await h.open(tester, seed: (_) async {});
      addTearDown(h.close);
      final state = trial();
      final machineId = state.bundle.variants.values
          .firstWhere((v) => v.equipmentKind == 'machine')
          .id;
      final choice = CatalogChoice.variant(machineId);
      final a = state.newSetup(choice, 'Hotel machine');
      final b = state.newSetup(choice, 'Station machine');
      final repo = ExerciseRepository.local(h.database);
      final sessions = SessionRepository.local(h.database);
      final controller = ActiveSessionController();
      await tester.runAsync(() async {
        final original = await state.materialize(choice, repo, locale: 'en');
        final setupA = await state.materialize(a, repo, locale: 'en');
        final setupB = await state.materialize(b, repo, locale: 'it');
        expect([setupA.id, setupB.id], [original.id, original.id]);
        expect((await repo.all()).length, 1);
        controller.seedEmpty(name: 'Synthetic', focus: '');
        await controller.addBlock(original, sessionRepo: sessions);
        await controller.addBlock(original, sessionRepo: sessions);
        expect(controller.draft.blocks.length, 1);
        await controller.addBlock(
          original,
          sessionRepo: sessions,
          allowRepeat: true,
        );
        expect(controller.draft.blocks.length, 2);
        expect(controller.draft.blocks.map((b) => b.exercise.id).toSet(), {
          original.id,
        });
        final first = Slot(
          id: 'slot-a',
          exerciseId: original.id,
          position: 1,
          localRevision: 2,
        );
        final second = Slot(
          id: 'slot-b',
          exerciseId: original.id,
          position: 2,
          localRevision: 4,
        );
        await controller.buildFromTemplate(
          DayTemplate(
            id: 'routine',
            name: 'Synthetic routine',
            position: 1,
            slots: [first, second],
          ),
          exerciseRepo: repo,
          sessionRepo: sessions,
        );
        expect(
          controller.originSlotIdFor(controller.draft.blocks[0]),
          'slot-a',
        );
        expect(
          controller.originSlotIdFor(controller.draft.blocks[1]),
          'slot-b',
        );
        expect(
          state.useInRoutine(
            'slot-b',
            b,
            actualSlot: second,
            exerciseId: original.id,
            expectedRevision: 4,
          ),
          isTrue,
        );
        expect(state.routineContexts.keys, ['slot-b']);
        expect(
          state.useInRoutine(
            'slot-b',
            a,
            actualSlot: second,
            exerciseId: original.id,
            expectedRevision: 3,
          ),
          isFalse,
        );
        expect(state.routineContexts['slot-b'], same(b));
        final customA = CatalogChoice.custom('My movement', 'load_reps');
        final customB = CatalogChoice.custom('My movement', 'load_reps');
        expect(
          (await state.materialize(customA, repo, locale: 'en')).id,
          isNot((await state.materialize(customB, repo, locale: 'en')).id),
        );
      });
      await h.unmount(tester);
      controller.dispose();
      state.dispose();
    },
  );

  testWidgets(
    'broad family never selects a variant and exact query stays direct',
    (tester) async {
      final state = trial();
      await tester.pumpWidget(app(CatalogPicker(state: state, multiple: true)));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('catalog-search')), 'curl');
      await tester.pump();
      expect(find.text('Curl'), findsOneWidget);
      expect(find.text('Neutral dumbbell curl'), findsNothing);
      await tester.tap(find.text('Curl'));
      await tester.pump();
      final neutralId = state.bundle.variants.values
          .firstWhere((v) => v.key == 'neutral_curl')
          .id;
      final neutralRow = find.byKey(ValueKey('variant:$neutralId@default'));
      expect(neutralRow, findsOneWidget);
      expect(find.text('Add selected · 0'), findsOneWidget);
      await tester.tap(neutralRow);
      await tester.pump();
      expect(find.text('Add selected · 1'), findsOneWidget);
      // Duplicate tap is idempotent; explicit menu action adds an occurrence.
      await tester.tap(neutralRow);
      await tester.pump();
      expect(find.text('Add selected · 1'), findsOneWidget);
      await tester.tap(find.byTooltip('Details').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add again'));
      await tester.pumpAndSettle();
      expect(find.text('Add selected · 2'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('catalog-search')),
        'Standing barbell shoulder press',
      );
      await tester.pump();
      expect(
        find
            .text('Standing barbell shoulder press', skipOffstage: true)
            .hitTestable(),
        findsWidgets,
      );
      expect(find.text('Add selected · 2'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    },
  );

  testWidgets('custom name keeps query and Back retains picker selection', (
    tester,
  ) async {
    final state = trial();
    await tester.pumpWidget(app(CatalogPicker(state: state, multiple: true)));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('catalog-search')),
      'My travel movement',
    );
    await tester.pump();
    await tester.ensureVisible(find.text('Create custom exercise'));
    await tester.tap(find.text('Create custom exercise'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('catalog-custom-name')))
          .controller!
          .text,
      'My travel movement',
    );
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('catalog-search')))
          .controller!
          .text,
      'My travel movement',
    );
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });

  testWidgets(
    'all eight metric profiles validate independently and retain exact draft across locale',
    (tester) async {
      final state = trial();
      expect(state.bundle.measurementProfiles.length, 8);
      for (final profile in state.bundle.measurementProfiles.values) {
        final values = <String, String>{};
        await tester.pumpWidget(
          app(
            CatalogMeasurementForm(
              key: ValueKey(profile.key),
              profile: profile,
              values: values,
              onChanged: () {},
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(catalogMeasurementsValid(profile, values), isFalse);
        for (final metric in profile.requiredMetrics) {
          await tester.enterText(
            find.byKey(ValueKey('metric-$metric')),
            metric == 'repetitions' ? '7' : '12.50',
          );
        }
        expect(catalogMeasurementsValid(profile, values), isTrue);
        for (final metric in profile.optionalMetrics) {
          expect(values[metric], isNull);
        }
        final exact = Map<String, String>.of(values);
        await tester.pumpWidget(
          app(
            CatalogMeasurementForm(
              key: ValueKey(profile.key),
              profile: profile,
              values: values,
              onChanged: () {},
            ),
            locale: const Locale('it'),
            brightness: Brightness.light,
          ),
        );
        await tester.pumpAndSettle();
        expect(values, exact);
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    },
  );

  for (final language in ['en', 'it', 'de', 'es']) {
    testWidgets('catalog is reachable at 320dp 2x keyboard in $language', (
      tester,
    ) async {
      final state = trial();
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        app(
          MediaQuery(
            data: const MediaQueryData(
              size: Size(320, 640),
              textScaler: TextScaler.linear(2),
              viewInsets: EdgeInsets.only(bottom: 220),
            ),
            child: CatalogPicker(state: state, multiple: true),
          ),
          locale: Locale(language),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('catalog-add-selected')), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('catalog-search')));
      await tester.enterText(find.byKey(const Key('catalog-search')), 'curl');
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    });
  }

  testWidgets(
    'real routine editor saves repeated slots with one owned definition',
    (tester) async {
      final h = real.ScreenHarness();
      await h.open(tester, seed: (_) async {});
      addTearDown(h.close);
      final state = trial();
      bool saved = false;
      await tester.pumpWidget(
        CatalogTrialScope(
          state: state,
          child: h.wrap(
            Scaffold(body: DayEditor(id: null, onBack: () => saved = true)),
          ),
        ),
      );
      await real.settleReal(tester);
      await tester.enterText(
        find.byType(TextField).first,
        'Synthetic travel routine',
      );
      await tester.ensureVisible(find.text('Add exercise'));
      await tester.tap(find.text('Add exercise'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('catalog-search')),
        'Machine curl',
      );
      await tester.pump();
      final row = find.byType(CatalogPickerRow).first;
      await tester.tap(row);
      await tester.pump();
      await tester.tap(find.byTooltip('Details').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add again'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('catalog-add-selected')));
      await real.settleReal(tester);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('Create training day'));
      await real.settleReal(tester, ticks: 2);
      await tester.tap(find.text('Create training day'));
      await real.settleReal(tester);
      expect(saved, isTrue);
      await tester.runAsync(() async {
        final days = await DayTemplateRepository.local(h.database).allDays();
        expect(days.single.slots.length, 2);
        expect(days.single.slots.map((s) => s.id).toSet().length, 2);
        expect(days.single.slots.map((s) => s.exerciseId).toSet().length, 1);
        expect(
          state.routineContexts.keys.toSet().containsAll(
            days.single.slots.map((s) => s.id),
          ),
          isTrue,
        );
      });
      await h.unmount(tester);
      state.dispose();
    },
  );

  testWidgets(
    'routine metric Save reopen Save and guarded Discard preserve exact saved text',
    (tester) async {
      final h = real.ScreenHarness();
      await h.open(tester, seed: (_) async {});
      addTearDown(h.close);
      final state = trial();
      final profile = state.bundle.measurementProfiles.values.firstWhere(
        (p) =>
            p.requiredMetrics.length == 1 &&
            p.requiredMetrics.single == 'duration',
      );
      final choice = CatalogChoice.custom('Synthetic hold', profile.key);
      late DayTemplate day;
      final repo = DayTemplateRepository.local(h.database);
      await tester.runAsync(() async {
        final ex = await state.materialize(
          choice,
          ExerciseRepository.local(h.database),
          locale: 'en',
        );
        await repo.saveDay(
          draft: DayDraft(
            name: 'Synthetic metric routine',
            slots: [
              SlotDraft(
                exerciseId: ex.id,
                workSets: 1,
                warmupSets: 0,
                repLow: 8,
                repHigh: 8,
              ),
            ],
          ),
        );
        day = (await repo.allDays()).single;
      });
      final slotId = day.slots.single.id!;
      state.routineContexts[slotId] = choice;
      final planKey = GlobalKey<PlanScreenState>();
      await tester.pumpWidget(
        CatalogTrialScope(
          state: state,
          child: h.wrap(Scaffold(body: PlanScreen(key: planKey))),
        ),
      );
      await real.settleReal(tester);
      Future<void> open() async {
        await tester.tap(find.text('Synthetic metric routine'));
        await real.settleReal(tester);
      }

      Future<void> save() async {
        await tester.scrollUntilVisible(
          find.text('Save changes'),
          250,
          scrollable: find
              .descendant(
                of: find.byType(DayEditor),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await real.settleReal(tester, ticks: 2);
        await tester.tap(find.text('Save changes'));
        await real.settleReal(tester);
      }

      await open();
      await tester.enterText(
        find.byKey(const ValueKey('metric-duration')),
        '42.50',
      );
      expect(planKey.currentState!.hasUnsavedEdits, isTrue);
      expect(state.routineMetrics[slotId], isNull);
      await save();
      expect(state.routineMetrics[slotId], {'duration': '42.50'});
      await open();
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('metric-duration')))
            .controller!
            .text,
        '42.50',
      );
      expect(planKey.currentState!.hasUnsavedEdits, isFalse);
      await save();
      expect(state.routineMetrics[slotId], {'duration': '42.50'});
      await open();
      await tester.enterText(
        find.byKey(const ValueKey('metric-duration')),
        '99.25',
      );
      expect(planKey.currentState!.hasUnsavedEdits, isTrue);
      final close = planKey.currentState!.requestClose();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Discard'));
      await real.settleReal(tester);
      expect(await close, isTrue);
      expect(state.routineMetrics[slotId], {'duration': '42.50'});
      await open();
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('metric-duration')))
            .controller!
            .text,
        '42.50',
      );
      // A concurrent real routine revision makes this editor's Save fail. Its
      // unpublished targets must not overwrite the previously accepted values.
      await tester.runAsync(() async {
        final latest = (await repo.byId(day.id))!;
        await repo.commitPrepared(
          repo.prepareSetActive(day.id, latest.localRevision!, false),
        );
      });
      await tester.enterText(
        find.byKey(const ValueKey('metric-duration')),
        '55.75',
      );
      await save();
      expect(state.routineMetrics[slotId], {'duration': '42.50'});
      expect(find.byType(DayEditor), findsOneWidget);
      await h.unmount(tester);
      state.dispose();
    },
  );

  testWidgets(
    'custom selected measurement wraps fully at 320dp 2x with Italian IME',
    (tester) async {
      final state = trial();
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      tester.view.viewInsets = FakeViewPadding(bottom: 220);
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(
        app(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => showCatalogPicker(context, state: state),
              child: const Text('Open picker'),
            ),
          ),
          locale: const Locale('it'),
        ),
      );
      await tester.tap(find.text('Open picker'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('catalog-search')),
        'Movimento personale',
      );
      await tester.pump();
      final create = find.text('Crea esercizio personale');
      await tester.scrollUntilVisible(
        create,
        150,
        scrollable: find
            .descendant(
              of: find.byType(CatalogPicker),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      await tester.tap(create);
      await tester.pumpAndSettle();
      final selected = find.text('Carico (kg) + Ripetizioni');
      final selector = find.byType(DropdownButtonFormField<String>);
      expect(selected, findsOneWidget);
      await tester.ensureVisible(selector);
      await tester.pumpAndSettle();
      final textBounds = tester.getRect(selected),
          selectorBounds = tester.getRect(selector);
      expect(textBounds.top, greaterThanOrEqualTo(selectorBounds.top));
      expect(textBounds.bottom, lessThanOrEqualTo(selectorBounds.bottom));
      expect(textBounds.right, lessThanOrEqualTo(selectorBounds.right));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    },
  );

  testWidgets(
    'single picker final action scrolls above Android bottom safe inset',
    (tester) async {
      final state = trial();
      tester.view.physicalSize = const Size(393, 800);
      tester.view.devicePixelRatio = 1;
      tester.view.padding = FakeViewPadding(bottom: 48);
      tester.view.viewPadding = FakeViewPadding(bottom: 48);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPadding);
      addTearDown(tester.view.resetViewPadding);
      await tester.pumpWidget(
        app(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => showCatalogPicker(context, state: state),
              child: const Text('Open picker'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open picker'));
      await tester.pumpAndSettle();
      await tester.drag(find.byType(ListView), const Offset(0, -2000));
      await tester.pumpAndSettle();
      final create = find.widgetWithText(TextButton, 'Create custom exercise');
      expect(tester.getBottomRight(create).dy, lessThanOrEqualTo(752));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    },
  );

  testWidgets(
    'selected equipment remains visible and clearable after narrowing',
    (tester) async {
      final state = trial();
      await tester.pumpWidget(app(CatalogPicker(state: state, multiple: true)));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('catalog-search')), 'curl');
      await tester.pump();
      await tester.tap(find.text('Curl'));
      await tester.pump();
      final machine = find.widgetWithText(FilterChip, 'Machine');
      await tester.tap(machine);
      await tester.pump();
      expect(tester.widget<FilterChip>(machine).selected, isTrue);
      expect(find.widgetWithText(FilterChip, 'Dumbbells'), findsOneWidget);
      final other = state.bundle.variants.values.firstWhere(
        (v) => v.key == 'neutral_curl',
      );
      expect(find.byKey(ValueKey('variant:${other.id}@default')), findsNothing);
      await tester.tap(machine);
      await tester.pump();
      expect(tester.widget<FilterChip>(machine).selected, isFalse);
      expect(
        find.byKey(ValueKey('variant:${other.id}@default')),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    },
  );

  testWidgets(
    'favorites honor qualified query and Change setup movement admission',
    (tester) async {
      final state = trial();
      final machine = state.bundle.variants.values.firstWhere(
        (v) => v.equipmentKind == 'machine',
      );
      final press = state.bundle.variants.values.firstWhere(
        (v) => v.key == 'standing_press',
      );
      final curl = CatalogChoice.variant(machine.id),
          standing = CatalogChoice.variant(press.id);
      final known = state.newSetup(curl, 'Hotel curl');
      state.toggleFavorite(curl);
      state.toggleFavorite(known);
      state.toggleFavorite(standing);
      final customA = CatalogChoice.custom('My café hold', 'load_reps');
      final customB = CatalogChoice.custom('My café hold', 'load_reps');
      state.toggleFavorite(customA);
      state.toggleFavorite(customB);
      await tester.pumpWidget(app(CatalogPicker(state: state, multiple: true)));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilterChip, 'Favorites'));
      await tester.pump();
      await tester.enterText(
        find.byKey(const Key('catalog-search')),
        'Standing barbell shoulder press',
      );
      await tester.pump();
      expect(find.byKey(ValueKey(standing.key)), findsOneWidget);
      expect(find.byKey(ValueKey(curl.key)), findsNothing);
      expect(find.byKey(ValueKey(known.key)), findsNothing);
      await tester.enterText(
        find.byKey(const Key('catalog-search')),
        'MY CAFE HOLD',
      );
      await tester.pump();
      expect(customA.key, isNot(customB.key));
      expect(find.byKey(ValueKey(customA.key)), findsOneWidget);
      expect(find.byKey(ValueKey(customB.key)), findsOneWidget);
      expect(find.byKey(ValueKey(standing.key)), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        app(
          CatalogPicker(
            state: state,
            multiple: true,
            familyId: machine.familyId,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilterChip, 'Favorites'));
      await tester.pump();
      expect(find.byKey(ValueKey(curl.key)), findsOneWidget);
      expect(find.byKey(ValueKey(known.key)), findsOneWidget);
      expect(find.byKey(ValueKey(standing.key)), findsNothing);
      expect(find.byKey(ValueKey(customA.key)), findsNothing);
      expect(find.byKey(ValueKey(customB.key)), findsNothing);
      await tester.enterText(
        find.byKey(const Key('catalog-search')),
        'Standing barbell shoulder press',
      );
      await tester.pump();
      expect(find.byType(CatalogPickerRow), findsNothing);
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    },
  );

  testWidgets(
    'bound familiar labels follow locale on actual library routine and workout routes',
    (tester) async {
      final h = real.ScreenHarness();
      await h.open(tester, seed: (_) async {});
      addTearDown(h.close);
      final state = trial();
      final variant = state.bundle.variants.values.firstWhere(
        (v) => v.key == 'standing_press',
      );
      final choice = CatalogChoice.variant(variant.id);
      state.remember(choice, locale: 'en', query: 'RDL');
      late Exercise ex;
      late DayTemplate day;
      final c = ActiveSessionController();
      await tester.runAsync(() async {
        final repo = ExerciseRepository.local(h.database);
        ex = await state.materialize(choice, repo, locale: 'en');
        final days = DayTemplateRepository.local(h.database);
        await days.saveDay(
          draft: DayDraft(
            name: 'Synthetic labels',
            slots: [
              SlotDraft(
                exerciseId: ex.id,
                workSets: 1,
                warmupSets: 0,
                repLow: 8,
                repHigh: 8,
              ),
            ],
          ),
        );
        day = (await days.allDays()).single;
        await c.buildFromTemplate(
          day,
          exerciseRepo: repo,
          sessionRepo: SessionRepository.local(h.database),
        );
      });
      expect(ex.name, 'RDL');
      for (final route in ['library', 'routine', 'workout']) {
        Widget screen(Locale locale) {
          final child = switch (route) {
            'library' => LibraryTab(onOpenEditor: (_) {}),
            'routine' => DayEditor(id: day.id, onBack: () {}),
            _ => const ActiveSessionScreen(),
          };
          return CatalogTrialScope(
            state: state,
            child: h.wrap(
              Scaffold(body: child),
              locale: locale,
              extra: [
                ChangeNotifierProvider<ActiveSessionController>.value(value: c),
              ],
            ),
          );
        }

        await tester.pumpWidget(screen(const Locale('en')));
        await real.settleReal(tester, ticks: 8);
        expect(find.text('RDL'), findsWidgets, reason: route);
        await tester.pumpWidget(screen(const Locale('it')));
        await real.settleReal(tester, ticks: 5);
        expect(find.text('Lento avanti'), findsWidgets, reason: route);
        expect(find.text('RDL'), findsNothing, reason: route);
        expect(tester.takeException(), isNull);
        await h.unmount(tester);
      }
      state.remember(choice, locale: 'it', query: 'Lento avanti');
      expect(state.label(choice, 'it'), 'Lento avanti');
      expect(state.label(choice, 'en'), 'RDL');
      expect(
        (await tester.runAsync(
          () => ExerciseRepository.local(h.database).byId(ex.id),
        ))!.name,
        'RDL',
      );
      c.dispose();
      state.dispose();
    },
  );

  testWidgets(
    'native setup change preserves logged and pending exact contexts and timer',
    (tester) async {
      final state = trial();
      final variant = state.bundle.variants.values.firstWhere(
        (v) => v.equipmentKind == 'machine',
      );
      final choice = CatalogChoice.variant(variant.id);
      const ex = Exercise(
        id: 'machine',
        name: 'Synthetic machine curl',
        slug: 'machine',
        muscleGroup: '',
        compound: false,
        plateStepKg: 2.5,
        isTemplate: false,
      );
      state.exercises[ex.id] = choice;
      final old = SetState(
        id: 'logged',
        weightKg: 40,
        reps: 8,
        rir: null,
        isWarmup: false,
        done: true,
      );
      final pending = SetState(
        id: 'pending',
        weightKg: 20,
        reps: 8,
        rir: null,
        isWarmup: false,
        done: false,
      );
      final block = BlockState(
        exercise: ex,
        resolved: ResolvedSlot(
          exercise: ex,
          workSets: 2,
          warmupSets: 0,
          repLow: 8,
          repHigh: 8,
          rirLow: null,
          rirHigh: null,
        ),
        warmupSets: [],
        workingSets: [old, pending],
        expanded: true,
      );
      state.loggedMetrics[old.id] = {'reported_load': '40', 'repetitions': '8'};
      state.metricDrafts[pending.id] = {
        'reported_load': '55.50',
        'repetitions': '10',
      };
      final c = ActiveSessionController()
        ..seedForTest(
          SessionDraft(
            templateId: null,
            name: 'Synthetic',
            focus: '',
            startedAt: DateTime.now(),
            blocks: [block],
          ),
        );
      c.startRest(90);
      final rest = c.restStart;
      final manager = SessionManager(),
          settings = SettingsService(),
          units = UnitService();
      Widget screen(Locale locale) => CatalogTrialScope(
        state: state,
        child: MultiProvider(
          providers: [
            ChangeNotifierProvider<ActiveSessionController>.value(value: c),
            ChangeNotifierProvider<SessionManager>.value(value: manager),
            ChangeNotifierProvider<SettingsService>.value(value: settings),
            ChangeNotifierProvider<UnitService>.value(value: units),
          ],
          child: app(const ActiveSessionScreen(), locale: locale),
        ),
      );
      await tester.pumpWidget(screen(const Locale('en')));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byTooltip('Change setup').first);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.ensureVisible(find.text('Change setup'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Change setup'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.ensureVisible(find.text('New machine'));
      await tester.tap(find.text('New machine'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.enterText(find.byType(TextField).last, 'Hotel pulley');
      await tester.tap(find.text('Apply to upcoming sets'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(block.exercise.id, 'machine');
      expect(block.allSets.length, 3);
      final added = block.workingSets.last;
      expect(state.setContexts[old.id]!.key, choice.key);
      expect(state.setContexts[pending.id]!.key, choice.key);
      expect(state.setContexts[added.id]!.key, isNot(choice.key));
      expect(state.metricDrafts[pending.id], {
        'reported_load': '55.50',
        'repetitions': '10',
      });
      expect(state.metricDrafts[added.id], isEmpty);
      expect(state.loggedMetrics[old.id], {
        'reported_load': '40',
        'repetitions': '8',
      });
      expect(c.restStart, rest);
      final header = tester.widget<SessionHeader>(find.byType(SessionHeader));
      expect(header.prCount, 0);
      expect(header.nextLabel, contains('Hotel pulley'));
      expect(header.nextLabel, isNot(contains('20kg')));
      expect(header.nextLabel, isNot(contains('55.50')));
      expect(header.nextLabel, isNot(contains('×')));
      await tester.pumpWidget(screen(const Locale('it')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(state.metricDrafts[pending.id]!['reported_load'], '55.50');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
      manager.dispose();
      settings.dispose();
      units.dispose();
      state.dispose();
    },
  );

  testWidgets(
    'actual workout route logs typed duration with controller rest and no rep fabrication',
    (tester) async {
      final state = trial();
      final profile = state.bundle.measurementProfiles.values.firstWhere(
        (p) =>
            p.requiredMetrics.length == 1 &&
            p.requiredMetrics.single == 'duration',
      );
      final choice = CatalogChoice.custom('Travel hold', profile.key);
      const ex = Exercise(
        id: 'trial-hold',
        name: 'Travel hold',
        slug: 'trial-hold',
        muscleGroup: '',
        compound: false,
        plateStepKg: 2.5,
        isTemplate: false,
      );
      state.exercises[ex.id] = choice;
      final set = SetState(
        id: 'typed-set',
        weightKg: 20,
        reps: 8,
        rir: null,
        isWarmup: false,
        done: false,
      );
      final block = BlockState(
        exercise: ex,
        resolved: ResolvedSlot(
          exercise: ex,
          workSets: 1,
          warmupSets: 0,
          repLow: 8,
          repHigh: 8,
          rirLow: null,
          rirHigh: null,
        ),
        warmupSets: [],
        workingSets: [set],
        expanded: true,
      );
      final c = ActiveSessionController()
        ..seedForTest(
          SessionDraft(
            templateId: null,
            name: 'Synthetic trial',
            focus: '',
            startedAt: DateTime.now(),
            blocks: [block],
          ),
        );
      final manager = SessionManager();
      final settings = SettingsService();
      final units = UnitService();
      await tester.pumpWidget(
        CatalogTrialScope(
          state: state,
          child: MultiProvider(
            providers: [
              ChangeNotifierProvider<ActiveSessionController>.value(value: c),
              ChangeNotifierProvider<SessionManager>.value(value: manager),
              ChangeNotifierProvider<SettingsService>.value(value: settings),
              ChangeNotifierProvider<UnitService>.value(value: units),
            ],
            child: app(const ActiveSessionScreen()),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey('metric-repetitions')), findsNothing);
      await tester.enterText(
        find.byKey(const ValueKey('metric-duration')),
        '30',
      );
      await tester.pump();
      expect(
        tester.widget<SessionHeader>(find.byType(SessionHeader)).nextLabel,
        contains('Duration (seconds): 30'),
      );
      await tester.enterText(
        find.byKey(const ValueKey('metric-duration')),
        '42.50',
      );
      await tester.pump();
      final pendingHeader = tester.widget<SessionHeader>(
        find.byType(SessionHeader),
      );
      expect(pendingHeader.nextLabel, contains('Duration (seconds): 42.50'));
      expect(pendingHeader.nextLabel, isNot(contains('20kg')));
      expect(pendingHeader.nextLabel, isNot(contains('×')));
      expect(pendingHeader.prCount, 0);
      await tester.tap(find.byKey(const Key('catalog-log-set')));
      await tester.pump();
      final loggedHeader = tester.widget<SessionHeader>(
        find.byType(SessionHeader),
      );
      expect(loggedHeader.prCount, 0);
      expect(loggedHeader.nextLabel, isEmpty);
      expect(state.loggedMetrics['typed-set'], {'duration': '42.50'});
      expect(set.done, isTrue);
      expect(
        set.reps,
        8,
      ); // Lifecycle only; duration never masquerades as reps.
      expect(c.restStart, isNotNull);
      await tester.tap(find.byKey(const Key('log-set-bar')));
      await tester.pump();
      expect(
        find.textContaining('This trial keeps measurements in memory'),
        findsOneWidget,
      );
      expect(c.hasSession, isTrue);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
      manager.dispose();
      settings.dispose();
      units.dispose();
      state.dispose();
    },
  );
}
