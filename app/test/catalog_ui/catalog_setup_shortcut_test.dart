import 'dart:convert';

import 'package:alkion/catalog/catalog.dart';
import 'package:alkion/catalog_ui/catalog_picker.dart';
import 'package:alkion/catalog_ui/catalog_trial_scope.dart';
import 'package:alkion/data/exercise_repository.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/l10n/app_localizations.dart';
import 'package:alkion/session/active_session_controller.dart';
import 'package:alkion/session/active_session_screen.dart';
import 'package:alkion/session/session_header.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../catalog/catalog_fixture.dart';
import '../support/screen_harness.dart';

const _transition = Duration(milliseconds: 300);

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

class _Workout {
  _Workout(this.store, this.trial, this.controller, this.block, this.original);
  final ScreenHarness store;
  final CatalogTrialState trial;
  final ActiveSessionController controller;
  final BlockState block;
  final CatalogChoice original;
  SetState get logged => block.workingSets[0];
  SetState get pending => block.workingSets[1];

  static Future<_Workout> open(
    WidgetTester tester, {
    String nickname = 'Hotel pulley',
    Locale locale = const Locale('en'),
  }) async {
    final store = ScreenHarness();
    await store.open(tester, seed: (_) async {});
    addTearDown(store.close);
    final trial = CatalogTrialState(
      CatalogBundle.fromJsonString(jsonEncode(syntheticCatalog())),
    );
    addTearDown(trial.dispose);
    final variant = trial.bundle.variants.values.firstWhere(
      (v) => v.equipmentKind == 'machine',
    );
    final original = trial.newSetup(
      CatalogChoice.variant(variant.id),
      nickname,
    );
    late Exercise exercise;
    await tester.runAsync(() async {
      exercise = await trial.materialize(
        original,
        ExerciseRepository.local(store.database),
        locale: 'en',
      );
    });
    final logged = SetState(
      id: 'logged',
      weightKg: 40,
      reps: 8,
      rir: 2,
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
      exercise: exercise,
      resolved: ResolvedSlot(
        exercise: exercise,
        workSets: 2,
        warmupSets: 0,
        repLow: 8,
        repHigh: 8,
        rirLow: null,
        rirHigh: null,
      ),
      warmupSets: [],
      workingSets: [logged, pending],
      expanded: true,
    );
    trial.blockContexts[block] = original;
    trial.setContexts[logged.id] = original;
    trial.setContexts[pending.id] = original;
    trial.loggedMetrics[logged.id] = {
      'reported_load': '040.00',
      'repetitions': '08',
    };
    trial.metricDrafts[pending.id] = {
      'reported_load': '55.50',
      'repetitions': '10',
    };
    final controller = ActiveSessionController()
      ..seedForTest(
        SessionDraft(
          templateId: null,
          name: 'Synthetic setup trial',
          focus: '',
          startedAt: DateTime.now(),
          blocks: [block],
        ),
      );
    addTearDown(controller.dispose);
    controller.startRest(600);
    await tester.pumpWidget(
      CatalogTrialScope(
        state: trial,
        child: store.wrap(
          const ActiveSessionScreen(),
          locale: locale,
          extra: [
            ChangeNotifierProvider<ActiveSessionController>.value(
              value: controller,
            ),
          ],
        ),
      ),
    );
    await tester.pump(_transition);
    final workout = _Workout(store, trial, controller, block, original);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
    });
    return workout;
  }

  AppLocalizations labels(WidgetTester tester) =>
      AppLocalizations.of(tester.element(find.byType(ActiveSessionScreen)));

  Future<void> openSetup(
    WidgetTester tester, {
    String setId = 'pending',
  }) async {
    final menu = find.descendant(
      of: find.byKey(ValueKey(setId)),
      matching: find.byType(IconButton),
    );
    await Scrollable.ensureVisible(tester.element(menu), alignment: .5);
    await tester.pump();
    await tester.tap(menu);
    await tester.pump(_transition);
    await tester.pump(_transition);
    final action = find.text(labels(tester).catalogChangeSetup);
    await tester.ensureVisible(action);
    await tester.pump(_transition);
    await tester.tap(action);
    await tester.pump(_transition);
    await tester.pump(_transition);
  }

  void expectPreserved(DateTime? restStart) {
    expect(trial.setContexts[logged.id]!.key, original.key);
    expect(trial.setContexts[pending.id]!.key, original.key);
    expect(trial.loggedMetrics[logged.id], {
      'reported_load': '040.00',
      'repetitions': '08',
    });
    expect(trial.metricDrafts[pending.id], {
      'reported_load': '055.500',
      'repetitions': '10',
    });
    expect(
      [logged.weightKg, logged.reps, logged.rir, logged.done],
      [40, 8, 2, true],
    );
    expect(
      [pending.weightKg, pending.reps, pending.rir, pending.done],
      [20, 8, null, false],
    );
    expect(controller.restStart, restStart);
    expect(controller.restTotal, 600);
    expect(trial.routineContexts, isEmpty);
    expect(trial.routineMetrics, isEmpty);
  }

  Future<void> typePendingLoad(WidgetTester tester) async {
    final field = find.descendant(
      of: find.byKey(const ValueKey('pending')),
      matching: find.byKey(const ValueKey('metric-reported_load')),
    );
    await tester.ensureVisible(field);
    await tester.enterText(field, '055.500');
    await tester.pump();
  }
}

void main() {
  testWidgets(
    'execution shortcut opens family variants with current context and preserves prior sets',
    (tester) async {
      final w = await _Workout.open(tester);
      final restStart = w.controller.restStart;
      await w.typePendingLoad(tester);
      await w.openSetup(tester);
      final l = w.labels(tester);
      expect(find.textContaining('Hotel pulley'), findsWidgets);
      expect(
        find.textContaining(w.trial.identifyingLabel(w.original, 'en')),
        findsWidgets,
      );
      expect(find.textContaining(l.catalogNewSetNotice), findsOneWidget);
      await tester.tap(find.text(l.catalogChooseExecution));
      await tester.pump(_transition);
      await tester.pump(_transition);
      final picker = tester.widget<CatalogPicker>(find.byType(CatalogPicker));
      expect(
        picker.familyId,
        w.trial.bundle.variants[w.original.variantId]!.familyId,
      );
      expect(picker.currentChoice!.key, w.original.key);
      expect(picker.setupIntent, isTrue);
      expect(picker.inDayChoiceKeys, {w.original.key});
      // A concrete sibling is available immediately, without a family-row tap.
      final sibling = w.trial.bundle.variants.values.firstWhere(
        (v) => v.key == 'preacher_cable_curl',
      );
      final row = find.byKey(ValueKey(CatalogChoice.variant(sibling.id).key));
      await tester.scrollUntilVisible(
        row,
        200,
        scrollable: find
            .descendant(
              of: find.byType(CatalogPicker),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(
        tester.widget<CatalogPickerRow>(row).label,
        w.trial.index('en').variantLabel(sibling.id),
      );
      final route = ModalRoute.of(tester.element(find.byType(CatalogPicker)))!;
      await tester.tap(row);
      await _finishPickerPop(tester, route);
      expect(find.byType(CatalogPicker), findsNothing);
      expect(w.block.workingSets.length, 3);
      final added = w.block.workingSets.last;
      expect(w.trial.setContexts[added.id]!.variantId, sibling.id);
      expect(w.trial.metricDrafts[added.id], isEmpty);
      expect(added.done, isFalse);
      w.expectPreserved(restStart);
      // Opening an earlier set identifies that set, even after an upcoming change.
      await w.openSetup(tester, setId: 'logged');
      expect(
        find.textContaining(
          'Current: ${w.trial.identifyingLabel(w.original, 'en')}',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('Hotel pulley'), findsWidgets);
      await tester.binding.handlePopRoute();
      await tester.pump(_transition);
      expect(w.block.workingSets.length, 3);
      await tester.runAsync(() async {
        expect(
          (await ExerciseRepository.local(w.store.database).all()).length,
          1,
        );
      });
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'new named machine states the new-set action and adds exactly one empty set',
    (tester) async {
      final w = await _Workout.open(tester);
      final restStart = w.controller.restStart;
      await w.typePendingLoad(tester);
      await w.openSetup(tester);
      final l = w.labels(tester);
      await tester.ensureVisible(find.text(l.catalogNewMachine));
      await tester.tap(find.text(l.catalogNewMachine));
      await tester.pump(_transition);
      await tester.pump(_transition);
      await tester.enterText(find.byType(TextField).last, 'Station machine');
      expect(l.catalogUpcoming, 'Add one new set');
      await tester.ensureVisible(find.text(l.catalogUpcoming));
      await tester.tap(find.text(l.catalogUpcoming));
      await tester.pump(_transition);
      expect(w.block.workingSets.length, 3);
      final added = w.block.workingSets.last;
      final choice = w.trial.setContexts[added.id]!;
      expect(choice.variantId, w.original.variantId);
      expect(choice.nickname, 'Station machine');
      expect(choice.setupId, isNot(w.original.setupId));
      expect(w.trial.metricDrafts[added.id], isEmpty);
      w.expectPreserved(restStart);
      final header = tester.widget<SessionHeader>(find.byType(SessionHeader));
      expect(header.nextLabel, contains('Station machine'));
      expect(header.nextLabel, isNot(contains('055.500')));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'set menu repeat uses the identified earlier context instead of the upcoming execution',
    (tester) async {
      final w = await _Workout.open(tester);
      final sibling = w.trial.bundle.variants.values.firstWhere(
        (v) => v.key == 'preacher_cable_curl',
      );
      w.trial.upcomingContexts[w.block] = CatalogChoice.variant(sibling.id);
      final menu = find.descendant(
        of: find.byKey(const ValueKey('logged')),
        matching: find.byType(IconButton),
      );
      await tester.ensureVisible(menu);
      await tester.tap(menu);
      await tester.pump(_transition);
      await tester.pump(_transition);
      expect(find.textContaining('Hotel pulley'), findsWidgets);
      await tester.tap(find.text(w.labels(tester).catalogAddAgain));
      await settleReal(tester);
      expect(w.controller.draft.blocks.length, 2);
      expect(
        w.trial.blockContexts[w.controller.draft.blocks.last]!.key,
        w.original.key,
      );
      expect(w.block.workingSets.length, 2);
      expect(w.trial.routineContexts, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'workout Add can repeat a catalog context without duplicating its owned definition',
    (tester) async {
      final w = await _Workout.open(tester);
      final stale = w.trial.bundle.variants.values.firstWhere(
        (v) => v.key == 'preacher_cable_curl',
      );
      w.trial.setContexts['removed-set'] = CatalogChoice.variant(stale.id);
      final add = find.text(w.labels(tester).sessionAddExercise);
      await tester.scrollUntilVisible(
        add,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(add);
      await settleReal(tester);
      final picker = tester.widget<CatalogPicker>(find.byType(CatalogPicker));
      expect(picker.inDayChoiceKeys, {w.original.key});
      final row = find.byKey(ValueKey(w.original.key));
      await tester.scrollUntilVisible(
        row,
        200,
        scrollable: find
            .descendant(
              of: find.byType(CatalogPicker),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(
        tester.widget<CatalogPickerRow>(row).label,
        w.trial.label(w.original, 'en'),
      );
      await tester.tap(row);
      await settleReal(tester);
      expect(w.controller.draft.blocks.length, 2);
      expect(w.controller.draft.blocks.map((b) => b.exercise.id).toSet(), {
        w.block.exercise.id,
      });
      expect(
        w.trial.blockContexts[w.controller.draft.blocks.last]!.key,
        w.original.key,
      );
      await tester.runAsync(() async {
        expect(
          (await ExerciseRepository.local(w.store.database).all()).length,
          1,
        );
      });
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'ordinary workout Add still excludes an exercise already in the session',
    (tester) async {
      final w = await _Workout.open(tester);
      await tester.pumpWidget(
        w.store.wrap(
          const ActiveSessionScreen(),
          extra: [
            ChangeNotifierProvider<ActiveSessionController>.value(
              value: w.controller,
            ),
          ],
        ),
      );
      await tester.pump(_transition);
      final add = find.text(w.labels(tester).sessionAddExercise);
      await tester.scrollUntilVisible(
        add,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(add);
      await settleReal(tester);
      expect(find.byType(CatalogPicker), findsNothing);
      expect(
        find.descendant(
          of: find.byType(BottomSheet),
          matching: find.text(w.block.exercise.name),
        ),
        findsNothing,
      );
      expect(w.controller.draft.blocks.length, 1);
      await tester.binding.handlePopRoute();
      await tester.pump(_transition);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'setup submenu actions stay reachable at 320dp and 2x with a long current nickname',
    (tester) async {
      setPhone(tester, width: 320, height: 640, textScale: 2);
      final w = await _Workout.open(
        tester,
        locale: const Locale('de'),
        nickname: 'Cable station by the hotel window with the high pulley',
      );
      await w.openSetup(tester);
      expect(tester.takeException(), isNull);
      final action = find.text(w.labels(tester).catalogChooseExecution);
      await Scrollable.ensureVisible(tester.element(action), alignment: .5);
      await tester.pump();
      expect(action.hitTestable(), findsOneWidget);
      await tester.tap(action);
      await tester.pump(_transition);
      await tester.pump(_transition);
      expect(find.byType(CatalogPicker), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'cancelling execution choice leaves the live draft and timer intact',
    (tester) async {
      final w = await _Workout.open(tester);
      final restStart = w.controller.restStart;
      await w.typePendingLoad(tester);
      await w.openSetup(tester);
      await tester.tap(find.text(w.labels(tester).catalogChooseExecution));
      await tester.pump(_transition);
      await tester.pump(_transition);
      expect(tester.view.viewInsets.bottom, 0);
      final route = ModalRoute.of(tester.element(find.byType(CatalogPicker)))!;
      await tester.binding.handlePopRoute();
      await _finishPickerPop(tester, route);
      expect(find.byType(CatalogPicker), findsNothing);
      expect(w.block.workingSets.length, 2);
      expect(w.trial.upcomingContexts[w.block], isNull);
      w.expectPreserved(restStart);
      expect(tester.takeException(), isNull);
    },
  );
}
