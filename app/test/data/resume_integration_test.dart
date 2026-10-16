import 'package:alkion/store/local_store.dart';
import 'package:alkion/data/active_session_draft.dart';
import '../support/screen_harness.dart';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:alkion/data/exercise_repository.dart';
import 'package:alkion/data/finished_session_store.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/data/session_repository.dart';
import 'package:alkion/data/session_writer.dart';
import 'package:alkion/session/active_session_controller.dart';
import 'package:alkion/session/resume.dart';
import 'package:alkion/session/session_manager.dart';
import 'package:alkion/shell/session_launcher.dart';
import 'package:alkion/util/dates.dart';

/// Resume contracts against the real standalone SQLite store: stable workout
/// identity, immutable authored revisions/outbox, and baselines that exclude
/// the resumed workout's own rows.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late FixtureDatabase db;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    dir = await Directory.systemTemp.createTemp('alkion-resume');
    db = await FixtureDatabase.open(dir);
    await db.initialize();
  });

  tearDown(() async {
    await db.close();
    await dir.delete(recursive: true);
  });

  Future<void> seedDay(String id) => db.execute(
    'INSERT INTO day_templates (id, name, position, is_template) VALUES (?, ?, 0, 0)',
    [id, 'Upper A'],
  );

  Future<void> seedSession(String id, String date, {String? day}) => db.execute(
    'INSERT INTO sessions (id, date, day_template_id, split_label, duration_min) '
    'VALUES (?, ?, ?, ?, ?)',
    [id, date, day, 'Upper A', 40],
  );

  Future<void> seedSet(
    String id,
    String sessionId,
    String exerciseId,
    int n,
    String weight, {
    bool top = false,
  }) => db.execute(
    'INSERT INTO sets (id, session_id, exercise_id, set_number, weight_kg, reps, rir, '
    'is_warmup, is_top_set, is_pr) VALUES (?, ?, ?, ?, ?, 5, 1, 0, ?, 0)',
    [id, sessionId, exerciseId, n, weight, top ? 1 : 0],
  );

  Future<void> seedExercise(String id, String name) => db.execute(
    'INSERT INTO exercises (id, slug, name, muscle_group, equip, compound, '
    'base_weight_kg, plate_step_kg, is_template) VALUES (?, ?, ?, ?, ?, 1, ?, ?, 0)',
    [id, '$name-$id', name, 'chest', 'barbell', '60.00', '2.50'],
  );

  Future<void> saveWrite(SessionWrite w, {bool replace = false}) async {
    final old = await db.getOptional('SELECT * FROM sessions WHERE id=?', [
      w.id,
    ]);
    for (final set in w.sets) {
      if (await db.getOptional('SELECT id FROM exercises WHERE id=?', [
            set.exerciseId,
          ]) ==
          null) {
        await seedExercise(set.exerciseId, set.exerciseId);
      }
    }
    final state = await db.readTransaction(
      (tx) => tx.localState(LocalStateKind.draft, 'active'),
    );
    final revision = await commitWorkflowState(
      db,
      PreparedWorkflowState(
        db,
        {'draftId': 'fixture-draft'},
        {'draftId': 'fixture-draft', 'restStart': null, 'restTotal': 0},
        state?['revision'] as int? ?? 0,
      ),
    );
    final rows = await db.getAll(
      'SELECT id,revision FROM sets WHERE session_id=?',
      [w.id],
    );
    final repo = WorkoutRepository.local(db);
    await repo.commitPrepared(
      repo.prepareFinish(
        write: w,
        baseRevision: replace ? (old?['revision'] as int? ?? 1) : 0,
        setBases: {
          for (final r in rows) r['id'] as String: r['revision'] as int,
        },
        recovery: {'fixture': 'finished'},
        draftRevision: revision,
        draftId: 'fixture-draft',
      ),
    );
  }

  SessionWrite write(String id, {String? day, List<SetWrite>? sets}) =>
      SessionWrite(
        id: id,
        dateIso: '2026-09-23',
        dayTemplateId: day,
        splitLabel: 'Upper A',
        durationMin: 55,
        sets:
            sets ??
            const [
              SetWrite(
                id: 'a',
                exerciseId: 'bench',
                setNumber: 1,
                weightKg: '102.50',
                reps: 5,
                rir: 1,
                isWarmup: false,
                isTopSet: true,
              ),
              SetWrite(
                id: 'b',
                exerciseId: 'bench',
                setNumber: 2,
                weightKg: '100.00',
                reps: 5,
                rir: 1,
                isWarmup: false,
              ),
            ],
      );

  group('writer (real DB)', () {
    test(
      'persistSession stores NULL for a training day that no longer exists',
      () async {
        await saveWrite(write('S', day: 'gone'));
        final row = await db.get(
          'SELECT day_template_id FROM sessions WHERE id = ?',
          ['S'],
        );
        expect(row['day_template_id'], isNull);
      },
    );

    test('persistSession keeps an existing training day', () async {
      await seedDay('d1');
      await saveWrite(write('S', day: 'd1'));
      final row = await db.get(
        'SELECT day_template_id FROM sessions WHERE id = ?',
        ['S'],
      );
      expect(row['day_template_id'], 'd1');
    });

    test(
      'replaceSession keeps the row and set IDs with one immutable replacement action and recoverable removed sets',
      () async {
        await seedDay('d1');
        await seedSession('S', '2026-09-23', day: 'd1');
        await seedSet('a', 'S', 'bench', 1, '100.00', top: true);
        await seedSet('old', 'S', 'bench', 2, '95.00');

        final priorRevisions = await db.getAll(
          'SELECT * FROM record_revisions ORDER BY rowid',
        );
        await saveWrite(write('S', day: 'd1'), replace: true);
        expect(
          (await db.getAll(
            'SELECT * FROM record_revisions ORDER BY rowid',
          )).take(priorRevisions.length),
          priorRevisions,
        );

        final operation = await db.get(
          'SELECT * FROM operations WHERE target_id=? ORDER BY rowid DESC LIMIT 1',
          ['S'],
        );
        expect(operation['action'], 'workoutReplace');
        expect(operation['target_id'], 'S');
        expect(operation['base_local_revision'], 1);
        expect(operation['input_bytes'], isNotEmpty);
        expect(operation['input_hash'], isNotEmpty);
        final revisions = await db.getAll(
          'SELECT * FROM record_revisions WHERE operation_id=?',
          [operation['operation_id']],
        );
        expect(
          revisions.map((r) => r['record_id']),
          containsAll(['S', 'a', 'b', 'old']),
        );
        expect(
          revisions.singleWhere((r) => r['record_id'] == 'old')['deleted'],
          1,
        );
        expect(
          (await db.get('SELECT * FROM sessions WHERE id=?', [
            'S',
          ]))['duration_min'],
          55,
        );
        expect(
          (await db.get('SELECT * FROM sets WHERE id=?', ['old']))['deleted'],
          1,
        );
        final sessions = await db.getAll('SELECT id, date FROM sessions');
        expect(sessions.single['id'], 'S');
        expect(sessions.single['date'], '2026-09-23');
        final sets = await db.getAll(
          'SELECT id, weight_kg FROM sets WHERE deleted=0 ORDER BY id',
        );
        expect(sets.map((r) => r['id']), ['a', 'b']);
        expect(sets.first['weight_kg'], '102.50');
      },
    );

    test(
      'replaceSession survives a training day deleted since the first finish',
      () async {
        await seedDay('d1');
        await seedSession('S', '2026-09-23', day: 'd1');
        await seedSet('a', 'S', 'bench', 1, '100.00', top: true);
        await db.execute('DELETE FROM day_templates WHERE id = ?', ['d1']);

        await saveWrite(write('S', day: 'd1'), replace: true);

        final operation = await db.get(
          'SELECT * FROM operations WHERE target_id=? ORDER BY rowid DESC LIMIT 1',
          ['S'],
        );
        expect(operation['action'], 'workoutReplace');
        expect(
          (await db.get('SELECT * FROM sessions WHERE id=?', [
            'S',
          ]))['original_day_id'],
          'd1',
        );
        expect((await db.getAll('SELECT id FROM sessions')).single['id'], 'S');
      },
    );

    test(
      'replaceSession refuses an absent recovered identity rather than inventing history',
      () async {
        await expectLater(
          saveWrite(write('S', day: 'gone'), replace: true),
          throwsA(isA<StoreException>()),
        );
        expect(await db.getAll('SELECT * FROM sessions'), isEmpty);
        expect(await db.getAll('SELECT * FROM sets'), isEmpty);
        expect(await db.getAll('SELECT * FROM operations'), isEmpty);
      },
    );
  });

  group('repository (real DB)', () {
    test('bestTopSet and lastTopSet can exclude one session', () async {
      await seedSession('Y', '2026-09-22');
      await seedSet('y1', 'Y', 'bench', 1, '90.00', top: true);
      await seedSession('T', '2026-09-23');
      await seedSet('t1', 'T', 'bench', 1, '100.00', top: true);
      final repo = SessionRepository.local(db);

      expect(await repo.bestTopSet('bench'), 100);
      expect(await repo.bestTopSet('bench', excludeSessionId: 'T'), 90);
      expect((await repo.lastTopSet('bench'))!.date, '2026-09-23');
      final last = (await repo.lastTopSet('bench', excludeSessionId: 'T'))!;
      expect(last.date, '2026-09-22');
      expect(last.weight, 90);
      final before = (await repo.lastTopSet(
        'bench',
        beforeDate: '2026-09-24',
        excludeSessionId: 'T',
      ))!;
      expect(before.date, '2026-09-22');
      expect(await repo.bestTopSet('bench', excludeSessionId: 'Y'), 100);
    });

    test('sessionById returns the row, or null once it is gone', () async {
      await seedSession('S', '2026-09-23', day: 'd1');
      final repo = SessionRepository.local(db);
      final row = (await repo.sessionById('S'))!;
      expect(row.date, '2026-09-23');
      expect(row.durationMin, 40);
      expect(await repo.sessionById('nope'), isNull);
    });
  });

  group('addBlock baseline (real DB)', () {
    Future<ActiveSessionController> controllerWithBench({
      String? sessionId,
    }) async {
      await seedExercise('bench', 'Bench');
      await seedSession('Y', '2026-09-22');
      await seedSet('y1', 'Y', 'bench', 1, '90.00', top: true);
      await seedSession('S', '2026-09-23');
      await seedSet('s1', 'S', 'bench', 1, '100.00', top: true);
      final c = ActiveSessionController()
        ..seedForTest(
          SessionDraft(
            templateId: null,
            name: 'Upper A',
            focus: '',
            startedAt: DateTime(2026, 9, 23, 9),
            blocks: [],
            sessionId: sessionId,
            sessionDate: sessionId == null ? null : '2026-09-23',
          ),
        );
      addTearDown(c.dispose);
      final bench = (await ExerciseRepository.local(db).byId('bench'))!;
      await c.addBlock(bench, sessionRepo: SessionRepository.local(db));
      return c;
    }

    test(
      'an exercise added to a resumed workout is baselined without its own rows',
      () async {
        final c = await controllerWithBench(sessionId: 'S');
        expect(c.draft.blocks.single.bestKg, 90);
        expect(c.draft.blocks.single.lastTop!.date, '2026-09-22');
      },
    );

    test('a fresh workout still sees every logged session', () async {
      final c = await controllerWithBench();
      expect(c.draft.blocks.single.bestKg, 100);
      expect(c.draft.blocks.single.lastTop!.date, '2026-09-23');
    });

    // Blocks are keyed by exercise id on screen: a second block for the same
    // exercise duplicates the key and the live workout glitches.
    test('an exercise already in the workout is not added again', () async {
      final c = await controllerWithBench();
      final bench = (await ExerciseRepository.local(db).byId('bench'))!;
      await c.addBlock(bench, sessionRepo: SessionRepository.local(db));
      expect(c.draft.blocks, hasLength(1));
    });

    test('two adds of the same exercise in flight add it once', () async {
      await seedExercise('row', 'Row');
      final c = await controllerWithBench();
      final row = (await ExerciseRepository.local(db).byId('row'))!;
      final repo = SessionRepository.local(db);
      await Future.wait([
        c.addBlock(row, sessionRepo: repo),
        c.addBlock(row, sessionRepo: repo),
      ]);
      expect(c.draft.blocks.map((b) => b.exercise.id), ['bench', 'row']);
    });
  });

  group('restoreFinishedDraft (real DB)', () {
    Exercise bench() => const Exercise(
      id: 'bench',
      name: 'Bench',
      slug: 'bench',
      muscleGroup: 'chest',
      compound: true,
      plateStepKg: 2.5,
      isTemplate: false,
    );

    BlockState benchBlock() => BlockState(
      exercise: bench(),
      resolved: ResolvedSlot(
        exercise: bench(),
        workSets: 3,
        warmupSets: 0,
        repLow: 5,
        repHigh: 8,
        rirLow: 1,
        rirHigh: 2,
      ),
      warmupSets: [],
      workingSets: [
        SetState(
          id: 's1',
          weightKg: 100,
          reps: 5,
          rir: 1,
          isWarmup: false,
          done: true,
        ),
        SetState(
          id: 's3',
          weightKg: 95,
          reps: 5,
          rir: 1,
          isWarmup: false,
          done: false,
        ),
      ],
      expanded: true,
      bestKg: 90,
    );

    FinishedSession finished(List<BlockState> blocks) => FinishedSession(
      sessionId: 'S',
      sessionDate: '2026-09-23',
      finishedAt: DateTime(2026, 9, 23, 10, 0),
      elapsedSeconds: 2400,
      draft: SessionDraft(
        templateId: null,
        name: 'Upper A',
        focus: '',
        startedAt: DateTime(2026, 9, 23, 9, 20),
        blocks: blocks,
      ),
    );

    test(
      'restores the snapshot, baselines a History-added exercise without this session, continues the clock',
      () async {
        await seedExercise('bench', 'Bench');
        await seedExercise('curl', 'Curl');
        await seedSession('Y', '2026-09-22');
        await seedSet('y2', 'Y', 'curl', 1, '20.00', top: true);
        await seedSession('S', '2026-09-23');
        await seedSet('s1', 'S', 'bench', 1, '100.00', top: true);
        await seedSet(
          'x1',
          'S',
          'curl',
          1,
          '22.50',
          top: true,
        ); // added in History
        final repo = SessionRepository.local(db);
        final now = DateTime(2026, 9, 23, 10, 10);

        final d = await restoreFinishedDraft(
          finished([benchBlock()]),
          await repo.setsForSession('S'),
          durationMin: 39,
          exerciseRepo: ExerciseRepository.local(db),
          sessionRepo: repo,
          now: now,
        );

        expect(d.sessionId, 'S');
        expect(d.sessionDate, '2026-09-23');
        expect(d.startedAt, now.subtract(const Duration(seconds: 2400)));
        expect(d.blocks.map((b) => b.exercise.id), ['bench', 'curl']);
        expect(d.blocks[0].workingSets.map((s) => s.id), ['s1', 's3']);
        expect(d.blocks[0].bestKg, 90); // the snapshot's pre-workout baseline
        final curl = d.blocks[1];
        expect(curl.exercise.name, 'Curl');
        expect(curl.workingSets.single.id, 'x1');
        expect(curl.workingSets.single.done, isTrue);
        expect(curl.bestKg, 20); // not this session's own 22.5
        expect(curl.lastTop!.date, '2026-09-22');
      },
    );

    test(
      'drops a planned-only block whose exercise was deleted; keeps logged sets of a deleted exercise',
      () async {
        await seedExercise('bench', 'Bench');
        await seedSession('S', '2026-09-23');
        await seedSet('s1', 'S', 'bench', 1, '100.00', top: true);
        await seedSet('z1', 'S', 'gone2', 1, '30.00', top: true);
        final ghost = Exercise(
          id: 'gone1',
          name: 'Ghost',
          slug: 'ghost',
          muscleGroup: 'chest',
          compound: false,
          plateStepKg: 2.5,
          isTemplate: false,
        );
        final planned = BlockState(
          exercise: ghost,
          resolved: ResolvedSlot(
            exercise: ghost,
            workSets: 1,
            warmupSets: 0,
            repLow: 8,
            repHigh: 12,
            rirLow: 1,
            rirHigh: 2,
          ),
          warmupSets: [],
          workingSets: [
            SetState(
              id: 'g1',
              weightKg: 10,
              reps: 10,
              rir: 1,
              isWarmup: false,
              done: false,
            ),
          ],
          expanded: true,
        );
        final repo = SessionRepository.local(db);
        final d = await restoreFinishedDraft(
          finished([benchBlock(), planned]),
          await repo.setsForSession('S'),
          durationMin: 40,
          exerciseRepo: ExerciseRepository.local(db),
          sessionRepo: repo,
          now: DateTime(2026, 9, 23, 10, 10),
        );
        expect(d.blocks.map((b) => b.exercise.id), ['bench', 'gone2']);
        expect(d.blocks[1].exercise.name, 'gone2'); // placeholder, rows kept
        expect(d.blocks[1].workingSets.single.id, 'z1');
      },
    );

    test('a stale snapshot cannot roll the clock back', () async {
      await seedExercise('bench', 'Bench');
      await seedSession('S', '2026-09-23');
      await seedSet('s1', 'S', 'bench', 1, '100.00', top: true);
      final repo = SessionRepository.local(db);
      final now = DateTime(2026, 9, 23, 10, 10);
      final d = await restoreFinishedDraft(
        finished([benchBlock()]),
        await repo.setsForSession('S'),
        durationMin: 55,
        exerciseRepo: ExerciseRepository.local(db),
        sessionRepo: repo,
        now: now,
      );
      expect(d.startedAt, now.subtract(const Duration(minutes: 55)));
    });
  });

  group('resume end to end (real DB)', () {
    // Computed per test in setUp, not when the group is defined, so a run
    // that crosses midnight stays consistent.
    late String yesterday;

    Exercise exercise(String id, String name) => Exercise(
      id: id,
      name: name,
      slug: '$name-$id',
      muscleGroup: 'chest',
      compound: true,
      baseWeightKg: 60,
      plateStepKg: 2.5,
      isTemplate: false,
    );

    BlockState block(
      Exercise e,
      List<SetState> warm,
      List<SetState> work,
      double best,
    ) => BlockState(
      exercise: e,
      resolved: ResolvedSlot(
        exercise: e,
        workSets: work.length,
        warmupSets: warm.length,
        repLow: 5,
        repHigh: 8,
        rirLow: 1,
        rirHigh: 2,
      ),
      warmupSets: warm,
      workingSets: work,
      expanded: true,
      bestKg: best,
      lastTop: (weight: best, reps: 5, date: yesterday),
    );

    SetState mkSet(
      String id,
      double w, {
      bool done = true,
      bool warmup = false,
    }) => SetState(
      id: id,
      weightKg: w,
      reps: warmup ? 8 : 5,
      rir: warmup ? null : 1,
      isWarmup: warmup,
      done: done,
    );

    /// Row block FIRST — 'row' sorts after 'bench', so a restore that took its
    /// order from the DB (exercise_id order) would put bench first.
    SessionDraft freshDraft() => SessionDraft(
      templateId: 'd1',
      name: 'Upper A',
      focus: 'Push',
      startedAt: DateTime.now().subtract(const Duration(minutes: 40)),
      blocks: [
        block(exercise('row', 'Row'), [], [
          mkSet('t1', 52.5),
          mkSet('t2', 52.5, done: false),
        ], 50),
        block(
          exercise('bench', 'Bench'),
          [mkSet('w1', 40, warmup: true)],
          [mkSet('s1', 100), mkSet('s2', 95), mkSet('s3', 95, done: false)],
          90,
        ),
      ],
    );

    late SessionManager m;
    late DraftStore drafts;

    setUp(() async {
      yesterday = isoDate(DateTime.now().subtract(const Duration(days: 1)));
      await seedDay('d1');
      await seedExercise('bench', 'Bench');
      await seedExercise('row', 'Row');
      await seedSession('Y', yesterday, day: 'd1');
      await seedSet('y1', 'Y', 'bench', 1, '90.00', top: true);
      await seedSet('y2', 'Y', 'row', 1, '50.00', top: true);
      drafts = DraftStore.local(db);
      m = SessionManager(
        finishedStore: FinishedSessionStore.local(db),
        draftStore: drafts,
      );
    });

    tearDown(() => m.dispose());

    /// The production finish path: one real write transaction, then the
    /// snapshot handed to the manager once it has committed.
    Future<FinishedSession> finish(ActiveSessionController c) async {
      final id = await finishWorkout(
        c,
        m,
        repository: WorkoutRepository.local(db),
      );
      final f = m.lastFinished!;
      expect(f.sessionId, id);
      expect(f, same(c.lastFinished));
      return f;
    }

    Future<FinishedSession> finishFresh() async {
      await drafts.load();
      final c = ActiveSessionController(draftStore: drafts)
        ..seedForTest(freshDraft());
      addTearDown(c.dispose);
      await c.flushPersistence();
      m.register(c);
      return finish(c);
    }

    Future<ActiveSessionController?> resume(
      FinishedSession f, {
      DateTime? now,
    }) => prepareResume(
      m,
      f.sessionId,
      sessionRepo: SessionRepository.local(db),
      exerciseRepo: ExerciseRepository.local(db),
      draftStore: drafts,
      now: now ?? f.finishedAt.add(const Duration(minutes: 5)),
    );

    test(
      'finish → resume → finish again leaves one session with the original id and date',
      () async {
        final f = await finishFresh();
        final c = (await resume(f))!;

        expect(m.active, same(c));
        final d = c.draft;
        expect(d.sessionId, f.sessionId);
        expect(d.blocks.map((b) => b.exercise.id), ['row', 'bench']);
        expect(
          (await drafts.load())?.sessionId,
          f.sessionId,
        ); // persisted before register
        // The clock continues from the finish: resumed 5 minutes later, the
        // workout time is still the elapsed time at finish.
        expect(
          d.startedAt,
          f.finishedAt
              .add(const Duration(minutes: 5))
              .subtract(Duration(seconds: f.elapsedSeconds)),
        );
        final s3 = d.blocks[1].workingSets.last;
        expect(s3.id, 's3');
        expect(s3.done, isFalse);

        c.toggleDone(d.blocks[1], s3);
        await finish(c);

        final sessions = await db.getAll(
          'SELECT id, date FROM sessions WHERE id != ?',
          ['Y'],
        );
        expect(sessions.single['id'], f.sessionId);
        expect(
          sessions.single['date'],
          f.sessionDate,
        ); // the first finish's date
        final sets = await db.getAll(
          'SELECT id, legacy_local_top AS is_top_set, legacy_local_pr AS is_pr FROM reps_compat1_legacy_local WHERE deleted=0 AND session_id = ? ORDER BY id',
          [f.sessionId],
        );
        expect(sets.map((r) => r['id']), ['s1', 's2', 's3', 't1', 'w1']);
        final s1 = sets.firstWhere((r) => r['id'] == 's1');
        expect(s1['is_top_set'], 1);
        expect(s1['is_pr'], 1); // 100 > the pre-workout 90
        expect(m.hasActive, isFalse);
        expect(m.lastFinished!.sessionId, f.sessionId);
      },
    );

    test(
      'the re-finish records one workoutReplace and preserves the workout identity',
      () async {
        final f = await finishFresh();
        final originalOperation = await db.get(
          'SELECT * FROM operations WHERE target_id=?',
          [f.sessionId],
        );
        final c = (await resume(f))!;
        await finish(c);

        final operations = await db.getAll(
          'SELECT * FROM operations WHERE target_id=? ORDER BY rowid',
          [f.sessionId],
        );
        expect(operations.map((r) => r['action']), [
          'workoutFinish',
          'workoutReplace',
        ]);
        expect(operations.first, originalOperation);
        expect(operations.last['base_local_revision'], 1);
        expect(
          operations.last['operation_id'],
          isNot(originalOperation['operation_id']),
        );
        expect(operations.last['input_bytes'], isNotEmpty);
        expect(operations.last['input_hash'], isNotEmpty);
        expect(
          (await db.get('SELECT * FROM sessions WHERE id=?', [
            f.sessionId,
          ]))['revision'],
          2,
        );
      },
    );

    test(
      'a training day deleted before the re-finish does not cost the session',
      () async {
        final f = await finishFresh();
        await db.execute('DELETE FROM day_templates WHERE id = ?', ['d1']);
        final c = (await resume(f))!;
        await finish(c);

        expect(
          (await db.get('SELECT * FROM sessions WHERE id=?', [
            f.sessionId,
          ]))['original_day_id'],
          'd1',
        );
        expect(
          (await db.get('SELECT * FROM sessions WHERE id=?', [
            f.sessionId,
          ]))['day_template_id'],
          isNull,
        );
        expect(
          (await db.getAll('SELECT id FROM sessions WHERE id = ?', [
            f.sessionId,
          ])).length,
          1,
        );
      },
    );

    test(
      'a workout tombstone during resume requires explicit restore and never recreates history',
      () async {
        final f = await finishFresh();
        final c = (await resume(f))!;
        await SessionRepository.local(
          db,
        ).deleteSession(f.sessionId, observedRevision: 1);
        final before = await db.store.inventory();
        await expectLater(finish(c), throwsA(isA<StoreException>()));
        expect(await db.store.inventory(), before);
        expect(c.hasSession, isTrue);
        expect(c.pendingFinish, isNotNull);
        expect(
          (await db.get('SELECT * FROM sessions WHERE id=?', [
            f.sessionId,
          ]))['deleted'],
          1,
        );
      },
    );

    test('History edits between finish and resume survive', () async {
      final f = await finishFresh();
      final repo = SessionRepository.local(db);
      await repo.setsForSession(f.sessionId);
      await repo.updateSet('s2', weightKg: '97.50', reps: 6, rir: 2);
      await repo.deleteSet('t1');
      final added = await repo.addSet(
        f.sessionId,
        'bench',
        weightKg: '80.00',
        reps: 10,
        rir: null,
        isWarmup: false,
      );

      final d = (await resume(f))!.draft;
      final bench = d.blocks.firstWhere((b) => b.exercise.id == 'bench');
      expect(bench.workingSets.map((s) => s.id), ['s1', 's2', 's3', added]);
      expect(bench.workingSets[1].weightKg, 97.5);
      expect(bench.workingSets[1].reps, 6);
      expect(bench.workingSets.last.done, isTrue);
      final row = d.blocks.firstWhere((b) => b.exercise.id == 'row');
      expect(row.workingSets.map((s) => s.id), [
        't2',
      ]); // t1 deleted, t2 planned
    });

    test(
      'discarding a resumed workout leaves the finished rows untouched and resumable',
      () async {
        final f = await finishFresh();
        Future<List<Map<String, Object?>>> rows() async => [
          for (final r in await db.getAll('SELECT * FROM sessions ORDER BY id'))
            Map.of(r),
          for (final r in await db.getAll('SELECT * FROM sets ORDER BY id'))
            Map.of(r),
        ];
        final before = await rows();

        final c = (await resume(f))!;
        final bench = c.draft.blocks[1];
        c.toggleDone(bench, bench.workingSets.last);
        await c.discard();

        expect(await rows(), before);
        expect(m.hasActive, isFalse);
        expect(m.lastFinished, same(f));
        expect(await resume(f), isNotNull);
      },
    );

    test(
      'two overlapping resume calls register exactly one controller',
      () async {
        final f = await finishFresh();
        final results = await Future.wait([resume(f), resume(f)]);
        final controllers = results
            .whereType<ActiveSessionController>()
            .toList();
        expect(controllers.length, 1);
        expect(m.active, same(controllers.single));
        expect(m.launching, isFalse);
      },
    );

    test(
      'an expired snapshot, a running workout or a vanished session is not resumed',
      () async {
        final f = await finishFresh();
        expect(
          await resume(f, now: f.finishedAt.add(const Duration(days: 2))),
          isNull,
        );

        final other = ActiveSessionController(draftStore: drafts)
          ..seedEmpty(name: 'Custom', focus: '');
        addTearDown(other.dispose);
        m.register(other);
        expect(await resume(f), isNull);
        await other.discard();

        await SessionRepository.local(
          db,
        ).deleteSession(f.sessionId, observedRevision: 1);
        await expectLater(resume(f), throwsA(isA<StoreException>()));
        expect(m.lastFinished, same(f)); // retained for explicit review/restore
      },
    );
  });
}
