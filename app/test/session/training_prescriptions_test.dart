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
import 'package:alkion/session/live_set_card.dart';
import 'package:alkion/session/session_manager.dart';
import 'package:alkion/settings/settings_service.dart';
import 'package:alkion/shell/session_launcher.dart';
import 'package:alkion/store/local_store.dart';
import 'package:alkion/units/unit_service.dart';
import '../alkion/domains/local_screen_harness.dart';
import '../support/app_fonts.dart';
import '../support/l10n_harness.dart';
import '../support/layout_expect.dart';

const exercise = Exercise(
  id: 'plain',
  name: 'Plain',
  slug: 'plain',
  muscleGroup: 'chest',
  compound: false,
  plateStepKg: 2.5,
  isTemplate: false,
  defaultRirLow: 1,
  defaultRirHigh: 2,
);

Slot slot({
  String? policy = RirPolicy.off,
  int? low = 8,
  int? high = 8,
  int? rirLow,
  int? rirHigh,
}) => Slot(
  exerciseId: 'plain',
  position: 1,
  workSets: 2,
  warmupSets: 1,
  repLow: low,
  repHigh: high,
  rirLow: rirLow,
  rirHigh: rirHigh,
  rirPolicy: policy,
);

SessionDraft draft(BlockState block) => SessionDraft(
  templateId: 'day',
  name: 'Synthetic',
  focus: '',
  startedAt: DateTime.now(),
  blocks: [block],
);

Future<DayTemplate> createDay(
  LocalDatabase db, {
  String name = 'Synthetic',
  String? policy = RirPolicy.off,
  int? low = 8,
  int? high = 8,
}) async {
  final repo = DayTemplateRepository.local(db);
  final prepared = repo.prepareDay(
    DayDraft(
      name: name,
      slots: [
        SlotDraft(
          exerciseId: 'ex3',
          workSets: 2,
          warmupSets: 0,
          repLow: low,
          repHigh: high,
          rirPolicy: policy,
        ),
      ],
    ),
  );
  await repo.commitPrepared(prepared);
  return (await repo.byId(prepared.action.target.id))!;
}

class GateDraftStore extends DraftStore {
  GateDraftStore(super.database) : super.local();
  final entered = Completer<void>(), release = Completer<void>();
  @override
  Future<SessionDraft?> load() async {
    entered.complete();
    await release.future;
    return super.load();
  }
}

void main() {
  setUpAll(preloadAppFonts);
  for (final policy in [RirPolicy.off, RirPolicy.inherit, RirPolicy.target]) {
    test(
      'fresh $policy keeps targets separate from actual observations and added sets',
      () {
        final r = resolveFreshPrescription(
          slot(
            policy: policy,
            rirLow: policy == RirPolicy.target ? 0 : null,
            rirHigh: policy == RirPolicy.target ? 1 : null,
          ),
          exercise,
        );
        final block = buildBlock(resolved: r);
        final c = ActiveSessionController()..seedForTest(draft(block));
        addTearDown(c.dispose);
        expect(block.allSets.map((s) => s.rir), everyElement(isNull));
        c.logLiveSet();
        expect(c.rirPromptSetId, isNull, reason: 'warmup');
        final working = block.workingSets.first;
        c.logLiveSet();
        expect(working.rir, isNull);
        expect(c.rirPromptSetId, policy == RirPolicy.off ? isNull : working.id);
        c.setRirFromPrompt(working, 0);
        expect(working.rir, 0);
        c.addSet(block);
        expect(block.workingSets.last.rir, isNull);
        expect(working.rir, 0);
        c.setRirFromPrompt(working, null);
        expect(working.rir, isNull);
      },
    );
  }
  test(
    'absent or unavailable known RIR never invents a target or auto-prompt',
    () {
      const noDefault = Exercise(
        id: 'plain',
        name: 'Plain',
        slug: 'plain',
        muscleGroup: 'chest',
        compound: false,
        plateStepKg: 2.5,
        isTemplate: false,
      );
      for (final source in [
        slot(policy: RirPolicy.inherit),
        slot(policy: RirPolicy.target, rirLow: 9, rirHigh: -1),
      ]) {
        final r = resolveFreshPrescription(source, noDefault);
        final b = buildBlock(resolved: r);
        final c = ActiveSessionController()..seedForTest(draft(b));
        addTearDown(c.dispose);
        c.logLiveSet();
        c.logLiveSet();
        expect(c.rirPromptSetId, isNull);
        expect(r.hasRirTarget, isFalse);
        expect(b.workingSets.first.rir, isNull);
        expect(
          SessionDraft.fromJson(
            c.snapshot().toJson(),
          ).blocks.single.resolved.rirState,
          r.rirState,
        );
      }
    },
  );
  for (final pair in [(8, null), (null, 12), (12, 8), (0, 8), (8, 100)]) {
    test('fresh source reps $pair refuse before mixed target generation', () {
      expect(
        () => resolveFreshPrescription(
          slot(low: pair.$1, high: pair.$2),
          exercise,
        ),
        throwsA(isA<FreshPrescriptionUnavailableException>()),
      );
    });
  }
  test('unknown policy cannot generate a draft rejected by the decoder', () {
    expect(
      () => resolveFreshPrescription(slot(policy: 'future-policy'), exercise),
      throwsA(
        isA<FreshPrescriptionUnavailableException>().having(
          (e) => e.rirPolicy,
          'RIR policy',
          true,
        ),
      ),
    );
  });
  test(
    'old numeric draft and exact existing observations/timers are never recomputed',
    () {
      final b = buildBlock(
        resolved: resolveFreshPrescription(
          slot(policy: RirPolicy.target, rirLow: 1, rirHigh: 2),
          exercise,
        ),
      );
      b.workingSets[0].rir = 9;
      b.workingSets[1].rir = 0;
      final c = ActiveSessionController()..seedForTest(draft(b));
      addTearDown(c.dispose);
      c.startRest(90);
      final json = c.snapshot().toJson();
      final block = (json['blocks'] as List).single as Map<String, dynamic>;
      block.remove('resolvedRirPolicy');
      block.remove('resolvedRirState');
      final restored = ActiveSessionController.fromDraft(
        SessionDraft.fromJson(json),
      );
      addTearDown(restored.dispose);
      expect(
        restored.draft.blocks.single.workingSets.map((s) => s.id),
        b.workingSets.map((s) => s.id),
      );
      expect(restored.draft.blocks.single.workingSets.map((s) => s.rir), [
        9,
        0,
      ]);
      expect(restored.draft.blocks.single.resolved.rirLow, 1);
      expect(restored.draft.blocks.single.resolved.rirHigh, 2);
      expect(restored.restStart, c.restStart);
      expect(restored.restTotal, 90);
      restored.addSet(restored.draft.blocks.single);
      expect(restored.draft.blocks.single.workingSets.map((s) => s.rir), [
        9,
        0,
        null,
      ]);
    },
  );

  testWidgets(
    'real draft roundtrip and new ad-hoc blocks retain captured concrete defaults',
    (tester) async {
      final h = ScreenHarness();
      addTearDown(h.close);
      await h.open(tester);
      await tester.runAsync(() async {
        final repo = ExerciseRepository.local(h.database),
            sessions = SessionRepository.local(h.database);
        final plainId = await repo.createExercise(
          ExerciseDraft(
            name: 'No defaults',
            muscleGroup: 'chest',
            compound: false,
            plateStepKg: 2.5,
          ),
        );
        final plain = (await repo.byId(plainId))!;
        final store = DraftStore.local(h.database);
        await store.load();
        final c = ActiveSessionController(draftStore: store)
          ..seedEmpty(name: 'Custom', focus: '');
        try {
          await c.addBlock(plain, sessionRepo: sessions);
          expect(
            (
              c.draft.blocks.first.resolved.repLow,
              c.draft.blocks.first.resolved.repHigh,
              c.draft.blocks.first.resolved.rirPolicy,
            ),
            (8, 8, RirPolicy.off),
          );
          await h.settings.setRepEntry(RepEntry.range);
          await h.settings.setRirControls(RirControls.show);
          await c.addBlock(
            (await repo.byId('ex3'))!,
            sessionRepo: sessions,
            repEntry: RepEntry.range,
            rirControls: RirControls.show,
          );
          final second = c.draft.blocks.last;
          expect(
            (second.resolved.repLow, second.resolved.repHigh),
            (6, 10),
            reason: 'valid exercise defaults win',
          );
          expect(second.resolved.hasRirTarget, isTrue);
          expect(second.workingSets.map((s) => s.rir), everyElement(isNull));
          c.draft.blocks.first.workingSets.first
            ..done = true
            ..rir = 0;
          c.startRest(120);
          await c.flushPersistence();
          final saved = (await store.load())!;
          final restored = ActiveSessionController.fromDraft(saved);
          try {
            expect(
              restored.draft.blocks.first.resolved.rirPolicy,
              RirPolicy.off,
            );
            expect(
              (
                restored.draft.blocks.first.resolved.repLow,
                restored.draft.blocks.first.resolved.repHigh,
              ),
              (8, 8),
            );
            expect(restored.draft.blocks.first.workingSets.first.rir, 0);
            expect(restored.restStart, c.restStart);
            expect(restored.restTotal, 120);
            restored.addSet(restored.draft.blocks.first);
            expect(restored.draft.blocks.first.workingSets.last.rir, isNull);
          } finally {
            restored.dispose();
          }
        } finally {
          c.dispose();
        }
      });
      await h.unmount(tester);
    },
  );

  testWidgets(
    'malformed reps and unknown RIR policy preserve an existing native draft and source bytes',
    (tester) async {
      final h = ScreenHarness();
      addTearDown(h.close);
      await h.open(tester);
      await tester.runAsync(() async {
        final store = DraftStore.local(h.database);
        await store.load();
        final saved = SessionDraft(
          templateId: null,
          name: 'Retained draft',
          focus: '',
          startedAt: DateTime.now(),
          blocks: [],
        );
        await store.save(saved);
        final before = await h.database.inventory();
        for (final source in [
          const Slot(exerciseId: 'ex3', position: 1, repLow: 8),
          const Slot(
            exerciseId: 'ex3',
            position: 1,
            repLow: 8,
            repHigh: 8,
            rirPolicy: 'future-policy',
          ),
        ]) {
          final c = ActiveSessionController(draftStore: store);
          try {
            await expectLater(
              c.buildFromTemplate(
                DayTemplate(
                  id: 'bad',
                  name: 'Bad',
                  position: 1,
                  slots: [source],
                ),
                exerciseRepo: ExerciseRepository.local(h.database),
                sessionRepo: SessionRepository.local(h.database),
              ),
              throwsA(isA<FreshPrescriptionUnavailableException>()),
            );
            expect(c.hasSession, isFalse);
            await c.flushPersistence();
            expect(store.pending, isNull);
            expect(await h.database.inventory(), before);
            expect((await store.load())!.draftId, saved.draftId);
          } finally {
            c.dispose();
          }
        }
      });
      await h.unmount(tester);
    },
  );

  for (final code in ['en', 'de', 'es', 'it']) {
    testWidgets(
      'manual actual RIR add/zero/clear remains optional and readable at 320dp 2x $code',
      (tester) async {
        setPhone(tester, width: 320, textScale: 2);
        final s = SetState(
          id: 'actual',
          weightKg: 20,
          reps: 8,
          rir: 9,
          isWarmup: false,
          done: true,
        );
        var changes = 0;
        Widget host() => wrapL10n(
          Scaffold(
            body: SingleChildScrollView(
              child: LiveSetCard(
                set: s,
                exercise: exercise,
                workIndex: 1,
                lastTop: null,
                unit: UnitService(),
                onChanged: () => changes++,
                onMarkNotDone: () {},
              ),
            ),
          ),
          locale: Locale(code),
        );
        await tester.pumpWidget(host());
        expect(s.rir, 9);
        expect(s.rirTouched, isFalse);
        expect(find.text('RIR 9'), findsOneWidget);
        expectNoSplitWords(tester);
        await tester.tap(find.byKey(const Key('rir-0')));
        await tester.pumpWidget(host());
        expect(s.rir, 0);
        await tester.ensureVisible(find.byKey(const Key('live-clear-rir')));
        await tester.tap(find.byKey(const Key('live-clear-rir')));
        await tester.pumpWidget(host());
        expect(s.rir, isNull);
        expect(changes, 2);
        expect(find.byKey(const Key('live-clear-rir')), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  for (final unknown in [false, true]) {
    testWidgets(
      'stale ${unknown ? 'unknown' : 'disabled'} day launch refuses without writes and offers Plan',
      (tester) async {
        final h = ScreenHarness();
        addTearDown(h.close);
        await h.open(tester);
        setPhone(tester, width: 412);
        late DayTemplate stale;
        late SessionManager manager;
        await tester.runAsync(() async {
          final repo = DayTemplateRepository.local(h.database);
          stale = (await repo.byId('d2'))!;
          if (unknown) {
            await h.database.writeTransaction((tx) async {
              final ref = LocalRef(
                h.database.profileId,
                RecordKind.trainingDay,
                stale.id,
              );
              final fields = {
                'name': stale.name,
                'position': stale.position,
                'is_active': 2,
              };
              final rev = await tx.writeRevision(
                ref,
                localBytes(fields),
                layer: 'sourceSelection',
              );
              await tx.putRecord(ref, rev, fields);
            });
          } else {
            await repo.commitPrepared(
              repo.prepareSetActive(stale.id, stale.localRevision!, false),
            );
          }
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
                      template: stale,
                      onOpenPlan: () => plan = true,
                    ),
                  ),
                  child: const Text('Stale start'),
                ),
              ),
            ),
            extra: [
              ChangeNotifierProvider<SessionManager>.value(value: manager),
            ],
          ),
        );
        final before = await tester.runAsync(h.database.inventory);
        await tester.tap(find.text('Stale start'));
        await settleReal(tester, ticks: 8);
        expect(manager.hasActive, isFalse);
        expect(find.text('Workout unavailable'), findsOneWidget);
        expect(plan, isFalse);
        await tester.tap(find.text('Open Plan'));
        await settleReal(tester);
        expect(plan, isTrue);
        expect(manager.launching, isFalse);
        expect(await tester.runAsync(h.database.inventory), before);
        await h.unmount(tester);
      },
    );
  }

  testWidgets(
    'Disable after fresh admission preserves the launch, minimize/resume and finish',
    (tester) async {
      final h = ScreenHarness();
      addTearDown(h.close);
      await h.open(tester);
      setPhone(tester, width: 412);
      late DayTemplate day;
      late GateDraftStore store;
      late SessionManager manager;
      await tester.runAsync(() async {
        day = (await DayTemplateRepository.local(h.database).byId('d2'))!;
        store = GateDraftStore(h.localDatabase);
        manager = SessionManager(
          draftStore: store,
          finishedStore: FinishedSessionStore.local(h.localDatabase),
        );
      });
      ActiveSessionController? controller;
      addTearDown(() => controller?.dispose());
      addTearDown(manager.dispose);
      await tester.pumpWidget(
        h.wrap(
          Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () =>
                    unawaited(startSession(context, template: day)),
                child: const Text('Start'),
              ),
            ),
          ),
          extra: [ChangeNotifierProvider<SessionManager>.value(value: manager)],
        ),
      );
      await tester.tap(find.text('Start'));
      await settleReal(tester, ticks: 5);
      expect(store.entered.isCompleted, isTrue);
      await tester.runAsync(() async {
        final r = DayTemplateRepository.local(h.database);
        await r.commitPrepared(
          r.prepareSetActive(day.id, day.localRevision!, false),
        );
      });
      store.release.complete();
      await settleReal(tester, ticks: 12);
      expect(manager.hasActive, isTrue);
      final active = manager.active!;
      controller = active;
      expect(active.draft.templateId, day.id);
      expect(find.byType(ActiveSessionScreen), findsOneWidget);
      final ids = active.draft.blocks.single.allSets.map((s) => s.id).toList();
      tester.state<NavigatorState>(find.byType(Navigator).first).pop();
      await settleReal(tester);
      expect(manager.hasActive, isTrue);
      expect(active.draft.blocks.single.allSets.map((s) => s.id), ids);
      await tester.tap(find.text('Start'));
      await settleReal(tester, ticks: 8);
      expect(find.byType(ActiveSessionScreen), findsOneWidget);
      expect(identical(manager.active, active), isTrue);
      expect(active.draft.blocks.single.allSets.map((s) => s.id), ids);
      tester.state<NavigatorState>(find.byType(Navigator).first).pop();
      await settleReal(tester);
      active.draft.blocks.single.workingSets.first
        ..done = true
        ..rir = 0;
      await tester.runAsync(() async {
        await active.flushPersistence();
        await finishWorkout(
          active,
          manager,
          repository: WorkoutRepository.local(h.database),
        );
      });
      expect(
        (await tester.runAsync(
          () => DayTemplateRepository.local(h.database).byId(day.id),
        ))!.active,
        false,
      );
      await h.unmount(tester);
    },
  );
}
