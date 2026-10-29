import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:alkion/data/active_session_draft.dart';
import 'package:alkion/data/day_template_repository.dart';
import 'package:alkion/data/exercise_repository.dart';
import 'package:alkion/data/finished_session_store.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/domain/evidence.dart';
import 'package:alkion/domain/local_action.dart';
import 'package:alkion/data/session_repository.dart';
import 'package:alkion/data/session_writer.dart';
import 'package:alkion/session/active_session_controller.dart';
import 'package:alkion/session/active_session_screen.dart';
import 'package:alkion/session/set_line.dart';
import 'package:alkion/session/session_manager.dart';
import 'package:alkion/settings/settings_service.dart';
import 'package:alkion/shell/session_launcher.dart';
import 'package:alkion/shell/app_shell.dart';
import 'package:alkion/ui/plan_screen.dart';
import 'package:alkion/ui/today_screen.dart';
import 'package:alkion/widgets/split_card.dart';
import 'package:alkion/widgets/week_strip.dart';
import '../alkion/domains/local_screen_harness.dart';
import '../support/layout_expect.dart';
import '../session/training_prescriptions_test.dart' show createDay;

Future<FinishedSession> finished(
  ScreenHarness h,
  DayTemplate day, {
  int? rir = 9,
}) async {
  final store = DraftStore.local(h.database);
  await store.load();
  final c = ActiveSessionController(draftStore: store);
  try {
    await c.buildFromTemplate(
      day,
      exerciseRepo: ExerciseRepository.local(h.database),
      sessionRepo: SessionRepository.local(h.database),
    );
    c.draft.blocks.first.workingSets.first
      ..done = true
      ..rir = rir;
    c.markChanged();
    await c.flushPersistence();
    await c.commitFinish(WorkoutRepository.local(h.database));
    return c.lastFinished!;
  } finally {
    c.dispose();
  }
}

void main() {
  testWidgets(
    'Today rotates after an inactive last-trained anchor and filters planned choices/weekday previews',
    (tester) async {
      final h = ScreenHarness();
      addTearDown(h.close);
      await h.open(tester);
      setPhone(tester, width: 412);
      late String historyId;
      await tester.runAsync(() async {
        await seedDay(
          h.database,
          'd3',
          'Third',
          position: 3,
          exerciseIds: ['ex3'],
          weekday: 4,
        );
        final r = DayTemplateRepository.local(h.database),
            b = (await r.byId('d2'))!;
        historyId = (await finished(h, b)).sessionId;
        await r.commitPrepared(
          r.prepareSetActive(b.id, b.localRevision!, false),
        );
      });
      var plan = false;
      await tester.pumpWidget(
        h.wrap(
          Scaffold(
            body: TodayScreen(
              onStart: (_) {},
              onOpenExercise: (_) {},
              onOpenProfile: () {},
              onResume: () {},
              onOpenPlan: () => plan = true,
            ),
          ),
        ),
      );
      await settleReal(tester);
      final card = tester.widget<SplitCard>(find.byType(SplitCard));
      expect(card.days.map((d) => d.day.id), ['d1', 'd3']);
      expect(
        card.days[card.nextIndex].day.id,
        'd3',
        reason:
            'full saved order after last-trained B must pick C, not active-list A',
      );
      expect(card.workload!.coverage!.mappedSets, 3);
      await scrollIntoView(
        tester,
        find.byType(TodayScreen),
        find.byType(WeekStrip),
      );
      final week = tester.widget<WeekStrip>(find.byType(WeekStrip));
      expect(week.days.map((d) => d.name), [longDay, 'Third']);
      expect(week.days.any((d) => d.name == 'Pull'), isFalse);
      final rows = (await tester.runAsync(
        () => SessionRepository.local(h.database).setsForSession(historyId),
      ))!;
      expect(rows.single.rir, 9, reason: 'inactive history remains present');
      await tester.runAsync(() async {
        final r = DayTemplateRepository.local(h.database);
        for (final d in await r.allDays()) {
          if (d.isActive) {
            await r.commitPrepared(
              r.prepareSetActive(d.id, d.localRevision!, false),
            );
          }
        }
      });
      await settleReal(tester);
      await scrollIntoView(
        tester,
        find.byType(TodayScreen),
        find.byType(SplitCard),
      );
      expect(tester.widget<SplitCard>(find.byType(SplitCard)).days, isEmpty);
      await scrollIntoView(
        tester,
        find.byType(TodayScreen),
        find.text('Enable a day in Plan'),
      );
      await tester.tap(find.text('Enable a day in Plan'));
      expect(plan, isTrue);
      expect(
        find.text(
          'Your saved days are not active. Review them in Plan or start a custom workout.',
        ),
        findsOneWidget,
      );
      await h.unmount(tester);
    },
  );

  testWidgets(
    'empty Today keeps custom creation distinct from saved all-disabled days',
    (tester) async {
      final h = ScreenHarness();
      addTearDown(h.close);
      await h.open(tester, seed: (_) async {});
      setPhone(tester, width: 320, textScale: 2);
      await tester.pumpWidget(
        h.wrap(
          Scaffold(
            body: TodayScreen(
              onStart: (_) {},
              onOpenExercise: (_) {},
              onOpenProfile: () {},
              onResume: () {},
              onOpenPlan: () {},
            ),
          ),
        ),
      );
      await settleReal(tester);
      expect(tester.widget<SplitCard>(find.byType(SplitCard)).days, isEmpty);
      expect(find.text('Enable a day in Plan'), findsNothing);
      expect(
        find.textContaining('Your saved days are not active'),
        findsNothing,
      );
      expectNoSplitWords(tester);
      expect(tester.takeException(), isNull);
      await h.unmount(tester);
    },
  );

  testWidgets(
    'open ad-hoc picker captures defaults and later additions leave old blocks unchanged',
    (tester) async {
      final h = ScreenHarness();
      addTearDown(h.close);
      await h.open(
        tester,
        seed: (db) async {
          final repo = ExerciseRepository.local(db);
          await repo.createExercise(
            ExerciseDraft(
              name: 'Plain one',
              muscleGroup: 'chest',
              compound: false,
              plateStepKg: 2.5,
            ),
          );
          await repo.createExercise(
            ExerciseDraft(
              name: 'Plain two',
              muscleGroup: 'chest',
              compound: false,
              plateStepKg: 2.5,
              defaultRirLow: 0,
              defaultRirHigh: 0,
            ),
          );
        },
      );
      setPhone(tester, width: 412);
      final c = ActiveSessionController()..seedEmpty(name: 'Custom', focus: '');
      addTearDown(c.dispose);
      await tester.pumpWidget(
        h.wrap(
          ChangeNotifierProvider<ActiveSessionController>.value(
            value: c,
            child: const ActiveSessionScreen(),
          ),
        ),
      );
      await settleReal(tester);
      await scrollIntoView(
        tester,
        find.byType(ActiveSessionScreen),
        find.text('Add exercise'),
      );
      await tester.tap(find.text('Add exercise'));
      await settleReal(tester);
      await tester.runAsync(() async {
        await h.settings.setRepEntry(RepEntry.range);
        await h.settings.setRirControls(RirControls.show);
      });
      await tester.tap(find.text('Plain one'));
      await settleReal(tester);
      final first = c.draft.blocks.first;
      expect(
        (
          first.resolved.repLow,
          first.resolved.repHigh,
          first.resolved.rirPolicy,
        ),
        (8, 8, RirPolicy.off),
      );
      await scrollIntoView(
        tester,
        find.byType(ActiveSessionScreen),
        find.text('Add exercise'),
      );
      await tester.tap(find.text('Add exercise'));
      await settleReal(tester);
      await tester.tap(find.text('Plain two'));
      await settleReal(tester);
      final second = c.draft.blocks.last;
      expect(
        (
          second.resolved.repLow,
          second.resolved.repHigh,
          second.resolved.rirPolicy,
        ),
        (8, 12, RirPolicy.inherit),
      );
      expect((second.resolved.rirLow, second.resolved.rirHigh), (0, 0));
      expect(second.workingSets.map((s) => s.rir), everyElement(isNull));
      expect(
        (
          first.resolved.repLow,
          first.resolved.repHigh,
          first.resolved.rirPolicy,
        ),
        (8, 8, RirPolicy.off),
      );
      expect(find.textContaining('3×8–8'), findsNothing);
      expect(find.textContaining('RIR null'), findsNothing);
      await h.unmount(tester);
    },
  );

  testWidgets(
    'disabled finished workout resumes exact targets/observations and finishes an added null-RIR set',
    (tester) async {
      final h = ScreenHarness();
      addTearDown(h.close);
      await h.open(tester);
      await tester.runAsync(() async {
        final r = DayTemplateRepository.local(h.database);
        final day = (await r.byId('d2'))!;
        final f = await finished(h, day);
        final originalId = f.draft.blocks.first.workingSets.first.id;
        await r.commitPrepared(
          r.prepareSetActive(day.id, day.localRevision!, false),
        );
        await h.settings.setRepEntry(RepEntry.fixed);
        await h.settings.setRirControls(RirControls.off);
        final manager = SessionManager(
          draftStore: DraftStore.local(h.database),
          finishedStore: FinishedSessionStore.local(h.database),
        );
        ActiveSessionController? c;
        try {
          manager.adoptCommitted(f);
          c = await prepareResume(
            manager,
            f.sessionId,
            sessionRepo: SessionRepository.local(h.database),
            exerciseRepo: ExerciseRepository.local(h.database),
            draftStore: manager.draftStore!,
          );
          expect(c, isNotNull);
          final block = c!.draft.blocks.single;
          expect(block.resolved.repLow, 6);
          expect(block.resolved.repHigh, 10);
          expect(block.resolved.rirLow, 1);
          expect(block.resolved.rirHigh, 2);
          expect(block.workingSets.first.id, originalId);
          expect(block.workingSets.first.rir, 9);
          c.addSet(block);
          final added = block.workingSets.last;
          expect(added.rir, isNull);
          added.done = true;
          c.markChanged();
          final id = await finishWorkout(
            c,
            manager,
            repository: WorkoutRepository.local(h.database),
          );
          expect(id, f.sessionId);
          final rows = await SessionRepository.local(
            h.database,
          ).setsForSession(id);
          expect(rows.map((s) => s.id), [originalId, added.id]);
          expect(rows.map((s) => s.rir), [9, null]);
          expect((await r.byId(day.id))!.active, false);
        } finally {
          manager.dispose();
          c?.dispose();
        }
      });
      await h.unmount(tester);
    },
  );

  testWidgets(
    'a valid target prompt offers actual RIR clear while no-target logging stays quiet',
    (tester) async {
      final h = ScreenHarness();
      addTearDown(h.close);
      await h.open(tester);
      setPhone(tester, width: 412);
      final ex = (await tester.runAsync(
        () => ExerciseRepository.local(h.database).byId('ex3'),
      ))!;
      final b = buildBlock(
        resolved: resolveFreshPrescription(
          Slot(
            exerciseId: ex.id,
            position: 1,
            workSets: 2,
            warmupSets: 0,
            repLow: 8,
            repHigh: 8,
            rirPolicy: RirPolicy.inherit,
          ),
          ex,
        ),
      );
      final c = ActiveSessionController()
        ..seedForTest(
          SessionDraft(
            templateId: null,
            name: 'Target',
            focus: '',
            startedAt: DateTime.now(),
            blocks: [b],
          ),
        );
      addTearDown(c.dispose);
      await tester.pumpWidget(
        h.wrap(
          ChangeNotifierProvider<ActiveSessionController>.value(
            value: c,
            child: const ActiveSessionScreen(),
          ),
        ),
      );
      await settleReal(tester);
      c.logLiveSet();
      await settleReal(tester, ticks: 4);
      final first = b.workingSets.first;
      expect(c.rirPromptSetId, first.id);
      expect(first.rir, isNull);
      final prompt = find.descendant(
        of: find.byType(SetLine),
        matching: find.byKey(const Key('rir-0')),
      );
      await scrollIntoView(tester, find.byType(ActiveSessionScreen), prompt);
      await tester.tap(prompt);
      await tester.pump();
      expect(first.rir, 0);
      await scrollIntoView(
        tester,
        find.byType(ActiveSessionScreen),
        find.text('Clear RIR'),
      );
      await tester.tap(find.text('Clear RIR'));
      await tester.pump();
      expect(first.rir, isNull);
      expect(find.textContaining('2×8–8'), findsNothing);
      expect(find.textContaining('2×8 · RIR 1–2'), findsOneWidget);
      await h.unmount(tester);
    },
  );
  testWidgets(
    'retained weekday9 never rolls into a real weekday in Today previews',
    (tester) async {
      final h = ScreenHarness();
      addTearDown(h.close);
      await h.open(tester);
      setPhone(tester, width: 320, textScale: 2);
      const day = DayTemplate(
        id: 'bad-weekday',
        name: 'Retained day',
        scheduledWeekday: 9,
        position: 1,
        slots: [],
      );
      await tester.pumpWidget(
        h.wrap(
          const Scaffold(
            body: SingleChildScrollView(
              child: Column(
                children: [
                  WeekStrip(
                    days: [
                      (
                        name: 'Retained day',
                        weekday: 9,
                        isNext: false,
                        done: false,
                      ),
                    ],
                  ),
                  DaySlide(
                    day: day,
                    exerciseCount: 0,
                    lastAgo: '',
                    index: 1,
                    nextIndex: 0,
                    bodyVisible: false,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await settleReal(tester);
      expect(find.text('Wed'), findsNothing);
      expect(find.textContaining('SWITCH TO WED'), findsNothing);
      expect(day.scheduledWeekday, 9);
      expectNoSplitWords(tester);
      expect(tester.takeException(), isNull);
      await h.unmount(tester);
    },
  );

  for (final unknownPolicy in [false, true]) {
    testWidgets(
      'fresh committed ${unknownPolicy ? 'unknown policy' : 'partial rep override'} refuses locally with Plan guidance',
      (tester) async {
        final h = ScreenHarness();
        addTearDown(h.close);
        await h.open(tester);
        setPhone(tester, width: 412);
        late DayTemplate day;
        late SessionManager manager;
        await tester.runAsync(() async {
          day = await createDay(h.database);
          await h.database.writeTransaction((tx) async {
            final ref = LocalRef(
              h.database.profileId,
              RecordKind.trainingSlot,
              day.slots.single.id!,
            );
            final fields = <String, Object?>{
              'day_template_id': day.id,
              'exercise_id': 'ex3',
              'position': 1,
              'target_working_sets': 2,
              'target_warmup_sets': 0,
              'target_rep_low': 8,
              'target_rep_high': unknownPolicy ? 8 : null,
              'rir_policy': unknownPolicy ? 'future-policy' : RirPolicy.off,
            };
            final rev = await tx.writeRevision(
              ref,
              localBytes(fields),
              layer: 'sourceSelection',
            );
            await tx.putRecord(ref, rev, fields);
          });
          manager = SessionManager(
            draftStore: DraftStore.local(h.localDatabase),
          );
        });
        addTearDown(manager.dispose);
        var plan = false;
        await tester.pumpWidget(
          h.wrap(
            Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => unawaited(
                    startSession(
                      context,
                      template: day,
                      onOpenPlan: () => plan = true,
                    ),
                  ),
                  child: const Text('Start'),
                ),
              ),
            ),
            extra: [
              ChangeNotifierProvider<SessionManager>.value(value: manager),
            ],
          ),
        );
        final before = await tester.runAsync(h.database.inventory);
        await tester.tap(find.text('Start'));
        await settleReal(tester, ticks: 8);
        expect(find.text('Workout unavailable'), findsOneWidget);
        expect(
          find.textContaining(
            unknownPolicy ? 'The RIR policy' : 'The rep prescription',
          ),
          findsOneWidget,
        );
        expect(manager.hasActive, isFalse);
        expect(manager.draftStore!.pending, isNull);
        await tester.tap(find.text('Open Plan'));
        await settleReal(tester);
        expect(plan, isTrue);
        expect(await tester.runAsync(h.database.inventory), before);
        await h.unmount(tester);
      },
    );
  }

  testWidgets('stale day refusal routes the real shell to Plan', (
    tester,
  ) async {
    final h = ScreenHarness();
    addTearDown(h.close);
    await h.open(tester);
    setPhone(tester, width: 412);
    final manager = SessionManager(
      draftStore: DraftStore.local(h.localDatabase),
    );
    addTearDown(manager.dispose);
    await tester.pumpWidget(
      h.wrap(
        const AppShell(),
        extra: [ChangeNotifierProvider<SessionManager>.value(value: manager)],
      ),
    );
    await settleReal(tester);
    final card = tester.widget<SplitCard>(find.byType(SplitCard));
    final day = card.days.first.day;
    await tester.runAsync(() async {
      final r = DayTemplateRepository.local(h.database);
      await r.commitPrepared(
        r.prepareSetActive(day.id, day.localRevision!, false),
      );
    });
    card.onStart(day);
    await settleReal(tester, ticks: 8);
    expect(find.text('Workout unavailable'), findsOneWidget);
    await tester.tap(find.text('Open Plan'));
    await settleReal(tester);
    expect(find.byType(PlanScreen), findsOneWidget);
    expect(find.byType(TodayScreen), findsNothing);
    expect(manager.hasActive, isFalse);
    await h.unmount(tester);
  });
  testWidgets('all-disabled saved days still allow a fresh custom workout', (
    tester,
  ) async {
    final h = ScreenHarness();
    addTearDown(h.close);
    await h.open(tester);
    setPhone(tester, width: 412);
    await tester.runAsync(() async {
      final r = DayTemplateRepository.local(h.database);
      for (final d in await r.allDays()) {
        await r.commitPrepared(
          r.prepareSetActive(d.id, d.localRevision!, false),
        );
      }
    });
    final manager = SessionManager(
      draftStore: DraftStore.local(h.localDatabase),
    );
    ActiveSessionController? active;
    addTearDown(() => active?.dispose());
    addTearDown(manager.dispose);
    await tester.pumpWidget(
      h.wrap(
        const AppShell(),
        extra: [ChangeNotifierProvider<SessionManager>.value(value: manager)],
      ),
    );
    await settleReal(tester);
    final card = tester.widget<SplitCard>(find.byType(SplitCard));
    expect(card.days, isEmpty);
    card.onStart(null);
    await settleReal(tester, ticks: 10);
    active = manager.active;
    expect(find.byType(ActiveSessionScreen), findsOneWidget);
    expect(active, isNotNull);
    expect(active!.draft.templateId, isNull);
    expect(active.draft.blocks, isEmpty);
    final days = (await tester.runAsync(
      () => DayTemplateRepository.local(h.database).allDays(),
    ))!;
    expect(days.map((d) => d.id), ['d1', 'd2']);
    expect(days.every((d) => d.active == false), isTrue);
    await h.unmount(tester);
  });
}
