import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:alkion/catalog/catalog.dart';
import 'package:alkion/catalog_ui/catalog_picker.dart';
import 'package:alkion/catalog_ui/catalog_runtime_state.dart';
import 'package:alkion/catalog_ui/catalog_scope.dart';
import 'package:alkion/data/active_session_draft.dart';
import 'package:alkion/data/day_template_repository.dart';
import 'package:alkion/data/exercise_repository.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/data/session_repository.dart';
import 'package:alkion/data/session_writer.dart';
import 'package:alkion/domain/catalog_execution.dart';
import 'package:alkion/l10n/app_localizations.dart';
import 'package:alkion/main.dart';
import 'package:alkion/session/active_session_controller.dart';
import 'package:alkion/session/active_session_screen.dart';
import 'package:alkion/shell/session_launcher.dart';
import 'package:alkion/store/local_store.dart';
import 'package:alkion/ui/day_editor.dart';
import 'package:alkion/ui/day_slot_card.dart';
import 'package:alkion/widgets/plan_form.dart';
import 'package:alkion/widgets/stepper.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import '../catalog/catalog_fixture.dart';
import '../support/app_fonts.dart';
import '../support/screen_harness.dart'
    show RealZoneDatabase, setPhone, settleReal;

const _transition = Duration(milliseconds: 300);

/// A live workout over a real durable runtime: disposable storage, the
/// synthetic catalog and one catalog block with a named machine setup and a
/// running rest timer.
class _DurableWorkout {
  _DurableWorkout._(
    this.runtime,
    this.database,
    this.controller,
    this.original,
    this.exercise,
  );
  AlkionRuntime runtime;
  final RealZoneDatabase database;
  final ActiveSessionController controller;
  final CatalogChoice original;
  final Exercise exercise;

  CatalogRuntimeState get catalog => runtime.catalog!;
  BlockState get block => controller.draft.blocks.first;

  static Future<_DurableWorkout> open(
    WidgetTester tester, {
    String nickname = 'Hotel pulley',
    String? locale,
    Future<void> Function(AlkionRuntime runtime)? history,
  }) async {
    late Directory temporary;
    late AlkionRuntime runtime;
    late RealZoneDatabase database;
    late ActiveSessionController controller;
    late CatalogChoice original;
    late Exercise exercise;
    await tester.runAsync(() async {
      await initializeDateFormatting();
      temporary = await Directory.systemTemp.createTemp('alkion-durable-menu-');
      runtime = await AlkionRuntime.open(
        Directory('${temporary.path}/dev.animusstudio.alkion.dev'),
        catalogBundle: CatalogBundle.fromJsonString(
          jsonEncode(syntheticCatalog()),
        ),
      );
      if (locale != null) {
        await runtime.settings.setLocaleOverride(locale);
        await runtime.settings.flushPersistence();
      }
      database = RealZoneDatabase(runtime.store, Zone.current);
      // Finished workouts from before this one, saved before its draft.
      await history?.call(runtime);
      final drafts = DraftStore.local(database);
      await drafts.load();
      controller = ActiveSessionController(draftStore: drafts)
        ..seedEmpty(name: 'Durable setup workout', focus: '');
      runtime.sessions.register(controller);
      final catalog = runtime.catalog!;
      final variant = catalog.bundle.variants.values.firstWhere(
        (v) => v.equipmentKind == 'machine',
      );
      original = catalog.newSetup(CatalogChoice.variant(variant.id), nickname);
      exercise = await catalog.materialize(
        original,
        ExerciseRepository.local(database),
        locale: 'en',
      );
      await controller.addCatalogBlock(
        exercise,
        catalog.selectionFor(original)!,
        sessionRepo: SessionRepository.local(database),
      );
      controller.startRest(600);
    });
    final workout = _DurableWorkout._(
      runtime,
      database,
      controller,
      original,
      exercise,
    );
    addTearDown(() async {
      // Owed writes were scheduled from the test zone; drain them there.
      var flushed = false;
      unawaited(
        workout.runtime.flushPersistence().whenComplete(() => flushed = true),
      );
      for (var i = 0; i < 100 && !flushed; i++) {
        await settleReal(tester, ticks: 1);
      }
      expect(flushed, isTrue, reason: 'owed writes never drained');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        await workout.runtime.close();
        await temporary.delete(recursive: true);
      });
    });
    await tester.pumpWidget(
      AlkionApp(runtime: runtime, databaseOverride: database),
    );
    await settleReal(tester, ticks: 5);
    unawaited(
      openActiveSession(appNavigatorKey.currentContext!, runtime.sessions),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.byType(ActiveSessionScreen), findsOneWidget);
    return workout;
  }

  AppLocalizations labels(WidgetTester tester) =>
      AppLocalizations.of(tester.element(find.byType(ActiveSessionScreen)));

  Future<void> openBlockMenu(WidgetTester tester) async {
    final menu = find.byKey(ValueKey('block-menu-${exercise.id}'));
    await tester.ensureVisible(menu);
    await tester.pump();
    await tester.tap(menu);
    await tester.pump(_transition);
    await tester.pump(_transition);
  }

  Future<void> openSetup(WidgetTester tester) async {
    await openBlockMenu(tester);
    final action = find.text(labels(tester).catalogChangeSetup);
    await tester.ensureVisible(action);
    await tester.pump(_transition);
    await tester.tap(action);
    await tester.pump(_transition);
    await tester.pump(_transition);
  }

  Future<int> exerciseCount(WidgetTester tester) async {
    late int count;
    await tester.runAsync(() async {
      count = (await ExerciseRepository.local(database).all()).length;
    });
    return count;
  }
}

/// Real-async frames until [done]: durable catalog writes need real time.
Future<void> _settleUntil(
  WidgetTester tester,
  bool Function() done, {
  int maxTicks = 300,
}) async {
  for (var i = 0; i < maxTicks && !done(); i++) {
    await settleReal(tester, ticks: 1);
  }
  expect(done(), isTrue, reason: 'condition not reached in $maxTicks ticks');
}

Future<void> _finishPickerPop(
  WidgetTester tester,
  ModalRoute<dynamic> route,
) async {
  // _pop first rebuilds PopScope and admits Navigator.pop after that frame.
  await tester.pump();
  // Give the newly started reverse ticker its initial timestamp.
  await tester.pump();
  // The pinned SDK interpolation simulation completes strictly after duration.
  await tester.pump(
    route.reverseTransitionDuration + const Duration(microseconds: 1),
  );
  expect(route.animation!.status, AnimationStatus.dismissed);
  await tester.pump();
}

/// Saves a finished workout dated [daysAgo] days back whose working sets in
/// [selection]'s context carry [values] (load, reps), through the real finish
/// path.
Future<void> _finishPast(
  LocalStore store,
  CatalogSelectionEvidence selection,
  List<(String, String)> values, {
  int daysAgo = 3,
}) async {
  const id = 'past-workout';
  final day = DateTime.now().subtract(Duration(days: daysAgo));
  final date =
      '${day.year}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';
  final sets = [
    for (final (load, reps) in values)
      CatalogSetEvidence(
        selection: selection,
        metrics: {
          'reported_load': CatalogMetricEvidence.fromInput(
            load,
            metric: 'reported_load',
            unit: 'kg',
          ),
          'repetitions': CatalogMetricEvidence.fromInput(
            reps,
            metric: 'repetitions',
            unit: 'count',
          ),
        },
      ),
  ];
  final draft = await store.getOptional(
    "SELECT revision FROM local_state WHERE state_kind='draft' AND state_key='active'",
  );
  final revision = await commitWorkflowState(
    store,
    PreparedWorkflowState(
      store,
      {'draftId': id},
      {'draftId': id, 'restStart': null, 'restTotal': 0},
      draft?['revision'] as int? ?? 0,
    ),
  );
  final repo = WorkoutRepository.local(store);
  await repo.commitPrepared(
    repo.prepareFinish(
      write: SessionWrite(
        id: id,
        dateIso: date,
        sets: [
          for (var i = 0; i < sets.length; i++)
            SetWrite(
              id: '$id-set-$i',
              exerciseId: selection.exerciseId,
              setNumber: i + 1,
              weightKg: null,
              reps: 0,
              rir: null,
              isWarmup: false,
              catalog: sets[i],
              blockId: '$id-block',
            ),
        ],
      ),
      baseRevision: 0,
      setBases: {},
      recovery: {
        'draft': {
          'draftId': id,
          'sets': [for (final set in sets) set.toJson()],
        },
      },
      draftRevision: revision,
      draftId: id,
    ),
  );
}

void main() {
  setUpAll(preloadAppFonts);

  testWidgets(
    'block menu "again" repeats the persisted setup without a new definition',
    (tester) async {
      final w = await _DurableWorkout.open(tester);
      final before = await w.exerciseCount(tester);
      await w.openBlockMenu(tester);
      expect(find.textContaining('Hotel pulley'), findsWidgets);
      await tester.tap(find.text(w.labels(tester).catalogAddAgain));
      await _settleUntil(tester, () => w.controller.draft.blocks.length == 2);
      final blocks = w.controller.draft.blocks;
      expect(blocks, hasLength(2));
      expect(blocks.map((b) => b.exercise.id).toSet(), {w.exercise.id});
      expect(
        blocks.last.catalogSelection!.compatibilityKey,
        blocks.first.catalogSelection!.compatibilityKey,
      );
      expect(blocks.last.catalogSelection!.contextLabel, 'Hotel pulley');
      expect(await w.exerciseCount(tester), before);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'block menu "setup" adds exactly one set for a new named machine',
    (tester) async {
      final w = await _DurableWorkout.open(tester);
      final restStart = w.controller.restStart;
      final setIds = [for (final s in w.block.allSets) s.id];
      await w.openSetup(tester);
      final l = w.labels(tester);
      expect(find.textContaining(l.catalogNewSetNotice), findsOneWidget);
      expect(find.textContaining('Hotel pulley'), findsWidgets);
      await tester.ensureVisible(find.text(l.catalogNewMachine));
      await tester.tap(find.text(l.catalogNewMachine));
      await tester.pump(_transition);
      await tester.pump(_transition);
      await tester.enterText(find.byType(TextField).last, 'Station machine');
      await tester.ensureVisible(find.text(l.catalogUpcoming));
      await tester.tap(find.text(l.catalogUpcoming));
      await tester.pump(_transition);
      await _settleUntil(tester, () => w.block.allSets.length > setIds.length);
      final sets = w.block.allSets;
      expect(sets, hasLength(setIds.length + 1));
      expect([for (final s in sets.take(setIds.length)) s.id], setIds);
      final added = sets.last;
      expect(added.done, isFalse);
      expect(added.catalog!.selection.contextLabel, 'Station machine');
      expect(
        added.catalog!.selection.variantId,
        w.block.catalogSelection!.variantId,
      );
      expect(w.controller.restStart, restStart);
      expect(w.controller.restTotal, 600);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'block menu "setup" to a known machine prefills from its last workout',
    (tester) async {
      late CatalogSelectionEvidence station;
      final w = await _DurableWorkout.open(
        tester,
        history: (runtime) async {
          final catalog = runtime.catalog!;
          final variant = catalog.bundle.variants.values.firstWhere(
            (v) => v.equipmentKind == 'machine',
          );
          final choice = catalog.newSetup(
            CatalogChoice.variant(variant.id),
            'Station machine',
          );
          await catalog.materialize(
            choice,
            ExerciseRepository.local(runtime.store),
            locale: 'en',
          );
          station = catalog.selectionFor(choice)!;
          await _finishPast(runtime.store, station, [
            ('32.50', '10'),
            ('35', '8'),
          ]);
        },
      );
      final setIds = [for (final s in w.block.allSets) s.id];
      // The block's own setup has no history: its sets open empty.
      expect(
        w.block.allSets.every(
          (s) => s.catalog!.metrics['reported_load']?.raw != '32.50',
        ),
        isTrue,
      );
      await w.openSetup(tester);
      final known = find.text('Station machine');
      await tester.ensureVisible(known);
      await tester.tap(known);
      await tester.pump(_transition);
      await _settleUntil(tester, () => w.block.allSets.length > setIds.length);
      final added = w.block.allSets.last;
      expect(added.catalog!.selection.contextId, station.contextId);
      // The first set of that context opens as its first set last time,
      // stored text and unit verbatim, and stays untouched.
      expect(added.catalog!.metrics['reported_load']!.raw, '32.50');
      expect(added.catalog!.metrics['reported_load']!.unit, 'kg');
      expect(added.catalog!.metrics['repetitions']!.raw, '10');
      expect(added.catalogTouched, isFalse);
      expect(w.controller.liveSet!.set, same(added));
      final key = station.compatibilityKey;
      expect(w.block.catalogLastSets[key], hasLength(2));
      expect(w.block.lastTop?.weight, 35);
      // The card shows the last top set as one dim line.
      expect(find.text('last 35 kg × 8 · 3d ago'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'setup sheet actions stay reachable at 320dp and 2x with a long nickname',
    (tester) async {
      setPhone(tester, width: 320, height: 640, textScale: 2);
      final w = await _DurableWorkout.open(
        tester,
        locale: 'de',
        nickname: 'Cable station by the hotel window with the high pulley',
      );
      await w.openSetup(tester);
      expect(tester.takeException(), isNull);
      final l = w.labels(tester);
      expect(l.localeName, 'de');
      for (final label in [l.catalogNewMachine, l.catalogChooseExecution]) {
        final action = find.text(label);
        await Scrollable.ensureVisible(tester.element(action), alignment: .5);
        await tester.pump();
        expect(action.hitTestable(), findsOneWidget);
      }
      await tester.tap(find.text(l.catalogChooseExecution));
      await tester.pump(_transition);
      await tester.pump(_transition);
      expect(find.byType(CatalogPicker), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'cancelling the execution choice keeps the live draft and rest timer',
    (tester) async {
      final w = await _DurableWorkout.open(tester);
      final restStart = w.controller.restStart;
      expect(restStart, isNotNull);
      final draft = jsonEncode(w.controller.draft.toJson());
      final count = await w.exerciseCount(tester);
      await w.openSetup(tester);
      await tester.tap(find.text(w.labels(tester).catalogChooseExecution));
      await tester.pump(_transition);
      await tester.pump(_transition);
      final picker = tester.widget<CatalogPicker>(find.byType(CatalogPicker));
      expect(picker.setupIntent, isTrue);
      expect(picker.currentChoice!.variantId, w.original.variantId);
      final route = ModalRoute.of(tester.element(find.byType(CatalogPicker)))!;
      await tester.binding.handlePopRoute();
      await _finishPickerPop(tester, route);
      expect(find.byType(CatalogPicker), findsNothing);
      expect(find.byType(ActiveSessionScreen), findsOneWidget);
      expect(jsonEncode(w.controller.draft.toJson()), draft);
      expect(w.controller.restStart, restStart);
      expect(w.controller.restTotal, 600);
      expect(await w.exerciseCount(tester), count);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('day editor saves catalog slots and reopens them as saved', (
    tester,
  ) async {
    final w = await _DurableWorkout.open(tester);
    await tester.binding.handlePopRoute();
    await tester.pump(_transition);
    late String dayId;
    late CatalogVariant timed;
    await tester.runAsync(() async {
      final catalog = w.runtime.catalog!;
      timed = catalog.bundle.variants.values.firstWhere(
        (v) => v.measurementProfileKey == 'duration_distance_optional',
      );
      final timedChoice = CatalogChoice.variant(timed.id);
      await catalog.materialize(
        timedChoice,
        ExerciseRepository.local(w.database),
        locale: 'en',
      );
      final timedSelection = catalog.selectionFor(timedChoice)!;
      final machineSelection = catalog.selectionFor(w.original)!;
      final days = DayTemplateRepository.local(w.database);
      final intent = days.prepareDay(
        DayDraft(
          name: 'Durable catalog day',
          slots: [
            SlotDraft(
              exerciseId: timedSelection.exerciseId,
              workSets: 1,
              warmupSets: 0,
              catalog: timedSelection,
            ),
            SlotDraft(
              exerciseId: machineSelection.exerciseId,
              workSets: 2,
              warmupSets: 0,
              catalog: machineSelection,
            ),
          ],
        ),
        dependencies: [
          ...catalog.dependenciesFor(timedChoice),
          ...catalog.dependenciesFor(w.original),
        ],
      );
      await days.commitPrepared(intent);
      dayId = intent.action.target.id;
    });

    Future<void> openEditor() async {
      unawaited(
        appNavigatorKey.currentState!.push(
          MaterialPageRoute<void>(
            builder: (routeContext) => Scaffold(
              body: DayEditor(
                id: dayId,
                onBack: () => Navigator.pop(routeContext),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await _settleUntil(
        tester,
        () => find.byType(DaySlotCard).evaluate().length == 2,
      );
      expect(find.byType(DayEditor), findsOneWidget);
    }

    // A loaded day starts collapsed; one card is open at a time.
    Future<void> expand(int index) async {
      final toggle = find
          .byWidgetPredicate(
            (widget) =>
                widget.key is ValueKey<String> &&
                (widget.key! as ValueKey<String>).value.startsWith(
                  'day-slot-expand-',
                ),
          )
          .at(index);
      await tester.ensureVisible(toggle);
      await tester.tap(toggle);
      await _settleUntil(
        tester,
        () => find
            .byKey(const Key('day-slot-working-sets'))
            .evaluate()
            .isNotEmpty,
      );
      // The card finishes opening (and any other finishes folding away).
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
    }

    final working = find.byKey(const Key('day-slot-working-sets'));

    await openEditor();
    final label = w.runtime.catalog!.index('en').variantLabel(timed.id);
    final machine = w.catalog.selectionFor(w.original)!.displayLabel;
    expect(find.text(label), findsWidgets);
    expect(find.text(machine), findsWidgets);
    expect(find.byKey(const Key('metric-duration')), findsNothing);
    await expand(0);
    await tester.ensureVisible(working);
    await tester.tap(
      find.descendant(
        of: working,
        matching: find.byKey(const Key('stepper-inc')),
      ),
    );
    await tester.pump();
    await tester.enterText(
      find.byKey(const Key('metric-duration')),
      '25.000000000000000001',
    );
    await tester.pump();
    final save = find.byWidgetPredicate(
      (widget) => widget is PrimaryBtn && widget.label == 'Save changes',
    );
    await tester.scrollUntilVisible(
      save,
      300,
      scrollable: find
          .descendant(
            of: find.byType(DayEditor),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.tap(save);
    await tester.pump();
    await _settleUntil(tester, () => find.byType(DayEditor).evaluate().isEmpty);

    await openEditor();
    expect(find.text(label), findsWidgets);
    expect(find.text(machine), findsWidgets);
    await expand(0);
    expect(tester.widget<WStepper>(working).value, 2);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('metric-duration')))
          .controller!
          .text,
      '25.000000000000000001',
    );
    await expand(1);
    expect(working, findsOneWidget);
    expect(tester.widget<WStepper>(working).value, 2);
    await tester.runAsync(() async {
      final day = (await DayTemplateRepository.local(w.database).byId(dayId))!;
      expect(day.slots, hasLength(2));
      expect(day.slots.every((slot) => slot.catalog != null), isTrue);
      expect(day.slots.first.workSets, 2);
      expect(
        day.slots.first.catalogTargets['duration']!.raw,
        '25.000000000000000001',
      );
      expect(day.slots.last.catalog!.contextLabel, 'Hotel pulley');
    });
    expect(tester.takeException(), isNull);
  });
}
