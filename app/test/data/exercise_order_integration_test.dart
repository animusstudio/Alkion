import 'package:alkion/data/active_session_draft.dart';
import '../support/screen_harness.dart';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/data/session_repository.dart';
import 'package:alkion/data/session_writer.dart';
import 'package:alkion/session/active_session_controller.dart';

/// A session's exercises read back (History, summary) in the order they were
/// done, not in exercise-id order — against a real production SQLite store.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late FixtureDatabase db;
  late SessionRepository repo;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    dir = await Directory.systemTemp.createTemp('alkion-order');
    db = await FixtureDatabase.open(dir);
    await db.initialize();
    repo = SessionRepository.local(db);
    await db.execute(
      'INSERT INTO sessions (id, date, split_label, duration_min) VALUES (?, ?, ?, ?)',
      ['S', '2026-09-24', 'Upper A', 40],
    );
  });

  tearDown(() async {
    await db.close();
    await dir.delete(recursive: true);
  });

  Future<void> seedSet(String id, String exerciseId, int n) => db.execute(
    'INSERT INTO sets (id, session_id, exercise_id, set_number, weight_kg, reps, rir, '
    'is_warmup, is_top_set, is_pr) VALUES (?, ?, ?, ?, ?, 5, 1, 0, 0, 0)',
    [id, 'S', exerciseId, n, '50.00'],
  );

  Future<List<String>> order() async => repo
      .groupIntoBlocks(await repo.setsForSession('S'))
      .map((b) => b.exerciseId)
      .toList();

  test('exercises read back in the order of their first set', () async {
    await seedSet('z1', 'zz', 1);
    await seedSet('z2', 'zz', 2);
    await seedSet('a1', 'aa', 3);
    await seedSet('a2', 'aa', 4);
    expect(await order(), ['zz', 'aa']);
    final sets = await repo.setsForSession('S');
    expect(sets.map((s) => s.id), ['z1', 'z2', 'a1', 'a2']);
  });

  test(
    'a session numbered per exercise (older builds) keeps exercise-id order',
    () async {
      await seedSet('z1', 'zz', 1);
      await seedSet('a1', 'aa', 1);
      await seedSet('a2', 'aa', 2);
      expect(await order(), ['aa', 'zz']);
      expect((await repo.setsForSession('S')).map((s) => s.id), [
        'a1',
        'a2',
        'z1',
      ]);
    },
  );

  test('History adds a set after every set of the workout', () async {
    await seedSet('z1', 'zz', 1);
    await seedSet('a1', 'aa', 2);
    await repo.setsForSession('S');
    final toExisting = await repo.addSet(
      'S',
      'zz',
      weightKg: '50.00',
      reps: 5,
      rir: 1,
      isWarmup: false,
    );
    await db.execute(
      'INSERT INTO exercises (id,name,is_template) VALUES (?,?,0)',
      ['mm', 'mm'],
    );
    final toNew = await repo.addSet(
      'S',
      'mm',
      weightKg: '10.00',
      reps: 12,
      rir: null,
      isWarmup: false,
    );
    final numbers = {
      for (final s in await repo.setsForSession('S')) s.id: s.setNumber,
    };
    expect(numbers[toExisting], 3);
    expect(numbers[toNew], 4);
    expect(await order(), [
      'zz',
      'aa',
      'mm',
    ]); // an exercise added in History comes last
  });

  test(
    'a finished workout reads back in workout order, after a reorder',
    () async {
      Exercise ex(String id) => Exercise(
        id: id,
        name: id,
        slug: id,
        muscleGroup: 'chest',
        compound: false,
        plateStepKg: 2.5,
        isTemplate: false,
      );
      BlockState block(String id, String setId) => BlockState(
        exercise: ex(id),
        resolved: ResolvedSlot(
          exercise: ex(id),
          workSets: 1,
          warmupSets: 0,
          repLow: 8,
          repHigh: 10,
          rirLow: 1,
          rirHigh: 2,
        ),
        warmupSets: [],
        workingSets: [
          SetState(
            id: setId,
            weightKg: 40,
            reps: 8,
            rir: 1,
            isWarmup: false,
            done: true,
          ),
        ],
        expanded: true,
      );
      final a = block('aa', 'x1');
      final z = block('zz', 'x2');
      for (final id in ['aa', 'zz']) {
        await db.execute(
          'INSERT INTO exercises (id,name,is_template) VALUES (?,?,0)',
          [id, id],
        );
      }
      final draftStore = DraftStore.local(db);
      await draftStore.load();
      final c = ActiveSessionController(draftStore: draftStore)
        ..seedForTest(
          SessionDraft(
            templateId: null,
            name: 'Custom',
            focus: '',
            startedAt: DateTime.now().subtract(const Duration(minutes: 20)),
            blocks: [a, z],
          ),
        );
      addTearDown(c.dispose);
      c.moveBlock(z, -1); // do zz first
      await c.flushPersistence();
      final id = await c.commitFinish(WorkoutRepository.local(db));
      expect(
        repo
            .groupIntoBlocks(await repo.setsForSession(id))
            .map((b) => b.exerciseId),
        ['zz', 'aa'],
      );
    },
  );
}
