import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/data/day_template_repository.dart';
import 'package:alkion/data/exercise_repository.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/domain/evidence.dart';
import 'package:alkion/domain/local_action.dart';
import 'package:alkion/settings/settings_service.dart';
import 'package:alkion/ui/day_editor.dart';
import 'package:alkion/ui/editor_guard.dart';
import 'package:alkion/ui/plan_screen.dart';
import 'package:alkion/ui/split_tab.dart' show SplitTab, DayStatusActions;
import '../alkion/domains/local_screen_harness.dart';
import '../alkion/domains/prepared_intent_retry_test.dart' show FaultDatabase;
import 'training_prescriptions_test.dart' show tap, input;

void main() {
  for (final remove in [false, true]) {
    testWidgets(
      'retained weekday9 stays unavailable through unrelated save then ${remove ? 'removal' : 'repair'}',
      (tester) async {
        final h = ScreenHarness();
        addTearDown(h.close);
        await h.open(
          tester,
          seed: (store) async {
            await seedLong(store);
            await store.writeTransaction((tx) async {
              final ref = LocalRef(
                store.profileId,
                RecordKind.trainingDay,
                'weekday9',
              );
              final fields = <String, Object?>{
                'name': 'Retained weekday',
                'position': 3,
                'scheduled_weekday': 9,
                'is_active': 1,
              };
              final revision = await tx.writeRevision(
                ref,
                localBytes(fields),
                layer: 'sourceSelection',
              );
              await tx.putRecord(ref, revision, fields);
            });
          },
        );
        setPhone(tester, width: 320, textScale: 2);
        await tester.pumpWidget(
          h.wrap(
            Scaffold(
              body: DayEditor(id: 'weekday9', onBack: () {}),
            ),
          ),
        );
        await settleReal(tester);
        expect(find.text('Weekday unavailable'), findsOneWidget);
        expect(find.text('Wed'), findsNothing);
        await tester.enterText(input('Day name'), 'Unrelated name edit');
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await settleReal(tester);
        await tap(tester, find.byType(DayEditor), 'Save changes');
        final retained = (await tester.runAsync(
          () => DayTemplateRepository.local(h.database).byId('weekday9'),
        ))!;
        expect(retained.name, 'Unrelated name edit');
        expect(retained.scheduledWeekday, 9);
        expect(retained.rawFields['scheduled_weekday'], 9);
        await h.unmount(tester);
        final guard = EditorGuard();
        await tester.pumpWidget(
          h.wrap(
            Scaffold(
              body: DayEditor(id: 'weekday9', guard: guard, onBack: () {}),
            ),
          ),
        );
        await settleReal(tester);
        await tap(tester, find.byType(DayEditor), 'Change weekday');
        expect(guard.isDirty(), isFalse);
        expect(
          tester
              .widgetList<Semantics>(find.byType(Semantics))
              .where((s) => s.properties.selected == true),
          isEmpty,
        );
        if (remove) {
          await tester.binding.handlePopRoute();
          await settleReal(tester);
          await tap(tester, find.byType(DayEditor), 'Remove weekday');
        } else {
          await tester.tap(find.text('Tue'));
          await settleReal(tester);
        }
        expect(guard.isDirty(), isTrue);
        await tap(tester, find.byType(DayEditor), 'Save changes');
        final repaired = (await tester.runAsync(
          () => DayTemplateRepository.local(h.database).byId('weekday9'),
        ))!;
        expect(repaired.scheduledWeekday, remove ? null : 1);
        expect(tester.takeException(), isNull);
        await h.unmount(tester);
      },
    );
  }

  for (final initial in RirControls.values) {
    testWidgets(
      'captured ${initial.name} discloses optional RIR for new no-target slots without numeric defaults',
      (tester) async {
        final h = ScreenHarness();
        addTearDown(h.close);
        await h.open(tester);
        setPhone(tester, width: 412);
        await tester.runAsync(() async {
          await h.settings.setRirControls(initial);
          await ExerciseRepository.local(h.database).createExercise(
            ExerciseDraft(
              name: 'Plain',
              muscleGroup: 'chest',
              compound: false,
              plateStepKg: 2.5,
            ),
          );
        });
        await tester.pumpWidget(
          h.wrap(Scaffold(body: DayEditor(id: null, onBack: () {}))),
        );
        await settleReal(tester);
        await tester.runAsync(
          () => h.settings.setRirControls(
            initial == RirControls.off ? RirControls.show : RirControls.off,
          ),
        );
        await tap(tester, find.byType(DayEditor), 'Add exercise');
        await tester.tap(find.text('Plain'));
        await settleReal(tester);
        await tap(tester, find.byType(DayEditor), 'Plain');
        final slot = tester.widget<DaySlotRow>(find.byType(DaySlotRow)).slot;
        expect(slot.showRirAdd, initial == RirControls.show);
        expect(
          slot.draft.rirPolicy,
          initial == RirControls.show ? RirPolicy.inherit : RirPolicy.off,
        );
        expect(slot.draft.rirLow, isNull);
        expect(slot.draft.rirHigh, isNull);
        expect(
          find.text('Add RIR target'),
          initial == RirControls.show ? findsOneWidget : findsNothing,
        );
        if (initial == RirControls.off) {
          await tap(tester, find.byType(DayEditor), 'More options');
          expect(slot.draft.rirLow, isNull);
          expect(slot.draft.rirHigh, isNull);
        }
        await tap(tester, find.byType(DayEditor), 'Add RIR target');
        expect(slot.draft.rirPolicy, RirPolicy.target);
        expect((slot.draft.rirLow, slot.draft.rirHigh), (1, 1));
        expect(find.text('RIR LOW'), findsOneWidget);
        await h.unmount(tester);
      },
    );
  }

  for (final editor in [false, true]) {
    testWidgets(
      'failed Disable retains exact intent across ${editor ? 'editor' : 'subtab'} navigation',
      (tester) async {
        final h = ScreenHarness();
        addTearDown(h.close);
        await h.open(tester);
        setPhone(tester, width: 412);
        final fault = FaultDatabase(h.database, beforeCommit: true);
        h.overrideDatabase = fault;
        await tester.pumpWidget(h.wrap(const Scaffold(body: PlanScreen())));
        await settleReal(tester);
        await tester.tap(find.byIcon(Icons.more_horiz).first);
        await settleReal(tester);
        await tester.tap(find.text('Disable'));
        await settleReal(tester, ticks: 12);
        expect(find.text("Couldn't save"), findsOneWidget);
        expect(find.text('Disabled $longDay'), findsNothing);
        await tester.tap(find.text('OK'));
        await settleReal(tester);
        if (editor) {
          await tester.tap(find.text(longDay));
          await settleReal(tester);
          expect(find.byType(DayEditor), findsOneWidget);
          expect(find.byType(SplitTab), findsNothing);
          await tester
              .state<PlanScreenState>(find.byType(PlanScreen))
              .requestClose();
          await settleReal(tester);
        } else {
          await tester.tap(find.text('Exercises'));
          await settleReal(tester);
          expect(find.byType(SplitTab), findsNothing);
          await tester.tap(find.text('Split'));
          await settleReal(tester);
        }
        await tester.tap(find.byIcon(Icons.more_horiz).first);
        await settleReal(tester);
        expect(find.text('Retry'), findsOneWidget);
        await tester.tap(find.text('Retry'));
        await settleReal(tester, ticks: 12);
        expect(fault.actions.length, 2);
        expect(fault.actions[1].operationId, fault.actions[0].operationId);
        expect(fault.actions[1].bytes, fault.actions[0].bytes);
        final operationRows = (await tester.runAsync(
          () => h.database.getAll(
            'SELECT * FROM operations WHERE operation_id=?',
            [fault.actions[0].operationId],
          ),
        ))!;
        expect(operationRows, hasLength(1));
        final day = (await tester.runAsync(
          () => DayTemplateRepository.local(h.database).byId('d1'),
        ))!;
        expect(day.active, false);
        expect(day.slots, hasLength(4));
        expect(tester.takeException(), isNull);
        await h.unmount(tester);
      },
    );
  }

  testWidgets(
    'definitively rejected status retry retires only after conflict and needs a new explicit action',
    (tester) async {
      final h = ScreenHarness();
      addTearDown(h.close);
      await h.open(tester);
      setPhone(tester, width: 412);
      final original = (await tester.runAsync(
        () => DayTemplateRepository.local(h.database).byId('d1'),
      ))!;
      final fault = FaultDatabase(h.database, beforeCommit: true);
      h.overrideDatabase = fault;
      await tester.pumpWidget(h.wrap(const Scaffold(body: PlanScreen())));
      await settleReal(tester);
      final owner = tester
          .widget<SplitTab>(find.byType(SplitTab))
          .statusActions!;
      await tester.tap(find.byIcon(Icons.more_horiz).first);
      await settleReal(tester);
      await tester.tap(find.text('Disable'));
      await settleReal(tester, ticks: 12);
      expect(owner.hasPending('d1'), isTrue);
      final first = fault.actions.single;
      await tester.tap(find.text('OK'));
      await settleReal(tester);
      await tester.tap(find.text(longDay));
      await settleReal(tester);
      await tester.enterText(input('Day name'), 'Retained renamed day');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await settleReal(tester, ticks: 3);
      await tap(tester, find.byType(DayEditor), 'Save changes');
      await settleReal(tester, ticks: 12);
      final edited = (await tester.runAsync(
        () => DayTemplateRepository.local(h.database).byId('d1'),
      ))!;
      expect(edited.name, 'Retained renamed day');
      expect(edited.localRevision, greaterThan(original.localRevision!));
      expect(edited.active, true);
      expect(owner.hasPending('d1'), isTrue);
      await tester.tap(find.byIcon(Icons.more_horiz).first);
      await settleReal(tester);
      await tester.tap(find.text('Retry'));
      await settleReal(tester, ticks: 8);
      expect(find.textContaining('revision_conflict'), findsOneWidget);
      expect(owner.hasPending('d1'), isFalse);
      final rejected = fault.actions
          .where((a) => a.action == LocalActionKind.planSetActive)
          .toList();
      expect(rejected, hasLength(2));
      expect(rejected[1].operationId, first.operationId);
      expect(rejected[1].bytes, first.bytes);
      final attempts = fault.actions.length;
      expect(
        (await tester.runAsync(
          () => h.database.getAll(
            'SELECT * FROM operations WHERE operation_id=?',
            [first.operationId],
          ),
        ))!,
        isEmpty,
      );
      await tester.tap(find.text('OK'));
      await settleReal(tester);
      expect(
        fault.actions.length,
        attempts,
        reason: 'no automatic replacement',
      );
      await tester.tap(find.byIcon(Icons.more_horiz).first);
      await settleReal(tester);
      expect(find.text('Retry'), findsNothing);
      expect(find.text('Disable'), findsOneWidget);
      expect(fault.actions.length, attempts);
      await tester.tap(find.text('Disable'));
      await settleReal(tester, ticks: 12);
      final latest = fault.actions.last;
      expect(latest.operationId, isNot(first.operationId));
      expect(latest.baseLocalRevision, edited.localRevision);
      final saved = (await tester.runAsync(
        () => DayTemplateRepository.local(h.database).byId('d1'),
      ))!;
      expect(saved.active, false);
      expect(saved.name, edited.name);
      expect(saved.focus, original.focus);
      expect(saved.scheduledWeekday, original.scheduledWeekday);
      expect(
        saved.slots.map(
          (s) => (
            s.id,
            s.exerciseId,
            s.position,
            s.workSets,
            s.warmupSets,
            s.repLow,
            s.repHigh,
            s.rirLow,
            s.rirHigh,
            s.rirPolicy,
          ),
        ),
        original.slots.map(
          (s) => (
            s.id,
            s.exerciseId,
            s.position,
            s.workSets,
            s.warmupSets,
            s.repLow,
            s.repHigh,
            s.rirLow,
            s.rirHigh,
            s.rirPolicy,
          ),
        ),
      );
      final statusRows = (await tester.runAsync(
        () => h.database.getAll(
          "SELECT * FROM operations WHERE target_id=? AND action='planSetActive'",
          ['d1'],
        ),
      ))!;
      expect(statusRows, hasLength(1));
      expect(statusRows.single['operation_id'], latest.operationId);
      expect(owner.hasPending('d1'), isFalse);
      await h.unmount(tester);
    },
  );

  testWidgets(
    'uncertain committed status intent survives a later content revision and replays exact bytes',
    (tester) async {
      final h = ScreenHarness();
      addTearDown(h.close);
      await h.open(tester);
      await tester.runAsync(() async {
        final repo = DayTemplateRepository.local(h.database),
            original = (await DayTemplateRepository.local(
              h.database,
            ).byId('d1'))!;
        final fault = FaultDatabase(h.database, afterCommit: true);
        final owner = DayStatusActions(DayTemplateRepository.local(fault));
        try {
          await expectLater(
            owner.perform(original),
            throwsA(isA<StateError>()),
          );
          expect(owner.hasPending('d1'), isTrue);
          final committed = (await repo.byId('d1'))!;
          expect(committed.active, false);
          await repo.saveDay(
            id: committed.id,
            draft: DayDraft(
              name: 'Uncertain preserved content',
              focus: committed.focus,
              weekday: committed.scheduledWeekday,
              localRevision: committed.localRevision,
              rawFields: committed.rawFields,
              changedFields: {'name'},
              slots: [
                for (final s in committed.slots)
                  SlotDraft(
                    itemId: s.id,
                    exerciseId: s.exerciseId,
                    workSets: s.workSets,
                    warmupSets: s.warmupSets,
                    repLow: s.repLow,
                    repHigh: s.repHigh,
                    rirLow: s.rirLow,
                    rirHigh: s.rirHigh,
                    rirPolicy: s.rirPolicy,
                    localRevision: s.localRevision,
                    rawFields: s.rawFields,
                    changedFields: {},
                  ),
              ],
            ),
          );
          final edited = (await repo.byId('d1'))!;
          expect(owner.hasPending('d1'), isTrue);
          expect(
            await owner.perform(edited),
            isFalse,
            reason: 'reconcile the original Disable, never enable',
          );
          expect(fault.actions, hasLength(2));
          expect(fault.actions[1].operationId, fault.actions[0].operationId);
          expect(fault.actions[1].bytes, fault.actions[0].bytes);
          expect(owner.hasPending('d1'), isFalse);
          final finalDay = (await repo.byId('d1'))!;
          expect(finalDay.active, false);
          expect(finalDay.name, edited.name);
          expect(finalDay.localRevision, edited.localRevision);
          expect(
            await h.database.getAll(
              "SELECT * FROM operations WHERE target_id=? AND action='planSetActive'",
              ['d1'],
            ),
            hasLength(1),
          );
        } finally {
          owner.dispose();
        }
      });
      await h.unmount(tester);
    },
  );

  for (final closePlan in [false, true]) {
    testWidgets(
      'in-flight Disable safely completes after ${closePlan ? 'Plan disposal' : 'list disposal'}',
      (tester) async {
        final h = ScreenHarness();
        addTearDown(h.close);
        await h.open(tester);
        setPhone(tester, width: 412);
        final gate = Completer<void>();
        final fault = FaultDatabase(h.database, gate: gate);
        h.overrideDatabase = fault;
        await tester.pumpWidget(h.wrap(const Scaffold(body: PlanScreen())));
        await settleReal(tester);
        await tester.tap(find.byIcon(Icons.more_horiz).first);
        await settleReal(tester);
        await tester.tap(find.text('Disable'));
        await settleReal(tester, ticks: 4);
        expect(fault.actions, hasLength(1));
        expect(find.text('Disabled $longDay'), findsNothing);
        if (closePlan) {
          await h.unmount(tester);
        } else {
          await tester.tap(find.text('Exercises'));
          await settleReal(tester);
        }
        gate.complete();
        await settleReal(tester, ticks: 12);
        expect(
          find.text('Disabled $longDay'),
          findsNothing,
          reason: 'a disposed list never reports success',
        );
        final day = (await tester.runAsync(
          () => DayTemplateRepository.local(h.database).byId('d1'),
        ))!;
        expect(day.active, false);
        expect(fault.actions, hasLength(1));
        if (!closePlan) {
          await tester.tap(find.text('Split'));
          await settleReal(tester);
          expect(find.text('Inactive (1)'), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
        await h.unmount(tester);
      },
    );
  }
}
